import CoreGraphics
import RealityKit
import simd
#if canImport(UIKit)
import UIKit
private typealias StageColor = UIColor
#else
import AppKit
private typealias StageColor = NSColor
#endif

/// A scene's colours, resolved for the current appearance: the palette's as plain sRGB numbers,
/// which RealityKit's materials are made from, and whether the page is dark.
struct SceneColors: Hashable {
    var accent: SIMD3<Double>
    var companion: SIMD3<Double>
    var isDark: Bool

    func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> { a + (b - a) * amount }

    /// Everything else: a quiet grey that reads on either background.
    var neutral: SIMD3<Double> { isDark ? SIMD3(repeating: 0.62) : SIMD3(repeating: 0.74) }

    /// An atom's colour: the one chemists know, drawn a little towards the palette so a
    /// molecule belongs on its page. Carbon lightens on a dark page, where grey would vanish.
    func element(_ number: Int) -> SIMD3<Double> {
        var color = Element.of(number).color
        if number == 6 { color = isDark ? SIMD3(repeating: 0.6) : SIMD3(repeating: 0.4) }
        return mix(color, accent, 0.12)
    }

    /// From low to high: the companion colour, the accent, then the accent lightened, with a
    /// faint line at every tenth of the height, so the shape reads like a contour map.
    func heightRamp(width: Int = 256) -> CGImage? {
        let stops = [companion, accent, mix(accent, SIMD3(repeating: 1), 0.5)]
        guard let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * 4) else { return nil }
        for x in 0..<width {
            let u = Double(x) / Double(width - 1)
            let along = u * Double(stops.count - 1)
            let index = min(Int(along), stops.count - 2)
            var color = mix(stops[index], stops[index + 1], along - Double(index))
            let band = (u * 10).truncatingRemainder(dividingBy: 1)
            if band < 0.035 || band > 0.965 { color *= isDark ? 0.7 : 0.8 }
            for (channel, value) in [color.x, color.y, color.z, 1].enumerated() {
                pixels[x * 4 + channel] = UInt8(max(0, min(255, value * 255)).rounded())
            }
        }
        return context.makeImage()
    }
}

/// The RealityKit side of a scene: entities for what a `SceneDrawing` holds, kept by id so that
/// when values change they're moved and resized rather than rebuilt, and placed by a
/// `SceneProjection`, the same one the labels drawn over it use. Plain RealityKit, so it can
/// also render offscreen on a Mac to check what a scene looks like.
@MainActor
final class SceneStage {
    // Made on first use, since SwiftUI may make a stage and throw it away many times before
    // keeping one.
    /// The scene, centred, scaled and turned by the projection.
    private(set) lazy var root = Entity()
    private(set) lazy var camera = PerspectiveCamera()
    /// Lights stay with the camera, so the side facing the reader is always lit.
    private(set) lazy var lights = Entity()
    private var models: [String: ModelEntity] = [:]
    private var shapes: [String: SceneDrawing.Solid.Shape] = [:]
    private var paints: [String: SceneDrawing.Solid.Paint] = [:]
    private var plots: [Int: ModelEntity] = [:]
    /// What each plot's mesh was made from, so turning the scene doesn't rebuild it.
    private var plotMeshes: [Int: SceneMesh] = [:]
    private var materials: [SceneDrawing.Solid.Paint: any RealityKit.Material] = [:]
    private var plotMaterial: (any RealityKit.Material)?
    private var colors: SceneColors?
    private var isInstalled = false

    /// Everything the view's content holds.
    var entities: [Entity] {
        install()
        return [root, camera, lights]
    }

    private func install() {
        guard !isInstalled else { return }
        isInstalled = true
        camera.camera.fieldOfViewInDegrees = Float(SceneCamera.fieldOfView * 180 / .pi)
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.02
        camera.camera.far = 100
        // A key light from above and to the left, a softer fill from the right, and a little from
        // behind to pick out edges. Even light all round comes from the environment.
        for (from, intensity) in [(SIMD3<Float>(-1.4, 2.2, 2.4), Float(2800)), (SIMD3<Float>(2.4, 0.4, 1.6), 900), (SIMD3<Float>(0.6, 1.2, -2.6), 700)] {
            let light = DirectionalLight()
            light.light.intensity = intensity
            light.look(at: .zero, from: from, relativeTo: nil)
            lights.addChild(light)
        }
        if let environment = Self.environment {
            lights.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
        }
    }

    func update(_ drawing: SceneDrawing, projection: SceneProjection, colors: SceneColors) {
        install()
        if colors != self.colors {
            self.colors = colors
            materials = [:]
            plotMaterial = nil
            for (id, model) in models { if let paint = paints[id] { model.model?.materials = [material(for: paint)] } }
            for model in plots.values { model.model?.materials = [plotSurface()] }
        }

        // The scene round the frame's centre, scaled to a radius of 1, then turned.
        let turn = projection.rotation.float
        root.transform = Transform(scale: SIMD3(repeating: Float(projection.scale)), rotation: turn,
                                   translation: turn.act((SceneProjection.toRender(-projection.center) * projection.scale).float))
        camera.position = SIMD3(0, 0, Float(projection.distance))

        var seen: Set<String> = []
        for solid in drawing.solids {
            seen.insert(solid.id)
            let model: ModelEntity
            if let existing = models[solid.id] {
                model = existing
                if shapes[solid.id] != solid.shape { model.model?.mesh = Self.mesh(for: solid.shape) }
                if paints[solid.id] != solid.paint { model.model?.materials = [material(for: solid.paint)] }
            } else {
                model = ModelEntity(mesh: Self.mesh(for: solid.shape), materials: [material(for: solid.paint)])
                model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lights))
                root.addChild(model)
                models[solid.id] = model
            }
            shapes[solid.id] = solid.shape
            paints[solid.id] = solid.paint
            model.transform = Self.transform(of: solid)
        }
        for (id, model) in models where !seen.contains(id) {
            model.removeFromParent()
            models[id] = nil
            shapes[id] = nil
            paints[id] = nil
        }

        var plotted: Set<Int> = []
        for plot in drawing.plots {
            plotted.insert(plot.id)
            guard plotMeshes[plot.id] != plot.mesh, let mesh = Self.mesh(from: plot.mesh) else { continue }
            plotMeshes[plot.id] = plot.mesh
            if let existing = plots[plot.id] {
                existing.model?.mesh = mesh
            } else {
                let model = ModelEntity(mesh: mesh, materials: [plotSurface()])
                model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lights))
                root.addChild(model)
                plots[plot.id] = model
            }
        }
        for (id, model) in plots where !plotted.contains(id) {
            model.removeFromParent()
            plots[id] = nil
            plotMeshes[id] = nil
        }
    }

    // MARK: - Pieces

    /// A solid's place, turn and size, in the renderer's axes. The unit shapes stand along the
    /// renderer's y where the scene's stand along z, so the sizes swap to match.
    static func transform(of solid: SceneDrawing.Solid) -> Transform {
        Transform(scale: SIMD3<Float>(Float(solid.scale.x), Float(solid.scale.z), Float(solid.scale.y)),
                  rotation: SceneProjection.toRender(solid.rotation).float,
                  translation: SceneProjection.toRender(solid.center).float)
    }

    private static var unitMeshes: [SceneDrawing.Solid.Shape: MeshResource] = [:]

    static func mesh(for shape: SceneDrawing.Solid.Shape) -> MeshResource {
        if let known = unitMeshes[shape] { return known }
        let mesh: MeshResource
        switch shape {
        case .sphere: mesh = .generateSphere(radius: 1)
        case .box: mesh = .generateBox(size: 1)
        case .cylinder: mesh = .generateCylinder(height: 1, radius: 1)
        case .cone: mesh = .generateCone(height: 1, radius: 1)
        case .plane: mesh = .generatePlane(width: 1, depth: 1)
        case .ring(let ratio): mesh = Self.mesh(from: SceneMesh.ring(ratio: ratio)) ?? .generateSphere(radius: 0.001)
        }
        if unitMeshes.count > 64 { unitMeshes = unitMeshes.filter { if case .ring = $0.key { false } else { true } } }
        unitMeshes[shape] = mesh
        return mesh
    }

    /// An engine mesh, in the renderer's axes.
    static func mesh(from data: SceneMesh) -> MeshResource? {
        guard !data.indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "scene")
        descriptor.positions = MeshBuffers.Positions(data.positions.map { SIMD3($0.x, $0.z, -$0.y) })
        descriptor.normals = MeshBuffers.Normals(data.normals.map { SIMD3($0.x, $0.z, -$0.y) })
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(data.uvs)
        descriptor.primitives = .triangles(data.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: - Materials

    private func material(for paint: SceneDrawing.Solid.Paint) -> any RealityKit.Material {
        if let known = materials[paint] { return known }
        let colors = self.colors ?? SceneColors(accent: SIMD3(0, 0.48, 1), companion: SIMD3(0.2, 0.7, 0.9), isDark: false)
        let made: any RealityKit.Material
        switch paint {
        case .tone(.main): made = Self.solid(colors.accent, roughness: 0.42)
        case .tone(.contrast): made = Self.solid(colors.companion, roughness: 0.42)
        case .tone(.plain): made = Self.solid(colors.neutral, roughness: 0.55)
        case .tone(.guide): made = Self.solid(colors.mix(colors.neutral, colors.accent, 0.35), roughness: 0.9, opacity: colors.isDark ? 0.24 : 0.36)
        case .tone(.glow):
            // A light source shines: warm, and bright from every side.
            let warm = colors.mix(SIMD3(1, 0.8, 0.36), colors.accent, 0.06)
            var glow = Self.solid(warm, roughness: 0.8)
            glow.emissiveColor = .init(color: Self.color(warm))
            glow.emissiveIntensity = 1.4
            made = glow
        case .element(let number): made = Self.solid(colors.element(number), roughness: 0.32)
        case .bond: made = Self.solid(colors.isDark ? SIMD3(repeating: 0.55) : SIMD3(repeating: 0.7), roughness: 0.5)
        }
        materials[paint] = made
        return made
    }

    private func plotSurface() -> any RealityKit.Material {
        if let plotMaterial { return plotMaterial }
        let colors = self.colors ?? SceneColors(accent: SIMD3(0, 0.48, 1), companion: SIMD3(0.2, 0.7, 0.9), isDark: false)
        var material = PhysicallyBasedMaterial()
        material.roughness = .init(floatLiteral: 0.6)
        material.metallic = .init(floatLiteral: 0)
        if let ramp = colors.heightRamp(), let texture = try? TextureResource(image: ramp, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: .white, texture: .init(texture))
        } else {
            material.baseColor = .init(tint: Self.color(colors.accent))
        }
        plotMaterial = material
        return material
    }

    private static func solid(_ rgb: SIMD3<Double>, roughness: Float, opacity: Float = 1) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color(rgb))
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0)
        if opacity < 1 { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
        return material
    }

    private static func color(_ rgb: SIMD3<Double>) -> StageColor {
        StageColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    /// Soft light from all round, brighter from above, like a studio: so the sides away from
    /// the lights are shaded rather than black. Made once; it takes a moment.
    private static let environment: EnvironmentResource? = {
        let (width, height) = (64, 32)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }
        for y in 0..<height {
            // From the top of the sky to straight down.
            let up = 1 - Double(y) / Double(height - 1)
            let level = 0.22 + 0.6 * pow(up, 1.4)
            for x in 0..<width {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(level * 255) }
                pixels[(y * width + x) * 4 + 3] = 255
            }
        }
        guard let image = context.makeImage() else { return nil }
        return try? EnvironmentResource(equirectangular: image, options: .init())
    }()
}

private extension SIMD3 where Scalar == Double {
    var float: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

private extension simd_quatd {
    var float: simd_quatf { simd_quatf(vector: SIMD4<Float>(vector)) }
}
