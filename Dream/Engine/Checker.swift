import Foundation

struct Issue: Hashable, CustomStringConvertible {
    enum Kind { case fixed, needsModel, warning }
    var kind: Kind
    var message: String
    var description: String { message }
}

/// Checks generated surfaces before they're shown. It fixes what it can on its own and reports
/// the rest, so the model only spends a repair round on real mistakes. Small models get
/// structure right (guided generation guarantees it) but often get logic wrong.
enum Checker {
    static func checkLogic(_ surface: inout Surface) -> [Issue] {
        // Collections first: formulas can total them.
        let listIssues = checkCollections(&surface)
        guard surface.hasLogic else { return listIssues }
        var issues: [Issue] = listIssues
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        func problem(_ message: String) { issues.append(Issue(kind: .needsModel, message: message)) }
        func warning(_ message: String) { issues.append(Issue(kind: .warning, message: message)) }
        var hasProblems: Bool { issues.contains { $0.kind == .needsModel } }

        // Names must be usable in formulas, and unique.
        var inputNames: Set<String> = []
        surface.inputs = surface.inputs.compactMap { original in
            var input = original
            input.name = identifier(input.name.isEmpty ? input.label : input.name)
            guard !input.name.isEmpty else { fixed("Dropped an input with no name."); return nil }
            guard inputNames.insert(input.name).inserted else { fixed("Dropped a second input named '\(input.name)'."); return nil }
            if input.label.trimmingCharacters(in: .whitespaces).isEmpty { input.label = words(input.name) }
            input.symbol = symbol(input.symbol)
            // Only numbers can be fixed facts or run along a chart.
            if input.role != .adjustable, input.role != .live, !input.format.isNumeric {
                fixed("Made '\(input.name)' adjustable, since a \(input.format.rawValue) can't be \(input.role == .given ? "a given" : "a chart's axis").")
                input.role = .adjustable
            }
            return input
        }
        var outputNames: Set<String> = []
        surface.outputs = surface.outputs.compactMap { original in
            var output = original
            output.name = identifier(output.name.isEmpty ? output.label : output.name)
            guard !output.name.isEmpty else { fixed("Dropped an output with no name."); return nil }
            guard outputNames.insert(output.name).inserted else { fixed("Dropped a second output named '\(output.name)'."); return nil }
            if inputNames.contains(output.name) {
                problem("'\(output.name)' is both an input and an output. If the user enters it, keep only the input; otherwise rename the output.")
            }
            if output.label.trimmingCharacters(in: .whitespaces).isEmpty { output.label = words(output.name) }
            output.symbol = symbol(output.symbol)
            // A result can be a yes or no, like whether to take an umbrella; never a choice.
            if output.format == .choice { output.format = .number }
            return output
        }

        // The model often calls money a plain number.
        var madeCurrency: [String] = []
        for index in surface.inputs.indices where surface.inputs[index].format == .number && looksLikeMoney(surface.inputs[index].name + " " + surface.inputs[index].label) {
            surface.inputs[index].format = .currency
            madeCurrency.append(surface.inputs[index].name)
        }
        for index in surface.outputs.indices where surface.outputs[index].format == .number && looksLikeMoney(surface.outputs[index].name + " " + surface.outputs[index].label) {
            surface.outputs[index].format = .currency
            madeCurrency.append(surface.outputs[index].name)
        }
        if !madeCurrency.isEmpty { fixed("Showed \(madeCurrency.map { "'\($0)'" }.joined(separator: ", ")) as money.") }
        issues += checkUnits(&surface)
        issues += checkLive(&surface)
        issues += checkServiceLists(&surface)

        if surface.inputs.isEmpty && !totalsRecords(surface) { problem("The calculation has results but no inputs, so nothing can change.") }
        if surface.outputs.isEmpty && !surface.showsLiveValues && !surface.drivesScenes { problem("The calculation has inputs but no results calculated from them.") }

        for index in surface.inputs.indices {
            surface.inputs[index] = checkedRange(surface.inputs[index], fixed: fixed, problem: problem)
        }

        // Choices are numbers (the option's position), but models often compare them to text.
        for index in surface.outputs.indices {
            let rewritten = numberedChoices(in: surface.outputs[index].formula, inputs: surface.inputs)
            if rewritten != surface.outputs[index].formula {
                fixed("In '\(surface.outputs[index].name)', compared choices by position instead of by name.")
                surface.outputs[index].formula = rewritten
            }
        }

        // Formulas must parse and only use names that exist. Near-misses are renamed.
        let names = inputNames.union(outputNames).union(surface.columnNames)
        for index in surface.outputs.indices {
            let output = surface.outputs[index]
            let expr: Expr
            do {
                expr = try Expr.parse(output.formula)
            } catch {
                problem("The formula for '\(output.name)' can't be read (\(error)): \(output.formula)")
                continue
            }
            for function in expr.functionNames.subtracting(Expr.functions).sorted() {
                problem("The formula for '\(output.name)' uses \(function)(), which isn't available. Use only: \(Expr.functions.sorted().joined(separator: ", ")).")
            }
            var renames: [String: String] = [:]
            for name in expr.names.subtracting(names).subtracting(Expr.constants.keys).sorted() {
                if let match = closestName(to: name, in: names) ?? closestColumn(to: name, in: surface) {
                    renames[name] = match
                } else {
                    problem("The formula for '\(output.name)' uses '\(name)', which isn't an input or output. Add it as an input, or use one of: \(names.sorted().joined(separator: ", ")).")
                }
            }
            if !renames.isEmpty {
                surface.outputs[index].formula = expr.renamed(renames).description
                let list = renames.sorted { $0.key < $1.key }.map { "'\($0.key)' as '\($0.value)'" }
                fixed("In '\(output.name)', read \(list.joined(separator: ", ")).")
            }
        }
        if hasProblems { return issues }

        // Starting values that break results, usually a count of 0 that something divides by.
        if broken(surface, surface.initialValues) > 0 {
            for index in surface.inputs.indices where surface.inputs[index].format.isNumeric && surface.inputs[index].initial == 0 && !surface.inputs[index].isFixed {
                var trial = surface
                let nudge = trial.inputs[index].format == .integer ? 1 : Swift.max(trial.inputs[index].step, 1)
                trial.inputs[index].initial = nudge
                trial.inputs[index].max = Swift.max(trial.inputs[index].max, nudge)
                if broken(trial, trial.initialValues) < broken(surface, surface.initialValues) {
                    surface = trial
                    fixed("Started '\(trial.inputs[index].name)' at \(nudge.plain) instead of 0, which broke the results.")
                }
            }
        }
        let start = surface.evaluate(surface.initialValues, records: surface.sampleRecords)
        for output in surface.outputs {
            if let error = start.errors[output.name] {
                problem("'\(output.name)' can't be calculated: \(error).")
            } else if !(start.values[output.name]?.isFinite ?? false) {
                problem("'\(output.name)' isn't a number at the starting values (\(output.formula)). Avoid dividing by something that can be zero.")
            } else if surface.inputs(feeding: output.name).isEmpty && surface.collections(feeding: output.name).isEmpty {
                problem("'\(output.name)' doesn't use any input, so it never changes. Calculate it from the inputs, or make it an input if the user should enter it.")
            }
        }
        // A chart of something the calculation doesn't have, usually the very curve the screen is
        // about, like y along x, written as a name or a formula. Left alone, the chart is dropped
        // and the screen loses the part the user came to play with.
        for chart in charts(in: surface.blocks) where !chart.refs.isEmpty && !chart.refs.contains(where: { surface.output($0) != nil }) {
            problem("The chart plots '\(chart.ref)', which isn't a result. Add what it plots as an output, calculated from the inputs, and chart that.")
        }
        if hasProblems { return issues }

        // Minimums that break results: raise them by one step if that's enough.
        for index in surface.inputs.indices where surface.inputs[index].format.isNumeric && surface.inputs[index].role == .adjustable {
            let input = surface.inputs[index]
            var values = surface.initialValues
            values[input.name] = input.min
            guard broken(surface, values) > 0 else { continue }
            let lowest = input.format == .integer ? 1 : input.step
            values[input.name] = lowest
            if input.min <= 0, lowest > 0, lowest <= input.max, broken(surface, values) == 0 {
                surface.inputs[index].min = lowest
                surface.inputs[index].initial = Swift.max(surface.inputs[index].initial, lowest)
                fixed("Raised the minimum of '\(input.name)' to \(lowest.plain) so results never divide by zero.")
            } else {
                warning("Some results break when '\(input.name)' is at its minimum.")
            }
        }

        let used = surface.outputs.reduce(into: Set<String>()) { $0.formUnion(surface.inputs(feeding: $1.name)) }
        for input in surface.inputs where !used.contains(input.name) && input.role != .live {
            warning("'\(input.name)' doesn't affect any result.")
        }
        return issues
    }

    /// Block mistakes are always fixed locally: a wrong block is cheaper to drop or adjust than
    /// to send back, and the calculation it shows is already checked.
    static func checkBlocks(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        issues += checkFigures(&surface)
        issues += checkScenes(&surface)

        // A variable no chart runs along would have no control at all, so the reader sets it instead.
        let axes = charts(in: surface.blocks).reduce(into: Set<String>()) { $0.insert($1.over) }.union(surface.figureAxes).union(surface.sceneAxes)
        for index in surface.inputs.indices where surface.inputs[index].role == .variable && !axes.contains(surface.inputs[index].name) {
            surface.inputs[index].role = .adjustable
            fixed("Gave '\(surface.inputs[index].name)' a control, since no chart runs along it.")
        }
        issues += checkSounds(&surface)
        issues += checkActions(&surface)
        issues += checkCitations(&surface)
        let reference = surface

        /// `{name}` placeholders the calculation can fill; others are dropped.
        func cleaned(_ text: String) -> String {
            let parts = Placeholders.parts(text).filter { part in
                guard case .name(let name) = part else { return true }
                return reference.input(name) != nil || reference.output(name) != nil
            }
            return Placeholders.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var ids: Set<String> = []
        func uniqueID(_ raw: String) -> String {
            let base = raw.isEmpty ? "block" : raw
            var id = base
            var suffix = 2
            while !ids.insert(id).inserted {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            return id
        }

        var controlled: Set<String> = []
        var shown: Set<String> = []
        var heroes = 0

        func clean(_ original: Block, depth: Int) -> Block? {
            var block = original
            block.id = uniqueID(block.id.trimmingCharacters(in: .whitespaces))
            block.title = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
            block.text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            block.items = block.items
                .map { Item(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), value: cleaned($0.value)) }
                .filter { !$0.value.isEmpty }

            switch block.kind {
            case .section, .row:
                block.ref = ""
                block.over = ""
                block.text = ""
                block.items = []
                block.children = block.children.compactMap { clean($0, depth: depth + 1) }
                if block.kind == .row && (block.children.count > 3 || block.children.contains { $0.kind.isContainer }) {
                    block.kind = .section
                }
                if block.kind == .row {
                    block.title = ""
                    // Side by side, results share the weight.
                    for index in block.children.indices where block.children[index].kind == .hero {
                        block.children[index].kind = .metric
                        heroes -= 1
                    }
                }
                guard !block.children.isEmpty else { return nil }

            case .hero, .metric:
                (block.over, block.text, block.items, block.children) = ("", "", [], [])
                let isGiven = reference.input(block.ref)?.role == .given
                guard reference.output(block.ref) != nil || isGiven || reference.input(block.ref)?.role == .live else {
                    // An adjustable input already shows its value in its control, and a chart shows its variable.
                    fixed("Removed a \(block.kind.rawValue) for '\(block.ref)', which isn't a result.")
                    return nil
                }
                shown.insert(block.ref)
                if isGiven { block.kind = .metric }
                if block.kind == .hero {
                    heroes += 1
                    if heroes > 1 { block.kind = .metric }
                }

            case .slider, .stepper, .field, .toggle, .picker:
                (block.over, block.text, block.items, block.children) = ("", "", [], [])
                guard let input = reference.input(block.ref), input.role == .adjustable else {
                    if reference.output(block.ref) != nil || reference.input(block.ref)?.isFixed == true {
                        shown.insert(block.ref)
                        block.kind = .metric
                        fixed("'\(block.ref)' is \(reference.output(block.ref) != nil ? "a result" : reference.input(block.ref)?.role == .live ? "live" : "a given"), so it's shown instead of edited.")
                        return block
                    }
                    fixed("Removed a control for '\(block.ref)', which isn't an adjustable input.")
                    return nil
                }
                guard controlled.insert(input.name).inserted else {
                    fixed("Removed a second control for '\(input.name)'.")
                    return nil
                }
                // Fields are for exact amounts; percentages and counts are easier to slide or step.
                if !block.kind.fits(input.format) || (block.kind == .field && input.format != .currency && input.format != .number) {
                    block.kind = input.defaultControl
                }

            case .chart:
                (block.text, block.items, block.children) = ("", [], [])
                let series = block.refs.filter { reference.output($0) != nil }
                guard !series.isEmpty else {
                    fixed("Removed a chart of '\(block.ref)', which isn't a result.")
                    return nil
                }
                block.ref = series.prefix(4).joined(separator: ", ")
                let feeding = series.reduce(into: Set<String>()) { $0.formUnion(reference.inputs(feeding: $1)) }
                func runsAlong(_ input: Input) -> Bool { input.format.isNumeric && !input.isFixed && feeding.contains(input.name) }
                if let over = reference.input(block.over), runsAlong(over) {
                    // Fine as it is.
                } else if let replacement = reference.inputs.first(where: { $0.role == .variable && runsAlong($0) }) ?? reference.inputs.first(where: runsAlong) {
                    block.over = replacement.name
                } else {
                    fixed("Removed a chart of '\(block.ref)', which nothing the reader changes moves.")
                    return nil
                }
                shown.formUnion(series)

            case .equation:
                (block.over, block.children) = ("", [])
                block.items = block.items.map { Item(label: symbol($0.label), value: $0.value) }
                if !block.ref.isEmpty {
                    if reference.output(block.ref) != nil {
                        // The calculation's own formula: the text isn't needed, and its symbols
                        // are explained from the calculation itself.
                        block.text = ""
                        block.items = []
                        shown.insert(block.ref)
                    } else {
                        block.ref = ""
                    }
                }
                if block.ref.isEmpty {
                    block.text = displayMath(block.text)
                    guard !block.text.isEmpty else {
                        fixed("Dropped an empty equation.")
                        return nil
                    }
                    // Words around $-delimited maths make it prose that holds maths, not an equation.
                    let segments = TeX.segments(block.text)
                    if segments.contains(where: { if case .math = $0 { true } else { false } }),
                       segments.contains(where: { if case .text(let prose) = $0 { prose.contains { $0.isLetter } } else { false } }) {
                        block.kind = .paragraph
                        block.text = cleaned(prose(block.text))
                        block.items = []
                        fixed("Showed an equation written as sentences as a paragraph.")
                    }
                }

            case .list, .add:
                let (keep, fix) = recordBlock(&block, in: reference)
                if let fix { fixed(fix) }
                guard keep else { return nil }

            case .data:
                // A chart of the user's entries.
                if boundData(&block, in: reference) { break }
                (block.ref, block.over, block.children, block.text) = ("", "", [], "")
                let points = block.items.filter { $0.number != nil && !$0.label.isEmpty }
                if points.count >= 2 {
                    block.items = points
                } else if !block.items.isEmpty {
                    block.kind = .facts
                    fixed("Showed a data block with fewer than two numbers as facts.")
                } else {
                    return nil
                }

            case .paragraph:
                (block.ref, block.over, block.children) = ("", "", [])
                if block.text.isEmpty { block.text = block.items.map(\.value).joined(separator: " ") }
                block.items = []
                block.text = cleaned(prose(block.text))
                guard !block.text.isEmpty else { return nil }

            case .sound:
                guard let checked = soundBlock(block, in: reference, fixed: fixed) else { return nil }
                block = checked

            case .figure, .diagram:
                guard let checked = visual(block, in: reference, fixed: fixed) else { return nil }
                block = checked

            case .action:
                guard let checked = actionBlock(block, in: reference, fixed: fixed) else { return nil }
                block = checked

            case .scene:
                guard let checked = sceneBlock(block, in: reference, fixed: fixed) else { return nil }
                block = checked

            case .facts, .bullets, .steps, .timeline, .stat:
                (block.ref, block.over, block.children) = ("", "", [])
                if block.items.isEmpty {
                    guard !block.text.isEmpty else {
                        fixed("Dropped an empty \(block.kind.rawValue) block.")
                        return nil
                    }
                    block.kind = .paragraph
                } else {
                    // The model tends to repeat the items as prose here; the items are what's shown.
                    block.text = ""
                }
            }
            return block
        }

        surface.blocks = surface.blocks.compactMap { clean($0, depth: 0) }
        issues += placeVisuals(&surface)
        issues += placeScenes(&surface)
        issues += removeRepeatedUnits(&surface)

        let title = surface.title.lowercased()
        var seenTopics: Set<String> = []
        surface.related = Array(surface.related
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != title && seenTopics.insert($0.lowercased()).inserted }
            .prefix(6))

        issues += placeLists(&surface)
        issues += placeActions(&surface)

        // A calculation the blocks don't show is still placed, so it's never lost.
        guard surface.hasLogic else { return issues + placeSounds(&surface) }
        if heroes == 0, let main = surface.outputs.first?.name,
           let index = surface.blocks.firstIndex(where: { $0.kind == .metric && $0.ref == main }) {
            surface.blocks[index].kind = .hero
            heroes = 1
            fixed("Made '\(main)' the main result.")
        }
        let missingControls = surface.adjustableInputs.filter { !controlled.contains($0.name) }
        if !missingControls.isEmpty {
            let controls = missingControls.map { Block(id: uniqueID("\($0.name)-control"), kind: $0.defaultControl, ref: $0.name) }
            surface.blocks.append(Block(id: uniqueID("more-inputs"), kind: .section, children: controls))
            fixed("Added controls for \(missingControls.map { "'\($0.name)'" }.joined(separator: ", ")).")
        }
        let missingGivens = surface.inputs.filter { $0.isFixed && !shown.contains($0.name) }
        if !missingGivens.isEmpty {
            // Beside the controls, so the reader sees what the calculation takes as fixed.
            let metrics = missingGivens.map { Block(id: uniqueID("\($0.name)-given"), kind: .metric, ref: $0.name) }
            let row = Block(id: uniqueID("givens"), kind: metrics.count <= 3 ? .row : .section, children: metrics)
            if let home = surface.blocks.firstIndex(where: { $0.kind == .section && $0.children.contains { $0.kind.isControl } }) {
                surface.blocks[home].children.append(row)
            } else {
                surface.blocks.append(Block(id: uniqueID("given"), kind: .section, children: [row]))
            }
            fixed("Showed the givens \(missingGivens.map { "'\($0.name)'" }.joined(separator: ", ")).")
        }
        var missingOutputs = surface.outputs.filter { !shown.contains($0.name) }
        if !missingOutputs.isEmpty {
            fixed("Added \(missingOutputs.map { "'\($0.name)'" }.joined(separator: ", ")) to the screen.")
            if heroes == 0, let first = missingOutputs.first, first.name == surface.outputs.first?.name {
                let hero = Block(id: uniqueID("\(first.name)-hero"), kind: .hero, ref: first.name)
                // Above the first control, so the answer comes before the knobs.
                let position = surface.blocks.firstIndex { !Surface.refs(in: [$0]).isEmpty } ?? surface.blocks.endIndex
                surface.blocks.insert(hero, at: position)
                missingOutputs.removeFirst()
            }
            if !missingOutputs.isEmpty {
                let metrics = missingOutputs.map { Block(id: uniqueID("\($0.name)-metric"), kind: .metric, ref: $0.name) }
                surface.blocks.append(Block(id: uniqueID("more-results"), kind: .section, children: metrics))
            }
        }
        issues += placeCharts(&surface)
        issues += placeSounds(&surface)
        return issues
    }

    /// A chart belongs with the controls that shape it, above them: one instrument, so every
    /// number the curve depends on is in reach of it, and the curve moves as they change.
    private static func placeCharts(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func shaping(_ chart: Block) -> Set<String> {
            let feeding = chart.refs.reduce(into: Set<String>()) { $0.formUnion(surface.inputs(feeding: $1)) }
            return Set(surface.adjustableInputs.map(\.name)).intersection(feeding)
        }
        func controls(in block: Block) -> Set<String> {
            block.kind.isControl ? [block.ref] : block.children.reduce(into: []) { $0.formUnion(controls(in: $1)) }
        }
        // Charts on their own, moved into the one section that holds their controls.
        for index in surface.blocks.indices.reversed() where surface.blocks[index].kind == .chart {
            let chart = surface.blocks[index]
            let inputs = shaping(chart)
            let holders = surface.blocks.indices.filter { $0 != index && !controls(in: surface.blocks[$0]).isDisjoint(with: inputs) }
            guard holders.count == 1, surface.blocks[holders[0]].kind == .section else { continue }
            surface.blocks.remove(at: index)
            let home = holders[0] > index ? holders[0] - 1 : holders[0]
            surface.blocks[home].children.insert(chart, at: 0)
            issues.append(Issue(kind: .fixed, message: "Put the chart of '\(chart.ref)' with the controls that shape it."))
        }
        // Within a section, the chart comes before the controls.
        for index in surface.blocks.indices where surface.blocks[index].kind == .section {
            var children = surface.blocks[index].children
            guard let firstControl = children.firstIndex(where: { $0.kind.isControl }) else { continue }
            for chartIndex in children.indices.reversed() where children[chartIndex].kind == .chart && chartIndex > firstControl {
                let chart = children.remove(at: chartIndex)
                children.insert(chart, at: firstControl)
            }
            surface.blocks[index].children = children
        }
        return issues
    }

    private static func charts(in blocks: [Block]) -> [Block] {
        blocks.flatMap { $0.kind == .chart ? [$0] : charts(in: $0.children) }
    }

    /// A symbol as LaTeX: no dollar signs, and short.
    static func symbol(_ raw: String) -> String {
        let tex = TeX.repaired(raw).trimmingCharacters(in: CharacterSet(charactersIn: "$ "))
        return tex.count <= 40 ? tex : ""
    }

    /// Small models sometimes write a line break as the two characters \n.
    static func prose(_ text: String) -> String {
        text.replacing(#/\\n(?![a-zA-Z])/#, with: " ").replacingOccurrences(of: "  ", with: " ")
    }

    /// An equation's LaTeX without the delimiters models sometimes wrap it in.
    static func displayMath(_ raw: String) -> String {
        var tex = TeX.repaired(raw)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] where tex.hasPrefix(open) && tex.hasSuffix(close) && tex.count > open.count + close.count {
            tex = String(tex.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return tex
    }

    // MARK: - Helpers

    private static func checkedRange(_ original: Input, fixed: (String) -> Void, problem: (String) -> Void) -> Input {
        var input = original
        let name = input.name
        // A given is one known value; it has no range to check. Nor has a live one.
        if input.isFixed {
            if !input.initial.isFinite { problem("'\(name)' is a given without a value.") }
            (input.min, input.max) = (input.initial, input.initial)
            return input
        }
        switch input.format {
        case .toggle:
            input.min = 0
            input.max = 1
            input.step = 1
            input.initial = input.initial != 0 ? 1 : 0
        case .choice:
            input.options = input.options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if input.options.count < 2 {
                problem("'\(name)' is a choice with \(input.options.isEmpty ? "no options" : "only one option"). Give it at least two options, or use another format.")
            }
            input.min = 0
            input.max = Double(Swift.max(input.options.count - 1, 0))
            input.step = 1
            input.initial = Swift.min(Swift.max(input.initial.rounded(), 0), input.max)
        case .number, .integer, .currency, .percent:
            guard input.initial.isFinite, input.min.isFinite, input.max.isFinite else {
                problem("'\(name)' has a starting value or range that isn't a number.")
                return input
            }
            if input.format == .percent, input.max <= 1, input.initial > 0, input.initial < 1 {
                problem("'\(name)' is a percent written as a fraction. Use whole numbers (18 means 18%) and divide by 100 in formulas.")
            }
            if input.min > input.max {
                (input.min, input.max) = (input.max, input.min)
                fixed("Swapped the minimum and maximum of '\(name)'.")
            }
            if input.initial < input.min || input.initial > input.max {
                input.min = Swift.min(input.min, input.initial)
                input.max = Swift.max(input.max, input.initial)
                fixed("Widened the range of '\(name)' to include its starting value.")
            }
            if input.min == input.max {
                input.max = input.min + Swift.max(1, Swift.abs(input.min))
                fixed("Gave '\(name)' a range.")
            }
            if input.format == .integer {
                input.min = input.min.rounded(.down)
                input.max = input.max.rounded(.up)
                input.initial = input.initial.rounded()
                input.step = Swift.max(1, input.step.rounded())
            } else if !(input.step > 0) || input.step > input.max - input.min {
                input.step = niceStep((input.max - input.min) / 100)
                fixed("Picked a step for '\(name)'.")
            }
        }
        return input
    }

    /// `unit == 'cups'` → `unit == 1`, when `unit` is a choice with "cups" as its second option.
    static func numberedChoices(in formula: String, inputs: [Input]) -> String {
        guard formula.contains("'") || formula.contains("\"") else { return formula }
        var result = formula
        for input in inputs where input.format == .choice {
            for (position, option) in input.options.enumerated() {
                let name = NSRegularExpression.escapedPattern(for: input.name)
                let quoted = "['\"]\\s*" + NSRegularExpression.escapedPattern(for: option) + "\\s*['\"]"
                for pattern in ["\\b\(name)\\s*(==|!=)\\s*\(quoted)", "\(quoted)\\s*(==|!=)\\s*\\b\(name)\\b"] {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "\(input.name) $1 \(position)")
                }
            }
        }
        return result
    }

    /// How many outputs aren't finite numbers at these values.
    private static func broken(_ surface: Surface, _ values: [String: Double]) -> Int {
        let evaluation = surface.evaluate(values, records: surface.sampleRecords)
        return surface.outputs.filter { !(evaluation.values[$0.name]?.isFinite ?? false) }.count
    }

    private static let moneyWords: Set<String> = [
        "cost", "price", "bill", "rent", "salary", "income", "saving", "payment", "budget", "loan", "fee", "spend", "spending",
        "expense", "deposit", "principal", "balance", "fare", "wage", "profit", "revenue", "debt", "money", "cash", "tip",
        "earning", "investment", "mortgage", "pension", "tax", "emi", "fund",
    ]

    /// Whole words only, so "billions" isn't a bill. Words split at camel case, keeping
    /// acronyms like EMI whole.
    static func looksLikeMoney(_ text: String) -> Bool {
        text.matches(of: #/[A-Z]+(?![a-z])|[A-Z]?[a-z]+/#).map { $0.output.lowercased() }.contains { word in
            moneyWords.contains(word) || (word.hasSuffix("s") && moneyWords.contains(String(word.dropLast())))
        }
    }

    /// "Tip percent" → "tipPercent". Names that are already identifiers are left alone.
    static func identifier(_ raw: String) -> String {
        let parts = raw.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        guard let first = parts.first else { return "" }
        var result = parts.count == 1
            ? first
            : first.prefix(1).lowercased() + first.dropFirst() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if result.first?.isNumber == true { result = "n" + result }
        return result
    }

    /// "tipPercent" → "Tip percent".
    static func words(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase, !result.isEmpty { result += " " + character.lowercased() } else { result.append(character) }
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        let leading = raw / magnitude
        return (leading < 1.5 ? 1 : leading < 3.5 ? 2 : leading < 7.5 ? 5 : 10) * magnitude
    }

    static func closestName(to name: String, in names: Set<String>) -> String? {
        let lower = name.lowercased()
        let candidates = names.sorted()
        if let match = candidates.first(where: { $0.lowercased() == lower }) { return match }
        let compact = lower.filter { $0.isLetter || $0.isNumber }
        if let match = candidates.first(where: { $0.lowercased().filter { $0.isLetter || $0.isNumber } == compact }) { return match }
        if lower.count >= 4 {
            let near = candidates.filter { distance(lower, $0.lowercased()) <= 2 }
            if near.count == 1 { return near[0] }
        }
        if lower.count >= 3 {
            let prefixed = candidates.filter { $0.lowercased().hasPrefix(lower) }
            if prefixed.count == 1 { return prefixed[0] }
        }
        return nil
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension Surface {
    /// Small models occasionally loop: one block that never ends, or the same sentence again and
    /// again. Real blocks are short, so either is a sign to stop and keep what came before.
    var isRepeatingItself: Bool {
        if summary.count > 600 { return true }
        var seenTexts: Set<String> = []
        func loops(in blocks: [Block]) -> Bool {
            for block in blocks {
                if block.text.count > 1400 { return true }
                if block.items.contains(where: { $0.value.count > 500 || $0.label.count > 200 }) { return true }
                let sentences = block.text.lowercased()
                    .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count >= 24 }
                if Set(sentences).count < sentences.count { return true }
                if !block.text.isEmpty, !seenTexts.insert(block.text.lowercased()).inserted { return true }
                let values = block.items.map { $0.value.lowercased() }
                if values.count >= 4, Set(values).count <= values.count / 2 { return true }
                if loops(in: block.children) { return true }
            }
            return false
        }
        return loops(in: blocks)
    }
}
