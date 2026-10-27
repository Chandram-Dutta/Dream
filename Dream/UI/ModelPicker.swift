import SwiftUI

/// What an account may choose about how its pages are made, from the plan Dream's server sent:
/// the models it can use (the default first) and the thinking levels. The picks themselves live in
/// UserDefaults (`ModelChoice`, `ThinkingChoice`), so Account and the chip always agree.
struct ModelOptions: Equatable {
    let models: [Plan.Status.ModelOption]
    let levels: [String]

    init(_ status: Plan.Status) {
        let all = status.models ?? []
        // A model only for Dream Plus is one the server would swap for the default, so it isn't
        // offered to anyone else.
        let usable = all.filter { !$0.plus || status.isPlus }
        models = usable.isEmpty ? Array(all.prefix(1)) : usable
        levels = status.thinking ?? []
    }

    /// The signed-in account's options, when there's something to choose: more than one model, or
    /// thinking levels. Nil otherwise, so a free account with one model sees nothing extra.
    @MainActor static var offered: ModelOptions? {
        guard let status = Plan.shared.status else { return nil }
        let options = ModelOptions(status)
        return options.canChoose ? options : nil
    }

    var canChooseModel: Bool { models.count > 1 }

    /// With only one model and it's Auto, the server decides the thinking too.
    var canChoose: Bool { canChooseModel || hasThinking(with: models.first) }

    /// The model pages are made with: the pick, or the default when nothing's picked or the pick
    /// is no longer offered (a lapsed plan, a retired model, Auto taken off the list).
    func model(picked: String) -> Plan.Status.ModelOption? {
        models.first { $0.id == picked } ?? models.first
    }

    /// Whether a thinking level goes with this model. Not with Auto, which picks its own.
    func hasThinking(with model: Plan.Status.ModelOption?) -> Bool {
        !levels.isEmpty && model?.isAuto != true
    }

    /// What's stored for a pick: nothing for the default, so someone who never moved off it
    /// follows the server's default when that changes; Auto always by name, since picking it is
    /// a choice to let the server decide.
    func stored(_ model: Plan.Status.ModelOption) -> String {
        model.id == models.first?.id && !model.isAuto ? "" : model.id
    }
}

extension Plan.Status.ModelOption {
    var isAuto: Bool { id == ModelChoice.auto }
}

/// Above the composer and the change bar, for an account that can choose: the model that will
/// make the page, with how long it thinks drawn as rising bars beside it, or a spark for Auto,
/// which decides both. Tapping it opens the picker.
struct ModelChip: View {
    let options: ModelOptions
    let palette: Palette
    /// The field beside it. If it had the keyboard when the picker opened, it gets it back after.
    var focus: FocusState<Bool>.Binding?

    @AppStorage(ModelChoice.key) private var picked = ""
    @AppStorage(ThinkingChoice.key) private var level = ThinkingChoice.standard
    @State private var picking = false
    @State private var wasFocused = false
    @ScaledMetric(relativeTo: .footnote) private var barHeight: CGFloat = 11

    var body: some View {
        let model = options.model(picked: picked)
        let thinking = options.hasThinking(with: model) ? ThinkingChoice.shown(level, among: options.levels) : nil
        Button {
            wasFocused = focus?.wrappedValue ?? false
            picking = true
        } label: {
            HStack(spacing: 7) {
                if model?.isAuto == true {
                    Image(systemName: "sparkles")
                        .foregroundStyle(palette.gradient)
                }
                Text(model?.name ?? "Thinking")
                    .lineLimit(1)
                if let thinking {
                    let count = options.levels.count
                    ThinkingBars(count: count, filled: (options.levels.firstIndex(of: thinking) ?? 0) + 1, palette: palette, spacing: barHeight * 0.18)
                        .frame(width: barHeight * (0.3 * CGFloat(count) + 0.18 * CGFloat(count - 1)), height: barHeight)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Model")
        .accessibilityValue(spoken(model, thinking))
        .accessibilityHint("Chooses the model that makes the page, and how long it thinks")
        .popover(isPresented: $picking) {
            ModelPicker(options: options, palette: palette)
                .presentationCompactAdaptation(.popover)
                .onDisappear {
                    if wasFocused { focus?.wrappedValue = true }
                }
        }
    }

    private func spoken(_ model: Plan.Status.ModelOption?, _ thinking: String?) -> String {
        let name = model?.name ?? ""
        guard let thinking else { return name }
        return name.isEmpty ? "Thinking \(ThinkingChoice.name(thinking))" : "\(name), thinking \(ThinkingChoice.name(thinking))"
    }
}

/// The picker the chip opens, in a glass popover: each model the account can use with its line on
/// what it's good for, then how long it thinks. Picking Auto folds the thinking away, since Auto
/// decides it page by page.
private struct ModelPicker: View {
    let options: ModelOptions
    let palette: Palette

    @AppStorage(ModelChoice.key) private var picked = ""
    @Namespace private var marker
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 300
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = options.model(picked: picked)
        VStack(alignment: .leading, spacing: 0) {
            if options.canChooseModel {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(options.models) { model in
                                row(model, isPicked: model.id == current?.id)
                                    .id(model.id)
                            }
                        }
                        .padding(8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // A long list (testers see every model) opens at the pick.
                    .onAppear {
                        if let current { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
                .frame(maxHeight: 380)
            }
            if options.hasThinking(with: current) {
                if options.canChooseModel {
                    Divider()
                        .padding(.horizontal, 20)
                }
                ThinkingControl(levels: options.levels, palette: palette)
                    .padding(20)
                    .transition(.opacity)
            }
        }
        .frame(width: min(width, 360))
        .animation(reduceMotion ? nil : .smooth, value: picked)
    }

    /// The pick is marked by a wash that slides to the row picked, and a check. With nothing to
    /// pick beside it (Auto, or a plan without thinking levels), the picker closes once that's shown.
    private func row(_ model: Plan.Status.ModelOption, isPicked: Bool) -> some View {
        Button {
            picked = options.stored(model)
            if !options.hasThinking(with: model) {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    dismiss()
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                    if !model.note.isEmpty {
                        Text(model.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(palette.gradient)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(CardRowStyle(palette: palette))
        .background {
            if isPicked {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.wash)
                    .matchedGeometryEffect(id: "picked", in: marker)
            }
        }
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// How long the model thinks: bars rising from left to right, one for each level offered. Tap a
/// bar, or slide along them, and the ones up to it fill with the palette; the level's name and
/// what it's like are said beside and below.
private struct ThinkingControl: View {
    let levels: [String]
    let palette: Palette

    @AppStorage(ThinkingChoice.key) private var level = ThinkingChoice.standard
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 30

    var body: some View {
        let current = ThinkingChoice.shown(level, among: levels) ?? ThinkingChoice.standard
        let index = levels.firstIndex(of: current) ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Thinking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(ThinkingChoice.name(current))
                    .font(.display(.subheadline, weight: .semibold))
                    .foregroundStyle(palette.gradient)
                    .contentTransition(.opacity)
            }
            GeometryReader { geometry in
                ThinkingBars(count: levels.count, filled: index + 1, palette: palette, spacing: 6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let slot = geometry.size.width / CGFloat(max(levels.count, 1))
                                let touched = min(max(Int(drag.location.x / slot), 0), levels.count - 1)
                                if levels[touched] != current { level = levels[touched] }
                            })
            }
            .frame(height: barHeight)
            Text(ThinkingChoice.note(current))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.smooth(duration: 0.25), value: current)
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
        .accessibilityValue(ThinkingChoice.name(current))
        .accessibilityHint(ThinkingChoice.note(current))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < levels.count { level = levels[index + 1] }
            case .decrement: if index > 0 { level = levels[index - 1] }
            @unknown default: break
            }
        }
    }
}

/// How long the model thinks, as bars rising from left to right, one for each level offered, with
/// the ones up to the pick filled in the palette. Small beside the model's name, large in the picker.
struct ThinkingBars: View {
    let count: Int
    /// How many bars are filled: the picked level's place, counting from one.
    let filled: Int
    let palette: Palette
    var spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = max((size.width - spacing * CGFloat(count - 1)) / CGFloat(max(count, 1)), 1)
            ZStack(alignment: .bottomLeading) {
                bars(width: width, height: size.height) { _ in palette.edge }
                // One gradient across the whole row, showing through the filled bars.
                palette.gradient
                    .mask(alignment: .bottomLeading) {
                        bars(width: width, height: size.height) { index in index < filled ? .black : .clear }
                    }
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(.smooth(duration: 0.25), value: filled)
        .accessibilityHidden(true)
    }

    private func bars(width: CGFloat, height: CGFloat, fill: @escaping (Int) -> Color) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: min(width / 2, 5), style: .continuous)
                    .fill(fill(index))
                    .frame(width: width, height: height * Self.rise(index, of: count))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// Each bar's height as a share of the tallest: the first under a third, rising evenly.
    private static func rise(_ index: Int, of count: Int) -> CGFloat {
        count > 1 ? 0.3 + 0.7 * CGFloat(index) / CGFloat(count - 1) : 1
    }
}
