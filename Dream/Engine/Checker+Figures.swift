import Foundation

// Figures and diagrams (ROADMAP.md, workstream 5). Like other blocks, their mistakes are fixed
// here rather than sent back: a shape that can't be drawn is dropped, and the rest still teach.

extension Checker {
    /// Names made usable and unique, formulas read with near-miss names repaired, and shapes
    /// that can't be drawn at the starting values dropped. Runs before the blocks that show them.
    static func checkFigures(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        let calculation = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))

        /// A figure or diagram's own name, kept apart from the calculation's names and each other's.
        var taken = calculation
        func uniqueName(_ raw: String, fallback: String) -> String {
            let base = identifier(raw).isEmpty ? fallback : identifier(raw)
            var name = base
            var suffix = 2
            while !taken.insert(name).inserted {
                name = "\(base)\(suffix)"
                suffix += 1
            }
            return name
        }

        if let figures = surface.figures {
            let reference = surface
            surface.figures = figures.compactMap { original in
                var figure = original
                figure.name = uniqueName(figure.name, fallback: "figure")
                let issuesBefore = issues.count
                figure = checked(figure, in: reference, fixed: fixed)
                guard !figure.shapes.isEmpty || figure.points.contains(where: { !$0.label.isEmpty }) else {
                    issues.removeSubrange(issuesBefore...)
                    fixed("Dropped the figure '\(original.name)', which had nothing that could be drawn.")
                    return nil
                }
                return figure
            }
            if surface.figures?.isEmpty == true { surface.figures = nil }
        }

        if let diagrams = surface.diagrams {
            surface.diagrams = diagrams.compactMap { original in
                var diagram = original
                diagram.name = uniqueName(diagram.name, fallback: "diagram")
                diagram = checked(diagram, fixed: fixed)
                guard diagram.nodes.count >= 2 else {
                    fixed("Dropped the diagram '\(diagram.name)', which needs at least two parts.")
                    return nil
                }
                return diagram
            }
            if surface.diagrams?.isEmpty == true { surface.diagrams = nil }
        }
        return issues
    }

    /// A figure or diagram block, pointed at one that exists. Nil if there's nothing to show.
    static func visual(_ original: Block, in surface: Surface, fixed: (String) -> Void) -> Block? {
        var block = original
        (block.over, block.text, block.items, block.children) = ("", "", [], [])
        block.ref = block.ref.trimmingCharacters(in: .whitespaces)
        let names = Set(block.kind == .figure ? (surface.figures ?? []).map(\.name) : (surface.diagrams ?? []).map(\.name))
        if names.contains(block.ref) { return block }
        if let match = closestName(to: block.ref, in: names) ?? (names.count == 1 && block.ref.isEmpty ? names.first : nil) {
            block.ref = match
            return block
        }
        fixed("Removed a \(block.kind.rawValue) of '\(block.ref)', which isn't defined.")
        return nil
    }

    /// A figure or diagram no block shows still gets shown: a figure just before the controls
    /// that move it, a diagram after the opening block.
    static func placeVisuals(_ surface: inout Surface) -> [Issue] {
        var issues: [Issue] = []
        func ids(_ blocks: [Block]) -> [String] { blocks.flatMap { [$0.id] + ids($0.children) } }
        func shown(_ kind: BlockKind, in blocks: [Block]) -> Set<String> {
            blocks.reduce(into: Set<String>()) { found, block in
                if block.kind == kind { found.insert(block.ref) }
                found.formUnion(shown(kind, in: block.children))
            }
        }
        var used = Set(ids(surface.blocks))
        func uniqueID(_ base: String) -> String {
            var id = base
            var suffix = 2
            while !used.insert(id).inserted {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            return id
        }
        func controls(in block: Block) -> Set<String> {
            block.kind.isControl ? [block.ref] : block.children.reduce(into: []) { $0.formUnion(controls(in: $1)) }
        }

        let figuresShown = shown(.figure, in: surface.blocks)
        for figure in surface.figures ?? [] where !figuresShown.contains(figure.name) {
            let block = Block(id: uniqueID("figure-\(figure.name)"), kind: .figure, ref: figure.name)
            let moving = figure.inputs(in: surface)
            if let home = surface.blocks.firstIndex(where: { !controls(in: $0).isDisjoint(with: moving) }) {
                if surface.blocks[home].kind == .section {
                    let first = surface.blocks[home].children.firstIndex { $0.kind.isControl } ?? 0
                    surface.blocks[home].children.insert(block, at: first)
                } else {
                    surface.blocks.insert(block, at: home)
                }
            } else {
                surface.blocks.insert(block, at: Swift.min(1, surface.blocks.count))
            }
            issues.append(Issue(kind: .fixed, message: "Showed the figure '\(figure.name)'."))
        }
        let diagramsShown = shown(.diagram, in: surface.blocks)
        for diagram in surface.diagrams ?? [] where !diagramsShown.contains(diagram.name) {
            surface.blocks.insert(Block(id: uniqueID("diagram-\(diagram.name)"), kind: .diagram, ref: diagram.name), at: Swift.min(1, surface.blocks.count))
            issues.append(Issue(kind: .fixed, message: "Showed the diagram '\(diagram.name)'."))
        }
        return issues
    }

    // MARK: - Figures

    private static func checked(_ original: Figure, in surface: Surface, fixed: (String) -> Void) -> Figure {
        var figure = original
        let calculation = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))

        var pointNames: Set<String> = []
        figure.points = figure.points.compactMap { original in
            var point = original
            point.name = identifier(point.name)
            guard !point.name.isEmpty else { return nil }
            guard pointNames.insert(point.name).inserted else {
                fixed("In the figure '\(figure.name)', dropped a second point named '\(point.name)'.")
                return nil
            }
            point.label = label(point.label, in: surface)
            return point
        }

        /// A point's name as a shape gives it, or a near miss.
        func pointName(_ raw: String) -> String? {
            let name = raw.trimmingCharacters(in: .whitespaces)
            return pointNames.contains(name) ? name : closestName(to: name, in: pointNames)
        }

        /// `Ax`, `A_x` and `a.X` as `A.x`.
        func coordinate(_ name: String) -> String? {
            if let (point, axis) = Figure.coordinate(String(name.dropLast()) + name.suffix(1).lowercased()), let match = pointName(point) {
                return "\(match).\(axis)"
            }
            guard let axis = name.last.map({ Character($0.lowercased()) }), axis == "x" || axis == "y" else { return nil }
            var point = String(name.dropLast())
            if point.hasSuffix("_") { point.removeLast() }
            return pointNames.contains(point) ? "\(point).\(axis)" : nil
        }

        /// A formula that parses and only uses names it can, with near misses renamed. Nil if not.
        func repaired(_ formula: String, locals: Set<String> = []) -> String? {
            let source = formula.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, let expr = try? Expr.parse(source), expr.functionNames.isSubset(of: Expr.functions) else { return nil }
            var renames: [String: String] = [:]
            for name in expr.names {
                if calculation.contains(name) || locals.contains(name) || Expr.constants[name] != nil { continue }
                if let (point, _) = Figure.coordinate(name), pointNames.contains(point) { continue }
                guard let match = coordinate(name) ?? closestName(to: name, in: calculation.union(locals)) else { return nil }
                renames[name] = match
            }
            return renames.isEmpty ? source : expr.renamed(renames).description
        }

        figure.points = figure.points.compactMap { original in
            var point = original
            guard let x = repaired(point.x.isEmpty && !point.y.isEmpty ? "0" : point.x),
                  let y = repaired(point.y.isEmpty && !point.x.isEmpty ? "0" : point.y) else {
                fixed("In the figure '\(figure.name)', dropped the point '\(point.name)', whose position can't be read: (\(point.x), \(point.y)).")
                return nil
            }
            (point.x, point.y) = (x, y)
            return point
        }
        pointNames = Set(figure.points.map(\.name))

        figure.shapes = figure.shapes.compactMap { original in
            var shape = original
            let kind = words(shape.kind.rawValue).lowercased()
            let what = "\(kind.first.map { "aeiou".contains($0) } == true ? "an" : "a") \(kind)\(shape.label.isEmpty ? "" : " '\(shape.label)'")"
            func drop(_ why: String) -> FigureShape? {
                fixed("In the figure '\(figure.name)', dropped \(what), \(why).")
                return nil
            }

            // Points by name. "ABC" is read as A, B, C when those are points.
            var names: [String] = []
            for raw in shape.points.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                if let name = pointName(raw) {
                    names.append(name)
                } else if raw.count > 1, raw.allSatisfy({ pointNames.contains(String($0)) }) {
                    names += raw.map(String.init)
                } else {
                    return drop("which uses '\(raw)', not a point")
                }
            }
            guard names.count >= shape.kind.pointCount.lowerBound else { return drop("which needs \(shape.kind.pointCount.lowerBound) points") }
            shape.points = Array(names.prefix(shape.kind.pointCount.upperBound))
            shape.label = label(shape.label, in: surface)

            switch shape.kind {
            case .circle, .arc:
                guard let radius = repaired(shape.radius) else { return drop("whose radius can't be read") }
                shape.radius = radius
                if shape.kind == .arc {
                    guard let from = repaired(shape.from), let to = repaired(shape.to) else { return drop("whose angles can't be read") }
                    (shape.from, shape.to) = (from, to)
                } else {
                    (shape.from, shape.to) = ("", "")
                }
                (shape.over, shape.x, shape.y) = ("", "", "")
            case .path:
                shape.over = identifier(shape.over).isEmpty ? "t" : identifier(shape.over)
                let locals: Set<String> = [shape.over]
                guard let x = repaired(shape.x, locals: locals), let y = repaired(shape.y, locals: locals) else { return drop("whose formulas can't be read") }
                (shape.x, shape.y) = (x, y)
                // Without its own range, a path runs along its variable's.
                let ranged = surface.input(shape.over) != nil
                guard let from = shape.from.isEmpty && ranged ? "" : repaired(shape.from),
                      let to = shape.to.isEmpty && ranged ? "" : repaired(shape.to) else { return drop("which needs a first and last value for \(shape.over)") }
                (shape.from, shape.to, shape.radius) = (from, to, "")
            case .text:
                guard !shape.label.isEmpty else { return drop("with nothing to say") }
                (shape.radius, shape.from, shape.to, shape.over, shape.x, shape.y) = ("", "", "", "", "", "")
            case .segment, .arrow, .polygon, .square, .angle, .rightAngle:
                (shape.radius, shape.from, shape.to, shape.over, shape.x, shape.y) = ("", "", "", "", "", "")
            }
            return shape
        }

        // Last, what the formulas can't show until they're worked out: shapes that aren't
        // there at the starting values.
        let drawing = figure.drawing(in: surface, given: [:])
        let drawn = Set(drawing.marks.map(\.id))
        let missing = figure.points.filter { drawing.points[$0.name] == nil }.map(\.name)
        if !missing.isEmpty {
            fixed("In the figure '\(figure.name)', dropped \(missing.map { "'\($0)'" }.joined(separator: ", ")), which can't be placed at the starting values.")
            figure.points.removeAll { missing.contains($0.name) }
        }
        let shapes = figure.shapes
        figure.shapes = shapes.enumerated().compactMap { index, shape in
            if drawn.contains(index) { return shape }
            fixed("In the figure '\(figure.name)', dropped a shape (\(words(shape.kind.rawValue).lowercased())) that can't be drawn at the starting values.")
            return nil
        }
        return figure
    }

    /// A label's text, trimmed, with live values only for names the calculation has.
    private static func label(_ text: String, in surface: Surface) -> String {
        let parts = Placeholders.parts(text.trimmingCharacters(in: .whitespacesAndNewlines)).filter { part in
            guard case .name(let name) = part else { return true }
            return surface.input(name) != nil || surface.output(name) != nil
        }
        return Placeholders.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Diagrams

    private static func checked(_ original: Diagram, fixed: (String) -> Void) -> Diagram {
        var diagram = original
        var ids: Set<String> = []
        diagram.nodes = diagram.nodes.compactMap { original in
            var node = original
            node.label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            node.id = identifier(node.id.isEmpty ? node.label : node.id)
            guard !node.id.isEmpty else { return nil }
            guard ids.insert(node.id).inserted else {
                fixed("In the diagram '\(diagram.name)', dropped a second part called '\(node.id)'.")
                return nil
            }
            if node.label.isEmpty { node.label = words(node.id) }
            node.detail = prose(node.detail).trimmingCharacters(in: .whitespacesAndNewlines)
            return node
        }

        /// An edge's end, by id or near miss, or by the label the model wrote instead.
        func nodeID(_ raw: String) -> String? {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if ids.contains(name) { return name }
            if let match = closestName(to: name, in: ids) ?? closestName(to: identifier(name), in: ids) { return match }
            return diagram.nodes.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }?.id
        }

        var seen: Set<[String]> = []
        diagram.edges = diagram.edges.compactMap { original in
            var edge = original
            guard let from = nodeID(edge.from), let to = nodeID(edge.to) else {
                fixed("In the diagram '\(diagram.name)', dropped an edge from '\(edge.from)' to '\(edge.to)', which aren't both parts.")
                return nil
            }
            guard from != to, seen.insert([from, to]).inserted else { return nil }
            (edge.from, edge.to) = (from, to)
            edge.label = edge.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return edge
        }
        return diagram
    }
}
