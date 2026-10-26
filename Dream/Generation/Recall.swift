import Foundation
import FoundationModels

/// One thing Dream remembers about the user, like Home city: Pune.
struct Remembered: Hashable, Sendable {
    var topic: String
    var detail: String
}

/// What Dream remembers about the user, as building a screen sees it. The app connects its store
/// at launch; on the bench it remembers nothing, unless given some with `-memory`.
///
/// The model is told only the topics, and fetches a detail with `RecallTool` when it would change
/// the screen, so every other detail stays on the phone. Picking on the phone was tried first:
/// the on-device model picked badly (a job for Mercury, a diet for a bill) and took seconds per
/// request, and NaturalLanguage's sentence embeddings can't tell a relevant fact from noise.
enum Recall {
    struct Source: Sendable {
        /// What's remembered, by topic, most recent first. Only facts the user confirmed.
        var topics: @Sendable () async -> [String]
        /// The details for some of those topics.
        var facts: @Sendable ([String]) async -> [Remembered]
    }

    nonisolated(unsafe) static var source = Source.fixed([])
}

extension Recall.Source {
    /// A fixed set of facts, for the bench and previews.
    static func fixed(_ facts: [Remembered]) -> Recall.Source {
        Recall.Source(
            topics: { facts.map(\.topic) },
            facts: { topics in
                let wanted = Set(topics.map(Recall.key))
                return facts.filter { wanted.contains(Recall.key($0.topic)) }
            })
    }
}

extension Recall {
    /// Topics compare without case or extra spaces, since the model copies them back.
    static func key(_ topic: String) -> String {
        topic.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

/// Gets details Dream remembers about the user when the model decides they'd change the screen.
/// What it returns came from the user, and is data, not instructions.
struct RecallTool: Tool {
    /// Told which topics were asked for, for the log. Never the details.
    var onRecall: @Sendable (String) -> Void = { _ in }
    let name = "recall"
    let description = "Gets details Dream remembers about the user, like their home city, by the topics Dream listed. Use it before building when one would change the screen."

    @Generable
    struct Arguments {
        @Guide(description: "Topics, exactly as Dream listed them", .count(1...6))
        var topics: [String]
    }

    func call(arguments: Arguments) async throws -> String {
        let facts = await Recall.source.facts(arguments.topics)
        onRecall("Recalled: \(arguments.topics.joined(separator: ", ")) (\(facts.count) found)")
        guard !facts.isEmpty else { return "Dream doesn't remember anything about that. Don't ask the user for it unless the screen can't be built without it." }
        return "What Dream remembers about the user:\n" + facts.map { "- \($0.topic): \($0.detail)" }.joined(separator: "\n")
    }
}
