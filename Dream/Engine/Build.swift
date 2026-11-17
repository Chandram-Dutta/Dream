import Foundation

/// Which kind of build this is. Debug builds, and the checks and bench that run on this Mac, keep
/// Dream's testing hooks: launch arguments like `-DreamAutoIntent`, the settings in Under the
/// hood, and traces of model traffic in the console. Release builds, the ones that reach people,
/// have none of them.
///
/// It follows the `DEBUG` compilation condition, which only the Debug configuration sets, so any
/// other configuration (Release, an archive for TestFlight) is locked down without anyone having
/// to remember. The Mac tools build with plain `swiftc` and no `DEBUG`; the app itself only builds
/// for iPhone, so macOS counts as testing too.
enum Build {
    #if DEBUG || os(macOS)
    static let hasTestingHooks = true
    #else
    static let hasTestingHooks = false
    #endif

    /// A testing launch argument's value, like "split a bill" from `-DreamAutoIntent "split a bill"`.
    /// Nil in Release.
    static func argument(_ name: String) -> String? {
        guard hasTestingHooks, let value = UserDefaults.standard.string(forKey: name), !value.isEmpty else { return nil }
        return value
    }

    /// Whether a testing switch, like `-DreamTour 1`, is on. Never in Release.
    static func flag(_ name: String) -> Bool {
        hasTestingHooks && UserDefaults.standard.bool(forKey: name)
    }

    /// A setting from Under the hood (the model, a server address), or the same name given at
    /// launch. Release builds don't show Under the hood, so they always use what they were built with.
    static func setting(_ name: String) -> String? {
        argument(name)
    }

    /// A value from the environment, for the bench on this Mac (`DREAM_SESSION`).
    static func environment(_ name: String) -> String? {
        guard hasTestingHooks, let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// A line for the console while testing. Release builds stay quiet: lines can carry what
    /// someone asked for, or what came back.
    static func trace(_ line: @autoclosure () -> String) {
        guard hasTestingHooks else { return }
        print(line())
    }
}
