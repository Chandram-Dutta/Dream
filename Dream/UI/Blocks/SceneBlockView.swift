import RealityKit
import SwiftUI

/// A scene in three dimensions, drawn by RealityKit in the surface's colours and moving as the
/// numbers change. The geometry is the engine's (`Scene3D`, `SceneDrawing`, `SceneCamera`); this
/// only shows it and lets the reader look round it.
///
/// Inside a scrolling page, a sideways drag turns the scene (and can then tilt it), an up or down
/// drag scrolls the page, a pinch zooms and a double tap puts it back (`OrbitGesture`). The view
/// fits the scene as it is, like a figure: it widens while the scene grows, and eases to the new
/// fit once the numbers settle. Off screen, RealityKit's view is taken away, so nothing renders
/// that no one sees.
struct SceneBlockView: View {
    let block: Block
    let context: RenderContext

    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How the reader has turned it. Nil until they do, and after they put it back.
    @State private var camera: SceneCamera?
    /// Where a turn or a pinch started.
    @State private var turning: SceneCamera?
    @State private var pinching: SceneCamera?
    /// What the view shows while the numbers change. Nil fits the scene as it is.
    @State private var shown: Box3?
    @State private var settle: Task<Void, Never>?
    @State private var isVisible = false
    @State private var player: Task<Void, Never>?
    @State private var resetting: Task<Void, Never>?

    /// How long play takes to sweep its time across the whole range.
    private static let sweep: TimeInterval = 12

    var body: some View {
        if let scene = context.surface.scene(block.ref) {
            sceneView(scene)
        }
    }

    private func sceneView(_ scene: Scene3D) -> some View {
        let surface = context.surface
        let frame = scene.frame(in: surface)
        let drawing = scene.drawing(in: surface, values: context.evaluation.values, zScale: frame.zScale)
        let extent = shown ?? drawing.bounds ?? frame.bounds
        let looking = camera ?? .standard(for: frame)
        let colors = sceneColors
        let waiting = scene.molecule.map { $0.structure == nil } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            header
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(1 / SceneProjection.aspect(of: frame), contentMode: .fit)
                .overlay {
                    SceneFit(extent: extent) { extent in
                        GeometryReader { geometry in
                            let projection = SceneProjection(frame: frame, camera: looking, width: geometry.size.width, height: geometry.size.height, extent: extent)
                            ZStack {
                                if isVisible, !waiting {
                                    SceneRealityView(drawing: drawing, projection: projection, colors: colors)
                                        .allowsHitTesting(false)
                                        .transition(.opacity)
                                }
                                SceneLabels(drawing: drawing, projection: projection, context: context)
                            }
                        }
                    }
                }
                .overlay {
                    if waiting {
                        RoundedRectangle(cornerRadius: 18).fill(context.palette.wash).shimmering()
                    }
                }
                .clipShape(.rect(cornerRadius: 18))
                .contentShape(.rect)
                .gesture(OrbitGesture(
                    began: {
                        resetting?.cancel()
                        turning = camera ?? .standard(for: frame)
                    },
                    changed: { moved in
                        guard let turning else { return }
                        var turned = turning.turned(dx: moved.x, dy: moved.y)
                        turned.zoom = (camera ?? turning).zoom
                        camera = turned
                    },
                    ended: { turning = nil }))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { pinch in
                        resetting?.cancel()
                        let start = pinching ?? camera ?? .standard(for: frame)
                        if pinching == nil { pinching = start }
                        var zoomed = camera ?? start
                        zoomed.zoom = min(max(start.zoom * pinch.magnification, SceneCamera.zoomRange.lowerBound), SceneCamera.zoomRange.upperBound)
                        camera = zoomed
                    }
                    .onEnded { _ in pinching = nil })
                .onTapGesture(count: 2) { reset(to: frame) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(block.title.isEmpty ? "3D view" : block.title)
                .accessibilityValue(spoken(scene, drawing))
                .accessibilityAdjustableAction { direction in
                    var turned = camera ?? .standard(for: frame)
                    turned.yaw += (direction == .increment ? 1 : -1) * .pi / 6
                    camera = turned
                }
                .overlay(alignment: .bottomLeading) { playControl(scene) }
                .overlay(alignment: .topTrailing) { resetButton(frame) }
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    withAnimation(.easeOut(duration: 0.2)) { isVisible = visible }
                    if !visible { stop() }
                }
            footer(scene, colors: colors)
        }
        .onChange(of: context.state.values) { old, new in changed(scene, frame: frame, from: old, to: new) }
        .onDisappear {
            stop()
            settle?.cancel()
            resetting?.cancel()
        }
    }

    @ViewBuilder private var header: some View {
        if !block.title.isEmpty {
            RichText(text: block.title, context: context, style: .headline)
                .font(.display(.headline))
        }
    }

    /// The palette as RealityKit needs it, for the light or dark page it's on.
    private var sceneColors: SceneColors {
        func rgb(_ color: Color) -> SIMD3<Double> {
            let resolved = color.resolve(in: environment)
            return SIMD3(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
        }
        return SceneColors(accent: rgb(context.palette.accent), companion: rgb(context.palette.companion), isDark: environment.colorScheme == .dark)
    }

    // MARK: - Time

    /// Play and pause for the input the scene runs along, with where it's got to.
    @ViewBuilder private func playControl(_ scene: Scene3D) -> some View {
        if let time = context.surface.input(scene.time) {
            let playing = player != nil
            HStack(spacing: 10) {
                Button {
                    if playing { stop() } else { play(time) }
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(context.palette.onAccent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                        .background(context.palette.accent, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause \(time.label.lowercased())" : "Play \(time.label.lowercased())")
                VStack(alignment: .leading, spacing: 0) {
                    Text(time.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(context.surface.display(time.name, context.value(time.name)))
                        .font(.display(.subheadline))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.leading, 5)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: .capsule)
            .padding(10)
            .sensoryFeedback(.impact(weight: .light), trigger: playing)
        }
    }

    /// Sweeps the time from where it is to the end of its range, round and round, at a pace
    /// that takes the whole range in `sweep` seconds.
    private func play(_ time: Input) {
        stop()
        let range = time.safeRange
        let span = range.upperBound - range.lowerBound
        let state = context.state
        let from = (state.value(time) - range.lowerBound) / span
        let started = Date.now
        player = Task { @MainActor in
            while !Task.isCancelled {
                let fraction = (from + Date.now.timeIntervalSince(started) / Self.sweep).truncatingRemainder(dividingBy: 1)
                state.values[time.name] = range.lowerBound + fraction * span
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stop() {
        player?.cancel()
        player = nil
    }

    // MARK: - Fitting

    /// When the numbers change, the view widens if the scene has grown past it, and eases to the
    /// new fit once they settle. While it plays, it holds still.
    private func changed(_ scene: Scene3D, frame: SceneFrame, from old: [String: Double], to new: [String: Double]) {
        let surface = context.surface
        guard let was = shown ?? scene.extent(in: surface, given: old, zScale: frame.zScale),
              let now = scene.extent(in: surface, given: new, zScale: frame.zScale) else { return }
        shown = was.contains(now) ? was : was.union(now)
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, player == nil else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.7)) { shown = nil }
        }
    }

    // MARK: - Looking round

    @ViewBuilder private func resetButton(_ frame: SceneFrame) -> some View {
        if camera != nil {
            Button("Put back", systemImage: "arrow.counterclockwise") { reset(to: frame) }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(context.accent)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: .circle)
                .padding(10)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    /// Back to the view it started with, turning the short way round.
    private func reset(to frame: SceneFrame) {
        guard let from = camera else { return }
        let to = SceneCamera.standard(for: frame)
        resetting?.cancel()
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { camera = nil }
            return
        }
        var yaw = (to.yaw - from.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if yaw > .pi { yaw -= 2 * .pi } else if yaw < -.pi { yaw += 2 * .pi }
        let turn = yaw
        resetting = Task { @MainActor in
            let started = Date.now
            while !Task.isCancelled {
                let t = min(Date.now.timeIntervalSince(started) / 0.45, 1)
                let eased = 1 - pow(1 - t, 3)
                camera = SceneCamera(yaw: from.yaw + turn * eased, pitch: from.pitch + (to.pitch - from.pitch) * eased, zoom: from.zoom + (to.zoom - from.zoom) * eased)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { camera = nil }
        }
    }

    // MARK: - Molecules

    /// What the colours mean, and where the structure came from.
    @ViewBuilder private func footer(_ scene: Scene3D, colors: SceneColors) -> some View {
        if let structure = scene.molecule?.structure {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 14) {
                    ForEach(structure.elements, id: \.element.number) { entry in
                        let rgb = colors.element(entry.element.number)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: rgb.x, green: rgb.y, blue: rgb.z))
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                                .frame(width: 11, height: 11)
                            Text(entry.element.name)
                            Text("\(entry.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let page = URL(string: structure.pageURL) {
                    Link(destination: page) {
                        Text("3D structure: \(Text("PubChem").foregroundStyle(context.accent))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - VoiceOver

    /// What's there, in words: a molecule's atoms, or the labels with their live values.
    private func spoken(_ scene: Scene3D, _ drawing: SceneDrawing) -> String {
        if let structure = scene.molecule?.structure {
            let atoms = structure.elements.map { "\($0.count) \($0.element.name.lowercased())" }
            return "\(structure.title): \(ListFormatter.localizedString(byJoining: atoms)) atoms"
        }
        var seen: Set<String> = []
        return drawing.labels.compactMap { label -> String? in
            let text = Placeholders.parts(label.text).map { part in
                switch part {
                case .text(let text): text
                case .name(let name): context.surface.display(name, context.value(name))
                case .math(let tex): TeX.spoken(context.surface.filled(tex, values: context.evaluation.values))
                }
            }.joined()
            return seen.insert(text).inserted ? text : nil
        }.joined(separator: ", ")
    }
}

/// Eases from one extent to the next when it changes in an animation, so the scene glides to
/// its new fit rather than jumping.
private struct SceneFit<Content: View>: View, Animatable {
    var extent: Box3
    @ViewBuilder let content: (Box3) -> Content

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<Double, Double>, Double>, AnimatablePair<AnimatablePair<Double, Double>, Double>> {
        get {
            AnimatablePair(AnimatablePair(AnimatablePair(extent.min.x, extent.min.y), extent.min.z),
                           AnimatablePair(AnimatablePair(extent.max.x, extent.max.y), extent.max.z))
        }
        set {
            extent = Box3(min: Vec3(newValue.first.first.first, newValue.first.first.second, newValue.first.second),
                          max: Vec3(newValue.second.first.first, newValue.second.first.second, newValue.second.second))
        }
    }

    var body: some View { content(extent) }
}

/// RealityKit's view of a drawing. The stage keeps the entities, so a change of values moves
/// what's there rather than building it again.
private struct SceneRealityView: View {
    let drawing: SceneDrawing
    let projection: SceneProjection
    let colors: SceneColors
    @State private var stage = SceneStage()

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            for entity in stage.entities { content.add(entity) }
            stage.update(drawing, projection: projection, colors: colors)
        } update: { _ in
            stage.update(drawing, projection: projection, colors: colors)
        }
    }
}

/// The labels, drawn over the scene where the projection puts what they name, clear of each
/// other and of small things like planets. Labels on the far side are quieter. SwiftUI text, so
/// they can hold live values and maths, and stay sharp at any zoom.
private struct SceneLabels: View {
    let drawing: SceneDrawing
    let projection: SceneProjection
    let context: RenderContext

    var body: some View {
        Canvas { graphics, size in
            var found: [Int: (symbol: GraphicsContext.ResolvedSymbol, depth: Double)] = [:]
            var requests: [LabelPlacement.Request] = []
            for label in drawing.labels {
                guard let symbol = graphics.resolveSymbol(id: label.id), let (point, depth) = projection.project(label.anchor) else { continue }
                found[label.id] = (symbol, depth)
                requests.append(LabelPlacement.Request(id: label.id, anchor: point, size: Vec2(x: symbol.size.width, y: symbol.size.height),
                                                       direction: label.centered ? .zero : Vec2(x: 0.4, y: -1).normalized, gap: 4))
            }
            // Balls small enough to be covered by a label, like planets.
            let obstacles = drawing.solids.prefix(80).compactMap { solid -> Rect2? in
                guard solid.shape == .sphere, let point = projection.project(solid.center)?.point,
                      let radius = projection.onScreen(solid.scale.x, at: solid.center), radius < 30 else { return nil }
                return Rect2(center: point, width: 2 * radius + 4, height: 2 * radius + 4)
            }
            let bounds = Rect2(minX: 2, minY: 2, maxX: size.width - 2, maxY: size.height - 2)
            for (id, box) in LabelPlacement.place(requests, obstacles: obstacles, lines: [], within: bounds) {
                guard let label = found[id] else { continue }
                var layer = graphics
                layer.opacity = label.depth > projection.distance + 0.35 ? 0.5 : 1
                layer.draw(label.symbol, at: CGPoint(x: box.center.x, y: box.center.y), anchor: .center)
            }
        } symbols: {
            ForEach(drawing.labels) { label in
                RichText(text: label.text, context: context, style: .footnote)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color(label.tone))
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(.systemBackground).opacity(0.55), in: .capsule)
                    .tag(label.id)
            }
        }
        .allowsHitTesting(false)
    }

    private func color(_ tone: SceneObject.Tone?) -> Color {
        switch tone {
        case .main: context.accent
        case .contrast: context.palette.companion
        case .guide: .secondary
        case .plain, .glow, nil: .primary
        }
    }
}
