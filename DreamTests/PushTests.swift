import Foundation
import Testing
@testable import Dream

// Notifications from Dream's server, without APNs or an iPhone (Push.swift): what one carries,
// where tapping one goes, which of Apple's servers this build's token is for, and the line to a
// page let go of while the app is away, so the server knows to notify.

private let page = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
private let jobID = String(repeating: "ab", count: 32)

/// A notification's userInfo, as APNs hands it over.
private func userInfo(page: String = page.uuidString, job: String? = jobID, kind: String = "done") -> [AnyHashable: Any] {
    var info: [AnyHashable: Any] = ["aps": ["alert": ["title": "Your page is ready", "body": "Dinner split"], "sound": "default"], "page": page, "kind": kind]
    info["job"] = job
    return info
}

/// A provisioning profile as Xcode embeds one: its property list inside a signed envelope.
private func profile(_ environment: String?) -> Data {
    var entitlements: [String: Any] = ["application-identifier": "DR99P625RR.xyz.onlychan.Dream"]
    entitlements["aps-environment"] = environment
    let plist = try! PropertyListSerialization.data(fromPropertyList: ["Name": "Dream Development", "Entitlements": entitlements], format: .xml, options: 0)
    return Data([0x30, 0x82, 0x4e, 0x1a, 0x06, 0x09, 0x2a, 0x86]) + plist + Data([0xa0, 0x82, 0x03, 0x00, 0x30])
}

/// A line to the server that plays each connection's events, then stays open and quiet until
/// it's let go of, as a page being made does.
private final class QuietLine: ComposeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [Int] = []
    private let script: [[ComposeEvent]]

    init(_ script: [[ComposeEvent]]) {
        self.script = script
    }

    /// The `after` each connection asked for, in order.
    var afters: [Int] { lock.withLock { opened } }

    func start(_ start: ComposeStart) async throws -> String { jobID }

    func events(_ job: String, after seq: Int) -> AsyncThrowingStream<ComposeEvent, Error> {
        let index = lock.withLock {
            opened.append(seq)
            return opened.count - 1
        }
        let events = script[min(index, script.count - 1)]
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events where event.seq > seq { continuation.yield(event) }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func answer(_ job: String, _ answers: [Answer]) async throws {}

    func output(_ job: String, _ output: DeviceToolOutput) async throws {}
}

/// Waits for `ready`, for a second at most.
@MainActor
private func soon(_ ready: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if ready() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return ready()
}

@Suite("Notifications from Dream's server")
struct PushTests {
    @Test("A notification carries its page, its job and what happened")
    func payload() {
        #expect(PushPayload(userInfo()) == PushPayload(page: page, job: jobID, kind: .done))
        #expect(PushPayload(userInfo(page: page.uuidString.lowercased(), kind: "asking")) == PushPayload(page: page, job: jobID, kind: .asking), "a page's id in either case")
        #expect(PushPayload(userInfo(page: "page-1")) == nil, "a page id that isn't one")
        #expect(PushPayload(userInfo(job: nil)) == nil && PushPayload(userInfo(job: "")) == nil, "no job")
        #expect(PushPayload(userInfo(kind: "shared")) == nil, "something this version doesn't know")
        #expect(PushPayload(["aps": ["alert": "Hello"]]) == nil, "anything that isn't about a page")
        #expect(PushPayload(userInfo())?.serverJob == ServerJob(id: jobID, page: page), "and the job, as the shelf follows it")
    }

    @Test("Tapping one opens the saved page, else the one being made, else the shelf")
    func opening() {
        typealias Opening = PushOpening<String, String>
        let done = PushPayload(page: page, job: jobID, kind: .done)
        let asking = PushPayload(page: page, job: jobID, kind: .asking)
        let saved: (UUID) -> String? = { $0 == page ? "saved" : nil }
        let forming: (UUID) -> String? = { $0 == page ? "forming" : nil }
        let none: (UUID) -> String? = { _ in nil }
        #expect(Opening.destination(for: done, saved: saved, forming: forming) == .page("saved"), "a finished page that's saved opens")
        #expect(Opening.destination(for: asking, saved: saved, forming: forming) == .page("saved"), "a question about a page that has since been made opens the page")
        #expect(Opening.destination(for: asking, saved: none, forming: forming) == .forming("forming"), "a question opens the page being made")
        #expect(Opening.destination(for: done, saved: none, forming: forming) == .forming("forming"), "so does a page that's done before sync has brought it")
        #expect(Opening.destination(for: done, saved: none, forming: none) == .shelf, "neither here: the shelf")
        #expect(Opening.destination(for: nil, saved: saved, forming: forming) == .shelf, "a notification that isn't about a page: the shelf")
    }

    @Test("A development build's token is the sandbox's; any other build's, production's")
    func environment() {
        #expect(PushEnvironment.of(profile: profile("development")) == .sandbox)
        #expect(PushEnvironment.of(profile: profile("production")) == .production, "ad hoc")
        #expect(PushEnvironment.of(profile: nil) == .production, "the App Store and TestFlight embed no profile")
        #expect(PushEnvironment.of(profile: profile(nil)) == .production && PushEnvironment.of(profile: Data("not a profile".utf8)) == .production, "a profile without push, or that can't be read")
        #expect(Data([0x0a, 0xff, 0x00, 0x7b]).hexToken == "0aff007b", "and the token goes as lowercase hex")
    }

    @Test("Leaving the app lets go of the line until it's back, and nothing is missed")
    @MainActor func leaving() async {
        let surface = Surface(title: "Tea", summary: "A page about tea.", symbol: "cup.and.saucer", accent: .green, inputs: [], outputs: [],
                              blocks: [Block(id: "about", kind: .paragraph, text: "Tea is a drink made by steeping leaves.")], related: [], reference: nil)
        let started = [ComposeEvent(seq: 1, kind: .phase(.composing)), ComposeEvent(seq: 2, kind: .log("Check: nothing to ask (1.0s)"))]
        let line = QuietLine([started, started + [ComposeEvent(seq: 3, kind: .done(surface, model: "grok-4.7"))]])
        let watch = ServerWatch(job: ServerJob(id: jobID, page: page), progress: PageProgress(intent: "a page about tea"), transport: line)
        watch.delay = { _ in .zero }
        let running = Task { await watch.run() }
        #expect(await soon { watch.progress.seq == 2 })
        watch.leave()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(line.afters == [0], "no line is open while the app is away, so the server notifies instead")
        watch.reconnect()
        #expect(await running.value == .done, "back in the app, the page is followed to its end")
        #expect(line.afters == [0, 2] && watch.progress.surface?.title == "Tea", "from the last event seen")
    }
}
