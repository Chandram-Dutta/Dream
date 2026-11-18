import Foundation
import SwiftData

// The account's changes, made on this iPhone. Writes go through sync's own context, marked with
// `Sync.author`, so they're never mistaken for the user's and sent back.

extension Sync {
    enum Outcome {
        case done
        /// It has to wait: a deletion of a page that's on screen.
        case later
    }

    /// Makes one change from the account here. Throws NewerFormat for an item from a later
    /// version of Dream, and when a photo it needs can't be fetched yet.
    func apply(_ item: SyncItem, in context: ModelContext, client: SyncClient) async throws -> Outcome {
        guard let key = item.key else { return .done }
        switch key.kind {
        case .surface: return try await applyPage(item, in: context, client: client)
        case .record: return try applyEntry(item, in: context)
        case .fact: return try applyFact(item, in: context)
        case .connection: return try await applyConnection(item)
        case .setting: return try applySetting(item)
        }
    }

    // MARK: - Pages

    private func applyPage(_ item: SyncItem, in context: ModelContext, client: SyncClient) async throws -> Outcome {
        guard let id = UUID(uuidString: item.id) else { return .done }
        let existing = Self.page(item.id, in: context)
        if item.deleted {
            if PageHold.isHeld(id) { return .later }
            let entries = try context.fetch(FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.surfaceID == id }))
            ledger.pageDeleted(item.id, at: item.updatedAt, entries: entries.map(\.recordID.uuidString))
            for entry in entries { context.delete(entry) }
            if let existing { context.delete(existing) }
            Self.forgetSeeded(item.id)
            ledger.prints["seeded/\(item.id)"] = nil
            touched.insert(id)
            return .done
        }
        let page = try SurfacePayload.read(item)
        let saved: SavedSurface
        if let existing {
            saved = existing
        } else {
            saved = SavedSurface(intent: page.intent, surface: .empty, modelName: page.modelName, log: [])
            saved.id = id
            context.insert(saved)
        }
        // Only what differs is written, so a page on screen is disturbed as little as can be.
        Self.set(saved, \.intent, page.intent)
        Self.set(saved, \.createdAt, page.createdAt)
        Self.set(saved, \.lastOpenedAt, page.lastOpenedAt)
        Self.set(saved, \.openCount, page.openCount)
        Self.set(saved, \.modelName, page.modelName)
        Self.set(saved, \.history, page.history)
        Self.set(saved, \.editRequests, page.editRequests)
        Self.set(saved, \.generationLog, page.generationLog)
        // As stored, not through `surface`, which would date it now.
        if let template = try? JSONEncoder().encode(page.template), (try? JSONDecoder().decode(JSONValue.self, from: saved.templateData)) != page.template {
            saved.templateData = template
        }
        Self.set(saved, \.values, page.values)
        Self.set(saved, \.sharedFrom, page.sharedFrom)
        Self.set(saved, \.isStarred, page.starred)
        Self.set(saved, \.parentID, page.parent.flatMap(UUID.init(uuidString:)))
        Self.set(saved, \.found, page.found)
        Self.set(saved, \.subjects, page.subjects)
        Self.set(saved, \.updatedAt, page.updatedAt)
        // Starters added anywhere count as added here. If this iPhone added some the account
        // doesn't know of, the comparison notices and sends the page back with them.
        for list in page.seeded where !RecordStore.wasSeeded(list, of: id) { RecordStore.markSeeded(list, of: id) }
        ledger.prints["seeded/\(item.id)"] = page.seeded.sorted().joined(separator: "\n")
        if let photo = page.photo, ledger.photos[item.id]?.id != photo, let data = try await client.photo(photo) {
            saved.photoData = data
            ledger.photos[item.id] = SyncLedger.Photo(id: photo, digest: Self.digest(data))
        }
        return .done
    }

    /// Sets a stored property only when it's different, so nothing is marked changed for nothing.
    static func set<Model: AnyObject, Value: Equatable>(_ model: Model, _ keyPath: ReferenceWritableKeyPath<Model, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }

    /// RecordStore keeps which lists' starters were added as "<page>/<list>".
    static func forgetSeeded(_ page: String) {
        let kept = (UserDefaults.standard.stringArray(forKey: "seededLists") ?? []).filter { !$0.hasPrefix(page + "/") }
        UserDefaults.standard.set(kept, forKey: "seededLists")
    }

    // MARK: - List entries

    private func applyEntry(_ item: SyncItem, in context: ModelContext) throws -> Outcome {
        guard let id = UUID(uuidString: item.id) else { return .done }
        var descriptor = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.recordID == id })
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        guard let page = item.parent.flatMap(UUID.init(uuidString:)) ?? existing?.surfaceID else { return .done }
        if item.deleted {
            // The list on screen still shows it.
            if PageHold.isHeld(page) { return .later }
            if let existing { context.delete(existing) }
            touched.insert(page)
            return .done
        }
        let entry = try RecordPayload.read(item)
        let record = Record(id: id, values: entry.values, order: entry.order, created: entry.createdAt)
        let stored: StoredRecord
        if let existing {
            stored = existing
            Self.set(stored, \.surfaceID, page)
            if stored.collection != entry.collection || stored.record != record { stored.update(collection: entry.collection, record: record) }
        } else {
            stored = StoredRecord(surfaceID: page, collection: entry.collection, record: record)
            context.insert(stored)
        }
        Self.set(stored, \.createdAt, entry.createdAt)
        Self.set(stored, \.updatedAt, entry.updatedAt)
        touched.insert(page)
        return .done
    }

    // MARK: - Memory

    private func applyFact(_ item: SyncItem, in context: ModelContext) throws -> Outcome {
        guard let id = UUID(uuidString: item.id) else { return .done }
        var descriptor = FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if item.deleted {
            if let existing { context.delete(existing) }
            return .done
        }
        let payload = try FactPayload.read(item)
        let fact: MemoryFact
        if let existing {
            fact = existing
        } else {
            fact = MemoryFact(topic: payload.topic, text: payload.text, source: .said, isConfirmed: payload.confirmed)
            fact.id = id
            context.insert(fact)
        }
        Self.set(fact, \.topic, payload.topic)
        Self.set(fact, \.text, payload.text)
        Self.set(fact, \.sourceName, payload.source)
        Self.set(fact, \.isConfirmed, payload.confirmed)
        Self.set(fact, \.request, payload.request)
        Self.set(fact, \.createdAt, payload.createdAt)
        Self.set(fact, \.updatedAt, payload.updatedAt)
        Self.set(fact, \.lastUsedAt, payload.lastUsedAt)
        return .done
    }

    // MARK: - Connections

    private func applyConnection(_ item: SyncItem) async throws -> Outcome {
        guard let id = UUID(uuidString: item.id) else { return .done }
        let store = ConnectionStore.shared
        if item.deleted {
            // Noted first, so removing it isn't taken for a change to send.
            ledger.prints[item.key!.description] = nil
            if store.connection(id) != nil { await store.remove(id) }
            return .done
        }
        let incoming = try ConnectionPayload.read(item).connection(id: id)
        var merged = store.connections
        if let index = merged.firstIndex(where: { $0.id == id }) {
            merged[index] = Self.combine(merged[index], with: incoming)
        } else if let twin = merged.firstIndex(where: { $0.url == incoming.url }) {
            // The same service, added on two devices. Every device keeps the one with the
            // smaller id, so they agree without talking; the sign-in here moves to it.
            let mine = merged[twin]
            guard incoming.id.uuidString < mine.id.uuidString else {
                ledger.changed(SyncKey(.connection, incoming.id.uuidString), deleted: true, at: stamp)
                ledger.changed(SyncKey(.connection, mine.id.uuidString), deleted: false, at: stamp)
                return .done
            }
            if let credentials = SignIn.Credentials.load(for: mine.id) {
                credentials.save(for: incoming.id)
                SignIn.Credentials.remove(for: mine.id)
            }
            var kept = Self.combine(mine, with: incoming)
            kept.id = incoming.id
            merged[twin] = kept
            ledger.prints[SyncKey(.connection, mine.id.uuidString).description] = nil
            ledger.changed(SyncKey(.connection, mine.id.uuidString), deleted: true, at: stamp)
            await ConnectionSessions.shared.close(mine.id)
        } else {
            merged.append(incoming)
        }
        for connection in merged { ledger.prints[SyncKey(.connection, connection.id.uuidString).description] = Self.print(connection) }
        store.replaceConnections(merged)
        return .done
    }

    /// A connection as the account has it, onto the one here: the user's choices come from the
    /// account; the tools stay as this iPhone last listed them, if it has.
    static func combine(_ local: Connection, with remote: Connection) -> Connection {
        var merged = local
        merged.url = remote.url
        merged.name = remote.name
        merged.isOn = remote.isOn
        merged.alwaysLooksUp = remote.alwaysLooksUp
        guard !local.tools.isEmpty else {
            merged.tools = remote.tools
            return merged
        }
        let theirs = Dictionary(remote.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        merged.tools = local.tools.map { tool in
            guard let other = theirs[tool.name] else { return tool }
            var tool = tool
            tool.isOn = other.isOn
            // An "Always" holds for the tool as it was described when it was given.
            tool.alwaysAllowed = other.alwaysAllowed && other.readOnlyHint == tool.readOnlyHint && other.destructiveHint == tool.destructiveHint
            return tool
        }
        return merged
    }

    // MARK: - Settings

    private func applySetting(_ item: SyncItem) throws -> Outcome {
        guard !item.deleted, let setting = SyncedSetting(rawValue: item.id) else { return .done }
        let value = try SettingPayload.read(item).value
        // The account's value is what's known; if what's here adds to it, that's sent back.
        ledger.prints[item.key!.description] = value.jsonString
        setting.take(value)
        return .done
    }
}
