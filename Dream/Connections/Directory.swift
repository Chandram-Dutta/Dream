import Foundation

// Discovering services to connect (ROADMAP.md, workstream 8): the directory Dream's Worker keeps
// from the official MCP Registry (Server/src/directory.ts), with a few services it has checked.

/// Reads the directory from Dream's server. What it says came from the registry, so it's shown
/// as plain text and connected to only when the user taps.
enum Directory {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// The services Dream has checked, with whether each needs a sign-in.
    static func featured(from server: URL) async throws -> [DirectoryEntry] {
        try await page(server.appending(path: "api/mcp/featured")).entries
    }

    /// The registry, searched by name, a page at a time.
    static func search(_ text: String, cursor: String? = nil, from server: URL) async throws -> (entries: [DirectoryEntry], next: String?) {
        var components = URLComponents(url: server.appending(path: "api/mcp/servers"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "search", value: String(text.prefix(80)))] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        guard let url = components?.url else { return ([], nil) }
        return try await page(url)
    }

    private static func page(_ url: URL) async throws -> (entries: [DirectoryEntry], next: String?) {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConnectionError.failed("The directory didn't answer. Try again in a moment.")
        }
        struct Page: Decodable {
            let servers: [Entry]
            let next: String?
        }
        // One entry Dream can't read doesn't spoil the page.
        struct Entry: Decodable {
            let entry: DirectoryEntry?
            init(from decoder: Decoder) throws { entry = try? DirectoryEntry(from: decoder) }
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let entries = page.servers.compactMap(\.entry).filter { $0.url.scheme == "https" }
        return (entries, page.next)
    }

    // MARK: - Kept on the phone

    private static let file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appending(path: "Dream/directory.json")

    /// The featured services as last fetched, so a request can be matched against them at once.
    static var saved: [DirectoryEntry] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([DirectoryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [DirectoryEntry]) {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
