import CoreGraphics
import Foundation
import FoundationModels
import Observation

/// One step of the work behind a page, as the screen shows it: what was searched for, which
/// site was read, which article was looked up.
struct Trace: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case search, read, lookup }

    let id = UUID()
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// A page's site as people say it: "livemint.com", not "https://www.livemint.com/…".
    static func site(_ url: String) -> String {
        let host = URL(string: url)?.host() ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Turns what the user wants into a surface: one screen that explains, calculates, or both.
///
/// A capable model (Grok, or Private Cloud Compute once Apple grants it) writes the whole surface
/// in one pass, looking things up itself through `LookupTool`. The checker fixes what it can and
/// sends real mistakes back in the same session. Apple's on-device model doesn't build screens;
/// it's kept for small private jobs elsewhere, like the ideas on the home screen.
@MainActor @Observable
final class Composer {
    enum Phase: Equatable {
        case idle, researching, composing, fixing(Int), done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// The surface as it stands, including while it's streaming in.
    private(set) var surface: Surface?
    private(set) var log: [String] = []
    private(set) var modelName = ""
    /// Working, but with nothing new on screen for a moment: reasoning, or looking something up.
    /// The screen shows it in the color field rather than in words.
    private(set) var isThinking = false
    /// The model's questions before it builds, and the user's answers. The screen shows them while the model waits.
    let asking = Asking()
    /// The live data fetched while writing, which the surface's live inputs bind to.
    private let live = LiveLog()
    /// Buttons proposed for connected services' write tools, and which services were read.
    private let connected = ConnectionLog()
    /// What a connected service's tool waits on the user to allow. The screen shows it like the questions.
    let consent = Consent()
    /// Services the request names that the user hasn't connected, which the screen offers to connect.
    private(set) var suggestions: [DirectoryEntry] = []
    /// The work as it happens: each search, page read and article looked up, as it starts. The
    /// screen shows the latest while a page forms, and each one stirs the light (FormingView).
    private(set) var trail: [Trace] = []
    /// The web pages read while writing, which the surface may cite (WebSearch.swift).
    private let web = WebLog()

    /// Which model writes surfaces. If the chosen one can't be used or fails, the next is tried.
    enum Provider: String, CaseIterable {
        /// Grok through Dream's server, with the signed-in user's session and allowance (DreamModel.swift).
        case dream
        /// Grok, with the developer's own xAI API key from the Keychain.
        case xai
        /// Needs an entitlement Apple grants on request (com.apple.developer.private-cloud-compute).
        case privateCloud

        var name: String {
            switch self {
            // On Auto, what the router picked for this page (Route.swift), like "Auto → Grok 4.7 · high".
            case .dream: Route.current?.label ?? "Dream (\(Composer.dreamModelID.isEmpty ? "default" : Composer.dreamModelID))"
            case .xai: "Grok (\(Composer.xaiModelID))"
            case .privateCloud: "Private Cloud Compute"
            }
        }

        var isUsable: Bool {
            switch self {
            case .dream: DreamLanguageModel.isUsable
            case .xai: XAILanguageModel.savedKey != nil
            case .privateCloud: PrivateCloudComputeLanguageModel().isAvailable
            }
        }
    }

    nonisolated static var provider: Provider { Provider(rawValue: Build.setting("provider") ?? "") ?? .dream }
    nonisolated static var xaiModelID: String { Build.setting("xaiModel") ?? "grok-4.7" }
    /// The model Dream's server is asked for: the one picked in Account, which only Dream Plus
    /// can use, or none, for the server's default (Server/src/models.ts). Testing builds can name
    /// one at launch, like `-xaiModel grok-4.7`.
    nonisolated static var dreamModelID: String { Build.setting("xaiModel") ?? ModelChoice.picked ?? ModelChoice.auto }

    /// Whether any model can make screens right now.
    static var canCompose: Bool { Provider.allCases.contains { $0.isUsable } }

    /// The model this request runs on.
    private var active: Provider = .dream
    /// This build or change, as Dream's server counts pages: every request for it, the gap check
    /// included, carries it.
    private var page = UUID().uuidString
    /// The request's language, whose Wikipedia lookups read first.
    private var language = "en"
    /// While the gap check decides, the page streams in out of sight for a few seconds, so it
    /// rarely appears only to give way to questions.
    private var isChecking = false
    private var held: Surface?
    private var holdUntil = Date.distantPast
    /// What the user asked for, which picks the connected services' tools worth offering.
    private var request = ""

    /// Makes a new page: on Dream's server when that's switched on (Composer+Server.swift),
    /// otherwise here.
    func compose(intent: String, image: CGImage? = nil, onServer: Bool = ServerCompose.isOn) async {
        if onServer {
            await composeOnServer(intent: intent, image: image)
            return
        }
        let started = Date()
        job = nil
        log = []
        trail = []
        surface = nil
        isThinking = true
        defer { isThinking = false }
        note("Request: \(intent)\(image == nil ? "" : " (with photo)")")
        page = UUID().uuidString
        Analytics.send(.pageRequested(withPhoto: image != nil))
        asking.start()
        live.start()
        connected.start()
        web.start()
        language = Languages.of(request: intent)?.rawValue ?? Languages.primary
        request = intent
        suggestions = Connections.unconnected(in: intent)
        // Auto (Route.swift): the server picks this page's model and thinking once, up front.
        if let line = await Route.start(page: page, request: intent, image: image) { note(line) }
        do {
            let context = await Prompts.context(for: intent)
            try await withModel {
                try await self.write(request: intent, image: image, context: context)
            }
            guard let surface, !surface.isEmpty else { throw ComposeError("Nothing came out of this. Try asking another way.") }
            recordLocale(likely: Languages.guess(intent)?.rawValue)
            phase = .done
            note("Done in \(elapsed(since: started))")
            countFinished(changing: false, since: started)
        } catch {
            fail(error)
            countFailure(error, changing: false, since: started)
        }
    }

    /// Changes a surface. `focus` is the block the user pointed at, if any.
    func edit(_ current: Surface, intent: String, instruction: String, focus: Block?) async {
        let started = Date()
        job = nil
        log = []
        trail = []
        surface = current
        isThinking = true
        defer { isThinking = false }
        note("Change: \(instruction)\(focus.map { " (pointing at #\($0.id))" } ?? "")")
        page = UUID().uuidString
        asking.start(keeping: current.answers)
        live.start(keeping: current.sources)
        connected.start(keeping: current)
        web.start(keeping: current.credits)
        language = current.locale?.language ?? Languages.of(request: intent)?.rawValue ?? Languages.primary
        request = "\(intent). \(instruction)"
        // Auto (Route.swift): a change is picked for like a new page.
        if let line = await Route.start(page: page, request: request, image: nil) { note(line) }
        do {
            let context = await Prompts.context(for: intent)
            let asked = Prompts.edit(intent: intent, surface: current, instruction: instruction, focus: focus, context: context)
            try await withModel {
                try await self.write(prompt: Prompt(asked), asked: asked, fallback: current.reference, streaming: false)
            }
            recordLocale(likely: current.locale?.language, editing: current.locale)
            phase = .done
            note("Done in \(elapsed(since: started))")
            countFinished(changing: true, pointed: focus != nil, since: started)
        } catch {
            surface = current
            fail(error)
            countFailure(error, changing: true, since: started)
        }
    }

    // MARK: - On Dream's server

    /// The job on Dream's server making what this shows, while a new page is made there.
    private(set) var job: ServerJob?
    /// What reads the job's events, while something does.
    @ObservationIgnored var watch: ServerWatch?
    /// Told as soon as a page has started on Dream's server, so the app can keep the job and find
    /// it again if it leaves the page mid-way.
    @ObservationIgnored var onJob: ((ServerJob) -> Void)?

    /// Shows a page being made on Dream's server as far as its events have got, in the same state
    /// a page made here fills, so the screen can't tell the two apart. Everything on that path
    /// reaches the screen through here.
    func show(_ progress: PageProgress, job: ServerJob?) {
        if self.job != job { self.job = job }
        if phase != progress.phase { phase = progress.phase }
        if surface != progress.surface { surface = progress.surface }
        if trail != progress.trail { trail = progress.trail }
        if log != progress.log {
            for line in progress.log.dropFirst(log.count) { Build.trace("[Dream] \(line)") }
            log = progress.log
        }
        if isThinking != progress.isThinking { isThinking = progress.isThinking }
        if modelName != progress.model { modelName = progress.model }
    }

    // MARK: - Model

    /// Runs on the chosen model, or on the other one if the chosen can't be used or fails.
    private func withModel(_ run: () async throws -> Void) async throws {
        let usable = ([Self.provider] + Provider.allCases.filter { $0 != Self.provider }).filter(\.isUsable)
        guard let first = usable.first else {
            throw ComposeError("Sign in to make pages.")
        }
        active = first
        note("Model: \(active.name)")
        do {
            try await run()
        } catch let error where !(error is CancellationError) && usable.count > 1 {
            note("\(active.name) failed (\(describe(error))); trying \(usable[1].name).")
            active = usable[1]
            try await run()
        }
    }

    private func session(_ instructions: String, tools: [any Tool]) -> LanguageModelSession {
        switch active {
        case .dream: LanguageModelSession(model: DreamLanguageModel(modelID: Self.dreamModelID, page: page), tools: tools, instructions: instructions)
        case .xai: LanguageModelSession(model: XAILanguageModel(apiKey: XAILanguageModel.savedKey ?? "", modelID: Self.xaiModelID), tools: tools, instructions: instructions)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
    }

    /// The tools a surface is written with. Features that give the model a tool add it here.
    private func tools(found: ReferenceLog) -> [any Tool] {
        [LookupTool(found: found, language: language, onLookup: { [weak self] subject in Task { @MainActor in self?.lookingUp(subject) } }),
         RecallTool(onRecall: { [weak self] line in Task { @MainActor in self?.note(line) } }),
         LiveTool(log: live, onFetch: { [weak self] line in Task { @MainActor in self?.note(line) } })]
            + ConnectionTool.offered(for: request, asking: asking, consent: consent, live: live, log: connected, onUse: { [weak self] line in Task { @MainActor in self?.note(line) } })
            + WebTools.offered(log: web, language: language, onNote: { [weak self] line in Task { @MainActor in self?.note(line) } }, onUse: { [weak self] line in Task { @MainActor in self?.researching(line) } },
                               onTrace: { [weak self] trace in Task { @MainActor in self?.trail.append(trace) } })
    }

    private func lookingUp(_ subject: String) {
        trail.append(Trace(.lookup, subject))
        researching("Lookup: \(subject)")
    }

    private func researching(_ line: String) {
        phase = .researching
        isThinking = true
        note(line)
    }

    // MARK: - Asking

    /// Writes the surface for a request while a quick check, in its own session, looks for what
    /// the request leaves out that only the user can tell (`GapCheck`). If it finds nothing, the
    /// writing carries on untouched. If it has questions, the writing stops, what Dream remembers
    /// or the user answers them, and it starts again with the answers.
    private func write(request intent: String, image: CGImage?, context: [String]) async throws {
        func asked(_ answers: [Answer]) -> String {
            Prompts.surfaceRequest(intent, hasImage: image != nil, context: context + Prompts.answersContext(answers))
        }
        func prompt(_ answers: [Answer]) -> Prompt {
            Prompt {
                asked(answers)
                if let image { Attachment(image) }
            }
        }
        // A photo usually settles what it's about; and on a second model, the answers are in.
        guard image == nil, asking.answers.isEmpty else {
            return try await write(prompt: prompt(asking.answers), asked: asked(asking.answers), fallback: nil, streaming: true)
        }
        let started = Date()
        let first = prompt([])
        isChecking = true
        held = nil
        holdUntil = started.addingTimeInterval(GapCheck.hold)
        defer { isChecking = false; held = nil }
        let checking = Task { await self.gaps(in: intent) }
        let writing = Task { try await self.write(prompt: first, asked: asked([]), fallback: nil, streaming: true) }
        try await withTaskCancellationHandler {
            let gaps = await checking.value
            guard !gaps.questions.isEmpty else {
                note(String(format: "Check: nothing to ask (%.1fs%@)", gaps.seconds, held == nil ? "" : ", while the page was held back"))
                isChecking = false
                if surface == nil, let held { surface = held }
                try await writing.value
                return
            }
            writing.cancel()
            note(String(format: "Check: %d to ask after %.1fs, so the screen stopped %@: ", gaps.questions.count, gaps.seconds, surface != nil ? "after it showed" : held != nil ? "before it showed" : "before it began")
                 + gaps.questions.map { "\($0.text) (\($0.options.joined(separator: " / "))\($0.allowsTyping ? ", or typed" : ""))" }.joined(separator: "; "))
            for answer in gaps.remembered { note("Remembered: \(answer.question.topic)") }
            let answers = await asking.ask(gaps.questions, knowing: gaps.remembered)
            note("Answered: " + answers.map { $0.isLeftToDream ? "You choose" : $0.isRemembered ? "\($0.choice) (remembered)" : $0.choice }.joined(separator: "; ")
                 + " after \(elapsed(since: started))")
            _ = await writing.result
            surface = nil
            isChecking = false
            try await write(prompt: prompt(answers), asked: asked(answers), fallback: nil, streaming: true)
        } onCancel: {
            checking.cancel()
            writing.cancel()
        }
    }

    /// A partial surface goes on screen, unless the gap check has only just started deciding.
    private func show(_ partial: Surface) {
        if isChecking, Date.now < holdUntil { held = partial } else { surface = partial }
    }

    /// The gap check, on the model this request runs on. If it fails, nothing is asked.
    private func gaps(in intent: String) async -> GapCheck.Gaps {
        let started = Date()
        do {
            return try await GapCheck.run(intent, in: session(Prompts.gapCheck, tools: []))
        } catch {
            note("Check failed after \(elapsed(since: started)) (\(describe(error))); building without asking.")
            return GapCheck.Gaps()
        }
    }

    // MARK: - Writing

    /// Writes a whole surface, then has the checker fix what it can and sends real mistakes
    /// back in the same session, so the model sees what it wrote. `asked` is the prompt's text,
    /// for a repair to repeat when the session no longer holds it.
    private func write(prompt: Prompt, asked: String, fallback: Reference?, streaming: Bool) async throws {
        phase = .composing
        let found = ReferenceLog()
        var session = session(Prompts.surface, tools: tools(found: found))
        var surface: Surface
        do {
            surface = try await generateSurface(in: session, prompt: prompt, found: found, fallback: fallback, streaming: streaming)
            if surface.title.isEmpty, surface.summary.isEmpty { throw EmptyScreen() }
        } catch where Self.isWorthAnotherTry(error) {
            // Nothing usable came out: a loop or padding with nothing finished, a broken answer, or
            // an empty one. Another go in a new session usually works, and costs less than a page
            // that fails.
            note("Writing again in a new session, after: \(describe(error))")
            session = self.session(Prompts.surface, tools: tools(found: found))
            surface = try await generateSurface(in: session, prompt: prompt, found: found, fallback: fallback, streaming: streaming)
        }
        surface = surface.fetched(live).connected(connected)
        for round in 0...2 {
            var issues = Checker.checkLogic(&surface) + connected.problems(in: surface)
            // Once: a page about the world that looked nothing up goes back to look it up.
            if round == 0 { issues += Checker.checkSourcing(surface, read: web.reading(with: found.all)) }
            report(issues)
            let problems = issues.filter { $0.kind == .needsModel }
            if problems.isEmpty || round == 2 { break }
            phase = .fixing(problems.count)
            // A screen that stopped early left the session without the request or the screen, so
            // the repair repeats both.
            let repair = session.endsWithAnswer ? Prompts.repair(problems) : Prompts.repair(problems, restating: asked, screen: surface)
            do {
                surface = try await generateSurface(in: session, step: "Repair \(round + 1)", prompt: Prompt(repair), found: found, fallback: fallback, streaming: false)
                    .fetched(live).connected(connected)
            } catch where !(error is CancellationError) && !Task.isCancelled {
                // A repair that fails leaves the page as it was, which beats no page.
                note("Kept the screen as it was: repair \(round + 1) didn't finish (\(describe(error))).")
                break
            }
        }
        await surface.findRecordings()
        await surface.findMolecules()
        report(Checker.checkCitations(&surface, read: web.reading(with: found.all)))
        report(Checker.checkBlocks(&surface))
        surface = surface.answered(asking.answers)
        self.surface = surface
        note(surface.outline)
    }

    /// A whole surface from one request, keeping the finished blocks if the model stops early.
    /// A repair is one too, and keeps what it finished the same way.
    private func generateSurface(in session: LanguageModelSession, step: String = "Surface", prompt: Prompt, found: ReferenceLog, fallback: Reference?, streaming: Bool) async throws -> Surface {
        let onPartial: ((WireSurface.PartiallyGenerated) -> Void)? = streaming ? { self.show(Surface(partial: $0, reference: found.first ?? fallback).answered(self.asking.answers)) } : nil
        do {
            let wire = try await generate(WireSurface.self, in: session, step: step, options: GenerationOptions(temperature: 0.4), prompt: prompt,
                                          onPartial: onPartial, isRunaway: { Surface(partial: $0, reference: nil).isRepeatingItself })
            return Surface(wire, reference: found.first ?? fallback)
        } catch let unfinished as Unfinished<WireSurface.PartiallyGenerated> {
            let kept = await salvaged(Surface(partial: unfinished.partial, reference: found.first ?? fallback), reason: unfinished.reason, blocksFinished: unfinished.partial.related != nil)
            // Finished blocks are worth keeping, and so is a calculation with none, if it has
            // results: the checker gives it its controls and results (Checker.checkBlocks). Inputs
            // alone were kept once, and every repair stopped early too: a page of one slider.
            guard !kept.blocks.isEmpty || (!kept.inputs.isEmpty && !kept.outputs.isEmpty && !kept.title.isEmpty) else { throw unfinished }
            note(kept.blocks.isEmpty ? "Kept the calculation; no block was finished." : "Kept the \(kept.blocks.count) finished blocks.")
            return kept
        }
    }

    /// What's usable from a surface that stopped early: every finished block. A block that was
    /// looping or cut off is dropped; after a stall, everything there is as finished as it gets.
    /// Related topics come from Wikipedia if they're missing.
    private func salvaged(_ partial: Surface, reason: StopReason, blocksFinished: Bool) async -> Surface {
        var surface = partial
        if reason == .stalled {
            // Keep it all.
        } else if reason == .repeating || !blocksFinished, !surface.blocks.isEmpty {
            surface.blocks.removeLast()
        } else if !surface.related.isEmpty {
            // It stopped while listing topics, so the last one may be cut off mid-word.
            surface.related.removeLast()
        }
        if surface.related.count < 3, let reference = surface.reference {
            surface.related += await Lookup.related(to: reference.title, language: reference.language)
        }
        return surface
    }

    // MARK: - Generation

    // A screen has no budget of its own below the server's cap. Providers count thinking against
    // it, and Grok thinking at low can spend 20,000 tokens on a quadratic: a budget of 20,000 cut
    // its answer off after 400 characters. Runaways are caught as they start instead: loops by
    // `isRepeatingItself`, padding by ChatCompletions.Padding.

    /// Whether writing the screen again might work where this failed: the model looped, padded or
    /// broke its answer with nothing worth keeping, or left it empty. Not when it was stopped, the
    /// safety filter stepped in, or the server refused (sign-in, allowance, a busy model it
    /// already retried).
    private static func isWorthAnotherTry(_ error: Error) -> Bool {
        error is Unfinished<WireSurface.PartiallyGenerated> || error is EmptyScreen || error is GeneratedContent.ParsingError
    }

    private func generate<Content: Generable>(
        _ type: Content.Type,
        in session: LanguageModelSession,
        step: String,
        options: GenerationOptions = GenerationOptions(),
        prompt: Prompt,
        onPartial: ((Content.PartiallyGenerated) -> Void)? = nil,
        isRunaway: ((Content.PartiallyGenerated) -> Bool)? = nil
    ) async throws -> Content {
        let started = Date()
        isThinking = true
        let watch = StreamWatch<Content.PartiallyGenerated>()
        let stream = session.streamResponse(to: prompt, generating: type, options: options)
        // The stream is read in its own task so the watchdog below can stop it.
        let reading = Task { @MainActor in
            for try await snapshot in stream {
                if snapshot.rawContent != watch.last {
                    watch.lastChange = .now
                    if self.isThinking { self.isThinking = false }
                    if self.phase == .researching { self.phase = .composing }
                }
                watch.last = snapshot.rawContent
                watch.partial = snapshot.content
                onPartial?(snapshot.content)
                if let isRunaway, isRunaway(snapshot.content) {
                    watch.stop = .repeating
                    return
                }
            }
        }
        // A model can stall: nothing new arrives, or tokens keep coming but nothing changes.
        // Models report activity while they think, so only real silence counts. The server's
        // heartbeat says the line is open, not that the model is working: it buys a long think,
        // up to `ceiling`, never a hang. A repair once waited on one for over three minutes.
        let patience: TimeInterval = 45
        let ceiling: TimeInterval = 150
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if !self.isThinking, Date.now.timeIntervalSince(watch.lastChange) > 1.5 { self.isThinking = true }
                let latest = max(watch.lastChange, ModelActivity.lastSeen)
                let heard = max(watch.lastChange, ModelActivity.lastHeard)
                if Date.now.timeIntervalSince(latest) > patience || Date.now.timeIntervalSince(heard) > ceiling {
                    watch.stop = .stalled
                    reading.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: {
                reading.cancel()
            }
        } catch where watch.stop == nil {
            note("\(step) stopped after \(elapsed(since: started)) (\(describe(error))).")
            // Never keep part of something the safety filter stopped.
            if let modelError = error as? LanguageModelError, case .guardrailViolation = modelError { throw error }
            if let partial = watch.partial, !(error is CancellationError) { throw Unfinished(partial: partial, reason: .cutOff) }
            throw error
        }
        // Stopped from outside, like writing that gives way to the gap check's questions. The
        // stream then just ends, which would otherwise read as an answer cut short.
        try Task.checkCancellation()

        switch watch.stop {
        case .repeating:
            note("\(step) started repeating itself after \(elapsed(since: started)); stopped it there.")
            if let partial = watch.partial { throw Unfinished(partial: partial, reason: .repeating) }
        case .stalled:
            // It may have stalled right at the end, in which case the answer is whole.
            if let last = watch.last, let whole = try? Content(last) {
                note("\(step): \(elapsed(since: started)) on \(active.name)")
                return whole
            }
            note("\(step) stopped making progress after \(elapsed(since: started)); stopped it there.")
            if let partial = watch.partial { throw Unfinished(partial: partial, reason: .stalled) }
            throw ComposeError("The model stopped making progress.")
        case nil:
            break
        }

        guard let last = watch.last else { throw ComposeError("The model returned nothing.") }
        modelName = active.name
        note("\(step): \(elapsed(since: started)) on \(modelName)")
        do {
            return try Content(last)
        } catch {
            // The answer filled its room before it was done, or turned to padding and was cut
            // off (ChatCompletions.swift).
            note("\(step) ended before it was finished.")
            if let partial = watch.partial { throw Unfinished(partial: partial, reason: .cutOff) }
            throw error
        }
    }

    // MARK: - Reporting

    /// Notes the language and units a finished surface is written in (Language.swift), and
    /// remembers its language as one the reader reads.
    private func recordLocale(likely: String?, editing earlier: SurfaceLocale? = nil) {
        guard let surface else { return }
        let locale = SurfaceLocale(written: surface, likely: likely, fallback: language, editing: earlier)
        self.surface?.locale = locale
        Languages.remember(locale.language)
        note("Written in \(Languages.name(locale.language)), for \(locale.measurementSystem) units")
    }

    private func fail(_ error: Error) {
        let message = describe(error)
        note("Failed: \(message)")
        phase = .failed(message)
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation: return "The model's safety filters blocked this request."
            case .contextSizeExceeded: return "This got too big for the model."
            case .rateLimited: return "Too many requests at once. Try again in a moment."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func report(_ issues: [Issue]) {
        for issue in issues {
            switch issue.kind {
            case .fixed: note("Fixed: \(issue.message)")
            case .needsModel: note("Problem: \(issue.message)")
            case .warning: note("Warning: \(issue.message)")
            }
        }
    }

    private func note(_ line: String) {
        log.append(line)
        Build.trace("[Dream] \(line)")
    }

    private func elapsed(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }
}

/// When a remote model last sent anything, reasoning included, so a long think isn't taken for a
/// stall; and when it last did anything but keep the line open.
enum ModelActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var heard = Date.distantPast
    nonisolated(unsafe) private static var beat = Date.distantPast

    /// The model, a tool or the user did something.
    static func touch() {
        lock.withLock { heard = .now }
    }

    /// Dream's server says the line is still open while the model is quiet (Server/src/stream.ts).
    static func heartbeat() {
        lock.withLock { beat = .now }
    }

    /// When anything last arrived, heartbeats included.
    static var lastSeen: Date {
        lock.withLock { max(heard, beat) }
    }

    /// When the model, a tool or the user last did something. Heartbeats don't count.
    static var lastHeard: Date {
        lock.withLock { heard }
    }
}

/// What a generation has produced so far, and whether it was stopped.
@MainActor
private final class StreamWatch<Partial> {
    enum Stop { case repeating, stalled }
    var last: GeneratedContent?
    var partial: Partial?
    var lastChange = Date.now
    var stop: Stop?
}

/// Why a generation stopped early, which decides what's worth keeping.
enum StopReason {
    /// Nothing changed for a while, so what's there is as finished as it will get.
    case stalled
    /// The last block was looping.
    case repeating
    /// Out of room, or an error, partway through something.
    case cutOff
}

/// The model stopped before finishing, with what it had written by then.
struct Unfinished<Partial>: LocalizedError {
    let partial: Partial
    let reason: StopReason

    var errorDescription: String? { "The model stopped before finishing." }
}

struct ComposeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The model answered with a screen that has nothing in it, not even a title.
struct EmptyScreen: LocalizedError {
    var errorDescription: String? { "The model wrote an empty screen." }
}

extension LanguageModelSession {
    /// Whether the session ends with the model's answer, which a follow-up like a repair can
    /// point back to. A generation that failed or was stopped early is taken back out of the
    /// transcript, request and all.
    var endsWithAnswer: Bool {
        if case .response = transcript.last { return true }
        return false
    }
}
