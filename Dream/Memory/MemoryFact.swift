import Foundation
import SwiftData

/// One thing Dream knows about the user, kept on the phone and apart from any surface.
///
/// The model is told only the topic. It gets the text when that would change a screen, and never
/// before the user has confirmed it (see `Recall`).
@Model
final class MemoryFact {
    enum Source: String, CaseIterable {
        /// The user wrote it in What Dream knows.
        case said
        /// The user answered a question that was about them.
        case answered
        /// Dream noticed it in a request. Not used until the user confirms it.
        case inferred
    }

    var id = UUID()
    /// What it's about, like Home city or Diet.
    var topic = ""
    /// The fact itself, like Pune or Vegetarian.
    var text = ""
    var sourceName = Source.said.rawValue
    var isConfirmed = false
    /// The request it came from, if any.
    var request = ""
    var createdAt = Date()
    var updatedAt = Date()
    /// When a screen was last built with it.
    var lastUsedAt: Date?

    init(topic: String, text: String, source: Source, isConfirmed: Bool, request: String = "") {
        self.topic = topic
        self.text = text
        self.sourceName = source.rawValue
        self.isConfirmed = isConfirmed
        self.request = request
    }

    var source: Source {
        get { Source(rawValue: sourceName) ?? .said }
        set { sourceName = newValue.rawValue }
    }

    /// How it reads on its own: "Home city: Pune".
    var statement: String { "\(topic): \(text)" }
}
