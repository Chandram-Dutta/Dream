import CoreGraphics
import Foundation
import FoundationModels
import Observation

/// Turns what the user wants into a surface: one screen that explains, calculates, or both.
///
/// How depends on the model. A capable model (reasoning and a large context) writes the whole
/// surface in one pass and looks things up itself through `LookupTool`. The on-device model gets
/// there in steps, each well inside its 4K context: plan what's needed, look it up, write the
/// calculation, then compose the screen. Both produce the same `Surface`, checked the same way,
/// so a better model makes better screens without changes anywhere else.
@MainActor @Observable
final class Composer {
    enum Phase: Equatable {
        case idle, planning, researching, calculating, fixing(Int), composing, done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    enum Strategy: String, CaseIterable {
        /// One pass when the model can reason over a large context, steps otherwise.
        case automatic
        case steps
        case onePass
    }

    private(set) var phase: Phase = .idle
    /// The surface as it stands, including while it's streaming in.
    private(set) var surface: Surface?
    private(set) var log: [String] = []
    private(set) var modelName = ""
    /// Working, but with nothing new on screen for a moment: reasoning, looking something up,
    /// or between steps. The screen shows it in the color field rather than in words.
    private(set) var isThinking = false

    /// Which model writes surfaces. Anything but on-device falls back to it if unusable.
    enum Provider: String, CaseIterable {
        case onDevice
        /// Needs an entitlement Apple grants on request (com.apple.developer.private-cloud-compute).
        case privateCloud
        /// Grok, with an xAI API key from the Keychain.
        case xai

        var name: String {
            switch self {
            case .onDevice: "On-device"
            case .privateCloud: "Private Cloud Compute"
            case .xai: "Grok (\(Composer.xaiModelID))"
            }
        }
    }

    nonisolated static var provider: Provider { Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .onDevice }
    nonisolated static var strategy: Strategy { Strategy(rawValue: UserDefaults.standard.string(forKey: "strategy") ?? "") ?? .automatic }
    nonisolated static var xaiModelID: String { UserDefaults.standard.string(forKey: "xaiModel").flatMap { $0.isEmpty ? nil : $0 } ?? "grok-4.7" }

    /// The model this request runs on: the chosen one, or on-device if that one can't be used.
    private var active: Provider = .onDevice
    private var failed: Set<Provider> = []
    private var usingCloud: Bool { active != .onDevice }

    /// Loads the on-device model ahead of the first request.
    static func prewarm() {
        LanguageModelSession(instructions: Prompts.plan).prewarm()
    }

    func compose(intent: String, image: CGImage? = nil) async {
        let started = Date()
        log = []
        surface = nil
        isThinking = true
        defer { isThinking = false }
        note("Request: \(intent)\(image == nil ? "" : " (with photo)")")
        do {
            try await withModel { onePass in
                if onePass {
                    try await self.composeInOnePass(intent: intent, image: image)
                } else {
                    try await self.composeInSteps(intent: intent, image: image)
                }
            }
            guard let surface, !surface.isEmpty else { throw ComposeError("Nothing came out of this. Try asking another way.") }
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
        do {
            try await withModel { onePass in
                if onePass {
                    try await self.editInOnePass(current, intent: intent, instruction: instruction, focus: focus)
                } else {
                    try await self.editInSteps(current, intent: intent, instruction: instruction, focus: focus)
                }
            }
            phase = .done
            note("Done in \(elapsed(since: started))")
        } catch {
            surface = current
            fail(error)
        }
    }

    // MARK: - Model and strategy

    /// Picks the model and strategy, and starts over on-device if a remote model fails.
    private func withModel(_ run: (Bool) async throws -> Void) async throws {
        active = usableProvider()
        do {
            try await run(await choosesOnePass())
        } catch let error where usingCloud && !(error is CancellationError) {
            note("\(active.name) failed (\(describe(error))); starting over on-device.")
            failed.insert(active)
            active = .onDevice
            try await run(await choosesOnePass())
        }
    }

    private func usableProvider() -> Provider {
        let chosen = Self.provider
        guard !failed.contains(chosen) else { return .onDevice }
        switch chosen {
        case .onDevice:
            return .onDevice
        case .privateCloud:
            return PrivateCloudComputeLanguageModel().isAvailable ? .privateCloud : .onDevice
        case .xai:
            if XAILanguageModel.savedKey == nil {
                note("No xAI API key saved; using the on-device model.")
                return .onDevice
            }
            return .xai
        }
    }

    private var xaiModel: XAILanguageModel {
        XAILanguageModel(apiKey: XAILanguageModel.savedKey ?? "", modelID: Self.xaiModelID)
    }

    private func choosesOnePass() async -> Bool {
        let onePass: Bool
        switch Self.strategy {
        case .steps:
            onePass = false
        case .onePass:
            onePass = true
        case .automatic:
            switch active {
            case .onDevice:
                let model = SystemLanguageModel.default
                onePass = model.capabilities.contains(.reasoning) && model.contextSize >= 16_000
            case .privateCloud:
                let model = PrivateCloudComputeLanguageModel()
                let context = (try? await model.contextSize) ?? 0
                onePass = model.capabilities.contains(.reasoning) && context >= 16_000
            case .xai:
                let model = xaiModel
                onePass = model.capabilities.contains(.reasoning) && model.contextSize >= 16_000
            }
        }
        note("Strategy: \(onePass ? "one pass" : "steps") on \(active.name)")
        return onePass
    }

    private func session(_ instructions: String, tools: [any Tool] = []) -> LanguageModelSession {
        switch active {
        case .onDevice: LanguageModelSession(tools: tools, instructions: instructions)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        case .xai: LanguageModelSession(model: xaiModel, tools: tools, instructions: instructions)
        }
    }

    // MARK: - Steps

    private func composeInSteps(intent: String, image: CGImage?) async throws {
        phase = .planning
        var lookup = ""
        var calculation = ""
        do {
            let prompt = Prompt {
                Prompts.planRequest(intent)
                if let image { Attachment(image) }
            }
            let plan = try await generate(WirePlan.self, instructions: Prompts.plan, step: "Plan", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200), prompt: prompt)
            lookup = plan.lookup.trimmingCharacters(in: .whitespacesAndNewlines)
            calculation = plan.calculate ? plan.calculation.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if plan.calculate && calculation.isEmpty { calculation = intent }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The on-device safety filter sometimes refuses even this; explaining is the safer guess.
            note("Planning failed (\(describe(error))); treating it as a question.")
            lookup = Lookup.subject(of: intent)
        }
        note("Plan: look up \(lookup.isEmpty ? "nothing" : "\"\(lookup)\""), calculate \(calculation.isEmpty ? "nothing" : "\"\(calculation)\"")")

        var surface = Surface.empty
        if !lookup.isEmpty {
            surface.reference = await research(lookup)
        }
        if !calculation.isEmpty {
            let reference = surface.reference
            let prompt = Prompt {
                Prompts.logicRequest(intent, calculation: calculation, reference: reference, hasImage: image != nil)
                if let image { Attachment(image) }
            }
            surface = try await calculate(on: surface, prompt: prompt, intent: intent, streaming: true)
        }
        surface = await composeScreen(on: surface, prompt: Prompt(Prompts.composeRequest(intent, surface: surface)), streaming: true, fallback: [])
        self.surface = surface
        note(surface.outline)
    }

    private func editInSteps(_ current: Surface, intent: String, instruction: String, focus: Block?) async throws {
        phase = .planning
        var lookup = ""
        var calculation = ""
        var removeCalculation = false
        do {
            let prompt = Prompt(Prompts.editPlanRequest(intent: intent, surface: current, instruction: instruction, focus: focus))
            let plan = try await generate(WireEditPlan.self, instructions: Prompts.editPlan, step: "Plan", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200), prompt: prompt)
            lookup = plan.lookup.trimmingCharacters(in: .whitespacesAndNewlines)
            calculation = plan.calculation.trimmingCharacters(in: .whitespacesAndNewlines)
            removeCalculation = plan.removeCalculation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            note("Planning the change failed (\(describe(error))); changing only the screen.")
        }
        note("Plan: look up \(lookup.isEmpty ? "nothing" : "\"\(lookup)\""), calculate \(calculation.isEmpty ? "the same" : "\"\(calculation)\"")\(removeCalculation ? ", remove the calculation" : "")")

        var surface = current
        if removeCalculation {
            surface.inputs = []
            surface.outputs = []
        }
        if !lookup.isEmpty, let reference = await research(lookup) {
            surface.reference = reference
        }
        if !calculation.isEmpty {
            let prompt = Prompt(Prompts.editLogic(intent: intent, surface: surface, instruction: instruction, calculation: calculation))
            surface = try await calculate(on: surface, prompt: prompt, intent: intent, streaming: false)
        }
        let prompt = Prompt(Prompts.editCompose(intent: intent, current: current, updated: surface, instruction: instruction, focus: focus))
        surface = await composeScreen(on: surface, prompt: prompt, streaming: false, fallback: current.blocks)
        self.surface = surface
        note(surface.outline)
    }

    private func research(_ subject: String) async -> Reference? {
        phase = .researching
        isThinking = true
        let started = Date()
        let reference = await Lookup.find(subject)
        note(reference.map { "Lookup: Wikipedia \"\($0.title)\" in \(elapsed(since: started))" }
            ?? "Lookup: nothing found for \"\(subject)\"")
        return reference
    }

    /// Writes the calculation and checks it. If the model won't, the screen goes on without one.
    private func calculate(on base: Surface, prompt: Prompt, intent: String, streaming: Bool) async throws -> Surface {
        phase = .calculating
        do {
            let onPartial: ((WireLogic.PartiallyGenerated) -> Void)? = streaming ? { self.surface = base.with(partial: $0) } : nil
            let logic = try await generate(WireLogic.self, instructions: Prompts.logic, step: "Logic", options: GenerationOptions(temperature: 0.3), prompt: prompt, onPartial: onPartial)
            let surface = try await checked(base.with(logic), intent: intent, streaming: streaming)
            if streaming { self.surface = surface }
            return surface
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            note("The calculation failed (\(describe(error))); going on without it.")
            return base
        }
    }

    /// Fixes what the checker can, and sends the rest back to the model, at most twice.
    private func checked(_ surface: Surface, intent: String, streaming: Bool) async throws -> Surface {
        var surface = surface
        for round in 0...2 {
            let issues = Checker.checkLogic(&surface)
            report(issues)
            let problems = issues.filter { $0.kind == .needsModel }
            if problems.isEmpty || round == 2 { break }
            if streaming { self.surface = surface }
            phase = .fixing(problems.count)
            let prompt = Prompt(Prompts.repair(intent, surface: surface, problems: problems))
            surface = surface.with(try await generate(WireLogic.self, instructions: Prompts.logic, step: "Repair \(round + 1)", options: GenerationOptions(temperature: 0.2), prompt: prompt))
        }
        return surface
    }

    /// Composes the blocks. If the model stops early, the finished blocks are kept; if nothing
    /// was finished, it tries once more with greedy sampling, which tends to be more concise.
    /// Failing that, the calculation gets a plain arrangement, and anything looked up is shown as written.
    private func composeScreen(on base: Surface, prompt: Prompt, streaming: Bool, fallback: [Block]) async -> Surface {
        phase = .composing
        let instructions = Prompts.compose(withCalculation: base.hasLogic)
        var composed: Surface?
        for attempt in 1...2 {
            let options = attempt == 1 ? GenerationOptions(temperature: 0.4) : GenerationOptions(samplingMode: .greedy)
            do {
                if base.hasLogic {
                    composed = try await compose(WireComposition.self, on: base, instructions: instructions, options: options, prompt: prompt, streaming: streaming,
                                                 apply: { $0.with($1) }, applyPartial: { $0.with(partial: $1) }, blocksFinished: { $0.related != nil })
                } else {
                    composed = try await compose(WireArticle.self, on: base, instructions: instructions, options: options, prompt: prompt, streaming: streaming,
                                                 apply: { $0.with($1) }, applyPartial: { $0.with(partial: $1) }, blocksFinished: { $0.related != nil })
                }
                break
            } catch is CancellationError {
                break
            } catch {
                note("Composing failed (\(describe(error)))\(attempt == 1 ? "; trying once more" : "").")
            }
        }
        var surface: Surface
        if let composed {
            surface = composed
        } else {
            surface = base
            surface.blocks = fallback
            if surface.blocks.isEmpty, let reference = surface.reference {
                surface = surface.withSourceText(of: reference, related: await Lookup.related(to: reference.title))
            }
        }
        report(Checker.checkBlocks(&surface))
        return surface
    }

    /// One composition, of either shape, keeping the finished blocks if the model stops early.
    private func compose<Wire: Generable>(
        _ type: Wire.Type,
        on base: Surface,
        instructions: String,
        options: GenerationOptions,
        prompt: Prompt,
        streaming: Bool,
        apply: @escaping (Surface, Wire) -> Surface,
        applyPartial: @escaping (Surface, Wire.PartiallyGenerated) -> Surface,
        blocksFinished: @escaping (Wire.PartiallyGenerated) -> Bool
    ) async throws -> Surface {
        do {
            let onPartial: ((Wire.PartiallyGenerated) -> Void)? = streaming ? { self.surface = applyPartial(base, $0) } : nil
            let wire = try await generate(type, instructions: instructions, step: "Compose", options: options, prompt: prompt,
                                          onPartial: onPartial, isRunaway: { applyPartial(base, $0).isRepeatingItself })
            return apply(base, wire)
        } catch let unfinished as Unfinished<Wire.PartiallyGenerated> {
            let kept = await salvaged(applyPartial(base, unfinished.partial), reason: unfinished.reason, blocksFinished: blocksFinished(unfinished.partial))
            guard !kept.blocks.isEmpty else { throw unfinished }
            note("Kept the \(kept.blocks.count) finished \(kept.blocks.count == 1 ? "block" : "blocks").")
            return kept
        }
    }

    /// What's usable from a composition that stopped early: every finished block. A block that was
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
            surface.related += await Lookup.related(to: reference.title)
        }
        return surface
    }

    // MARK: - One pass

    private func composeInOnePass(intent: String, image: CGImage?) async throws {
        phase = .composing
        let found = ReferenceLog()
        let session = session(Prompts.onePass, tools: [LookupTool(found: found)])
        let prompt = Prompt {
            Prompts.onePassRequest(intent, hasImage: image != nil)
            if let image { Attachment(image) }
        }
        let first = try await generateSurface(in: session, prompt: prompt, found: found, fallback: nil, streaming: true)
        let surface = try await repaired(first, in: session, found: found, fallback: nil)
        self.surface = surface
        note(surface.outline)
    }

    private func editInOnePass(_ current: Surface, intent: String, instruction: String, focus: Block?) async throws {
        phase = .composing
        let found = ReferenceLog()
        let session = session(Prompts.onePass, tools: [LookupTool(found: found)])
        let prompt = Prompt(Prompts.onePassEdit(intent: intent, surface: current, instruction: instruction, focus: focus))
        let first = try await generateSurface(in: session, prompt: prompt, found: found, fallback: current.reference, streaming: false)
        let surface = try await repaired(first, in: session, found: found, fallback: current.reference)
        self.surface = surface
        note(surface.outline)
    }

    /// A whole surface from one request, keeping the finished blocks if the model stops early.
    private func generateSurface(in session: LanguageModelSession, prompt: Prompt, found: ReferenceLog, fallback: Reference?, streaming: Bool) async throws -> Surface {
        let onPartial: ((WireSurface.PartiallyGenerated) -> Void)? = streaming ? { self.surface = Surface(partial: $0, reference: found.first ?? fallback) } : nil
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

    /// Sends problems back in the same session, so the model sees what it wrote.
    private func repaired(_ surface: Surface, in session: LanguageModelSession, found: ReferenceLog, fallback: Reference?) async throws -> Surface {
        var surface = surface
        for round in 0...2 {
            let issues = Checker.checkLogic(&surface)
            report(issues)
            let problems = issues.filter { $0.kind == .needsModel }
            if problems.isEmpty || round == 2 { break }
            phase = .fixing(problems.count)
            let wire = try await generate(WireSurface.self, in: session, step: "Repair \(round + 1)", prompt: Prompt(Prompts.onePassRepair(problems)))
            surface = Surface(wire, reference: found.first ?? fallback)
        }
        report(Checker.checkBlocks(&surface))
        return surface
    }

    // MARK: - Generation

    /// One request in a fresh session, which is how every step runs. On the on-device model the
    /// answer gets whatever room the context has left, measured rather than guessed.
    private func generate<Content: Generable>(
        _ type: Content.Type,
        instructions: String,
        step: String,
        options: GenerationOptions = GenerationOptions(),
        prompt: Prompt,
        onPartial: ((Content.PartiallyGenerated) -> Void)? = nil,
        isRunaway: ((Content.PartiallyGenerated) -> Bool)? = nil
    ) async throws -> Content {
        var options = options
        if options.maximumResponseTokens == nil, !usingCloud {
            options.maximumResponseTokens = await responseBudget(instructions: instructions, prompt: prompt, schema: Content.generationSchema)
            if let budget = options.maximumResponseTokens { note("\(step) has room for \(budget) tokens.") }
        }
        return try await generate(type, in: session(instructions), step: step, options: options, prompt: prompt, onPartial: onPartial, isRunaway: isRunaway)
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
        // Small models can get stuck writing the whitespace a schema allows between values:
        // tokens keep coming but nothing changes. That's a stall, not a long answer. Remote models
        // report activity while they think, so for them only real silence counts.
        let patience: TimeInterval = usingCloud ? 45 : 6
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if !self.isThinking, Date.now.timeIntervalSince(watch.lastChange) > 1.5 { self.isThinking = true }
                let latest = self.usingCloud ? max(watch.lastChange, ModelActivity.lastSeen) : watch.lastChange
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

    /// The room left in the on-device model's context once instructions, prompt and schema are in.
    private func responseBudget(instructions: String, prompt: Prompt, schema: GenerationSchema) async -> Int? {
        let model = SystemLanguageModel.default
        guard let used = try? await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: prompt) + model.tokenCount(for: schema) else {
            return nil
        }
        return max(model.contextSize - used - 128, 256)
    }

    // MARK: - Reporting

    private func fail(_ error: Error) {
        let message = describe(error)
        note("Failed: \(message)")
        phase = .failed(message)
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation: return "Apple's safety filters blocked this request."
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
