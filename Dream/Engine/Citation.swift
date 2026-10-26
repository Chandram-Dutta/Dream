import Foundation

// Sources a surface's facts came from, beyond the one Wikipedia article in `Surface.reference`
// (which also gives the screen its picture and the model its extract). The model names the pages
// it took facts from; the checker keeps only pages it actually read (Checker+Citations.swift), and
// the foot of the screen credits them all. Pictures still come only from Wikimedia: a page that
// was read lends its words, never its images.

/// One page a surface credits.
struct Citation: Codable, Hashable, Identifiable {
    /// The page's own title.
    var title: String
    /// Who published it, like 9to5Mac or Wikipedia.
    var site: String
    /// Where it is: always http or https.
    var url: String
    /// When it was published, as YYYY-MM-DD, if the page says.
    var date: String? = nil

    var id: String { url }

    var isWikipedia: Bool {
        URL(string: url)?.host()?.lowercased().hasSuffix(".wikipedia.org") ?? false
    }

    /// An address as the model wrote it, before the checker finds the page it means.
    static func named(_ url: String) -> Citation {
        Citation(title: "", site: "", url: url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// An address in a form that's the same however it's written: no scheme, `www.`, fragment
    /// or trailing slash, and the host in lower case. Nil for anything that isn't http or https.
    static func key(_ url: String) -> String? {
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

extension Citation {
    init(_ reference: Reference) {
        self.init(title: reference.title, site: "Wikipedia", url: reference.url)
    }
}

/// The pages a model read while writing one surface, by every address it could cite them by:
/// the one it asked for, the one the page calls its own, and where it ended up.
struct ReadingList {
    private(set) var pages: [Citation] = []
    private var byAddress: [String: Int] = [:]

    init(_ pages: [Citation] = []) {
        for page in pages { add(page) }
    }

    mutating func add(_ page: Citation, at addresses: [String] = []) {
        let index: Int
        if let known = Citation.key(page.url).flatMap({ byAddress[$0] }) {
            index = known
        } else {
            index = pages.count
            pages.append(page)
        }
        for address in [page.url] + addresses {
            if let key = Citation.key(address), byAddress[key] == nil { byAddress[key] = index }
        }
    }

    func page(at url: String) -> Citation? {
        Citation.key(url).flatMap { byAddress[$0] }.map { pages[$0] }
    }
}

extension Surface {
    /// Everyone the foot of the screen credits: the Wikipedia article first, then each page cited.
    var credits: [Citation] {
        var credits: [Citation] = []
        var seen: Set<String> = []
        for credit in (reference.map { [Citation($0)] } ?? []) + (citations ?? []) {
            guard let key = Citation.key(credit.url), seen.insert(key).inserted else { continue }
            credits.append(credit)
        }
        return credits
    }

    /// Whether any text came from Wikipedia, whose licence asks to be named.
    var usesWikipedia: Bool { credits.contains(where: \.isWikipedia) }
}
