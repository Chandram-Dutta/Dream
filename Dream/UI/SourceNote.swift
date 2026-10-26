import SwiftUI

/// Who the facts came from, quietly, at the foot of a surface: each source's name, linked to its
/// page, and Wikipedia's licence when its text was used. Touch and hold for every page with its
/// title and date. Pictures come only from Wikimedia, so a web page is credited for its words alone.
struct SourceNote: View {
    let surface: Surface

    var body: some View {
        let credits = surface.credits
        Group {
            if !credits.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: credits.allSatisfy(\.isWikipedia) ? "book.closed" : "doc.text")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line(credits))
                            .foregroundStyle(.secondary)
                            .tint(surface.palette.accent)
                        if surface.usesWikipedia {
                            Text("Wikipedia text is available under CC BY-SA 4.0.")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .contextMenu {
                    ForEach(credits) { credit in
                        if let url = URL(string: credit.url) {
                            Link(destination: url) {
                                Text(credit.title)
                                Text(([credit.site] + [Self.day(credit.date)].compactMap(\.self)).joined(separator: " · "))
                            }
                        }
                    }
                }
                .accessibilityHint(credits.count > 1 ? "Touch and hold for each source." : "")
            } else if surface.hasInformation {
                Label("Written without a source. Check anything important.", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    /// "From Wikipedia: Compound interest" for one page; "From Wikipedia, 9to5Mac and Apple
    /// Support" for several, each site linked to the first of its pages.
    private func line(_ credits: [Citation]) -> AttributedString {
        var line = AttributedString("From ")
        var sites: [(name: String, url: String)] = []
        for credit in credits where !sites.contains(where: { $0.name == credit.site }) {
            sites.append((credit.site, credit.url))
        }
        if credits.count == 1, let only = credits.first {
            line += linked(only.title == only.site ? only.site : "\(only.site): \(only.title)", to: only.url)
        } else {
            for (index, site) in sites.enumerated() {
                if index > 0 { line += AttributedString(index == sites.count - 1 ? " and " : ", ") }
                line += linked(site.name, to: site.url)
            }
        }
        return line
    }

    private func linked(_ text: String, to address: String) -> AttributedString {
        var run = AttributedString(text)
        if let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) { run.link = url }
        return run
    }

    /// A page's date as the reader writes dates.
    private static func day(_ text: String?) -> String? {
        guard let text, let date = try? Date(text, strategy: .iso8601.year().month().day()) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
