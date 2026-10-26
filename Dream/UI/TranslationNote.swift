import SwiftUI
import Translation

// Translating reused and shared surfaces (ROADMAP.md, workstream 4).

/// Shows a surface in the reader's language when it was written in one they don't read. The
/// translation happens on the phone and only for showing: the saved template stays as it was
/// written, and the original is a tap away.
@MainActor @Observable
final class SurfaceTranslation {
    enum Status: Equatable {
        /// In a language the reader reads, or one that can't be translated.
        case none
        /// The languages aren't on the phone yet; downloading them waits for the reader to ask.
        case offered
        case translating
        case translated
        case original
    }

    private(set) var status = Status.none
    /// The language the surface is written in.
    private(set) var source = ""
    private(set) var configuration: TranslationSession.Configuration?
    private var original: Surface?
    private var translated: Surface?

    private struct Key: Hashable {
        let surface: Surface
        let target: String
    }

    /// Translations made since launch, so going back to a surface doesn't translate it again.
    private static var cache: [Key: Surface] = [:]

    /// The surface as it's shown: translated, as far as it's got, unless the reader asked for
    /// the original.
    func shown(_ surface: Surface) -> Surface {
        guard status == .translated || status == .translating, let translated, surface == original else { return surface }
        return translated
    }

    /// Works out whether a surface needs translating for this reader, and starts when the
    /// languages are already on the phone.
    func prepare(for surface: Surface) async {
        guard surface != original else { return }
        original = surface
        translated = nil
        guard let written = surface.locale?.language, !Languages.reads(written) else {
            status = .none
            return
        }
        source = written
        if let cached = Self.cache[Key(surface: surface, target: Languages.primary)] {
            translated = cached
            status = .translated
            return
        }
        let availability = await LanguageAvailability().status(from: Locale.Language(identifier: written), to: Locale.Language(identifier: Languages.primary))
        guard surface == original else { return }
        switch availability {
        case .installed: translate()
        case .supported: status = .offered
        default: status = .none
        }
    }

    /// Asks for a session, which `.translationTask` hands to `run`. Languages that aren't on
    /// the phone yet are offered for download first, by the system.
    func translate() {
        if translated != nil {
            withAnimation(.smooth) { status = .translated }
            return
        }
        status = .translating
        let (from, to) = (Locale.Language(identifier: source), Locale.Language(identifier: Languages.primary))
        if configuration?.source == from, configuration?.target == to {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: from, target: to)
        }
    }

    func run(_ session: TranslationSession) async {
        guard let surface = original else { return }
        do {
            let result = try await Translator.translate(surface, with: session) { partial in
                guard surface == self.original else { return }
                withAnimation(.smooth) { self.translated = partial }
            }
            guard surface == original else { return }
            Self.cache[Key(surface: surface, target: Languages.primary)] = result
            translated = result
            withAnimation(.smooth) { status = .translated }
        } catch {
            guard surface == original else { return }
            translated = nil
            status = .offered
        }
    }

    func showOriginal() {
        withAnimation(.smooth) { status = .original }
    }
}

extension View {
    /// Translates `surface` for this reader when it's in a language they don't read.
    func translating(_ surface: Surface, with translation: SurfaceTranslation) -> some View {
        task(id: surface) { await translation.prepare(for: surface) }
            .translationTask(translation.configuration) { session in await translation.run(session) }
    }
}

/// A quiet line under the title: the language a surface was written in, and a way to switch.
struct TranslationNote: View {
    let translation: SurfaceTranslation
    let palette: Palette

    var body: some View {
        let language = Languages.localizedName(translation.source)
        HStack(spacing: 6) {
            Image(systemName: "translate")
            switch translation.status {
            case .translated:
                Text("Translated from \(language)")
                switchButton("Show original", action: translation.showOriginal)
            case .translating:
                Text("Translating from \(language)…")
            case .original, .offered:
                Text("Written in \(language)")
                switchButton("Translate", action: translation.translate)
            case .none:
                EmptyView()
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth, value: translation.status)
    }

    private func switchButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .fontWeight(.semibold)
            .foregroundStyle(palette.accent)
            .buttonStyle(.plain)
    }
}
