import Foundation
import FoundationModels

// What the app's engine makes of each golden case (Server/test/golden), for the server's port of
// it (Server/src/engine) to be checked against: the page as the app reads the model's answer, then
// after each check the composer runs on it, with the issues in order, and the shorthand the log and
// repairs use. The TypeScript engine must produce the same, field for field (docs/ServerGeneration.md).
//
// A case is a model's answer (`wire`, a WireSurface as JSON, or `text`, an answer cut off as it was
// streaming), with what the composer would have beside it: the Wikipedia article looked up
// (`reference`), the pages read (`read`), the live sources fetched (`sources`), the services used
// (`services`), and the recordings and molecules found (`recordings` by search, `molecules` by name).
// `locale` is the reader's; the tool only writes the cases for the locale it runs in, since the
// checker reads the user's currency and units from it.
//
// Built and run by Tools/engine-golden.sh: engine-golden <cases> <expected> <locale>

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("Usage: engine-golden <cases folder> <expected folder> <locale>\n".utf8))
    exit(2)
}
let casesFolder = URL(fileURLWithPath: arguments[1])
let expectedFolder = URL(fileURLWithPath: arguments[2])
let wantedLocale = arguments[3]

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

/// Something the engine encodes, as plain JSON to put in the expected file.
func plain<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
}

func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T? {
    guard let value, !(value is NSNull) else { return nil }
    return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
}

func issues(_ list: [Issue]) -> [[String: String]] {
    list.map { issue in
        let kind = switch issue.kind {
        case .fixed: "fixed"
        case .needsModel: "needsModel"
        case .warning: "warning"
        }
        return ["kind": kind, "message": issue.message]
    }
}

func facts(_ surface: Surface) -> [String: Any] {
    ["isEmpty": surface.isEmpty, "hasLogic": surface.hasLogic, "isRepeatingItself": surface.isRepeatingItself,
     "outline": surface.outline, "logicSummary": surface.logicSummary]
}

/// One page the model read, with every address it can be cited by.
struct ReadPage: Decodable {
    var title: String
    var site: String
    var url: String
    var date: String?
    var addresses: [String]?
}

func run(_ input: [String: Any]) throws -> [String: Any] {
    var result: [String: Any] = [:]
    let reference = try decode(Reference.self, input["reference"])

    // The answer as the app reads it: whole if it is, otherwise as far as it got.
    let content: GeneratedContent
    if let text = input["text"] as? String {
        guard let parsed = try? GeneratedContent(json: text) else {
            result["decodes"] = ["json": false]
            return result
        }
        content = parsed
    } else {
        let data = try JSONSerialization.data(withJSONObject: input["wire"] ?? [:], options: [.fragmentsAllowed])
        content = try GeneratedContent(json: String(decoding: data, as: UTF8.self))
    }
    let whole = try? WireSurface(content)
    let partial = try? WireSurface.PartiallyGenerated(content)
    result["decodes"] = ["json": true, "whole": whole != nil, "partial": partial != nil]
    result["content"] = try JSONSerialization.jsonObject(with: Data(content.jsonString.utf8), options: [.fragmentsAllowed])

    var surface: Surface
    if let whole, input["text"] == nil, input["partial"] as? Bool != true {
        surface = Surface(whole, reference: reference)
    } else if let partial {
        surface = Surface(partial: partial, reference: reference)
    } else {
        return result
    }
    result["converted"] = try plain(surface)
    result["convertedFacts"] = facts(surface)

    // What the composer does with a finished answer (Composer.write), without the repairs.
    if let sources = try decode([Source].self, input["sources"]) { surface.sources = sources.isEmpty ? nil : sources }
    if let services = try decode([String].self, input["services"]) { surface.services = services.isEmpty ? nil : services }
    var reading = ReadingList()
    for page in try decode([ReadPage].self, input["read"]) ?? [] {
        reading.add(Citation(title: page.title, site: page.site, url: page.url, date: page.date), at: page.addresses ?? [])
    }

    let logic = Checker.checkLogic(&surface)
    result["logic"] = ["issues": issues(logic), "surface": try plain(surface)]
    result["sourcing"] = issues(Checker.checkSourcing(surface, read: reading))

    // What the lookups after the repairs would have found.
    let recordings = try decode([String: Recording].self, input["recordings"]) ?? [:]
    for index in (surface.sounds ?? []).indices {
        guard let sound = surface.sounds?[index], sound.isRecording, sound.recording == nil, let found = recordings[sound.search] else { continue }
        surface.sounds?[index].recording = found
    }
    let molecules = try decode([String: MoleculeStructure].self, input["molecules"]) ?? [:]
    for index in (surface.scenes ?? []).indices {
        guard let molecule = surface.scenes?[index].molecule, molecule.structure == nil, let found = molecules[molecule.name] else { continue }
        surface.scenes?[index].molecule?.structure = found
    }

    let citations = Checker.checkCitations(&surface, read: reading)
    result["citations"] = ["issues": issues(citations), "surface": try plain(surface)]
    let blocks = Checker.checkBlocks(&surface)
    result["blocks"] = ["issues": issues(blocks), "surface": try plain(surface)]
    result["final"] = facts(surface)
    return result
}

let files = try FileManager.default.contentsOfDirectory(at: casesFolder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
try FileManager.default.createDirectory(at: expectedFolder, withIntermediateDirectories: true)
var written = 0
for file in files {
    guard let input = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        FileHandle.standardError.write(Data("\(file.lastPathComponent) isn't a JSON object\n".utf8))
        exit(1)
    }
    guard (input["locale"] as? String ?? "en_US") == wantedLocale else { continue }
    var output = try run(input)
    output["locale"] = Locale.current.identifier
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: expectedFolder.appendingPathComponent(file.lastPathComponent))
    written += 1
}
print("Wrote \(written) cases for \(wantedLocale)")
