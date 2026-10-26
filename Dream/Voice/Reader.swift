import AVFoundation
import NaturalLanguage

/// Text to speech, for "Read this page" and hands-free steps. Each passage is put together just
/// before it's spoken, so a number you've just changed is read as it is now.
@MainActor @Observable
final class Reader: NSObject {
    enum Phase {
        case idle, speaking, paused
    }

    private(set) var phase: Phase = .idle
    /// The passage being read, so the page can mark it.
    private(set) var passageID: String?
    /// How far through: the passage being read, out of how many.
    private(set) var position = 0
    private(set) var count = 0
    var use: VoiceSession.Use = .reading

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var script: (() -> [Narration.Passage])?
    @ObservationIgnored private var onFinish: (() -> Void)?
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    /// The utterance being spoken; callbacks for any other are stale. Held, so no new one can
    /// take its identity.
    @ObservationIgnored private var current: AVSpeechUtterance?
    @ObservationIgnored private var holdsSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads passages in order. `script` is asked again before each one, for live values;
    /// `sample` is text in the page's language, to choose a voice.
    func read(_ script: @escaping () -> [Narration.Passage], sample: String, onFinish: (() -> Void)? = nil) {
        stop()
        guard !script().isEmpty else { return }
        do {
            try VoiceSession.acquire(use)
            holdsSession = true
        } catch {
            return
        }
        self.script = script
        self.onFinish = onFinish
        voice = Self.voice(for: sample)
        position = 0
        speakCurrent()
    }

    /// Says one thing, then calls `onFinish`.
    func say(_ text: String, onFinish: @escaping () -> Void) {
        read({ [Narration.Passage(id: "", text: text)] }, sample: text, onFinish: onFinish)
    }

    func pause() {
        guard phase == .speaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        synthesizer.continueSpeaking()
        phase = .speaking
    }

    func stop() {
        script = nil
        onFinish = nil
        current = nil
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        finishUp()
    }

    private func speakCurrent() {
        guard let passages = script?(), position < passages.count else {
            let onFinish = self.onFinish
            script = nil
            self.onFinish = nil
            finishUp()
            onFinish?()
            return
        }
        let passage = passages[position]
        count = passages.count
        passageID = passage.id.isEmpty ? nil : passage.id
        let utterance = AVSpeechUtterance(string: passage.text)
        utterance.voice = voice
        // Someone who uses VoiceOver hears their own voice and speed.
        utterance.prefersAssistiveTechnologySettings = true
        utterance.postUtteranceDelay = 0.2
        current = utterance
        synthesizer.speak(utterance)
        phase = .speaking
    }

    private func finished(_ utterance: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == utterance else { return }
        position += 1
        speakCurrent()
    }

    private func finishUp() {
        phase = .idle
        passageID = nil
        position = 0
        count = 0
        if holdsSession {
            VoiceSession.release()
            holdsSession = false
        }
    }

    /// The best installed voice for the text's language: premium or enhanced when they're
    /// there, and the reader's own accent when it's as good.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) } ?? Locale.current.language
        guard let code = detected.languageCode?.identifier else { return nil }
        let region = Locale.current.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            Locale.Language(identifier: voice.language).languageCode?.identifier == code
                && !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            let local = region != nil && Locale.Language(identifier: voice.language).region?.identifier == region
            return voice.quality.rawValue * 2 + (local ? 3 : 0)
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: code)
    }
}

extension Reader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
