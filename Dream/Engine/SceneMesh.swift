import Foundation
import simd

/// A mesh as plain arrays, in a scene's maths axes, so it can be built and checked without
/// RealityKit. The renderer hands it to a `MeshDescriptor`. Triangles wind counterclockwise
/// seen from the side their normals face.
struct SceneMesh: Hashable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    /// u is how high a point is, from 0 at the lowest to 1 at the highest, which picks its colour.
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    /// A hoop round the z axis with radius 1, its tube `ratio` thick: an orbit's path, or the rim
    /// of something round.
    static func ring(ratio: Double, segments: Int = 96, sides: Int = 10) -> SceneMesh {
        var mesh = SceneMesh()
        for i in 0...segments {
            let u = 2 * Double.pi * Double(i) / Double(segments)
            for j in 0...sides {
                let v = 2 * Double.pi * Double(j) / Double(sides)
                let normal = Vec3(cos(v) * cos(u), cos(v) * sin(u), sin(v))
                let position = Vec3(cos(u), sin(u), 0) + normal * ratio
                mesh.positions.append(SIMD3<Float>(position))
                mesh.normals.append(SIMD3<Float>(normal))
                mesh.uvs.append(SIMD2<Float>(0.5, 0.5))
            }
        }
        let row = UInt32(sides + 1)
        for i in 0..<UInt32(segments) {
            for j in 0..<UInt32(sides) {
                let a = i * row + j, b = (i + 1) * row + j, c = (i + 1) * row + j + 1, d = i * row + j + 1
                mesh.indices += [a, b, c, a, c, d]
            }
        }
        return mesh
    }

    /// A surface through a grid of heights: `heights[j][i]` is the height at the i-th x and the
    /// j-th y, already in display units. Cells with a height that isn't a number are left out, so
    /// a function that blows up somewhere has a hole there rather than a spike. Both faces are
    /// built, each with its own normals, so it's lit from above and below alike. Nil if no cell
    /// can be drawn.
    static func surface(heights: [[Double]], x: ClosedRange<Double>, y: ClosedRange<Double>) -> SceneMesh? {
        let rows = heights.count
        guard rows >= 2, let columns = heights.first?.count, columns >= 2, heights.allSatisfy({ $0.count == columns }) else { return nil }
        let finite = heights.joined().filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        let span = high - low
        let dx = (x.upperBound - x.lowerBound) / Double(columns - 1)
        let dy = (y.upperBound - y.lowerBound) / Double(rows - 1)
        func height(_ i: Int, _ j: Int) -> Double? {
            guard i >= 0, i < columns, j >= 0, j < rows, heights[j][i].isFinite else { return nil }
            return heights[j][i]
        }

        var front = SceneMesh()
        for j in 0..<rows {
            for i in 0..<columns {
                let z = height(i, j) ?? low
                front.positions.append(SIMD3<Float>(Vec3(x.lowerBound + Double(i) * dx, y.lowerBound + Double(j) * dy, z)))
                // Slopes from the neighbours on either side, or the one there is at an edge.
                func slope(_ before: Double?, _ after: Double?, _ step: Double) -> Double {
                    switch (before, after) {
                    case let (b?, a?): return (a - b) / (2 * step)
                    case let (nil, a?): return (a - z) / step
                    case let (b?, nil): return (z - b) / step
                    case (nil, nil): return 0
                    }
                }
                let sx = slope(height(i - 1, j), height(i + 1, j), dx)
                let sy = slope(height(i, j - 1), height(i, j + 1), dy)
                front.normals.append(SIMD3<Float>(simd_normalize(Vec3(-sx, -sy, 1))))
                front.uvs.append(SIMD2<Float>(Float(span > 0 ? (z - low) / span : 0.5), 0.5))
            }
        }
        for j in 0..<(rows - 1) {
            for i in 0..<(columns - 1) {
                guard height(i, j) != nil, height(i + 1, j) != nil, height(i + 1, j + 1) != nil, height(i, j + 1) != nil else { continue }
                let a = UInt32(j * columns + i), b = a + 1, c = a + 1 + UInt32(columns), d = a + UInt32(columns)
                front.indices += [a, b, c, a, c, d]
            }
        }
        guard !front.indices.isEmpty else { return nil }

        // The underside: the same points facing down, wound the other way.
        var mesh = front
        let offset = UInt32(front.positions.count)
        mesh.positions += front.positions
        mesh.normals += front.normals.map { -$0 }
        mesh.uvs += front.uvs
        for triangle in stride(from: 0, to: front.indices.count, by: 3) {
            mesh.indices += [front.indices[triangle] + offset, front.indices[triangle + 2] + offset, front.indices[triangle + 1] + offset]
        }
        return mesh
    }
}
