import SwiftUI

/// "Help improve Dream" in Account, with the policy beside it: on from sign-in, off here. It goes
/// in a `List` or `Form`.
struct ImproveDreamSection: View {
    @AppStorage(ImproveDream.key) private var choice: Bool?

    var body: some View {
        Section {
            Toggle("Help improve Dream", isOn: Binding(get: { choice == true }, set: { ImproveDream.set($0) }))
        } footer: {
            Text("Sends crash and hang reports, and counts of what you use, like how long pages take. Never what you ask for, what pages say, or your lists and memory.")
        }
        Section {
            LegalLinks(style: .rows)
        }
    }
}

/// Links to the privacy policy, terms and support, which Dream's server keeps
/// (Server/src/legal.ts). Small enough to sit under any question about data.
struct LegalLinks: View {
    enum Style {
        /// One quiet line: "Privacy policy · Terms · Support".
        case line
        /// A row each, for a list.
        case rows
    }

    var style = Style.line

    enum Page: String, CaseIterable {
        case privacy, terms, support

        var title: String {
            switch self {
            case .privacy: "Privacy policy"
            case .terms: "Terms of use"
            case .support: "Support"
            }
        }

        var symbol: String {
            switch self {
            case .privacy: "hand.raised"
            case .terms: "doc.text"
            case .support: "questionmark.bubble"
            }
        }

        var url: URL? { ServerAddress.dream?.appending(path: rawValue) }
    }

    var body: some View {
        switch style {
        case .line:
            HStack(spacing: 6) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    if let url = page.url {
                        if index > 0 { Text("·").foregroundStyle(.tertiary) }
                        Link(page == .terms ? "Terms" : page.title, destination: url)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .tint(.secondary)
        case .rows:
            ForEach(Page.allCases, id: \.self) { page in
                if let url = page.url {
                    Link(destination: url) {
                        Label(page.title, systemImage: page.symbol)
                    }
                }
            }
        }
    }
}
