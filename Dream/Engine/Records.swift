import Foundation

// Lists and the user's own data (ROADMAP.md, workstream 2).
//
// A surface can declare collections: lists of entries with typed fields, like groceries or
// expenses. The declaration is part of the template; the entries (records) are the user's own,
// stored on the phone and handed to the engine as plain values. They're never in the surface.

/// A list the user keeps, as the template declares it: its fields, and any starting entries.
struct RecordCollection: Codable, Hashable {
    /// Used in formulas, like `sum(expenses.amount)`.
    var name: String
    var label: String
    /// What one entry is called, singular and lowercase, like "expense".
    var entry: String
    /// The first field names each entry.
    var fields: [RecordField]
    /// Entries anyone would start with, like what to pack for a beach. Shareable defaults, copied
    /// into the user's records the first time the surface opens. Keyed by field name.
    var starters: [[String: RecordValue]] = []

    func field(_ name: String) -> RecordField? { fields.first { $0.name == name } }

    /// What names an entry: the first text field, or else the first field.
    var titleField: RecordField? { fields.first { $0.type == .text } ?? fields.first }
    /// Entries with a date are a log: newest first, dated as they're added.
    var dateField: RecordField? { fields.first { $0.type == .date } }
    var isLog: Bool { dateField != nil }
    /// The one thing an entry is checked off by. With several done fields (one per habit, say)
    /// there's no single check.
    var checkField: RecordField? {
        let done = fields.filter { $0.type == .done }
        return done.count == 1 ? done[0] : nil
    }
    /// The number that matters most about an entry, shown beside it.
    var amountField: RecordField? { fields.first { $0.type == .currency } ?? fields.first { $0.type == .number } }

    /// Entries in the order they're shown, which is also how the user counts them ("the first
    /// two"). A log runs newest first. Otherwise the user's own order, with checked-off entries
    /// sinking below the rest.
    func arranged(_ records: [Record]) -> [Record] {
        if let date = dateField {
            return records.sorted { a, b in
                let (x, y) = (a.date(date.name), b.date(date.name))
                return x != y ? x > y : a.created > b.created
            }
        }
        let ordered = records.sorted { $0.order != $1.order ? $0.order < $1.order : $0.created < $1.created }
        guard let check = checkField else { return ordered }
        return ordered.filter { !$0.isOn(check.name) } + ordered.filter { $0.isOn(check.name) }
    }

    /// Oldest first, so `last()` is the latest entry: by date in a log, otherwise as added.
    func chronological(_ records: [Record]) -> [Record] {
        if let date = dateField {
            return records.sorted { a, b in
                let (x, y) = (a.date(date.name), b.date(date.name))
                return x != y ? x < y : a.created < b.created
            }
        }
        return records.sorted { $0.created < $1.created }
    }

    /// "an expense", "a grocery": for the usual English nouns, good enough to name an entry.
    static func indefinite(_ noun: String) -> String {
        let vowel = noun.lowercased().first.map { "aeio".contains($0) } ?? false
        return (vowel ? "an " : "a ") + noun
    }

    /// One entry, as the interface names it: "an expense".
    var anEntry: String { Self.indefinite(entry.isEmpty ? "entry" : entry) }

    /// Several entries: "expenses", "groceries", "days".
    var entries: String {
        let noun = entry.isEmpty ? "entry" : entry
        if noun.hasSuffix("y"), let before = noun.dropLast().last, !"aeiou".contains(before) { return noun.dropLast() + "ies" }
        if ["s", "sh", "ch", "x", "z"].contains(where: noun.hasSuffix) { return noun + "es" }
        return noun + "s"
    }

    /// The starters as the user's own entries, the way they're copied in the first time the
    /// surface opens.
    func starterRecords(at time: Date = .now) -> [Record] {
        starters.enumerated().map { index, values in
            // A second apart, so they keep their order when sorted by when they were added.
            newRecord(values, after: [], at: time.addingTimeInterval(Double(index - starters.count)))
                .reordered(Double(index))
        }
    }

    /// A new entry with these values, dated now if it's a log, at the end of the user's order.
    func newRecord(_ values: [String: RecordValue], after records: [Record], at time: Date = .now) -> Record {
        var values = values
        if let date = dateField, values[date.name] == nil { values[date.name] = .number(time.timeIntervalSince1970) }
        let order = (records.map(\.order).max() ?? -1) + 1
        return Record(id: UUID(), values: values, order: order, created: time)
    }
}

/// One field of a collection's entries.
struct RecordField: Codable, Hashable {
    var name: String
    var label: String
    var type: FieldType
    /// Only for `.choice`.
    var options: [String] = []
}

enum FieldType: String, Codable, CaseIterable {
    case text, number, currency, date
    /// Checked off or not.
    case done
    /// One of a few options.
    case choice
    /// 1 to 5 stars.
    case rating

    /// Whether it adds up: what sum() and friends can use.
    var isNumeric: Bool { [.number, .currency, .rating, .done, .date].contains(self) }
}

/// A field's value: a number (amounts, dates as seconds since 1970, done as 1 or 0, ratings)
/// or text (text, and a choice's option). Stored as plain JSON numbers and strings.
enum RecordValue: Codable, Hashable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let flag = try? container.decode(Bool.self) {
            self = .number(flag ? 1 : 0)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number.isFinite ? number : 0)
        case .text(let text): try container.encode(text)
        }
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

/// One of the user's entries, as the engine sees it: plain values, never the store.
struct Record: Codable, Hashable, Identifiable {
    var id: UUID
    /// By field name. A field without a value is simply missing.
    var values: [String: RecordValue]
    /// Where it sits in a list the user arranges by hand.
    var order: Double
    var created: Date

    subscript(field: String) -> RecordValue? {
        get { values[field] }
        set { values[field] = newValue }
    }

    func isOn(_ field: String) -> Bool { (values[field]?.numberValue ?? 0) != 0 }

    func reordered(_ order: Double) -> Record {
        var record = self
        record.order = order
        return record
    }

    func date(_ field: String) -> Date {
        values[field]?.numberValue.map { Date(timeIntervalSince1970: $0) } ?? created
    }
}

// MARK: - Values

extension RecordField {
    var format: Format {
        switch type {
        case .currency: .currency
        case .rating: .integer
        case .done: .toggle
        default: .number
        }
    }

    /// Reads a value from text, as the model, a starter or the quick-add bar writes it: "₹1,200",
    /// "2026-10-26", "yesterday", "yes", "Food", "4".
    func parse(_ raw: String, now: Date = .now) -> RecordValue? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text:
            return text.isEmpty ? nil : .text(text)
        case .number, .currency:
            return RecordField.number(in: text).map { .number($0) }
        case .rating:
            let stars = text.filter { $0 == "★" || $0 == "⭐" }.count
            let value = stars > 0 ? Double(stars) : RecordField.number(in: text)
            return value.map { .number(Swift.min(Swift.max($0.rounded(), 1), 5)) }
        case .done:
            let word = text.lowercased()
            if ["yes", "true", "done", "1", "y", "x", "✓", "✔", "checked", "on", "packed", "bought"].contains(word) { return .number(1) }
            if ["no", "false", "0", "n", "", "off", "not done", "unchecked"].contains(word) { return .number(0) }
            return nil
        case .date:
            return RecordField.date(in: text, now: now).map { .number($0.timeIntervalSince1970) }
        case .choice:
            return option(matching: text).map { .text($0) }
        }
    }

    /// The option this text means: the same words, or close enough.
    func option(matching text: String) -> String? {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = options.first(where: { $0.lowercased() == wanted }) { return exact }
        let keyed = Dictionary(options.map { (Checker.identifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        return Checker.closestName(to: Checker.identifier(wanted), in: Set(keyed.keys)).flatMap { keyed[$0] }
    }

    /// Converts a value this field held under another type, when a change to the screen changed it.
    func converted(_ value: RecordValue, from old: FieldType) -> RecordValue? {
        guard old != type else { return value }
        switch (value, type) {
        case (.number(let number), .text):
            return old == .done ? nil : .text(old == .date ? Date(timeIntervalSince1970: number).formatted(date: .abbreviated, time: .omitted) : number.plain)
        case (.number(let number), .choice):
            return option(matching: number.plain).map { .text($0) }
        case (.number(let number), .done):
            return .number(number != 0 ? 1 : 0)
        case (.number(let number), .rating):
            return old == .date ? nil : .number(Swift.min(Swift.max(number.rounded(), 1), 5))
        case (.number, .number), (.number, .currency):
            return old == .date ? nil : value
        case (.number, .date):
            return nil
        case (.text(let text), _):
            return parse(text)
        }
    }

    /// How a value reads in a list: "₹400", "Today", "★★★★☆".
    func display(_ value: RecordValue?, now: Date = .now) -> String {
        guard let value else { return "" }
        switch (type, value) {
        case (.text, .text(let text)), (.choice, .text(let text)):
            return text
        case (.date, .number(let seconds)):
            return RecordField.relative(Date(timeIntervalSince1970: seconds), now: now)
        case (.rating, .number(let stars)):
            let count = stars.isFinite ? Int(Swift.min(Swift.max(stars.rounded(), 0), 5)) : 0
            return String(repeating: "★", count: count) + String(repeating: "☆", count: 5 - count)
        case (.done, .number(let flag)):
            return flag != 0 ? label : ""
        case (_, .number(let number)):
            return format.display(number)
        case (_, .text(let text)):
            return text
        }
    }

    /// The value as a model or a person would write it back: "400", "2026-10-26", "yes".
    func written(_ value: RecordValue?) -> String {
        guard let value else { return "" }
        switch (type, value) {
        case (.date, .number(let seconds)):
            return RecordField.day.string(from: Date(timeIntervalSince1970: seconds))
        case (.done, .number(let flag)):
            return flag != 0 ? "yes" : "no"
        case (_, .number(let number)):
            return number.plain
        case (_, .text(let text)):
            return text
        }
    }

    /// What a new entry starts with when nothing's given.
    var sample: RecordValue {
        switch type {
        case .text: .text("Sample")
        case .number, .currency, .done: .number(1)
        case .rating: .number(3)
        case .date: .number(Date.now.timeIntervalSince1970)
        case .choice: .text(options.first ?? "")
        }
    }

    // MARK: Reading text

    /// The first number in some text, so "₹1,200.50" reads as 1200.5 and "4,5" as 4.5.
    static func number(in text: String) -> Double? {
        let cleaned = text.replacing(#/(\d),(\d{3})(?!\d)/#) { "\($0.output.1)\($0.output.2)" }
        guard let match = cleaned.firstMatch(of: #/-?\d+(?:[.,]\d+)?/#) else { return nil }
        return Double(match.output.replacingOccurrences(of: ",", with: "."))
    }

    /// A date in some text: ISO days, the usual relative words, and whatever the system's date
    /// detector finds.
    static func date(in text: String, now: Date = .now) -> Date? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        switch lower {
        case "today", "now", "": return now
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: noon)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: noon)
        default: break
        }
        if let day = day.date(from: String(lower.prefix(10))) {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
        return detected(in: text, now: now)?.date
    }

    /// The date the system finds in some text, and where, so the quick-add bar can take it out.
    static func detected(in text: String, now: Date = .now) -> (date: Date, range: Range<String.Index>)? {
        let lower = text.lowercased()
        for word in ["yesterday", "today", "tomorrow"] {
            if let range = lower.range(of: #"\b\#(word)\b"#, options: .regularExpression), let date = date(in: word, now: now) {
                return (date, range)
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date, let range = Range(match.range, in: text) else { return nil }
        return (date, range)
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// "Today", "Yesterday", the weekday within a week, then the date.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Surface

extension Surface {
    var recordCollections: [RecordCollection] { collections ?? [] }

    func collection(_ name: String) -> RecordCollection? { collections?.first { $0.name == name } }

    /// A collection's label, or a field's ("expenses.amount" → "Amount"), for whatever names them.
    func collectionLabel(_ name: String) -> String? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        // Empty while a block is still streaming in.
        guard let first = parts.first, let collection = collection(first) else { return nil }
        guard parts.count == 2 else { return collection.label }
        return collection.field(parts[1])?.label
    }

    /// One entry with every field filled, for each collection, so the checker can see whether
    /// totals work: an empty list makes an average "—", which is right, but says nothing.
    var sampleRecords: [String: [Record]] {
        Dictionary(recordCollections.map { collection in
            let values = Dictionary(collection.fields.map { ($0.name, $0.sample) }, uniquingKeysWith: { first, _ in first })
            return (collection.name, [Record(id: UUID(), values: values, order: 0, created: .now)])
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The collections in shorthand, for showing the model the screen and for the log. Never
    /// the user's entries.
    var collectionSummary: String {
        guard !recordCollections.isEmpty else { return "" }
        var lines = ["Lists:"]
        for collection in recordCollections {
            let fields = collection.fields.map { field in
                field.type == .choice ? "\(field.name) (choice of \(field.options.joined(separator: " / ")))" : "\(field.name) (\(field.type.rawValue))"
            }
            lines.append("- \(collection.name): \"\(collection.label)\", each \(collection.anEntry): \(fields.joined(separator: ", "))")
            if let title = collection.titleField, !collection.starters.isEmpty {
                let titles = collection.starters.prefix(30).compactMap { $0[title.name].map(title.written) }
                lines.append("  starters: \(titles.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension RecordCollection {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? name
        entry = try container.decodeIfPresent(String.self, forKey: .entry) ?? ""
        fields = try container.decodeIfPresent([RecordField].self, forKey: .fields) ?? []
        starters = try container.decodeIfPresent([[String: RecordValue]].self, forKey: .starters) ?? []
    }
}

extension RecordField {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? name
        type = (try? container.decode(FieldType.self, forKey: .type)) ?? .text
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}
