import Foundation
import FoundationModels

/// Lets a capable model look things up itself, when it decides the facts matter.
struct LookupTool: Tool {
    let found: ReferenceLog
    /// Told the subject as each lookup starts, so the screen can show it's reading.
    var onLookup: @Sendable (String) -> Void = { _ in }
    let name = "lookup"
    let description = "Looks up a subject in Wikipedia and returns the article's introduction. Use it whenever facts, numbers, dates or names matter."

    @Generable
    struct Arguments {
        @Guide(description: "The subject, as a short encyclopedia title")
        var subject: String
    }

    func call(arguments: Arguments) async throws -> String {
        onLookup(arguments.subject)
        guard let reference = await Lookup.find(arguments.subject) else {
            return "Nothing found for \"\(arguments.subject)\"."
        }
        found.append(reference)
        return "Wikipedia, \"\(reference.title)\":\n\(reference.extract)"
    }
}

/// What the lookup tool found, so the surface can credit its source and show its image.
final class ReferenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var references: [Reference] = []

    func append(_ reference: Reference) {
        lock.withLock { references.append(reference) }
    }

    var first: Reference? {
        lock.withLock { references.first }
    }
}

/// Grounds surfaces in Wikipedia, so facts come from a source rather than from the
/// on-device model's memory. One request: search, then the best article's intro and image.
enum Lookup {
    private static let questionWords: Set<String> = [
        "what", "whats", "is", "are", "was", "were", "who", "whom", "whose", "how", "do", "does", "did", "why", "when",
        "where", "which", "the", "a", "an", "of", "tell", "me", "about", "explain", "work", "works", "working", "can",
        "could", "i", "you", "my", "mean", "means", "meaning", "please", "this", "that", "it", "in", "to",
    ]

    /// The subject of a question, for searching: "how do vaccines work" → "vaccines".
    static func subject(of question: String) -> String {
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !questionWords.contains($0) }
        return words.isEmpty ? question : words.joined(separator: " ")
    }

    /// Content words, roughly singular, for comparing a subject with an article title.
    private static func stems(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !questionWords.contains($0) }
            .map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    static func find(_ topic: String) async -> Reference? {
        guard let response = await query([
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: topic),
            URLQueryItem(name: "gsrlimit", value: "3"),
            URLQueryItem(name: "prop", value: "extracts|pageimages|info|pageprops"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exchars", value: "1800"),
            URLQueryItem(name: "exlimit", value: "3"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "800"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "ppprop", value: "disambiguation"),
        ]) else { return nil }
        // Search always returns something; an article whose title shares no word with the
        // subject is usually a wrong turn that would mislead the page.
        let subject = stems(topic)
        let best = (response.query?.pages ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .first { !($0.pageprops?.isDisambiguation ?? false) && !($0.extract ?? "").isEmpty && !stems($0.title).isDisjoint(with: subject) }
        guard let best, let extract = best.extract else { return nil }
        return Reference(
            title: best.title,
            extract: extract,
            url: best.fullurl ?? "https://en.wikipedia.org/wiki/\(best.title.replacingOccurrences(of: " ", with: "_"))",
            imageURL: best.thumbnail?.source)
    }

    /// Articles Wikipedia's search considers similar, for pages the model didn't write.
    static func related(to title: String) async -> [String] {
        let response = await query([
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: "morelike:\(title)"),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "srprop", value: ""),
        ])
        return response?.query?.search?.map(\.title) ?? []
    }

    private static func query(_ items: [URLQueryItem]) async -> Response? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ] + items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Dream/0.1 (iOS prototype)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    private struct Response: Decodable {
        let query: Query?

        struct Query: Decodable {
            let pages: [Result]?
            let search: [SearchResult]?
        }

        struct SearchResult: Decodable {
            let title: String
        }

        struct Result: Decodable {
            let title: String
            let index: Int?
            let extract: String?
            let fullurl: String?
            let thumbnail: Thumbnail?
            let pageprops: Properties?
        }

        struct Thumbnail: Decodable {
            let source: String
        }

        struct Properties: Decodable {
            let isDisambiguation: Bool

            init(from decoder: Decoder) throws {
                isDisambiguation = try decoder.container(keyedBy: Keys.self).contains(.disambiguation)
            }

            enum Keys: String, CodingKey { case disambiguation }
        }
    }
}
