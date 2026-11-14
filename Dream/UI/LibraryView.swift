import SwiftData
import SwiftUI

/// Every page, to search, or to see as a map of how they relate (PageMapView.swift). Home shows
/// only the starred and the last few; this is where the rest are.
struct LibraryView: View {
    @Query(sort: \SavedSurface.updatedAt, order: .reverse) private var surfaces: [SavedSurface]
    @State private var search = ""
    @State private var showing = Showing.pages

    enum Showing: String, CaseIterable {
        case pages = "Pages"
        case map = "Map"
    }

    private var found: [SavedSurface] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return surfaces }
        return surfaces.filter { saved in
            let text = ([saved.surface.title, saved.intent, saved.surface.summary] + saved.subjects).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        Group {
            switch showing {
            case .pages:
                ScrollView {
                    if found.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .padding(.top, 60)
                    } else {
                        PageGrid(pages: found)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }
                .searchable(text: $search, prompt: "Search your pages")
            case .map:
                PageMapView(pages: surfaces.filter { $0.sharedFrom == nil })
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("All pages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $showing) {
                    ForEach(Showing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }
}

/// Pages as tiles, two across, each with its menu: star it, or delete it.
struct PageGrid: View {
    @Environment(\.modelContext) private var context
    let pages: [SavedSurface]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(pages) { saved in
                NavigationLink(value: saved) {
                    SurfaceTile(saved: saved)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if saved.sharedFrom == nil {
                        Button(saved.isStarred ? "Unstar" : "Star", systemImage: saved.isStarred ? "star.slash" : "star") {
                            withAnimation(.smooth) { saved.isStarred.toggle() }
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        RecordStore.deleteAll(of: saved.id, in: context)
                        context.delete(saved)
                    }
                }
            }
        }
    }
}
