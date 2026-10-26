import Foundation

// Changes to the user's entries: from the quick-add bar, from what they say, and when a change
// to the screen changes a collection's fields.

/// A change to the user's entries, checked against the collection's fields.
enum RecordOperation: Hashable {
    case insert(collection: String, values: [String: RecordValue])
    case update(collection: String, id: UUID, values: [String: RecordValue])
    case delete(collection: String, id: UUID)

    var collection: String {
        switch self {
        case .insert(let name, _), .update(let name, _, _), .delete(let name, _): name
        }
    }
}

/// A change as a model proposes it, before it's checked: entries by their number in the list as
/// shown (counting from 1), values as text.
struct ProposedOperation: Hashable {
    enum Action: String { case insert, update, delete }
    var action: Action
    var collection: String
    var entry: Int
    var values: [Value]

    struct Value: Hashable {
        var field: String
        var value: String
    }
}

/// Model output is untrusted: every proposed change is checked against the collection's fields
/// before it touches the user's entries. What can't be read is reported, so a weaker model's
/// attempt can be handed to a stronger one.
enum RecordChecker {
    static func check(_ proposed: [ProposedOperation], in surface: Surface, records: [String: [Record]], now: Date = .now) -> (operations: [RecordOperation], issues: [String]) {
        var operations: [RecordOperation] = []
        var issues: [String] = []
        let collections = surface.recordCollections
        let names = Set(collections.map(\.name))
        for change in proposed {
            let name = Checker.closestColumn(to: change.collection, in: surface) ?? Checker.closestName(to: change.collection, in: names)
                ?? (collections.count == 1 ? collections[0].name : nil)
            guard let name, let collection = surface.collection(name) else {
                issues.append("There's no list called '\(change.collection)'.")
                continue
            }
            var values: [String: RecordValue] = [:]
            for item in change.values {
                guard let field = field(item.field, in: collection) else {
                    issues.append("\(collection.label) has no field '\(item.field)'.")
                    continue
                }
                if let value = field.parse(item.value, now: now) {
                    values[field.name] = value
                } else if !item.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("'\(item.value)' isn't a \(field.type.rawValue) for \(field.label.lowercased()).")
                }
            }
            let shown = collection.arranged(records[name] ?? [])
            switch change.action {
            case .insert:
                guard let title = collection.titleField, values[title.name] != nil || title.type != .text else {
                    issues.append("A new \(collection.entry.isEmpty ? "entry" : collection.entry) needs \(RecordCollection.indefinite(collection.titleField?.label.lowercased() ?? "name")).")
                    continue
                }
                operations.append(.insert(collection: name, values: values))
            case .update, .delete:
                guard let record = target(change, values: values, in: collection, shown: shown) else {
                    issues.append("There's no entry \(change.entry) in \(collection.label.lowercased()).")
                    continue
                }
                if change.action == .delete {
                    operations.append(.delete(collection: name, id: record.id))
                } else if values.isEmpty {
                    issues.append("Nothing to change in entry \(change.entry).")
                } else {
                    operations.append(.update(collection: name, id: record.id, values: values))
                }
            }
        }
        return (operations, issues)
    }

    /// A field by name, or by its label, or close to either.
    static func field(_ raw: String, in collection: RecordCollection) -> RecordField? {
        if let exact = collection.field(raw) { return exact }
        let wanted = raw.lowercased()
        if let byLabel = collection.fields.first(where: { $0.label.lowercased() == wanted }) { return byLabel }
        return Checker.closestName(to: Checker.identifier(raw), in: Set(collection.fields.map(\.name))).flatMap(collection.field)
    }

    /// The entry a change means: by its number as shown, or, when the number's off, the one
    /// whose name it gives.
    private static func target(_ change: ProposedOperation, values: [String: RecordValue], in collection: RecordCollection, shown: [Record]) -> Record? {
        if change.entry >= 1, change.entry <= shown.count { return shown[change.entry - 1] }
        guard let title = collection.titleField, let named = values[title.name]?.textValue?.lowercased() else { return nil }
        return shown.first { $0[title.name]?.textValue?.lowercased() == named }
    }
}

extension Surface {
    /// Applies checked changes to the user's entries. New entries go after the rest, in the
    /// order given.
    func apply(_ operations: [RecordOperation], to records: inout [String: [Record]], at time: Date = .now) {
        for (index, operation) in operations.enumerated() {
            switch operation {
            case .insert(let name, let values):
                guard let collection = collection(name) else { continue }
                let existing = records[name] ?? []
                // Apart by a millisecond, so entries added together keep their order.
                records[name, default: []].append(collection.newRecord(values, after: existing, at: time.addingTimeInterval(Double(index) / 1000)))
            case .update(let name, let id, let values):
                guard let position = records[name]?.firstIndex(where: { $0.id == id }) else { continue }
                records[name]?[position].values.merge(values) { _, new in new }
            case .delete(let name, let id):
                records[name]?.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Changing fields

/// When a change to the screen changes a collection, the user's entries move with it: lists
/// and fields are matched by name, then by label, then by a close name; values convert to a new
/// type where they can; new fields start empty, except a new date, which starts as when the
/// entry was added. Values of fields that went away are kept, so they come back if the field does.
enum RecordMigration {
    static func migrate(_ records: [String: [Record]], from old: [RecordCollection], to new: [RecordCollection]) -> [String: [Record]] {
        guard old != new else { return records }
        var result = records
        var unmatched = old.filter { previous in !new.contains { $0.name == previous.name } }
        for collection in new {
            let previous: RecordCollection
            if let same = old.first(where: { $0.name == collection.name }) {
                previous = same
            } else if let match = match(collection, in: unmatched) {
                previous = match
                unmatched.removeAll { $0.name == match.name }
                // The entries move to the new name.
                result[collection.name] = (result[collection.name] ?? []) + (result[match.name] ?? [])
                result[match.name] = nil
            } else {
                continue
            }
            let fields = fieldMap(from: previous, to: collection)
            guard let entries = result[collection.name], !(fields.isEmpty && previous.fields == collection.fields) else { continue }
            result[collection.name] = entries.map { moved($0, fields: fields, from: previous, to: collection) }
        }
        return result
    }

    private static func match(_ collection: RecordCollection, in candidates: [RecordCollection]) -> RecordCollection? {
        if let byLabel = candidates.first(where: { $0.label.lowercased() == collection.label.lowercased() }) { return byLabel }
        if let near = Checker.closestName(to: collection.name, in: Set(candidates.map(\.name))) { return candidates.first { $0.name == near } }
        return nil
    }

    /// Old field name → new field, for fields that were renamed. Fields keeping their name map
    /// to themselves.
    static func fieldMap(from old: RecordCollection, to new: RecordCollection) -> [String: RecordField] {
        var map: [String: RecordField] = [:]
        var unclaimed = new.fields.filter { field in old.field(field.name) == nil }
        for field in old.fields {
            if let same = new.field(field.name) {
                map[field.name] = same
            } else if let renamed = unclaimed.first(where: { $0.label.lowercased() == field.label.lowercased() })
                        ?? Checker.closestName(to: field.name, in: Set(unclaimed.map(\.name))).flatMap(new.field) {
                map[field.name] = renamed
                unclaimed.removeAll { $0.name == renamed.name }
            }
        }
        return map
    }

    private static func moved(_ record: Record, fields: [String: RecordField], from old: RecordCollection, to new: RecordCollection) -> Record {
        var record = record
        var values: [String: RecordValue] = [:]
        for (name, value) in record.values {
            guard let field = fields[name], let previous = old.field(name) else {
                values[name] = values[name] ?? value
                continue
            }
            if let converted = field.converted(value, from: previous.type) { values[field.name] = converted }
        }
        for field in new.fields where values[field.name] == nil && field.type == .date && old.field(field.name) == nil {
            values[field.name] = .number(record.created.timeIntervalSince1970)
        }
        record.values = values
        return record
    }
}

// MARK: - Quick add

/// What's typed in a list's add bar, read on the phone without a model: "Milk", "Coffee 4.50",
/// "Taxi 300 yesterday travel", or several at once, "milk, eggs, bread". Numbers go to the
/// number fields in order, a date to the date, an option's name to its choice, and the rest
/// names the entry.
enum QuickAdd {
    struct Reading {
        var entries: [[String: RecordValue]]
        /// Whether it read cleanly. Sentences like "I spent 400 on lunch" are better worked out
        /// by a model, when there is one.
        var isPlain: Bool
    }

    static func read(_ text: String, for collection: RecordCollection, now: Date = .now) -> Reading {
        // Commas and new lines separate entries; a comma inside a number doesn't.
        let parts = text.split(separator: #/\n|,(?!\d{3}(?!\d))|;/#).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var plain = !text.lowercased().contains(" and ")
        var entries: [[String: RecordValue]] = []
        for part in parts {
            let (values, rest) = fields(in: part, for: collection, now: now)
            var entry = values
            let words = rest.split(separator: " ")
            if words.count > 3 { plain = false }
            if let title = collection.titleField, title.type == .text {
                guard !rest.isEmpty else {
                    plain = false
                    continue
                }
                entry[title.name] = .text(rest == rest.lowercased() ? rest.prefix(1).uppercased() + rest.dropFirst() : rest)
            } else if !rest.isEmpty {
                // Nothing to name the entry with what's left over.
                plain = false
            }
            entries.append(entry)
        }
        return Reading(entries: entries, isPlain: plain && !entries.isEmpty)
    }

    private static let filler: Set<String> = ["on", "for", "at", "in", "of", "-", "–", ":", "x", "×", "the", "a", "an"]

    /// The values a part of the text gives, and what's left to name the entry.
    private static func fields(in part: String, for collection: RecordCollection, now: Date) -> ([String: RecordValue], String) {
        var rest = part
        var values: [String: RecordValue] = [:]
        if let date = collection.dateField, let found = RecordField.detected(in: rest, now: now),
           rest[found.range].contains(where: { $0.isLetter || $0 == "/" }) {
            values[date.name] = .number(found.date.timeIntervalSince1970)
            rest.removeSubrange(found.range)
        }
        var words = rest.split(separator: " ").map(String.init)
        for field in collection.fields where [.number, .currency, .rating].contains(field.type) {
            guard let index = words.firstIndex(where: { amount(in: $0) != nil }), let number = amount(in: words[index]) else { break }
            values[field.name] = field.type == .rating ? .number(Swift.min(Swift.max(number.rounded(), 1), 5)) : .number(number)
            words.remove(at: index)
        }
        // An option's name at the end sets its choice ("taxi 300 travel"); anywhere else it's
        // part of the name ("frozen peas").
        for field in collection.fields where field.type == .choice {
            for option in field.options.sorted(by: { $0.count > $1.count }) {
                let length = option.split(separator: " ").count
                guard words.count > length, words.suffix(length).joined(separator: " ").lowercased() == option.lowercased() else { continue }
                values[field.name] = .text(option)
                words.removeLast(length)
                break
            }
        }
        while let first = words.first, filler.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, filler.contains(last.lowercased()) { words.removeLast() }
        return (values, words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// A word that's an amount: "400", "₹1,200", "4.50€", "2kg", "3x".
    private static func amount(in word: String) -> Double? {
        var core = Substring(word.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
        while let first = core.first, first.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .currencySymbol }) { core = core.dropFirst() }
        var suffix = 0
        while let last = core.last, !last.isNumber, suffix < 3 {
            core = core.dropLast()
            suffix += 1
        }
        guard let first = core.first, first.isNumber || first == "-", core.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }) else { return nil }
        return RecordField.number(in: String(core))
    }
}
