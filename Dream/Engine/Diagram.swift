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

