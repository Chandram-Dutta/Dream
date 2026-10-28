import SwiftUI

/// The light behind a screen, in its palette's colors. It says what's happening without words.
/// At rest it's a glow at the top, drifting. While Dream works it floods the screen and churns,
/// its colors running through each other, so the wait is something to watch; every step of the
/// work (a search, a page read, a block landing) surges through it. When a page arrives, the
/// light turns from Dream's own colors to the page's and pulls back up to the top.
struct Aura: View, Animatable {
    let palette: Palette
    /// 0 at rest, 1 while working hard. Animatable, so it eases between them.
    var energy: Double
    /// How far down it reaches: 0 a glow at the top, 1 the whole screen.
    var flood = 0.0
    /// Bump for each thing that happens: the light surges.
    var pulse = 0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(energy, flood) }
        set {
            energy = newValue.first
            flood = newValue.second
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    /// Time is measured from here, so the motion stays smooth.
    @State private var start = Date.now
    /// When each surge began, in seconds since `start`.
    @State private var surges: [Double] = []
    /// The palette it's turning from, and when it began to.
    @State private var turning: (from: Palette, at: Double)?

    var body: some View {
        let lively = energy > 0.01 || flood > 0.01
        TimelineView(.animation(minimumInterval: lively ? 1.0 / 60 : 1.0 / 15, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            let surge = reduceMotion ? 0 : surge(at: time)
            MeshGradient(width: 4, height: 4, points: points(at: time, surge: surge), colors: colors(at: time), smoothsColors: true)
                .brightness(surge * (colorScheme == .dark ? 0.12 : 0.06) + breath(at: time))
        }
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.7 + 0.3 * flood), location: 0.18 + 0.12 * energy + 0.5 * flood),
                .init(color: .black.opacity(0.75 * flood), location: min(1, 0.5 + 0.15 * energy + 0.5 * flood)),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulse) {
            guard !reduceMotion else { return }
            surges.append(Date.now.timeIntervalSince(start))
        }
        .onChange(of: palette) { old, _ in
            turning = reduceMotion ? nil : (old, Date.now.timeIntervalSince(start))
        }
    }

    /// How strongly the surges are still felt: each one starts at 1 and dies away in about a second.
    private func surge(at time: Double) -> Double {
        surges.reduce(0) { total, began in
            let since = time - began
            return since < 0 || since > 3 ? total : total + exp(-since * 2.5)
        }
    }

    /// How far the surges have pushed the colors along, smoothly: half a color each.
    private func surgeShift(at time: Double) -> Double {
        surges.reduce(0) { total, began in
            total + 0.5 * (1 - exp(-max(0, time - began) * 2.5))
        }
    }

    /// A 4×4 grid whose corners stay put and whose edges slide along themselves. Three layers of
    /// motion: a slow drift always, a wide flow with energy, a fast swirl when working hard and on
    /// each surge. Speeds are fixed and only amplitudes change, so a change never jumps.
    private func points(at time: Double, surge: Double) -> [SIMD2<Float>] {
        func offset(_ phase: Double) -> Double {
            let drift = sin(time * 0.25 + phase) * 0.05
            let flow = sin(time * 0.9 + phase * 2.3) * 0.1 * energy
            let swirl = sin(time * 2.1 + phase * 3.7) * (0.05 * energy * energy + 0.06 * min(surge, 1.5))
            return drift + flow + swirl
        }
        var points: [SIMD2<Float>] = []
        for row in 0..<4 {
            for column in 0..<4 {
                let x = Double(column) / 3
                let y = Double(row) / 3
                let index = Double(row * 4 + column)
                let edgeX = column == 0 || column == 3
                let edgeY = row == 0 || row == 3
                let dx = edgeX ? 0 : offset(index * 1.3)
                let dy = edgeY ? 0 : offset(index * 2.1 + 0.7)
                points.append([Float(x + dx), Float(y + dy)])
            }
        }
        return points
    }

    /// Each point runs through the palette's lights on its own rhythm: slowly at rest, quickly
    /// while working, a step further on each surge.
    private func colors(at time: Double) -> [Color] {
        let strength = colorScheme == .dark ? 0.7 + 0.2 * energy : 0.4 + 0.3 * energy
        let shift = surgeShift(at: time)
        let current = resolved(palette)
        var from: [SIMD4<Float>]?
        var progress = 1.0
        if let turning {
            progress = smoothstep((time - turning.at) / 1.6)
            if progress < 1 { from = resolved(turning.from) }
        }
        return (0..<16).map { index in
            let place = Double(index) * 0.37 + Double(index / 4) * 0.23
            let slow = time * 0.035 + place
            let fast = time * 0.45 + place * 1.7 + shift
            var color = mix(light(current, at: slow), light(current, at: fast), Float(energy))
            if let from {
                let before = mix(light(from, at: slow), light(from, at: fast), Float(energy))
                color = mix(before, color, Float(progress))
            }
            return Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z), opacity: Double(color.w) * strength)
        }
    }

    private func resolved(_ palette: Palette) -> [SIMD4<Float>] {
        palette.lights.map {
            let color = $0.resolve(in: environment)
            return [color.red, color.green, color.blue, color.opacity]
        }
    }

    /// The lights as a loop: at 2.5, halfway from the third to the fourth.
    private func light(_ lights: [SIMD4<Float>], at phase: Double) -> SIMD4<Float> {
        guard !lights.isEmpty else { return .zero }
        let count = Double(lights.count)
        let wrapped = phase.truncatingRemainder(dividingBy: count) + (phase < 0 ? count : 0)
        let index = Int(wrapped) % lights.count
        return mix(lights[index], lights[(index + 1) % lights.count], Float(smoothstep(wrapped - floor(wrapped))))
    }

    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ amount: Float) -> SIMD4<Float> {
        a + (b - a) * amount
    }

    private func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A slow breath of brightness while working.
    private func breath(at time: Double) -> Double {
        sin(time * 1.3) * (colorScheme == .dark ? 0.04 : 0.025) * energy
    }
}
