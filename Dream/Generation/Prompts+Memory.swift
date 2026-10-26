import Foundation

// User memory and questions (ROADMAP.md, workstream 1).

extension Prompts {
    /// When and how to ask the user something before building, and how to use what Dream remembers.
    static var memoryRules: String {
        """
        Asking first: once it's built, the screen can't ask the user anything; there's no chat. So before building, you can ask up to 3 quick questions with the ask tool, once. Ask only about what decides what the screen is about, when a wrong guess would build the wrong screen:
        - the request names something with several unrelated meanings, and each would be a screen about a different subject (Java: the island or the language);
        - or it's about the user's own plans, and without details only they know you'd build a generic screen or one that tells them what to provide (a revision plan needs which exam, and when it is).
        Never build a screen that asks the user for details or tells them what to provide.
        Never ask for a value the screen can let them change, like an amount, a count, a rate or a number of days: start it at a sensible value and give it a control. Never ask for what the lookup can find, or for what Dream remembers. When one meaning is far more likely, or a sensible default exists, build without asking. Most requests need no questions.
        Each question offers 2 to 4 short answers to tap; "You choose" is always added, so leave it out. Allow typing only when no short list could cover the answer, like a place. Mark a question personal only when its answer is a lasting fact about the user, like where they live, their diet or their household.
        When the user answers "You choose", pick what's most likely. Build for their answers without remarking on them.
        Remembered details: when Dream lists what it remembers about the user, and one would change this screen, get it with the recall tool before building, and build for it.
        """
    }

    /// What Dream remembers about the user, as topics only: the model fetches a detail with the
    /// recall tool when it matters to this request (see `Recall`). Then a reminder beside the
    /// request that it can ask first, since a quick model easily skips rules at the end of a long
    /// prompt.
    static func memoryContext(for intent: String) async -> [String] {
        let topics = await Recall.source.topics()
        let remembered = topics.isEmpty ? [] : ["Dream remembers these about the user: \(topics.joined(separator: ", "))."]
        return remembered + ["Before building a new screen: if a wrong guess about what this means, or about plans only the user knows, would build the wrong screen, ask first with the ask tool. Never ask about anything a control or the lookup can handle."]
    }

    /// What the ask tool hands back to the model.
    static func answered(_ answers: [Answer]) -> String {
        let lines = answers.map { answer in
            "- \(answer.question.text) \(answer.isLeftToDream ? "You choose: pick what's most likely." : answer.choice)"
        }
        return "The user answered:\n\(lines.joined(separator: "\n"))\nBuild the screen for these answers. Don't ask again."
    }

    /// A change to one of the answers a surface was built from, in the user's words.
    static func changedAnswer(_ answer: Answer, to choice: String) -> String {
        let before = answer.isLeftToDream ? "I left it to you" : "I said \(answer.choice)"
        let now = choice.isEmpty ? "Choose for me instead" : "I mean \(choice)"
        return "\(now). (You asked \(answer.question.text) and \(before).) Rebuild the screen for that."
    }
}
