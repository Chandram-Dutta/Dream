import SwiftUI

/// Where the page is forming, the question before a connected service's tool runs: what it
/// does, exactly what it sends, and anything personal in it, named. The tool waits until the
/// user answers.
struct ConsentView: View {
    let consent: Consent
    let palette: Palette

    var body: some View {
        if let request = consent.pending {
            ConsentCard(request: request, palette: palette) { answer in
                Analytics.send(.toolPromptAnswered(answer == .always ? .always : answer == .once ? .once : .deny))
                consent.answer(answer)
            }
                .id(request.id)
                .onAppear { Analytics.send(.toolPromptShown) }
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
        }
    }
}

private struct ConsentCard: View {
    let request: ConsentRequest
    let palette: Palette
    let onAnswer: (ConsentAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ServiceMonogram(name: request.service, isOn: true)
                Text(request.service)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(request.question)
                .font(.display(.title3))
                .accessibilityAddTraits(.isHeader)
            if let note = request.note {
                Label(note, systemImage: request.kind == .destroy ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(request.kind == .destroy ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if !request.personal.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.personal, id: \.self) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(palette.gradient)
                            Text("“\(detail.text)”, from \(detail.from)")
                        }
                    }
                }
                .font(.subheadline)
            }
            if !request.values.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.values, id: \.self) { value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(value.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(value.text)
                                .font(.callout)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground).opacity(0.6), in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.edge, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("What it sends")
            }
            FlowLayout(spacing: 8) {
                Button("Allow once") { onAnswer(.once) }
                    .buttonStyle(ConsentStyle(palette: palette, prominence: .main))
                if let always = request.always {
                    Button(always) { onAnswer(.always) }
                        .buttonStyle(ConsentStyle(palette: palette, prominence: .tinted))
                }
                Button("Don't allow") { onAnswer(.deny) }
                    .buttonStyle(ConsentStyle(palette: palette, prominence: .quiet))
            }
        }
        .panel(palette)
        .sensoryFeedback(.selection, trigger: request.id)
    }
}

/// The card's answers: allowing stands out, "Always" is tinted, refusing stays quiet.
private struct ConsentStyle: ButtonStyle {
    enum Prominence { case main, tinted, quiet }
    let palette: Palette
    let prominence: Prominence

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(prominence == .main ? .semibold : .medium))
            .foregroundStyle(prominence == .main ? AnyShapeStyle(.white) : prominence == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                switch prominence {
                case .main: Capsule().fill(palette.gradient)
                case .tinted: Capsule().fill(palette.accent.opacity(configuration.isPressed ? 0.24 : 0.12))
                case .quiet: Capsule().fill(Color.clear)
                }
            }
            .overlay(Capsule().strokeBorder(palette.edge, lineWidth: prominence == .quiet ? 1 : 0))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
