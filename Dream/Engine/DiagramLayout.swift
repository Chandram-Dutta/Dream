import Foundation

/// A diagram placed in a view of a given width, in points with y down. Text is measured by the
/// caller (the app with its fonts, tests with estimates), so every node is wide enough for its
/// longest word and no word is ever broken, and each edge's label sits beside its own line,
/// clear of every node, line and other label.
struct DiagramLayout {
    struct Route {
        let from: String
        let to: String
        /// The line to draw, as points close enough together to read as a curve.
        var points: [Vec2]
        let hasArrow: Bool
        let label: String
        /// The label broken into lines at spaces, and the box it sits in; nil without a label.
        var labelLines: [String] = []
        var labelFrame: Rect2?
    }

    /// How text measures, and the room around it.
    struct Metrics {
        /// How wide a node's text is on one line, in its font.
        var measureNode: (String) -> Double = { Double($0.count) * 8.4 }
        /// How wide an edge's label is on one line.
        var measureLabel: (String) -> Double = { Double($0.count) * 6.4 }
        var lineHeight = 19.0
        var labelLineHeight = 14.0
        /// Room either side of a node's text.
        var nodePadding = 10.0
        var nodeHeight = 50.0
        var gap = 10.0
        var rowGap = 34.0
        var minNodeWidth = 92.0
        var maxNodeWidth = 230.0
        /// How wide an edge's label gets before it wraps.
        var maxLabelWidth = 104.0
        /// Room at the sides for edges that loop back or skip a row.
        var lane = 18.0

        static var standard: Metrics { Metrics() }

        /// The narrowest a node can be: its longest word, with padding.
        func narrowest(_ text: String) -> Double {
            (text.split(separator: " ").map { measureNode(String($0)) }.max() ?? 0) + 2 * nodePadding
        }

        /// A node's width with all its text on one line.
        func oneLine(_ text: String) -> Double { measureNode(text) + 2 * nodePadding }

        /// The gap between rows when an edge's label sits in it.
        var labeledRowGap: Double { 2 * labelLineHeight + 26 }

        /// The same, with text a little smaller, for when a diagram is too cramped at full size.
        func scaled(_ scale: Double) -> Metrics {
            var copy = self
            let (node, label) = (measureNode, measureLabel)
            copy.measureNode = { node($0) * scale }
            copy.measureLabel = { label($0) * scale }
            copy.lineHeight *= scale
            copy.labelLineHeight *= scale
            copy.nodeHeight *= scale
            copy.minNodeWidth *= scale
            return copy
        }
    }

    var width: Double
    var height: Double
    var frames: [String: Rect2]
    /// Each node's text, broken into lines at spaces.
    var lines: [String: [String]] = [:]
    var routes: [Route]
    /// A tree too broad for the width is drawn as an indented outline instead.
    var isOutline = false
    /// The node in the middle of a hub.
    var hub: String?
    /// How much of the labels couldn't be kept clear; zero in a good layout.
    var clashes = 0.0
    /// How the text is sized against the metrics given: below 1 when the diagram only fits with smaller text.
    var textScale = 1.0

    /// The layout at full size, or with slightly smaller text if that's what it takes for
    /// every label to stay clear.
    static func make(_ diagram: Diagram, width: Double, metrics: Metrics = .standard) -> DiagramLayout {
        guard !diagram.nodes.isEmpty, width > 0 else { return DiagramLayout(width: width, height: 0, frames: [:], routes: []) }
        var best: DiagramLayout?
        for scale in [1.0, 0.9, 0.82] {
            var layout = make(diagram, width: width, scaled: metrics.scaled(scale))
            layout.textScale = scale
            if best.map({ layout.clashes < $0.clashes - 0.5 }) ?? true { best = layout }
            if layout.clashes < 1 { break }
        }
        return best ?? DiagramLayout(width: width, height: 0, frames: [:], routes: [])
    }

    private static func make(_ diagram: Diagram, width: Double, scaled metrics: Metrics) -> DiagramLayout {
        var metrics = metrics
        var layout = build(diagram, width: width, metrics: metrics)
        // Nodes are as tall as the longest text among them needs.
        let most = Double(layout.lines.values.map(\.count).max() ?? 1)
        if most * metrics.lineHeight + 12 > metrics.nodeHeight, !layout.isOutline {
            metrics.nodeHeight = most * metrics.lineHeight + 12
            layout = build(diagram, width: width, metrics: metrics)
        }
        return layout
    }

    private static func build(_ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        switch diagram.shape {
        case .flow: flow(diagram, width: width, metrics: metrics)
        case .cycle: cycle(diagram, width: width, metrics: metrics)
        case .hub: hub(of: diagram).map { hubLayout(diagram, width: width, metrics: metrics, hub: $0) } ?? flow(diagram, width: width, metrics: metrics)
        case .tree: tree(diagram, width: width, metrics: metrics)
        }
    }

    /// Whether any two nodes overlap. Layouts are built never to, so this is for tests.
    var hasOverlaps: Bool {
        let boxes = Array(frames.values)
        return boxes.indices.contains { i in boxes.indices.contains { j in i < j && boxes[i].overlap(boxes[j]) > 0 } }
    }

    /// Labels that overlap a node or another label. Layouts are built to have none; this is for tests.
    var crowdedLabels: Int {
        let boxes = routes.compactMap(\.labelFrame)
        return boxes.indices.filter { i in
            frames.values.contains { $0.overlap(boxes[i]) > 0.5 } || boxes.indices.contains { $0 != i && boxes[$0].overlap(boxes[i]) > 0.5 }
        }.count
    }

    /// Labels that cross a line, their own included.
    var labelsOnLines: Int {
        let segments = routes.flatMap { zip($0.points, $0.points.dropFirst()).map { ($0, $1) } }
        return routes.compactMap(\.labelFrame).filter { box in segments.contains { box.crosses($0.0, $0.1) } }.count
    }

    /// Text broken into lines at spaces, never inside a word, each as long as `width` allows.
    /// Past the last line allowed, the rest stays on the last line.
    static func wrap(_ text: String, width: Double, measure: (String) -> Double, maxLines: Int) -> [String] {
        var lines: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if let last = lines.last, measure(last + " " + word) <= width {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        guard lines.count > maxLines else { return lines }
        return Array(lines.prefix(maxLines - 1)) + [lines.dropFirst(maxLines - 1).joined(separator: " ")]
    }

    // MARK: - Finishing

    /// Nodes and lines, before the labels are placed and the whole is moved to start at the top.
    private struct Draft {
        var frames: [String: Rect2] = [:]
        var routes: [Route] = []
        /// For a route along a cycle, the centre its label keeps away from.
        var away: [Int: Vec2] = [:]
        var isOutline = false
        var hub: String?
    }

    private static func finish(_ draft: Draft, _ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        var layout = DiagramLayout(width: width, height: 0, frames: draft.frames, routes: draft.routes, isOutline: draft.isOutline, hub: draft.hub)
        for node in diagram.nodes {
            guard let frame = draft.frames[node.id] else { continue }
            layout.lines[node.id] = wrap(node.label, width: frame.width - 2 * metrics.nodePadding, measure: metrics.measureNode, maxLines: 3)
        }
        layout.placeLabels(away: draft.away, metrics: metrics)
        layout.settle()
        return layout
    }

    /// Each label beside its own line, at the first spot along it that covers no node, no line
    /// and no other label, and is nearer its own line than any other. A label along a cycle
    /// stays outside it, never in the middle. Labels go in order, then each is placed again
    /// knowing where all the others went, so an early one can make way for a later one.
    private mutating func placeLabels(away: [Int: Vec2], metrics: Metrics) {
        let segments = routes.flatMap { zip($0.points, $0.points.dropFirst()).map { ($0, $1) } }
        let nodes = Array(frames.values)
        let labeled = routes.indices.filter { !routes[$0].label.isEmpty && routes[$0].points.count >= 2 }
        var placed: [Int: Rect2] = [:]
        var costs: [Int: Double] = [:]

        func place(_ index: Int) {
            // As wide as reads well, or narrower on more lines where that's what fits beside the line.
            let wide = Self.wrap(routes[index].label, width: metrics.maxLabelWidth, measure: metrics.measureLabel, maxLines: 2)
            let narrow = Self.wrap(routes[index].label, width: metrics.maxLabelWidth * 0.6, measure: metrics.measureLabel, maxLines: 3)
            let others = placed.filter { $0.key != index }.map(\.value)
            var best: (score: Double, cost: Double, box: Rect2, text: [String])?
            var rank = 0.0
            for text in narrow == wide ? [wide] : [wide, narrow] {
                let size = Vec2(x: (text.map(metrics.measureLabel).max() ?? 0) + 12, y: Double(text.count) * metrics.labelLineHeight + 4)
                for fraction in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8, 0.12, 0.88] {
                    let (point, tangent) = Self.along(routes[index].points, fraction)
                    var across = tangent.perpendicular.normalized
                    // Along a cycle, outside it; just inside only when everything outside is taken.
                    var inward = 0.0
                    if let center = away[index], across.dot(point - center) < 0 { across = across * -1 }
                    for side in [across, across * -1] {
                        if away[index] != nil, side != across { inward = 50 }
                        for extra in [5.0, 14, 26, 40] {
                            let reach = abs(side.x) * size.x / 2 + abs(side.y) * size.y / 2 + extra
                            let box = Rect2(center: point + side * reach, width: size.x, height: size.y)
                            let room = box.insetBy(-3)
                            let crowding = nodes.reduce(0) { $0 + room.overlap($1) } + others.reduce(0) { $0 + room.overlap($1) }
                            let crossing = Double(segments.filter { box.insetBy(-2).crosses($0.0, $0.1) }.count) * 40
                            let spill = (Swift.max(0, -box.minX) + Swift.max(0, box.maxX - width)) * size.y
                            let own = Self.distance(from: box, to: routes[index].points)
                            let nearest = routes.indices.filter { $0 != index }.map { Self.distance(from: box, to: routes[$0].points) }.min() ?? .infinity
                            // Covering anything counts far more than being ambiguous, which counts more than the order tried.
                            let cost = crowding + crossing + spill
                            let score = cost * 100 + inward + (nearest < own + 4 ? 5 : 0) + rank
                            if best.map({ score < $0.score }) ?? true { best = (score, cost, box, text) }
                            rank += 0.01
                        }
                    }
                }
            }
            guard let best else { return }
            routes[index].labelLines = best.text
            routes[index].labelFrame = best.box
            placed[index] = best.box
            costs[index] = best.cost
        }

        for index in labeled { place(index) }
        for _ in 0..<2 where costs.values.contains(where: { $0 > 0 }) {
            for index in labeled { place(index) }
        }
        clashes = costs.values.reduce(0, +)
    }

    /// Moves everything so the highest node, line or label is at the top, and sets the height.
    private mutating func settle() {
        let boxes = Array(frames.values) + routes.compactMap(\.labelFrame) + routes.compactMap { Rect2(containing: $0.points) }
        let top = boxes.map(\.minY).min() ?? 0
        let shift = Vec2(x: 0, y: -top)
        frames = frames.mapValues { $0.offsetBy(shift) }
        for index in routes.indices {
            routes[index].points = routes[index].points.map { $0 + shift }
            routes[index].labelFrame = routes[index].labelFrame?.offsetBy(shift)
        }
        height = (boxes.map(\.maxY).max() ?? 0) - top
    }

    /// How far a box is from the nearest point of a line.
    private static func distance(from box: Rect2, to points: [Vec2]) -> Double {
        zip(points, points.dropFirst()).map { a, b -> Double in
            if box.crosses(a, b) { return 0 }
            let corners = [Vec2(x: box.minX, y: box.minY), Vec2(x: box.maxX, y: box.minY), Vec2(x: box.maxX, y: box.maxY), Vec2(x: box.minX, y: box.maxY)]
            let toCorners = corners.map { point in
                let along = b - a
                let t = along.dot(along) > 0 ? Swift.min(Swift.max((point - a).dot(along) / along.dot(along), 0), 1) : 0
                return (a + along * t - point).length
            }
            let toEnds = [a, b].map { point in
                (Vec2(x: Swift.min(Swift.max(point.x, box.minX), box.maxX), y: Swift.min(Swift.max(point.y, box.minY), box.maxY)) - point).length
            }
            return (toCorners + toEnds).min() ?? .infinity
        }.min() ?? .infinity
    }

    /// The point a fraction of the way along a line, and the line's direction there.
    private static func along(_ points: [Vec2], _ fraction: Double) -> (Vec2, Vec2) {
        let lengths = zip(points, points.dropFirst()).map { ($1 - $0).length }
        var remaining = lengths.reduce(0, +) * fraction
        for (index, length) in lengths.enumerated() where length > 0 {
            if remaining <= length || index == lengths.count - 1 {
                let direction = (points[index + 1] - points[index]) / length
                return (points[index] + direction * Swift.min(remaining, length), direction)
            }
            remaining -= length
        }
        return (points[0], Vec2(x: 1, y: 0))
    }

    // MARK: - Flow

    /// Rows top to bottom, each node a row below everything that leads to it. Steps side by side
    /// are alternatives or happen together. Edges that go back up, or skip a row, run down the sides.
    private static func flow(_ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        let ids = diagram.nodes.map(\.id)
        let texts = Dictionary(diagram.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let edges = diagram.connections
        let backward = backEdges(ids: ids, edges: edges)
        let forward = edges.enumerated().filter { !backward.contains($0.offset) }.map(\.element)

        // Each node one layer below the furthest node that leads to it.
        var layer: [String: Int] = [:]
        func depth(_ id: String, _ visiting: Set<String> = []) -> Int {
            if let known = layer[id] { return known }
            let parents = forward.filter { $0.to == id && !visiting.contains($0.from) }.map(\.from)
            let result = parents.map { depth($0, visiting.union([id])) + 1 }.max() ?? 0
            layer[id] = result
            return result
        }
        // A node with no edges at all follows the one before it.
        var previous = -1
        for id in ids {
            let connected = edges.contains { $0.from == id || $0.to == id }
            layer[id] = connected ? depth(id) : previous + 1
            previous = layer[id] ?? previous
        }

        // Lanes at the sides: a return on the right, a skip on the left.
        let skips = forward.contains { (layer[$0.to] ?? 0) - (layer[$0.from] ?? 0) > 1 }
        let returns = edges.enumerated().filter { backward.contains($0.offset) }.map(\.element)
        let narrow = { (id: String) in metrics.narrowest(texts[id] ?? "") }
        func rows(of members: [String], usable: Double) -> [[String]] {
            // As many side by side as fit with room for their longest words, three at most.
            var rows: [[String]] = []
            for id in members {
                if let last = rows.last, last.count < 3 {
                    let trial = last + [id]
                    let needed = (trial.map(narrow).max() ?? 0) * Double(trial.count) + metrics.gap * Double(trial.count - 1)
                    if needed <= usable {
                        rows[rows.count - 1] = trial
                        continue
                    }
                }
                rows.append([id])
            }
            return rows
        }
        var left = skips ? metrics.lane : 0
        let right = returns.isEmpty ? 0 : metrics.lane + Double(Swift.min(returns.count, 3) - 1) * 6
        var usable = width - left - right

        var rowList: [[String]] = []
        var column: [String: Double] = [:]
        func arrange() {
            rowList = []
            column = [:]
            for level in 0...(layer.values.max() ?? 0) {
                let members = ids.filter { layer[$0] == level }
                // In an order that keeps each node under the ones it follows.
                let ordered = members.enumerated().sorted { a, b in
                    func weight(_ id: String, _ index: Int) -> Double {
                        let parents = forward.filter { $0.to == id }.compactMap { column[$0.from] }
                        return parents.isEmpty ? Double(index) : parents.reduce(0, +) / Double(parents.count)
                    }
                    return (weight(a.element, a.offset), a.offset) < (weight(b.element, b.offset), b.offset)
                }.map(\.element)
                for row in rows(of: ordered, usable: usable) {
                    for (index, id) in row.enumerated() { column[id] = Double(index) - Double(row.count - 1) / 2 }
                    rowList.append(row)
                }
            }
        }
        arrange()
        // A layer split over two rows makes its edges skip a row, which needs the left lane.
        if left == 0, rowList.count > (layer.values.max() ?? 0) + 1 {
            left = metrics.lane
            usable = width - left - right
            arrange()
        }
        let rowOf = Dictionary(uniqueKeysWithValues: rowList.enumerated().flatMap { index, row in row.map { ($0, index) } })

        var draft = Draft()
        var y = 0.0
        for (index, row) in rowList.enumerated() {
            let count = Double(row.count)
            let narrowest = row.map(narrow).max() ?? metrics.minNodeWidth
            let nodeWidth = Swift.min(usable, row.count == 1
                ? Swift.max(narrowest, Swift.min(metrics.maxNodeWidth + 10, usable * 0.72))
                : Swift.max(narrowest, Swift.min(metrics.maxNodeWidth, (usable - metrics.gap * (count - 1)) / count)))
            let total = nodeWidth * count + metrics.gap * (count - 1)
            for (position, id) in row.enumerated() {
                let x = left + (usable - total) / 2 + Double(position) * (nodeWidth + metrics.gap)
                draft.frames[id] = Rect2(minX: x, minY: y, maxX: x + nodeWidth, maxY: y + metrics.nodeHeight)
            }
            let next = index + 1 < rowList.count ? rowList[index + 1] : []
            let labeled = forward.contains { !$0.label.isEmpty && row.contains($0.from) && next.contains($0.to) }
            y += metrics.nodeHeight + (labeled ? metrics.labeledRowGap : metrics.rowGap)
        }

        var lanes = (left: 0, right: 0)
        for edge in edges {
            guard let source = draft.frames[edge.from], let target = draft.frames[edge.to] else { continue }
            let rise = (rowOf[edge.to] ?? 0) - (rowOf[edge.from] ?? 0)
            let points: [Vec2]
            if rise == 1 {
                // Straight down, or a gentle S between neighbouring rows.
                let start = Vec2(x: source.center.x, y: source.maxY + 3)
                let end = Vec2(x: target.center.x, y: target.minY - 3)
                points = curve(start, start + Vec2(x: 0, y: (end.y - start.y) / 2), end - Vec2(x: 0, y: (end.y - start.y) / 2), end)
            } else {
                // Down the left for a skip, up the right for a return.
                let isReturn = rise <= 0 && returns.contains(edge)
                let lane = isReturn ? width - metrics.lane / 2 - Double(lanes.right % 3) * 6 : metrics.lane / 2 + Double(lanes.left % 3) * 6
                if isReturn { lanes.right += 1 } else { lanes.left += 1 }
                let start = Vec2(x: isReturn ? source.maxX + 3 : source.minX - 3, y: source.center.y)
                let end = Vec2(x: isReturn ? target.maxX + 3 : target.minX - 3, y: target.center.y)
                points = elbow(start, end, lane: lane, side: isReturn ? 1 : -1)
            }
            draft.routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label))
        }
        return finish(draft, diagram, width: width, metrics: metrics)
    }

    /// Edges that point back to a node before them, found by walking the flow from its starts.
    private static func backEdges(ids: [String], edges: [Diagram.Edge]) -> Set<Int> {
        var state: [String: Int] = [:] // 1 while being walked, 2 once done
        var back: Set<Int> = []
        func visit(_ id: String) {
            state[id] = 1
            for (index, edge) in edges.enumerated() where edge.from == id {
                switch state[edge.to] {
                case 1: back.insert(index)
                case nil: visit(edge.to)
                default: break
                }
            }
            state[id] = 2
        }
        let starts = ids.filter { id in !edges.contains { $0.to == id } }
        for id in starts + ids where state[id] == nil { visit(id) }
        return back
    }

    // MARK: - Cycle

    /// A cycle's stages round a loop, clockwise from the top, in the order of the longest loop
    /// its edges make. The loop is a stadium: two columns joined by arcs, so it fits a phone at
    /// any count, with stages side by side only across its width. Stages off the loop sit just
    /// outside it beside the stages they connect to, or inside it where the screen has no room.
    /// Labels go outside the loop; if they don't fit, the loop narrows to make room.
    private static func cycle(_ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        let ids = diagram.nodes.map(\.id)
        let edges = diagram.connections
        let order = mainCycle(ids: ids, edges: edges)
        let side = ids.filter { !order.contains($0) }
        // Room for every node's longest word, and its whole text on one line if that's not much more.
        let narrowest = diagram.nodes.map { metrics.narrowest($0.label) }.max() ?? metrics.minNodeWidth
        let comfortable = Swift.min(diagram.nodes.map { metrics.oneLine($0.label) }.max() ?? 0, width * 0.36)
        let nodeWidth = Swift.min(Swift.max(narrowest, comfortable, metrics.minNodeWidth), width * 0.46)
        let widest = (width - nodeWidth) / 2 - 2

        var best: DiagramLayout?
        var bestCost = Double.infinity
        for room in edges.contains(where: { !$0.label.isEmpty }) ? [0.0, 12, 24, 36, 48] : [0.0] {
            let radius = widest - room
            // Stages across from each other need room between them for an arrow.
            guard room == 0 || 2 * radius >= nodeWidth + 40 else { break }
            let draft = loopDraft(order: order, side: side, edges: edges, width: width, nodeWidth: nodeWidth, radius: radius, metrics: metrics)
            let layout = finish(draft, diagram, width: width, metrics: metrics)
            let cost = layout.clashes + (layout.hasOverlaps ? 1_000_000 : 0)
            if cost < bestCost {
                best = layout
                bestCost = cost
            }
            if cost < 1 { break }
        }
        return best ?? DiagramLayout(width: width, height: 0, frames: [:], routes: [])
    }

    /// A stadium: from the top centre, clockwise round a right arc, down a column, round the
    /// bottom and up the other column, in points along its length.
    private struct Stadium {
        let center: Vec2
        let radius: Double
        let straight: Double

        var length: Double { 2 * .pi * radius + 2 * straight }
        var top: Vec2 { center - Vec2(x: 0, y: straight / 2) }
        var bottom: Vec2 { center + Vec2(x: 0, y: straight / 2) }

        func point(_ distance: Double) -> Vec2 {
            var u = distance.truncatingRemainder(dividingBy: length)
            if u < 0 { u += length }
            let quarter = .pi * radius / 2
            func around(_ middle: Vec2, _ angle: Double) -> Vec2 { middle + Vec2(x: cos(angle), y: sin(angle)) * radius }
            if u < quarter { return around(top, -.pi / 2 + u / radius) }
            u -= quarter
            if u < straight { return Vec2(x: center.x + radius, y: top.y + u) }
            u -= straight
            if u < 2 * quarter { return around(bottom, u / radius) }
            u -= 2 * quarter
            if u < straight { return Vec2(x: center.x - radius, y: bottom.y - u) }
            u -= straight
            return around(top, .pi + u / radius)
        }

        /// Whether a point is inside the loop.
        func contains(_ point: Vec2) -> Bool {
            let nearest = Vec2(x: center.x, y: Swift.min(Swift.max(point.y, top.y), bottom.y))
            return (point - nearest).length < radius
        }
    }

    private static func loopDraft(order: [String], side: [String], edges: [Diagram.Edge], width: Double, nodeWidth: Double, radius: Double, metrics: Metrics) -> Draft {
        var draft = Draft()
        let height = metrics.nodeHeight
        let count = Double(Swift.max(order.count, 1))
        // As round as it can be with no stages touching and room between neighbours for an arrow.
        var loop = Stadium(center: Vec2(x: width / 2, y: 0), radius: radius, straight: 0)
        for straight in stride(from: 0.0, through: count * (height + 60), by: 8) {
            let trial = Stadium(center: Vec2(x: width / 2, y: 0), radius: radius, straight: straight)
            let boxes = order.indices.map { Rect2(center: trial.point(trial.length * Double($0) / count), width: nodeWidth, height: height) }
            let clear = !boxes.indices.contains { i in boxes.indices.contains { j in i < j && boxes[i].insetBy(-metrics.gap / 2).overlap(boxes[j].insetBy(-metrics.gap / 2)) > 0 } }
            let roomy = order.count < 2 || order.indices.allSatisfy { i in
                let (a, b) = (boxes[i], boxes[(i + 1) % order.count])
                return Swift.max(b.minX - a.maxX, a.minX - b.maxX, b.minY - a.maxY, a.minY - b.maxY) >= 26
            }
            loop = trial
            if clear && roomy { break }
        }
        let spot = { (index: Int) in loop.length * Double(index) / count }
        for (index, id) in order.enumerated() {
            draft.frames[id] = Rect2(center: loop.point(spot(index)), width: nodeWidth, height: height)
        }

        // Stages off the loop, beside the stages they connect to: outside if there's room,
        // otherwise inside, but never on the loop itself.
        let outline = (0..<160).map { loop.point(loop.length * Double($0) / 160) }
        for id in side {
            let neighbours = edges.filter { $0.from == id || $0.to == id }.map { $0.from == id ? $0.to : $0.from }
            let anchors = neighbours.compactMap { order.firstIndex(of: $0) }
            let base: Vec2
            if let first = anchors.first {
                // Halfway round the shorter way between its anchors.
                let last = anchors.count > 1 ? anchors[1] : first
                var span = Double(last - first)
                if abs(span) > count / 2 { span -= span > 0 ? count : -count }
                base = loop.point(spot(first) + loop.length * span / 2 / count)
            } else {
                base = neighbours.compactMap { draft.frames[$0]?.center }.first ?? loop.point(loop.length / 2)
            }
            let outward = (base - loop.center).length > 0 ? (base - loop.center).normalized : Vec2(x: 0, y: 1)
            var choice: (cost: Double, box: Rect2)?
            for direction in [outward, Vec2(x: 0, y: -1), Vec2(x: 0, y: 1), outward * -1] {
                for distance in stride(from: height * 0.6, through: 600, by: 6) {
                    var center = base + direction * distance
                    center.x = Swift.min(Swift.max(center.x, nodeWidth / 2 + 1), width - nodeWidth / 2 - 1)
                    let box = Rect2(center: center, width: nodeWidth, height: height)
                    guard !draft.frames.values.contains(where: { $0.insetBy(-metrics.gap).overlap(box) > 0 }),
                          !outline.contains(where: { box.insetBy(-12).contains($0) }) else { continue }
                    let cost = (center - base).length + (loop.contains(center) ? 60 : 0)
                    if choice.map({ cost < $0.cost }) ?? true { choice = (cost, box) }
                    break
                }
            }
            draft.frames[id] = choice?.box ?? Rect2(center: base + outward * (height + 40), width: nodeWidth, height: height)
        }

        var later: [Diagram.Edge] = []
        for edge in edges {
            guard let source = draft.frames[edge.from], let target = draft.frames[edge.to] else { continue }
            guard let i = order.firstIndex(of: edge.from), let j = order.firstIndex(of: edge.to), order.count >= 2,
                  (j - i + order.count) % order.count == 1 || (i - j + order.count) % order.count == 1 else {
                later.append(edge)
                continue
            }
            // Neighbours on the loop: along it, forwards if that's the way it goes, or back.
            let forwards = (j - i + order.count) % order.count == 1
            var (start, end) = (spot(i), spot(j))
            if forwards, end <= start { end += loop.length }
            if !forwards, end >= start { start += loop.length }
            let points = trimmed((0...48).map { loop.point(start + (end - start) * Double($0) / 48) }, from: source.insetBy(-4), to: target.insetBy(-4))
            guard points.count >= 2 else { continue }
            draft.away[draft.routes.count] = loop.center
            draft.routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label))
        }
        // The rest, across the loop or out to a stage beside it, bent round any stage in the way.
        for edge in later {
            guard let source = draft.frames[edge.from], let target = draft.frames[edge.to] else { continue }
            let points = avoiding(from: source, to: target, frames: draft.frames, lines: draft.routes.map(\.points), width: width)
            guard points.count >= 2 else { continue }
            draft.routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label))
        }
        return draft
    }

    // MARK: - Hub

    /// The hub in the middle, what flows into it above and what comes out of it below, in rows
    /// that fit the width. Everything else is shared between the two sides.
    private static func hubLayout(_ diagram: Diagram, width: Double, metrics: Metrics, hub: String) -> DiagramLayout {
        let edges = diagram.connections
        let texts = Dictionary(diagram.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let others = diagram.nodes.map(\.id).filter { $0 != hub }
        let into = others.filter { id in edges.contains { $0.from == id && $0.to == hub } && !edges.contains { $0.from == hub && $0.to == id } }
        let out = others.filter { id in !into.contains(id) && edges.contains { $0.from == hub && $0.to == id } }
        var above = into, below = out
        for id in others where !into.contains(id) && !out.contains(id) {
            if above.count <= below.count { above.append(id) } else { below.append(id) }
        }
        let narrow = { (id: String) in metrics.narrowest(texts[id] ?? "") }
        func rows(_ members: [String]) -> [[String]] {
            var rows: [[String]] = []
            for id in members {
                if let last = rows.last, last.count < 3 {
                    let trial = last + [id]
                    if (trial.map(narrow).max() ?? 0) * Double(trial.count) + metrics.gap * Double(trial.count - 1) <= width {
                        rows[rows.count - 1] = trial
                        continue
                    }
                }
                rows.append([id])
            }
            return rows
        }
        let labeled = edges.contains { !$0.label.isEmpty }
        let spoke = labeled ? metrics.labeledRowGap + 60 : metrics.rowGap + 10
        var draft = Draft(hub: hub)
        var y = 0.0
        func place(_ row: [String]) {
            let count = Double(row.count)
            let nodeWidth = Swift.min(width, Swift.max(row.map(narrow).max() ?? 0, Swift.min(metrics.maxNodeWidth, (width - metrics.gap * (count - 1)) / count)))
            let total = nodeWidth * count + metrics.gap * (count - 1)
            for (position, id) in row.enumerated() {
                let x = (width - total) / 2 + Double(position) * (nodeWidth + metrics.gap)
                draft.frames[id] = Rect2(minX: x, minY: y, maxX: x + nodeWidth, maxY: y + metrics.nodeHeight)
            }
        }
        let aboveRows = rows(above), belowRows = rows(below)
        // The row nearest the hub is closest to it, so the first above goes last.
        for (index, row) in aboveRows.reversed().enumerated() {
            place(row)
            y += metrics.nodeHeight + (index == aboveRows.count - 1 ? spoke : metrics.rowGap)
        }
        let hubWidth = Swift.min(width, Swift.max(narrow(hub), Swift.min(metrics.oneLine(texts[hub] ?? ""), width * 0.6)))
        draft.frames[hub] = Rect2(minX: (width - hubWidth) / 2, minY: y, maxX: (width + hubWidth) / 2, maxY: y + metrics.nodeHeight + 6)
        y += metrics.nodeHeight + 6 + spoke
        for row in belowRows {
            place(row)
            y += metrics.nodeHeight + metrics.rowGap
        }
        for edge in edges {
            guard let source = draft.frames[edge.from], let target = draft.frames[edge.to] else { continue }
            let points = avoiding(from: source, to: target, frames: draft.frames, lines: draft.routes.map(\.points), width: width)
            guard points.count >= 2 else { continue }
            draft.routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label))
        }
        return finish(draft, diagram, width: width, metrics: metrics)
    }

    /// A line between two nodes that goes round the others: straight if nothing's in the way,
    /// otherwise bowed to whichever side crosses least, nodes first, then other lines, and
    /// never off the side of the screen.
    private static func avoiding(from source: Rect2, to target: Rect2, frames: [String: Rect2], lines: [[Vec2]], width: Double) -> [Vec2] {
        let others = frames.values.filter { $0 != source && $0 != target }.map { $0.insetBy(-6) }
        let segments = lines.flatMap { zip($0, $0.dropFirst()).map { ($0, $1) } }
        // Each end leans towards the other, so lines meeting at one node arrive side by side, not crossed.
        func port(_ box: Rect2, toward point: Vec2) -> Vec2 {
            box.center + Vec2(x: Swift.min(Swift.max((point.x - box.center.x) * 0.45, -box.width / 2 + 14), box.width / 2 - 14), y: 0)
        }
        let (start, end) = (port(source, toward: target.center), port(target, toward: source.center))
        let across = (end - start).perpendicular.normalized
        let length = (end - start).length
        var best: (cost: Double, points: [Vec2])?
        for (rank, bow) in [0.0, 0.2, -0.2, 0.4, -0.4, 0.7, -0.7, 1.0, -1.0].enumerated() {
            let control = (start + end) / 2 + across * (bow * length)
            let curve = (0...32).map { step -> Vec2 in
                let t = Double(step) / 32
                return start * ((1 - t) * (1 - t)) + control * (2 * (1 - t) * t) + end * (t * t)
            }
            let points = trimmed(curve, from: source.insetBy(-4), to: target.insetBy(-4))
            guard points.count >= 2 else { continue }
            let blocked = points.filter { point in others.contains { $0.contains(point) } }.count
            let crossings = zip(points, points.dropFirst()).filter { a, b in segments.contains { intersects(a, b, $0.0, $0.1) } }.count
            let outside = points.filter { $0.x < 2 || $0.x > width - 2 }.count
            let cost = Double(blocked + outside) * 100 + Double(crossings) * 10 + Double(rank)
            if best.map({ cost < $0.cost }) ?? true { best = (cost, points) }
        }
        return best?.points ?? []
    }

    /// Whether two line segments cross.
    private static func intersects(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let (r, s) = (b - a, d - c)
        let denominator = r.cross(s)
        guard abs(denominator) > 1e-9 else { return false }
        let t = (c - a).cross(s) / denominator
        let u = (c - a).cross(r) / denominator
        return t > 0.001 && t < 0.999 && u > 0.001 && u < 0.999
    }

    /// The order round a cycle: the longest loop its edges make, starting from the earliest
    /// stage on it, so a cycle that starts where the model started does so at the top. Without
    /// a loop, the longest chain.
    static func mainCycle(ids: [String], edges: [Diagram.Edge]) -> [String] {
        var next: [String: [String]] = [:]
        for edge in edges where edge.from != edge.to { next[edge.from, default: []].append(edge.to) }
        var budget = 200_000
        func longest(from start: String, closing: Bool) -> [String] {
            var best: [String] = []
            var path = [start]
            func walk() {
                budget -= 1
                guard budget > 0, let last = path.last else { return }
                if !closing, path.count > best.count { best = path }
                for node in next[last] ?? [] {
                    if node == start {
                        if closing, path.count > best.count { best = path }
                    } else if !path.contains(node) {
                        path.append(node)
                        walk()
                        path.removeLast()
                    }
                }
            }
            walk()
            return best
        }
        var loop: [String] = []
        for start in ids {
            let found = longest(from: start, closing: true)
            if found.count > loop.count { loop = found }
        }
        if loop.count >= 2 {
            let position = { (id: String) in ids.firstIndex(of: id) ?? ids.count }
            guard let first = loop.min(by: { position($0) < position($1) }), let index = loop.firstIndex(of: first) else { return loop }
            return Array(loop[index...] + loop[..<index])
        }
        var chain: [String] = []
        for start in ids {
            let found = longest(from: start, closing: false)
            if found.count > chain.count { chain = found }
        }
        return chain.count >= 2 ? chain : ids
    }

    /// The hub: the node with the most connections, the first one if it's a tie.
    private static func hub(of diagram: Diagram) -> String? {
        let edges = diagram.connections
        return diagram.nodes.map(\.id).enumerated().max { a, b in
            let degree = { (id: String) in edges.filter { $0.from == id || $0.to == id }.count }
            return (degree(a.element), -a.offset) < (degree(b.element), -b.offset)
        }?.element
    }

    // MARK: - Tree

    /// Top down when the leaves fit side by side with room for their words; otherwise an
    /// indented outline, which reads at any width.
    private static func tree(_ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        let ids = diagram.nodes.map(\.id)
        let edges = diagram.connections
        // Each node's first parent; others are drawn but don't shape the tree.
        var parent: [String: String] = [:]
        var children: [String: [String]] = [:]
        let roots = ids.filter { id in !edges.contains { $0.to == id } }
        var queue = roots.isEmpty ? [ids[0]] : roots
        var reached = Set(queue)
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for edge in edges where edge.from == id && !reached.contains(edge.to) {
                reached.insert(edge.to)
                parent[edge.to] = id
                children[id, default: []].append(edge.to)
                queue.append(edge.to)
            }
        }
        let tops = (roots.isEmpty ? [ids[0]] : roots) + ids.filter { !reached.contains($0) }

        func leaves(_ id: String) -> Int { children[id].map { $0.map(leaves).reduce(0, +) } ?? 1 }
        let slot = width / Double(tops.map(leaves).reduce(0, +))
        let nodeWidth = Swift.min(metrics.maxNodeWidth, slot - metrics.gap)
        let narrowest = diagram.nodes.map { metrics.narrowest($0.label) }.max() ?? metrics.minNodeWidth

        var draft = Draft()
        if nodeWidth >= Swift.max(narrowest, metrics.minNodeWidth * 0.9) {
            // Leaves share the width; each parent sits over its children.
            let step = metrics.nodeHeight + (edges.contains { !$0.label.isEmpty } ? metrics.labeledRowGap : metrics.rowGap + 6)
            var next = 0.0
            func place(_ id: String, depth: Int) -> Double {
                var x = (next + 0.5) * slot
                if let kids = children[id], let first = kids.first.map({ place($0, depth: depth + 1) }) {
                    let last = kids.dropFirst().map { place($0, depth: depth + 1) }.last ?? first
                    x = (first + last) / 2
                } else {
                    next += 1
                }
                draft.frames[id] = Rect2(center: Vec2(x: x, y: Double(depth) * step + metrics.nodeHeight / 2), width: nodeWidth, height: metrics.nodeHeight)
                return x
            }
            for top in tops { _ = place(top, depth: 0) }
            for edge in edges {
                guard let source = draft.frames[edge.from], let target = draft.frames[edge.to] else { continue }
                let start = Vec2(x: source.center.x, y: source.maxY + 2)
                let end = Vec2(x: target.center.x, y: target.minY - 2)
                let bend = (end.y - start.y) / 2
                draft.routes.append(Route(from: edge.from, to: edge.to, points: curve(start, start + Vec2(x: 0, y: bend), end - Vec2(x: 0, y: bend), end), hasArrow: false, label: edge.label))
            }
            return finish(draft, diagram, width: width, metrics: metrics)
        }

        // An outline: each node on its own line, indented under its parent, joined by an elbow.
        // What joins a node to its parent is shown beside its name, since there's no room on the lines.
        let indent = 22.0
        let texts = Dictionary(diagram.nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        var y = 0.0
        func list(_ id: String, depth: Int) {
            let x = Double(depth) * indent
            let lines = wrap(texts[id] ?? "", width: width - x - 2 * metrics.nodePadding, measure: metrics.measureNode, maxLines: 3)
            let rowHeight = Swift.max(metrics.nodeHeight * 0.8, Double(lines.count) * metrics.lineHeight + 12)
            draft.frames[id] = Rect2(minX: x, minY: y, maxX: width, maxY: y + rowHeight)
            y += rowHeight + metrics.gap
            for child in children[id] ?? [] { list(child, depth: depth + 1) }
        }
        for top in tops { list(top, depth: 0) }
        for (child, parentID) in parent {
            guard let source = draft.frames[parentID], let target = draft.frames[child] else { continue }
            let x = source.minX + indent / 2
            draft.routes.append(Route(from: parentID, to: child, points: [Vec2(x: x, y: source.maxY), Vec2(x: x, y: target.center.y), Vec2(x: target.minX - 2, y: target.center.y)],
                                      hasArrow: false, label: ""))
        }
        draft.isOutline = true
        return finish(draft, diagram, width: width, metrics: metrics)
    }

    // MARK: - Lines

    /// A cubic Bézier, as points.
    private static func curve(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> [Vec2] {
        (0...16).map { step in
            let t = Double(step) / 16
            let u = 1 - t
            return a * (u * u * u) + b * (3 * u * u * t) + c * (3 * u * t * t) + d * (t * t * t)
        }
    }

    /// Out to a lane at the side, along it, and back in, with rounded corners.
    private static func elbow(_ start: Vec2, _ end: Vec2, lane: Double, side: Double) -> [Vec2] {
        let radius = Swift.min(10, abs(end.y - start.y) / 2, abs(lane - start.x))
        let down = end.y > start.y ? 1.0 : -1.0
        return [start, Vec2(x: lane - side * radius, y: start.y)]
            + curve(Vec2(x: lane - side * radius, y: start.y), Vec2(x: lane, y: start.y), Vec2(x: lane, y: start.y), Vec2(x: lane, y: start.y + down * radius))
            + curve(Vec2(x: lane, y: end.y - down * radius), Vec2(x: lane, y: end.y), Vec2(x: lane, y: end.y), Vec2(x: lane - side * radius, y: end.y))
            + [end]
    }

    /// The part of a line outside both nodes, so it starts and ends at their edges.
    private static func trimmed(_ points: [Vec2], from source: Rect2, to target: Rect2) -> [Vec2] {
        guard points.count >= 2 else { return points }
        var line = points
        if line.count == 2 {
            // Densify a straight line so it can be cut close to each box.
            line = (0...60).map { line[0] + (line[1] - line[0]) * (Double($0) / 60) }
        }
        let start = line.firstIndex { !source.contains($0) } ?? 0
        let end = line.lastIndex { !target.contains($0) } ?? line.count - 1
        return start < end ? Array(line[start...end]) : []
    }
}
