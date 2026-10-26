import SwiftData
import SwiftUI

@main
struct DreamApp: App {
    /// A fresh store, since earlier prototypes stored tools and pages in other shapes.
    private let container = try! ModelContainer(for: SavedSurface.self, StoredRecord.self, configurations: ModelConfiguration("Dream"))

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(container)
    }
}
