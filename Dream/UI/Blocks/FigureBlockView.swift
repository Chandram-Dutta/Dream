import SwiftUI

/// A figure, drawn to scale in the surface's colours and moving as the numbers change. Points
/// the inputs place are handles: drag one and the inputs follow, snapped to their steps. When
/// the inputs change, the paths they had before linger as a faint trace, so you see what the
/// change did. The geometry is the engine's (`Figure`, `FigureLayout`); this only draws it.
struct FigureBlockView: View {
    let block: Block
    let context: RenderContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: FigureHandle?
    /// From the finger to the handle's centre, so grabbing it off-centre doesn't make it jump.
    @State private var grab = Vec2.zero
    /// What the view shows while a handle is dragged: held still, so the figure doesn't
    /// rescale under the finger even if it grows past the view.
    @State private var frozen: Rect2?
    @State private var ghost: [FigureDrawing.Mark] = []
    @State private var fade: Task<Void, Never>?

    var body: some View {
        if let figure = context.surface.figure(block.ref) {
            figureView(figure)
        }
    }

    private func figureView(_ figure: Figure) -> some View {
        let surface = context.surface
        let drawing = figure.drawing(in: surface, given: context.state.values, values: context.evaluation.values)
        let handles = figure.handles(in: surface)
        // The view keeps the shape of the figure at rest, and grows to keep all of it in sight.
        let rest = figure.extent(in: surface) ?? drawing.bounds ?? Rect2(minX: -1, minY: -1, maxX: 1, maxY: 1)
        let extent = frozen ?? drawing.bounds.map { rest.union($0) } ?? rest
        let space = "figure-\(block.id)"
        return VStack(alignment: .leading, spacing: 12) {
            header
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(1 / FigureViewport.aspect(of: rest), contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        let viewport = FigureViewport(fitting: extent, width: geometry.size.width, height: geometry.size.height)
                        let knobs = handles.compactMap { drawing.points[$0.point].map(viewport.screen) }
                        ZStack(alignment: .topLeading) {
                            FigureCanvas(drawing: drawing, ghost: ghost, viewport: viewport, knobs: knobs, context: context)
                                .clipped()
                            readout(at: dragging.flatMap { drawing.points[$0.point] }.map(viewport.screen), in: geometry.size)
                            ForEach(handles) { handle in
                                if let point = drawing.points[handle.point] {
                                    knob(handle, at: viewport.screen(point), figure: figure, viewport: viewport, extent: extent, space: space)
                                }
                            }
                        }
                        .coordinateSpace(.named(space))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(block.title.isEmpty ? "Figure" : block.title)
                .accessibilityValue(spoken(drawing))
        }
        .onChange(of: context.state.values) { old, _ in remember(figure, before: old) }
        .sensoryFeedback(.selection, trigger: feedback)
    }

    @ViewBuilder private var header: some View {
        if !block.title.isEmpty {
            RichText(text: block.title, context: context, style: .headline)
                .font(.display(.headline))
        }
    }

    /// While dragging, the numbers under your finger, in a top corner away from it. Over the
    /// figure rather than above it, so the figure doesn't move down under the finger.
    @ViewBuilder private func readout(at point: Vec2?, in size: CGSize) -> some View {
        if let dragging {
            let crowded = point.map { $0.x < size.width / 2 && $0.y < 70 } ?? false
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach(dragging.inputs, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.surface.label(of: name)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(context.surface.display(name, context.value(name))).font(.display(.subheadline)).monospacedDigit().foregroundStyle(context.accent)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: crowded ? .topTrailing : .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func knob(_ handle: FigureHandle, at point: Vec2, figure: Figure, viewport: FigureViewport, extent: Rect2, space: String) -> some View {
        let active = dragging == handle
        return Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(context.palette.gradient, lineWidth: 2.5))
            .shadow(color: context.accent.opacity(0.4), radius: active ? 9 : 3, y: 1)
            .frame(width: 22, height: 22)
            .scaleEffect(active && !reduceMotion ? 1.2 : 1)
            .animation(.snappy(duration: 0.2), value: active)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .position(x: point.x, y: point.y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { drag in
                        let finger = Vec2(x: drag.location.x, y: drag.location.y)
                        if dragging != handle {
                            withAnimation(.easeOut(duration: 0.2)) { dragging = handle }
                            grab = point - Vec2(x: drag.startLocation.x, y: drag.startLocation.y)
                            frozen = extent
                        }
                        let values = figure.dragged(handle, to: viewport.model(finger + grab), in: context.surface, given: context.state.values)
                        for (name, value) in values where context.state.values[name] != value {
                            context.state.values[name] = value
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.3)) { dragging = nil }
                        frozen = nil
                    })
            .accessibilityHidden(true)
    }

    /// What a tick of haptics follows: the dragged inputs, when they move in a few big steps.
    private var feedback: [Double] {
        guard let dragging else { return [] }
        return dragging.inputs.compactMap { name in
            context.surface.input(name).flatMap { $0.hasFewSteps ? context.value(name) : nil }
        }
    }

    /// Keeps the paths from before a change began, and lets them go once things settle.
    private func remember(_ figure: Figure, before: [String: Double]) {
        if ghost.isEmpty {
            ghost = figure.drawing(in: context.surface, given: before).marks.filter { $0.shape.kind == .path }
        }
        fade?.cancel()
        fade = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { ghost = [] }
        }
    }

    /// The labels read out, with their live values.
    private func spoken(_ drawing: FigureDrawing) -> String {
        drawing.labels.map { label in
            Placeholders.parts(label.text).map { part in
                switch part {
                case .text(let text): text
                case .name(let name): context.surface.display(name, context.value(name))
                case .math(let tex): TeX.spoken(context.surface.filled(tex, values: context.evaluation.values))
                }
            }.joined()
        }.joined(separator: ", ")
    }

}

/// The shapes and labels, in a Canvas. Labels are SwiftUI text drawn as symbols, so they can
/// hold live values and maths, and are placed once their sizes are known.
private struct FigureCanvas: View {
    let drawing: FigureDrawing
    let ghost: [FigureDrawing.Mark]
    let viewport: FigureViewport
    let knobs: [Vec2]
    let context: RenderContext

    var body: some View {
        Canvas { graphics, size in
            for mark in ghost {
                draw(mark, in: &graphics, faded: true)
            }
            for mark in drawing.marks {
                draw(mark, in: &graphics, faded: false)
            }
            for dot in drawing.dots {
                let center = viewport.screen(dot)
                graphics.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.primary))
            }

            var symbols: [Int: GraphicsContext.ResolvedSymbol] = [:]
            var sizes: [Int: Vec2] = [:]
            for label in drawing.labels {
                guard let symbol = graphics.resolveSymbol(id: label.id) else { continue }
                symbols[label.id] = symbol
                sizes[label.id] = Vec2(x: symbol.size.width, y: symbol.size.height)
            }
            let bounds = Rect2(minX: 2, minY: 2, maxX: size.width - 2, maxY: size.height - 2)
            for (id, box) in drawing.placeLabels(in: viewport, sizes: sizes, bounds: bounds, avoiding: knobs) {
                guard let symbol = symbols[id] else { continue }
                graphics.draw(symbol, at: CGPoint(x: box.center.x, y: box.center.y), anchor: .center)
            }
        } symbols: {
            ForEach(drawing.labels) { label in
                RichText(text: label.text, context: context, style: .footnote)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(label.tone.map { color($0) } ?? .primary)
                    .fixedSize()
                    .padding(.horizontal, 2)
                    .tag(label.id)
            }
        }
    }

    private func draw(_ mark: FigureDrawing.Mark, in graphics: inout GraphicsContext, faded: Bool) {
        let tone = mark.shape.tone
        let ink = faded ? color(tone).opacity(0.4) : color(tone)
        var style = StrokeStyle(lineWidth: width(tone), lineCap: .round, lineJoin: .round, dash: tone == .guide ? [5, 4] : [])
        if faded { style.dash = [4, 5] }

        switch mark.geometry {
        case .line(let points, let closed):
            var screen = points.map(viewport.screen)
            if mark.shape.kind == .arrow, screen.count >= 2 {
                let head = FigureMarks.arrowhead(tip: screen[screen.count - 1], from: screen[screen.count - 2])
                screen[screen.count - 1] = head.lineEnd
                graphics.fill(polygon(head.corners), with: .color(ink))
            }
            var path = Path()
            path.addLines(screen.map { CGPoint(x: $0.x, y: $0.y) })
            if closed {
                path.closeSubpath()
                if tone != .guide && !faded { graphics.fill(path, with: .color(color(tone).opacity(tone == .plain ? 0.07 : 0.16))) }
            }
            graphics.stroke(path, with: .color(ink), style: style)

        case .angle(let vertex, let a, let b):
            let (corner, first, second) = (viewport.screen(vertex), viewport.screen(a), viewport.screen(b))
            if mark.shape.kind == .rightAngle {
                var path = Path()
                path.addLines(FigureMarks.rightAngle(corner, first, second, size: 11).map { CGPoint(x: $0.x, y: $0.y) })
                graphics.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.4, lineJoin: .miter))
            } else {
                let arc = FigureMarks.angleArc(corner, first, second, radius: 22).map { CGPoint(x: $0.x, y: $0.y) }
                var sector = Path()
                sector.move(to: CGPoint(x: corner.x, y: corner.y))
                sector.addLines(arc)
                sector.closeSubpath()
                graphics.fill(sector, with: .color(color(tone).opacity(0.16)))
                var line = Path()
                line.addLines(arc)
                graphics.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }

        case .text:
            break
        }
    }

    private func polygon(_ corners: [Vec2]) -> Path {
        var path = Path()
        path.addLines(corners.map { CGPoint(x: $0.x, y: $0.y) })
        path.closeSubpath()
        return path
    }

    /// The subject in the surface's colour, what it's set against in its companion, the rest in
    /// ink, and helpers quieter still.
    private func color(_ tone: FigureShape.Tone) -> Color {
        switch tone {
        case .main: context.accent
        case .contrast: context.palette.companion
        case .plain: .primary.opacity(0.7)
        case .guide: .secondary
        }
    }

    private func width(_ tone: FigureShape.Tone) -> CGFloat {
        switch tone {
        case .main: 2.5
        case .contrast: 2.2
        case .plain: 1.6
        case .guide: 1.2
        }
    }
}
