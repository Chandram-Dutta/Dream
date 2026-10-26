import EventKit
import Foundation

// What actions do (ROADMAP.md, workstream 7). Like sources, performers sit in a registry that
// can grow while Dream runs, so an MCP server's write tools can become buttons too: conform to
// `ActionPerformer` and `LiveActions.register` it. A performer only ever runs when the user taps
// its button, after the button has said, in `sentence`, exactly what it will do.

/// Does one kind of action.
protocol ActionPerformer: Sendable {
    /// What actions of this kind are called, like calendarEvent.
    var kind: String { get }
    /// An SF Symbol for the button.
    var symbol: String { get }
    /// Whether to ask once more before doing it: for what can't be taken back, or sends
    /// something somewhere. Dream's own actions only add to the user's own apps, so they don't.
    var confirms: Bool { get }
    /// What tapping does, exactly, as the button says it: Add “Picnic, Sat 31 Oct, 4 pm” to your calendar.
    func sentence(_ action: ResolvedAction) -> String
    /// The rest of what it sends, shown under the button: where, and any notes.
    func details(_ action: ResolvedAction) -> [String]
    /// Does it. Throws `LiveError` with words the user can act on.
    func perform(_ action: ResolvedAction) async throws -> ActionDone
}

extension ActionPerformer {
    var confirms: Bool { false }
}

/// What an action did, in words, and where to see it.
struct ActionDone: Hashable, Sendable {
    var message: String
    var link: URL?
    var linkTitle = ""
    /// The link is the action itself, like directions in Maps, so the screen opens it right away.
    var opensNow = false
}

/// Every performer Dream can use.
enum LiveActions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var performers: [String: any ActionPerformer] = Dictionary(
        uniqueKeysWithValues: ([CalendarEventPerformer(), ReminderPerformer(), DirectionsPerformer()] as [any ActionPerformer]).map { ($0.kind, $0) })

    static func register(_ performer: any ActionPerformer) {
        lock.withLock { performers[performer.kind] = performer }
    }

    static func performer(_ kind: String) -> (any ActionPerformer)? {
        lock.withLock { performers[kind] }
    }
}

// MARK: - Calendar

/// Adds an event to the user's default calendar, with write-only access: Dream never sees what
/// else is on it.
struct CalendarEventPerformer: ActionPerformer {
    let kind = "calendarEvent"
    let symbol = "calendar.badge.plus"

    func sentence(_ action: ResolvedAction) -> String {
        "Add “\([action["title"], action.when()].filter { !$0.isEmpty }.joined(separator: ", "))” to your calendar"
    }

    func details(_ action: ResolvedAction) -> [String] {
        [action["place"], action["notes"]].filter { !$0.isEmpty }
    }

    func perform(_ action: ResolvedAction) async throws -> ActionDone {
        guard let start = action.start else { throw LiveError(.notFound, "This event has no day.") }
        let store = EKEventStore()
        let allowed = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        guard allowed else { throw LiveError(.denied, "Dream isn't allowed to add to your calendar.") }
        let event = EKEvent(eventStore: store)
        event.title = action["title"].isEmpty ? "Event" : action["title"]
        event.isAllDay = !action.hasTime
        event.startDate = start
        event.endDate = action.hasTime
            ? start.addingTimeInterval(max(action.minutes ?? 60, 5) * 60)
            : Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        if !action["place"].isEmpty { event.location = action["place"] }
        if !action["notes"].isEmpty { event.notes = action["notes"] }
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw LiveError(.unavailable, "Your calendar didn't take it.")
        }
        return ActionDone(message: "Added to your calendar", link: URL(string: "calshow:\(start.timeIntervalSinceReferenceDate)"), linkTitle: "Open Calendar")
    }
}

// MARK: - Reminders

/// Adds a reminder to the user's default list. Reminders have no write-only access, so this
/// asks for full access, and uses it only to add.
struct ReminderPerformer: ActionPerformer {
    let kind = "reminder"
    let symbol = "checklist"

    func sentence(_ action: ResolvedAction) -> String {
        "Add “\([action["title"], action.when()].filter { !$0.isEmpty }.joined(separator: ", "))” to your reminders"
    }

    func details(_ action: ResolvedAction) -> [String] {
        [action["notes"]].filter { !$0.isEmpty }
    }

    func perform(_ action: ResolvedAction) async throws -> ActionDone {
        let store = EKEventStore()
        let allowed = (try? await store.requestFullAccessToReminders()) ?? false
        guard allowed else { throw LiveError(.denied, "Dream isn't allowed to add to your reminders.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = action["title"].isEmpty ? "Reminder" : action["title"]
        if !action["notes"].isEmpty { reminder.notes = action["notes"] }
        if let start = action.start {
            let parts: Set<Calendar.Component> = action.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: start)
            if action.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: start)) }
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw LiveError(.unavailable, "There's no reminders list to add to.") }
        reminder.calendar = list
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw LiveError(.unavailable, "Reminders didn't take it.")
        }
        return ActionDone(message: "Added to your reminders", link: URL(string: "x-apple-reminderkit://"), linkTitle: "Open Reminders")
    }
}

// MARK: - Directions

/// Opens directions in Maps. Nothing is written anywhere, so it needs no permission.
struct DirectionsPerformer: ActionPerformer {
    let kind = "directions"
    let symbol = "arrow.triangle.turn.up.right.diamond.fill"

    func sentence(_ action: ResolvedAction) -> String {
        let place = action["title"].isEmpty ? action["place"] : action["title"]
        let from = Source.isHere(action["from"]) ? "" : " from \(action["from"])"
        let mode = Travel(action["travel"])
        let how = mode == .walking ? "walking" : mode == .transit ? "transit" : "driving"
        return "Get \(how) directions to \(place)\(from) in Maps"
    }

    func details(_ action: ResolvedAction) -> [String] {
        action["title"].isEmpty || action["title"] == action["place"] ? [] : [action["place"]]
    }

    /// Maps is handed the place's name rather than a point Dream found, so it searches near
    /// the user itself: "the airport" is theirs, and Dream never needs their location for it.
    func perform(_ action: ResolvedAction) async throws -> ActionDone {
        guard let url = Self.url(action) else { throw LiveError(.notFound, "There's nowhere to go.") }
        return ActionDone(message: "Opened in Maps", link: url, linkTitle: "Open Maps again", opensNow: true)
    }

    static func url(_ action: ResolvedAction) -> URL? {
        let place = action["place"].isEmpty ? action["title"] : action["place"]
        guard !place.isEmpty, var components = URLComponents(string: "https://maps.apple.com/") else { return nil }
        let mode: String = switch Travel(action["travel"]) {
        case .driving: "d"
        case .walking: "w"
        case .transit: "r"
        }
        components.queryItems = [URLQueryItem(name: "daddr", value: place), URLQueryItem(name: "dirflg", value: mode)]
        if !Source.isHere(action["from"]) { components.queryItems?.append(URLQueryItem(name: "saddr", value: action["from"])) }
        return components.url
    }
}
