import Foundation
import SwiftData

// What signing in and out asks of sync (workstream A shows the prompts).

extension Sync {
    /// Whether this iPhone holds pages, list entries, memory or connections, which signing in
    /// could move into the account (`adoptLocalData`).
    static var hasLocalData: Bool {
        guard let container = shared.container else { return false }
        let context = ModelContext(container)
        let pages = (try? context.fetchCount(FetchDescriptor<SavedSurface>())) ?? 0
        let facts = (try? context.fetchCount(FetchDescriptor<MemoryFact>())) ?? 0
        let entries = (try? context.fetchCount(FetchDescriptor<StoredRecord>())) ?? 0
        return pages + facts + entries > 0 || !ConnectionStore.shared.connections.isEmpty
    }

    /// Moves everything on this iPhone into the signed-in account: pages with their photos,
    /// numbers and conversations, list entries, memory, connections (never their sign-ins) and
    /// synced settings. Call it once the user agrees, at their first sign-in. Without it, what was
    /// here before signing in stays on this iPhone only, unless it's changed.
    static func adoptLocalData() {
        shared.adopt()
    }

    private func adopt() {
        guard let container else { return }
        // Before signing in, it's queued in the stored ledger, which signing in picks up.
        if !isOn { loadLedger() }
        let context = ModelContext(container)
        let at = stamp
        for saved in (try? context.fetch(FetchDescriptor<SavedSurface>())) ?? [] {
            ledger.changed(SyncKey(.surface, saved.id.uuidString), deleted: false, at: at)
        }
        for stored in (try? context.fetch(FetchDescriptor<StoredRecord>())) ?? [] {
            ledger.changed(SyncKey(.record, stored.recordID.uuidString), parent: stored.surfaceID.uuidString, deleted: false, at: at)
        }
        for fact in (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? [] {
            ledger.changed(SyncKey(.fact, fact.id.uuidString), deleted: false, at: at)
        }
        for connection in ConnectionStore.shared.connections {
            ledger.changed(SyncKey(.connection, connection.id.uuidString), deleted: false, at: at)
        }
        for setting in SyncedSetting.allCases where setting.value != nil {
            ledger.changed(SyncKey(.setting, setting.rawValue), deleted: false, at: at)
        }
        storeLedger()
        unsent = ledger.outbox.count
        now()
    }

    /// Removes everything personal from this iPhone: pages, list entries, memory, connections
    /// with their sign-ins, and synced settings; and forgets where sync was. For signing out, and
    /// for starting from the account alone at first sign-in. The account keeps its copy.
    /// Call `flush` first when signing out, so nothing unsent is lost.
    static func clearLocalData() async {
        await shared.clear()
    }

    private func clear() async {
        guard let container else { return }
        paused = true
        let context = ModelContext(container)
        context.author = Self.author
        for stored in (try? context.fetch(FetchDescriptor<StoredRecord>())) ?? [] { context.delete(stored) }
        for saved in (try? context.fetch(FetchDescriptor<SavedSurface>())) ?? [] { context.delete(saved) }
        for fact in (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? [] { context.delete(fact) }
        try? context.save()
        for connection in ConnectionStore.shared.connections { await ConnectionStore.shared.remove(connection.id) }
        for setting in SyncedSetting.allCases { setting.clear() }
        UserDefaults.standard.removeObject(forKey: "seededLists")
        ledger.reset(for: nil)
        skipHistory(in: context)
        compare(in: context, queue: false)
        ledger.primed = true
        storeLedger()
        unsent = 0
        trouble = nil
        paused = false
        now(force: true)
    }

    /// Sends what's waiting and reads what's new, right away. True when nothing is left unsent.
    /// For signing out: call it first, while the session still works.
    @discardableResult
    static func flush() async -> Bool {
        await shared.roundNow()
        return shared.ledger.outbox.isEmpty
    }

    /// Uploads what was on the phone before signing in, once the user agreed to move it.
    func moveIntoAccount() {
        Sync.adoptLocalData()
        Task { @MainActor in
            if await Sync.flush() { LocalData.moveFinished() }
        }
    }
}
