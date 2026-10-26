import AuthenticationServices
import UIKit

/// Shows a server's sign-in page in a browser sheet and returns the address it sends the user
/// back to. The sheet shares Safari's cookies, so someone already signed in to the service there
/// only has to approve Dream.
@MainActor
enum WebSignIn {
    /// Kept while it's on screen; the system doesn't hold on to it.
    private static var current: ASWebAuthenticationSession?

    static func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(SignIn.callbackScheme)) { callback, error in
                Task { @MainActor in current = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignIn.Failure.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SignIn.Failure.cancelled)
                }
            }
            session.presentationContextProvider = Anchor.shared
            current = session
            if !session.start() {
                current = nil
                continuation.resume(throwing: SignIn.Failure.cancelled)
            }
        }
    }
}

/// The window the sheet rises over.
@MainActor
private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Anchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Sign-in starts from a tap, so there's always a scene on screen.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            preconditionFailure("Signing in needs a window.")
        }
        return scene.keyWindow ?? scene.windows.first ?? ASPresentationAnchor(windowScene: scene)
    }
}
