import Foundation
import UIKit

/// "Help improve Dream": one choice that covers crash and hang reports (Diagnostics.swift, sent
/// to Dream's own server) and counts of what people use (ProductAnalytics.swift, through
/// PostHog). It's off until the user answers: the home screen asks once, and Account can change
/// it. Turning it off stops both at once.
enum ImproveDream {
    /// The UserDefaults key, which views can watch with `@AppStorage`.
    static let key = "improveDream"

    /// Nil until the user has answered.
    static var choice: Bool? { UserDefaults.standard.object(forKey: key) as? Bool }

    static var isOn: Bool { choice == true }

    /// At launch: starts what the user agreed to, and counts each time Dream is opened.
    @MainActor static func start() {
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

    /// The user's answer, from the home screen's question or from Account.
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
