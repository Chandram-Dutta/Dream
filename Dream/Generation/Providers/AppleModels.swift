import Foundation
import FoundationModels

/// What Dream needs to know about Apple's two models: whether they can be used, why not, how much
/// Private Cloud Compute reasons, and when a failure is worth handing to the other one.
///
/// Every page is written by Apple's models: the larger one on Private Cloud Compute, whose
/// requests run on Apple silicon servers that keep nothing and that no one, Apple included, can
/// read; or the one on the iPhone itself. Dream has no model of its own and no model provider.
enum AppleModels {
    /// Whether this build carries the Private Cloud Compute entitlement. Asking PCC anything
    /// without it stops the app, so a build signed without it (DREAM_PRIVATE_CLOUD = NO, like a
    /// test copy on a Mac whose profile lacks it) never touches PCC and writes on the device.
    static let isCloudEntitled: Bool = {
        #if os(iOS)
        (Bundle.main.object(forInfoDictionaryKey: "DreamPrivateCloud") as? String).map { $0 != "NO" } ?? true
        #else
        // The Mac bench runs unsigned, so PCC is only tried when asked for (`-provider privateCloud`).
        Build.setting("provider") == "privateCloud"
        #endif
    }()

    /// Private Cloud Compute, when this build may use it and it's there.
    static var cloudIsAvailable: Bool { isCloudEntitled && PrivateCloudComputeLanguageModel().isAvailable }

    /// How much Private Cloud Compute reasons before writing a page. Testing builds can pick one
    /// at launch (`-reasoning light|moderate|deep`).
    static var reasoning: ContextOptions.ReasoningLevel {
        switch Build.setting("reasoning") {
        case "moderate": .moderate
        case "deep": .deep
        default: .light
        }
    }

    /// Whether a page that failed on one model might work on the other: PCC couldn't be reached,
    /// was busy or this account's share is used up for now; or the iPhone's model ran out of room.
    /// Not when the safety filter stepped in, which the other model would most likely do too.
    static func isWorthTheOtherModel(_ error: Error) -> Bool {
        if error is PrivateCloudComputeLanguageModel.Error { return true }
        if let error = error as? LanguageModelError {
            if case .guardrailViolation = error { return false }
            return true
        }
        return !(error is CancellationError)
    }

    /// Why neither model can write a page, in plain words for the screen.
    static var unavailableMessage: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple Intelligence isn't ready yet. Try again in a moment."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to make pages."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready on this iPhone. Try again soon."
        case .unavailable(.deviceNotEligible):
            return "Dream needs an iPhone with Apple Intelligence."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    /// A line about Private Cloud Compute for Under the hood and the account screen.
    static var cloudStatus: String {
        guard isCloudEntitled else { return "Not in this build" }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            if model.quotaUsage.isLimitReached {
                if let reset = model.quotaUsage.resetDate {
                    return "Used up until \(reset.formatted(date: .omitted, time: .shortened)). Pages are made on this iPhone until then."
                }
                return "Used up for now. Pages are made on this iPhone until then."
            }
            if case .belowLimit(let below) = model.quotaUsage.status, below.isApproachingLimit {
                return "Available, close to the limit for now"
            }
            return "Available"
        case .unavailable(.deviceNotEligible): return "Not on this device"
        case .unavailable(.systemNotReady): return "Getting ready"
        case .unavailable: return "Unavailable"
        }
    }

    /// A line about the on-device model, for Under the hood.
    static var deviceStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Available"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off"
        case .unavailable(.modelNotReady): "Downloading"
        case .unavailable(.deviceNotEligible): "Not on this device"
        case .unavailable: "Unavailable"
        }
    }

    /// When PCC's share has run out, the system's own sheet offering more, if it has one.
    static func offerMoreIfLimited(_ error: Error) -> Bool {
        guard isCloudEntitled, let error = error as? PrivateCloudComputeLanguageModel.Error,
              case .quotaLimitReached(let reached) = error,
              let suggestion = reached.limitIncreaseSuggestion else { return false }
        suggestion.show()
        return true
    }

    /// Whether this account is near its share of Private Cloud Compute for now, for analytics.
    @MainActor static func isApproachingQuota(_ provider: Composer.Provider) -> Bool {
        guard provider == .privateCloud, cloudIsAvailable else { return false }
        switch PrivateCloudComputeLanguageModel().quotaUsage.status {
        case .belowLimit(let below): return below.isApproachingLimit
        case .limitReached: return true
        @unknown default: return false
        }
    }
}
