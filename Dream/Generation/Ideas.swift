import Foundation
import FoundationModels
import Observation

/// A few things to try, written for this moment and for what the user has been making, so the
/// home screen shows what's possible and where to go next instead of explaining it. Made on the
/// iPhone, which is free and private, once per part of the day and whenever the pages made
/// lately change.
@MainActor @Observable
final class Ideas {
    private(set) var items: [String] = []

    @Generable
    struct WireIdeas {
        @Guide(description: "Short, specific requests, under 8 words each", .count(4))
        var ideas: [String]
    }

    /// What the user made lately, for suggestions that go on from it: the titles of their own
    /// latest and starred pages, with what each is about.
    static func lately(_ pages: [SavedSurface]) -> [String] {
        let own = pages.filter { $0.sharedFrom == nil }
        let chosen = own.filter(\.isStarred).prefix(2) + own.filter { !$0.isStarred }.prefix(4)
        return chosen.map { page in
            let about = page.subjects.isEmpty ? "" : " (about \(page.subjects.prefix(3).joined(separator: ", ")))"
            return page.surface.title + about
        }
    }

    func load(after lately: [String] = []) async {
        let defaults = UserDefaults.standard
        let key = Self.momentKey + "|" + lately.joined(separator: "|")
        if defaults.string(forKey: "ideasMoment") == key, let cached = defaults.stringArray(forKey: "ideas"), !cached.isEmpty {
            items = cached
            return
        }
        // Yesterday's, while new ones are written.
        if items.isEmpty, let cached = defaults.stringArray(forKey: "ideas") { items = cached }
        guard SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(instructions: """
            You suggest things to try in an app that turns any request into an interactive screen: an explanation, a calculator, or both. Each suggestion is a request someone would type, specific and concrete, never a question about the app.
            """)
        let place = Locale.current.region.flatMap { Locale.current.localizedString(forRegionCode: $0.identifier) } ?? "the world"
        let moment = "It's \(Self.weekday) \(Self.partOfDay) in \(place)."
        let prompt = lately.isEmpty
            ? "\(moment) Suggest 4 requests someone might make right now: two questions about the world, and two things to work out with numbers. Make them varied and specific."
            : """
            \(moment) Lately they made these pages: \(lately.joined(separator: "; ")).
            Suggest 4 requests: two that go on from those pages (the next thing to know about one, or the same for another case, naming it), one question about the world they might like, and one thing to work out with numbers for this moment. Make them varied and specific, and never repeat a page they already made.
            """
        guard let response = try? await session.respond(to: prompt, generating: WireIdeas.self, options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 200)) else { return }
        let fresh = response.content.ideas
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"."))) }
            .filter { !$0.isEmpty }
        guard !fresh.isEmpty else { return }
        items = fresh
        defaults.set(items, forKey: "ideas")
        defaults.set(key, forKey: "ideasMoment")
    }

    private static var momentKey: String {
        Date.now.formatted(.iso8601.year().month().day()) + "-" + partOfDay
    }

    private static var weekday: String {
        Date.now.formatted(.dateTime.weekday(.wide))
    }

    private static var partOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
    }
}
