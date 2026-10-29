import PhotosUI
import SwiftData
import SwiftUI

/// Where everything starts. Ask at the bottom, or tap an idea; what you've made glows above,
/// each in its own colors.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSurface.updatedAt, order: .reverse) private var surfaces: [SavedSurface]
    /// Pages still being made on Dream's server.
    @Query(sort: \StartedPage.startedAt, order: .reverse) private var started: [StartedPage]
    @State private var intent = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var request: ComposeRequest?
    @State private var ideas = Ideas()
    @State private var canCompose = Composer.canCompose
    @State private var showingSettings = false
    @State private var listener = Listener()
    @State private var sharedLinks = SharedLinks()
    /// The pages open over the shelf, so a tapped notification can open its own.
    @State private var path = NavigationPath()
    private let notifications = Notifications.shared
    @FocusState private var focused: Bool
    @MainActor private static var startedAutomatically = false

    private let palette = Palette.dream

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // One button for everything that isn't making a page, so the name stands alone.
                    HStack(spacing: 12) {
                        Text("Dream")
                            .font(.display(.largeTitle, weight: .bold))
                        Spacer(minLength: 0)
                        AccountButton(palette: palette)
                    }
                    .padding(.top, 24)
                    // The key goes in Under the hood, which only testing builds have.
                    if !canCompose, Build.hasTestingHooks {
                        Button { showingSettings = true } label: {
                            Label("Add an xAI API key to start making screens.", systemImage: "key.fill")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .panel(palette)
                    }
                    if !surfaces.isEmpty || !forming.isEmpty {
                        shelf
                    }
                    ideaList
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(alignment: .top) {
                Aura(palette: palette, energy: 0)
                    .frame(height: 620)
            }
            .background(Color(.systemBackground))
            .background { EdgeSwipeBack() }
            .safeAreaInset(edge: .bottom) { composer }
            .toolbar(.hidden, for: .navigationBar)
            // A plain push, not a zoom out of the tile: going back from a zoom lets a drag carry the
            // whole page off in any direction, and pages are full of things a finger drags sideways.
            .navigationDestination(item: $request) { SurfaceScreen(request: $0) }
            .navigationDestination(for: SavedSurface.self) { SurfaceScreen(saved: $0) }
            .navigationDestination(for: FormingPage.self) { SurfaceScreen(forming: $0) }
            // Shared with the user, from a link (SharedLinks.swift).
            .navigationDestination(item: $sharedLinks.opened) { SurfaceScreen(saved: $0) }
        }
        .receivingSharedScreens(sharedLinks)
        .onChange(of: notifications.opened, initial: true) { _, opened in open(opened) }
        .sheet(isPresented: $showingSettings, onDismiss: { canCompose = Composer.canCompose }) {
            DebugView(surface: nil, values: [:], log: [], modelName: "")
        }
        .onChange(of: photoItem) { _, item in
            Task { await loadPhoto(item) }
        }
        .task {
            startFromLaunchArgument()
            await ideas.load()
        }
    }

    // MARK: - Ideas

    /// Things to try, written for this moment. With nothing made yet, they're the whole screen.
    private var ideaList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ideas.items, id: \.self) { idea in
                Button {
                    make(idea)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(idea)
                            .font(.display(.title3, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(palette.accent)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.blurReplace)
            }
            if ideas.items.isEmpty {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(palette.wash)
                        .frame(width: [260, 210, 240, 190][index], height: 18)
                        .padding(.vertical, 17)
                }
                .shimmering()
            }
        }
        .animation(.smooth(duration: 0.6), value: ideas.items)
    }

    // MARK: - Shelf

    /// Started pages that aren't saved yet. One that came by sync before its record went is
    /// shown once, as the page. A change shows on its page's own screen, never as a tile.
    private var forming: [StartedPage] {
        let saved = Set(surfaces.map(\.id))
        return started.filter { $0.changeData == nil && !saved.contains($0.pageID) }
    }

    private var shelf: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(forming) { started in
                // As values: the record goes the moment the page is saved, and the tile can be
                // drawn once more before the shelf hears.
                let page = FormingPage(started)
                let failure = started.failure
                NavigationLink(value: page) {
                    FormingTile(page: page, failure: failure)
                }
                .buttonStyle(.plain)
                .transition(.blurReplace)
                .contextMenu {
                    // Nothing on the server stops a page part way, so only one that failed can go.
                    if failure != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            ServerPages.shared.discard(page.job.page)
                        }
                    }
                }
            }
            ForEach(surfaces) { saved in
                NavigationLink(value: saved) {
                    SurfaceTile(saved: saved)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        RecordStore.deleteAll(of: saved.id, in: context)
                        context.delete(saved)
                    }
                }
            }
        }
    }

    // MARK: - Asking

    private var composer: some View {
        let options = ModelOptions.offered
        return VStack(spacing: 10) {
            SavedSuggestion(text: intent, surfaces: surfaces)
            // What will make the page, for accounts that can choose (ModelPicker.swift).
            if let options {
                ModelChip(options: options, palette: palette, focus: $focused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(alignment: .topTrailing) {
                            Button("Remove photo", systemImage: "xmark.circle.fill") {
                                self.photo = nil
                                photoItem = nil
                            }
                            .labelStyle(.iconOnly)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .offset(x: 6, y: -6)
                        }
                        .padding(.leading, 8)
                        .transition(.scale.combined(with: .opacity))
                }
                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "camera")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel("Ask about a photo")
                    TextField("Ask, or work something out", text: $intent)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { make(intent) }
                        .onChange(of: focused) { if focused, listener.isActive { listener.cancel() } }
                    if intent.isEmpty || listener.isActive {
                        MicButton(listener: listener, text: $intent, palette: palette, onStart: { focused = false }) { make($0) }
                    }
                    if canMake && !listener.isActive {
                        Button("Make", systemImage: "arrow.up") { make(intent) }
                            .labelStyle(.iconOnly)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 38, height: 38)
                            .background(palette.accent, in: .circle)
                    }
                }
            }
            .padding(6)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            .listeningGlow(listener, palette: palette, in: .rect(cornerRadius: 26))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .animation(.smooth, value: photo)
        .animation(.smooth, value: focused)
        .animation(.smooth, value: listener.isActive)
        .animation(.smooth, value: options)
    }

    private var canMake: Bool {
        !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil
    }

    private func make(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil else { return }
        // Pages are made through Dream's server, so they need an account (Account.swift).
        guard Account.shared.mayMake else {
            focused = false
            Account.shared.askToSignIn("Sign in to make pages") { make(text) }
            return
        }
        request = ComposeRequest(intent: text.isEmpty ? "What is this?" : text, image: photo?.cgImage)
        intent = ""
        photo = nil
        photoItem = nil
        focused = false
    }

    /// A tapped notification (Notifications.swift): its page, finished or still being made, alone
    /// over the shelf; or the shelf, when neither is here. Back to the shelf first, and the page
    /// once that's settled: replacing a page opened another way (a request, a shared link, a
    /// topic explored from a page) in the same moment left a blank screen with a back button.
    private func open(_ opened: Notifications.Opened?) {
        guard let opened else { return }
        notifications.opened = nil
        let wasOpen = request != nil || sharedLinks.opened != nil || !path.isEmpty
        request = nil
        sharedLinks.opened = nil
        path = NavigationPath()
        let next: NavigationPath
        switch opened.destination {
        case .page(let saved): next = NavigationPath([saved])
        case .forming(let page): next = NavigationPath([page])
        case .shelf: return
        }
        Task { @MainActor in
            if wasOpen { try? await Task.sleep(for: .milliseconds(450)) }
            path = next
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        photo = image.downscaled(toFit: 1024)
    }

    /// For testing on a device: launch with `-DreamAutoIntent "split a bill"`. `-DreamXAIKey`
    /// moves an xAI key into this device's Keychain and switches to Grok; `-DreamWebKey` does
    /// the same for the key the web search server expects. Release builds ignore all three.
    private func startFromLaunchArgument() {
        if let key = Build.argument("DreamXAIKey") {
            Keychain.save(key, for: "xai")
            UserDefaults.standard.set(Composer.Provider.xai.rawValue, forKey: "provider")
        }
        if let key = Build.argument("DreamWebKey") {
            Keychain.save(key, for: "web")
        }
        // `-DreamOpenPage <page id>`: as if its "ready" notification were tapped; with
        // `-DreamOpenAfter <seconds>`, tapped that long after the request below has opened its page.
        if let page = Build.argument("DreamOpenPage").flatMap(UUID.init(uuidString:)) {
            let after = Build.argument("DreamOpenAfter").flatMap(Double.init) ?? 0
            Task {
                try? await Task.sleep(for: .seconds(after))
                await Notifications.shared.open(PushPayload(page: page, job: "testing", kind: .done))
            }
            if after == 0 { return }
        }
        guard !Self.startedAutomatically, let auto = Build.argument("DreamAutoIntent") else { return }
        Self.startedAutomatically = true
        request = ComposeRequest(intent: auto, image: nil)
    }
}

/// A saved surface on the shelf, glowing in its own colors. A calculation shows its live
/// answer; anything else, what it says.
struct SurfaceTile: View {
    let saved: SavedSurface
    /// The surface's entries, for totals worked out from its lists.
    @Query private var stored: [StoredRecord]

    init(saved: SavedSurface) {
        self.saved = saved
        let id = saved.id
        _stored = Query(filter: #Predicate<StoredRecord> { $0.surfaceID == id })
    }

    var body: some View {
        let surface = saved.surface
        let palette = surface.palette
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: surface.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.accent)
            Spacer(minLength: 20)
            Text(surface.title)
                .font(.display(.subheadline))
                .lineLimit(2)
            if let main = surface.outputs.first {
                Text(surface.display(main.name, surface.evaluate(saved.values, records: StoredRecord.grouped(stored)).values[main.name]))
                    .font(.display(.title3))
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(surface.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if saved.sharedFrom != nil {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .accessibilityLabel("Shared with you")
            }
        }
        .background {
            ZStack(alignment: .topTrailing) {
                palette.wash
                Circle()
                    .fill(palette.accent)
                    .frame(width: 150, height: 150)
                    .blur(radius: 44)
                    .opacity(0.5)
                    .offset(x: 50, y: -60)
            }
        }
        .clipShape(.rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(palette.edge, lineWidth: 0.5))
        .contentShape(.rect(cornerRadius: 26))
    }
}

/// A page still being made on Dream's server, on the shelf. Nothing stands in for the page:
/// Dream's light moves through the tile while Dream works and holds still while a question waits
/// for the user, and it turns to the page's colors once the page knows its subject, with its
/// title as it's written, or the request until there is one.
struct FormingTile: View {
    let started: FormingPage
    /// Why the server couldn't make it, once it couldn't.
    let failed: String?
    private let pages = ServerPages.shared

    init(page: FormingPage, failure: String?) {
        started = page
        failed = failure
    }

    var body: some View {
        let composer = pages.following[started.job.page]
        let page = composer?.surface.flatMap { $0.title.isEmpty ? nil : $0 }
        let failure = failed ?? composer.flatMap(Self.failure)
        // A question, or a connected service's tool to allow.
        let waiting = composer.map { $0.asking.isWaiting || $0.consent.isWaiting } ?? false
        let palette = page?.palette ?? .dream
        VStack(alignment: .leading, spacing: 6) {
            if failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if let page {
                Image(systemName: page.symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .transition(.blurReplace)
            }
            Spacer(minLength: 20)
            Text(page?.title ?? started.intent)
                .font(.display(.subheadline))
                .lineLimit(3)
                .contentTransition(.opacity)
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background {
            ZStack {
                palette.wash
                // Moving while it's Dream's turn, still while it's the user's; each step of the
                // work and each block landing surges it, as on the page's own screen.
                Aura(palette: palette, energy: failure != nil ? 0 : waiting ? 0.04 : 0.8, flood: failure != nil ? 0 : 1,
                     pulse: (composer?.trail.count ?? 0) + (composer?.surface?.blocks.count ?? 0))
                    .animation(.easeInOut(duration: 1.4), value: waiting)
                    .animation(.easeInOut(duration: 1.2), value: failure != nil)
            }
        }
        .clipShape(.rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(palette.edge, lineWidth: 0.5))
        .contentShape(.rect(cornerRadius: 26))
        .animation(.smooth(duration: 0.6), value: page?.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failure.map { "\(started.intent). Couldn't make this page: \($0)" }
            ?? (waiting ? "\(page?.title ?? started.intent). Dream has a question" : "Making a page for: \(started.intent)"))
    }

    private static func failure(_ composer: Composer) -> String? {
        if case .failed(let message) = composer.phase { return message }
        return nil
    }
}

/// Back is the swipe from the screen's edge, or the back button; a swipe from anywhere on the
/// page is the page's own. A page is full of things a finger drags sideways (sliders, charts,
/// an entry swiped away, a scene turned), and a swipe from anywhere took the page with them.
private struct EdgeSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Finder { Finder() }
    func updateUIViewController(_ controller: Finder, context: Context) {}

    final class Finder: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }
    }
}

extension UIImage {
    /// Redrawn upright and smaller: the model doesn't need full resolution, and `cgImage` drops orientation.
    func downscaled(toFit side: CGFloat) -> UIImage {
        let scale = Swift.min(1, side / Swift.max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
