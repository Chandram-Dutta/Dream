import Foundation

// The body of each kind of item, format 1. Every field decodes with a default when it's missing,
// so a later version that adds fields keeps reading what this one wrote, and this one reads what
// a later one wrote in the same format. The server can read all of it (PRODUCTION.md).

/// A saved page (SavedSurface): the template, and everything about it that's the user's.
struct SurfacePayload: SyncPayload {
    static let kind = SyncKind.surface

    /// What the user asked for, in their words.
    var intent = ""
    var createdAt = Date.distantPast
    /// When the template last changed.
    var updatedAt = Date.distantPast
    var lastOpenedAt: Date?
    var openCount = 0
    var modelName = ""
    /// The user's conversation with the page.
    var history: [PageTurn] = []
    /// Changes asked for, as earlier versions kept them.
    var editRequests: [String] = []
    var generationLog: [String] = []
    /// The template, exactly as the page keeps it.
    var template = JSONValue.object([:])
    /// The user's own numbers.
    var values: [String: Double] = [:]
    /// The link it was opened from, when someone else shared it.
    var sharedFrom: String?
    /// The photo it started from, by its id on the server (/api/photos/:id).
    var photo: String?
    /// Lists whose starter entries were already added, so another device doesn't add them again.
    var seeded: [String] = []
    var starred = false
    /// The page it went on from.
    var parent: String?
    /// What understanding the request found out, and what the page is about.
    var found = ""
    var subjects: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decodeIfPresent(String.self, forKey: .intent) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        openCount = try c.decodeIfPresent(Int.self, forKey: .openCount) ?? 0
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        history = try c.decodeIfPresent([PageTurn].self, forKey: .history) ?? []
        editRequests = try c.decodeIfPresent([String].self, forKey: .editRequests) ?? []
        generationLog = try c.decodeIfPresent([String].self, forKey: .generationLog) ?? []
        template = try c.decodeIfPresent(JSONValue.self, forKey: .template) ?? .object([:])
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        sharedFrom = try c.decodeIfPresent(String.self, forKey: .sharedFrom)
        photo = try c.decodeIfPresent(String.self, forKey: .photo)
        seeded = try c.decodeIfPresent([String].self, forKey: .seeded) ?? []
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        found = try c.decodeIfPresent(String.self, forKey: .found) ?? ""
        subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
    }

    /// The same page with less of its generation log, for one that's grown past what an item may
    /// carry. The log is a record of how it was built, not the user's words, so it goes first.
    func trimmed(keepingLog lines: Int) -> SurfacePayload {
        var trimmed = self
        trimmed.generationLog = Array(generationLog.suffix(lines))
        return trimmed
    }
}

/// One entry in a page's list (StoredRecord). The page is the item's parent.
struct RecordPayload: SyncPayload {
    static let kind = SyncKind.record

    var collection = ""
    var values: [String: RecordValue] = [:]
    var order = 0.0
    var createdAt = Date.distantPast
    var updatedAt = Date.distantPast

    init(collection: String, values: [String: RecordValue], order: Double, createdAt: Date, updatedAt: Date) {
        self.collection = collection
        self.values = values
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decodeIfPresent(String.self, forKey: .collection) ?? ""
        values = try c.decodeIfPresent([String: RecordValue].self, forKey: .values) ?? [:]
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// One thing Dream knows about the user (MemoryFact).
struct FactPayload: SyncPayload {
    static let kind = SyncKind.fact

    var topic = ""
    var text = ""
    /// said, answered or inferred.
    var source = "said"
    var confirmed = false
    /// The request it came from, if any.
    var request = ""
    var createdAt = Date.distantPast
    var updatedAt = Date.distantPast
    var lastUsedAt: Date?

    init(topic: String, text: String, source: String, confirmed: Bool, request: String, createdAt: Date, updatedAt: Date, lastUsedAt: Date?) {
        self.topic = topic
        self.text = text
        self.source = source
        self.confirmed = confirmed
        self.request = request
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "said"
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        request = try c.decodeIfPresent(String.self, forKey: .request) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// A service the user connected: everything the phone keeps about it except its sign-in, whose
/// tokens never leave the Keychain.
struct ConnectionPayload: SyncPayload {
    static let kind = SyncKind.connection

    var url: URL
    var name = ""
    var isOn = true
    /// "Always" for the service's look-ups.
    var alwaysLooksUp = false
    /// Its tools, each with whether it's on and whether the user chose "Always" for it.
    var tools: [ConnectedTool] = []

    init(_ connection: Connection) {
        url = connection.url
        name = connection.name
        isOn = connection.isOn
        alwaysLooksUp = connection.alwaysLooksUp
        tools = connection.tools
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? url.host() ?? ""
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        alwaysLooksUp = try c.decodeIfPresent(Bool.self, forKey: .alwaysLooksUp) ?? false
        tools = try c.decodeIfPresent([ConnectedTool].self, forKey: .tools) ?? []
    }

    /// The connection it describes, under its id.
    func connection(id: UUID) -> Connection {
        var connection = Connection(url: url, name: name)
        connection.id = id
        connection.isOn = isOn
        connection.alwaysLooksUp = alwaysLooksUp
        connection.tools = tools
        return connection
    }

    /// The same, with the tools' schemas left out, for a service whose list of tools is too long
    /// to carry. Each device lists them again from the service; the user's choices still travel.
    var withoutSchemas: ConnectionPayload {
        var light = self
        light.tools = tools.map { tool in
            var tool = tool
            tool.inputSchema = .object([:])
            tool.summary = ""
            return tool
        }
        return light
    }
}

/// A setting worth having on every device.
struct SettingPayload: SyncPayload {
    static let kind = SyncKind.setting

    var value = JSONValue.null

    init(value: JSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
    }
}
