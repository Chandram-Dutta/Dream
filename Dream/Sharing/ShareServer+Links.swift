import Foundation

/// A link the user shared, as the server keeps it: which page, when, whether their numbers
/// went too, and how often it's been opened (a count, nothing about who).
struct OwnedLink: Decodable, Identifiable, Hashable {
    enum State: String, Decodable {
        /// Still shared; the rest have stopped and show a page saying so.
        case shared, stopped, expired, removed
    }

    let id: String
    let url: URL
    /// The app's id for the page it came from (`SavedSurface.id`), when it said.
    let page: String?
    let title: String
    let accent: Accent?
    let symbol: String?
    let created: Date
    let updated: Date
    let hasValues: Bool
    let views: Int
    let expiresAt: Date?
    let state: State

    var isShared: Bool { state == .shared }

    enum CodingKeys: String, CodingKey {
        case id, url, page, title, accent, symbol, created, updated, hasValues, views, expiresAt, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        page = try container.decodeIfPresent(String.self, forKey: .page)
        title = try container.decode(String.self, forKey: .title)
        // An accent this version doesn't know is just left out.
        accent = (try? container.decodeIfPresent(String.self, forKey: .accent)).flatMap { $0.flatMap(Accent.init(rawValue:)) }
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        created = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .created))
        updated = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .updated))
        hasValues = try container.decode(Bool.self, forKey: .hasValues)
        views = try container.decode(Int.self, forKey: .views)
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt).map { Date(timeIntervalSince1970: $0) }
        state = (try? container.decode(State.self, forKey: .state)) ?? .stopped
    }
}

/// A sharer the user chose not to see again, named by the page they blocked them from: Dream
/// never says who shared a page.
struct BlockedSharer: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let created: Date

    enum CodingKeys: String, CodingKey { case id, title, created }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        created = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .created))
    }
}

/// Why someone reports a page, as the server takes it (Server/src/page.ts).
enum ReportReason: String, CaseIterable, Identifiable {
    case hate, sexual, violence, `private`, spam, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hate: "Hate or harassment"
        case .sexual: "Sexual content"
        case .violence: "Violence or threats"
        case .private: "Someone's private information"
        case .spam: "Spam or a scam"
        case .other: "Something else"
        }
    }
}

/// The user's links, and reports and blocks, on Dream's server (Server/src/shares.ts, safety.ts).
/// Everything here but reporting needs the user signed in.
extension ShareServer {
    /// The user's links: those still shared, and those that stopped in the last month.
    static func myLinks() async throws -> [OwnedLink] {
        struct Listing: Decodable { let shares: [OwnedLink] }
        return try await send("GET", "api/me/shares", as: Listing.self).shares
    }

    /// Puts the page's newest version behind a link it already has.
    static func update(_ link: OwnedLink, to shared: SharedSurface) async throws -> OwnedLink {
        try await send("PUT", "api/surfaces/\(link.id)", body: try shared.json, as: OwnedLink.self)
    }

    /// When a link stops working, or nil for never.
    static func expire(_ link: OwnedLink, at date: Date?) async throws -> OwnedLink {
        let expiresAt: Any = date.map { Int($0.timeIntervalSince1970) } ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: ["expiresAt": expiresAt])
        return try await send("PUT", "api/surfaces/\(link.id)", body: body, as: OwnedLink.self)
    }

    /// Stops sharing: the link stays, saying the page is no longer shared, and the page is erased.
    static func stop(_ link: OwnedLink) async throws -> OwnedLink {
        try await send("DELETE", "api/surfaces/\(link.id)", as: OwnedLink.self)
    }

    /// Reports a page someone shared. It goes without the session: reports don't say who sent them.
    static func report(_ link: SharedLink, reason: ReportReason, note: String) async throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONSerialization.data(withJSONObject: ["reason": reason.rawValue, "note": String(trimmed.prefix(500))])
        _ = try await send("POST", "api/surfaces/\(link.id)/report", base: link.base, body: body, signedIn: false, as: Empty.self)
    }

    /// Stops showing pages from whoever shared `link`. Of the shared pages the user has opened
    /// (`opened`, by id), returns those from the same person, to remove them too.
    static func block(sharerOf link: SharedLink, opened: [String]) async throws -> [String] {
        struct Blocked: Decodable { let hidden: [String] }
        let body = try JSONSerialization.data(withJSONObject: ["opened": opened])
        return try await send("POST", "api/surfaces/\(link.id)/block", base: link.base, body: body, as: Blocked.self).hidden
    }

    static func blockedSharers() async throws -> [BlockedSharer] {
        struct Listing: Decodable { let blocked: [BlockedSharer] }
        return try await send("GET", "api/me/blocked", as: Listing.self).blocked
    }

    static func unblock(_ sharer: BlockedSharer) async throws {
        _ = try await send("DELETE", "api/me/blocked/\(sharer.id)", as: Empty.self)
    }

    private struct Empty: Decodable {}

    /// One request to Dream's server, with the session unless `signedIn` is false, decoded; or
    /// the failure, in words.
    private static func send<Answer: Decodable>(_ method: String, _ path: String, base: URL? = nil, body: Data? = nil, signedIn: Bool = true, as: Answer.Type) async throws -> Answer {
        guard let base = base ?? Self.base else { throw ServerError(status: 0) }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        // The session only ever goes to Dream's own server.
        if signedIn, [Self.base, Self.builtIn].contains(base) { Session.authorize(&request) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServerError(status: status, data: data) }
        if Answer.self == Empty.self { return Empty() as! Answer }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw ServerError(status: status) }
        return answer
    }
}

extension SharedLink {
    /// The link a shared page on the shelf was opened from (`SavedSurface.sharedFrom`).
    init?(address: String) {
        guard let url = URL(string: address), let base = ServerAddress.normalized(url.absoluteString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "s" else { return nil }
        self.init(base: base, id: parts[1])
    }
}
