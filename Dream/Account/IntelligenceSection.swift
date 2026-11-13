import SwiftUI

/// Who makes the pages: Apple Intelligence, on this iPhone or on Private Cloud Compute, and how
/// each is doing. There's nothing to buy and no model to choose.
struct IntelligenceSection: View {
    @State private var cloud = AppleModels.cloudStatus
    @State private var device = AppleModels.deviceStatus

    var body: some View {
        Section {
            LabeledContent {
                Text(cloud)
            } label: {
                Label("Private Cloud Compute", systemImage: "lock.icloud")
            }
            LabeledContent {
                Text(device)
            } label: {
                Label("On this iPhone", systemImage: "iphone")
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("Your pages are made by Apple's models: on Private Cloud Compute, where requests are processed on Apple silicon and never kept, or on this iPhone when you're offline. Dream has no model of its own, and nothing you ask goes to anyone else's.")
        }
        .task {
            cloud = AppleModels.cloudStatus
            device = AppleModels.deviceStatus
        }
    }
}
