import Foundation

// Checking collections, the blocks that show them, and charts of the user's entries. Like the
// rest of the block checks, mistakes here are always fixed locally.

extension Checker {
    /// Names usable in formulas and unique, labels filled in, choices with real options, and
    /// starters keyed by the fields they fill.
    static func checkCollections(_ surface: inout Surface) -> [Issue] {
        guard let collections = surface.collections, !collections.isEmpty else {
            surface.collections = nil
            return []
        }
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        let taken = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))
        var names: Set<String> = []
        surface.collections = collections.prefix(4).compactMap { original in
            var collection = original
            collection.name = identifier(collection.name.isEmpty ? collection.label : collection.name)
            guard !collection.name.isEmpty else { fixed("Dropped a list with no name."); return nil }
            if taken.contains(collection.name) {
                fixed("Renamed the list '\(collection.name)' to '\(collection.name)List', since an input or output has its name.")
                collection.name += "List"
            }
            guard names.insert(collection.name).inserted else { fixed("Dropped a second list named '\(collection.name)'."); return nil }
            collection.label = collection.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if collection.label.isEmpty { collection.label = words(collection.name) }
            collection.entry = collection.entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if collection.entry.isEmpty || collection.entry.count > 30 { collection.entry = singular(collection.label.lowercased()) }

            // Fields, remembering renames so starters stay with their fields.
            var renames: [String: String] = [:]
            var fieldNames: Set<String> = []
            collection.fields = collection.fields.prefix(8).compactMap { original in
                var field = original
                field.name = identifier(field.name.isEmpty ? field.label : field.name)
                guard !field.name.isEmpty, fieldNames.insert(field.name).inserted else { return nil }
                renames[original.name] = field.name
                field.label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if field.label.isEmpty { field.label = words(field.name) }
                if field.type == .number, looksLikeMoney(field.name + " " + field.label) {
                    field.type = .currency
                    fixed("Showed '\(collection.name).\(field.name)' as money.")
                }
                if field.type == .choice {
                    var seen: Set<String> = []
                    field.options = field.options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                    if field.options.count < 2 {
                        fixed("Made '\(collection.name).\(field.name)' text, since a choice needs at least two options.")
                        field.type = .text
                        field.options = []
                    }
                } else {
                    field.options = []
                }
                return field
            }
            if collection.fields.isEmpty {
                collection.fields = [RecordField(name: "name", label: "Name", type: .text)]
                fixed("Gave '\(collection.name)' a name for each entry, since it had no fields.")
            }

            // Starters: only known fields, each entry named, no repeats.
            let title = collection.titleField
            var titles: Set<String> = []
            collection.starters = collection.starters.prefix(40).compactMap { starter in
                var values: [String: RecordValue] = [:]
                for (name, value) in starter {
                    guard let field = collection.field(renames[name] ?? name) else { continue }
                    values[field.name] = value.textValue.flatMap { field.parse($0) } ?? (field.type.isNumeric ? value : nil)
                }
                if let title, title.type == .text {
                    guard let name = values[title.name]?.textValue, titles.insert(name.lowercased()).inserted else { return nil }
                }
                return values.isEmpty ? nil : values
            }
            return collection
        }
        if surface.collections?.isEmpty == true { surface.collections = nil }
        return issues
    }

    /// A list or an add bar shows one collection. A near-miss name is read as the one it
    /// means; with only one collection, that's the one.
    static func recordBlock(_ block: inout Block, in surface: Surface) -> (keep: Bool, fix: String?) {
        (block.over, block.text, block.items, block.children) = ("", "", [], [])
        let kind = block.kind == .add ? "bar for adding to" : "list of"
        let collections = surface.recordCollections
        guard !collections.isEmpty else { return (false, "Removed the \(kind) '\(block.ref)', since the screen keeps no list.") }
        if surface.collection(block.ref) != nil { return (true, nil) }
        let wanted = String(block.ref.split(separator: ".").first ?? "")
        let names = Set(collections.map(\.name))
        let match = surface.collection(wanted)?.name
            ?? closestName(to: wanted, in: names)
            ?? collections.first { $0.label.lowercased() == wanted.lowercased() }?.name
            ?? (collections.count == 1 ? collections[0].name : nil)
        guard let match else { return (false, "Removed the \(kind) '\(block.ref)', which isn't a list.") }
        let fix = "Read the \(kind) '\(block.ref)' as '\(match)'."
        block.ref = match
        return (true, block.ref == wanted ? nil : fix)
    }

    /// A data block drawn from the user's entries rather than from figures: `ref` is what's
    /// measured (a number field, or a collection, to count entries) and `over` is what it runs
    /// along (a date, to follow it over time) or what it's compared by (a choice, or each
    /// entry's name). False when the block isn't about a collection.
    static func boundData(_ block: inout Block, in surface: Surface) -> Bool {
        guard !surface.recordCollections.isEmpty, !block.ref.isEmpty else { return false }
        let parts = block.ref.split(separator: ".", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let names = Set(surface.recordCollections.map(\.name))
        guard let first = parts.first, let name = surface.collection(first)?.name ?? closestName(to: first, in: names),
              let collection = surface.collection(name) else { return false }
        var measured = collection.name
        if parts.count == 2 {
            let numeric = Set(collection.fields.filter { $0.type.isNumeric && $0.type != .date }.map(\.name))
            guard let field = numeric.contains(parts[1]) ? parts[1] : closestName(to: parts[1], in: numeric) else { return false }
            measured += ".\(field)"
        }
        let along = block.over.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        let groups = Set(collection.fields.filter { [.date, .choice, .text].contains($0.type) }.map(\.name))
        let over = groups.contains(along) ? along
            : closestName(to: along, in: groups)
            ?? collection.dateField?.name ?? collection.fields.first { $0.type == .choice }?.name ?? collection.titleField?.name
        guard let over else { return false }
        (block.ref, block.over, block.text, block.items, block.children) = (measured, "\(collection.name).\(over)", "", [], [])
        return true
    }

    /// Every collection is shown, and every list has a bar to add to it, just above it. A row
    /// is too narrow for a list, so a row holding one becomes a section.
    static func placeLists(_ surface: inout Surface) -> [Issue] {
        guard !surface.recordCollections.isEmpty else { return [] }
        var issues: [Issue] = []
        var ids = Set(allBlocks(surface.blocks).map(\.id))
        func uniqueID(_ base: String) -> String {
            var id = base
            var suffix = 2
            while !ids.insert(id).inserted {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            return id
        }
        func widened(_ blocks: [Block]) -> [Block] {
            blocks.map { block in
                var block = block
                if block.kind == .row, block.children.contains(where: { $0.kind == .list || $0.kind == .add }) { block.kind = .section }
                block.children = widened(block.children)
                return block
            }
        }
        surface.blocks = widened(surface.blocks)

        let all = allBlocks(surface.blocks)
        let adding = Set(all.filter { $0.kind == .add }.map(\.ref))
        func withAddBars(_ blocks: [Block]) -> [Block] {
            blocks.flatMap { block -> [Block] in
                var block = block
                block.children = withAddBars(block.children)
                // A list a service fills is the service's to add to.
                guard block.kind == .list, !adding.contains(block.ref), let collection = surface.collection(block.ref), collection.source == nil else { return [block] }
                issues.append(Issue(kind: .fixed, message: "Added a bar for adding to '\(collection.name)'."))
                return [Block(id: uniqueID("\(collection.name)-add"), kind: .add, ref: collection.name), block]
            }
        }
        surface.blocks = withAddBars(surface.blocks)

        let shown = Set(all.filter { [.list, .add].contains($0.kind) }.map(\.ref))
        let missing = surface.recordCollections.filter { !shown.contains($0.name) }
        if !missing.isEmpty {
            // After the lists already shown; with none, after the main result if it leads, or
            // else first: the list is what was asked for.
            let lastList = surface.blocks.lastIndex { block in allBlocks([block]).contains { $0.kind == .list || $0.kind == .add } }
            let position = lastList.map { $0 + 1 } ?? (surface.blocks.first?.kind == .hero ? 1 : 0)
            let blocks = missing.flatMap { [Block(id: uniqueID("\($0.name)-add"), kind: .add, ref: $0.name), Block(id: uniqueID("\($0.name)-list"), kind: .list, ref: $0.name)] }
            surface.blocks.insert(contentsOf: blocks, at: Swift.min(position, surface.blocks.count))
            issues.append(Issue(kind: .fixed, message: "Showed the lists \(missing.map { "'\($0.name)'" }.joined(separator: ", "))."))
        }
        return issues
    }

    /// A list or field a formula means, part by part: `expences.amout` → `expenses.amount`,
    /// and a list renamed by the checker (`expenses` → `expensesList`) is still found.
    static func closestColumn(to name: String, in surface: Surface) -> String? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        let collections = surface.recordCollections
        // A plain name is only read as a list when it's clearly one, so a misspelt input isn't.
        let fuzzy = parts.count == 2 ? closestName(to: first, in: Set(collections.map(\.name))).flatMap(surface.collection) : nil
        guard let collection = surface.collection(first) ?? fuzzy
                ?? collections.first(where: { [$0.name, $0.entry, $0.label].map { $0.lowercased() }.contains(first.lowercased()) }) else { return nil }
        guard parts.count == 2 else { return collection.name }
        return RecordChecker.field(parts[1], in: collection).map { "\(collection.name).\($0.name)" }
    }

    /// Whether any formula totals a list, even under a name that still needs repairing.
    static func totalsRecords(_ surface: Surface) -> Bool {
        let collections = Set(surface.recordCollections.map { $0.name.lowercased() })
        guard !collections.isEmpty else { return false }
        return surface.outputs.contains { output in
            guard let expr = try? Expr.parse(output.formula) else { return false }
            return expr.totals.contains { total in
                Expr.aggregates.contains(total.function) && (total.name.contains(".") || collections.contains(total.name.lowercased()))
            }
        }
    }

    private static func allBlocks(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { [$0] + allBlocks($0.children) }
    }

    /// "Expenses" → "expense", roughly; only for naming an entry when the model didn't.
    private static func singular(_ word: String) -> String {
        let last = word.split(separator: " ").last.map(String.init) ?? word
        let stem = last.hasSuffix("ies") ? String(last.dropLast(3)) + "y"
            : last.hasSuffix("sses") || last.hasSuffix("shes") || last.hasSuffix("ches") ? String(last.dropLast(2))
            : last.hasSuffix("s") && !last.hasSuffix("ss") ? String(last.dropLast())
            : last
        return stem.isEmpty ? "entry" : stem
    }
}
