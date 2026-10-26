import SwiftData
import SwiftUI

@main
struct DreamApp: App {
    /// A fresh store, since earlier prototypes stored tools and pages in other shapes.
    private let container = try! ModelContainer(for: SavedSurface.self, MemoryFact.self, StoredRecord.self, configurations: ModelConfiguration("Dream"))

    init() {
        Memory.start(container)
        ConnectionStore.shared.start(container)
        Plan.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .offeringPlans()
        }
        .modelContainer(container)
    }
}
