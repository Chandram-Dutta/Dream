import SwiftUI

/// The first-run question, on the home screen until it's answered: may Dream send crash reports
/// and counts of what's used? Nothing is sent until the user says yes. Account has the same
/// choice later (`ImproveDreamSection`).
struct ImproveDreamQuestion: View {
    let palette: Palette
    @AppStorage(ImproveDream.key) private var choice: Bool?

    var body: some View {
        if choice == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text("Help improve Dream?")
                    .font(.display(.title3))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 8) {
                    point("Crash and hang reports", symbol: "waveform.path.ecg")
                    point("Counts, like how long pages take", symbol: "chart.bar")
                    point("Never what you ask, make or keep", symbol: "eye.slash")
                }
                .font(.subheadline)
                HStack(spacing: 8) {
                    Button("Help improve") { answer(true) }
                        .buttonStyle(AnswerStyle(palette: palette, isMain: true))
                    Button("Not now") { answer(false) }
                        .buttonStyle(AnswerStyle(palette: palette, isMain: false))
                    Spacer(minLength: 0)
                }
                LegalLinks()
            }
            .panel(palette)
            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
        }
    }

    private func point(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(palette.gradient)
        }
    }

    private func answer(_ on: Bool) {
        withAnimation(.smooth) { ImproveDream.set(on) }
    }
}

/// The same choice in Account, with the policy beside it. It goes in a `List` or `Form`.
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

/// Saying yes stands out; "Not now" stays quiet but just as easy to tap.
struct AnswerStyle: ButtonStyle {
    let palette: Palette
    let isMain: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(isMain ? .semibold : .medium))
            .foregroundStyle(isMain ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                if isMain { Capsule().fill(palette.gradient) }
            }
            .overlay(Capsule().strokeBorder(palette.edge, lineWidth: isMain ? 0 : 1))
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
