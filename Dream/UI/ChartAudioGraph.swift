import Accessibility
import SwiftUI

// Audio graphs (ROADMAP.md, workstream 6): what VoiceOver plays and reads for a chart, so its
// shape can be heard. Swift Charts makes one on its own, but from every mark, the faint trace of
// the old curve included, with axes called x and y; these describe what the chart means.

/// A chart of the calculation: the curves as they are now, along the chart's axis, with
/// values written the way the screen writes them.
struct CurveChartDescriptor: AXChartDescriptorRepresentable {
    let block: Block
    let surface: Surface
    let curves: [ChartBlockView.Curve]
    let domain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let surface = surface
        let over = block.over
        let first = block.refs.first ?? ""
        let names = curves.map { surface.label(of: $0.name) }
        let x = AXNumericDataAxisDescriptor(title: surface.label(of: over), range: surface.input(over)?.safeRange ?? 0...1, gridlinePositions: []) {
            surface.display(over, $0)
        }
        let y = AXNumericDataAxisDescriptor(title: names.joined(separator: ", "), range: domain, gridlinePositions: []) {
            surface.display(first, $0)
        }
        let series = curves.map { curve in
            AXDataSeriesDescriptor(name: surface.label(of: curve.name), isContinuous: true, dataPoints: curve.points.map { AXDataPoint(x: $0.x, y: $0.y) })
        }
        let title = block.title.isEmpty ? "\(names.joined(separator: " and ")) by \(surface.label(of: over).lowercased())" : block.title
        return AXChartDescriptor(title: TeX.spoken(title.replacingOccurrences(of: "$", with: " ")), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}

/// Real figures: categories along one axis, or years when they run in order.
struct DataChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let points: [(label: String, value: Double)]
    let overTime: Bool

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = points.map(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, low + 1)
        let y = AXNumericDataAxisDescriptor(title: title, range: low...high, gridlinePositions: []) { Format.number.display($0) }
        let x: any AXDataAxisDescriptor
        let data: [AXDataPoint]
        let years = points.compactMap { Double($0.label.trimmingCharacters(in: .whitespaces)) }
        if overTime, let first = years.first, let last = years.last, first < last {
            x = AXNumericDataAxisDescriptor(title: "Year", range: first...last, gridlinePositions: []) { String(Int($0.rounded())) }
            data = zip(years, values).map { AXDataPoint(x: $0, y: $1) }
        } else {
            x = AXCategoricalDataAxisDescriptor(title: "", categoryOrder: points.map(\.label))
            data = points.map { AXDataPoint(x: $0.label, y: $0.value) }
        }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: overTime, dataPoints: data)
        return AXChartDescriptor(title: TeX.spoken(title.replacingOccurrences(of: "$", with: " ")), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}
