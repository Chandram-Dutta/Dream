import Foundation
import FoundationModels

/// Lets a capable model look things up itself, when it decides the facts matter.
struct LookupTool: Tool {
    let found: ReferenceLog
    /// The request's language, for when the model doesn't say which Wikipedia to read.
    var language = "en"
    /// Told the subject as each lookup starts, so the screen can show it's reading.
    var onLookup: @Sendable (String) -> Void = { _ in }
    let name = "lookup"
    let description = "Looks up a subject in Wikipedia, in the language you're writing in, or in English when that has nothing, and returns the article's introduction. Use it whenever facts, numbers, dates or names matter."

    @Generable
    struct Arguments {
        @Guide(description: "The subject, as a short encyclopedia title")
        var subject: String
        // The model knows what it's writing in better than a recognizer reading a few words.
        @Guide(description: "The language you're writing the screen in, as a code like en, fr or hi")
        var language: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard found.mayLookUp() else { return "That's enough looking up for one screen. Build it from what you've found." }
        onLookup(arguments.subject)
        let code = arguments.language.trimmingCharacters(in: .whitespaces)
        let language = Locale(identifier: "en").localizedString(forLanguageCode: code) != nil ? code : self.language
        guard let reference = await Lookup.find(arguments.subject, language: language) else {
            return "Nothing found for \"\(arguments.subject)\"."
        }
        found.append(reference)
        return "Wikipedia, \"\(reference.title)\" (cite it as \(reference.url)):\n\(reference.extract)"
    }
}

/// What the lookup tool found, so the surface can credit its source and show its image.
final class ReferenceLog: @unchecked Sendable {
    /// Enough for a screen, as for the web (`WebLog`); more is a model going round in circles.
    /// Grok looks up five at most; DeepSeek once looked up the same few subjects a dozen times.
    static let lookupLimit = 6

    private let lock = NSLock()
    private var references: [Reference] = []
    private var lookups = 0

    func append(_ reference: Reference) {
        lock.withLock { references.append(reference) }
    }

    /// Whether another lookup may go ahead, counting it if so.
    func mayLookUp() -> Bool {
        lock.withLock {
            lookups += 1
            return lookups <= Self.lookupLimit
        }
    }

    var first: Reference? {
        lock.withLock { references.first }
    }

    /// Every article looked up, which the surface may also cite.
    var all: [Reference] {
        lock.withLock { references }
    }
}

/// Grounds surfaces in Wikipedia, so facts come from a source rather than from the
/// on-device model's memory. One request: search, then the best article's intro and image.
/// In another language, that language's Wikipedia is searched first, and English is the fallback.
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

    static func find(_ topic: String, language: String = "en") async -> Reference? {
        let wikipedia = Languages.wikipedia(language)
        guard wikipedia != "en" else { return await search(topic, in: "en")?.reference }
        if let local = await search(topic, in: wikipedia) { return local.reference }
        // Models often name the subject in English, which another language's search can miss:
        // find it in English, then follow the article's link to the same one in this language.
        guard let english = await search(topic, in: "en", linkingTo: wikipedia) else { return nil }
        if let title = english.link, let local = await article(title, in: wikipedia) { return local }
        return english.reference
    }

    /// The best article for a subject, and the title of the same article in another Wikipedia.
    private static func search(_ topic: String, in wikipedia: String, linkingTo other: String? = nil) async -> (reference: Reference, link: String?)? {
        var items = [
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: topic),
            URLQueryItem(name: "gsrlimit", value: "3"),
        ] + articleItems(linking: other != nil)
        if let other { items.append(URLQueryItem(name: "lllang", value: other)) }
        guard let response = await query(items, in: wikipedia) else { return nil }
        // Search always returns something; an article whose title shares no word with the
        // subject is usually a wrong turn that would mislead the page.
        let subject = stems(topic)
        let best = (response.query?.pages ?? [])
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .first { !($0.pageprops?.isDisambiguation ?? false) && !($0.extract ?? "").isEmpty && (!stems($0.title).isDisjoint(with: subject) || overlaps($0.title, topic)) }
        guard let best, let reference = reference(best, in: wikipedia) else { return nil }
        return (reference, best.langlinks?.first?.title)
    }

    /// One article, by its exact title.
    private static func article(_ title: String, in wikipedia: String) async -> Reference? {
        let items = [URLQueryItem(name: "redirects", value: "1"), URLQueryItem(name: "titles", value: title)] + articleItems(linking: false)
        return await query(items, in: wikipedia)?.query?.pages?.first.flatMap { reference($0, in: wikipedia) }
    }

    /// An article's introduction, image and address, and its link to another language if asked.
    private static func articleItems(linking: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "prop", value: "extracts|pageimages|info|pageprops" + (linking ? "|langlinks" : "")),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exchars", value: "1800"),
            URLQueryItem(name: "exlimit", value: "3"),
            URLQueryItem(name: "piprop", value: "thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "800"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "ppprop", value: "disambiguation"),
        ]
    }

    private static func reference(_ page: Response.Result, in wikipedia: String) -> Reference? {
        guard let extract = page.extract, !extract.isEmpty else { return nil }
        return Reference(
            title: page.title,
            extract: extract,
            url: page.fullurl ?? "https://\(wikipedia).wikipedia.org/wiki/\(page.title.replacingOccurrences(of: " ", with: "_"))",
            imageURL: page.thumbnail?.source)
    }

    /// For scripts written without spaces, where a title and its subject share no separate words.
    private static func overlaps(_ title: String, _ topic: String) -> Bool {
        let (title, topic) = (title.lowercased(), topic.lowercased())
        return title.count >= 2 && topic.count >= 2 && (title.contains(topic) || topic.contains(title))
    }

    /// Articles Wikipedia's search considers similar, for pages the model didn't write.
    static func related(to title: String, language: String = "en") async -> [String] {
        let response = await query([
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: "morelike:\(title)"),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "srprop", value: ""),
        ], in: Languages.wikipedia(language))
        return response?.query?.search?.map(\.title) ?? []
    }

    private static func query(_ items: [URLQueryItem], in wikipedia: String) async -> Response? {
        guard !wikipedia.isEmpty, wikipedia.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }),
              var components = URLComponents(string: "https://\(wikipedia).wikipedia.org/w/api.php") else { return nil }
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
            let langlinks: [LanguageLink]?
        }

        struct Thumbnail: Decodable {
            let source: String
        }

        struct LanguageLink: Decodable {
            let title: String
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

extension Reference {
    /// The language of the Wikipedia it came from, so related topics are found there too.
    var language: String {
        guard let host = URL(string: url)?.host(), host.hasSuffix(".wikipedia.org"), let code = host.split(separator: ".").first else { return "en" }
        return String(code)
    }
}
