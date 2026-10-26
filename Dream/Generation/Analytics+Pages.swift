import Foundation
import FoundationModels

extension Composer {
    /// Counts a finished page or change (Analytics.swift): its shape, the model and how long it
    /// took, never its words.
    func countFinished(changing: Bool, pointed: Bool = false, since started: Date) {
        guard let surface else { return }
        let seconds = Date().timeIntervalSince(started)
        Analytics.send(changing
            ? .pageChanged(Analytics.Shape(surface), pointedAtBlock: pointed, seconds: seconds)
            : .pageBuilt(Analytics.Shape(surface), model: modelName, seconds: seconds))
    }

    func countFailure(_ error: Error, changing: Bool, since started: Date) {
        Analytics.send(.pageFailed(Analytics.Failure(error), changing: changing, seconds: Date().timeIntervalSince(started)))
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
        case is XAIError:
            self = .model
        case is ComposeError:
            self = Composer.canCompose ? .empty : .noModel
        default:
            self = .other
        }
    }
}
