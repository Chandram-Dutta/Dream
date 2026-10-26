import SafariServices
import SwiftData
import SwiftUI

/// Your shared links: each page shared as a link, when, whether your numbers went too, and how
/// often it's been opened (a count, nothing about who). From here a link opens, is copied,
/// updated to its page's newest version at the same address, set to stop working, or stopped.
struct YourLinksView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var pages: [SavedSurface]
    @State private var links: [OwnedLink] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var working: Set<String> = []
    @State private var stopping: OwnedLink?
    /// A page holding what a connected service gave it, waiting for the user to say it may go.
    @State private var confirming: (link: OwnedLink, page: SavedSurface)?
    @State private var showingWeb: WebPage?
    @State private var signedIn = Session.isSignedIn

    private var shared: [OwnedLink] { links.filter(\.isShared) }
    private var stopped: [OwnedLink] { links.filter { !$0.isShared } }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !shared.isEmpty {
                    Section {
                        ForEach(shared) { link in row(link) }
                    } footer: {
                        Text("Views count each time someone opens a link. Dream keeps nothing about who.")
                    }
                }
                if !stopped.isEmpty {
                    Section("No longer shared") {
                        ForEach(stopped) { link in row(link) }
                    }
                }
                if signedIn, loaded {
                    Section {
                        NavigationLink("Pages you've chosen not to see") { BlockedSharersView() }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Your shared links")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SavedSurface.self) { SurfaceScreen(saved: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: signedIn) { await load() }
            .refreshable { await load() }
            .onReceive(NotificationCenter.default.publisher(for: Session.didChange)) { _ in signedIn = Session.isSignedIn }
            .sheet(item: $showingWeb) { $0.ignoresSafeArea() }
            .confirmationDialog("Stop sharing “\(stopping?.title ?? "")”?", isPresented: .init(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible, presenting: stopping) { link in
                Button("Stop sharing", role: .destructive) { Task { await stop(link) } }
            } message: { _ in
                Text("The link will say the page is no longer shared. Sharing it again makes a new link.")
            }
            .confirmationDialog("Update with what's from \(confirming.map { names($0.page) } ?? "")?", isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible, presenting: confirming) { pending in
                Button("Update and share it") { Task { await update(pending.link, from: pending.page, confirmed: true) } }
            } message: { pending in
                Text("This page shows what Dream read from \(names(pending.page)). Whoever has the link will see it.")
            }
            .animation(.smooth, value: links)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !signedIn {
            ContentUnavailableView {
                Label("Sign in to share links", systemImage: "link")
            } description: {
                Text("Links you share belong to your account, so you can see how often they're opened and stop them any time.")
            }
        } else if loaded, links.isEmpty, failure == nil {
            ContentUnavailableView {
                Label("No shared links yet", systemImage: "link")
            } description: {
                Text("Share a page as a link and it shows up here, with how many times it's been opened.")
            }
        } else if !loaded {
            ProgressView()
        }
    }

    // MARK: - A link

    private func row(_ link: OwnedLink) -> some View {
        let page = page(of: link)
        return Group {
            if let page, link.isShared {
                NavigationLink(value: page) { LinkRow(link: link, page: page, isWorking: working.contains(link.id)) { Task { await update(link, from: page) } } }
            } else if link.isShared {
                Button { showingWeb = WebPage(url: link.url) } label: { LinkRow(link: link, page: nil, isWorking: working.contains(link.id), update: nil) }
                    .buttonStyle(.plain)
            } else {
                LinkRow(link: link, page: nil, isWorking: false, update: nil)
            }
        }
        .contextMenu { if link.isShared { actions(link, page: page) } }
        .swipeActions {
            if link.isShared {
                Button("Stop sharing", systemImage: "link.badge.minus", role: .destructive) { stopping = link }
                Button("Copy link", systemImage: "doc.on.doc") { UIPasteboard.general.url = link.url }
                    .tint(link.accent?.color ?? .accentColor)
            }
        }
    }

    @ViewBuilder private func actions(_ link: OwnedLink, page: SavedSurface?) -> some View {
        Button("See what others see", systemImage: "safari") { showingWeb = WebPage(url: link.url) }
        Button("Copy link", systemImage: "doc.on.doc") { UIPasteboard.general.url = link.url }
        ShareLink("Share link", item: link.url, subject: Text(link.title))
        if let page {
            Button("Update to this version", systemImage: "arrow.triangle.2.circlepath") { Task { await update(link, from: page) } }
        }
        Menu("Stops working", systemImage: "timer") {
            ForEach(Expiry.allCases) { expiry in
                Button(expiry.label) { Task { await expire(link, expiry) } }
            }
        }
        Button("Stop sharing", systemImage: "link.badge.minus", role: .destructive) { stopping = link }
    }

    private func page(of link: OwnedLink) -> SavedSurface? {
        guard let id = link.page.flatMap(UUID.init(uuidString:)) else { return nil }
        return pages.first { $0.id == id }
    }

    private func names(_ page: SavedSurface) -> String {
        let services = page.surface.services ?? []
        return services.count <= 1 ? services.first ?? "a connected service" : services.dropLast().joined(separator: ", ") + " and " + services.last!
    }

    // MARK: - Changes

    private func load() async {
        guard signedIn else {
            links = []
            loaded = true
            return
        }
        do {
            links = try await ShareServer.myLinks()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func replace(_ link: OwnedLink) {
        if let index = links.firstIndex(where: { $0.id == link.id }) { links[index] = link }
    }

    private func perform(_ link: OwnedLink, _ change: () async throws -> OwnedLink) async {
        working.insert(link.id)
        defer { working.remove(link.id) }
        do {
            replace(try await change())
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The page's newest version, at the same link: with the user's numbers if the link has them.
    private func update(_ link: OwnedLink, from page: SavedSurface, confirmed: Bool = false) async {
        let surface = page.surface
        guard confirmed || (surface.services ?? []).isEmpty else {
            confirming = (link, page)
            return
        }
        let shared = SharedSurface(sharing: surface, values: link.hasValues ? page.values : nil)
        await perform(link) { try await ShareServer.update(link, to: shared) }
    }

    private func expire(_ link: OwnedLink, _ expiry: Expiry) async {
        await perform(link) { try await ShareServer.expire(link, at: expiry.date) }
    }

    private func stop(_ link: OwnedLink) async {
        await perform(link) { try await ShareServer.stop(link) }
    }
}

/// When a link stops working, counted from now.
private enum Expiry: CaseIterable, Identifiable {
    case day, week, month, never

    var id: Self { self }

    var label: String {
        switch self {
        case .day: "In a day"
        case .week: "In a week"
        case .month: "In a month"
        case .never: "Never"
        }
    }

    var date: Date? {
        switch self {
        case .day: .now.addingTimeInterval(86_400)
        case .week: .now.addingTimeInterval(7 * 86_400)
        case .month: .now.addingTimeInterval(30 * 86_400)
        case .never: nil
        }
    }
}

/// One link: the page in its colors, when it was shared and how, and its views as a number.
private struct LinkRow: View {
    let link: OwnedLink
    let page: SavedSurface?
    let isWorking: Bool
    /// Updates the link to the page as it is now, offered when the page has changed since.
    let update: (() -> Void)?

    private var palette: Palette { (link.accent ?? .indigo).palette }

    /// The page changed after the link last did.
    private var hasChanged: Bool {
        guard let page, link.isShared else { return false }
        return page.updatedAt.timeIntervalSince(link.updated) > 1
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(link.isShared ? palette.wash : Color.secondary.opacity(0.08))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: symbol)
                        .font(.headline)
                        .foregroundStyle(link.isShared ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(link.title.isEmpty ? "A page" : link.title)
                    .font(.display(.subheadline))
                    .foregroundStyle(link.isShared ? .primary : .secondary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if hasChanged, let update {
                    Button(action: update) {
                        Label("Changed since. Update the link", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.wash, in: .capsule)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.accent)
                    .padding(.top, 3)
                    .disabled(isWorking)
                }
            }
            Spacer(minLength: 8)
            if isWorking {
                ProgressView()
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(link.views.formatted())
                        .font(.display(.title3))
                        .monospacedDigit()
                        .foregroundStyle(link.isShared ? AnyShapeStyle(palette.numberGradient) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText(value: Double(link.views)))
                    Text(link.views == 1 ? "view" : "views")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        guard let symbol = link.symbol, UIImage(systemName: symbol) != nil else { return "link" }
        return symbol
    }

    private var detail: String {
        let day = Date.FormatStyle.dateTime.day().month(.abbreviated)
        switch link.state {
        case .removed: return "Taken down: it broke the rules for shared pages"
        case .expired: return "Stopped working \(link.expiresAt?.formatted(day) ?? "")"
        case .stopped: return "Shared \(link.created.formatted(day)), now stopped"
        case .shared:
            var parts = ["Shared \(link.created.formatted(day))", link.hasValues ? "with your numbers" : "blank"]
            if let expires = link.expiresAt { parts.append("stops \(expires.formatted(day))") }
            return parts.joined(separator: " · ")
        }
    }
}

/// Sharers the user chose not to see again, named by the page they blocked them from.
private struct BlockedSharersView: View {
    @State private var sharers: [BlockedSharer] = []
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        List {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(sharers) { sharer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whoever shared “\(sharer.title)”")
                        Text("Since \(sharer.created.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Show again") { Task { await unblock(sharer) } }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Show their pages again", systemImage: "eye") { Task { await unblock(sharer) } }
                    }
                }
            } footer: {
                if !sharers.isEmpty {
                    Text("Their links don't open in Dream for you. Swipe to show their pages again.")
                }
            }
        }
        .overlay {
            if loaded, sharers.isEmpty, failure == nil {
                ContentUnavailableView("Nobody", systemImage: "hand.raised", description: Text("When you choose not to see pages from someone who shared one, they show here."))
            }
        }
        .navigationTitle("Not shown")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .animation(.smooth, value: sharers)
    }

    private func load() async {
        do {
            sharers = try await ShareServer.blockedSharers()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func unblock(_ sharer: BlockedSharer) async {
        do {
            try await ShareServer.unblock(sharer)
            sharers.removeAll { $0.id == sharer.id }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A link as anyone else sees it, in Safari's viewer inside Dream, so it doesn't open back in Dream.
private struct WebPage: UIViewControllerRepresentable, Identifiable {
    let url: URL

    var id: URL { url }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Opens Your shared links from home, once the user is signed in and so can share links.
struct YourLinksButton: View {
    @State private var showing = false
    @State private var signedIn = Session.isSignedIn

    var body: some View {
        Group {
            if signedIn {
                Button { showing = true } label: {
                    Image(systemName: "link")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Your shared links")
                .sheet(isPresented: $showing) { YourLinksView() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Session.didChange)) { _ in signedIn = Session.isSignedIn }
    }
}
