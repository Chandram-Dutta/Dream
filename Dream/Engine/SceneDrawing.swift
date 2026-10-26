import Foundation
import simd

/// An axis-aligned box in a scene.
struct Box3: Hashable {
    var min: Vec3
    var max: Vec3

    init(min: Vec3, max: Vec3) {
        (self.min, self.max) = (min, max)
    }

    init(center: Vec3, half: Vec3) {
        self.init(min: center - half, max: center + half)
    }

    init?(containing points: some Sequence<Vec3>) {
        var box: Box3?
        for point in points where point.x.isFinite && point.y.isFinite && point.z.isFinite {
            box = box.map { $0.union(Box3(min: point, max: point)) } ?? Box3(min: point, max: point)
        }
        guard let box else { return nil }
        self = box
    }

    var center: Vec3 { (min + max) / 2 }
    var half: Vec3 { (max - min) / 2 }
    /// The radius of the sphere round it.
    var radius: Double { simd_length(half) }

    func union(_ other: Box3) -> Box3 { Box3(min: simd_min(min, other.min), max: simd_max(max, other.max)) }

    /// The part of this box inside `other`, or `other` itself if they don't meet.
    func clamped(to other: Box3) -> Box3 {
        let low = simd_max(min, other.min), high = simd_min(max, other.max)
        return low.x <= high.x && low.y <= high.y && low.z <= high.z ? Box3(min: low, max: high) : other
    }

    func contains(_ other: Box3, tolerance: Double = 1e-9) -> Bool {
        other.min.x >= min.x - tolerance && other.min.y >= min.y - tolerance && other.min.z >= min.z - tolerance
            && other.max.x <= max.x + tolerance && other.max.y <= max.y + tolerance && other.max.z <= max.z + tolerance
    }

    var corners: [Vec3] {
        [0, 1].flatMap { i in [0, 1].flatMap { j in [0, 1].map { k in Vec3(i == 0 ? min.x : max.x, j == 0 ? min.y : max.y, k == 0 ? min.z : max.z) } } }
    }
}

/// A scene at one set of values: every object resolved to the solids drawn for it, the plots
/// to their meshes, and the molecule to balls and sticks, in the scene's maths axes with heights
/// scaled for display. What can't be drawn at these values, like an object placed on itself or
/// a size that isn't a number, is left out rather than drawn wrong.
struct SceneDrawing {
    struct Solid: Identifiable, Hashable {
        /// The renderer's unit shapes, which `scale` stretches. A ring keeps its own mesh,
        /// since stretching would thicken its hoop.
        enum Shape: Hashable {
            /// Radius 1.
            case sphere
            /// 1 along each side.
            case box
            /// Radius 1 and height 1, upright, centred on its middle.
            case cylinder
            /// Radius 1 and height 1, pointing up, centred on its middle.
            case cone
            /// 1 by 1, level.
            case plane
            /// Radius 1, level, its hoop this thick.
            case ring(Double)
        }

        enum Paint: Hashable {
            case tone(SceneObject.Tone)
            /// An atom, by atomic number.
            case element(Int)
            /// A bond between atoms.
            case bond
        }

        /// Stable as values change, so the renderer moves what's there rather than rebuilding it.
        let id: String
        let shape: Shape
        let center: Vec3
        /// Along the shape's own axes, before it's turned.
        let scale: Vec3
        let rotation: simd_quatd
        let paint: Paint
        /// Setting rather than subject, like a faint ground or axes: the view doesn't shrink
        /// the scene to fit all of it.
        var isBackdrop = false

        /// How far it reaches from its centre along each axis, once turned.
        var half: Vec3 {
            let local: Vec3
            switch shape {
            case .sphere: local = scale
            case .box: local = scale / 2
            case .cylinder, .cone: local = Vec3(scale.x, scale.y, scale.z / 2)
            case .plane: local = Vec3(scale.x / 2, scale.y / 2, 0)
            case .ring(let ratio): local = Vec3(scale.x * (1 + ratio), scale.y * (1 + ratio), scale.z * ratio)
            }
            let turned = simd_matrix3x3(rotation)
            let reach = simd_double3x3(columns: (simd_abs(turned.columns.0), simd_abs(turned.columns.1), simd_abs(turned.columns.2)))
            return reach * local
        }
    }

    struct Label: Identifiable, Hashable {
        let id: Int
        let text: String
        let anchor: Vec3
        /// Centred on its anchor, like an axis's letter, rather than beside it.
        let centered: Bool
        let tone: SceneObject.Tone?
    }

    struct Plot: Identifiable {
        let id: Int
        let mesh: SceneMesh
        /// The heights it reaches at these values, before scaling for display.
        let low: Double
        let high: Double
    }

    var solids: [Solid] = []
    var labels: [Label] = []
    var plots: [Plot] = []
    /// The objects that could be placed, even those that make no copies at these values.
    var placed: Set<String> = []

    /// What the view fits: everything drawn, except that a backdrop reaches only a little past
    /// the rest, so a wide ground doesn't shrink the cylinder standing on it.
    var bounds: Box3? {
        var box: Box3?
        func include(_ other: Box3) { box = box.map { $0.union(other) } ?? other }
        for solid in solids where !solid.isBackdrop { include(Box3(center: solid.center, half: solid.half)) }
        for plot in plots {
            if let extent = Box3(containing: plot.mesh.positions.map { Vec3($0) }) { include(extent) }
        }
        let backdrop = Box3(containing: solids.filter(\.isBackdrop).flatMap { [$0.center - $0.half, $0.center + $0.half] })
        if let subject = box, let backdrop {
            let margin = Vec3(repeating: subject.radius * 0.4)
            include(backdrop.clamped(to: Box3(min: subject.min - margin, max: subject.max + margin)))
        } else if let backdrop {
            include(backdrop)
        }
        if box == nil, let marks = Box3(containing: labels.map(\.anchor)) { include(marks) }
        return box
    }

    /// The most solids one scene draws, so a slider can't stall the phone.
    static let maxSolids = 600
    /// The most labels a text object shows across its copies.
    static let maxLabelsPerObject = 12
}

extension Scene3D {
    /// The scene at the reader's numbers. `values` are the evaluated inputs and outputs, and
    /// `zScale` stretches heights for display (`SceneFrame.zScale`), so a flat plot can be read.
    func drawing(in surface: Surface, values: [String: Double], zScale: Double = 1, plotGrid: Int = 40) -> SceneDrawing {
        var drawing = SceneDrawing()
        func lookup(_ name: String) throws -> Double {
            if let value = values[name] { return value }
            if let constant = Expr.constants[name] { return constant }
            throw FormulaError("'\(name)' isn't an input or an output")
        }
        func number(_ expr: Expr) throws -> Double {
            let value = try expr.evaluate(lookup)
            guard value.isFinite else { throw FormulaError("\(expr) isn't a number") }
            return value
        }
        func numbers(_ list: String) -> [Double]? {
            guard !list.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            guard case .call(_, let arguments) = try? FormulaCache.parse("size(\(list))") else { return nil }
            return try? arguments.map(number)
        }
        func angle(_ formula: String) -> Double? {
            guard !formula.isEmpty else { return 0 }
            return (try? number(FormulaCache.parse(formula))).map { $0 * .pi / 180 }
        }
        func display(_ point: Vec3) -> Vec3 { Vec3(point.x, point.y, point.z * zScale) }

        // Each object's shape first: its sizes, how it's turned, and how far it reaches, which
        // is what anything placed against it needs.
        struct Body {
            var sizes: [Double]
            var rotation: simd_quatd
            var half: Vec3
        }
        var bodies: [String: Body] = [:]
        for object in objects where bodies[object.name] == nil {
            guard let given = numbers(object.size), let turn = angle(object.turn), let tilt = angle(object.tilt) else { continue }
            let sizes = Self.sizes(given, for: object.kind)
            guard sizes.allSatisfy({ $0 >= 0 }) else { continue }
            let rotation = simd_quatd(angle: tilt, axis: Vec3(0, 1, 0)) * simd_quatd(angle: turn, axis: Vec3(0, 0, 1))
            bodies[object.name] = Body(sizes: sizes, rotation: rotation, half: Self.reach(of: object.kind, sizes: sizes, rotation: rotation))
        }

        // Then where each one goes. Objects can be placed against each other in any order; one
        // that can't be placed (on something that can't be, or on itself) is left out.
        let names = Set(objects.map(\.name))
        let byName = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [String: [Vec3]] = [:]
        var failed: Set<String> = []
        var resolving: Set<String> = []
        func spot(_ name: String) throws -> SceneSpot {
            if name == ScenePlacement.ground, byName[name] == nil { return .ground }
            guard let first = try place(name).first, let body = bodies[name] else { throw FormulaError("'\(name)' has nowhere to be") }
            return SceneSpot(center: first, half: body.half)
        }
        func places(_ position: String, half: Vec3) throws -> [Vec3] {
            try ScenePlacement.places(FormulaCache.parse(position), half: half, objects: names, spot: spot, number: number)
        }
        func place(_ name: String) throws -> [Vec3] {
            if let known = placed[name] { return known }
            guard !failed.contains(name), let object = byName[name], let body = bodies[name] else { throw FormulaError("there's no object '\(name)'") }
            guard resolving.insert(name).inserted else { throw FormulaError("'\(name)' is placed against itself") }
            defer { resolving.remove(name) }
            let result = try places(object.position, half: body.half)
            placed[name] = result
            return result
        }
        for object in objects where placed[object.name] == nil {
            do { _ = try place(object.name) } catch { failed.insert(object.name) }
        }
        var ends: [String: [Vec3]] = [:]
        for object in objects where object.kind.isSpan {
            ends[object.name] = try? places(object.to, half: .zero)
        }
        drawing.placed = Set(placed.keys).filter { name in byName[name].map { !$0.kind.isSpan || ends[name] != nil } ?? false }

        // Thin things are thin for the size of the whole scene: paths and axes faint, rods and
        // arrows thick enough to tell apart.
        var extent = Box3(containing: placed.flatMap { name, copies in
            copies.flatMap { center -> [Vec3] in
                let half = bodies[name]?.half ?? .zero
                return [center - half, center + half]
            }
        } + ends.values.joined())
        if let structure = molecule?.structure, let atoms = Box3(containing: structure.atoms.map(\.position)) {
            extent = extent.map { $0.union(atoms) } ?? atoms
        }
        let reach = Swift.max(extent.map { Swift.max($0.half.x, $0.half.y, $0.half.z) } ?? 1, 1e-6)
        let thin = reach * 0.006
        let thick = reach * 0.016

        func add(_ solid: SceneDrawing.Solid) {
            guard drawing.solids.count < SceneDrawing.maxSolids, solid.center.x.isFinite, solid.center.y.isFinite, solid.center.z.isFinite,
                  solid.scale.x > 0, solid.scale.y > 0, solid.scale.z > 0 else { return }
            drawing.solids.append(solid)
        }
        func label(_ text: String, at anchor: Vec3, centered: Bool = false, tone: SceneObject.Tone?) {
            guard !text.isEmpty else { return }
            drawing.labels.append(SceneDrawing.Label(id: drawing.labels.count, text: text, anchor: anchor, centered: centered, tone: tone))
        }
        /// A rod from one point to another: an upright cylinder, stretched and turned to fit.
        func rod(_ id: String, from a: Vec3, to b: Vec3, radius: Double, paint: SceneDrawing.Solid.Paint) {
            let along = b - a
            let length = simd_length(along)
            guard length > 1e-12 else { return }
            add(SceneDrawing.Solid(id: id, shape: .cylinder, center: (a + b) / 2, scale: Vec3(radius, radius, length), rotation: Self.upright(to: along / length), paint: paint))
        }
        func arrow(_ id: String, from a: Vec3, to b: Vec3, radius: Double, tone: SceneObject.Tone) {
            let along = b - a
            let length = simd_length(along)
            guard length > 1e-12 else { return }
            let direction = along / length
            let head = Swift.min(radius * 7, length * 0.45)
            rod("\(id)-shaft", from: a, to: b - direction * head * 0.9, radius: radius, paint: .tone(tone))
            add(SceneDrawing.Solid(id: "\(id)-head", shape: .cone, center: b - direction * head / 2, scale: Vec3(radius * 2.6, radius * 2.6, head),
                                   rotation: Self.upright(to: direction), paint: .tone(tone)))
        }

        for (index, object) in objects.enumerated() {
            guard let body = bodies[object.name], let copies = placed[object.name] else { continue }
            let id = "o\(index)"
            let sizes = body.sizes
            var anchors: [(point: Vec3, centered: Bool)] = []
            func labelCopy(_ anchor: Vec3, centered: Bool = false) { anchors.append((anchor, centered)) }
            /// Copies are alike, so one label names them all: on the copy nearest the front and
            /// the top, as the scene is first seen. Text is the exception, being nothing else.
            func finishLabels() {
                if object.kind == .text {
                    for anchor in anchors.prefix(SceneDrawing.maxLabelsPerObject) { label(object.label, at: anchor.point, centered: true, tone: object.tone) }
                } else if let front = anchors.min(by: { $0.point.y - $0.point.z / 2 < $1.point.y - $1.point.z / 2 }) {
                    label(object.label, at: front.point, centered: front.centered, tone: object.tone)
                }
            }
            if object.kind == .box, object.tone == .guide {
                // A guide box is its edges, like a unit cell or a room, so it doesn't hide what's in it.
                let half = Vec3(sizes[0], sizes[1], sizes[2]) / 2
                for (copy, center) in copies.enumerated() {
                    let middle = display(center)
                    var edge = 0
                    for axis in 0..<3 {
                        let (u, v) = ((axis + 1) % 3, (axis + 2) % 3)
                        for (su, sv) in [(-1.0, -1.0), (-1, 1), (1, -1), (1, 1)] {
                            var a = Vec3.zero
                            a[axis] = -half[axis]
                            a[u] = su * half[u]
                            a[v] = sv * half[v]
                            var b = a
                            b[axis] = half[axis]
                            rod("\(id)-\(copy)-\(edge)", from: middle + body.rotation.act(a), to: middle + body.rotation.act(b), radius: thin * 1.5, paint: .tone(.guide))
                            edge += 1
                        }
                    }
                    labelCopy(middle + Vec3(0, 0, body.half.z))
                }
                finishLabels()
                continue
            }
            defer { finishLabels() }
            switch object.kind {
            case .sphere, .box, .cylinder, .cone, .plane, .ring:
                let shape: SceneDrawing.Solid.Shape
                let scale: Vec3
                switch object.kind {
                case .sphere: (shape, scale) = (.sphere, Vec3(repeating: sizes[0]))
                case .box: (shape, scale) = (.box, Vec3(sizes[0], sizes[1], sizes[2]))
                case .cylinder: (shape, scale) = (.cylinder, Vec3(sizes[0], sizes[0], sizes[1]))
                case .cone: (shape, scale) = (.cone, Vec3(sizes[0], sizes[0], sizes[1]))
                case .plane: (shape, scale) = (.plane, Vec3(sizes[0], sizes[1], 1))
                default:
                    let thickness = sizes.count > 1 && sizes[1] > 0 ? sizes[1] : thin
                    (shape, scale) = (.ring(Self.ringRatio(thickness / Swift.max(sizes[0], 1e-12))), Vec3(repeating: sizes[0]))
                }
                for (copy, center) in copies.enumerated() {
                    var solid = SceneDrawing.Solid(id: "\(id)-\(copy)", shape: shape, center: display(center), scale: scale, rotation: body.rotation, paint: .tone(object.tone))
                    solid.isBackdrop = object.kind == .plane && object.tone == .guide
                    add(solid)
                    if case .ring = shape {
                        // On the rim, at the front, where a ring is easiest to tell apart.
                        let angle = -60.0 * .pi / 180
                        labelCopy(solid.center + body.rotation.act(Vec3(cos(angle), sin(angle), 0) * scale.x))
                    } else {
                        labelCopy(solid.center + Vec3(0, 0, solid.half.z))
                    }
                }
            case .tube, .arrow:
                guard let targets = ends[object.name], !targets.isEmpty, !copies.isEmpty else { continue }
                let radius = sizes.first.flatMap { $0 > 0 ? $0 : nil } ?? thick
                // One to one, or one to many: spokes from a hub, or rods from each copy to a point.
                let count = copies.count == 1 || targets.count == 1 ? Swift.max(copies.count, targets.count) : Swift.min(copies.count, targets.count)
                for k in 0..<count {
                    let (a, b) = (display(copies[copies.count == 1 ? 0 : k]), display(targets[targets.count == 1 ? 0 : k]))
                    if object.kind == .arrow {
                        arrow("\(id)-\(k)", from: a, to: b, radius: radius, tone: object.tone)
                        labelCopy(b)
                    } else {
                        rod("\(id)-\(k)", from: a, to: b, radius: radius, paint: .tone(object.tone))
                        labelCopy((a + b) / 2)
                    }
                }
            case .axes:
                let length = sizes.first.flatMap { $0 > 0 ? $0 : nil } ?? reach
                for (copy, center) in copies.prefix(4).enumerated() {
                    let origin = display(center)
                    for (axis, name) in zip([Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)], ["x", "y", "z"]) {
                        arrow("\(id)-\(copy)-\(name)", from: origin - axis * length, to: origin + axis * length, radius: thin, tone: .guide)
                        label(name, at: origin + axis * length * 1.1, centered: true, tone: .guide)
                    }
                }
            case .text:
                for center in copies { labelCopy(display(center), centered: true) }
            }
        }

        for (index, plot) in plots.enumerated() {
            drawPlot(plot, index: index, in: surface, values: values, zScale: zScale, grid: plotGrid, thin: thick * 0.6, to: &drawing)
        }

        if let structure = molecule?.structure {
            Self.drawMolecule(structure, to: &drawing)
        }
        return drawing
    }

    /// Sizes with the ones left out filled in: a box given one side is a cube, a cylinder given
    /// only its radius is as tall as it is wide, and a sphere with no size has radius 1.
    static func sizes(_ given: [Double], for kind: SceneObject.Kind) -> [Double] {
        switch kind {
        case .sphere: return [given.first ?? 1]
        case .box:
            let width = given.first ?? 1
            let depth = given.count > 1 ? given[1] : width
            return [width, depth, given.count > 2 ? given[2] : depth]
        case .cylinder, .cone:
            let radius = given.first ?? 1
            return [radius, given.count > 1 ? given[1] : radius * 2]
        case .plane:
            let width = given.first ?? 1
            return [width, given.count > 1 ? given[1] : width]
        case .ring: return [given.first ?? 1] + given.dropFirst().prefix(1)
        case .tube, .arrow, .axes: return Array(given.prefix(1))
        case .text: return []
        }
    }

    /// How far an object reaches from its centre along each axis, which is what's placed against it.
    static func reach(of kind: SceneObject.Kind, sizes: [Double], rotation: simd_quatd) -> Vec3 {
        let local: Vec3
        switch kind {
        case .sphere: local = Vec3(repeating: sizes[0])
        case .box: local = Vec3(sizes[0], sizes[1], sizes[2]) / 2
        case .cylinder, .cone: local = Vec3(sizes[0], sizes[0], sizes[1] / 2)
        case .plane: local = Vec3(sizes[0] / 2, sizes[1] / 2, 0)
        case .ring: local = Vec3(sizes[0], sizes[0], 0)
        case .axes: local = Vec3(repeating: sizes.first ?? 0)
        case .tube, .arrow, .text: return .zero
        }
        let turned = simd_matrix3x3(rotation)
        return simd_double3x3(columns: (simd_abs(turned.columns.0), simd_abs(turned.columns.1), simd_abs(turned.columns.2))) * local
    }

    /// A ring's thickness for its mesh, rounded so a slider changing its radius doesn't rebuild
    /// the mesh on every step: steps of about 2.5%.
    static func ringRatio(_ raw: Double) -> Double {
        let clamped = Swift.min(Swift.max(raw, 0.001), 0.45)
        return Foundation.exp((Foundation.log(clamped) * 40).rounded() / 40)
    }

    /// The turn that stands an upright shape along `direction`.
    static func upright(to direction: Vec3) -> simd_quatd {
        let up = Vec3(0, 0, 1)
        let cosine = simd_dot(up, direction)
        if cosine > 1 - 1e-12 { return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }
        if cosine < -1 + 1e-12 { return simd_quatd(angle: .pi, axis: Vec3(1, 0, 0)) }
        return simd_quatd(from: up, to: direction)
    }

    // MARK: - Plots

    /// A plot's surface, with axes along its edges through the origin when it's inside.
    private func drawPlot(_ plot: ScenePlot, index: Int, in surface: Surface, values: [String: Double], zScale: Double, grid: Int, thin: Double, to drawing: inout SceneDrawing) {
        guard let sampled = Self.sample(plot, in: surface, values: values, grid: grid) else { return }
        let heights = sampled.heights.map { $0.map { $0 * zScale } }
        guard let mesh = SceneMesh.surface(heights: heights, x: sampled.x, y: sampled.y) else { return }
        drawing.plots.append(SceneDrawing.Plot(id: index, mesh: mesh, low: sampled.low, high: sampled.high))

        // Axes through the origin, or along the edge nearest it.
        let origin = Vec3(Swift.min(Swift.max(0, sampled.x.lowerBound), sampled.x.upperBound),
                          Swift.min(Swift.max(0, sampled.y.lowerBound), sampled.y.upperBound),
                          Swift.min(Swift.max(0, sampled.low), sampled.high) * zScale)
        let ends = [
            (Vec3(sampled.x.lowerBound, origin.y, origin.z), Vec3(sampled.x.upperBound, origin.y, origin.z), "x"),
            (Vec3(origin.x, sampled.y.lowerBound, origin.z), Vec3(origin.x, sampled.y.upperBound, origin.z), "y"),
            (Vec3(origin.x, origin.y, sampled.low * zScale), Vec3(origin.x, origin.y, sampled.high * zScale), "z"),
        ]
        let span = Swift.max(sampled.x.upperBound - sampled.x.lowerBound, sampled.y.upperBound - sampled.y.lowerBound)
        for (a, b, name) in ends {
            // Past the surface's edge a little, so the arrowhead shows.
            let direction = simd_length(b - a) > 0 ? simd_normalize(b - a) : Vec3(0, 0, 1)
            let tip = b + direction * span * 0.12
            let radius = Swift.min(thin, span * 0.006)
            let along = tip - a
            let length = simd_length(along)
            guard length > 0 else { continue }
            let head = Swift.min(radius * 7, length * 0.45)
            let shaftEnd = tip - direction * head * 0.9
            drawing.solids.append(SceneDrawing.Solid(id: "p\(index)-\(name)-shaft", shape: .cylinder, center: (a + shaftEnd) / 2,
                                                     scale: Vec3(radius, radius, simd_length(shaftEnd - a)), rotation: Self.upright(to: direction), paint: .tone(.guide)))
            drawing.solids.append(SceneDrawing.Solid(id: "p\(index)-\(name)-head", shape: .cone, center: tip - direction * head / 2,
                                                     scale: Vec3(radius * 2.6, radius * 2.6, head), rotation: Self.upright(to: direction), paint: .tone(.guide)))
            drawing.labels.append(SceneDrawing.Label(id: drawing.labels.count, text: name, anchor: tip + direction * span * 0.06, centered: true, tone: .guide))
        }
        if !plot.label.isEmpty {
            let top = Vec3((sampled.x.lowerBound + sampled.x.upperBound) / 2, (sampled.y.lowerBound + sampled.y.upperBound) / 2, sampled.high * zScale)
            drawing.labels.append(SceneDrawing.Label(id: drawing.labels.count, text: plot.label, anchor: top, centered: false, tone: .main))
        }
    }

    /// Heights over a plot's grid at these values, with its ranges worked out. Heights far
    /// outside where most of them lie (near where a function blows up) are left out, so a
    /// single spike doesn't flatten the rest. Nil if the ranges can't be worked out.
    static func sample(_ plot: ScenePlot, in surface: Surface, values: [String: Double], grid: Int) -> (heights: [[Double]], x: ClosedRange<Double>, y: ClosedRange<Double>, low: Double, high: Double)? {
        func lookup(_ locals: [String: Double]) -> (String) throws -> Double {
            { name in
                if let local = locals[name] { return local }
                if let value = values[name] { return value }
                if let constant = Expr.constants[name] { return constant }
                throw FormulaError("'\(name)' isn't an input or an output")
            }
        }
        func value(_ formula: String) -> Double? {
            guard let result = try? FormulaCache.parse(formula).evaluate(lookup([:])), result.isFinite else { return nil }
            return result
        }
        guard let x0 = value(plot.xFrom), let x1 = value(plot.xTo), let y0 = value(plot.yFrom), let y1 = value(plot.yTo), x0 < x1, y0 < y1,
              let z = surface.inlined(plot.z) else { return nil }
        let count = Swift.max(grid, 2)
        var heights: [[Double]] = []
        heights.reserveCapacity(count + 1)
        for j in 0...count {
            let y = y0 + (y1 - y0) * Double(j) / Double(count)
            heights.append((0...count).map { i in
                let x = x0 + (x1 - x0) * Double(i) / Double(count)
                return (try? z.evaluate(lookup(["x": x, "y": y]))) ?? .nan
            })
        }
        let sorted = heights.joined().filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let low = sorted[Int(Double(sorted.count - 1) * 0.02)], high = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let margin = Swift.max(high - low, 1e-9) * 1.5
        let kept = heights.map { row in row.map { $0 >= low - margin && $0 <= high + margin ? $0 : .nan } }
        let finite = kept.joined().filter(\.isFinite)
        return (kept, x0...x1, y0...y1, finite.min() ?? low, finite.max() ?? high)
    }

    // MARK: - Molecules

    /// Ball and stick: each atom a ball sized in proportion to the element, each bond a stick,
    /// doubled or tripled for double and triple bonds, side by side in the plane of a neighbour
    /// so a ring's double bonds lie in the ring.
    private static func drawMolecule(_ structure: MoleculeStructure, to drawing: inout SceneDrawing) {
        let atoms = structure.atoms.map(\.position)
        for (index, atom) in structure.atoms.enumerated() {
            let radius = Swift.max(Element.of(atom.element).radius * 0.22, 0.18)
            drawing.solids.append(SceneDrawing.Solid(id: "a\(index)", shape: .sphere, center: atoms[index], scale: Vec3(repeating: radius),
                                                     rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), paint: .element(atom.element)))
        }
        var neighbours: [Int: [Int]] = [:]
        for bond in structure.bonds {
            neighbours[bond.from, default: []].append(bond.to)
            neighbours[bond.to, default: []].append(bond.from)
        }
        for (index, bond) in structure.bonds.enumerated() {
            let (a, b) = (atoms[bond.from], atoms[bond.to])
            let along = b - a
            guard simd_length(along) > 1e-9 else { continue }
            let direction = simd_normalize(along)
            var across = Vec3.zero
            if bond.order > 1 {
                let third = (neighbours[bond.from] ?? []).first { $0 != bond.to } ?? (neighbours[bond.to] ?? []).first { $0 != bond.from }
                if let third {
                    let normal = simd_cross(along, atoms[third] - a)
                    if simd_length(normal) > 1e-9 { across = simd_normalize(simd_cross(normal, direction)) }
                }
                if across == .zero {
                    let other = abs(direction.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
                    across = simd_normalize(simd_cross(direction, other))
                }
            }
            let offsets: [Double] = bond.order >= 3 ? [-1, 0, 1] : bond.order == 2 ? [-0.5, 0.5] : [0]
            let radius = bond.order == 1 ? 0.075 : 0.05
            for (k, offset) in offsets.enumerated() {
                let shift = across * offset * 0.19
                let length = simd_length(along)
                drawing.solids.append(SceneDrawing.Solid(id: "b\(index)-\(k)", shape: .cylinder, center: (a + b) / 2 + shift, scale: Vec3(radius, radius, length),
                                                         rotation: upright(to: direction), paint: .bond))
            }
        }
    }
}

extension Surface {
    /// `formula` with each output it names replaced by that output's own formula, all the way
    /// down to the inputs, so it can be worked out thousands of times (a plot's grid) without
    /// the rest of the calculation. Nil if it can't be read, or if outputs refer to each other
    /// in a loop.
    func inlined(_ formula: String) -> Expr? {
        let formulas = Dictionary(outputs.map { ($0.name, $0.formula) }, uniquingKeysWith: { first, _ in first })
        func expand(_ expr: Expr, depth: Int) -> Expr? {
            guard depth < 24 else { return nil }
            switch expr {
            case .number: return expr
            case .name(let name):
                guard let source = formulas[name], input(name) == nil else { return expr }
                guard let parsed = try? FormulaCache.parse(source) else { return nil }
                return expand(parsed, depth: depth + 1)
            case .unary(let op, let operand):
                return expand(operand, depth: depth).map { .unary(op, $0) }
            case .binary(let op, let lhs, let rhs):
                guard let left = expand(lhs, depth: depth), let right = expand(rhs, depth: depth) else { return nil }
                return .binary(op, left, right)
            case .conditional(let condition, let then, let otherwise):
                guard let c = expand(condition, depth: depth), let t = expand(then, depth: depth), let o = expand(otherwise, depth: depth) else { return nil }
                return .conditional(c, t, o)
            case .call(let function, let arguments):
                let expanded = arguments.compactMap { expand($0, depth: depth) }
                return expanded.count == arguments.count ? .call(function, expanded) : nil
            }
        }
        guard let parsed = try? FormulaCache.parse(formula) else { return nil }
        return expand(parsed, depth: 0)
    }
}
