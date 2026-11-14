import Foundation

// User memory and questions (ROADMAP.md, workstream 1).

extension Prompts {
    /// How to use the answers to questions asked before building, and what Dream remembers.
    /// Asking itself happens in the gap check, with its own instructions (`gapCheck`).
    static var memoryRules: String {
        """
        The screen can't ask the user anything once it's built; there's no chat. Never build one that asks for details or tells them what to provide: when something's missing, choose what's most likely, and give values a control.
        When the request comes with the user's answers to questions asked first, build for them without remarking on them. "You choose" means pick what's most likely.
        Remembered details: when Dream lists what it remembers about the user, and one would change this screen, get it with the recall tool before building, and build for it.
        """
    }

    /// What Dream remembers about the user, as topics only: the model fetches a detail with the
    /// recall tool when it matters to this request (see `Recall`).
    static func memoryContext(for intent: String) async -> [String] {
        let topics = await Recall.source.topics()
        guard !topics.isEmpty else { return [] }
        return ["Dream remembers these about the user: \(topics.joined(separator: ", "))."]
    }

    // MARK: - The gap check

    /// Instructions for understanding a request: find out what it refers to, then ask only
    /// what's still open.
    static let gapCheck = """
        You read a request to an app before it builds one interactive screen to answer it. The screen can't ask the user anything, so first understand the request, then find what's still open that only the user can tell and that changes which screen to build, and return questions for it: none, or up to 3.
        Understand it before you ask. Read all its words. When it's about the user's own things (their notes, projects, documents, tasks, messages, files) and a connected service has tools for them, look there first, so you know what they have: their projects by name, the pages that match. When a name could mean several unrelated things and the words don't settle it, look it up. Use tools only when what they return would change what you ask or what the screen is built from, and at most 3 calls. Most requests need none: a clear subject, a calculation or a how-to.
        Then write what you found that the screen should be built from, and ask only what you couldn't find out. Offer as answers the real things you found, like the user's actual project names, never guesses. If what you found settles it, ask nothing.
        Ask when:
        - it names something with unrelated meanings, each a screen about a different subject (Mercury: the planet, the element or the god);
        - it's about the user's own plans, tastes or situation, and leaves out what decides the screen (where and when for a trip, whose occasion a party is for, which kind of budget, what they're in the mood for).
        Never ask for:
        - anything the screen can let them set or switch: an amount, a rate, a count, a length of time, or a choice between ways of working it out. Those get a control that starts at a sensible value;
        - what the user fills in on the screen themselves, like a list's items or their own entries;
        - facts anyone could look up, like dates, definitions, figures or how something works;
        - anything the request already says.
        Most requests need none. A clear subject, an explanation, a how-to or a calculator gets no questions.
        Each question is short and plain, with 2 to 4 short answers to tap; "You choose" is always added, so leave it out. Allow typing only when no short list could cover the answer, like a place. Mark a question personal when its answer is a lasting fact about the user, like where they live, their diet or their household. If a topic Dream remembers answers a question, name that topic.
        """

    static func gapRequest(_ intent: String, remembering topics: [String], recent: [String] = [], related: [String] = [], place: String? = nil) -> String {
        var parts = ["Request: \(intent)"]
        if let place, !place.isEmpty {
            parts.append("The user is in \(place), so a request about the weather, places nearby or local prices is about there unless it names somewhere else.")
        }
        if !recent.isEmpty {
            parts.append("Pages the user made in the last few hours, newest first: \(recent.joined(separator: "; ")). They can settle what a short request means. They aren't answers to offer: a request that names what it's about needs no question about it.")
        }
        if !related.isEmpty {
            parts.append("Pages the user made before that may be about the same things, with what was found for them:\n\(related.map { "- " + $0 }.joined(separator: "\n"))\nIf one is clearly what the request means, read it that way and use what was found, looking again only for more than that, instead of asking.")
        }
        if !topics.isEmpty {
            parts.append("Dream remembers these about the user: \(topics.joined(separator: ", ")).")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The answers, next to the request, when the main generation starts again with them.
    static func answersContext(_ answers: [Answer]) -> [String] {
        guard !answers.isEmpty else { return [] }
        let lines = answers.map { answer in
            let said = answer.isLeftToDream ? "You choose: pick what's most likely." : answer.choice
            return "- \(answer.question.text) \(said)\(answer.isRemembered ? " (from what Dream remembers)" : "")"
        }
        return ["Before building, the user answered:\n\(lines.joined(separator: "\n"))\nBuild the screen for these answers."]
    }

    /// A change to one of the answers a surface was built from, in the user's words.
    static func changedAnswer(_ answer: Answer, to choice: String) -> String {
        let before = answer.isLeftToDream ? "I left it to you" : "I said \(answer.choice)"
        let now = choice.isEmpty ? "Choose for me instead" : "I mean \(choice)"
        return "\(now). (You asked \(answer.question.text) and \(before).) Rebuild the screen for that."
    }
}
