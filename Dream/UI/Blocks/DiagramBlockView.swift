import SwiftUI

/// A diagram, laid out by the engine for the width it has (`DiagramLayout`). Tap a part to read
/// about it: it lights up with the lines that join it, its detail shows below, and in a flow or
/// cycle you can step on to what comes next. The first part starts selected, so the page shows
/// what tapping does rather than saying so.
struct DiagramBlockView: View {
    let block: Block
    let context: RenderContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var nodeHeight: CGFloat = 50
    @State private var width: CGFloat = 0
    @State private var selected: String?

    var body: some View {
        if let diagram = context.surface.diagram(block.ref) {
            let layout = layout(of: diagram)
            let hasDetail = diagram.nodes.contains { !$0.detail.isEmpty }
            let current = selected.flatMap { diagram.node($0) } ?? (hasDetail ? diagram.nodes.first : nil)
            VStack(alignment: .leading, spacing: 16) {
                if !block.title.isEmpty {
                    RichText(text: block.title, context: context, style: .title3)
                        .font(.display(.title3))
                }
                ZStack(alignment: .topLeading) {
                    DiagramLines(layout: layout, highlighted: current?.id, palette: context.palette)
                    ForEach(layout.routes.indices, id: \.self) { index in
                        let route = layout.routes[index]
                        if let center = route.labelCenter {
                            Text(route.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.systemBackground), in: .capsule)
                                .fixedSize()
                                .position(x: center.x, y: center.y)
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(diagram.nodes, id: \.id) { node in
                        if let frame = layout.frames[node.id] {
                            nodeView(node, in: diagram, frame: frame, isSelected: node.id == current?.id, isHub: node.id == layout.hub, isOutline: layout.isOutline)
                        }
                    }
                }
                .frame(width: width, height: layout.height, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                if let current, !current.detail.isEmpty {
                    detail(current, in: diagram)
                        .id(current.id)
                        .transition(.opacity)
                }
            }
        }
    }

    private func layout(of diagram: Diagram) -> DiagramLayout {
        var metrics = DiagramLayout.Metrics.standard
        metrics.nodeHeight = Double(nodeHeight)
        metrics.rowHeight = Double(nodeHeight) * 0.8
        return DiagramLayout.make(diagram, width: Double(width), metrics: metrics)
    }

    private func nodeView(_ node: Diagram.Node, in diagram: Diagram, frame: Rect2, isSelected: Bool, isHub: Bool, isOutline: Bool) -> some View {
        let palette = context.palette
        // An outline has no room on its lines, so what joins a part to its parent goes beside its name.
        let joining = isOutline ? diagram.connections.first { $0.to == node.id && !$0.label.isEmpty }?.label : nil
        let label = joining.map { Text("\(node.label)  \(Text($0).font(.caption).fontWeight(.regular).foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)))") } ?? Text(node.label)
        return Button {
            select(node.id)
        } label: {
            label
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(isOutline ? .leading : .center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .frame(width: frame.width, height: frame.height, alignment: isOutline ? .leading : .center)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isSelected ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(palette.wash))
                        .background(Color(.systemBackground), in: .rect(cornerRadius: 14))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isHub && !isSelected ? palette.accent.opacity(0.5) : palette.edge, lineWidth: isHub ? 1.5 : 0.5)
                }
        }
        .buttonStyle(.plain)
        .position(x: frame.center.x, y: frame.center.y)
        .accessibilityLabel(node.label)
        .accessibilityValue(isSelected ? node.detail : "")
        .accessibilityHint(leads(from: node, in: diagram))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detail(_ node: Diagram.Node, in diagram: Diagram) -> some View {
        let next = diagram.shape == .flow || diagram.shape == .cycle
            ? diagram.connections.first { $0.from == node.id }.flatMap { diagram.node($0.to) }
            : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(node.label)
                .font(.display(.headline))
                .foregroundStyle(context.palette.accent)
            RichText(text: node.detail, context: context)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let next {
                Button {
                    select(next.id)
                } label: {
                    Label("Next: \(next.label)", systemImage: "arrow.right")
                        .font(.subheadline.weight(.medium))
                        .labelStyle(TrailingIcon())
                }
                .buttonStyle(.plain)
                .foregroundStyle(context.palette.gradient)
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(context.palette.wash, in: .rect(cornerRadius: 20))
    }

    private func select(_ id: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { selected = id }
    }

    /// For VoiceOver: where this part leads.
    private func leads(from node: Diagram.Node, in diagram: Diagram) -> String {
        let next = diagram.connections.filter { $0.from == node.id }.compactMap { diagram.node($0.to)?.label }
        return next.isEmpty ? "" : "Leads to \(ListFormatter.localizedString(byJoining: next))"
    }
}

/// The lines between parts, in a Canvas. Those joining the selected part are drawn stronger.
private struct DiagramLines: View {
    let layout: DiagramLayout
    let highlighted: String?
    let palette: Palette

    var body: some View {
        Canvas { graphics, _ in
            // The quiet lines first, so the highlighted ones sit on top.
            let routes = layout.routes.sorted { !isLit($0) && isLit($1) }
            for route in routes {
                let lit = isLit(route)
                let ink = lit ? palette.accent : palette.accent.opacity(0.4)
                var points = route.points
                if route.hasArrow, points.count >= 2 {
                    let head = FigureMarks.arrowhead(tip: points[points.count - 1], from: points[points.count - 2], length: 9, width: 8)
                    points[points.count - 1] = head.lineEnd
                    var path = Path()
                    path.addLines(head.corners.map { CGPoint(x: $0.x, y: $0.y) })
                    path.closeSubpath()
                    graphics.fill(path, with: .color(ink))
                }
                var line = Path()
                line.addLines(points.map { CGPoint(x: $0.x, y: $0.y) })
                graphics.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: lit ? 2 : 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: layout.width, height: layout.height)
        .accessibilityHidden(true)
    }

    private func isLit(_ route: DiagramLayout.Route) -> Bool {
        highlighted != nil && (route.from == highlighted || route.to == highlighted)
    }
}

/// The icon after the title, for a button that moves on.
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.caption.weight(.bold))
        }
    }
}
