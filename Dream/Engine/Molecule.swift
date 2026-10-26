import Foundation
import simd

// Reading PubChem's 3D records (ROADMAP.md, workstream 10). What comes over the network is
// untrusted, so it's checked as strictly as the model's output: every atom, coordinate and
// bond must make sense, or the record is refused, and nothing in it is ever read as text the
// model sees beyond a cleaned-up name.

extension MoleculeStructure {
    /// More than PubChem computes conformers for, and more than a phone should draw as balls.
    static let maxAtoms = 300

    /// A PUG REST compound record (`record_type=3d`), checked. Positions are moved so the
    /// molecule is centred on its middle. Nil if it isn't a usable 3D structure. `title` and
    /// `formula` come from PubChem's property table, cleaned with `cleaned(_:)`.
    init?(pubChem data: Data, title: String = "", formula: String = "") {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), let compound = record.compounds?.first,
              let cid = compound.id?.id?.cid, cid > 0,
              let ids = compound.atoms?.aid, let elements = compound.atoms?.element,
              (1...Self.maxAtoms).contains(ids.count), elements.count == ids.count,
              elements.allSatisfy({ (1...118).contains($0) }), Set(ids).count == ids.count,
              let coordinates = compound.coords?.first, let order = coordinates.aid, Set(order) == Set(ids),
              let conformer = coordinates.conformers?.first,
              let xs = conformer.x, let ys = conformer.y, let zs = conformer.z,
              xs.count == order.count, ys.count == order.count, zs.count == order.count
        else { return nil }

        var position: [Int: Vec3] = [:]
        for (index, id) in order.enumerated() {
            let point = Vec3(xs[index], ys[index], zs[index])
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite, simd_length(point) < 500 else { return nil }
            position[id] = point
        }
        let points = ids.compactMap { position[$0] }
        guard points.count == ids.count else { return nil }
        let middle = points.reduce(Vec3.zero, +) / Double(points.count)
        let atoms = zip(elements, points).map { element, point in
            Atom(element: element, x: point.x - middle.x, y: point.y - middle.y, z: point.z - middle.z)
        }

        // Bonds between atoms that exist, at lengths real bonds have. Others are left out.
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var bonds: [Bond] = []
        if let bonded = compound.bonds, let from = bonded.aid1, let to = bonded.aid2 {
            let orders = bonded.order ?? Array(repeating: 1, count: from.count)
            guard to.count == from.count, orders.count == from.count, from.count <= ids.count * 4 else { return nil }
            var seen: Set<[Int]> = []
            for k in from.indices {
                guard let a = index[from[k]], let b = index[to[k]], a != b, seen.insert([min(a, b), max(a, b)]).inserted else { continue }
                let length = simd_length(atoms[a].position - atoms[b].position)
                guard (0.5...3.5).contains(length) else { continue }
                bonds.append(Bond(from: a, to: b, order: (1...3).contains(orders[k]) ? orders[k] : 1))
            }
        }
        self.init(cid: cid, title: Self.cleaned(title), formula: Self.cleaned(formula), atoms: atoms, bonds: bonds)
    }

    /// A name or formula as plain, short text: letters, digits, spaces and the punctuation
    /// chemical names use.
    static func cleaned(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -,()[]'+.:"))
        let kept = String(text.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
        return String(kept.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// The part of the record that's used. Everything is optional, so a record missing a part
    /// is refused by the checks above rather than by a decoding error.
    private struct Record: Decodable {
        let compounds: [Compound]?

        enum CodingKeys: String, CodingKey { case compounds = "PC_Compounds" }

        struct Compound: Decodable {
            let id: Identity?
            let atoms: Atoms?
            let bonds: Bonds?
            let coords: [Coordinates]?
        }

        struct Identity: Decodable {
            let id: Inner?
            struct Inner: Decodable { let cid: Int? }
        }

        struct Atoms: Decodable {
            let aid: [Int]?
            let element: [Int]?
        }

        struct Bonds: Decodable {
            let aid1: [Int]?
            let aid2: [Int]?
            let order: [Int]?
        }

        struct Coordinates: Decodable {
            let aid: [Int]?
            let conformers: [Conformer]?
        }

        struct Conformer: Decodable {
            let x: [Double]?
            let y: [Double]?
            let z: [Double]?
        }
    }
}
