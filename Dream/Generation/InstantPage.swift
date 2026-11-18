import Foundation

/// Pages for requests that are a sum, built by Dream itself in a moment, without a model:
/// "square root of 420", "15% tax on 200 rupees", "20% off 1500", "12 x 7 + 3", "2 to the power
/// of 10". The engine already works formulas out, so the page is the answer, the equation worked
/// through with the user's numbers, and a control for each number. A model took 16 seconds over
/// "square root of 9".
///
/// Only a request that reads wholly as a sum is taken: any word left over ("square root of 420
/// in history", "tax on my salary") means it's asking more, and goes to the model.
enum InstantPage {
    /// The page for `request`, or nil when it isn't simply a sum.
    static func make(for request: String) -> Surface? {
        var text = plain(request)
        let money = takeMoney(&text)
        guard !text.isEmpty else { return nil }
        return percentage(text, money: money)
            ?? root(text)
            ?? power(text)
            ?? arithmetic(text, money: money)
    }

    // MARK: - Kinds of sum

    /// "15% of 200", "15% tax on 200", "18% gst on 1200", "10% tip on 850", "20% off 1500".
    private static func percentage(_ text: String, money: Bool) -> Surface? {
        guard let match = text.wholeMatch(of: #/(\d+(?:\.\d+)?)\s*(?:%|percent|per cent)\s*(tax|gst|vat|tip|discount|off|interest)?\s*(?:of|on|from|for)?\s*(\d+(?:\.\d+)?)/#),
              let rate = Double(match.1), let amount = Double(match.3) else { return nil }
        let kind = match.2.map(String.init)
        let isMoney = money || kind != nil
        let format: Format = isMoney ? .currency : number(amount)
        let shownAmount = isMoney ? Format.currency.display(amount) : amount.plain
        let rateInput = input("rate", "Rate", .percent, rate, min: 0, max: max(100, rate), step: rate == rate.rounded() ? 1 : 0.1)
        let amountInput = input("amount", isMoney ? "Amount" : "Number", format, amount)
        var surface = Surface.empty
        surface.mode = .use
        surface.symbol = "percent"
        surface.accent = isMoney ? Subject.money.accent : Subject.learning.accent
        surface.inputs = [amountInput, rateInput]
        switch kind {
        case "tax", "gst", "vat", "tip", "interest":
            // GST and VAT are names; tax, tip and interest are words.
            let word = kind == "gst" || kind == "vat" ? kind!.uppercased() : kind!
            let name = word.prefix(1).uppercased() + word.dropFirst()
            surface.title = "\(rate.plain)% \(word) on \(shownAmount)"
            surface.summary = "The \(word), and the total with it."
            surface.question = "How much is the \(word), and the total?"
            surface.outputs = [Output(name: "part", label: name, formula: "amount * rate / 100", format: .currency),
                               Output(name: "total", label: "Total", formula: "amount + part", format: .currency)]
            surface.blocks = [block("hero", .hero, ref: "part"), block("total", .metric, ref: "total"),
                              block("amount", .slider, ref: "amount"), block("rate", .slider, ref: "rate"),
                              block("how", .equation, ref: "part")]
        case "discount", "off":
            surface.title = "\(rate.plain)% off \(shownAmount)"
            surface.summary = "The price after the discount, and what it saves."
            surface.question = "What's the price after the discount?"
            surface.outputs = [Output(name: "saving", label: "You save", formula: "amount * rate / 100", format: .currency),
                               Output(name: "price", label: "Price", formula: "amount - saving", format: .currency)]
            surface.blocks = [block("hero", .hero, ref: "price"), block("saving", .metric, ref: "saving"),
                              block("amount", .slider, ref: "amount"), block("rate", .slider, ref: "rate"),
                              block("how", .equation, ref: "saving")]
        default:
            surface.title = "\(rate.plain)% of \(shownAmount)"
            surface.summary = "A percentage, worked out."
            surface.question = "What's \(rate.plain)% of \(shownAmount)?"
            surface.outputs = [Output(name: "result", label: "\(rate.plain)% of \(shownAmount)", formula: "amount * rate / 100", format: isMoney ? .currency : .number)]
            surface.blocks = [block("hero", .hero, ref: "result"), block("amount", .slider, ref: "amount"),
                              block("rate", .slider, ref: "rate"), block("how", .equation, ref: "result")]
        }
        return surface
    }

    /// "square root of 420", "sqrt 9", "√2", "cube root of 27".
    private static func root(_ text: String) -> Surface? {
        let square = text.wholeMatch(of: #/(?:the\s+)?(?:square\s+root|sqrt|root|√)\s*(?:of\s+)?(-?\d+(?:\.\d+)?)/#)
        let cube = text.wholeMatch(of: #/(?:the\s+)?(?:cube\s+root|cbrt|∛)\s*(?:of\s+)?(-?\d+(?:\.\d+)?)/#)
        guard let raw = square?.1 ?? cube?.1, let value = Double(raw) else { return nil }
        let isCube = cube != nil
        if !isCube, value < 0 { return nil }
        var surface = Surface.empty
        surface.mode = .use
        surface.symbol = "x.squareroot"
        surface.accent = Subject.learning.accent
        surface.title = "\(isCube ? "Cube" : "Square") root of \(value.plain)"
        surface.summary = isCube ? "The number that, multiplied by itself three times, gives this one." : "The number that, multiplied by itself, gives this one."
        surface.question = "What's the \(isCube ? "cube" : "square") root of \(value.plain)?"
        surface.inputs = [input("number", "Number", number(value), value, min: isCube ? Swift.min(value * 2, -10) : 0)]
        surface.outputs = [Output(name: "root", label: "\(isCube ? "Cube" : "Square") root", formula: isCube ? "number >= 0 ? pow(number, 1 / 3) : -pow(-number, 1 / 3)" : "sqrt(number)", format: .number)]
        surface.blocks = [block("hero", .hero, ref: "root"), block("number", .slider, ref: "number"), block("how", .equation, ref: "root"),
                          block("check", .paragraph, text: isCube ? "{root} × {root} × {root} gives back {number}." : "{root} × {root} gives back {number}.")]
        return surface
    }

    /// "12 squared", "3 cubed", "2 to the power of 10", "2^10".
    private static func power(_ text: String) -> Surface? {
        var base: Double?
        var exponent: Double?
        if let match = text.wholeMatch(of: #/(-?\d+(?:\.\d+)?)\s*(squared|cubed)/#) {
            base = Double(match.1)
            exponent = match.2 == "squared" ? 2 : 3
        } else if let match = text.wholeMatch(of: #/(-?\d+(?:\.\d+)?)\s*(?:\^|\*\*|to the power of|to the power|raised to(?: the power of)?)\s*(-?\d+(?:\.\d+)?)(?:\s*(?:st|nd|rd|th)(?:\s+power)?)?/#) {
            base = Double(match.1)
            exponent = Double(match.2)
        }
        guard let base, let exponent, Swift.abs(exponent) <= 64 else { return nil }
        var surface = Surface.empty
        surface.mode = .use
        surface.symbol = "textformat.superscript"
        surface.accent = Subject.learning.accent
        surface.title = exponent == 2 ? "\(base.plain) squared" : exponent == 3 ? "\(base.plain) cubed" : "\(base.plain) to the power of \(exponent.plain)"
        surface.summary = "A number multiplied by itself, as many times as the power says."
        surface.question = "What's \(base.plain) to the power of \(exponent.plain)?"
        surface.inputs = [input("base", "Number", number(base), base),
                          input("power", "Power", number(exponent), exponent, min: Swift.min(0, exponent), max: Swift.max(10, exponent * 2), step: exponent == exponent.rounded() ? 1 : 0.1)]
        surface.outputs = [Output(name: "result", label: "Result", formula: "base ^ power", format: .number)]
        surface.blocks = [block("hero", .hero, ref: "result"), block("base", .slider, ref: "base"), block("power", .stepper, ref: "power"), block("how", .equation, ref: "result")]
        return surface
    }

    /// "12 x 7 + 3", "450 divided by 6", "what is 45 times 12", "(3 + 4) * 2".
    private static func arithmetic(_ text: String, money: Bool) -> Surface? {
        var sum = " " + text + " "
        for (words, symbol) in [(" multiplied by ", " * "), (" times ", " * "), (" divided by ", " / "), (" over ", " / "), (" plus ", " + "),
                                (" minus ", " - "), (" x ", " * "), (" × ", " * "), (" ÷ ", " / "), (" into ", " * ")] {
            sum = sum.replacingOccurrences(of: words, with: symbol)
        }
        sum = sum.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        // Digits next to x, like 12x7.
        sum = sum.replacing(#/(\d)\s*x\s*(\d)/#) { "\($0.output.1) * \($0.output.2)" }
        sum = sum.trimmingCharacters(in: .whitespaces)
        guard !sum.isEmpty, sum.allSatisfy({ "0123456789.+-*/^() ".contains($0) }),
              sum.contains(where: { "+-*/^".contains($0) }) else { return nil }
        // The numbers become inputs, in order, so each can be changed.
        let numbers = sum.matches(of: #/\d+(?:\.\d+)?/#).compactMap { Double($0.output) }
        guard (2...6).contains(numbers.count) else { return nil }
        var formula = ""
        var index = 0
        var names: [String] = []
        var lastEnd = sum.startIndex
        for match in sum.matches(of: #/\d+(?:\.\d+)?/#) {
            formula += sum[lastEnd..<match.range.lowerBound]
            let name = "n\(index + 1)"
            names.append(name)
            formula += name
            index += 1
            lastEnd = match.range.upperBound
        }
        formula += sum[lastEnd...]
        formula = formula.replacingOccurrences(of: " ", with: "")
        // It has to be a sum the engine can work out.
        guard let expression = try? FormulaCache.parse(formula),
              let value = try? expression.evaluate({ name in names.firstIndex(of: name).map { numbers[$0] } ?? .nan }),
              value.isFinite else { return nil }
        let shown = sum.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
            .replacing(#/\s*([+\-×÷^])\s*/#) { " \($0.output.1) " }
        var surface = Surface.empty
        surface.mode = .use
        surface.symbol = "plus.forwardslash.minus"
        surface.accent = money ? Subject.money.accent : Subject.learning.accent
        surface.title = shown
        surface.summary = "A sum, worked out. Change any number to work it out again."
        surface.question = "What's \(shown)?"
        surface.inputs = numbers.enumerated().map { offset, value in
            input(names[offset], numbers.count == 2 ? (offset == 0 ? "First number" : "Second number") : "Number \(offset + 1)", money ? .currency : number(value), value)
        }
        let allWhole = numbers.allSatisfy { $0 == $0.rounded() } && value == value.rounded()
        surface.outputs = [Output(name: "result", label: "Result", formula: formula, format: money ? .currency : allWhole ? .integer : .number)]
        surface.blocks = [block("hero", .hero, ref: "result")] + names.map { block($0, .slider, ref: $0) } + [block("how", .equation, ref: "result")]
        return surface
    }

    // MARK: - Reading the request

    /// Lowercased, with what's said around a sum taken off: "what is", "calculate", a question mark.
    static func plain(_ request: String) -> String {
        var text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: ",", with: "")
        while let last = text.last, "?.!=".contains(last) { text.removeLast() }
        let openings = ["what is the value of ", "what's the value of ", "what is ", "what's ", "whats ", "calculate ", "compute ", "work out ",
                        "how much is ", "find the ", "find ", "evaluate ", "please ", "can you calculate ", "tell me "]
        var changed = true
        while changed {
            changed = false
            for opening in openings where text.hasPrefix(opening) {
                text.removeFirst(opening.count)
                changed = true
            }
        }
        if text.hasSuffix(" please") { text.removeLast(" please".count) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Takes the money out of the text: a symbol, a code or a word for it. True if there was any.
    private static func takeMoney(_ text: inout String) -> Bool {
        var found = false
        for symbol in ["₹", "$", "€", "£", "¥"] where text.contains(symbol) {
            text = text.replacingOccurrences(of: symbol, with: "")
            found = true
        }
        let words = #/\s*\b(?:rupees?|rs\.?|inr|dollars?|usd|euros?|eur|pounds?|gbp|yen|jpy|bucks)\b/#
        if text.contains(words) {
            text = text.replacing(words, with: "")
            found = true
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return found
    }

    // MARK: - Pieces

    private static func number(_ value: Double) -> Format {
        value == value.rounded() ? .integer : .number
    }

    /// An input starting at `value`, with room either side to explore.
    private static func input(_ name: String, _ label: String, _ format: Format, _ value: Double, min: Double? = nil, max: Double? = nil, step: Double? = nil) -> Input {
        let size = Swift.max(Swift.abs(value), 1)
        let top = max ?? nice(size * 4)
        let bottom = min ?? (value < 0 ? -nice(size * 4) : 0)
        let decimals = value == value.rounded() ? 0 : Swift.min(String(value.plain.split(separator: ".").last ?? "").count, 3)
        let stride = step ?? (decimals > 0 ? pow(10, -Double(decimals)) : Swift.max(1, nice(top / 200)))
        return Input(name: name, label: label, format: format, initial: value, min: bottom, max: Swift.max(top, value), step: stride, options: [])
    }

    /// A round number at or above `value`: 1, 2 or 5 times a power of ten.
    private static func nice(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let power = pow(10, floor(log10(value)))
        for factor in [1.0, 2, 5, 10] where factor * power >= value { return factor * power }
        return 10 * power
    }

    private static func block(_ id: String, _ kind: BlockKind, ref: String = "", text: String = "") -> Block {
        Block(id: id, kind: kind, text: text, ref: ref)
    }
}
