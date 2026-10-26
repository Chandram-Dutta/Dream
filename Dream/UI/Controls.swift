import SwiftUI

struct ControlView: View {
    let kind: BlockKind
    let input: Input
    let context: RenderContext
    @Environment(\.isPicture) private var isPicture

    var body: some View {
        // In a shared picture, controls UIKit draws are drawn still (SurfacePicture.swift).
        if isPicture, let still = StillControl(kind: kind, input: input, context: context) {
            still
        } else {
            control
        }
    }

    @ViewBuilder private var control: some View {
        switch kind {
        case .toggle: ToggleControl(input: input, context: context)
        case .picker: PickerControl(input: input, context: context)
        case .stepper: StepperControl(input: input, context: context)
        case .field: FieldControl(input: input, context: context)
        default: SliderControl(input: input, context: context)
        }
    }
}

/// The current value next to a control's label, in the surface's voice.
private struct ValueLabel: View {
    let input: Input
    let context: RenderContext

    var body: some View {
        let value = context.state.value(input)
        Text(reading: context.surface.reading(input.name, value), unitFont: .display(.subheadline))
            .font(.display(.title3))
            .monospacedDigit()
            .foregroundStyle(context.palette.numberGradient)
            .contentTransition(.numericText(value: value))
            .animation(.snappy, value: value)
    }
}

struct SliderControl: View {
    let input: Input
    let context: RenderContext

    var body: some View {
        let value = context.state.value(input)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(input.label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                ValueLabel(input: input, context: context)
            }
            // In the reader's units (Units+UI.swift).
            let shown = context.surface.shown(input)
            DreamSlider(value: context.binding(input), range: shown.safeRange, step: shown.safeStep, palette: context.palette)
        }
        .sensoryFeedback(.selection, trigger: input.hasFewSteps ? value : 0)
    }
}

/// A thick gradient track whose thumb grows under your finger. Tap anywhere on it to jump there.
/// VoiceOver gets a standard slider.
struct DreamSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let palette: Palette
    @State private var dragging = false

    private let thumb: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - thumb, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.accent.opacity(0.14))
                    .frame(height: 8)
                Capsule()
                    .fill(palette.gradient)
                    .frame(width: CGFloat(fraction) * travel + thumb / 2, height: 8)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(palette.accent.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: palette.accent.opacity(0.35), radius: dragging ? 10 : 4, y: 2)
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(dragging ? 1.18 : 1)
                    .offset(x: CGFloat(fraction) * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let position = min(max((drag.location.x - thumb / 2) / travel, 0), 1)
                        var newValue = range.lowerBound + Double(position) * span
                        if let step { newValue = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step }
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragging = false })
        }
        .frame(height: 34)
        .animation(.snappy(duration: 0.25), value: dragging)
        .accessibilityRepresentation {
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

/// Round minus and plus buttons; hold one to keep counting.
struct StepperControl: View {
    let input: Input
    let context: RenderContext

    var body: some View {
        // In the reader's units (Units+UI.swift).
        let shown = context.surface.shown(input)
        let binding = context.binding(input)
        let value = binding.wrappedValue
        let step = shown.safeStep ?? 1
        let range = shown.safeRange
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(input.label).foregroundStyle(.secondary)
                ValueLabel(input: input, context: context)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                RoundButton(symbol: "minus", palette: context.palette) {
                    binding.wrappedValue = max(value - step, range.lowerBound)
                }
                .disabled(value <= range.lowerBound)
                RoundButton(symbol: "plus", palette: context.palette) {
                    binding.wrappedValue = min(value + step, range.upperBound)
                }
                .disabled(value >= range.upperBound)
            }
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityRepresentation {
            Stepper(input.label, value: binding, in: range, step: step)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let palette: Palette
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline.weight(.bold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
                .frame(width: 44, height: 44)
                .background(palette.accent.opacity(isEnabled ? 0.14 : 0.06), in: .circle)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

struct ToggleControl: View {
    let input: Input
    let context: RenderContext

    var body: some View {
        let isOn = Binding(
            get: { context.state.value(input) != 0 },
            set: { context.state.values[input.name] = $0 ? 1 : 0 })
        Toggle(input.label, isOn: isOn)
            .tint(context.accent)
            .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }
}

struct PickerControl: View {
    let input: Input
    let context: RenderContext

    var body: some View {
        let selection = Binding<Int>(
            get: { Int(exactly: context.state.value(input).rounded()) ?? 0 },
            set: { context.state.values[input.name] = Double($0) })
        Group {
            if input.options.count <= 3 && input.options.allSatisfy({ $0.count <= 14 }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(input.label).foregroundStyle(.secondary)
                    Segments(options: input.options, selection: selection, palette: context.palette)
                }
            } else {
                HStack {
                    Text(input.label).foregroundStyle(.secondary)
                    Spacer()
                    Picker(input.label, selection: selection) {
                        ForEach(Array(input.options.enumerated()), id: \.offset) { index, option in
                            Text(option).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(context.accent)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
}

/// A few options side by side; the selection glides to whichever you tap.
private struct Segments: View {
    let options: [String]
    @Binding var selection: Int
    let palette: Palette
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selection = index
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(selection == index ? Color.white : Color.primary)
                        .background {
                            if selection == index {
                                Capsule()
                                    .fill(palette.gradient)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(palette.accent.opacity(0.1), in: .capsule)
        .animation(.snappy, value: selection)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(option).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// For exact amounts. Updates the surface as the user types, not only when they finish.
struct FieldControl: View {
    let input: Input
    let context: RenderContext
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // In the reader's units (Units+UI.swift).
        let binding = context.binding(input)
        let value = binding.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            Text(input.label).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if input.format == .currency {
                    Text(context.surface.currency(of: input.name).map(Currency.symbol(for:)) ?? Currency.symbol)
                        .font(.display(.title2))
                        .foregroundStyle(.secondary)
                }
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.display(.title))
                    .monospacedDigit()
                    .foregroundStyle(context.palette.numberGradient)
                    .focused($focused)
                if input.format == .percent {
                    Text("%").font(.display(.title2)).foregroundStyle(.secondary)
                }
                if let unit = context.surface.shownUnit(input.name)?.symbol {
                    Text(unit).font(.display(.title3)).foregroundStyle(.secondary)
                }
            }
            Capsule()
                .fill(focused ? AnyShapeStyle(context.palette.gradient) : AnyShapeStyle(context.palette.edge))
                .frame(height: focused ? 2 : 1)
                .animation(.snappy, value: focused)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { text = Self.text(for: value) }
        .onChange(of: text) { _, new in
            if let parsed = Double(new.replacingOccurrences(of: ",", with: ".")), parsed != value {
                binding.wrappedValue = parsed
            }
        }
        .onChange(of: value) { _, new in
            if !focused { text = Self.text(for: new) }
        }
    }

    private static func text(for value: Double) -> String {
        value == value.rounded() ? value.plain : String(format: "%.2f", value)
    }
}
