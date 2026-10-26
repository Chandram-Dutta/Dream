import SwiftData

extension ConnectionStore {
    /// At launch, knowing what Dream remembers about the user, every fact including ones still
    /// waiting to be confirmed, so it can keep them from services not allowed them.
    func start(_ container: ModelContainer) {
        start(personalDetails: {
            await MainActor.run {
                ((try? container.mainContext.fetch(FetchDescriptor<MemoryFact>())) ?? []).map(\.text)
            }
        })
    }
}
