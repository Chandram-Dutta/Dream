import SwiftData
import SwiftUI

/// Home's one button, for everything that isn't making a page: the account's initial in the colors
/// of the moment. It opens a small card with the account, what Dream knows, connections and shared
/// links. What needs attention shows on the button without words: a dot when Dream has noticed
/// something to confirm, and a ring when sync does, dotted while changes wait for a connection and
/// orange when something's wrong. The card says what, and what to do.
struct AccountButton: View {
    let palette: Palette
    private let account = Account.shared
    private let sync = Sync.shared
    @Query(filter: #Predicate<MemoryFact> { $0.isConfirmed == false }) private var noticed: [MemoryFact]
    @State private var showingCard = false
    /// Picked in the card, and opened once the card has gone: a sheet can't open over a popover
    /// that's still closing.
    @State private var next: AccountPlace?
    @State private var open: AccountPlace?
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = min(self.size, 48)
        Button { showingCard = true } label: {
            AccountMark(palette: palette, size: size)
                .overlay { ring }
                .overlay { dot(on: size) }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .smooth, value: sync.trouble)
        .animation(reduceMotion ? nil : .smooth, value: noticed.isEmpty)
        .accessibilityLabel("Account")
        .accessibilityValue(attention)
        .accessibilityHint("Your account, what Dream knows, connections and shared links")
        .popover(isPresented: $showingCard) {
            AccountCard(palette: palette, noticed: noticed.count) { place in
                next = place
                showingCard = false
            }
            .presentationCompactAdaptation(.popover)
            .onDisappear(perform: openNext)
        }
        .sheet(item: $open) { place in
            switch place {
            case .account: AccountView()
            case .memory: MemoryView()
            case .connections: ConnectionsSheet()
            case .links: YourLinksView()
            case .signIn: EmptyView()
            }
        }
    }

    /// Sync needing attention: a dotted ring while changes wait for a connection, since they'll go
    /// on their own; orange when it needs the person, or won't fix itself soon.
    @ViewBuilder private var ring: some View {
        if let trouble = sync.trouble {
            Circle()
                .stroke(
                    trouble.isWaiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: trouble.isWaiting ? [0.5, 3.5] : []))
                .padding(-4)
                .transition(.opacity)
        }
    }

    /// Something Dream noticed, waiting to be confirmed: a dot on the mark's shoulder, cut out of
    /// the mark so it reads against the same colors.
    @ViewBuilder private func dot(on size: CGFloat) -> some View {
        if !noticed.isEmpty {
            Circle()
                .fill(palette.accent)
                .frame(width: 10, height: 10)
                .background(Circle().fill(Color(.systemBackground)).padding(-2))
                .offset(x: size * 0.354, y: -size * 0.354)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        }
    }

    private var attention: String {
        var parts: [String] = []
        if !noticed.isEmpty { parts.append(noticed.count == 1 ? "1 thing to confirm" : "\(noticed.count) things to confirm") }
        if let trouble = sync.trouble { parts.append(trouble.title) }
        return parts.joined(separator: ", ")
    }

    private func openNext() {
        guard let place = next else { return }
        next = nil
        if place == .signIn {
            account.askToSignIn("Sign in to Dream")
        } else {
            open = place
        }
    }
}

/// Where the account card leads.
private enum AccountPlace: Identifiable {
    case account, memory, connections, links, signIn

    var id: Self { self }
}

/// What the account button opens: who's signed in, with the pages left today, then the places
/// that aren't about making a page. Sync shows at the bottom only when it needs attention.
private struct AccountCard: View {
    let palette: Palette
    let noticed: Int
    let go: (AccountPlace) -> Void
    private let account = Account.shared
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 290
    /// The mark, and the icons under it, share one column.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { go(account.isSignedIn ? .account : .signIn) } label: {
                HStack(spacing: 12) {
                    AccountMark(palette: palette, size: column)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.isSignedIn ? account.profile?.name ?? "Your account" : "Sign in")
                            .font(.display(.subheadline, weight: .bold))
                            .lineLimit(2)
                        if let detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.bottom, 4)
            row("What Dream knows", systemImage: "person.text.rectangle", to: .memory, marked: noticed > 0)
                .accessibilityValue(noticed > 0 ? "\(noticed) to confirm" : "")
            row("Connections", systemImage: "point.3.connected.trianglepath.dotted", to: .connections)
            if account.isSignedIn {
                row("Your shared links", systemImage: "link", to: .links)
            }
            SyncNote(column: column)
        }
        .buttonStyle(CardRowStyle(palette: palette))
        .padding(8)
        .frame(width: min(width, 360))
    }

    /// Under the name: what's left of today's pages, which otherwise lives deep in Account.
    private var detail: String? {
        guard account.isSignedIn else { return "To make, sync and share pages" }
        guard let left = Plan.shared.status?.pagesLeftToday else { return nil }
        return left == 1 ? "1 page left today" : "\(left) pages left today"
    }

    private func row(_ title: String, systemImage: String, to place: AccountPlace, marked: Bool = false) -> some View {
        Button { go(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(palette.accent)
                    .frame(width: column)
                Text(title)
                Spacer(minLength: 8)
                if marked {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }
}

/// The account as a mark: the initial of their name on the colors of the moment, or a figure when
/// Apple didn't share a name, or nobody's signed in.
struct AccountMark: View {
    let palette: Palette
    let size: CGFloat
    private let account = Account.shared

    var body: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: size, height: size)
            .overlay {
                if account.isSignedIn, let initial = account.profile?.initial {
                    Text(initial)
                        .font(.display(size: size * 0.46, weight: .bold))
                        .foregroundStyle(palette.onAccent)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(palette.onAccent)
                }
            }
            .accessibilityHidden(true)
    }
}

extension Account.Profile {
    /// The first letter of their name, if Apple shared it.
    var initial: String? {
        name?.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
    }
}
