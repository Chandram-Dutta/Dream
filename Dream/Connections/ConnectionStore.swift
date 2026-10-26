import Foundation
import Observation

// Connected services (ROADMAP.md, workstream 8): the ones the user added.

/// The services the user connected, kept on this iPhone in a small file; a sign-in's tokens are
/// in the Keychain. Each one's tools are listed when it's added, and again when they're a day
/// old or the Connections screen asks. Building a screen reads the current state through
/// `Connections.source`, which `start` connects.
@MainActor @Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    enum Status: Equatable {
        case checking
        case ready
        case needsSignIn
        case failed(String)
    }

    private(set) var connections: [Connection] = []
    /// How each one is doing right now. Not saved: it's found out again after launch.
    private(set) var status: [UUID: Status] = [:]
    /// Each server's last sign-in challenge, which says where to sign in.
    @ObservationIgnored private var challenges: [UUID: [String: String]] = [:]
    @ObservationIgnored private var started = false

    /// What building a screen reads, from any thread, while a session is being set up.
    nonisolated private static let current = Current()

    private let file: URL? = {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return folder.appending(path: "Dream/connections.json")
    }()

    /// At launch: loads what's saved, connects it to building screens, and refreshes old tool lists.
    /// `directory` is the server whose /api/mcp/ lists services to discover, if there is one.
    func start(personalDetails: @escaping @Sendable () async -> [PersonalDetail], directory: URL?) {
        guard !started else { return }
        started = true
        load()
        Connections.source = Connections.Source(
            connections: { ConnectionStore.current.connections },
            call: { connection, tool, arguments in
                do {
                    return try await ConnectionSessions.shared.call(connection, tool: tool, arguments: arguments)
                } catch let challenged as Challenged {
                    await ConnectionStore.shared.challenged(connection.id, challenged)
                    throw ConnectionError.needsSignIn(connection.name)
                }
            },
            personalDetails: personalDetails,
            allowAlways: { id, tool in await ConnectionStore.shared.allowAlways(id, tool: tool) })
        Connections.registerLive()
        directoryServer = directory
        Connections.directory = Directory.saved
        Task { await refresh(olderThan: 24 * 60 * 60) }
        Task { await refreshDirectory() }
    }

    // MARK: - Discovering

    /// Where the directory comes from: Dream's sharing server.
    private(set) var directoryServer: URL?
    /// The featured services, as last fetched.
    private(set) var featured: [DirectoryEntry] = Directory.saved

    /// Fetches the featured services again, for discovery and for noticing them in requests.
    func refreshDirectory() async {
        guard let directoryServer, let fresh = try? await Directory.featured(from: directoryServer), !fresh.isEmpty else { return }
        featured = fresh
        Connections.directory = fresh
        Directory.save(fresh)
    }

    /// The connection for a directory entry, if the user has it.
    func connection(for entry: DirectoryEntry) -> Connection? {
        connections.first { $0.url.host()?.lowercased() == entry.url.host()?.lowercased() && $0.url.path() == entry.url.path() }
    }

    /// Connects an entry in one go: adds it, and signs in if it asks. Returns the connection
    /// once it's ready to use.
    func connect(_ entry: DirectoryEntry, present: @escaping @Sendable (URL) async throws -> URL) async throws -> Connection {
        let connection = try await add(entry.url.absoluteString)
        if status(of: connection.id) == .needsSignIn {
            try await signIn(connection.id, present: present)
        }
        if case .failed(let message) = status(of: connection.id) { throw ConnectionError.failed(message) }
        return self.connection(connection.id) ?? connection
    }

    // MARK: - Allowing

    /// An "Always" from the card: a service's look-ups (a nil tool), or one tool.
    func allowAlways(_ id: UUID, tool: String?) {
        if let tool {
            updateTool(tool, of: id) { $0.alwaysAllowed = true }
        } else {
            update(id) { $0.alwaysLooksUp = true }
        }
    }

    func connection(_ id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    func status(of id: UUID) -> Status {
        status[id] ?? .ready
    }

    /// Whether Dream holds a sign-in for it, which the Keychain knows.
    func isSignedIn(_ id: UUID) -> Bool {
        _ = signInChanges
        return SignIn.Credentials.load(for: id)?.isSignedIn ?? false
    }

    /// Bumped when a sign-in starts or ends, so views asking `isSignedIn` look again.
    private var signInChanges = 0

    // MARK: - Adding and refreshing

    /// Connects to a server by its address and lists its tools. One that wants a sign-in is
    /// added anyway, waiting for it. Throws when the address isn't usable or nothing answers.
    func add(_ address: String) async throws -> Connection {
        let url = try Self.endpoint(from: address)
        if let existing = connections.first(where: { $0.url == url }) { return existing }
        var connection = Connection(url: url, name: url.host() ?? address)
        do {
            let description = try await ConnectionSessions.shared.describe(url, id: connection.id)
            connection.name = description.name
            connection.tools = description.tools
            connection.checkedAt = .now
            status[connection.id] = .ready
        } catch let challenged as Challenged {
            challenges[connection.id] = challenged.headers
            status[connection.id] = .needsSignIn
        }
        connections.append(connection)
        save()
        Analytics.send(.connectionAdded(needsSignIn: challenges[connection.id] != nil))
        return connection
    }

    /// Lists a server's tools again, keeping what the user switched on or off.
    func refresh(_ id: UUID) async {
        guard let connection = connection(id) else { return }
        status[id] = .checking
        do {
            let description = try await ConnectionSessions.shared.describe(connection.url, id: id)
            update(id) { connection in
                let before = Dictionary(connection.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                connection.name = description.name
                connection.tools = description.tools.map { tool in
                    var tool = tool
                    if let old = before[tool.name] {
                        tool.isOn = old.isOn
                        // An "Always" holds for the tool as it was: one that now says it does
                        // something else is asked about again.
                        tool.alwaysAllowed = old.alwaysAllowed && old.readOnlyHint == tool.readOnlyHint && old.destructiveHint == tool.destructiveHint
                    }
                    return tool
                }
                connection.checkedAt = .now
            }
            status[id] = .ready
        } catch let challenged as Challenged {
            self.challenged(id, challenged)
        } catch {
            status[id] = .failed(error.localizedDescription)
        }
    }

    /// Every switched-on server whose tools were listed longer ago than `age`.
    func refresh(olderThan age: TimeInterval) async {
        await refresh(connections.filter { $0.isOn && ($0.checkedAt.map { -$0.timeIntervalSinceNow > age } ?? true) })
    }

    /// Every server not heard from since launch, as the Connections screen opens.
    func refreshUnchecked() async {
        await refresh(connections.filter { status[$0.id] == nil })
    }

    func refreshAll() async {
        await refresh(connections)
    }

    private func refresh(_ some: [Connection]) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in some {
                group.addTask { await self.refresh(connection.id) }
            }
        }
    }

    // MARK: - Signing in

    /// Signs in to a server, then lists its tools. `present` shows the sign-in page in a
    /// browser sheet and returns where it sent the user back to.
    func signIn(_ id: UUID, present: @escaping @Sendable (URL) async throws -> URL) async throws {
        guard let connection = connection(id) else { return }
        status[id] = .checking
        do {
            try await SignIn.signIn(to: connection.url, id: id, challenge: challenges[id], present: present)
        } catch {
            status[id] = .needsSignIn
            throw error
        }
        challenges[id] = nil
        signInChanges += 1
        await ConnectionSessions.shared.close(id)
        await refresh(id)
    }

    func signOut(_ id: UUID) async {
        SignIn.signOut(id)
        signInChanges += 1
        await ConnectionSessions.shared.close(id)
        status[id] = .needsSignIn
    }

    fileprivate func challenged(_ id: UUID, _ challenged: Challenged) {
        challenges[id] = challenged.headers
        status[id] = .needsSignIn
    }

    // MARK: - Settings

    func update(_ id: UUID, _ change: (inout Connection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
        save()
    }

    func updateTool(_ name: String, of id: UUID, _ change: (inout ConnectedTool) -> Void) {
        update(id) { connection in
            guard let index = connection.tools.firstIndex(where: { $0.name == name }) else { return }
            change(&connection.tools[index])
        }
    }

    /// Removes a server, with its sign-in.
    func remove(_ id: UUID) async {
        connections.removeAll { $0.id == id }
        status[id] = nil
        challenges[id] = nil
        save()
        SignIn.Credentials.remove(for: id)
        await ConnectionSessions.shared.close(id)
    }

    // MARK: - Saving

    private func load() {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Connection].self, from: data) else { return }
        connections = saved
        Self.current.connections = saved
    }

    private func save() {
        Self.current.connections = connections
        guard let file, let data = try? JSONEncoder().encode(connections) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    /// An address as typed, made into a secure server endpoint.
    static func endpoint(from address: String) throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else {
            throw ConnectionError.failed("That doesn't look like a server address.")
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else {
            throw ConnectionError.failed("Dream only connects to secure (https) addresses.")
        }
        return url
    }
}

/// The connections as last saved, behind a lock, for code that can't wait for the main actor.
private final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [Connection] = []

    var connections: [Connection] {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
