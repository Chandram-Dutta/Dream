import Foundation
import SwiftData
import SwiftUI

extension View {
    /// Keeps a surface's entries on the phone: loads them once the surface is saved, copies in
    /// its starters the first time each list is seen, writes every change, and moves entries
    /// along when a change to the screen changes a list's fields.
    func keepingRecords(of surfaceID: UUID?, collections: [RecordCollection], in state: SurfaceState) -> some View {
        modifier(RecordKeeper(surfaceID: surfaceID, collections: collections, state: state))
    }
}

private struct RecordKeeper: ViewModifier {
    let surfaceID: UUID?
    let collections: [RecordCollection]
    let state: SurfaceState
    @Environment(\.modelContext) private var context
    @State private var store = RecordStore()
    /// While this screen lives, deletions from the user's other devices wait (Sync).
    @State private var hold = PageHold()

    func body(content: Content) -> some View {
        content
            .task(id: surfaceID) {
                load()
                hold.hold(surfaceID)
            }
            // Entries changed on the user's other devices.
            .onReceive(NotificationCenter.default.publisher(for: Sync.recordsDidChange)) { note in
                if let surfaceID, (note.object as? Set<UUID>)?.contains(surfaceID) == true { load() }
            }
            .onChange(of: state.records) { _, records in store.save(records, context: context) }
            .onChange(of: collections) { old, new in
                // Only a saved surface's lists change by editing; while one streams in, its fields
                // are still arriving.
                guard let surfaceID else { return }
                var records = RecordMigration.migrate(state.records, from: old, to: new)
                seed(new, into: &records, surfaceID: surfaceID)
                if records != state.records { state.records = records }
            }
    }

    private func load() {
        guard let surfaceID else { return }
        var records = store.load(surfaceID, context: context)
        // Anything added before the surface was saved.
        for (name, entries) in state.records {
            let known = Set(records[name, default: []].map(\.id))
            records[name, default: []] += entries.filter { !known.contains($0.id) }
        }
        seed(collections, into: &records, surfaceID: surfaceID)
        state.records = records
    }

    /// Starters are copied in once per list, so a list the user has emptied stays empty.
    private func seed(_ collections: [RecordCollection], into records: inout [String: [Record]], surfaceID: UUID) {
        for collection in collections where !RecordStore.wasSeeded(collection.name, of: surfaceID) {
            if records[collection.name, default: []].isEmpty, !collection.starters.isEmpty {
                records[collection.name] = collection.starterRecords()
            }
            RecordStore.markSeeded(collection.name, of: surfaceID)
        }
    }
}

/// Reads and writes one surface's entries, writing only what changed.
@MainActor
final class RecordStore {
    private var surfaceID: UUID?
    private var stored: [UUID: StoredRecord] = [:]
    /// What each stored entry holds, so finding what changed doesn't mean reading them all back.
    private var written: [UUID: Written] = [:]
    private var pendingSave: Task<Void, Never>?

    private struct Written: Equatable {
        let collection: String
        let record: Record
    }

    func load(_ surfaceID: UUID, context: ModelContext) -> [String: [Record]] {
        self.surfaceID = surfaceID
        let found = (try? context.fetch(FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.surfaceID == surfaceID }))) ?? []
        stored = Dictionary(found.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        written = stored.mapValues { Written(collection: $0.collection, record: $0.record) }
        return Dictionary(grouping: written.values, by: \.collection).mapValues { $0.map(\.record) }
    }

    func save(_ records: [String: [Record]], context: ModelContext) {
        guard let surfaceID else { return }
        var seen: Set<UUID> = []
        for (collection, entries) in records {
            for record in entries {
                seen.insert(record.id)
                let now = Written(collection: collection, record: record)
                guard written[record.id] != now else { continue }
                if let existing = stored[record.id] {
                    existing.update(collection: collection, record: record)
                } else {
                    let new = StoredRecord(surfaceID: surfaceID, collection: collection, record: record)
                    context.insert(new)
                    stored[record.id] = new
                }
                written[record.id] = now
            }
        }
        for (id, gone) in stored where !seen.contains(id) {
            context.delete(gone)
            stored[id] = nil
            written[id] = nil
        }
        // Typing changes an entry on every key, so the store is written once things settle.
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            try? context.save()
        }
    }

    /// When a surface goes, the user's entries in it go too.
    static func deleteAll(of surfaceID: UUID, in context: ModelContext) {
        try? context.delete(model: StoredRecord.self, where: #Predicate { $0.surfaceID == surfaceID })
        UserDefaults.standard.set(seeded.filter { !$0.hasPrefix(surfaceID.uuidString) }, forKey: seededKey)
    }

    private static let seededKey = "seededLists"
    private static var seeded: [String] { UserDefaults.standard.stringArray(forKey: seededKey) ?? [] }

    static func wasSeeded(_ collection: String, of surfaceID: UUID) -> Bool {
        seeded.contains("\(surfaceID.uuidString)/\(collection)")
    }

    static func markSeeded(_ collection: String, of surfaceID: UUID) {
        UserDefaults.standard.set(seeded + ["\(surfaceID.uuidString)/\(collection)"], forKey: seededKey)
    }
}
