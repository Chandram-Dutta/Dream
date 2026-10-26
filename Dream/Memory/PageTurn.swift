import Foundation

/// One turn of the user's conversation with a page: what they asked, and when. A page's turns
/// are its chat: the request that made it, the answers given before it was built, each change,
/// and what was said to its lists. They belong to the user, so they go wherever the page goes on
/// the user's own devices (Sync), and never with a shared page.
struct PageTurn: Codable, Hashable {
    enum Kind: String, Codable {
        /// The request that made the page, with the answers given before it was built.
        case asked
        /// A change to the page ("make it monthly").
        case changed
        /// A different answer to one of the questions, from its tag in the header.
        case answered
        /// Something said to one of the page's lists ("add milk and eggs").
        case listed
        /// The request again, after connecting a service it named.
        case rebuilt
    }

    /// Kept as written, so a kind added later survives a trip through an older version.
    var kindName: String
    /// What the user said.
    var text: String
    var at: Date
    /// For a request, the answers given before the page was built; for a changed answer, the new one.
    var answers: [Answer]

    init(_ kind: Kind, _ text: String, at: Date = .now, answers: [Answer] = []) {
        kindName = kind.rawValue
        self.text = text
        self.at = at
        self.answers = answers
    }

    var kind: Kind? { Kind(rawValue: kindName) }

    private enum CodingKeys: String, CodingKey {
        case kindName = "kind", text, at, answers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kindName = try container.decodeIfPresent(String.self, forKey: .kindName) ?? Kind.changed.rawValue
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try container.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        answers = try container.decodeIfPresent([Answer].self, forKey: .answers) ?? []
    }
}
