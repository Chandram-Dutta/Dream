import Foundation

/// The signed-in user's session with Dream's server. Signing in with Apple gives it; every
/// request that keeps something for the user, or spends on their behalf, carries it as
/// `Authorization: Bearer <token>` (Server/src/auth.ts).
enum Session {
    /// Posted when someone signs in or out, so sync, sharing and limits can follow.
    static let didChange = Notification.Name("DreamSessionDidChange")

    /// The token: from the Keychain on the phone, or DREAM_SESSION on the Mac bench.
    static var token: String? {
        if let token = Build.environment("DREAM_SESSION") { return token }
        return Keychain.read("session")
    }

    static var isSignedIn: Bool { token != nil }

    /// Keeps a new token, or forgets it with nil.
    static func save(_ token: String?) {
        Keychain.save(token ?? "", for: "session")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Adds the session to a request for Dream's server.
    static func authorize(_ request: inout URLRequest) {
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}

extension ServerAddress {
    /// Dream's own server: the one set in Under the hood, else the one this build was made for
    /// (the `DREAM_SHARE_HOST` build setting).
    static var dream: URL? {
        if let custom = Build.setting("shareServer"), let url = normalized(custom) { return url }
        return (Bundle.main.object(forInfoDictionaryKey: "DreamShareHost") as? String).flatMap(normalized)
    }
}
