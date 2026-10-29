import AuthenticationServices
import Foundation
import Observation
import SwiftData
import UIKit

/// Who's signed in to Dream on this iPhone, and everything that follows from it.
///
/// Dream needs an account: pages are built by AI models through Dream's server, which spends money
/// and keeps limits per person, and signing in is where someone agrees to the terms. So the welcome
/// stays until they sign in, and comes back when they sign out. Only device tours and the bench,
/// in testing builds, go without; for them, anything that reaches the cloud asks at the moment it's
/// needed (`askToSignIn`).
@MainActor @Observable
final class Account {
    static let shared = Account()

    struct Profile: Codable, Equatable {
        var id: String
        var name: String?
        /// Only if they shared it. With Hide My Email, an address Apple forwards to them.
        var email: String?
        var isPrivateEmail: Bool
        var createdAt: Date
    }

    /// Someone needs to sign in for what they just did, which carries on once they have.
    struct SignInRequest: Identifiable {
        let id = UUID()
        let reason: String
        let then: (@MainActor () -> Void)?
    }

    private(set) var isSignedIn = Session.isSignedIn
    private(set) var profile: Profile?
    /// The welcome, shown until someone signs in.
    var showsWelcome = false
    var signInRequest: SignInRequest?
    /// After signing in, what's on the phone, to offer to move into the account (LocalData.swift).
    var offeredMove: LocalData.Summary?
    /// Why this iPhone was signed out without the user doing it here, for the welcome to say.
    var notice: String?

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var afterMove: (@MainActor () -> Void)?
    @ObservationIgnored private var checkedAt: Date?

    private init() {
        profile = Keychain.read("account").flatMap { try? JSONDecoder().decode(Profile.self, from: Data($0.utf8)) }
    }

    /// At launch: watches for sign-ins and Apple withdrawing Dream's access, and checks the
    /// session is still good.
    func start(_ container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        // Device tours and the bench have nobody to sign in.
        let isTour = Build.flag("DreamTour") || Build.argument("DreamAutoIntent") != nil
        showsWelcome = !isSignedIn && !isTour
        Task {
            for await _ in NotificationCenter.default.notifications(named: Session.didChange) {
                isSignedIn = Session.isSignedIn
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: ASAuthorizationAppleIDProvider.credentialRevokedNotification) {
                await checkApple()
            }
        }
        Task {
            await checkApple()
            await check()
        }
    }

    /// Whether this iPhone can make pages: signed in, or using a developer's own model key.
    var mayMake: Bool {
        isSignedIn || XAILanguageModel.savedKey != nil
    }

    /// Asks the user to sign in, for `reason`, then carries on with `then`.
    func askToSignIn(_ reason: String, then: (@MainActor () -> Void)? = nil) {
        signInRequest = SignInRequest(reason: reason, then: then)
    }


    // MARK: - Signing in

    /// Signs in to Dream with what Apple gave the app.
    func signIn(_ credential: AppleSignIn.Credential) async throws {
        let signedIn = try await AccountServer.signIn(credential, device: Self.deviceName)
        Keychain.save(credential.user, for: "appleUser")
        Keychain.save(ServerAddress.dream?.absoluteString ?? "", for: "sessionServer")
        // Signing in agrees to the terms and privacy policy, which say Dream counts how it's used.
        ImproveDream.signedIn()
        keep(signedIn.user)
        Session.save(signedIn.token)
        isSignedIn = true
        notice = nil
        afterMove = signInRequest?.then
        // Things made before signing in: the welcome or sheet asks about them, then goes.
        if let context = container?.mainContext, LocalData.move == .undecided {
            let summary = LocalData.summary(in: context)
            if !summary.isEmpty {
                offeredMove = summary
                return
            }
            // Nothing here yet: whatever's made from now on is the account's.
            LocalData.move = .moved
        }
        finishSigningIn()
    }

    /// The answer to the move question.
    func answerMove(_ moving: Bool) {
        if moving {
            LocalData.requestMove()
        } else {
            LocalData.move = .declined
        }
        offeredMove = nil
        finishSigningIn()
    }

    /// Puts away the welcome or sheet, then carries on with what needed an account.
    private func finishSigningIn() {
        showsWelcome = false
        signInRequest = nil
        guard let then = afterMove else { return }
        afterMove = nil
        Task {
            // Once the sheet is out of the way.
            try? await Task.sleep(for: .seconds(0.5))
            then()
        }
    }

    /// What the server calls this iPhone in the list of devices: its kind and system, never its name.
    static var deviceName: String {
        "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }

    // MARK: - Staying signed in

    /// Fetches the profile again, at most every few minutes unless `force`. A session the server
    /// no longer knows (signed out from another device, the account deleted there, or a server
    /// fault) signs this iPhone out, but keeps what's on it: a 401 can't tell those apart, and
    /// erasing someone's pages on a server's word alone can't be undone.
    func check(force: Bool = false) async {
        guard isSignedIn, issuedHere else { return }
        if !force, let checkedAt, -checkedAt.timeIntervalSinceNow < 300 { return }
        checkedAt = .now
        do {
            keep(try await AccountServer.profile())
        } catch AccountServer.Failure.signedOut {
            await forget(notice: "This iPhone was signed out. Your pages, lists and what Dream knows are still here; sign in to keep them in your account.", erasing: false)
        } catch {
            // Offline, or the server's having a moment: stay as we are.
        }
    }

    /// Whether the session came from the server Dream talks to now. Pointing Under the hood at
    /// another server (`wrangler dev`) mustn't look like being signed out.
    private var issuedHere: Bool {
        guard let issuer = Keychain.read("sessionServer") else { return true }
        return issuer == ServerAddress.dream?.absoluteString
    }

    /// Apple says whether the user still lets Dream use their Apple ID. Stopping it in Settings
    /// signs them out here.
    private func checkApple() async {
        guard isSignedIn, let user = Keychain.read("appleUser") else { return }
        guard let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: user), state == .revoked else { return }
        try? await AccountServer.signOut("current")
        await forget(notice: "You stopped using your Apple ID with Dream, so this iPhone was signed out and your things were removed from it.")
    }

    private func keep(_ profile: Profile) {
        self.profile = profile
        ProductAnalytics.signedIn(userID: profile.id)
        if let data = try? JSONEncoder().encode(profile) {
            Keychain.save(String(decoding: data, as: UTF8.self), for: "account")
        }
    }

    // MARK: - Signing out and deleting

    /// Signs this iPhone out and removes everything personal from it. The server forgets the
    /// session if it can be reached; if not, the session ends anyway when it's next unused for 90
    /// days, and nothing on the phone can use it.
    func signOut() async {
        // Whatever hasn't reached the account yet goes now, while the session still works.
        await Sync.flush()
        // And this iPhone stops hearing about the account's pages.
        await Notifications.shared.signOut()
        try? await AccountServer.signOut("current")
        await forget()
    }

    /// Erases the account on the server, then everything here. Returns whether Apple was asked to
    /// forget Dream too.
    func delete(authorizationCode: String?) async throws -> Bool {
        let revoked = try await AccountServer.delete(authorizationCode: authorizationCode)
        await forget()
        return revoked
    }

    /// Nobody's signed in here any more. The session goes first, so sync stops before anything is
    /// erased and never sends the erasing as deletions (LocalData.swift). Only what the user chose
    /// (signing out, deleting the account, revoking Apple ID access) erases.
    private func forget(notice: String? = nil, erasing: Bool = true) async {
        Session.save(nil)
        isSignedIn = false
        for item in ["account", "appleUser", "sessionServer"] { Keychain.save("", for: item) }
        profile = nil
        offeredMove = nil
        afterMove = nil
        signInRequest = nil
        if erasing {
            // Sync's own record of what's sent goes too, so the next account starts clean.
            await Sync.clearLocalData()
            if let context = container?.mainContext { await LocalData.erase(in: context) }
        }
        self.notice = notice
        showsWelcome = true
    }
}
