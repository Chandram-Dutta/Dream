import Foundation

// Keeping a surface's sources honest (Citation.swift).

extension Checker {
    /// The most sources a screen credits.
    static let citationLimit = 8

    /// Keeps the sources a surface credits to web pages, over http or https, and, while it's
    /// being written, to pages the model actually read (`read`): a source it names but never read
    /// is dropped, and one it read is credited with the page's own title, site and address. If it
    /// read pages but named none, every page it read is credited, since its facts came from them.
    /// With `read` nil, as for a surface from elsewhere, only the addresses are checked.
    static func checkCitations(_ surface: inout Surface, read: ReadingList? = nil) -> [Issue] {
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        var named = surface.citations ?? []
        if let read, named.isEmpty, surface.hasInformation, !read.pages.isEmpty {
            named = read.pages
            issues.append(Issue(kind: .warning, message: "Named no sources, so every page read is credited."))
        }

        // The article already credited as the reference isn't credited twice.
        var seen: Set<String> = surface.reference.flatMap { Citation.key($0.url) }.map { [$0] } ?? []
        var kept: [Citation] = []
        for citation in named {
            guard let key = Citation.key(citation.url), citation.url.count <= 2_000 else {
                fixed("Dropped a source that isn't a web address.")
                continue
            }
            var credited = citation
            if let read {
                guard let page = read.page(at: citation.url) else {
                    fixed("Dropped a source that wasn't read: \(URL(string: citation.url)?.host() ?? citation.url).")
                    continue
                }
                credited = page
            }
            // Named twice, or under two addresses of one page.
            guard let creditedKey = Citation.key(credited.url), !seen.contains(key), !seen.contains(creditedKey) else { continue }
            seen.formUnion([key, creditedKey])
            kept.append(bounded(credited))
        }
        if kept.count > citationLimit {
            fixed("Kept the first \(citationLimit) of \(kept.count) sources.")
            kept = Array(kept.prefix(citationLimit))
        }
        surface.citations = kept.isEmpty ? nil : kept
        return issues
    }

    /// No longer than a footnote needs, with a site name even if the page gave none.
    private static func bounded(_ citation: Citation) -> Citation {
        var citation = citation
        let host = URL(string: citation.url)?.host()?.lowercased().replacing(#/^www\./#, with: "") ?? ""
        citation.site = String(citation.site.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if citation.site.isEmpty { citation.site = host }
        citation.title = String(citation.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if citation.title.isEmpty { citation.title = citation.site }
        if let date = citation.date, date.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) == nil { citation.date = nil }
        return citation
    }
}
