import Foundation

extension SavedSurface {
    /// The user's conversation with this page, oldest first. A page saved before turns were kept
    /// starts from its request and the changes asked for since, dated when the page last changed.
    /// A page someone shared has no conversation until the user says something to it.
    var history: [PageTurn] {
        get {
            if !historyData.isEmpty, let turns = try? JSONDecoder().decode([PageTurn].self, from: historyData) { return turns }
            guard sharedFrom == nil, !intent.isEmpty else { return [] }
            return [PageTurn(.asked, intent, at: createdAt, answers: surface.answers ?? [])]
                + editRequests.map { PageTurn(.changed, $0, at: updatedAt) }
        }
        set { historyData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Adds one turn to the page's conversation.
    func note(_ kind: PageTurn.Kind, _ text: String, answers: [Answer] = []) {
        history.append(PageTurn(kind, text, answers: answers))
    }
}
