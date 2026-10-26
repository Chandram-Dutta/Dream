import Foundation

/// Maths in LaTeX: finding it in text, and writing a calculation's formulas as equations, so an
/// equation on screen is always the one that produces the numbers beside it.
enum TeX {
    enum Segment: Hashable {
        case text(String)
        case math(String)
    }

    /// Splits text into prose and maths. Maths sits between `$` signs, `$$` pairs or `\(` and
    /// `\)`, the way models write it. A `$` only opens maths before something that isn't a
    /// space, and only closes it after something that isn't a space and before something that
    /// isn't a digit, so "$5 to $10" stays prose.
    static func segments(_ text: String) -> [Segment] {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return [.text(text)] }
        // Form feeds, backspaces and tabs never belong in prose: they're LaTeX commands that
        // JSON read as escapes. Restored first, so `$\frac` still opens maths.
        let characters = Array(text
            .replacingOccurrences(of: "\u{0C}", with: "\\f")
            .replacingOccurrences(of: "\u{08}", with: "\\b")
            .replacingOccurrences(of: "\t", with: "\\t"))
        var segments: [Segment] = []
        var prose = ""
        var index = 0
        func at(_ position: Int) -> Character? { characters.indices.contains(position) ? characters[position] : nil }
        func find(_ marker: String, from start: Int) -> Int? {
            let marker = Array(marker)
            var position = start
            while position + marker.count <= characters.count {
                if Array(characters[position..<position + marker.count]) == marker { return position }
                position += 1
            }
            return nil
        }
        func math(_ range: Range<Int>, resumingAt next: Int) {
            if !prose.isEmpty { segments.append(.text(prose)) }
            prose = ""
            segments.append(.math(repaired(String(characters[range]))))
            index = next
        }

        while index < characters.count {
            let character = characters[index]
            if character == "\\", at(index + 1) == "$" {
                prose.append("$")
                index += 2
                continue
            }
            if character == "\\", let next = at(index + 1), next == "(" || next == "[",
               let end = find(next == "(" ? "\\)" : "\\]", from: index + 2) {
                math(index + 2..<end, resumingAt: end + 2)
                continue
            }
            if character == "$" {
                if at(index + 1) == "$", let end = find("$$", from: index + 2), end > index + 2 {
                    math(index + 2..<end, resumingAt: end + 2)
                    continue
                }
                if let next = at(index + 1), !next.isWhitespace {
                    var position = index + 1
                    var end: Int?
                    while position < characters.count {
                        let candidate = characters[position]
                        if candidate == "\n", at(position + 1) == "\n" { break }
                        if candidate == "$", characters[position - 1] != "\\", !characters[position - 1].isWhitespace,
                           !(at(position + 1)?.isNumber ?? false) {
                            end = position
                            break
                        }
                        position += 1
                    }
                    if let end {
                        math(index + 1..<end, resumingAt: end + 1)
                        continue
                    }
                }
            }
            prose.append(character)
            index += 1
        }
        if !prose.isEmpty { segments.append(.text(prose)) }
        return segments
    }

    /// JSON reads `\f`, `\b`, `\t`, `\r` and `\n` as control characters, which turns `\frac`
    /// into a form feed and "rac". Maths never holds control characters, so put them back.
    static func repaired(_ tex: String) -> String {
        let scalars = Array(tex.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\u{0C}": result.append(contentsOf: "\\f".unicodeScalars)
            case "\u{08}": result.append(contentsOf: "\\b".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            case "\r": result.append(contentsOf: "\\r".unicodeScalars)
            case "\n":
                let next = index + 1 < scalars.count ? scalars[index + 1] : " "
                result.append(contentsOf: (CharacterSet.letters.contains(next) ? "\\n" : " ").unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commands models use that the typesetter spells differently.
    static func compatible(_ tex: String) -> String {
        var result = tex
        for (command, replacement) in [("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\operatorname", "\\mathrm"), ("\\implies", "\\Rightarrow"),
                                       ("\\iff", "\\Leftrightarrow"), ("\\textrm", "\\text"), ("\\mathrm{d}", "d"), ("\\displaystyle", "")] {
            result = result.replacingOccurrences(of: command, with: replacement)
        }
        return result
    }

    /// How maths reads aloud, for VoiceOver and "Read this page": "a squared plus b squared".
    static func spoken(_ tex: String) -> String {
        SpokenMath.read(tex)
    }

    /// Plain words, safe inside `\text{}`.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "#", with: "")
    }

    /// A number as maths. Very large and very small numbers are written in scientific form.
    /// `precise` keeps up to six significant digits, for constants inside formulas.
    static func number(_ value: Double, precise: Bool = false) -> String {
        guard value.isFinite else { return "\\text{—}" }
        let magnitude = Swift.abs(value)
        if magnitude != 0, magnitude < 1e-4 || magnitude >= 1e9 {
            let exponent = Int(Foundation.floor(Foundation.log10(magnitude)))
            let mantissa = value / Foundation.pow(10, Double(exponent))
            let digits = mantissa.formatted(.number.precision(.significantDigits(1...3)))
            return (digits == "1" ? "" : "\(digits) \\times ") + "10^{\(exponent)}"
        }
        let text = precise || magnitude < 1
            ? value.formatted(.number.precision(.significantDigits(1...(precise ? 6 : 3))))
            : value.formatted(.number.precision(.fractionLength(0...2)))
        // Braces stop TeX spacing a separator out like a comma in a list.
        return text.replacingOccurrences(of: ",", with: "{,}")
    }

    static let constantSymbols = ["pi": "\\pi", "e": "e", "tau": "\\tau"]
}

extension Surface {
    /// How a name is written in an equation: its symbol, or its label in words.
    func texSymbol(_ name: String) -> String {
        let symbol = (input(name)?.symbol ?? output(name)?.symbol ?? "").trimmingCharacters(in: .whitespaces)
        return symbol.isEmpty ? "\\text{\(TeX.escaped(label(of: name)))}" : symbol
    }

    /// An output's formula as an equation, like `c = \sqrt{a^2 + b^2}`.
    func equation(for name: String) -> String? {
        guard let output = output(name), let expr = try? FormulaCache.parse(output.formula) else { return nil }
        return "\(texSymbol(name)) = \(TeXWriter(surface: self, values: nil).write(expr).tex)"
    }

    /// The same formula worked through with the reader's numbers: `= \sqrt{3^2 + 4^2} = 5`.
    func workedEquation(for name: String, values: [String: Double]) -> String? {
        guard let output = output(name), let expr = try? FormulaCache.parse(output.formula) else { return nil }
        let result = texValue(name, values[name] ?? .nan)
        let worked = TeXWriter(surface: self, values: values).write(expr).tex
        return worked == result ? "= \(result)" : "= \(worked) = \(result)"
    }

    /// Written LaTeX with each `\val{name}` replaced by its live value.
    func filled(_ tex: String, values: [String: Double]) -> String {
        guard tex.contains("\\val") else { return tex }
        var result = tex
        // From the end, so earlier ranges stay valid.
        for match in tex.matches(of: TeX.liveValue).reversed() {
            let name = String(match.output.1)
            let known = input(name) != nil || output(name) != nil
            result.replaceSubrange(match.range, with: known ? texValue(name, values[name] ?? .nan) : "\\text{\(TeX.escaped(name))}")
        }
        return result
    }

    /// A value as a result is written: rounded like it's shown, with its unit where maths has one.
    func texValue(_ name: String, _ value: Double) -> String {
        guard value.isFinite else { return "\\text{—}" }
        let format = input(name)?.format ?? output(name)?.format ?? .number
        switch format {
        case .percent: return TeX.number((value * 10).rounded() / 10) + "\\%"
        case .currency:
            let shown = Swift.abs(value) >= 1000 ? value.rounded() : (value * 100).rounded() / 100
            return (Currency.symbol == "$" ? "\\$" : "") + TeX.number(shown)
        case .integer: return TeX.number(value.rounded())
        case .choice, .toggle: return "\\text{\(TeX.escaped(display(name, value)))}"
        case .number: return TeX.number(value)
        }
    }

    /// An output's formula in words, for VoiceOver: the equation on screen, read as maths, with
    /// symbols where it has them and labels where it doesn't.
    func spokenEquation(for name: String) -> String? {
        equation(for: name).map(TeX.spoken)
    }
}

extension TeX {
    /// `\val{name}`, or `\value{name}`.
    nonisolated(unsafe) static let liveValue = #/\\val(?:ue)?\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}/#
}

/// Writes a parsed formula as LaTeX, adding only the brackets the maths needs.
private struct TeXWriter {
    /// How tightly a piece holds together; a looser piece is bracketed inside a tighter one.
    enum Level: Int, Comparable {
        case top, comparison, sum, unary, product, power, application, atom
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Piece {
        var tex: String
        var level: Level
    }

    let surface: Surface
    /// When set, names are written as their values: the formula worked through.
    let values: [String: Double]?

    func write(_ expr: Expr) -> Piece {
        switch expr {
        case .number(let value):
            return Piece(tex: TeX.number(value, precise: true), level: value < 0 ? .unary : .atom)
        case .name(let name):
            let known = surface.input(name) != nil || surface.output(name) != nil
            if !known, let symbol = TeX.constantSymbols[name] { return Piece(tex: symbol, level: .atom) }
            guard let values else { return Piece(tex: surface.texSymbol(name), level: .atom) }
            let value = values[name] ?? .nan
            if let input = surface.input(name), input.format == .choice {
                return Piece(tex: surface.texValue(name, value), level: .atom)
            }
            return Piece(tex: TeX.number(value), level: value < 0 ? .unary : .atom)
        case .unary("!", let operand):
            return Piece(tex: "\\neg " + wrap(write(operand), .power), level: .unary)
        case .unary(_, let operand):
            return Piece(tex: "-" + wrap(write(operand), .product), level: .unary)
        case .binary("/", .binary("/", let numerator, let denominator), let rhs):
            // a / b / c reads as one fraction: a over b c.
            return write(.binary("/", numerator, .binary("*", denominator, rhs)))
        case _ where degrees(in: expr) != nil:
            return degree(degrees(in: expr)!)
        case .binary(let op, let lhs, let rhs):
            let (a, b) = (write(lhs), write(rhs))
            switch op {
            case "+", "-":
                return Piece(tex: "\(wrap(a, .sum)) \(op) \(wrap(b, .product))", level: .sum)
            case "*":
                return product(a, b)
            case "/":
                return Piece(tex: "\\frac{\(a.tex)}{\(b.tex)}", level: .application)
            case "%":
                return Piece(tex: "\(wrap(a, .product)) \\text{ mod } \(wrap(b, .power))", level: .product)
            case "^":
                return power(a, b)
            case "&&", "||":
                return Piece(tex: "\(wrap(a, .comparison)) \(op == "&&" ? "\\land" : "\\lor") \(wrap(b, .comparison))", level: .top)
            default:
                if values == nil, let option = choice(op, lhs, rhs) { return Piece(tex: option, level: .atom) }
                let symbol = ["<": "<", "<=": "\\le", ">": ">", ">=": "\\ge", "==": "=", "!=": "\\ne"][op] ?? op
                return Piece(tex: "\(wrap(a, .sum)) \(symbol) \(wrap(b, .sum))", level: .comparison)
            }
        case .conditional(let condition, let then, let otherwise):
            return conditional(condition, then, otherwise, whole: expr)
        case .call("if", let arguments) where arguments.count == 3:
            return conditional(arguments[0], arguments[1], arguments[2], whole: .conditional(arguments[0], arguments[1], arguments[2]))
        case .call(let function, let arguments) where Expr.aggregates.contains(function) && arguments.count == 1 && surface.columnNames.contains(arguments[0].description):
            return total(function, of: arguments[0].description)
        case .call(let function, let arguments):
            return call(function, arguments.map(write))
        }
    }

    /// A total over the user's entries: its value when worked through, otherwise what it adds
    /// up, like `\sum \text{Amount}`.
    private func total(_ function: String, of name: String) -> Piece {
        if let values {
            let value = values[Expr.call(function, [.name(name)]).description] ?? .nan
            return Piece(tex: TeX.number(value), level: value < 0 ? .unary : .atom)
        }
        let label = "\\text{\(TeX.escaped(surface.label(of: name)))}"
        switch function {
        case "sum": return Piece(tex: "\\sum " + label, level: .application)
        case "min", "max": return Piece(tex: "\\\(function) " + label, level: .application)
        default: return Piece(tex: "\\text{\(function)}(\(label))", level: .application)
        }
    }

    /// `x * pi / 180`, the usual way to turn degrees into radians, gives back x.
    private func degrees(in expr: Expr) -> Expr? {
        switch expr {
        case .binary("/", .binary("*", let angle, .name("pi")), .number(180)),
             .binary("/", .binary("*", .name("pi"), let angle), .number(180)),
             .binary("*", .binary("/", let angle, .number(180)), .name("pi")),
             .binary("*", .name("pi"), .binary("/", let angle, .number(180))),
             .binary("*", let angle, .binary("/", .name("pi"), .number(180))):
            return surface.input("pi") == nil && surface.output("pi") == nil ? angle : nil
        default:
            return nil
        }
    }

    /// Degrees as maths writes them: 2θ°.
    private func degree(_ angle: Expr) -> Piece {
        if case .binary("*", let factor, let last) = angle {
            return product(write(factor), degree(last))
        }
        return Piece(tex: "{\(wrap(write(angle), .atom))}^{\\circ}", level: .power)
    }

    private func wrap(_ piece: Piece, _ level: Level) -> String {
        piece.level >= level ? piece.tex : bracketed(piece.tex)
    }

    /// Brackets that grow only around something tall, like a fraction; sized brackets also
    /// bring extra space with them.
    private func bracketed(_ tex: String) -> String {
        let tall = ["\\frac", "\\begin", "\\binom", "\\sqrt", "\\sum", "\\int"].contains { tex.contains($0) }
        return tall ? "\\left(\(tex)\\right)" : "(\(tex))"
    }

    private func product(_ a: Piece, _ b: Piece) -> Piece {
        // a * a is a², not "aa".
        if values == nil, a.tex == b.tex, a.level == .atom { return power(a, Piece(tex: "2", level: .atom)) }
        let left = wrap(a, .product)
        let right = wrap(b, .product)
        let startsWithNumber = right.first.map { $0.isNumber || $0 == "." || $0 == "-" } ?? false
        // Symbols sit side by side, as in 2πr; numbers and words need a sign between them.
        let joiner = values != nil || startsWithNumber || left.contains("\\text") || right.contains("\\text") ? " \\times " : " "
        return Piece(tex: left + joiner + right, level: .product)
    }

    private func power(_ base: Piece, _ exponent: Piece) -> Piece {
        Piece(tex: "{\(wrap(base, .atom))}^{\(exponent.tex)}", level: .power)
    }

    /// Symbolically, every case; worked through, only the one that applies.
    private func conditional(_ condition: Expr, _ then: Expr, _ otherwise: Expr, whole: Expr) -> Piece {
        if let values {
            let holds = (try? condition.evaluate { values[$0] ?? Expr.constants[$0] ?? .nan }) ?? 0
            return write(holds != 0 ? then : otherwise)
        }
        var rows: [(value: Expr, condition: Expr?)] = []
        var rest = whole
        while true {
            if case .conditional(let condition, let then, let otherwise) = rest {
                rows.append((then, condition))
                rest = otherwise
            } else if case .call("if", let arguments) = rest, arguments.count == 3 {
                rows.append((arguments[1], arguments[0]))
                rest = arguments[2]
            } else {
                break
            }
        }
        rows.append((rest, nil))
        let body = rows.map { row in
            let when = row.condition.map { condition -> String in
                let piece = write(condition)
                return piece.tex.hasPrefix("\\text{") ? piece.tex : "\\text{if } \(piece.tex)"
            } ?? "\\text{otherwise}"
            return "\(write(row.value).tex) & \(when)"
        }
        return Piece(tex: "\\begin{cases} \(body.joined(separator: " \\\\ ")) \\end{cases}", level: .atom)
    }

    /// `unit == 1`, where unit is a choice, reads as the option itself.
    private func choice(_ op: String, _ lhs: Expr, _ rhs: Expr) -> String? {
        guard op == "==" || op == "!=" else { return nil }
        let pair: (String, Double)?
        switch (lhs, rhs) {
        case (.name(let name), .number(let value)), (.number(let value), .name(let name)): pair = (name, value)
        default: pair = nil
        }
        guard let (name, value) = pair, let input = surface.input(name), input.format == .choice,
              let index = Int(exactly: value), input.options.indices.contains(index) else { return nil }
        return "\\text{\(op == "!=" ? "not " : "")\(TeX.escaped(input.options[index]))}"
    }

    private func call(_ function: String, _ pieces: [Piece]) -> Piece {
        let arguments = bracketed(pieces.map(\.tex).joined(separator: ", "))
        func applied(_ command: String) -> Piece { Piece(tex: command + arguments, level: .application) }
        switch (function, pieces.count) {
        case ("sqrt", 1): return Piece(tex: "\\sqrt{\(pieces[0].tex)}", level: .atom)
        case ("cbrt", 1): return Piece(tex: "\\sqrt[3]{\(pieces[0].tex)}", level: .atom)
        case ("pow", 2): return power(pieces[0], pieces[1])
        case ("exp", 1): return Piece(tex: "e^{\(pieces[0].tex)}", level: .power)
        case ("abs", 1): return Piece(tex: "\\left|\(pieces[0].tex)\\right|", level: .atom)
        case ("floor", 1): return Piece(tex: "\\left\\lfloor \(pieces[0].tex) \\right\\rfloor", level: .atom)
        case ("ceil", 1): return Piece(tex: "\\left\\lceil \(pieces[0].tex) \\right\\rceil", level: .atom)
        case ("ln", 1), ("log", 1): return applied("\\ln")
        case ("log", 2): return Piece(tex: "\\log_{\(pieces[1].tex)}" + bracketed(pieces[0].tex), level: .application)
        case ("log10", 1): return applied("\\log_{10}")
        case ("log2", 1): return applied("\\log_{2}")
        case ("sin", 1), ("cos", 1), ("tan", 1), ("sinh", 1), ("cosh", 1), ("tanh", 1): return applied("\\" + function)
        case ("asin", 1), ("acos", 1), ("atan", 1): return applied("\\arc" + function.dropFirst())
        case ("min", _), ("max", _): return applied("\\" + function)
        case ("hypot", 2):
            let two = Piece(tex: "2", level: .atom)
            return Piece(tex: "\\sqrt{\(power(pieces[0], two).tex) + \(power(pieces[1], two).tex)}", level: .atom)
        case ("fact", 1): return Piece(tex: wrap(pieces[0], .atom) + "!", level: .power)
        case ("choose", 2): return Piece(tex: "\\binom{\(pieces[0].tex)}{\(pieces[1].tex)}", level: .atom)
        case ("mod", 2): return Piece(tex: "\(wrap(pieces[0], .product)) \\text{ mod } \(wrap(pieces[1], .power))", level: .product)
        case ("sum", 1...): return Piece(tex: pieces.map { wrap($0, .sum) }.joined(separator: " + "), level: .sum)
        case ("avg", 1...):
            return Piece(tex: "\\frac{\(pieces.map { wrap($0, .sum) }.joined(separator: " + "))}{\(pieces.count)}", level: .application)
        default: return applied("\\mathrm{\(function)}")
        }
    }
}
