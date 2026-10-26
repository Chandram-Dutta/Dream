import Foundation

// Connected services as live data (ROADMAP.md, workstream 8). A connected service's read tool
// is a source like the weather: its numbers bind to live inputs, and a list it returns, like
// open issues, fills a collection the screen keeps current. Its write tools are action buttons.
// What it read is written into the page, so sharing says so and leaves out what it can.

/// A list a source reads: its name, and the keys each row has, which a collection's fields are
/// named after.
struct SourceList: Codable, Hashable, Sendable {
    var name: String
    var keys: [String]
    /// How many rows it had when it was fetched while writing.
    var count: Int
}

extension Source {
    /// Which kind of source a connected service's read tool is.
    static let connectionKind = "connection"

    var isConnection: Bool { kind == Self.connectionKind }
}

extension Action {
    /// Which kind of action a connected service's write tool is.
    static let connectionKind = "connection"

    var isConnection: Bool { kind == Self.connectionKind }
}

extension RecordCollection {
    /// The source and list that fill it: searchNotes.notes is the list notes of searchNotes.
    var listSource: (source: String, list: String)? {
        guard let source else { return nil }
        let parts = source.split(separator: ".", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// A service's rows as entries. Each field takes the row's value under its own name, or
    /// the nearest key, read as the field's type. Ids come from the row, so an entry keeps its
    /// place and identity from one reading to the next.
    func records(from rows: [[String: RecordValue]]) -> [Record] {
        let keys = Set(rows.flatMap(\.keys))
        let fieldKeys = Dictionary(fields.map { field in
            (field.name, keys.contains(field.name) ? field.name : Self.nearest(field.name, in: keys))
        }, uniquingKeysWith: { first, _ in first })
        var seen: [String: Int] = [:]
        return rows.enumerated().map { index, row in
            var values: [String: RecordValue] = [:]
            for field in fields {
                guard let key = fieldKeys[field.name] ?? nil, let raw = row[key], let value = field.reading(raw) else { continue }
                values[field.name] = value
            }
            var identity = ["id", "identifier", "key", "url", "uri", "slug"].lazy.compactMap { row[$0].map(\.plain) }.first
                ?? titleField.flatMap { values[$0.name] }.map(\.plain) ?? String(index)
            // Two rows alike still get an entry each.
            seen[identity, default: 0] += 1
            if let repeats = seen[identity], repeats > 1 { identity += "#\(repeats)" }
            return Record(id: StableID.make("\(name)/\(identity)"), values: values, order: Double(index),
                          created: Date(timeIntervalSinceReferenceDate: Double(-index)))
        }
    }

    /// A key that's the same name written another way: dueDate for due_date or DueDate.
    private static func nearest(_ name: String, in keys: Set<String>) -> String? {
        let plain = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return keys.first { $0.lowercased().filter { $0.isLetter || $0.isNumber } == plain }
            ?? Checker.closestName(to: name, in: keys)
    }
}

extension RecordField {
    /// A value a service sent, as this field holds it.
    func reading(_ value: RecordValue) -> RecordValue? {
        switch (type, value) {
        case (.text, .text): return value
        case (.text, .number(let number)): return .text(number.plain)
        case (.number, .number), (.currency, .number), (.done, .number): return value
        case (.rating, .number(let stars)): return .number(min(max(stars.rounded(), 1), 5))
        case (.date, .number(let number)):
            // Services count time in seconds or in milliseconds since 1970.
            return .number(number > 100_000_000_000 ? number / 1000 : number)
        case (.choice, _): return option(matching: value.plain).map { .text($0) }
        case (_, .text(let text)): return parse(text)
        }
    }
}

extension RecordValue {
    fileprivate var plain: String {
        switch self {
        case .number(let number): number.plain
        case .text(let text): text
        }
    }
}

extension Surface {
    /// The entries each collection a source fills would have from this reading, by collection.
    func serviceRecords(_ reading: SourceReading, from source: String) -> [String: [Record]] {
        var found: [String: [Record]] = [:]
        for collection in recordCollections {
            guard let bound = collection.listSource, bound.source == source, let rows = reading.lists[bound.list] else { continue }
            found[collection.name] = collection.records(from: rows)
        }
        return found
    }

    /// Only the lists the user keeps: talking to a list can't change a service's.
    var keepingOwnLists: Surface {
        var surface = self
        let own = recordCollections.filter { $0.source == nil }
        surface.collections = own.isEmpty ? nil : own
        return surface
    }

    /// The template without what can safely go from what a service gave it, for sharing and for
    /// opening what someone shared. Buttons that act on a service go: a reader's Dream must
    /// never act on their own services from someone else's page. A source keeps the values it
    /// read and the service's name, but not what was asked of it or where it is, so a reader's
    /// Dream never reads their own services for it either. What the model wrote from a service
    /// stays, which is why the share sheet asks first.
    var forgettingConnections: Surface {
        var surface = self
        let buttons = Set((actions ?? []).filter(\.isConnection).map(\.name))
        if !buttons.isEmpty {
            let kept = (actions ?? []).filter { !$0.isConnection }
            surface.actions = kept.isEmpty ? nil : kept
            func without(_ blocks: [Block]) -> [Block] {
                blocks.compactMap { block in
                    if block.kind == .action, buttons.contains(block.ref) { return nil }
                    var block = block
                    block.children = without(block.children)
                    return block.kind.isContainer && block.children.isEmpty ? nil : block
                }
            }
            surface.blocks = without(blocks)
        }
        surface.sources = sources?.map { source in
            guard source.isConnection else { return source }
            var kept = source
            kept.parameters = source["service"].isEmpty ? [:] : ["service": source["service"]]
            return kept
        }
        return surface
    }
}

extension Checker {
    /// A collection filled by a service's list must name a list a source read; a near miss is
    /// read as the list it means. Its entries are the service's, so it has no starters and no
    /// bar for adding to it. Runs in `checkLogic`, after sources are bound.
    static func checkServiceLists(_ surface: inout Surface) -> [Issue] {
        guard var collections = surface.collections, collections.contains(where: { $0.source != nil }) else { return [] }
        var issues: [Issue] = []
        let lists = Set(surface.liveSources.flatMap { source in (source.lists ?? []).map { "\(source.name).\($0.name)" } })
        for index in collections.indices {
            guard let written = collections[index].source?.trimmingCharacters(in: .whitespaces) else { continue }
            if written.isEmpty {
                collections[index].source = nil
                continue
            }
            if !lists.contains(written) {
                if let match = closestName(to: written, in: lists) {
                    collections[index].source = match
                    issues.append(Issue(kind: .fixed, message: "Filled '\(collections[index].name)' from \(match), for \(written)."))
                } else {
                    let named = lists.isEmpty ? "No service returned a list." : "Lists a service returned: \(lists.sorted().joined(separator: ", "))."
                    issues.append(Issue(kind: .needsModel, message: "The list '\(collections[index].name)' is filled from \(written), which no connected service returned. \(named) Leave its source empty for a list the user keeps."))
                    continue
                }
            }
            if !collections[index].starters.isEmpty {
                collections[index].starters = []
                issues.append(Issue(kind: .fixed, message: "Took the starters out of '\(collections[index].name)', which a service fills."))
            }
        }
        surface.collections = collections
        let filled = Set(collections.filter { $0.source != nil }.map(\.name))
        func withoutBars(_ blocks: [Block]) -> [Block] {
            blocks.compactMap { block in
                if block.kind == .add, filled.contains(block.ref) {
                    issues.append(Issue(kind: .fixed, message: "Removed the bar for adding to '\(block.ref)', which a service fills."))
                    return nil
                }
                var block = block
                block.children = withoutBars(block.children)
                return block
            }
        }
        surface.blocks = withoutBars(surface.blocks)
        return issues
    }
}

/// The same id for the same text, every time: a service's row keeps its identity between readings.
enum StableID {
    static func make(_ text: String) -> UUID {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x100_0000_01b3 &+ 0x9e37_79b9
        }
        let bytes = withUnsafeBytes(of: a.bigEndian) { Array($0) } + withUnsafeBytes(of: b.bigEndian) { Array($0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
