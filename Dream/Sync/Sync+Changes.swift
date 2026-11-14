import CryptoKit
import Foundation
import SwiftData

// Changes made on this iPhone, and what goes to the account for them.

extension Sync {
    /// Queues every change made here since last time: from SwiftData's history for pages, list
    /// entries and memory, and by comparison for connections, settings and lists' starters.
    func collect(in context: ModelContext) {
        readHistory(in: context)
        compare(in: context, queue: true)
    }

    // MARK: - SwiftData's history

    private func readHistory(in context: ModelContext) {
        let (changes, token) = SyncHistory.changes(after: ledger.historyToken, in: context, ignoring: Self.author)
        for change in changes {
            ledger.changed(change.key, parent: change.parent, deleted: change.deleted, at: ledger.serverTime(Self.millis(change.at)))
        }
        ledger.historyToken = token
    }

    /// Moves past everything SwiftData's history holds now, without sending it. Only at a fresh
    /// start, and history is pruned after, so reading it all stays small.
    func skipHistory(in context: ModelContext) {
        ledger.historyToken = SyncHistory.latest(after: ledger.historyToken, in: context)
    }

    func pruneHistory(in context: ModelContext) {
        SyncHistory.prune(before: ledger.historyToken, in: context)
    }

    // MARK: - What isn't in SwiftData

    /// Compares connections, synced settings and lists' starters with how they were last seen,
    /// and queues what changed. With `queue` off, it only notes how they are now.
    func compare(in context: ModelContext, queue: Bool) {
        let at = stamp
        var seen: Set<String> = []
        func check(_ key: SyncKey, _ print: String) {
            let name = key.description
            seen.insert(name)
            guard ledger.prints[name] != print else { return }
            ledger.prints[name] = print
            if queue { ledger.changed(key, deleted: false, at: at) }
        }
        for connection in ConnectionStore.shared.connections {
            check(SyncKey(.connection, connection.id.uuidString), Self.print(connection))
        }
        for setting in SyncedSetting.allCases {
            if let value = setting.value { check(SyncKey(.setting, setting.rawValue), value.jsonString) }
        }
        // A page's starters travel with the page, so a list emptied on one device isn't refilled on another.
        for (page, lists) in Self.seededLists() {
            let name = "seeded/\(page)"
            seen.insert(name)
            let print = lists.sorted().joined(separator: "\n")
            guard ledger.prints[name] != print else { continue }
            ledger.prints[name] = print
            if queue, Self.page(page, in: context) != nil { ledger.changed(SyncKey(.surface, page), deleted: false, at: at) }
        }
        for name in ledger.prints.keys where !seen.contains(name) {
            ledger.prints[name] = nil
            if queue, let key = SyncKey(name), key.kind == .connection { ledger.changed(key, deleted: true, at: at) }
        }
    }

    /// What about a connection travels: enough to notice when the user changes it.
    static func print(_ connection: Connection) -> String {
        let tools = connection.tools.map { "\($0.name) \($0.isOn) \($0.alwaysAllowed) \(String(describing: $0.readOnlyHint)) \(String(describing: $0.destructiveHint))" }
        return ([connection.url.absoluteString, connection.name, "\(connection.isOn)", "\(connection.alwaysLooksUp)"] + tools).joined(separator: "\n")
    }

    /// Which lists' starters were added, by page id (RecordStore keeps them as "<page>/<list>").
    static func seededLists() -> [String: [String]] {
        var lists: [String: [String]] = [:]
        for entry in UserDefaults.standard.stringArray(forKey: "seededLists") ?? [] {
            let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { lists[parts[0], default: []].append(parts[1]) }
        }
        return lists
    }

    static func page(_ id: String, in context: ModelContext) -> SavedSurface? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var descriptor = FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - What goes

    /// Just under the server's limit for one item.
    static let maxItem = 250_000

    /// The item for a queued change: the latest version of what's here, or its tombstone if it's
    /// gone. Nil when it can't go, like a page too large to carry; it stays here.
    func outgoing(_ pending: SyncLedger.Pending, in context: ModelContext, client: SyncClient) async throws -> SyncItem? {
        let key = pending.key
        let gone = SyncItem.deletion(key, parent: pending.parent, at: pending.stamp)
        if pending.deleted { return gone }
        switch key.kind {
        case .surface:
            guard let saved = Self.page(key.id, in: context) else { return gone }
            var page = SurfacePayload(saved, seeded: Self.seededLists()[key.id] ?? [])
            page.photo = try await photo(of: saved, client: client)
            // The generation log is how it was built, not the user's words, so it's what gives way.
            for lines in [Int.max, 200, 40, 0] {
                let item = try page.trimmed(keepingLog: lines).item(id: key.id, at: pending.stamp)
                if item.size <= Self.maxItem { return item }
            }
            return nil
        case .record:
            guard let id = UUID(uuidString: key.id) else { return nil }
            var descriptor = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.recordID == id })
            descriptor.fetchLimit = 1
            guard let stored = try context.fetch(descriptor).first else { return gone }
            let item = try RecordPayload(stored).item(id: key.id, parent: stored.surfaceID.uuidString, at: pending.stamp)
            return item.size <= Self.maxItem ? item : nil
        case .fact:
            guard let id = UUID(uuidString: key.id) else { return nil }
            var descriptor = FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let fact = try context.fetch(descriptor).first else { return gone }
            let item = try FactPayload(fact).item(id: key.id, at: pending.stamp)
            return item.size <= Self.maxItem ? item : nil
        case .connection:
            guard let id = UUID(uuidString: key.id), let connection = ConnectionStore.shared.connection(id) else { return gone }
            let payload = ConnectionPayload(connection)
            let item = try payload.item(id: key.id, at: pending.stamp)
            if item.size <= Self.maxItem { return item }
            let light = try payload.withoutSchemas.item(id: key.id, at: pending.stamp)
            return light.size <= Self.maxItem ? light : nil
        case .setting:
            guard let setting = SyncedSetting(rawValue: key.id), let value = setting.value else { return nil }
            return try SettingPayload(value: value).item(id: key.id, at: pending.stamp)
        }
    }

    /// The page's photo on the server, sent first if the server doesn't have it yet.
    private func photo(of saved: SavedSurface, client: SyncClient) async throws -> String? {
        guard let data = saved.photoData, !data.isEmpty, data.count <= SyncClient.maxPhoto else { return nil }
        let page = saved.id.uuidString
        let digest = Self.digest(data)
        if let sent = ledger.photos[page], sent.digest == digest { return sent.id }
        let id = UUID().uuidString
        try await client.upload(photo: data, id: id)
        ledger.photos[page] = SyncLedger.Photo(id: id, digest: digest)
        return id
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Payloads from what's stored

extension SurfacePayload {
    init(_ saved: SavedSurface, seeded: [String]) {
        self.init()
        intent = saved.intent
        createdAt = saved.createdAt
        updatedAt = saved.updatedAt
        lastOpenedAt = saved.lastOpenedAt
        openCount = saved.openCount
        modelName = saved.modelName
        history = saved.history
        editRequests = saved.editRequests
        generationLog = saved.generationLog
        template = (try? JSONDecoder().decode(JSONValue.self, from: saved.templateData)) ?? .object([:])
        values = saved.values.filter { $0.value.isFinite }
        sharedFrom = saved.sharedFrom
        self.seeded = seeded
        starred = saved.isStarred
        parent = saved.parentID?.uuidString
        found = saved.found
        subjects = saved.subjects
    }
}

extension RecordPayload {
    init(_ stored: StoredRecord) {
        self.init(collection: stored.collection, values: stored.record.values, order: stored.order, createdAt: stored.createdAt, updatedAt: stored.updatedAt)
    }
}

extension FactPayload {
    init(_ fact: MemoryFact) {
        self.init(topic: fact.topic, text: fact.text, source: fact.sourceName, confirmed: fact.isConfirmed, request: fact.request,
                  createdAt: fact.createdAt, updatedAt: fact.updatedAt, lastUsedAt: fact.lastUsedAt)
    }
}
