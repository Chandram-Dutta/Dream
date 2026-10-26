import Foundation
import FoundationModels

// What the model writes for actions (ROADMAP.md, workstream 7). `WireSurface.actions` holds
// them. Sources aren't written here: calling the live tool is how the model declares one, so
// every source has really been read, and its parameters are never typed twice.

@Generable
enum WireActionKind { case calendarEvent, reminder, directions }

@Generable
enum WireTravel { case driving, walking, transit }

@Generable(description: "Something the user can do with one tap")
struct WireAction {
    @Guide(description: "camelCase name that action blocks refer to")
    var name: String
    var kind: WireActionKind
    @Guide(description: "calendarEvent and reminder: what it's called, short, like Picnic in Cubbon Park. directions: the place's name")
    var title: String
    @Guide(description: "calendarEvent and reminder: today, tomorrow, a weekday like saturday, or YYYY-MM-DD. directions: empty")
    var day: String
    @Guide(description: "calendarEvent and reminder: when, as HH:mm in 24-hour time, or a formula giving the hour, like startHour. Empty for all day. directions: empty")
    var time: String
    @Guide(description: "calendarEvent: how long, in minutes: a number or a formula. Otherwise empty")
    var duration: String
    @Guide(description: "calendarEvent: where, if anywhere. directions: where to, as Maps would find it. reminder: empty")
    var place: String
    @Guide(description: "directions: where from; empty for where the user is. Otherwise empty")
    var from: String
    @Guide(description: "directions: how they're travelling")
    var travel: WireTravel
    @Guide(description: "calendarEvent and reminder: a short note, where {name} shows a live value or result. Otherwise empty")
    var notes: String
}

extension Action {
    init(_ wire: WireAction) {
        self.init(name: wire.name, kind: String(describing: wire.kind), fields: Self.fields(
            kind: wire.kind, title: wire.title, day: wire.day, time: wire.time, duration: wire.duration,
            place: wire.place, from: wire.from, travel: String(describing: wire.travel), notes: wire.notes))
    }

    /// While the model is still writing: an action appears once its name and kind have.
    init?(partial wire: WireAction.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty, let kind = wire.kind else { return nil }
        self.init(name: name, kind: String(describing: kind), fields: Self.fields(
            kind: kind, title: wire.title ?? "", day: wire.day ?? "", time: wire.time ?? "", duration: wire.duration ?? "",
            place: wire.place ?? "", from: wire.from ?? "", travel: wire.travel.map { String(describing: $0) } ?? "", notes: wire.notes ?? ""))
    }

    /// Only the fields its kind uses, so the template doesn't carry the others empty.
    private static func fields(kind: WireActionKind, title: String, day: String, time: String, duration: String,
                               place: String, from: String, travel: String, notes: String) -> [String: String] {
        let all: [String: String]
        switch kind {
        case .calendarEvent: all = ["title": title, "day": day, "time": time, "duration": duration, "place": place, "notes": notes]
        case .reminder: all = ["title": title, "day": day, "time": time, "notes": notes]
        case .directions: all = ["title": title, "place": place, "from": from, "travel": travel]
        }
        return all.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func list(_ wires: [WireAction]) -> [Action]? {
        wires.isEmpty ? nil : wires.map { Action($0) }
    }

    static func list(partial wires: [WireAction.PartiallyGenerated]?) -> [Action]? {
        let actions = (wires ?? []).compactMap { Action(partial: $0) }
        return actions.isEmpty ? nil : actions
    }
}
