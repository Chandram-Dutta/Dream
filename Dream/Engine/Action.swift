import Foundation

// Actions (ROADMAP.md, workstream 7).

/// Something the user can do from a surface with one tap, like adding the picnic to their
/// calendar, shown by an `action` block. The model writes what it does; nothing happens until
/// the user taps, and the button says exactly what will happen before they do. Performers live
/// in `Generation/LiveActions.swift`.
struct Action: Codable, Hashable {
    /// camelCase, what action blocks name.
    var name: String
    /// Which performer does it: calendarEvent, reminder or directions.
    var kind: String
    /// What it sends, by the performer's own names. Text can show live values and results with
    /// `{name}`. `day` is a day as sources write it, `time` a time like 16:00 or a formula
    /// giving the hour, and `duration` a number of minutes or a formula.
    var fields: [String: String]

    subscript(field: String) -> String { fields[field] ?? "" }
}

/// An action with its fields worked out at the surface's current values, as it would be done
/// if the user tapped now.
struct ResolvedAction: Hashable, Sendable {
    var name: String
    var kind: String
    /// Text fields, with their `{name}`s filled in. Everything but day, time and duration.
    var text: [String: String]
    /// When it's for: the day at the time. Nil when it has no day.
    var start: Date?
    /// False for something that lasts all day.
    var hasTime: Bool
    /// How long, from `duration`.
    var minutes: Double?

    subscript(field: String) -> String { text[field] ?? "" }
}

extension Surface {
    func action(_ name: String) -> Action? { actions?.first { $0.name == name } }
}

extension Action {
    /// Fields that aren't text.
    static let timing: Set<String> = ["day", "time", "duration"]

    func resolved(in surface: Surface, evaluation: Evaluation, now: Date = .now, calendar: Calendar = .current) -> ResolvedAction {
        var text: [String: String] = [:]
        for (field, value) in fields where !Self.timing.contains(field) {
            text[field] = Self.filled(value, in: surface, evaluation: evaluation)
        }
        let minutes = Self.clock(self["time"], evaluation: evaluation)
        let day = self["day"].trimmingCharacters(in: .whitespaces)
        let start = day.isEmpty && minutes == nil ? nil : LiveDay.moment(day: day, minutes: minutes, now: now, calendar: calendar)
        let duration = self["duration"].trimmingCharacters(in: .whitespaces)
        return ResolvedAction(
            name: name,
            kind: kind,
            text: text,
            start: start,
            hasTime: minutes != nil,
            minutes: duration.isEmpty ? nil : Self.number(duration, evaluation: evaluation).map { max($0, 0) })
    }

    /// A time as minutes after midnight: written as one, or worked out from a formula giving
    /// the hour, so 16.5 is 4:30 pm.
    static func clock(_ text: String, evaluation: Evaluation) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let minutes = LiveDay.minutes(trimmed) { return minutes }
        guard let hours = number(trimmed, evaluation: evaluation), (0..<24).contains(hours) else { return nil }
        return Int((hours * 60).rounded())
    }

    /// A formula worked out with the surface's values. Nil if it can't be, or isn't a number.
    static func number(_ formula: String, evaluation: Evaluation) -> Double? {
        guard let expr = try? FormulaCache.parse(formula),
              let value = try? expr.evaluate({ name in
                  if let known = evaluation.values[name] { return known }
                  if let constant = Expr.constants[name] { return constant }
                  throw FormulaError("'\(name)' isn't an input or output")
              }),
              value.isFinite
        else { return nil }
        return value
    }

    /// Text with each `{name}` shown as the screen shows it, unit and all.
    static func filled(_ text: String, in surface: Surface, evaluation: Evaluation) -> String {
        Placeholders.parts(text).map { part in
            switch part {
            case .text(let text): text
            case .name(let name): surface.display(name, evaluation.values[name])
            case .math(let tex): TeX.spoken(tex)
            }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ResolvedAction {
    /// When, the way the button says it: "today, 4 pm", "Sat 31 Oct, 4–6 pm", "Sat 31 Oct".
    func when(calendar: Calendar = .current, now: Date = .now) -> String {
        guard let start else { return "" }
        var day: String
        if calendar.isDate(start, inSameDayAs: now) {
            day = "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            day = "tomorrow"
        } else {
            day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        guard hasTime else { return day }
        let time = Self.time(start)
        if let minutes, minutes > 0, let end = calendar.date(byAdding: .minute, value: Int(minutes.rounded()), to: start), calendar.isDate(end, inSameDayAs: start) {
            return "\(day), \(time)–\(Self.time(end))"
        }
        return "\(day), \(time)"
    }

    /// 4 pm rather than 4:00 pm, in the reader's own clock.
    private static func time(_ date: Date) -> String {
        Calendar.current.component(.minute, from: date) == 0 ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.hour().minute())
    }
}

/// How someone's getting there, as routes and directions write it.
enum Travel: String {
    case driving, walking, transit

    init(_ text: String) {
        let words = text.lowercased()
        self = words.contains("walk") || words.contains("foot") ? .walking
            : ["transit", "train", "bus", "metro", "public"].contains(where: words.contains) ? .transit
            : .driving
    }

    var words: String {
        switch self {
        case .driving: "by car"
        case .walking: "on foot"
        case .transit: "by public transport"
        }
    }

    var symbol: String {
        switch self {
        case .driving: "car.fill"
        case .walking: "figure.walk"
        case .transit: "tram.fill"
        }
    }
}
