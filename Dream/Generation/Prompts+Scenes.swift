import Foundation

// 3D scenes (ROADMAP.md, workstream 10).

extension Prompts {
    /// When depth teaches better than a flat drawing, and how to build a scene from placements
    /// rather than worked-out coordinates.
    static var sceneRules: String {
        """
        3D scenes show what depth explains: how things sit and move in space (orbits, a tilted axis through the year, spins), a molecule's shape, a solid whose volume or surface is found (a cylinder, cone, sphere, a box of unit cubes), vectors in space and their cross product, a surface z = f(x, y), a crystal lattice. Anything flat is a figure instead: triangles and circles, forces on a slope, levers and pulleys, a ball thrown in a plane. One quantity against another is a chart, and stages in order are a diagram. Never use 3D for decoration. Define it in scenes, then place it with a scene block whose ref is its name, in the section with the controls that change it, scene first.
        - Axes: x to the right, y away from the viewer, z up, all in one unit.
        - objects: sphere, box, cylinder and cone (upright), tube and arrow (from position to to: a rod, a force or a vector), ring (a level circle, like an orbit's path), plane (the ground, or a slice), axes, and text (a label alone). Sizes are formulas of the inputs and outputs, so the scene resizes as they change: a cylinder of radius r and height h has size r, h.
        - position is a placement, never coordinates you work out, and it's where the object's centre goes: at(x, y, z), at(other, dx, dy, dz), orbit(center, radius, angle) on a level circle with the angle in degrees, on(ground) or on(other) to rest on top, beside(other, gap), between(a, b). Copies: ring(center, radius, count), row(start, spacing, count), stack(base, count), grid(start, spacing, nx, ny, nz); a sixth number for grid, 0 or 1, keeps every other place, so two objects alternate like the ions in a salt crystal. Places nest, like orbit(at(0, 0, 2), 1, 45). Counts can be inputs, so the copies change with a stepper.
        - turn and tilt are degrees, as formulas: 360 * t / 24 for a day's spin, 23.4 for Earth's axis.
        - To make it move, name an input as its time, like t in days, and drive angles with it, like orbit(sun, 1, 360 * t / 365.25). A play button sweeps time across its range; make it a variable to only play, or adjustable to also scrub it. Real periods and distances are numbers in formulas or givens, never sliders.
        - Tones: main for the subject, contrast for what's compared with it, plain for the rest, guide for helpers like orbits and the ground (a guide box is drawn as its edges, like a unit cell), glow for a light source like the sun. Labels are short: r, $h$, {volume}, Earth.
        - When true scale would make things invisible, like planets beside their orbits, enlarge them and say so in the text.
        - plots: z as a formula of x and y over their ranges, like x^2 - y^2 from -2 to 2. It can use inputs, so sliders reshape the surface. The app colours it by height and draws its axes.
        - molecule: its common name, like methane, water, benzene or caffeine. The app fetches its real structure from PubChem and draws it ball and stick. Never give atom positions, and leave objects empty.
        """
    }
}

extension Surface {
    /// Scenes in the outline's shorthand, so a change keeps them and the log shows them.
    var sceneOutline: [String] {
        var lines: [String] = []
        for scene in scenes ?? [] {
            lines.append("scene \(scene.name)\(scene.time.isEmpty ? "" : ", time \(scene.time)"):")
            if let molecule = scene.molecule {
                let found = molecule.structure.map { " (found \"\($0.title)\", PubChem CID \($0.cid), \($0.atoms.count) atoms)" } ?? ""
                lines.append("  molecule \(molecule.name)\(found)")
            }
            for object in scene.objects {
                var line = "  \(object.name) \(object.kind.rawValue) \(object.position)"
                if !object.to.isEmpty { line += " to \(object.to)" }
                if !object.size.isEmpty { line += " size \(object.size)" }
                if !object.turn.isEmpty { line += " turn \(object.turn)" }
                if !object.tilt.isEmpty { line += " tilt \(object.tilt)" }
                if !object.label.isEmpty { line += " \"\(object.label)\"" }
                lines.append(line + " \(object.tone.rawValue)")
            }
            for plot in scene.plots {
                lines.append("  plot z = \(plot.z) for x \(plot.xFrom) to \(plot.xTo), y \(plot.yFrom) to \(plot.yTo)\(plot.label.isEmpty ? "" : " \"\(plot.label)\"")")
            }
        }
        return lines
    }
}
