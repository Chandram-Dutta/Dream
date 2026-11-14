import SwiftData
import SwiftUI

/// The user's pages as a map of how they relate (PageGraph.swift): each page a point in its own
/// color, joined to what it shares with others (the people, places and projects named in
/// several), and to the page it went on from. Pages about the same things gather together. Drag
/// to move around, pinch to zoom, tap a page to open it.
struct PageMapView: View {
    let pages: [SavedSurface]
    @State private var map = MapLayout.empty
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var scale: CGFloat { min(max(zoom * pinch, 0.4), 2.5) }

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(geometry.size.width, map.size.width * scale), height: max(geometry.size.height, map.size.height * scale))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { canvas, _ in
                        for edge in map.edges {
                            guard let from = map.points[edge.from], let to = map.points[edge.to] else { continue }
                            var path = Path()
                            path.move(to: place(from, in: size))
                            path.addLine(to: place(to, in: size))
                            canvas.stroke(path, with: .color(edge.isThread ? .primary.opacity(0.35) : .secondary.opacity(0.18)),
                                          style: StrokeStyle(lineWidth: edge.isThread ? 1.5 : 1, dash: edge.isThread ? [] : [3, 4]))
                        }
                    }
                    ForEach(map.hubs, id: \.self) { hub in
                        if let point = map.points[hubKey(hub)] {
                            Text(hub)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.background, in: .capsule)
                                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                                .fixedSize()
                                .position(place(point, in: size))
                        }
                    }
                    ForEach(pages) { saved in
                        if let point = map.points[saved.id.uuidString] {
                            NavigationLink(value: saved) {
                                MapPoint(saved: saved, compact: scale < 0.7)
                            }
                            .buttonStyle(.plain)
                            .position(place(point, in: size))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            .defaultScrollAnchor(.center)
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(max(zoom * value.magnification, 0.4), 2.5) }
            )
            .overlay {
                if pages.isEmpty {
                    ContentUnavailableView("No pages yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Pages you make show here, gathered by what they're about."))
                }
            }
        }
        .task(id: pages.map(\.id)) {
            let nodes = pages.map(\.node)
            map = await Task.detached(priority: .userInitiated) { MapLayout(nodes) }.value
        }
    }

    private func hubKey(_ hub: String) -> String { "hub:" + PageGraph.key(hub) }

    /// A point of the layout, from 0 to 1 each way, on the canvas, with a margin.
    private func place(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 90
        return CGPoint(x: margin + point.x * (size.width - 2 * margin), y: margin + point.y * (size.height - 2 * margin))
    }
}

/// One page on the map: its symbol in its own color, and its title.
private struct MapPoint: View {
    let saved: SavedSurface
    let compact: Bool

    var body: some View {
        let surface = saved.surface
        VStack(spacing: 6) {
            Image(systemName: surface.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(surface.palette.onAccent)
                .frame(width: 36, height: 36)
                .background(surface.palette.accent, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if saved.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow)
                            .offset(x: 4, y: -4)
                    }
                }
            if !compact {
                Text(surface.title)
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 110)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(surface.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// Where everything goes on the map: a force layout, in which every point pushes the others
/// away and every line pulls its ends together, so pages sharing subjects gather around them.
/// Worked out once for the pages there are, the same each time for the same pages.
struct MapLayout: Sendable {
    struct Edge: Sendable {
        var from: String
        var to: String
        /// A page and the one it went on from, rather than a page and what it's about.
        var isThread: Bool
    }

    /// Each page (by id) and subject (as "hub:" and its key), from 0 to 1 each way.
    var points: [String: CGPoint] = [:]
    var edges: [Edge] = []
    /// The subjects drawn, as named.
    var hubs: [String] = []
    /// How big the map wants to be, so points have room.
    var size: CGSize = .zero

    static let empty = MapLayout()

    private init() {}

    init(_ nodes: [PageGraph.Node]) {
        let clusters = Array(PageGraph.clusters(nodes).prefix(40))
        hubs = clusters.map(\.subject)
        let ids = nodes.map(\.id.uuidString) + clusters.map { "hub:" + PageGraph.key($0.subject) }
        let present = Set(nodes.map(\.id))
        for cluster in clusters {
            for page in cluster.pages { edges.append(Edge(from: page.uuidString, to: "hub:" + PageGraph.key(cluster.subject), isThread: false)) }
        }
        for node in nodes {
            if let parent = node.parent, present.contains(parent) { edges.append(Edge(from: node.id.uuidString, to: parent.uuidString, isThread: true)) }
        }
        points = Self.arrange(ids, edges: edges)
        let side = max(420, sqrt(Double(ids.count)) * 150)
        size = CGSize(width: side, height: side)
    }

    /// Fruchterman and Reingold's layout: a few hundred rounds of pushing and pulling, cooling as
    /// it goes, starting from a spiral so the same pages always land the same way.
    private static func arrange(_ ids: [String], edges: [Edge]) -> [String: CGPoint] {
        let count = ids.count
        guard count > 0 else { return [:] }
        guard count > 1 else { return [ids[0]: CGPoint(x: 0.5, y: 0.5)] }
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var position: [SIMD2<Double>] = (0..<count).map { i in
            let angle = Double(i) * 2.399963 // the golden angle
            let radius = sqrt(Double(i + 1) / Double(count))
            return SIMD2(cos(angle) * radius, sin(angle) * radius)
        }
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.from], let b = index[edge.to] else { return nil }
            return (a, b)
        }
        let k = sqrt(4.0 / Double(count))
        var heat = 0.1
        for _ in 0..<300 {
            var shift = [SIMD2<Double>](repeating: .zero, count: count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    var delta = position[i] - position[j]
                    var distance = (delta * delta).sum().squareRoot()
                    if distance < 1e-4 { delta = SIMD2(1e-3, 0); distance = 1e-3 }
                    let push = delta / distance * (k * k / distance)
                    shift[i] += push
                    shift[j] -= push
                }
            }
            for (a, b) in links {
                let delta = position[a] - position[b]
                let distance = max((delta * delta).sum().squareRoot(), 1e-4)
                let pull = delta / distance * (distance * distance / k)
                shift[a] -= pull
                shift[b] += pull
            }
            for i in 0..<count {
                // A little gravity, so pages with nothing in common stay near the rest.
                shift[i] -= position[i] * 0.6
                let length = max((shift[i] * shift[i]).sum().squareRoot(), 1e-9)
                position[i] += shift[i] / length * min(length, heat)
            }
            heat *= 0.985
        }
        let xs = position.map(\.x), ys = position.map(\.y)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let width = max(maxX - minX, 1e-6), height = max(maxY - minY, 1e-6)
        var points: [String: CGPoint] = [:]
        for (i, id) in ids.enumerated() {
            points[id] = CGPoint(x: (position[i].x - minX) / width, y: (position[i].y - minY) / height)
        }
        return points
    }
}
