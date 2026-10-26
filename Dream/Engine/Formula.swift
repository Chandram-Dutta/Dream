import Foundation

/// A parsed formula. Deliberately small: arithmetic, comparisons, conditionals and the usual
/// maths functions. That's enough for tools and for exploring maths and science, and simple
/// enough for a small model to write correctly.
indirect enum Expr: Hashable {
    case number(Double)
    case name(String)
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case conditional(Expr, Expr, Expr)
    case call(String, [Expr])
}

struct FormulaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Expr {
    static let functions: Set<String> = [
        "min", "max", "round", "floor", "ceil", "abs", "sqrt", "cbrt", "pow", "exp", "log", "ln", "log10", "log2",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "hypot",
        "sign", "mod", "fact", "choose", "if", "clamp", "sum", "avg",
    ]

    /// Names every formula can use. An input or output with the same name wins.
    static let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]

    static func parse(_ source: String) throws -> Expr {
        var parser = Parser(tokens: try tokenize(source))
        guard !parser.tokens.isEmpty else { throw FormulaError("the formula is empty") }
        let expr = try parser.parse(0)
        if let extra = parser.peek { throw FormulaError("unexpected \(extra)") }
        return expr
    }

    /// Input and output names the formula refers to.
    var names: Set<String> {
        switch self {
        case .number: return []
        case .name(let name): return [name]
        case .unary(_, let operand): return operand.names
        case .binary(_, let lhs, let rhs): return lhs.names.union(rhs.names)
        case .conditional(let condition, let then, let otherwise):
            return condition.names.union(then.names).union(otherwise.names)
        case .call(_, let arguments): return arguments.reduce(into: []) { $0.formUnion($1.names) }
        }
    }

    var functionNames: Set<String> {
        switch self {
        case .number, .name: return []
        case .unary(_, let operand): return operand.functionNames
        case .binary(_, let lhs, let rhs): return lhs.functionNames.union(rhs.functionNames)
        case .conditional(let condition, let then, let otherwise):
            return condition.functionNames.union(then.functionNames).union(otherwise.functionNames)
        case .call(let function, let arguments):
            return arguments.reduce(into: [function]) { $0.formUnion($1.functionNames) }
        }
    }

    func renamed(_ names: [String: String]) -> Expr {
        switch self {
        case .number: return self
        case .name(let name): return .name(names[name] ?? name)
        case .unary(let op, let operand): return .unary(op, operand.renamed(names))
        case .binary(let op, let lhs, let rhs): return .binary(op, lhs.renamed(names), rhs.renamed(names))
        case .conditional(let condition, let then, let otherwise):
            return .conditional(condition.renamed(names), then.renamed(names), otherwise.renamed(names))
        case .call(let function, let arguments): return .call(function, arguments.map { $0.renamed(names) })
        }
    }

    /// Booleans are numbers: comparisons give 1 or 0, and anything non-zero is true.
    func evaluate(_ lookup: (String) throws -> Double) throws -> Double {
        switch self {
        case .number(let value):
            return value
        case .name(let name):
            return try lookup(name)
        case .unary(let op, let operand):
            let value = try operand.evaluate(lookup)
            return op == "!" ? (value == 0 ? 1 : 0) : -value
        case .binary(let op, let lhs, let rhs):
            let a = try lhs.evaluate(lookup)
            let b = try rhs.evaluate(lookup)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return a / b
            case "%": return a.truncatingRemainder(dividingBy: b)
            case "^": return Foundation.pow(a, b)
            case "<": return a < b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "&&": return a != 0 && b != 0 ? 1 : 0
            case "||": return a != 0 || b != 0 ? 1 : 0
            default: throw FormulaError("unknown operator \(op)")
            }
        case .conditional(let condition, let then, let otherwise):
            return try condition.evaluate(lookup) != 0 ? then.evaluate(lookup) : otherwise.evaluate(lookup)
        case .call("if", let arguments):
            guard arguments.count == 3 else { throw FormulaError("if() needs a condition and two values") }
            return try arguments[0].evaluate(lookup) != 0 ? arguments[1].evaluate(lookup) : arguments[2].evaluate(lookup)
        case .call(let function, let arguments):
            let values = try arguments.map { try $0.evaluate(lookup) }
            func needs(_ count: Int) throws {
                guard values.count == count else {
                    throw FormulaError("\(function)() needs \(count) value\(count == 1 ? "" : "s")")
                }
            }
            switch function {
            case "min":
                guard let result = values.min() else { throw FormulaError("min() needs values") }
                return result
            case "max":
                guard let result = values.max() else { throw FormulaError("max() needs values") }
                return result
            case "sum":
                return values.reduce(0, +)
            case "avg":
                guard !values.isEmpty else { throw FormulaError("avg() needs values") }
                return values.reduce(0, +) / Double(values.count)
            case "round":
                if values.count == 2 {
                    let scale = Foundation.pow(10, values[1].rounded())
                    return (values[0] * scale).rounded() / scale
                }
                try needs(1)
                return values[0].rounded()
            case "floor": try needs(1); return Foundation.floor(values[0])
            case "ceil": try needs(1); return Foundation.ceil(values[0])
            case "abs": try needs(1); return Swift.abs(values[0])
            case "sqrt": try needs(1); return values[0].squareRoot()
            case "pow": try needs(2); return Foundation.pow(values[0], values[1])
            case "log":
                if values.count == 2 { return Foundation.log(values[0]) / Foundation.log(values[1]) }
                try needs(1)
                return Foundation.log(values[0])
            case "ln": try needs(1); return Foundation.log(values[0])
            case "log10": try needs(1); return Foundation.log10(values[0])
            case "log2": try needs(1); return Foundation.log2(values[0])
            case "exp": try needs(1); return Foundation.exp(values[0])
            case "cbrt": try needs(1); return Foundation.cbrt(values[0])
            case "sin": try needs(1); return Foundation.sin(values[0])
            case "cos": try needs(1); return Foundation.cos(values[0])
            case "tan": try needs(1); return Foundation.tan(values[0])
            case "asin": try needs(1); return Foundation.asin(values[0])
            case "acos": try needs(1); return Foundation.acos(values[0])
            case "atan": try needs(1); return Foundation.atan(values[0])
            case "atan2": try needs(2); return Foundation.atan2(values[0], values[1])
            case "sinh": try needs(1); return Foundation.sinh(values[0])
            case "cosh": try needs(1); return Foundation.cosh(values[0])
            case "tanh": try needs(1); return Foundation.tanh(values[0])
            case "hypot": try needs(2); return Foundation.hypot(values[0], values[1])
            case "sign": try needs(1); return values[0] > 0 ? 1 : values[0] < 0 ? -1 : 0
            case "mod": try needs(2); return values[0] - values[1] * Foundation.floor(values[0] / values[1])
            case "fact":
                try needs(1)
                guard values[0] >= 0 else { return .nan }
                return Foundation.tgamma(values[0] + 1)
            case "choose":
                try needs(2)
                let (n, k) = (values[0], values[1])
                guard k >= 0, n >= k else { return 0 }
                return (Foundation.exp(Foundation.lgamma(n + 1) - Foundation.lgamma(k + 1) - Foundation.lgamma(n - k + 1))).rounded()
            case "clamp": try needs(3); return Swift.min(Swift.max(values[0], values[1]), values[2])
            default: throw FormulaError("unknown function \(function)()")
            }
        }
    }
}

extension Expr: CustomStringConvertible {
    var description: String { render(0) }

    private func render(_ parent: Int) -> String {
        switch self {
        case .number(let value):
            return value.plain
        case .name(let name):
            return name
        case .unary(let op, let operand):
            let text = op + operand.render(Parser.prefixPower)
            return Parser.prefixPower < parent ? "(\(text))" : text
        case .binary(let op, let lhs, let rhs):
            let power = Parser.infix[op] ?? (0, 0)
            let leftAssociative = power.right > power.left
            let text = "\(lhs.render(leftAssociative ? power.left : power.left + 1)) \(op) \(rhs.render(leftAssociative ? power.right : power.left))"
            return power.left < parent ? "(\(text))" : text
        case .conditional(let condition, let then, let otherwise):
            let text = "\(condition.render(Parser.conditionalPower + 1)) ? \(then.render(0)) : \(otherwise.render(Parser.conditionalPower))"
            return Parser.conditionalPower < parent ? "(\(text))" : text
        case .call(let function, let arguments):
            return "\(function)(\(arguments.map { $0.render(0) }.joined(separator: ", ")))"
        }
    }
}

/// Formulas are re-evaluated on every slider tick and chart sample, so parse each once.
enum FormulaCache {
    nonisolated(unsafe) private static var parsed: [String: Result<Expr, FormulaError>] = [:]
    private static let lock = NSLock()

    static func parse(_ source: String) throws -> Expr {
        lock.lock()
        defer { lock.unlock() }
        if let hit = parsed[source] { return try hit.get() }
        if parsed.count > 4000 { parsed.removeAll() }
        let result = Result { try Expr.parse(source) }.mapError { $0 as? FormulaError ?? FormulaError("\($0)") }
        parsed[source] = result
        return try result.get()
    }
}

private enum Token: Equatable, CustomStringConvertible {
    case number(Double)
    case name(String)
    case symbol(String)

    var description: String {
        switch self {
        case .number(let value): return value.plain
        case .name(let name): return "'\(name)'"
        case .symbol(let symbol): return "'\(symbol)'"
        }
    }
}

private func tokenize(_ source: String) throws -> [Token] {
    let characters = Array(source)
    var tokens: [Token] = []
    var index = 0
    func at(_ position: Int) -> Character? { position < characters.count ? characters[position] : nil }
    func isDigit(_ character: Character?) -> Bool { character.map { $0.isASCII && $0.isNumber } ?? false }

    while let character = at(index) {
        if character.isWhitespace || character == "$" {
            index += 1
            continue
        }
        if isDigit(character) || (character == "." && isDigit(at(index + 1))) {
            var end = index
            while let next = at(end), isDigit(next) || next == "." || next == "_" { end += 1 }
            if let e = at(end), e == "e" || e == "E",
               isDigit(at(end + 1)) || ((at(end + 1) == "-" || at(end + 1) == "+") && isDigit(at(end + 2))) {
                end += 2
                while isDigit(at(end)) { end += 1 }
            }
            let text = String(characters[index..<end]).replacingOccurrences(of: "_", with: "")
            guard let value = Double(text) else { throw FormulaError("can't read the number \(text)") }
            tokens.append(.number(value))
            index = end
            continue
        }
        if character.isLetter || character == "_" {
            var end = index
            while let next = at(end), next.isLetter || next.isNumber || next == "_" || next == "." { end += 1 }
            var word = String(characters[index..<end])
            if word.lowercased().hasPrefix("math.") { word = String(word.dropFirst(5)) }
            switch word.lowercased() {
            case "and": tokens.append(.symbol("&&"))
            case "or": tokens.append(.symbol("||"))
            case "not": tokens.append(.symbol("!"))
            case "true": tokens.append(.number(1))
            case "false": tokens.append(.number(0))
            case "pi": tokens.append(.name("pi"))
            default: tokens.append(.name(word))
            }
            index = end
            continue
        }
        if let next = at(index + 1) {
            let pair = String([character, next])
            if ["<=", ">=", "==", "!=", "&&", "||", "**"].contains(pair) {
                tokens.append(.symbol(pair == "**" ? "^" : pair))
                index += 2
                continue
            }
        }
        switch character {
        case "+", "-", "*", "/", "%", "^", "(", ")", ",", "?", ":", "<", ">", "!":
            tokens.append(.symbol(String(character)))
        case "=": tokens.append(.symbol("=="))
        case "×", "·": tokens.append(.symbol("*"))
        case "÷": tokens.append(.symbol("/"))
        case "−", "–": tokens.append(.symbol("-"))
        case "≤": tokens.append(.symbol("<="))
        case "≥": tokens.append(.symbol(">="))
        case "≠": tokens.append(.symbol("!="))
        default: throw FormulaError("unexpected character '\(character)'")
        }
        index += 1
    }
    return tokens
}

/// A Pratt parser. Binding powers: left < right means left-associative.
private struct Parser {
    let tokens: [Token]
    var position = 0

    static let infix: [String: (left: Int, right: Int)] = [
        "||": (3, 4), "&&": (5, 6),
        "==": (7, 8), "!=": (7, 8),
        "<": (9, 10), "<=": (9, 10), ">": (9, 10), ">=": (9, 10),
        "+": (11, 12), "-": (11, 12),
        "*": (13, 14), "/": (13, 14), "%": (13, 14),
        "^": (18, 17),
    ]
    static let prefixPower = 15
    static let conditionalPower = 1

    var peek: Token? { position < tokens.count ? tokens[position] : nil }

    mutating func advance() -> Token? {
        defer { position += 1 }
        return peek
    }

    mutating func expect(_ symbol: String) throws {
        guard advance() == .symbol(symbol) else { throw FormulaError("expected '\(symbol)'") }
    }

    mutating func parse(_ minimumPower: Int) throws -> Expr {
        var lhs = try parsePrefix()
        while case .symbol(let op)? = peek {
            if op == "?" {
                guard Self.conditionalPower >= minimumPower else { break }
                position += 1
                let then = try parse(0)
                try expect(":")
                lhs = .conditional(lhs, then, try parse(Self.conditionalPower))
                continue
            }
            guard let power = Self.infix[op], power.left >= minimumPower else { break }
            position += 1
            lhs = .binary(op, lhs, try parse(power.right))
        }
        return lhs
    }

    mutating func parsePrefix() throws -> Expr {
        guard let token = advance() else { throw FormulaError("the formula ends too early") }
        switch token {
        case .number(let value):
            return .number(value)
        case .name(let name):
            guard peek == .symbol("(") else { return .name(name) }
            position += 1
            var arguments: [Expr] = []
            if peek == .symbol(")") {
                position += 1
                return .call(name.lowercased(), arguments)
            }
            while true {
                arguments.append(try parse(0))
                guard let next = advance() else { throw FormulaError("missing ')'") }
                if next == .symbol(")") { return .call(name.lowercased(), arguments) }
                guard next == .symbol(",") else { throw FormulaError("expected ',' or ')' but found \(next)") }
            }
        case .symbol("("):
            let inner = try parse(0)
            try expect(")")
            return inner
        case .symbol(let op) where op == "-" || op == "+" || op == "!":
            let operand = try parse(Self.prefixPower)
            return op == "+" ? operand : .unary(op, operand)
        default:
            throw FormulaError("unexpected \(token)")
        }
    }
}
