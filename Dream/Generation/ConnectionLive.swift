import Foundation

// Connected services as live data and actions (ROADMAP.md, workstream 8). A read tool the
// model calls while writing is a source the screen reads again when it opens and on a pull,
// without writing anything anew: the call itself declares it, as the live tool's do. A write
// tool the model calls isn't run: the call becomes a button that runs it only when tapped.

extension Connections {
    /// Connects services to the live layer: their read tools as a provider, their write tools
    /// as a performer. The app does it at launch; the bench when it connects servers.
    static func registerLive() {
        LiveSources.register(ConnectionProvider())
        LiveActions.register(ConnectionPerformer())
    }

    /// The connection a template names, by its server's address.
    static func connection(at server: String) -> Connection? {
        source.connections().first { $0.url.absoluteString == server }
    }
}

// MARK: - Reading

/// Reads a connected service's read tool again with the arguments it was first called with.
/// A source from someone else's page names only the service, so it's never read here: the
/// reader's own services aren't asked anything a stranger wrote.
struct ConnectionProvider: LiveProvider {
    let kind = Source.connectionKind
    /// A service's items change through the day; a screen open longer reads them again.
    let freshness: TimeInterval = 10 * 60

    func read(_ source: Source) async throws -> SourceReading {
        let service = source["service"].isEmpty ? "the service" : source["service"]
        guard !source["server"].isEmpty, !source["tool"].isEmpty else {
            throw LiveError(.unavailable, "This came from someone else's \(service), so Dream doesn't read it here.")
        }
        guard let connection = Connections.connection(at: source["server"]) else {
            throw LiveError(.unavailable, "Connect \(service) in Connections to keep this current.")
        }
        guard let tool = connection.tools.first(where: { $0.name == source["tool"] }), tool.readsOnly else {
            throw LiveError(.unavailable, "\(service) no longer offers this to read.")
        }
        let arguments = (try? JSONValue(json: source["arguments"])) ?? .object([:])
        let carrying: Set<Connections.Personal> = source["memory"] == "yes" ? [.memory] : []
        let result: ToolResult
        do {
            result = try await Connections.call(tool.name, on: connection.id, arguments: arguments, carrying: carrying)
        } catch let error as ConnectionError {
            throw LiveError(.unavailable, error.problem(for: connection.name))
        }
        guard !result.isError else {
            throw LiveError(.unavailable, "\(connection.name) didn't answer this time.")
        }
        ConnectionResults.keep(result, for: source)
        return ConnectionReading.make(result, service: connection.name, tool: tool.label)
    }
}

/// The last thing each source's tool returned, whole, so the model's call while writing reads
/// the service once: through the live layer, which keeps the reading for the screen, and then
/// here for the text the model builds from.
enum ConnectionResults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var results: [String: ToolResult] = [:]

    static func keep(_ result: ToolResult, for source: Source) {
        lock.withLock { results[key(source)] = result }
    }

    static func result(for source: Source) -> ToolResult? {
        lock.withLock { results[key(source)] }
    }

    private static func key(_ source: Source) -> String {
        source.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}

/// What a tool returned, as live values: every number in its structured content (or in text
/// that is JSON) as a field, how many items each list holds, and the lists themselves, whose
/// rows collections can show. Text that isn't JSON has no values to keep current.
enum ConnectionReading {
    static let fieldLimit = 30
    static let rowLimit = 100

    static func make(_ result: ToolResult, service: String, tool: String) -> SourceReading {
        var fields: [SourceField] = []
        var lists: [String: [[String: RecordValue]]] = [:]
        func visit(_ value: JSONValue, path: [String], depth: Int) {
            guard fields.count < fieldLimit else { return }
            switch value {
            case .number(let number):
                fields.append(SourceField(name: name(path, or: "value"), value: number, format: .number, meaning: words(path)))
            case .bool(let flag):
                fields.append(SourceField(name: name(path, or: "value"), value: flag ? 1 : 0, format: .toggle, meaning: words(path)))
            case .object(let object) where depth < 3:
                for key in object.keys.sorted() { visit(object[key]!, path: path + [key], depth: depth + 1) }
            case .array(let items):
                let list = name(path, or: "items")
                fields.append(SourceField(name: name(path + ["count"], or: "count"), value: Double(items.count), format: .integer, meaning: "how many in \(words(path).isEmpty ? "the list" : words(path))"))
                let rows = items.prefix(rowLimit).compactMap { $0.object.map(row) }
                if !rows.isEmpty, lists.count < 5 { lists[list] = rows }
            default:
                break
            }
        }
        if let data = result.structured ?? (try? JSONValue(json: result.text.trimmingCharacters(in: .whitespacesAndNewlines))) {
            visit(data, path: [], depth: 0)
        }
        return SourceReading(fields: fields, summary: "\(service) · \(tool)", asOf: .now, lists: lists)
    }

    /// The shapes of the lists in a reading, for the template.
    static func shapes(_ reading: SourceReading) -> [SourceList] {
        reading.lists.keys.sorted().map { name in
            let rows = reading.lists[name] ?? []
            var counts: [String: Int] = [:]
            for row in rows { for key in row.keys { counts[key, default: 0] += 1 } }
            let keys = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(20).map(\.key)
            return SourceList(name: name, keys: keys, count: rows.count)
        }
    }

    /// One row: its plain values by camelCase key, with a nested object's values beside them
    /// (state.name as stateName) and a list of words as one text.
    private static func row(_ object: [String: JSONValue]) -> [String: RecordValue] {
        var values: [String: RecordValue] = [:]
        func add(_ value: JSONValue, as key: String, nested: Bool) {
            switch value {
            case .string(let text): values[key] = .text(String(text.prefix(500)))
            case .number(let number): values[key] = .number(number)
            case .bool(let flag): values[key] = .number(flag ? 1 : 0)
            case .array(let items):
                let words = items.compactMap(\.string)
                if !words.isEmpty, words.count == items.count { values[key] = .text(words.joined(separator: ", ")) }
            case .object(let inner) where !nested:
                for (innerKey, innerValue) in inner { add(innerValue, as: name([key, innerKey], or: key), nested: true) }
            default:
                break
            }
        }
        for (key, value) in object.prefix(40) { add(value, as: name([key], or: "value"), nested: false) }
        return values
    }

    /// A path as one camelCase name: ["due_date"] is dueDate, ["budget", "total"] budgetTotal.
    static func name(_ path: [String], or fallback: String) -> String {
        let words = path.flatMap { $0.split { !$0.isLetter && !$0.isNumber }.map(String.init) }.flatMap(splitCamel)
        guard let first = words.first else { return fallback }
        var name = first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
        if name.first?.isNumber == true { name = "n" + name }
        return name
    }

    private static func words(_ path: [String]) -> String {
        path.flatMap { $0.split { !$0.isLetter && !$0.isNumber }.map(String.init) }.flatMap(splitCamel).map { $0.lowercased() }.joined(separator: " ")
    }

    private static func splitCamel(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in word {
            if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Acting

/// Runs a connected service's write tool, only when its button is tapped, with exactly the
/// values the button shows. A tool that may delete, or whose service doesn't say what it does,
/// asks once more; and the service must be allowed whatever personal data the values carry.
struct ConnectionPerformer: ActionPerformer {
    let kind = Action.connectionKind
    let symbol = "paperplane.fill"

    func sentence(_ action: ResolvedAction) -> String {
        "\(action["label"].isEmpty ? Self.words(action["tool"]) : action["label"]) in \(action["service"])"
    }

    /// Every value it sends, by name, then the tool itself when its label differs.
    func details(_ action: ResolvedAction) -> [String] {
        let inputs = (Self.inputs(action).object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            "\(Self.words(key)): \(value.string ?? value.jsonString)"
        }
        let tool = action["label"].isEmpty || Self.words(action["tool"]) == action["label"] ? [] : ["Tool: \(action["tool"])"]
        return inputs + tool
    }

    func needsConfirmation(_ action: ResolvedAction) -> Bool {
        guard let tool = Self.tool(for: action) else { return true }
        return tool.needsConfirmation || action["memory"] == "yes"
    }

    func perform(_ action: ResolvedAction) async throws -> ActionDone {
        let service = action["service"]
        guard let connection = Connections.connection(at: action["server"]), let tool = Self.tool(for: action) else {
            throw LiveError(.unavailable, "Connect \(service) in Connections to do this.")
        }
        let arguments = Self.inputs(action)
        // Whether the values carry something Dream remembers was found when the button was
        // made, against what the user asked; the service must still be allowed it now.
        let carrying: Set<Connections.Personal> = action["memory"] == "yes" ? [.memory] : []
        let result: ToolResult
        do {
            result = try await Connections.call(tool.name, on: connection.id, arguments: arguments, carrying: carrying)
        } catch let error as ConnectionError {
            throw LiveError(.unavailable, error.problem(for: connection.name))
        } catch {
            throw LiveError(.unavailable, "\(connection.name) didn't do it.")
        }
        guard !result.isError else {
            let said = result.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            throw LiveError(.unavailable, said.isEmpty ? "\(connection.name) didn't do it." : "\(connection.name) didn't do it: \(said)")
        }
        return ActionDone(message: "Done in \(connection.name)")
    }

    private static func tool(for action: ResolvedAction) -> ConnectedTool? {
        Connections.connection(at: action["server"])?.tools.first { $0.name == action["tool"] && $0.isOn }
    }

    /// The tool's inputs as the model gave them, kept whole in one field. Text in an action's
    /// fields is read for {name}s and $maths$, which a note's own braces and dollar amounts
    /// would trip; encoded, the button sends exactly what it shows.
    static func encode(_ inputs: JSONValue) -> String {
        Data(inputs.jsonString.utf8).base64EncodedString()
    }

    static func inputs(_ action: ResolvedAction) -> JSONValue {
        guard let data = Data(base64Encoded: action["inputs"]), let inputs = try? JSONValue(json: String(decoding: data, as: UTF8.self)) else {
            return .object([:])
        }
        return inputs
    }

    /// due_date or dueDate as "Due date".
    static func words(_ name: String) -> String {
        let spaced = ConnectionReading.name([name], or: name)
        var result = ""
        for character in spaced {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(contentsOf: character.lowercased())
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

extension Action {
    /// A connected service's button in the outline's shorthand: what it runs, with its values
    /// written out rather than encoded.
    var connectionOutline: String {
        let resolved = ResolvedAction(name: name, kind: kind, text: fields, start: nil, hasTime: false, minutes: nil)
        return "\(self["service"]) tool \(self["tool"]) with \(ConnectionPerformer.inputs(resolved).jsonString) (change it by calling the tool again)"
    }
}

extension ConnectionError {
    /// What went wrong, for under a button or beside a value.
    func problem(for service: String) -> String {
        switch self {
        case .notAllowed: "\(service) isn't allowed to receive what this sends. You can allow it in Connections."
        case .needsSignIn: "Sign in to \(service) in Connections first."
        case .off, .toolOff: "\(service) is switched off in Connections."
        default: errorDescription ?? "\(service) didn't answer."
        }
    }
}

// MARK: - While writing

/// What writing with connected services leaves the surface: buttons proposed for write tools,
/// and which services' data went into it.
final class ConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var proposed: [Action] = []
    private var earlier: [Action] = []
    private var used: [String] = []
    /// The write tools offered because the request asks to do something, by the names the
    /// model calls them.
    private var offered: [String] = []

    /// A new request starts with nothing; a change keeps what the screen already has.
    func start(keeping surface: Surface? = nil) {
        lock.withLock {
            proposed = []
            earlier = (surface?.actions ?? []).filter(\.isConnection)
            used = surface?.services ?? []
            offered = []
        }
    }

    func offer(_ tools: [String]) {
        lock.withLock { offered = tools }
    }

    /// What goes back to the model with the checker's problems: the request asks to do
    /// something a service's tool does, and no button does it, because its tool was never
    /// called. Models often write a reminder in its place instead.
    func problems(in surface: Surface) -> [Issue] {
        let (offered, proposed) = lock.withLock { (offered, proposed) }
        guard !offered.isEmpty, proposed.isEmpty, !(surface.actions ?? []).contains(where: \.isConnection) else { return [] }
        return [Issue(kind: .needsModel, message: "The request asks to do something in a connected service, but no button does it, because you didn't call \(offered.joined(separator: " or ")). Call it now with the values to send: that makes the button. Show it with an action block whose ref is the name the call gives, and drop any other action standing in for it.")]
    }

    func propose(_ action: Action) {
        lock.withLock {
            proposed.removeAll { $0.name == action.name }
            earlier.removeAll { $0.name == action.name }
            proposed.append(action)
        }
    }

    func use(_ service: String) {
        lock.withLock { if !used.contains(service) { used.append(service) } }
    }

    /// A name no other button has.
    func name(for base: String) -> String {
        lock.withLock {
            let taken = Set((proposed + earlier).map(\.name))
            var name = base
            var number = 2
            while taken.contains(name) {
                name = "\(base)\(number)"
                number += 1
            }
            return name
        }
    }

    fileprivate var state: (proposed: [Action], earlier: [Action], used: [String]) {
        lock.withLock { (proposed, earlier, used) }
    }
}

extension Surface {
    /// With the buttons proposed while it was written, those it had that it still shows, and
    /// the services whose data it holds.
    func connected(_ log: ConnectionLog) -> Surface {
        var surface = self
        let (proposed, earlier, used) = log.state
        let shown = Self.actionRefs(in: blocks)
        let added = proposed + earlier.filter { shown.contains($0.name) }
        // An action the model wrote under a proposed button's name is its attempt to define
        // that button, which the call already did.
        let names = Set(added.map(\.name))
        let own = (actions ?? []).filter { !$0.isConnection && !names.contains($0.name) }
        let all = own + added
        surface.actions = all.isEmpty ? nil : all
        surface.services = used.isEmpty ? nil : used
        return surface
    }

    private static func actionRefs(in blocks: [Block]) -> Set<String> {
        blocks.reduce(into: []) { refs, block in
            if block.kind == .action { refs.insert(block.ref) }
            refs.formUnion(actionRefs(in: block.children))
        }
    }
}
