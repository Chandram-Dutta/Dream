import Foundation
import SwiftData

/// What changed in SwiftData since a point in its history: which pages, list entries and memory
/// facts were inserted, updated or deleted, and when. Writes marked with sync's own author are
/// left out, so what came from the account isn't sent back. Deleted items are named by the ids
/// their models keep after deletion (`.preserveValueOnDeletion`). `Tools/sync.sh` checks this
/// against a real store on a Mac.
enum SyncHistory {
    struct Change: Equatable {
        var key: SyncKey
        /// A list entry's page, when the change is its deletion.
        var parent: String?
        var deleted: Bool
        var at: Date
    }

    /// Changes after `token` (nil for all history), oldest first, and the token to read from next.
    static func changes(after token: Data?, in context: ModelContext, ignoring author: String) -> (changes: [Change], token: Data?) {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = decode(token) { descriptor.predicate = #Predicate { $0.token > token } }
        guard let transactions = try? context.fetchHistory(descriptor), let last = transactions.last else { return ([], token) }
        var keys: [PersistentIdentifier: SyncKey] = [:]
        var changes: [Change] = []
        for transaction in transactions where transaction.author != author {
            for change in transaction.changes {
                if let found = read(change, at: transaction.timestamp, in: context, keys: &keys) { changes.append(found) }
            }
        }
        return (changes, try? JSONEncoder().encode(last.token))
    }

    /// The token for everything history holds now.
    static func latest(after token: Data?, in context: ModelContext) -> Data? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = decode(token) { descriptor.predicate = #Predicate { $0.token > token } }
        guard let last = (try? context.fetchHistory(descriptor))?.last else { return token }
        return try? JSONEncoder().encode(last.token)
    }

    /// Lets go of history before `token`, already read, so it doesn't grow without end.
    static func prune(before token: Data?, in context: ModelContext) {
        guard let token = decode(token) else { return }
        try? context.deleteHistory(HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token < token }))
    }

    private static func decode(_ token: Data?) -> DefaultHistoryToken? {
        token.flatMap { try? JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }
    }

    private static func read(_ change: HistoryChange, at date: Date, in context: ModelContext, keys: inout [PersistentIdentifier: SyncKey]) -> Change? {
        switch change {
        case .insert(let insert as DefaultHistoryInsert<SavedSurface>):
            return changed(SavedSurface.self, insert.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .update(let update as DefaultHistoryUpdate<SavedSurface>):
            // Opening a page counts the visit; that alone isn't worth sending the page again.
            // The count goes with its next real change.
            let visit: [AnyKeyPath] = [\SavedSurface.openCount, \SavedSurface.lastOpenedAt]
            if !update.updatedAttributes.isEmpty, update.updatedAttributes.allSatisfy({ visit.contains($0 as AnyKeyPath) }) { return nil }
            return changed(SavedSurface.self, update.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .delete(let delete as DefaultHistoryDelete<SavedSurface>):
            return (delete.tombstone[\.id] as? UUID).map { Change(key: SyncKey(.surface, $0.uuidString), deleted: true, at: date) }
        case .insert(let insert as DefaultHistoryInsert<StoredRecord>):
            return changed(StoredRecord.self, insert.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .update(let update as DefaultHistoryUpdate<StoredRecord>):
            return changed(StoredRecord.self, update.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .delete(let delete as DefaultHistoryDelete<StoredRecord>):
            let page = (delete.tombstone[\.surfaceID] as? UUID)?.uuidString
            return (delete.tombstone[\.recordID] as? UUID).map { Change(key: SyncKey(.record, $0.uuidString), parent: page, deleted: true, at: date) }
        case .insert(let insert as DefaultHistoryInsert<MemoryFact>):
            return changed(MemoryFact.self, insert.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .update(let update as DefaultHistoryUpdate<MemoryFact>):
            return changed(MemoryFact.self, update.changedPersistentIdentifier, at: date, in: context, keys: &keys)
        case .delete(let delete as DefaultHistoryDelete<MemoryFact>):
            return (delete.tombstone[\.id] as? UUID).map { Change(key: SyncKey(.fact, $0.uuidString), deleted: true, at: date) }
        default:
            return nil
        }
    }

    /// An insert or update: the item it was, if it's still here. If it's gone, its delete follows.
    private static func changed<Model: PersistentModel>(_ type: Model.Type, _ identifier: PersistentIdentifier, at date: Date, in context: ModelContext, keys: inout [PersistentIdentifier: SyncKey]) -> Change? {
        if keys[identifier] == nil {
            var descriptor = FetchDescriptor<Model>(predicate: #Predicate { $0.persistentModelID == identifier })
            descriptor.fetchLimit = 1
            guard let model = (try? context.fetch(descriptor))?.first else { return nil }
            switch model {
            case let saved as SavedSurface: keys[identifier] = SyncKey(.surface, saved.id.uuidString)
            case let stored as StoredRecord: keys[identifier] = SyncKey(.record, stored.recordID.uuidString)
            case let fact as MemoryFact: keys[identifier] = SyncKey(.fact, fact.id.uuidString)
            default: return nil
            }
        }
        return keys[identifier].map { Change(key: $0, deleted: false, at: date) }
    }
}
