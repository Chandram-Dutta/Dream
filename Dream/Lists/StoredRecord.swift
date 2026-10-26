import Foundation
import SwiftData

/// One of the user's entries in a surface's list, as stored on the phone.
///
/// SwiftData can't make tables at runtime, so every collection's entries share this one generic
/// shape: which surface and list it belongs to, and its values as JSON. The engine never sees
/// this type, only the plain `Record` it holds.
@Model
final class StoredRecord {
    #Index<StoredRecord>([\.surfaceID])

    var surfaceID = UUID()
    var collection = ""
    var recordID = UUID()
    var valuesData = Data()
    var order = 0.0
    var createdAt = Date()
    var updatedAt = Date()

    init(surfaceID: UUID, collection: String, record: Record) {
        self.surfaceID = surfaceID
        self.recordID = record.id
        self.createdAt = record.created
        update(collection: collection, record: record)
    }

    var record: Record {
        Record(id: recordID, values: (try? JSONDecoder().decode([String: RecordValue].self, from: valuesData)) ?? [:], order: order, created: createdAt)
    }

    func update(collection: String, record: Record) {
        self.collection = collection
        valuesData = (try? Self.encoder.encode(record.values)) ?? Data()
        order = record.order
        updatedAt = .now
    }

    /// Entries by collection, the way the engine takes them.
    static func grouped(_ stored: [StoredRecord]) -> [String: [Record]] {
        Dictionary(grouping: stored, by: \.collection).mapValues { $0.map(\.record) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}
