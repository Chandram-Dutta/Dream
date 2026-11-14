import Foundation
import FoundationModels

/// A quick check of a request for what it leaves out that only the user can tell, run in its own
/// short session beside the main generation. Asking used to be a tool inside the main generation,
/// but with every feature's rules in one long prompt the model often skipped it ("Mercury" asked
/// 0 times in 2 runs), so the decision now has its own small structured answer.
enum GapCheck {
    /// What the check found. `remembered` holds the questions Dream could answer itself.
    struct Gaps {
        var questions: [Question] = []
        var remembered: [Answer] = []
        var seconds: TimeInterval = 0
    }

    @Generable
    struct WireGaps {
        // First, so the model decides whether anything is missing before it writes a question.
        // Asked for questions alone, Apple's model always wrote one, often the request itself.
        @Guide(description: "What the request leaves out that only the user can tell and that changes which screen to build, in a few words. Empty when nothing is, as for almost every request.")
        var missing: String
        @Guide(description: "Only when something is missing: 1 to 3 questions about it. Otherwise none.", .maximumCount(3))
        var questions: [WireQuestion]
    }

    @Generable
    struct WireQuestion {
        @Guide(description: "Short and plain, like 'Which Java?'")
        var question: String
        @Guide(description: "What it's about, in 1 to 3 words, like Subject, Destination or Diet")
        var topic: String
        @Guide(description: "2 to 4 short answers to tap, without 'You choose', which is always added. When typing, up to 4 likely ones.", .maximumCount(4))
        var options: [String]
        @Guide(description: "True when the answer is a lasting fact about the user, like where they live, their diet or their household")
        var personal: Bool
        @Guide(description: "True only when no short list could cover the answer, like a place, so the user can type it")
        var typing: Bool
        @Guide(description: "If one of the topics Dream remembers answers this, that topic exactly as listed; otherwise empty")
        var remembered: String
    }

    /// Longer than this and the check is dropped. A main generation takes 15 to 60 seconds, so a
    /// question that comes late still saves building the wrong screen.
    static let patience: Duration = .seconds(25)
    /// How long the page may stream out of sight while the check decides. Most checks take 3 to 6
    /// seconds; past this the page shows, and gives way to questions only if the check finds some.
    static let hold: TimeInterval = 6

    static func run(_ intent: String, in session: LanguageModelSession) async throws -> Gaps {
        let started = Date()
        let topics = await Recall.source.topics()
        let prompt = Prompts.gapRequest(intent, remembering: topics)
        let wire = try await within(patience) {
            try await session.respond(to: prompt, generating: WireGaps.self, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)).content
        }
        var gaps = await resolve(wire, for: intent, remembering: topics)
        gaps.seconds = Date().timeIntervalSince(started)
        return gaps
    }

    /// The questions, with those Dream can answer itself answered: the model names the topic that
    /// answers one, and a question about a remembered topic is answered even if it didn't.
    static func resolve(_ wire: WireGaps, for intent: String, remembering topics: [String]) async -> Gaps {
        var gaps = Gaps()
        // Nothing missing, nothing to ask, whatever questions came with it.
        guard !wire.missing.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty else { return gaps }
        for item in wire.questions.prefix(3) {
            guard let question = Question(item), !question.restates(intent) else { continue }
            gaps.questions.append(question)
            let named = item.remembered.trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = named.isEmpty ? topics.first { Recall.key($0) == Recall.key(question.topic) } : named
            guard let topic else { continue }
            let facts = await Recall.source.facts([topic])
            if !facts.isEmpty {
                gaps.remembered.append(Answer(question: question, choice: facts.map(\.detail).joined(separator: ", "), isRemembered: true))
            }
        }
        return gaps
    }

    /// The work's result, or an error if it takes longer than `limit`.
    private static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw ComposeError("The check took too long.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

extension Question {
    /// What the model wrote, tidied: options it shouldn't have offered are dropped, and a question
    /// left with too few options to tap takes a typed answer instead.
    init?(_ wire: GapCheck.WireQuestion) {
        let text = wire.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var seen: Set<String> = []
        let options = wire.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isYouChoose($0) && seen.insert($0.lowercased()).inserted }
        let topic = wire.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            text: text,
            topic: topic.isEmpty ? text : topic,
            options: Array(options.prefix(4)),
            allowsTyping: wire.typing || options.count < 2,
            isPersonal: wire.personal)
    }

    /// Whether the question only says the request again ("Calculate 15% of 20000?"), which
    /// asks the user nothing: nearly all its words are the request's.
    func restates(_ request: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        }
        let asked = words(text)
        guard !asked.isEmpty else { return true }
        return Double(asked.intersection(words(request)).count) / Double(asked.count) >= 0.75
    }

    private static func isYouChoose(_ option: String) -> Bool {
        let plain = option.lowercased().filter(\.isLetter)
        return ["youchoose", "youdecide", "surpriseme", "dontmind", "anything", "either"].contains(plain)
    }
}
