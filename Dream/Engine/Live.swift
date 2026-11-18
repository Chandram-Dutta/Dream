import Foundation

// Sources and live data (ROADMAP.md, workstream 7).
//
// A surface can declare sources: somewhere live values come from, like tomorrow's weather in
// Bengaluru or the dollar in rupees. An input with the role `live` shows one of a source's
// fields. The engine reads sources when the screen opens and keeps them fresh; the model never
// types a live number, and a live value is never a control. Providers live in
// `Generation/LiveSources.swift`.

/// Somewhere live values come from. It's declared when the model fetches it while writing
/// (`LiveTool`), so every source on a surface has been read at least once and the text agrees
/// with its numbers. Parameters are words, never coordinates: "current location" stays that, so
/// the template says nothing about where its author was.
struct Source: Codable, Hashable, Sendable {
    /// camelCase, the first half of a live input's binding: `weather` in `weather.rainChance`.
    var name: String
    /// Which provider reads it, like weather, exchangeRate or route.
    var kind: String
    /// What to read, by the provider's own names, like place, day, from and to.
    var parameters: [String: String]
    /// What it read when it was fetched while writing.
    var fields: [SourceField]
    /// Lists it reads, like a service's open issues, which collections can show. Nil for the
    /// sources that read only numbers.
    var lists: [SourceList]? = nil

    subscript(parameter: String) -> String { parameters[parameter] ?? "" }
    func field(_ name: String) -> SourceField? { fields.first { $0.name == name } }
}

/// One value a source reads: in the provider's own unit (metric), with what it means.
struct SourceField: Codable, Hashable, Sendable {
    var name: String
    var value: Double
    /// Like °C, km or min. Empty for percentages and plain numbers.
    var unit: String = ""
    var format: Format = .number
    /// What it is, in a few words, for the model: "the chance of rain during the day".
    var meaning: String = ""
}

/// What a source read, and when.
struct SourceReading: Hashable, Sendable {
    var fields: [SourceField]
    /// In words, for the model and beside the values: "Bengaluru, Saturday 31 October: rain".
    var summary: String
    /// An SF Symbol for what it read, like cloud.rain. Empty when there's none.
    var symbol: String = ""
    /// When the values were true: when the forecast was made or the rate was set, which can be
    /// earlier than when Dream read them.
    var asOf: Date
    /// Who the values come from, shown beside them.
    var credit: LiveCredit?
    /// Not real: on the bench a provider that can't authorize stands values in, so the format
    /// can still be tried. Always shown as such.
    var isStandIn = false
    /// The rows of each list it read, by list name, each row's values by key.
    var lists: [String: [[String: RecordValue]]] = [:]

    func field(_ name: String) -> SourceField? { fields.first { $0.name == name } }
}

/// Credit a provider's terms ask for, wherever its values appear.
enum LiveCredit: Hashable, Sendable {
    /// The Apple Weather mark and a link to its legal attribution, which WeatherKit requires.
    case appleWeather
    case link(text: String, url: String)
}

/// Why a source couldn't be read, in words the user can act on.
struct LiveError: LocalizedError, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// The user hasn't allowed something Dream needs for it: location, calendars or reminders.
        case denied
        /// The place, currency or route doesn't exist, or is out of range.
        case notFound
        /// The service didn't answer.
        case unavailable
    }

    var reason: Reason
    var message: String
    /// Waiting on the user to fix something in Dream (connect a service, choose Always), not on
    /// the service, so it's worth trying again as soon as asked.
    var waitsOnUser = false

    init(_ reason: Reason, _ message: String, waitsOnUser: Bool = false) {
        self.reason = reason
        self.message = message
        self.waitsOnUser = waitsOnUser
    }

    var errorDescription: String? { message }
}

extension Input {
    /// Shown with its value, never set: a known fact, or a live value.
    var isFixed: Bool { role == .given || role == .live }

    /// A binding's two halves: `weather.rainChance` is the field rainChance of the source weather.
    var binding: (source: String, field: String)? {
        let parts = source.split(separator: ".", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

extension Surface {
    var liveSources: [Source] { sources ?? [] }
    func source(_ name: String) -> Source? { sources?.first { $0.name == name } }
    var liveInputs: [Input] { inputs.filter { $0.role == .live } }
    /// Shows live values without calculating anything, like tomorrow's chance of rain, so it
    /// needs no results.
    var showsLiveValues: Bool { !liveInputs.isEmpty && inputs.allSatisfy(\.isFixed) }

    /// The sources a block's values come from: those of the live inputs it shows, in it or in
    /// what it holds.
    func sources(shownBy block: Block) -> [String] {
        var found: [String] = []
        func walk(_ block: Block) {
            for name in block.refs {
                if let input = input(name), input.role == .live, let binding = input.binding, !found.contains(binding.source) {
                    found.append(binding.source)
                }
                if let bound = collection(name)?.listSource, !found.contains(bound.source) { found.append(bound.source) }
            }
            block.children.forEach(walk)
        }
        walk(block)
        return found
    }

    /// Each live input's value in a reading, in the input's own unit. What the screen puts in
    /// place of the values it had.
    func liveValues(_ reading: SourceReading, from source: String) -> [String: Double] {
        var values: [String: Double] = [:]
        for input in inputs where input.role == .live {
            guard let binding = input.binding, binding.source == source, let field = reading.field(binding.field),
                  let value = field.converted(to: input.unit) else { continue }
            values[input.name] = value
        }
        return values
    }

    /// The template without what was read about where its author was, for sharing: a route
    /// from "current location" would otherwise say how far they were from somewhere. The
    /// reader's own Dream reads it again, for where they are.
    var forgettingLocation: Surface {
        var surface = self
        let personal = Set(liveSources.filter(\.readsLocation).map(\.name))
        guard !personal.isEmpty else { return self }
        surface.sources = sources?.map { source in
            guard personal.contains(source.name) else { return source }
            var source = source
            source.fields = source.fields.map { SourceField(name: $0.name, value: 0, unit: $0.unit, format: $0.format, meaning: $0.meaning) }
            return source
        }
        for index in surface.inputs.indices {
            if let binding = surface.inputs[index].binding, personal.contains(binding.source) {
                surface.inputs[index].initial = 0
            }
        }
        return surface
    }
}

extension Source {
    /// Words that mean wherever the user is, rather than a place.
    static let hereWords: Set<String> = ["", "current location", "my location", "here", "near me", "where i am", "current", "me"]

    static func isHere(_ place: String) -> Bool {
        hereWords.contains(place.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether it reads where the user is: weather here, or a route from here.
    var readsLocation: Bool {
        switch kind {
        case "weather": Source.isHere(self["place"])
        case "route": Source.isHere(self["from"]) || Source.isHere(self["to"])
        default: false
        }
    }
}

extension SourceField {
    /// The value in another unit of the same kind, like °F for a field read in °C. Nil when the
    /// two don't convert.
    func converted(to target: String) -> Double? {
        guard !target.isEmpty, target != unit else { return value }
        return LiveUnits.convert(value, from: unit, to: target)
    }
}

/// Converting a provider's metric values into the units an input is written in.
enum LiveUnits {
    /// Spans of time, in seconds, which Foundation's dimensions don't cover in everyday units.
    private static let seconds: [String: Double] = ["s": 1, "min": 60, "h": 3600, "days": 86_400]

    static func convert(_ value: Double, from: String, to: String) -> Double? {
        let (from, to) = (Units.tidy(from), Units.tidy(to))
        if from == to { return value }
        if let a = seconds[from], let b = seconds[to] { return value * a / b }
        guard let a = Units.dimension(from, in: .metric), let b = Units.dimension(to, in: .metric) ?? Units.dimension(to, in: .us),
              type(of: a) == type(of: b) else { return nil }
        return b.converter.value(fromBaseUnitValue: a.converter.baseUnitValue(fromValue: value))
    }

    /// A metric unit as this reader would see it, like °F for °C in the US, with the value in it.
    static func local(_ value: Double, unit: String) -> (value: Double, unit: String) {
        let system = Locale.current.measurementSystem
        guard system != .metric, let (symbol, _) = Units.counterpart(of: unit, from: .metric, for: system),
              let converted = convert(value, from: unit, to: symbol) else { return (value, unit) }
        return (converted, symbol)
    }
}

extension Units {
    /// Part of an hour as hours and minutes, like 2 hr, 33 min, which reads more easily than
    /// 2.55 h, the way travel times come. Minutes stay minutes, so a screen can show both.
    /// Nil for anything else.
    static func clock(_ value: Double, unit: String) -> Reading? {
        guard unit == "h", value > 0, value < 100, value != value.rounded() else { return nil }
        let text = Duration.seconds((value * 60).rounded() * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return Reading(number: text)
    }
}

// MARK: - Days and times

/// Days and times as sources and actions write them. A day stays relative ("saturday"), so a
/// surface opened next week reads next week's forecast and plans next week's picnic.
enum LiveDay {
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The start of the day named: today, tonight, tomorrow, a weekday (the coming one, or today
    /// if it's that day), the weekend (the coming Saturday), "in 3 days" or YYYY-MM-DD.
    static func date(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        var words = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["this ", "next ", "coming ", "on "] where words.hasPrefix(prefix) {
            words = String(words.dropFirst(prefix.count))
        }
        func days(_ count: Int) -> Date? { calendar.date(byAdding: .day, value: count, to: today) }
        switch words {
        case "", "today", "tonight", "now", "this evening", "this morning", "this afternoon": return today
        case "tomorrow": return days(1)
        case "day after tomorrow", "the day after tomorrow": return days(2)
        case "weekend": words = "saturday"
        default: break
        }
        if let match = words.wholeMatch(of: #/in (\d{1,2}) days?/#), let count = Int(match.output.1) { return days(count) }
        if let index = weekdays.firstIndex(where: { $0 == words || ($0.prefix(3) == words.prefix(3) && words.count >= 3 && $0.hasPrefix(words)) }) {
            let current = calendar.component(.weekday, from: today) - 1
            return days((index - current + 7) % 7)
        }
        if let match = words.wholeMatch(of: #/(\d{4})-(\d{1,2})-(\d{1,2})/#),
           let year = Int(match.output.1), let month = Int(match.output.2), let day = Int(match.output.3) {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        return nil
    }

    /// Minutes after midnight for a time written as 16:00, 4 pm, 4:30pm or 16. Nil if it isn't one.
    static func minutes(_ text: String) -> Int? {
        let words = text.lowercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        if words == "noon" || words == "midday" { return 12 * 60 }
        guard let match = words.wholeMatch(of: #/(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/#), var hour = Int(match.output.1) else { return nil }
        let minute = match.output.2.flatMap { Int($0) } ?? 0
        switch match.output.3 {
        case "pm" where hour < 12: hour += 12
        case "am" where hour == 12: hour = 0
        default: break
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// A day at a time, or nil when the day can't be read.
    static func moment(day: String, minutes: Int?, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard let start = date(day, now: now, calendar: calendar) else { return nil }
        guard let minutes else { return start }
        return calendar.date(byAdding: .minute, value: minutes, to: start)
    }
}
