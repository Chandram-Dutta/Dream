import Foundation
import SwiftData

// Checks sync's merge rules without the app (Dream/Sync/SyncLedger.swift): two devices of one
// person, and a stand-in for the server that keeps the Worker's rules (Server/src/sync.ts).
// Changes made offline on both, deletions, a slow clock, ties, a change made while a batch is on
// its way, pages of changes, a page deleted under an entry being edited, and payloads written by
// other versions. It also reads changes from SwiftData's history in a real store with the app's
// models, the way the app does. Build and run with Tools/sync.sh.
//
// With DREAM_SYNC_URL (say http://127.0.0.1:8787, from `npx wrangler dev` with DEV_LOGIN=1 in
// .dev.vars), the same two devices then sync through the real Worker, as one test person.

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

// MARK: - Time

/// The true time, which the server's clock keeps. Devices' clocks may be off from it.
nonisolated(unsafe) var simulated: Int64 = 1_793_000_000_000
nonisolated(unsafe) var live = false

func trueNow() -> Int64 { live ? Int64(Date().timeIntervalSince1970 * 1000) : simulated }

/// Lets time pass: a little on the stand-in, and for real (a few ms) on the real server.
func pass(_ ms: Int64 = 1_000) async {
    // Real clocks are set by the server's to within a few milliseconds, so real time passes more.
    if live { try? await Task.sleep(for: .milliseconds(50)) } else { simulated += ms }
}

// MARK: - Servers

struct Taken {
    var stale: [SyncItem]
    var refused: Set<SyncKey>
    var now: Int64
}

struct Page {
    var items: [SyncItem]
    var cursor: String
    var more: Bool
    var now: Int64
}

protocol Backend {
    func send(_ items: [SyncItem]) async throws -> Taken
    func changes(since cursor: String?, limit: Int) async throws -> Page
}

/// The Worker's rules: the latest change wins and a tie keeps what's stored, each batch takes the
/// next change number, and a deleted page takes its entries unless one changed after it.
final class StandIn: Backend {
    struct Row {
        var item: SyncItem
        var change: Int
    }

    var rows: [String: Row] = [:]
    var counter = 0

    func send(_ items: [SyncItem]) async throws -> Taken {
        counter += 1
        var stale: [SyncItem] = []
        for item in items {
            let name = "\(item.kind)/\(item.id)"
            if let old = rows[name], item.updatedAt <= old.item.updatedAt {
                stale.append(old.item)
                continue
            }
            var stored = item
            if item.deleted { stored.body = nil }
            rows[name] = Row(item: stored, change: counter)
            guard item.kind == "surface", item.deleted else { continue }
            for (entry, row) in rows where row.item.kind == "record" && row.item.parent == item.id && !row.item.deleted && row.item.updatedAt < item.updatedAt {
                var gone = row.item
                gone.deleted = true
                gone.body = nil
                gone.updatedAt = item.updatedAt
                rows[entry] = Row(item: gone, change: counter)
            }
        }
        return Taken(stale: stale, refused: [], now: trueNow())
    }

    func changes(since cursor: String?, limit: Int) async throws -> Page {
        let ordered = rows.sorted { ($0.value.change, $0.key) < ($1.value.change, $1.key) }
        let start = cursor.flatMap { mark in ordered.firstIndex { "\($0.value.change)|\($0.key)" == mark }.map { $0 + 1 } } ?? 0
        let page = Array(ordered[start...].prefix(limit))
        let next = page.last.map { "\($0.value.change)|\($0.key)" } ?? cursor ?? ""
        return Page(items: page.map(\.value.item), cursor: next, more: start + page.count < ordered.count, now: trueNow())
    }
}

/// The real Worker, through the app's own client.
struct Live: Backend {
    let client: SyncClient

    func send(_ items: [SyncItem]) async throws -> Taken {
        let taken = try await client.send(items)
        let refused = taken.refused.compactMap { refusal in SyncKind(rawValue: refusal.kind).map { SyncKey($0, refusal.id) } }
        return Taken(stale: taken.stale, refused: Set(refused), now: taken.now)
    }

    func changes(since cursor: String?, limit: Int) async throws -> Page {
        let page = try await client.changes(since: cursor, limit: limit)
        return Page(items: page.items, cursor: page.cursor, more: page.more, now: page.now)
    }
}

// MARK: - Devices

/// One phone: what it holds, and its ledger. Applying works the way the app's does.
final class Device {
    let name: String
    let backend: Backend
    /// How far this phone's clock is off the true time.
    var offset: Int64
    var ledger = SyncLedger()
    var items: [String: SyncItem] = [:]
    /// Changes from the server made here, to see that nothing is made twice.
    var applied = 0
    /// Pages on screen, whose deletion waits.
    var open: Set<String> = []

    init(_ name: String, backend: Backend, offset: Int64 = 0) {
        self.name = name
        self.backend = backend
        self.offset = offset
    }

    private var stamp: Int64 { ledger.serverTime(trueNow() + offset) }

    func edit(_ key: SyncKey, _ text: String, parent: String? = nil) {
        ledger.changed(key, parent: parent, deleted: false, at: stamp)
        items[key.description] = SyncItem(key, parent: parent, updatedAt: 0, body: .object(["text": .string(text)]))
    }

    func delete(_ key: SyncKey) {
        let parent = items[key.description]?.parent
        ledger.changed(key, parent: parent, deleted: true, at: stamp)
        items[key.description] = nil
        // Deleting a page here deletes its entries here, as the app does.
        if key.kind == .surface {
            for (name, item) in items where item.parent == key.id {
                ledger.changed(SyncKey(.record, item.id), parent: key.id, deleted: true, at: self.stamp)
                items[name] = nil
            }
        }
    }

    func text(_ key: SyncKey) -> String? { items[key.description]?.body?["text"]?.string }

    /// What would go to the server for the queued changes.
    func outgoing(_ batch: [SyncLedger.Pending]) -> [SyncItem] {
        batch.map { pending in
            pending.deleted || items[pending.key.description] == nil
                ? .deletion(pending.key, parent: pending.parent, at: pending.stamp)
                : SyncItem(pending.key, parent: pending.parent, updatedAt: pending.stamp, body: items[pending.key.description]?.body)
        }
    }

    func push() async throws {
        while true {
            let batch = ledger.due(limit: 4)
            guard !batch.isEmpty else { return }
            let taken = try await backend.send(outgoing(batch))
            ledger.heard(serverNow: taken.now, at: trueNow() + offset)
            ledger.sent(batch, stale: Set(taken.stale.compactMap(\.key)), refused: taken.refused)
            for item in taken.stale { receive(item) }
        }
    }

    func pull(limit: Int = 3) async throws {
        var more = true
        while more {
            let page = try await backend.changes(since: ledger.cursor, limit: limit)
            ledger.heard(serverNow: page.now, at: trueNow() + offset)
            for item in page.items { receive(item) }
            ledger.cursor = page.cursor
            more = page.more
        }
        for item in ledger.takeWaiting() { make(item) }
    }

    /// As the app does: send, read, then send anything reading queued.
    func sync() async throws {
        try await push()
        try await pull()
        try await push()
    }

    func receive(_ item: SyncItem) {
        if ledger.receive(item) == .apply { make(item) }
    }

    private func make(_ item: SyncItem) {
        guard let key = item.key else { return }
        let held = key.kind == .surface ? key.id : item.parent ?? ""
        if item.deleted, open.contains(held) {
            ledger.wait(item)
            return
        }
        applied += 1
        guard item.deleted else {
            items[key.description] = item
            return
        }
        items[key.description] = nil
        if key.kind == .surface {
            let entries = items.values.filter { $0.parent == key.id }.map(\.id)
            ledger.pageDeleted(key.id, at: item.updatedAt, entries: entries)
            for id in entries { items[SyncKey(.record, id).description] = nil }
        }
    }
}

/// Whether two phones hold the same items, with the same content.
func same(_ a: Device, _ b: Device) -> Bool {
    Set(a.items.keys) == Set(b.items.keys) && a.items.keys.allSatisfy { a.items[$0]?.body == b.items[$0]?.body }
}

// MARK: - The rules

func checkRules(_ makeBackend: () async throws -> (Backend, Backend)) async throws {
    let (backendA, backendB) = try await makeBackend()
    let a = Device("A", backend: backendA)
    let b = Device("B", backend: backendB)
    let fact = SyncKey(.fact, UUID().uuidString)

    print("Sending and reading back")
    a.edit(fact, "Pune")
    try await a.sync()
    try await b.sync()
    expect(b.text(fact) == "Pune", "a change made on one phone reaches the other")
    let before = a.applied
    try await a.sync()
    expect(a.applied == before && a.ledger.outbox.isEmpty, "the phone that made it doesn't make it again when it comes back")

    print("Offline on both: the latest change wins, whoever syncs first")
    await pass()
    a.edit(fact, "Mumbai")
    await pass()
    b.edit(fact, "Delhi")
    try await a.sync()
    try await b.sync()
    try await a.sync()
    expect(a.text(fact) == "Delhi" && b.text(fact) == "Delhi", "the later change, made on B, wins on both")
    await pass()
    b.edit(fact, "Goa")
    await pass()
    a.edit(fact, "Chennai")
    try await b.sync()
    try await a.sync()
    try await b.sync()
    expect(a.text(fact) == "Chennai" && b.text(fact) == "Chennai", "and the other way round")

    print("Deleting")
    let gone = SyncKey(.fact, UUID().uuidString)
    a.edit(gone, "Vegetarian")
    try await a.sync()
    try await b.sync()
    await pass()
    b.edit(gone, "Vegan")
    await pass()
    a.delete(gone)
    try await b.sync()
    try await a.sync()
    try await b.sync()
    expect(a.text(gone) == nil && b.text(gone) == nil, "a deletion after an edit wins on both")
    let back = SyncKey(.fact, UUID().uuidString)
    a.edit(back, "Two cats")
    try await a.sync()
    try await b.sync()
    await pass()
    a.delete(back)
    await pass()
    b.edit(back, "Three cats")
    try await a.sync()
    try await b.sync()
    try await a.sync()
    expect(a.text(back) == "Three cats" && b.text(back) == "Three cats", "an edit after a deletion brings it back, on both")

    print("A slow clock")
    let slow = Device("Slow", backend: backendB, offset: -3_600_000)
    try await slow.sync()
    slow.ledger.skew = 0  // As if it hadn't heard the server's clock.
    let clocked = SyncKey(.fact, UUID().uuidString)
    a.edit(clocked, "Before")
    try await a.sync()
    try await slow.pull()
    slow.ledger.skew = 0
    await pass()
    slow.edit(clocked, "After, an hour slow")
    try await slow.sync()
    try await a.sync()
    expect(a.text(clocked) == "After, an hour slow", "a change made after seeing a version beats it, even on a clock an hour slow")
    try await slow.sync()
    expect(slow.ledger.skew != 0 || live, "and the phone learns the server's clock")

    // Only the stand-in can make two phones' clocks agree to the millisecond.
    if !live {
        print("A tie")
        let tied = SyncKey(.fact, UUID().uuidString)
        let c = Device("C", backend: backendA)
        let d = Device("D", backend: backendB)
        c.edit(tied, "From C")
        d.edit(tied, "From D")
        try await c.sync()
        try await d.sync()
        try await c.sync()
        expect(c.text(tied) == "From C" && d.text(tied) == "From C", "the same time keeps the one the server had first, on both")
    }

    print("A change made while a batch is on its way")
    let busy = SyncKey(.fact, UUID().uuidString)
    a.edit(busy, "First")
    let batch = a.ledger.due(limit: 10)
    let taken = try await a.backend.send(a.outgoing(batch))
    await pass()
    a.edit(busy, "Second")
    a.ledger.sent(batch, stale: Set(taken.stale.compactMap(\.key)), refused: taken.refused)
    expect(a.ledger.outbox[busy.description] != nil, "the newer change is still queued")
    try await a.sync()
    try await b.sync()
    expect(b.text(busy) == "Second", "and arrives")

    print("Pages of changes")
    let many = (0..<10).map { _ in SyncKey(.fact, UUID().uuidString) }
    for (index, key) in many.enumerated() { a.edit(key, "Fact \(index)") }
    try await a.sync()
    let applied = b.applied
    try await b.pull(limit: 3)
    expect(b.applied - applied == 10 && many.allSatisfy { b.text($0) != nil }, "ten changes read three at a time arrive once each")

    print("A page deleted under an entry being edited")
    let page = SyncKey(.surface, UUID().uuidString)
    let milk = SyncKey(.record, UUID().uuidString)
    let eggs = SyncKey(.record, UUID().uuidString)
    a.edit(page, "Groceries")
    a.edit(milk, "Milk", parent: page.id)
    a.edit(eggs, "Eggs", parent: page.id)
    try await a.sync()
    try await b.sync()
    expect(b.text(milk) == "Milk", "the page and its entries reach B")
    await pass()
    a.delete(page)
    await pass()
    b.edit(milk, "Oat milk", parent: page.id)
    try await a.sync()
    try await b.sync()
    try await a.sync()
    expect(a.text(page) == nil && b.text(page) == nil && b.text(milk) == nil && a.text(milk) == nil && b.text(eggs) == nil, "the page and every entry go on both, even one edited after it was deleted")

    print("A deletion waits for a page that's open")
    let shown = SyncKey(.surface, UUID().uuidString)
    a.edit(shown, "Budget")
    try await a.sync()
    try await b.sync()
    b.open.insert(shown.id)
    a.delete(shown)
    try await a.sync()
    try await b.sync()
    expect(b.text(shown) == "Budget" && b.ledger.waiting[shown.description] != nil, "while it's on B's screen, it stays")
    b.open.remove(shown.id)
    try await b.sync()
    expect(b.text(shown) == nil && b.ledger.waiting.isEmpty, "once it's closed, it goes")
    try await a.sync()
    try await b.sync()
    expect(same(a, b) && a.items.count > 10, "and in the end both phones hold the same \(a.items.count) items")
}

// MARK: - Formats

func checkFormats() throws {
    print("Formats")
    let older = #"{"intent":"split a bill","template":{"title":"Split a bill","ratio":0.25,"blocks":[]},"values":{"bill":240},"history":[{"kind":"asked","text":"split a bill","at":"2026-10-26T10:00:00.123Z","answers":[]},{"kind":"sung","text":"a later kind"}],"futureField":true}"#
    let item = SyncItem(SyncKey(.surface, "P"), updatedAt: 1, body: try JSONDecoder().decode(JSONValue.self, from: Data(older.utf8)))
    let payload = try SurfacePayload.read(item)
    expect(payload.intent == "split a bill" && payload.values["bill"] == 240 && payload.openCount == 0 && payload.seeded.isEmpty, "a page with fields missing and one unknown still reads")
    expect(payload.template["ratio"]?.number == 0.25 && payload.template["title"]?.string == "Split a bill", "its template comes through as written")
    let asked = try Date("2026-10-26T10:00:00Z", strategy: .iso8601).addingTimeInterval(0.123)
    expect(payload.history.first?.kind == .asked && abs(payload.history.first!.at.timeIntervalSince(asked)) < 0.0005, "its conversation, with times to the millisecond")
    expect(payload.history.last?.kind == nil && payload.history.last?.kindName == "sung", "a kind of turn from a later version is kept as written")
    let again = try SurfacePayload.read(try payload.item(id: "P", at: 2))
    expect(again.history == payload.history && again.template == payload.template, "and survives a trip through this version")
    var newer = item
    newer.format = SyncFormat.current + 1
    expect((try? SurfacePayload.read(newer)) == nil, "a format from a later version waits")
    var ledger = SyncLedger()
    var unknown = item
    unknown.kind = "hologram"
    expect(ledger.receive(unknown) == .skip, "a kind this version doesn't know is passed over")
    let record = try RecordPayload(collection: "groceries", values: ["name": .text("Milk"), "done": .number(1)], order: 2, createdAt: Date(timeIntervalSince1970: 1_793_000_000.5), updatedAt: .now).item(id: "R", parent: "P", at: 3)
    let read = try RecordPayload.read(record)
    expect(read.values["name"] == .text("Milk") && read.values["done"] == .number(1) && read.createdAt.timeIntervalSince1970 == 1_793_000_000.5 && record.parent == "P", "an entry, with its page")
    let refused = SyncLedger.Pending(kind: .fact, id: "F", stamp: 5, deleted: false)
    ledger.outbox["fact/F"] = refused
    ledger.sent([refused], stale: [], refused: [refused.key])
    expect(ledger.outbox.isEmpty && ledger.known["fact/F"] == nil, "a change the server refuses isn't sent again")
    let saved = try JSONEncoder().encode(ledger)
    expect((try? JSONDecoder().decode(SyncLedger.self, from: saved)) == ledger && (try? JSONDecoder().decode(SyncLedger.self, from: Data("{}".utf8))) != nil, "the ledger saves, and an empty one loads")
}

// MARK: - SwiftData's history

/// What the app reads changes made on the phone from (Dream/Sync/SyncHistory.swift), against a
/// real store with the app's own models.
@MainActor
func checkHistory() throws {
    print("SwiftData's history")
    let folder = FileManager.default.temporaryDirectory.appending(path: "dream-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let container = try ModelContainer(for: SavedSurface.self, MemoryFact.self, StoredRecord.self, configurations: ModelConfiguration("Check", url: folder.appending(path: "check.store")))
    let user = ModelContext(container)
    var saves: [String?] = []
    let watcher = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
        saves.append((note.object as? ModelContext)?.author)
    }
    defer { NotificationCenter.default.removeObserver(watcher) }
    let read = { (token: Data?) in SyncHistory.changes(after: token, in: ModelContext(container), ignoring: "sync") }

    let page = SavedSurface(intent: "groceries", surface: .empty, modelName: "", log: [])
    let fact = MemoryFact(topic: "Home city", text: "Pune", source: .said, isConfirmed: true)
    let milk = Record(id: UUID(), values: ["name": .text("Milk")], order: 0, created: .now)
    user.insert(page)
    user.insert(fact)
    user.insert(StoredRecord(surfaceID: page.id, collection: "groceries", record: milk))
    try user.save()
    var (changes, token) = read(nil)
    let keys = [SyncKey(.surface, page.id.uuidString), SyncKey(.fact, fact.id.uuidString), SyncKey(.record, milk.id.uuidString)]
    expect(Set(changes.map(\.key)) == Set(keys) && changes.allSatisfy { !$0.deleted }, "new pages, entries and facts are noticed, by their own ids")
    expect(saves.count == 1 && saves[0] == nil, "and saving says so, from a context without an author")

    fact.text = "Mumbai"
    try user.save()
    (changes, token) = read(token)
    expect(changes.map(\.key) == [keys[1]] && changes[0].deleted == false, "a change is noticed, and only it")

    page.openCount += 1
    page.lastOpenedAt = .now
    try user.save()
    (changes, token) = read(token)
    expect(changes.isEmpty, "opening a page isn't a change worth sending")
    page.values = ["bill": 240]
    page.openCount += 1
    try user.save()
    (changes, token) = read(token)
    expect(changes.map(\.key) == [keys[0]], "but changing its numbers is")

    let synced = ModelContext(container)
    synced.author = "sync"
    synced.insert(MemoryFact(topic: "Diet", text: "Vegetarian", source: .said, isConfirmed: true))
    try synced.save()
    (changes, token) = read(token)
    expect(changes.isEmpty && saves.last == "sync", "what sync writes itself is left out, and its saves say who made them")

    let stored = try user.fetch(FetchDescriptor<StoredRecord>())
    for entry in stored { user.delete(entry) }
    user.delete(page)
    user.delete(fact)
    try user.save()
    (changes, token) = read(token)
    let deleted = Dictionary(changes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    expect(Set(deleted.keys) == Set(keys) && changes.allSatisfy(\.deleted), "deletions are noticed, by the ids the models keep after deleting")
    expect(deleted[keys[2]]?.parent == page.id.uuidString, "and a deleted entry says which page it was on")

    // How RecordStore.deleteAll removes a page's entries.
    let other = UUID()
    for name in ["Eggs", "Bread"] {
        user.insert(StoredRecord(surfaceID: other, collection: "groceries", record: Record(id: UUID(), values: ["name": .text(name)], order: 0, created: .now)))
    }
    try user.save()
    (_, token) = read(token)
    try user.delete(model: StoredRecord.self, where: #Predicate { $0.surfaceID == other })
    try user.save()
    (changes, token) = read(token)
    print("  note  deleting entries in one go is \(changes.count == 2 ? "noticed one by one" : "not in history (\(changes.count)); the server deletes a page's entries with it")")

    SyncHistory.prune(before: token, in: user)
    let left = read(nil).changes
    expect(left.count <= 2, "history already read is let go (\(left.count) changes left, from the last save)")
    expect(SyncHistory.latest(after: nil, in: user) != nil, "and reading can start after what's there")
}

// MARK: - Running

do {
    try checkFormats()
    try checkHistory()
    try await checkRules {
        let server = StandIn()
        return (server, server)
    }
    if let address = ProcessInfo.processInfo.environment["DREAM_SYNC_URL"], let base = URL(string: address) {
        print("\nThrough the Worker at \(base.absoluteString)")
        live = true
        let person = "sync-check-\(UUID().uuidString.prefix(8))"
        func session() async throws -> String {
            var request = URLRequest(url: base.appending(path: "api/dev/session").appending(queryItems: [URLQueryItem(name: "user", value: person)]))
            request.httpMethod = "POST"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw URLError(.userAuthenticationRequired) }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)["token"]?.string ?? ""
        }
        func backend(_ token: String) -> Backend {
            Live(client: SyncClient(base: base, authorize: { $0.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }))
        }
        try await checkRules { (backend(try await session()), backend(try await session())) }
    } else {
        print("\nThrough the Worker: skipped (set DREAM_SYNC_URL to a local `wrangler dev` with DEV_LOGIN=1).")
    }
} catch {
    print("  FAIL  \(error)")
    failures += 1
}
print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
