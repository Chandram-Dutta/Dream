import SwiftData
import UIKit
import UserNotifications

/// Notifications from Dream's server (docs/ServerGeneration.md, Stage 3): a page made there that
/// nobody is watching says when it's ready, when Dream has a question about it, or when it needs
/// this iPhone to run one of its tools. What they carry and where tapping one goes are Push.swift;
/// this asks for them, registers this iPhone with the account, and opens what was tapped.
///
/// Dream asks the first time a page is still being made when the user leaves it, its screen or
/// the app: that's when a notification is worth having, and never at launch. Once they're allowed,
/// this iPhone registers at every launch and sign-in, and the server forgets it at sign-out.
@MainActor @Observable
final class Notifications: NSObject {
    static let shared = Notifications()

    typealias Destination = PushOpening<SavedSurface, FormingPage>

    /// A notification tapped, for the shelf to open (HomeView).
    struct Opened: Equatable {
        let id = UUID()
        let destination: Destination
    }

    var opened: Opened?

    @ObservationIgnored private var container: ModelContainer?
    /// The app was left with a page being made, before Dream had asked: it asks on coming back.
    @ObservationIgnored private var askOnReturn = false

    private static let askedKey = "notificationsAsked"
    /// The token iOS gave this iPhone, for forgetting it at sign-out. It isn't anyone's data.
    private static let tokenKey = "pushToken"

    /// At launch, before the app finishes launching, so a tap that launched it is heard.
    func start(_ container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        UNUserNotificationCenter.current().delegate = self
        // A notification names a page, so the account's go with everything else.
        LocalData.erasers.append { _ in UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
        Task {
            for await _ in NotificationCenter.default.notifications(named: Session.didChange) where Session.isSignedIn {
                await register()
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) where askOnReturn {
                askOnReturn = false
                // Once the app is in front again.
                try? await Task.sleep(for: .seconds(1))
                await ask()
            }
        }
        Task { await register() }
    }

    // MARK: - Asking and registering

    /// A page is still being made on the server and the user left it. The first time, Dream asks
    /// to notify: now if the app is in front, or when it's back.
    func pageLeft() {
        guard Session.isSignedIn, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        if UIApplication.shared.applicationState == .background {
            askOnReturn = true
        } else {
            Task { await ask() }
        }
    }

    private func ask() async {
        let center = UNUserNotificationCenter.current()
        // Asked once; afterwards it's Settings' to change.
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        await register()
    }

    /// Has iOS give this iPhone's token, when notifications are allowed and someone is signed in:
    /// at launch, on signing in, and once they're allowed. It comes back to `registered`.
    func register() async {
        guard Session.isSignedIn, ServerAddress.dream != nil else { return }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    /// The token, from the app delegate: sent to the account, with which of Apple's servers it's for.
    func registered(_ deviceToken: Data) {
        let token = deviceToken.hexToken
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        guard Session.isSignedIn else { return }
        Task {
            do {
                try await AccountServer.registerPush(token: token, environment: .current)
            } catch {
                Build.trace("[Dream/Push] The server didn't take this iPhone's token: \(error.localizedDescription)")
            }
        }
    }

    /// At sign-out, while the session still works: the server forgets this iPhone, so the
    /// account's pages aren't announced on it any more.
    func signOut() async {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey), !token.isEmpty else { return }
        try? await AccountServer.forgetPush(token: token)
    }

    // MARK: - Opening

    /// Opens what a tapped notification names. A finished page that's neither saved nor started
    /// here, like one asked for on another iPhone, may come with a round of sync.
    func open(_ payload: PushPayload?) async {
        var destination = destination(for: payload)
        if case .shelf = destination, payload?.kind == .done, Session.isSignedIn {
            await Sync.shared.roundNow()
            destination = self.destination(for: payload)
        }
        opened = Opened(destination: destination)
    }

    private func destination(for payload: PushPayload?) -> Destination {
        .destination(for: payload, saved: { ServerPages.shared.page($0) }, forming: { self.started($0).map(FormingPage.init) })
    }

    private func started(_ page: UUID) -> StartedPage? {
        var descriptor = FetchDescriptor<StartedPage>(predicate: #Predicate { $0.pageID == page })
        descriptor.fetchLimit = 1
        return try? container?.mainContext.fetch(descriptor).first
    }

    /// While the app is open: not for a page this iPhone is following already, which shows the
    /// same thing on its screen or its tile.
    private func presents(_ payload: PushPayload?) -> UNNotificationPresentationOptions {
        if let payload, ServerPages.shared.following[payload.page] != nil { return [] }
        return [.banner, .list, .sound]
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let payload = PushPayload(notification.request.content.userInfo)
        return await presents(payload)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let payload = PushPayload(response.notification.request.content.userInfo)
        await open(payload)
    }
}

/// What only an app delegate hears: the token iOS gives this iPhone for notifications.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Notifications.shared.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Build.trace("[Dream/Push] iOS gave no token: \(error.localizedDescription)")
    }
}
