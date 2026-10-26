import Foundation
import NaturalLanguage

// Language and locale (ROADMAP.md, workstream 4): which language a request and a surface are
// in, which languages this reader reads, and the text a translation changes.

/// The language and measurement system a surface was written for.
struct SurfaceLocale: Codable, Hashable {
    /// A BCP 47 code, like en, hi or zh-Hans.
    var language: String
    /// A `Locale.MeasurementSystem` identifier: metric, ussystem or uksystem.
    var measurementSystem: String
}

extension SurfaceLocale {
    /// What a finished surface was written in. The language comes from its own text, which is
    /// long enough to tell reliably, unlike a request of a word or two; `likely` (the request's)
    /// settles a close call, and `fallback` is used when nothing can be told. Its everyday units
    /// follow the reader's measurement system, except that an edit keeps those of what it changed.
    init(written surface: Surface, likely: String?, fallback: String, editing earlier: SurfaceLocale? = nil) {
        self.init(
            language: Languages.of(surface, likely: likely)?.rawValue ?? fallback,
            measurementSystem: earlier?.measurementSystem ?? Locale.current.measurementSystem.identifier)
    }
}

enum Languages {
    /// The request's language, when the recognizer is sure of it. A word or two ("Mercury",
    /// "Ada Lovelace") isn't enough to tell, so then the model tells from the request itself.
    static func of(request: String) -> NLLanguage? {
        guard let language = guess(request) else { return nil }
        // Languages typed in Latin letters read as some other one: Hindi as Indonesian. So a
        // Latin-script language is only believed when it's in the reader's Settings or their
        // region speaks it.
        let code = Locale.Language(identifier: language.rawValue).languageCode?.identifier ?? language.rawValue
        if isLatin(request), !settings.contains(where: { same($0, language.rawValue) }), !regional.contains(code) { return nil }
        return language
    }

    /// The recognizer's answer for a request, when it's sure, before anything else is weighed.
    static func guess(_ request: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = hints()
        recognizer.processString(request)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.9 else { return nil }
        return language
    }

    private static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.filter(CharacterSet.letters.contains).allSatisfy { $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    /// The language a surface is written in, from its sentences, since labels like "Triangle
    /// rectangle" can belong to several languages. Maths and live values are left out. A page
    /// of text needs no hints, and they'd only tip close languages, like Spanish into Catalan;
    /// `likely` is only used when the text can't settle it.
    static func of(_ surface: Surface, likely: String? = nil) -> NLLanguage? {
        let texts = surface.readableTexts.map { text in
            Placeholders.parts(text).compactMap { part -> String? in
                if case .text(let prose) = part { return prose }
                return nil
            }.joined()
        }
        let sentences = texts.filter { $0.split(separator: " ").count >= 4 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString((sentences.isEmpty ? texts : sentences).joined(separator: "\n"))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (best, confidence) = hypotheses.max(by: { $0.value < $1.value }) else { return likely.map { NLLanguage(rawValue: $0) } }
        if confidence < 0.6, let likely, hypotheses[NLLanguage(likely)] != nil { return NLLanguage(likely) }
        return best
    }

    /// How likely each language is before a word is read: the reader's own in Settings first,
    /// then their region's, then any other. Without this, short requests like "Ada Lovelace"
    /// read as Indonesian. Languages they've asked in before aren't counted, so a misreading
    /// can't make itself more likely next time.
    private static func hints() -> [NLLanguage: Double] {
        var hints = Dictionary(uniqueKeysWithValues: recognized.map { (NLLanguage($0), 0.05) })
        // Only languages the recognizer knows: hinting others, like many of India's, skews it
        // so far that Spanish can read as English.
        for code in regional where recognized.contains(code) { hints[NLLanguage(code)] = 0.3 }
        for code in settings where recognized.contains(code) { hints[NLLanguage(code)] = 1 }
        return hints
    }

    /// The languages NaturalLanguage tells apart.
    private static let recognized: Set<String> = [
        "am", "ar", "bg", "bn", "bo", "ca", "chr", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "gu", "he", "hi", "hr",
        "hu", "hy", "id", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "lo", "ml", "mn", "mr", "ms", "my", "nb", "nl", "or",
        "pa", "pl", "pt", "ro", "ru", "si", "sk", "sv", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Languages spoken in the reader's region, by CLDR's reckoning.
    private static let regional: Set<String> = {
        guard let region = Locale.current.region else { return [] }
        return Set(Locale.availableIdentifiers.map(Locale.init).filter { $0.region == region }.compactMap { $0.language.languageCode?.identifier })
    }()

    // MARK: - The reader

    /// The languages this reader reads: theirs in Settings, and any they've asked Dream
    /// something in. Launch with `-DreamReadIn de` to read only German, for trying translation.
    static var reader: [String] {
        guard !isOverridden else { return settings }
        var seen: Set<String> = []
        return (settings + asked).filter { seen.insert($0).inserted }
    }

    /// The reader's languages in Settings.
    private static var settings: [String] {
        if let only = Build.argument("DreamReadIn") { return [recognizerCode(only)] }
        return Locale.preferredLanguages.map(recognizerCode)
    }

    /// A language as the recognizer names it: Chinese by its script, any other by its code.
    private static func recognizerCode(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return identifier }
        guard code == "zh" else { return code }
        return Locale.Language(identifier: language.maximalIdentifier).script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
    }

    /// Languages the reader has asked Dream something in.
    private static var asked: [String] {
        isOverridden ? [] : UserDefaults.standard.stringArray(forKey: "requestLanguages") ?? []
    }

    private static var isOverridden: Bool {
        Build.argument("DreamReadIn") != nil
    }

    /// The language a surface in another one is translated into.
    static var primary: String { reader.first ?? "en" }

    static func reads(_ language: String) -> Bool {
        reader.contains { same($0, language) }
    }

    /// Remembers a language the reader asked in, so what they make in it is never translated.
    static func remember(_ language: String) {
        guard !reads(language) else { return }
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: "requestLanguages") ?? []) + [language], forKey: "requestLanguages")
    }

    /// The same language in the same script: English in India and in the US are one; Chinese
    /// in simplified and traditional characters are two.
    static func same(_ a: String, _ b: String) -> Bool {
        let (first, second) = (Locale.Language(identifier: a), Locale.Language(identifier: b))
        func script(_ language: Locale.Language) -> Locale.Script? { Locale.Language(identifier: language.maximalIdentifier).script }
        return first.languageCode == second.languageCode && script(first) == script(second)
    }

    /// A language's name in English, for the model: Hindi.
    static func name(_ language: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
    }

    /// A language's name in the reader's own language, for the screen.
    static func localizedName(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    /// The subdomain of a language's Wikipedia: fr for French.
    static func wikipedia(_ language: String) -> String {
        let code = Locale.Language(identifier: language).languageCode?.identifier ?? "en"
        return ["nb": "no", "fil": "tl"][code] ?? code
    }
}

// MARK: - Text

extension Surface {
    /// A copy with every piece of text the reader sees passed through `transform`, roughly in
    /// reading order: titles, prose and items, then labels and options, then related topics.
    /// Names, formulas, symbols, units, equations and data values aren't text, so they stay as
    /// they are.
    func mappingText(_ transform: (String) -> String) -> Surface {
        var copy = self
        copy.title = transform(title)
        copy.summary = transform(summary)
        copy.blocks = blocks.map { $0.mappingText(transform) }
        for index in copy.inputs.indices {
            copy.inputs[index].label = transform(inputs[index].label)
            copy.inputs[index].options = inputs[index].options.map(transform)
        }
        for index in copy.outputs.indices {
            copy.outputs[index].label = transform(outputs[index].label)
        }
        copy.related = related.map(transform)
        copy.question = question.map(transform)
        return copy
    }

    /// Every piece of text the reader sees, roughly in reading order.
    var readableTexts: [String] {
        var texts: [String] = []
        _ = mappingText { text in
            if !text.isEmpty { texts.append(text) }
            return text
        }
        return texts
    }
}

extension Block {
    func mappingText(_ transform: (String) -> String) -> Block {
        var block = self
        block.title = transform(title)
        // An equation's text is LaTeX.
        if kind != .equation { block.text = transform(text) }
        block.items = items.map { item in
            switch kind {
            // The label is a symbol in LaTeX; the value says what it means.
            case .equation: Item(label: item.label, value: transform(item.value))
            // The value is a plain number the chart reads.
            case .data: Item(label: transform(item.label), value: item.value)
            default: Item(label: transform(item.label), value: transform(item.value))
            }
        }
        block.children = children.map { $0.mappingText(transform) }
        return block
    }
}
