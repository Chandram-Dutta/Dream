import CryptoKit
import Foundation
#if os(iOS)
import DeviceCheck
#endif

/// Shows Dream's server that a model or web request comes from the app (Server/src/attest.ts).
/// On an iPhone, that's App Attest: a key in the Secure Enclave, which Apple attests once belongs
/// to a genuine copy of Dream, signs each request. Where a shared app key is set (the Mac bench,
/// or a phone set up by hand in Under the hood) it goes too, as `X-Dream-Key`; the session goes
/// separately, in `Authorization`.
enum AppProof {
    /// The shared app key: from the environment on the Mac bench, else the Keychain, where Under
    /// the hood › Web search saves it.
    static var key: String? {
        if let key = Build.environment("DREAM_WEB_KEY") { return key }
        return Keychain.read("web")
    }

    /// Whether this device can prove it's the app without the shared key.
    static var canAttest: Bool {
        #if os(iOS)
        return DCAppAttestService.shared.isSupported
        #else
        return false
        #endif
    }

    /// Whether requests can carry any proof at all.
    static var isAvailable: Bool { key != nil || canAttest }

    /// Headers proving a request for `path` with `body` comes from the app.
    static func headers(method: String, path: String, body: Data) async -> [String: String] {
        var headers: [String: String] = [:]
        if let key { headers["X-Dream-Key"] = key }
        #if os(iOS)
        if canAttest, let assertion = await Attestation.shared.assert(method: method, path: path, body: body) {
            headers.merge(assertion) { _, new in new }
        }
        #endif
        return headers
    }

    /// The server didn't know this device's key (`X-Dream-Attest: again`), so the next request makes a new one.
    static func serverAsks(_ response: HTTPURLResponse) {
        #if os(iOS)
        if response.value(forHTTPHeaderField: "X-Dream-Attest") == "again" {
            Task { await Attestation.shared.forget() }
        }
        #endif
    }
}

#if os(iOS)
/// This install's App Attest key: made and attested once, then used to sign requests. If
/// anything about it fails, requests go without an assertion (and the server decides), and it
/// isn't tried again for a while, so a broken attestation never slows every request.
actor Attestation {
    static let shared = Attestation()

    private let service = DCAppAttestService.shared
    private var attesting: Task<String?, Never>?
    private var failedAt: Date?

    /// The headers for one request: the key id, the time, and an assertion over both and the body.
    func assert(method: String, path: String, body: Data) async -> [String: String]? {
        guard let keyID = await keyID() else { return nil }
        let time = String(Int(Date().timeIntervalSince1970))
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let clientData = Data("\(method)\n\(path)\n\(time)\n\(bodyHash)".utf8)
        do {
            let assertion = try await service.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
            return ["X-Dream-Attest-Key": keyID, "X-Dream-Attest-Time": time, "X-Dream-Assertion": assertion.base64EncodedString()]
        } catch {
            // A reinstall or a restored backup leaves an id whose key is gone.
            if (error as? DCError)?.code == .invalidKey { forget() }
            note("assertion failed (\((error as NSError).code))")
            return nil
        }
    }

    func forget() {
        Keychain.save("", for: "attest")
    }

    private func keyID() async -> String? {
        if let saved = Keychain.read("attest") { return saved }
        if let failedAt, Date().timeIntervalSince(failedAt) < 600 { return nil }
        if let attesting { return await attesting.value }
        let task = Task { await attestNewKey() }
        attesting = task
        let keyID = await task.value
        attesting = nil
        if keyID == nil { failedAt = .now }
        return keyID
    }

    /// Asks the server for a challenge, makes a key, has Apple attest it for that challenge, and
    /// gives the server the attestation to check and keep.
    private func attestNewKey() async -> String? {
        guard let base = ServerAddress.dream, Session.isSignedIn else { return nil }
        do {
            var asking = URLRequest(url: base.appending(path: "api/attest/challenge"), timeoutInterval: 20)
            asking.httpMethod = "POST"
            Session.authorize(&asking)
            let (data, response) = try await URLSession.shared.data(for: asking)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let challenge = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["challenge"] as? String,
                  let challengeData = Data(base64Encoded: challenge) else { return nil }
            let keyID = try await service.generateKey()
            let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challengeData)))
            var keeping = URLRequest(url: base.appending(path: "api/attest/key"), timeoutInterval: 20)
            keeping.httpMethod = "POST"
            keeping.setValue("application/json", forHTTPHeaderField: "Content-Type")
            Session.authorize(&keeping)
            keeping.httpBody = try JSONSerialization.data(withJSONObject: ["keyId": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge])
            let (_, kept) = try await URLSession.shared.data(for: keeping)
            guard (kept as? HTTPURLResponse)?.statusCode == 201 else {
                note("the server didn't keep the key (\((kept as? HTTPURLResponse)?.statusCode ?? 0))")
                return nil
            }
            Keychain.save(keyID, for: "attest")
            note("attested a new key")
            return keyID
        } catch {
            note("attestation failed (\((error as NSError).domain) \((error as NSError).code))")
            return nil
        }
    }

    private func note(_ line: String) {
        Build.trace("[Dream/AppAttest] \(line)")
    }
}
#endif
