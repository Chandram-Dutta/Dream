import Foundation

// Fitting a figure to its view and placing its labels. Plain geometry, so it can be tested on a Mac.

extension Figure {
    /// Every formula in the figure.
    var formulas: [String] {
        points.flatMap { [$0.x, $0.y] } + shapes.flatMap { [$0.radius, $0.from, $0.to, $0.x, $0.y] }.filter { !$0.isEmpty }
    }

    /// The inputs the figure's shapes depend on, directly or through outputs.
    func inputs(in surface: Surface) -> Set<String> {
        formulas.reduce(into: Set<String>()) { found, formula in
            guard let expr = try? FormulaCache.parse(formula) else { return }
            for name in expr.names { found.formUnion(surface.inputs(feeding: name)) }
        }
    }

    /// Everything drawn at the starting values, which sets the shape of the figure's view: the
    /// view then fits the figure as it is, not the values the reader might choose.
    func startBounds(in surface: Surface) -> Rect2? {
        FigureMemo.startBounds(of: self, in: surface) { drawing(in: surface, given: [:]).bounds }
    }
}

/// Starting bounds and handles take many evaluations to work out and are asked for on every
/// frame, so they're kept for each figure and calculation.
enum FigureMemo {
    private struct Key: Hashable {
        let figure: Figure
        let inputs: [Input]
        let outputs: [Output]

        init(_ figure: Figure, _ surface: Surface) {
            (self.figure, inputs, outputs) = (figure, surface.inputs, surface.outputs)
        }
    }

    nonisolated(unsafe) private static var starts: [Key: Rect2?] = [:]
    nonisolated(unsafe) private static var handles: [Key: [FigureHandle]] = [:]
    private static let lock = NSLock()

    static func startBounds(of figure: Figure, in surface: Surface, _ make: () -> Rect2?) -> Rect2? {
        let key = Key(figure, surface)
        if let hit = lock.withLock({ starts[key] }) { return hit }
        let bounds = make()
        lock.withLock {
            if starts.count > 64 { starts.removeAll() }
            starts[key] = bounds
        }
        return bounds
    }

    static func handles(of figure: Figure, in surface: Surface, _ make: () -> [FigureHandle]) -> [FigureHandle] {
        let key = Key(figure, surface)
        if let hit = lock.withLock({ handles[key] }) { return hit }
        let found = make()
        lock.withLock {
            if handles.count > 64 { handles.removeAll() }
            handles[key] = found
        }
        return found
    }
}

/// Where a figure's units land in a view: one scale on both axes, so shapes are true to life,
/// with y turned to point up.
struct FigureViewport {
    let scale: Double
    let offset: Vec2

    /// Room around the drawing for labels and marks, in points.
    static let margin = 28.0

    /// `extent` centred in a view of this size, as large as fits within the margin.
    init(fitting extent: Rect2, width: Double, height: Double, margin: Double = FigureViewport.margin) {
        let box = Self.padded(extent)
        scale = Swift.max(Swift.min((width - 2 * margin) / box.width, (height - 2 * margin) / box.height), 1e-9)
        offset = Vec2(x: width / 2 - box.center.x * scale, y: height / 2 + box.center.y * scale)
    }

    func screen(_ point: Vec2) -> Vec2 { Vec2(x: point.x * scale + offset.x, y: offset.y - point.y * scale) }
    func model(_ point: Vec2) -> Vec2 { Vec2(x: (point.x - offset.x) / scale, y: (offset.y - point.y) / scale) }

    /// Height over width for a view that shows `extent` well: its own shape, kept between a
    /// wide strip and a little taller than square, so a flat figure doesn't become a sliver and
    /// a tall one doesn't push the page away.
    static func aspect(of extent: Rect2, width: Double = 320, margin: Double = FigureViewport.margin) -> Double {
        let box = padded(extent)
        let height = box.height / box.width * (width - 2 * margin) + 2 * margin
        return Swift.min(Swift.max(height / width, 0.5), 1.15)
    }

    /// A box with some size in both directions, so a figure that's a single line still fits.
    private static func padded(_ extent: Rect2) -> Rect2 {
        let size = Swift.max(extent.width, extent.height, 1e-9)
        let width = Swift.max(extent.width, size * 0.1)
        let height = Swift.max(extent.height, size * 0.1)
        return Rect2(center: extent.center, width: width, height: height)
    }
}

// MARK: - Labels

extension FigureDrawing {
    /// Where each label goes on screen, given the sizes they take there. Labels sit beside what
    /// they name, on the side away from the rest of the figure, and move round it rather than
    /// cover another label, a point, a line or an angle's mark.
    func placeLabels(in viewport: FigureViewport, sizes: [Int: Vec2], bounds: Rect2, avoiding knobs: [Vec2] = [], markRadius: Double = 22) -> [Int: Rect2] {
        let center = self.bounds.map { viewport.screen($0.center) } ?? bounds.center
        var lines: [(Vec2, Vec2)] = []
        var obstacles = dots.map { Rect2(center: viewport.screen($0), width: 10, height: 10) }
            + knobs.map { Rect2(center: $0, width: 30, height: 30) }
        for mark in marks {
            var screen: [Vec2]
            switch mark.geometry {
            case .line(let points, let closed):
                screen = points.map(viewport.screen)
                if closed, let first = screen.first { screen.append(first) }
            case .angle(let vertex, let a, let b):
                // Marks are drawn at a fixed size, so they're as easy to collide with at any scale.
                let (corner, first, second) = (viewport.screen(vertex), viewport.screen(a), viewport.screen(b))
                screen = mark.shape.kind == .rightAngle
                    ? FigureMarks.rightAngle(corner, first, second, size: 11)
                    : FigureMarks.angleArc(corner, first, second, radius: markRadius)
                if let box = Rect2(containing: screen + [corner]) { obstacles.append(box) }
            case .text:
                continue
            }
            lines += zip(screen, screen.dropFirst()).map { ($0, $1) }
        }

        var requests: [LabelPlacement.Request] = []
        for label in labels {
            guard let size = sizes[label.id] else { continue }
            var request = LabelPlacement.Request(id: label.id, anchor: .zero, size: size, direction: .zero, gap: 7)
            switch label.anchor {
            case .point(let point):
                request.anchor = viewport.screen(point)
                request.direction = (request.anchor - center).normalized
                if request.direction == .zero { request.direction = Vec2(x: 1, y: -1).normalized }
            case .side(let a, let b):
                let (start, end) = (viewport.screen(a), viewport.screen(b))
                request.anchor = (start + end) / 2
                // Across the side, on whichever face looks away from the middle of the figure.
                var across = (end - start).perpendicular.normalized
                if across.dot(request.anchor - center) < 0 { across = across * -1 }
                request.direction = across
            case .inside(let point):
                request.anchor = viewport.screen(point)
            case .beyond(let point, let direction):
                request.anchor = viewport.screen(point)
                request.direction = Vec2(x: direction.x, y: -direction.y).normalized
            case .angle(let vertex, let a, let b):
                let corner = viewport.screen(vertex)
                let bisector = FigureMarks.bisector(corner, viewport.screen(a), viewport.screen(b))
                request.anchor = corner + bisector * (markRadius + 4)
                request.direction = bisector
                request.gap = 2
            }
            requests.append(request)
        }
        return LabelPlacement.place(requests, obstacles: obstacles, lines: lines, within: bounds)
    }
}

enum LabelPlacement {
    struct Request {
        var id: Int
        var anchor: Vec2
        var size: Vec2
        /// The side it's best on. Zero centres it on the anchor first.
        var direction: Vec2
        var gap: Double
    }

    /// Each label at the first spot around its anchor that's clear, in order of preference: its
    /// own side first, then round the anchor, then further out. Clear means a few points off
    /// every line, so a label never touches what it's next to. Where nothing is clear, the spot
    /// that covers least.
    static func place(_ requests: [Request], obstacles: [Rect2], lines: [(Vec2, Vec2)], within bounds: Rect2, clearance: Double = 3) -> [Int: Rect2] {
        var placed: [Int: Rect2] = [:]
        var taken: [Rect2] = []
        let compass = (0..<8).map { Vec2(x: cos(Double($0) * .pi / 4), y: sin(Double($0) * .pi / 4)) }
        for request in requests {
            let (width, height) = (request.size.x, request.size.y)
            var spots: [Rect2] = []
            if request.direction == .zero { spots.append(Rect2(center: request.anchor, width: width, height: height)) }
            let preferred = request.direction == .zero ? Vec2(x: 0, y: -1) : request.direction
            let directions = ([preferred] + compass.sorted { $0.dot(preferred) > $1.dot(preferred) })
            for distance in [request.gap, request.gap + 8, request.gap + 18] {
                for direction in directions {
                    // Far enough along the direction that the box clears the anchor by the gap.
                    let reach = abs(direction.x) * width / 2 + abs(direction.y) * height / 2 + distance
                    spots.append(Rect2(center: request.anchor + direction * reach, width: width, height: height))
                }
            }
            func cost(_ spot: Rect2, rank: Int) -> Double {
                let room = spot.insetBy(-clearance)
                let crowding = taken.reduce(0) { $0 + room.overlap($1) } * 100
                let covering = obstacles.reduce(0) { $0 + room.overlap($1) } * 30
                let crossing = Double(lines.filter { room.crosses($0.0, $0.1) }.count) * 400
                return crowding + covering + crossing + spot.spill(outside: bounds) * 100 + Double(rank)
            }
            guard let best = spots.enumerated().min(by: { cost($0.element, rank: $0.offset) < cost($1.element, rank: $1.offset) })?.element else { continue }
            placed[request.id] = best
            taken.append(best)
        }
        return placed
    }
}

/// The small marks drawn at a fixed size on screen, whatever the figure's scale.
enum FigureMarks {
    /// The direction halfway between two arms, pointing into the angle.
    static func bisector(_ vertex: Vec2, _ a: Vec2, _ b: Vec2) -> Vec2 {
        let sum = (a - vertex).normalized + (b - vertex).normalized
        return sum.length > 1e-9 ? sum.normalized : (a - vertex).normalized.perpendicular
    }

    /// An arc across the angle at `vertex`, the short way round, in screen points.
    static func angleArc(_ vertex: Vec2, _ a: Vec2, _ b: Vec2, radius: Double) -> [Vec2] {
        let start = atan2((a - vertex).y, (a - vertex).x)
        var sweep = atan2((b - vertex).y, (b - vertex).x) - start
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        return (0...24).map { step in
            let angle = start + sweep * Double(step) / 24
            return vertex + Vec2(x: cos(angle), y: sin(angle)) * radius
        }
    }

    /// The square in the corner of a right angle: the corner, along one arm, across, along the other.
    static func rightAngle(_ vertex: Vec2, _ a: Vec2, _ b: Vec2, size: Double) -> [Vec2] {
        let u = (a - vertex).normalized * size
        let v = (b - vertex).normalized * size
        return [vertex + u, vertex + u + v, vertex + v]
    }

    /// An arrowhead's three corners, tip first, and where the line should stop so it doesn't show through.
    static func arrowhead(tip: Vec2, from tail: Vec2, length: Double = 11, width: Double = 9) -> (corners: [Vec2], lineEnd: Vec2) {
        let direction = (tip - tail).normalized
        let length = Swift.min(length, (tip - tail).length * 0.6)
        let base = tip - direction * length
        let side = direction.perpendicular * (width / 2 * length / 11)
        return ([tip, base + side, base - side], tip - direction * length * 0.7)
    }
}
