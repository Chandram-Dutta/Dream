import SwiftUI

/// A field of a surface's colors behind the top of the screen. It shows what the model is
/// doing without any words: while it thinks, the light spreads down the screen and swirls,
/// its colors drifting into each other; while it writes, it pulls back and flows gently;
/// at rest it settles. It brightens for a moment when a result changes.
struct Aura: View, Animatable {
    let palette: Palette
    /// 0 at rest, about 0.5 while writing, 1 while thinking. Animatable, so it eases between them.
    var energy: Double
    /// Bump to brighten the field for a moment.
    var pulse = 0

    var animatableData: Double {
        get { energy }
        set { energy = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var flash = 0.0
    /// Time is measured from here, so the waves stay smooth.
    @State private var start = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: energy > 0.01 ? 1.0 / 30 : 1.0 / 12, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            MeshGradient(width: 3, height: 3, points: points(at: time), colors: colors(at: time))
                .brightness(breath(at: time))
        }
        .brightness(flash)
        // Reach: the light spreads further down the screen the more the model is thinking.
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.7), location: 0.25 + 0.25 * energy),
                .init(color: .clear, location: 0.6 + 0.4 * energy),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 1.2), value: palette)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulse) {
            guard !reduceMotion else { return }
            flash = colorScheme == .dark ? 0.1 : 0.05
            withAnimation(.easeOut(duration: 0.8)) { flash = 0 }
        }
    }

    /// Corners stay put. The middle points drift slowly at rest, flow while writing, and swirl
    /// while thinking. Speeds are fixed and only amplitudes change, so shifts never jump.
    private func points(at time: Double) -> [SIMD2<Float>] {
        func offset(_ phase: Double) -> Float {
            let drift = sin(time * 0.22 + phase) * 0.06
            let flow = sin(time * 1.1 + phase * 2.3) * 0.11 * energy
            let swirl = sin(time * 2.4 + phase * 3.7) * 0.06 * energy * energy
            return Float(drift + flow + swirl)
        }
        return [
            [0, 0], [0.5 + offset(0), 0], [1, 0],
            [0, 0.5 + offset(1)], [0.5 + offset(2), 0.5 + offset(3)], [1, 0.5 + offset(4)],
            [0, 1], [0.5 + offset(5), 1], [1, 1],
        ]
    }

    /// While thinking, each point drifts between the two colors on its own rhythm.
    private func colors(at time: Double) -> [Color] {
        let strength = (colorScheme == .dark ? 0.72 : 0.42) + 0.15 * energy
        let accent = palette.accent
        let companion = palette.companion
        func color(_ index: Double, starting base: Color, toward other: Color, _ opacity: Double) -> Color {
            let amount = energy * energy * (sin(time * 0.9 + index * 1.7) + 1) / 2
            return base.mix(with: other, by: amount).opacity(strength * opacity)
        }
        return [
            color(0, starting: accent, toward: companion, 1), color(1, starting: companion, toward: accent, 0.9), color(2, starting: accent, toward: companion, 0.55),
            color(3, starting: companion, toward: accent, 0.45), color(4, starting: accent, toward: companion, 0.35), color(5, starting: companion, toward: accent, 0.5),
            .clear, .clear, .clear,
        ]
    }

    /// A slow breath of brightness while thinking.
    private func breath(at time: Double) -> Double {
        sin(time * 1.3) * (colorScheme == .dark ? 0.05 : 0.03) * energy * energy
    }
}
