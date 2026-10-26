import SwiftData
import SwiftUI

@main
struct DreamApp: App {
    /// A fresh store, since earlier prototypes stored tools and pages in other shapes.
    private let container = try! ModelContainer(for: SavedSurface.self, MemoryFact.self, StoredRecord.self, configurations: ModelConfiguration("Dream"))

    init() {
        Memory.start(container)
        ConnectionStore.shared.start(container)
        Account.shared.start(container)
        Sync.start(container)
        Plan.shared.start()
        ImproveDream.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .accountFlow()
                .offeringPlans()
        }
        .modelContainer(container)
    }
}
