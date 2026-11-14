import Foundation
import FoundationModels

/// Understanding a request before its page is written: what it refers to, found out where it can
/// be (the user's connected services, what Dream remembers, Wikipedia, the web), and then only
/// what's still open that only the user can tell, asked with answers taken from what was found.
/// "Check my project's GTM notes" looks in Notion first and asks which project, by name, rather
/// than guessing at what GTM means. What it found goes to the writer, which builds from it.
///
/// It runs in its own short session, with look-up tools only, before the page is written.
/// Asking used to be a tool inside the main generation, but with every feature's rules in one
/// long prompt the model often skipped it, so the decision has its own small structured answer.
enum GapCheck {
    /// What the check found. `remembered` holds the questions Dream could answer itself.
    struct Gaps {
        var questions: [Question] = []
        var remembered: [Answer] = []
        var seconds: TimeInterval = 0
        /// What was found out while understanding the request, for the writer to build from.
        var found = ""
        /// The particular things the request is about.
        var subjects: [String] = []
    }

    @Generable
    struct WireGaps {
        // First, so the model says how it reads the request, words and all, before it looks for
        // what's missing: "Vulcan destruction in 2258" is already Star Trek's planet, and saying so
        // keeps the check from asking which Vulcan.
        @Guide(description: "What the request is about, as you read it from all its words and what the user just made, in one short line")
        var reading: String
        // After looking, so the questions come from what's there, and the writer gets it too.
        @Guide(description: "What you found out with the tools that the screen should be built from: names, titles, ids, dates and figures exactly as the tools gave them, in a few short lines. Empty if you used no tools.")
        var found: String
        // What Dream remembers each page by (PageGraph.swift), so a later request about the
        // same things, or one going on from this, starts from what was found here.
        @Guide(description: "The particular things the request is about, as their names: people, places, projects, products, works, documents. At most 4. Empty for a general idea or a calculation, like square roots or a bill split.", .maximumCount(4))
        var subjects: [String]
        // Then, so the model decides whether anything is missing before it writes a question.
        // Asked for questions alone, Apple's model always wrote one, often the request itself.
        @Guide(description: "What your reading leaves open that only the user can tell and that changes which screen to build, in a few words. Empty when the request's words settle it, or the screen can offer it as a control or a choice, as for almost every request.")
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
        @Guide(description: "2 to 4 short answers to tap, taken from what you found when you found the real ones (the user's actual projects, pages or places), without 'You choose', which is always added. When typing, up to 4 likely ones.", .maximumCount(4))
        var options: [String]
        @Guide(description: "True when the answer is a lasting fact about the user, like where they live, their diet or their household")
        var personal: Bool
        @Guide(description: "True only when no short list could cover the answer, like a place, so the user can type it")
        var typing: Bool
        @Guide(description: "If one of the topics Dream remembers answers this, that topic exactly as listed; otherwise empty")
        var remembered: String
    }

    /// Longer than this and understanding is dropped, and the page is written without asking.
    /// Most requests are understood in 2 to 4 seconds without a tool; looking in a service can
    /// take longer, and so can the user deciding whether to let it.
    static let patience: Duration = .seconds(90)

    /// The titles of the pages the user made lately, newest first, which the app fills in
    /// (PageMaker.swift): what someone just read often settles what a short request means.
    @MainActor static var recentPages: () -> [String] = { [] }

    /// Earlier pages about the same things as a request, with what was found for them, which the
    /// app fills in (PageGraph.swift): "the GTM plan" finds the page made from those Notion notes.
    @MainActor static var relatedPages: (String) -> [String] = { _ in [] }

    static func run(_ intent: String, in session: LanguageModelSession, reasoning: ContextOptions.ReasoningLevel? = nil, recent: [String] = [], related: [String] = [], place: String? = nil) async throws -> Gaps {
        let started = Date()
        let topics = await Recall.source.topics()
        let prompt = Prompts.gapRequest(intent, remembering: topics, recent: recent, related: related, place: place)
        let wire = try await within(patience) {
            try await session.respond(to: prompt, generating: WireGaps.self, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600),
                                      contextOptions: ContextOptions(includeSchemaInPrompt: true, reasoningLevel: reasoning)).content
        }
        var gaps = await resolve(wire, for: intent, remembering: topics)
        gaps.found = wire.found.trimmingCharacters(in: .whitespacesAndNewlines)
        gaps.subjects = wire.subjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        gaps.seconds = Date().timeIntervalSince(started)
        return gaps
    }

    /// The questions, with those Dream can answer itself answered: the model names the topic that
    /// answers one, and a question about a remembered topic is answered even if it didn't.
    static func resolve(_ wire: WireGaps, for intent: String, remembering topics: [String]) async -> Gaps {
        var gaps = Gaps(found: wire.found.trimmingCharacters(in: .whitespacesAndNewlines))
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
