import Foundation

// 2D figures and diagrams (ROADMAP.md, workstream 5).

extension Prompts {
    /// How to draw figures whose shapes move with the calculation, and diagrams of flows and cycles.
    static var figureRules: String {
        """
        Figures and diagrams show what words can't. Use one when the shape or the connections are the point; never for decoration. Define it in figures or diagrams, then place it with a figure or diagram block whose ref is its name.
        - figure: a drawing for geometry or physics, to scale: a triangle and the squares on its sides, a circle with its radius and chord, forces on a slope, a thrown ball's flight. Coordinates are formulas over the calculation, so the drawing moves as the numbers change. Put it in the same section as the controls that shape it, figure first. A chart plots one quantity against another; a figure draws the thing itself, where it really is: for motion through space, like a throw, draw its path in a figure.
          - points: x and y are formulas of the inputs and outputs, y pointing up, both in the same units. A formula can use another point's coordinates as A.x and A.y. A point whose position comes straight from adjustable inputs, like (a, 0) or (v * cos(angle * pi / 180), v * sin(angle * pi / 180)), becomes a handle the user drags to set them, so put the corner or tip they'd want to move there. Corners for shapes need no label.
          - shapes go through points by name: segment, arrow (a force or velocity), polygon (a filled area), square (a square on a side, which the app builds outward, so there are no corners to work out), circle and arc (a centre and a radius formula; arc angles in degrees, counterclockwise from the right), angle and rightAngle (marks at the middle of three points), text (a label at a point), path (a curve: x and y as formulas of over, from one value to another, like a ball's position over time t from 0 to its flight time).
          - Label sides, angles and areas briefly, with symbols or live values: a, $c^2$, {angle}°. Use main for the subject, contrast for what it's compared with, plain for the rest, guide for the ground or an axis.
          - The view is sized for the starting values, with room to grow, so start at typical values and keep ranges to what's worth exploring.
        - diagram: how parts connect, laid out by the app; never give positions. flow for a process in order (how a bill becomes law), cycle for stages that repeat (the water cycle), tree for a hierarchy (a classification), hub for one idea and what surrounds it. Nodes have an id, a 1 to 3 word label and one or two sentences of detail, shown when tapped. Edges join ids, in order, with an optional few-word label. 3 to 8 nodes. Let the diagram carry the sequence instead of repeating it in steps.
        Never write SVG, or coordinates in text.
        """
    }
}

extension Surface {
    /// Figures and diagrams in the outline's shorthand, so a change keeps them and the log shows them.
    var visualOutline: [String] {
        var lines: [String] = []
        for figure in figures ?? [] {
            lines.append("figure \(figure.name):")
            for point in figure.points {
                lines.append("  point \(point.name) = (\(point.x), \(point.y))\(point.label.isEmpty ? "" : " \"\(point.label)\"")")
            }
            for shape in figure.shapes {
                var line = "  \(shape.kind.rawValue) \(shape.points.joined(separator: ", "))"
                switch shape.kind {
                case .circle: line += " radius \(shape.radius)"
                case .arc: line += " radius \(shape.radius) from \(shape.from)° to \(shape.to)°"
                case .path: line += "(\(shape.x), \(shape.y)) over \(shape.over)\(shape.from.isEmpty ? "" : " from \(shape.from) to \(shape.to)")"
                default: break
                }
                if !shape.label.isEmpty { line += " \"\(shape.label)\"" }
                lines.append(line + " \(shape.tone.rawValue)")
            }
        }
        for diagram in diagrams ?? [] {
            lines.append("diagram \(diagram.name), \(diagram.shape.rawValue):")
            for node in diagram.nodes {
                lines.append("  \(node.id) \"\(node.label)\"\(node.detail.isEmpty ? "" : ": \(node.detail)")")
            }
            for edge in diagram.edges {
                lines.append("  \(edge.from) → \(edge.to)\(edge.label.isEmpty ? "" : " \"\(edge.label)\"")")
            }
        }
        return lines
    }
}
