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
    /// Dream answered it from what it remembers about the user, without asking.
    var isRemembered = false

    var isLeftToDream: Bool { choice.isEmpty }
}

// Answers saved before remembered ones existed decode with the default.
extension Answer {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(Question.self, forKey: .question)
        choice = try container.decode(String.self, forKey: .choice)
        isRemembered = try container.decodeIfPresent(Bool.self, forKey: .isRemembered) ?? false
    }
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
