import Foundation

/// The settings worth having on every device. Most of Dream's settings are about one device, or
/// for developers (the model, the servers), so they stay where they are.
enum SyncedSetting: String, CaseIterable {
    /// Languages the user has asked Dream something in (`Languages.remember`), so what they make
    /// in them is never translated, on any of their devices.
    case requestLanguages

    /// Its value here, or nil when it's never been set.
    var value: JSONValue? {
        switch self {
        case .requestLanguages:
            UserDefaults.standard.stringArray(forKey: rawValue).map { .array($0.map(JSONValue.string)) }
        }
    }

    /// Takes the account's value. A list only ever grows, so what's here and what's there are put
    /// together, and if that's more than the account had, it's sent back.
    func take(_ remote: JSONValue) {
        switch self {
        case .requestLanguages:
            let here = UserDefaults.standard.stringArray(forKey: rawValue) ?? []
            let there = remote.array?.compactMap(\.string) ?? []
            UserDefaults.standard.set(here + there.filter { !here.contains($0) }, forKey: rawValue)
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: rawValue)
    }
}
