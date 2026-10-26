import Charts
import SwiftUI

/// A chart of the user's own entries: a value followed day by day, or compared across
/// categories or entries. It redraws as entries come and go.
struct RecordChartView: View {
    let block: Block
    let context: RenderContext

    @State private var selectedDay: Date?

    var body: some View {
        let parts = block.ref.split(separator: ".", maxSplits: 1).map(String.init)
        let along = block.over.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        if let first = parts.first, let collection = context.surface.collection(first), let axis = collection.field(along) {
            let measure = parts.count == 2 ? collection.field(parts[1]) : nil
            let points = collection.series(of: measure?.name, along: axis.name, in: context.state.records[collection.name] ?? [])
            VStack(alignment: .leading, spacing: 14) {
                Text(block.title.isEmpty ? "\(measure?.label ?? collection.label) by \(axis.label.lowercased())" : block.title)
                    .font(.display(.headline))
                if points.isEmpty {
                    Text("Shows up as you add \(collection.entries)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else if axis.type == .date {
                    overTime(points, format: measure?.format ?? .integer)
                } else {
                    bars(points, format: measure?.format ?? .integer)
                }
            }
            .animation(.smooth, value: points)
        }
    }

    private func overTime(_ points: [RecordPoint], format: Format) -> some View {
        let palette = context.palette
        let nearest = selectedDay.flatMap { day in points.min { Swift.abs($0.day?.timeIntervalSince(day) ?? 0) < Swift.abs($1.day?.timeIntervalSince(day) ?? 0) } }
        return Chart {
            ForEach(points) { point in
                if let day = point.day {
                    if points.count > 1 {
                        AreaMark(x: .value("Day", day, unit: .day), y: .value("Value", point.value))
                            .foregroundStyle(LinearGradient(colors: [palette.companion.opacity(0.28), palette.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", day, unit: .day), y: .value("Value", point.value))
                            .foregroundStyle(palette.gradient)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    PointMark(x: .value("Day", day, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(palette.accent)
                        .symbolSize(points.count > 1 ? 30 : 80)
                }
            }
            if let nearest, let day = nearest.day {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(palette.accent.opacity(0.35))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(RecordField.relative(day)).font(.caption2).foregroundStyle(.secondary)
                            Text(format.display(nearest.value)).font(.display(.subheadline)).monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(format.display(number)) }
                }
            }
        }
        .chartXSelection(value: $selectedDay)
        .frame(height: 200)
    }

    private func bars(_ points: [RecordPoint], format: Format) -> some View {
        Chart(points) { point in
            BarMark(x: .value("Value", point.value), y: .value("Label", point.label))
                .foregroundStyle(context.palette.gradient)
                .clipShape(.capsule)
                .annotation(position: .trailing, spacing: 6) {
                    Text(format.display(point.value))
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
    }
}
