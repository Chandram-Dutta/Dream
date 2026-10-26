import SwiftUI

/// Tones summed over a fixed stretch of time, from the same levels the synthesizer plays: a
/// higher pitch packs in more cycles, a louder one stands taller, and close tones show their
/// beats. When there are too many cycles to draw one by one, it's a band from the lowest point
/// to the highest in each column, the way recordings are drawn; stroke the line, fill the band.
struct WaveShape: Shape {
    let levels: [ToneLevel]
    /// Seconds across the width.
    let window: Double
    /// The amplitude that reaches the top.
    let loudest: Double
    /// Seconds into the sound at the left edge.
    var start: Double = 0

    func isBand(width: CGFloat) -> Bool {
        let highest = levels.map(\.frequency).max() ?? 440
        // A line needs about four points of width per cycle to read as a wave.
        return highest * window / Double(max(width, 2)) >= 0.25
    }

    func path(in rect: CGRect) -> Path {
        let columns = max(Int(rect.width), 2)
        let middle = rect.midY
        let reach = (rect.height / 2 - 2) / max(loudest, 0.01)
        func signal(_ time: Double) -> Double {
            let sum = levels.reduce(0) { sum, level in
                sum + level.amplitude * level.waveform.value(at: (level.frequency * time).truncatingRemainder(dividingBy: 1))
            }
            return min(max(sum, -loudest), loudest)
        }
        var path = Path()
        if !isBand(width: rect.width) {
            let samples = columns * 2
            for index in 0...samples {
                let fraction = Double(index) / Double(samples)
                let point = CGPoint(x: rect.minX + fraction * rect.width, y: middle - signal(start + fraction * window) * reach)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
        let highest = levels.map(\.frequency).max() ?? 440
        let samples = min(48, Int((highest * window / Double(columns) * 12).rounded(.up)) + 2)
        let width = rect.width / Double(columns)
        for column in 0..<columns {
            var low = Double.infinity
            var high = -Double.infinity
            // Up to where the next column starts, so neighbouring columns join.
            for sample in 0...samples {
                let value = signal(start + (Double(column) + Double(sample) / Double(samples)) / Double(columns) * window)
                low = min(low, value)
                high = max(high, value)
            }
            path.addRect(CGRect(x: rect.minX + Double(column) * width, y: middle - high * reach - 0.75, width: width, height: (high - low) * reach + 1.5))
        }
        return path
    }
}
