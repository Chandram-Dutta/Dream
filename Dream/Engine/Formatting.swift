import Foundation

enum Currency {
    static var code: String { Locale.current.currency?.identifier ?? "USD" }
    static var symbol: String { Locale.current.currencySymbol ?? "$" }

    /// Whether a unit is an ISO currency code, like USD: money in a currency other than the
    /// user's, as a converter shows it.
    static func isCode(_ unit: String) -> Bool {
        unit.count == 3 && unit == unit.uppercased() && Locale.commonISOCurrencyCodes.contains(unit)
    }

    /// The symbol for a currency, as this reader writes it: $ for USD in the US, US$ elsewhere.
    static func symbol(for code: String) -> String {
        guard code != self.code else { return symbol }
        return 0.formatted(.currency(code: code).precision(.fractionLength(0))).filter { !$0.isNumber && !$0.isWhitespace }
    }
}

extension Double {
    /// Compact and lossless, for prompts and formulas: 12 rather than 12.0.
    var plain: String {
        self == rounded() && Swift.abs(self) < 1e15 ? String(Int64(self)) : String(self)
    }
}

extension Format {
    func display(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch self {
        case .currency:
            return Self.money(value, code: Currency.code)
        case .percent:
            return (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
        case .integer:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .toggle:
            return value != 0 ? "On" : "Off"
        case .number, .choice:
            return Self.number(value)
        }
    }

    /// Whole amounts from a thousand up; cents below that, unless there are none.
    static func money(_ value: Double, code: String) -> String {
        let whole = Swift.abs(value) >= 1000 || value == value.rounded()
        return value.formatted(.currency(code: code).precision(.fractionLength(whole ? 0 : 2)))
    }

    /// Two decimals for everyday sizes; significant digits for small ones, so 1/440 isn't 0;
    /// powers of ten for the very large and very small.
    private static func number(_ value: Double) -> String {
        let magnitude = Swift.abs(value)
        guard magnitude != 0, magnitude < 1e-4 || magnitude >= 1e12 else {
            return magnitude < 1 && magnitude != 0
                ? value.formatted(.number.precision(.significantDigits(1...3)))
                : value.formatted(.number.precision(.fractionLength(0...2)))
        }
        let exponent = Int(Foundation.floor(Foundation.log10(magnitude)))
        let mantissa = (value / Foundation.pow(10, Double(exponent))).formatted(.number.precision(.significantDigits(1...3)))
        let superscripts: [Character: Character] = ["-": "⁻", "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return "\(mantissa) × 10" + String(String(exponent).compactMap { superscripts[$0] })
    }
}

extension Surface {
    func display(_ name: String, _ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if let input = input(name), input.format == .choice {
            let index = Int(exactly: value.rounded()) ?? -1
            return input.options.indices.contains(index) ? input.options[index] : "—"
        }
        // With its unit, in the reader's units (Units.swift).
        return reading(name, value).text
    }
}

/// Text with `{name}` placeholders that show live values, and maths between `$` signs.
/// Braces inside maths are LaTeX, never placeholders.
enum Placeholders {
    enum Part: Hashable {
        case text(String)
        case name(String)
        case math(String)
    }

    static func parts(_ text: String) -> [Part] {
        TeX.segments(text).flatMap { segment -> [Part] in
            switch segment {
            case .math(let tex): return [.math(tex)]
            case .text(let prose): return names(in: prose)
            }
        }
    }

    private static func names(in text: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { parts.append(.text(String(rest[..<open]))) }
            let name = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            parts.append(name.isEmpty ? .text("{}") : .name(name))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return parts
    }

    static func join(_ parts: [Part]) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .name(let name): "{\(name)}"
            case .math(let tex): "$\(tex)$"
            }
        }.joined()
    }
}
