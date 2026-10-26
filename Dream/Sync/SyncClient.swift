import Foundation

/// Talks to the sync routes on Dream's server (Server/src/sync.ts). Every request carries the
/// user's session, which `authorize` adds.
struct SyncClient: Sendable {
    let base: URL
    let authorize: @Sendable (inout URLRequest) -> Void

    /// A page of the account's changes.
    struct Page: Decodable {
        var user: String
        var items: [SyncItem]
        var cursor: String
        var more: Bool
        /// The cursor was made for another account, so this page starts from the beginning.
        var reset: Bool?
        var now: Int64
    }

    /// What the server did with a batch.
    struct Taken: Decodable {
        struct Refused: Decodable {
            var kind: String
            var id: String
            var reason: String
        }

        var applied: Int
        /// Its own versions of the items it already had later changes to.
        var stale: [SyncItem]
        var refused: [Refused]
        var now: Int64
    }

    enum Failure: Error, Equatable {
        /// No connection.
        case offline
        /// The session is gone: the user has to sign in again.
        case signedOut
        /// The account has no room for more.
        case full
        /// Too many requests: try again after this long.
        case busy(TimeInterval)
        /// Anything else the server said, by status.
        case server(Int)
    }

    /// The largest photo the server takes.
    static let maxPhoto = 4_000_000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The account's changes after `cursor`, oldest first.
    func changes(since cursor: String?, limit: Int = 200) async throws -> Page {
        var components = URLComponents(url: base.appending(path: "api/sync"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))] + (cursor.map { [URLQueryItem(name: "since", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try JSONDecoder().decode(Page.self, from: try await send(request, expecting: 200))
    }

    /// Sends a batch of changes.
    func send(_ items: [SyncItem]) async throws -> Taken {
        var request = URLRequest(url: base.appending(path: "api/sync"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        request.httpBody = try encoder.encode(["items": items])
        return try JSONDecoder().decode(Taken.self, from: try await send(request, expecting: 200))
    }

    /// Keeps a page's photo under `id`.
    func upload(photo: Data, id: String) async throws {
        var request = URLRequest(url: base.appending(path: "api/photos/\(id)"))
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = photo
        _ = try await send(request, expecting: 201)
    }

    /// A photo's bytes, or nil when the server no longer has it.
    func photo(_ id: String) async throws -> Data? {
        let request = URLRequest(url: base.appending(path: "api/photos/\(id)"))
        do {
            return try await send(request, expecting: 200)
        } catch Failure.server(404) {
            return nil
        }
    }

    private func send(_ request: URLRequest, expecting status: Int) async throws -> Data {
        var request = request
        authorize(&request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where Self.offline.contains(error.code) {
            throw Failure.offline
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case status: return data
        case 401: throw Failure.signedOut
        case 507: throw Failure.full
        case 429:
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw Failure.busy(wait)
        default: throw Failure.server(code)
        }
    }

    private static let offline: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]
}
