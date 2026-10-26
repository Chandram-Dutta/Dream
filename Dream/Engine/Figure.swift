import Foundation

/// A drawing for geometry and physics, defined once at the top of the surface and shown by a
/// `figure` block. The model names points and the shapes through them; every coordinate is a
/// formula over the calculation, so the drawing moves as the numbers do. Models are good at
/// structure and bad at coordinates, so the engine does the rest: it fits the view, places the
/// labels, and turns points the reader can move into handles.
struct Figure: Codable, Hashable {
    var name: String
    var points: [FigurePoint]
    var shapes: [FigureShape]

    func point(_ name: String) -> FigurePoint? { points.first { $0.name == name } }

    /// `A.x` → (A, x): another point's coordinate, as figure formulas write it.
    static func coordinate(_ name: String) -> (point: String, axis: Character)? {
        guard name.count > 2, let axis = name.last, axis == "x" || axis == "y", name.dropLast().last == "." else { return nil }
        return (String(name.dropLast(2)), axis)
    }
}

/// A named position. Formulas in the same figure can use its coordinates as `A.x` and `A.y`.
struct FigurePoint: Codable, Hashable {
    var name: String
    var x: String
    var y: String
    /// Shown beside the point. Without one, a point is only a corner for shapes, unless it's a handle.
    var label: String
}

struct FigureShape: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// Two or more points, joined in order.
        case segment
        /// From the first point to the second, like a force or a velocity.
        case arrow
        /// Three or more corners, filled.
        case polygon
        /// A square on the side between the first two points, built outward: away from the third
        /// point if there is one, or else from the shape that side belongs to. Models get the
        /// rotation behind this wrong, and it's how areas on sides are shown.
        case square
        /// Around the point, with `radius`.
        case circle
        /// Around the point, with `radius`, from the angle `from` to `to`: degrees, counterclockwise from the right.
        case arc
        /// The angle at the middle one of three points, marked with a small arc.
        case angle
        /// A right angle at the middle one of three points, marked with a small square.
        case rightAngle
        /// Only the label, at the point.
        case text
        /// A curve: `x` and `y` as formulas of `over`, as it runs from `from` to `to`.
        case path

        /// How many points it goes through.
        var pointCount: ClosedRange<Int> {
            switch self {
            case .segment: 2...16
            case .arrow: 2...2
            case .polygon: 3...16
            case .square: 2...3
            case .circle, .arc, .text: 1...1
            case .angle, .rightAngle: 3...3
            case .path: 0...0
            }
        }
    }

    /// How much a shape stands out. The colours come from the surface's palette.
    enum Tone: String, Codable, CaseIterable {
        /// What the figure is about.
        case main
        /// Something to tell apart from it.
        case contrast
        /// Everything else.
        case plain
        /// Helpers, like the ground or an axis: dashed and quiet.
        case guide
    }

    var kind: Kind
    var points: [String] = []
    var radius = ""
    var from = ""
    var to = ""
    var over = ""
    var x = ""
    var y = ""
    var label = ""
    var tone: Tone = .plain
}

extension Surface {
    func figure(_ name: String) -> Figure? { figures?.first { $0.name == name } }

    /// Names that paths run along. A variable a path uses this way needs no control of its own.
    var figureAxes: Set<String> {
        Set((figures ?? []).flatMap { $0.shapes.filter { $0.kind == .path }.map(\.over) })
    }
}

// MARK: - Geometry

/// A position or a direction, in a figure's units or on screen.
struct Vec2: Hashable {
    var x: Double
    var y: Double

    static let zero = Vec2(x: 0, y: 0)

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(x: a.x * k, y: a.y * k) }
    static func / (a: Vec2, k: Double) -> Vec2 { Vec2(x: a.x / k, y: a.y / k) }

    var length: Double { hypot(x, y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
    /// A quarter turn counterclockwise, in y-up units.
    var perpendicular: Vec2 { Vec2(x: -y, y: x) }
    var normalized: Vec2 { length > 0 ? self / length : .zero }

    func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }
    func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }
}

/// An axis-aligned box.
struct Rect2: Hashable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (self.minX, self.minY, self.maxX, self.maxY) = (minX, minY, maxX, maxY)
    }

    init(center: Vec2, width: Double, height: Double) {
        self.init(minX: center.x - width / 2, minY: center.y - height / 2, maxX: center.x + width / 2, maxY: center.y + height / 2)
    }

    init?(containing points: some Sequence<Vec2>) {
        var box: Rect2?
        for point in points where point.isFinite {
            box = box.map { $0.including(point) } ?? Rect2(minX: point.x, minY: point.y, maxX: point.x, maxY: point.y)
        }
        guard let box else { return nil }
        self = box
    }

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: Vec2 { Vec2(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }

    func including(_ point: Vec2) -> Rect2 {
        Rect2(minX: Swift.min(minX, point.x), minY: Swift.min(minY, point.y), maxX: Swift.max(maxX, point.x), maxY: Swift.max(maxY, point.y))
    }

    func union(_ other: Rect2) -> Rect2 {
        Rect2(minX: Swift.min(minX, other.minX), minY: Swift.min(minY, other.minY), maxX: Swift.max(maxX, other.maxX), maxY: Swift.max(maxY, other.maxY))
    }

    func insetBy(_ amount: Double) -> Rect2 {
        Rect2(minX: minX + amount, minY: minY + amount, maxX: maxX - amount, maxY: maxY - amount)
    }

    func contains(_ point: Vec2) -> Bool { point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY }

    /// How much area two boxes share.
    func overlap(_ other: Rect2) -> Double {
        Swift.max(0, Swift.min(maxX, other.maxX) - Swift.max(minX, other.minX)) * Swift.max(0, Swift.min(maxY, other.maxY) - Swift.max(minY, other.minY))
    }

    /// How much of this box lies outside `other`.
    func spill(outside other: Rect2) -> Double { width * height - overlap(other) }

    /// Whether the line from `a` to `b` passes through the box.
    func crosses(_ a: Vec2, _ b: Vec2) -> Bool {
        // Liang–Barsky clipping: the line meets the box if some part of it survives.
        var low = 0.0, high = 1.0
        let delta = b - a
        for (p, q) in [(-delta.x, a.x - minX), (delta.x, maxX - a.x), (-delta.y, a.y - minY), (delta.y, maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { low = Swift.max(low, t) } else { high = Swift.min(high, t) }
                if low > high { return false }
            }
        }
        return true
    }
}

// MARK: - Drawing

/// A figure at one set of values: every shape resolved to positions in the figure's units, with
/// y up. Shapes that can't be drawn at these values, like a circle whose radius isn't a number,
/// are left out rather than drawn wrong.
struct FigureDrawing {
    struct Mark: Identifiable {
        enum Geometry {
            /// Points joined in order; closed for polygons and circles.
            case line([Vec2], closed: Bool)
            /// The angle at `vertex` between the arms towards `a` and `b`. Drawn at a fixed size on screen.
            case angle(vertex: Vec2, a: Vec2, b: Vec2)
            case text(Vec2)
        }

        /// The shape's position in the figure, so it keeps its identity as values change.
        let id: Int
        let shape: FigureShape
        let geometry: Geometry
    }

    /// Text to show, and what it belongs to.
    struct Label: Identifiable {
        enum Anchor {
            /// Beside a point, on the side away from the rest of the figure.
            case point(Vec2)
            /// Beside a line, at its middle: the first point is where the side starts.
            case side(Vec2, Vec2)
            /// In the middle of an area.
            case inside(Vec2)
            /// Just outside a curve, at its highest point or along a direction from a centre.
            case beyond(Vec2, direction: Vec2)
            /// In an angle mark, along its bisector.
            case angle(vertex: Vec2, a: Vec2, b: Vec2)
        }

        let id: Int
        let text: String
        /// The tone of the shape it labels; nil for a point's own label.
        let tone: FigureShape.Tone?
        let anchor: Anchor
    }

    var points: [String: Vec2]
    var marks: [Mark]
    var labels: [Label]
    /// Points shown as dots: the labeled ones.
    var dots: [Vec2]

    /// Everything drawn, in the figure's units.
    var bounds: Rect2? {
        var all = dots
        for mark in marks {
            switch mark.geometry {
            case .line(let points, _): all += points
            case .angle(let vertex, _, _): all.append(vertex)
            case .text(let point): all.append(point)
            }
        }
        return Rect2(containing: all)
    }
}

extension Figure {
    /// The figure at the reader's numbers. `given` holds the inputs they've set; the rest are where
    /// the surface starts them.
    func drawing(in surface: Surface, given: [String: Double]) -> FigureDrawing {
        drawing(in: surface, given: given, values: surface.evaluate(given).values)
    }

    /// `values` are the evaluated inputs and outputs. A path along an input re-evaluates the
    /// surface at each of its samples, so it can use outputs that depend on that input.
    func drawing(in surface: Surface, given: [String: Double], values: [String: Double], pathSamples: Int = 120) -> FigureDrawing {
        let placed = positions(values: values)
        func lookup(_ locals: [String: Double], _ values: [String: Double]) -> (String) throws -> Double {
            { name in
                if let local = locals[name] { return local }
                if let value = values[name] { return value }
                if let (point, axis) = Figure.coordinate(name), let position = placed[point] { return axis == "x" ? position.x : position.y }
                if let constant = Expr.constants[name] { return constant }
                throw FormulaError("'\(name)' isn't an input, an output or a point")
            }
        }
        func number(_ formula: String, _ locals: [String: Double] = [:], _ values: [String: Double] = values) -> Double? {
            guard let value = try? FormulaCache.parse(formula).evaluate(lookup(locals, values)), value.isFinite else { return nil }
            return value
        }

        var marks: [FigureDrawing.Mark] = []
        var labels: [FigureDrawing.Label] = []
        for (index, shape) in shapes.enumerated() {
            let corners = shape.points.compactMap { placed[$0] }
            guard corners.count == shape.points.count, shape.kind.pointCount.contains(corners.count) else { continue }
            let geometry: FigureDrawing.Mark.Geometry
            var anchor: FigureDrawing.Label.Anchor
            switch shape.kind {
            case .segment, .arrow:
                guard zip(corners, corners.dropFirst()).contains(where: { ($1 - $0).length > 0 }) else { continue }
                geometry = .line(corners, closed: false)
                // The middle of the middle side, so a long chain is labeled near its centre.
                let side = Swift.max(0, (corners.count - 2) / 2)
                anchor = .side(corners[side], corners[side + 1])
            case .polygon:
                geometry = .line(corners, closed: true)
                anchor = .inside(Self.centroid(of: corners))
            case .square:
                let (a, b) = (corners[0], corners[1])
                guard (b - a).length > 0 else { continue }
                var across = (b - a).perpendicular
                if across.dot(a - away(from: shape, at: index, placed)) < 0 { across = across * -1 }
                let square = [a, b, b + across, a + across]
                geometry = .line(square, closed: true)
                anchor = .inside(Self.centroid(of: square))
            case .circle, .arc:
                guard let radius = number(shape.radius), radius > 0 else { continue }
                let center = corners[0]
                var start = 0.0, end = 2 * Double.pi
                if shape.kind == .arc {
                    guard let from = number(shape.from), let to = number(shape.to), from != to else { continue }
                    (start, end) = (from * .pi / 180, to * .pi / 180)
                }
                let count = Swift.max(12, Int(abs(end - start) / (2 * .pi) * 96))
                let outline = (0...count).map { step in
                    let angle = start + (end - start) * Double(step) / Double(count)
                    return center + Vec2(x: cos(angle), y: sin(angle)) * radius
                }
                geometry = .line(shape.kind == .circle ? Array(outline.dropLast()) : outline, closed: shape.kind == .circle)
                let middle = shape.kind == .circle ? Double.pi / 4 : (start + end) / 2
                let direction = Vec2(x: cos(middle), y: sin(middle))
                anchor = .beyond(center + direction * radius, direction: direction)
            case .angle, .rightAngle:
                guard (corners[0] - corners[1]).length > 0, (corners[2] - corners[1]).length > 0 else { continue }
                geometry = .angle(vertex: corners[1], a: corners[0], b: corners[2])
                anchor = .angle(vertex: corners[1], a: corners[0], b: corners[2])
            case .text:
                guard !shape.label.isEmpty else { continue }
                geometry = .text(corners[0])
                anchor = .inside(corners[0])
            case .path:
                let isInput = surface.input(shape.over) != nil
                let range = surface.input(shape.over)?.safeRange
                guard let first = shape.from.isEmpty ? range?.lowerBound : number(shape.from),
                      let last = shape.to.isEmpty ? range?.upperBound : number(shape.to), first != last else { continue }
                let samples = (0..<pathSamples).compactMap { step -> Vec2? in
                    let t = first + (last - first) * Double(step) / Double(pathSamples - 1)
                    var sampleValues = values
                    if isInput {
                        var trial = given
                        trial[shape.over] = t
                        sampleValues = surface.evaluate(trial).values
                    }
                    guard let x = number(shape.x, [shape.over: t], sampleValues), let y = number(shape.y, [shape.over: t], sampleValues) else { return nil }
                    return Vec2(x: x, y: y)
                }
                guard samples.count >= 2 else { continue }
                geometry = .line(samples, closed: false)
                // Above its highest point: the top of a throw, or of a wave.
                anchor = .beyond(samples.max { $0.y < $1.y } ?? samples[samples.count / 2], direction: Vec2(x: 0, y: 1))
            }
            marks.append(FigureDrawing.Mark(id: index, shape: shape, geometry: geometry))
            if !shape.label.isEmpty {
                labels.append(FigureDrawing.Label(id: index, text: shape.label, tone: shape.tone, anchor: anchor))
            }
        }

        // An angle needs the lines it sits between. Arms no shape draws are drawn faintly.
        let edges = marks.flatMap { mark -> [(Vec2, Vec2)] in
            guard case .line(let points, let closed) = mark.geometry else { return [] }
            return Array(zip(points, points.dropFirst())) + (closed && points.count > 2 ? [(points[points.count - 1], points[0])] : [])
        }
        // Along its whole length, so the start of a curve that leaves the corner the same way doesn't count.
        func drawn(from vertex: Vec2, to end: Vec2) -> Bool {
            let length = (end - vertex).length
            return [0.05, 0.5, 0.95].allSatisfy { fraction in
                let probe = vertex + (end - vertex) * fraction
                return edges.contains { a, b in
                    let along = b - a
                    guard along.length > 0 else { return false }
                    let t = Swift.min(Swift.max((probe - a).dot(along) / along.dot(along), 0), 1)
                    return (a + along * t - probe).length < length * 0.002
                }
            }
        }
        var arms: [FigureDrawing.Mark] = []
        for mark in marks {
            guard case .angle(let vertex, let a, let b) = mark.geometry else { continue }
            for end in [a, b] where !drawn(from: vertex, to: end) {
                arms.append(FigureDrawing.Mark(id: shapes.count + points.count + arms.count, shape: FigureShape(kind: .segment, tone: .guide), geometry: .line([vertex, end], closed: false)))
            }
        }
        marks.insert(contentsOf: arms, at: 0)

        var dots: [Vec2] = []
        for (index, point) in points.enumerated() where !point.label.isEmpty {
            guard let position = placed[point.name] else { continue }
            dots.append(position)
            labels.append(FigureDrawing.Label(id: shapes.count + index, text: point.label, tone: nil, anchor: .point(position)))
        }
        return FigureDrawing(points: placed, marks: marks, labels: labels, dots: dots)
    }

    /// Where each point is. Points can use each other's coordinates in any order; one that
    /// can't be placed (a formula that isn't a number, or that depends on itself) is left out.
    func positions(values: [String: Double]) -> [String: Vec2] {
        let byName = Dictionary(points.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [String: Vec2] = [:]
        var failed: Set<String> = []
        var resolving: Set<String> = []

        func place(_ name: String) throws -> Vec2 {
            if let known = placed[name] { return known }
            guard !failed.contains(name), let point = byName[name] else { throw FormulaError("there's no point '\(name)'") }
            guard resolving.insert(name).inserted else { throw FormulaError("'\(name)' depends on itself") }
            defer { resolving.remove(name) }
            let position = Vec2(x: try FormulaCache.parse(point.x).evaluate(lookup), y: try FormulaCache.parse(point.y).evaluate(lookup))
            guard position.isFinite else { throw FormulaError("'\(name)' isn't at a number") }
            placed[name] = position
            return position
        }

        func lookup(_ name: String) throws -> Double {
            if let value = values[name] { return value }
            if let (point, axis) = Figure.coordinate(name), byName[point] != nil {
                let position = try place(point)
                return axis == "x" ? position.x : position.y
            }
            if let constant = Expr.constants[name] { return constant }
            throw FormulaError("'\(name)' isn't an input, an output or a point")
        }

        for point in points where placed[point.name] == nil {
            do { _ = try place(point.name) } catch { failed.insert(point.name) }
        }
        return placed
    }

    /// What a square is built away from: the point it names, or the middle of a polygon that has
    /// the same side, or the middle of the rest of the figure.
    private func away(from square: FigureShape, at index: Int, _ placed: [String: Vec2]) -> Vec2 {
        let side = Set(square.points.prefix(2))
        if square.points.count == 3, let point = placed[square.points[2]] { return point }
        if let owner = shapes.enumerated().first(where: { $0.offset != index && $0.element.kind == .polygon && side.isSubset(of: $0.element.points) })?.element {
            let corners = owner.points.compactMap { placed[$0] }
            if corners.count >= 3 { return Self.centroid(of: corners) }
        }
        let others = points.map(\.name).filter { !side.contains($0) }.compactMap { placed[$0] }
        if !others.isEmpty { return others.reduce(.zero, +) / Double(others.count) }
        // Nothing to go by: the side's left, going from the first point to the second.
        let (a, b) = (placed[square.points[0]] ?? .zero, placed[square.points[1]] ?? .zero)
        return a - (b - a).perpendicular
    }

    /// The centre of an area, so a label like a² sits in the middle of its square.
    static func centroid(of corners: [Vec2]) -> Vec2 {
        var area = 0.0
        var sum = Vec2.zero
        for (a, b) in zip(corners, corners.dropFirst() + corners.prefix(1)) {
            let cross = a.cross(b)
            area += cross
            sum = sum + (a + b) * cross
        }
        guard abs(area) > 1e-12 else { return corners.reduce(.zero, +) / Double(Swift.max(corners.count, 1)) }
        return sum / (3 * area)
    }
}
