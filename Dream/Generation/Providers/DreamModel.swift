import Foundation
import FoundationModels

/// The model through Dream's own server (`POST /api/model`, Server/src/model.ts), with the
/// signed-in user's session: no provider key on the phone, and the account's allowance applies.
/// It speaks the same chat completions as xAI, so requests and streamed answers are translated by
/// the same code as `XAILanguageModel` (ChatCompletions.swift). The default for anyone signed in.
struct DreamLanguageModel: LanguageModel {
    typealias Executor = DreamExecutor

    let modelID: String
    /// The page this request is part of (one build or one change), so the server counts the
    /// page once however many requests it takes. Nil for small jobs that aren't a page.
    let page: String?

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration, .toolCalling, .reasoning, .vision])
    }

    var executorConfiguration: DreamExecutor.Configuration {
        DreamExecutor.Configuration(modelID: modelID, page: page)
    }

    var contextSize: Int { 256_000 }

    /// Signed in, with a server to ask and a way to show it this is the app.
    static var isUsable: Bool {
        Session.isSignedIn && ServerAddress.dream != nil && AppProof.isAvailable
    }
}

struct DreamExecutor: LanguageModelExecutor {
    typealias Model = DreamLanguageModel

    struct Configuration: Hashable, Sendable {
        let modelID: String
        let page: String?
    }

    private let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func prewarm(model: DreamLanguageModel, transcript: Transcript) {}

    func respond(to request: LanguageModelExecutorGenerationRequest, model: DreamLanguageModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        guard let base = ServerAddress.dream, Session.isSignedIn else { throw DreamServiceError(message: "Sign in to make pages.") }
        // On Auto, the model and thinking the router picked for this page (Route.swift); for a
        // small job that isn't a page, the server's default.
        let routed = configuration.modelID == Route.auto ? Route.pick(for: configuration.page) : nil
        let modelID = configuration.modelID == Route.auto ? routed?.model ?? "" : configuration.modelID
        let (body, summary) = try ChatCompletions.body(for: request, modelID: modelID, effort: routed?.effort)
        let path = "/api/model"
        var urlRequest = URLRequest(url: base.appending(path: "api/model"), timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Session.authorize(&urlRequest)
        if let page = configuration.page { urlRequest.setValue(page, forHTTPHeaderField: "X-Dream-Page") }
        // The server counts what this request used, never what it says, only while the user lets
        // Dream count what's used (Server/src/analytics.ts).
        if Analytics.isOn { urlRequest.setValue("on", forHTTPHeaderField: "X-Dream-Analytics") }
        for (name, value) in await AppProof.headers(method: "POST", path: path, body: body) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = body
        try await ChatCompletions.stream(urlRequest, summary: summary, label: "Dream", into: channel) { response, data in
            DreamServiceError(response: response, body: data)
        }
    }
}

/// What Dream's server said when it didn't answer, in its own plain words. When the allowance
/// has run out, the app hears about it (`Allowance.ranOut`) and can offer Dream Plus.
struct DreamServiceError: LocalizedError {
    let message: String

    init(message: String) {
        self.message = message
    }

    init(response: HTTPURLResponse, body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let said = ChatCompletions.errorMessage(in: body)
        if response.statusCode == 402 || (response.statusCode == 429 && object?["reason"] as? String == "allowance") {
            message = said ?? "You've used today's allowance."
            Allowance.ranOut(message: message, upgrade: object?["upgrade"] as? Bool ?? false)
            return
        }
        switch response.statusCode {
        case 401:
            AppProof.serverAsks(response)
            message = said ?? "Sign in to make pages."
        case 429:
            message = said ?? "Too many requests at once. Try again in a minute."
        default:
            message = said ?? "Dream's server didn't answer (\(response.statusCode)). Try again in a moment."
        }
    }

    var errorDescription: String? { message }
}

/// Tells the app the allowance has run out, so it can say so and offer Dream Plus.
enum Allowance {
    static let didRunOut = Notification.Name("DreamAllowanceDidRunOut")

    static func ranOut(message: String, upgrade: Bool) {
        NotificationCenter.default.post(name: didRunOut, object: nil, userInfo: ["message": message, "upgrade": upgrade])
    }
}

/// The model picked in Account. Only Dream Plus can pick; the server checks the plan on every
/// request, and anyone else gets the default. "auto" (`Route.auto`) has the server pick for each
/// page instead (Route.swift).
enum ModelChoice {
    /// The UserDefaults key, which views can watch with `@AppStorage`. Empty is the default.
    static let key = "model"

    static var picked: String? {
        UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// How long the model thinks before it answers, picked in Account. Only Dream Plus can pick, and
/// testers from every level; the server gives everyone else "low", and moves a level a model
/// doesn't take to the nearest one it does.
enum ThinkingChoice {
    /// The UserDefaults key, which views can watch with `@AppStorage`.
    static let key = "thinking"
    static let levels = ["none", "low", "medium", "high", "max"]

    /// Testing builds can name one at launch, like `-thinking high`.
    static var level: String {
        let picked = Build.setting(key) ?? UserDefaults.standard.string(forKey: key)
        return picked.flatMap { levels.contains($0) ? $0 : nil } ?? "low"
    }
}
