import Foundation

/// Real 3D structures from PubChem, found the way `SoundLookup` finds recordings: the model
/// names a molecule, and once the surface is written its measured or computed conformer is
/// fetched and checked (`MoleculeStructure.init(pubChem:)`). The model never places atoms.
enum MoleculeLookup {
    /// What's been found this session, by name, so changing a page doesn't fetch it again.
    private static let cache = Cache()

    static func find(_ name: String) async -> MoleculeStructure? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.count <= 80 else { return nil }
        if let known = cache[key] { return known }
        guard let segment = key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")),
              let record = await fetch("compound/name/\(segment)/JSON?record_type=3d"),
              let found = MoleculeStructure(pubChem: record)
        else { return nil }
        // PubChem's own name and formula, for the credit and the legend.
        var structure = found
        if let data = await fetch("compound/cid/\(found.cid)/property/Title,MolecularFormula/JSON"),
           let table = try? JSONDecoder().decode(PropertyTable.self, from: data), let row = table.table.properties.first(where: { $0.cid == found.cid }) {
            structure.title = MoleculeStructure.cleaned(row.title ?? "")
            structure.formula = MoleculeStructure.cleaned(row.formula ?? "")
        }
        if structure.title.isEmpty { structure.title = MoleculeStructure.cleaned(name.capitalized) }
        cache[key] = structure
        return structure
    }

    private static func fetch(_ path: String) async -> Data? {
        guard let url = URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Dream/0.1 (iOS prototype)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
            // PubChem asks busy clients to slow down; one more try, a moment later.
            if status == 503 || status == 429, attempt == 0 {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            // A full 3D record for the biggest molecules allowed is well under this.
            return status == 200 && data.count < 4_000_000 ? data : nil
        }
        return nil
    }

    private struct PropertyTable: Decodable {
        let table: Table

        enum CodingKeys: String, CodingKey { case table = "PropertyTable" }

        struct Table: Decodable {
            let properties: [Row]
            enum CodingKeys: String, CodingKey { case properties = "Properties" }
        }

        struct Row: Decodable {
            let cid: Int
            let title: String?
            let formula: String?
            enum CodingKeys: String, CodingKey { case cid = "CID", title = "Title", formula = "MolecularFormula" }
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: MoleculeStructure] = [:]

        subscript(key: String) -> MoleculeStructure? {
            get { lock.withLock { found[key] } }
            set { lock.withLock { found[key] = newValue } }
        }
    }
}

extension Surface {
    /// Fetches the structure of every molecule a scene names, all at once. One that isn't
    /// found is left without, and the checker drops it.
    mutating func findMolecules() async {
        guard let scenes else { return }
        let wanted = scenes.indices.filter { scenes[$0].molecule.map { $0.structure == nil && !$0.name.isEmpty } ?? false }
        guard !wanted.isEmpty else { return }
        let found = await withTaskGroup(of: (Int, MoleculeStructure?).self) { group in
            for index in wanted {
                let name = scenes[index].molecule?.name ?? ""
                group.addTask { (index, await MoleculeLookup.find(name)) }
            }
            return await group.reduce(into: [Int: MoleculeStructure]()) { $0[$1.0] = $1.1 }
        }
        for (index, structure) in found {
            self.scenes?[index].molecule?.structure = structure
        }
    }
}
