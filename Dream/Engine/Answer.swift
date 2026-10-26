import Foundation

/// A question the model asked before building, because a wrong guess would have built the wrong
/// screen: which Mercury, or where a trip goes.
struct Question: Codable, Hashable {
    var text: String
    /// What it's about, in a word or two, like Destination. Shown on the answer's tag, and what a
    /// personal answer is remembered under.
    var topic: String
    /// Short answers to tap. "You choose" is always offered as well.
    var options: [String]
    /// No short list could cover the answer, like a place, so the user can type one.
    var allowsTyping = false
    /// The answer is a lasting fact about the user, like their diet, so it's worth remembering.
    var isPersonal = false
}

/// What the user said to one question. Kept on the surface, so its header shows the answers and
/// they can be changed later. Personal ones belong to the user: leave them out when sharing.
struct Answer: Codable, Hashable {
    var question: Question
    /// What they tapped or typed. Empty when they left it to Dream.
    var choice: String

    var isLeftToDream: Bool { choice.isEmpty }
}

extension Question {
    /// Every question can be left to Dream.
    var leftToDream: Answer { Answer(question: self, choice: "") }
}

extension Surface {
    /// The same surface, carrying the answers it was built from.
    func answered(_ answers: [Answer]) -> Surface {
        var surface = self
        surface.answers = answers.isEmpty ? nil : answers
        return surface
    }
}
