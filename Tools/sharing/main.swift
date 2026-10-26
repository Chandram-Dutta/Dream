import Foundation

// Checks sharing without the app: what leaves the phone, what the web viewer is given, and how a
// shared surface is checked when it comes back, including ones built to cause trouble. Build and
// run with Tools/sharing.sh. With DREAM_SHARE_URL set (say, to `npx wrangler dev` in Server/),
// it also uploads to the Worker and opens the link again.

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

/// A surface with a bit of everything that's shared: a calculation, an equation, a chart, real
/// figures, a list with starters, a recording, a source and a locale. Plus personal answers.
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

let surface = sample()

print("What leaves the phone")
expect(surface.shareable.answers == nil && surface.answers?.count == 3, "answers are left out of the shareable template, and kept on the phone's copy")
expect(surface.mentionedAnswers == ["Pune"], "a personal answer the text repeats is noticed (Pune), one it doesn't isn't (Vegetarian)")
let blank = SharedSurface(sharing: surface, values: ["days": 4, "hotel": 3000], currency: "INR")
expect(blank.values == nil, "numbers left at their starting values aren't 'my numbers'")
let mine = SharedSurface(sharing: surface, values: ["days": 7, "hotel": 4500, "rate": 9, "unknown": 3, "walk": .infinity], currency: "INR")
expect(mine.values == ["days": 7, "hotel": 4500], "only numbers the user set on adjustable inputs are shared")
let upload = try! mine.json
let uploadText = String(decoding: upload, as: UTF8.self)
expect(!uploadText.contains("Vegetarian") && !uploadText.contains("Home city") && !uploadText.contains("\"answers\""), "no answer or question text in what's uploaded")
expect(!uploadText.contains("Charger") || surface.collections?.first?.starters.count == 2, "list starters travel with the template")
expect(upload.count < 40_000, "a typical surface uploads in well under the limit (\(upload.count) bytes)")
let uploaded = object(upload)
expect((uploaded["surface"] as? [String: Any])?["locale"] != nil && (uploaded["surface"] as? [String: Any])?["reference"] != nil, "the locale, reference and credits are kept")
expect(uploaded["currency"] as? String == "INR", "with the currency money is written in")

print("\nWhat the web viewer is given")
let preview = mine.preview!
expect(preview.values["days"] == "7", "values as shown, at the sharer's numbers")
expect(preview.values["total"]?.contains("33") == true, "outputs worked out with the sharer's numbers and the list's starters (\(preview.values["total"] ?? "nil"))")
expect(preview.values["distance"]?.contains("km") == true, "with their units (\(preview.values["distance"] ?? "nil"))")
expect(preview.equations["total"]?.equation.hasPrefix("T =") == true, "the equation, written from the formula")
expect(preview.equations["total"]?.worked?.contains("7") == true, "worked through with the numbers")
expect(preview.charts["chart"]?.lines.first?.points.count == 14, "the chart's line, one point a day")
expect(preview.charts["chart"]?.lines.first?.points.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } == true, "as finite x, y pairs")
expect(SharedSurface(sharing: surface, values: nil).preview?.values["days"] == "4", "a blank share's preview is at the starting values")

print("\nOpening a share")
let received = try! SharedSurface.received(upload)
expect(received.surface.title == surface.title && received.surface.blocks.map(\.id) == surface.blocks.map(\.id), "the surface comes back whole")
expect(received.surface.inputs == surface.inputs && received.surface.outputs == surface.outputs, "with its calculation unchanged by checking it again")
expect(received.surface.answers == nil, "and no answers")
expect(received.values == ["days": 7, "hotel": 4500], "the sharer's numbers")
expect(received.surface.locale == surface.locale, "the locale it was written for, so it can be translated")
expect(received.surface.sounds?.first?.recording != nil && received.surface.reference?.imageURL != nil, "Wikimedia recordings and images stay")
expect(received.surface.citations == surface.citations && received.surface.credits.map(\.site) == ["Wikipedia", "Lonely Planet"], "the sources it credits, Wikipedia first")

func tampered(_ change: (inout [String: Any]) -> Void) -> Data {
    var payload = object(upload)
    var surface = payload["surface"] as! [String: Any]
    change(&surface)
    payload["surface"] = surface
    return json(payload)
}

func error(_ data: Data) -> ShareError? {
    do {
        _ = try SharedSurface.received(data)
        return nil
    } catch {
        return error as? ShareError
    }
}

let elsewhere = try! SharedSurface.received(tampered({ surface in
    surface["reference"] = ["title": "Pune", "extract": "", "url": "https://evil.example/wiki/Pune", "imageURL": "https://evil.example/a.png"]
    var sounds = surface["sounds"] as! [[String: Any]]
    var recording = sounds[0]["recording"] as! [String: Any]
    recording["audioURL"] = "https://tracker.example/a.ogg"
    sounds[0]["recording"] = recording
    surface["sounds"] = sounds
}))
expect(elsewhere.surface.reference == nil, "a source that isn't Wikipedia is dropped")
expect(elsewhere.surface.sounds == nil && !elsewhere.surface.blocks.contains { $0.kind == .sound }, "a recording from anywhere but Wikimedia is dropped, with its block")
let wikiImage = try! SharedSurface.received(tampered({ surface in
    surface["reference"] = ["title": "Pune", "extract": "", "url": "https://de.wikipedia.org/wiki/Pune", "imageURL": "http://upload.wikimedia.org/a.png"]
}))
expect(wikiImage.surface.reference?.url == "https://de.wikipedia.org/wiki/Pune" && wikiImage.surface.reference?.imageURL == nil, "an image not on Wikimedia over https is dropped, the source kept")
let cited = try! SharedSurface.received(tampered({ surface in
    let page = { (url: String) -> [String: Any] in ["title": "A page", "site": "", "url": url] }
    surface["citations"] = [page("javascript:alert(1)"), page("ftp://files.example/a"), page("https://user:pw@evil.example/"), page("https://news.example/a"), page("https://news.example/a/#top"), page("https://en.wikipedia.org/wiki/Pune")]
        + (0..<12).map { page("http://site\($0).example/") }
}))
let citedURLs = cited.surface.citations?.map(\.url) ?? []
expect(!citedURLs.contains { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") } && !citedURLs.contains { $0.contains("@") }, "only http(s) sources stay, without names or passwords in them")
expect(citedURLs.first == "https://news.example/a" && citedURLs.filter { $0.hasPrefix("https://news.example") }.count == 1, "a source named twice is credited once")
expect(!citedURLs.contains("https://en.wikipedia.org/wiki/Pune"), "the reference isn't credited twice")
expect(citedURLs.count == Checker.citationLimit && cited.surface.citations?.first?.site == "news.example", "at most \(Checker.citationLimit), each with a site name")
let answered = try! SharedSurface.received(tampered { $0["answers"] = [["question": ["text": "Where?", "topic": "City", "options": []], "choice": "Delhi"]] })
expect(answered.surface.answers == nil, "answers sent anyway are dropped")
let foreign = try! SharedSurface.received(tampered { $0["locale"] = nil })
expect(foreign.surface.locale?.language == "en", "a share without a locale gets one from its text")
let odd = try! SharedSurface.received(tampered { $0["locale"] = ["language": "<script>", "measurementSystem": "imperial"] })
expect(odd.surface.locale?.language == "en" && odd.surface.locale?.measurementSystem != "imperial", "a locale that isn't one is worked out again")
var outOfRange = object(upload)
outOfRange["values"] = ["days": 900, "rate": 50, "nothing": 1]
let clamped = try! SharedSurface.received(json(outOfRange))
expect(clamped.values == ["days": 14], "numbers are kept inside their ranges, and only for adjustable inputs")
let longFormula = try! SharedSurface.received(tampered({ surface in
    var outputs = surface["outputs"] as! [[String: Any]]
    outputs[1]["formula"] = Array(repeating: "1", count: 1_900).joined(separator: "+")
    surface["outputs"] = outputs
}))
expect(longFormula.surface.evaluate(longFormula.surface.initialValues).values["distance"]?.isNaN != false, "a formula built to exhaust the stack is refused, not evaluated")
expect(error(tampered({ surface in
    var nested: Any = ["id": "x", "kind": "paragraph", "text": "deep"]
    for _ in 0..<40 { nested = ["id": "s", "kind": "section", "children": [nested]] }
    surface["blocks"] = [nested]
})) == .unreadable, "deeply nested blocks are refused before decoding")
expect(error(tampered { $0["summary"] = String(repeating: "(", count: 60) + "x" }) == .unreadable, "deeply bracketed text is refused before maths or formulas parse it")
expect(error(tampered { $0["title"] = String(repeating: "a", count: 5_000) }) == .unreadable, "very long text is refused")
expect(error(Data(repeating: 32, count: SharedSurface.maxSize + 1)) == .tooBig, "anything over the size limit is refused unread")
expect(error(Data("{\"format\":1}".utf8)) == .unreadable, "something that isn't a surface is refused")
var newer = object(upload)
newer["format"] = 2
expect(error(json(newer)) == .newer, "a newer format says so")
expect(error(tampered({ surface in
    surface["title"] = ""
    surface["summary"] = ""
    surface["blocks"] = []
    surface["inputs"] = []
    surface["outputs"] = []
})) == .empty, "an empty surface is refused")
let manyBlocks = try! SharedSurface.received(tampered({ surface in
    surface["blocks"] = (0..<300).map { ["id": "p\($0)", "kind": "paragraph", "title": "", "text": "Line \($0).", "ref": "", "over": "", "items": [], "children": []] }
}))
expect(manyBlocks.surface.blocks.count <= 70, "a share with hundreds of blocks is cut down")

print("\nLinks")
let base = URL(string: "https://dream-share.example.workers.dev")!
expect(ShareServer.normalized("dream-share.example.workers.dev/") == base, "a bare host becomes an https server")
expect(ShareServer.normalized("http://dream-share.example.workers.dev") == nil, "plain http is refused, except on this Mac")
expect(ShareServer.normalized("http://127.0.0.1:8787") != nil, "a local wrangler dev server is allowed")
expect(ShareServer.normalized("dream-share.invalid") == nil, "the placeholder host counts as unset")
UserDefaults.standard.set(base.absoluteString, forKey: "shareServer")
expect(SharedLink(URL(string: "https://dream-share.example.workers.dev/s/AbCdE12345")!)?.id == "AbCdE12345", "a link to this server opens")
expect(SharedLink(URL(string: "dream://s/AbCdE12345")!)?.base == base, "dream://s/<id> opens from this server")
expect(SharedLink(URL(string: "https://elsewhere.example/s/AbCdE12345")!) == nil, "a link to another server doesn't")
expect(SharedLink(URL(string: "dream://s/AbCdE12345/../../x")!) == nil && SharedLink(URL(string: "dream://s/short")!) == nil, "malformed ids don't")
UserDefaults.standard.removeObject(forKey: "shareServer")
expect(SharedLink(address: "https://dream.onlychan.xyz/s/AbCdE12345")?.id == "AbCdE12345" && SharedLink(address: "https://dream.onlychan.xyz/x/AbCdE12345") == nil, "a shelf page's link is read back from where it was opened")

print("\nYour links, and refusals")
let listing = Data("""
{"shares":[{"id":"AbCdE12345","url":"https://dream.onlychan.xyz/s/AbCdE12345","page":"7D2A","title":"Split a bill","accent":"orange","symbol":"fork.knife",
"created":1761400000,"updated":1761500000,"hasValues":true,"views":12,"expiresAt":null,"state":"shared"},
{"id":"ZyXwV98765","url":"https://dream.onlychan.xyz/s/ZyXwV98765","page":null,"title":"Old","accent":"ultraviolet","symbol":null,
"created":1761400000,"updated":1761400000,"hasValues":false,"views":0,"expiresAt":1761600000,"state":"somethingnew"}]}
""".utf8)
struct Listing: Decodable { let shares: [OwnedLink] }
let owned = (try? JSONDecoder().decode(Listing.self, from: listing))?.shares ?? []
expect(owned.count == 2 && owned[0].views == 12 && owned[0].hasValues && owned[0].accent == .orange && owned[0].isShared, "links decode, with views, numbers and colors")
expect(owned.count == 2 && owned[1].accent == nil && owned[1].expiresAt != nil && !owned[1].isShared, "an unknown color or state doesn't stop a link decoding")
let refusal = { (status: Int, json: String) in ServerError(status: status, data: Data(json.utf8)).localizedDescription }
expect(refusal(422, #"{"error":"…","reason":"slur"}"#).contains("slur") && refusal(422, #"{"reason":"private"}"#).contains("private details"), "the publish check's refusals say why, in Dream's words")
expect(refusal(403, #"{"reason":"blocked"}"#).contains("chose not to see") && refusal(410, "{}") == "This page is no longer shared.", "and so do blocked and stopped pages")
expect(refusal(401, "not json") == "Sign in to share links.", "making a link signed out asks for signing in")

if let server = ProcessInfo.processInfo.environment["DREAM_SHARE_URL"].flatMap(ShareServer.normalized) {
    print("\nThrough the Worker at \(server.absoluteString)")
    UserDefaults.standard.set(server.absoluteString, forKey: "shareServer")
    defer { UserDefaults.standard.removeObject(forKey: "shareServer") }
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
}

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
