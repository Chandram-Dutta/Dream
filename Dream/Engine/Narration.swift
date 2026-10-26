import Foundation

/// A surface read aloud, for "Read this page": the title and summary, then each block in the
/// order it's shown. Live values are read as they are right now, and maths as it's said.
enum Narration {
    struct Passage: Hashable {
        /// What's being read, so the screen can mark it: a block's id, `headerID`, or a step's `stepID`.
        var id: String
        var text: String
    }

    static let headerID = "narration-header"

    /// One step of a steps block, which is read, and marked, on its own.
    static func stepID(_ block: String, _ index: Int) -> String { "\(block)#step\(index)" }

    /// Ends a piece with a full stop if it has no punctuation of its own, so the voice pauses.
    static func sentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return "" }
        return ".!?:;".contains(last) ? text : text + "."
    }
}

extension Surface {
    func narration(values given: [String: Double]) -> [Narration.Passage] {
        let values = evaluate(given).values
        var passages: [Narration.Passage] = []
        let header = [spoken(title, values: values), spoken(summary, values: values)].map(Narration.sentence).filter { !$0.isEmpty }
        if !header.isEmpty {
            passages.append(Narration.Passage(id: Narration.headerID, text: header.joined(separator: " ")))
        }
        for block in displayBlocks {
            passages += narration(of: block, values: values)
        }
        return passages.filter { !$0.text.isEmpty }
    }

    /// The first steps block, for reading hands-free.
    var stepsBlock: Block? {
        func first(in blocks: [Block]) -> Block? {
            for block in blocks {
                if block.kind == .steps, !block.items.isEmpty { return block }
                if let found = first(in: block.children) { return found }
            }
            return nil
        }
        return first(in: displayBlocks)
    }

    /// The block on the page that holds what's being read, to scroll to.
    func topLevelID(containing id: String) -> String? {
        let block = id.components(separatedBy: "#step").first ?? id
        func contains(_ candidate: Block) -> Bool { candidate.id == block || candidate.children.contains(where: contains) }
        return displayBlocks.first(where: contains)?.id
    }

    /// A steps block's steps, read one at a time: "Step 2 of 6. Fold in the flour."
    func spokenSteps(of block: Block, values given: [String: Double]) -> [String] {
        let values = evaluate(given).values
        let count = block.items.count
        return block.items.enumerated().map { index, item in
            "Step \(index + 1) of \(count). " + Narration.sentence(spoken(item.value, values: values))
        }
    }

    /// Text as it's heard: `{name}` as its current value, and `$...$` as spoken maths.
    func spoken(_ text: String, values: [String: Double]) -> String {
        Placeholders.parts(text).map { part in
            switch part {
            case .text(let prose): prose
            case .name(let name): spokenValue(name, values[name])
            case .math(let tex): " " + TeX.spoken(filled(tex, values: values)) + " "
            }
        }
        .joined()
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .replacingOccurrences(of: " ,", with: ",")
        .replacingOccurrences(of: " .", with: ".")
    }

    /// A value as it's shown, with the parts a voice would stumble on spelled out: 1.5 × 10⁹ is
    /// "1.5 times 10 to the power of 9".
    func spokenValue(_ name: String, _ value: Double?) -> String {
        let shown = display(name, value)
        guard shown != "—" else { return "no value yet" }
        guard let times = shown.range(of: " × 10") else { return shown }
        let digits: [Character: Character] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9"]
        let exponent = shown[times.upperBound...]
        let power = (exponent.hasPrefix("⁻") ? "minus " : "") + String(exponent.compactMap { digits[$0] })
        return "\(shown[..<times.lowerBound]) times 10 to the power of \(power)"
    }

    private func narration(of block: Block, values: [String: Double]) -> [Narration.Passage] {
        let heading = Narration.sentence(spoken(block.title, values: values))
        func passage(_ parts: [String]) -> [Narration.Passage] {
            let text = parts.map(Narration.sentence).filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty ? [] : [Narration.Passage(id: block.id, text: text)]
        }
        /// "Monthly payment: $1,498."
        func reading(_ name: String) -> String {
            guard input(name) != nil || output(name) != nil else { return "" }
            return "\(label(of: name)): \(spokenValue(name, values[name]))"
        }

        switch block.kind {
        case .section, .row:
            let title = heading.isEmpty ? [] : [Narration.Passage(id: block.id, text: heading)]
            return title + block.children.flatMap { narration(of: $0, values: values) }
        case .hero, .metric, .slider, .stepper, .field, .toggle, .picker:
            return passage([reading(block.ref)])
        case .chart:
            // The caption says what the chart shows; without one, say what's drawn against what.
            guard heading.isEmpty else { return passage([heading]) }
            let drawn = block.refs.map(label(of:)).joined(separator: " and ")
            return passage(drawn.isEmpty ? [] : ["A chart of \(drawn)" + (block.over.isEmpty ? "" : " against \(label(of: block.over))")])
        case .equation:
            if !block.ref.isEmpty, let equation = spokenEquation(for: block.ref) {
                return passage([heading, equation, reading(block.ref)])
            }
            let legend = block.items.map { "\(TeX.spoken($0.label)), \(spoken($0.value, values: values))" }
            return passage([heading, TeX.spoken(filled(block.text, values: values))] + legend)
        case .steps:
            let title = heading.isEmpty ? [] : [Narration.Passage(id: block.id, text: heading)]
            return title + block.items.enumerated().map { index, item in
                Narration.Passage(id: Narration.stepID(block.id, index), text: "Step \(index + 1). " + Narration.sentence(spoken(item.value, values: values)))
            }
        case .data:
            // Enough points to hear the shape, not a recital.
            let shown = block.items.prefix(8).map { "\(spoken($0.label, values: values)): \($0.value)" }
            let rest = block.items.count > 8 ? ["and \(block.items.count - 8) more"] : []
            return passage([heading] + shown + rest)
        default:
            // Paragraphs, facts, bullets, timelines, stats, and anything newer: what it says, in order.
            let items = block.items.map { item -> String in
                let label = spoken(item.label, values: values)
                let value = spoken(item.value, values: values)
                return label.isEmpty ? value : "\(label): \(value)"
            }
            return passage([heading, spoken(block.text, values: values)] + items)
        }
    }
}
