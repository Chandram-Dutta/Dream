import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Signing in with Apple, on the phone. Each sign-in makes a random nonce: Apple gets its hash and
/// writes it into the identity token, and Dream's server checks the token against the nonce, so a
/// token is good for this one sign-in and no other (Server/src/apple.ts).
enum AppleSignIn {
    /// What Apple gave the app, ready for Dream's server.
    struct Credential {
        let identityToken: String
        /// Apple's id for the person in Dream, to ask Apple later whether they're still signed in.
        let user: String
        /// Apple sends the name only the first time someone signs in to Dream.
        let name: String?
        /// The nonce as made, before hashing: the server hashes it to compare.
        let nonce: String
    }

    enum Failure: LocalizedError {
        case canceled
        case unavailable
        case unusable

        var errorDescription: String? {
            switch self {
            case .canceled: "Signing in was canceled."
            case .unavailable: "Apple couldn't sign you in just now. Try again."
            case .unusable: "Apple didn't send what Dream needs. Try again."
            }
        }
    }

    /// 32 random bytes, base64url.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hashed(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Asks for the name and email (which Apple only shares the first time) and binds the request
    /// to `nonce`.
    static func prepare(_ request: ASAuthorizationAppleIDRequest, nonce: String) {
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashed(nonce)
    }

    /// What Dream's server needs from a finished sign-in.
    static func credential(from result: Result<ASAuthorization, any Error>, nonce: String) throws -> Credential {
        switch result {
        case .failure(let error):
            if let error = error as? ASAuthorizationError {
                throw error.code == .canceled ? Failure.canceled : Failure.unavailable
            }
            throw error
        case .success(let authorization):
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = apple.identityToken, let token = String(data: data, encoding: .utf8) else { throw Failure.unusable }
            let name = apple.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            return Credential(identityToken: token, user: apple.user, name: name?.isEmpty == false ? name : nil, nonce: nonce)
        }
    }

    /// A fresh authorization code, after the person confirms with Face ID or their passcode. Deleting
    /// an account sends it, so the server can ask Apple to forget Dream for them. Nil when Apple
    /// couldn't give one; throws `Failure.canceled` when they said no.
    static func confirm(with controller: AuthorizationController) async throws -> String? {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        do {
            guard case .appleID(let apple) = try await controller.performRequest(request),
                  let data = apple.authorizationCode else { return nil }
            return String(data: data, encoding: .utf8)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw Failure.canceled
        } catch {
            return nil
        }
    }
}
