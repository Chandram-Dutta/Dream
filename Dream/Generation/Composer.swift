import CoreGraphics
import Foundation
import FoundationModels
import Observation

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

    /// Which model writes surfaces. If the chosen one can't be used or fails, the other is tried.
    enum Provider: String, CaseIterable {
        /// Grok, with an xAI API key from the Keychain.
        case xai
        /// Needs an entitlement Apple grants on request (com.apple.developer.private-cloud-compute).
        case privateCloud

        var name: String {
            switch self {
            case .xai: "Grok (\(Composer.xaiModelID))"
            case .privateCloud: "Private Cloud Compute"
            }
        }

        var isUsable: Bool {
            switch self {
            case .xai: XAILanguageModel.savedKey != nil
            case .privateCloud: PrivateCloudComputeLanguageModel().isAvailable
            }
        }
    }

    nonisolated static var provider: Provider { Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .xai }
    nonisolated static var xaiModelID: String { UserDefaults.standard.string(forKey: "xaiModel").flatMap { $0.isEmpty ? nil : $0 } ?? "grok-4.7" }

    /// Whether any model can make screens right now.
    static var canCompose: Bool { Provider.allCases.contains { $0.isUsable } }

    /// The model this request runs on.
    private var active: Provider = .xai
    /// The request's language, whose Wikipedia lookups read first.
    private var language = "en"

    func compose(intent: String, image: CGImage? = nil) async {
        let started = Date()
        log = []
        surface = nil
        isThinking = true
        defer { isThinking = false }
        note("Request: \(intent)\(image == nil ? "" : " (with photo)")")
        asking.start()
        language = Languages.of(request: intent)?.rawValue ?? Languages.primary
        do {
            let context = await Prompts.context(for: intent)
            let prompt = Prompt {
                Prompts.surfaceRequest(intent, hasImage: image != nil, context: context)
                if let image { Attachment(image) }
            }
            try await withModel {
                try await self.write(prompt: prompt, fallback: nil, streaming: true)
            }
            guard let surface, !surface.isEmpty else { throw ComposeError("Nothing came out of this. Try asking another way.") }
            recordLocale(likely: Languages.guess(intent)?.rawValue)
            phase = .done
            note("Done in \(elapsed(since: started))")
        } catch {
            fail(error)
        }
    }

    /// Changes a surface. `focus` is the block the user pointed at, if any.
    func edit(_ current: Surface, intent: String, instruction: String, focus: Block?) async {
        let started = Date()
        log = []
        surface = current
        isThinking = true
        defer { isThinking = false }
        note("Change: \(instruction)\(focus.map { " (pointing at #\($0.id))" } ?? "")")
        asking.start(keeping: current.answers)
        language = current.locale?.language ?? Languages.of(request: intent)?.rawValue ?? Languages.primary
        do {
            let context = await Prompts.context(for: intent)
            let prompt = Prompt(Prompts.edit(intent: intent, surface: current, instruction: instruction, focus: focus, context: context))
            try await withModel {
                try await self.write(prompt: prompt, fallback: current.reference, streaming: false)
            }
            recordLocale(likely: current.locale?.language, editing: current.locale)
            phase = .done
            note("Done in \(elapsed(since: started))")
        } catch {
            surface = current
            fail(error)
        }
    }

    // MARK: - Model

    /// Runs on the chosen model, or on the other one if the chosen can't be used or fails.
    private func withModel(_ run: () async throws -> Void) async throws {
        let usable = ([Self.provider] + Provider.allCases.filter { $0 != Self.provider }).filter(\.isUsable)
        guard let first = usable.first else {
            throw ComposeError("Dream needs a model to make screens. Add an xAI API key in Under the hood.")
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
        case .xai: LanguageModelSession(model: XAILanguageModel(apiKey: XAILanguageModel.savedKey ?? "", modelID: Self.xaiModelID), tools: tools, instructions: instructions)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
    }

    /// The tools a surface is written with. Features that give the model a tool add it here.
    private func tools(found: ReferenceLog) -> [any Tool] {
        [LookupTool(found: found, language: language, onLookup: { [weak self] subject in Task { @MainActor in self?.lookingUp(subject) } }),
         AskTool(asking: asking, onAsk: { [weak self] line in Task { @MainActor in self?.note(line) } }),
         RecallTool(onRecall: { [weak self] line in Task { @MainActor in self?.note(line) } })]
    }

    private func lookingUp(_ subject: String) {
        phase = .researching
        isThinking = true
        note("Lookup: \(subject)")
    }

    // MARK: - Writing

    /// Writes a whole surface, then has the checker fix what it can and sends real mistakes
    /// back in the same session, so the model sees what it wrote.
    private func write(prompt: Prompt, fallback: Reference?, streaming: Bool) async throws {
        phase = .composing
        let found = ReferenceLog()
        let session = session(Prompts.surface, tools: tools(found: found))
        var surface = try await generateSurface(in: session, prompt: prompt, found: found, fallback: fallback, streaming: streaming)
        for round in 0...2 {
            let issues = Checker.checkLogic(&surface)
            report(issues)
            let problems = issues.filter { $0.kind == .needsModel }
            if problems.isEmpty || round == 2 { break }
            phase = .fixing(problems.count)
            let wire = try await generate(WireSurface.self, in: session, step: "Repair \(round + 1)", prompt: Prompt(Prompts.repair(problems)))
            surface = Surface(wire, reference: found.first ?? fallback)
        }
        await surface.findRecordings()
        report(Checker.checkBlocks(&surface))
        surface = surface.answered(asking.answers)
        self.surface = surface
        note(surface.outline)
    }

    /// A whole surface from one request, keeping the finished blocks if the model stops early.
    private func generateSurface(in session: LanguageModelSession, prompt: Prompt, found: ReferenceLog, fallback: Reference?, streaming: Bool) async throws -> Surface {
        let onPartial: ((WireSurface.PartiallyGenerated) -> Void)? = streaming ? { self.surface = Surface(partial: $0, reference: found.first ?? fallback).answered(self.asking.answers) } : nil
        do {
            let wire = try await generate(WireSurface.self, in: session, step: "Surface", options: GenerationOptions(temperature: 0.4), prompt: prompt,
                                          onPartial: onPartial, isRunaway: { Surface(partial: $0, reference: nil).isRepeatingItself })
            return Surface(wire, reference: found.first ?? fallback)
        } catch let unfinished as Unfinished<WireSurface.PartiallyGenerated> {
            let kept = await salvaged(Surface(partial: unfinished.partial, reference: found.first ?? fallback), reason: unfinished.reason, blocksFinished: unfinished.partial.related != nil)
            guard !kept.blocks.isEmpty else { throw unfinished }
            note("Kept the \(kept.blocks.count) finished blocks.")
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
        // Models report activity while they think, so only real silence counts.
        let patience: TimeInterval = 45
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                // Waiting for the user to answer isn't a stall.
                if self.asking.isWaiting { continue }
                if !self.isThinking, Date.now.timeIntervalSince(watch.lastChange) > 1.5 { self.isThinking = true }
                let latest = max(watch.lastChange, ModelActivity.lastSeen)
                if Date.now.timeIntervalSince(latest) > patience {
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
            // The answer filled its room in the context before it was done.
            note("\(step) ran out of room before finishing.")
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
        print("[Dream] \(line)")
    }

    private func elapsed(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }
}

/// When a remote model last sent anything, reasoning included, so a long think isn't taken for a stall.
enum ModelActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = Date.distantPast

    static func touch() {
        lock.withLock { last = .now }
    }

    static var lastSeen: Date {
        lock.withLock { last }
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
