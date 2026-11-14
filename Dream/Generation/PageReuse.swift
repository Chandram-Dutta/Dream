import Foundation

/// A saved page made again for a request that asks the same thing with other numbers: "15% tax
/// on 300" after "15% tax on 200 rupees", "split 3600 five ways" after "split 2400 four ways".
/// The page is a calculation, so it already works for any numbers; only its starting values,
/// and the numbers its words quote, change. No model, so it's there at once.
///
/// Only when it's safe: the requests' words match once their numbers are set aside, each number
/// in the earlier request is the starting value of exactly one of the page's inputs, and the page
/// is a calculation that fetches nothing (no live values, lists or services), so nothing on it
/// was true only for the earlier numbers.
enum PageReuse {
    /// The page `surface`, made for `earlier`, set up for `request`; nil when it doesn't fit.
    static func adapt(_ surface: Surface, asked earlier: String, for request: String) -> Surface? {
        guard surface.mode == .use || surface.mode == .decide, !surface.outputs.isEmpty,
              (surface.sources ?? []).isEmpty, (surface.collections ?? []).isEmpty, (surface.services ?? []).isEmpty,
              (surface.answers ?? []).isEmpty else { return nil }
        let before = shape(of: earlier), after = shape(of: request)
        guard !before.words.isEmpty, before.words == after.words, !before.numbers.isEmpty,
              before.numbers.count == after.numbers.count, before.numbers != after.numbers else { return nil }
        // Which input each number in the earlier request started.
        var adapted = surface
        var changed: [(old: Double, new: Double, input: Int)] = []
        for (old, new) in zip(before.numbers, after.numbers) where old != new {
            let matching = surface.inputs.indices.filter { surface.inputs[$0].initial == old && surface.inputs[$0].role == .adjustable }
            guard matching.count == 1 else { return nil }
            changed.append((old, new, matching[0]))
        }
        let oldValues = surface.evaluate(surface.initialValues).values
        for change in changed {
            var input = adapted.inputs[change.input]
            input.initial = change.new
            if change.new > input.max { input.max = nice(change.new * 2) }
            if change.new < input.min { input.min = change.new < 0 ? -nice(-change.new * 2) : 0 }
            adapted.inputs[change.input] = input
        }
        let newValues = adapted.evaluate(adapted.initialValues).values
        // The numbers its words quote: each changed input, and each result shown as it was.
        var replacements: [(String, String)] = []
        for change in changed {
            let input = adapted.inputs[change.input]
            replacements.append((surface.display(input.name, change.old), adapted.display(input.name, change.new)))
            replacements.append((change.old.plain, change.new.plain))
        }
        for output in surface.outputs {
            if let old = oldValues[output.name], let new = newValues[output.name], old != new {
                replacements.append((surface.display(output.name, old), adapted.display(output.name, new)))
            }
        }
        // The longest first, so ₹2,400 is replaced whole before 2400 could be.
        replacements.sort { $0.0.count > $1.0.count }
        func rewrite(_ text: String) -> String { replace(replacements, in: text) }
        adapted.title = rewrite(adapted.title)
        adapted.summary = rewrite(adapted.summary)
        adapted.question = adapted.question.map(rewrite)
        adapted.blocks = adapted.blocks.map { rewritten($0, by: rewrite) }
        return adapted
    }

    /// A request's words, with its numbers set aside in order.
    static func shape(of request: String) -> (words: [String], numbers: [Double]) {
        var words: [String] = []
        var numbers: [Double] = []
        let text = request.lowercased().replacingOccurrences(of: ",", with: "")
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "%")))
            let digits = trimmed.filter { $0.isNumber || $0 == "." }
            if !digits.isEmpty, let value = Double(digits), digits.count >= trimmed.filter({ $0 != "%" }).count {
                numbers.append(value)
                words.append(trimmed.contains("%") ? "#%" : "#")
            } else if !trimmed.isEmpty {
                words.append(trimmed)
            }
        }
        return (words, numbers)
    }

    private static func rewritten(_ block: Block, by rewrite: (String) -> String) -> Block {
        var block = block
        block.title = rewrite(block.title)
        block.text = rewrite(block.text)
        block.items = block.items.map { item in
            var item = item
            item.label = rewrite(item.label)
            item.value = rewrite(item.value)
            return item
        }
        block.children = block.children.map { rewritten($0, by: rewrite) }
        return block
    }

    /// Each number replaced where it stands whole, not inside another number.
    private static func replace(_ replacements: [(String, String)], in text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (old, new) in replacements where !old.isEmpty && old != new {
            var output = ""
            var rest = Substring(result)
            while let range = rest.range(of: old) {
                let before = rest[..<range.lowerBound].last
                let after = rest[range.upperBound...].first
                let standsAlone = !(before?.isNumber ?? false) && before != "." && !(after?.isNumber ?? false) && !(after == "." && rest[range.upperBound...].dropFirst().first?.isNumber == true)
                output += rest[..<range.lowerBound]
                output += standsAlone ? new : old
                rest = rest[range.upperBound...]
            }
            output += rest
            result = output
        }
        return result
    }

    private static func nice(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let power = pow(10, floor(log10(value)))
        for factor in [1.0, 2, 5, 10] where factor * power >= value { return factor * power }
        return 10 * power
    }
}
