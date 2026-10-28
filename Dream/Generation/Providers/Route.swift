import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Auto, picked in Account: Dream's server picks the model and how long it thinks for each page
/// (`POST /api/route`, Server/src/route.ts), from what kind of page it is and how hard it looks.
/// The composer asks once as a page starts (`start`), and every request of that page then names
/// what came back (`DreamExecutor`). If the server can't be asked, the page is made on Dream's
/// default, thinking low, as if Auto weren't on.
enum Route {
    /// What `ModelChoice` holds when Auto is picked.
    static let auto = "auto"

    /// What one page runs on.
    struct Pick: Sendable, Equatable {
        let page: String
        /// The catalogue id to ask for; empty for the server's default.
        let model: String
        let effort: String
        /// The model's name, for the log.
        let name: String
        let category: String
        let difficulty: String
        let why: String

        /// "Auto → Grok 4.7 · high", as the composer's log and model name show it.
        var label: String { "Auto → \(name) · \(effort)" }
    }

    /// The page being made on Auto, and what it runs on. One page is made at a time; nil once a
    /// page starts on a model picked by name.
    static var current: Pick? { lock.withLock { latest } }

    /// The pick for a page, if it's being made on Auto.
    static func pick(for page: String?) -> Pick? {
        guard let page, let current, current.page == page else { return nil }
        return current
    }

    /// When Auto is picked, asks the server what this page runs on and returns a line for the
    /// log. Otherwise asks nothing and returns nil.
    static func start(page: String, request: String, image: CGImage?) async -> String? {
        guard Composer.dreamModelID == auto, DreamLanguageModel.isUsable else {
            set(nil)
            return nil
        }
        let started = Date()
        do {
            let pick = try await ask(page: page, request: request, image: image)
            set(pick)
            return String(format: "%@ (%@, %@: %@; %.1fs)", pick.label, pick.category, pick.difficulty, pick.why, Date().timeIntervalSince(started))
        } catch {
            let fallback = Pick(page: page, model: "", effort: "low", name: "Dream's default", category: "other", difficulty: "easy", why: "")
            set(fallback)
            return "\(fallback.label) (the router didn't answer: \(error.localizedDescription))"
        }
    }

    // MARK: - Asking

    nonisolated(unsafe) private static var latest: Pick?
    private static let lock = NSLock()

    private static func set(_ pick: Pick?) {
        lock.withLock { latest = pick }
    }

    private struct Answer: Decodable {
        let model: String
        let effort: String
        let name: String?
        let category: String
        let difficulty: String
        let why: String
    }

    private static func ask(page: String, request: String, image: CGImage?) async throws -> Pick {
        guard let base = ServerAddress.dream else { throw DreamServiceError(message: "No server.") }
        var fields: [String: Any] = ["request": String(request.prefix(4_000)), "hasImage": image != nil]
        // Small, so Clef sees what the photo shows without the upload slowing the page's start.
        if let image, let jpeg = smallJPEG(image) { fields["image"] = "data:image/jpeg;base64,\(jpeg.base64EncodedString())" }
        let body = try JSONSerialization.data(withJSONObject: fields)
        let path = "/api/route"
        // The page waits on this, so it gives up quickly and the default takes over.
        var urlRequest = URLRequest(url: base.appending(path: "api/route"), timeoutInterval: 8)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Session.authorize(&urlRequest)
        for (name, value) in await AppProof.headers(method: "POST", path: path, body: body) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw DreamServiceError(message: "No answer.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { AppProof.serverAsks(http) }
            throw DreamServiceError(message: ChatCompletions.errorMessage(in: data) ?? "HTTP \(http.statusCode)")
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        return Pick(page: page, model: answer.model, effort: answer.effort, name: answer.name ?? answer.model,
                    category: answer.category, difficulty: answer.difficulty, why: answer.why)
    }

    /// The photo at most 768 points on its longer side, as a JPEG: Clef reads about a megapixel
    /// at most, and a page's photo is often twelve.
    private static func smallJPEG(_ image: CGImage, longest: CGFloat = 768) -> Data? {
        let scale = min(1, longest / CGFloat(max(image.width, image.height, 1)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
