import Foundation

// Sharing through the Worker and back: uploads a surface to DREAM_SHARE_URL (say, `npx wrangler
// dev` in Server/), opens the link again, and reads the web viewer. Run with Tools/sharing.sh,
// which first runs the checks that need no server (DreamTests/SharingTests.swift): what leaves
// the phone, the web viewer's preview, and opening shared surfaces as untrusted input.

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

/// The same surface DreamTests shares: a bit of everything that's shared, plus personal answers.
func sample() -> Surface {
    var surface = Surface(
        title: "Pune trip budget",
        summary: "What a {days}-day trip costs, with $\\frac{total}{days}$ a day.",
        symbol: "airplane",
        accent: .teal,
        inputs: [
            Input(name: "days", label: "Days", format: .integer, initial: 4, min: 1, max: 14, step: 1, options: []),
            Input(name: "hotel", label: "Hotel a night", format: .currency, initial: 3000, min: 500, max: 20000, step: 100, options: []),
            Input(name: "walk", label: "Walking a day", format: .number, initial: 5, min: 0, max: 30, step: 0.5, options: [], unit: "km"),
            Input(name: "rate", label: "Fees", format: .percent, initial: 5, min: 0, max: 5, step: 5, options: [], role: .given),
        ],
        outputs: [
            Output(name: "total", label: "Total", formula: "days * hotel * (1 + rate / 100) + sum(packing.cost)", format: .currency, symbol: "T"),
            Output(name: "distance", label: "Distance walked", formula: "days * walk", format: .number, unit: "km"),
        ],
        blocks: [
            Block(id: "hero", kind: .hero, ref: "total"),
            Block(id: "controls", kind: .section, title: "Your trip", children: [
                Block(id: "days", kind: .stepper, ref: "days"),
                Block(id: "hotel", kind: .slider, ref: "hotel"),
                Block(id: "walk", kind: .slider, ref: "walk"),
            ]),
            Block(id: "rate", kind: .metric, ref: "rate"),
            Block(id: "distance", kind: .metric, ref: "distance"),
            Block(id: "chart", kind: .chart, ref: "total", over: "days"),
            Block(id: "equation", kind: .equation, ref: "total"),
            Block(id: "about", kind: .paragraph, title: "Pune", text: "Pune is a city in Maharashtra, about $150$ km from Mumbai."),
            Block(id: "visitors", kind: .data, title: "Visitors (millions)", items: [Item(label: "2019", value: "4.1"), Item(label: "2021", value: "1.9"), Item(label: "2023", value: "5.2")]),
            Block(id: "packing", kind: .list, ref: "packing"),
            Block(id: "add", kind: .add, ref: "packing"),
            Block(id: "sound", kind: .sound, ref: "street"),
        ],
        related: ["Mumbai", "Lonavala"],
        reference: Reference(title: "Pune", extract: "Pune is a city.", url: "https://en.wikipedia.org/wiki/Pune", imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/pune.jpg"))
    surface.sounds = [Sound(name: "street", label: "A Pune street", tones: [], search: "Pune street",
                            recording: Recording(title: "Pune traffic.ogg", audioURL: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Pune_traffic.ogg",
                                                 pageURL: "https://commons.wikimedia.org/wiki/File:Pune_traffic.ogg", credit: "Someone", licence: "CC BY-SA 4.0", duration: 12))]
    surface.collections = [RecordCollection(name: "packing", label: "Packing", entry: "item", fields: [
        RecordField(name: "item", label: "Item", type: .text),
        RecordField(name: "packed", label: "Packed", type: .done),
        RecordField(name: "cost", label: "Cost", type: .currency),
    ], starters: [["item": .text("Umbrella"), "cost": .number(400)], ["item": .text("Charger"), "packed": .number(1)]])]
    surface.answers = [
        Answer(question: Question(text: "Where are you going?", topic: "Destination", options: [], allowsTyping: true, isPersonal: false), choice: "Pune"),
        Answer(question: Question(text: "What do you eat?", topic: "Diet", options: ["Vegetarian", "Anything"], isPersonal: true), choice: "Vegetarian"),
        Answer(question: Question(text: "Where do you live?", topic: "Home city", options: [], allowsTyping: true, isPersonal: true), choice: "Pune"),
    ]
    surface.locale = SurfaceLocale(language: "en", measurementSystem: "metric")
    surface.citations = [Citation(title: "Pune travel guide", site: "Lonely Planet", url: "https://www.lonelyplanet.com/india/pune", date: "2026-10-01")]
    _ = Checker.checkLogic(&surface)
    _ = Checker.checkBlocks(&surface)
    return surface
}

guard let server = ProcessInfo.processInfo.environment["DREAM_SHARE_URL"].flatMap(ShareServer.normalized) else {
    print("Set DREAM_SHARE_URL to a sharing server (like http://127.0.0.1:8787) to go through it.")
    exit(1)
}

let surface = sample()
let mine = SharedSurface(sharing: surface, values: ["days": 7, "hotel": 4500, "rate": 9, "unknown": 3, "walk": .infinity], currency: "INR")

print("Through the Worker at \(server.absoluteString)")
UserDefaults.standard.set(server.absoluteString, forKey: "shareServer")
// A test user, from the Worker's dev sign-in (DEV_LOGIN=1 in Server/.dev.vars).
var signIn = URLRequest(url: server.appending(path: "api/dev/session").appending(queryItems: [URLQueryItem(name: "user", value: "sharing-tool")]))
signIn.httpMethod = "POST"
struct DevSession: Decodable { let token: String }
if let (data, _) = try? await URLSession.shared.data(for: signIn), let token = try? JSONDecoder().decode(DevSession.self, from: data).token {
    setenv("DREAM_SESSION", token, 1)
} else {
    print("  (no dev sign-in on this server: set DEV_LOGIN=1 in Server/.dev.vars, or DREAM_SESSION)")
}
do {
    let page = UUID()
    let upload = try await ShareServer.upload(mine, to: server, page: page)
    let link = upload.link
    expect(link.url.absoluteString.hasPrefix(server.absoluteString + "/s/") && !upload.reused, "uploading gives a link (\(link.url.absoluteString))")
    let again = try await ShareServer.upload(mine, to: server, page: page)
    expect(again.reused && again.link == link, "sharing the same page again reuses its link")
    let listed = try await ShareServer.myLinks().first { $0.id == link.id }
    expect(listed?.page == page.uuidString && listed?.hasValues == true && listed?.title == surface.title, "and it's in your links")
    let fetched = try await ShareServer.fetch(link)
    let opened = try SharedSurface.received(fetched)
    expect(opened.surface.inputs == surface.inputs && opened.surface.blocks.map(\.id) == surface.blocks.map(\.id), "it opens as it was shared")
    expect(opened.values == ["days": 7, "hotel": 4500], "with the sharer's numbers")
    let (viewer, _) = try await URLSession.shared.data(from: link.url)
    let html = String(decoding: viewer, as: UTF8.self)
    expect(html.contains("Pune trip budget") && html.contains("class=\"katex\"") && !html.contains("Vegetarian"), "and the web viewer shows it, without the answers")
    expect(html.contains("href=\"https://www.lonelyplanet.com/india/pune\"") && html.contains("CC BY-SA 4.0"), "crediting every source, with Wikipedia's licence")
    expect(html.contains("/s/\(link.id)/report"), "with a way to report it")
    print("  Web viewer: \(link.url.absoluteString)")

    var renamed = surface
    renamed.title = "Pune trip budget, revised"
    let updated = try await ShareServer.update(listed!, to: SharedSurface(sharing: renamed, values: nil))
    expect(updated.title == renamed.title && updated.id == link.id && !updated.hasValues, "updating puts the newest version at the same link")
    try await ShareServer.report(link, reason: .spam, note: "  Checking reports.  ")
    expect(true, "reporting it works")
    let stopped = try await ShareServer.stop(updated)
    expect(stopped.state == .stopped, "stopping it works")
    do {
        _ = try await ShareServer.fetch(link)
        expect(false, "a stopped link doesn't open")
    } catch {
        expect(error.localizedDescription == "This page is no longer shared.", "a stopped link says it's no longer shared")
    }
} catch {
    expect(false, "the round trip through the Worker failed: \(error.localizedDescription)")
}
UserDefaults.standard.removeObject(forKey: "shareServer")

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
