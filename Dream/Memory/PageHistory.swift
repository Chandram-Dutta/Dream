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

/// The page as it was before a change, to go back to.
struct PageVersion: Codable, Hashable, Identifiable {
    var id = UUID()
    /// The template, exactly as the page kept it.
    var template: Data
    var title: String
    /// The change made after it, which going back undoes.
    var change: String
    var at: Date
}

extension SavedSurface {
    /// The most versions a page keeps: enough to step back through an evening's changes.
    static let versionLimit = 12

    /// Earlier versions, oldest first.
    var versions: [PageVersion] {
        get { versionsData.flatMap { try? JSONDecoder().decode([PageVersion].self, from: $0) } ?? [] }
        set { versionsData = try? JSONEncoder().encode(Array(newValue.suffix(Self.versionLimit))) }
    }

    /// Keeps the page as it is now, before `change` is made to it.
    func keepVersion(before change: String) {
        guard !templateData.isEmpty else { return }
        versions.append(PageVersion(template: templateData, title: surface.title, change: change, at: .now))
    }

    /// Goes back to an earlier version. The page as it is now is kept too, so going back can be
    /// undone the same way.
    func restore(_ version: PageVersion) {
        var kept = versions.filter { $0.id != version.id }
        kept.append(PageVersion(template: templateData, title: surface.title, change: "Went back to an earlier version", at: .now))
        versions = kept
        templateData = version.template
        updatedAt = .now
        note(.changed, "Went back to the version before \"\(version.change)\"")
    }
}
