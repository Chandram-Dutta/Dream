import Foundation

/// What this iPhone knows about its sync with the account: how far it has read the server's
/// changes, which version of each item it holds, and the changes it still has to send. These are
/// the merge rules, with no storage or network, so `Tools/sync.sh` checks them on a Mac.
///
/// For each item the latest change wins, by when it was made. The server keeps an incoming
/// change only if it's later than what it has; a tie keeps the server's. This side matches it:
/// a change from the server replaces a local one unless the local one is later. A change made
/// here is always dated after the version it was made to, so a slow clock can't lose it.
struct SyncLedger: Codable, Equatable {
    /// A change made here and not yet taken by the server.
    struct Pending: Codable, Hashable {
        var kind: SyncKind
        var id: String
        /// A list entry's page, so the entry can follow a page that's deleted elsewhere.
        var parent: String?
        /// When it was made, by the server's clock.
        var stamp: Int64
        var deleted: Bool

        var key: SyncKey { SyncKey(kind, id) }
    }

    /// What to do with a change from the server.
    enum Verdict: Equatable {
        /// Make it here.
        case apply
        /// This iPhone already has it.
        case skip
        /// A later change made here wins, and is still to be sent.
        case keepLocal
    }

    /// A page's photo on the server, and a digest of its bytes, so it's sent once.
    struct Photo: Codable, Hashable {
        var id: String
        var digest: String
    }

    /// The account this belongs to. Another account starts again from nothing.
    var user: String?
    /// Where reading the server's changes left off.
    var cursor: String?
    /// The version (its `updatedAt`) of each item this iPhone holds, as the server had it.
    var known: [String: Int64] = [:]
    /// Changes still to send, by item.
    var outbox: [String: Pending] = [:]
    /// The server's clock minus this iPhone's, in milliseconds.
    var skew: Int64 = 0
    /// Changes from the server waiting to be made here: one to a page that's on screen, or one
    /// from a newer version of Dream.
    var waiting: [String: SyncItem] = [:]
    /// Each page's photo on the server, by page id.
    var photos: [String: Photo] = [:]
    /// What connections, settings and lists' starters looked like when last compared, by item,
    /// to notice when they change: they aren't in SwiftData, so its history doesn't say.
    var prints: [String: String] = [:]
    /// Whether `prints` has been filled in for this account.
    var primed = false
    /// How far SwiftData's history has been read (an encoded history token).
    var historyToken: Data?

    // MARK: - The clock

    /// A time on this iPhone's clock, as the server's clock would say it.
    func serverTime(_ local: Int64) -> Int64 { local + skew }

    /// Sets the clock by the server's, from a reply that came at `local`.
    mutating func heard(serverNow: Int64, at local: Int64) {
        skew = serverNow - local
    }

    // MARK: - Changes made here

    /// Queues a change made here at `stamp` (server time). It's dated after any version of the
    /// item seen so far, and after any change to it still queued, so it can't lose to either.
    mutating func changed(_ key: SyncKey, parent: String? = nil, deleted: Bool, at stamp: Int64) {
        let name = key.description
        let floor = max(known[name] ?? 0, outbox[name]?.stamp ?? 0) + 1
        outbox[name] = Pending(kind: key.kind, id: key.id, parent: parent ?? outbox[name]?.parent, stamp: max(stamp, floor), deleted: deleted)
    }

    /// The changes to send next, deletions first so a full account can make room, then oldest first.
    func due(limit: Int) -> [Pending] {
        outbox.values
            .sorted { ($0.deleted ? 0 : 1, $0.stamp, $0.key.description) < ($1.deleted ? 0 : 1, $1.stamp, $1.key.description) }
            .prefix(limit)
            .map { $0 }
    }

    /// After the server answered a batch. A change it took is done, unless the item changed again
    /// while it was on its way. One it refused is dropped: it would never be taken, and the item
    /// stays here. A stale one is settled by `receive` with the server's own version.
    mutating func sent(_ batch: [Pending], stale: Set<SyncKey>, refused: Set<SyncKey>) {
        for pending in batch {
            let name = pending.key.description
            if refused.contains(pending.key) {
                if outbox[name] == pending { outbox[name] = nil }
            } else if !stale.contains(pending.key) {
                if outbox[name] == pending { outbox[name] = nil }
                known[name] = max(known[name] ?? 0, pending.stamp)
            }
        }
    }

    /// Drops a queued change that can't be sent, like a page too large to carry.
    mutating func drop(_ pending: Pending) {
        if outbox[pending.key.description] == pending { outbox[pending.key.description] = nil }
    }

    // MARK: - Changes from the server

    /// Decides what to do with a change from the server, and notes the version it brings.
    mutating func receive(_ item: SyncItem) -> Verdict {
        guard let key = item.key else { return .skip }
        let name = key.description
        if let pending = outbox[name] {
            guard item.updatedAt >= pending.stamp else {
                known[name] = max(known[name] ?? 0, item.updatedAt)
                return .keepLocal
            }
            outbox[name] = nil
            known[name] = item.updatedAt
            return .apply
        }
        if known[name] == item.updatedAt { return .skip }
        known[name] = item.updatedAt
        return .apply
    }

    /// A page deleted elsewhere at `stamp` takes its entries (`entries`, by id, as this iPhone has
    /// them). The server already deleted those that hadn't changed since; one changed here, or
    /// changed later than that and seen here, is deleted from here too, so none outlives its page.
    mutating func pageDeleted(_ pageID: String, at stamp: Int64, entries: [String]) {
        for (name, pending) in outbox where pending.kind == .record && pending.parent == pageID && !pending.deleted {
            outbox[name] = Pending(kind: .record, id: pending.id, parent: pageID, stamp: pending.stamp + 1, deleted: true)
        }
        for id in entries {
            let key = SyncKey(.record, id)
            if outbox[key.description] == nil, (known[key.description] ?? 0) >= stamp {
                changed(key, parent: pageID, deleted: true, at: stamp)
            }
        }
        photos[pageID] = nil
    }

    /// Keeps a change from the server to make later.
    mutating func wait(_ item: SyncItem) {
        guard let key = item.key else { return }
        waiting[key.description] = item
    }

    /// The changes that waited, oldest first, leaving out any a later change here has overtaken.
    mutating func takeWaiting() -> [SyncItem] {
        let items = waiting.values.sorted { $0.updatedAt < $1.updatedAt }
        waiting = [:]
        return items.filter { item in
            guard let name = item.key?.description, let pending = outbox[name] else { return true }
            return item.updatedAt >= pending.stamp
        }
    }

    // MARK: - Starting again

    /// Forgets the account: nothing known, nothing to send. What's on the phone stays as it is,
    /// and so does how far SwiftData's history has been read.
    mutating func reset(for user: String?) {
        self = SyncLedger(skew: skew, historyToken: historyToken)
        self.user = user
    }

    init(skew: Int64 = 0, historyToken: Data? = nil) {
        self.skew = skew
        self.historyToken = historyToken
    }

    // Ledgers saved by earlier versions load, with what they didn't keep left empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        known = try c.decodeIfPresent([String: Int64].self, forKey: .known) ?? [:]
        outbox = try c.decodeIfPresent([String: Pending].self, forKey: .outbox) ?? [:]
        skew = try c.decodeIfPresent(Int64.self, forKey: .skew) ?? 0
        waiting = try c.decodeIfPresent([String: SyncItem].self, forKey: .waiting) ?? [:]
        photos = try c.decodeIfPresent([String: Photo].self, forKey: .photos) ?? [:]
        prints = try c.decodeIfPresent([String: String].self, forKey: .prints) ?? [:]
        primed = try c.decodeIfPresent(Bool.self, forKey: .primed) ?? false
        historyToken = try c.decodeIfPresent(Data.self, forKey: .historyToken)
    }
}
