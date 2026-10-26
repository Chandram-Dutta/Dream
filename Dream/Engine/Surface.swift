import Foundation

/// Everything Dream generates is a surface: one screen that can explain, calculate, or both.
///
/// The calculation (inputs, and outputs calculated from them) is optional, and so are information
/// blocks. A question gets facts, a calculation gets an instrument, and a request that needs both
/// ("what is compound interest") gets an explanation with a working calculator in it.
///
/// This is the template. The user's own numbers live separately (`SavedSurface.values`), so a
/// surface can later be reused by someone else without carrying personal data.
struct Surface: Codable, Hashable {
    var title: String
    var summary: String
    var symbol: String
    var accent: Accent
    var inputs: [Input]
    var outputs: [Output]
    var blocks: [Block]
    /// Nearby topics to explore next. Each opens another surface.
    var related: [String]
    /// Where the facts came from. Nil when nothing was looked up.
    var reference: Reference?
    /// What the reader finds out by changing the numbers, in their words, like "How does the
    /// angle change the throw?". Nil when nothing's calculated. Remembered with the surface, so
    /// it can be found again for the same question.
    var question: String?
    /// Tones and recordings that `sound` blocks play. Nil in surfaces saved before sounds existed.
    var sounds: [Sound]?

    static let empty = Surface(title: "", summary: "", symbol: "sparkles", accent: .blue, inputs: [], outputs: [], blocks: [], related: [], reference: nil)

    var isEmpty: Bool { title.isEmpty && summary.isEmpty && blocks.isEmpty && !hasLogic }
    var hasLogic: Bool { !inputs.isEmpty || !outputs.isEmpty }
    /// Inputs the reader sets with a control.
    var adjustableInputs: [Input] { inputs.filter { $0.role == .adjustable } }
    var hasInformation: Bool { blocks.contains { $0.kind.isInformation || $0.children.contains { $0.kind.isInformation } } }

    func input(_ name: String) -> Input? { inputs.first { $0.name == name } }
    func output(_ name: String) -> Output? { outputs.first { $0.name == name } }
    func label(of name: String) -> String { input(name)?.label ?? output(name)?.label ?? sound(name)?.label ?? name }

    var initialValues: [String: Double] {
        Dictionary(inputs.map { ($0.name, $0.initial) }, uniquingKeysWith: { first, _ in first })
    }

    /// The blocks, plus a plain arrangement of any calculation they don't show yet: while the
    /// model is still writing, or if composing failed. Once checked, every input and output is
    /// placed, so this is just `blocks`.
    var visibleBlocks: [Block] {
        guard hasLogic else { return blocks }
        let placed = Self.refs(in: blocks)
        var extra: [Block] = []
        if let main = outputs.first, !placed.contains(main.name) {
            extra.append(Block(id: "auto-hero", kind: .hero, ref: main.name))
        }
        // Positional ids, so elements keep their identity while names are still streaming in.
        let controls = inputs.enumerated().filter { !placed.contains($1.name) && $1.role == .adjustable }.map { index, input in
            Block(id: "auto-input-\(index)", kind: input.defaultControl, ref: input.name)
        }
        if !controls.isEmpty {
            extra.append(Block(id: "auto-inputs", kind: .section, children: controls))
        }
        let results = outputs.enumerated().dropFirst().filter { !placed.contains($1.name) }.map { index, output in
            Block(id: "auto-output-\(index)", kind: .metric, ref: output.name)
        }
        if !results.isEmpty {
            extra.append(Block(id: "auto-outputs", kind: .section, children: results))
        }
        return blocks + extra
    }

    /// What's drawn: `visibleBlocks`, with consecutive top-level controls sharing one panel so
    /// a calculation reads as one instrument rather than a stack of separate cards.
    var displayBlocks: [Block] {
        var result: [Block] = []
        var run: [Block] = []
        func flush() {
            guard !run.isEmpty else { return }
            result.append(run.count == 1 ? run[0] : Block(id: "group-\(run[0].id)", kind: .section, children: run))
            run = []
        }
        for block in visibleBlocks {
            if block.kind.isControl {
                run.append(block)
            } else {
                flush()
                result.append(block)
            }
        }
        flush()
        return result
    }

    static func refs(in blocks: [Block]) -> Set<String> {
        blocks.reduce(into: []) { refs, block in
            refs.formUnion(block.refs)
            if block.kind == .chart, !block.over.isEmpty { refs.insert(block.over) }
            refs.formUnion(Self.refs(in: block.children))
        }
    }
}

struct Block: Codable, Hashable, Identifiable {
    var id: String
    var kind: BlockKind
    /// A heading, or a chart's caption.
    var title: String = ""
    /// A paragraph's sentences, where `{name}` shows a live value and `$...$` is maths. For an
    /// equation, the LaTeX itself, where `\val{name}` shows a live value.
    var text: String = ""
    /// The input or output this block edits or shows. A chart can draw several outputs,
    /// separated by commas, the main one first.
    var ref: String = ""
    /// For charts: the variable or input along the horizontal axis.
    var over: String = ""
    var items: [Item] = []
    var children: [Block] = []

    /// The names in `ref`.
    var refs: [String] {
        ref.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum BlockKind: String, Codable {
    // Bound to the calculation.
    case hero, metric, slider, stepper, field, toggle, picker, chart
    // Information. An equation can also show an output's formula, live.
    case paragraph, facts, bullets, steps, timeline, stat, equation, data
    // Grouping.
    case section, row
    // Something to hear, from `Surface.sounds`.
    case sound

    var isContainer: Bool { self == .section || self == .row }
    var isControl: Bool { [.slider, .stepper, .field, .toggle, .picker].contains(self) }
    var isInformation: Bool { [.paragraph, .facts, .bullets, .steps, .timeline, .stat, .equation, .data].contains(self) }

    func fits(_ format: Format) -> Bool {
        switch self {
        case .toggle: return format == .toggle
        case .picker: return format == .choice
        case .slider, .stepper, .field: return format.isNumeric
        default: return false
        }
    }
}

struct Item: Codable, Hashable {
    /// A fact's name, an event's date, a stat's number, a data point's year or category, or
    /// an equation's symbol. Empty for bullets and steps.
    var label: String
    /// For data, a plain number.
    var value: String
}

extension Item {
    /// A data point's value: the first number in it, so "1,210.9 million" still reads as 1210.9.
    var number: Double? {
        guard let match = value.replacingOccurrences(of: ",", with: "").firstMatch(of: #/-?\d+(?:\.\d+)?/#) else { return nil }
        return Double(match.output)
    }
}

struct Reference: Codable, Hashable {
    var title: String
    var extract: String
    var url: String
    var imageURL: String?
}

enum Accent: String, Codable, CaseIterable {
    case blue, teal, green, mint, orange, pink, purple, indigo, red, yellow, cyan, brown
}

enum Format: String, Codable {
    case number, integer, currency, percent, toggle, choice

    var isNumeric: Bool { self != .toggle && self != .choice }
}

/// What an input is for. Only numbers the reader would change get a control: a number that's
/// simply true is shown, never adjusted.
enum InputRole: String, Codable {
    /// The reader sets it: their own figures, a choice, or a what-if.
    case adjustable
    /// A fixed, known value the formulas need, like gravity on Earth. Shown, not adjusted.
    case given
    /// What a chart runs along, like time or x. The chart is its control.
    case variable
}

struct Input: Codable, Hashable {
    var name: String
    var label: String
    var format: Format
    var initial: Double
    var min: Double
    var max: Double
    var step: Double
    /// Only for `.choice`; the value is the index of the selected option.
    var options: [String]
    var role: InputRole = .adjustable
    /// How it's written in an equation, in LaTeX, like `\theta`. Empty for everyday quantities.
    var symbol = ""

    /// The control to use when the model hasn't picked one, or picked one that doesn't fit.
    var defaultControl: BlockKind {
        switch format {
        case .toggle: return .toggle
        case .choice: return .picker
        case .integer: return step > 0 && (max - min) / step <= 20 ? .stepper : .slider
        case .currency, .number: return step > 0 && (max - min) / step > 2000 ? .field : .slider
        case .percent: return .slider
        }
    }

    /// A range that's always safe to hand to SwiftUI, even mid-stream.
    var safeRange: ClosedRange<Double> {
        guard min.isFinite, max.isFinite, min < max else { return 0...1 }
        return min...max
    }

    var safeStep: Double? {
        step.isFinite && step > 0 && step < safeRange.upperBound - safeRange.lowerBound ? step : nil
    }

    var hasFewSteps: Bool {
        safeStep.map { (safeRange.upperBound - safeRange.lowerBound) / $0 <= 40 } ?? false
    }

    /// Clamps to the range and rounds to the step.
    func snapped(_ value: Double) -> Double {
        let range = safeRange
        var result = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        if let step = safeStep {
            result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step
        }
        return result
    }
}

struct Output: Codable, Hashable {
    var name: String
    var label: String
    var formula: String
    var format: Format
    var symbol = ""
}

// Surfaces saved before roles and symbols existed decode with the defaults.
extension Input {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decode(String.self, forKey: .label)
        format = try container.decode(Format.self, forKey: .format)
        initial = try container.decode(Double.self, forKey: .initial)
        min = try container.decode(Double.self, forKey: .min)
        max = try container.decode(Double.self, forKey: .max)
        step = try container.decode(Double.self, forKey: .step)
        options = try container.decode([String].self, forKey: .options)
        role = try container.decodeIfPresent(InputRole.self, forKey: .role) ?? .adjustable
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
    }
}

extension Output {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decode(String.self, forKey: .label)
        formula = try container.decode(String.self, forKey: .formula)
        format = try container.decode(Format.self, forKey: .format)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
    }
}
