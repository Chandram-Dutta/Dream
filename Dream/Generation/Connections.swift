import Foundation
import NaturalLanguage

// Connected services (ROADMAP.md, workstream 8): remote MCP servers the user adds, and what
// building a screen may do with them. The app's store (Dream/Connections) talks to the servers;
// this side decides what the model sees, and asks the user before a tool runs (Consent.swift).

/// A remote MCP server the user connected, with the tools it offers and what the user has let it
/// do without asking. Kept on the phone; a sign-in's tokens are in the Keychain, never here.
struct Connection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// The server's MCP endpoint, like https://mcp.linear.app/mcp.
    var url: URL
    /// What the server calls itself, or its host.
    var name: String
    /// Off, none of its tools are offered or called.
    var isOn = true
    var tools: [ConnectedTool] = []
    /// The user chose "Always" for its tools that only look things up: they run without asking,
    /// unless a call carries something personal.
    var alwaysLooksUp = false
    /// When its tools were last listed.
    var checkedAt: Date?

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    var host: String { url.host() ?? url.absoluteString }

    /// A short lowercase name for tools' names, like deepwiki.
    var slug: String {
        let name = ToolSchema.identifier(name.lowercased())
        return String((name == "value" ? ToolSchema.identifier(host.lowercased()) : name).prefix(20))
    }

    // Later versions may add settings, and earlier ones had switches that blocked tools; older
    // saved connections still load, without them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        name = try container.decode(String.self, forKey: .name)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        tools = try container.decodeIfPresent([ConnectedTool].self, forKey: .tools) ?? []
        alwaysLooksUp = try container.decodeIfPresent(Bool.self, forKey: .alwaysLooksUp) ?? false
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
    }
}

/// One tool a connected server offers, with the server's hints about what it does.
struct ConnectedTool: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var title: String?
    var summary: String
    var inputSchema: JSONValue
    /// The server's hints. They're only hints, from a server Dream doesn't control, so a missing
    /// one counts as the riskier answer: an unmarked tool may write, and a write may destroy.
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?
    /// Off, it's never offered or called.
    var isOn = true
    /// The user chose "Always allow this action": it runs without asking, unless a call carries
    /// something personal.
    var alwaysAllowed = false

    init(name: String, title: String?, summary: String, inputSchema: JSONValue, readOnlyHint: Bool?, destructiveHint: Bool?, idempotentHint: Bool?, openWorldHint: Bool?) {
        self.name = name
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema) ?? .object([:])
        readOnlyHint = try container.decodeIfPresent(Bool.self, forKey: .readOnlyHint)
        destructiveHint = try container.decodeIfPresent(Bool.self, forKey: .destructiveHint)
        idempotentHint = try container.decodeIfPresent(Bool.self, forKey: .idempotentHint)
        openWorldHint = try container.decodeIfPresent(Bool.self, forKey: .openWorldHint)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        alwaysAllowed = try container.decodeIfPresent(Bool.self, forKey: .alwaysAllowed) ?? false
    }

    var id: String { name }
    var label: String { title?.isEmpty == false ? title! : name }

    /// Whether its service says it only reads.
    var readsOnly: Bool { readOnlyHint == true }

    /// What running it does, by the hints. A tool whose service doesn't say counts as one that
    /// may destroy something.
    enum Effect { case reads, changes, destroys }

    var effect: Effect {
        if readsOnly { return .reads }
        return destructiveHint == false ? .changes : .destroys
    }

    /// Whether a tap on its button should be confirmed before it runs.
    var needsConfirmation: Bool { effect == .destroys }

    /// Whether the model can be given it: its inputs have a shape guided generation can fill.
    var isRepresentable: Bool { ToolSchema.generationSchema(for: inputSchema, name: "check") != nil }
}

/// What a tool returned. It came from a server, so it's data, never instructions.
struct ToolResult: Hashable, Sendable {
    /// Its text, and what its other content was.
    var text: String
    /// Structured content, when the tool gave some.
    var structured: JSONValue?
    var isError: Bool
}

enum ConnectionError: LocalizedError, Equatable {
    case unavailable
    case off(String)
    case toolOff(String)
    case needsSignIn(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Connections aren't available here."
        case .off(let name): "\(name) is switched off."
        case .toolOff(let tool): "\(tool) is switched off."
        case .needsSignIn(let name): "\(name) needs you to sign in."
        case .timedOut(let name): "\(name) didn't answer in time."
        case .failed(let message): message
        }
    }
}

/// A service in the directory of MCP servers (the Worker's /api/mcp/, from the MCP Registry).
struct DirectoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var url: URL
    var website: URL?
    var icon: URL?
    /// Nil when nobody has checked.
    var signIn: Bool?
    var category: String?
    /// Other names for it, like Jira for Atlassian.
    var aliases: [String] = []
    var featured = false

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        url = try container.decode(URL.self, forKey: .url)
        website = try? container.decodeIfPresent(URL.self, forKey: .website)
        icon = try? container.decodeIfPresent(URL.self, forKey: .icon)
        signIn = try container.decodeIfPresent(Bool.self, forKey: .signIn)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
    }
}

/// The user's connected services, as building a screen sees them. The app connects its store at
/// launch; the bench registers servers with `-mcp`. Nothing here talks to a server itself.
enum Connections {
    struct Source: Sendable {
        /// The connections as they stand. Called while a session is set up, so it can't wait.
        var connections: @Sendable () -> [Connection]
        /// Runs a tool. Whether to ask first is the caller's to decide (`ConsentPolicy`).
        var call: @Sendable (_ connection: Connection, _ tool: String, _ arguments: JSONValue) async throws -> ToolResult
        /// The details Dream remembers about the user, so a call that carries one is always shown.
        var personalDetails: @Sendable () async -> [PersonalDetail]
        /// Keeps an "Always": for a service's look-ups (a nil tool), or for one tool.
        var allowAlways: @Sendable (_ connection: Connection.ID, _ tool: String?) async -> Void = { _, _ in }
    }

    nonisolated(unsafe) static var source = Source(
        connections: { [] },
        call: { _, _, _ in throw ConnectionError.unavailable },
        personalDetails: { [] })

    /// The directory's featured services, as last fetched, for noticing one in a request.
    nonisolated(unsafe) static var directory: [DirectoryEntry] = []

    /// Runs a switched-on tool for the user: live sources reading again, and action buttons on a
    /// tap. Nothing here asks; those callers already have the user's word.
    static func call(_ tool: String, on id: Connection.ID, arguments: JSONValue) async throws -> ToolResult {
        guard let connection = source.connections().first(where: { $0.id == id }) else { throw ConnectionError.unavailable }
        guard connection.isOn else { throw ConnectionError.off(connection.name) }
        guard connection.tools.first(where: { $0.name == tool })?.isOn == true else { throw ConnectionError.toolOff(tool) }
        return try await source.call(connection, tool, arguments)
    }

    /// Every tool the model may be given while building: switched on, with inputs it can fill.
    /// What its hints say decides only whether the user is asked first.
    static var usableTools: [(connection: Connection, tool: ConnectedTool)] {
        source.connections().filter(\.isOn).flatMap { connection in
            connection.tools.filter { $0.isOn && $0.isRepresentable }.map { (connection, $0) }
        }
    }

    /// Tools offered by relevance alone: those that only look things up, and those whose service
    /// doesn't say, which may.
    static var lookingTools: [(connection: Connection, tool: ConnectedTool)] {
        usableTools.filter { $0.tool.readOnlyHint != false }
    }

    /// Tools that say they change things, offered when the request asks to do something.
    static var changingTools: [(connection: Connection, tool: ConnectedTool)] {
        usableTools.filter { $0.tool.readOnlyHint == false }
    }

    /// Services from the directory a request names as holding the user's own things, but that
    /// the user hasn't connected: "my Linear issues", "the sprint in Jira", "add it to Notion".
    /// Naming one in passing ("Linear vs Jira") isn't asking for what's in it, and "linear
    /// regression in linear algebra" isn't naming one at all.
    static func unconnected(in request: String) -> [DirectoryEntry] {
        let connected = Set(source.connections().compactMap { $0.url.host()?.lowercased() })
        return directory.filter { entry in
            guard !connected.contains(entry.url.host()?.lowercased() ?? "") else { return false }
            return ([entry.name] + entry.aliases).contains { Self.names($0, in: request) }
        }
    }

    private static func names(_ service: String, in request: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: service)
        // Theirs, however it's written.
        if request.range(of: "\\b(my|our)\\s+(own\\s+)?\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        // Somewhere things are kept, written with its capital.
        return request.range(of: "(?i:\\b(in|on|from|to|into|inside|with|using|via)\\s+(the\\s+)?)\(escaped)\\b", options: .regularExpression) != nil
    }
}


// MARK: - Picking

/// Picks the few tools worth offering for a request, so the model's context stays small. It runs
/// on the phone in a few milliseconds, by the words the request shares with each tool.
///
/// Naming the service ("my Linear issues") counts most. Otherwise only the request's nouns and
/// names count, matched against what a tool says it does: verbs and inputs say little, and a
/// dataset tool's `split` input shouldn't answer "split a bill". Words every tool uses ("data",
/// "list") don't count, and a short word matches the start of a longer one, so "repo" finds
/// "repository". Sentence embeddings were tried and couldn't tell a fitting tool from noise.
enum ToolPicker {
    static func pick(for request: String, from tools: [(connection: Connection, tool: ConnectedTool)], limit: Int = 5, perService: Int = 3) -> [(connection: Connection, tool: ConnectedTool)] {
        let asked = words(in: request)
        let things = words(in: nouns(in: request))
        guard !asked.isEmpty else { return [] }
        let scored = tools.enumerated().compactMap { index, entry -> (index: Int, score: Int)? in
            let score = score(asked, things, entry.connection, entry.tool)
            return score > 0 ? (index, score) : nil
        }
        var perConnection: [UUID: Int] = [:]
        var picked: [(connection: Connection, tool: ConnectedTool)] = []
        for (index, _) in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }) {
            let entry = tools[index]
            guard perConnection[entry.connection.id, default: 0] < perService else { continue }
            perConnection[entry.connection.id, default: 0] += 1
            picked.append(entry)
            if picked.count == limit { break }
        }
        return picked
    }

    /// Each word the request shares counts once, by where it's found: the service's name, what
    /// the tool says it does, or the tool's own name.
    private static func score(_ asked: Set<String>, _ things: Set<String>, _ connection: Connection, _ tool: ConnectedTool) -> Int {
        let service = words(in: connection.name).union(words(in: connection.host).subtracting(hostWords))
        let described = words(in: tool.summary).union(words(in: tool.title ?? ""))
        let named = words(in: tool.name)
        let naming = asked.filter { matches($0, service) }
        return naming.count * 3 + things.subtracting(naming).reduce(0) { total, word in
            if matches(word, described) { return total + 2 }
            if matches(word, named) { return total + 1 }
            return total
        }
    }

    /// The request's nouns and names, and anything the tagger doesn't know, like swift-sdk.
    private static func nouns(in request: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = request
        var kept: [String] = []
        tagger.enumerateTags(in: request.startIndex..<request.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == nil || tag == .noun || tag == .otherWord || request[range].contains(where: { $0.isNumber || $0.isUppercase }) {
                kept.append(String(request[range]))
            }
            return true
        }
        // Names joined with - or /, like swift-sdk and owner/repo, count even when the tagger
        // reads their parts as other kinds of words.
        kept += request.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("-") || $0.contains("/") }
        return kept.joined(separator: " ")
    }

    /// Whether the request asks to do something, not only to know something: only then are
    /// tools that change things worth turning into buttons.
    static func asksToAct(_ request: String) -> Bool {
        // Only as verbs: "my open issues" and "my notes" ask nothing to be done.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let text = request.lowercased()
        tagger.string = text
        var acts = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = String(text[range])
            if tag == .verb, actWords.contains(where: { word == $0 || (word.hasPrefix($0) && word.count <= $0.count + 3) }) { acts = true }
            return !acts
        }
        return acts
    }

    private static let actWords: [String] = [
        "add", "append", "create", "save", "store", "post", "send", "log", "record", "file", "put", "write", "note",
        "remind", "schedule", "book", "update", "change", "edit", "rename", "move", "assign", "close", "complete",
        "finish", "mark", "delete", "remove", "archive", "cancel", "comment", "reply", "invite", "upload", "publish",
        "open", "start", "track", "set", "make", "turn",
    ]

    private static func matches(_ word: String, _ words: Set<String>) -> Bool {
        if words.contains(word) { return true }
        guard word.count >= 4 else { return false }
        return words.contains { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }
    }

    /// Content words, lowercased and roughly singular. Names are split where they join words:
    /// repoName, read_wiki and swift-sdk each give two.
    static func words(in text: String) -> Set<String> {
        var spaced = ""
        var previous: Character?
        for character in text {
            if let previous, previous.isLowercase, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        let tokens = spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(tokens.compactMap { token in
            guard token.count >= 3, !commonWords.contains(token) else { return nil }
            let singular = token.hasSuffix("ies") && token.count > 4 ? String(token.dropLast(3)) + "y"
                : token.hasSuffix("s") && !token.hasSuffix("ss") && token.count > 3 ? String(token.dropLast()) : token
            return commonWords.contains(singular) ? nil : singular
        })
    }

    /// Parts of a host that say nothing about the service.
    private static let hostWords: Set<String> = ["mcp", "www", "com", "org", "net", "app", "api", "dev", "cloud", "server", "remote", "sse"]

    /// Words too common in requests or in tools to say a tool fits.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "about", "over", "under", "between", "than", "then", "that",
        "this", "these", "those", "there", "here", "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "are", "was", "were", "been", "being", "have", "has", "had", "having", "does", "did", "done", "can", "could", "should",
        "would", "will", "shall", "may", "might", "must", "not", "yes", "its", "you", "your", "yours", "our", "ours", "they",
        "them", "their", "his", "her", "hers", "she", "him", "all", "any", "some", "each", "every", "more", "most", "much",
        "many", "few", "other", "such", "only", "own", "same", "too", "very", "just", "also", "like", "want", "need", "know",
        "help", "please", "tell", "explain", "show", "give", "make", "made", "take", "get", "got", "use", "used", "using",
        "work", "way", "thing", "something", "anything", "everything", "one", "two", "new", "find", "list", "search", "read",
        "view", "fetch", "return", "query", "look", "see", "ask", "question", "answer", "information", "info", "data", "content",
        "detail", "result", "tool", "item", "name", "value", "type", "number", "text", "string", "object", "field", "based",
        "specific", "given", "provided", "provide", "available", "optional", "required", "default", "format", "via", "per",
        "within", "without", "including", "include", "contain", "current", "able", "let", "lets", "now", "today", "good",
    ]
}

// MARK: - What may be sent

/// Finds what's personal in a call: details Dream remembers about the user, or entries from their
/// lists, which the model may have put in its arguments. Such a call is always shown to the user
/// first, naming them. Words the request itself uses don't count: the user chose to say them.
enum PersonalCheck {
    /// The details these arguments would carry that the request didn't say.
    static func carried(in arguments: JSONValue, details: [PersonalDetail], request: String) -> [PersonalDetail] {
        let sent = " " + plain(arguments.strings.joined(separator: " ")) + " "
        let said = " " + plain(request) + " "
        var seen: Set<String> = []
        return details.filter { detail in
            let whole = plain(detail.text)
            guard seen.insert(whole).inserted else { return false }
            guard whole.count >= 3 else { return false }
            if sent.contains(" \(whole) ") && !said.contains(" \(whole) ") { return true }
            // A part of a short detail is enough: "Pune" from "Pune, Maharashtra". A single word
            // from a sentence, like "Apple" from "Software engineer at Apple", says too little.
            let parts = whole.split(separator: " ")
            return parts.count <= 3 && parts.contains { part in
                part.count >= 4 && !part.allSatisfy(\.isNumber) && sent.contains(" \(part) ") && !said.contains(" \(part) ")
            }
        }
    }

    /// Lowercased, without accents or punctuation, so "Zürich," matches "zurich".
    private static func plain(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
