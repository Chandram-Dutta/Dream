import SwiftUI

// The light behind a request says where it is. Each stage has its own colors and its own way of
// moving, so the reader can tell what Dream is doing at a glance, without reading a word:
//
//   understanding   violet and indigo, breathing slowly: taking the request in
//   your turn       pearl, almost still: a question or a permission waits on you
//   researching     blue to teal, flowing: looking things up out in the world
//   writing         Dream's warm light, rose to honey: the page coming onto the screen
//   checking        green, a quick even pulse: the numbers being checked and fixed
//   done            the page's own colors, a glow settled at the top
//
// The colors turn into each other between stages (Aura crossfades palettes), so the change
// reads as one light moving on, not a switch. Only the light is a gradient; the page itself stays
// in one solid ink chosen by its subject.

extension Stage {
    /// The stage's light.
    var palette: Palette {
        switch self {
        case .understanding: .understanding
        case .yourTurn: .yourTurn
        case .researching: .researching
        case .writing: .dream
        case .checking: .checking
        case .done: .dream
        case .failed: .failed
        }
    }

    /// How lively the light is: calm while taking it in, flowing while working, almost still on
    /// the user's turn.
    var energy: Double {
        switch self {
        case .understanding: 0.3
        case .yourTurn: 0.03
        case .researching: 0.6
        case .writing: 0.55
        case .checking: 0.45
        case .done, .failed: 0
        }
    }
}

extension Palette {
    static let understanding = Palette(
        accent: .primary, companion: Color(red: 0.42, green: 0.36, blue: 0.95),
        lights: [ink(0.17, 0.12, 0.42), ink(0.42, 0.36, 0.95), ink(0.66, 0.52, 1), ink(0.42, 0.36, 0.95), ink(0.27, 0.2, 0.6), ink(0.55, 0.62, 1)])
    static let yourTurn = Palette(
        accent: .primary, companion: Color(red: 0.6, green: 0.58, blue: 0.56),
        lights: [ink(0.55, 0.53, 0.52), ink(0.78, 0.76, 0.73), ink(0.9, 0.87, 0.82), ink(0.7, 0.7, 0.72)])
    static let researching = Palette(
        accent: .primary, companion: Color(red: 0.1, green: 0.62, blue: 0.9),
        lights: [ink(0.04, 0.22, 0.5), ink(0.1, 0.5, 0.95), ink(0.15, 0.78, 0.92), ink(0.1, 0.62, 0.72), ink(0.2, 0.42, 0.9)])
    static let checking = Palette(
        accent: .primary, companion: Color(red: 0.1, green: 0.7, blue: 0.45),
        lights: [ink(0.03, 0.3, 0.2), ink(0.1, 0.7, 0.45), ink(0.45, 0.88, 0.6), ink(0.1, 0.55, 0.4)])
    static let failed = Palette(
        accent: .primary, companion: Color(red: 0.6, green: 0.3, blue: 0.3),
        lights: [ink(0.35, 0.18, 0.2), ink(0.6, 0.35, 0.35), ink(0.45, 0.42, 0.45)])

    private static func ink(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// The light behind a request, in the colors of its stage. Once the page is done, it's the page's
/// own light, settled at the top.
struct StageLight: View {
    let stage: Stage
    /// The page's palette, once there's a page; it takes over when the page is done.
    var palette: Palette?
    /// How far down it reaches: 0 a glow at the top, 1 the whole screen.
    var flood: Double
    /// Bump for each thing that happens: the light surges.
    var pulse = 0

    var body: some View {
        let light = stage == .done ? (palette ?? .dream) : stage.palette
        Aura(palette: light, energy: stage.energy, flood: flood, pulse: pulse)
            .animation(.easeInOut(duration: 1.4), value: stage.energy)
            .animation(.easeInOut(duration: 1.2), value: flood)
    }
}

/// Where the request is, in words, quietly at the foot of the screen: four steps, the current one
/// lit in its stage's color. The light already says it; this is for a closer look, and for
/// VoiceOver.
struct StageSteps: View {
    let stage: Stage

    private static let steps: [Stage] = [.understanding, .researching, .writing, .checking]

    var body: some View {
        let current = Self.steps.firstIndex(of: stage == .yourTurn ? .understanding : stage) ?? 0
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    Capsule()
                        .fill(index <= current ? AnyShapeStyle(color(step)) : AnyShapeStyle(.quaternary))
                        .frame(width: index == current ? 18 : 6, height: 6)
                }
            }
            Text(stage.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .animation(.smooth(duration: 0.5), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.label)
    }

    private func color(_ step: Stage) -> Color {
        step.palette.lights.dropFirst().first ?? .accentColor
    }
}
