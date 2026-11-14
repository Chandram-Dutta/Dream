import SwiftData
import SwiftUI

// How a page links to the others (PageGraph.swift): the pages it went on from, above it; the
// pages related to it, below; and its menu, to star it or go back to an earlier version.

/// The pages this one went on from, oldest first, each one tap away.
struct ThreadPath: View {
    let pages: [SavedSurface]
    let palette: Palette
    let open: (SavedSurface) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    Button(page.surface.title) { open(page) }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goes on from")
    }
}

/// Pages related to this one: those that went on from it, and those about the same things.
struct RelatedPages: View {
    let pages: [SavedSurface]
    let parent: UUID?
    let palette: Palette
    let open: (SavedSurface) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(pages) { page in
                Button { open(page) } label: {
                    let surface = page.surface
                    HStack(spacing: 12) {
                        Image(systemName: surface.symbolName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(surface.palette.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(surface.title)
                                .font(.display(.subheadline))
                                .lineLimit(1)
                            Text(surface.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page of the user's own: star it, or go back to how it was before a change.
struct PageMenu: View {
    @Bindable var saved: SavedSurface
    let restore: (PageVersion) -> Void

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button(saved.isStarred ? "Unstar" : "Star", systemImage: saved.isStarred ? "star.slash" : "star") {
                saved.isStarred.toggle()
                Analytics.send(.pageStarred(on: saved.isStarred))
            }
            let versions = saved.versions
            if !versions.isEmpty {
                Menu("Earlier versions", systemImage: "clock.arrow.circlepath") {
                    // Newest first: the one before the last change is what's usually wanted.
                    ForEach(versions.reversed()) { version in
                        Button {
                            restore(version)
                        } label: {
                            Text("Before \u{201C}\(version.change)\u{201D}")
                            Text(version.at.formatted(.relative(presentation: .named)))
                        }
                    }
                }
            }
        }
    }
}
