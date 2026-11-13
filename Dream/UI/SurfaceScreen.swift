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
    /// The page being made for the request, by PageMaker, so it goes on if this screen is left.
    @State private var making: PageMaker.Making?
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
    @State private var voice = PageVoice()
    @FocusState private var instructionFocused: Bool

    init(request: ComposeRequest) {
        self.request = request
        _saved = State(initialValue: nil)
    }

    init(saved: SavedSurface) {
        request = nil
        _saved = State(initialValue: saved)
    }

    /// A page still being made, opened from the shelf.
    init(making: PageMaker.Making) {
        request = nil
        _making = State(initialValue: making)
        _saved = State(initialValue: nil)
    }

    private var surface: Surface? { composer.surface ?? saved?.surface }
    private var intent: String { saved?.intent ?? request?.intent ?? making?.intent ?? "" }

    private var photo: UIImage? {
        if let image = request?.image { return UIImage(cgImage: image) }
        return (saved?.photoData ?? making?.photoData).flatMap { UIImage(data: $0) }
    }

    private var hasFailed: Bool {
        if case .failed = composer.phase { return true }
        return false
    }

    /// Dream's own until the page arrives; then the page's, from its subject.
    private var palette: Palette {
        guard let surface, !surface.isEmpty else { return .dream }
        return surface.palette
    }

    /// No page to show yet, or questions to answer before there is one.
    private var isForming: Bool {
        guard let surface, !surface.isEmpty else { return true }
        return yourTurn
    }

    /// The model is waiting on the user: questions, or a connected service's tool to allow.
    private var yourTurn: Bool { composer.asking.isWaiting || composer.consent.isWaiting }

    /// Dream is on it: making or changing the page, or about to start on a new request.
    private var isWorking: Bool {
        composer.phase.isBusy || (composer.phase == .idle && saved == nil && (request != nil || making != nil))
    }

    /// Where the request is, which the light shows in its colors (StageLight.swift). A saved
    /// page at rest is done; one starting up is still being understood.
    private var stage: Stage {
        if !isWorking { return hasFailed ? .failed : .done }
        if composer.phase == .idle { return .understanding }
        return composer.stage
    }

    /// The light fills the screen while there's no page, from the first frame; behind a page
    /// still being written it stays over most of the screen, and it pulls up to the top when the
    /// page is done.
    private var flood: Double {
        guard isWorking else { return 0 }
        return isForming ? 1 : 0.6
    }

    /// Blocks shown, so each one landing surges the light.
    private var blockCount: Int { surface?.displayBlocks.count ?? 0 }

    /// The main result, so the field behind it can respond when it changes.
    private var mainValue: Double? {
        guard let surface, let main = surface.outputs.first else { return nil }
        return surface.evaluate(state.values, records: state.records).values[main.name]
    }

    /// The page, or the request while it forms, over the light.
    private var page: some View {
        let busy = composer.phase.isBusy
        return ScrollView {
            // A service the request names, which the user could connect.
            ConnectSuggestions(entries: composer.suggestions, palette: palette) { Task { await runAgain() } }
                .padding(.horizontal, 20)
            // Questions waiting on the user always show, even over a page that's begun.
            if let surface, !surface.isEmpty, !composer.asking.isWaiting, !composer.consent.isWaiting {
                SurfaceView(
                    surface: surface,
                    state: state,
                    photo: photo,
                    focusedID: changing?.block?.id ?? changingID,
                    readingID: voice.readingID,
                    onChange: busy ? nil : { beginChange(ChangeTarget(block: $0)) },
                    onExplore: busy ? nil : { exploring = ComposeRequest(intent: $0, image: nil) },
                    onAnswer: busy ? nil : { changeAnswer($0, to: $1) },
                    isStreaming: composer.isStreaming)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                    .transition(.blurReplace)
            } else {
                FormingView(intent: intent, palette: palette, asking: composer.asking, consent: composer.consent)
                    .padding(.horizontal, 20)
                    .transition(.blurReplace)
            }
        }
        .background {
            // The light, in the colors of the stage the request is at; the page's own once it's done.
            StageLight(stage: stage, palette: surface.flatMap { $0.isEmpty ? nil : $0.palette }, flood: flood, pulse: pulse)
        }
        .background(Color(.systemBackground))
        // What the work is touching while there's no page yet, and the stage it's at.
        .overlay(alignment: .bottom) {
            if busy, !yourTurn {
                VStack(alignment: .leading, spacing: 10) {
                    if isForming { WorkGlimpses(trail: composer.trail) }
                    StageSteps(stage: stage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.6), value: isForming)
        // Each step of the work, and each block as it lands, surges the light; so does the main
        // result changing once the page is done.
        .onChange(of: composer.trail.count) { pulse += 1 }
        .onChange(of: blockCount) { if busy { pulse += 1 } }
        .onChange(of: mainValue) { if !busy { pulse += 1 } }
    }

    var body: some View {
        let busy = composer.phase.isBusy
        page
        .refreshingLive(surface, state: state)
        .scrollPosition($scroll)
        // Blocks stream in above ones already shown, and the scroll view follows those down.
        // Hold the top while the surface forms, until the user scrolls themselves.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                userScrolled = true
                voice.userScrolled()
            }
        }
        .followsReading(voice, surface: surface, scroll: $scroll)
        .onChange(of: composer.surface) {
            if !userScrolled { scroll.scrollTo(edge: .top) }
        }
        .onChange(of: composer.phase) {
            if !composer.phase.isBusy { changingID = nil }
            guard composer.phase == .done else { return }
            // The last blocks can land after the final surface update; settle at the top.
            if !userScrolled { scroll.scrollTo(edge: .top) }
            Task { await tour() }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top) { failure }
        .safeAreaInset(edge: .bottom) { changeBar }
        .safeAreaInset(edge: .bottom) { VoiceBar(voice: voice, palette: palette) }
        .safeAreaInset(edge: .bottom) { if changing == nil, !busy { NoticedFacts(request: intent, palette: palette) } }
        .onChange(of: composer.phase.isBusy) { if composer.phase.isBusy { voice.stop() } }
        .onDisappear { voice.stop() }
        .animation(.smooth, value: composer.phase)
        .animation(.smooth, value: changing)
        .sensoryFeedback(trigger: composer.phase) { _, new in new == .done ? .success : nil }
        .navigationBarTitleDisplayMode(.inline)
        // Home hides its bar; said outright here, so a back swipe let go halfway can't leave the
        // page without its own.
        .toolbarVisibility(.visible, for: .navigationBar)
        .navigationDestination(item: $exploring) { SurfaceScreen(request: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ReadAloudButton(voice: voice, surface: surface, state: state)
                    .disabled(busy || surface == nil)
                Button("Change", systemImage: "wand.and.stars") { beginChange(ChangeTarget()) }
                    .disabled(busy || surface == nil)
                ShareButton(surface: surface, values: state.values, page: saved?.id)
                    .disabled(busy || surface == nil)
                // Someone else's page: report it, or stop seeing pages from them (SharedPageMenu.swift).
                if let saved, saved.sharedFrom != nil { SharedPageMenu(saved: saved) }
                if Build.hasTestingHooks {
                    Button("Under the hood", systemImage: "ladybug") { showingDebug = true }
                }
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
        // A new page goes on being made on the shelf, and its questions wait for the user to
        // come back to them. A change to a saved page stops with its screen, and never leaves the
        // model waiting on questions nobody can see.
        .onChange(of: madePage?.id) { adopt(madePage) }
        .onDisappear {
            guard saved != nil || making == nil else { return }
            composer.asking.cancel()
            composer.consent.cancel()
        }
        .onChange(of: state.values) { _, values in
            saved?.values = values
        }
        .countingControlUses(state.values, of: surface, settled: !busy)
        .keepingRecords(of: saved?.id, collections: surface?.recordCollections ?? [], in: state)
    }

    /// For checking whole pages on a device: launched with `-DreamTour 1`, a finished page
    /// scrolls down most of a screen at a time, slowly enough to take screenshots.
    private func tour() async {
        guard Build.flag("DreamTour") else { return }
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
            instructionField(for: target)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func instructionField(for target: ChangeTarget) -> some View {
        HStack(spacing: 8) {
            TextField(placeholderText(for: target), text: $instruction)
                .focused($instructionFocused)
                .submitLabel(.go)
                .onSubmit(submitChange)
                .onAppear { instructionFocused = true }
                .onChange(of: instructionFocused) { if instructionFocused, voice.listener.isActive { voice.listener.cancel() } }
            if instruction.isEmpty || voice.listener.isActive {
                MicButton(listener: voice.listener, text: $instruction, palette: palette, onStart: { instructionFocused = false }) { _ in submitChange() }
            } else {
                Button("Send", systemImage: "arrow.up", action: submitChange)
                    .labelStyle(.iconOnly)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 38, height: 38)
                    .background(palette.accent, in: .circle)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
        .listeningGlow(voice.listener, palette: palette, in: .capsule)
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
            // Live values may have arrived first, and are newer than the saved ones.
            state.values = saved.values.merging(state.values) { _, current in current }
            saved.openCount += 1
            saved.lastOpenedAt = .now
            return
        }
        if let making {
            // Made while the screen was away, or still being made: carry on with it.
            if let made = madePage { adopt(made); return }
            if hasFailed {
                PageMaker.shared.retry(making)
            }
            if let current = PageMaker.shared.composer(for: making), current !== composer { composer = current }
            return
        }
        guard let request else { return }
        let page = PageMaker.shared.begin(intent: request.intent, image: request.image)
        making = page
        if let current = PageMaker.shared.composer(for: page) { composer = current }
    }

    /// The page PageMaker saved for this screen's request, once it has.
    private var madePage: SavedSurface? { making.flatMap { PageMaker.shared.made[$0.id] } }

    /// Carries on with the saved page, keeping the numbers the user changed while it was written.
    private func adopt(_ made: SavedSurface?) {
        guard let made, saved == nil else { return }
        if !state.values.isEmpty { made.values = made.values.merging(state.values) { _, current in current } }
        saved = made
        saved?.lastOpenedAt = .now
        saved?.openCount += 1
    }

    /// After connecting a service the request named, the request runs again, now able to read
    /// it.
    private func runAgain() async {
        await composer.compose(intent: intent, image: request?.image ?? photo?.cgImage)
        guard composer.phase == .done, let surface = composer.surface, let saved else { return }
        saved.surface = surface
        saved.generationLog.append(contentsOf: composer.log)
        saved.modelName = composer.modelName
        saved.note(.rebuilt, intent, answers: surface.answers ?? [])
        try? context.save()
    }

    private func beginChange(_ target: ChangeTarget) {
        voice.stop()
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
            // On a list, "add milk" or "mark the first two done" changes the user's entries, not the screen.
            if await RecordTalk.handle(text, on: current, focus: target.block, state: state) {
                changingID = nil
                saved?.note(.listed, text)
                return
            }
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
                saved.note(.changed, text)
                saved.generationLog.append(contentsOf: composer.log)
                saved.modelName = composer.modelName
                try? context.save()
            }
        }
    }

    /// A different answer to one of the questions asked before building, from its tag in the header.
    private func changeAnswer(_ answer: Answer, to choice: String) {
        guard let current = surface else { return }
        Task {
            await composer.rebuild(current, intent: intent, changing: answer, to: choice)
            guard composer.phase == .done, let updated = composer.surface else { return }
            state.values = state.values.filter { name, _ in
                guard let before = current.input(name), let after = updated.input(name) else { return false }
                return before.initial == after.initial
            }
            Memory.remember((updated.answers ?? []).filter { $0.question == answer.question }, from: intent, in: context)
            if let saved {
                saved.surface = updated
                saved.editRequests.append(Prompts.changedAnswer(answer, to: choice))
                saved.note(.answered, choice, answers: (updated.answers ?? []).filter { $0.question == answer.question })
                saved.generationLog.append(contentsOf: composer.log)
                saved.modelName = composer.modelName
                try? context.save()
            }
        }
    }
}
