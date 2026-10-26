import SwiftUI

/// Finding services to connect: the few Dream has checked, by what they're for, and the whole
/// MCP Registry, searched by name. One tap connects, signing in when a service asks.
struct DiscoverView: View {
    private let store = ConnectionStore.shared
    @State private var query = ""
    @State private var category: String?
    @State private var results: [DirectoryEntry] = []
    @State private var next: String?
    @State private var searching = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private let palette = Palette.now

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discover")
                        .font(.display(.largeTitle, weight: .bold))
                    Text("Services Dream can read from, and do things in, while it makes a page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                searchField
                if store.directoryServer == nil {
                    ContentUnavailableView("Discover needs Dream's server", systemImage: "network.slash",
                                           description: Text("Set a sharing server in Under the hood, or add a service by its address in Connections."))
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    featured
                } else {
                    found
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .top) {
            Aura(palette: palette, energy: 0)
                .frame(height: 420)
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshDirectory() }
        .task(id: query) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the MCP Registry", text: $query)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if searching {
                ProgressView()
            } else if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: - Featured

    private var categories: [String] {
        var seen: [String] = []
        for entry in store.featured { if let category = entry.category, !seen.contains(category) { seen.append(category) } }
        return seen
    }

    @ViewBuilder private var featured: some View {
        let shown = store.featured.filter { category == nil || $0.category == category }
        if !categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "All", isOn: category == nil, palette: palette) { category = nil }
                    ForEach(categories, id: \.self) { name in
                        Chip(title: name, isOn: category == name, palette: palette) { category = category == name ? nil : name }
                    }
                }
            }
            .scrollClipDisabled()
        }
        if shown.isEmpty {
            Text("Loading what Dream has checked…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(shown) { entry in
                DirectoryCard(entry: entry, compact: true)
            }
        }
        .animation(.smooth, value: category)
        Text("Dream has tried each of these. Anything else in the registry is listed by whoever made it, so connect only to services you trust.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Searching

    @ViewBuilder private var found: some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        } else if results.isEmpty && !searching {
            Text("Nothing in the registry is called that.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        LazyVStack(spacing: 12) {
            ForEach(results) { entry in
                DirectoryCard(entry: entry, compact: false)
            }
            if let next, !searching {
                Button("More") { Task { await search(after: next) } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.vertical, 8)
            }
        }
        if !results.isEmpty {
            Text("From the official MCP Registry, which anyone can list a server in. Connect only to services you trust.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func search(after cursor: String? = nil) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let server = store.directoryServer, !text.isEmpty else {
            results = []
            next = nil
            problem = nil
            return
        }
        if cursor == nil {
            // Typing settles before the registry is asked.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        searching = true
        defer { searching = false }
        do {
            let page = try await Directory.search(text, cursor: cursor, from: server)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                results = cursor == nil ? page.entries : results + page.entries.filter { entry in !results.contains { $0.url == entry.url } }
                next = page.next
                problem = nil
            }
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
        }
    }
}

private struct Chip: View {
    let title: String
    let isOn: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(isOn ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(palette.accent.opacity(0.1)), in: .capsule)
            .overlay(Capsule().strokeBorder(palette.edge, lineWidth: isOn ? 0 : 0.5))
            .buttonStyle(.plain)
    }
}

// MARK: - A service

/// One service from the directory, in its own colors, with a button that connects it.
struct DirectoryCard: View {
    let entry: DirectoryEntry
    /// In the featured grid: name, line and button stacked. Otherwise a wide row.
    let compact: Bool

    var body: some View {
        let palette = ServiceMonogram.palette(for: entry.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ServiceIcon(entry: entry)
                if !compact {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.display(.headline))
                        Text(entry.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    ConnectButton(entry: entry, palette: palette)
                }
            }
            if compact {
                Text(entry.name)
                    .font(.display(.headline))
                    .lineLimit(1)
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
                    .frame(maxWidth: .infinity, minHeight: compact ? 32 : nil, alignment: .topLeading)
            }
            if let signIn = entry.signIn {
                Label(signIn ? "Signs in" : "No sign-in", systemImage: signIn ? "key.fill" : "checkmark.seal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if compact {
                ConnectButton(entry: entry, palette: palette)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .topTrailing) {
                palette.wash
                Circle()
                    .fill(palette.gradient)
                    .frame(width: 120, height: 120)
                    .blur(radius: 40)
                    .opacity(0.35)
                    .offset(x: 40, y: -50)
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(palette.edge, lineWidth: 0.5))
    }
}

/// The service's own icon when the directory has one from its own domain, else its initial.
private struct ServiceIcon: View {
    let entry: DirectoryEntry

    var body: some View {
        if let icon = entry.icon {
            AsyncImage(url: icon) { image in
                image.resizable().scaledToFit().clipShape(.rect(cornerRadius: 9))
            } placeholder: {
                ServiceMonogram(name: entry.name, isOn: true)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
        } else {
            ServiceMonogram(name: entry.name, isOn: true)
        }
    }
}

/// Connects a directory entry in one tap, signing in when it asks, and says how it went.
struct ConnectButton: View {
    let entry: DirectoryEntry
    let palette: Palette
    var label = "Connect"
    /// Told once it's connected and ready.
    var onConnected: (() -> Void)?
    private let store = ConnectionStore.shared
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.connection(for: entry) != nil && !working {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if working { ProgressView().tint(.white) }
                        Text(working ? "Connecting…" : label)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(palette.gradient, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .animation(.smooth, value: working)
    }

    private func connect() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                _ = try await store.connect(entry, present: { try await WebSignIn.present($0) })
                onConnected?()
            } catch SignIn.Failure.cancelled {
                // They can try again.
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - In a page

/// Above a page whose request names a service the user hasn't connected, like "my Linear
/// issues": a quiet offer to connect it, after which the request runs again.
struct ConnectSuggestions: View {
    let entries: [DirectoryEntry]
    let palette: Palette
    let onConnected: () -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(spacing: 10) {
                ForEach(entries) { entry in
                    HStack(alignment: .center, spacing: 12) {
                        ServiceIcon(entry: entry)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect \(entry.name) to see what's in it")
                                .font(.subheadline.weight(.semibold))
                            Text(entry.signIn == true ? "You'll sign in to \(entry.name). Dream asks before it reads anything." : "Dream asks before it reads anything.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        ConnectButton(entry: entry, palette: palette, onConnected: onConnected)
                    }
                    .padding(14)
                    .background(palette.wash, in: .rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.edge, lineWidth: 0.5))
                }
            }
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
