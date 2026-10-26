import Foundation

// Checking live inputs, sources and actions (ROADMAP.md, workstream 7). Bindings are part of
// the calculation, so a live input that names no field goes back to the model; actions, like
// blocks, are always fixed locally.

extension Checker {
    /// Binds each live input to a field its sources read, and gives it the field's value, format
    /// and unit: the model never types a live number. Runs in `checkLogic`, after names and
    /// units are tidied and before ranges are checked.
    static func checkLive(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        func problem(_ message: String) { issues.append(Issue(kind: .needsModel, message: message)) }

        // Every field, by its full name: weather.rainChance.
        var fields: [String: SourceField] = [:]
        for source in surface.liveSources {
            for field in source.fields { fields["\(source.name).\(field.name)"] = field }
        }
        let names = Set(fields.keys)
        var byField: [String: [String]] = [:]
        for name in names.sorted() {
            if let field = name.split(separator: ".").last { byField[String(field), default: []].append(name) }
        }

        /// The field an input means: as written, a near miss, or the only field with the name it
        /// gives, or its own name. A field's name alone must match outright: rain isn't rate.
        func bound(_ input: Input) -> String? {
            let written = input.source.trimmingCharacters(in: .whitespaces)
            if names.contains(written) { return written }
            if written.contains("."), let match = closestName(to: written, in: names) { return match }
            func same(_ a: String, _ b: String) -> Bool { a.lowercased().filter(\.isLetter) == b.lowercased().filter(\.isLetter) }
            for candidate in [written.split(separator: ".").last.map(String.init) ?? "", input.name] where !candidate.isEmpty {
                let matches = byField.filter { same($0.key, candidate) }.flatMap(\.value)
                if matches.count == 1 { return matches[0] }
            }
            return nil
        }

        for index in surface.inputs.indices {
            var input = surface.inputs[index]
            defer { surface.inputs[index] = input }
            if input.role != .live {
                guard !input.source.isEmpty else { continue }
                let full = bound(input)
                if input.role == .given, let full {
                    input.role = .live
                    fixed("Made '\(input.name)' live, since it shows \(full).")
                } else {
                    // A what-if the user changes starts where things are now.
                    if input.role == .adjustable, let full, let field = fields[full], input.format.isNumeric {
                        let value = field.converted(to: input.unit) ?? field.value
                        input.initial = value
                        input.min = Swift.min(input.min, value)
                        input.max = Swift.max(input.max, value)
                    }
                    input.source = ""
                    continue
                }
            }
            guard let full = bound(input), let field = fields[full] else {
                if surface.liveSources.isEmpty {
                    problem("'\(input.name)' is live, but nothing was fetched for it. Fetch it with the live tool and set its source to a field the tool names, or make it a given if it's a fixed fact.")
                } else {
                    problem("'\(input.name)' is live, but '\(input.source)' isn't a field the live tool returned. Set its source to one of \(names.sorted().joined(separator: ", ")), or fetch what it needs with the live tool.")
                }
                continue
            }
            if !input.source.isEmpty, input.source != full { fixed("Read the source of '\(input.name)' as \(full).") }
            input.source = full
            // It reads as what the field is: a chance as a percentage, a temperature in degrees.
            if !(field.format.isMeasured && input.format.isMeasured) { input.format = field.format }
            if field.format.isMeasured {
                if input.unit.isEmpty || field.converted(to: input.unit) == nil { input.unit = LiveUnits.local(field.value, unit: field.unit).unit }
            } else {
                input.unit = ""
            }
            input.initial = field.converted(to: input.unit) ?? field.value
        }
        return issues
    }

    /// Sources no live input shows are dropped, so the screen never reads what it doesn't use.
    /// Then each action is tidied: its name, the `{name}`s in its text, and its day, time and
    /// length, which must be readable. Runs before blocks are checked, so a block can only keep
    /// an action that survived.
    static func checkActions(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }

        let used = Set(surface.liveInputs.compactMap { $0.binding?.source })
        let unused = surface.liveSources.filter { !used.contains($0.name) }
        if !unused.isEmpty {
            let kept = surface.liveSources.filter { used.contains($0.name) }
            surface.sources = kept.isEmpty ? nil : kept
            fixed("Dropped the source\(unused.count == 1 ? "" : "s") \(unused.map { "'\($0.name)'" }.joined(separator: ", ")), which nothing shows.")
        }

        guard let original = surface.actions else { return issues }
        let values = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))
        let taken = values.union((surface.sounds ?? []).map(\.name))

        func formula(_ text: String) -> Bool {
            guard let expr = try? Expr.parse(text), expr.functionNames.isSubset(of: Expr.functions) else { return false }
            return expr.names.subtracting(Expr.constants.keys).isSubset(of: values)
        }
        /// `{name}`s the calculation can fill; others are dropped.
        func cleaned(_ text: String) -> String {
            let parts = Placeholders.parts(text).filter { part in
                guard case .name(let name) = part else { return true }
                return values.contains(name)
            }
            return Placeholders.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var names: Set<String> = []
        let actions = original.compactMap { candidate -> Action? in
            var action = candidate
            action.name = identifier(action.name.isEmpty ? action.kind : action.name)
            guard !action.name.isEmpty else { fixed("Dropped an action with no name."); return nil }
            if taken.contains(action.name) { action.name += "Action" }
            guard names.insert(action.name).inserted else { fixed("Dropped a second action named '\(action.name)'."); return nil }
            for (field, value) in action.fields {
                let tidy = Action.timing.contains(field) ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned(value)
                action.fields[field] = tidy.isEmpty ? nil : tidy
            }

            switch action.kind {
            case "calendarEvent", "reminder":
                if action["title"].isEmpty { action.fields["title"] = surface.title }
                // An event is on a day; the button says which before anything's added.
                if action.kind == "calendarEvent", action["day"].isEmpty { action.fields["day"] = "today" }
                let day = action["day"]
                if !day.isEmpty, LiveDay.date(day) == nil {
                    fixed("Dropped the action '\(action.name)', whose day can't be read: \(day).")
                    return nil
                }
                let time = action["time"]
                if !time.isEmpty, LiveDay.minutes(time) == nil, !formula(time) {
                    action.fields["time"] = nil
                    fixed("Made '\(action.name)' last all day, since its time can't be read: \(time).")
                }
                if action.kind == "calendarEvent" {
                    let duration = action["duration"]
                    if action["time"].isEmpty {
                        action.fields["duration"] = nil
                    } else if duration.isEmpty || !formula(duration) {
                        action.fields["duration"] = "60"
                    }
                } else {
                    action.fields["duration"] = nil
                }
            case "directions":
                if action["place"].isEmpty { action.fields["place"] = action["title"].isEmpty ? nil : action["title"] }
                guard !action["place"].isEmpty else {
                    fixed("Dropped the action '\(action.name)', which doesn't say where to.")
                    return nil
                }
                action.fields["travel"] = Travel(action["travel"]).rawValue
            default:
                // Another performer's, like an MCP tool's: it checks its own fields.
                break
            }
            return action
        }
        surface.actions = actions.isEmpty ? nil : actions
        return issues
    }

    /// An action block shows one action: a near-miss name is read as the action it means, and
    /// with only one action, a block naming none shows that. The button says what it does, so
    /// the block has no heading of its own.
    static func actionBlock(_ original: Block, in surface: Surface, fixed: (String) -> Void) -> Block? {
        var block = original
        (block.title, block.over, block.text, block.items, block.children) = ("", "", "", [], [])
        let names = Set((surface.actions ?? []).map(\.name))
        if names.contains(block.ref) { return block }
        if let match = closestName(to: block.ref, in: names) ?? (names.count == 1 && block.ref.isEmpty ? names.first : nil) {
            block.ref = match
            return block
        }
        fixed("Removed an action block for '\(block.ref)', which isn't an action.")
        return nil
    }

    /// Every action has one button. One that no block shows gets a block of its own at the end,
    /// after what it acts on; a row's width is for results side by side, so a row holding a
    /// button becomes a section.
    static func placeActions(_ surface: inout Surface) -> [Issue] {
        guard let actions = surface.actions else { return [] }
        var issues: [Issue] = []
        var placed: Set<String> = []

        func deduplicated(_ blocks: [Block]) -> [Block] {
            blocks.compactMap { original in
                var block = original
                if block.kind == .action {
                    guard placed.insert(block.ref).inserted else {
                        issues.append(Issue(kind: .fixed, message: "Removed a second button for '\(block.ref)'."))
                        return nil
                    }
                    return block
                }
                block.children = deduplicated(block.children)
                if block.kind == .row, block.children.contains(where: { $0.kind == .action }) { block.kind = .section }
                if block.kind.isContainer, block.children.isEmpty { return nil }
                return block
            }
        }
        surface.blocks = deduplicated(surface.blocks)

        func ids(_ blocks: [Block]) -> [String] { blocks.flatMap { [$0.id] + ids($0.children) } }
        var taken = Set(ids(surface.blocks))
        for action in actions where !placed.contains(action.name) {
            var id = "\(action.name)-action"
            while !taken.insert(id).inserted { id += "-2" }
            surface.blocks.append(Block(id: id, kind: .action, ref: action.name))
            issues.append(Issue(kind: .fixed, message: "Added a button for '\(action.name)'."))
        }
        return issues
    }
}
