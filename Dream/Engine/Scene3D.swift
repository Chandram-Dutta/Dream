import Foundation
import simd

// 3D scenes (ROADMAP.md, workstream 10).

/// A scene in three dimensions, defined once at the top level of a surface and shown by `scene`
/// blocks. Like a figure, it's structure: named objects whose sizes, turns and places are
/// formulas over the calculation, so they move with the sliders; surfaces plotted from
/// z = f(x, y); or a real molecule, drawn from PubChem's measured structure. Models get 3D
/// coordinates wrong, so objects are placed by helpers (on, orbit, ring, stack…) that the
/// engine works out, and atoms are never placed by the model at all. The engine also fits the
/// camera and places the labels; RealityKit only draws it.
///
/// Axes follow the maths convention: x to the right, y away from the viewer, z up.
struct Scene3D: Codable, Hashable {
    var name: String
    var objects: [SceneObject] = []
    /// Surfaces of z = f(x, y).
    var plots: [ScenePlot] = []
    /// A real molecule, drawn from its measured structure.
    var molecule: Molecule?
    /// The input the play button sweeps across its range, like t, so things orbit and turn.
    /// Empty when nothing moves on its own.
    var time = ""

    func object(_ name: String) -> SceneObject? { objects.first { $0.name == name } }
}

struct SceneObject: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case sphere, box, cylinder, cone
        /// A rod from `position` to `to`.
        case tube
        /// From `position` to `to`, like a vector or a force.
        case arrow
        /// A circle drawn as a thin hoop, lying flat unless tilted, like an orbit's path.
        case ring
        /// A flat rectangle, like the ground or a slice through something.
        case plane
        /// Axes through `position`, marked x, y and z.
        case axes
        /// Only the label, at `position`.
        case text

        /// What `size` holds, in order. The ones after the first can be left out.
        var sizeNames: [String] {
            switch self {
            case .sphere: ["radius"]
            case .box: ["width", "depth", "height"]
            case .cylinder, .cone: ["radius", "height"]
            case .tube, .arrow: ["thickness"]
            case .ring: ["radius", "thickness"]
            case .plane: ["width", "depth"]
            case .axes: ["length"]
            case .text: []
            }
        }

        /// Drawn from one end to the other rather than around a centre.
        var isSpan: Bool { self == .tube || self == .arrow }
    }

    /// How much it stands out. The colours come from the surface's palette.
    enum Tone: String, Codable, CaseIterable {
        /// What the scene is about.
        case main
        /// Something to tell apart from it.
        case contrast
        /// Everything else.
        case plain
        /// Helpers, like the ground, an axis or an orbit's path: faint.
        case guide
        /// Something that gives off light, like the sun.
        case glow
    }

    var name: String
    var kind: Kind
    /// Where it is: a placement like at(0, 0, 1), orbit(sun, 1, 360 * t / 365), on(ground) or
    /// ring(center, 2, 6), or another object's name. A placement that makes copies, like ring
    /// or stack, draws the object at each place. See `ScenePlacement`.
    var position: String
    /// tube and arrow: where it ends, as a placement. Otherwise empty.
    var to = ""
    /// Formulas separated by commas, as `Kind.sizeNames` says.
    var size = ""
    /// Degrees about its own upright axis, as a formula. Empty for none.
    var turn = ""
    /// Degrees it leans over from upright, towards x, as a formula. Empty for none.
    var tilt = ""
    /// Shown beside it: a few characters, maths or live values.
    var label = ""
    var tone: Tone = .plain
}

/// A surface z = f(x, y) over a rectangle, coloured by height. `x` and `y` are its own names,
/// so its formula can also use the calculation's inputs and outputs, and reshapes as they change.
struct ScenePlot: Codable, Hashable {
    var z: String
    var xFrom: String
    var xTo: String
    var yFrom: String
    var yTo: String
    var label = ""
}

// MARK: - Molecules

/// A molecule, by name. Its structure comes from PubChem's 3D conformer, never from the model.
struct Molecule: Codable, Hashable {
    /// What PubChem is searched for, like methane or caffeine.
    var name: String
    /// Nil until it's been looked up.
    var structure: MoleculeStructure?
}

/// Atoms and bonds as PubChem gives them, checked (`MoleculeStructure.init(pubChem:)`), with
/// positions in ångströms around the molecule's centre.
struct MoleculeStructure: Codable, Hashable {
    struct Atom: Codable, Hashable {
        /// The atomic number.
        var element: Int
        var x: Double
        var y: Double
        var z: Double

        var position: SIMD3<Double> { SIMD3(x, y, z) }
    }

    struct Bond: Codable, Hashable {
        /// Positions in `atoms`.
        var from: Int
        var to: Int
        /// 1, 2 or 3.
        var order: Int
    }

    /// PubChem's compound ID.
    var cid: Int
    /// PubChem's name for it, like Methane.
    var title: String
    /// Like CH4.
    var formula: String
    var atoms: [Atom]
    var bonds: [Bond]

    var pageURL: String { "https://pubchem.ncbi.nlm.nih.gov/compound/\(cid)" }

    /// Each element in it, in the order chemists write formulas (carbon, hydrogen, then the
    /// rest alphabetically), with how many atoms of it there are.
    var elements: [(element: Element, count: Int)] {
        let counts = Dictionary(grouping: atoms, by: \.element).mapValues(\.count)
        return counts.keys.map { (Element.of($0), counts[$0] ?? 0) }.sorted { a, b in
            let order = { (element: Element) -> (Int, String) in (element.number == 6 ? 0 : element.number == 1 ? 1 : 2, element.symbol) }
            return order(a.element) < order(b.element)
        }
    }
}

/// What ball-and-stick models need to know about an element: Jmol's colours, which chemists
/// recognize, and van der Waals radii, which size the balls in proportion.
struct Element: Hashable {
    let number: Int
    let symbol: String
    let name: String
    /// Red, green and blue, from 0 to 1.
    let color: SIMD3<Double>
    /// In ångströms.
    let radius: Double

    static func of(_ number: Int) -> Element {
        table[number] ?? Element(number: number, symbol: "?", name: "Element \(number)", color: SIMD3(1, 0.08, 0.58), radius: 2)
    }

    private static let table: [Int: Element] = {
        let rows: [(Int, String, String, UInt32, Double)] = [
            (1, "H", "Hydrogen", 0xFFFFFF, 1.20), (2, "He", "Helium", 0xD9FFFF, 1.40), (3, "Li", "Lithium", 0xCC80FF, 1.82),
            (4, "Be", "Beryllium", 0xC2FF00, 1.53), (5, "B", "Boron", 0xFFB5B5, 1.92), (6, "C", "Carbon", 0x909090, 1.70),
            (7, "N", "Nitrogen", 0x3050F8, 1.55), (8, "O", "Oxygen", 0xFF0D0D, 1.52), (9, "F", "Fluorine", 0x90E050, 1.47),
            (10, "Ne", "Neon", 0xB3E3F5, 1.54), (11, "Na", "Sodium", 0xAB5CF2, 2.27), (12, "Mg", "Magnesium", 0x8AFF00, 1.73),
            (13, "Al", "Aluminium", 0xBFA6A6, 1.84), (14, "Si", "Silicon", 0xF0C8A0, 2.10), (15, "P", "Phosphorus", 0xFF8000, 1.80),
            (16, "S", "Sulfur", 0xFFFF30, 1.80), (17, "Cl", "Chlorine", 0x1FF01F, 1.75), (18, "Ar", "Argon", 0x80D1E3, 1.88),
            (19, "K", "Potassium", 0x8F40D4, 2.75), (20, "Ca", "Calcium", 0x3DFF00, 2.31), (22, "Ti", "Titanium", 0xBFC2C7, 2.00),
            (24, "Cr", "Chromium", 0x8A99C7, 2.00), (25, "Mn", "Manganese", 0x9C7AC7, 2.00), (26, "Fe", "Iron", 0xE06633, 2.00),
            (27, "Co", "Cobalt", 0xF090A0, 2.00), (28, "Ni", "Nickel", 0x50D050, 1.63), (29, "Cu", "Copper", 0xC88033, 1.40),
            (30, "Zn", "Zinc", 0x7D80B0, 1.39), (33, "As", "Arsenic", 0xBD80E3, 1.85), (34, "Se", "Selenium", 0xFFA100, 1.90),
            (35, "Br", "Bromine", 0xA62929, 1.85), (36, "Kr", "Krypton", 0x5CB8D1, 2.02), (47, "Ag", "Silver", 0xC0C0C0, 1.72),
            (50, "Sn", "Tin", 0x668080, 2.17), (53, "I", "Iodine", 0x940094, 1.98), (54, "Xe", "Xenon", 0x429EB0, 2.16),
            (78, "Pt", "Platinum", 0xD0D0E0, 1.75), (79, "Au", "Gold", 0xFFD123, 1.66), (80, "Hg", "Mercury", 0xB8B8D0, 1.55),
            (82, "Pb", "Lead", 0x575961, 2.02), (92, "U", "Uranium", 0x008FFF, 1.86),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { number, symbol, name, hex, radius in
            let color = SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)) / 255
            return (number, Element(number: number, symbol: symbol, name: name, color: color, radius: radius))
        })
    }()
}

// MARK: - Finding them

extension Surface {
    func scene(_ name: String) -> Scene3D? { scenes?.first { $0.name == name } }

    /// What scenes run along on their own: the inputs they play, and the inputs a plot is drawn
    /// over. Like a chart's variable, these need no control of their own.
    var sceneAxes: Set<String> {
        Set((scenes ?? []).flatMap { scene in
            [scene.time].filter { !$0.isEmpty } + (scene.plots.isEmpty ? [] : ["x", "y"].filter { input($0)?.role == .variable })
        })
    }
}
