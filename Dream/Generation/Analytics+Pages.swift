import Foundation
import FoundationModels

extension Composer {
    /// Counts a finished page or change made here (Analytics.swift): its shape, the model, how
    /// long it took and how it was made, stage by stage, never its words.
    func countFinished(changing: Bool, pointed: Bool = false, since started: Date) {
        guard let surface else { return }
        let seconds = Date().timeIntervalSince(started)
        var run = run
        run.quotaApproaching = AppleModels.isApproachingQuota(active)
        Analytics.send(changing
            ? .pageChanged(Analytics.Shape(surface), pointedAtBlock: pointed, seconds: seconds)
            : .pageBuilt(Analytics.Shape(surface), model: modelName, seconds: seconds, run: run))
        Analytics.send(.pageTrace(trace: run.trace, seconds: seconds, level: run.level, failed: false))
    }

    func countFailure(_ error: Error, changing: Bool, since started: Date, stage: String = "") {
        let seconds = Date().timeIntervalSince(started)
        Analytics.send(.pageFailed(Analytics.Failure(error), changing: changing, seconds: seconds, run: changing ? nil : run, stage: stage))
        Analytics.send(.pageTrace(trace: run.trace, seconds: seconds, level: run.level, failed: true))
    }

    /// One model call, for PostHog's LLM analytics: the step, the model, how long, and roughly
    /// how many tokens it read and wrote, from the characters (about 3.2 to a token).
    func countGeneration(_ step: String, seconds: Double, budget: ContextBudget?, output: Int, failed: Bool = false) {
        let read = (budget?.fixed ?? 0) + (budget?.returned ?? 0) + 1_000
        let input = read / 3, written = output / 3
        run.generations += 1
        run.inputTokens += input
        run.outputTokens += written
        Analytics.send(.generation(Analytics.Generation(trace: run.trace, step: step, model: active.name, seconds: seconds, inputTokens: input,
                                                        outputTokens: written, reasoning: active == .privateCloud ? reasoningName : "none", level: run.level, failed: failed)))
    }
}

extension Analytics.Failure {
    /// The kind of failure, from the error's type alone. Its message can quote what was asked
    /// for, so it's never sent.
    @MainActor init(_ error: Error) {
        switch error {
        case is CancellationError:
            self = .cancelled
        case let error as LanguageModelError:
            switch error {
            case .guardrailViolation: self = .safetyFilter
            case .contextSizeExceeded: self = .tooBig
            case .rateLimited: self = .rateLimited
            default: self = .model
            }
        case is URLError:
            self = .network
        case let error as PrivateCloudComputeLanguageModel.Error:
            if case .quotaLimitReached = error { self = .rateLimited } else { self = .network }
        case is ComposeError:
            self = Composer.canCompose ? .empty : .noModel
        default:
            self = .other
        }
    }
}
