import Foundation
import FoundationModels

// What the model writes for figures and diagrams (ROADMAP.md, workstream 5): structure only.
// Coordinates are formulas over the calculation, and diagrams have no coordinates at all.

// MARK: - Figure

@Generable
enum WireShapeKind { case segment, arrow, polygon, square, circle, arc, angle, rightAngle, text, path }

@Generable
enum WireTone { case main, contrast, plain, guide }

@Generable(description: "A named position in a figure")
struct WirePoint {
    @Guide(description: "Short name, like A, O or tip. Other formulas in the figure can use its coordinates as A.x and A.y")
    var name: String
    @Guide(description: "x as a formula of the inputs and outputs, or a number")
    var x: String
    @Guide(description: "y as a formula, pointing up, in the same units as x")
    var y: String
    @Guide(description: "Shown beside the point, like A; empty for a corner that needs no name")
    var label: String
}

@Generable(description: "One shape in a figure, through named points")
struct WireShape {
    var kind: WireShapeKind
    @Guide(description: "Point names, separated by commas. segment: 2 or more, joined in order. arrow: from, to. polygon: the corners in order. square: the two ends of a side, then optionally a point to build it away from. circle, arc: the centre. angle, rightAngle: a point on one arm, the corner, a point on the other arm. text: where it goes. path: empty")
    var points: String
    @Guide(description: "circle and arc: the radius, as a formula. Otherwise empty")
    var radius: String
    @Guide(description: "arc: the start angle in degrees, counterclockwise from the right. path: the first value of over. Otherwise empty")
    var from: String
    @Guide(description: "arc: the end angle in degrees. path: the last value of over. Otherwise empty")
    var to: String
    @Guide(description: "path only: the name its formulas run along, like t; an input, or a new name for the path alone")
    var over: String
    @Guide(description: "path only: x as a formula of over")
    var x: String
    @Guide(description: "path only: y as a formula of over")
    var y: String
    @Guide(description: "A few characters shown beside it, like c, $c^2$ or {hypotenuse}; often empty")
    var label: String
    @Guide(description: "main: what the figure is about. contrast: something to tell apart from it. plain: the rest. guide: helpers like the ground or an axis")
    var tone: WireTone
}

@Generable(description: "A drawing for geometry or physics whose shapes move as the numbers change")
struct WireFigure {
    @Guide(description: "camelCase name, used as a figure block's ref")
    var name: String
    @Guide(.count(0...16))
    var points: [WirePoint]
    @Guide(.count(1...16))
    var shapes: [WireShape]
}

// MARK: - Diagram

@Generable
enum WireDiagramShape { case flow, cycle, tree, hub }

@Generable
struct WireNode {
    @Guide(description: "Short camelCase id, like evaporation")
    var id: String
    @Guide(description: "1 to 3 words")
    var label: String
    @Guide(description: "One or two sentences, shown when the user taps it")
    var detail: String
}

@Generable
struct WireEdge {
    @Guide(description: "The id it starts from")
    var from: String
    @Guide(description: "The id it goes to")
    var to: String
    @Guide(description: "A few words on the arrow, or empty")
    var label: String
}

@Generable(description: "Steps, stages or parts and how they connect. The app lays it out")
struct WireDiagram {
    @Guide(description: "camelCase name, used as a diagram block's ref")
    var name: String
    @Guide(description: "flow: steps in order, which can branch. cycle: stages that repeat, back to the first. tree: a hierarchy from one root. hub: one central idea and what connects to it")
    var shape: WireDiagramShape
    @Guide(.count(2...10))
    var nodes: [WireNode]
    @Guide(.count(0...16))
    var edges: [WireEdge]
}

// MARK: - Conversion

extension Figure {
    init(_ wire: WireFigure) {
        self.init(name: wire.name, points: wire.points.map(FigurePoint.init), shapes: wire.shapes.map(FigureShape.init))
    }

    /// While the model is still writing: the points and shapes that have arrived.
    init?(partial wire: WireFigure.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(
            name: name,
            points: (wire.points ?? []).compactMap { point in
                guard let name = point.name, let x = point.x, let y = point.y else { return nil }
                return FigurePoint(name: name, x: x, y: y, label: point.label ?? "")
            },
            shapes: (wire.shapes ?? []).compactMap { shape in
                guard let kind = shape.kind else { return nil }
                return FigureShape(kind: FigureShape.Kind(kind), points: FigureShape.names(shape.points ?? ""), radius: shape.radius ?? "", from: shape.from ?? "", to: shape.to ?? "",
                                   over: shape.over ?? "", x: shape.x ?? "", y: shape.y ?? "", label: shape.label ?? "", tone: shape.tone.map { FigureShape.Tone($0) } ?? .plain)
            })
    }
}

extension FigurePoint {
    init(_ wire: WirePoint) {
        self.init(name: wire.name, x: wire.x, y: wire.y, label: wire.label)
    }
}

extension FigureShape {
    init(_ wire: WireShape) {
        self.init(kind: Kind(wire.kind), points: Self.names(wire.points), radius: wire.radius, from: wire.from, to: wire.to,
                  over: wire.over, x: wire.x, y: wire.y, label: wire.label, tone: Tone(wire.tone))
    }

    /// "A, B, C" → [A, B, C].
    static func names(_ list: String) -> [String] {
        list.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }
}

extension FigureShape.Kind {
    init(_ wire: WireShapeKind) {
        self = FigureShape.Kind(rawValue: String(describing: wire)) ?? .segment
    }
}

extension FigureShape.Tone {
    init(_ wire: WireTone) {
        self = FigureShape.Tone(rawValue: String(describing: wire)) ?? .plain
    }
}

extension Diagram {
    init(_ wire: WireDiagram) {
        self.init(name: wire.name, shape: Shape(rawValue: String(describing: wire.shape)) ?? .flow,
                  nodes: wire.nodes.map { Node(id: $0.id, label: $0.label, detail: $0.detail) },
                  edges: wire.edges.map { Edge(from: $0.from, to: $0.to, label: $0.label) })
    }

    init?(partial wire: WireDiagram.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(name: name, shape: wire.shape.flatMap { Shape(rawValue: String(describing: $0)) } ?? .flow,
                  nodes: (wire.nodes ?? []).compactMap { node in
                      guard let id = node.id, let label = node.label else { return nil }
                      return Node(id: id, label: label, detail: node.detail ?? "")
                  },
                  edges: (wire.edges ?? []).compactMap { edge in
                      guard let from = edge.from, let to = edge.to else { return nil }
                      return Edge(from: from, to: to, label: edge.label ?? "")
                  })
    }
}

extension Surface {
    /// Figures and diagrams from what the model wrote. Nil rather than empty, so surfaces
    /// without them are stored as they were before.
    mutating func takeVisuals(figures: [Figure], diagrams: [Diagram]) {
        self.figures = figures.isEmpty ? nil : figures
        self.diagrams = diagrams.isEmpty ? nil : diagrams
    }
}
