import PhotosUI
import SwiftData
import SwiftUI

/// Where everything starts. Ask at the bottom, or tap an idea; what you've made glows above,
/// each in its own colors. Every surface opens out of what you touched.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedSurface.updatedAt, order: .reverse) private var surfaces: [SavedSurface]
    @State private var intent = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var request: ComposeRequest?
    @State private var ideas = Ideas()
    @State private var canCompose = Composer.canCompose
    @State private var showingSettings = false
    @FocusState private var focused: Bool
    @Namespace private var zoom
    @MainActor private static var startedAutomatically = false

    private let palette = Palette.now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Dream")
                        .font(.display(.largeTitle, weight: .bold))
                        .padding(.top, 24)
                    if !canCompose {
                        Button { showingSettings = true } label: {
                            Label("Add an xAI API key to start making screens.", systemImage: "key.fill")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .panel(palette)
                    }
                    if !surfaces.isEmpty {
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
            .safeAreaInset(edge: .bottom) { composer }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $request) { request in
                SurfaceScreen(request: request)
                    .navigationTransition(.zoom(sourceID: "composer", in: zoom))
            }
            .navigationDestination(for: SavedSurface.self) { saved in
                SurfaceScreen(saved: saved)
                    .navigationTransition(.zoom(sourceID: saved.id, in: zoom))
            }
        }
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
                            .foregroundStyle(palette.gradient)
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

    private var shelf: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(surfaces) { saved in
                NavigationLink(value: saved) {
                    SurfaceTile(saved: saved)
                        .matchedTransitionSource(id: saved.id, in: zoom)
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
        VStack(spacing: 10) {
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
                    Button("Make", systemImage: "arrow.up") { make(intent) }
                        .labelStyle(.iconOnly)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(palette.gradient, in: .circle)
                        .disabled(!canMake)
                        .opacity(canMake ? 1 : 0.4)
                }
            }
            .padding(6)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            .matchedTransitionSource(id: "composer", in: zoom)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .animation(.smooth, value: photo)
        .animation(.smooth, value: focused)
    }

    private var canMake: Bool {
        !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil
    }

    private func make(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil else { return }
        request = ComposeRequest(intent: text.isEmpty ? "What is this?" : text, image: photo?.cgImage)
        intent = ""
        photo = nil
        photoItem = nil
        focused = false
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        photo = image.downscaled(toFit: 1024)
    }

    /// For testing on a device: launch with `-DreamAutoIntent "split a bill"`. `-DreamXAIKey`
    /// moves an xAI key into this device's Keychain and switches to Grok.
    private func startFromLaunchArgument() {
        if let key = UserDefaults.standard.string(forKey: "DreamXAIKey"), !key.isEmpty {
            Keychain.save(key, for: "xai")
            UserDefaults.standard.set(Composer.Provider.xai.rawValue, forKey: "provider")
        }
        guard !Self.startedAutomatically, let auto = UserDefaults.standard.string(forKey: "DreamAutoIntent"), !auto.isEmpty else { return }
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
                .foregroundStyle(palette.gradient)
            Spacer(minLength: 20)
            Text(surface.title)
                .font(.display(.subheadline))
                .lineLimit(2)
            if let main = surface.outputs.first {
                Text(surface.display(main.name, surface.evaluate(saved.values, records: StoredRecord.grouped(stored)).values[main.name]))
                    .font(.display(.title3))
                    .monospacedDigit()
                    .foregroundStyle(palette.numberGradient)
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
        .background {
            ZStack(alignment: .topTrailing) {
                palette.wash
                Circle()
                    .fill(palette.gradient)
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
