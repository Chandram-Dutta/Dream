import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// OpenAI-style chat completions, as xAI speaks them and Dream's server passes them on
/// (Server/src/model.ts): a Foundation Models request turned into one, and its streamed answer
/// turned back. Both the xAI and the Dream adapters use it, so they behave the same.
enum ChatCompletions {
    /// The request's JSON, and a line describing it for the log.
    static func body(for request: LanguageModelExecutorGenerationRequest, modelID: String) throws -> (data: Data, summary: String) {
        var body: [String: Any] = [
            "messages": messages(from: request.transcript),
            "stream": true,
        ]
        // Dream's server picks when none is named (Server/src/models.ts).
        if !modelID.isEmpty { body["model"] = modelID }
        if let schema = request.schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "schema": try json(schema), "strict": true],
            ]
        }
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": try json(tool.parameters)]]
            }
        }
        // Screens should arrive in seconds; at default effort, Grok can think for half a minute
        // first. Low unless Dream Plus picked longer in Account (ThinkingChoice).
        body["reasoning_effort"] = ThinkingChoice.level
        let options = request.generationOptions
        if let temperature = options.temperature { body["temperature"] = temperature }
        if options.samplingMode == .greedy { body["temperature"] = 0 }
        if let maximum = options.maximumResponseTokens { body["max_tokens"] = maximum }

        let messages = body["messages"] as? [[String: Any]] ?? []
        let summary = "\(messages.count) messages (last: \(messages.last?["role"] as? String ?? "?")), schema: \(request.schema != nil), tools: \(request.enabledToolDefinitions.map(\.name))"
        return (try JSONSerialization.data(withJSONObject: body), summary)
    }

    /// Sends a request that's ready to go and streams the answer into `channel`. Every line that
    /// arrives, reasoning included, tells `ModelActivity` the model is still working. `failure`
    /// turns an answer other than 200 into the error to throw.
    static func stream(
        _ urlRequest: URLRequest,
        summary: String,
        label: String,
        into channel: LanguageModelExecutorGenerationChannel,
        failure: (HTTPURLResponse, Data) -> Error
    ) async throws {
        let started = Date()
        trace(label, "request: \(summary)")
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ChatCompletionsError("\(label) didn't respond.") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw failure(http, data)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var firstText = true
        var reasoningCharacters = 0
        for try await line in bytes.lines {
            ModelActivity.touch()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)), let delta = chunk.choices.first?.delta else { continue }
            if let reasoning = delta.reasoningContent { reasoningCharacters += reasoning.count }
            if let text = delta.content, !text.isEmpty {
                if firstText {
                    firstText = false
                    trace(label, String(format: "first text after %.1fs (%d characters of reasoning before it)", Date().timeIntervalSince(started), reasoningCharacters))
                }
                await channel.send(.response(action: .appendText(text, tokenCount: tokens(in: text))))
            }
            // Streamed tool calls arrive whole, in a single chunk.
            for call in delta.toolCalls ?? [] {
                let arguments = call.function?.arguments ?? "{}"
                trace(label, String(format: "tool call %@ %@ after %.1fs", call.function?.name ?? "?", arguments, Date().timeIntervalSince(started)))
                await channel.send(.toolCalls(action: .toolCall(
                    id: call.id ?? UUID().uuidString,
                    name: call.function?.name ?? "",
                    action: .appendArguments(arguments, tokenCount: tokens(in: arguments)))))
            }
        }
        trace(label, String(format: "done after %.1fs", Date().timeIntervalSince(started)))
    }

    /// The `error` an answer's JSON carries, as a string or an object with a message.
    static func errorMessage(in body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["message"] as? String)
    }

    // MARK: - Translation

    private static func messages(from transcript: Transcript) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(["role": "system", "content": text(instructions.segments)])
            case .prompt(let prompt):
                messages.append(["role": "user", "content": content(prompt.segments)])
            case .response(let response):
                messages.append(["role": "assistant", "content": text(response.segments)])
            case .toolCalls(let calls):
                messages.append([
                    "role": "assistant",
                    "content": "",
                    "tool_calls": calls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.toolName, "arguments": call.arguments.jsonString]]
                    },
                ])
            case .toolOutput(let output):
                messages.append(["role": "tool", "tool_call_id": output.id, "content": text(output.segments)])
            case .reasoning:
                continue
            @unknown default:
                continue
            }
        }
        return messages
    }

    private static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            case .attachment: return nil
            @unknown default: return nil
            }
        }.joined(separator: "\n")
    }

    /// Plain text, unless the prompt carries a photo.
    private static func content(_ segments: [Transcript.Segment]) -> Any {
        let hasImage = segments.contains { segment in
            if case .attachment = segment { return true }
            return false
        }
        guard hasImage else { return text(segments) }
        return segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text):
                return ["type": "text", "text": text.content]
            case .structure(let structure):
                return ["type": "text", "text": structure.content.jsonString]
            case .attachment(let attachment):
                guard case .image(let image) = attachment.content, let data = jpeg(image.cgImage) else { return nil }
                return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
            @unknown default:
                return nil
            }
        }
    }

    /// Apple's schemas are JSON Schema already; only the ordering extension needs to go.
    private static func json(_ schema: GenerationSchema) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        func clean(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "x-order" }.mapValues(clean)
            }
            if let array = value as? [Any] { return array.map(clean) }
            return value
        }
        return clean(object)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Shows in the console when debugging, like the composer's own log. Never in Release.
    private static func trace(_ label: String, _ line: @autoclosure () -> String) {
        Build.trace("[Dream/\(label)] \(line())")
    }

    private static func tokens(in text: String) -> Int {
        max(1, text.count / 4)
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            let delta: Delta?
        }

        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCall]?
        }

        struct ToolCall: Decodable {
            let id: String?
            let function: Function?
        }

        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }

        let choices: [Choice]
    }
}

struct ChatCompletionsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
