import SwiftUI

// The action block (ROADMAP.md, workstream 7): the one place on a surface where Dream writes
// anything, and only when it's tapped.

/// A button that does one thing for the user. It says exactly what before it's tapped, worked
/// out from the screen's values as they are now, then shows what happened.
struct ActionBlockView: View {
    let block: Block
    let context: RenderContext
    @State private var phase = Phase.ready
    @State private var confirming = false
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case ready, working
        case done(ActionDone)
        case failed(LiveError)
    }

    var body: some View {
        if let action = context.surface.action(block.ref) {
            let resolved = action.resolved(in: context.surface, evaluation: context.evaluation)
            let performer = LiveActions.performer(action.kind)
            content(resolved, performer: performer)
        }
    }

    @ViewBuilder private func content(_ action: ResolvedAction, performer: (any ActionPerformer)?) -> some View {
        let palette = context.palette
        let sentence = performer?.sentence(action) ?? "Dream can't do this here."
        let done: ActionDone? = if case .done(let done) = phase { done } else { nil }
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if performer?.needsConfirmation(action) == true { confirming = true } else { perform(action, with: performer) }
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: done == nil ? performer?.symbol ?? "exclamationmark.circle" : "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(done?.message ?? sentence)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                    if phase == .working { ProgressView().tint(.white) }
                }
                .foregroundStyle(done == nil ? AnyShapeStyle(.white) : AnyShapeStyle(palette.accent))
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(done == nil ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(palette.wash))
                }
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(palette.edge, lineWidth: done == nil ? 0 : 0.5))
                .opacity(performer == nil ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(performer == nil || phase == .working || done != nil)
            .accessibilityHint(done == nil ? "Nothing happens until you tap." : "")

            let details = performer?.details(action) ?? []
            if !details.isEmpty || done != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if done != nil { Text(sentence) }
                    ForEach(details, id: \.self) { Text($0) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            }
            if let done, let link = done.link, !done.linkTitle.isEmpty {
                Link(done.linkTitle, destination: link)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
            }
            if case .failed(let error) = phase {
                HStack(spacing: 10) {
                    Text(error.message)
                    if error.reason == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Allow in Settings", destination: settings).fontWeight(.semibold)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            }
        }
        .animation(.smooth, value: phase)
        .sensoryFeedback(.success, trigger: done)
        .confirmationDialog(sentence, isPresented: $confirming, titleVisibility: .visible) {
            Button("Do it") { perform(action, with: performer) }
        } message: {
            Text((performer?.details(action) ?? []).joined(separator: "\n"))
        }
    }

    private func perform(_ action: ResolvedAction, with performer: (any ActionPerformer)?) {
        guard let performer, phase != .working else { return }
        phase = .working
        Task {
            do {
                let done = try await performer.perform(action)
                phase = .done(done)
                if done.opensNow, let link = done.link { openURL(link) }
            } catch {
                phase = .failed(error as? LiveError ?? LiveError(.unavailable, "That didn't work."))
            }
        }
    }
}
