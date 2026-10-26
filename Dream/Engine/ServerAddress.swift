import Foundation

/// Addresses of Dream's own server (Server/), as typed in Under the hood or set when the app was
/// built: sharing and web search both live there.
enum ServerAddress {
    /// A server address as typed: a bare host gets https; a path or trailing slash is dropped.
    /// Plain http only reaches this Mac, for trying the Worker under `wrangler dev`.
    static func normalized(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("$(") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host?.lowercased(), !host.isEmpty, !host.hasSuffix(".invalid") else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard components.scheme == "https" || (components.scheme == "http" && isLocal) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}
