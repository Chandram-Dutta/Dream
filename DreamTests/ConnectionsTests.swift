import Foundation
import FoundationModels
import Testing
@testable import Dream

// Connected services without a model or a network: schemas, picking tools, when Dream asks
// first and what each answer does, readings and the lists they fill, service buttons, services a
// request names, and what sharing leaves out. A stand-in answers like the local test server
// (Tools/mcp-test-server.py), in the process; Tools/connections.sh still talks to the real one
// through the MCP SDK.

/// The local test server's tools, answered in the process: one more task each time the tasks are
/// listed, so a refresh visibly changes, and "Done." for anything that changes something.
final class TeamNotes: @unchecked Sendable {
    static let name = "Team Notes"
    static let titles = ["Book the venue", "Send the agenda", "Order lunch", "Print badges", "Plan the dinner"]

    let server: URL
    private let lock = NSLock()
    private var current: [Connection]
    private var sent: [(tool: String, arguments: JSONValue)] = []
    private var listings = 0

    /// Each test gets its own address, so readings kept by the live layer aren't shared.
    init(port: Int) {
        server = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var connection = Connection(url: server, name: Self.name)
        connection.tools = Self.tools
        current = [connection]
    }

    var connections: [Connection] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var connection: Connection { connections[0] }

    func tool(_ name: String) -> ConnectedTool { connection.tools.first { $0.name == name }! }

    /// What each call of a tool sent.
    func calls(of tool: String) -> [JSONValue] {
        lock.withLock { sent.filter { $0.tool == tool }.map(\.arguments) }
    }

    func call(_ tool: String, _ arguments: JSONValue) -> ToolResult {
        lock.withLock {
            sent.append((tool, arguments))
            switch tool {
            case "list_tasks":
                listings += 1
                return Self.tasks(2 + listings)
            case "add_task", "delete_note", "append_note":
                return ToolResult(text: "Done.", structured: nil, isError: false)
            default:
                return ToolResult(text: "Note 'Offsite 2026': The team offsite budget is $4,200 in total, for 12 people.", structured: nil, isError: false)
            }
        }
    }

    /// Dream's connections, as the app sets them up at launch.
    func connect(personal: [PersonalDetail] = []) {
        Connections.source = Connections.Source(
            connections: { self.connections },
            call: { _, tool, arguments in self.call(tool, arguments) },
            personalDetails: { personal },
            allowAlways: { id, tool in
                guard let index = self.connections.firstIndex(where: { $0.id == id }) else { return }
                if let tool, let at = self.connections[index].tools.firstIndex(where: { $0.name == tool }) {
                    self.connections[index].tools[at].alwaysAllowed = true
                } else if tool == nil {
                    self.connections[index].alwaysLooksUp = true
                }
            })
        Connections.registerLive()
    }

    /// What list_tasks returns with this many tasks: the first is done.
    static func tasks(_ count: Int) -> ToolResult {
        let tasks: [JSONValue] = (1...count).map { i in
            .object(["id": .string("T\(i)"), "title": .string(titles[(i - 1) % titles.count]), "done": .bool(i == 1),
                     "due_date": .string("2026-11-0\(i)"), "points": .number(Double(i * 2))])
        }
        let data = JSONValue.object(["open": .number(Double(count - 1)), "tasks": .array(tasks)])
        return ToolResult(text: data.jsonString, structured: data, isError: false)
    }

    static func reading(tasks count: Int) -> SourceReading {
        ConnectionReading.make(tasks(count), service: name, tool: "List tasks")
    }

    /// The server's tools, with the hints its annotations give.
    static let tools: [ConnectedTool] = [
        ConnectedTool(name: "list_tasks", title: "List tasks", summary: "List the team's tasks in the user's team notes, with how many are still open.",
                      inputSchema: schema(#"{"type": "object", "properties": {"status": {"enum": ["open", "all"]}}}"#),
                      readOnlyHint: true, destructiveHint: nil, idempotentHint: nil, openWorldHint: nil),
        ConnectedTool(name: "add_task", title: "Add task", summary: "Add a task to the user's team notes.",
                      inputSchema: schema(#"{"type": "object", "properties": {"title": {"type": "string"}, "due_date": {"type": "string", "format": "date"}, "points": {"type": "integer"}}, "required": ["title"]}"#),
                      readOnlyHint: false, destructiveHint: false, idempotentHint: nil, openWorldHint: nil),
        ConnectedTool(name: "search_notes", title: "Search notes", summary: "Search the user's team notes by keyword. Returns matching notes with their text.",
                      inputSchema: schema(##"{"type": "object", "$defs": {"Filters": {"type": "object", "properties": {"folder": {"type": "string", "description": "Folder to search in"}, "since": {"type": ["string", "null"], "format": "date"}}}}, "properties": {"query": {"type": "string", "description": "Keywords to search for"}, "filters": {"$ref": "#/$defs/Filters"}, "tags": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]}, "limit": {"type": "integer", "minimum": 1, "maximum": 20}, "sort": {"enum": ["recent", "relevant"]}, "metadata": {"type": "object", "additionalProperties": {"type": "string"}}}, "required": ["query"]}"##),
                      readOnlyHint: true, destructiveHint: nil, idempotentHint: nil, openWorldHint: nil),
        ConnectedTool(name: "delete_note", title: nil, summary: "Delete a note from the user's team notes.",
                      inputSchema: schema(#"{"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]}"#),
                      readOnlyHint: false, destructiveHint: true, idempotentHint: nil, openWorldHint: nil),
        ConnectedTool(name: "append_note", title: nil, summary: "Add text to one of the user's team notes.",
                      inputSchema: schema(#"{"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}}, "required": ["id", "text"]}"#),
                      readOnlyHint: nil, destructiveHint: nil, idempotentHint: nil, openWorldHint: nil),
        ConnectedTool(name: "tag_notes", title: nil, summary: "Read notes by arbitrary tag map.",
                      inputSchema: schema(#"{"type": "object", "properties": {"tags": {"type": "object", "additionalProperties": true}}, "required": ["tags"]}"#),
                      readOnlyHint: true, destructiveHint: nil, idempotentHint: nil, openWorldHint: nil),
    ]

    private static func schema(_ json: String) -> JSONValue {
        (try? JSONValue(json: json)) ?? .object([:])
    }
}

private let pune = PersonalDetail(text: "Pune, Maharashtra", from: "what Dream knows about you (home city)")

/// A list a service fills, bound to the tasks reading.
private func offsite(declaring reading: SourceReading, notes: TeamNotes) -> Surface {
    var surface = Surface(title: "Offsite tasks", summary: "", symbol: "checklist", accent: .blue,
                          inputs: [Input(name: "open", label: "Open", format: .integer, initial: 0, min: 0, max: 100, step: 1, options: [], role: .live, source: "listTasks.open")],
                          outputs: [Output(name: "points", label: "Points", formula: "sum(tasks.points)", format: .integer)],
                          blocks: [Block(id: "a", kind: .hero, ref: "open"), Block(id: "b", kind: .add, ref: "tasks"), Block(id: "c", kind: .list, ref: "tasks"), Block(id: "d", kind: .metric, ref: "points")],
                          related: [], reference: nil)
    var declared = Source(name: "listTasks", kind: Source.connectionKind, parameters: [
        "service": TeamNotes.name, "server": notes.server.absoluteString, "tool": "list_tasks", "arguments": "{}",
    ], fields: reading.fields)
    declared.lists = ConnectionReading.shapes(reading)
    surface.sources = [declared]
    surface.collections = [RecordCollection(name: "tasks", label: "Tasks", entry: "task", fields: [
        RecordField(name: "title", label: "Task", type: .text),
        RecordField(name: "done", label: "Done", type: .done),
        RecordField(name: "due", label: "Due", type: .date),
        RecordField(name: "points", label: "Points", type: .number),
    ], starters: [["title": .text("Made up")]], source: "listTask.task")]
    return surface
}

/// A service button as it's kept on a page.
private func button(_ tool: String, _ inputs: String, notes: TeamNotes, memory: Bool = false) throws -> ResolvedAction {
    var fields = ["service": TeamNotes.name, "server": notes.server.absoluteString, "tool": tool,
                  "label": notes.connection.tools.first { $0.name == tool }?.title ?? "", "inputs": ConnectionPerformer.encode(try JSONValue(json: inputs))]
    if memory { fields["memory"] = "yes" }
    return ResolvedAction(name: "b", kind: Action.connectionKind, text: fields, start: nil, hasTime: false, minutes: nil)
}

/// Connected services, the consent answerer and the live layer are shared, so these run one at a time.
@Suite("Connections", .serialized)
@MainActor
struct ConnectionsTests {
    @Test("JSON Schemas become generation schemas, or their tool is left out")
    func schemas() throws {
        let rich = try JSONValue(json: ##"{"type":"object","$defs":{"F":{"type":"object","properties":{"folder":{"type":"string"}}}},"properties":{"query":{"type":"string"},"filters":{"$ref":"#/$defs/F"},"tags":{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]},"limit":{"type":"integer","minimum":1,"maximum":20},"sort":{"enum":["recent","relevant"]},"metadata":{"type":"object","additionalProperties":{"type":"string"}}},"required":["query"]}"##)
        #expect(ToolSchema.generationSchema(for: rich, name: "rich") != nil, "a $ref, an anyOf, an enum and an optional free-form map can be filled")
        let unusable = try JSONValue(json: #"{"type":"object","properties":{"tags":{"type":"object","additionalProperties":true}},"required":["tags"]}"#)
        #expect(ToolSchema.generationSchema(for: unusable, name: "unusable") == nil, "a required free-form map can't, so its tool is left out")
    }

    @Test("Tools are offered by what they say they do, and picked by the request")
    func offeringAndPicking() {
        let notes = TeamNotes(port: 9001)
        notes.connect()
        #expect(Set(Connections.lookingTools.map(\.tool.name)) == ["list_tasks", "search_notes", "append_note"], "tools that look things up, or don't say, are offered by relevance alone")
        #expect(Set(Connections.changingTools.map(\.tool.name)) == ["add_task", "delete_note"], "tools that say they change things are offered when asked to act")
        #expect(!Connections.usableTools.contains { $0.tool.name == "tag_notes" }, "a tool whose inputs can't be filled is left out")

        let tasks = ToolPicker.pick(for: "which tasks are still open in my team notes", from: Connections.lookingTools).map(\.tool.name)
        #expect(tasks.contains("list_tasks"), "a request about tasks gets the task tool")
        #expect(ToolPicker.pick(for: "split a restaurant bill between friends", from: Connections.usableTools).isEmpty, "a bill gets nothing")
        for (request, acts) in [("add a task to book the venue", true), ("which tasks are still open", false), ("what's in my team notes", false),
                                ("save the offsite plan to my notes", true), ("create an issue for the login bug", true), ("my open Linear issues", false)] {
            #expect(ToolPicker.asksToAct(request) == acts, "\"\(request)\" \(acts ? "asks" : "doesn't ask") to do something")
        }
    }

    @Test("When Dream asks first, and how")
    func askingFirst() throws {
        let notes = TeamNotes(port: 9002)
        let connection = notes.connection
        let look = ConsentPolicy.request(connection, notes.tool("list_tasks"), values: .object(["status": .string("open")]), personal: [])
        #expect(look?.kind == .lookUp && look?.question == "Let Team Notes look this up?" && look?.always == "Always for Team Notes", "a look-up asks the first time")
        let change = ConsentPolicy.request(connection, notes.tool("add_task"), values: try JSONValue(json: #"{"title": "Book the venue", "due_date": "2026-11-06"}"#), personal: [])
        #expect(change?.kind == .change && change?.question == "Add task in Team Notes?", "a change asks")
        #expect(change?.values == [.init(name: "Due date", text: "2026-11-06"), .init(name: "Title", text: "Book the venue")], "showing exactly what it sends")
        #expect(ConsentPolicy.request(connection, notes.tool("delete_note"), values: .object([:]), personal: [])?.kind == .destroy, "one that may delete says so")
        #expect(ConsentPolicy.request(connection, notes.tool("append_note"), values: .object([:]), personal: [])?.note?.contains("doesn't say") == true, "one whose service doesn't say is asked as a change")
        var trusting = connection
        trusting.alwaysLooksUp = true
        #expect(ConsentPolicy.request(trusting, notes.tool("list_tasks"), values: .object([:]), personal: []) == nil, "after Always, a look-up isn't asked again")
        #expect(ConsentPolicy.request(trusting, notes.tool("add_task"), values: .object([:]), personal: []) != nil, "but a change still is")
        let carried = PersonalCheck.carried(in: .object(["query": .string("notes about Pune")]), details: [pune], request: "notes about my home city")
        let personal = ConsentPolicy.request(trusting, notes.tool("list_tasks"), values: .object(["query": .string("notes about Pune")]), personal: carried)
        #expect(personal?.kind == .personal && personal?.personal == [pune] && personal?.always == nil, "anything personal is always asked, naming it, with no Always")
        #expect(PersonalCheck.carried(in: .object(["query": .string("Pune")]), details: [pune], request: "notes about Pune").isEmpty, "what the request itself says isn't personal")
    }

    @Test("One question shows at a time, and Always answers the look-ups waiting")
    func oneQuestionAtATime() async throws {
        let notes = TeamNotes(port: 9003)
        let connection = notes.connection
        let look = try #require(ConsentPolicy.request(connection, notes.tool("list_tasks"), values: .object(["status": .string("open")]), personal: []))
        let search = try #require(ConsentPolicy.request(connection, notes.tool("search_notes"), values: .object([:]), personal: []))
        let change = try #require(ConsentPolicy.request(connection, notes.tool("add_task"), values: .object(["title": .string("Book the venue")]), personal: []))
        let earlier = Consent.answerer
        Consent.answerer = .user
        defer { Consent.answerer = earlier }
        let waiting = Consent()
        let firstAsk = Task { await waiting.ask(look) }
        let secondAsk = Task { await waiting.ask(search) }
        let thirdAsk = Task { await waiting.ask(change) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(waiting.pending?.question == look.question, "one question shows at a time")
        waiting.answer(.always)
        try await Task.sleep(for: .milliseconds(100))
        let (answered, covered) = (await firstAsk.value, await secondAsk.value)
        #expect(answered == .always && covered == .once, "Always for a service answers its other look-ups waiting too")
        #expect(waiting.pending?.question == change.question, "a change waiting behind them still asks")
        waiting.cancel()
        #expect(await thirdAsk.value == .deny, "leaving the page refuses what's still waiting")
    }

    @Test("Calling, as the model does: each answer does what it says")
    func calling() async throws {
        let notes = TeamNotes(port: 9004)
        notes.connect(personal: [pune])
        let earlier = Consent.answerer
        defer { Consent.answerer = earlier }
        let live = LiveLog()
        let log = ConnectionLog()
        func call(_ name: String, _ json: String, answer: ConsentAnswer) async throws -> String {
            Consent.answerer = .automatic(answer)
            let entry = try #require(Connections.usableTools.first { $0.tool.name == name })
            let parameters = try #require(ToolSchema.generationSchema(for: entry.tool.inputSchema, name: "t"))
            let tool = ConnectionTool(name: "t", description: "", parameters: parameters, connection: entry.connection,
                                      tool: entry.tool, request: "", asking: Asking(), consent: Consent(), live: live, log: log)
            return try await tool.call(arguments: try GeneratedContent(json: json))
        }
        let offered = ConnectionTool.offered(for: "add a task to book the venue in my team notes", asking: Asking(), consent: Consent(), live: live, log: log, onUse: { _ in })
            .compactMap { $0 as? ConnectionTool }.map(\.tool.name)
        #expect(offered.contains("add_task"), "asked to act, a change is offered as a tool to call")
        #expect(!log.problems(in: Surface.empty).isEmpty, "and if the model never calls it, that goes back to it")
        let refused = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .deny)
        #expect(refused.contains("didn't allow") && notes.calls(of: "add_task").isEmpty, "Don't allow sends nothing, and tells the model plainly")
        let added = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .once)
        #expect(notes.calls(of: "add_task").count == 1 && added.contains("It's done"), "Allow once runs it, and the model is told it's done")
        #expect(notes.tool("add_task").alwaysAllowed == false, "and asks again next time")
        let looked = try await call("list_tasks", "{}", answer: .always)
        #expect(notes.connection.alwaysLooksUp && live.sources.contains { $0.name == "listTasks" }, "Always is kept, and the look-up becomes a live source")
        #expect(looked.contains("Dream keeps these current"), "which the model is told how to show")
        #expect(log.problems(in: Surface.empty).isEmpty, "a change that was tried isn't sent back as missing")
    }

    @Test("A look-up the user allows always is read again as a live source")
    func readingAgain() async throws {
        let notes = TeamNotes(port: 9005)
        notes.connect()
        let source = Source(name: "listTasks", kind: Source.connectionKind, parameters: [
            "service": TeamNotes.name, "server": notes.server.absoluteString, "tool": "list_tasks", "arguments": "{}",
        ], fields: [])
        await #expect(throws: (any Error).self, "without Always, a page doesn't read a service again by itself") {
            try await LiveSources.read(source, again: true)
        }
        notes.connections[0].alwaysLooksUp = true
        let first = try await LiveSources.read(source, again: true)
        let count = first.field("tasksCount")?.value ?? 0
        #expect(count >= 3 && first.field("open")?.value == count - 1, "numbers become fields")
        #expect(first.lists["tasks"]?.count == Int(count), "a list of objects becomes rows")
        let shapes = ConnectionReading.shapes(first)
        #expect(shapes.first?.keys.contains("dueDate") == true, "row keys are camelCase")
        let readsBefore = notes.calls(of: "list_tasks").count
        _ = try await LiveSources.read(source)
        #expect(notes.calls(of: "list_tasks").count == readsBefore, "a fresh reading is kept, so the screen's first read doesn't ask again")
        let again = try await LiveSources.read(source, again: true)
        #expect(notes.calls(of: "list_tasks").count == readsBefore + 1 && again.field("tasksCount")?.value == count + 1, "a pull asks the service again, without the model")

        let shared = Source(name: "listTasks", kind: Source.connectionKind, parameters: ["service": TeamNotes.name], fields: [])
        await #expect(throws: (any Error).self, "a source from someone else's page isn't read") {
            try await LiveSources.read(shared)
        }
        #expect(notes.calls(of: "list_tasks").count == readsBefore + 1, "and nothing was asked of the service")
    }

    @Test("A list a service fills takes its rows as entries")
    func serviceList() throws {
        let notes = TeamNotes(port: 9006)
        notes.connect()
        let first = TeamNotes.reading(tasks: 3)
        let again = TeamNotes.reading(tasks: 4)
        let count = try #require(first.field("tasksCount")?.value)
        var surface = offsite(declaring: first, notes: notes)
        let issues = Checker.checkLogic(&surface)
        #expect(!issues.contains { $0.kind == .needsModel }, "it checks")
        #expect(surface.collection("tasks")?.source == "listTasks.tasks", "a near-miss list is read as the one it means")
        #expect(surface.collection("tasks")?.starters.isEmpty == true, "it has no starters")
        #expect(!surface.blocks.contains { $0.kind == .add }, "nobody adds to it here")
        let entries = surface.serviceRecords(again, from: "listTasks")["tasks"] ?? []
        #expect(entries.count == Int(count) + 1 && entries.first?["title"] == .text("Book the venue") && entries.first?.isOn("done") == true, "rows become entries, by field name")
        #expect(entries.count > 1 && entries[1]["due"]?.numberValue != nil, "a due_date fills a date field named due")
        let firstEntries = surface.serviceRecords(first, from: "listTasks")["tasks"] ?? []
        #expect(Array(entries.prefix(firstEntries.count).map(\.id)) == firstEntries.map(\.id), "an entry keeps its id from one reading to the next")
        let total = surface.evaluate(["open": 3], records: ["tasks": entries]).values["points"]
        let expected = entries.compactMap { $0["points"]?.numberValue }.reduce(0, +)
        #expect(total == expected && expected > 0, "totals over a service's list work")
        #expect(surface.keepingOwnLists.collections == nil, "talking to lists leaves a service's alone")
        var unbound = surface
        unbound.collections?[0].source = "nothing.here"
        #expect(Checker.checkLogic(&unbound).contains { $0.kind == .needsModel }, "a list no service returned goes back to the model")
    }

    @Test("Buttons already on a page say what they do, and a tap sends exactly that")
    func buttons() async throws {
        let notes = TeamNotes(port: 9007)
        notes.connect()
        let performer = try #require(LiveActions.performer(Action.connectionKind), "service buttons have a performer")
        let add = try button("add_task", #"{"title": "Book the venue for $4,200 {all}", "points": 3}"#, notes: notes)
        #expect(performer.sentence(add) == "Add task in Team Notes", "it says what it does")
        #expect(performer.details(add) == ["Points: 3", "Title: Book the venue for $4,200 {all}"], "and with which values, exactly")
        #expect(performer.needsConfirmation(add) == false, "a tap is the user's word, so a plain change goes on the tap")
        #expect(performer.needsConfirmation(try button("delete_note", #"{"id": "1"}"#, notes: notes)) == true, "one that may delete asks first")
        #expect(performer.needsConfirmation(try button("append_note", #"{"id": "1", "text": "x"}"#, notes: notes)) == true, "so does one whose service doesn't say")
        #expect(performer.needsConfirmation(try button("add_task", #"{"title": "Visit Pune"}"#, notes: notes, memory: true)) == true, "and one carrying something personal")
        let done = try await performer.perform(add)
        let sent = notes.calls(of: "add_task")
        #expect(sent.count == 1 && sent.last?["title"] == .string("Book the venue for $4,200 {all}") && sent.last?["points"] == .number(3), "the tap sends exactly that")
        #expect(done.message == "Done in Team Notes", "and says it's done")
    }

    @Test("Services a request names, but the user hasn't connected, are suggested")
    func servicesNamed() throws {
        let notes = TeamNotes(port: 9008)
        notes.connect()
        let earlier = Connections.directory
        defer { Connections.directory = earlier }
        Connections.directory = try JSONDecoder().decode([DirectoryEntry].self, from: Data(#"""
            [{"id": "app.linear/linear", "name": "Linear", "summary": "Your issues.", "url": "https://mcp.linear.app/mcp", "signIn": true, "aliases": [], "featured": true},
             {"id": "com.atlassian/atlassian-mcp-server", "name": "Atlassian", "summary": "Jira and Confluence.", "url": "https://mcp.atlassian.com/v1/mcp", "signIn": true, "aliases": ["Jira", "Confluence"], "featured": true},
             {"id": "local/team-notes", "name": "Team Notes", "summary": "", "url": "\#(notes.server.absoluteString)", "signIn": false, "aliases": [], "featured": true}]
            """#.utf8))
        for (request, names) in [("my Linear issues", ["Linear"]), ("what's on my linear board", ["Linear"]), ("explain linear regression in linear algebra", []),
                                 ("summarise the sprint in Jira", ["Atlassian"]), ("what's in my team notes", []), ("Linear vs Jira for a small team", []),
                                 ("add the plan to Linear", ["Linear"])] {
            #expect(Connections.unconnected(in: request).map(\.name) == names, "\"\(request)\" \(names.isEmpty ? "suggests nothing" : "suggests connecting \(names.joined(separator: ", "))")")
        }
    }

    @Test("Sharing leaves a service's buttons and address behind")
    func sharing() throws {
        let notes = TeamNotes(port: 9009)
        notes.connect()
        let first = TeamNotes.reading(tasks: 3)
        var page = offsite(declaring: first, notes: notes)
        _ = Checker.checkLogic(&page)
        let add = try button("add_task", #"{"title": "Book the venue", "points": 3}"#, notes: notes)
        page.services = [TeamNotes.name]
        page.actions = [Action(name: "addTask", kind: Action.connectionKind, fields: add.text),
                        Action(name: "remind", kind: "reminder", fields: ["title": "Offsite"])]
        page.blocks.append(Block(id: "e", kind: .section, title: "Do", children: [Block(id: "f", kind: .action, ref: "addTask")]))
        page.blocks.append(Block(id: "g", kind: .action, ref: "remind"))
        let outgoing = SharedSurface(sharing: page, values: nil).surface
        #expect(outgoing.actions?.map(\.name) == ["remind"], "a service's buttons don't travel, others do")
        #expect(!outgoing.blocks.contains { $0.id == "e" || $0.id == "f" }, "nor do their blocks")
        #expect(outgoing.sources?.first?.parameters == ["service": "Team Notes"], "a source keeps only the service's name")
        #expect(outgoing.sources?.first?.fields == first.fields, "and the values the user chose to share")
        #expect(outgoing.services == ["Team Notes"], "the page still says which service's data is in it")
        let json = try SharedSurface.encoder.encode(SharedSurface(sharing: page, values: nil))
        #expect(!String(decoding: json, as: UTF8.self).contains("127.0.0.1"), "the service's address isn't in what's shared")
        var crafted = page
        crafted.services = nil
        let received = try SharedSurface.received(try SharedSurface.encoder.encode(SharedSurface(format: 1, surface: crafted, values: nil, currency: nil, preview: nil)))
        #expect(received.surface.actions?.contains { $0.isConnection } != true, "a shared page can't bring a button for the reader's services")
        #expect(received.surface.sources?.first?.parameters["server"] == nil, "nor a source that would ask them anything")
    }
}
