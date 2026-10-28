import SwiftUI
import UIKit

/// A screen's colors. A page has one ink, from its subject (`Accent`): numbers, controls and
/// links in one solid color, a neighbouring hue for a second series, and quiet tints for panels.
/// The only gradient is the light behind it (`Aura`), which moves through `lights`.
struct Palette: Equatable {
    /// The ink.
    let accent: Color
    let companion: Color
    /// What the light behind the screen moves through, in order, round and round.
    let lights: [Color]
    /// Text and symbols set on the ink.
    var onAccent: Color = .white

    /// Panels and tiles: the ink, barely there.
    var wash: Color { accent.opacity(0.09) }
    var edge: Color { accent.opacity(0.2) }

    /// Dream's own screens, and a page before it knows what it's about. No ink of its own, so
    /// color belongs to pages: black on white, white on black. Its light is the one behind closed
    /// eyes: rose, apricot and honey over deep plum, with a rare flicker of teal.
    static let dream = Palette(
        accent: .primary,
        companion: .secondary,
        lights: [plum, rose, apricot, honey, apricot, rose, plum, teal],
        onAccent: Color(.systemBackground))

    private static let plum = Color(red: 0.42, green: 0.1, blue: 0.36)
    private static let rose = Color(red: 1, green: 0.24, blue: 0.43)
    private static let apricot = Color(red: 1, green: 0.54, blue: 0.24)
    private static let honey = Color(red: 1, green: 0.77, blue: 0.24)
    private static let teal = Color(red: 0.18, green: 0.88, blue: 0.78)
}

extension Accent {
    /// Tuned for each appearance: deep enough to read on white, bright enough on black.
    var color: Color {
        switch self {
        case .blue: Color(light: 0x2563EB, dark: 0x5B8CFF)
        case .teal: Color(light: 0x0F9488, dark: 0x2DD4BF)
        case .green: Color(light: 0x0E9F6E, dark: 0x34D399)
        case .mint: Color(light: 0x0EA5A0, dark: 0x5EEAD4)
        case .orange: Color(light: 0xE8670C, dark: 0xFF8A3D)
        case .pink: Color(light: 0xDB2777, dark: 0xFF6B9A)
        case .purple: Color(light: 0x9333EA, dark: 0xC084FC)
        case .indigo: Color(light: 0x4F46E5, dark: 0x8B83FF)
        case .red: Color(light: 0xDC2626, dark: 0xFF5A5A)
        case .yellow: Color(light: 0xB7791F, dark: 0xFBBF24)
        case .cyan: Color(light: 0x0891B2, dark: 0x38D5F5)
        case .brown: Color(light: 0x9A5B2E, dark: 0xD19A66)
        }
    }

    /// A neighbouring hue, for a second series and the light.
    var companion: Color {
        switch self {
        case .blue: Accent.cyan.color
        case .teal: Accent.blue.color
        case .green: Accent.teal.color
        case .mint: Accent.cyan.color
        case .orange: Accent.pink.color
        case .pink: Accent.orange.color
        case .purple: Accent.indigo.color
        case .indigo: Accent.blue.color
        case .red: Accent.orange.color
        case .yellow: Accent.orange.color
        case .cyan: Accent.blue.color
        case .brown: Accent.orange.color
        }
    }

    var palette: Palette {
        let deep = color.mix(with: .black, by: 0.5)
        // Only a little lighter: text sits on this light while a page is written.
        let bright = color.mix(with: .white, by: 0.15)
        // One deep shade among them, so the light stays bright while a page is being written.
        return Palette(accent: color, companion: companion, lights: [deep, color, bright, companion, color, bright])
    }
}

extension Color {
    /// One color in light appearance and another in dark, as 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

extension Surface {
    var palette: Palette { accent.palette }

    /// The model sometimes invents symbol names, and names arrive a few letters at a time.
    var symbolName: String { UIImage(systemName: symbol) != nil ? symbol : "sparkles" }
}

extension Font {
    /// Dream's voice: SF Pro's expanded width, for titles and big numbers. Scales with Dynamic Type.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, weight: weight).width(.expanded)
    }

    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
}

extension View {
    /// The surface's instrument: a tinted panel for controls, results and charts. Information
    /// isn't paneled; it reads as text on the page.
    @ViewBuilder func panel(_ palette: Palette, enabled: Bool = true) -> some View {
        if enabled {
            padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.wash, in: .rect(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(palette.edge, lineWidth: 0.5))
        } else {
            self
        }
    }
}

/// A row in Dream's small glass cards (the account card, the model picker): the whole row is the
/// target, and it answers a finger with a wash of the palette instead of a grey highlight.
struct CardRowStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(configuration.isPressed ? 0.14 : 0), in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

/// A light sweep across placeholders, while there's nothing to show yet.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: phase * geometry.size.width * 1.5)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
