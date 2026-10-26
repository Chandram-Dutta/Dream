import SwiftData
import SwiftUI

/// Opens surfaces shared with the user: from a universal link (`https://<server>/s/<id>`) or
/// from the web viewer's Open in Dream button (`dream://s/<id>`). What arrives is checked as
/// untrusted (`SharedSurface.received`), kept as a new surface marked as shared, and opened.
/// It never touches memory, and the user's own numbers and lists start fresh, apart from any
/// numbers the sender chose to include.
@MainActor @Observable
final class SharedLinks {
    enum Status: Equatable {
        case idle, opening
        case failed(String)
    }

    private(set) var status = Status.idle
    /// The surface to open, once it's kept.
    var opened: SavedSurface?

    func open(_ url: URL, in context: ModelContext) async {
        guard status != .opening else { return }
        guard let link = SharedLink(url) else {
            if url.scheme?.lowercased() == "dream" {
                status = .failed(ShareServer.base == nil ? "Set a sharing server in Under the hood to open shared screens." : "This link isn't one Dream can open.")
            }
            return
        }
        let address = link.url.absoluteString
        // Opened before: go back to it, with whatever the user has done since.
        let known = FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.sharedFrom == address })
        if let existing = try? context.fetch(known).first {
            opened = existing
            return
        }
        status = .opening
        do {
            let received = try SharedSurface.received(try await ShareServer.fetch(link))
            let surface = received.surface
            let saved = SavedSurface(intent: surface.question ?? surface.title, surface: surface, modelName: "",
                                     log: ["Shared with you: \(address)"] + received.issues.map { "Checked: \($0.message)" })
            saved.values = received.values
            saved.sharedFrom = address
            context.insert(saved)
            try? context.save()
            status = .idle
            opened = saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func dismissFailure() {
        status = .idle
    }
}

extension View {
    /// Opens shared links that reach the app, showing a quiet note while one is fetched.
    func receivingSharedScreens(_ links: SharedLinks) -> some View {
        modifier(SharedScreenReceiver(links: links))
    }
}

private struct SharedScreenReceiver: ViewModifier {
    let links: SharedLinks
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                Task { await links.open(url, in: context) }
            }
            .safeAreaInset(edge: .top) {
                note
                    .animation(.smooth, value: links.status)
            }
    }

    @ViewBuilder private var note: some View {
        switch links.status {
        case .idle:
            EmptyView()
        case .opening:
            HStack(spacing: 12) {
                ProgressView()
                Text("Opening a shared screen…").font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        case .failed(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.subheadline)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark", action: links.dismissFailure)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The sharing server, in Under the hood: until Dream's Worker has a permanent home, this is
/// where links are made and opened from.
struct ShareServerSettings: View {
    @AppStorage("shareServer") private var server = ""

    var body: some View {
        Section {
            TextField(ShareServer.builtIn?.host() ?? "dream-share.your-subdomain.workers.dev", text: $server)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !server.isEmpty, ShareServer.normalized(server) == nil {
                Text("That doesn't look like a server address. Use its https address, like dream-share.example.workers.dev.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text("Links to shared screens are made on this server, Dream's Worker on Cloudflare (Server/README.md). Empty uses the one this build was made for\(ShareServer.builtIn == nil ? ", and there isn't one yet" : "").")
        }
    }
}
