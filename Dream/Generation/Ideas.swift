import Foundation
import FoundationModels
import Observation

/// A few things to try, written for this moment, so the home screen shows what's possible
/// instead of explaining it. Made once per part of the day and remembered until the next.
@MainActor @Observable
final class Ideas {
    private(set) var items: [String] = []

    @Generable
    struct WireIdeas {
        @Guide(description: "Short, specific requests, under 7 words each", .count(4))
        var ideas: [String]
    }

    func load() async {
        let defaults = UserDefaults.standard
        let key = Self.momentKey
        if defaults.string(forKey: "ideasMoment") == key, let cached = defaults.stringArray(forKey: "ideas"), !cached.isEmpty {
            items = cached
            return
        }
        guard SystemLanguageModel.default.isAvailable else { return }
        let session = LanguageModelSession(instructions: """
            You suggest things to try in an app that turns any request into an interactive screen: an explanation, a calculator, or both.
            """)
        let place = Locale.current.region.flatMap { Locale.current.localizedString(forRegionCode: $0.identifier) } ?? "the world"
        let prompt = """
            It's \(Self.weekday) \(Self.partOfDay) in \(place). Suggest 4 requests someone might make right now: \
            two questions about the world, and two things to work out with numbers. Make them varied and specific.
            """
        guard let response = try? await session.respond(to: prompt, generating: WireIdeas.self, options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 160)) else { return }
        items = response.content.ideas
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"."))) }
            .filter { !$0.isEmpty }
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
