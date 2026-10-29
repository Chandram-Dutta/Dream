import CoreGraphics
import Foundation

// Follows pages made by a scripted server (Tools/compose-mock.py) through the app's own client,
// over the network, as the phone does: a page to its end, a line that drops mid-page, a question
// and its answer, a failure, a page picked up again from its first event after the app left it,
// a job the server doesn't have, and a photo. Built and run by Tools/compose-check.sh, which
// starts the mock; settings as for the bench, like "-shareServer http://127.0.0.1:8790".

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

        var request: String
        var image: String?
        var model: String?
        var locale: Place
        var context: [String]
        var pageID: String
    }

    var request: Request
    var answers: [[Answer]]
    var readings: [Int]
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
}

await run()
print(failures == 0 ? "\nEverything as expected." : "\n\(failures) not as expected.")
exit(failures == 0 ? 0 : 1)
