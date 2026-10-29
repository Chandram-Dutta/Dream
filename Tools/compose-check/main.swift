import CoreGraphics
import Foundation

// Follows pages made by a scripted server (Tools/compose-mock.py) through the app's own client,
// over the network, as the phone does: a page to its end, a line that drops mid-page, a question
// and its answer, a failure, a page picked up again from its first event after the app left it,
// a job the server doesn't have, and a photo. Then changes of each kind, and the phone's own
// tools: one run for the server, one the server stopped waiting for, one the loop went past.
// Built and run by Tools/compose-check.sh, which starts the mock; settings as for the bench, like
// "-shareServer http://127.0.0.1:8790".

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
    if !ok { failures += 1 }
}

/// What the mock was sent for a job, and how often its events were read.
struct Sent: Decodable {
    struct Request: Decodable {
        struct Place: Decodable {
            var language: String
            var region: String
            var currency: String
            var measurementSystem: String
        }

        struct Tool: Decodable {
            var name: String
            var description: String
        }

        var request: String
        var image: String?
        var model: String?
        var locale: Place
        var context: [String]
        var pageID: String
        var editing: JSONValue?
        var deviceTools: [Tool]?
    }

    /// What one of the phone's tools returned, and whether the job took it (200) or had gone on (409).
    struct Posted: Decodable {
        struct Output: Decodable {
            var id: String
            var output: String
        }

        var output: Output
        var status: Int
    }

    var request: Request
    var answers: [[Answer]]
    var tools: [Posted]
    var readings: [Int]
}

/// A service the user connected, answered here: its one tool lists the team's tasks.
final class TeamNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    let connection: Connection = {
        var connection = Connection(url: URL(string: "https://notes.example/mcp")!, name: "Team Notes")
        connection.tools = [ConnectedTool(name: "list_tasks", title: "List tasks", summary: "List the team's tasks in the user's team notes, with how many are still open.",
                                          inputSchema: (try? JSONValue(json: #"{"type": "object", "properties": {"status": {"enum": ["open", "all"]}}}"#)) ?? .object([:]),
                                          readOnlyHint: true, destructiveHint: nil, idempotentHint: nil, openWorldHint: nil)]
        return connection
    }()

    func connect() {
        let connection = connection
        Connections.source = Connections.Source(
            connections: { [connection] },
            call: { _, _, _ in
                self.lock.withLock { self.count += 1 }
                return ToolResult(text: #"{"open": 2, "tasks": ["Book the venue", "Send the agenda"]}"#, structured: nil, isError: false)
            },
            personalDetails: { [] })
    }
}

func sent(_ job: ServerJob?) async -> Sent? {
    guard let job, let base = ServerAddress.dream,
          let reply = try? await URLSession.shared.data(from: base.appending(path: "mock/jobs/\(job.id)")) else { return nil }
    return try? JSONDecoder().decode(Sent.self, from: reply.0)
}

let steps = ["Tipping", "tipping at restaurants in India", "livemint.com"]

@MainActor func run() async {
    print("A page, to its end")
    let plain = Composer()
    await plain.compose(intent: "split a 2400 rupee dinner between 3 friends", onServer: true)
    check(plain.phase == .done, "done (\(plain.phase))")
    check(plain.surface?.title == "Dinner split" && plain.surface?.blocks.count == 3, "the finished page, every block")
    check(plain.trail.map(\.text) == steps, "each step of the work once: \(plain.trail.map(\.text))")
    check(plain.modelName == "mock-model", "the model that wrote it")
    check(plain.surface?.locale?.language == "en", "labelled with its language")
    check(plain.log.contains("Lookup: Tipping") && plain.log.contains("Fixed: placed every input"), "the server's log, for Under the hood")
    let first = await sent(plain.job)
    check(first?.request.pageID == plain.job?.page.uuidString, "the page's id, as the app made it")
    check(first?.request.locale.currency.isEmpty == false && first?.request.locale.measurementSystem.isEmpty == false, "the reader's currency and units")
    check(first?.request.context.isEmpty == false, "the lines the phone adds")
    check(first?.readings == [0], "its events read once, from the start: \(first?.readings ?? [])")

    print("A line that drops mid-page")
    let dropped = Composer()
    check(await dropped.composeOnServer(intent: "drop: split a 2400 rupee dinner between 3 friends", image: nil) == .done, "done")
    check(dropped.trail.map(\.text) == steps, "nothing shown twice: \(dropped.trail.map(\.text))")
    check(dropped.surface?.blocks.count == 3, "the finished page")
    let again = await sent(dropped.job)
    check(again?.readings == [0, 3], "read again after the last event counted: \(again?.readings ?? [])")

    print("A question, answered")
    let asking = Composer()
    check(await asking.composeOnServer(intent: "ask: split a 2400 rupee dinner between 3 friends", image: nil) == .done, "done")
    let asked = await sent(asking.job)
    check(asked?.answers.count == 1 && asked?.answers.first?.first?.question.topic == "Tip", "the answers went back to the job")
    check(asking.surface?.answers?.first?.question.topic == "Tip", "and the page carries them")

    print("A page that fails")
    let failing = Composer()
    check(await failing.composeOnServer(intent: "fail: split a dinner", image: nil) == .failed, "failed")
    check(failing.phase == .failed("The model's safety filters blocked this request."), "with the server's reason: \(failing.phase)")

    print("A page left mid-way, picked up again")
    let left = Composer()
    let leaving = Task { await left.composeOnServer(intent: "slow: split a 2400 rupee dinner between 3 friends", image: nil) }
    while left.trail.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
    leaving.cancel()
    check(await leaving.value == .stopped, "stopped with the page still being made")
    guard let job = left.job else { return check(false, "it had a job") }
    let back = Composer()
    check(await back.watch(job, intent: "slow: split a 2400 rupee dinner between 3 friends") == .done, "done")
    check(back.trail.map(\.text) == steps, "every step once: \(back.trail.map(\.text))")
    check(back.surface?.blocks.count == 3, "the finished page")
    check(back.job?.page == job.page, "under the same id")
    let resumed = await sent(job)
    check(resumed?.readings.first == 0 && resumed?.readings.last == 0, "the new composer read from the first event: \(resumed?.readings ?? [])")

    print("A job the server doesn't have")
    let gone = Composer()
    check(await gone.watch(ServerJob(id: "no-such-job", page: UUID()), intent: "anything") == .gone, "gone, so its page comes by sync")
    check(gone.phase.isBusy, "and nothing says it failed")

    print("A page from a photo")
    let width = 4032, height = 3024
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let photo = Composer()
    check(await photo.composeOnServer(intent: "split this bill", image: context.makeImage()) == .done, "done")
    let withPhoto = await sent(photo.job)
    check(withPhoto?.request.image?.hasSuffix("bytes of JPEG") == true, "the photo went as a JPEG: \(withPhoto?.request.image ?? "none")")

    guard let base = plain.surface else { return check(false, "a page to change") }
    let intent = "split a 2400 rupee dinner between 3 friends"

    print("A change, made on the server")
    let page = UUID()
    let change = PageChange.instruction("make it 4 people", focus: "hero", on: base, values: ["bill": 3000, "people": 5])
    let changing = Composer()
    // As ServerPages starts one: shown at once, then started.
    changing.beginChange(change, intent: intent)
    let making = Task { await changing.changeOnServer(change, intent: intent, image: nil, page: page) }
    var held = true
    while changing.phase.isBusy {
        if changing.surface != base { held = false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    check(await making.value == .done, "done")
    check(held, "the page as it was stayed on screen while the change was written")
    check(changing.surface?.input("people")?.initial == 4 && changing.surface?.summary == "₹2,400 between 4 friends.", "then the change")
    check(changing.job?.page == page, "under the page's own id")
    let changed = await sent(changing.job)
    check(changed?.request.request == intent, "the request is what the page was first asked for")
    check(changed?.request.editing?["instruction"]?.string == "make it 4 people" && changed?.request.editing?["focus"]?.string == "hero", "the change, and the block it's about")
    check(changed?.request.editing?["surface"]?["title"]?.string == "Dinner split", "and the page as it is")
    let offered = changed?.request.deviceTools?.map { $0.name } ?? []
    check(offered == ["travel"], "the phone's tools went with it: \(offered)")
    check(changing.surface.map(change.kept(after:)) == ["bill": 3000],"the user's bill kept, people where the change put it")
    check(changing.log.first == "Change: make it 4 people (pointing at #hero)", "logged as a change made here is")

    print("A different answer")
    let question = Question(text: "Is the tip in the bill?", topic: "Tip", options: ["Yes", "No"])
    let answered = base.answered([Answer(question: question, choice: "Yes")])
    let answering = Composer()
    check(await answering.changeOnServer(.answer(answered.answers![0], to: "No", on: answered, values: [:]), intent: intent, image: nil, page: UUID()) == .done, "done")
    let answer = await sent(answering.job)?.request.editing?["answer"]
    check(answer?["choice"]?.string == "No" && answer?["question"]?["topic"]?.string == "Tip", "the question, and the new choice")
    check(answering.surface?.answers == [Answer(question: question, choice: "No")], "the page carries the new answer")

    print("Made again, after connecting a service")
    let remaking = Composer()
    check(await remaking.changeOnServer(.again(intent, on: base, values: [:]), intent: intent, image: context.makeImage(), page: UUID()) == .done, "done")
    let remade = await sent(remaking.job)
    check(remade?.request.editing?["again"] == JSONValue.bool(true), "made again")
    check(remade?.request.image?.hasSuffix("bytes of JPEG") == true, "from its photo")

    print("One of the phone's tools, run for the server")
    let notes = TeamNotes()
    notes.connect()
    let tooling = Composer()
    check(await tooling.composeOnServer(intent: "tool: which tasks are still open in my team notes", image: nil) == .done, "done")
    let used = await sent(tooling.job)
    let names = used?.request.deviceTools?.map { $0.name } ?? []
    check(names.count == 2 && names.last == "travel" && names.first?.hasSuffix("list_tasks") == true, "the service's tool picked for the request, and travel times: \(names)")
    check(used?.request.deviceTools?.first?.description.hasPrefix("From Team Notes") == true, "described as the phone describes it to a model")
    check(notes.calls == 1, "run here, once, after asking (\(notes.calls))")
    check(used?.tools.map(\.status) == [200] && used?.tools.first?.output.output.contains("What Team Notes returned") == true, "and what it returned went back to the job")
    check(tooling.log.contains { $0.hasPrefix("Team Notes: list_tasks") }, "the call is in the log for Under the hood")

    print("A call the server stopped waiting for")
    let impatient = Composer()
    check(await impatient.composeOnServer(intent: "impatient: which tasks are still open in my team notes", image: nil) == .done, "the page goes on")
    let refused = await sent(impatient.job)
    check(refused?.tools.map(\.status) == [409], "sent once, and let go after a 409: \(refused?.tools.map(\.status) ?? [])")
    check(impatient.log.contains { $0.hasPrefix("Dream's server had gone on without") }, "which the log says")

    print("A call the loop went past")
    let before = notes.calls
    let past = Composer()
    check(await past.composeOnServer(intent: "past: which tasks are still open in my team notes", image: nil) == .done, "done")
    check(await sent(past.job)?.tools.isEmpty == true && notes.calls == before, "never run, and nothing sent")
}

await run()
print(failures == 0 ? "\nEverything as expected." : "\n\(failures) not as expected.")
exit(failures == 0 ? 0 : 1)
