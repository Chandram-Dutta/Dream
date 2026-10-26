import Foundation
import MCP

// Connected services (ROADMAP.md, workstream 8): talking to their servers.

/// Talks to connected MCP servers through the official MCP Swift SDK, over Streamable HTTP.
/// One session per server, opened when it's first needed and opened again if the server forgets
/// it. Dream offers servers no capabilities of its own (no sampling, roots or elicitation), so a
/// server can't prompt its model or ask the user anything.
actor ConnectionSessions {
    static let shared = ConnectionSessions()

    /// What a server says about itself when Dream connects.
    struct Description: Sendable {
        var name: String
        var tools: [ConnectedTool]
    }

    private struct Session {
        let client: MCP.Client
        let authorizer: ConnectionAuthorizer
        let name: String
    }

    private var sessions: [UUID: Session] = [:]

    /// Connects afresh, and lists what the server offers.
    func describe(_ url: URL, id: UUID) async throws -> Description {
        await close(id)
        let session = try await session(url, id: id)
        do {
            var tools: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let page = try await session.client.listTools(cursor: cursor)
                tools += page.tools
                cursor = page.nextCursor
            } while cursor != nil && tools.count < 300
            session.authorizer.accepted()
            return Description(name: session.name, tools: tools.map(ConnectedTool.init))
        } catch {
            throw await failure(error, id: id, name: session.name)
        }
    }

    /// Runs one tool, reconnecting once if the server has forgotten the session.
    func call(_ connection: Connection, tool: String, arguments: JSONValue) async throws -> ToolResult {
        let values = arguments.object?.mapValues(MCP.Value.init)
        for attempt in 0..<2 {
            let session = try await session(connection.url, id: connection.id)
            do {
                let context: RequestContext<CallTool.Result> = try await session.client.callTool(name: tool, arguments: values)
                let result = try await context.value
                session.authorizer.accepted()
                return ToolResult(result)
            } catch let error as MCPError where attempt == 0 && error.localizedDescription.contains("Session expired") {
                await close(connection.id)
            } catch {
                throw await failure(error, id: connection.id, name: connection.name)
            }
        }
        throw ConnectionError.failed("\(connection.name) didn't answer.")
    }

    /// Forgets a session, as after signing in or out.
    func close(_ id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.client.disconnect()
    }

    // MARK: - Pieces

    private func session(_ url: URL, id: UUID) async throws -> Session {
        if let session = sessions[id] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let authorizer = ConnectionAuthorizer(id: id)
        // Each request gets its answer on its own response; nothing needs to stay open.
        let transport = HTTPClientTransport(endpoint: url, configuration: configuration, streaming: false, authorizer: authorizer)
        let client = MCP.Client(name: "Dream", version: "0.1")
        do {
            let result = try await client.connect(transport: transport)
            authorizer.accepted()
            let info = result.serverInfo
            let name = [info.title, info.name].compactMap { $0.map(Self.plainName) }.first { !$0.isEmpty } ?? url.host() ?? "This service"
            let session = Session(client: client, authorizer: authorizer, name: String(name.prefix(40)))
            sessions[id] = session
            return session
        } catch {
            await client.disconnect()
            throw await failure(error, id: id, name: url.host() ?? "This service", authorizer: authorizer)
        }
    }

    /// What a server calls itself, as a person would: "Microsoft Learn MCP Server" is Microsoft Learn.
    private static func plainName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" MCP Server", " MCP server", " MCP", " Server"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// What went wrong, in terms the Connections screen can act on.
    private func failure(_ error: Error, id: UUID, name: String, authorizer: ConnectionAuthorizer? = nil) async -> Error {
        let authorizer = authorizer ?? sessions[id]?.authorizer
        if let challenge = authorizer?.pendingChallenge {
            await close(id)
            return Challenged(name: name, headers: challenge)
        }
        if error is ConnectionError || error is CancellationError { return error }
        if let error = error as? URLError {
            return ConnectionError.failed(error.code == .timedOut ? "\(name) didn't answer in time." : "Couldn't reach \(name): \(error.localizedDescription)")
        }
        if let error = error as? MCPError {
            switch error {
            case .internalError(let detail?): return ConnectionError.failed("\(name): \(detail)")
            case .methodNotFound: return ConnectionError.failed("\(name) doesn't offer that.")
            case .connectionClosed: return ConnectionError.failed("\(name) closed the connection.")
            default: break
            }
        }
        return ConnectionError.failed("\(name): \(error.localizedDescription)")
    }
}

/// The server wants a sign-in, and said how in these headers.
struct Challenged: LocalizedError {
    let name: String
    let headers: [String: String]

    var errorDescription: String? { ConnectionError.needsSignIn(name).errorDescription }
}

// MARK: - Between the SDK's types and Dream's

extension ConnectedTool {
    init(_ tool: MCP.Tool) {
        self.init(
            name: tool.name,
            title: [tool.annotations.title, tool.title].compactMap { $0 }.first { !$0.isEmpty },
            summary: tool.description ?? "",
            inputSchema: JSONValue(tool.inputSchema),
            readOnlyHint: tool.annotations.readOnlyHint,
            destructiveHint: tool.annotations.destructiveHint,
            idempotentHint: tool.annotations.idempotentHint,
            openWorldHint: tool.annotations.openWorldHint)
    }
}

extension ToolResult {
    /// Text as it came, and the rest described: images, sounds and links aren't passed on.
    init(_ result: CallTool.Result) {
        let parts = result.content.map { content -> String in
            switch content {
            case .text(let text, _, _): text
            case .image(_, let type, _, _): "[An image (\(type)), not shown]"
            case .audio(_, let type, _, _): "[A sound (\(type)), not played]"
            case .resource(let resource, _, _): resource.text ?? "[\(resource.mimeType ?? "A file") at \(resource.uri)]"
            case .resourceLink(let uri, let name, let title, let description, _, _):
                "\(title ?? name): \(uri)" + (description.map { " (\($0))" } ?? "")
            }
        }
        self.init(text: parts.joined(separator: "\n\n"), structured: result.structuredContent.map(JSONValue.init), isError: result.isError ?? false)
    }
}

extension JSONValue {
    init(_ value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .number(Double(int))
        case .double(let double): self = .number(double)
        case .string(let string): self = .string(string)
        case .data(let type, let data): self = .string("data:\(type ?? "application/octet-stream");base64,\(data.base64EncodedString())")
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .object(let object): self = .object(object.mapValues(JSONValue.init))
        }
    }
}

extension MCP.Value {
    /// Whole numbers go as integers, which integer inputs need.
    init(_ json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number) where number == number.rounded() && abs(number) < 1e15: self = .int(Int(number))
        case .number(let number): self = .double(number)
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map(MCP.Value.init))
        case .object(let object): self = .object(object.mapValues(MCP.Value.init))
        }
    }
}
