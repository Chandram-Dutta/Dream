import Foundation

/// The account routes on Dream's server (Server/src/accounts.ts): signing in with Apple, the
/// profile, devices, export and deletion. Everything but signing in carries the session.
enum AccountServer {
    struct SignedIn: Decodable {
        let token: String
        let user: Account.Profile
        /// Whether this sign-in made the account.
        let isNew: Bool
    }

    /// A device signed in to the account.
    struct Device: Decodable, Identifiable, Equatable {
        let id: String
        let device: String?
        let createdAt: Date
        let lastUsedAt: Date
        /// The device asking: this iPhone.
        let current: Bool
    }

    enum Failure: LocalizedError {
        case noServer
        /// The session isn't good any more: signed out elsewhere, expired, or the account is gone.
        case signedOut
        case refused(String)
        case unreachable

        var errorDescription: String? {
            switch self {
            case .noServer: "Dream's server isn't set."
            case .signedOut: "You've been signed out."
            case .refused(let message): message
            case .unreachable: "Couldn't reach Dream. Check your connection and try again."
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func signIn(_ credential: AppleSignIn.Credential, device: String) async throws -> SignedIn {
        var body: [String: String] = ["identityToken": credential.identityToken, "nonce": credential.nonce, "device": device]
        body["name"] = credential.name
        let data = try await send("api/auth/apple", method: "POST", body: body, signedIn: false, expecting: 201)
        return try decode(SignedIn.self, from: data)
    }

    static func profile() async throws -> Account.Profile {
        try decode(Account.Profile.self, from: try await send("api/me"))
    }

    static func devices() async throws -> [Device] {
        struct Devices: Decodable { let sessions: [Device] }
        return try decode(Devices.self, from: try await send("api/me/sessions")).sessions
    }

    /// Signs one device out; "current" is this one.
    static func signOut(_ id: String) async throws {
        _ = try await send("api/me/sessions/\(id)", method: "DELETE", expecting: 204)
    }

    /// This iPhone's token for notifications (Server/src/push.ts), for the account signed in on it.
    static func registerPush(token: String, environment: PushEnvironment) async throws {
        _ = try await send("api/push/devices", method: "POST", body: ["token": token, "environment": environment.rawValue], expecting: 204)
    }

    /// Forgets this iPhone's token, so the account's pages aren't announced on it any more.
    static func forgetPush(token: String) async throws {
        _ = try await send("api/push/devices/\(token)", method: "DELETE", expecting: 204)
    }

    /// Everything the server keeps for the user, as the JSON file it sends.
    static func export() async throws -> Data {
        try await send("api/me/export", method: "POST")
    }

    /// Erases the account. Returns whether Apple was asked to forget Dream too.
    static func delete(authorizationCode: String?) async throws -> Bool {
        var body: [String: String] = [:]
        body["authorizationCode"] = authorizationCode
        struct Deleted: Decodable { let appleRevoked: Bool }
        return try decode(Deleted.self, from: try await send("api/me", method: "DELETE", body: body)).appleRevoked
    }

    // MARK: - Sending

    private static func send(_ path: String, method: String = "GET", body: [String: String]? = nil, signedIn: Bool = true, expecting expected: Int = 200) async throws -> Data {
        guard let base = ServerAddress.dream else { throw Failure.noServer }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if signedIn {
            guard Session.isSignedIn else { throw Failure.signedOut }
            Session.authorize(&request)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == expected { return data }
        if status == 401 && signedIn { throw Failure.signedOut }
        struct Problem: Decodable { let error: String }
        throw Failure.refused((try? JSONDecoder().decode(Problem.self, from: data).error) ?? "Something went wrong. Try again in a moment.")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw Failure.refused("Dream's server sent something unexpected. Try again in a moment.")
        }
    }
}
