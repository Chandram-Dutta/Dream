import AppKit
import Foundation
import Metal
import RealityKit

// Renders 3D scenes to PNG files on this Mac, with the same stage the app uses (SceneStage.swift)
// and the labels where the app's overlay puts them, so a scene can be looked at without a
// device. With requests, it composes them first (on Grok, like the bench) and renders each scene
// they make. Build and run with Tools/scene-preview.sh.

let arguments = Array(CommandLine.arguments.dropFirst())
let output = URL(fileURLWithPath: arguments.first ?? FileManager.default.currentDirectoryPath)
let requests = Array(arguments.dropFirst())
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

@MainActor func render(_ scene: Scene3D, in surface: Surface, values: [String: Double]? = nil, camera: SceneCamera? = nil, dark: Bool, name: String) async {
    let width = 706, scale = 2.0
    let frame = scene.frame(in: surface)
    let height = Int((Double(width) * SceneProjection.aspect(of: frame)).rounded())
    let evaluated = surface.evaluate(values ?? surface.initialValues).values
    let drawing = scene.drawing(in: surface, values: evaluated, zScale: frame.zScale)
    let projection = SceneProjection(frame: frame, camera: camera ?? .standard(for: frame), width: Double(width) / scale, height: Double(height) / scale, extent: drawing.bounds)
    let palette: (SIMD3<Double>, SIMD3<Double>) = dark ? (SIMD3(0.04, 0.52, 1), SIMD3(0.39, 0.82, 1)) : (SIMD3(0, 0.48, 1), SIMD3(0.2, 0.68, 0.9))
    let colors = SceneColors(accent: palette.0, companion: palette.1, isDark: dark)

    let stage = SceneStage()
    stage.update(drawing, projection: projection, colors: colors)
    guard let renderer = try? RealityRenderer(), let device = MTLCreateSystemDefaultDevice() else { print("No renderer"); return }
    renderer.entities.append(contentsOf: stage.entities)
    renderer.activeCamera = stage.camera
    let background = dark ? CGColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1) : CGColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1)
    renderer.cameraSettings.colorBackground = .color(background)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor), let cameraOutput = try? RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture)) else { return }
    // A few frames, so resources have loaded.
    for _ in 0..<3 {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            do {
                try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: cameraOutput, onComplete: { _ in done.resume() })
            } catch {
                print("Render failed: \(error)")
                done.resume()
            }
        }
    }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

    // The labels, where the overlay puts them.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for label in drawing.labels {
        guard let (point, _) = projection.project(label.anchor) else { continue }
        let x = point.x * scale, y = Double(height) - point.y * scale
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.4, alpha: 1))
        context.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
        let text = NSAttributedString(string: label.text, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: dark ? NSColor.white : NSColor.black])
        text.draw(at: CGPoint(x: x + 6, y: y + (label.centered ? -11 : 4)))
    }
    guard let image = context.makeImage() else { return }
    let url = output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("Wrote \(url.path) (\(drawing.solids.count) solids, \(drawing.plots.count) plots, \(drawing.labels.count) labels)")
}

@MainActor func run() async {
    if requests.isEmpty {
        // The scenes the checks use, to look at.
        func input(_ name: String, _ initial: Double, _ min: Double, _ max: Double, role: InputRole = .adjustable) -> Input {
            Input(name: name, label: name, format: .number, initial: initial, min: min, max: max, step: 0.1, options: [], role: role)
        }
        var can = Surface.empty
        can.inputs = [input("r", 1, 0.5, 3), input("h", 2, 1, 6)]
        can.scenes = [Scene3D(name: "can", objects: [
            SceneObject(name: "ground", kind: .plane, position: "at(0, 0, 0)", size: "6, 6", tone: .guide),
            SceneObject(name: "can", kind: .cylinder, position: "on(ground)", size: "r, h", label: "h", tone: .main),
            SceneObject(name: "radius", kind: .arrow, position: "at(0, 0, h + 0.01)", to: "at(r, 0, h + 0.01)", label: "r", tone: .contrast),
        ])]
        await render(can.scenes![0], in: can, dark: false, name: "cylinder")
        await render(can.scenes![0], in: can, dark: true, name: "cylinder")
        await render(can.scenes![0], in: can, values: ["r": 2.5, "h": 5], dark: false, name: "cylinder-grown")

        var planets = Surface.empty
        planets.inputs = [input("t", 40, 0, 365, role: .variable)]
        planets.scenes = [Scene3D(name: "planets", objects: [
            SceneObject(name: "sun", kind: .sphere, position: "at(0, 0, 0)", size: "0.2", label: "Sun", tone: .glow),
            SceneObject(name: "mercuryOrbit", kind: .ring, position: "sun", size: "0.39", tone: .guide),
            SceneObject(name: "venusOrbit", kind: .ring, position: "sun", size: "0.72", tone: .guide),
            SceneObject(name: "earthOrbit", kind: .ring, position: "sun", size: "1", tone: .guide),
            SceneObject(name: "marsOrbit", kind: .ring, position: "sun", size: "1.52", tone: .guide),
            SceneObject(name: "mercury", kind: .sphere, position: "orbit(sun, 0.39, 360 * t / 88)", size: "0.04", label: "Mercury", tone: .plain),
            SceneObject(name: "venus", kind: .sphere, position: "orbit(sun, 0.72, 360 * t / 225)", size: "0.06", label: "Venus", tone: .plain),
            SceneObject(name: "earth", kind: .sphere, position: "orbit(sun, 1, 360 * t / 365.25)", size: "0.065", label: "Earth", tone: .main),
            SceneObject(name: "mars", kind: .sphere, position: "orbit(sun, 1.52, 360 * t / 687)", size: "0.05", label: "Mars", tone: .contrast),
        ], time: "t")]
        await render(planets.scenes![0], in: planets, dark: false, name: "planets")
        await render(planets.scenes![0], in: planets, dark: true, name: "planets")

        var saddle = Surface.empty
        saddle.inputs = [input("a", 1, -2, 2)]
        saddle.scenes = [Scene3D(name: "saddle", plots: [ScenePlot(z: "a * x^2 - y^2", xFrom: "-2", xTo: "2", yFrom: "-2", yTo: "2", label: "$z = x^2 - y^2$")])]
        await render(saddle.scenes![0], in: saddle, dark: false, name: "saddle")
        await render(saddle.scenes![0], in: saddle, dark: true, name: "saddle")
        await render(saddle.scenes![0], in: saddle, values: ["a": -1], dark: false, name: "saddle-bowl")

        var vectors = Surface.empty
        vectors.inputs = [input("ax", 2, -3, 3), input("ay", 0, -3, 3), input("az", 0, -3, 3), input("bx", 0, -3, 3), input("by", 2, -3, 3), input("bz", 0, -3, 3)]
        vectors.outputs = [Output(name: "cx", label: "cx", formula: "ay * bz - az * by", format: .number), Output(name: "cy", label: "cy", formula: "az * bx - ax * bz", format: .number),
                           Output(name: "cz", label: "cz", formula: "ax * by - ay * bx", format: .number)]
        vectors.scenes = [Scene3D(name: "cross", objects: [
            SceneObject(name: "axes", kind: .axes, position: "at(0, 0, 0)", size: "3", tone: .guide),
            SceneObject(name: "a", kind: .arrow, position: "at(0, 0, 0)", to: "at(ax, ay, az)", label: "a", tone: .main),
            SceneObject(name: "b", kind: .arrow, position: "at(0, 0, 0)", to: "at(bx, by, bz)", label: "b", tone: .contrast),
            SceneObject(name: "c", kind: .arrow, position: "at(0, 0, 0)", to: "at(cx / 2, cy / 2, cz / 2)", label: "a × b", tone: .plain),
        ])]
        await render(vectors.scenes![0], in: vectors, dark: false, name: "vectors")

        for name in ["methane", "benzene", "caffeine"] {
            guard let structure = await MoleculeLookup.find(name) else { print("PubChem had no \(name)"); continue }
            var molecule = Surface.empty
            molecule.scenes = [Scene3D(name: name, molecule: Molecule(name: name, structure: structure))]
            await render(molecule.scenes![0], in: molecule, dark: false, name: name)
            await render(molecule.scenes![0], in: molecule, dark: true, name: name)
        }
        return
    }

    for request in requests {
        // A surface saved by an earlier run: render it again without asking the model.
        if request.hasSuffix(".json") {
            let url = URL(fileURLWithPath: request)
            guard let data = try? Data(contentsOf: url), let surface = try? JSONDecoder().decode(Surface.self, from: data) else {
                print("Can't read \(request)")
                continue
            }
            for scene in surface.scenes ?? [] {
                let name = url.deletingPathExtension().lastPathComponent + "-\(scene.name)"
                await render(scene, in: surface, dark: false, name: name)
                await render(scene, in: surface, dark: true, name: name)
            }
            continue
        }
        let composer = Composer()
        await composer.compose(intent: request)
        print(composer.log.joined(separator: "\n"))
        guard let surface = composer.surface else { continue }
        let slug = request.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").prefix(4).joined(separator: "-")
        if let data = try? JSONEncoder().encode(surface) { try? data.write(to: output.appendingPathComponent("\(slug).json")) }
        for scene in surface.scenes ?? [] {
            await render(scene, in: surface, dark: false, name: "\(slug)-\(scene.name)")
            await render(scene, in: surface, dark: true, name: "\(slug)-\(scene.name)")
        }
    }
}

await run()
