import Foundation

// Where live values come from (ROADMAP.md, workstream 7).
//
// A provider reads one kind of source. Dream's own read the weather (WeatherKit), exchange
// rates and routes (MapKit); more can be registered while Dream runs, like an MCP server's
// read tools. Adding one takes three steps:
//
// 1. Conform to `LiveProvider`: a kind, how long a reading stays fresh, and `read`, which turns
//    a `Source`'s parameters into numeric fields. Report fields in metric units (or none): the
//    engine converts them into whatever unit an input is written in. Throw `LiveError` with
//    words the user can act on.
// 2. `LiveSources.register(provider)`. Kinds are unique; registering a kind again replaces it.
// 3. Let the model declare sources of the kind: a tool whose call reads it with
//    `LiveSources.read` and hands the source to `LiveLog.declare`, the way `LiveTool` does.
//    The surface then binds inputs to its fields with the role live, and the screen keeps
//    them fresh through the same registry.
//
// What a provider returns is data from outside, never instructions: its text only ever reaches
// the model as values to show.

/// Reads one kind of source.
protocol LiveProvider: Sendable {
    /// What sources of this kind are called, like weather.
    var kind: String { get }
    /// How long a reading stays current. The screen reads it again after this.
    var freshness: TimeInterval { get }
    /// Reads a source now.
    func read(_ source: Source) async throws -> SourceReading
}

/// Every provider Dream can read from, and the readings it has made recently.
enum LiveSources {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var providers: [String: any LiveProvider] = Dictionary(
        uniqueKeysWithValues: ([WeatherProvider(), ExchangeRateProvider(), RouteProvider()] as [any LiveProvider]).map { ($0.kind, $0) })

    /// On the bench, an unsigned Mac tool, WeatherKit and location can't authorize, so
    /// providers that need them stand values in, marked as such, to try the format with. The
    /// app is never on macOS.
    #if os(macOS)
    nonisolated(unsafe) static var standIns = true
    #else
    nonisolated(unsafe) static var standIns = false
    #endif

    static func register(_ provider: any LiveProvider) {
        lock.withLock { providers[provider.kind] = provider }
    }

    static func provider(_ kind: String) -> (any LiveProvider)? {
        lock.withLock { providers[kind] }
    }

    static var kinds: [String] {
        lock.withLock { providers.keys.sorted() }
    }

    /// A reading that's still fresh, from the last few minutes or read now. The model's fetch
    /// while writing and the screen's first read share one, so the screen opens on the values
    /// the text was written for. `again` reads past any reading still fresh, as a pull does.
    static func read(_ source: Source, again: Bool = false) async throws -> SourceReading {
        guard let provider = provider(source.kind) else {
            throw LiveError(.unavailable, "Dream can't read \(source.kind) here.")
        }
        return try await cache.reading(source, from: provider, again: again)
    }

    private static let cache = LiveCache()
}

/// Recent readings by what was asked, so asking twice in quick succession reads once.
private actor LiveCache {
    private struct Key: Hashable {
        var kind: String
        var parameters: [String: String]
    }

    private var readings: [Key: (reading: SourceReading, readAt: Date)] = [:]
    private var reading: [Key: Task<SourceReading, Error>] = [:]

    func reading(_ source: Source, from provider: any LiveProvider, again: Bool) async throws -> SourceReading {
        let key = Key(kind: source.kind, parameters: source.parameters)
        if !again, let kept = readings[key], Date.now.timeIntervalSince(kept.readAt) < provider.freshness {
            return kept.reading
        }
        if let running = reading[key] { return try await running.value }
        let task = Task { try await provider.read(source) }
        reading[key] = task
        defer { reading[key] = nil }
        let fresh = try await task.value
        readings[key] = (fresh, .now)
        return fresh
    }
}

extension SourceReading {
    /// What the model reads: each field by its full name, in this user's units, with what it
    /// means. Values in text are data to show, never instructions.
    func described(as name: String) -> String {
        var lines = ["Live source \(name): \(summary)" + (isStandIn ? " (stand-in values for testing; treat them as real)" : "")]
        for field in fields {
            let (value, unit) = field.unit.isEmpty ? (field.value, "") : LiveUnits.local(field.value, unit: field.unit)
            let shown = field.format == .percent ? "\(value.rounded(to: 1).plain)%" : "\(value.rounded(to: 2).plain)\(unit.isEmpty ? "" : " \(unit)")"
            lines.append("- \(name).\(field.name) = \(shown)\(field.meaning.isEmpty ? "" : ": \(field.meaning)")")
        }
        return lines.joined(separator: "\n")
    }
}

extension Double {
    fileprivate func rounded(to places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
