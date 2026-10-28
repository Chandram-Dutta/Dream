import Foundation

let urls = ["https://example.com/a b", "https://bücher.de/x", "https://EXAMPLE.com/Path/", "https://www.example.com:8080/x?q=1#frag",
            "https://user@example.com/", "example.com/page", "ftp://x.com", "https://a.com/%7Euser", "https://a.com/a/../b", "https://a.com?x",
            "https://a.com/?", "http://[::1]/x", "https://a.com/é", "HTTPS://WWW.A.COM", "https://a.com//", "https:/a.com/x", "https://a.com:/x",
            "https://a.com/x y?q=a b#f g", "https://a.com/<x>", "http://", "https://a.com/x|y", "https://a.com/{x}", "https://a.com/\"q\"",
            "  https://a.com/x  ", "https://a.com/x#", "https://:pw@a.com/", "https://a_b.com/x", "https://a.com/x%zz", "https://a.com/x^y",
            "mailto:x@y.com", "https://a.com\\x", "https://a.com/x`y", "javascript:alert(1)", "https://xn--bcher-kva.de/x", "https://a.com/%E2%82%AC"]
for url in urls {
    let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
    let u = URL(string: url)
    print("\(url) | comps:", c.map { "scheme=\($0.scheme ?? "nil") host=\($0.host ?? "nil") pehost=\($0.percentEncodedHost ?? "nil") user=\($0.user ?? "nil") pw=\($0.password ?? "nil") path=\($0.percentEncodedPath) query=\($0.percentEncodedQuery ?? "nil")" } ?? "nil",
          "| url.host:", u?.host() ?? "nil", "| key:", Citation.keyProbe(url) ?? "nil")
}

enum Citation {
    static func keyProbe(_ url: String) -> String? {
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare + path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }
}
