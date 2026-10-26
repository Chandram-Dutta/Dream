import Foundation
import Observation

/// The questions for one request, and the answers. The gap check (`GapCheck`) finds them; what
/// Dream remembers answers some at once, and the rest wait on screen for the user.
@MainActor @Observable
final class Asking {
    enum Answerer {
        /// The questions go on screen and building waits for the user.
        case user
        /// Nobody to ask, as on the bench: every question is left to the model.
        case model
    }

    /// The app sets this at launch. The bench has no screen, so by default the model chooses.
    static var answerer = Answerer.model
    /// For unattended runs on a device: questions left unanswered this long go to the model.
    static var patience: Duration?

    /// What's waiting on the user, or nil.
    private(set) var questions: [Question]?
    /// The answers this surface is built from: remembered ones first, then the user's.
    private(set) var answers: [Answer] = []
    private var continuation: CheckedContinuation<[Answer], Never>?

    var isWaiting: Bool { questions != nil }

    /// A new request: nothing asked yet.
    func start() {
        cancel()
        answers = []
    }

    /// Changing a surface: its answers carry over, and there's no asking.
    func start(keeping answers: [Answer]?) {
        cancel()
        self.answers = answers ?? []
    }

    /// Every question answered: those in `known` already, the rest by the user.
    func ask(_ questions: [Question], knowing known: [Answer]) async -> [Answer] {
        answers = known
        let open = questions.filter { question in !known.contains { $0.question == question } }
        guard !open.isEmpty, continuation == nil else { return answers }
        guard Self.answerer == .user, !Task.isCancelled else {
            answers += open.map(\.leftToDream)
            return answers
        }
        if let patience = Self.patience {
            Task {
                try? await Task.sleep(for: patience)
                if self.questions == open { self.cancel() }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.questions = open
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// From the screen, once every open question has an answer.
    func answer(_ picked: [Answer]) {
        guard let continuation else { return }
        self.continuation = nil
        answers += picked
        questions = nil
        continuation.resume(returning: answers)
    }

    /// Leaves whatever's still open to the model, so building never waits on a screen that's gone.
    func cancel() {
        guard let questions else { return }
        answer(questions.map(\.leftToDream))
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
