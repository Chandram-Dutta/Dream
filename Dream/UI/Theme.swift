import SwiftUI
import UIKit

/// A surface's colors, from its accent: the accent, a neighbouring hue for gradients, and
/// quiet tints for panels. Every surface gets its own, so each one looks like its subject.
struct Palette: Equatable {
    let accent: Color
    let companion: Color

    /// Panels and tiles: the accent, barely there.
    var wash: Color { accent.opacity(0.09) }
    var edge: Color { accent.opacity(0.2) }
    var gradient: LinearGradient { LinearGradient(colors: [accent, companion], startPoint: .leading, endPoint: .trailing) }
    /// Big numbers: reads as one color at a glance, but isn't flat.
    var numberGradient: LinearGradient { LinearGradient(colors: [accent, companion], startPoint: .top, endPoint: .bottom) }

    /// Before anything's been made: the time of day.
    static var now: Palette {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: return Accent.mint.palette
        case 11..<17: return Accent.blue.palette
        case 17..<21: return Accent.orange.palette
        default: return Accent.indigo.palette
        }
    }
}

extension Accent {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .mint: .mint
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .indigo: .indigo
        case .red: .red
        case .yellow: .yellow
        case .cyan: .cyan
        case .brown: .brown
        }
    }

    /// A neighbouring hue, so gradients shift a little without turning into a rainbow.
    var companion: Color {
        switch self {
        case .blue: .cyan
        case .teal: .blue
        case .green: .teal
        case .mint: .cyan
        case .orange: .pink
        case .pink: .orange
        case .purple: .indigo
        case .indigo: .blue
        case .red: .orange
        case .yellow: .orange
        case .cyan: .blue
        case .brown: .orange
        }
    }

    var palette: Palette { Palette(accent: color, companion: companion) }
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
