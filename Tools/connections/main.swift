import Foundation

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
Connections.source = Connections.Source(
    connections: { fixture.connections },
    call: { connection, tool, arguments in try await ConnectionSessions.shared.call(connection, tool: tool, arguments: arguments) },
    personalDetails: { ["Pune, Maharashtra"] })
Connections.registerLive()
expect(notes.name == "Team Notes", "the server says what it's called: \(notes.name)")
expect(Set(Connections.readingTools.map(\.tool.name)) == ["list_tasks", "search_notes"], "tools that only read, and can be filled, may be used while building")
expect(Set(Connections.writingTools.map(\.tool.name)) == ["add_task", "delete_note", "append_note"], "tools that change things can only become buttons")

print("Picking")
let tasks = ToolPicker.pick(for: "which tasks are still open in my team notes", from: Connections.readingTools).map(\.tool.name)
expect(tasks.contains("list_tasks"), "a request about tasks gets the task tool: \(tasks)")
expect(ToolPicker.pick(for: "split a restaurant bill between friends", from: Connections.readingTools + Connections.writingTools).isEmpty, "a bill gets nothing")
for (request, acts) in [("add a task to book the venue", true), ("which tasks are still open", false), ("what's in my team notes", false),
                        ("save the offsite plan to my notes", true), ("create an issue for the login bug", true), ("my open Linear issues", false)] {
    expect(ToolPicker.asksToAct(request) == acts, "\"\(request)\" \(acts ? "asks" : "doesn't ask") to do something")
}

print("Reading as a live source")
let source = Source(name: "listTasks", kind: Source.connectionKind, parameters: [
    "service": notes.name, "server": server.absoluteString, "tool": "list_tasks", "arguments": "{}",
], fields: [])
let first = try await LiveSources.read(source)
expect(first.field("open")?.value == 2 && first.field("tasksCount")?.value == 3, "numbers become fields: open \(first.field("open")?.value ?? -1), tasksCount \(first.field("tasksCount")?.value ?? -1)")
expect(first.lists["tasks"]?.count == 3, "a list of objects becomes rows")
let shapes = ConnectionReading.shapes(first)
expect(shapes.first?.keys.contains("dueDate") == true, "row keys are camelCase: \(shapes.first?.keys ?? [])")
_ = try await LiveSources.read(source)
expect(calls(of: "list_tasks").count == 1, "a fresh reading is kept, so the screen's first read doesn't ask again")
let again = try await LiveSources.read(source, again: true)
expect(calls(of: "list_tasks").count == 2 && again.field("open")?.value == 3, "a pull asks the service again, without the model: open is now \(again.field("open")?.value ?? -1)")

let shared = Source(name: "listTasks", kind: Source.connectionKind, parameters: ["service": notes.name], fields: [])
do {
    _ = try await LiveSources.read(shared)
    expect(false, "a source from someone else's page isn't read")
} catch {
    expect(calls(of: "list_tasks").count == 2, "a source from someone else's page isn't read: \(error.localizedDescription)")
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
expect(entries.count == 4 && entries[0]["title"] == .text("Book the venue") && entries[0].isOn("done"), "rows become entries, by field name")
expect(entries[1]["due"]?.numberValue != nil, "a due_date fills a date field named due")
let firstEntries = surface.serviceRecords(first, from: "listTasks")["tasks"] ?? []
expect(Array(entries.prefix(3).map(\.id)) == firstEntries.map(\.id), "an entry keeps its id from one reading to the next")
let total = surface.evaluate(["open": 3], records: ["tasks": entries]).values["points"]
expect(total == 20, "totals over a service's list work: \(total ?? -1)")
expect(surface.keepingOwnLists.collections == nil, "talking to lists leaves a service's alone")
var unbound = surface
unbound.collections?[0].source = "nothing.here"
expect(Checker.checkLogic(&unbound).contains { $0.kind == .needsModel }, "a list no service returned goes back to the model")

print("Buttons for write tools")
let performer = LiveActions.performer(Action.connectionKind)
expect(performer != nil, "write tools have a performer")
func button(_ tool: String, _ inputs: String, memory: Bool = false) throws -> ResolvedAction {
    var fields = ["service": notes.name, "server": server.absoluteString, "tool": tool,
                  "label": notes.tools.first { $0.name == tool }?.title ?? "", "inputs": ConnectionPerformer.encode(try JSONValue(json: inputs))]
    if memory { fields["memory"] = "yes" }
    return ResolvedAction(name: "b", kind: Action.connectionKind, text: fields, start: nil, hasTime: false, minutes: nil)
}
let add = try button("add_task", #"{"title": "Book the venue for $4,200 {all}", "points": 3}"#)
expect(performer?.sentence(add) == "Add task in Team Notes", "it says what it does: \(performer?.sentence(add) ?? "")")
expect(performer?.details(add) == ["Points: 3", "Title: Book the venue for $4,200 {all}"], "and with which values, exactly: \(performer?.details(add) ?? [])")
expect(performer?.needsConfirmation(add) == false, "a write the service says isn't destructive goes on a tap")
expect(performer?.needsConfirmation(try button("delete_note", #"{"id": "1"}"#)) == true, "one that may delete asks first")
expect(performer?.needsConfirmation(try button("append_note", #"{"id": "1", "text": "x"}"#)) == true, "so does one whose service doesn't say")
let done = try await performer!.perform(add)
let sent = calls(of: "add_task").last ?? ""
expect(sent.contains(#""title": "Book the venue for $4,200 {all}""#) && sent.contains(#""points": 3"#), "the tap sends exactly that: \(sent)")
expect(done.message == "Done in Team Notes", "and says it's done: \(done.message)")
do {
    _ = try await performer!.perform(try button("add_task", #"{"title": "Visit Pune"}"#, memory: true))
    expect(false, "a button carrying what Dream remembers needs the service to be allowed it")
} catch {
    expect(calls(of: "add_task").count == 1, "a button carrying what Dream remembers needs the service to be allowed it: \(error.localizedDescription)")
}
fixture.connections[0].mayReceiveMemory = true
_ = try await performer!.perform(try button("add_task", #"{"title": "Visit Pune"}"#, memory: true))
expect(calls(of: "add_task").count == 2, "once allowed, it goes")

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
