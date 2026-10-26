import Foundation

/// Maths read aloud the way a teacher says it: "a squared plus b squared equals c squared", or
/// "minus b plus or minus the square root of b squared minus 4 a c, all over 2 a".
///
/// The LaTeX is read as structure rather than as characters, so a fraction, root or power says
/// where it ends when a listener couldn't otherwise tell: a sum inside something larger becomes
/// "the quantity", and a pause closes a root or power that reaches over several terms.
enum SpokenMath {
    static func read(_ tex: String) -> String {
        var parser = Parser(tokens: tokenize(TeX.compatible(tex)))
        var nodes: [Node] = []
        // A stray closing brace mustn't end the reading early.
        while parser.peek != nil {
            nodes += parser.sequence { _ in false }
            if parser.peek == .close { parser.position += 1 }
        }
        return tidy(Speaker.speak(nodes).text)
    }

    /// Spacing and punctuation the pieces leave behind.
    private static func tidy(_ text: String) -> String {
        var result = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for (from, to) in [(" ,", ","), (",,", ","), ("$ ", "$")] {
            while result.contains(from) { result = result.replacingOccurrences(of: from, with: to) }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ", ")).replacingOccurrences(of: ", ,", with: ",")
    }
}

// MARK: - Tokens

private enum Token: Equatable {
    /// `\frac` is "frac"; `\\` is "\\".
    case command(String)
    case open, close
    case superscript, `subscript`
    case number(String)
    case letter(String)
    case symbol(String)
    /// Words written as words, from `\text{}`. An upright name (`\mathrm`, `\operatorname`)
    /// reads as a function when brackets follow it.
    case text(String, isName: Bool)
}

extension SpokenMath {
    /// Commands whose argument is read as written.
    fileprivate static let textCommands: [String: Bool] = [
        "text": false, "textrm": false, "textit": false, "textbf": false, "textsf": false, "texttt": false, "mbox": false,
        "mathrm": true, "operatorname": true, "val": false, "value": false,
    ]
    /// Sizing and spacing, which make no sound.
    fileprivate static let silentCommands: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "middle",
        "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "quad", "qquad", "nonumber", "notag", "centering",
    ]
    fileprivate static let unicode: [Character: Token] = [
        "×": .command("times"), "·": .command("cdot"), "÷": .command("div"), "±": .command("pm"), "∓": .command("mp"),
        "−": .symbol("-"), "–": .symbol("-"), "≤": .command("le"), "≥": .command("ge"), "≠": .command("ne"),
        "≈": .command("approx"), "→": .command("to"), "⇒": .command("Rightarrow"), "∞": .command("infty"),
        "√": .command("sqrt"), "∑": .command("sum"), "∫": .command("int"), "∂": .command("partial"), "∝": .command("propto"),
        "α": .command("alpha"), "β": .command("beta"), "γ": .command("gamma"), "δ": .command("delta"), "Δ": .command("Delta"),
        "ε": .command("epsilon"), "θ": .command("theta"), "λ": .command("lambda"), "μ": .command("mu"), "π": .command("pi"),
        "ρ": .command("rho"), "σ": .command("sigma"), "Σ": .command("Sigma"), "τ": .command("tau"), "φ": .command("phi"),
        "ω": .command("omega"), "Ω": .command("Omega"),
    ]
}

private func tokenize(_ tex: String) -> [Token] {
    let characters = Array(tex)
    var tokens: [Token] = []
    var index = 0
    func at(_ position: Int) -> Character? { characters.indices.contains(position) ? characters[position] : nil }
    func isDigit(_ character: Character?) -> Bool { character.map { $0.isASCII && $0.isNumber } ?? false }

    /// A braced argument as written, for `\text{}`.
    func raw() -> String {
        while at(index)?.isWhitespace == true { index += 1 }
        guard at(index) == "{" else { return "" }
        var depth = 0
        var text = ""
        while let character = at(index) {
            index += 1
            if character == "{" { depth += 1; if depth == 1 { continue } }
            if character == "}" { depth -= 1; if depth == 0 { break } }
            if character == "\\", let next = at(index) {
                // `\%` and `\ ` inside words are the characters themselves.
                if !next.isLetter { text.append(next == "%" ? " percent" : next == "$" ? "$" : " "); index += 1 }
                continue
            }
            text.append(character)
        }
        return text
    }

    while let character = at(index) {
        if character.isWhitespace || character == "~" || character == "$" {
            index += 1
            continue
        }
        if character == "\\" {
            guard let next = at(index + 1) else { break }
            if next.isLetter {
                var end = index + 1
                while let letter = at(end), letter.isLetter { end += 1 }
                let name = String(characters[index + 1..<end])
                index = end
                if let isName = SpokenMath.textCommands[name] {
                    let words = raw()
                    if !words.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append(.text(words, isName: isName)) }
                } else if SpokenMath.silentCommands.contains(name) {
                    // `\left.` opens nothing.
                    if at(index) == "." { index += 1 }
                } else {
                    tokens.append(.command(name))
                }
                continue
            }
            index += 2
            switch next {
            case "\\": tokens.append(.command("\\"))
            case "{", "}", "|": tokens.append(.symbol(String(next)))
            case "%": tokens.append(.command("%"))
            case "$": tokens.append(.command("$"))
            case "&": tokens.append(.text("and", isName: false))
            default: break // spacing: \, \; \: \! and "\ "
            }
            continue
        }
        if isDigit(character) || (character == "." && isDigit(at(index + 1))) {
            var number = ""
            while let next = at(index) {
                if isDigit(next) || (next == "." && isDigit(at(index + 1))) {
                    number.append(next)
                    index += 1
                } else if next == "{", at(index + 1) == ",", at(index + 2) == "}", isDigit(at(index + 3)) {
                    // Thousands, as `TeX.number` writes them.
                    number.append(",")
                    index += 3
                } else if next == ",", isDigit(at(index + 1)), isDigit(at(index + 2)), isDigit(at(index + 3)), !isDigit(at(index + 4)) {
                    number.append(",")
                    index += 1
                } else {
                    break
                }
            }
            tokens.append(.number(number))
            continue
        }
        index += 1
        switch character {
        case "{": tokens.append(.open)
        case "}": tokens.append(.close)
        case "^": tokens.append(.superscript)
        case "_": tokens.append(.subscript)
        case "&": tokens.append(.symbol("&"))
        case "²", "³": tokens += [.superscript, .number(character == "²" ? "2" : "3")]
        default:
            if let mapped = SpokenMath.unicode[character] {
                tokens.append(mapped)
            } else if character.isLetter {
                tokens.append(.letter(String(character)))
            } else {
                tokens.append(.symbol(String(character)))
            }
        }
    }
    return tokens
}

// MARK: - Structure

private enum Operator {
    /// Joins terms: plus, minus, plus or minus.
    case term(String)
    /// Joins factors: times, over, mod.
    case factor(String)
    /// Joins sides: equals, is less than, approaches.
    case relation(String)

    var words: String {
        switch self {
        case .term(let words), .factor(let words), .relation(let words): words
        }
    }
}

private enum Fence {
    case parentheses, absolute, floor, ceiling
}

private indirect enum Node {
    case number(String)
    case letter(String)
    /// Said as it is: Greek letters, infinity, words.
    case word(String)
    /// An upright name like `\mathrm{sign}`, which applies to brackets after it.
    case name(String)
    case op(Operator)
    /// Braces, which make no sound of their own.
    case group([Node])
    case fenced([Node], Fence)
    case fraction([Node], [Node])
    case root([Node], index: [Node]?)
    case scripted(Node, sub: [Node]?, sup: [Node]?, primes: Int)
    /// Sine, log and the like: they apply to the brackets or the term after them.
    case function(String, sub: [Node]?, sup: [Node]?)
    /// Sum, integral, limit: they reach over everything after them.
    case large(String, sub: [Node]?, sup: [Node]?)
    /// `\bar{x}` is "x bar"; `\vec{v}` is "vector v".
    case accent(String, [Node], before: Bool)
    case binomial([Node], [Node])
    /// Cases and matrices: rows of cells.
    case table(String, [[[Node]]])
    /// Factorial, percent, degrees: said after what they follow.
    case postfix(String)
    case pause
}

private struct Parser {
    var tokens: [Token]
    var position = 0

    var peek: Token? { position < tokens.count ? tokens[position] : nil }

    /// Items up to the end, a closing brace, or whatever `stops` says ends this part. The closing
    /// brace is left for the caller.
    mutating func sequence(stops: (Token) -> Bool) -> [Node] {
        var nodes: [Node] = []
        while let token = peek, token != .close, !stops(token) {
            if let node = item(scripts: true) { nodes.append(node) }
        }
        return nodes
    }

    /// `{...}`, or a single item, as TeX takes arguments: `\frac12` is one half.
    mutating func argument() -> [Node] {
        switch peek {
        case .open?:
            position += 1
            let nodes = sequence { _ in false }
            if peek == .close { position += 1 }
            return nodes
        case .number(let digits)? where digits.count > 1 && !digits.contains(",") && !digits.contains("."):
            tokens[position] = .number(String(digits.dropFirst()))
            return [.number(String(digits.prefix(1)))]
        case nil, .close?:
            return []
        default:
            return item(scripts: false).map { [$0] } ?? []
        }
    }

    /// Reads up to a closing symbol, which it consumes.
    mutating func fenced(until close: Token, _ fence: Fence) -> Node {
        let inner = sequence { $0 == close }
        if peek == close { position += 1 }
        return .fenced(inner, fence)
    }

    mutating func scripts() -> (sub: [Node]?, sup: [Node]?, primes: Int) {
        var sub: [Node]?
        var sup: [Node]?
        var primes = 0
        while let token = peek {
            if token == .superscript {
                position += 1
                sup = argument()
            } else if token == .subscript {
                position += 1
                sub = argument()
            } else if token == .symbol("'") {
                position += 1
                primes += 1
            } else {
                break
            }
        }
        return (sub, sup, primes)
    }

    mutating func item(scripts withScripts: Bool) -> Node? {
        guard let token = peek else { return nil }
        position += 1
        var node: Node?
        switch token {
        case .number(let digits): node = .number(digits)
        case .letter(let letter): node = .letter(letter)
        case .text(let words, let isName): node = isName ? .name(words) : .word(words)
        case .open:
            let inner = sequence { _ in false }
            if peek == .close { position += 1 }
            node = .group(inner)
        case .close, .superscript, .subscript:
            // A stray script marker has nothing to attach to.
            return nil
        case .symbol(let symbol):
            switch symbol {
            case "(": node = fenced(until: .symbol(")"), .parentheses)
            case "[": node = fenced(until: .symbol("]"), .parentheses)
            case "{": node = fenced(until: .symbol("}"), .parentheses)
            case "|": node = fenced(until: .symbol("|"), .absolute)
            case "+": return .op(.term("plus"))
            case "-": return .op(.term("minus"))
            case "*": return .op(.factor("times"))
            case "/": return .op(.factor("over"))
            case "=": return .op(.relation("equals"))
            case "<": return .op(.relation("is less than"))
            case ">": return .op(.relation("is greater than"))
            case ":": return .op(.relation("to"))
            case "!": return .postfix("factorial")
            case "°": return .postfix("degrees")
            case "'": return .postfix("prime")
            case ",", ";": return .pause
            default: return nil
            }
        case .command(let name):
            node = command(name)
            if node == nil { return nil }
        }
        guard withScripts, let base = node else { return node }
        if case .function = base { return base }
        if case .large = base { return base }
        let (sub, sup, primes) = scripts()
        guard sub != nil || sup != nil || primes > 0 else { return base }
        return .scripted(base, sub: sub, sup: sup, primes: primes)
    }

    mutating func command(_ name: String) -> Node? {
        if let words = Self.symbols[name] { return .word(words) }
        if let op = Self.operators[name] { return .op(op) }
        if let words = Self.functions[name] {
            let (sub, sup, _) = scripts()
            return .function(words, sub: sub, sup: sup)
        }
        if let words = Self.large[name] {
            let (sub, sup, _) = scripts()
            return .large(words, sub: sub, sup: sup)
        }
        if let accent = Self.accents[name] { return .accent(accent.words, argument(), before: accent.before) }
        switch name {
        case "frac", "cfrac": return .fraction(argument(), argument())
        case "binom", "dbinom", "tbinom": return .binomial(argument(), argument())
        case "sqrt":
            var index: [Node]?
            if peek == .symbol("[") {
                position += 1
                index = sequence { $0 == .symbol("]") }
                if peek == .symbol("]") { position += 1 }
            }
            return .root(argument(), index: index)
        case "lfloor": return fenced(until: .command("rfloor"), .floor)
        case "lceil": return fenced(until: .command("rceil"), .ceiling)
        case "lvert", "vert": return fenced(until: .command(name == "lvert" ? "rvert" : "vert"), .absolute)
        case "langle": return fenced(until: .command("rangle"), .parentheses)
        case "lbrace": return fenced(until: .command("rbrace"), .parentheses)
        case "mathbf", "boldsymbol", "bm", "mathit", "mathsf", "mathcal", "mathbb", "mathfrak", "underline", "boxed", "cancel", "overbrace", "underbrace":
            return .group(argument())
        case "textcolor":
            _ = argument()
            return .group(argument())
        case "color", "hspace", "vspace", "phantom", "label", "tag":
            _ = argument()
            return nil
        case "begin": return table()
        case "end":
            _ = argument()
            return nil
        case "\\": return .pause
        case "%": return .postfix("percent")
        case "$": return .word("$")
        case "circ", "degree": return .postfix("degrees")
        case "prime": return .postfix("prime")
        case "not": return .word("not")
        case "rfloor", "rceil", "rvert", "rangle", "rbrace": return nil
        default: return .word(name)
        }
    }

    /// `\begin{cases} a & b \\ c & d \end{cases}`: rows of cells, up to the matching `\end`.
    mutating func table() -> Node {
        let environment = argument().map { node -> String in
            if case .letter(let letter) = node { return letter }
            return ""
        }.joined()
        // An array's column spec, like {cc}, says nothing.
        if environment == "array", peek == .open { _ = argument() }
        var rows: [[[Node]]] = []
        var row: [[Node]] = []
        while peek != nil {
            let cell = sequence { $0 == .symbol("&") || $0 == .command("\\") || $0 == .command("end") }
            row.append(cell)
            guard let token = peek else { break }
            position += 1
            if token == .command("\\") {
                rows.append(row)
                row = []
            } else if token == .command("end") {
                _ = argument()
                break
            } else if token == .close {
                break
            }
        }
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return .table(environment, rows)
    }

    static let symbols: [String: String] = [
        "alpha": "alpha", "beta": "beta", "gamma": "gamma", "delta": "delta", "epsilon": "epsilon", "varepsilon": "epsilon",
        "zeta": "zeta", "eta": "eta", "theta": "theta", "vartheta": "theta", "iota": "iota", "kappa": "kappa", "lambda": "lambda",
        "mu": "mu", "nu": "nu", "xi": "xi", "omicron": "omicron", "pi": "pi", "varpi": "pi", "rho": "rho", "varrho": "rho",
        "sigma": "sigma", "varsigma": "sigma", "tau": "tau", "upsilon": "upsilon", "phi": "phi", "varphi": "phi", "chi": "chi",
        "psi": "psi", "omega": "omega",
        "Gamma": "gamma", "Delta": "delta", "Theta": "theta", "Lambda": "lambda", "Xi": "xi", "Pi": "pi", "Sigma": "sigma",
        "Upsilon": "upsilon", "Phi": "phi", "Psi": "psi", "Omega": "omega",
        "infty": "infinity", "partial": "partial", "nabla": "del", "hbar": "h bar", "ell": "l", "emptyset": "the empty set",
        "cdots": "and so on", "ldots": "and so on", "dots": "and so on", "vdots": "and so on",
        "therefore": "therefore", "because": "because", "forall": "for all", "exists": "there exists", "angle": "angle",
        "triangle": "triangle", "neg": "not", "lnot": "not",
    ]

    static let operators: [String: Operator] = [
        "times": .factor("times"), "cdot": .factor("times"), "ast": .factor("times"), "div": .factor("divided by"),
        "bmod": .factor("mod"), "mod": .factor("mod"),
        "pm": .term("plus or minus"), "mp": .term("minus or plus"), "land": .term("and"), "wedge": .term("and"),
        "lor": .term("or"), "vee": .term("or"), "cup": .term("union"), "cap": .term("intersect"),
        "ne": .relation("is not equal to"), "neq": .relation("is not equal to"),
        "le": .relation("is less than or equal to"), "leq": .relation("is less than or equal to"), "leqslant": .relation("is less than or equal to"),
        "ge": .relation("is greater than or equal to"), "geq": .relation("is greater than or equal to"), "geqslant": .relation("is greater than or equal to"),
        "lt": .relation("is less than"), "gt": .relation("is greater than"), "ll": .relation("is much less than"), "gg": .relation("is much greater than"),
        "approx": .relation("is approximately"), "simeq": .relation("is approximately"), "sim": .relation("is similar to"),
        "equiv": .relation("is equivalent to"), "propto": .relation("is proportional to"), "cong": .relation("is congruent to"),
        "to": .relation("approaches"), "rightarrow": .relation("approaches"), "longrightarrow": .relation("approaches"),
        "Rightarrow": .relation("which means"), "Longrightarrow": .relation("which means"), "implies": .relation("which means"),
        "Leftrightarrow": .relation("if and only if"), "iff": .relation("if and only if"), "mapsto": .relation("maps to"),
        "in": .relation("is in"), "notin": .relation("is not in"), "subset": .relation("is a subset of"), "subseteq": .relation("is a subset of"),
        "perp": .relation("is perpendicular to"), "parallel": .relation("is parallel to"),
    ]

    static let functions: [String: String] = [
        "sin": "sine", "cos": "cosine", "tan": "tangent", "sec": "secant", "csc": "cosecant", "cot": "cotangent",
        "arcsin": "arc sine", "arccos": "arc cosine", "arctan": "arc tangent",
        "sinh": "hyperbolic sine", "cosh": "hyperbolic cosine", "tanh": "hyperbolic tangent",
        "ln": "the natural log", "log": "log", "lg": "log", "exp": "the exponential", "det": "the determinant",
        "max": "the maximum", "min": "the minimum", "gcd": "the greatest common divisor", "Pr": "the probability", "arg": "the argument",
    ]

    static let large: [String: String] = [
        "sum": "the sum", "prod": "the product", "int": "the integral", "iint": "the double integral", "iiint": "the triple integral",
        "oint": "the contour integral", "lim": "the limit", "bigcup": "the union", "bigcap": "the intersection",
    ]

    static let accents: [String: (words: String, before: Bool)] = [
        "bar": ("bar", false), "overline": ("bar", false), "hat": ("hat", false), "widehat": ("hat", false),
        "tilde": ("tilde", false), "widetilde": ("tilde", false), "dot": ("dot", false), "ddot": ("double dot", false),
        "vec": ("vector", true), "overrightarrow": ("vector", true),
    ]
}

// MARK: - Speaking

private struct Spoken {
    var text: String
    /// Joins terms with plus, equals and the like, so inside something larger it has to be held
    /// together: "the quantity a plus b", "a plus b, all over c".
    var isCompound = false
    /// Several things side by side ("2 a"), which a listener hears as one.
    var isPlural = false
    /// Reaches further than a listener can hear, like "the square root of b squared minus 4 a c";
    /// a pause after it marks the end.
    var needsPause = false
}

private enum Speaker {
    static func speak(_ nodes: [Node]) -> Spoken {
        var words: [String] = []
        var compound = false
        var operands = 0
        var pause = false
        var afterOperand = false
        var single: Spoken?
        var index = 0

        func add(_ spoken: Spoken) {
            if pause, !words.isEmpty { words[words.count - 1] += "," }
            words.append(spoken.text)
            pause = spoken.needsPause
            afterOperand = true
            operands += 1
            single = spoken
        }

        while index < nodes.count {
            let node = nodes[index]
            index += 1
            switch node {
            case .op(let op):
                // Any sign between two things makes a compound; a sign at the start is just minus.
                if afterOperand { compound = true }
                if pause, !words.isEmpty { words[words.count - 1] += "," }
                pause = false
                // -3 is "negative 3"; a - 3 and -b are "minus".
                if !afterOperand, op.words == "minus", index < nodes.count, case .number = nodes[index] {
                    words.append("negative")
                } else {
                    words.append(op.words)
                }
                afterOperand = false
            case .pause:
                if !words.isEmpty { words[words.count - 1] += "," }
                pause = false
                afterOperand = false
            case .postfix(let word):
                // (n - 1)! is "the quantity n minus 1, factorial".
                if pause, !words.isEmpty { words[words.count - 1] += "," }
                pause = false
                words.append(word)
            case .large(let name, let sub, let sup):
                if pause, !words.isEmpty { words[words.count - 1] += "," }
                pause = false
                words.append((afterOperand ? "times " : "") + large(name, sub: sub, sup: sup))
                afterOperand = false
                operands += 1
            case .function(let name, let sub, let sup):
                // What it applies to: the brackets after it, or the term up to the next sign.
                var argument: [Node] = []
                if index < nodes.count, case .fenced(let inner, .parentheses) = nodes[index] {
                    argument = inner
                    index += 1
                } else {
                    while index < nodes.count, isOperand(nodes[index]) {
                        argument.append(nodes[index])
                        index += 1
                    }
                }
                let spoken = speak(argument)
                var phrase = function(name, sub: sub, sup: sup)
                if !spoken.text.isEmpty { phrase += " of " + spoken.text }
                add(Spoken(text: phrase, needsPause: spoken.isCompound || spoken.isPlural || spoken.needsPause))
            case .letter, .name, .scripted(.letter, nil, nil, _):
                // f(x) is "f of x"; so is y(t). P(1 + r) is a product.
                if index < nodes.count, case .fenced(let inner, .parentheses) = nodes[index], applies(node, to: inner) {
                    index += 1
                    let spoken = speak(inner)
                    add(Spoken(text: "\(item(node).text) of \(spoken.text)", needsPause: spoken.isCompound || spoken.isPlural || spoken.needsPause))
                } else {
                    add(item(node))
                }
            case _ where opensWithBrackets(node):
                // Brackets right after a term multiply it.
                var spoken = item(node)
                if afterOperand { spoken.text = "times " + spoken.text }
                add(spoken)
            case .fraction(let numerator, let denominator):
                if let derivative = derivative(numerator, denominator), derivative.hasSuffix(" of") {
                    // d/dx applies to what follows, like a sum.
                    if pause, !words.isEmpty { words[words.count - 1] += "," }
                    pause = false
                    words.append(derivative)
                    afterOperand = false
                    operands += 1
                } else if let derivative = derivative(numerator, denominator) {
                    add(Spoken(text: derivative, isPlural: true, needsPause: true))
                } else {
                    add(item(node))
                }
            default:
                add(item(node))
            }
        }
        // One item alone keeps what it is: a fraction is still a fraction inside brackets.
        if operands == 1, !compound, let single {
            return Spoken(text: words.joined(separator: " "), isCompound: single.isCompound, isPlural: single.isPlural, needsPause: pause)
        }
        return Spoken(text: words.joined(separator: " "), isCompound: compound, isPlural: operands > 1, needsPause: pause)
    }

    /// Whether a name followed by brackets is a function applied to them.
    private static func applies(_ node: Node, to inner: [Node]) -> Bool {
        switch node {
        case .name: return true
        case .scripted(_, _, _, let primes) where primes > 0: return true
        case .letter(let letter) where ["f", "g", "h"].contains(letter): return true
        case .letter: return inner.count == 1 && isOperand(inner[0])
        default: return false
        }
    }

    /// (a + b), (a + b)², and the same in braces, as formulas are written out.
    private static func opensWithBrackets(_ node: Node) -> Bool {
        switch node {
        case .fenced(_, .parentheses): true
        case .scripted(let base, _, _, _): opensWithBrackets(base)
        case .group(let inner): inner.count == 1 && opensWithBrackets(inner[0])
        default: false
        }
    }

    private static func isOperand(_ node: Node) -> Bool {
        switch node {
        case .op, .pause, .function, .large, .postfix: false
        default: true
        }
    }

    /// One item, said on its own.
    static func item(_ node: Node) -> Spoken {
        switch node {
        case .number(let digits):
            return Spoken(text: digits)
        case .letter(let letter):
            // Said as a word, "a" would be "uh".
            return Spoken(text: letter.lowercased() == "a" ? "ay" : letter)
        case .word(let words), .name(let words):
            return Spoken(text: words.trimmingCharacters(in: .whitespaces), isPlural: words.contains(" "))
        case .op(let op):
            return Spoken(text: op.words)
        case .group(let inner):
            return speak(inner)
        case .fenced(let inner, let fence):
            let spoken = speak(inner)
            switch fence {
            case .parentheses:
                guard spoken.isCompound || spoken.isPlural else { return spoken }
                return Spoken(text: "the quantity " + spoken.text, isPlural: true, needsPause: true)
            case .absolute: return held("the absolute value of", spoken)
            case .floor: return held("the floor of", spoken)
            case .ceiling: return held("the ceiling of", spoken)
            }
        case .fraction(let numerator, let denominator):
            if let simple = simpleFraction(numerator, denominator) { return Spoken(text: simple) }
            let top = speak(numerator)
            let bottom = speak(denominator)
            let over = top.isCompound || top.needsPause ? ", all over " : " over "
            let under = bottom.isCompound ? "the quantity " + bottom.text : bottom.text
            // After "all over", only a pause says where the bottom ends.
            return Spoken(text: top.text + over + under, isPlural: true, needsPause: over != " over " || bottom.isCompound || bottom.isPlural || bottom.needsPause)
        case .root(let radicand, let index):
            let degree = index.map { speak($0).text } ?? "2"
            let name = switch degree {
            case "2": "the square root of"
            case "3": "the cube root of"
            default: "the \(ordinal(degree)) root of"
            }
            return held(name, speak(radicand))
        case .scripted(let base, let sub, let sup, let primes):
            return scripted(base, sub: sub, sup: sup, primes: primes)
        case .function(let name, let sub, let sup):
            return Spoken(text: function(name, sub: sub, sup: sup))
        case .large(let name, let sub, let sup):
            return Spoken(text: large(name, sub: sub, sup: sup))
        case .accent(let words, let inner, let before):
            let spoken = speak(inner).text
            return Spoken(text: before ? "\(words) \(spoken)" : "\(spoken) \(words)")
        case .binomial(let top, let bottom):
            return Spoken(text: "\(speak(top).text) choose \(speak(bottom).text)", isPlural: true)
        case .table(let environment, let rows):
            let spokenRows = rows.map { row in
                row.map { speak($0).text }.filter { !$0.isEmpty }.joined(separator: environment.contains("matrix") ? ", " : " ")
            }.filter { !$0.isEmpty }
            let separator = environment.contains("matrix") ? "; " : ", "
            let prefix = environment.contains("matrix") ? "the matrix " : ""
            return Spoken(text: prefix + spokenRows.joined(separator: separator), isPlural: true, needsPause: true)
        case .postfix(let words):
            return Spoken(text: words)
        case .pause:
            return Spoken(text: ",")
        }
    }

    /// Something that applies to what follows it, like a root: it needs a pause after a long argument.
    private static func held(_ name: String, _ spoken: Spoken) -> Spoken {
        Spoken(text: "\(name) \(spoken.text)", needsPause: spoken.isCompound || spoken.isPlural || spoken.needsPause)
    }

    private static func scripted(_ base: Node, sub: [Node]?, sup: [Node]?, primes: Int) -> Spoken {
        var spoken = item(base)
        var text = spoken.text
        if let sub, !sub.isEmpty {
            let index = speak(sub)
            text += index.isCompound ? " sub \(index.text)," : " \(index.text)"
        }
        if primes > 0 { text += [" prime", " double prime", " triple prime"][min(primes, 3) - 1] }
        var needsPause = spoken.needsPause && sup == nil
        if let sup, !sup.isEmpty {
            // The quantity (1 + r), squared: the pause says the power is on all of it.
            if spoken.needsPause { text += "," }
            let power = speak(sup)
            switch power.text {
            case "2": text += " squared"
            case "3": text += " cubed"
            case "degrees", "prime": text += " " + power.text
            default:
                text += " to the power of " + power.text
                needsPause = power.isCompound || power.isPlural || power.needsPause
            }
        }
        spoken.text = text
        spoken.needsPause = needsPause
        spoken.isPlural = spoken.isPlural || sup != nil
        return spoken
    }

    private static func function(_ name: String, sub: [Node]?, sup: [Node]?) -> String {
        var text = name
        if let sub, !sub.isEmpty { text += name == "log" ? " base " + speak(sub).text : " " + speak(sub).text }
        if let sup, !sup.isEmpty {
            let power = speak(sup).text
            text += power == "2" ? " squared" : power == "3" ? " cubed" : power == "minus 1" ? " inverse" : " to the power of \(power)"
        }
        return text
    }

    private static func large(_ name: String, sub: [Node]?, sup: [Node]?) -> String {
        let lower = sub.map { speak($0).text } ?? ""
        let upper = sup.map { speak($0).text } ?? ""
        if name == "the limit" { return lower.isEmpty ? "the limit of" : "the limit as \(lower) of" }
        switch (lower.isEmpty, upper.isEmpty) {
        case (false, false): return "\(name) from \(lower) to \(upper) of"
        case (false, true): return "\(name) over \(lower) of"
        case (true, false): return "\(name) up to \(upper) of"
        case (true, true): return "\(name) of"
        }
    }

    /// d/dx, dy/dx, d²y/dx², ∂f/∂x.
    private static func derivative(_ numerator: [Node], _ denominator: [Node]) -> String? {
        func isD(_ node: Node) -> (partial: Bool, order: String?)? {
            switch node {
            case .letter("d"): return (false, nil)
            case .word("partial"): return (true, nil)
            case .scripted(.letter("d"), nil, let sup?, 0): return (false, speak(sup).text)
            case .scripted(.word("partial"), nil, let sup?, 0): return (true, speak(sup).text)
            default: return nil
            }
        }
        guard let top = numerator.first.flatMap(isD), denominator.count >= 2, let bottom = isD(denominator[0]), top.partial == bottom.partial else { return nil }
        var variable = denominator[1]
        if case .scripted(let base, nil, _?, 0) = variable { variable = base }
        let respect = item(variable).text
        let order = ["2": "second ", "3": "third "][top.order ?? ""] ?? ""
        let kind = top.partial ? "partial derivative" : "derivative"
        let of = speak(Array(numerator.dropFirst())).text
        return of.isEmpty ? "the \(order)\(kind) with respect to \(respect) of" : "the \(order)\(kind) of \(of) with respect to \(respect)"
    }

    /// 1/2 is one half, 3/4 three quarters.
    private static func simpleFraction(_ numerator: [Node], _ denominator: [Node]) -> String? {
        guard numerator.count == 1, denominator.count == 1, case .number(let top) = numerator[0], case .number(let bottom) = denominator[0],
              let n = Int(top), let d = Int(bottom), (1...9).contains(n), (2...10).contains(d) else { return nil }
        let names = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let parts = [2: "half", 3: "third", 4: "quarter", 5: "fifth", 6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth"]
        guard let part = parts[d] else { return nil }
        let plural = n == 1 ? part : part == "half" ? "halves" : part + "s"
        return "\(names[n]) \(plural)"
    }

    private static func ordinal(_ degree: String) -> String {
        switch degree {
        case "4": "fourth"
        case "5": "fifth"
        default: "\(degree)th"
        }
    }
}
