import Foundation
import Observation

/// Permission to send what someone asks to xAI, whose Grok writes Dream's pages. App Store
/// guideline 5.1.2(i) asks apps to say clearly when personal data goes to another company's AI,
/// and to get explicit permission first.
///
/// Nothing is blocked in settings: the first time a page would be made or changed through Grok,
/// Dream asks, and the page waits for the answer, the way it waits on questions asked before
/// building. Account can take it back, and then Dream asks again next time. Private Cloud
/// Compute and the on-device model are Apple's own, so they never ask.
@MainActor @Observable
final class AIConsent {
    static let shared = AIConsent()

    /// What the user agreed to. Raise it when what's sent, or who it goes to, changes, and
    /// everyone is asked again.
    nonisolated static let version = 1
    /// The UserDefaults key, which views can watch with `@AppStorage`. It holds the version.
    nonisolated static let key = "aiConsent"

    /// What a page says when the user said no.
    nonisolated static let declined = "Dream makes pages with Grok, by xAI, and needs your permission to send it what you ask. You can allow it the next time you make a page."

    nonisolated static var isGiven: Bool {
        #if os(macOS)
        // The bench and the checks on this Mac, where there's nobody to ask.
        true
        #else
        // Device tours have nobody to ask either.
        Build.flag("DreamTour") || Build.argument("DreamAutoIntent") != nil || UserDefaults.standard.integer(forKey: key) >= version
        #endif
    }

    /// True while a page is waiting for the answer, which puts the question on screen.
    private(set) var isAsking = false
    @ObservationIgnored private var waiting: [CheckedContinuation<Bool, Never>] = []

    /// Whether Dream may send this to xAI, asking first if the user hasn't said.
    func ask() async -> Bool {
        if Self.isGiven { return true }
        isAsking = true
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// The user's answer, from the question or from Account.
    func answer(_ allowed: Bool) {
        Self.set(allowed)
        isAsking = false
        let answered = waiting
        waiting = []
        for continuation in answered { continuation.resume(returning: allowed) }
    }

    nonisolated static func set(_ allowed: Bool) {
        if allowed {
            UserDefaults.standard.set(version, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

extension Composer.Provider {
    /// Whether what's asked goes to xAI: through Dream's server, or with a developer's own key.
    var sendsToXAI: Bool {
        switch self {
        case .dream, .xai: true
        case .privateCloud: false
        }
    }
}
