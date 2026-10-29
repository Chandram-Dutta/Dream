import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Dream

// Pages made on Dream's server, without the server: reading every kind of event, the lines they
// come on, following a page through a dropped line without showing anything twice, how a page
// ends, its questions, and what starts one. Against a scripted server, over the network, it's
// Tools/compose-check.sh.

/// A page as the server sends it, as JSON.
private func pageJSON(_ surface: Surface) -> String {
    String(decoding: try! JSONEncoder().encode(surface), as: UTF8.self)
}

private func billSplit(blocks: Int = 2) -> Surface {
    var surface = Surface(title: "Dinner split", summary: "₹2,400 between 3 friends.", symbol: "fork.knife", accent: .green,
                          inputs: [Input(name: "bill", label: "Bill", format: .currency, initial: 2400, min: 0, max: 20000, step: 50, options: [])],
                          outputs: [Output(name: "share", label: "Each pays", formula: "bill / 3", format: .currency)],
                          blocks: [], related: [], reference: nil)
    surface.blocks = (0..<blocks).map { index in
        index == 0 ? Block(id: "hero", kind: .hero, ref: "share") : Block(id: "note-\(index)", kind: .paragraph, text: "Everyone pays the same share of the bill.")
    }
    return surface
}

private func event(_ json: String) -> ComposeEvent? {
    try? JSONDecoder().decode(ComposeEvent.self, from: Data(json.utf8))
}

/// The routes, scripted: each time the events are read, the next connection's steps play.
private final class ScriptedServer: ComposeTransport, @unchecked Sendable {
    enum Step {
        case event(ComposeEvent)
        /// The line drops here.
        case drop
        /// Nothing more until the answers come.
        case awaitAnswers
        /// Nothing more until a tool's output comes, or this long.
        case awaitOutput(Duration)
    }

    private let lock = NSLock()
    private var connections: [[Step]]
    private var asked: [Int] = []
    private var sent: [[Answer]] = []
    private var tools: [DeviceToolOutput] = []
    private var started: [ComposeStart] = []
    private var gone = false
    /// The job has gone on: what a tool returns is refused, as the server answers 409.
    private let movedOn: Bool
    private let answers = AsyncStream<Void>.makeStream()
    private let outputs = AsyncStream<Void>.makeStream()

    init(_ connections: [[Step]], gone: Bool = false, movedOn: Bool = false) {
        self.connections = connections
        self.gone = gone
        self.movedOn = movedOn
    }

    /// The `after` each reading asked for, in order.
    var afters: [Int] { lock.withLock { asked } }
    var answered: [[Answer]] { lock.withLock { sent } }
    /// What the phone's tools returned, as it was sent.
    var returned: [DeviceToolOutput] { lock.withLock { tools } }
    var starts: [ComposeStart] { lock.withLock { started } }

    func start(_ start: ComposeStart) async throws -> String {
        lock.withLock { started.append(start) }
        return "job-1"
    }

    func output(_ job: String, _ output: DeviceToolOutput) async throws {
        lock.withLock { tools.append(output) }
        outputs.continuation.yield()
        if movedOn { throw ComposeFailure.movedOn }
    }

    func events(_ job: String, after seq: Int) -> AsyncThrowingStream<ComposeEvent, Error> {
        let (steps, isGone): ([Step], Bool) = lock.withLock {
            asked.append(seq)
            return (connections.isEmpty ? [] : connections.removeFirst(), gone)
        }
        let answers = self.answers.stream
        let outputs = self.outputs.stream
        return AsyncThrowingStream { continuation in
            Task {
                if isGone { return continuation.finish(throwing: ComposeFailure.gone) }
                for step in steps {
                    switch step {
                    case .event(let event): continuation.yield(event)
                    case .drop: return continuation.finish(throwing: URLError(.networkConnectionLost))
                    case .awaitAnswers: for await _ in answers { break }
                    case .awaitOutput(let longest):
                        let waiting = Task { for await _ in outputs { break } }
                        let timer = Task { try? await Task.sleep(for: longest); waiting.cancel() }
                        await waiting.value
                        timer.cancel()
                    }
                }
                continuation.finish()
            }
        }
    }

    func answer(_ job: String, _ answers: [Answer]) async throws {
        lock.withLock { sent.append(answers) }
        self.answers.continuation.yield()
    }
}

private let job = ServerJob(id: "job-1", page: UUID())
private let destination = Question(text: "Where are you going?", topic: "Destination", options: ["Goa", "Pune"], allowsTyping: true)

@MainActor
private func watch(_ server: ScriptedServer, intent: String = "split a 2400 rupee dinner between 3 friends") -> ServerWatch {
    let watch = ServerWatch(job: job, progress: PageProgress(intent: intent), transport: server)
    watch.delay = { _ in .zero }
    watch.settle = .milliseconds(100)
    return watch
}

@Suite("Pages made on the server")
struct ServerComposeTests {
    @Test("Every kind of event reads as what the page screen shows")
    func events() throws {
        #expect(event(#"{"seq":1,"type":"phase","phase":"researching"}"#) == ComposeEvent(seq: 1, kind: .phase(.researching)))
        #expect(event(#"{"seq":2,"type":"phase","phase":"fixing"}"#)?.kind == .phase(.fixing))
        #expect(event(#"{"seq":3,"type":"trace","kind":"search","text":"dinner tipping India"}"#)?.kind == .trace(.search, "dinner tipping India"))
        #expect(event(#"{"seq":4,"type":"trace","kind":"read","text":"livemint.com"}"#)?.kind == .trace(.read, "livemint.com"))
        #expect(event(#"{"seq":5,"type":"trace","kind":"lookup","text":"Tipping"}"#)?.kind == .trace(.lookup, "Tipping"))
        #expect(event(#"{"seq":6,"type":"surface","surface":\#(pageJSON(billSplit()))}"#)?.kind == .surface(billSplit()))
        #expect(event(#"{"seq":7,"type":"log","line":"Check: nothing to ask (3.1s)"}"#)?.kind == .log("Check: nothing to ask (3.1s)"))
        #expect(event(#"{"seq":8,"type":"done","surface":\#(pageJSON(billSplit(blocks: 3))),"model":"grok-4.7","pageID":"\#(job.page.uuidString)"}"#)?.kind
            == .done(billSplit(blocks: 3), model: "grok-4.7"))
        #expect(event(#"{"seq":9,"type":"failed","message":"The model's safety filters blocked this request."}"#)?.kind == .failed("The model's safety filters blocked this request."))
        #expect(event(#"{"seq":9,"type":"failed"}"#)?.kind == .failed("Dream's server couldn't make this page."), "a failure always says something")

        // Questions, as the app's Question encodes them and as the gap check's model writes them.
        let asked = try #require(event(#"{"seq":10,"type":"asking","questions":[\#(String(decoding: try JSONEncoder().encode(destination), as: UTF8.self))]}"#))
        #expect(asked.kind == .asking([destination]))
        let wire = event(#"{"seq":11,"type":"asking","questions":[{"question":"Which Mercury?","topic":"Subject","options":["The planet","The element","You choose"],"personal":false,"typing":false,"remembered":""}]}"#)
        #expect(wire?.kind == .asking([Question(text: "Which Mercury?", topic: "Subject", options: ["The planet", "The element"])]), "tidied as the gap check here does: no 'You choose'")

        // A page so far may not have every part yet.
        let partial = event(#"{"seq":12,"type":"surface","surface":{"title":"Dinner sp","blocks":[{"id":"hero","kind":"hero","title":"","text":"","ref":"share","over":"","items":[],"children":[]}]}}"#)
        guard case .surface(let early)? = partial?.kind else { Issue.record("a page with parts missing still reads"); return }
        #expect(early.title == "Dinner sp" && early.blocks.count == 1 && early.inputs.isEmpty)

        // What this version doesn't know, or can't read, is passed over, never a stop.
        #expect(event(#"{"seq":13,"type":"consent","tool":"linear"}"#)?.kind == .other("consent"))
        #expect(event(#"{"seq":14,"type":"surface","surface":"not a page"}"#)?.kind == .other("surface"))
        #expect(event(#"{"seq":15,"type":"done","surface":{"blocks":"broken"},"model":"grok-4.7"}"#)?.kind == .done(nil, model: "grok-4.7"))
        #expect(event(#"{"type":"log","line":"no seq"}"#) == nil, "an event without its number can't be placed")
    }

    @Test("Each data line is one event; heartbeats, blank lines and other fields carry nothing")
    func lines() {
        #expect(EventLine.event(#"data: {"seq":1,"type":"log","line":"Model: Grok"}"#)?.seq == 1)
        #expect(EventLine.event(#"data:{"seq":2,"type":"log","line":"tight"}"#)?.kind == .log("tight"))
        #expect(EventLine.event("data: {\"seq\":3,\"type\":\"log\",\"line\":\"crlf\"}\r")?.kind == .log("crlf"))
        #expect(EventLine.event(": heartbeat") == nil)
        #expect(EventLine.event("") == nil)
        #expect(EventLine.event("event: compose") == nil)
        #expect(EventLine.event("id: 4") == nil)
        #expect(EventLine.event("retry: 3000") == nil)
        #expect(EventLine.event("data: [DONE]") == nil)
    }

    @Test("Reading again from the last event counted shows nothing twice")
    func overlap() {
        var progress = PageProgress()
        let first: [ComposeEvent] = [
            ComposeEvent(seq: 1, kind: .phase(.researching)),
            ComposeEvent(seq: 2, kind: .trace(.lookup, "Tipping")),
            ComposeEvent(seq: 3, kind: .log("Lookup: Tipping")),
        ]
        let counted = first.map { progress.apply($0) }
        #expect(counted == [true, true, true])
        #expect(progress.after == 3)
        // The line dropped; the server sends a few already seen again.
        let again: [ComposeEvent] = [
            ComposeEvent(seq: 2, kind: .trace(.lookup, "Tipping")),
            ComposeEvent(seq: 3, kind: .log("Lookup: Tipping")),
            ComposeEvent(seq: 4, kind: .trace(.search, "tipping in India")),
            ComposeEvent(seq: 5, kind: .surface(billSplit(blocks: 1))),
        ]
        let recounted = again.map { progress.apply($0) }
        #expect(recounted == [false, false, true, true])
        #expect(progress.trail.map(\.text) == ["Tipping", "tipping in India"], "each step of the work once")
        #expect(progress.log == ["Lookup: Tipping"])
        #expect(progress.phase == .composing && !progress.isThinking, "a page arriving means writing, with something to see")
        #expect(progress.after == 5)
    }

    @Test("A page ends done or failed, and nothing after counts")
    func endings() {
        var done = PageProgress(intent: "split a 2400 rupee dinner between 3 friends")
        done.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 1))))
        done.apply(ComposeEvent(seq: 2, kind: .done(billSplit(blocks: 3), model: "grok-4.7")))
        #expect(done.phase == .done && done.isOver && done.model == "grok-4.7")
        #expect(done.surface?.blocks.count == 3)
        #expect(done.surface?.locale?.language == "en", "labelled with its language when the server didn't say")
        let changed = done.apply(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1))))
        #expect(!changed, "nothing changes a finished page")
        #expect(done.surface?.blocks.count == 3)

        var kept = PageProgress()
        kept.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 2))))
        kept.apply(ComposeEvent(seq: 2, kind: .done(nil, model: "grok-4.7")))
        #expect(kept.phase == .done && kept.surface?.blocks.count == 2, "a finished page this version can't read leaves the one so far")

        var empty = PageProgress()
        empty.apply(ComposeEvent(seq: 1, kind: .done(nil, model: "")))
        #expect(empty.phase == .failed("Nothing came out of this. Try asking another way."))

        var failed = PageProgress()
        failed.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 1))))
        failed.apply(ComposeEvent(seq: 2, kind: .failed("The model stopped making progress.")))
        #expect(failed.phase == .failed("The model stopped making progress.") && failed.isOver && !failed.isThinking)
        let revived = failed.apply(ComposeEvent(seq: 3, kind: .done(billSplit(), model: "")))
        #expect(!revived)
    }

    @Test("A dropped line is read again after the last event counted, and the page still shows once")
    @MainActor func reconnect() async {
        let server = ScriptedServer([
            [.event(ComposeEvent(seq: 1, kind: .phase(.researching))), .event(ComposeEvent(seq: 2, kind: .trace(.lookup, "Tipping"))),
             .event(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1)))), .drop],
            // The second time, the server repeats one it sent before the drop.
            [.event(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1)))), .event(ComposeEvent(seq: 4, kind: .trace(.search, "tipping in India"))),
             .event(ComposeEvent(seq: 5, kind: .done(billSplit(blocks: 3), model: "grok-4.7")))],
        ])
        let follow = watch(server)
        var shown: [PageProgress] = []
        follow.onChange = { shown.append($0) }
        let ending = await follow.run()
        #expect(ending == .done)
        #expect(server.afters == [0, 3], "the second reading asks for what came after the last event counted")
        #expect(follow.progress.trail.map(\.text) == ["Tipping", "tipping in India"])
        #expect(follow.progress.surface?.blocks.count == 3 && follow.progress.phase == .done)
        // Each change shown is a new event, except the note of the drop; the repeated one never shows.
        #expect(shown.map(\.after) == [1, 2, 3, 3, 4, 5])
        #expect(shown[3].log.last?.hasPrefix("The line to Dream's server dropped after event 3") == true)
    }

    @Test("A line that ends before the page does is read again too")
    @MainActor func endedEarly() async {
        let server = ScriptedServer([
            [.event(ComposeEvent(seq: 1, kind: .phase(.composing)))],
            [],
            [.event(ComposeEvent(seq: 2, kind: .failed("This got too big for the model.")))],
        ])
        let follow = watch(server)
        #expect(await follow.run() == .failed)
        #expect(server.afters == [0, 1, 1])
        #expect(follow.progress.phase == .failed("This got too big for the model."))
    }

    @Test("A job the server no longer has is gone: its page comes by sync")
    @MainActor func gone() async {
        let server = ScriptedServer([], gone: true)
        let follow = watch(server)
        #expect(await follow.run() == .gone)
        #expect(!follow.progress.isOver, "nothing is shown as failed: the page is coming another way")
    }

    @Test("Questions wait on the user, and their answers go back to the job")
    @MainActor func questions() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .phase(.composing))),
            .event(ComposeEvent(seq: 2, kind: .asking([destination]))),
            .awaitAnswers,
            .event(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1)))),
            .event(ComposeEvent(seq: 4, kind: .done(billSplit(blocks: 2), model: "grok-4.7"))),
        ]])
        let follow = watch(server)
        var asked: [[Question]] = []
        follow.ask = { questions in
            asked.append(questions)
            return [Answer(question: questions[0], choice: "Goa")]
        }
        #expect(await follow.run() == .done)
        #expect(asked == [[destination]])
        #expect(server.answered == [[Answer(question: destination, choice: "Goa")]])
        #expect(follow.progress.surface?.answers == [Answer(question: destination, choice: "Goa")], "the page carries the answers it was made from")
        #expect(follow.progress.log.contains("Answered: Goa"))
    }

    @Test("Questions answered while the app was away aren't asked again")
    @MainActor func answeredAway() async {
        // Read again from the start: the questions, then what came of the answers given then.
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .asking([destination]))),
            .event(ComposeEvent(seq: 2, kind: .log("Answered: Goa"))),
            .event(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1)))),
            .event(ComposeEvent(seq: 4, kind: .done(billSplit(blocks: 2), model: "grok-4.7"))),
        ]])
        let follow = watch(server)
        var asked = 0
        follow.ask = { questions in
            asked += 1
            return questions.map(\.leftToDream)
        }
        #expect(await follow.run() == .done)
        #expect(asked == 0 && server.answered.isEmpty, "nothing put on screen, nothing sent")
    }

    @Test("A page starts with its photo small, its region, and its id as sync writes ids")
    func start() throws {
        let width = 3000, height = 2000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let photo = try #require(context.makeImage())
        let page = UUID()
        let start = ComposeStart(intent: "what is this?", image: photo, page: page, context: ["The user's region: India."])
        #expect(start.pageID == page.uuidString, "upper case, exactly as sync names the page")
        let jpeg = try #require(start.image.flatMap { Data(base64Encoded: $0) })
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024 && properties[kCGImagePropertyPixelHeight] as? Int == 683, "at most 1024 on its longer side")
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any]
        let locale = body?["locale"] as? [String: Any]
        #expect(Set(locale?.keys.map { $0 } ?? []) == ["language", "region", "currency", "measurementSystem"])
        #expect(body?["request"] as? String == "what is this?" && body?["context"] as? [String] == ["The user's region: India."])
        let plain = ComposeStart(intent: "split a bill", image: nil, page: page, context: [])
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        #expect(fields?["image"] == nil, "no photo, no field")
        #expect((fields?["model"] as? String) == Composer.dreamModelID)
    }
}

// MARK: - Changes, and the phone's own tools

/// The bill split with how many share it, which a change can be about.
private func sharedSplit(people: Double = 3) -> Surface {
    var surface = billSplit()
    surface.inputs.append(Input(name: "people", label: "People", format: .integer, initial: people, min: 1, max: 20, step: 1, options: []))
    surface.outputs = [Output(name: "share", label: "Each pays", formula: "bill / people", format: .currency)]
    return surface
}

private func photo(width: Int = 400, height: Int = 300) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// A tool the phone runs, counting its calls and what they were sent.
private final class Counting: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    var calls: [String] { lock.withLock { sent } }

    func entry(name: String = "count", answer: String = "3 tasks", taking: Duration = .zero) -> DeviceTools.Entry {
        DeviceTools.Entry(definition: DeviceToolDefinition(name: name, description: "Counts things.", parameters: .object(["type": .string("object")]))) { arguments in
            self.lock.withLock { self.sent.append(arguments.jsonString) }
            if taking > .zero { try await Task.sleep(for: taking) }
            return answer
        }
    }
}

private let counting = DeviceToolCall(id: "call-1", name: "count", arguments: #"{"what":"tasks"}"#)

@Suite("Changes and the phone's tools on the server")
struct ServerChangeTests {
    @Test("A change asks with the page as it is and what's changing, for each kind")
    func bodies() throws {
        let page = UUID()
        var current = sharedSplit()
        current.answers = [Answer(question: destination, choice: "Goa")]
        func body(_ change: PageChange, image: CGImage? = nil) throws -> [String: Any] {
            let start = ComposeStart(changing: change, intent: "split a 2400 rupee dinner", image: image, page: page, context: ["The user's region: India."])
            return try #require(try JSONSerialization.jsonObject(with: start.body()) as? [String: Any])
        }

        let typed = try body(.instruction("make it 4 people", focus: "hero", on: current, values: ["bill": 3000]), image: photo())
        let editing = try #require(typed["editing"] as? [String: Any])
        #expect(typed["request"] as? String == "split a 2400 rupee dinner", "the request is still what the page was first asked for")
        #expect(typed["pageID"] as? String == page.uuidString, "under the page's own id")
        #expect(typed["context"] as? [String] == ["The user's region: India."])
        #expect(typed["image"] == nil, "a change works from the page, not the photo")
        #expect(editing["instruction"] as? String == "make it 4 people" && editing["focus"] as? String == "hero")
        #expect(editing["answer"] == nil && editing["again"] == nil, "nothing it isn't")
        let surface = try #require(editing["surface"])
        let read = ComposeEvent.surface(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: surface)))
        #expect(read == current, "the page as the app's Surface encodes it, which reads back as the same page")

        let answered = try body(.answer(current.answers![0], to: "Pune", on: current, values: [:]))
        let answer = try #require((answered["editing"] as? [String: Any])?["answer"] as? [String: Any])
        #expect((answer["question"] as? [String: Any])?["text"] as? String == destination.text && answer["choice"] as? String == "Pune",
                "a different answer: the question as the app's Question encodes it, and the new choice")
        #expect((answered["editing"] as? [String: Any])?["instruction"] == nil)

        let again = try body(.again("split a 2400 rupee dinner", on: current, values: [:]), image: photo())
        #expect((again["editing"] as? [String: Any])?["again"] as? Bool == true)
        #expect(again["image"] is String, "made again, the photo goes again")

        let fresh = ComposeStart(intent: "split a 2400 rupee dinner", image: nil, page: page, context: [])
        let plain = try #require(try JSONSerialization.jsonObject(with: fresh.body()) as? [String: Any])
        #expect(plain["editing"] == nil && plain["deviceTools"] == nil, "a new page has no change, and no tools unless it's given them")
    }

    @Test("The phone's tools go with the request as the phone gives a model its tools")
    @MainActor func toolsInRequest() throws {
        let tool = TravelTool(log: LiveLog())
        let devices = DeviceTools([DeviceTools.Entry(tool)])
        var start = ComposeStart(intent: "how long to drive to the airport", image: nil, page: UUID(), context: [])
        start.deviceTools = devices.definitions
        let text = String(decoding: try start.body(), as: UTF8.self)
        let body = try #require(try JSONSerialization.jsonObject(with: start.body()) as? [String: Any])
        let tools = try #require(body["deviceTools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["travel"] && (tools[0]["description"] as? String)?.contains("Apple Maps") == true)
        // What ChatCompletions sends a model for the same tool: properties in the order declared.
        let schema = String(decoding: try ChatCompletions.ordered(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))), as: UTF8.self)
        #expect(text.contains("\"parameters\":" + schema), "its arguments' schema, byte for byte as a model request carries it")
        #expect(!text.contains("x-order"))
        let order = ["\"name\":{", "\"from\":{", "\"to\":{", "\"travel\":{"].compactMap { schema.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted(), "name, from, to, travel, as declared")
    }

    @Test("A deviceTool event reads as a call to run")
    func deviceToolEvents() {
        let call = DeviceToolCall(id: "call-1", name: "travel", arguments: #"{"to":"the airport"}"#)
        #expect(event(#"{"seq":1,"type":"deviceTool","call":{"id":"call-1","name":"travel","arguments":"{\"to\":\"the airport\"}"}}"#)?.kind == .deviceTool(call))
        #expect(event(#"{"seq":2,"type":"deviceTool","call":{"id":"call-1","name":"travel","arguments":{"to":"the airport"}}}"#)?.kind == .deviceTool(call),
                "arguments already read are written back as JSON")
        #expect(event(#"{"seq":3,"type":"deviceTool","call":{"id":"call-2","name":"travel"}}"#)?.kind == .deviceTool(DeviceToolCall(id: "call-2", name: "travel", arguments: "{}")))
        #expect(event(#"{"seq":4,"type":"deviceTool","call":{"name":"travel","arguments":"{}"}}"#)?.kind == .other("deviceTool"), "a call without its id can't be answered")
        #expect(event(#"{"seq":5,"type":"deviceTool"}"#)?.kind == .other("deviceTool"))
        #expect(EventLine.event(#"data: {"seq":6,"type":"deviceTool","call":{"id":"c","name":"travel","arguments":"{}"}}"#)?.seq == 6)
        guard case .deviceTool(let timed)? = event(#"{"seq":7,"type":"deviceTool","call":{"id":"c","name":"travel","arguments":"{}"},"deadline":1793270400000}"#)?.kind else {
            Issue.record("a call with its deadline")
            return
        }
        #expect(timed.deadline == Date(timeIntervalSince1970: 1_793_270_400), "with when the server stops waiting on it, from milliseconds since 1970")
        #expect(call.deadline == nil, "and none from a server that doesn't say")
    }

    @Test("A change keeps the page on screen until the changed one is done")
    func changeProgress() {
        var current = sharedSplit()
        current.locale = SurfaceLocale(language: "en", measurementSystem: "uksystem")
        current.answers = [Answer(question: destination, choice: "Goa")]
        let typed = PageChange.instruction("add a tip", focus: "hero", on: current, values: [:])

        var progress = PageProgress(change: typed, intent: "split a dinner")
        #expect(progress.surface == current && progress.phase.isBusy, "the page as it was, working from the first moment")
        progress.apply(ComposeEvent(seq: 1, kind: .phase(.composing)))
        progress.apply(ComposeEvent(seq: 2, kind: .surface(billSplit(blocks: 1))))
        #expect(progress.surface == current && !progress.isThinking, "not the change half written")
        progress.apply(ComposeEvent(seq: 3, kind: .done(sharedSplit(people: 4), model: "grok-4.7")))
        #expect(progress.phase == .done && progress.surface?.input("people")?.initial == 4)
        #expect(progress.surface?.answers == current.answers, "carrying the answers the page was built from")
        #expect(progress.surface?.locale?.measurementSystem == "uksystem", "in the units of the page it changed")

        var unreadable = PageProgress(change: typed, intent: "split a dinner")
        unreadable.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 1))))
        unreadable.apply(ComposeEvent(seq: 2, kind: .done(nil, model: "grok-4.7")))
        #expect(unreadable.phase == .done && unreadable.surface?.blocks.count == 1, "a finished change this version can't read is the latest it sent")

        var nothing = PageProgress(change: typed, intent: "split a dinner")
        nothing.apply(ComposeEvent(seq: 1, kind: .done(nil, model: "")))
        #expect(nothing.phase == .failed("Nothing came out of this. Try asking another way.") && nothing.surface == current, "and with none, the page stays as it was")

        var failing = PageProgress(change: typed, intent: "split a dinner")
        failing.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 1))))
        failing.apply(ComposeEvent(seq: 2, kind: .failed("The model stopped making progress.")))
        #expect(failing.surface == current, "so does a change that fails")

        var answering = PageProgress(change: .answer(current.answers![0], to: "Pune", on: current, values: [:]), intent: "split a dinner")
        answering.apply(ComposeEvent(seq: 1, kind: .done(current, model: "grok-4.7")))
        #expect(answering.surface?.answers == [Answer(question: destination, choice: "Pune")], "a different answer is the one the page carries")

        var again = PageProgress(change: .again("split a dinner", on: current, values: [:]), intent: "split a dinner")
        #expect(again.surface == nil, "made again, it forms as a new page does")
        again.apply(ComposeEvent(seq: 1, kind: .surface(billSplit(blocks: 1))))
        #expect(again.surface?.blocks.count == 1)
    }

    @Test("A change keeps the user's numbers where it left their input alone")
    func keptValues() {
        let values = ["bill": 3000.0, "people": 5, "tip": 10]
        let typed = PageChange.instruction("make it 4 people", focus: nil, on: sharedSplit(), values: values)
        #expect(typed.kept(after: sharedSplit(people: 4)) == ["bill": 3000], "the bill stays theirs; people starts where the change put it; tip has no input")
        #expect(typed.kept(after: sharedSplit()) == ["bill": 3000, "people": 5])
        #expect(PageChange.again("split", on: sharedSplit(), values: values).kept(after: sharedSplit(people: 4)) == values, "made again, they stay as they were, as here")
        #expect(PageChange.decoded(typed.encoded()) == typed, "kept while it's made, and read back the same")
    }

    @Test("A call to the phone's tools runs here, and what it returned goes back to the job")
    @MainActor func toolRoundTrip() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .phase(.researching))),
            .event(ComposeEvent(seq: 2, kind: .deviceTool(counting))),
            // Looking things up goes on beside it.
            .event(ComposeEvent(seq: 3, kind: .trace(.search, "open tasks"))),
            .awaitOutput(.seconds(5)),
            .event(ComposeEvent(seq: 4, kind: .surface(billSplit(blocks: 1)))),
            .event(ComposeEvent(seq: 5, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        let devices = DeviceTools([tool.entry()])
        var kept: [String] = []
        devices.onRun = { kept.append($0) }
        let follow = watch(server)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.count == 1 && tool.calls.first.flatMap { try? JSONValue(json: $0) } == .object(["what": .string("tasks")]), "run once, with what the model sent")
        #expect(server.returned == [DeviceToolOutput(id: "call-1", output: "3 tasks")], "and what it returned went back")
        #expect(kept == ["call-1"], "kept as it started")
        #expect(follow.progress.calls.isEmpty)
    }

    @Test("What a tool returned after the job went on without it is let go")
    @MainActor func movedOn() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(counting))),
            .awaitOutput(.seconds(5)),
            .event(ComposeEvent(seq: 2, kind: .surface(billSplit(blocks: 1)))),
            .event(ComposeEvent(seq: 3, kind: .done(billSplit(), model: "grok-4.7"))),
        ]], movedOn: true)
        let devices = DeviceTools([Counting().entry()])
        let follow = watch(server)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done, "the page goes on")
        #expect(server.returned.count == 1, "sent once, and not again after a 409")
        #expect(follow.progress.log.contains("Dream's server had gone on without count, so what it returned wasn't needed."))
    }

    @Test("A call the loop went past, read again from the first event, is never run")
    @MainActor func wentPast() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(counting))),
            .event(ComposeEvent(seq: 2, kind: .log("count couldn't be read: no answer in time"))),
            .event(ComposeEvent(seq: 3, kind: .surface(billSplit(blocks: 1)))),
            .awaitOutput(.milliseconds(400)),
            .event(ComposeEvent(seq: 4, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        let devices = DeviceTools([tool.entry()])
        let follow = watch(server)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.isEmpty && server.returned.isEmpty, "the page was written after it, so nothing ran, and nothing was sent")
    }

    @Test("A call run before the app last closed isn't run again")
    @MainActor func ranBefore() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(counting))),
            .awaitOutput(.milliseconds(400)),
            .event(ComposeEvent(seq: 2, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        let devices = DeviceTools([tool.entry()], ran: ["call-1"])
        let follow = watch(server)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.isEmpty && server.returned.isEmpty)
    }

    @Test("A call still waiting when the server stops waiting is given up on, and nothing is sent")
    @MainActor func patience() async {
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(counting))),
            .awaitOutput(.seconds(1)),
            .event(ComposeEvent(seq: 2, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        // Like a question about it waiting on the user.
        let devices = DeviceTools([tool.entry(taking: .seconds(30))])
        let follow = watch(server)
        follow.patience = .milliseconds(200)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.count == 1 && server.returned.isEmpty, "it began, was stopped, and nothing went back")
        #expect(follow.progress.log.contains("Dream's server went on without count, so what it returned wasn't sent."))
    }

    @Test("A call read again runs only before its deadline, and waits on the user until a little before it")
    @MainActor func deadlines() async {
        var stale = counting
        stale.id = "call-stale"
        stale.deadline = Date.now.addingTimeInterval(-60)
        var close = counting
        close.id = "call-close"
        close.deadline = Date.now.addingTimeInterval(3)
        var fresh = counting
        fresh.id = "call-fresh"
        fresh.deadline = Date.now.addingTimeInterval(600)
        // As the app opened from a notification reads the page from its first event.
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(stale))),
            .event(ComposeEvent(seq: 2, kind: .deviceTool(close))),
            .event(ComposeEvent(seq: 3, kind: .deviceTool(fresh))),
            .awaitOutput(.seconds(5)),
            .event(ComposeEvent(seq: 4, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        let devices = DeviceTools([tool.entry()])
        let follow = watch(server)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.count == 1 && server.returned.map(\.id) == ["call-fresh"], "only the call the server still waits on runs, and goes back")
        #expect(follow.progress.log.filter { $0 == "Dream's server had stopped waiting on count, so it wasn't run." }.count == 2,
                "one past its deadline, or too close to it, isn't run at all")

        #expect(follow.timeLeft(for: counting) == follow.patience, "a call from a server that sends no deadline waits its minute, less the margin")
        let left = follow.timeLeft(for: fresh, at: fresh.deadline!.addingTimeInterval(-65)) ?? .zero
        #expect(left > .seconds(59) && left <= .seconds(60), "one with ten minutes waits until a little before them: \(left)")
        #expect(follow.timeLeft(for: fresh, at: fresh.deadline!.addingTimeInterval(-4)) == nil, "and none once that's past")
    }

    @Test("A call still waiting on the user near its deadline is given up on, and nothing is sent")
    @MainActor func nearDeadline() async {
        var call = counting
        call.deadline = Date.now.addingTimeInterval(1.2)
        let server = ScriptedServer([[
            .event(ComposeEvent(seq: 1, kind: .deviceTool(call))),
            .awaitOutput(.seconds(2)),
            .event(ComposeEvent(seq: 2, kind: .done(billSplit(), model: "grok-4.7"))),
        ]])
        let tool = Counting()
        let devices = DeviceTools([tool.entry(taking: .seconds(30))])
        let follow = watch(server)
        follow.margin = .milliseconds(500)
        follow.runTool = { await devices.run($0) }
        #expect(await follow.run() == .done)
        #expect(tool.calls.count == 1 && server.returned.isEmpty, "it began, was stopped before the deadline, and nothing went back")
        #expect(follow.progress.log.contains("Dream's server went on without count, so what it returned wasn't sent."))
    }

    @Test("A call to a tool this iPhone doesn't offer, or with arguments that aren't JSON, says so")
    @MainActor func unknownTools() async throws {
        let devices = DeviceTools([Counting().entry()])
        let unknown = try #require(await devices.run(DeviceToolCall(id: "a", name: "linear_issues", arguments: "{}")))
        #expect(unknown.output.contains("isn't available on the user's iPhone"))
        let broken = try #require(await devices.run(DeviceToolCall(id: "b", name: "count", arguments: "{not json")))
        #expect(broken.output.contains("weren't JSON"))
    }
}
