import Foundation
import FoundationModels

// Fetching live data while writing (ROADMAP.md, workstream 7). The model sees the values now,
// so its text agrees with them, and the call itself declares the source the screen keeps fresh.

/// Lets the model read the weather, an exchange rate or a route while it writes a screen.
/// What it returns is data from outside Dream, to show, never instructions.
struct LiveTool: Tool {
    let log: LiveLog
    /// Told what was fetched, for the log.
    var onFetch: @Sendable (String) -> Void = { _ in }
    let name = "live"
    let description = "Fetches live data that Dream keeps current on the screen: the weather for a place and day, an exchange rate, or the distance and travel time between places. Returns the values now and the name of each field. Use it whenever the screen shows any of these, before building."

    @Generable
    enum Kind { case weather, exchangeRate, route }

    @Generable
    struct Arguments {
        @Guide(description: "camelCase name for this source, like weather, rate or trip")
        var name: String
        var kind: Kind
        @Guide(description: "weather: the place, or current location for where the user is. Otherwise empty")
        var place: String
        @Guide(description: "weather: today, tomorrow, a weekday like saturday, or a date as YYYY-MM-DD. Otherwise empty")
        var day: String
        @Guide(description: "weather: an hour as HH:mm, for the forecast then. Empty for the whole day, or for now")
        var time: String
        @Guide(description: "exchangeRate: the currency's ISO code, like USD. route: where from, or current location")
        var from: String
        @Guide(description: "exchangeRate: the other currency's ISO code, like INR. route: where to")
        var to: String
        @Guide(description: "route: driving, walking or transit. Otherwise empty")
        var travel: String
    }

    func call(arguments: Arguments) async throws -> String {
        let kind = String(describing: arguments.kind)
        let name = Checker.identifier(arguments.name.isEmpty ? kind : arguments.name)
        var parameters: [String: String] = [:]
        switch arguments.kind {
        case .weather:
            parameters = ["place": arguments.place, "day": arguments.day, "time": arguments.time]
        case .exchangeRate:
            parameters = ["from": arguments.from, "to": arguments.to]
        case .route:
            parameters = ["from": arguments.from, "to": arguments.to, "travel": arguments.travel.isEmpty ? "driving" : arguments.travel]
        }
        parameters = parameters
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        // Where the user is, said one way, so the screen and the cache agree on it.
        for key in ["place", "from"] where parameters[key].map(Source.isHere) == true {
            parameters[key] = "current location"
        }
        if arguments.kind == .weather, parameters["place"] == nil { parameters["place"] = "current location" }
        if arguments.kind == .route, parameters["from"] == nil { parameters["from"] = "current location" }
        let source = Source(name: name, kind: kind, parameters: parameters, fields: [])
        let asked = parameters.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        do {
            let reading = try await LiveSources.read(source)
            log.declare(source, reading: reading)
            onFetch("Live: \(name), \(kind) (\(asked))\(reading.isStandIn ? ", stand-in values" : "")")
            return reading.described(as: name) + "\nShow each value you use with an input whose role is live and whose source is the field's full name, like \(name).\(reading.fields.first?.name ?? "value"). Dream keeps them current."
        } catch {
            let message = (error as? LiveError)?.message ?? "It couldn't be read."
            onFetch("Live: \(name), \(kind) (\(asked)) failed: \(message)")
            if (error as? LiveError)?.reason == .denied {
                return "\(message) Use a place the user named or Dream remembers, or ask where with the ask tool. Don't show values for where they are."
            }
            return "\(message) Don't show these values, and don't make them up."
        }
    }
}

/// The sources fetched while writing a surface: what it may bind live inputs to.
final class LiveLog: @unchecked Sendable {
    private let lock = NSLock()
    private var declared: [Source] = []

    /// A new request starts with nothing; a change starts with the sources the screen already has.
    func start(keeping sources: [Source]? = nil) {
        lock.withLock { declared = sources ?? [] }
    }

    /// A source, with what it read. One fetched again under the same name replaces the first.
    func declare(_ source: Source, reading: SourceReading) {
        var source = source
        source.fields = reading.fields
        lock.withLock {
            declared.removeAll { $0.name == source.name }
            declared.append(source)
        }
    }

    var sources: [Source] {
        lock.withLock { declared }
    }
}

extension Surface {
    /// With the sources fetched while it was written, for the checker to bind its live inputs to.
    func fetched(_ log: LiveLog) -> Surface {
        var surface = self
        let sources = log.sources
        surface.sources = sources.isEmpty ? nil : sources
        return surface
    }
}
