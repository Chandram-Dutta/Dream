import Foundation
import FoundationModels

/// What someone means by what they say to a page they're on: a change to it ("make it
/// monthly"), something that goes on from it ("what about Mumbai?", "how do Swahili verbs
/// work?"), or something else entirely. A change rewrites the page, keeping the version before
/// it; going on makes a new page linked to this one, which starts from its request, answers,
/// numbers and what was found for it. Before, everything said to a page rewrote it, so "now do
/// Mumbai" replaced the Bengaluru page instead of adding one beside it.
enum FollowUp {
    enum Kind: String, Equatable {
        case change, further, new
    }

    struct Decision: Equatable {
        var kind: Kind
        /// For a new page: the request on its own, with what it refers to on this page spelled
        /// out ("Split a ₹2,400 dinner bill four ways in Mumbai").
        var request: String
    }

    @Generable
    enum WireKind {
        case change
        case further
        case new
    }

    @Generable
    struct WireDecision {
        // First, so the model says what it takes them to mean before it sorts it.
        @Guide(description: "What they want, in one short line")
        var reading: String
        @Guide(description: "change: this screen made different: other numbers, units, wording, layout, more or less detail, a fix, or something added to it. further: a new question that goes on from it: the same thing for another case (another city, person, year, product), the next thing to know, or a closer look at one part. new: nothing to do with this screen.")
        var kind: WireKind
        @Guide(description: "For further or new: the request as they would type it on its own, with what it refers to on the screen spelled out, names and numbers included. Empty for a change.")
        var request: String
    }

    /// Longer than this, and what was said is taken as a change, as it always was.
    static let patience: Duration = .seconds(15)

    /// Decides what `said` means on a page made for `intent`. Anything that goes wrong reads as
    /// a change, which is what saying something to a page did before.
    @MainActor
    static func decide(_ said: String, on surface: Surface, asked intent: String) async -> Decision {
        let change = Decision(kind: .change, request: "")
        guard Composer.canCompose else { return change }
        let session: LanguageModelSession
        switch Composer.provider {
        case .privateCloud: session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Prompts.followUp)
        case .onDevice: session = LanguageModelSession(model: SystemLanguageModel.default, instructions: Prompts.followUp)
        }
        let prompt = Prompts.followUpRequest(said, title: surface.title, summary: surface.summary, asked: intent)
        let reasoning: ContextOptions.ReasoningLevel? = Composer.provider == .privateCloud ? .light : nil
        do {
            let wire = try await withDeadline(patience) {
                try await session.respond(to: prompt, generating: WireDecision.self, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 200),
                                          contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: reasoning)).content
            }
            return decision(wire, said: said)
        } catch {
            Build.trace("[Dream] Follow-up: couldn't tell (\(error.localizedDescription)); changing the page")
            return change
        }
    }

    /// The model's answer, tidied: a new page needs a request, and the user's own words do when
    /// the model gave none.
    static func decision(_ wire: WireDecision, said: String) -> Decision {
        let request = wire.request.trimmingCharacters(in: .whitespacesAndNewlines)
        switch wire.kind {
        case .change: return Decision(kind: .change, request: "")
        case .further: return Decision(kind: .further, request: request.isEmpty ? said : request)
        case .new: return Decision(kind: .new, request: request.isEmpty ? said : request)
        }
    }
}

extension Prompts {
    static let followUp = """
        Someone is looking at a screen Dream made for them, and has just typed something to it. Decide what they mean: a change to this screen, a new question that goes on from it, or something unrelated.
        A change keeps the same subject and question and makes the screen different. Going on asks something the screen doesn't answer yet: the same thing for another case, or the next thing to know.
        """

    static func followUpRequest(_ said: String, title: String, summary: String, asked intent: String) -> String {
        """
        The screen: "\(title)": \(summary)
        It was made for: \(intent)
        They typed: \(said)
        """
    }

    /// What a page going on from another starts from: that page's request, what it showed, the
    /// numbers the user had on it, their answers and what was found for it. The new page keeps
    /// all of that unless its request changes it, so "what about Mumbai?" from a bill split is
    /// the same bill, split the same way, in Mumbai.
    static func goingOn(from surface: Surface, asked intent: String, found: String, values: [String: Double]) -> [String] {
        var lines = ["This request goes on from a screen the user was just on, \"\(surface.title)\" (made for: \(intent)). \(surface.summary)"]
        let numbers = surface.inputs.filter { $0.role == .adjustable || $0.role == .given }.map { input in
            "\(input.label): \((values[input.name] ?? input.initial).plain)\(input.unit.isEmpty ? "" : " \(input.unit)")"
        }
        if !numbers.isEmpty { lines.append("Its numbers, as the user left them: \(numbers.joined(separator: ", ")).") }
        let answers = (surface.answers ?? []).filter { !$0.isLeftToDream }.map { "\($0.question.text) \($0.choice)" }
        if !answers.isEmpty { lines.append("The user's answers for it: \(answers.joined(separator: "; ")).") }
        if !found.isEmpty { lines.append("What was found for it:\n\(found)") }
        lines.append("Keep what this request doesn't change, like the place, people, numbers and choices, and build what it asks for next. Don't rebuild the earlier screen.")
        return [lines.joined(separator: "\n")]
    }
}
