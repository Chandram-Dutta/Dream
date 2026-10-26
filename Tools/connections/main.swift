import Foundation
import FoundationModels

// Connected services through the MCP SDK and the local test server, without a model: connecting
// and listing tools, calling them as the model does, reading one again as a live source, and a
// button's tap. Run with Tools/connections.sh, which first runs the checks that need no server
// (DreamTests/ConnectionsTests.swift), then starts the server and passes its address and log.

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
expect(Set(Connections.lookingTools.map(\.tool.name)) == ["list_tasks", "search_notes", "append_note"], "its read-only hints arrive: tools that look things up, or don't say, are offered by relevance alone")
expect(Set(Connections.changingTools.map(\.tool.name)) == ["add_task", "delete_note"], "tools that say they change things are offered when asked to act")
expect(!Connections.usableTools.contains { $0.tool.name == "tag_notes" }, "a tool whose inputs can't be filled is left out")

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
let refused = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .deny)
expect(refused.contains("didn't allow") && calls(of: "add_task").isEmpty, "Don't allow sends nothing, and tells the model plainly")
let added = try await call("add_task", #"{"title": "Book the venue"}"#, answer: .once)
expect(calls(of: "add_task").count == 1 && added.contains("It's done"), "Allow once runs it, and the model is told it's done")
let looked = try await call("list_tasks", "{}", answer: .always)
expect(fixture.connections[0].alwaysLooksUp && live.sources.contains { $0.name == "listTasks" }, "Always is kept, and the look-up becomes a live source")
expect(looked.contains("Dream keeps these current"), "which the model is told how to show")

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
_ = try await LiveSources.read(source)
expect(calls(of: "list_tasks").count == readsBefore + 1, "a fresh reading is kept, so the screen's first read doesn't ask again")
let again = try await LiveSources.read(source, again: true)
expect(calls(of: "list_tasks").count == readsBefore + 2 && again.field("tasksCount")?.value == count + 1, "a pull asks the service again, without the model: \(again.field("tasksCount")?.value ?? -1) tasks now")

print("A button's tap")
let performer = LiveActions.performer(Action.connectionKind)!
let add = ResolvedAction(name: "b", kind: Action.connectionKind, text: [
    "service": notes.name, "server": server.absoluteString, "tool": "add_task", "label": notes.tools.first { $0.name == "add_task" }?.title ?? "",
    "inputs": ConnectionPerformer.encode(try JSONValue(json: #"{"title": "Book the venue for $4,200 {all}", "points": 3}"#)),
], start: nil, hasTime: false, minutes: nil)
let sentBefore = calls(of: "add_task").count
let done = try await performer.perform(add)
let sent = calls(of: "add_task").last ?? ""
expect(calls(of: "add_task").count == sentBefore + 1 && sent.contains(#""title": "Book the venue for $4,200 {all}""#) && sent.contains(#""points": 3"#), "the tap sends exactly that: \(sent)")
expect(done.message == "Done in Team Notes", "and says it's done: \(done.message)")

print(failures == 0 ? "\nAll connection checks passed." : "\n\(failures) connection checks failed.")
exit(failures == 0 ? 0 : 1)
