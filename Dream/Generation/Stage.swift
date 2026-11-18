import Foundation

/// Where a request is, from the moment it's asked to the finished page. The screen's light shows
/// it: each stage has its own colors and motion, so the reader can tell what Dream is doing
/// without reading a word (StageLight.swift).
enum Stage: Equatable, Sendable {
    /// Reading the request and deciding whether anything needs asking.
    case understanding
    /// Waiting on the user: questions, or a connected service's tool to allow.
    case yourTurn
    /// Looking things up: Wikipedia, the web, live data, connected services.
    case researching
    /// The page is being written onto the screen.
    case writing
    /// The checker found something, and the model is fixing it.
    case checking
    case done
    case failed

    /// In a few words, for the Lock Screen and for VoiceOver.
    var label: String {
        switch self {
        case .understanding: "Understanding"
        case .yourTurn: "Waiting for you"
        case .researching: "Looking things up"
        case .writing: "Writing"
        case .checking: "Checking the numbers"
        case .done: "Done"
        case .failed: "Couldn't finish"
        }
    }

    /// Whether Dream is working: everything but the user's turn and the end.
    var isDreamsTurn: Bool {
        switch self {
        case .understanding, .researching, .writing, .checking: true
        case .yourTurn, .done, .failed: false
        }
    }
}
