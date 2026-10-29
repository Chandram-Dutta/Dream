import Foundation
import FoundationModels

// Tools only this iPhone can run, for pages made on Dream's server (docs/ServerGeneration.md):
// a connected service's, whose sign-in never leaves the phone, and travel times from Apple Maps.
// The phone tells the server which it would offer the model for a request (`deviceTools`), the
// server offers them like its own, and when the model calls one the phone runs it exactly as its
// own loop would, asking first where that asks (Consent.swift), and sends back what it returned
// (POST /api/compose/:id/tools). While the app isn't open the server stops waiting on its own.

/// A tool the phone runs, as the server offers it to the model.
struct DeviceToolDefinition: Encodable, Equatable {
    var name: String
    var description: String
    /// JSON Schema for its arguments, as the phone sends a model its tools (ChatCompletions).
    var parameters: JSONValue
    /// The connected service it's from, like Linear, so the server can say which one couldn't
    /// answer. Nil for travel times.
    var service: String? = nil
}

/// The model called one of the phone's tools, and the server waits on what it returns.
struct DeviceToolCall: Hashable, Sendable {
    var id: String
    var name: String
    /// As the model wrote them: JSON.
    var arguments: String
}

/// What a tool returned, for the model: the body of POST /api/compose/:id/tools.
struct DeviceToolOutput: Encodable, Equatable {
    var id: String
    var output: String
    /// The live source the call read, as the page keeps it, so the server can bind the page's
    /// live values to it as the phone's checker would (Checker+Live.swift).
    var source: Source?
    /// The connected service whose data it holds, so the page lists it among its services
    /// (Surface.services) and sharing says so first, as for a page made here.
    var service: String? = nil
}

/// The phone's part of the live tool, for pages made on Dream's server: how far it is between
/// places and how long it takes now, from Apple Maps (LiveRoutes.swift), which only the phone can
/// ask. The server reads the weather and exchange rates itself.
struct TravelTool: Tool {
    let log: LiveLog
    /// Told what was fetched, for the log.
    var onFetch: @Sendable (String) -> Void = { _ in }
    let name = "travel"
    let description = "Fetches the distance and travel time between places now, by car, on foot or by transit, from Apple Maps, which Dream keeps current on the screen. Returns the values now and the name of each field. Use it whenever the screen shows how far somewhere is or how long it takes to get there, before building."

    @Generable
    struct Arguments {
        @Guide(description: "camelCase name for this source, like trip or commute")
        var name: String
        @Guide(description: "Where from: a place, or current location")
        var from: String
        @Guide(description: "Where to")
        var to: String
        @Guide(description: "driving, walking or transit")
        var travel: String
    }

    /// Exactly as the live tool reads a route.
    func call(arguments: Arguments) async throws -> String {
        try await LiveTool(log: log, onFetch: onFetch).call(arguments: LiveTool.Arguments(
            name: arguments.name, kind: .route, place: "", day: "", time: "",
            from: arguments.from, to: arguments.to, travel: arguments.travel))
    }
}

/// The phone's tools for one page on Dream's server: what the server is told the model may call,
/// and each call the model makes, run once. Lines for Under the hood wait until something follows
/// the page to show them.
@MainActor
final class DeviceTools {
    /// One tool, as the server is told of it and as the phone runs it.
    struct Entry: Sendable {
        let definition: DeviceToolDefinition
        let run: @Sendable (GeneratedContent) async throws -> String

        init<T: Tool>(_ tool: T, service: String? = nil) where T.Output == String {
            definition = DeviceToolDefinition(name: tool.name, description: tool.description, parameters: Self.json(tool.parameters), service: service)
            run = { arguments in try await tool.call(arguments: try T.Arguments(arguments)) }
        }

        init(definition: DeviceToolDefinition, run: @escaping @Sendable (GeneratedContent) async throws -> String) {
            self.definition = definition
            self.run = run
        }

        /// A schema as the phone's model requests carry it. Its "x-order" stays, so the request's
        /// properties go in the order they were declared and it then goes (ChatCompletions.ordered).
        private static func json(_ schema: GenerationSchema) -> JSONValue {
            (try? JSONEncoder().encode(schema)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
        }
    }

    private(set) var entries: [Entry] = []
    /// Where the tools declare the live sources they read.
    let live: LiveLog
    /// Calls run already, here or before the app last closed, so reading a page again from its
    /// first event never runs one twice.
    private(set) var ran: Set<String>
    /// Told of each call as it starts, so the app can keep it (StartedPage).
    var onRun: (String) -> Void = { _ in }
    /// Where lines for Under the hood go, once something follows the page.
    var onNote: ((String) -> Void)? {
        didSet {
            guard let onNote else { return }
            waiting.forEach(onNote)
            waiting = []
        }
    }
    private var waiting: [String] = []

    init(_ entries: [Entry] = [], live: LiveLog = LiveLog(), ran: Set<String> = []) {
        self.entries = entries
        self.live = live
        self.ran = ran
    }

    var definitions: [DeviceToolDefinition] { entries.map(\.definition) }

    /// What this iPhone would offer the model for a request if it made the page itself
    /// (Composer.tools): the connected services' tools picked for it, and travel times. The rest
    /// the server has of its own.
    static func offered(for request: String, asking: Asking, consent: Consent, live: LiveLog, log: ConnectionLog, ran: Set<String> = []) -> DeviceTools {
        let devices = DeviceTools(live: live, ran: ran)
        let note: @Sendable (String) -> Void = { [weak devices] line in Task { @MainActor in devices?.note(line) } }
        let connections = ConnectionTool.offered(for: request, asking: asking, consent: consent, live: live, log: log, onUse: note)
            .compactMap { $0 as? ConnectionTool }
        devices.entries = connections.map { Entry($0, service: $0.connection.name) } + [Entry(TravelTool(log: live, onFetch: note))]
        return devices
    }

    /// Runs a call the model made, as the phone's own loop would, and what it returned for the
    /// model. Nil when it was run already. A call is counted as run as soon as it starts, so one
    /// cut off by the app closing is never run again, even if it asked first: the server tells
    /// the model it couldn't be read.
    func run(_ call: DeviceToolCall) async -> DeviceToolOutput? {
        guard ran.insert(call.id).inserted else { return nil }
        onRun(call.id)
        guard let entry = entries.first(where: { $0.definition.name == call.name }) else {
            note("Asked to run \(call.name), which this iPhone doesn't offer for this page.")
            return DeviceToolOutput(id: call.id, output: "\(call.name) isn't available on the user's iPhone for this page, so it wasn't run. Build the screen without it, and don't claim anything about what it would have returned.")
        }
        let arguments: GeneratedContent
        do {
            arguments = try GeneratedContent(json: call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : call.arguments)
        } catch {
            note("\(call.name)'s arguments couldn't be read: \(call.arguments.prefix(160))")
            return DeviceToolOutput(id: call.id, output: "The arguments for \(call.name) weren't JSON, so it wasn't run. Call it again with arguments that match its schema.")
        }
        let before = live.sources
        let output: String
        var read: String?
        do {
            output = try await entry.run(arguments)
            read = entry.definition.service
        } catch {
            note("\(call.name) couldn't run: \(error.localizedDescription)")
            output = "\(call.name) couldn't run with those arguments (\(error.localizedDescription)). Call it again with arguments that match its schema, or build the screen without it."
        }
        return DeviceToolOutput(id: call.id, output: output, source: live.sources.first { !before.contains($0) }, service: read)
    }

    func note(_ line: String) {
        if let onNote { onNote(line) } else { waiting.append(line) }
    }
}
