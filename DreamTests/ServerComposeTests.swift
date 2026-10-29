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
        if movedOn { throw ComposeFailure.movedOn }
        outputs.continuation.yield()
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
