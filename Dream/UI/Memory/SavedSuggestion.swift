import SwiftUI

/// Above the composer: a saved surface that closely matches what's being typed, offered rather
/// than built again. Tapping opens it; typing on ignores it.
struct SavedSuggestion: View {
    let text: String
    let surfaces: [SavedSurface]
    @State private var match: SavedSurface?

    var body: some View {
        Group {
            if let match {
                let surface = match.surface
                NavigationLink(value: match) {
                    HStack(spacing: 10) {
                        Image(systemName: surface.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(surface.palette.gradient)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("You made this before")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(surface.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(surface.palette.gradient)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityHint("Opens the page you made before, instead of making a new one")
            }
        }
        .animation(.smooth, value: match?.id)
        .task(id: text) {
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed.count >= 3 else { match = nil; return }
            let candidates = surfaces.map { saved in
                let surface = saved.surface
                return (id: saved.id, texts: [saved.intent, surface.title, surface.question ?? ""].filter { !$0.isEmpty })
            }
            let found = await Task.detached(priority: .userInitiated) { ScreenMemory.best(for: typed, in: candidates) }.value
            guard !Task.isCancelled else { return }
            match = found.flatMap { id in surfaces.first { $0.id == id } }
        }
    }
}
