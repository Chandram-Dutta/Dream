import Foundation
import Translation

/// Translates a surface's text on the phone, with Apple's Translation framework, so a surface
/// written in one language can be read in another without sending it anywhere.
///
/// Each piece of text is translated whole, so the translator sees full sentences, but live
/// values (`{name}`) and maths (`$...$`) are marked to be skipped, and a translation that
/// changed any of them is dropped. Names, formulas and units aren't text, so they never change,
/// and neither does the saved template.
enum Translator {
    /// Translating takes about a second a piece, so `progress` gets the surface as each one
    /// arrives, in reading order, and the page changes language from the top down.
    @MainActor
    static func translate(_ surface: Surface, with session: TranslationSession, progress: (Surface) -> Void = { _ in }) async throws -> Surface {
        var seen: Set<String> = []
        let texts = readingOrder(surface).filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }
        guard !texts.isEmpty else { return surface }
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: marked(text), clientIdentifier: String(index))
        }
        var translations: [String: String] = [:]
        for try await response in session.translate(batch: requests) {
            guard let index = response.clientIdentifier.flatMap(Int.init), texts.indices.contains(index) else { continue }
            let translated = response.attributedTargetText.map { String($0.characters) } ?? response.targetText
            guard keepsValuesAndMaths(texts[index], translated) else { continue }
            translations[texts[index]] = capitalized(translated, like: texts[index])
            progress(surface.mappingText { translations[$0] ?? $0 })
        }
        return surface.mappingText { translations[$0] ?? $0 }
    }

    /// Translators lowercase a word on its own ("Distance" → "distance"); a label keeps its capital.
    private static func capitalized(_ translated: String, like original: String) -> String {
        guard let first = original.first, first.isUppercase, let start = translated.first, start.isLowercase else { return translated }
        return start.uppercased() + translated.dropFirst()
    }

    /// Texts in the order they're on screen, with each block's labels beside it, so the top of
    /// the page changes first. Anything not shown comes last.
    private static func readingOrder(_ surface: Surface) -> [String] {
        var texts = [surface.title, surface.summary]
        func visit(_ block: Block) {
            for name in block.refs + [block.over] where !name.isEmpty {
                texts.append(surface.label(of: name))
                texts += surface.input(name)?.options ?? []
            }
            var own = block
            own.children = []
            _ = own.mappingText { text in
                texts.append(text)
                return text
            }
            block.children.forEach(visit)
        }
        surface.displayBlocks.forEach(visit)
        return texts + surface.readableTexts
    }

    /// The text, with its live values and maths marked to be left as they are.
    static func marked(_ text: String) -> AttributedString {
        Placeholders.parts(text).reduce(into: AttributedString()) { result, part in
            var piece = AttributedString(Placeholders.join([part]))
            if case .text = part {} else { piece.translation.skipsTranslation = true }
            result += piece
        }
    }

    /// Whether every live value and piece of maths came through exactly once, unchanged.
    static func keepsValuesAndMaths(_ original: String, _ translated: String) -> Bool {
        func fixed(_ text: String) -> [Placeholders.Part: Int] {
            Placeholders.parts(text).reduce(into: [:]) { counts, part in
                if case .text = part { return }
                counts[part, default: 0] += 1
            }
        }
        return fixed(original) == fixed(translated)
    }
}
