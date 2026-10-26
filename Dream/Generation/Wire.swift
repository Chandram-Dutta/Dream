import Foundation
import FoundationModels

// What the model generates. Kept apart from the app's own types so the schema the model
// sees (descriptions, order, wording) can be tuned without touching storage.
// Properties are generated in declaration order, so names come before anything that uses them.

// MARK: - Planning (steps)

@Generable
struct WirePlan {
    @Guide(description: "A subject to look up in an encyclopedia so the facts are right, as a short title like Eiffel Tower or Compound interest. If there's a photo, name what's in it. Empty if nothing needs looking up.")
    var lookup: String
    // A yes or no first: the small model skips calculations more often when it only has a blank to fill.
    @Guide(description: "True if trying numbers would help the user: money, interest, costs, amounts, time, sizes, or how a formula behaves. False when the numbers are facts to know, like a population, a date or a death toll.")
    var calculate: Bool
    @Guide(description: "What to calculate, in a few words. Empty if calculate is false.")
    var calculation: String
}

@Generable
struct WireEditPlan {
    @Guide(description: "A new subject to look up, only if the change needs facts the screen doesn't have. Otherwise empty.")
    var lookup: String
    @Guide(description: "If the change adds or alters what the screen calculates, the new calculation in a few words. Otherwise empty.")
    var calculation: String
    @Guide(description: "True only if the user wants the calculation taken off the screen")
    var removeCalculation: Bool
}

// MARK: - Calculation

@Generable
enum WireFormat { case number, integer, currency, percent, toggle, choice }

@Generable
enum WireAccent { case blue, teal, green, mint, orange, pink, purple, indigo, red, yellow, cyan, brown }

@Generable
enum WireRole { case adjustable, given, variable }

@Generable
struct WireInput {
    @Guide(description: "camelCase name used in formulas, e.g. billAmount")
    var name: String
    @Guide(description: "Short label the user sees")
    var label: String
    @Guide(description: "adjustable: the user sets it. given: a fixed known value the formulas need, shown but never changed. variable: what a chart runs along, like time or x")
    var role: WireRole
    @Guide(description: "How it's written in an equation, in LaTeX, like x, \\theta or v_0. Empty for everyday quantities.")
    var symbol: String
    var format: WireFormat
    @Guide(description: "Realistic starting value")
    var initial: Double
    var min: Double
    var max: Double
    var step: Double
    @Guide(description: "Option labels for choice; otherwise empty")
    var options: [String]
}

@Generable
struct WireOutput {
    @Guide(description: "camelCase name")
    var name: String
    @Guide(description: "Short label the user sees")
    var label: String
    @Guide(description: "How it's written in an equation, in LaTeX. Empty for everyday quantities.")
    var symbol: String
    @Guide(description: "Formula using input names and earlier output names")
    var formula: String
    var format: WireFormat
}

@Generable(description: "The calculation behind an interactive screen")
struct WireLogic {
    @Guide(description: "2 to 4 words")
    var title: String
    @Guide(description: "SF Symbols name, e.g. fork.knife, house.fill, car.fill, figure.run")
    var symbol: String
    var accent: WireAccent
    @Guide(description: "Values the user knows or wants to try", .count(1...7))
    var inputs: [WireInput]
    @Guide(description: "Results calculated from the inputs, main result first", .count(1...5))
    var outputs: [WireOutput]
}

// MARK: - Screen

@Generable
enum WireBlockKind {
    case hero, metric, slider, stepper, field, toggle, picker, chart
    case paragraph, facts, bullets, steps, timeline, stat, equation, data
    case section, row
}

@Generable
struct WireItem {
    @Guide(description: "facts: the name, like Height. timeline: the date. stat: the number. data: the year or category. equation: a symbol, in LaTeX. Otherwise empty.")
    var label: String
    @Guide(description: "The text. data: a plain number.")
    var value: String
}

@Generable(description: "One block of the screen")
struct WireBlock {
    var kind: WireBlockKind
    @Guide(description: "Short heading, or empty")
    var title: String
    @Guide(description: "paragraph: 2 or 3 sentences, with maths as $...$ and {name} for a live value. equation: LaTeX, without $. Otherwise empty.")
    var text: String
    @Guide(description: "The input or output this block edits or shows. chart: outputs to plot, separated by commas. equation: an output, to show its formula live. Empty for other information blocks.")
    var ref: String
    @Guide(description: "chart only: the variable or input along the bottom; otherwise empty")
    var over: String
    @Guide(description: "facts, bullets, steps, timeline, stat and data: the items. equation: what each symbol means. Otherwise empty.", .count(0...8))
    var items: [WireItem]
    @Guide(description: "section and row only: the blocks inside; otherwise empty", .count(0...8))
    var children: [WireBlock]
}

@Generable(description: "The screen that answers the user's request")
struct WireComposition {
    @Guide(description: "1 to 4 words")
    var title: String
    @Guide(description: "One sentence that answers the request directly")
    var summary: String
    @Guide(description: "SF Symbols name for the subject")
    var symbol: String
    var accent: WireAccent
    @Guide(.count(1...8))
    var blocks: [WireBlock]
    // A field rather than a block, so every screen has somewhere to go next.
    // No minimum: a model that has run out of ideas would otherwise stall, writing whitespace.
    @Guide(description: "3 to 6 nearby topics the user might explore next, as short titles", .maximumCount(6))
    var related: [String]
}

/// For screens without a calculation. Narrower than `WireComposition` on purpose: offered
/// fewer kinds of block, the small model writes richer pages.
@Generable
enum WireInfoKind { case paragraph, facts, bullets, steps, timeline, stat, equation, data }

@Generable(description: "One block of the page")
struct WireInfoBlock {
    var kind: WireInfoKind
    @Guide(description: "Short heading, or empty")
    var title: String
    @Guide(description: "paragraph: 2 or 3 sentences, with maths as $...$. equation: LaTeX, without $. Otherwise empty.")
    var text: String
    @Guide(description: "Items for facts, bullets, steps, timeline, stat and data, or what each symbol in an equation means; empty for paragraph", .count(0...8))
    var items: [WireItem]
}

@Generable(description: "A page that answers the user's request")
struct WireArticle {
    @Guide(description: "The subject, 1 to 4 words")
    var title: String
    @Guide(description: "One sentence that answers the request directly")
    var summary: String
    @Guide(description: "SF Symbols name for the subject")
    var symbol: String
    var accent: WireAccent
    @Guide(.count(1...6))
    var blocks: [WireInfoBlock]
    // No minimum: a model that has run out of ideas would otherwise stall, writing whitespace.
    @Guide(description: "3 to 6 nearby topics the user might explore next, as short titles", .maximumCount(6))
    var related: [String]
}

// MARK: - One pass (capable models)

@Generable(description: "A screen that answers the user's request: it can explain, calculate, or both")
struct WireSurface {
    @Guide(description: "1 to 4 words")
    var title: String
    @Guide(description: "One sentence that answers the request directly")
    var summary: String
    @Guide(description: "SF Symbols name for the subject")
    var symbol: String
    var accent: WireAccent
    // Before the inputs, so the model decides whether there's anything worth changing first.
    @Guide(description: "If changing numbers here would help the user, the question they'd explore, in their words, like 'How much will I save?' or 'How does the angle change the throw?'. Empty when they want facts: then there are no inputs or outputs.")
    var question: String
    @Guide(description: "The calculation's values, only if there's a question", .count(0...8))
    var inputs: [WireInput]
    @Guide(description: "Results calculated from the inputs, main result first", .count(0...6))
    var outputs: [WireOutput]
    @Guide(.count(1...12))
    var blocks: [WireBlock]
    // No minimum: a model that has run out of ideas would otherwise stall, writing whitespace.
    @Guide(description: "3 to 6 nearby topics the user might explore next, as short titles", .maximumCount(6))
    var related: [String]
}

// MARK: - Conversion

extension Surface {
    init(_ wire: WireSurface, reference: Reference?) {
        self.init(
            title: wire.title,
            summary: wire.summary,
            symbol: wire.symbol,
            accent: Accent(wire.accent),
            inputs: wire.inputs.map { Input($0) },
            outputs: wire.outputs.map { Output($0) },
            blocks: Block.list(wire.blocks),
            related: wire.related,
            reference: reference,
            question: wire.question.isEmpty ? nil : wire.question)
    }

    /// While the model is still writing: show whatever has arrived.
    init(partial wire: WireSurface.PartiallyGenerated, reference: Reference?) {
        self.init(
            title: wire.title ?? "",
            summary: wire.summary ?? "",
            symbol: wire.symbol ?? "sparkles",
            accent: wire.accent.map { Accent($0) } ?? .blue,
            inputs: (wire.inputs ?? []).compactMap { Input(partial: $0) },
            outputs: (wire.outputs ?? []).compactMap { Output(partial: $0) },
            blocks: Block.list(partial: wire.blocks ?? []),
            related: wire.related ?? [],
            reference: reference,
            question: wire.question.flatMap { $0.isEmpty ? nil : $0 })
    }

    func with(_ logic: WireLogic) -> Surface {
        var surface = self
        surface.title = logic.title
        surface.symbol = logic.symbol
        surface.accent = Accent(logic.accent)
        surface.inputs = logic.inputs.map { Input($0) }
        surface.outputs = logic.outputs.map { Output($0) }
        return surface
    }

    func with(partial logic: WireLogic.PartiallyGenerated) -> Surface {
        var surface = self
        surface.title = logic.title ?? ""
        surface.symbol = logic.symbol ?? "sparkles"
        surface.accent = logic.accent.map { Accent($0) } ?? .blue
        surface.inputs = (logic.inputs ?? []).compactMap { Input(partial: $0) }
        surface.outputs = (logic.outputs ?? []).compactMap { Output(partial: $0) }
        return surface
    }

    func with(_ composition: WireComposition) -> Surface {
        var surface = self
        surface.title = composition.title
        surface.summary = composition.summary
        surface.symbol = composition.symbol
        surface.accent = Accent(composition.accent)
        surface.blocks = Block.list(composition.blocks)
        surface.related = composition.related
        return surface
    }

    /// Keeps what's already known (like the calculation's title) until the composition replaces it.
    func with(partial composition: WireComposition.PartiallyGenerated) -> Surface {
        var surface = self
        if let title = composition.title, !title.isEmpty { surface.title = title }
        surface.summary = composition.summary ?? ""
        if let symbol = composition.symbol { surface.symbol = symbol }
        if let accent = composition.accent { surface.accent = Accent(accent) }
        surface.blocks = Block.list(partial: composition.blocks ?? [])
        surface.related = composition.related ?? []
        return surface
    }

    func with(_ article: WireArticle) -> Surface {
        var surface = self
        surface.title = article.title
        surface.summary = article.summary
        surface.symbol = article.symbol
        surface.accent = Accent(article.accent)
        surface.blocks = article.blocks.enumerated().map { index, block in
            Block(id: "block-\(index)", kind: BlockKind(rawValue: String(describing: block.kind)) ?? .paragraph, title: block.title, text: block.text,
                  items: block.items.map { Item(label: $0.label, value: $0.value) })
        }
        surface.related = article.related
        return surface
    }

    func with(partial article: WireArticle.PartiallyGenerated) -> Surface {
        var surface = self
        if let title = article.title, !title.isEmpty { surface.title = title }
        surface.summary = article.summary ?? ""
        if let symbol = article.symbol { surface.symbol = symbol }
        if let accent = article.accent { surface.accent = Accent(accent) }
        surface.blocks = (article.blocks ?? []).enumerated().compactMap { index, block in
            guard let kind = block.kind else { return nil }
            return Block(id: "block-\(index)", kind: BlockKind(rawValue: String(describing: kind)) ?? .paragraph, title: block.title ?? "", text: block.text ?? "",
                         items: (block.items ?? []).map { Item(label: $0.label ?? "", value: $0.value ?? "") })
        }
        surface.related = article.related ?? []
        return surface
    }

    /// Used when the model won't compose a screen: the source's own words, unedited.
    func withSourceText(of reference: Reference, related: [String]) -> Surface {
        var surface = self
        if surface.title.isEmpty { surface.title = reference.title }
        if surface.symbol == "sparkles" { surface.symbol = "book.closed" }
        let paragraphs = reference.extract.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        surface.blocks = paragraphs.prefix(hasLogic ? 1 : 3).enumerated().map { index, text in
            Block(id: "block-\(index)", kind: .paragraph, text: text)
        }
        surface.related = related
        return surface
    }
}

extension Block {
    /// Ids are positions, so blocks keep their identity while they stream in.
    static func list(_ wires: [WireBlock], prefix: String = "block") -> [Block] {
        wires.enumerated().map { index, wire in Block(wire, id: "\(prefix)-\(index)") }
    }

    static func list(partial wires: [WireBlock.PartiallyGenerated], prefix: String = "block") -> [Block] {
        wires.enumerated().compactMap { index, wire in Block(partial: wire, id: "\(prefix)-\(index)") }
    }

    init(_ wire: WireBlock, id: String) {
        self.init(
            id: id,
            kind: BlockKind(rawValue: String(describing: wire.kind)) ?? .paragraph,
            title: wire.title,
            text: wire.text,
            ref: wire.ref,
            over: wire.over,
            items: wire.items.map { Item(label: $0.label, value: $0.value) },
            children: Block.list(wire.children, prefix: id))
    }

    init?(partial wire: WireBlock.PartiallyGenerated, id: String) {
        guard let kind = wire.kind else { return nil }
        self.init(
            id: id,
            kind: BlockKind(rawValue: String(describing: kind)) ?? .paragraph,
            title: wire.title ?? "",
            text: wire.text ?? "",
            ref: wire.ref ?? "",
            over: wire.over ?? "",
            items: (wire.items ?? []).map { Item(label: $0.label ?? "", value: $0.value ?? "") },
            children: Block.list(partial: wire.children ?? [], prefix: id))
    }
}

extension Accent {
    init(_ wire: WireAccent) {
        self = Accent(rawValue: String(describing: wire)) ?? .blue
    }
}

extension InputRole {
    init(_ wire: WireRole) {
        self = InputRole(rawValue: String(describing: wire)) ?? .adjustable
    }
}

extension Format {
    init(_ wire: WireFormat) {
        self = Format(rawValue: String(describing: wire)) ?? .number
    }
}

extension Input {
    init(_ wire: WireInput) {
        self.init(name: wire.name, label: wire.label, format: Format(wire.format), initial: wire.initial,
                  min: wire.min, max: wire.max, step: wire.step, options: wire.options,
                  role: InputRole(wire.role), symbol: wire.symbol)
    }

    init?(partial wire: WireInput.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        let initial = wire.initial ?? 0
        let lowest = wire.min ?? Swift.min(0, initial)
        self.init(
            name: name,
            label: wire.label ?? "",
            format: wire.format.map { Format($0) } ?? .number,
            initial: initial,
            min: lowest,
            max: wire.max ?? Swift.max(lowest + 1, initial * 2),
            step: wire.step ?? 0,
            options: wire.options ?? [],
            role: wire.role.map { InputRole($0) } ?? .adjustable,
            symbol: wire.symbol ?? "")
    }
}

extension Output {
    init(_ wire: WireOutput) {
        self.init(name: wire.name, label: wire.label, formula: wire.formula, format: Format(wire.format), symbol: wire.symbol)
    }

    init?(partial wire: WireOutput.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(name: name, label: wire.label ?? "", formula: wire.formula ?? "", format: wire.format.map { Format($0) } ?? .number, symbol: wire.symbol ?? "")
    }
}
