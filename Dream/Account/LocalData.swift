import Foundation
import SwiftData

/// Everything personal Dream keeps on this iPhone: pages (with their numbers and photos), list
/// entries, what Dream knows, connected services and their sign-ins, and the languages the user
/// has asked in. Signing out or deleting the account erases all of it (`erase`).
///
/// ## Moving it into an account (for sync, workstream B)
///
/// What's on the phone before anyone signs in belongs to no account. On sign-in, if there's any,
/// Dream asks whether to move it into the account (`MoveSheet`), and keeps the answer in `move`:
///
/// - `.undecided`: not asked yet, or the question is showing. Sync leaves what was already on the
///   phone alone, and syncs only what's pulled from the account or made from now on.
/// - `.requested`: the user said yes, and `LocalData.moveRequested` is posted. Sync uploads
///   everything on the phone that isn't in the account yet, then calls `moveFinished()`.
/// - `.declined`: "Keep on this iPhone". As undecided, but nothing asks again; the account screen
///   offers the move (`requestMove()`).
/// - `.moved`: done, or there was nothing to move. Everything on the phone is the account's.
///
/// `Session.didChange` is posted before the question shows, so sync starts at once; it reads
/// `move` to know what it may upload. Signing out posts `Session.didChange` with nobody signed in
/// *before* erasing, so sync must check `Session.isSignedIn` and never record the erasing as
/// deletions to send. Anything sync keeps of its own (a queue of changes) goes in `erasers`.
@MainActor
enum LocalData {
    /// What's on the phone, for the move question.
    struct Summary: Equatable {
        var pages = 0
        var lists = 0
        var entries = 0
        var facts = 0

        var isEmpty: Bool { pages == 0 && entries == 0 && facts == 0 }
    }

    enum Move: String {
        case undecided, requested, declined, moved
    }

    /// Posted when the user chooses to move what's on the phone into their account.
    static let moveRequested = Notification.Name("DreamMoveLocalData")

    static var move: Move {
        get { Move(rawValue: UserDefaults.standard.string(forKey: "localDataMove") ?? "") ?? .undecided }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "localDataMove") }
    }

    static func requestMove() {
        move = .requested
        NotificationCenter.default.post(name: moveRequested, object: nil)
    }

    /// Sync calls this once everything that was on the phone is in the account.
    static func moveFinished() {
        move = .moved
    }

    static func summary(in context: ModelContext) -> Summary {
        let pages = (try? context.fetchCount(FetchDescriptor<SavedSurface>())) ?? 0
        let facts = (try? context.fetchCount(FetchDescriptor<MemoryFact>())) ?? 0
        let records = (try? context.fetch(FetchDescriptor<StoredRecord>())) ?? []
        let lists = Set(records.map { "\($0.surfaceID.uuidString)/\($0.collection)" }).count
        return Summary(pages: pages, lists: lists, entries: records.count, facts: facts)
    }

    /// What other features keep that's personal, erased with the rest. Each runs before the
    /// context is saved.
    static var erasers: [@MainActor (ModelContext) -> Void] = []

    /// Removes everything personal from the phone. Developer settings (Under the hood's keys and
    /// servers) stay, since they aren't anyone's data.
    static func erase(in context: ModelContext) async {
        for page in (try? context.fetch(FetchDescriptor<SavedSurface>())) ?? [] { context.delete(page) }
        for entry in (try? context.fetch(FetchDescriptor<StoredRecord>())) ?? [] { context.delete(entry) }
        for fact in (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? [] { context.delete(fact) }
        for eraser in erasers { eraser(context) }
        try? context.save()
        // Each service's sign-in lives in the Keychain; removing the service removes it.
        for connection in ConnectionStore.shared.connections {
            await ConnectionStore.shared.remove(connection.id)
        }
        for key in ["requestLanguages", "seededLists", "localDataMove"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
