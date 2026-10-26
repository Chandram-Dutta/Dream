import Charts
import SwiftUI

/// Outputs plotted along a variable or an input. The inputs that shape the curves sit with the
/// chart, and when one of them changes, the curve it had before lingers as a faint trace, so you
/// see what the change did. Dragging moves along the axis: along an input, that sets it; along
/// a variable, it reads the curves at that point.
struct ChartBlockView: View {
    let block: Block
    let context: RenderContext

    /// The curves as they were before the inputs shaping them started to change.
    @State private var ghost: [Curve] = []
    @State private var fade: Task<Void, Never>?
    @State private var dragging = false

    struct Curve: Identifiable {
        let name: String
        let points: [ChartPoint]
        var id: String { name }
    }

    var body: some View {
        let surface = context.surface
        let curves = block.refs.map { Curve(name: $0, points: surface.series(of: $0, over: block.over, given: context.state.values, records: context.state.records)) }
        let axis = surface.input(block.over)
        let x = axis.map { context.state.value($0) }
        let domain = Self.domain(of: curves + ghost)
        VStack(alignment: .leading, spacing: 10) {
            header(curves: curves, x: x)
            Chart {
                ForEach(ghost) { curve in
                    ForEach(curve.points) { point in
                        LineMark(x: .value("x", point.x), y: .value("y", point.y), series: .value("curve", "before-\(curve.name)"))
                            .foregroundStyle(color(of: curve.name).opacity(0.4))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
                    }
                }
                ForEach(Array(curves.enumerated()), id: \.element.id) { index, curve in
                    ForEach(curve.points) { point in
                        if curves.count == 1 {
                            AreaMark(x: .value("x", point.x), yStart: .value("y", domain.lowerBound), yEnd: .value("y", point.y))
                                .foregroundStyle(LinearGradient(colors: [context.palette.companion.opacity(0.28), context.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("x", point.x), y: .value("y", point.y), series: .value("curve", curve.name))
                            .foregroundStyle(style(index))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: index == 0 ? 2.5 : 2, lineCap: .round, dash: index >= 2 ? [6, 4] : []))
                    }
                }
                if let x {
                    RuleMark(x: .value("x", x))
                        .foregroundStyle(context.accent.opacity(dragging ? 0.6 : 0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    ForEach(Array(curves.enumerated()), id: \.element.id) { index, curve in
                        if let y = context.value(curve.name), y.isFinite, domain.contains(y) {
                            PointMark(x: .value("x", x), y: .value("y", y))
                                .foregroundStyle(.white)
                                .symbolSize(index == 0 ? 140 : 90)
                            PointMark(x: .value("x", x), y: .value("y", y))
                                .foregroundStyle(index == 0 ? context.accent : color(of: curve.name))
                                .symbolSize(index == 0 ? 60 : 36)
                        }
                    }
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: axis.map { $0.safeRange } ?? 0...1)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(surface.display(block.over, number)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(surface.display(block.refs.first ?? "", number)) }
                    }
                }
            }
            .chartXAxisLabel(position: .bottom, alignment: .trailing) {
                Text(surface.label(of: block.over))
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    guard let axis, let plot = proxy.plotFrame else { return }
                                    let origin = geometry[plot].origin
                                    guard let raw: Double = proxy.value(atX: drag.location.x - origin.x) else { return }
                                    dragging = true
                                    context.state.values[axis.name] = axis.snapped(raw)
                                }
                                .onEnded { _ in
                                    withAnimation(.easeOut(duration: 0.3)) { dragging = false }
                                })
                }
            }
            .frame(height: 200)
            .animation(.smooth(duration: 0.5), value: ghost.isEmpty)
            .accessibilityChartDescriptor(CurveChartDescriptor(block: block, surface: surface, curves: curves, domain: domain))
        }
        .onChange(of: shape) { old, _ in remember(old) }
        .sensoryFeedback(.selection, trigger: dragging && (axis?.hasFewSteps ?? false) ? x ?? 0 : 0)
    }

    /// Title and legend; while dragging, the values under your finger instead.
    @ViewBuilder private func header(curves: [Curve], x: Double?) -> some View {
        let surface = context.surface
        let title = block.title.isEmpty
            ? "\(block.refs.map { surface.label(of: $0) }.joined(separator: " and ")) by \(surface.label(of: block.over).lowercased())"
            : block.title
        RichText(text: title, context: context, style: .headline)
            .font(.display(.headline))
        if dragging, let x {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                reading(surface.label(of: block.over), surface.display(block.over, x), color: .secondary)
                ForEach(curves) { curve in
                    reading(surface.label(of: curve.name), surface.display(curve.name, context.value(curve.name)), color: color(of: curve.name))
                }
            }
            .transition(.opacity)
        } else if curves.count > 1 {
            HStack(spacing: 14) {
                ForEach(Array(curves.enumerated()), id: \.element.id) { index, curve in
                    HStack(spacing: 6) {
                        Capsule().fill(style(index)).frame(width: 14, height: 4)
                        Text(surface.label(of: curve.name)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func reading(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.display(.subheadline)).monospacedDigit().foregroundStyle(color)
        }
    }

    /// Every input except the axis: what changes the curves' shape.
    private var shape: [String: Double] {
        Dictionary(context.surface.inputs.filter { $0.name != block.over }.map { ($0.name, context.state.value($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Keeps the curves from before a change began, and lets them go once things settle.
    private func remember(_ before: [String: Double]) {
        if ghost.isEmpty {
            var values = before
            if let axis = context.surface.input(block.over) { values[axis.name] = context.state.value(axis) }
            ghost = block.refs.map { Curve(name: $0, points: context.surface.series(of: $0, over: block.over, given: values, records: context.state.records)) }
        }
        fade?.cancel()
        fade = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { ghost = [] }
        }
    }

    /// The main curve in the surface's colours; the ones it's compared with in neutral tones,
    /// so they never read as the same line.
    private func style(_ index: Int) -> AnyShapeStyle {
        index == 0 ? AnyShapeStyle(context.palette.gradient) : AnyShapeStyle(color(at: index))
    }

    private func color(of name: String) -> Color {
        color(at: block.refs.firstIndex(of: name) ?? 0)
    }

    private func color(at index: Int) -> Color {
        switch index {
        case 0: context.accent
        case 1: .primary.opacity(0.6)
        case 2: context.palette.companion.opacity(0.7)
        default: .secondary
        }
    }

    /// Room for every curve, the trace of the old one included, so a change is visible as a
    /// change in shape rather than hidden by the axis rescaling. Zero is kept in view unless
    /// the curves sit far from it.
    private static func domain(of curves: [Curve]) -> ClosedRange<Double> {
        let ys = curves.flatMap { $0.points.map(\.y) }
        guard var low = ys.min(), var high = ys.max() else { return 0...1 }
        let farFromZero = low > 0 && low > high * 0.6 || high < 0 && high < low * 0.6
        if !farFromZero {
            low = min(low, 0)
            high = max(high, 0)
        }
        if high - low < 1e-9 { (low, high) = (low - 1, high + 1) }
        let padding = (high - low) * 0.06
        return (low == 0 ? 0 : low - padding)...(high + padding)
    }
}

/// Real figures: bars to compare categories, or a line through the years. Touch a year to read it.
struct DataChartView: View {
    let block: Block
    let context: RenderContext

    @State private var selectedYear: Double?
    @State private var grown = false

    private struct Point: Identifiable {
        let label: String
        let value: Double
        var id: String { label }
    }

    var body: some View {
        let points = block.items.compactMap { item in item.number.map { Point(label: item.label, value: $0) } }
        let years = points.compactMap { Double($0.label.trimmingCharacters(in: .whitespaces)) }
        let overTime = points.count >= 3 && years.count == points.count && years == years.sorted()
        VStack(alignment: .leading, spacing: 14) {
            if !block.title.isEmpty {
                RichText(text: block.title, context: context, style: .title3)
                    .font(.display(.title3))
            }
            if overTime {
                timeline(points, years: years)
            } else {
                bars(points)
            }
        }
        .onAppear {
            withAnimation(.smooth(duration: 0.9).delay(0.1)) { grown = true }
        }
    }

    private func bars(_ points: [Point]) -> some View {
        Chart(points) { point in
            BarMark(x: .value("Value", grown ? point.value : 0), y: .value("Label", point.label))
                .foregroundStyle(context.palette.gradient)
                .clipShape(.capsule)
                .annotation(position: .trailing, spacing: 6) {
                    Text(Format.number.display(point.value))
                        .font(.display(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.subheadline)
            }
        }
        .frame(height: CGFloat(points.count) * 38 + 8)
        .accessibilityChartDescriptor(DataChartDescriptor(title: block.title, points: points.map { ($0.label, $0.value) }, overTime: false))
    }

    private func timeline(_ points: [Point], years: [Double]) -> some View {
        let series = zip(years, points).map { (year: $0, value: $1.value, label: $1.label) }
        let nearest = selectedYear.flatMap { selected in series.min { abs($0.year - selected) < abs($1.year - selected) } }
        return Chart {
            ForEach(series, id: \.year) { point in
                AreaMark(x: .value("Year", point.year), y: .value("Value", grown ? point.value : 0))
                    .foregroundStyle(LinearGradient(colors: [context.palette.companion.opacity(0.28), context.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Year", point.year), y: .value("Value", grown ? point.value : 0))
                    .foregroundStyle(context.palette.gradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Year", point.year), y: .value("Value", grown ? point.value : 0))
                    .foregroundStyle(context.accent)
                    .symbolSize(30)
            }
            if let nearest {
                RuleMark(x: .value("Year", nearest.year))
                    .foregroundStyle(context.accent.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(nearest.label).font(.caption2).foregroundStyle(.secondary)
                            Text(Format.number.display(nearest.value)).font(.display(.subheadline)).monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                    }
            }
        }
        .chartXScale(domain: (years.first ?? 0)...(years.last ?? 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let year = value.as(Double.self) { Text(verbatim: String(Int(year.rounded()))) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(number.formatted(.number.notation(.compactName))) }
                }
            }
        }
        .chartXSelection(value: $selectedYear)
        .frame(height: 200)
        .accessibilityChartDescriptor(DataChartDescriptor(title: block.title, points: points.map { ($0.label, $0.value) }, overTime: true))
    }
}
