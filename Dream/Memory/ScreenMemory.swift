import Foundation
import NaturalLanguage

/// Finds a saved surface that closely matches what's being typed, so Dream can offer it instead
/// of building it again. On the phone, by the words that carry meaning in the request, its
/// title and its question.
///
/// Whole-sentence embeddings were tried and rejected: they score "who was Alan Turing" closer to
/// "who was Ada Lovelace" than "split the bill" to "split a restaurant bill". Words that matter
/// have to be shared; a word embedding only lets near-synonyms (trip, travel) count for part.
enum ScreenMemory {
    /// How close two requests must be to offer one for the other.
    static let threshold = 0.66

    /// The best match among saved surfaces, each given as the texts that describe it.
    static func best<ID>(for typed: String, in candidates: [(id: ID, texts: [String])]) -> ID? {
        let words = terms(typed)
        guard !words.isEmpty else { return nil }
        var best: (id: ID, score: Double)?
        for candidate in candidates {
            let score = candidate.texts.map { similarity(words, terms($0)) }.max() ?? 0
            if score >= threshold, score > (best?.score ?? 0) { best = (candidate.id, score) }
        }
        return best?.id
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        similarity(terms(a), terms(b))
    }

    /// How much of each side the other covers, from 0 to 1, mostly how much of what's typed: a
    /// short request inside a longer saved one is still a match. At least one word must be shared
    /// outright, so near-synonyms alone never make one.
    static func similarity(_ typed: [String], _ saved: [String]) -> Double {
        guard !typed.isEmpty, !saved.isEmpty, !Set(typed).isDisjoint(with: saved) else { return 0 }
        let typedCovered = typed.map { cover($0, by: saved) }.reduce(0, +) / Double(typed.count)
        let savedCovered = saved.map { cover($0, by: typed) }.reduce(0, +) / Double(saved.count)
        return 0.6 * typedCovered + 0.4 * savedCovered
    }

    private static func cover(_ word: String, by others: [String]) -> Double {
        others.map { match(word, $0) }.max() ?? 0
    }

    private static func match(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        // splitter and split, savings and saving.
        if a.count >= 4, b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return 0.8 }
        if let embedding, embedding.contains(a), embedding.contains(b), embedding.distance(between: a, and: b) < 0.85 { return 0.6 }
        return 0
    }

    nonisolated(unsafe) private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    /// The words that carry meaning, as lemmas: "how do vaccines work" → vaccine.
    static func terms(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var terms: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            let word = (tag?.rawValue ?? String(text[range])).lowercased()
            if word.count > 1, !fillers.contains(word), !terms.contains(word), word.contains(where: \.isLetter) || word.contains(where: \.isNumber) {
                terms.append(word)
            }
            return true
        }
        return terms
    }

    /// Words that say how something is asked rather than what about.
    private static let fillers: Set<String> = [
        "what", "whats", "is", "be", "are", "was", "were", "who", "whom", "whose", "how", "do", "does", "did", "why", "when",
        "where", "which", "the", "an", "of", "tell", "me", "about", "explain", "work", "can", "could", "you", "my", "mine",
        "mean", "meaning", "please", "this", "that", "it", "in", "to", "for", "with", "and", "or", "on", "at", "by", "from",
        "much", "many", "will", "would", "should", "shall", "get", "make", "show", "help", "calculate", "calculator",
        "work out", "find", "out", "between", "into", "your", "our", "we", "us", "they", "them", "if", "than", "then", "so",
        "some", "any", "all", "every", "per", "have", "has", "had", "want", "need", "like", "let", "lets", "let's", "go",
    ]
}
