import SwiftData
import SwiftUI

struct ComposeRequest: Hashable, Identifiable {
    let id = UUID()
    let intent: String
    let image: CGImage?

    static func == (a: ComposeRequest, b: ComposeRequest) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What the user is about to change: one block they long-pressed, or the whole surface.
struct ChangeTarget: Equatable {
    var block: Block?
}

/// One surface, either being made from a request or opened from the shelf.
struct SurfaceScreen: View {
    @Environment(\.modelContext) private var context
    private let request: ComposeRequest?
    @State private var saved: SavedSurface?
    @State private var composer = Composer()
    @State private var state = SurfaceState()
    @State private var changing: ChangeTarget?
    @State private var changingID: String?
    @State private var instruction = ""
    @State private var exploring: ComposeRequest?
    @State private var showingDebug = false
    @State private var pulse = 0
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var userScrolled = false
    @FocusState private var instructionFocused: Bool

    init(request: ComposeRequest) {
        self.request = request
        _saved = State(initialValue: nil)
    }

    init(saved: SavedSurface) {
        request = nil
        _saved = State(initialValue: saved)
    }

    private var surface: Surface? { composer.surface ?? saved?.surface }
    private var intent: String { saved?.intent ?? request?.intent ?? "" }

    private var photo: UIImage? {
        if let image = request?.image { return UIImage(cgImage: image) }
        return saved?.photoData.flatMap { UIImage(data: $0) }
    }

    private var hasFailed: Bool {
        if case .failed = composer.phase { return true }
        return false
    }

    /// Before the model has picked colors, the time of day's.
    private var palette: Palette {
        guard let surface, !surface.isEmpty else { return .now }
        return surface.palette
    }

    /// What the model is doing, as a symbol. Nil when it's not working.
    private var stage: String? {
        switch composer.phase {
        case .planning: "sparkles"
        case .researching: "book.pages"
        case .calculating: "function"
        case .fixing: "wrench.adjustable"
        case .composing: "rectangle.3.group"
        case .idle, .done, .failed: nil
        }
    }

    /// How lively the color field is: thinking spreads and swirls it, writing calms it, done settles it.
    private var energy: Double {
        guard composer.phase.isBusy else { return 0 }
        return composer.isThinking ? 1 : 0.45
    }

    /// The main result, so the field behind it can respond when it changes.
    private var mainValue: Double? {
        guard let surface, let main = surface.outputs.first else { return nil }
        return surface.evaluate(state.values).values[main.name]
    }

    var body: some View {
        let busy = composer.phase.isBusy
        ScrollView {
            if let surface, !surface.isEmpty {
                SurfaceView(
                    surface: surface,
                    state: state,
                    photo: photo,
                    stage: stage,
                    focusedID: changing?.block?.id ?? changingID,
                    onChange: busy ? nil : { beginChange(ChangeTarget(block: $0)) },
                    onExplore: busy ? nil : { exploring = ComposeRequest(intent: $0, image: nil) })
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            } else {
                FormingView(intent: intent, stage: stage, palette: palette)
                    .padding(.horizontal, 20)
            }
        }
        .background(alignment: .top) {
            Aura(palette: palette, energy: energy, pulse: pulse)
                .frame(height: 720)
                .animation(.easeInOut(duration: 1.4), value: energy)
        }
        .background(Color(.systemBackground))
        .scrollPosition($scroll)
        // Blocks stream in above ones already shown, and the scroll view follows those down.
        // Hold the top while the surface forms, until the user scrolls themselves.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { userScrolled = true }
        }
        .onChange(of: composer.surface) {
            if !userScrolled { scroll.scrollTo(edge: .top) }
        }
        .onChange(of: composer.phase) {
            guard composer.phase == .done else { return }
            // The last blocks can land after the final surface update; settle at the top.
            if !userScrolled { scroll.scrollTo(edge: .top) }
            Task { await tour() }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { failure }
        .safeAreaInset(edge: .bottom) { changeBar }
        .animation(.smooth, value: composer.phase)
        .animation(.smooth, value: changing)
        .sensoryFeedback(trigger: composer.phase) { _, new in new == .done ? .success : nil }
        .onChange(of: mainValue) { if !busy { pulse += 1 } }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $exploring) { SurfaceScreen(request: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Change", systemImage: "wand.and.stars") { beginChange(ChangeTarget()) }
                    .disabled(busy || surface == nil)
                Button("Under the hood", systemImage: "ladybug") { showingDebug = true }
            }
        }
        .sheet(isPresented: $showingDebug) {
            DebugView(
                surface: surface,
                values: state.values,
                log: composer.log.isEmpty ? (saved?.generationLog ?? []) : composer.log,
                modelName: composer.modelName.isEmpty ? (saved?.modelName ?? "") : composer.modelName)
        }
        .task { await start() }
        .onChange(of: state.values) { _, values in saved?.values = values }
    }

    /// For checking whole pages on a device: launched with `-DreamTour 1`, a finished page
    /// scrolls down most of a screen at a time, slowly enough to take screenshots.
    private func tour() async {
        guard UserDefaults.standard.bool(forKey: "DreamTour") else { return }
        for step in 1...8 {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.smooth(duration: 0.8)) { scroll.scrollTo(y: CGFloat(step) * 560) }
        }
    }

    /// Failures are the one state that needs words: what went wrong, and a way to retry.
    @ViewBuilder private var failure: some View {
        if case .failed(let message) = composer.phase {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.subheadline)
                if saved == nil {
                    Spacer(minLength: 0)
                    Button("Try again") { Task { await start() } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var changeBar: some View {
        if let target = changing {
            HStack(spacing: 8) {
                TextField(placeholderText(for: target), text: $instruction)
                    .focused($instructionFocused)
                    .submitLabel(.go)
                    .onSubmit(submitChange)
                    .onAppear { instructionFocused = true }
                Button("Send", systemImage: "arrow.up", action: submitChange)
                    .labelStyle(.iconOnly)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(palette.gradient, in: .circle)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", systemImage: "xmark") { changing = nil }
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func placeholderText(for target: ChangeTarget) -> String {
        guard let block = target.block else { return "Change this…" }
        if !block.ref.isEmpty, let surface { return "Change \(surface.label(of: block.ref).lowercased())…" }
        if !block.title.isEmpty { return "Change \(block.title.lowercased())…" }
        return "Change this \(block.kind.rawValue)…"
    }

    // MARK: - Actions

    private func start() async {
        if let saved {
            if state.values.isEmpty { state.values = saved.values }
            saved.openCount += 1
            saved.lastOpenedAt = .now
            return
        }
        guard let request, composer.phase == .idle || hasFailed else { return }
        await composer.compose(intent: request.intent, image: request.image)
        guard composer.phase == .done, let surface = composer.surface else { return }
        let saved = SavedSurface(intent: request.intent, surface: surface, modelName: composer.modelName, log: composer.log)
        saved.values = state.values
        saved.photoData = request.image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) }
        context.insert(saved)
        try? context.save()
        self.saved = saved
    }

    private func beginChange(_ target: ChangeTarget) {
        instruction = ""
        changing = target
    }

    private func submitChange() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target = changing, let current = surface else { return }
        changing = nil
        changingID = target.block?.id
        instruction = ""
        instructionFocused = false
        Task {
            await composer.edit(current, intent: intent, instruction: text, focus: target.block)
            changingID = nil
            guard composer.phase == .done, let updated = composer.surface else { return }
            // Keep the user's numbers, unless the change was about that number.
            state.values = state.values.filter { name, _ in
                guard let before = current.input(name), let after = updated.input(name) else { return false }
                return before.initial == after.initial
            }
            if let saved {
                saved.surface = updated
                saved.editRequests.append(text)
                saved.generationLog.append(contentsOf: composer.log)
                saved.modelName = composer.modelName
                try? context.save()
            }
        }
    }
}
