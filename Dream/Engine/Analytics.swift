import Foundation

/// What Dream counts about how it's used, when the user has said it may ("Help improve Dream",
/// Dream/Privacy/ImproveDream.swift). Every event and property is named here, and only here
/// (docs/Analytics.md has the table).
///
/// Events say what happened, never what anyone wrote: no requests, page text, values, list
/// entries, memory, names or addresses. A page is described by its shape (how many blocks, of
/// which kinds, how long it took), not its words.
///
/// The app sends them to PostHog (Dream/Privacy/ProductAnalytics.swift). Nothing is sent until
/// the user agrees; on the Mac bench and in the checks nobody is listening, so nothing goes anywhere.
enum Analytics {
    /// Where events go: set by the app once the user agrees, and cleared if they change their mind.
    nonisolated(unsafe) static var sink: (@Sendable (_ name: String, _ properties: [String: any Sendable]) -> Void)?

    /// Whether the user lets Dream count what's used, so events go somewhere.
    static var isOn: Bool { sink != nil }

    static func send(_ event: Event) {
        guard let sink else { return }
        sink(event.name, event.properties)
    }

    /// Why a page couldn't be made, in words that carry nothing from the request.
    enum Failure: String, Sendable {
        case noModel = "no_model"
        case safetyFilter = "safety_filter"
        case tooBig = "too_big"
        case rateLimited = "rate_limited"
        case network
        case empty
        case model
        /// The user left before it was done.
        case cancelled
        case other
    }

    enum ShareKind: String, Sendable {
        case link, picture
    }

    /// The user's answer when a connected service's tool asked first.
    enum PromptAnswer: String, Sendable {
        case once, always, deny
    }

    /// What a page is made of: never its words.
    struct Shape: Sendable {
        var blocks = 0
        var kinds: [String] = []
        var inputs = 0
        var outputs = 0
        var lists = 0
        var liveSources = 0
        var usedWeb = false
        var usedConnections = false
        var asked = false

        init(_ surface: Surface) {
            func walk(_ blocks: [Block]) -> [Block] { blocks.flatMap { [$0] + walk($0.children) } }
            let all = walk(surface.blocks)
            blocks = all.count
            kinds = Set(all.map(\.kind.rawValue)).sorted()
            inputs = surface.inputs.count
            outputs = surface.outputs.count
            lists = surface.collections?.count ?? 0
            liveSources = surface.sources?.count ?? 0
            usedWeb = (surface.citations ?? []).contains { !$0.isWikipedia }
            usedConnections = !(surface.services ?? []).isEmpty
            asked = !(surface.answers ?? []).isEmpty
        }

        var properties: [String: any Sendable] {
            ["blocks": blocks, "block_kinds": kinds, "inputs": inputs, "outputs": outputs, "lists": lists,
             "live_sources": liveSources, "used_web": usedWeb, "used_connections": usedConnections, "asked_questions": asked]
        }
    }

    enum Event: Sendable {
        case appOpened
        case signedIn
        case signedOut
        case pageRequested(withPhoto: Bool)
        case pageBuilt(Shape, model: String, seconds: Double)
        case pageFailed(Failure, changing: Bool, seconds: Double)
        case pageChanged(Shape, pointedAtBlock: Bool, seconds: Double)
        /// How many times the page's controls were moved while it was open, and how many controls.
        case controlsUsed(changes: Int, controls: Int)
        case shared(ShareKind, withNumbers: Bool)
        case openedShared(again: Bool)
        /// Typed, said or photographed into a list, or tapped in blank.
        case listEntriesAdded(count: Int)
        case connectionAdded(needsSignIn: Bool)
        case toolPromptShown
        case toolPromptAnswered(PromptAnswer)
        case paywallShown
        case subscriptionStarted(product: String)
        case subscriptionEnded
        /// A free allowance ran out: "pages", "tokens" or "searches".
        case limitReached(kind: String)

        var name: String {
            switch self {
            case .appOpened: "app_opened"
            case .signedIn: "signed_in"
            case .signedOut: "signed_out"
            case .pageRequested: "page_requested"
            case .pageBuilt: "page_built"
            case .pageFailed: "page_failed"
            case .pageChanged: "page_changed"
            case .controlsUsed: "controls_used"
            case .shared: "shared"
            case .openedShared: "opened_shared"
            case .listEntriesAdded: "list_entries_added"
            case .connectionAdded: "connection_added"
            case .toolPromptShown: "tool_prompt_shown"
            case .toolPromptAnswered: "tool_prompt_answered"
            case .paywallShown: "paywall_shown"
            case .subscriptionStarted: "subscription_started"
            case .subscriptionEnded: "subscription_ended"
            case .limitReached: "limit_reached"
            }
        }

        var properties: [String: any Sendable] {
            switch self {
            case .appOpened, .signedIn, .signedOut, .toolPromptShown, .paywallShown, .subscriptionEnded:
                return [:]
            case .pageRequested(let withPhoto):
                return ["with_photo": withPhoto]
            case .pageBuilt(let shape, let model, let seconds):
                return shape.properties.merging(["model": model, "seconds": Self.rounded(seconds)]) { $1 }
            case .pageFailed(let failure, let changing, let seconds):
                return ["reason": failure.rawValue, "changing": changing, "seconds": Self.rounded(seconds)]
            case .pageChanged(let shape, let pointed, let seconds):
                return shape.properties.merging(["pointed_at_block": pointed, "seconds": Self.rounded(seconds)]) { $1 }
            case .controlsUsed(let changes, let controls):
                return ["changes": changes, "controls": controls]
            case .shared(let kind, let withNumbers):
                return ["kind": kind.rawValue, "with_numbers": withNumbers]
            case .openedShared(let again):
                return ["again": again]
            case .listEntriesAdded(let count):
                return ["count": count]
            case .connectionAdded(let needsSignIn):
                return ["needs_sign_in": needsSignIn]
            case .toolPromptAnswered(let answer):
                return ["answer": answer.rawValue]
            case .subscriptionStarted(let product):
                return ["product": product]
            case .limitReached(let kind):
                return ["kind": kind]
            }
        }

        /// Tenths of a second are plenty, and make durations easier to read in charts.
        private static func rounded(_ seconds: Double) -> Double {
            (seconds * 10).rounded() / 10
        }
    }
}

/// Switches PostHog can flip without an app update (Dream/Privacy/ProductAnalytics.swift reads
/// them). None is wired yet. A flag is read only when the user has agreed to help improve Dream;
/// otherwise, and before flags arrive, each one is its fallback. So a switch that must reach
/// everyone, like changing the model provider, belongs on Dream's own server instead.
///
///     extension FeatureFlag {
///         static let webSearch = FeatureFlag("web-search", fallback: true)
///     }
///     if FeatureFlag.webSearch.isOn { … }
struct FeatureFlag: Sendable {
    let key: String
    let fallback: Bool

    init(_ key: String, fallback: Bool) {
        self.key = key
        self.fallback = fallback
    }

    /// Where flags come from: set by the app while the user agrees.
    nonisolated(unsafe) static var source: (@Sendable (_ key: String) -> Bool?)?

    var isOn: Bool { Self.source?(key) ?? fallback }
}
