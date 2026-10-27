import SwiftUI

/// Sync, at the foot of the account card on home, only when it matters: changes waiting without a
/// connection, a session that needs signing in again, a full account, or a server that keeps
/// failing. The rest of the time there's nothing to see. The account button's ring says the same
/// without words (AccountButton.swift); this says what, and what to do.
struct SyncNote: View {
    /// The card's icon column, so this lines up with the rows above.
    let column: CGFloat
    private let sync = Sync.shared

    var body: some View {
        if let trouble = sync.trouble {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: trouble.symbol)
                    .foregroundStyle(trouble.isWaiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .frame(width: column)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trouble.title)
                        .font(.subheadline.weight(.semibold))
                    Text(trouble.detail(unsent: sync.unsent))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if trouble == .offline || trouble == .failing {
                        Button("Try now") { Task { await Sync.flush() } }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Sync.Trouble {
    /// Changes waiting for a connection go on their own, so they're shown quietly; the rest need
    /// the person, or won't fix themselves soon, and are shown in orange.
    var isWaiting: Bool { self == .offline }

    func detail(unsent: Int) -> String {
        switch self {
        case .offline:
            unsent == 1 ? "1 change is on this iPhone, and syncs when you're back online." : "\(unsent) changes are on this iPhone, and sync when you're back online."
        case .signedOut: "Your changes stay on this iPhone until you sign in again."
        case .full: "New changes stay on this iPhone. Deleting pages you don't need makes room."
        case .failing: "Your changes are safe on this iPhone. Dream keeps trying."
        }
    }

    var title: String {
        switch self {
        case .offline: "Not synced yet"
        case .signedOut: "Sign in to keep syncing"
        case .full: "Your account is full"
        case .failing: "Sync isn't working right now"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "icloud.slash"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .full, .failing: "exclamationmark.icloud"
        }
    }
}

/// Sync in Under the hood: whether it's on, what's waiting to go, and when it last finished.
struct SyncSection: View {
    private let sync = Sync.shared

    var body: some View {
        Section {
            LabeledContent("Status", value: status)
            LabeledContent("Waiting to send", value: "\(sync.unsent)")
            LabeledContent("Last synced", value: sync.lastSynced?.formatted(.relative(presentation: .named)) ?? "—")
            Button("Sync now") { Task { await Sync.flush() } }
                .disabled(!sync.isOn)
        } header: {
            Text("Sync")
        } footer: {
            Text("When you're signed in, your pages with their history, your lists, what Dream knows about you, your connections and some settings are kept in your account, so they're on every device you use. Sign-ins to connected services stay on this iPhone.")
        }
    }

    private var status: String {
        guard sync.isOn else { return Session.isSignedIn ? "No server set" : "Not signed in" }
        return sync.trouble?.title ?? "Up to date"
    }
}
