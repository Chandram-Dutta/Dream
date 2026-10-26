import Foundation
import Network
import Observation
import SwiftData
import UIKit

/// Keeps the signed-in user's pages, list entries, memory, connections and settings the same on
/// every device they use (PRODUCTION.md, workstream B), through their account on Dream's server.
///
/// SwiftData stays what every screen reads. Changes made here are read from SwiftData's history
/// (and, for connections and settings, noticed by comparison), queued in the ledger, and sent
/// soon after, with backoff when that fails. The account's changes are read at launch, on coming
/// back to the app, after sending, and every few minutes. For each item the latest change wins;
/// deletions travel as tombstones (SyncLedger). It runs only while someone is signed in.
@MainActor @Observable
final class Sync {
    static let shared = Sync()

    /// Something about sync worth telling the user. Everything else stays quiet.
    enum Trouble: Equatable {
        /// No connection, with changes waiting to go.
        case offline
        /// The server no longer takes the session.
        case signedOut
        /// The account has no room for more.
        case full
        /// The server keeps failing.
        case failing
    }

    /// Nil while all's well.
    var trouble: Trouble?
    /// Changes made here that the account doesn't have yet.
    var unsent = 0
    private(set) var lastSynced: Date?
    /// Someone is signed in and there's a server to sync with.
    private(set) var isOn = false

    /// Posted after the account's changes reach a page's list entries. The object is the pages'
    /// ids, a `Set<UUID>`, so a list on screen can show them.
    static let recordsDidChange = Notification.Name("DreamSyncRecordsDidChange")
    /// What sync's own SwiftData writes are marked with, so they're never sent back.
    nonisolated static let author = "sync"

    @ObservationIgnored var container: ModelContainer?
    @ObservationIgnored var ledger = SyncLedger()
    /// Pages whose list entries changed in what was just made here.
    @ObservationIgnored var touched: Set<UUID> = []
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var current: Task<Void, Never>?
    @ObservationIgnored private var wantsRead = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var restingUntil: Date?
    @ObservationIgnored private var online = true
    @ObservationIgnored var paused = false
    @ObservationIgnored private var background = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: - Starting and stopping

    /// At launch: watches for sign-in, changes, the network and the app coming and going, and
    /// starts if someone is signed in.
    static func start(_ container: ModelContainer) {
        let sync = shared
        guard sync.container == nil else { return }
        sync.container = container
        sync.watch()
        if Session.isSignedIn { sync.begin() }
    }

    private func watch() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Session.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Sync.shared.sessionChanged() }
            },
            // Every save, from any context but sync's own.
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard (note.object as? ModelContext)?.author != Sync.author else { return }
                    Sync.shared.soon()
                }
            },
            // Settings, and which lists' starters were added, live in UserDefaults.
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Sync.shared.soon() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Sync.shared.now(force: true) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Sync.shared.finishInBackground() }
            },
        ]
        ConnectionStore.shared.onSave = { Sync.shared.soon() }
        path.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            Task { @MainActor in Sync.shared.reachable(reachable) }
        }
        path.start(queue: .main)
    }

    private func sessionChanged() {
        if Session.isSignedIn {
            begin()
        } else {
            end()
            // Whoever signs in next starts from their own account.
            ledger.reset(for: nil)
            storeLedger()
        }
    }

    private func begin() {
        guard let container, ServerAddress.dream != nil else { return }
        guard !isOn else {
            trouble = nil
            now(force: true)
            return
        }
        loadLedger()
        let context = ModelContext(container)
        // Fresh for this account: what was on the phone before is only sent if the user moves it
        // in (adoptLocalData), not because SwiftData's history mentions it.
        if ledger.cursor == nil, ledger.outbox.isEmpty { skipHistory(in: context) }
        pruneHistory(in: context)
        if !ledger.primed {
            compare(in: context, queue: false)
            ledger.primed = true
        }
        storeLedger()
        isOn = true
        unsent = ledger.outbox.count
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        runner = Task {
            for await _ in stream {
                await Sync.shared.cycleOnce()
            }
        }
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if UIApplication.shared.applicationState == .active { Sync.shared.now() }
            }
        }
        now(force: true)
    }

    private func end() {
        isOn = false
        trouble = nil
        // A round still going stops, and can no longer save what it was doing (saveLedger).
        current?.cancel()
        runner?.cancel()
        ticker?.cancel()
        settling?.cancel()
        wake?.finish()
        wake = nil
    }

    // MARK: - When to sync

    /// After a change here: sends it once things settle, without reading unless something went.
    func soon() {
        guard isOn else { return }
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Sync.shared.wake?.yield()
        }
    }

    /// Sends what's waiting and reads what's new. `force` skips any backoff.
    func now(force: Bool = false) {
        guard isOn else { return }
        wantsRead = true
        if force { restingUntil = nil }
        wake?.yield()
    }

    /// One round right away, skipping any backoff, finished before it returns.
    func roundNow() async {
        guard isOn else { return }
        wantsRead = true
        restingUntil = nil
        await cycleOnce()
    }

    /// A page left the screen: changes that waited for it can be made.
    func pageReleased() {
        guard isOn, !ledger.waiting.isEmpty else { return }
        wake?.yield()
    }

    private func reachable(_ reachable: Bool) {
        let was = online
        online = reachable
        if !reachable, unsent > 0, trouble == nil { trouble = .offline }
        if reachable, !was {
            if trouble == .offline { trouble = nil }
            now(force: true)
        }
    }

    private func finishInBackground() {
        guard isOn, background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Sync") { Sync.shared.endBackground() }
        Task {
            await cycleOnce()
            endBackground()
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: - One round

    /// One round at a time, whoever asks.
    func cycleOnce() async {
        while let current { await current.value }
        let round = Task { await cycle() }
        current = round
        await round.value
        current = nil
    }

    private func cycle() async {
        guard isOn, !paused, let container, let client = client() else { return }
        let context = ModelContext(container)
        context.author = Self.author
        context.autosaveEnabled = false
        collect(in: context)
        await makeWaiting(in: context, client: client)
        unsent = ledger.outbox.count
        let read = wantsRead || !ledger.outbox.isEmpty
        guard read else {
            saveLedger()
            return
        }
        if let restingUntil, restingUntil > .now {
            saveLedger()
            return
        }
        wantsRead = false
        do {
            var full = false
            do {
                try await send(with: client, in: context)
            } catch SyncClient.Failure.full {
                full = true
            }
            try await receive(with: client, in: context)
            if !full, !ledger.outbox.isEmpty { try await send(with: client, in: context) }
            failures = 0
            trouble = full ? .full : nil
            lastSynced = .now
        } catch let failure as SyncClient.Failure {
            failed(failure)
        } catch {
            failed(.server(0))
        }
        saveLedger()
        unsent = ledger.outbox.count
        if isOn, trouble == nil, !online, unsent > 0 { trouble = .offline }
    }

    private func failed(_ failure: SyncClient.Failure) {
        // After signing out, a round that was still going says nothing.
        guard isOn else { return }
        switch failure {
        case .signedOut:
            // Until someone signs in again.
            trouble = .signedOut
            restingUntil = .distantFuture
        case .full:
            trouble = .full
        case .busy(let wait):
            rest(for: wait)
        case .offline:
            failures += 1
            trouble = ledger.outbox.isEmpty ? nil : .offline
            rest(for: backoff)
        case .server:
            failures += 1
            if failures >= 3 { trouble = .failing }
            rest(for: backoff)
        }
    }

    /// 5 s, doubling up to 5 minutes, a little uneven so phones don't all come back at once.
    private var backoff: TimeInterval {
        min(300, 5 * pow(2, Double(max(failures - 1, 0)))) * Double.random(in: 0.8...1.2)
    }

    private func rest(for seconds: TimeInterval) {
        restingUntil = .now.addingTimeInterval(seconds)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            Sync.shared.now()
        }
    }

    // MARK: - Sending and reading

    private func client() -> SyncClient? {
        guard let base = ServerAddress.dream else { return nil }
        return SyncClient(base: base, authorize: { Session.authorize(&$0) })
    }

    /// Sends queued changes, a batch at a time.
    private func send(with client: SyncClient, in context: ModelContext) async throws {
        for _ in 0..<20 {
            let due = ledger.due(limit: 100)
            guard !due.isEmpty else { return }
            var items: [SyncItem] = []
            var sending: [SyncLedger.Pending] = []
            var bytes = 0
            for pending in due {
                guard let item = try await outgoing(pending, in: context, client: client) else {
                    ledger.drop(pending)
                    continue
                }
                if !items.isEmpty, bytes + item.size > 1_500_000 { break }
                items.append(item)
                sending.append(pending)
                bytes += item.size
            }
            guard !items.isEmpty else { continue }
            let taken = try await client.send(items)
            ledger.heard(serverNow: taken.now, at: Self.millis())
            let refused = taken.refused.compactMap { refusal in SyncKind(rawValue: refusal.kind).map { SyncKey($0, refusal.id) } }
            ledger.sent(sending, stale: Set(taken.stale.compactMap(\.key)), refused: Set(refused))
            // What the account already had later versions of comes back to be made here.
            try await make(taken.stale, in: context, client: client)
            saveLedger()
            unsent = ledger.outbox.count
        }
    }

    /// Reads the account's changes since last time, a page at a time.
    private func receive(with client: SyncClient, in context: ModelContext) async throws {
        for _ in 0..<200 {
            let page = try await client.changes(since: ledger.cursor)
            if let user = ledger.user, user != page.user {
                // Another account: nothing from the last one applies, and what's on this iPhone
                // goes to this one only if the user moves it in.
                ledger.reset(for: page.user)
                compare(in: context, queue: false)
                ledger.primed = true
            }
            ledger.user = page.user
            ledger.heard(serverNow: page.now, at: Self.millis())
            try await make(page.items, in: context, client: client)
            ledger.cursor = page.cursor
            saveLedger()
            if !page.more { return }
        }
    }

    /// Makes a page of the account's changes here, all or none: if one fails part way, nothing
    /// is kept, and the same page is read again next time.
    private func make(_ items: [SyncItem], in context: ModelContext, client: SyncClient) async throws {
        guard !items.isEmpty else { return }
        let before = ledger
        do {
            for item in items where ledger.receive(item) == .apply {
                try await make(item, in: context, client: client)
            }
            try context.save()
        } catch {
            context.rollback()
            ledger = before
            touched = []
            throw error
        }
        announce()
    }

    private func make(_ item: SyncItem, in context: ModelContext, client: SyncClient) async throws {
        do {
            if try await apply(item, in: context, client: client) == .later { ledger.wait(item) }
        } catch is NewerFormat {
            ledger.wait(item)
        } catch is DecodingError {
            // Unreadable: what's here stays as it is.
        }
    }

    /// Changes that waited for a page to close, or for this version to learn their format.
    private func makeWaiting(in context: ModelContext, client: SyncClient) async {
        let items = ledger.takeWaiting()
        guard !items.isEmpty else { return }
        for item in items {
            do {
                try await make(item, in: context, client: client)
            } catch {
                ledger.wait(item)
            }
        }
        try? context.save()
        announce()
    }

    private func announce() {
        guard !touched.isEmpty else { return }
        NotificationCenter.default.post(name: Self.recordsDidChange, object: touched)
        touched = []
    }

    // MARK: - The ledger

    private static let file: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "Dream/sync.json")

    /// The ledger as last stored. Anything that changes it while sync is off starts here, since
    /// a round that was still going at sign-out may have changed the one in memory.
    func loadLedger() {
        guard let file = Self.file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(SyncLedger.self, from: data) else {
            ledger = SyncLedger(skew: ledger.skew, historyToken: ledger.historyToken)
            return
        }
        ledger = saved
    }

    /// Stores the ledger while sync is on.
    func saveLedger() {
        guard isOn else { return }
        storeLedger()
    }

    func storeLedger() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable after the first unlock, so sync can finish in the background.
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Milliseconds since 1970 on this iPhone's clock.
    static func millis(_ date: Date = .now) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Now, by the server's clock.
    var stamp: Int64 { ledger.serverTime(Self.millis()) }
}
