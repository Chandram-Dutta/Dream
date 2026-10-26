import Foundation

/// A point the reader can drag. Dragging it sets the inputs that place it, so a corner at the
/// end of a leg sets the leg, and the tip of a launch arrow sets both speed and angle.
struct FigureHandle: Hashable, Identifiable {
    let point: String
    /// One input, or two that move it in different directions.
    let inputs: [String]
    var id: String { point }
}

extension Figure {
    /// The adjustable numbers that move a point, directly or through outputs and other points.
    func drivers(of name: String, in surface: Surface) -> Set<String> {
        var seen: Set<String> = []
        func walk(_ name: String) -> Set<String> {
            guard let point = point(name), seen.insert(name).inserted else { return [] }
            var found: Set<String> = []
            for formula in [point.x, point.y] {
                guard let expr = try? FormulaCache.parse(formula) else { continue }
                for used in expr.names {
                    if let (other, _) = Figure.coordinate(used), self.point(other) != nil {
                        found.formUnion(walk(other))
                    } else {
                        found.formUnion(surface.inputs(feeding: used))
                    }
                }
            }
            return found
        }
        return walk(name).filter { surface.input($0).map { $0.role == .adjustable && $0.format.isNumeric } ?? false }
    }

    /// Which points can be dragged, and what each one sets. Each input gets one handle at most:
    /// the point it moves most plainly, so a triangle's corner is the handle for its leg rather
    /// than a corner of the square built on it, and the tip of an object sets both its distance
    /// and its height. Points whose formulas name their inputs outright come first, then the
    /// ones most shapes go through, then labeled points, then points moved by one input, then
    /// the ones that travel furthest. A point whose other input already has a handle can still
    /// be the handle for the one that's left.
    func handles(in surface: Surface) -> [FigureHandle] {
        FigureMemo.handles(of: self, in: surface) { findHandles(in: surface) }
    }

    private func findHandles(in surface: Surface) -> [FigureHandle] {
        let initial = surface.inputs.reduce(into: [String: Double]()) { $0[$1.name] = $1.initial }
        struct Candidate {
            let index: Int
            let point: FigurePoint
            let drivers: [String]
            let isDirect: Bool
            /// How many shapes go through it: the figure's own corners, rather than helpers.
            let uses: Int
            /// How far it moves as each driver crosses its range.
            let travel: Double

            var rank: (Int, Int, Int, Int, Double, Int) { (isDirect ? 0 : 1, -uses, point.label.isEmpty ? 1 : 0, drivers.count, -travel, index) }
        }
        func at(_ point: String, _ name: String, _ value: Double) -> Vec2? {
            position(of: point, at: initial.merging([name: value]) { $1 }, in: surface)
        }
        let candidates = points.enumerated().compactMap { index, point -> Candidate? in
            let drivers = drivers(of: point.name, in: surface).sorted()
            guard (1...2).contains(drivers.count) else { return nil }
            // It has to move. Measured at several places, since an angle turned all the way
            // round ends where it started.
            var travel = 0.0
            for name in drivers {
                guard let range = surface.input(name)?.safeRange else { return nil }
                let spots = (0...4).compactMap { at(point.name, name, range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / 4) }
                let reach = spots.flatMap { a in spots.map { ($0 - a).length } }.max() ?? 0
                guard spots.count == 5, reach > 1e-9 else { return nil }
                travel += reach
            }
            let named = [point.x, point.y].reduce(into: Set<String>()) { $0.formUnion((try? FormulaCache.parse($1).names) ?? []) }
            let uses = shapes.filter { $0.points.contains(point.name) }.count
            return Candidate(index: index, point: point, drivers: drivers, isDirect: Set(drivers).isSubset(of: named), uses: uses, travel: travel)
        }
        .sorted { $0.rank < $1.rank }

        /// Two inputs have to move the point in different directions where it starts, or
        /// dragging it couldn't tell them apart.
        func independent(_ point: String, _ drivers: [String]) -> Bool {
            let directions = drivers.compactMap { name -> Vec2? in
                guard let input = surface.input(name), let start = initial[name] else { return nil }
                let range = input.safeRange
                let nudge = (range.upperBound - range.lowerBound) / 100
                guard let a = at(point, name, Swift.max(start - nudge, range.lowerBound)),
                      let b = at(point, name, Swift.min(start + nudge, range.upperBound)) else { return nil }
                return (b - a).normalized
            }
            return directions.count == 2 && abs(directions[0].cross(directions[1])) >= 0.1
        }

        var taken: Set<String> = []
        var chosen: [(index: Int, handle: FigureHandle)] = []
        for candidate in candidates {
            let free = candidate.drivers.filter { !taken.contains($0) }
            guard !free.isEmpty, free.count == 1 || independent(candidate.point.name, free) else { continue }
            chosen.append((candidate.index, FigureHandle(point: candidate.point.name, inputs: free)))
            taken.formUnion(free)
        }
        return chosen.sorted { $0.index < $1.index }.map(\.handle)
    }

    /// The values that bring a handle as close to `target` as its inputs' ranges allow, snapped
    /// to their steps. `given` is what the reader has set so far.
    func dragged(_ handle: FigureHandle, to target: Vec2, in surface: Surface, given: [String: Double]) -> [String: Double] {
        let inputs = handle.inputs.compactMap { surface.input($0) }
        var values = surface.evaluate(given).values.filter { name, _ in surface.input(name) != nil }

        func distance(_ trial: [String: Double]) -> Double {
            position(of: handle.point, at: trial, in: surface).map { ($0 - target).length } ?? .infinity
        }

        /// The best value for one input, the others held where they are.
        func best(_ input: Input, around current: Double, window: Double, samples count: Int) -> Double {
            let range = input.safeRange
            let low = Swift.max(range.lowerBound, current - window)
            let high = Swift.min(range.upperBound, current + window)
            func at(_ value: Double) -> Vec2? {
                var trial = values
                trial[input.name] = value
                return position(of: handle.point, at: trial, in: surface)
            }
            func cost(_ value: Double) -> Double {
                var trial = values
                trial[input.name] = value
                return distance(trial)
            }
            // A point that moves in a straight line, evenly, has an exact answer.
            if let a = at(low), let b = at(high), let middle = at((low + high) / 2) {
                let line = b - a
                if line.length > 0, ((a + b) / 2 - middle).length <= 1e-6 * line.length {
                    let along = Swift.min(Swift.max((target - a).dot(line) / line.dot(line), 0), 1)
                    return low + along * (high - low)
                }
            }
            // Otherwise the nearest of a sweep, narrowed down between its neighbours.
            let samples = (0...count).map { low + (high - low) * Double($0) / Double(count) }
            let costs = samples.map(cost)
            guard let nearest = costs.indices.min(by: { costs[$0] < costs[$1] }) else { return current }
            var a = samples[Swift.max(nearest - 1, 0)], b = samples[Swift.min(nearest + 1, count)]
            let ratio = (sqrt(5) - 1) / 2
            var c = b - (b - a) * ratio, d = a + (b - a) * ratio
            var (costC, costD) = (cost(c), cost(d))
            for _ in 0..<14 {
                if costC < costD {
                    (b, d, costD) = (d, c, costC)
                    c = b - (b - a) * ratio
                    costC = cost(c)
                } else {
                    (a, c, costC) = (c, d, costD)
                    d = a + (b - a) * ratio
                    costD = cost(d)
                }
            }
            return (a + b) / 2
        }

        // One input is solved directly. Two take turns, each from where the other left it:
        // first across their whole ranges, then close to the answer.
        let rounds = inputs.count == 1 ? 1 : 3
        for round in 0..<rounds {
            var moved = false
            for input in inputs {
                let range = input.safeRange
                let current = values[input.name] ?? input.initial
                let window = round == 0 ? range.upperBound - range.lowerBound : (range.upperBound - range.lowerBound) * 0.15
                let value = best(input, around: current, window: window, samples: round == 0 ? 32 : 12)
                moved = moved || abs(value - current) > (input.safeStep ?? 0) / 4
                values[input.name] = value
            }
            if round > 0 && !moved { break }
        }
        return Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, $0.snapped(values[$0.name] ?? $0.initial)) })
    }

    /// Where a point is when the inputs are `given`.
    func position(of name: String, at given: [String: Double], in surface: Surface) -> Vec2? {
        positions(values: surface.evaluate(given).values)[name]
    }
}
