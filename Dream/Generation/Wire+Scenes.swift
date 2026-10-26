import Foundation
import FoundationModels

// What the model writes for 3D scenes (ROADMAP.md, workstream 10): structure only. Objects are
// placed with helpers the engine works out, and a molecule is only named; its atoms come from
// PubChem.

@Generable
enum WireSolidKind { case sphere, box, cylinder, cone, tube, arrow, ring, plane, axes, text }

@Generable
enum WireSolidTone { case main, contrast, plain, guide, glow }

@Generable(description: "One object in a 3D scene")
struct WireSolid {
    @Guide(description: "Short camelCase name, like sun or base. Other objects can be placed against it")
    var name: String
    var kind: WireSolidKind
    @Guide(description: "Where it goes, as a placement: at(x, y, z), at(other, dx, dy, dz), orbit(center, radius, angle), on(other) or on(ground), beside(other, gap), between(a, b), or copies: ring(center, radius, count), row(start, spacing, count), stack(base, count), grid(start, spacing, nx, ny, nz). Numbers are formulas, angles in degrees. tube and arrow: where it starts")
    var position: String
    @Guide(description: "tube and arrow: where it ends, as a placement. Otherwise empty")
    var to: String
    @Guide(description: "Formulas separated by commas. sphere: radius. box: width, depth, height. cylinder and cone: radius, height. tube and arrow: thickness, or empty. ring: radius. plane: width, depth. axes: length. text: empty")
    var size: String
    @Guide(description: "Degrees it turns about its upright axis, as a formula; often empty")
    var turn: String
    @Guide(description: "Degrees it leans over from upright, as a formula; often empty")
    var tilt: String
    @Guide(description: "A few characters shown beside it, like r, $h$ or {volume}; often empty")
    var label: String
    @Guide(description: "main: what the scene is about. contrast: something to tell apart from it. plain: the rest. guide: helpers like the ground, an axis or an orbit's path. glow: something that gives off light, like the sun")
    var tone: WireSolidTone
}

@Generable(description: "A surface z = f(x, y), coloured by height, with axes")
struct WirePlot {
    @Guide(description: "z as a formula of x and y, which can also use the inputs and outputs")
    var z: String
    @Guide(description: "The lowest x, as a number or formula")
    var xFrom: String
    @Guide(description: "The highest x")
    var xTo: String
    @Guide(description: "The lowest y")
    var yFrom: String
    @Guide(description: "The highest y")
    var yTo: String
    @Guide(description: "A few characters, like $z = x^2 - y^2$; often empty")
    var label: String
}

@Generable(description: "A 3D scene, for what depth explains: solids that resize with the numbers, things in orbit, vectors in space, a surface z = f(x, y), or a real molecule")
struct WireScene {
    @Guide(description: "camelCase name, used as a scene block's ref")
    var name: String
    @Guide(description: "A real molecule's common name in English, like methane or caffeine, to show its measured 3D structure from PubChem. Otherwise empty")
    var molecule: String
    @Guide(.count(0...16))
    var objects: [WireSolid]
    @Guide(.count(0...2))
    var plots: [WirePlot]
    @Guide(description: "The input a play button sweeps across its range, like t, so things orbit or turn; empty if nothing moves on its own")
    var time: String
}

// MARK: - Conversion

extension Scene3D {
    init(_ wire: WireScene) {
        let molecule = wire.molecule.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: wire.name, objects: wire.objects.map(SceneObject.init), plots: wire.plots.map(ScenePlot.init),
                  molecule: molecule.isEmpty ? nil : Molecule(name: molecule), time: wire.time)
    }

    /// While the model is still writing: the objects and plots that have arrived. A molecule
    /// is only named, and is looked up once the surface is finished.
    init?(partial wire: WireScene.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(
            name: name,
            objects: (wire.objects ?? []).compactMap { object in
                guard let objectName = object.name, let kind = object.kind, let position = object.position else { return nil }
                return SceneObject(name: objectName, kind: SceneObject.Kind(kind), position: position, to: object.to ?? "", size: object.size ?? "",
                                   turn: object.turn ?? "", tilt: object.tilt ?? "", label: object.label ?? "", tone: object.tone.map { SceneObject.Tone($0) } ?? .plain)
            },
            plots: (wire.plots ?? []).compactMap { plot in
                guard let z = plot.z, let xFrom = plot.xFrom, let xTo = plot.xTo, let yFrom = plot.yFrom, let yTo = plot.yTo else { return nil }
                return ScenePlot(z: z, xFrom: xFrom, xTo: xTo, yFrom: yFrom, yTo: yTo, label: plot.label ?? "")
            },
            molecule: wire.molecule.flatMap { $0.isEmpty ? nil : Molecule(name: $0) },
            time: wire.time ?? "")
    }
}

extension SceneObject {
    init(_ wire: WireSolid) {
        self.init(name: wire.name, kind: Kind(wire.kind), position: wire.position, to: wire.to, size: wire.size,
                  turn: wire.turn, tilt: wire.tilt, label: wire.label, tone: Tone(wire.tone))
    }
}

extension SceneObject.Kind {
    init(_ wire: WireSolidKind) {
        self = SceneObject.Kind(rawValue: String(describing: wire)) ?? .sphere
    }
}

extension SceneObject.Tone {
    init(_ wire: WireSolidTone) {
        self = SceneObject.Tone(rawValue: String(describing: wire)) ?? .plain
    }
}

extension ScenePlot {
    init(_ wire: WirePlot) {
        self.init(z: wire.z, xFrom: wire.xFrom, xTo: wire.xTo, yFrom: wire.yFrom, yTo: wire.yTo, label: wire.label)
    }
}

extension Surface {
    /// Scenes from what the model wrote. Nil rather than empty, so surfaces without them are
    /// stored as they were before.
    mutating func takeScenes(_ scenes: [Scene3D]) {
        self.scenes = scenes.isEmpty ? nil : scenes
    }
}
