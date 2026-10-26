import Foundation
import FoundationModels
import Observation

/// The model's questions for one request, and the user's answers. While the questions are on
/// screen the model waits inside the ask tool; answering lets it carry on.
@MainActor @Observable
final class Asking {
    enum Answerer {
        /// The questions go on screen and the model waits for the user.
        case user
        /// Nobody to ask, as on the bench: every question is left to the model.
        case model
    }

    /// The app sets this at launch. The bench has no screen, so by default the model chooses.
    static var answerer = Answerer.model
    /// For unattended runs on a device: questions left unanswered this long go to the model.
    static var patience: Duration?

    /// What the model is waiting on, or nil.
    private(set) var questions: [Question]?
    /// The answers this surface is built from.
    private(set) var answers: [Answer] = []
    /// One round per request, and none while changing a surface.
    private var isOpen = true
    private var continuation: CheckedContinuation<[Answer], Never>?

    var isWaiting: Bool { questions != nil }

    /// A new request: nothing asked yet.
    func start() {
        cancel()
        answers = []
        isOpen = true
    }

    /// Changing a surface: its answers carry over, and there's no asking.
    func start(keeping answers: [Answer]?) {
        cancel()
        self.answers = answers ?? []
        isOpen = false
    }

    /// The answers, or nil when it isn't the time to ask.
    func ask(_ questions: [Question]) async -> [Answer]? {
        guard isOpen, continuation == nil else { return nil }
        isOpen = false
        guard Self.answerer == .user, !Task.isCancelled else {
            answers = questions.map(\.leftToDream)
            return answers
        }
        if let patience = Self.patience {
            Task {
                try? await Task.sleep(for: patience)
                if self.questions == questions { self.cancel() }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.questions = questions
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// From the screen, once every question has an answer.
    func answer(_ answers: [Answer]) {
        guard let continuation else { return }
        self.continuation = nil
        self.answers = answers
        questions = nil
        // The model has been waiting on the user, not stalling.
        ModelActivity.touch()
        continuation.resume(returning: answers)
    }

    /// Leaves whatever's still open to the model, so it never waits on a screen that's gone.
    func cancel() {
        guard let questions else { return }
        answer(questions.map(\.leftToDream))
    }
}

/// Lets the model ask the user a few quick questions before it builds, when a wrong guess would
/// build the wrong screen. Its call waits until the user answers. `Prompts.memoryRules` says when.
struct AskTool: Tool {
    let asking: Asking
    /// Told what was asked and answered, for the log.
    var onAsk: @Sendable (String) -> Void = { _ in }
    let name = "ask"
    let description = "Asks the user up to 3 quick questions and waits for their answers. Call it before writing anything when a wrong guess would build the wrong screen: a name with unrelated meanings, or their own plans that need details only they know. The screen itself can never ask them. Never for a value a control can hold. At most once."

    @Generable
    struct Arguments {
        @Guide(description: "1 to 3 questions", .count(1...3))
        var questions: [WireQuestion]
    }

    @Generable
    struct WireQuestion {
        @Guide(description: "Short and plain, like 'Which Java?'")
        var question: String
        @Guide(description: "What it's about, in 1 to 3 words, like Subject, Destination or Diet")
        var topic: String
        @Guide(description: "2 to 4 short answers to tap, without 'You choose', which is always added. When typing, up to 4 likely ones.", .count(0...4))
        var options: [String]
        @Guide(description: "True when the answer is a lasting fact about the user, like where they live, their diet or their household. False for anything about this request alone.")
        var personal: Bool
        @Guide(description: "True only when no short list could cover the answer, like a place, so the user can type it")
        var typing: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let questions = arguments.questions.prefix(3).compactMap(Question.init)
        guard !questions.isEmpty else { return "There was nothing to ask. Build the screen." }
        onAsk("Asked: " + questions.map { "\($0.text) (\($0.options.joined(separator: " / "))\($0.allowsTyping ? ", or typed" : ""))" }.joined(separator: "; "))
        guard let answers = await asking.ask(questions) else {
            onAsk("Didn't ask: not the time.")
            return "You can't ask now. Build the screen, choosing what's most likely."
        }
        onAsk("Answered: " + answers.map { $0.isLeftToDream ? "You choose" : $0.choice }.joined(separator: "; "))
        return Prompts.answered(answers)
    }
}

extension Question {
    /// What the model wrote, tidied: options it shouldn't have offered are dropped, and a question
    /// left with too few options to tap takes a typed answer instead.
    init?(_ wire: AskTool.WireQuestion) {
        let text = wire.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var seen: Set<String> = []
        let options = wire.options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isYouChoose($0) && seen.insert($0.lowercased()).inserted }
        let topic = wire.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            text: text,
            topic: topic.isEmpty ? text : topic,
            options: Array(options.prefix(4)),
            allowsTyping: wire.typing || options.count < 2,
            isPersonal: wire.personal)
    }

    private static func isYouChoose(_ option: String) -> Bool {
        let plain = option.lowercased().filter(\.isLetter)
        return ["youchoose", "youdecide", "surpriseme", "dontmind", "anything", "either"].contains(plain)
    }
}

extension Composer {
    /// Rebuilds a surface for a different answer to one of the questions asked before building
    /// it, through the same path as any other change.
    func rebuild(_ current: Surface, intent: String, changing answer: Answer, to choice: String) async {
        let answers = (current.answers ?? []).map { $0.question == answer.question ? Answer(question: $0.question, choice: choice) : $0 }
        await edit(current.answered(answers), intent: intent, instruction: Prompts.changedAnswer(answer, to: choice), focus: nil)
    }
}
