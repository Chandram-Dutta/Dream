import SwiftUI

/// The first thing someone sees. Rather than describe Dream, it shows it: a request types itself
/// in and becomes a small working page (a bill to split, the distance to the horizon, a week's
/// groceries) that answers to the finger. Then it asks them to sign in, which Dream needs.
struct WelcomeView: View {
    private let account = Account.shared
    @State private var demo = Demo.bill
    /// Once they've touched a demo, it stays put.
    @State private var exploring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let summary = account.offeredMove {
            MoveQuestion(summary: summary)
                .background(alignment: .top) {
                    Aura(palette: Palette.now, energy: 0.08)
                        .frame(height: 620)
                }
                .background(Color(.systemBackground).ignoresSafeArea())
                .transition(.blurReplace)
        } else {
            welcome
        }
    }

    private var welcome: some View {
        let palette = demo.accent.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dream")
                        .font(.display(.largeTitle, weight: .bold))
                    Text("Ask for anything, and get a page that explains it, works it out, or both.")
                        .font(.display(.title3, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 28)
                if let notice = account.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.subheadline)
                        .panel(palette)
                }
                DemoStage(demo: demo, exploring: $exploring)
                    .id(demo)
                    .transition(.blurReplace)
                demoPicker(palette)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) {
            Aura(palette: palette, energy: 0.12)
                .frame(height: 620)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { signIn }
        .task(id: exploring) {
            // A new demo every little while, until they start playing with one.
            guard !exploring, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled, !exploring else { return }
                withAnimation(.smooth(duration: 0.6)) { demo = demo.next }
            }
        }
    }

    private func demoPicker(_ palette: Palette) -> some View {
        HStack(spacing: 8) {
            ForEach(Demo.allCases, id: \.self) { each in
                Button {
                    exploring = true
                    withAnimation(.smooth(duration: 0.6)) { demo = each }
                } label: {
                    Capsule()
                        .fill(each == demo ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(width: each == demo ? 22 : 8, height: 8)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(each.request)
                .accessibilityAddTraits(each == demo ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: demo)
    }

    private var signIn: some View {
        VStack(spacing: 12) {
            SignInButton()
            Text("Your account keeps your pages, lists and what Dream knows, on any iPhone you sign in on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background {
            // The page fades out under the buttons rather than ending at a line.
            LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0), location: 0), .init(color: Color(.systemBackground), location: 0.3)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Demos

private enum Demo: CaseIterable {
    case bill, horizon, groceries

    var accent: Accent {
        switch self {
        case .bill: .orange
        case .horizon: .indigo
        case .groceries: .green
        }
    }

    var request: String {
        switch self {
        case .bill: "Split a \(BillDemo.total.formatted(.currency(code: BillDemo.currency).precision(.fractionLength(0)))) bill four ways, with a tip"
        case .horizon: "How far away is the horizon?"
        case .groceries: "A grocery list for the week"
        }
    }

    var next: Demo {
        let all = Demo.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// One demo: the request typing itself in, then the page it makes.
private struct DemoStage: View {
    let demo: Demo
    @Binding var exploring: Bool
    @State private var typed = 0
    @State private var formed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = demo.accent.palette
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                // The whole request, unseen, holds the space while it types, so nothing below jumps.
                Text(demo.request)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        Text(String(demo.request.prefix(typed)))
                    }
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(palette.gradient, in: .circle)
                    .opacity(typed >= demo.request.count ? 1 : 0.35)
            }
            .padding(.leading, 16)
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Asking: \(demo.request)")

            Group {
                switch demo {
                case .bill: BillDemo(palette: palette, exploring: $exploring)
                case .horizon: HorizonDemo(palette: palette, exploring: $exploring)
                case .groceries: GroceriesDemo(palette: palette, exploring: $exploring)
                }
            }
            .opacity(formed ? 1 : 0)
            .blur(radius: formed ? 0 : 12)
            .scaleEffect(formed ? 1 : 0.97, anchor: .top)
        }
        .task {
            guard !reduceMotion else {
                typed = demo.request.count
                formed = true
                return
            }
            for count in 0...demo.request.count {
                typed = count
                try? await Task.sleep(for: .milliseconds(32))
            }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.smooth(duration: 0.7)) { formed = true }
        }
    }
}

/// A page's title line, as surfaces show theirs.
private struct DemoTitle: View {
    let text: String
    let symbol: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(palette.gradient)
            Text(text)
                .font(.display(.headline))
        }
    }
}

private struct BillDemo: View {
    let palette: Palette
    @Binding var exploring: Bool
    @State private var tip = 10.0

    static let currency = Locale.current.currency?.identifier ?? "USD"
    static let total = 240.0

    var body: some View {
        let each = Self.total * (1 + tip / 100) / 4
        VStack(alignment: .leading, spacing: 16) {
            DemoTitle(text: "Splitting the bill", symbol: "fork.knife", palette: palette)
            VStack(alignment: .leading, spacing: 2) {
                Text("Each of you pays")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(each, format: .currency(code: Self.currency))
                    .font(.display(size: 44, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.numberGradient)
                    .contentTransition(.numericText(value: each))
                    .animation(.snappy, value: each)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tip").foregroundStyle(.secondary)
                    Spacer()
                    Text((tip / 100).formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: tip))
                }
                DreamSlider(value: $tip.noticing { exploring = true }, range: 0...25, step: 1, palette: palette)
            }
        }
        .panel(palette)
    }
}

private struct HorizonDemo: View {
    let palette: Palette
    @Binding var exploring: Bool
    @State private var height = 1.7

    var body: some View {
        // The Earth is round: from h above it, the horizon is √(2Rh + h²) away.
        let earth = 6_371_000.0
        let distance = (2 * earth * height + height * height).squareRoot()
        VStack(alignment: .leading, spacing: 14) {
            DemoTitle(text: "Seeing to the horizon", symbol: "eye", palette: palette)
            HorizonFigure(height: height, palette: palette)
                .frame(height: 110)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The horizon is")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Measurement(value: distance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1)))))
                    .font(.display(size: 44, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.numberGradient)
                    .contentTransition(.numericText(value: distance))
                    .animation(.snappy, value: distance)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Your eyes are").foregroundStyle(.secondary)
                    Spacer()
                    Text(Measurement(value: height, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))) + " up")
                        .monospacedDigit()
                }
                DreamSlider(value: $height.noticing { exploring = true }, range: 1...100, step: 0.5, palette: palette)
            }
        }
        .panel(palette)
    }
}

/// A slice of the Earth, someone standing on it (taller than life), and their line of sight
/// grazing the curve at the horizon. The higher they stand, the further along it touches.
private struct HorizonFigure: View {
    let height: Double
    let palette: Palette

    var body: some View {
        Canvas { context, size in
            let radius = size.width * 1.6
            let center = CGPoint(x: size.width / 2, y: size.height - 12 + radius)
            let lift = 8 + 44 * (height / 100).squareRoot()
            // Where they stand, as an angle from straight up.
            let stand = asin((size.width * 0.14 - size.width / 2) / radius)
            let reach = acos(radius / (radius + lift))
            func point(_ angle: Double, _ distance: Double) -> CGPoint {
                CGPoint(x: center.x + distance * sin(angle), y: center.y - distance * cos(angle))
            }
            let ground = point(stand, radius)
            let eye = point(stand, radius + lift)
            let horizon = point(stand + reach, radius)

            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(palette.accent.opacity(0.12)))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(palette.accent.opacity(0.5)), lineWidth: 1.5)
            var sight = Path()
            sight.move(to: eye)
            sight.addLine(to: CGPoint(x: horizon.x + (horizon.x - eye.x) * 0.25, y: horizon.y + (horizon.y - eye.y) * 0.25))
            context.stroke(sight, with: .linearGradient(Gradient(colors: [palette.accent, palette.companion.opacity(0.2)]), startPoint: eye, endPoint: horizon), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            var stance = Path()
            stance.move(to: ground)
            stance.addLine(to: eye)
            context.stroke(stance, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: eye.x - 5, y: eye.y - 5, width: 10, height: 10)), with: .linearGradient(Gradient(colors: [palette.accent, palette.companion]), startPoint: CGPoint(x: eye.x - 5, y: eye.y), endPoint: CGPoint(x: eye.x + 5, y: eye.y)))
            context.stroke(Path(ellipseIn: CGRect(x: horizon.x - 4, y: horizon.y - 4, width: 8, height: 8)), with: .color(palette.accent), lineWidth: 2)
        }
        .animation(.snappy, value: height)
    }
}

private struct GroceriesDemo: View {
    let palette: Palette
    @Binding var exploring: Bool
    @State private var items: [(name: String, done: Bool)] = [("Milk", true), ("Eggs", false), ("Spinach", false), ("Rice", false), ("Bananas", false)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let left = items.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                DemoTitle(text: "This week's groceries", symbol: "cart", palette: palette)
                Spacer()
                Text("\(left) left")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.numberGradient)
                    .contentTransition(.numericText(value: Double(left)))
            }
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    Button {
                        exploring = true
                        withAnimation(.snappy) { items[index].done.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: items[index].done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(items[index].done ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                                .contentTransition(.symbolEffect(.replace))
                            Text(items[index].name)
                                .strikethrough(items[index].done, color: .secondary)
                                .foregroundStyle(items[index].done ? .secondary : .primary)
                            Spacer()
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(items[index].done ? .isSelected : [])
                    if index < items.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
        .panel(palette)
        .sensoryFeedback(.selection, trigger: left)
        .task {
            // Ticks one off by itself, to show it's a list you use.
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(2.6))
            guard !exploring else { return }
            withAnimation(.snappy) { items[1].done = true }
        }
    }
}

private extension Binding where Value == Double {
    /// The same value, noticing when the user moves it.
    func noticing(_ action: @escaping () -> Void) -> Binding<Double> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}
