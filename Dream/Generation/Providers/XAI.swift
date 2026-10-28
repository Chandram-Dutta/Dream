import Foundation
import FoundationModels

/// Grok, through xAI's chat completions API, behind Apple's `LanguageModel` protocol. Sessions,
/// guided generation and tools work exactly as they do with Apple's own models. With the user's
/// own xAI key, it's a developer option in Under the hood; everyone else reaches Grok through
/// Dream's server (DreamModel.swift), with the same translation (ChatCompletions.swift).
struct XAILanguageModel: LanguageModel {
    typealias Executor = XAIExecutor

    let apiKey: String
    let modelID: String

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration, .toolCalling, .reasoning, .vision])
    }

    var executorConfiguration: XAIExecutor.Configuration {
        XAIExecutor.Configuration(apiKey: apiKey, modelID: modelID)
    }

    /// Far more than anything Dream sends.
    var contextSize: Int { 256_000 }

    /// The key from the environment (for the Mac bench), else the Keychain. `XAI_API_KEY=off`
    /// leaves Grok out, so a bench of Dream's server models isn't quietly finished by Grok when
    /// one of them fails (Composer tries the next usable provider).
    static var savedKey: String? {
        if let key = Build.environment("XAI_API_KEY") { return key == "off" ? nil : key }
        return Keychain.read("xai")
    }
}

struct XAIExecutor: LanguageModelExecutor {
    typealias Model = XAILanguageModel

    struct Configuration: Hashable, Sendable {
        let apiKey: String
        let modelID: String
    }

    private let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func prewarm(model: XAILanguageModel, transcript: Transcript) {}

    func respond(to request: LanguageModelExecutorGenerationRequest, model: XAILanguageModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        // Grok thinks low to high; a level picked for Dream's other models moves to the nearest,
        // as the server moves it (Server/src/models.ts), instead of xAI turning the request away.
        let effort = ThinkingChoice.shown(ThinkingChoice.level, among: ["low", "medium", "high"])
        let (body, summary) = try ChatCompletions.body(for: request, modelID: configuration.modelID, effort: effort)
        var urlRequest = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!, timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        try await ChatCompletions.stream(urlRequest, summary: summary, label: "xAI", into: channel) { response, data in
            XAIError(status: response.statusCode, body: data)
        }
    }
}

struct XAIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(status: Int, body: Data) {
        let detail = ChatCompletions.errorMessage(in: body) ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401, 403: message = "xAI didn't accept the API key (\(status)). Check it in Under the hood."
        case 429: message = "xAI's rate limit was reached. Try again in a moment."
        default: message = "xAI returned an error (\(status)): \(detail)"
        }
    }

    var errorDescription: String? { message }
}
