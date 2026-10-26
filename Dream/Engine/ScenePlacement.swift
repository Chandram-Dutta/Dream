import Foundation
import simd

typealias Vec3 = SIMD3<Double>

/// Where a scene's objects go. A position is written like a formula call, so the formula parser
/// reads it, and its numbers are formulas over the calculation:
///
/// - `at(x, y, z)`, or `at(other, dx, dy, dz)` from another object's centre, or just a name.
/// - `orbit(center, radius, angle)`: on a level circle round `center`, `angle` degrees
///   counterclockwise from x, seen from above.
/// - `on(base, gap)`: resting on top of `base`, or on the ground with `on()` or `on(ground)`.
/// - `beside(other, gap)`: next to `other` along x, standing on the same level.
/// - `between(a, b, fraction)`: on the line from `a` to `b`, halfway unless `fraction` says.
/// - `ring(center, radius, count, start)`: `count` copies spaced round a level circle.
/// - `row(start, spacing, count)`: copies along x.
/// - `stack(base, count)`: copies piled up on `base`.
/// - `grid(start, spacing, nx, ny, nz, parity)`: copies in a block, from its first corner. A
///   parity of 0 or 1 keeps every other place, so two objects can alternate, like the ions of
///   a salt crystal.
///
/// Places can nest, like `orbit(at(0, 0, 2), 1, 45)`. Models are good at naming what goes on
/// what and bad at the trigonometry behind it, which is the engine's job.
enum ScenePlacement {
    enum Argument { case place, number }

    struct Helper {
        let arguments: [Argument]
        /// How many have to be given; the rest have defaults.
        let required: Int
        /// Whether it can make more than one copy.
        let copies: Bool
    }

    static let helpers: [String: Helper] = [
        "orbit": Helper(arguments: [.place, .number, .number], required: 3, copies: false),
        "on": Helper(arguments: [.place, .number], required: 0, copies: false),
        "beside": Helper(arguments: [.place, .number], required: 1, copies: false),
        "between": Helper(arguments: [.place, .place, .number], required: 2, copies: false),
        "ring": Helper(arguments: [.place, .number, .number, .number], required: 3, copies: true),
        "row": Helper(arguments: [.place, .number, .number], required: 3, copies: true),
        "stack": Helper(arguments: [.place, .number], required: 2, copies: true),
        "grid": Helper(arguments: [.place, .number, .number, .number, .number, .number], required: 3, copies: true),
    ]

    /// Words models reach for instead, read as the helper they mean.
    static let synonyms: [String: String] = [
        "around": "orbit", "orbiting": "orbit", "circle": "ring", "above": "on", "atop": "on", "onto": "on", "ontop": "on",
        "next": "beside", "nextto": "beside", "besides": "beside", "midpoint": "between", "line": "row", "column": "stack",
        "pile": "stack", "lattice": "grid", "array": "grid", "point": "at", "position": "at", "pos": "at", "vec": "at",
        "vector": "at", "vec3": "at", "offset": "at", "translate": "at",
    ]

    /// The level the ground is at: z = 0, as far as needed in every direction.
    static let ground = "ground"

    /// The most copies one placement makes, so a slider can't fill the phone with spheres.
    static let maxCopies = 216

    static func isHelper(_ name: String) -> Bool { name == "at" || helpers[name] != nil }
}

/// An object's first place and how far it reaches from there along each axis, which is what
/// other objects are placed against.
struct SceneSpot {
    var center: Vec3
    var half: Vec3

    var top: Double { center.z + half.z }
    var bottom: Double { center.z - half.z }

    static let ground = SceneSpot(center: .zero, half: .zero)
}

extension ScenePlacement {
    /// Works out the places a position names. `objects` are the names of the scene's objects,
    /// `spot` finds one of them (or `ground`), and `number` works out a formula. `half` is how far
    /// the object being placed reaches, so it can rest on things rather than sink into them.
    static func places(_ expr: Expr, half: Vec3, objects: Set<String>, spot: (String) throws -> SceneSpot, number: (Expr) throws -> Double) throws -> [Vec3] {
        /// A place given as an argument: an object, the ground, or a nested placement.
        func base(_ argument: Expr?) throws -> SceneSpot {
            guard let argument else { return .ground }
            switch argument {
            case .name(let name): return try spot(name)
            case .call(let function, _) where isHelper(function):
                guard let first = try places(argument, half: .zero, objects: objects, spot: spot, number: number).first else { throw FormulaError("an empty place") }
                return SceneSpot(center: first, half: .zero)
            default:
                throw FormulaError("\(argument) isn't a place")
            }
        }
        func value(_ argument: Expr?, or fallback: Double) throws -> Double {
            guard let argument else { return fallback }
            let result = try number(argument)
            guard result.isFinite else { throw FormulaError("\(argument) isn't a number") }
            return result
        }
        func count(_ argument: Expr?) throws -> Int {
            let raw = try value(argument, or: 1).rounded()
            return Int(Swift.min(Swift.max(raw, 0), Double(maxCopies)))
        }
        func degrees(_ value: Double) -> Double { value * .pi / 180 }

        switch expr {
        case .name(let name):
            return [try spot(name).center]
        case .call("at", let arguments):
            // A place first means "from there"; otherwise the numbers are where it is.
            if let first = arguments.first, isPlace(first, objects: objects) {
                let from = try base(first)
                let rest = arguments.dropFirst()
                let offset = Vec3(try value(rest.first, or: 0), try value(rest.dropFirst().first, or: 0), try value(rest.dropFirst(2).first, or: 0))
                return [from.center + offset]
            }
            guard (1...3).contains(arguments.count) else { throw FormulaError("at() needs x, y and z") }
            return [Vec3(try value(arguments.first, or: 0), try value(arguments.dropFirst().first, or: 0), try value(arguments.dropFirst(2).first, or: 0))]
        case .call("orbit", let arguments):
            guard arguments.count >= 3 else { throw FormulaError("orbit() needs a centre, a radius and an angle") }
            let center = try base(arguments[0]).center
            let radius = try value(arguments[1], or: 1)
            let angle = degrees(try value(arguments[2], or: 0))
            return [center + Vec3(cos(angle), sin(angle), 0) * radius]
        case .call("on", let arguments):
            let below = try base(arguments.first)
            let gap = try value(arguments.dropFirst().first, or: 0)
            return [Vec3(below.center.x, below.center.y, below.top + gap + half.z)]
        case .call("beside", let arguments):
            guard let first = arguments.first else { throw FormulaError("beside() needs something to stand beside") }
            let other = try base(first)
            let gap = try value(arguments.dropFirst().first, or: 0.3 * Swift.max(other.half.x, half.x))
            return [Vec3(other.center.x + other.half.x + gap + half.x, other.center.y, other.bottom + half.z)]
        case .call("between", let arguments):
            guard arguments.count >= 2 else { throw FormulaError("between() needs two places") }
            let (a, b) = (try base(arguments[0]).center, try base(arguments[1]).center)
            let fraction = try value(arguments.dropFirst(2).first, or: 0.5)
            return [a + (b - a) * fraction]
        case .call("ring", let arguments):
            guard arguments.count >= 3 else { throw FormulaError("ring() needs a centre, a radius and a count") }
            let center = try base(arguments[0]).center
            let radius = try value(arguments[1], or: 1)
            let n = try count(arguments[2])
            let start = degrees(try value(arguments.dropFirst(3).first, or: 0))
            return (0..<n).map { k in
                let angle = start + 2 * .pi * Double(k) / Double(n)
                return center + Vec3(cos(angle), sin(angle), 0) * radius
            }
        case .call("row", let arguments):
            guard arguments.count >= 3 else { throw FormulaError("row() needs a start, a spacing and a count") }
            let start = try base(arguments[0]).center
            let spacing = try value(arguments[1], or: 1)
            return (0..<(try count(arguments[2]))).map { start + Vec3(Double($0) * spacing, 0, 0) }
        case .call("stack", let arguments):
            guard arguments.count >= 2 else { throw FormulaError("stack() needs a base and a count") }
            let below = try base(arguments[0])
            return (0..<(try count(arguments[1]))).map { k in
                Vec3(below.center.x, below.center.y, below.top + half.z * Double(2 * k + 1))
            }
        case .call("grid", let arguments):
            guard arguments.count >= 3 else { throw FormulaError("grid() needs a start, a spacing and how many along x") }
            let start = try base(arguments[0]).center
            let spacing = try value(arguments[1], or: 1)
            let counts = [try count(arguments[2]), try count(arguments.dropFirst(3).first), try count(arguments.dropFirst(4).first)]
            let parity = try arguments.dropFirst(5).first.map { Int(try value($0, or: 0).rounded()) & 1 }
            guard counts.reduce(1, *) <= maxCopies * (parity == nil ? 1 : 2) else { throw FormulaError("grid() would make more than \(maxCopies) copies") }
            var result: [Vec3] = []
            for k in 0..<counts[2] {
                for j in 0..<counts[1] {
                    for i in 0..<counts[0] where parity.map({ (i + j + k) & 1 == $0 }) ?? true {
                        result.append(start + Vec3(Double(i), Double(j), Double(k)) * spacing)
                    }
                }
            }
            return result
        case .call(let function, _):
            throw FormulaError("\(function)() isn't a placement")
        default:
            throw FormulaError("\(expr) isn't a place")
        }
    }

    /// Whether an argument names a place rather than a number: a placement, the ground, or one
    /// of the scene's objects. This is for `at`, which takes either first.
    static func isPlace(_ argument: Expr, objects: Set<String>) -> Bool {
        switch argument {
        case .call(let function, _): return isHelper(function)
        case .name(let name): return name == ground || objects.contains(name)
        default: return false
        }
    }
}
