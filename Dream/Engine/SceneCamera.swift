import Foundation
import simd

// Framing a scene and looking at it: what the view fits, where the camera stands, and where a
// point lands on screen. Plain geometry, so it can be tested on a Mac. The renderer and the
// labels drawn over it both use `SceneProjection`, so a label always sits by what it names.

/// A scene as it starts, which sets the shape of its panel and the angle it's first seen from.
/// The view then fits the scene as it is (`SceneProjection`'s extent), like a figure's.
struct SceneFrame: Hashable {
    var bounds: Box3
    /// How much heights are stretched for display. 1 unless a plot is much flatter or much taller
    /// than it is wide.
    var zScale: Double

    var center: Vec3 { bounds.center }
    var radius: Double { Swift.max(bounds.radius, 1e-9) }
    /// Much wider than tall, like orbits round the sun, which read better from higher up.
    var isFlat: Bool { bounds.half.z < 0.3 * Swift.max(bounds.half.x, bounds.half.y) }
}

extension Scene3D {
    func frame(in surface: Surface) -> SceneFrame {
        SceneMemo.frame(of: self, in: surface) { makeFrame(in: surface) }
    }

    private func makeFrame(in surface: Surface) -> SceneFrame {
        let zScale = plotScale(in: surface)
        let start = surface.evaluate(surface.initialValues).values
        let bounds = drawing(in: surface, values: start, zScale: zScale, plotGrid: 16).bounds ?? Box3(center: .zero, half: Vec3(repeating: 1))
        return SceneFrame(bounds: bounds, zScale: zScale)
    }

    /// Everything drawn at these values, worked out quickly: what the view fits.
    func extent(in surface: Surface, given: [String: Double], zScale: Double) -> Box3? {
        drawing(in: surface, values: surface.evaluate(given).values, zScale: zScale, plotGrid: 12).bounds
    }

    /// Heights are drawn true unless a plot at its starting values is far flatter or taller than
    /// it is wide; then they're stretched so its height is about three quarters of its width, the
    /// way a plot of z = f(x, y) is usually drawn.
    func plotScale(in surface: Surface) -> Double {
        let start = surface.evaluate(surface.initialValues).values
        var ratio: Double?
        for plot in plots {
            guard let sampled = Self.sample(plot, in: surface, values: start, grid: 24) else { continue }
            let width = Swift.max(sampled.x.upperBound - sampled.x.lowerBound, sampled.y.upperBound - sampled.y.lowerBound)
            let height = sampled.high - sampled.low
            guard width > 0, height > 0 else { continue }
            ratio = Swift.max(ratio ?? 0, height / width)
        }
        guard let ratio, ratio < 0.35 || ratio > 1.2 else { return 1 }
        return Swift.min(Swift.max(0.75 / ratio, 1e-4), 1e4)
    }
}

/// How the reader is looking at a scene: turned round its upright axis, tilted to look down on
/// it, and zoomed. Zero turn looks along y, with x to the right.
struct SceneCamera: Hashable {
    /// Radians round the upright axis.
    var yaw: Double
    /// Radians; positive looks down on the scene.
    var pitch: Double
    /// 1 fits the frame; more is closer.
    var zoom: Double = 1

    /// Vertically, in radians: a little narrower than a phone camera, so shapes aren't distorted.
    static let fieldOfView = 34.0 * Double.pi / 180
    static let pitchRange = (-80.0 * Double.pi / 180)...(85.0 * Double.pi / 180)
    static let zoomRange = 0.5...4.0

    /// A three-quarter view from a little above, higher for flat scenes so orbits read as circles.
    static func standard(for frame: SceneFrame) -> SceneCamera {
        SceneCamera(yaw: -28 * .pi / 180, pitch: (frame.isFlat ? 38 : 20) * .pi / 180)
    }

    /// After a drag of `dx` and `dy` points from where it was: sideways turns, up and down tilts.
    func turned(dx: Double, dy: Double) -> SceneCamera {
        var camera = self
        let perPoint = 0.6 * Double.pi / 180
        camera.yaw += dx * perPoint
        camera.pitch = Swift.min(Swift.max(pitch + dy * perPoint, Self.pitchRange.lowerBound), Self.pitchRange.upperBound)
        return camera
    }

    /// The turn applied to the scene, in the renderer's axes: round the upright axis, then tilted.
    var rotation: simd_quatd {
        simd_quatd(angle: pitch, axis: Vec3(1, 0, 0)) * simd_quatd(angle: yaw, axis: Vec3(0, 1, 0))
    }
}

/// Where a scene lands in a view of a given size: the transform the renderer gives the scene,
/// the camera's distance, and where any point of the scene appears on screen.
///
/// The renderer's axes are RealityKit's: x right, y up, z towards the viewer. The camera stands
/// on the z axis looking back at the origin, and the scene is moved so its frame's centre is
/// there, scaled so the frame's radius is 1, and turned as the reader turns it.
struct SceneProjection {
    let width: Double
    let height: Double
    let center: Vec3
    /// From scene units to the renderer's.
    let scale: Double
    let rotation: simd_quatd
    let distance: Double

    /// How much of the view the frame fills, at most, across its narrower side.
    static let fill = 0.86

    /// `extent` is what the view shows: the scene as it is, or as it was while it's changing.
    /// Without one, the scene as it starts.
    init(frame: SceneFrame, camera: SceneCamera, width: Double, height: Double, extent: Box3? = nil) {
        let box = extent ?? frame.bounds
        self.width = Swift.max(width, 1)
        self.height = Swift.max(height, 1)
        center = box.center
        scale = 1 / Swift.max(box.radius, 1e-9)
        rotation = camera.rotation
        // The distance that fits the box at the standard view, so turning the scene doesn't
        // make it breathe in and out. Never much closer than fits its sphere, so turning it
        // doesn't push much of it out of view.
        let standard = SceneCamera.standard(for: frame).rotation
        let tanY = tan(SceneCamera.fieldOfView / 2) * Self.fill
        let tanX = tanY * self.width / self.height
        var fit = 0.0
        for corner in box.corners {
            let point = standard.act(Self.toRender(corner - center) * scale)
            fit = Swift.max(fit, point.z + abs(point.x) / tanX, point.z + abs(point.y) / tanY)
        }
        let sphere = 1 / sin(atan(Swift.min(tanX, tanY)))
        let fitted = Swift.max(fit, sphere * 0.75)
        distance = Swift.max(fitted / Swift.min(Swift.max(camera.zoom, SceneCamera.zoomRange.lowerBound), SceneCamera.zoomRange.upperBound), 0.25)
    }

    /// Scene axes to the renderer's: x stays, y (away) becomes -z, z (up) becomes y.
    static func toRender(_ point: Vec3) -> Vec3 { Vec3(point.x, point.z, -point.y) }

    /// The same change of axes, as a turn: a quarter turn back round x.
    static let basis = simd_quatd(angle: -.pi / 2, axis: Vec3(1, 0, 0))

    /// A turn in scene axes, as the renderer sees it.
    static func toRender(_ rotation: simd_quatd) -> simd_quatd { basis * rotation * basis.inverse }

    /// Where a point of the scene is once the scene is placed, in the renderer's axes.
    func placed(_ point: Vec3) -> Vec3 { rotation.act(Self.toRender(point - center) * scale) }

    /// Where a point of the scene appears in the view, in points from the top left, and how
    /// far it is in front of the camera. Nil if it's behind the camera.
    func project(_ point: Vec3) -> (point: Vec2, depth: Double)? {
        let at = placed(point)
        let depth = distance - at.z
        guard depth > 1e-6 else { return nil }
        let focal = height / 2 / tan(SceneCamera.fieldOfView / 2)
        return (Vec2(x: width / 2 + at.x / depth * focal, y: height / 2 - at.y / depth * focal), depth)
    }

    /// How long a length of the scene looks at a point, in points.
    func onScreen(_ length: Double, at point: Vec3) -> Double? {
        guard let depth = project(point)?.depth else { return nil }
        return length * scale / depth * (height / 2 / tan(SceneCamera.fieldOfView / 2))
    }

    /// Height over width for a view that shows a frame well at its standard view: its own shape
    /// as seen from there, kept between a wide strip and a little taller than square.
    static func aspect(of frame: SceneFrame) -> Double {
        let standard = SceneCamera.standard(for: frame).rotation
        let scale = 1 / frame.radius
        let seen = frame.bounds.corners.map { standard.act(toRender($0 - frame.center) * scale) }
        let wide = (seen.map(\.x).max() ?? 1) - (seen.map(\.x).min() ?? -1)
        let tall = (seen.map(\.y).max() ?? 1) - (seen.map(\.y).min() ?? -1)
        guard wide > 1e-9 else { return 1 }
        return Swift.min(Swift.max(tall / wide * 1.08, 0.62), 1.1)
    }
}

/// Frames sample the plots and are asked for on every frame, so they're kept for each scene and
/// calculation.
enum SceneMemo {
    private struct Key: Hashable {
        let scene: Scene3D
        let inputs: [Input]
        let outputs: [Output]
    }

    nonisolated(unsafe) private static var frames: [Key: SceneFrame] = [:]
    private static let lock = NSLock()

    static func frame(of scene: Scene3D, in surface: Surface, _ make: () -> SceneFrame) -> SceneFrame {
        let key = Key(scene: scene, inputs: surface.inputs, outputs: surface.outputs)
        if let hit = lock.withLock({ frames[key] }) { return hit }
        let frame = make()
        lock.withLock {
            if frames.count > 32 { frames.removeAll() }
            frames[key] = frame
        }
        return frame
    }
}
