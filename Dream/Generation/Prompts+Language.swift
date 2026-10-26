import Foundation

// Language, locale and units (ROADMAP.md, workstream 4).

extension Prompts {
    /// How to write for the user's language and region, and how to give values units.
    static var languageRules: String { "" }

    /// The user's language, region, currency and measurement system.
    static func languageContext() -> [String] { [] }
}
