import Foundation
import PostHog

/// Counts of what people use, through PostHog, while the user lets Dream improve. Only the events
/// in Analytics.swift go: there's no session replay, no automatic screen, lifecycle or touch
/// events, no surveys, and PostHog isn't asked to work out where someone is from their address.
/// Crashes go to Dream's own server instead (Diagnostics.swift).
///
/// The project key and host come from the `POSTHOG_KEY` and `POSTHOG_HOST` build settings, by
/// way of Info.plist, like `DREAM_SHARE_HOST`. With no key, nothing starts.
@MainActor
enum ProductAnalytics {
    private static var isSetUp = false
    /// Dream's own id for the signed-in person (the server's, never Apple's or an email), kept so
    /// counting can pick up after the user agrees later.
    private static let userKey = "analyticsUserID"

    private static var projectKey: String? { setting("PostHogKey") }
    private static var host: String { setting("PostHogHost") ?? PostHogConfig.defaultHost }

    /// Starts, or resumes, sending. Called when the user agrees, and at launch if they already have.
    static func start() {
        guard let projectKey else { return }
        if !isSetUp {
            let config = PostHogConfig(projectToken: projectKey, host: host)
            config.captureApplicationLifecycleEvents = false
            config.captureScreenViews = false
            config.enableSwizzling = false
            config.sessionReplay = false
            config.surveys = false
            config.disableGeoIp = true
            config.sendFeatureFlagEvent = false
            config.errorTrackingConfig.autoCapture = false
            config.personProfiles = .identifiedOnly
            PostHogSDK.shared.setup(config)
            isSetUp = true
        }
        // A choice made at an earlier launch is kept by the SDK, and would win over the setup.
        if PostHogSDK.shared.isOptOut() { PostHogSDK.shared.optIn() }
        if let user = UserDefaults.standard.string(forKey: userKey), PostHogSDK.shared.getDistinctId() != user {
            PostHogSDK.shared.identify(user)
        }
        Analytics.sink = { name, properties in
            PostHogSDK.shared.capture(name, properties: properties.mapValues { $0 as Any })
        }
        FeatureFlag.source = { key in
            switch PostHogSDK.shared.getFeatureFlag(key) {
            case let on as Bool: on
            case is String: true
            default: nil
            }
        }
    }

    /// Stops sending at once, when the user says no or changes their mind.
    static func stop() {
        Analytics.sink = nil
        FeatureFlag.source = nil
        guard isSetUp else { return }
        PostHogSDK.shared.optOut()
    }

    /// After signing in: counts from here on belong to this person, by Dream's own id for them.
    /// Account calls it each time it has the profile, so only a new person counts as a sign-in.
    static func signedIn(userID: String) {
        guard UserDefaults.standard.string(forKey: userKey) != userID else { return }
        UserDefaults.standard.set(userID, forKey: userKey)
        guard isSetUp, !PostHogSDK.shared.isOptOut() else { return }
        PostHogSDK.shared.identify(userID)
        Analytics.send(.signedIn)
    }

    /// After signing out: the next person on this phone starts fresh.
    static func signedOut() {
        guard UserDefaults.standard.string(forKey: userKey) != nil else { return }
        Analytics.send(.signedOut)
        UserDefaults.standard.removeObject(forKey: userKey)
        if isSetUp { PostHogSDK.shared.reset() }
    }

    private static func setting(_ name: String) -> String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: name) as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
