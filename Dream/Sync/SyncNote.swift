import SwiftUI

/// Sync on the home screen, only when it matters: changes waiting without a connection, a
/// session that needs signing in again, a full account, or a server that keeps failing. The rest
/// of the time there's nothing to see.
struct SyncNote: View {
    @State private var showing = false
    private let sync = Sync.shared

    var body: some View {
        ZStack {
            if let trouble = sync.trouble {
                Button { showing = true } label: {
                    Image(systemName: trouble.symbol)
                        .font(.title2)
                        .foregroundStyle(trouble == .offline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(trouble.title)
                .popover(isPresented: $showing) {
                    SyncTroubleDetail(trouble: trouble, unsent: sync.unsent)
                        .presentationCompactAdaptation(.popover)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth, value: sync.trouble)
    }
}

private struct SyncTroubleDetail: View {
    let trouble: Sync.Trouble
    let unsent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trouble.title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if trouble == .offline || trouble == .failing {
                Button("Try now") { Task { await Sync.flush() } }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 290, alignment: .leading)
    }

    private var detail: String {
        switch trouble {
        case .offline:
            unsent == 1 ? "1 change is on this iPhone, and syncs when you're back online." : "\(unsent) changes are on this iPhone, and sync when you're back online."
        case .signedOut: "Your changes stay on this iPhone until you sign in again."
        case .full: "New changes stay on this iPhone. Deleting pages you don't need makes room."
        case .failing: "Your changes are safe on this iPhone. Dream keeps trying."
        }
    }
}

extension Sync.Trouble {
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
