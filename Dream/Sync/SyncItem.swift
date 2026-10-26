import Foundation

// Cloud sync (PRODUCTION.md, workstream B): what travels between this iPhone and the user's
// account on Dream's server (Server/src/sync.ts). Nothing here touches storage or the network,
// so `Tools/sync.sh` checks it on a Mac.

/// What syncs, as the server names it.
enum SyncKind: String, Codable, CaseIterable, Sendable {
    /// A saved page: its template, the user's numbers, its conversation and its photo.
    case surface
    /// One entry in one of a page's lists.
    case record
    /// One thing Dream knows about the user.
    case fact
    /// A service the user connected, with what they've let it do. Never its sign-in.
    case connection
    /// A setting worth having on every device.
    case setting
}

/// One item: its kind, and its own id, made on the device that created it.
struct SyncKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    var kind: SyncKind
    var id: String

    init(_ kind: SyncKind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    /// "surface/<id>", as the ledger keeps it.
    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = SyncKind(rawValue: parts[0]) else { return nil }
        self.init(kind, parts[1])
    }

    var description: String { "\(kind.rawValue)/\(id)" }

    static func < (a: SyncKey, b: SyncKey) -> Bool { a.description < b.description }
}

/// One item as it travels: its latest version, or a tombstone saying it was deleted.
struct SyncItem: Codable, Hashable, Sendable {
    /// Kept as written, so a kind this version doesn't know is passed over rather than refused.
    var kind: String
    var id: String
    /// A list entry's page.
    var parent: String?
    /// The shape of `body`, so a later version of Dream can still read what this one wrote.
    var format: Int
    /// When it last changed, in milliseconds since 1970 by the server's clock, as the device that
    /// changed it reckoned it. The latest change wins.
    var updatedAt: Int64
    var deleted: Bool
    var body: JSONValue?

    init(_ key: SyncKey, parent: String? = nil, format: Int = SyncFormat.current, updatedAt: Int64, deleted: Bool = false, body: JSONValue? = nil) {
        kind = key.kind.rawValue
        id = key.id
        self.parent = parent
        self.format = format
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.body = deleted ? nil : body
    }

    /// Nil for a kind this version doesn't know.
    var key: SyncKey? { SyncKind(rawValue: kind).map { SyncKey($0, id) } }

    /// The tombstone for an item.
    static func deletion(_ key: SyncKey, parent: String? = nil, at stamp: Int64) -> SyncItem {
        SyncItem(key, parent: parent, updatedAt: stamp, deleted: true)
    }
}

/// The newest shape of each kind's body that this version writes. Every earlier one stays
/// readable: a payload's decoder takes any format up to this, and fields added later decode
/// with defaults when they're missing.
enum SyncFormat {
    static let current = 1
}

/// An item from a newer version of Dream than this one. It waits, unread, until the app updates.
struct NewerFormat: Error {}

/// Dates as ISO 8601 with milliseconds, so what's stored reads plainly; times in ms also decode.
enum SyncCoding {
    private static let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(precise.format(date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let millis = try? container.decode(Double.self) { return Date(timeIntervalSince1970: millis / 1000) }
            let text = try container.decode(String.self)
            if let date = (try? precise.parse(text)) ?? (try? plain.parse(text)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date")
        }
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

/// The body of one kind of item.
protocol SyncPayload: Codable {
    static var kind: SyncKind { get }
}

extension SyncPayload {
    /// Reads an item's body, in any format up to the current one.
    static func read(_ item: SyncItem) throws -> Self {
        guard item.format <= SyncFormat.current else { throw NewerFormat() }
        guard let body = item.body else { throw DecodingError.valueNotFound(Self.self, .init(codingPath: [], debugDescription: "No body")) }
        return try SyncCoding.decoder.decode(Self.self, from: JSONEncoder().encode(body))
    }

    /// This, as an item to send.
    func item(id: String, parent: String? = nil, at stamp: Int64) throws -> SyncItem {
        let body = try JSONDecoder().decode(JSONValue.self, from: SyncCoding.encoder.encode(self))
        return SyncItem(SyncKey(Self.kind, id), parent: parent, updatedAt: stamp, body: body)
    }
}

extension SyncItem {
    /// Bytes of its body, as the server counts them.
    var size: Int { body.map { Data($0.jsonString.utf8).count } ?? 0 }
}
