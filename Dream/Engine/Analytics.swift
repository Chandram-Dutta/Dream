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
        /// What the user came for (Mode), or "unknown" on a page made before it was asked.
        var mode = "unknown"

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
            mode = surface.mode?.rawValue ?? "unknown"
        }

        var properties: [String: any Sendable] {
            ["blocks": blocks, "block_kinds": kinds, "inputs": inputs, "outputs": outputs, "lists": lists,
             "live_sources": liveSources, "used_web": usedWeb, "used_connections": usedConnections, "asked_questions": asked, "mode": mode]
        }
    }

    /// How a page was made, stage by stage: the level it was made at, and how long each stage
    /// took. Never what was asked.
    struct Run: Sendable {
        /// The run's own id, which ties its model calls together in PostHog's LLM analytics.
        var trace = UUID().uuidString
        /// instant, reused, quick, standard or deep (Effort.swift).
        var level = "standard"
        /// typed, suggestion, follow_up, explore, voice or launch.
        var source = "typed"
        var understoodSeconds: Double?
        var questions = 0
        var firstBlockSeconds: Double?
        var writingSeconds: Double?
        var repairs = 0
        var toolCalls = 0
        var readers = 0
        var generations = 0
        var inputTokens = 0
        var outputTokens = 0
        var quotaApproaching = false

        var properties: [String: any Sendable] {
            var properties: [String: any Sendable] = ["level": level, "source": source, "repairs": repairs, "tool_calls": toolCalls,
                                                      "readers": readers, "generations": generations, "input_tokens": inputTokens,
                                                      "output_tokens": outputTokens, "quota_approaching": quotaApproaching, "questions": questions,
                                                      "$ai_trace_id": trace]
            if let understoodSeconds { properties["understood_seconds"] = Event.rounded(understoodSeconds) }
            if let firstBlockSeconds { properties["first_block_seconds"] = Event.rounded(firstBlockSeconds) }
            if let writingSeconds { properties["writing_seconds"] = Event.rounded(writingSeconds) }
            return properties
        }
    }

    /// One call to a model, for PostHog's LLM analytics ($ai_generation): which step, which
    /// model, how long and roughly how many tokens. Never the prompt or the answer.
    struct Generation: Sendable {
        var trace: String
        /// understanding, writing, repair, reader, follow_up, ideas.
        var step: String
        var model: String
        var seconds: Double
        var inputTokens: Int
        var outputTokens: Int
        var reasoning: String
        var level: String
        var failed = false
    }

    enum Event: Sendable {
        case appOpened
        case signedIn
        case signedOut
        case pageRequested(withPhoto: Bool, run: Run? = nil)
        case pageBuilt(Shape, model: String, seconds: Double, run: Run? = nil)
        case pageFailed(Failure, changing: Bool, seconds: Double, run: Run? = nil, stage: String = "")
        /// Understanding the request finished: how long, how many tools it used, how many
        /// questions it asked, and whether it found anything or knew related pages.
        case pageUnderstood(seconds: Double, toolCalls: Int, questions: Int, foundSomething: Bool, relatedPages: Int, trace: String)
        /// The user answered the questions: how many, how many left to Dream, how many Dream
        /// knew, and how long they took.
        case questionsAnswered(count: Int, leftToDream: Int, remembered: Int, seconds: Double, trace: String)
        /// The first block of a page showed, the moment it starts to feel made.
        case firstBlock(seconds: Double, level: String, trace: String)
        /// One model call ($ai_generation), one tool call ($ai_span) and a whole page ($ai_trace).
        case generation(Generation)
        case toolCall(kind: String, seconds: Double, characters: Int, trace: String, failed: Bool)
        case pageTrace(trace: String, seconds: Double, level: String, failed: Bool)
        /// What was typed to a page was taken as a change, as going on from it, or as new.
        case followUpDecided(kind: String, seconds: Double)
        case versionRestored
        case pageStarred(on: Bool)
        /// A suggestion on home was tapped: which one, and whether they were made from the
        /// user's own pages.
        case suggestionTapped(position: Int, personal: Bool)
        case libraryOpened
        case mapOpened(pages: Int)
        /// A linked page was opened from another: from its thread, its related pages or the map.
        case linkedPageOpened(from: String)
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
            case .limitReached: "limit_reached"
            case .pageUnderstood: "page_understood"
            case .questionsAnswered: "questions_answered"
            case .firstBlock: "first_block"
            case .generation: "$ai_generation"
            case .toolCall: "$ai_span"
            case .pageTrace: "$ai_trace"
            case .followUpDecided: "follow_up_decided"
            case .versionRestored: "version_restored"
            case .pageStarred: "page_starred"
            case .suggestionTapped: "suggestion_tapped"
            case .libraryOpened: "library_opened"
            case .mapOpened: "map_opened"
            case .linkedPageOpened: "linked_page_opened"
            }
        }

        var properties: [String: any Sendable] {
            switch self {
            case .appOpened, .signedIn, .signedOut, .toolPromptShown, .versionRestored, .libraryOpened:
                return [:]
            case .pageRequested(let withPhoto, let run):
                return (run?.properties ?? [:]).merging(["with_photo": withPhoto]) { $1 }
            case .pageBuilt(let shape, let model, let seconds, let run):
                return shape.properties.merging(run?.properties ?? [:]) { $1 }.merging(["model": model, "seconds": Self.rounded(seconds)]) { $1 }
            case .pageFailed(let failure, let changing, let seconds, let run, let stage):
                return (run?.properties ?? [:]).merging(["reason": failure.rawValue, "changing": changing, "seconds": Self.rounded(seconds), "stage": stage]) { $1 }
            case .pageUnderstood(let seconds, let toolCalls, let questions, let found, let related, let trace):
                return ["seconds": Self.rounded(seconds), "tool_calls": toolCalls, "questions": questions, "found_something": found,
                        "related_pages": related, "$ai_trace_id": trace]
            case .questionsAnswered(let count, let left, let remembered, let seconds, let trace):
                return ["count": count, "left_to_dream": left, "remembered": remembered, "seconds": Self.rounded(seconds), "$ai_trace_id": trace]
            case .firstBlock(let seconds, let level, let trace):
                return ["seconds": Self.rounded(seconds), "level": level, "$ai_trace_id": trace]
            case .generation(let call):
                return ["$ai_trace_id": call.trace, "$ai_span_name": call.step, "$ai_model": call.model, "$ai_provider": "apple",
                        "$ai_latency": Self.rounded(call.seconds), "$ai_input_tokens": call.inputTokens, "$ai_output_tokens": call.outputTokens,
                        "$ai_is_error": call.failed, "reasoning": call.reasoning, "level": call.level, "tokens_estimated": true]
            case .toolCall(let kind, let seconds, let characters, let trace, let failed):
                return ["$ai_trace_id": trace, "$ai_span_name": kind, "$ai_latency": Self.rounded(seconds), "characters": characters, "$ai_is_error": failed]
            case .pageTrace(let trace, let seconds, let level, let failed):
                return ["$ai_trace_id": trace, "$ai_span_name": "page", "$ai_latency": Self.rounded(seconds), "level": level, "$ai_is_error": failed]
            case .followUpDecided(let kind, let seconds):
                return ["kind": kind, "seconds": Self.rounded(seconds)]
            case .pageStarred(let on):
                return ["on": on]
            case .suggestionTapped(let position, let personal):
                return ["position": position, "personal": personal]
            case .mapOpened(let pages):
                return ["pages": pages]
            case .linkedPageOpened(let from):
                return ["from": from]
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
            case .limitReached(let kind):
                return ["kind": kind]
            }
        }

        /// Tenths of a second are plenty, and make durations easier to read in charts.
        static func rounded(_ seconds: Double) -> Double {
            (seconds * 10).rounded() / 10
        }
    }
}

/// Switches PostHog can flip without an app update (Dream/Privacy/ProductAnalytics.swift reads
/// them). A flag is read only when the user has agreed to help improve Dream;
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

extension FeatureFlag {
    /// Sums answered by Dream itself, without a model (InstantPage.swift).
    static let instantPages = FeatureFlag("instant-pages", fallback: true)
    /// A saved page made again for the same request with other numbers (PageReuse.swift).
    static let pageReuse = FeatureFlag("page-reuse", fallback: true)
    /// Calculations with their numbers given, written without understanding first (Effort.swift).
    static let quickLevel = FeatureFlag("quick-level", fallback: true)
}
