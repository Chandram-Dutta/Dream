import SwiftData
import SwiftUI

@main
struct DreamApp: App {
    /// For the token iOS gives for notifications (Notifications.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// A fresh store, since earlier prototypes stored tools and pages in other shapes.
    private let container = try! ModelContainer(for: SavedSurface.self, MemoryFact.self, StoredRecord.self, StartedPage.self, configurations: ModelConfiguration("Dream"))

    init() {
        Memory.start(container)
        ConnectionStore.shared.start(container)
        Account.shared.start(container)
        Sync.start(container)
        ServerPages.start(container)
        Notifications.shared.start(container)
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
