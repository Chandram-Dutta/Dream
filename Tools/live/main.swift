import Foundation

// The live tool against real exchange rates and MapKit (weather stands in, since WeatherKit won't
// authorize here). Run with Tools/live.sh, which first runs the checks that need no network:
// days and times, units, the checker's bindings and actions (DreamTests/LiveTests.swift). It
// makes a few network requests, and none to a model.

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

print("Fetching (network)")
let log = LiveLog()
let tool = LiveTool(log: log)
for arguments in [
    LiveTool.Arguments(name: "rate", kind: .exchangeRate, place: "", day: "", time: "", from: "usd", to: "INR", travel: ""),
    LiveTool.Arguments(name: "trip", kind: .route, place: "", day: "", time: "", from: "Bengaluru", to: "Mysuru", travel: "driving"),
    LiveTool.Arguments(name: "weather", kind: .weather, place: "current location", day: "tomorrow", time: "", from: "", to: "", travel: ""),
    LiveTool.Arguments(name: "picnic", kind: .weather, place: "Bengaluru", day: "saturday", time: "16:00", from: "", to: "", travel: ""),
    LiveTool.Arguments(name: "airport", kind: .route, place: "", day: "", time: "", from: "current location", to: "airport", travel: "transit"),
    LiveTool.Arguments(name: "nowhere", kind: .route, place: "", day: "", time: "", from: "Bengaluru", to: "Qwxzvbnm Plkjh", travel: "driving"),
] {
    let text = try await tool.call(arguments: arguments)
    print(text.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
}
let sources = log.sources
expect(sources.map(\.name) == ["rate", "trip", "weather", "picnic", "airport"], "each source read is declared; a failed one isn't")
expect((sources.first { $0.name == "airport" }?.field("distance")?.value ?? 1000) < 150, "the airport is the nearest one, not one across the country")
expect((sources.first { $0.name == "rate" }?.field("rate")?.value ?? 0) > 1, "a real exchange rate")
expect((sources.first { $0.name == "trip" }?.field("distance")?.value ?? 0) > 100, "a real route, over 100 km")
expect(sources.first { $0.name == "weather" }?.parameters["place"] == "current location", "where the user is stays a word, never coordinates")
let again = try await LiveSources.read(sources.first { $0.name == "rate" }!)
expect(again.field("rate") != nil, "a second read comes from the cache")

print(failures == 0 ? "\nAll live checks passed." : "\n\(failures) live checks failed.")
exit(failures == 0 ? 0 : 1)
