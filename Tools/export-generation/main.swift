import Foundation
import FoundationModels

// Writes what the server sends a model to make a page, from the app's own definitions, so the two
// never drift while both make pages (docs/ServerGeneration.md): the instructions, the page's and
// the gap check's JSON schemas in the order the app sends them, and the tools' descriptions and
// argument schemas. The user's currency is left as {{currency}}, for the server to fill in. The
// instructions come apart too, into the core and each feature's rules with the tools they
// describe, so the server leaves out rules for a tool it doesn't offer.
//
// Then the prompts that wrap something: the request, the answers to the gap check's questions,
// a repair, a change to a page and the block it points at, a different answer, what Dream
// remembers. Each is what the app's own function writes, called with {{slots}} for its
// arguments, and a list's line is a template of its own (Server/src/compose/prompts.ts fills them
// in). And what the tools tell the model, from the tools themselves: when they can't go ahead,
// what recall finds, and how the live tool lists what it read, from a stand-in reading. Their
// answers that need the network to write are in Server/src/compose/tools.ts and live.ts.
//
// Built and run by Tools/export-generation.sh; prints JSON. It never signs in or goes online:
// with no server set, web search fails before it would; the memory and the connected service are
// made up, and the one live reading is a stand-in's.

func schema(_ value: GenerationSchema) throws -> String {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return String(decoding: try ChatCompletions.ordered(object), as: UTF8.self)
}

func string(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

let log = WebLog()
// In the order a page is written with them (Composer.tools); a connected service's go after live.
let tools: [any Tool] = [LookupTool(found: ReferenceLog()), RecallTool(), LiveTool(log: LiveLog()), SearchTool(log: log), ReadTool(log: log)]
let toolLines = try tools.map { tool in
    "{\"name\":\(string(tool.name)),\"description\":\(string(tool.description)),\"parameters\":\(try schema(tool.parameters))}"
}

/// Anything made of dictionaries, arrays and strings, as JSON with its keys sorted.
func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

/// What's between two markers in `text`, which holds each once.
func between(_ start: String, _ end: String, in text: String) -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
        preconditionFailure("\(start)…\(end) isn't in: \(text)")
    }
    return String(text[a.upperBound..<b.lowerBound])
}

// MARK: - Templates

/// `text` with the one line holding `marker` swapped for `slot`, and that line on its own.
func lifted(_ marker: String, from text: String, as slot: String) -> (text: String, line: String) {
    var lines = text.components(separatedBy: "\n")
    let holding = lines.indices.filter { lines[$0].contains(marker) }
    precondition(holding.count == 1, "\(marker) isn't on one line of: \(text)")
    let line = lines[holding[0]]
    lines[holding[0]] = slot
    return (lines.joined(separator: "\n"), line)
}

func object(_ fields: KeyValuePairs<String, String>) -> String {
    "{" + fields.map { "\(string($0.key)):\(string($0.value))" }.joined(separator: ",") + "}"
}

let asked = Question(text: "{{question}}", topic: "", options: [])
let answered = lifted("{{question}}", from: Prompts.answersContext([Answer(question: asked, choice: "{{choice}}")])[0], as: "{{lines}}")
let leftToDream = lifted("{{question}}", from: Prompts.answersContext([asked.leftToDream])[0], as: "").line
let remembered = lifted("{{question}}", from: Prompts.answersContext([Answer(question: asked, choice: "{{choice}}", isRemembered: true)])[0], as: "").line

let problem = [Issue(kind: .needsModel, message: "{{problem}}")]
let repair = lifted("{{problem}}", from: Prompts.repair(problem), as: "{{problems}}")
// A screen as a repair shows it: its outline, after its calculation when it has one. The
// outline and the calculation are the server engine's (Surface.outline, Surface.logicSummary).
var plain = Surface.empty
plain.title = "\u{1}title"
plain.summary = "\u{1}summary"
var calculating = plain
calculating.inputs = [Input(name: "x", label: "X", format: .number, initial: 1, min: 0, max: 2, step: 1, options: [])]
let restating = lifted("{{problem}}", from: Prompts.repair(problem, restating: "{{asked}}", screen: plain).replacingOccurrences(of: plain.outline, with: "{{screen}}"), as: "{{problems}}").text
let withLogic = lifted("{{problem}}", from: Prompts.repair(problem, restating: "{{asked}}", screen: calculating)
    .replacingOccurrences(of: calculating.logicSummary, with: "{{logic}}").replacingOccurrences(of: calculating.outline, with: "{{outline}}"), as: "{{problems}}").text
let around = restating.components(separatedBy: "{{screen}}")
precondition(around.count == 2 && withLogic.hasPrefix(around[0]) && withLogic.hasSuffix(around[1]), "A screen with a calculation isn't where one without goes")
let screenWithLogic = String(withLogic.dropFirst(around[0].count).dropLast(around[1].count))

let templates = """
{"gapRequest":\(string(Prompts.gapRequest("{{request}}", remembering: []))),\
"gapRequestRemembering":\(string(Prompts.gapRequest("{{request}}", remembering: ["{{topics}}"]))),\
"surfaceRequest":\(object([
    "alone": Prompts.surfaceRequest("{{request}}", hasImage: false, context: []),
    "withContext": Prompts.surfaceRequest("{{request}}", hasImage: false, context: ["{{context}}"]),
    "withPhoto": Prompts.surfaceRequest("{{request}}", hasImage: true, context: []),
    "withPhotoAndContext": Prompts.surfaceRequest("{{request}}", hasImage: true, context: ["{{context}}"]),
])),\
"answers":\(object(["block": answered.text, "line": answered.line, "leftToDream": leftToDream, "remembered": remembered])),\
"repair":\(object(["block": repair.text, "problem": repair.line, "restating": restating, "screen": "{{outline}}", "screenWithLogic": screenWithLogic]))}
"""

// MARK: - What the tools say when they can't go ahead

// Web search fails before anything leaves this Mac when no server is set, as here, and then
// never asks the Keychain for a session.
precondition(WebService.base == nil, "A server is set, so web search would go online")
func message(_ status: Int) -> String { WebError(status: status).errorDescription ?? "" }

let tired = ReferenceLog()
for _ in 0..<ReferenceLog.lookupLimit { _ = tired.mayLookUp() }
let lookupEnough = try await LookupTool(found: tired).call(arguments: .init(subject: "x", language: "en"))
let used = WebLog()
for _ in 0..<WebLog.searchLimit { _ = used.maySearch() }
for _ in 0..<WebLog.readLimit { _ = used.mayRead() }
let searchEnough = try await SearchTool(log: used).call(arguments: .init(question: "x", keywords: "x", freshness: .any, country: ""))
let readEnough = try await ReadTool(log: used).call(arguments: .init(url: "https://example.com/", focus: ""))
let fresh = WebLog()
let notAddress = try await ReadTool(log: fresh).call(arguments: .init(url: "not an address", focus: ""))
let searchFailed = try await SearchTool(log: fresh).call(arguments: .init(question: "x", keywords: "x", freshness: .any, country: ""))
let readFailed = try await ReadTool(log: fresh).call(arguments: .init(url: "https://example.com/", focus: ""))
let reread = WebLog()
reread.read(Citation(title: "x", site: "x", url: "https://example.com/"), at: [])
let readAlready = try await ReadTool(log: reread).call(arguments: .init(url: "https://example.com/", focus: ""))
precondition(searchFailed.hasPrefix(message(-1)) && readFailed.hasPrefix(message(-1)), "Web search didn't fail for want of a server")

let statuses = [-1, 0, 400, 401, 402, 403, 404, 415, 429, 503, 500]
let toolText = """
{"lookupEnough":\(string(lookupEnough)),"searchEnough":\(string(searchEnough)),"readEnough":\(string(readEnough)),\
"readNotAddress":\(string(notAddress)),"readAlready":\(string(readAlready)),\
"searchFailed":\(string(searchFailed.replacingOccurrences(of: message(-1), with: "{{error}}"))),\
"readFailed":\(string(readFailed.replacingOccurrences(of: message(-1), with: "{{error}}"))),\
"webErrors":{\(statuses.map { "\(string(String($0))):\(string(message($0)))" }.joined(separator: ","))}}
"""

// MARK: - Changes to a page

// The screen as a change shows it is the same as a repair's (`screen` and `screenWithLogic`
// above), so only where it goes is kept here.
let editing = Prompts.edit(intent: "{{intent}}", surface: plain, instruction: "{{instruction}}", focus: nil, context: [])
let edit = lifted("{{instruction}}", from: editing.replacingOccurrences(of: plain.outline, with: "{{screen}}"), as: "{{request}}")
let editWithContext = lifted("{{instruction}}", from: Prompts.edit(intent: "{{intent}}", surface: plain, instruction: "{{instruction}}", focus: nil, context: ["{{context}}"])
    .replacingOccurrences(of: plain.outline, with: "{{screen}}"), as: "{{request}}").text
let showingLogic = screenWithLogic.replacingOccurrences(of: "{{logic}}", with: calculating.logicSummary).replacingOccurrences(of: "{{outline}}", with: calculating.outline)
precondition(Prompts.edit(intent: "{{intent}}", surface: calculating, instruction: "{{instruction}}", focus: nil, context: []) == editing.replacingOccurrences(of: plain.outline, with: showingLogic),
             "A change shows the screen another way than a repair")
let pointer = Block(id: "{{id}}", kind: .paragraph)
let pointing = lifted("{{instruction}}", from: Prompts.edit(intent: "{{intent}}", surface: plain, instruction: "{{instruction}}", focus: pointer, context: []), as: "").line
    .replacingOccurrences(of: Prompts.describe(pointer, in: plain), with: "{{block}}")

// The block pointed at, by kind (Prompts.describe). {{Label}} is what the block shows, as the
// screen names it, and {{label}} the same in lower case; a chart's labels are {{labels}}.
var labelled = Surface.empty
labelled.inputs = [("{{ref}}", "{{Label}}"), ("{{ref2}}", "{{Label2}}"), ("{{over}}", "{{Over}}")].map {
    Input(name: $0.0, label: $0.1, format: .number, initial: 0, min: 0, max: 1, step: 1, options: [])
}
labelled.sounds = [Sound(name: "{{ref}}", label: "{{Label}}", tones: [], search: "x", recording: nil)]
labelled.actions = [Action(name: "{{ref}}", kind: "{{actionKind}}", fields: ["title": "{{actionTitle}}"])]
let kinds = ["hero", "metric", "slider", "stepper", "field", "toggle", "picker", "chart", "paragraph", "facts", "bullets", "steps", "timeline", "stat",
             "equation", "data", "section", "row", "sound", "list", "add", "figure", "diagram", "action", "scene"]
var describing: [String: String] = [:]
for name in kinds {
    guard let kind = BlockKind(rawValue: name) else { preconditionFailure("\(name) isn't a block kind") }
    let ref = kind == .chart ? "{{ref}}, {{ref2}}" : "{{ref}}"
    describing[name] = Prompts.describe(Block(id: "{{id}}", kind: kind, ref: ref, over: "{{over}}"), in: labelled)
    describing["\(name) titled"] = Prompts.describe(Block(id: "{{id}}", kind: kind, title: "{{title}}", ref: ref, over: "{{over}}"), in: labelled)
}
describing["equation plain"] = Prompts.describe(Block(id: "{{id}}", kind: .equation), in: labelled)
describing["equation plain titled"] = Prompts.describe(Block(id: "{{id}}", kind: .equation, title: "{{title}}"), in: labelled)
describing["action missing"] = Prompts.describe(Block(id: "{{id}}", kind: .action, ref: "{{ref}}"), in: .empty)
let labelSeparator = between("{{Label}}", "{{Label2}}", in: describing["chart"] ?? "")
for key in ["chart", "chart titled"] {
    describing[key] = describing[key]?.replacingOccurrences(of: "{{Label}}\(labelSeparator){{Label2}}", with: "{{labels}}")
}

// A different answer to one of the questions, in the user's words, from what they said before
// (or left to Dream) to what they say now (or leave to Dream).
let changedQuestion = Question(text: "{{question}}", topic: "", options: [])
let changedAnswer: [String: String] = [
    "said": Prompts.changedAnswer(Answer(question: changedQuestion, choice: "{{before}}"), to: "{{after}}"),
    "saidLeft": Prompts.changedAnswer(Answer(question: changedQuestion, choice: "{{before}}"), to: ""),
    "left": Prompts.changedAnswer(changedQuestion.leftToDream, to: "{{after}}"),
    "leftLeft": Prompts.changedAnswer(changedQuestion.leftToDream, to: ""),
]

// MARK: - What Dream remembers

// The recall tool and the line beside the request, from a memory holding two made-up facts.
Recall.source = .fixed([Remembered(topic: "{{topic}}", detail: "{{detail}}"), Remembered(topic: "{{topic2}}", detail: "{{detail2}}")])
let remembering = await Prompts.memoryContext(for: "x")
precondition(remembering.count == 1, "What Dream remembers isn't one line")
let topicSeparator = between("{{topic}}", "{{topic2}}", in: remembering[0])
precondition(Prompts.gapRequest("{{request}}", remembering: ["{{topics}}"]) == Prompts.gapRequest("{{request}}", remembering: ["{{topic}}", "{{topic2}}"])
    .replacingOccurrences(of: "{{topic}}\(topicSeparator){{topic2}}", with: "{{topics}}"), "The gap check lists topics another way")
let memoryLine = remembering[0].replacingOccurrences(of: "{{topic}}\(topicSeparator){{topic2}}", with: "{{topics}}")
let recalled = lifted("{{detail}}", from: try await RecallTool().call(arguments: .init(topics: ["{{topic}}"])), as: "{{lines}}")
let recalledNothing = try await RecallTool().call(arguments: .init(topics: ["nothing"]))
Recall.source = .fixed([])

// MARK: - Live data

// What the live tool says when a source can't be read, from an exchange rate it can't even ask
// for, and when it can, from a stand-in that reads one made-up field without going online.
let unreadable = Source(name: "rate", kind: "exchangeRate", parameters: ["from": "x", "to": "y"], fields: [])
var unreadableMessage = ""
do { _ = try await LiveSources.read(unreadable) } catch let error as LiveError { unreadableMessage = error.message }
precondition(!unreadableMessage.isEmpty, "A rate without currencies was read")
let liveFailed = try await LiveTool(log: LiveLog()).call(arguments: .init(name: "rate", kind: .exchangeRate, place: "", day: "", time: "", from: "x", to: "y", travel: ""))
    .replacingOccurrences(of: unreadableMessage, with: "{{message}}")

struct OneField: LiveProvider {
    let kind = "exchangeRate"
    let freshness: TimeInterval = 0
    let meaning: String

    func read(_ source: Source) async throws -> SourceReading {
        SourceReading(fields: [SourceField(name: "zqxfield", value: 1, format: .number, meaning: meaning)], summary: "{{summary}}", asOf: .now)
    }
}

func liveAnswer(meaning: String) async throws -> [String] {
    LiveSources.register(OneField(meaning: meaning))
    let answer = try await LiveTool(log: LiveLog()).call(arguments: .init(name: "zqxname", kind: .exchangeRate, place: "", day: "", time: "", from: "USD", to: "INR", travel: ""))
    let lines = answer.replacingOccurrences(of: "zqxname", with: "{{name}}").replacingOccurrences(of: "zqxfield", with: "{{field}}").components(separatedBy: "\n")
    precondition(lines.count == 3 && lines[1].contains(" = 1"), "The live tool's answer isn't a header, a field and how to show it: \(answer)")
    return [lines[0], lines[1].replacingOccurrences(of: " = 1", with: " = {{value}}"), lines[2]]
}
let liveWithMeaning = try await liveAnswer(meaning: "{{meaning}}")
let liveWithout = try await liveAnswer(meaning: "")

// MARK: - Which rules go with which tools

// The server offers the model only tools the instructions describe, and describes only tools it
// offers (Server/src/compose/prompts.ts): a feature's rules go in only when its tools are offered.
// Connected services' rules are written only when the user has connected one, as here.
let surfaceWithoutConnections = Prompts.surface(currency: "{{currency}}")
Connections.source = Connections.Source(
    connections: { [Connection(url: URL(string: "https://example.com/mcp")!, name: "Example")] },
    call: { _, _, _ in throw ConnectionError.unavailable },
    personalDetails: { [] })
precondition(!Prompts.connectionRules.isEmpty, "Connected services have no rules")
let surfaceWithConnections = Prompts.surface(currency: "{{currency}}")
let toolsOf: [String: [String]] = [
    "memory": [RecallTool().name], "live": [LiveTool(log: LiveLog()).name], "web": [SearchTool(log: log).name, ReadTool(log: log).name],
    "lists": [], "figures": [], "scenes": [], "sounds": [], "connections": [], "language": [], "sharing": [],
]
precondition(Set(Prompts.features.map(\.name)) == Set(toolsOf.keys), "A feature's tools aren't said here")
let features: [[String: Any]] = Prompts.features.map { feature in
    ["name": feature.name, "rules": feature.rules, "tools": toolsOf[feature.name] ?? [], "connections": feature.name == "connections"]
}
let surfaceCore = Prompts.surface(currency: "{{currency}}", features: ["{{features}}"])
let featureSeparator = between("{{a}}", "{{b}}", in: Prompts.surface(currency: "{{currency}}", features: ["{{a}}", "{{b}}"]))
func assembled(connections: Bool) -> String {
    let rules = Prompts.features.filter { connections || $0.name != "connections" }.map(\.rules).filter { !$0.isEmpty }
    return surfaceCore.replacingOccurrences(of: "{{features}}", with: rules.joined(separator: featureSeparator))
}
precondition(assembled(connections: false) == surfaceWithoutConnections && assembled(connections: true) == surfaceWithConnections, "The instructions don't come apart into their features")
Connections.source = Connections.Source(connections: { [] }, call: { _, _, _ in throw ConnectionError.unavailable }, personalDetails: { [] })

// What the phone may add beside a request that the server says otherwise: it searches the web.
let webUnavailable = Prompts.webContext()
precondition(webUnavailable.count == 1, "There's no line for web search being off")

let stage2Templates = json([
    "edit": [
        "block": edit.text,
        "withContext": editWithContext,
        "whole": edit.line,
        "pointing": pointing,
        "describe": describing,
        "labelSeparator": labelSeparator,
    ],
    "changedAnswer": changedAnswer,
    "memory": ["line": memoryLine, "topicSeparator": topicSeparator],
])
let stage2ToolText = json([
    "recall": ["found": recalled.text, "line": recalled.line, "nothing": recalledNothing],
    "live": ["header": liveWithMeaning[0], "field": liveWithMeaning[1], "fieldPlain": liveWithout[1], "closing": liveWithMeaning[2], "failed": liveFailed],
])
precondition(liveWithMeaning[0] == liveWithout[0] && liveWithMeaning[2] == liveWithout[2], "A field's meaning changes more than its line")

print("""
{
"prompts": {
"surface": \(string(Prompts.surface(currency: "{{currency}}"))),
"gapCheck": \(string(Prompts.gapCheck)),
"surfaceCore": \(string(surfaceCore)),
"featureSeparator": \(string(featureSeparator)),
"features": \(json(features)),
"surfaceWithConnections": \(string(surfaceWithConnections))
},
"schemas": {
"surface": \(try schema(WireSurface.generationSchema)),
"gaps": \(try schema(GapCheck.WireGaps.generationSchema))
},
"tools": [
\(toolLines.joined(separator: ",\n"))
],
"templates": \(templates.dropLast()),\(stage2Templates.dropFirst()),
"toolText": \(toolText.dropLast()),\(stage2ToolText.dropFirst()),
"context": \(json(["webUnavailable": webUnavailable[0]]))
}
""")
