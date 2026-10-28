import AuthenticationServices
import SwiftUI

extension View {
    /// Everything about signing in that can come up anywhere: the welcome, a request to sign in
    /// when something needs an account, the question about what's already on the phone, and
    /// checking the session is still good whenever Dream comes back to the front.
    func accountFlow() -> some View {
        modifier(AccountFlow())
    }
}

private struct AccountFlow: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        @Bindable var account = Account.shared
        content
            // A layer rather than a cover, so it can appear while a sheet is still going away
            // (after signing out or deleting the account), and is simply there underneath.
            .overlay {
                if account.showsWelcome {
                    WelcomeView()
                        .accessibilityAddTraits(.isModal)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.5), value: account.showsWelcome)
            .sheet(item: $account.signInRequest) { request in
                SignInSheet(request: request)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await account.check() } }
            }
    }
}

/// Sign in with Apple, then Dream's server. Apple's own button, as Apple asks; the rest of the
/// screen around it is Dream's.
struct SignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 10) {
            SignInWithAppleButton(.continue) { request in
                nonce = AppleSignIn.makeNonce()
                AppleSignIn.prepare(request, nonce: nonce)
            } onCompletion: { result in
                let nonce = nonce
                Task { await finish(result, nonce: nonce) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .id(colorScheme)
            .frame(height: 54)
            .clipShape(.capsule)
            .opacity(working ? 0.4 : 1)
            .disabled(working)
            .overlay {
                if working { ProgressView() }
            }
            agreement
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: working)
        .animation(.smooth, value: failure)
    }

    /// What signing in agrees to, said where it's agreed to. The terms and privacy policy
    /// (Server/src/legal.ts) name the AI providers and what each receives, so this doesn't have to
    /// change when they do.
    private var agreement: some View {
        let link = { (title: String, page: LegalLinks.Page) in page.url.map { "[\(title)](\($0.absoluteString))" } ?? title }
        let text = "Dream sends what you ask to its AI providers to make your pages, and counts how it's used, which you can turn off in Account. By continuing, you agree to the \(link("Terms", .terms)) and \(link("Privacy Policy", .privacy))."
        return Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func finish(_ result: Result<ASAuthorization, any Error>, nonce: String) async {
        failure = nil
        do {
            let credential = try AppleSignIn.credential(from: result, nonce: nonce)
            working = true
            defer { working = false }
            try await Account.shared.signIn(credential)
        } catch AppleSignIn.Failure.canceled {
            // They changed their mind; nothing to say.
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// When something needs an account: what it was, why, and signing in. Once they have, what they
/// were doing carries on.
private struct SignInSheet: View {
    let request: Account.SignInRequest
    private let account = Account.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let summary = account.offeredMove {
                MoveQuestion(summary: summary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text(request.reason)
                        .font(.display(.title2, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Dream builds each page with a cloud model, through your account. Your account keeps your pages, lists and what Dream knows, on any iPhone you sign in on.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SignInButton()
                    Button("Not now") { dismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
                .padding(.top, 12)
            }
        }
        .background(alignment: .top) {
            Aura(palette: Palette.dream, energy: 0.08)
                .frame(height: 320)
        }
        .presentationDetents(account.offeredMove == nil ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(account.offeredMove != nil)
    }
}

/// Just after signing in, when the phone already holds things made before: whether to move them
/// into the account. Nothing leaves the phone unless they say so (LocalData.swift).
struct MoveQuestion: View {
    let summary: LocalData.Summary
    private let account = Account.shared
    private let palette = Palette.dream

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Bring what's on this iPhone?")
                    .font(.display(.title2, weight: .bold))
                    .padding(.top, 28)
                VStack(alignment: .leading, spacing: 14) {
                    if summary.pages > 0 {
                        row("square.grid.2x2", summary.pages == 1 ? "1 page" : "\(summary.pages) pages")
                    }
                    if summary.entries > 0 {
                        row("checklist", (summary.lists == 1 ? "1 list" : "\(summary.lists) lists") + ", " + (summary.entries == 1 ? "1 entry" : "\(summary.entries) entries"))
                    }
                    if summary.facts > 0 {
                        row("person.crop.circle", summary.facts == 1 ? "1 thing Dream knows about you" : "\(summary.facts) things Dream knows about you")
                    }
                }
                .panel(palette)
                Text("Moved into your account, they're on any iPhone you sign in on, and safe if this one is lost.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button { account.answerMove(true) } label: {
                    Text("Move them to my account")
                        .font(.headline)
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(palette.accent, in: .capsule)
                }
                .buttonStyle(.plain)
                Button("Keep them on this iPhone only") { account.answerMove(false) }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                Text("You can move them later, from your account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(palette.accent)
                .frame(width: 30)
            Text(text)
                .font(.display(.body, weight: .medium))
        }
    }
}
