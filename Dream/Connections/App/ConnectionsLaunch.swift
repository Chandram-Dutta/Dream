import Foundation
import SwiftData

extension ConnectionStore {
    /// At launch, knowing what's personal (every fact Dream remembers, including ones still
    /// waiting to be confirmed, and the text of the user's list entries) so a call that would
    /// carry any of it is always shown first, and with the directory on Dream's sharing server.
    func start(_ container: ModelContainer) {
        // The card goes where the page is forming. Device tours have nobody to tap it.
        Consent.answerer = Build.flag("DreamTour") ? .automatic(.once) : .user
        start(personalDetails: {
            await MainActor.run {
                let context = container.mainContext
                let facts = ((try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []).map {
                    PersonalDetail(text: $0.text, from: "what Dream knows about you (\($0.topic.lowercased()))")
                }
                var descriptor = FetchDescriptor<StoredRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 500
                let entries = ((try? context.fetch(descriptor)) ?? []).flatMap { stored in
                    stored.record.values.values.compactMap(\.textValue).map { PersonalDetail(text: $0, from: "your \(stored.collection) list") }
                }
                return facts + entries
            }
        }, directory: ShareServer.base)
    }
}
