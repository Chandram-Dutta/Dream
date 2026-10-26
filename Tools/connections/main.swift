import Foundation
import FoundationModels

// Connected services, checked without a model against the local test server. Run with
// Tools/connections.sh, which starts the server and passes its address and log.

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("  ✓ \(message)") } else { failures += 1; print("  ✗ \(message)") }
}

let server = URL(string: CommandLine.arguments[1])!
let serverLog = URL(filePath: CommandLine.arguments[2])
func calls(of tool: String) -> [String] {
    ((try? String(contentsOf: serverLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.contains("\"name\": \"\(tool)\"") }
}

/// The connections as the test changes them, readable from anywhere.
final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [Connection] = []
    var connections: [Connection] {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
let fixture = Fixture()

print("Schemas")
let rich = try JSONValue(json: ##"{"type":"object","$defs":{"F":{"type":"object","properties":{"folder":{"type":"string"}}}},"properties":{"query":{"type":"string"},"filters":{"$ref":"#/$defs/F"},"tags":{"anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]},"limit":{"type":"integer","minimum":1,"maximum":20},"sort":{"enum":["recent","relevant"]},"metadata":{"type":"object","additionalProperties":{"type":"string"}}},"required":["query"]}"##)
expect(ToolSchema.generationSchema(for: rich, name: "rich") != nil, "a $ref, an anyOf, an enum and an optional free-form map can be filled")
let unusable = try JSONValue(json: #"{"type":"object","properties":{"tags":{"type":"object","additionalProperties":true}},"required":["tags"]}"#)
expect(ToolSchema.generationSchema(for: unusable, name: "unusable") == nil, "a required free-form map can't, so its tool is left out")

print("Connecting")
var notes = Connection(url: server, name: server.host() ?? "")
let described = try await ConnectionSessions.shared.describe(server, id: notes.id)
notes.name = described.name
notes.tools = described.tools
fixture.connections = [notes]
let pune = PersonalDetail(text: "Pune, Maharashtra", from: "what Dream knows about you (home city)")
Connections.source = Connections.Source(
    connections: { fixture.connections },
    call: { connection, tool, arguments in try await ConnectionSessions.shared.call(connection, tool: tool, arguments: arguments) },
    personalDetails: { [pune] },
    allowAlways: { id, tool in
        guard let index = fixture.connections.firstIndex(where: { $0.id == id }) else { return }
        if let tool, let at = fixture.connections[index].tools.firstIndex(where: { $0.name == tool }) {
            fixture.connections[index].tools[at].alwaysAllowed = true
        } else if tool == nil {
            fixture.connections[index].alwaysLooksUp = true
        }
    })
Connections.registerLive()
expect(notes.name == "Team Notes", "the server says what it's called: \(notes.name)")
expect(Set(Connections.lookingTools.map(\.tool.name)) == ["list_tasks", "search_notes", "append_note"], "tools that look things up, or don't say, are offered by relevance alone")
expect(Set(Connections.changingTools.map(\.tool.name)) == ["add_task", "delete_note"], "tools that say they change things are offered when asked to act")
expect(!Connections.usableTools.contains { $0.tool.name == "tag_notes" }, "a tool whose inputs can't be filled is left out")

print("Picking")
let tasks = ToolPicker.pick(for: "which tasks are still open in my team notes", from: Connections.lookingTools).map(\.tool.name)
expect(tasks.contains("list_tasks"), "a request about tasks gets the task tool: \(tasks)")
expect(ToolPicker.pick(for: "split a restaurant bill between friends", from: Connections.usableTools).isEmpty, "a bill gets nothing")
for (request, acts) in [("add a task to book the venue", true), ("which tasks are still open", false), ("what's in my team notes", false),
                        ("save the offsite plan to my notes", true), ("create an issue for the login bug", true), ("my open Linear issues", false)] {
    expect(ToolPicker.asksToAct(request) == acts, "\"\(request)\" \(acts ? "asks" : "doesn't ask") to do something")
}

print("Asking first")
func tool(_ name: String) -> ConnectedTool { fixture.connections[0].tools.first { $0.name == name }! }
let look = ConsentPolicy.request(fixture.connections[0], tool("list_tasks"), values: .object(["status": .string("open")]), personal: [])
expect(look?.kind == .lookUp && look?.question == "Let Team Notes look this up?" && look?.always == "Always for Team Notes", "a look-up asks the first time: \(look?.question ?? "")")
let change = ConsentPolicy.request(fixture.connections[0], tool("add_task"), values: try JSONValue(json: #"{"title": "Book the venue", "due_date": "2026-11-06"}"#), personal: [])
expect(change?.kind == .change && change?.question == "Add task in Team Notes?", "a change asks: \(change?.question ?? "")")
expect(change?.values == [.init(name: "Due date", text: "2026-11-06"), .init(name: "Title", text: "Book the venue")], "showing exactly what it sends")
expect(ConsentPolicy.request(fixture.connections[0], tool("delete_note"), values: .object([:]), personal: [])?.kind == .destroy, "one that may delete says so")
expect(ConsentPolicy.request(fixture.connections[0], tool("append_note"), values: .object([:]), personal: [])?.note?.contains("doesn't say") == true, "one whose service doesn't say is asked as a change")
var trusting = fixture.connections[0]
trusting.alwaysLooksUp = true
expect(ConsentPolicy.request(trusting, tool("list_tasks"), values: .object([:]), personal: []) == nil, "after Always, a look-up isn't asked again")
expect(ConsentPolicy.request(trusting, tool("add_task"), values: .object([:]), personal: []) != nil, "but a change still is")
let carried = PersonalCheck.carried(in: .object(["query": .string("notes about Pune")]), details: [pune], request: "notes about my home city")
let personal = ConsentPolicy.request(trusting, tool("list_tasks"), values: .object(["query": .string("notes about Pune")]), personal: carried)
expect(personal?.kind == .personal && personal?.personal == [pune] && personal?.always == nil, "anything personal is always asked, naming it, with no Always")
expect(PersonalCheck.carried(in: .object(["query": .string("Pune")]), details: [pune], request: "notes about Pune").isEmpty, "what the request itself says isn't personal")

Consent.answerer = .user
let waiting = Consent()
let firstAsk = Task { await waiting.ask(look!) }
let secondAsk = Task { await waiting.ask(ConsentPolicy.request(fixture.connections[0], tool("search_notes"), values: .object([:]), personal: [])!) }
let thirdAsk = Task { await waiting.ask(change!) }
try await Task.sleep(for: .milliseconds(100))
expect(waiting.pending?.question == look?.question, "one question shows at a time")
waiting.answer(.always)
try await Task.sleep(for: .milliseconds(100))
let (answered, covered) = (await firstAsk.value, await secondAsk.value)
expect(answered == .always && covered == .once, "Always for a service answers its other look-ups waiting too")
expect(waiting.pending?.question == change?.question, "a change waiting behind them still asks")
waiting.cancel()
expect(await thirdAsk.value == .deny, "leaving the page refuses what's still waiting")

print("Calling, as the model does")
@MainActor func call(_ name: String, _ json: String, answer: ConsentAnswer) async throws -> String {
    Consent.answerer = .automatic(answer)
    let entry = Connections.usableTools.first { $0.tool.name == name }!
    let tool = ConnectionTool(name: "t", description: "", parameters: ToolSchema.generationSchema(for: entry.tool.inputSchema, name: "t")!, connection: entry.connection,
                              tool: entry.tool, request: "", asking: Asking(), consent: Consent(), live: live, log: log)
    return try await tool.call(arguments: try GeneratedContent(json: json))
}
let live = LiveLog()
let log = ConnectionLog()
let offeredTools = ConnectionTool.offered(for: "add a task to book the venue in my team notes", asking: Asking(), consent: Consent(), live: live, log: log, onUse: { _ in })
    .compactMap { $0 as? ConnectionTool }.map(\.tool.name)
expect(offeredTools.contains("add_task"), "asked to act, a change is offered as a tool to call: \(offeredTools)")
expect(!log.problems(in: Surface.empty).isEmpty, "and if the model never calls it, that goes back to it")
let refused = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .deny)
expect(refused.contains("didn't allow") && calls(of: "add_task").isEmpty, "Don't allow sends nothing, and tells the model plainly")
let added = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .once)
expect(calls(of: "add_task").count == 1 && added.contains("It's done"), "Allow once runs it, and the model is told it's done")
expect(fixture.connections[0].tools.first { $0.name == "add_task" }?.alwaysAllowed == false, "and asks again next time")
let looked = try await call("list_tasks", "{}", answer: .always)
expect(fixture.connections[0].alwaysLooksUp && live.sources.contains { $0.name == "listTasks" }, "Always is kept, and the look-up becomes a live source")
expect(looked.contains("Dream keeps these current"), "which the model is told how to show")
expect(log.problems(in: Surface.empty).isEmpty, "a change that was tried isn't sent back as missing")

print("Reading as a live source")
let source = Source(name: "listTasks", kind: Source.connectionKind, parameters: [
    "service": notes.name, "server": server.absoluteString, "tool": "list_tasks", "arguments": "{}",
], fields: [])
fixture.connections[0].alwaysLooksUp = false
do {
    _ = try await LiveSources.read(source, again: true)
    expect(false, "without Always, a page doesn't read a service again by itself")
} catch {
    expect(true, "without Always, a page doesn't read a service again by itself: \(error.localizedDescription)")
}
fixture.connections[0].alwaysLooksUp = true
let readsBefore = calls(of: "list_tasks").count
let first = try await LiveSources.read(source, again: true)
let count = first.field("tasksCount")?.value ?? 0
expect(count >= 3 && first.field("open")?.value == count - 1, "numbers become fields: open \(first.field("open")?.value ?? -1), tasksCount \(count)")
expect(first.lists["tasks"]?.count == Int(count), "a list of objects becomes rows")
let shapes = ConnectionReading.shapes(first)
expect(shapes.first?.keys.contains("dueDate") == true, "row keys are camelCase: \(shapes.first?.keys ?? [])")
_ = try await LiveSources.read(source)
expect(calls(of: "list_tasks").count == readsBefore + 1, "a fresh reading is kept, so the screen's first read doesn't ask again")
let again = try await LiveSources.read(source, again: true)
expect(calls(of: "list_tasks").count == readsBefore + 2 && again.field("tasksCount")?.value == count + 1, "a pull asks the service again, without the model: \(again.field("tasksCount")?.value ?? -1) tasks now")

let shared = Source(name: "listTasks", kind: Source.connectionKind, parameters: ["service": notes.name], fields: [])
do {
    _ = try await LiveSources.read(shared)
    expect(false, "a source from someone else's page isn't read")
} catch {
    expect(calls(of: "list_tasks").count == readsBefore + 2, "a source from someone else's page isn't read: \(error.localizedDescription)")
}

print("A list a service fills")
var surface = Surface(title: "Offsite tasks", summary: "", symbol: "checklist", accent: .blue,
                      inputs: [Input(name: "open", label: "Open", format: .integer, initial: 0, min: 0, max: 100, step: 1, options: [], role: .live, source: "listTasks.open")],
                      outputs: [Output(name: "points", label: "Points", formula: "sum(tasks.points)", format: .integer)],
                      blocks: [Block(id: "a", kind: .hero, ref: "open"), Block(id: "b", kind: .add, ref: "tasks"), Block(id: "c", kind: .list, ref: "tasks"), Block(id: "d", kind: .metric, ref: "points")],
                      related: [], reference: nil)
var declared = source
declared.fields = first.fields
declared.lists = shapes
surface.sources = [declared]
surface.collections = [RecordCollection(name: "tasks", label: "Tasks", entry: "task", fields: [
    RecordField(name: "title", label: "Task", type: .text),
    RecordField(name: "done", label: "Done", type: .done),
    RecordField(name: "due", label: "Due", type: .date),
    RecordField(name: "points", label: "Points", type: .number),
], starters: [["title": .text("Made up")]], source: "listTask.task")]
let issues = Checker.checkLogic(&surface)
expect(!issues.contains { $0.kind == .needsModel }, "it checks: \(issues.filter { $0.kind == .needsModel }.map(\.message))")
expect(surface.collection("tasks")?.source == "listTasks.tasks", "a near-miss list is read as the one it means")
expect(surface.collection("tasks")?.starters.isEmpty == true, "it has no starters")
expect(!surface.blocks.contains { $0.kind == .add }, "nobody adds to it here")
let entries = surface.serviceRecords(again, from: "listTasks")["tasks"] ?? []
expect(entries.count == Int(count) + 1 && entries[0]["title"] == .text("Book the venue") && entries[0].isOn("done"), "rows become entries, by field name")
expect(entries[1]["due"]?.numberValue != nil, "a due_date fills a date field named due")
let firstEntries = surface.serviceRecords(first, from: "listTasks")["tasks"] ?? []
expect(Array(entries.prefix(firstEntries.count).map(\.id)) == firstEntries.map(\.id), "an entry keeps its id from one reading to the next")
let total = surface.evaluate(["open": 3], records: ["tasks": entries]).values["points"]
let expected = entries.compactMap { $0["points"]?.numberValue }.reduce(0, +)
expect(total == expected && expected > 0, "totals over a service's list work: \(total ?? -1)")
expect(surface.keepingOwnLists.collections == nil, "talking to lists leaves a service's alone")
var unbound = surface
unbound.collections?[0].source = "nothing.here"
expect(Checker.checkLogic(&unbound).contains { $0.kind == .needsModel }, "a list no service returned goes back to the model")

print("Buttons already on a page")
let performer = LiveActions.performer(Action.connectionKind)
expect(performer != nil, "service buttons have a performer")
func button(_ tool: String, _ inputs: String, memory: Bool = false) throws -> ResolvedAction {
    var fields = ["service": notes.name, "server": server.absoluteString, "tool": tool,
                  "label": notes.tools.first { $0.name == tool }?.title ?? "", "inputs": ConnectionPerformer.encode(try JSONValue(json: inputs))]
    if memory { fields["memory"] = "yes" }
    return ResolvedAction(name: "b", kind: Action.connectionKind, text: fields, start: nil, hasTime: false, minutes: nil)
}
let add = try button("add_task", #"{"title": "Book the venue for $4,200 {all}", "points": 3}"#)
expect(performer?.sentence(add) == "Add task in Team Notes", "it says what it does: \(performer?.sentence(add) ?? "")")
expect(performer?.details(add) == ["Points: 3", "Title: Book the venue for $4,200 {all}"], "and with which values, exactly: \(performer?.details(add) ?? [])")
expect(performer?.needsConfirmation(add) == false, "a tap is the user's word, so a plain change goes on the tap")
expect(performer?.needsConfirmation(try button("delete_note", #"{"id": "1"}"#)) == true, "one that may delete asks first")
expect(performer?.needsConfirmation(try button("append_note", #"{"id": "1", "text": "x"}"#)) == true, "so does one whose service doesn't say")
expect(performer?.needsConfirmation(try button("add_task", #"{"title": "Visit Pune"}"#, memory: true)) == true, "and one carrying something personal")
let sentBefore = calls(of: "add_task").count
let done = try await performer!.perform(add)
let sent = calls(of: "add_task").last ?? ""
expect(calls(of: "add_task").count == sentBefore + 1 && sent.contains(#""title": "Book the venue for $4,200 {all}""#) && sent.contains(#""points": 3"#), "the tap sends exactly that: \(sent)")
expect(done.message == "Done in Team Notes", "and says it's done: \(done.message)")

print("Services a request names")
Connections.directory = try JSONDecoder().decode([DirectoryEntry].self, from: Data(#"""
    [{"id": "app.linear/linear", "name": "Linear", "summary": "Your issues.", "url": "https://mcp.linear.app/mcp", "signIn": true, "aliases": [], "featured": true},
     {"id": "com.atlassian/atlassian-mcp-server", "name": "Atlassian", "summary": "Jira and Confluence.", "url": "https://mcp.atlassian.com/v1/mcp", "signIn": true, "aliases": ["Jira", "Confluence"], "featured": true},
     {"id": "local/team-notes", "name": "Team Notes", "summary": "", "url": "\#(server.absoluteString)", "signIn": false, "aliases": [], "featured": true}]
    """#.utf8))
for (request, names) in [("my Linear issues", ["Linear"]), ("what's on my linear board", ["Linear"]), ("explain linear regression in linear algebra", []),
                         ("summarise the sprint in Jira", ["Atlassian"]), ("what's in my team notes", []), ("Linear vs Jira for a small team", []),
                         ("add the plan to Linear", ["Linear"])] {
    let found = Connections.unconnected(in: request).map(\.name)
    expect(found == names, "\"\(request)\" \(names.isEmpty ? "suggests nothing" : "suggests connecting \(names.joined(separator: ", "))")\(found == names ? "" : ": got \(found)")")
}

print("Sharing")
var page = surface
page.services = [notes.name]
page.actions = [Action(name: "addTask", kind: Action.connectionKind, fields: add.text),
                Action(name: "remind", kind: "reminder", fields: ["title": "Offsite"])]
page.blocks.append(Block(id: "e", kind: .section, title: "Do", children: [Block(id: "f", kind: .action, ref: "addTask")]))
page.blocks.append(Block(id: "g", kind: .action, ref: "remind"))
let outgoing = SharedSurface(sharing: page, values: nil).surface
expect(outgoing.actions?.map(\.name) == ["remind"], "a service's buttons don't travel, others do")
expect(!outgoing.blocks.contains { $0.id == "e" || $0.id == "f" }, "nor do their blocks")
expect(outgoing.sources?.first?.parameters == ["service": "Team Notes"], "a source keeps only the service's name: \(outgoing.sources?.first?.parameters ?? [:])")
expect(outgoing.sources?.first?.fields == declared.fields, "and the values the user chose to share")
expect(outgoing.services == ["Team Notes"], "the page still says which service's data is in it")
let json = try SharedSurface.encoder.encode(SharedSurface(sharing: page, values: nil))
expect(!String(decoding: json, as: UTF8.self).contains("127.0.0.1"), "the service's address isn't in what's shared")
var crafted = page
crafted.services = nil
let received = try SharedSurface.received(try SharedSurface.encoder.encode(SharedSurface(format: 1, surface: crafted, values: nil, currency: nil, preview: nil)))
expect(received.surface.actions?.contains { $0.isConnection } != true, "a shared page can't bring a button for the reader's services")
expect(received.surface.sources?.first?.parameters["server"] == nil, "nor a source that would ask them anything")

print(failures == 0 ? "\nAll connection checks passed." : "\n\(failures) connection checks failed.")
exit(failures == 0 ? 0 : 1)
