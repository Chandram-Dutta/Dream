import Foundation

/// How parts connect: the steps of a process, the stages of a cycle, a hierarchy, or one idea
/// and what surrounds it. Defined once at the top of the surface and shown by a `diagram` block.
/// The model gives only the structure; the engine lays it out for a phone, so there are never
/// coordinates to get wrong.
struct Diagram: Codable, Hashable {
    enum Shape: String, Codable, CaseIterable {
        /// Steps in order, top to bottom, which can branch and rejoin.
        case flow
        /// Stages that come back round to the first.
        case cycle
        /// A hierarchy from one root.
        case tree
        /// One central idea, with what connects to it around it.
        case hub
    }

    struct Node: Codable, Hashable {
        var id: String
        var label: String
        /// A sentence or two, shown when the node is tapped.
        var detail: String
    }

    struct Edge: Codable, Hashable {
        var from: String
        var to: String
        var label: String
    }

    var name: String
    var shape: Shape
    var nodes: [Node]
    var edges: [Edge]

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// The edges to lay out: the model's, or for a flow or cycle with none, each node to the next.
    var connections: [Edge] {
        guard edges.isEmpty, nodes.count > 1 else { return edges }
        switch shape {
        case .flow, .cycle:
            var implied = zip(nodes, nodes.dropFirst()).map { Edge(from: $0.id, to: $1.id, label: "") }
            if shape == .cycle { implied.append(Edge(from: nodes[nodes.count - 1].id, to: nodes[0].id, label: "")) }
            return implied
        case .hub:
            return nodes.dropFirst().map { Edge(from: nodes[0].id, to: $0.id, label: "") }
        case .tree:
            return nodes.dropFirst().map { Edge(from: nodes[0].id, to: $0.id, label: "") }
        }
    }
}

extension Surface {
    func diagram(_ name: String) -> Diagram? { diagrams?.first { $0.name == name } }
}

/// A diagram placed in a view of a given width, in points with y down.
struct DiagramLayout {
    struct Route {
        let from: String
        let to: String
        /// The line to draw, as points close enough together to read as a curve.
        let points: [Vec2]
        let hasArrow: Bool
        let label: String
        /// Where the label's centre goes; nil without a label.
        let labelCenter: Vec2?
    }

    struct Metrics {
        var nodeHeight = 50.0
        /// The height of a node in an outline, which has room for one line.
        var rowHeight = 40.0
        var gap = 10.0
        var rowGap = 34.0
        /// Extra room between rows for an edge's label.
        var labeledRowGap = 50.0
        var minNodeWidth = 92.0
        var maxNodeWidth = 230.0
        /// Room at the sides for edges that loop back or skip a row.
        var lane = 18.0
        var labelHeight = 18.0

        static let standard = Metrics()

        /// Roughly how wide an edge label is, in a caption font.
        func labelWidth(_ text: String) -> Double { Swift.min(Double(text.count) * 6.4 + 14, 150) }
    }

    var width: Double
    var height: Double
    var frames: [String: Rect2]
    var routes: [Route]
    /// A tree too broad for the width is drawn as an indented outline instead.
    var isOutline = false
    /// The node in the middle of a hub.
    var hub: String?

    static func make(_ diagram: Diagram, width: Double, metrics: Metrics = .standard) -> DiagramLayout {
        guard !diagram.nodes.isEmpty, width > 0 else { return DiagramLayout(width: width, height: 0, frames: [:], routes: []) }
        switch diagram.shape {
        case .flow: return flow(diagram, width: width, metrics: metrics)
        case .cycle: return ring(diagram, width: width, metrics: metrics, hub: nil)
        case .hub: return ring(diagram, width: width, metrics: metrics, hub: hub(of: diagram))
        case .tree: return tree(diagram, width: width, metrics: metrics)
        }
    }

    /// Whether any two nodes overlap. Layouts are built never to, so this is for tests.
    var hasOverlaps: Bool {
        let boxes = Array(frames.values)
        return boxes.indices.contains { i in boxes.indices.contains { j in i < j && boxes[i].overlap(boxes[j]) > 0 } }
    }

    // MARK: - Flow

    /// Rows top to bottom, each node a row below everything that leads to it. Steps side by side
    /// are alternatives or happen together. Edges that go back up, or skip a row, run down the sides.
    private static func flow(_ diagram: Diagram, width: Double, metrics: Metrics) -> DiagramLayout {
        let ids = diagram.nodes.map(\.id)
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

        // Rows of at most three, in an order that keeps each node under the ones it follows.
        let perRow = width < 300 ? 2 : 3
        var rows: [[String]] = []
        var column: [String: Double] = [:]
        for level in 0...(layer.values.max() ?? 0) {
            let members = ids.filter { layer[$0] == level }
            let ordered = members.enumerated().sorted { a, b in
                func weight(_ id: String, _ index: Int) -> Double {
                    let parents = forward.filter { $0.to == id }.compactMap { column[$0.from] }
                    return parents.isEmpty ? Double(index) : parents.reduce(0, +) / Double(parents.count)
                }
                return (weight(a.element, a.offset), a.offset) < (weight(b.element, b.offset), b.offset)
            }.map(\.element)
            for start in stride(from: 0, to: ordered.count, by: perRow) {
                let row = Array(ordered[start..<Swift.min(start + perRow, ordered.count)])
                for (index, id) in row.enumerated() { column[id] = Double(index) - Double(row.count - 1) / 2 }
                rows.append(row)
            }
        }
        let rowOf = Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { index, row in row.map { ($0, index) } })

        let routesBack = edges.enumerated().filter { backward.contains($0.offset) }.map(\.element)
        let skipping = forward.filter { (rowOf[$0.to] ?? 0) - (rowOf[$0.from] ?? 0) > 1 || rowOf[$0.to] == rowOf[$0.from] }
        let left = skipping.isEmpty ? 0 : metrics.lane + Double(Swift.min(skipping.count, 3) - 1) * 6
        let right = routesBack.isEmpty ? 0 : metrics.lane + Double(Swift.min(routesBack.count, 3) - 1) * 6
        let usable = width - left - right

        var frames: [String: Rect2] = [:]
        var y = 0.0
        for (index, row) in rows.enumerated() {
            let count = Double(row.count)
            let nodeWidth = row.count == 1
                ? Swift.min(metrics.maxNodeWidth + 10, usable * 0.72)
                : Swift.min(metrics.maxNodeWidth, (usable - metrics.gap * (count - 1)) / count)
            let total = nodeWidth * count + metrics.gap * (count - 1)
            for (position, id) in row.enumerated() {
                let x = left + (usable - total) / 2 + Double(position) * (nodeWidth + metrics.gap)
                frames[id] = Rect2(minX: x, minY: y, maxX: x + nodeWidth, maxY: y + metrics.nodeHeight)
            }
            let next = index + 1 < rows.count ? rows[index + 1] : []
            let labeled = forward.contains { !$0.label.isEmpty && row.contains($0.from) && next.contains($0.to) }
            y += metrics.nodeHeight + (labeled ? metrics.labeledRowGap : metrics.rowGap)
        }
        let height = y - (rows.isEmpty ? 0 : metrics.rowGap)

        var routes: [Route] = []
        var lanes = (left: 0, right: 0)
        for edge in edges {
            guard let source = frames[edge.from], let target = frames[edge.to] else { continue }
            let rise = (rowOf[edge.to] ?? 0) - (rowOf[edge.from] ?? 0)
            if rise == 1 {
                // Straight down, or a gentle S between neighbouring rows.
                let start = Vec2(x: source.center.x, y: source.maxY + 3)
                let end = Vec2(x: target.center.x, y: target.minY - 3)
                let points = curve(start, start + Vec2(x: 0, y: (end.y - start.y) / 2), end - Vec2(x: 0, y: (end.y - start.y) / 2), end)
                routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label,
                                    labelCenter: edge.label.isEmpty ? nil : sideLabel(at: points[points.count / 2], text: edge.label, metrics: metrics, width: width)))
            } else {
                // Down the left for a skip, up the right for a return.
                let isReturn = rise <= 0 && routesBack.contains(edge)
                let lane = isReturn ? width - metrics.lane / 2 - Double(lanes.right % 3) * 6 : metrics.lane / 2 + Double(lanes.left % 3) * 6
                if isReturn { lanes.right += 1 } else { lanes.left += 1 }
                let side = isReturn ? 1.0 : -1.0
                let start = Vec2(x: isReturn ? source.maxX + 3 : source.minX - 3, y: source.center.y)
                let end = Vec2(x: isReturn ? target.maxX + 3 : target.minX - 3, y: target.center.y)
                let points = elbow(start, end, lane: lane, side: side)
                var labelCenter: Vec2?
                if !edge.label.isEmpty {
                    // On the lane, in the gap between rows where it leaves the source, so no node is in the way.
                    let half = metrics.labelWidth(edge.label) / 2
                    let below = frames.values.map(\.minY).filter { $0 > source.maxY }.min() ?? source.maxY + metrics.rowGap
                    let above = frames.values.map(\.maxY).filter { $0 < source.minY }.max() ?? source.minY - metrics.rowGap
                    labelCenter = Vec2(x: Swift.min(Swift.max(lane, half), width - half), y: isReturn ? (above + source.minY) / 2 : (source.maxY + below) / 2)
                }
                routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label, labelCenter: labelCenter))
            }
        }
        return DiagramLayout(width: width, height: height, frames: frames, routes: routes)
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

    // MARK: - Cycle and hub

    /// Nodes round an ellipse, clockwise from the top, in the order the edges go round. A hub
    /// sits in the middle. The ellipse is made just tall enough that no two nodes touch.
    private static func ring(_ diagram: Diagram, width: Double, metrics: Metrics, hub: String?) -> DiagramLayout {
        let edges = diagram.connections
        let others = diagram.nodes.map(\.id).filter { $0 != hub }
        let order = hub == nil ? cycleOrder(others, edges: edges) : others
        let count = Double(order.count)

        var nodeWidth = Swift.min(metrics.maxNodeWidth * 0.62, Swift.max(metrics.minNodeWidth, width * (order.count <= 4 ? 0.4 : 0.36)))
        var frames: [String: Rect2] = [:]
        var radii = (x: 0.0, y: 0.0)
        var center = Vec2.zero
        search: while true {
            let rx = (width - nodeWidth) / 2 - 2
            let hubWidth = Swift.min(nodeWidth * 1.15, width * 0.42)
            for stretch in stride(from: 0.55, through: 2.4, by: 0.05) {
                let ry = rx * stretch
                center = Vec2(x: width / 2, y: ry + metrics.nodeHeight / 2)
                var trial: [String: Rect2] = [:]
                for (index, id) in order.enumerated() {
                    let angle = -Double.pi / 2 + 2 * .pi * Double(index) / count
                    trial[id] = Rect2(center: center + Vec2(x: cos(angle) * rx, y: sin(angle) * ry), width: nodeWidth, height: metrics.nodeHeight)
                }
                if let hub { trial[hub] = Rect2(center: center, width: hubWidth, height: metrics.nodeHeight + 6) }
                let boxes = Array(trial.values).map { $0.insetBy(-metrics.gap / 2) }
                let clear = !boxes.indices.contains { i in boxes.indices.contains { j in i < j && boxes[i].overlap(boxes[j]) > 0 } }
                // A cycle also needs room between neighbours for its arrows.
                let roomy = hub != nil || order.count < 2 || zip(order, order.dropFirst() + order.prefix(1)).allSatisfy { a, b in
                    guard let first = trial[a], let second = trial[b] else { return true }
                    return (first.center - second.center).length > Swift.max(nodeWidth, metrics.nodeHeight) * 0.75 + 24
                }
                if clear && roomy {
                    frames = trial
                    radii = (rx, ry)
                    break search
                }
            }
            guard nodeWidth > metrics.minNodeWidth * 0.8 else {
                // Out of options: the tallest ring, overlaps and all, is still readable.
                radii = (rx, rx * 2.4)
                break search
            }
            nodeWidth *= 0.9
        }
        if frames.isEmpty {
            center = Vec2(x: width / 2, y: radii.y + metrics.nodeHeight / 2)
            for (index, id) in order.enumerated() {
                let angle = -Double.pi / 2 + 2 * .pi * Double(index) / count
                frames[id] = Rect2(center: center + Vec2(x: cos(angle) * radii.x, y: sin(angle) * radii.y), width: nodeWidth, height: metrics.nodeHeight)
            }
            if let hub { frames[hub] = Rect2(center: center, width: nodeWidth, height: metrics.nodeHeight) }
        }

        let angleOf = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, -Double.pi / 2 + 2 * .pi * Double($0) / count) })
        func onRing(_ angle: Double) -> Vec2 { center + Vec2(x: cos(angle) * radii.x, y: sin(angle) * radii.y) }

        // An edge's label goes on its line where the line is clear, or inside the ring from
        // there, wherever it covers no part and no other label.
        let bounds = Rect2(minX: 0, minY: 0, maxX: width, maxY: frames.values.map(\.maxY).max() ?? 0)
        var labels: [Rect2] = []
        func labelCenter(_ text: String, along points: [Vec2]) -> Vec2 {
            var best: (cost: Double, box: Rect2)?
            var rank = 0.0
            for fraction in [0.5, 0.4, 0.6, 0.3, 0.7] {
                let base = points[Int(Double(points.count - 1) * fraction)]
                let inward = hub == nil ? (center - base).normalized : (points[points.count - 1] - points[0]).normalized.perpendicular
                for offset in [0.0, 14, 28, -14, 42, -28, 56, 70, 84] where hub != nil || offset >= 0 {
                    let box = Rect2(center: base + inward * offset, width: metrics.labelWidth(text) + 4, height: metrics.labelHeight + 2)
                    let crowding = frames.values.reduce(0) { $0 + box.overlap($1) } + labels.reduce(0) { $0 + box.overlap($1) }
                    let cost = (crowding + box.spill(outside: bounds)) * 10 + rank
                    rank += 1
                    if best.map({ cost < $0.cost }) ?? true { best = (cost, box) }
                }
            }
            guard let best else { return points[points.count / 2] }
            labels.append(best.box)
            return best.box.center
        }

        var routes: [Route] = []
        for edge in edges {
            guard let source = frames[edge.from], let target = frames[edge.to] else { continue }
            var points: [Vec2]
            if let a = angleOf[edge.from], let b = angleOf[edge.to], let i = order.firstIndex(of: edge.from), let j = order.firstIndex(of: edge.to),
               (j - i + order.count) % order.count == 1 || (i - j + order.count) % order.count == 1 {
                // Neighbours: along the ring, the short way.
                var sweep = b - a
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                points = (0...40).map { onRing(a + sweep * Double($0) / 40) }
            } else {
                points = [source.center, target.center]
            }
            points = trimmed(points, from: source.insetBy(-4), to: target.insetBy(-4))
            guard points.count >= 2 else { continue }
            routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: true, label: edge.label,
                                labelCenter: edge.label.isEmpty ? nil : labelCenter(edge.label, along: points)))
        }
        let height = (frames.values.map(\.maxY).max() ?? 0)
        return DiagramLayout(width: width, height: height, frames: frames, routes: routes, hub: hub)
    }

    /// The hub: the node with the most connections, the first one if it's a tie.
    private static func hub(of diagram: Diagram) -> String? {
        let edges = diagram.connections
        return diagram.nodes.map(\.id).enumerated().max { a, b in
            let degree = { (id: String) in edges.filter { $0.from == id || $0.to == id }.count }
            return (degree(a.element), -a.offset) < (degree(b.element), -b.offset)
        }?.element
    }

    /// The order round the cycle: from the first node, following its edges; nodes off the
    /// cycle come after.
    private static func cycleOrder(_ ids: [String], edges: [Diagram.Edge]) -> [String] {
        guard let first = ids.first else { return [] }
        var order = [first]
        var current = first
        while let next = edges.first(where: { $0.from == current && !order.contains($0.to) && ids.contains($0.to) })?.to {
            order.append(next)
            current = next
        }
        return order + ids.filter { !order.contains($0) }
    }

    // MARK: - Tree

    /// Top down when the leaves fit side by side; otherwise an indented outline, which reads at
    /// any width.
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
        let leafCount = tops.map(leaves).reduce(0, +)
        let slot = width / Double(leafCount)

        var frames: [String: Rect2] = [:]
        var routes: [Route] = []
        if slot - metrics.gap >= metrics.minNodeWidth {
            // Leaves share the width; each parent sits over its children.
            let nodeWidth = Swift.min(metrics.maxNodeWidth, slot - metrics.gap)
            var next = 0.0
            func place(_ id: String, depth: Int) -> Double {
                let x: Double
                if let kids = children[id] {
                    let xs = kids.map { place($0, depth: depth + 1) }
                    x = (xs.first! + xs.last!) / 2
                } else {
                    x = (next + 0.5) * slot
                    next += 1
                }
                frames[id] = Rect2(center: Vec2(x: x, y: Double(depth) * (metrics.nodeHeight + metrics.rowGap + 6) + metrics.nodeHeight / 2), width: nodeWidth, height: metrics.nodeHeight)
                return x
            }
            for top in tops { _ = place(top, depth: 0) }
            for edge in edges {
                guard let source = frames[edge.from], let target = frames[edge.to] else { continue }
                let start = Vec2(x: source.center.x, y: source.maxY + 2)
                let end = Vec2(x: target.center.x, y: target.minY - 2)
                let bend = (end.y - start.y) / 2
                let points = curve(start, start + Vec2(x: 0, y: bend), end - Vec2(x: 0, y: bend), end)
                routes.append(Route(from: edge.from, to: edge.to, points: points, hasArrow: false, label: edge.label,
                                    labelCenter: edge.label.isEmpty ? nil : points[points.count / 2]))
            }
            return DiagramLayout(width: width, height: frames.values.map(\.maxY).max() ?? 0, frames: frames, routes: routes)
        }

        // An outline: each node on its own line, indented under its parent, joined by an elbow.
        let indent = 22.0
        var y = 0.0
        func list(_ id: String, depth: Int) {
            let x = Double(depth) * indent
            frames[id] = Rect2(minX: x, minY: y, maxX: width, maxY: y + metrics.rowHeight)
            y += metrics.rowHeight + metrics.gap
            for child in children[id] ?? [] { list(child, depth: depth + 1) }
        }
        for top in tops { list(top, depth: 0) }
        for (child, parentID) in parent {
            guard let source = frames[parentID], let target = frames[child] else { continue }
            let x = source.minX + indent / 2
            routes.append(Route(from: parentID, to: child, points: [Vec2(x: x, y: source.maxY), Vec2(x: x, y: target.center.y), Vec2(x: target.minX - 2, y: target.center.y)],
                                hasArrow: false, label: "", labelCenter: nil))
        }
        return DiagramLayout(width: width, height: Swift.max(y - metrics.gap, 0), frames: frames, routes: routes, isOutline: true)
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

    /// A label beside the middle of a vertical edge, kept inside the width.
    private static func sideLabel(at point: Vec2, text: String, metrics: Metrics, width: Double) -> Vec2 {
        let half = metrics.labelWidth(text) / 2
        let x = point.x + half + 8
        return Vec2(x: x + half > width ? point.x - half - 8 : x, y: point.y)
    }

    /// The part of a line outside both nodes, so it starts and ends at their edges.
    private static func trimmed(_ points: [Vec2], from source: Rect2, to target: Rect2) -> [Vec2] {
        guard points.count >= 2 else { return points }
        var line = points
        if line.count == 2 {
            // Densify a straight line so it can be cut close to each box.
            line = (0...40).map { line[0] + (line[1] - line[0]) * (Double($0) / 40) }
        }
        let start = line.firstIndex { !source.contains($0) } ?? 0
        let end = line.lastIndex { !target.contains($0) } ?? line.count - 1
        return start < end ? Array(line[start...end]) : []
    }
}
