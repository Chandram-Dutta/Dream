import Foundation
import FoundationModels

// Writes what the server sends a model to make a page, from the app's own definitions, so the two
// never drift while both make pages (docs/ServerGeneration.md): the instructions, the page's and
// the gap check's JSON schemas in the order the app sends them, and the tools' descriptions and
// argument schemas. The user's currency is left as {{currency}}, for the server to fill in.
//
// Built and run by Tools/export-generation.sh; prints JSON.

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
]
}
""")
