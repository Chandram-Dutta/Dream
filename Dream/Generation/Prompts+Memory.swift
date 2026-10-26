import Foundation

// User memory and questions (ROADMAP.md, workstream 1).

extension Prompts {
    /// When and how to ask the user something before building, and how to use what Dream remembers.
    static var memoryRules: String { "" }

    /// What Dream remembers about the user that's relevant to this request.
    static func memoryContext(for intent: String) async -> [String] { [] }
}
