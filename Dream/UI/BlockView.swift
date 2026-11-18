import SwiftUI

/// One block of a surface, of any kind. Calculations sit in the surface's tinted panels;
/// information reads as text on the page. Long-press any block to change it.
struct BlockView: View {
    let block: Block
    let context: RenderContext
    let depth: Int

    var body: some View {
        content
            .liveStamp(block, context: context, depth: depth)
            .readingMark(context.readingID == block.id, palette: context.palette)
            .overlay {
                if context.focusedID == block.id {
                    RoundedRectangle(cornerRadius: 30)
                        .strokeBorder(context.palette.accent, lineWidth: 2)
                        .padding(-6)
                }
            }
            .contextMenu {
                if let onChange = context.onChange {
                    Button("Change this…", systemImage: "wand.and.stars") { onChange(block) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        let palette = context.palette
        switch block.kind {
        case .section:
            let isInstrument = block.children.contains { !$0.kind.isInformation }
            VStack(alignment: .leading, spacing: 18) {
                if !block.title.isEmpty {
                    RichText(text: block.title, context: context, style: isInstrument ? .headline : .title3)
                        .font(.display(isInstrument ? .headline : .title3))
                }
                ForEach(Array(block.children.enumerated()), id: \.element.id) { index, child in
                    BlockView(block: child, context: context, depth: depth + 1)
                    if isInstrument && index < block.children.count - 1 {
                        Rectangle().fill(palette.edge).frame(height: 0.5)
                    }
                }
            }
            .panel(palette, enabled: isInstrument && depth == 0)
        case .row:
            // Laid out as if top level, so each metric becomes a tile. Only tiles go side by
            // side: a control needs the width for its label, value and buttons, and squeezed
            // beside another one its label wrapped a word to a line.
            if block.children.allSatisfy({ [.metric, .stat].contains($0.kind) }) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(block.children) { child in
                        BlockView(block: child, context: context, depth: depth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(block.children) { child in
                        BlockView(block: child, context: context, depth: depth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .hero:
            HeroView(block: block, context: context)
        case .metric:
            MetricView(block: block, context: context).panel(palette, enabled: depth == 0)
        case .chart:
            ChartBlockView(block: block, context: context).panel(palette, enabled: depth == 0)
        case .equation:
            EquationBlockView(block: block, context: context)
        case .data:
            if block.ref.isEmpty {
                DataChartView(block: block, context: context)
            } else {
                RecordChartView(block: block, context: context).panel(palette, enabled: depth == 0)
            }
        case .sound:
            SoundBlockView(block: block, context: context).panel(palette, enabled: depth == 0)
        case .list:
            ListBlockView(block: block, context: context, depth: depth)
        case .add:
            AddBarView(block: block, context: context, depth: depth)
        case .figure:
            FigureBlockView(block: block, context: context).panel(palette, enabled: depth == 0)
        case .diagram:
            DiagramBlockView(block: block, context: context)
        case .action:
            ActionBlockView(block: block, context: context)
        case .scene:
            SceneBlockView(block: block, context: context).panel(palette, enabled: depth == 0)
        case .slider, .stepper, .field, .toggle, .picker:
            if let input = context.surface.input(block.ref) {
                ControlView(kind: block.kind, input: input, context: context).panel(palette, enabled: depth == 0)
            }
        case .paragraph:
            VStack(alignment: .leading, spacing: 8) {
                heading
                RichText(text: block.text, context: context)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .facts:
            VStack(alignment: .leading, spacing: 0) {
                heading.padding(.bottom, 6)
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        RichText(text: item.label, context: context).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        RichText(text: item.value, context: context)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 11)
                    if index < block.items.count - 1 {
                        Rectangle().fill(.separator).frame(height: 0.5)
                    }
                }
            }
        case .bullets:
            VStack(alignment: .leading, spacing: 12) {
                heading
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle()
                            .fill(palette.accent)
                            .frame(width: 7, height: 7)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        RichText(text: item.value, context: context).lineSpacing(3)
                    }
                }
            }
        case .steps:
            VStack(alignment: .leading, spacing: 16) {
                heading
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.display(.subheadline, weight: .bold))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 28, height: 28)
                            .background(palette.accent, in: .circle)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        RichText(text: item.value, context: context).lineSpacing(3)
                    }
                    .readingMark(context.readingID == Narration.stepID(block.id, index), palette: palette)
                }
            }
        case .timeline:
            VStack(alignment: .leading, spacing: 0) {
                heading.padding(.bottom, 12)
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 16) {
                        // The line joins events, so the sequence reads at a glance.
                        VStack(spacing: 0) {
                            Circle().fill(palette.accent).frame(width: 11, height: 11).padding(.top, 5)
                            if index < block.items.count - 1 {
                                Rectangle().fill(palette.accent.opacity(0.22)).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.display(.subheadline)).foregroundStyle(palette.accent)
                            RichText(text: item.value, context: context).lineSpacing(3)
                        }
                        .padding(.bottom, index < block.items.count - 1 ? 20 : 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .stat:
            VStack(alignment: .leading, spacing: 16) {
                heading
                ForEach(Array(block.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label.isEmpty ? item.value : item.label)
                            .font(.display(size: 46))
                            .foregroundStyle(palette.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                        if !item.label.isEmpty {
                            RichText(text: item.value, context: context).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var heading: some View {
        if !block.title.isEmpty {
            RichText(text: block.title, context: context, style: .title3).font(.display(.title3))
        }
    }
}

/// The main result: large, on the page itself, rolling to each new value.
struct HeroView: View {
    let block: Block
    let context: RenderContext
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 64

    var body: some View {
        let value = context.value(block.ref).flatMap { $0.isFinite ? $0 : nil }
        VStack(alignment: .leading, spacing: 2) {
            Text(context.surface.label(of: block.ref))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(reading: context.surface.reading(block.ref, value), unitFont: .display(size: size * 0.42))
                .font(.display(size: size))
                .monospacedDigit()
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(context.palette.accent))
                .contentTransition(.numericText(value: value ?? 0))
                .lineLimit(1)
                .minimumScaleFactor(0.35)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: value)
    }
}

/// A secondary result. It lights up when a change reaches it, so you can see what your input affected.
struct MetricView: View {
    let block: Block
    let context: RenderContext
    @State private var lit = false

    var body: some View {
        let value = context.value(block.ref).flatMap { $0.isFinite ? $0 : nil }
        VStack(alignment: .leading, spacing: 4) {
            Text(context.surface.label(of: block.ref))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(reading: context.surface.reading(block.ref, value), unitFont: .display(.subheadline))
                .font(.display(.title2))
                .monospacedDigit()
                .foregroundStyle(lit ? AnyShapeStyle(context.palette.accent) : AnyShapeStyle(.primary))
                .contentTransition(.numericText(value: value ?? 0))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: value)
        .onChange(of: value) {
            lit = true
            withAnimation(.easeOut(duration: 1.1)) { lit = false }
        }
    }
}
