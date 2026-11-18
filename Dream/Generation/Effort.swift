import Foundation
import FoundationModels
import NaturalLanguage

/// How much a request needs, so an easy one is quick and a hard one gets the time it's worth.
/// Every request used to go the same way: understood first, then written with the whole brief,
/// every kind of block, every tool and light reasoning. "Square root of 9" took 16.8 seconds.
///
/// - instant: a sum, answered by Dream itself (InstantPage.swift), or a saved page made again
///   with the request's numbers (PageReuse.swift). No model.
/// - quick: a calculation with its numbers given: written straight away, without understanding
///   it first, with the short brief and the narrower page (DeviceSurface), and no tools.
/// - standard: understood first, then written with everything.
/// - deep: as standard, with more reasoning and room for more calls, for a request that asks
///   for depth: comparing, planning, researching.
///
/// The level comes from the request's words alone, which costs nothing. It errs towards more:
/// anything that may need looking up, the user's own things or a name goes the standard way.
enum Effort {
    enum Level: String, Sendable {
        case instant, reused, quick, standard, deep
    }

    /// The level a request starts at.
    static func level(for request: String, hasImage: Bool) -> Level {
        guard !hasImage else { return .standard }
        let text = " " + request.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if deepWords.contains(where: { text.contains($0) }) { return .deep }
        return isQuick(text, original: request) ? .quick : .standard
    }

    /// A calculation with its numbers in it, about nothing that needs looking up.
    private static func isQuick(_ text: String, original: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "%" }.map(String.init)
        guard words.count <= 24, text.contains(where: \.isNumber) else { return false }
        guard calculationWords.contains(where: { word in words.contains { $0 == word || ($0.hasPrefix(word) && $0.count <= word.count + 3) } })
                || text.contains("%") else { return false }
        // Anything current, about the world, or the user's own things in a service needs a look.
        if lookingWords.contains(where: { text.contains($0) }) { return false }
        if Connections.source.connections().contains(where: { $0.isOn && text.contains(" " + $0.name.lowercased()) }) { return false }
        // Money between currencies needs today's rate.
        if text.contains(#/\b(?:to|in|into)\s+(?:usd|inr|eur|gbp|jpy|aed|dollars?|rupees?|euros?|pounds?|yen)\b/#) { return false }
        // A name (a place, a person, a company) may need looking up: "rent in Bandra". EMI,
        // GST and BMI read as names too, but they're what's being worked out.
        return names(in: original).allSatisfy { name in
            name.lowercased().split(separator: " ").allSatisfy { calculationWords.contains(String($0)) }
        }
    }

    private static func names(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { found.append(String(text[range])) }
            return true
        }
        return found
    }

    /// Words that ask for working something out.
    private static let calculationWords = [
        "split", "tip", "emi", "loan", "mortgage", "interest", "compound", "sip", "invest", "savings", "save", "budget",
        "salary", "tax", "gst", "vat", "discount", "percent", "percentage", "average", "mean", "bmi", "calorie",
        "monthly", "yearly", "weekly", "rent", "fuel", "mileage", "speed", "profit", "margin", "markup", "cost", "price",
        "each", "share", "divide", "ratio", "area", "volume", "perimeter", "circumference", "hypotenuse", "triangle",
        "circle", "radius", "calculate", "calculator", "convert", "how much", "how many", "per", "total", "sum", "multiply",
        "times", "plus", "minus", "root", "squared", "power", "factorial", "probability", "odds", "payback", "inflation", "depreciation",
    ]

    /// Words that mean the page needs to look something up first.
    private static let lookingWords = [
        " latest", " today", " tonight", " tomorrow", " current", " now ", " news", " price of", " weather", " rate of exchange", "exchange rate",
        " my notes", " my notion", " my project", " my issues", " my tasks", " who ", " when did", " history", " why ", " explain", " how does",
        " how do ", " what is a ", " what are ", " best ", " compare", " vs ", " versus ", " near ", " nearby", " stock", " share price",
    ]

    /// Words that ask for depth.
    private static let deepWords = [
        " in depth", " in-depth", " detailed", " thorough", " think hard", " deep dive", " research ", " compare ", " comparison",
        " pros and cons", " step by step", " plan my", " plan a ", " analyse", " analyze", " analysis",
    ]
}

extension Effort.Level {
    /// How much Private Cloud Compute reasons before writing, at this level. The setting in
    /// Under the hood (`AppleModels.reasoning`) can raise it, never lower it.
    var reasoning: Effort.Reasoning {
        switch self {
        case .instant, .reused, .quick: .light
        case .standard: .light
        case .deep: .moderate
        }
    }

    /// How many tool calls writing may make.
    var calls: Int { self == .deep ? 20 : 14 }
}

extension Effort {
    /// The reasoning levels, in order, so one can be raised to another.
    enum Reasoning: Int, Comparable, Sendable {
        case light, moderate, deep

        static func < (a: Reasoning, b: Reasoning) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .light: "light"
            case .moderate: "moderate"
            case .deep: "deep"
            }
        }
    }
}

extension Effort.Reasoning {
    init(_ level: ContextOptions.ReasoningLevel) {
        switch level {
        case .moderate: self = .moderate
        case .deep: self = .deep
        default: self = .light
        }
    }

    var level: ContextOptions.ReasoningLevel {
        switch self {
        case .light: .light
        case .moderate: .moderate
        case .deep: .deep
        }
    }
}
