import Foundation
import MCP

// Connected services (ROADMAP.md, workstream 8): signing in to a server that needs it.

/// Signing in to a connected server, as MCP's authorization spec lays out: OAuth 2.1 with PKCE.
///
/// The server's protected resource metadata (RFC 9728), found from its 401 challenge or at its
/// well-known address, names the authorization server. That server's metadata (RFC 8414, or
/// OpenID discovery) gives the endpoints. Dream registers itself there (RFC 7591) when it can,
/// sends the user to sign in in a browser sheet, and swaps the code for tokens bound to this
/// server (RFC 8707). Tokens live in the Keychain and are refreshed before they run out.
///
/// The SDK has its own authorizer, but it only accepts web or loopback redirects. An iPhone app
/// gets its callback through a private-use scheme from its bundle ID (RFC 8252), so the flow is
/// here, using the SDK's PKCE and discovery helpers.
enum SignIn {
    static let callbackScheme = "com.chandramdutta.dream"
    static let redirectURI = URL(string: "\(callbackScheme):/oauth/callback")!

    /// Where and how to sign in to one server.
    struct Plan: Sendable {
        var endpoint: URL
        /// The server, as tokens name it (RFC 8707).
        var resource: URL
        var issuer: URL
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopes: [String]
        var authMethods: [String]
        /// The server promises to say who it is in the callback (RFC 9207).
        var sendsIssuer: Bool
    }

    /// What Dream registered as at an authorization server, and the tokens it holds there.
    struct Credentials: Codable, Sendable {
        var issuer: URL
        var tokenEndpoint: URL
        var resource: URL
        var clientID: String
        var clientSecret: String?
        /// none, client_secret_post or client_secret_basic.
        var authMethod: String
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var scope: String?

        var isSignedIn: Bool { accessToken != nil }

        /// Expired, or about to be.
        func expires(within seconds: TimeInterval) -> Bool {
            expiresAt.map { $0.timeIntervalSinceNow < seconds } ?? false
        }

        static func load(for id: UUID) -> Credentials? {
            Keychain.read(account(id)).flatMap { try? JSONDecoder().decode(Credentials.self, from: Data($0.utf8)) }
        }

        func save(for id: UUID) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            Keychain.save(String(decoding: data, as: UTF8.self), for: Self.account(id))
        }

        static func remove(for id: UUID) {
            Keychain.save("", for: account(id))
        }

        private static func account(_ id: UUID) -> String { "mcp.\(id.uuidString)" }
    }

    enum Failure: LocalizedError {
        case noAuthorizationServer
        case insecure(String)
        case noPKCE
        case cantRegister
        case registrationRefused(String)
        case cancelled
        case refused(String)
        case mismatch
        case tokenRefused(String)

        var errorDescription: String? {
            switch self {
            case .noAuthorizationServer: "This service didn't say where to sign in."
            case .insecure(let what): "This service's \(what) isn't a secure address."
            case .noPKCE: "This service doesn't support the secure sign-in Dream uses."
            case .cantRegister: "This service only lets apps it already knows sign in."
            case .registrationRefused(let detail): "This service wouldn't register Dream (\(detail))."
            case .cancelled: "Sign-in was cancelled."
            case .refused(let detail): "Sign-in didn't go through (\(detail))."
            case .mismatch: "The sign-in reply didn't match the request, so Dream ignored it."
            case .tokenRefused(let detail): "This service wouldn't finish the sign-in (\(detail))."
            }
        }
    }

    private static let discovery = DefaultOAuthMetadataDiscovery()
    private static let validator = OAuthURLValidator()

    // MARK: - Discovery

    /// Where to sign in to a server. `challenge` is the headers of its 401, if there was one.
    static func plan(for endpoint: URL, challenge: [String: String]?, session: URLSession = .shared) async throws -> Plan {
        let bearer = challenge.flatMap { DefaultOAuthWWWAuthenticateParser().parseBearer(from: $0) }
        var candidates = discovery.protectedResourceMetadataURLs(for: endpoint)
        if let pointed = bearer?.resourceMetadataURL {
            try checked(pointed, "resource metadata")
            candidates.insert(pointed, at: 0)
        }
        var resource = try discovery.canonicalResourceURI(from: endpoint)
        var issuers: [URL] = []
        var supportedScopes: [String]?
        for url in candidates {
            guard let metadata: ProtectedResource = await fetch(url, session: session) else { continue }
            // Metadata for some other resource isn't about this server.
            if let named = metadata.resource.flatMap(URL.init(string:)) {
                guard let canonical = try? discovery.canonicalResourceURI(from: named),
                      discovery.protectedResourceMatches(resource: canonical, endpoint: resource) else { continue }
                resource = canonical
            }
            issuers = metadata.authorizationServers ?? []
            supportedScopes = metadata.scopesSupported
            break
        }
        // Servers from before resource metadata are their own authorization server.
        if issuers.isEmpty, let origin = try? discovery.authorizationServerFallbackIssuer(from: endpoint) {
            issuers = [origin]
        }
        for issuer in issuers {
            guard (try? checked(issuer, "sign-in server")) != nil else { continue }
            for url in discovery.authorizationServerMetadataURLs(for: issuer) {
                guard let metadata: AuthorizationServer = await fetch(url, session: session),
                      let authorize = metadata.authorizationEndpoint, let token = metadata.tokenEndpoint else { continue }
                // RFC 8414: metadata must come from the issuer it names.
                guard let named = metadata.issuer, same(named, issuer) else { continue }
                try checked(authorize, "sign-in page")
                try checked(token, "token address")
                if let register = metadata.registrationEndpoint { try checked(register, "registration address") }
                guard metadata.codeChallengeMethodsSupported?.contains(where: { $0.caseInsensitiveCompare("S256") == .orderedSame }) == true else {
                    throw Failure.noPKCE
                }
                let scopes = bearer?.scope.map { $0.split(separator: " ").map(String.init) } ?? supportedScopes ?? []
                return Plan(
                    endpoint: endpoint, resource: resource, issuer: issuer,
                    authorizationEndpoint: authorize, tokenEndpoint: token, registrationEndpoint: metadata.registrationEndpoint,
                    scopes: scopes, authMethods: metadata.tokenEndpointAuthMethodsSupported ?? ["client_secret_basic"],
                    sendsIssuer: metadata.authorizationResponseIssParameterSupported == true)
            }
        }
        throw Failure.noAuthorizationServer
    }

    // MARK: - Registration

    /// Dream's client at the plan's authorization server: the one registered before, or a new
    /// registration (RFC 7591). Dream is a public client, so it asks for no secret.
    static func client(for plan: Plan, existing: Credentials?, session: URLSession = .shared) async throws -> Credentials {
        if let existing, same(existing.issuer, plan.issuer) {
            var kept = existing
            kept.tokenEndpoint = plan.tokenEndpoint
            kept.resource = plan.resource
            return kept
        }
        guard let endpoint = plan.registrationEndpoint else { throw Failure.cantRegister }
        let method = plan.authMethods.contains("none") ? "none" : "client_secret_post"
        var body: [String: Any] = [
            "client_name": "Dream",
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": method,
        ]
        if !plan.scopes.isEmpty { body["scope"] = plan.scopes.joined(separator: " ") }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let registered = try? JSONDecoder().decode(Registration.self, from: data) else {
            throw Failure.registrationRefused(problem(in: data, status: (response as? HTTPURLResponse)?.statusCode))
        }
        return Credentials(
            issuer: plan.issuer, tokenEndpoint: plan.tokenEndpoint, resource: plan.resource,
            clientID: registered.clientID, clientSecret: registered.clientSecret,
            authMethod: registered.tokenEndpointAuthMethod ?? (registered.clientSecret == nil ? "none" : method))
    }

    // MARK: - Signing in

    /// The page that starts sign-in, and what's needed to check and use its reply.
    struct Attempt: Sendable {
        var url: URL
        var verifier: String
        var state: String
    }

    static func attempt(_ plan: Plan, client: Credentials) throws -> Attempt {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier(length: 32)
        let url = try OAuthAuthorizationCodeFlow().buildURL(
            authorizationEndpoint: plan.authorizationEndpoint,
            resource: plan.resource,
            redirectURI: redirectURI,
            clientID: client.clientID,
            codeChallenge: try PKCE.makeChallenge(from: verifier),
            scopes: plan.scopes.isEmpty ? nil : Set(plan.scopes),
            state: state,
            scopeSerializer: DefaultOAuthScopeSelector())
        return Attempt(url: url, verifier: verifier, state: state)
    }

    /// Checks the browser's reply and swaps its code for tokens.
    static func finish(_ attempt: Attempt, callback: URL, plan: Plan, client: Credentials, session: URLSession = .shared) async throws -> Credentials {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == attempt.state else { throw Failure.mismatch }
        // RFC 9207: the reply must come from the server Dream asked.
        if let issuer = item("iss") {
            guard let url = URL(string: issuer), same(url, plan.issuer) else { throw Failure.mismatch }
        } else if plan.sendsIssuer {
            throw Failure.mismatch
        }
        if let error = item("error") {
            throw error == "access_denied" ? Failure.cancelled : Failure.refused(item("error_description") ?? error)
        }
        guard let code = item("code"), !code.isEmpty else { throw Failure.mismatch }
        return try await tokens(for: client, session: session, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": attempt.verifier,
        ])
    }

    /// The whole sign-in. `present` shows the page and returns the reply's address.
    static func signIn(to endpoint: URL, id: UUID, challenge: [String: String]?, present: @Sendable (URL) async throws -> URL) async throws {
        let plan = try await plan(for: endpoint, challenge: challenge)
        let client = try await client(for: plan, existing: Credentials.load(for: id))
        // Registered before sign-in finishes, so a second try doesn't register again.
        if Credentials.load(for: id)?.clientID != client.clientID { client.save(for: id) }
        let attempt = try attempt(plan, client: client)
        let callback = try await present(attempt.url)
        try await finish(attempt, callback: callback, plan: plan, client: client).save(for: id)
    }

    /// Fresh tokens from the refresh token. The old refresh token stays if no new one comes.
    static func refresh(_ credentials: Credentials, session: URLSession = .shared) async throws -> Credentials {
        guard let refreshToken = credentials.refreshToken else { throw Failure.tokenRefused("nothing to refresh") }
        var refreshed = try await tokens(for: credentials, session: session, ["grant_type": "refresh_token", "refresh_token": refreshToken])
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        return refreshed
    }

    /// Signs out, keeping the registration for next time.
    static func signOut(_ id: UUID) {
        guard var credentials = Credentials.load(for: id) else { return }
        credentials.accessToken = nil
        credentials.refreshToken = nil
        credentials.expiresAt = nil
        credentials.save(for: id)
    }

    // MARK: - Tokens

    private static func tokens(for client: Credentials, session: URLSession, _ grant: [String: String]) async throws -> Credentials {
        var form = grant
        form["resource"] = client.resource.absoluteString
        var request = URLRequest(url: client.tokenEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch (client.authMethod, client.clientSecret) {
        case ("client_secret_basic", let secret?):
            let pair = "\(formEncoded(client.clientID)):\(formEncoded(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        case ("client_secret_post", let secret?):
            form["client_id"] = client.clientID
            form["client_secret"] = secret
        default:
            form["client_id"] = client.clientID
        }
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\(formEncoded($0.key))=\(formEncoded($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200..<300).contains(status), let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw Failure.tokenRefused(problem(in: data, status: status))
        }
        guard token.tokenType.caseInsensitiveCompare("bearer") == .orderedSame else { throw Failure.tokenRefused("not a bearer token") }
        var credentials = client
        credentials.accessToken = token.accessToken
        credentials.refreshToken = token.refreshToken ?? client.refreshToken
        credentials.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        credentials.scope = token.scope ?? client.scope
        return credentials
    }

    // MARK: - Pieces

    /// Sign-in addresses must be secure and public.
    @discardableResult
    private static func checked(_ url: URL, _ what: String) throws -> URL {
        do {
            try validator.validateHTTPSOrLoopback(url, context: what)
        } catch {
            throw Failure.insecure(what)
        }
        if let host = url.host()?.lowercased(), validator.isPrivateIPHost(host) { throw Failure.insecure(what) }
        return url
    }

    private static func fetch<Value: Decodable>(_ url: URL, session: URLSession) async -> Value? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Issuers compare without a trailing slash or case in the scheme and host.
    private static func same(_ a: URL, _ b: URL) -> Bool {
        func plain(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            return parts.string
        }
        return plain(a) != nil && plain(a) == plain(b)
    }

    private static func formEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
    }

    /// An OAuth error's words, for saying what went wrong.
    private static func problem(in data: Data, status: Int?) -> String {
        if let error = try? JSONDecoder().decode(OAuthProblem.self, from: data) {
            return error.description ?? error.error
        }
        return status.map { "error \($0)" } ?? "no reply"
    }

    private struct ProtectedResource: Decodable {
        let resource: String?
        let authorizationServers: [URL]?
        let scopesSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case resource
            case authorizationServers = "authorization_servers"
            case scopesSupported = "scopes_supported"
        }
    }

    private struct AuthorizationServer: Decodable {
        let issuer: URL?
        let authorizationEndpoint: URL?
        let tokenEndpoint: URL?
        let registrationEndpoint: URL?
        let codeChallengeMethodsSupported: [String]?
        let tokenEndpointAuthMethodsSupported: [String]?
        let authorizationResponseIssParameterSupported: Bool?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
            case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
            case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
        }
    }

    private struct Registration: Decodable {
        let clientID: String
        let clientSecret: String?
        let tokenEndpointAuthMethod: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let expiresIn: Int?
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct OAuthProblem: Decodable {
        let error: String
        let description: String?

        enum CodingKeys: String, CodingKey {
            case error
            case description = "error_description"
        }
    }
}

/// Gives the SDK's transport the bearer token for one connection, and keeps it fresh. It never
/// starts a sign-in itself: when the server wants one, it notes the challenge, and the
/// Connections screen asks the user. A screen being built just goes on without that service.
final class ConnectionAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    let id: UUID
    private let lock = NSLock()
    private var credentials: SignIn.Credentials?
    private var challenge: [String: String]?

    init(id: UUID) {
        self.id = id
        credentials = SignIn.Credentials.load(for: id)
    }

    /// The headers of the server's last refusal. Still there after a call fails, the server
    /// wants a sign-in Dream couldn't renew by itself.
    var pendingChallenge: [String: String]? { lock.withLock { challenge } }

    /// After a call goes through.
    func accepted() {
        lock.withLock { challenge = nil }
    }

    // One retry, after a refresh.
    var maxAuthorizationAttempts: Int { 2 }

    func validateEndpointSecurity(for endpoint: URL) throws {
        try OAuthURLValidator().validateHTTPSOrLoopback(endpoint, context: "MCP server")
    }

    func authorizationHeader(for endpoint: URL) -> String? {
        lock.withLock { credentials?.accessToken.map { "Bearer \($0)" } }
    }

    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        guard let current = lock.withLock({ credentials }), current.isSignedIn, current.refreshToken != nil, current.expires(within: 60) else { return }
        _ = await refreshed(current, session: session)
    }

    func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession) async throws -> Bool {
        lock.withLock { challenge = headers }
        guard statusCode == 401, let current = lock.withLock({ credentials }), current.refreshToken != nil else { return false }
        return await refreshed(current, session: session)
    }

    /// The refresh under way, which every call needing one waits on. Calls made together (a model
    /// asking three of a service's tools at once) each refreshed with the same refresh token;
    /// a service that hands out a new one each time took the first and refused the rest, which
    /// read as "sign in again".
    private var refreshing: Task<SignIn.Credentials?, Never>?

    private func refreshed(_ current: SignIn.Credentials, session: URLSession) async -> Bool {
        // Another call has refreshed since this one read the tokens: use theirs.
        if lock.withLock({ credentials?.accessToken != current.accessToken }) { return true }
        let task: Task<SignIn.Credentials?, Never> = lock.withLock {
            if let running = refreshing { return running }
            let started = Task { try? await SignIn.refresh(current, session: session) }
            refreshing = started
            return started
        }
        let fresh = await task.value
        lock.withLock { if refreshing == task { refreshing = nil } }
        guard let fresh else { return lock.withLock { credentials?.accessToken != current.accessToken } }
        lock.withLock {
            if credentials?.accessToken == current.accessToken {
                fresh.save(for: id)
                credentials = fresh
            }
        }
        return true
    }
}
