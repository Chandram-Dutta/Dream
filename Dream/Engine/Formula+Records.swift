import Foundation

// Totals over the user's entries: `sum(expenses.amount)`, `count(groceries.done)`,
// `last(weights.value)`. A list's values reach formulas as plain numbers, so totals, progress
// and charts reuse the engine unchanged.

extension Expr {
    /// What each function makes of a whole list of values. Empty lists total 0 and count 0;
    /// there's no average, smallest or latest of nothing, so those aren't numbers.
    static func aggregate(_ function: String, of values: [Double]) throws -> Double {
        switch function {
        case "sum": return values.reduce(0, +)
        // Counts what's there: entries, checked boxes, filled-in fields.
        case "count": return Double(values.filter { $0 != 0 }.count)
        case "avg": return values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
        case "min": return values.min() ?? .nan
        case "max": return values.max() ?? .nan
        case "first": return values.first ?? .nan
        case "last": return values.last ?? .nan
        default: throw FormulaError("\(function)() can't total a list; use sum, avg, min, max, count, first or last")
        }
    }

    static let aggregates: Set<String> = ["sum", "count", "avg", "min", "max", "first", "last"]

    /// Every list reference in the formula, like `expenses.amount` in `sum(expenses.amount)`,
    /// with the function that totals it.
    var totals: [(function: String, name: String)] {
        switch self {
        case .number, .name: return []
        case .unary(_, let operand): return operand.totals
        case .binary(_, let lhs, let rhs): return lhs.totals + rhs.totals
        case .conditional(let condition, let then, let otherwise): return condition.totals + then.totals + otherwise.totals
        case .call(let function, let arguments):
            if arguments.count == 1, case .name(let name) = arguments[0] { return [(function, name)] }
            return arguments.flatMap(\.totals)
        }
    }
}

/// One point of a chart of entries: a day, a category, or an entry.
struct RecordPoint: Hashable, Identifiable {
    var label: String
    /// For a chart over time, the day.
    var day: Date?
    var value: Double
    var id: String { label }
}

extension RecordCollection {
    /// What a chart of entries shows: `measure` (a field, or nil to count entries) along a date,
    /// one point a day, or by a choice or each entry's name, one bar each. Amounts, checks and
    /// counts add up within a day or a category; other numbers, like a weight, average.
    func series(of measure: String?, along: String, in records: [Record]) -> [RecordPoint] {
        guard let axis = field(along) else { return [] }
        let measured = measure.flatMap { self.field($0) }
        func value(_ record: Record) -> Double? {
            guard let measured else { return 1 }
            if measured.type == .done { return record.isOn(measured.name) ? 1 : 0 }
            return record[measured.name]?.numberValue
        }
        let adds = measured.map { [.currency, .done].contains($0.type) } ?? true
        func combined(_ values: [Double]) -> Double {
            adds ? values.reduce(0, +) : values.reduce(0, +) / Double(Swift.max(values.count, 1))
        }
        switch axis.type {
        case .date:
            let calendar = Calendar.current
            let days = Dictionary(grouping: records.filter { value($0) != nil }) { calendar.startOfDay(for: $0.date(axis.name)) }
            return days.keys.sorted().map { day in
                RecordPoint(label: RecordField.day.string(from: day), day: day, value: combined(days[day, default: []].compactMap(value)))
            }
        case .choice:
            let groups = Dictionary(grouping: records.filter { value($0) != nil }) { $0[axis.name]?.textValue ?? "" }
            return (axis.options + [""]).compactMap { option in
                groups[option].map { RecordPoint(label: option.isEmpty ? "Other" : option, value: combined($0.compactMap(value))) }
            }
        default:
            var seen: Set<String> = []
            return arranged(records).compactMap { record in
                guard let number = value(record) else { return nil }
                let label = axis.display(record[axis.name])
                guard !label.isEmpty, seen.insert(label).inserted else { return nil }
                return RecordPoint(label: label, value: number)
            }
            .prefix(12).map { $0 }
        }
    }
}

extension Surface {
    /// Names formulas can use for lists: each collection (`groceries`, for counting entries)
    /// and each of its fields (`groceries.done`).
    var columnNames: Set<String> {
        recordCollections.reduce(into: []) { names, collection in
            names.insert(collection.name)
            for field in collection.fields { names.insert("\(collection.name).\(field.name)") }
        }
    }

    /// A list's values as numbers, oldest first so `last()` is the latest. A collection's own
    /// name gives a 1 for each entry. Done fields give 1 or 0; text and choices give 1 when
    /// filled in, so `count()` counts them; numbers and dates only where there's a value. Nil
    /// when the name isn't a list.
    func column(_ name: String, in records: [String: [Record]]) -> [Double]? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let collection = collection(parts[0]) else { return nil }
        let entries = collection.chronological(records[collection.name] ?? [])
        guard parts.count == 2 else { return entries.map { _ in 1 } }
        guard let field = collection.field(parts[1]) else { return nil }
        return entries.compactMap { record in
            switch (field.type, record[field.name]) {
            case (.done, let value): return (value?.numberValue ?? 0) != 0 ? 1 : 0
            case (_, .number(let number)?): return number
            case (_, .text(let text)?): return text.isEmpty ? nil : 1
            case (_, nil): return nil
            }
        }
    }

    /// The collections an output totals, directly or through other outputs.
    func collections(feeding name: String) -> Set<String> {
        var seen: Set<String> = []
        var found: Set<String> = []
        func walk(_ name: String) {
            guard seen.insert(name).inserted, let output = output(name), let expr = try? FormulaCache.parse(output.formula) else { return }
            for total in expr.totals {
                if let collection = total.name.split(separator: ".").first.map(String.init), self.collection(collection) != nil { found.insert(collection) }
            }
            expr.names.forEach(walk)
        }
        walk(name)
        return found
    }

    /// Whether anything is worked out from the user's entries.
    var usesRecords: Bool { outputs.contains { !collections(feeding: $0.name).isEmpty } }

    /// Each total in the formulas with its value, keyed as it's written (`sum(expenses.amount)`),
    /// so an equation worked through with live numbers can show it.
    func totals(in records: [String: [Record]]) -> [String: Double] {
        var values: [String: Double] = [:]
        for output in outputs {
            guard let expr = try? FormulaCache.parse(output.formula) else { continue }
            for total in expr.totals {
                guard let column = column(total.name, in: records), let value = try? Expr.aggregate(total.function, of: column) else { continue }
                values[Expr.call(total.function, [.name(total.name)]).description] = value
            }
        }
        return values
    }
}
