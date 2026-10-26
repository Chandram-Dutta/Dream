import SwiftMath
import SwiftUI
import UIKit

/// LaTeX, typeset by SwiftMath into template images: maths takes the colour of whatever it sits
/// in, a gradient included, and lines up with the text around it.
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: UIImage
        /// How far the maths reaches below the baseline, padding included.
        let descent: CGFloat
        /// Space added around the ink, so italic overhangs aren't clipped.
        static let padding: CGFloat = 1.5
    }

    /// A sans math face, so equations belong with SF Pro but keep their italic variables.
    private static let fontName = MathFont.leteSansFont.rawValue
    private static var cache: [String: Rendered] = [:]
    private static var failed: Set<String> = []

    static func render(_ latex: String, size: CGFloat, display: Bool) -> Rendered? {
        let tex = TeX.compatible(latex)
        let key = "\(display ? "d" : "t")\(size)|\(tex)"
        if let hit = cache[key] { return hit }
        guard !failed.contains(key) else { return nil }
        if cache.count > 500 { cache.removeAll() }

        let label = MTMathUILabel()
        label.font = MTFontManager.manager.font(withName: fontName, size: size)
        label.labelMode = display ? .display : .text
        label.textColor = .black
        label.latex = tex
        guard label.error == nil else {
            failed.insert(key)
            return nil
        }
        let padding = Rendered.padding
        label.contentInsets = UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        label.textAlignment = .left
        label.frame = CGRect(origin: .zero, size: label.intrinsicContentSize)
        label.layoutSubviews()
        guard var list = label.displayList, list.width > 0 else {
            failed.insert(key)
            return nil
        }
        // The label centres very short maths (a lone minus) in half a line; give it that room,
        // so the baseline still sits at the descent.
        if list.ascent + list.descent < size / 2 {
            label.frame.size.height = size / 2 + padding * 2
            label.layoutSubviews()
            list = label.displayList ?? list
        }
        let canvas = CGSize(width: ceil(label.frame.width), height: ceil(label.frame.height))
        let image = UIGraphicsImageRenderer(size: canvas).image { context in
            // SwiftMath draws with y going up.
            context.cgContext.translateBy(x: 0, y: canvas.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            list.draw(context.cgContext)
        }
        let rendered = Rendered(image: image.withRenderingMode(.alwaysTemplate), descent: list.descent + padding)
        cache[key] = rendered
        return rendered
    }

    /// The point size of a text style at the reader's text size, so maths matches its line.
    static func size(of style: UIFont.TextStyle, _ dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        // Math faces run a little small beside SF Pro.
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize * 1.08
    }
}

/// A displayed equation. Wider than the screen, it scrolls sideways rather than shrinking.
struct MathView: View {
    let latex: String
    let size: CGFloat

    var body: some View {
        if let rendered = MathRenderer.render(latex, size: size, display: true) {
            ScrollView(.horizontal) {
                Image(uiImage: rendered.image)
                    .renderingMode(.template)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .accessibilityElement()
            .accessibilityLabel(TeX.spoken(latex))
        } else {
            Text(verbatim: latex)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Text with live values (`{name}`) and inline maths (`$...$`), set as one wrapping paragraph.
/// Without a calculation, placeholders show as their names.
struct RichText: View {
    let text: String
    var context: RenderContext?
    /// The style the caller sets the text in, so maths is the same size.
    var style: UIFont.TextStyle = .body

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let mathSize = MathRenderer.size(of: style, dynamicTypeSize)
        return Placeholders.parts(text).reduce(Text(verbatim: "")) { text, part in
            switch part {
            case .text(let string):
                return Text("\(text)\(string)")
            case .name(let name):
                guard let context else { return Text("\(text)\(name)") }
                let value = Text(context.surface.display(name, context.value(name))).fontWeight(.semibold).foregroundStyle(context.accent)
                return Text("\(text)\(value)")
            case .math(let tex):
                let filled = context.map { $0.surface.filled(tex, values: $0.evaluation.values) } ?? tex
                guard let rendered = MathRenderer.render(filled, size: mathSize, display: false) else {
                    return Text("\(text)\(Text(verbatim: tex).italic())")
                }
                let math = Text(Image(uiImage: rendered.image).renderingMode(.template))
                    .baselineOffset(-rendered.descent)
                    .accessibilityLabel(TeX.spoken(filled))
                return Text("\(text)\(math)")
            }
        }
    }
}

/// An equation block. Pointed at an output, it shows that output's own formula, and beneath
/// it the same formula worked through with the reader's numbers, live, lined up on the equals
/// sign. Otherwise it shows the LaTeX the model wrote. Either way, symbols are explained below.
struct EquationBlockView: View {
    let block: Block
    let context: RenderContext

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 25

    var body: some View {
        let surface = context.surface
        VStack(alignment: .leading, spacing: 12) {
            if !block.title.isEmpty {
                RichText(text: block.title, context: context, style: .title3)
                    .font(.display(.title3))
            }
            if !block.ref.isEmpty, let equation = surface.equation(for: block.ref) {
                VStack(alignment: .leading, spacing: 6) {
                    MathView(latex: equation, size: size)
                    if let worked = surface.workedEquation(for: block.ref, values: context.evaluation.values) {
                        MathView(latex: worked, size: size)
                            .foregroundStyle(context.palette.numberGradient)
                            .padding(.leading, indent(before: surface.texSymbol(block.ref)))
                            .animation(.snappy, value: worked)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(surface.spokenEquation(for: block.ref) ?? "")
                .accessibilityValue(surface.display(block.ref, context.value(block.ref)))
            } else {
                MathView(latex: surface.filled(block.text, values: context.evaluation.values), size: size)
            }
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The width of the left-hand side and the space before `=`, so the worked line's `=`
    /// sits under the equation's.
    private func indent(before symbol: String) -> CGFloat {
        guard let rendered = MathRenderer.render(symbol, size: size, display: true) else { return 0 }
        return rendered.image.size.width - MathRenderer.Rendered.padding * 2 + size * 5 / 18
    }

    /// What each symbol stands for: what the model wrote, or for a calculated equation, the
    /// labels of the symbols in it.
    private var symbols: [Item] {
        if !block.items.isEmpty { return block.items }
        let surface = context.surface
        guard let output = surface.output(block.ref), let expr = try? FormulaCache.parse(output.formula) else { return [] }
        let names = [output.name] + surface.inputs.map(\.name).filter(expr.names.contains) + surface.outputs.map(\.name).filter(expr.names.contains)
        var seen: Set<String> = []
        return names.compactMap { name in
            let symbol = (surface.input(name)?.symbol ?? surface.output(name)?.symbol ?? "")
            guard !symbol.isEmpty, seen.insert(symbol).inserted else { return nil }
            return Item(label: symbol, value: surface.label(of: name))
        }
    }

    @ViewBuilder private var legend: some View {
        let items = symbols
        if items.count > 1 || (items.count == 1 && block.ref.isEmpty) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    GridRow {
                        RichText(text: "$\(item.label)$", context: context, style: .callout)
                            .font(.callout)
                            .foregroundStyle(context.palette.accent)
                            .gridColumnAlignment(.trailing)
                        RichText(text: item.value, context: context, style: .callout)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
