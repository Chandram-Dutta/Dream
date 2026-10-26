import Foundation

/// Everything the model is told. The core rules live here. Each feature's own rules live in its
/// own file (`Prompts+Lists.swift` and so on) and are gathered in `featureRules`, so a feature can
/// change what it teaches the model without touching this file or any other feature.
enum Prompts {
    // MARK: - Core rules

    /// When numbers deserve controls, so a fact never becomes a slider.
    private static let whenToCalculate = """
        Calculate only when changing numbers helps the user: their own figures (a bill, a loan, a trip), a decision, or a what-if worth exploring, like how the angle changes a throw or how a graph moves when a term changes. A number that's simply true is a fact, not an input: a population, a death toll, a date, a distance, a record. Show facts in facts, stat or data blocks, never on a slider, and don't invent a formula to restate or project them.
        """

    private static var formulaRules: String {
        """
        Each input has a role:
        - adjustable: the user sets it. Give it a realistic starting value, a sensible range and a step. Anything the user divides by (people, months, years, items) starts at 1 or more, with a minimum of at least 1.
        - given: a fixed, known value the formulas need, like gravity on Earth. Shown with its value, never changed; min and max equal it.
        - variable: what a chart runs along, like time t or x, over a range. Formulas use it like any input; the chart is its control.
        Outputs are results calculated from the inputs, main result first. A formula can use inputs and earlier outputs, never itself. If the user should type a value in, it's an input, not an output. When part of a formula has its own name in the maths, like n for periods per year, make it an output too, so each equation stays readable.
        Formulas use names, numbers, + - * / ^ ( ), comparisons (< <= > >= == !=) and condition ? a : b. Functions: min, max, round, floor, ceil, abs, sqrt, pow, exp, ln, log10, sin, cos, tan, asin, acos, atan, atan2, hypot, fact, choose. Angles are radians: sin(angle * pi / 180). Constants: pi, e. No units or symbols inside formulas.
        symbol: how a quantity is written in an equation, in LaTeX (c, \\theta, v_0), for maths and science. Empty for everyday quantities like a bill.
        Formats: currency for money, in \(Currency.code). percent for percentages, as whole numbers: 18 means 18%, so divide by 100 in formulas. integer for counts. number for anything else. toggle for yes or no (1 or 0). choice for one of a few options; its value is the option's position, starting at 0.
        """
    }

    private static let informationRules = """
        Information blocks:
        - paragraph: 2 or 3 plain sentences. {name} shows a live value from the calculation.
        - equation: one displayed equation, in LaTeX in text, with items saying what each symbol means (label: the symbol in LaTeX; value: its meaning). Or set ref to an output instead: it shows that output's formula typeset, worked through with the user's live numbers. Use ref whenever the screen calculates the equation.
        - facts: label and value pairs, like Height and 330 m.
        - bullets: short points. steps: how to do something, or the steps of a derivation or proof, in order.
        - timeline: dated events; the label is the date.
        - stat: one number that's striking on its own; the label is the number and the value says what it means.
        - data: real figures as a chart, to compare or follow over time. Label: the year or category. Value: a plain number. Title: what's measured, with its unit, like Population (millions). Use figures from the lookup.
        Maths is always LaTeX: inline between $ signs in any text, like $a^2 + b^2 = c^2$, and displayed in equation blocks. Never write maths as plain text like x^2 or sqrt(x).
        Use the kinds the subject calls for, usually 3 to 5 blocks: facts for key details, timeline for history, steps for how-tos, data for real figures. Never add a block just for variety.
        For maths and science, build understanding in order: what it is in words, the equation, what each symbol means, an example worked with live numbers, then the user exploring it, ideally on a chart.
        """

    private static let calculationRules = """
        Calculation blocks; ref is an exact input or output name:
        - hero: the main result, large. metric: another result, or a given. row: 2 or 3 metrics side by side.
        - slider (explore a range), stepper (small counts), field (exact amounts), toggle (yes or no), picker (choices): each edits one adjustable input.
        - chart: outputs (ref; several, separated by commas, to compare curves) plotted along a variable or input (over). Plot the thing itself: a wave over time, a function over x, a balance over the years, a ball's height over distance. The other inputs reshape the curve as the user moves them. Put a chart in the same section as the controls that shape it, chart first.
        - section: a card with a short heading that groups blocks.
        Every adjustable input gets one control, and every given and output is shown once.
        """

    private static let closingRules = "Lead with what answers the request. Keep text short. Then list related: 3 to 6 nearby topics to explore next."

    /// Each feature's rules, in the order the model reads them. Empty until the feature fills them in.
    private static var featureRules: [String] {
        [memoryRules, listRules, figureRules, soundRules, languageRules].filter { !$0.isEmpty }
    }

    // MARK: - Writing a surface

    static var surface: String {
        """
        You build one screen that answers the user's request. It can explain, let the user calculate, or both: whatever the request needs. Use the lookup tool whenever facts, numbers, dates or names matter, and take them only from what it returns.

        \(whenToCalculate)
        If there's something worth changing, write the question it answers, then the calculation. Otherwise leave question, inputs and outputs empty.
        \(formulaRules)

        Then compose the screen from blocks.
        \(informationRules)
        \(calculationRules)
        \(([closingRules] + featureRules).joined(separator: "\n\n"))
        """
    }

    /// What the model is told alongside each request about the user and their device. Each
    /// feature adds its own lines from its own file.
    static func context(for intent: String) async -> [String] {
        await memoryContext(for: intent) + languageContext()
    }

    static func surfaceRequest(_ intent: String, hasImage: Bool, context: [String]) -> String {
        var parts = ["Request: \(intent)"]
        if hasImage {
            parts.append("The user attached a photo. If they're asking what something is, identify it; if it shows amounts or items, use them as starting values.")
        }
        if !context.isEmpty {
            parts.append(context.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    static func repair(_ problems: [Issue]) -> String {
        """
        The calculation in that screen has problems:
        \(problems.map { "- \($0.message)" }.joined(separator: "\n"))

        Return the whole screen again with these problems fixed. Keep everything else the same.
        """
    }

    static func edit(intent: String, surface: Surface, instruction: String, focus: Block?, context: [String]) -> String {
        var parts = [
            """
            The user has this screen, made for "\(intent)":
            \(screen(surface))

            \(request(instruction, focus: focus, in: surface))

            Return the whole updated screen. Keep what they didn't ask to change.
            """,
        ]
        if !context.isEmpty {
            parts.append(context.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Pieces

    /// Calculation and blocks together, for showing the model a whole screen.
    private static func screen(_ surface: Surface) -> String {
        surface.hasLogic ? "\(surface.logicSummary)\nScreen:\n\(surface.outline)" : surface.outline
    }

    private static func request(_ instruction: String, focus: Block?, in surface: Surface) -> String {
        guard let focus else { return "About the whole screen, they say: \"\(instruction)\"" }
        return "They're pointing at \(describe(focus, in: surface)) and say: \"\(instruction)\""
    }

    static func describe(_ block: Block, in surface: Surface) -> String {
        switch block.kind {
        case .section:
            return "the section \"\(block.title)\" (#\(block.id))"
        case .row:
            return "a row of results (#\(block.id))"
        case .chart:
            return "the chart of \(block.refs.map { surface.label(of: $0) }.joined(separator: " and ")) along \(surface.label(of: block.over)) (#\(block.id))"
        case .hero, .metric, .slider, .stepper, .field, .toggle, .picker:
            return "the \(block.kind.rawValue) for \"\(surface.label(of: block.ref))\" (\(block.ref), #\(block.id))"
        case .list:
            return "the list of \(surface.label(of: block.ref).lowercased()) (\(block.ref), #\(block.id))"
        case .add:
            return "the bar for adding to \(surface.label(of: block.ref).lowercased()) (\(block.ref), #\(block.id))"
        case .equation where !block.ref.isEmpty:
            return "the equation for \"\(surface.label(of: block.ref))\" (\(block.ref), #\(block.id))"
        case .paragraph, .facts, .bullets, .steps, .timeline, .stat, .equation, .data:
            return "the \(block.kind.rawValue) block\(block.title.isEmpty ? "" : " \"\(block.title)\"") (#\(block.id))"
        }
    }
}

extension Surface {
    /// The calculation in the same shorthand the prompts use, which costs far fewer tokens than JSON.
    var logicSummary: String {
        var lines = ["Inputs:"]
        for input in inputs {
            switch input.format {
            case .toggle:
                lines.append("- \(input.name): \"\(input.label)\", toggle, starts \(input.initial != 0 ? "on" : "off")")
            case .choice:
                lines.append("- \(input.name): \"\(input.label)\", choice of \(input.options.joined(separator: " / ")), starts at option \(input.initial.plain)")
            default:
                let symbol = input.symbol.isEmpty ? "" : ", written \(input.symbol)"
                switch input.role {
                case .given:
                    lines.append("- \(input.name): \"\(input.label)\", given \(input.format.rawValue), \(input.initial.plain)\(symbol)")
                case .variable:
                    lines.append("- \(input.name): \"\(input.label)\", variable \(input.format.rawValue), \(input.min.plain) to \(input.max.plain)\(symbol)")
                case .adjustable:
                    lines.append("- \(input.name): \"\(input.label)\", \(input.format.rawValue), starts at \(input.initial.plain), \(input.min.plain) to \(input.max.plain), step \(input.step.plain)\(symbol)")
                }
            }
        }
        lines.append("Outputs:")
        for output in outputs {
            lines.append("- \(output.name): \"\(output.label)\", \(output.format.rawValue)\(output.symbol.isEmpty ? "" : ", written \(output.symbol)") = \(output.formula)")
        }
        return lines.joined(separator: "\n")
    }

    /// The screen in shorthand, for showing the model what's there and for the log.
    var outline: String {
        func lines(_ blocks: [Block], depth: Int) -> [String] {
            blocks.flatMap { block -> [String] in
                let pad = String(repeating: "  ", count: depth)
                var line = pad + "- \(block.kind.rawValue) #\(block.id)"
                if !block.ref.isEmpty { line += " ref \(block.ref)" }
                if !block.over.isEmpty { line += " over \(block.over)" }
                if !block.title.isEmpty { line += " \"\(block.title)\"" }
                var result = [line]
                if !block.text.isEmpty { result.append(pad + "  \(block.text)") }
                result += block.items.map { pad + "  • " + ($0.label.isEmpty ? $0.value : "\($0.label): \($0.value)") }
                return result + lines(block.children, depth: depth + 1)
            }
        }
        var all = ["\(title): \(summary)"] + (collectionSummary.isEmpty ? [] : [collectionSummary]) + lines(visibleBlocks, depth: 0)
        if !related.isEmpty { all.append("related: " + related.joined(separator: ", ")) }
        return all.joined(separator: "\n")
    }
}
