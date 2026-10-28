import SwiftUI
import UIKit

/// A diagram, laid out by the engine for the width it has (`DiagramLayout`), with text measured
/// in the fonts it's drawn in, so names break only between words. Tap a part to read about it:
/// it lights up with the lines that join it, its detail shows below, and in a flow or cycle you
/// can step on to what comes next. The first part starts selected, so the page shows what
/// tapping does rather than saying so.
struct DiagramBlockView: View {
    let block: Block
    let context: RenderContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0
    @State private var selected: String?

    var body: some View {
        if let diagram = context.surface.diagram(block.ref) {
            let fonts = DiagramFonts(dynamicTypeSize)
            let layout = DiagramLayouts.layout(of: diagram, width: Double(width), fonts: fonts)
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
                        if let frame = route.labelFrame {
                            VStack(spacing: 0) {
                                ForEach(Array(route.labelLines.enumerated()), id: \.offset) { _, line in
                                    Text(line).lineLimit(1).minimumScaleFactor(0.8)
                                }
                            }
                            .font(fonts.label(layout.textScale))
                            .foregroundStyle(.secondary)
                            .frame(width: frame.width, height: frame.height)
                            .background(Color(.systemBackground), in: .rect(cornerRadius: 6))
                            .position(x: frame.center.x, y: frame.center.y)
                            .accessibilityHidden(true)
                        }
                    }
                    ForEach(diagram.nodes, id: \.id) { node in
                        if let frame = layout.frames[node.id] {
                            nodeView(node, in: diagram, layout: layout, frame: frame, fonts: fonts, isSelected: node.id == current?.id)
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

    private func nodeView(_ node: Diagram.Node, in diagram: Diagram, layout: DiagramLayout, frame: Rect2, fonts: DiagramFonts, isSelected: Bool) -> some View {
        let palette = context.palette
        let isHub = node.id == layout.hub
        let lines = layout.lines[node.id] ?? [node.label]
        // An outline has no room on its lines, so what joins a part to its parent goes beside its name.
        let joining = layout.isOutline ? diagram.connections.first { $0.to == node.id && !$0.label.isEmpty }?.label : nil
        return Button {
            select(node.id)
        } label: {
            VStack(alignment: layout.isOutline ? .leading : .center, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Group {
                        if index == lines.count - 1, let joining {
                            Text("\(line)  \(Text(joining).font(.caption).fontWeight(.regular).foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)))")
                        } else {
                            Text(line)
                        }
                    }
                    // The engine made room for every word; this only catches a font that measures a hair wider.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .font(fonts.node(layout.textScale))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, DiagramFonts.padding)
            .frame(width: frame.width, height: frame.height, alignment: layout.isOutline ? .leading : .center)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.wash))
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
                .foregroundStyle(context.palette.accent)
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

/// The fonts a diagram is drawn in, at the reader's text size, and how the engine measures them.
private struct DiagramFonts: Hashable {
    /// Room either side of a node's text, matching the engine's.
    static let padding = 10.0

    let nodeSize: CGFloat
    let labelSize: CGFloat

    init(_ dynamicTypeSize: DynamicTypeSize) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        nodeSize = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
        labelSize = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).pointSize
    }

    func node(_ scale: Double) -> Font { .system(size: nodeSize * scale, weight: .semibold) }
    func label(_ scale: Double) -> Font { .system(size: labelSize * scale, weight: .medium) }

    var metrics: DiagramLayout.Metrics {
        let nodeFont = UIFont.systemFont(ofSize: nodeSize, weight: .semibold)
        let labelFont = UIFont.systemFont(ofSize: labelSize, weight: .medium)
        var metrics = DiagramLayout.Metrics.standard
        metrics.measureNode = { ($0 as NSString).size(withAttributes: [.font: nodeFont]).width }
        metrics.measureLabel = { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }
        metrics.lineHeight = nodeFont.lineHeight
        metrics.labelLineHeight = labelFont.lineHeight
        metrics.nodePadding = Self.padding
        metrics.nodeHeight = Swift.max(50, 2 * nodeFont.lineHeight + 12)
        return metrics
    }
}

/// Laying a diagram out tries several sizes and places every label, so each layout is kept for
/// its diagram, width and text size rather than redone whenever the page redraws.
@MainActor
private enum DiagramLayouts {
    private struct Key: Hashable {
        let diagram: Diagram
        let width: Double
        let fonts: DiagramFonts
    }

    private static var known: [Key: DiagramLayout] = [:]

    static func layout(of diagram: Diagram, width: Double, fonts: DiagramFonts) -> DiagramLayout {
        let key = Key(diagram: diagram, width: width, fonts: fonts)
        if let hit = known[key] { return hit }
        let layout = DiagramLayout.make(diagram, width: width, metrics: fonts.metrics)
        if known.count > 32 { known.removeAll() }
        known[key] = layout
        return layout
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
