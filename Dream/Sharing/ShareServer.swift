import Foundation

/// Dream's sharing server: a Worker on Cloudflare (Server/) that keeps shared surfaces under short
/// links and shows them on the web to people without Dream.
enum ShareServer {
    /// Where links are made: the server set in Under the hood, or else the one this build was
    /// made for (the `DREAM_SHARE_HOST` build setting, which also names the universal-link
    /// domain). Nil until one is set.
    static var base: URL? {
        if let custom = UserDefaults.standard.string(forKey: "shareServer"), let url = normalized(custom) { return url }
        return builtIn
    }

    /// The host in the app's Info.plist. A `.invalid` host is the placeholder for "not set yet".
    static var builtIn: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "DreamShareHost") as? String).flatMap(normalized)
    }

    /// A server address as typed (ServerAddress.swift, shared with web search).
    static func normalized(_ text: String) -> URL? {
        ServerAddress.normalized(text)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Uploads a surface and returns its link.
    static func upload(_ shared: SharedSurface, to base: URL) async throws -> SharedLink {
        var request = URLRequest(url: base.appending(path: "api/surfaces"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try shared.json
        guard request.httpBody?.count ?? 0 <= SharedSurface.maxSize else { throw ShareError.tooBig }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw ServerError(status: status) }
        struct Created: Decodable { let id: String }
        guard let id = try? JSONDecoder().decode(Created.self, from: data).id, let link = SharedLink(base: base, id: id) else {
            throw ServerError(status: status)
        }
        return link
    }

    /// A shared surface's JSON, unchecked: `SharedSurface.received` checks it.
    static func fetch(_ link: SharedLink) async throws -> Data {
        var request = URLRequest(url: link.base.appending(path: "api/surfaces/\(link.id)"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ServerError(status: status) }
        guard response.expectedContentLength <= Int64(SharedSurface.maxSize) else { throw ShareError.tooBig }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > SharedSurface.maxSize { throw ShareError.tooBig }
        }
        return data
    }
}

/// A link to one shared surface: `https://<server>/s/<id>`, or `dream://s/<id>` from the web
/// viewer's Open in Dream button, which means the server this app shares to.
struct SharedLink: Hashable {
    let base: URL
    let id: String

    init?(base: URL, id: String) {
        guard id.count == 10, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        self.base = base
        self.id = id
    }

    /// Only links to a server Dream shares to: one in Under the hood, or the one it was built
    /// for. Universal links only ever arrive for that one.
    init?(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "dream":
            // dream://s/<id>: the host is "s".
            guard url.host()?.lowercased() == "s", parts.count == 1, let base = ShareServer.base else { return nil }
            self.init(base: base, id: parts[0])
        case "https", "http":
            guard parts.count == 2, parts[0] == "s", let base = ShareServer.normalized(url.absoluteString),
                  [ShareServer.base, ShareServer.builtIn].contains(base) else { return nil }
            self.init(base: base, id: parts[1])
        default:
            return nil
        }
    }

    /// The link people get: the web viewer, which opens in Dream where it's installed.
    var url: URL { base.appending(path: "s/\(id)") }
}

/// A failed request, in words. The server's own messages are left out: what's shown on the
/// phone is written here.
struct ServerError: LocalizedError {
    let status: Int

    var errorDescription: String? {
        switch status {
        case 404: "This shared screen isn't there anymore, or the link is incomplete."
        case 413: "This screen is too big to share."
        case 429: "Too many shares at once. Try again in a minute."
        case 0: "Couldn't reach the sharing server."
        default: "The sharing server had a problem (\(status)). Try again in a moment."
        }
    }
}
