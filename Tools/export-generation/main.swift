import Foundation
import FoundationModels

// Writes what the server sends a model to make a page, from the app's own definitions, so the two
// never drift while both make pages (docs/ServerGeneration.md): the instructions, the page's and
// the gap check's JSON schemas in the order the app sends them, and the tools' descriptions and
// argument schemas. The user's currency is left as {{currency}}, for the server to fill in.
//
// Then the prompts that wrap something: the request, the answers to the gap check's questions,
// a repair. Each is what the app's own function writes, called with {{slots}} for its arguments,
// and a list's line is a template of its own (Server/src/compose/prompts.ts fills them in). And
// what the tools tell the model when they can't go ahead, from the tools themselves; their
// answers that need the network to write are in Server/src/compose/tools.ts.
//
// Built and run by Tools/export-generation.sh; prints JSON. It never signs in or goes online:
// with no server set, web search fails before it would.

func schema(_ value: GenerationSchema) throws -> String {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return String(decoding: try ChatCompletions.ordered(object), as: UTF8.self)
}

func string(_ text: String) -> String {
    String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
}

let log = WebLog()
let tools: [any Tool] = [LookupTool(found: ReferenceLog()), SearchTool(log: log), ReadTool(log: log)]
let toolLines = try tools.map { tool in
    "{\"name\":\(string(tool.name)),\"description\":\(string(tool.description)),\"parameters\":\(try schema(tool.parameters))}"
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

print("""
{
"prompts": {
"surface": \(string(Prompts.surface(currency: "{{currency}}"))),
"gapCheck": \(string(Prompts.gapCheck))
},
"schemas": {
"surface": \(try schema(WireSurface.generationSchema)),
"gaps": \(try schema(GapCheck.WireGaps.generationSchema))
},
"tools": [
\(toolLines.joined(separator: ",\n"))
],
"templates": \(templates),
"toolText": \(toolText)
}
""")
