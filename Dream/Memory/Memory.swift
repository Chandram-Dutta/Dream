import Foundation
import FoundationModels
import NaturalLanguage
import SwiftData

/// What Dream remembers about the user, on this iPhone: what they said, what they answered, and
/// what Dream noticed in their requests, which waits for them to confirm it.
@MainActor
enum Memory {
    private static var container: ModelContainer?

    /// Connects building screens to the store, and lets the model's questions reach the screen.
    static func start(_ container: ModelContainer) {
        self.container = container
        Recall.source = Recall.Source(
            topics: { await Memory.topics() },
            facts: { await Memory.facts(about: $0) })
        Asking.answerer = .user
        // Device tours have nobody to tap an answer.
        if UserDefaults.standard.bool(forKey: "DreamTour") { Asking.patience = .seconds(8) }
    }

    // MARK: - Recalling

    /// Confirmed topics, most recent first.
    static func topics() -> [String] {
        var seen: Set<String> = []
        return confirmed().map(\.topic).filter { seen.insert(Recall.key($0)).inserted }
    }

    /// The confirmed facts on some topics, noting that they were used.
    static func facts(about topics: [String]) -> [Remembered] {
        let wanted = Set(topics.map(Recall.key))
        let facts = confirmed().filter { wanted.contains(Recall.key($0.topic)) }
        for fact in facts { fact.lastUsedAt = .now }
        try? container?.mainContext.save()
        return facts.map { Remembered(topic: $0.topic, detail: $0.text) }
    }

    private static func confirmed() -> [MemoryFact] {
        let descriptor = FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.isConfirmed == true }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? container?.mainContext.fetch(descriptor)) ?? []
    }

    // MARK: - Learning

    /// After a request: answers about the user become facts, and anything they said about
    /// themselves in it is noticed, to be confirmed before it's used.
    static func learn(from request: String, answers: [Answer], in context: ModelContext) {
        remember(answers, from: request, in: context)
        Task { await notice(in: request, context: context) }
    }

    /// Answers about the user, kept under their question's topic.
    static func remember(_ answers: [Answer], from request: String, in context: ModelContext) {
        for answer in answers where answer.question.isPersonal && !answer.isLeftToDream {
            remember(topic: answer.question.topic, text: answer.choice, source: .answered, request: request, in: context)
        }
    }

    /// Saves something the user told Dream directly. A new answer replaces the old one on the same topic.
    static func remember(topic: String, text: String, source: MemoryFact.Source, request: String = "", in context: ModelContext) {
        let key = Recall.key(topic)
        let all = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
        if source == .answered {
            for old in all where Recall.key(old.topic) == key { context.delete(old) }
        }
        context.insert(MemoryFact(topic: topic, text: text, source: source, isConfirmed: true, request: request))
        try? context.save()
    }

    static func confirm(_ fact: MemoryFact, in context: ModelContext) {
        fact.isConfirmed = true
        fact.updatedAt = .now
        try? context.save()
    }

    @Generable
    struct Noticed {
        @Guide(description: "Each lasting fact the person states about themselves. Usually none.", .maximumCount(3))
        var facts: [NoticedFact]
    }

    @Generable
    struct NoticedFact {
        @Guide(description: "What it's about, in 1 to 3 words")
        var topic: String
        @Guide(description: "The fact itself, short, in their words")
        var text: String
    }

    /// Lasting facts the user states about themselves in a request ("I'm vegetarian"), found by
    /// the on-device model, so nothing leaves the phone. They're saved unconfirmed.
    private static func notice(in request: String, context: ModelContext) async {
        guard mentionsThemselves(request), SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(instructions: """
            You find lasting facts a person states about themselves in a request: where they live, what they eat, who they live with, their work, their health, what they own. Only what the request itself says; never guess. Plans, wishes and one-off details aren't facts about them: a trip they want to take, when a flight leaves, what they're cooking tonight. Most requests state nothing about the person.
            """)
        guard let response = try? await session.respond(to: "Request: \(request)", generating: Noticed.self, options: GenerationOptions(samplingMode: .greedy)) else { return }
        let known = Set(((try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []).map { Recall.key($0.statement) })
        let said = words(in: request)
        for found in response.content.facts {
            let topic = found.topic.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let text = found.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !topic.isEmpty, !text.isEmpty else { continue }
            // Small models invent; keep only what the request actually says.
            guard !words(in: text).isDisjoint(with: said) else { continue }
            let fact = MemoryFact(topic: topic.prefix(1).uppercased() + topic.dropFirst(), text: text, source: .inferred, isConfirmed: false, request: request)
            guard !known.contains(Recall.key(fact.statement)) else { continue }
            context.insert(fact)
        }
        try? context.save()
    }

    private static let selfWords: Set<String> = ["i", "i'm", "im", "i've", "me", "my", "mine", "myself", "we", "we're", "our", "ours", "us"]

    /// Whether a request could say anything about the person asking. Other languages always could.
    private static func mentionsThemselves(_ request: String) -> Bool {
        if let language = NLLanguageRecognizer.dominantLanguage(for: request), language != .english { return true }
        let tokens = request.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        return tokens.contains(where: selfWords.contains)
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !selfWords.contains($0) && !plainWords.contains($0) })
    }

    /// Too common to show a fact came from the request.
    private static let plainWords: Set<String> = ["am", "an", "and", "are", "as", "at", "be", "by", "for", "in", "is", "it", "of", "on", "or", "so", "the", "to", "with"]
}
