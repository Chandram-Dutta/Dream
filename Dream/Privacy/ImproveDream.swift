import Foundation
import UIKit

/// "Help improve Dream": one choice that covers crash and hang reports (Diagnostics.swift, sent
/// to Dream's own server) and counts of what people use (ProductAnalytics.swift, through
/// PostHog). It's off until someone signs in, which agrees to the terms and privacy policy that
/// say so, and on from then; Account turns it off. Turning it off stops both at once.
enum ImproveDream {
    /// The UserDefaults key, which views can watch with `@AppStorage`.
    static let key = "improveDream"

    /// Nil until the user signs in, or turns it off in Account.
    static var choice: Bool? { UserDefaults.standard.object(forKey: key) as? Bool }

    static var isOn: Bool { choice == true }

    /// At launch: starts what the user agreed to, and counts each time Dream is opened.
    @MainActor static func start() {
        // Signed in before it was on from sign-in: the same as signing in now.
        if Session.isSignedIn, choice == nil { UserDefaults.standard.set(true, forKey: key) }
        apply()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Analytics.send(.appOpened)
        }
        NotificationCenter.default.addObserver(forName: Session.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !Session.isSignedIn { ProductAnalytics.signedOut() }
            }
        }
    }

    /// At sign-in: on, unless the user turned it off before.
    @MainActor static func signedIn() {
        if choice == nil { set(true) }
    }

    /// The user's choice, from Account.
    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        apply()
    }

    @MainActor private static func apply() {
        if isOn {
            Diagnostics.shared.start()
            ProductAnalytics.start()
        } else {
            Diagnostics.shared.stop()
            ProductAnalytics.stop()
        }
    }
}
