import SwiftUI

/// How a page under construction shows that Dream is working on it: the screen's border glowing,
/// with stars flying into it at each step of the work; or Dream's light filling the screen
/// (Aura). An experiment, picked in Under the hood.
enum ConstructionStyle: String, CaseIterable {
    case warp, light

    /// The UserDefaults key, which views can watch with `@AppStorage`.
    static let key = "constructionStyle"

    var name: String {
        switch self {
        case .warp: "Border and stars"
        case .light: "Light"
        }
    }
}

/// The screen's border glowing while Dream works, in a page's colors, so the page itself stays
/// clear to read; and while Dream thinks, before there's a page, stars streaming from the centre
/// out into the border, each in the border's color where it lands. Each step of the work (a
/// search, a page read, a block landing) speeds the stars up for a few seconds and flares the
/// border. Both in one shader (Warp.metal), at most 60 frames a second, and nothing at all once
/// the page is done.
struct ConstructionGlow: View, Animatable {
    let palette: Palette
    /// How strongly the border glows: 0 gone, 1 full.
    var border: Double
    /// How visible the stars are: 1 while Dream thinks, 0 once the page is writing itself.
    var stars: Double
    /// Bump for each step of the work. Ignored while the border is off, so a value changed on a
    /// finished page sets nothing off.
    var pulse = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var clock = WarpClock()

    /// Both fade rather than switch.
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(border, stars) }
        set {
            border = newValue.first
            stars = newValue.second
        }
    }

    var body: some View {
        let lights = palette.lights.map { Color($0.resolve(in: environment)) }
        let four = (0..<4).map { lights.isEmpty ? Color.white : lights[$0 * lights.count / 4] }
        let dark: Float = colorScheme == .dark ? 1 : 0
        GeometryReader { geometry in
            let size = geometry.size
            // The screen's own corner, as far as the container says.
            let corner = geometry.containerCornerInsets.topLeading.width
            let radius = corner > 0 ? corner : 55
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || (border < 0.01 && stars < 0.01))) { timeline in
                let frame = clock.advance(to: timeline.date, cruising: stars)
                Rectangle()
                    .colorEffect(ShaderLibrary.construction(
                        .float2(size), .float(radius), .float(frame.turn), .float(min(1, border * frame.breath + frame.flare)), .float(stars),
                        .float(frame.travel), .float(frame.stretch), .float(dark),
                        .color(four[0]), .color(four[1]), .color(four[2]), .color(four[3])))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: pulse) { if border > 0.01, !reduceMotion { clock.surge() } }
    }
}

/// The construction glow's sense of time: how far the border's colors have gone round, and how
/// far the stars have flown, added up frame by frame so speeding up never makes them jump. The
/// stars cruise while Dream thinks; a surge speeds them up for a few seconds, and the border
/// flares as the fast ones reach it, a third of a second later.
@MainActor
final class WarpClock {
    private var start: Date?
    private var last: Date?
    private var travel = 0.0
    private var boost = 0.0
    private var surgedAt: Date?

    func surge() {
        boost = 1
        surgedAt = .now
    }

    func advance(to date: Date, cruising: Double) -> (turn: Float, breath: Double, flare: Double, travel: Float, stretch: Float) {
        let started = start ?? date
        start = started
        let step = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        // About three or four seconds to die away.
        boost *= exp(-step * 0.6)
        travel += (0.03 + 0.09 * cruising + 0.45 * boost) * step
        // Kept small, so the shader's floats stay precise however long it runs.
        if travel > 1024 { travel -= 1024 }
        let time = date.timeIntervalSince(started)
        let since = surgedAt.map { date.timeIntervalSince($0) } ?? 99
        let flare = since < 0.35 ? 0.4 * since / 0.35 : 0.4 * exp(-(since - 0.35) * 1.5)
        return (Float((time * 0.08).truncatingRemainder(dividingBy: 1)), 0.85 + 0.15 * sin(time * 2.2), flare,
                Float(travel), Float(0.02 + 0.03 * cruising + 0.25 * boost))
    }
}
