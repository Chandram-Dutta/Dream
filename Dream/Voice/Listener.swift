import AVFoundation
import Speech

/// Speech to text, on the phone: SpeechAnalyzer with a transcriber, fed from the microphone.
/// It fills a text field as you talk and stops by itself when you pause. Nothing you say
/// leaves the phone.
@MainActor @Observable
final class Listener {
    enum Phase: Equatable {
        case idle
        /// Getting the microphone and speech model ready. The first time, the model may need
        /// downloading; `progress` says how far that's got.
        case preparing(progress: Double?)
        case listening
        case unavailable(Problem)
    }

    enum Problem: Equatable {
        /// The microphone is off for Dream in Settings.
        case denied
        /// This phone can't transcribe the reader's language.
        case unsupported
        case failed
    }

    private(set) var phase: Phase = .idle
    /// Everything heard so far: the settled words, then the best guess at the ones still being said.
    private(set) var transcript = ""
    /// How loud the voice is right now, from 0 to 1. For motion only.
    private(set) var level: Double = 0
    /// How long a pause ends listening. Nil keeps listening until told to stop, for commands.
    var pauseToStop: Duration? = .seconds(1.5)
    var use: VoiceSession.Use = .listening
    /// Called whenever the transcript changes.
    var onTranscript: ((String) -> Void)?
    /// While Dream itself is speaking, so it doesn't hear itself.
    var isMuted = false {
        didSet { gate.isOpen = !isMuted }
    }

    var isActive: Bool {
        switch phase {
        case .preparing, .listening: true
        case .idle, .unavailable: false
        }
    }

    private var completion: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var holdsSession = false
    private let gate = Gate()
    /// Each start gets a number, so a start still getting ready can tell it's been stopped.
    private var attempt = 0
    private var settled = ""
    private var volatile = ""
    private var startedAt = ContinuousClock.now
    private var lastWords = ContinuousClock.now
    private var lastSound = ContinuousClock.now

    /// Starts listening. `onFinish` gets what was heard when listening ends by itself or with
    /// `finish()`, unless nothing was.
    func start(onFinish: @escaping (String) -> Void) async {
        guard !isActive else { return }
        attempt += 1
        let current = attempt
        completion = onFinish
        settled = ""
        volatile = ""
        transcript = ""
        phase = .preparing(progress: nil)

        guard await Self.microphoneAllowed() else {
            if attempt == current { phase = .unavailable(.denied) }
            return
        }
        // A start that fails has already put back what it took.
        do {
            try await begin(attempt: current)
        } catch Problem.unsupported {
            if attempt == current { phase = .unavailable(.unsupported) }
        } catch {
            // Speech recognition may also need asking for; ask once, then try again.
            if attempt == current, SFSpeechRecognizer.authorizationStatus() == .notDetermined, await Self.speechAllowed(),
               (try? await begin(attempt: current)) != nil {
                return
            }
            if attempt == current { phase = .unavailable(.failed) }
        }
    }

    /// Stops listening and hands over what was heard.
    func finish() {
        Task { await stop(delivering: true) }
    }

    /// Stops listening and forgets what was heard.
    func cancel() {
        Task { await stop(delivering: false) }
    }

    /// Starts the transcript afresh, keeping the microphone open: after each command in hands-free steps.
    func clearTranscript() {
        settled = ""
        volatile = ""
        transcript = ""
        lastWords = .now
    }

    // MARK: - Starting

    /// Gets everything ready, then starts. Stopped part way (`attempt` moves on), it puts back
    /// what it took and leaves quietly.
    private func begin(attempt current: Int) async throws {
        let transcriber = try await Transcriber.make()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
            guard attempt == current else { return }
            phase = .preparing(progress: 0)
            let progress = Task { [weak self] in
                while !Task.isCancelled, let self, self.attempt == current {
                    self.phase = .preparing(progress: request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { progress.cancel() }
            try await request.downloadAndInstall()
        }
        guard attempt == current else { return }

        // The session comes first: the microphone's format depends on it.
        try VoiceSession.acquire(use)
        var started = false
        defer { if !started { VoiceSession.release() } }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Problem.failed }
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module], considering: format)
        let converter: AnalyzerInputConverter
        if let analyzerFormat {
            converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        } else {
            converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber.module])
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber.module])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        guard attempt == current else { return }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        gate.isOpen = !isMuted
        try Self.installTap(on: engine.inputNode, format: format, converter: converter, gate: gate, input: input) { [weak self] level in
            Task { @MainActor in self?.hear(level) }
        }
        func abandon() async {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            input.finish()
            await analyzer.cancelAndFinishNow()
        }
        do {
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            await abandon()
            throw error
        }
        guard attempt == current else {
            await abandon()
            return
        }

        started = true
        holdsSession = true
        self.engine = engine
        self.analyzer = analyzer
        self.input = input
        results = Task { [weak self] in
            do {
                switch transcriber {
                case .speech(let module):
                    for try await result in module.results { self?.received(String(result.text.characters), isFinal: result.isFinal) }
                case .dictation(let module):
                    for try await result in module.results { self?.received(String(result.text.characters), isFinal: result.isFinal) }
                }
            } catch {}
        }
        startedAt = .now
        lastWords = .now
        lastSound = .now
        phase = .listening
        watch(engine)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.checkForPause()
            }
        }
    }

    /// Audio arrives on its own thread: measure it, then pass it on unless muted.
    nonisolated private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, converter: AnalyzerInputConverter, gate: Gate,
                                               input: AsyncStream<AnalyzerInput>.Continuation, level: @escaping @Sendable (Double) -> Void) throws {
        try node.installAudioTap(onBus: 0, bufferSize: 4800, format: format) { shared, _ in
            guard gate.isOpen else {
                level(0)
                return
            }
            let buffer = AVAudioPCMBuffer(copying: shared)
            level(loudness(of: buffer))
            guard let converted = try? converter.convert(buffer, at: nil) else { return }
            for item in converted { input.yield(item) }
        }
    }

    /// Loudness from 0 (a quiet room) to 1 (talking close to the phone).
    nonisolated private static func loudness(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let decibels = 20 * log10(max((sum / Float(count)).squareRoot(), 1e-6))
        return Double(min(max((decibels + 55) / 40, 0), 1))
    }

    /// A phone call, Siri, or headphones coming and going end listening.
    private func watch(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            },
        ]
    }

    // MARK: - Hearing

    private func hear(_ value: Double) {
        guard phase == .listening else { return }
        // Quick to rise, slow to fall, so motion follows the voice without flickering.
        level = value > level ? level + (value - level) * 0.6 : level + (value - level) * 0.15
        if value > 0.45 { lastSound = .now }
    }

    private func received(_ text: String, isFinal: Bool) {
        if isFinal {
            settled = Self.joined(settled, text)
            volatile = ""
        } else {
            volatile = text
        }
        let heard = Self.joined(settled, volatile)
        guard heard != transcript else { return }
        transcript = heard
        lastWords = .now
        onTranscript?(heard)
    }

    private static func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespaces)
        let second = second.trimmingCharacters(in: .whitespaces)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    /// Ends listening after a pause in what you're saying, or if nothing's said at all.
    private func checkForPause() {
        guard phase == .listening, !isMuted else { return }
        let now = ContinuousClock.now
        if transcript.isEmpty {
            if pauseToStop != nil, now - startedAt > .seconds(8) { finish() }
            return
        }
        guard let pause = pauseToStop else { return }
        // Words have stopped and so has the sound; or words have stopped for long enough
        // that the sound must be something else, like a fan.
        if (now - lastWords > pause && now - lastSound > pause) || now - lastWords > pause * 2 {
            finish()
        }
    }

    // MARK: - Stopping

    private func stop(delivering: Bool) async {
        guard isActive else { return }
        attempt += 1
        let completion = self.completion
        self.completion = nil
        phase = .idle
        level = 0
        if let analyzer {
            input?.finish()
            input = nil
            // The last words settle once the audio's ended.
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
        await tearDown()
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if delivering, !heard.isEmpty { completion?(heard) }
    }

    private func tearDown() async {
        watchdog?.cancel()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        input?.finish()
        input = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        results?.cancel()
        results = nil
        if holdsSession {
            VoiceSession.release()
            holdsSession = false
        }
    }

    // MARK: - Permission

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    private static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }
}

extension Listener.Problem: Error {}

/// The transcriber for the reader's language: SpeechTranscriber where the phone has it, and
/// dictation's model where it doesn't.
private enum Transcriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }

    static func make() async throws -> Transcriber {
        let wanted = Locale.current
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            await reserve(locale)
            return .speech(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            await reserve(locale)
            return .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
        }
        throw Listener.Problem.unsupported
    }

    /// Keeps the language's model on the phone for Dream.
    private static func reserve(_ locale: Locale) async {
        guard !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
    }
}

/// Whether the microphone's sound goes on to the transcriber. Read on the audio thread.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}
