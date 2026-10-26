import Foundation

// 3D scenes (ROADMAP.md, workstream 10). Like figures, their mistakes are fixed here rather
// than sent back: an object that can't be placed is dropped, and the rest still teach.

extension Checker {
    /// Names made usable and unique, placements and formulas read with near misses repaired,
    /// and objects and plots that can't be drawn at the starting values dropped. Runs after
    /// figures and before the blocks that show scenes.
    static func checkScenes(_ surface: inout Surface) -> [Issue] {
        guard let scenes = surface.scenes else { return [] }
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        var taken = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name) + (surface.figures ?? []).map(\.name) + (surface.diagrams ?? []).map(\.name))
        let reference = surface
        surface.scenes = scenes.compactMap { original in
            var scene = original
            scene.name = unique(identifier(scene.name), fallback: "scene", in: &taken)
            scene = checked(scene, in: reference, fixed: fixed)
            guard !scene.objects.isEmpty || !scene.plots.isEmpty || scene.molecule != nil else {
                fixed("Dropped the scene '\(scene.name)', which had nothing that could be drawn.")
                return nil
            }
            return scene
        }
        if surface.scenes?.isEmpty == true { surface.scenes = nil }
        return issues
    }

    /// A scene block, pointed at a scene that exists. Nil if there's nothing to show.
    static func sceneBlock(_ original: Block, in surface: Surface, fixed: (String) -> Void) -> Block? {
        var block = original
        (block.over, block.text, block.items, block.children) = ("", "", [], [])
        block.ref = block.ref.trimmingCharacters(in: .whitespaces)
        let names = Set((surface.scenes ?? []).map(\.name))
        if names.contains(block.ref) { return block }
        if let match = closestName(to: block.ref, in: names) ?? (names.count == 1 && block.ref.isEmpty ? names.first : nil) {
            block.ref = match
            return block
        }
        fixed("Removed a scene of '\(block.ref)', which isn't defined.")
        return nil
    }

    /// A scene no block shows still gets shown: just before the controls that move it, or
    /// after the opening block.
    static func placeScenes(_ surface: inout Surface) -> [Issue] {
        guard let scenes = surface.scenes else { return [] }
        var issues: [Issue] = []
        func ids(_ blocks: [Block]) -> [String] { blocks.flatMap { [$0.id] + ids($0.children) } }
        func shown(in blocks: [Block]) -> Set<String> {
            blocks.reduce(into: Set<String>()) { found, block in
                if block.kind == .scene { found.insert(block.ref) }
                found.formUnion(shown(in: block.children))
            }
        }
        func controls(in block: Block) -> Set<String> {
            block.kind.isControl ? [block.ref] : block.children.reduce(into: []) { $0.formUnion(controls(in: $1)) }
        }
        var used = Set(ids(surface.blocks))
        let showing = shown(in: surface.blocks)
        for scene in scenes where !showing.contains(scene.name) {
            var id = "scene-\(scene.name)"
            while !used.insert(id).inserted { id += "-2" }
            let block = Block(id: id, kind: .scene, ref: scene.name)
            let moving = scene.inputs(in: surface)
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
            issues.append(Issue(kind: .fixed, message: "Showed the scene '\(scene.name)'."))
        }
        return issues
    }

    // MARK: - Scenes

    private static func unique(_ raw: String, fallback: String, in taken: inout Set<String>) -> String {
        let base = raw.isEmpty ? fallback : raw
        var name = base
        var suffix = 2
        while !taken.insert(name).inserted {
            name = "\(base)\(suffix)"
            suffix += 1
        }
        return name
    }

    private static func checked(_ original: Scene3D, in surface: Surface, fixed: (String) -> Void) -> Scene3D {
        var scene = original
        let calculation = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))

        if var molecule = scene.molecule {
            molecule.name = molecule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if molecule.name.isEmpty {
                scene.molecule = nil
            } else if molecule.structure == nil {
                fixed("In the scene '\(scene.name)', dropped the molecule '\(molecule.name)': PubChem has no 3D structure for it.")
                scene.molecule = nil
            } else {
                scene.molecule = molecule
            }
        }

        var objectNames: Set<String> = []
        scene.objects = scene.objects.enumerated().compactMap { index, original in
            var object = original
            let base = identifier(object.name).isEmpty ? "\(object.kind.rawValue)\(index + 1)" : identifier(object.name)
            object.name = unique(base, fallback: object.kind.rawValue, in: &objectNames)
            return object
        }

        /// A formula that parses and only uses names it can, with near misses renamed. Nil if not.
        func repaired(_ formula: String, locals: Set<String> = []) -> String? {
            let source = formula.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, let expr = try? Expr.parse(source), expr.functionNames.isSubset(of: Expr.functions) else { return nil }
            return repaired(expr, locals: locals)?.description
        }
        func repaired(_ expr: Expr, locals: Set<String>) -> Expr? {
            guard expr.functionNames.isSubset(of: Expr.functions) else { return nil }
            var renames: [String: String] = [:]
            for name in expr.names {
                if calculation.contains(name) || locals.contains(name) || Expr.constants[name] != nil { continue }
                guard let match = closestName(to: name, in: calculation.union(locals)) else { return nil }
                renames[name] = match
            }
            return renames.isEmpty ? expr : expr.renamed(renames)
        }

        /// An object, the ground, or a nested placement, as a place argument. `origin` and
        /// `floor` are what models call the obvious places.
        func place(_ argument: Expr, placing name: String) -> Expr? {
            switch argument {
            case .name(let raw):
                if objectNames.contains(raw) { return raw == name ? nil : argument }
                switch raw.lowercased() {
                case "ground", "floor", "table", "surface": return .name(ScenePlacement.ground)
                case "origin", "center", "centre", "o": return .call("at", [.number(0), .number(0), .number(0)])
                default: break
                }
                if let match = closestName(to: raw, in: objectNames), match != name { return .name(match) }
                return nil
            case .call:
                return placement(argument, placing: name)
            default:
                return nil
            }
        }

        /// Whether `at` was given a place first, rather than a number: a placement, or a name
        /// the calculation doesn't have.
        func namesPlace(_ argument: Expr) -> Bool {
            switch argument {
            case .call(let function, _): return ScenePlacement.isHelper(ScenePlacement.synonyms[function] ?? function)
            case .name(let name): return !calculation.contains(name) && Expr.constants[name] == nil
            default: return false
            }
        }

        /// A placement with its helper and arguments checked and repaired. Nil if it can't be read.
        func placement(_ expr: Expr, placing name: String) -> Expr? {
            switch expr {
            case .name:
                return place(expr, placing: name)
            case .call(let raw, let arguments):
                let function = ScenePlacement.synonyms[raw] ?? (ScenePlacement.isHelper(raw) ? raw : closestName(to: raw, in: Set(ScenePlacement.helpers.keys).union(["at"])))
                guard let function else { return nil }
                if function == "at" {
                    // From a place, or at numbers.
                    if let first = arguments.first, namesPlace(first), let from = place(first, placing: name) {
                        let offsets = arguments.dropFirst().prefix(3).map { repaired($0, locals: []) }
                        return offsets.contains(where: { $0 == nil }) ? nil : .call("at", [from] + offsets.compactMap { $0 })
                    }
                    let numbers = arguments.prefix(3).map { repaired($0, locals: []) }
                    guard !numbers.isEmpty, !numbers.contains(where: { $0 == nil }) else { return nil }
                    return .call("at", numbers.compactMap { $0 })
                }
                guard let helper = ScenePlacement.helpers[function], arguments.count >= helper.required else { return nil }
                var checked: [Expr] = []
                for (argument, kind) in zip(arguments, helper.arguments) {
                    switch kind {
                    case .place:
                        guard let fixed = place(argument, placing: name) else { return nil }
                        checked.append(fixed)
                    case .number:
                        guard let fixed = repaired(argument, locals: []) else { return nil }
                        checked.append(fixed)
                    }
                }
                return .call(function, checked)
            default:
                return nil
            }
        }

        /// A position as written, read leniently: (1, 2, 3) and [1, 2, 3] as at(1, 2, 3).
        func position(_ raw: String, placing name: String) -> String? {
            var source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.hasPrefix("[") && source.hasSuffix("]") { source = "(" + source.dropFirst().dropLast() + ")" }
            guard !source.isEmpty else { return nil }
            if let expr = try? Expr.parse(source) {
                switch expr {
                case .call, .name: return placement(expr, placing: name)?.description
                default: break
                }
            }
            // Coordinates on their own.
            let inner = source.hasPrefix("(") && source.hasSuffix(")") ? String(source.dropFirst().dropLast()) : source
            guard let expr = try? Expr.parse("at(\(inner))") else { return nil }
            return placement(expr, placing: name)?.description
        }

        scene.objects = scene.objects.compactMap { original in
            var object = original
            let what = "the \(words(object.kind.rawValue).lowercased()) '\(object.name)'"
            func drop(_ why: String) -> SceneObject? {
                fixed("In the scene '\(scene.name)', dropped \(what), \(why).")
                return nil
            }
            if object.position.trimmingCharacters(in: .whitespaces).isEmpty {
                object.position = "at(0, 0, 0)"
            } else {
                guard let place = position(object.position, placing: object.name) else { return drop("whose position can't be read: \(object.position)") }
                object.position = place
            }
            if object.kind.isSpan {
                guard let end = position(object.to, placing: object.name) else { return drop("which needs somewhere to end") }
                object.to = end
            } else {
                object.to = ""
            }

            // Sizes, as many as the kind takes.
            let size = object.size.trimmingCharacters(in: .whitespaces)
            if size.isEmpty || object.kind == .text {
                object.size = ""
            } else {
                guard case .call(_, let arguments)? = try? Expr.parse("size(\(size))") else { return drop("whose size can't be read: \(size)") }
                let sizes = arguments.prefix(object.kind.sizeNames.count).map { repaired($0, locals: []) }
                guard !sizes.contains(where: { $0 == nil }) else { return drop("whose size can't be read: \(size)") }
                object.size = sizes.compactMap { $0?.description }.joined(separator: ", ")
            }
            for keyPath in [\SceneObject.turn, \SceneObject.tilt] {
                let raw = object[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, raw != "0" else {
                    object[keyPath: keyPath] = ""
                    continue
                }
                guard let angle = repaired(raw) else {
                    fixed("In the scene '\(scene.name)', \(what) is drawn upright: its angle can't be read (\(raw)).")
                    object[keyPath: keyPath] = ""
                    continue
                }
                object[keyPath: keyPath] = angle
            }
            object.label = sceneLabel(object.label, in: surface)
            if object.kind == .text, object.label.isEmpty { return drop("with nothing to say") }
            return object
        }

        // Plots run along their own x and y. Without a range they take their inputs', or -2 to 2.
        scene.plots = scene.plots.compactMap { original in
            var plot = original
            guard let z = repaired(plot.z, locals: ["x", "y"]) else {
                fixed("In the scene '\(scene.name)', dropped a plot whose formula can't be read: \(plot.z)")
                return nil
            }
            plot.z = z
            for (axis, from, to) in [("x", \ScenePlot.xFrom, \ScenePlot.xTo), ("y", \ScenePlot.yFrom, \ScenePlot.yTo)] {
                let range = surface.input(axis)?.safeRange ?? -2...2
                plot[keyPath: from] = repaired(plot[keyPath: from]) ?? range.lowerBound.plain
                plot[keyPath: to] = repaired(plot[keyPath: to]) ?? range.upperBound.plain
            }
            plot.label = sceneLabel(plot.label, in: surface)
            return plot
        }

        // The time it plays: an input that can be swept. A variable only the scene runs along is
        // its time even if the model didn't say so.
        let time = identifier(scene.time)
        let sweepable = Set(surface.inputs.filter { $0.role != .given && $0.format.isNumeric }.map(\.name))
        if sweepable.contains(time) {
            scene.time = time
        } else if !time.isEmpty, let match = closestName(to: time, in: sweepable) {
            scene.time = match
        } else {
            let variables = scene.inputs(in: surface).filter { surface.input($0)?.role == .variable && !(["x", "y"].contains($0) && !scene.plots.isEmpty) }
            scene.time = variables.count == 1 ? variables.first! : ""
        }

        // Last, what the formulas can't show until they're worked out: what isn't there at the
        // starting values.
        let drawing = scene.drawing(in: surface, values: surface.evaluate(surface.initialValues).values, plotGrid: 12)
        let objects = scene.objects
        scene.objects = objects.filter { object in
            if drawing.placed.contains(object.name) { return true }
            fixed("In the scene '\(scene.name)', dropped the \(words(object.kind.rawValue).lowercased()) '\(object.name)', which can't be placed at the starting values.")
            return false
        }
        let plots = scene.plots
        scene.plots = plots.enumerated().compactMap { index, plot in
            if drawing.plots.contains(where: { $0.id == index }) { return plot }
            fixed("In the scene '\(scene.name)', dropped a plot (\(plot.z)) that can't be drawn at the starting values.")
            return nil
        }
        return scene
    }

    /// A label's text, trimmed, with live values only for names the calculation has.
    private static func sceneLabel(_ text: String, in surface: Surface) -> String {
        let parts = Placeholders.parts(text.trimmingCharacters(in: .whitespacesAndNewlines)).filter { part in
            guard case .name(let name) = part else { return true }
            return surface.input(name) != nil || surface.output(name) != nil
        }
        return Placeholders.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Scene3D {
    /// Every formula in the scene: placements and sizes, angles and plots.
    var formulas: [String] {
        objects.flatMap { [$0.position, $0.to, $0.size.isEmpty ? "" : "size(\($0.size))", $0.turn, $0.tilt] }
            + plots.flatMap { [$0.z, $0.xFrom, $0.xTo, $0.yFrom, $0.yTo] }
    }

    /// The inputs the scene depends on, directly or through outputs. A plot's own x and y aren't
    /// inputs, even where the calculation has inputs with those names.
    func inputs(in surface: Surface) -> Set<String> {
        let plotFormulas = Set(plots.map(\.z))
        return formulas.filter { !$0.isEmpty }.reduce(into: Set<String>()) { found, formula in
            guard let expr = try? FormulaCache.parse(formula) else { return }
            for name in expr.names where !(plotFormulas.contains(formula) && (name == "x" || name == "y")) {
                found.formUnion(surface.inputs(feeding: name))
            }
        }
    }
}

extension Surface {
    /// Whether any scene moves with an input, so the inputs have something to show even with
    /// no results calculated from them, like the planets' places on a given day.
    var drivesScenes: Bool {
        (scenes ?? []).contains { scene in
            scene.formulas.contains { formula in
                guard let names = (try? Expr.parse(formula))?.names else { return false }
                return names.contains { input($0) != nil }
            }
        }
    }
}
