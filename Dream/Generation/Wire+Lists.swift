import Foundation
import FoundationModels

// What the model writes to declare a list the user keeps (ROADMAP.md, workstream 2). The
// entries themselves are never generated into a surface; only starters anyone would begin with.

@Generable
enum WireFieldType { case text, number, currency, date, done, choice, rating }

@Generable
struct WireField {
    @Guide(description: "camelCase name used in formulas, e.g. amount")
    var name: String
    @Guide(description: "Short label the user sees")
    var label: String
    @Guide(description: "text, number, currency for money, date, done for a checkbox, choice for one of a few options, rating for 1 to 5 stars")
    var type: WireFieldType
    @Guide(description: "choice only: the options; otherwise empty")
    var options: [String]
}

@Generable
struct WireStarter {
    @Guide(description: "One value per field, in the same order, as text")
    var values: [String]
}

@Generable(description: "A list the user keeps: its fields, and any entries it starts with")
struct WireCollection {
    @Guide(description: "camelCase plural used in formulas, e.g. expenses")
    var name: String
    @Guide(description: "Short title the user sees, e.g. Expenses")
    var label: String
    @Guide(description: "What one entry is called, singular and lowercase, e.g. expense")
    var entry: String
    @Guide(description: "The first field names each entry", .count(1...6))
    var fields: [WireField]
    @Guide(description: "Only entries the request itself implies, like what to pack for a beach. Never the user's own figures, like expenses or weights. Usually empty.", .maximumCount(30))
    var starters: [WireStarter]
}

extension RecordCollection {
    init(_ wire: WireCollection) {
        let fields = wire.fields.map { RecordField($0) }
        self.init(name: wire.name, label: wire.label, entry: wire.entry, fields: fields,
                  starters: wire.starters.map { Self.starter($0.values, fields: fields) })
    }

    init?(partial wire: WireCollection.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        let fields = (wire.fields ?? []).compactMap { RecordField(partial: $0) }
        self.init(name: name, label: wire.label ?? "", entry: wire.entry ?? "", fields: fields,
                  starters: (wire.starters ?? []).map { Self.starter($0.values ?? [], fields: fields) })
    }

    /// A starter's values, written in field order, by field name.
    private static func starter(_ values: [String], fields: [RecordField]) -> [String: RecordValue] {
        var result: [String: RecordValue] = [:]
        for (field, text) in zip(fields, values) {
            if let value = field.parse(text) { result[field.name] = value }
        }
        return result
    }
}

extension RecordField {
    init(_ wire: WireField) {
        self.init(name: wire.name, label: wire.label, type: FieldType(rawValue: String(describing: wire.type)) ?? .text, options: wire.options)
    }

    init?(partial wire: WireField.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(name: name, label: wire.label ?? "", type: wire.type.flatMap { FieldType(rawValue: String(describing: $0)) } ?? .text, options: wire.options ?? [])
    }
}

extension Surface {
    /// Nil when the surface keeps no lists, so its template doesn't carry an empty one.
    static func collections(_ wires: [WireCollection]) -> [RecordCollection]? {
        wires.isEmpty ? nil : wires.map { RecordCollection($0) }
    }

    static func collections(partial wires: [WireCollection.PartiallyGenerated]?) -> [RecordCollection]? {
        let collections = (wires ?? []).compactMap { RecordCollection(partial: $0) }
        return collections.isEmpty ? nil : collections
    }
}
