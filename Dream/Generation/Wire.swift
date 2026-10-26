import Foundation
import FoundationModels

// What the model generates. Kept apart from the app's own types so the schema the model
// sees (descriptions, order, wording) can be tuned without touching storage.
// Properties are generated in declaration order, so names come before anything that uses them.

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

// MARK: - Surface

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
