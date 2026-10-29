import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pages made on Dream's server (docs/ServerGeneration.md): what the phone and the server's page
// loop say to each other (Server/src/compose/contract.ts), and how the phone follows a page as it
// forms there. Nothing here needs an iPhone or the network, so Tools/tests.sh checks it on a Mac,
// and Tools/compose-check.sh runs it against a scripted server.

/// Whether new pages are made on Dream's server instead of on this iPhone, so a page goes on when
/// the app is left. On for everyone; a testing build can turn it off in Under the hood, or at
/// launch with `-DreamServerCompose 0`.
enum ServerCompose {
    /// The UserDefaults key the switch in Under the hood and the launch argument share.
    static let key = "DreamServerCompose"

    static var isOn: Bool {
        guard Build.hasTestingHooks, UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// A page started on Dream's server: the job that makes it, and the id it's kept under.
struct ServerJob: Hashable, Sendable {
    /// The job's id on the server, which its events are read from.
    let id: String
    /// The page's id, made here. The server keeps the finished page in sync under it (a `surface`
    /// item), and the phone saves a page it watched under it too, so the account holds it once.
    let page: UUID
}

// MARK: - Starting a page

/// What starts a page on the server: the body of `POST /api/compose`.
struct ComposeStart: Encodable, Equatable {
    struct Place: Encodable, Equatable {
        var language: String
        var region: String
        var currency: String
        /// metric, ussystem or uksystem.
        var measurementSystem: String
    }

    var request: String
    /// The photo to start from: a JPEG, base64, at most 1024 pixels on its longer side.
    var image: String?
    /// "auto", or a model picked in Account.
    var model: String?
    /// How long the model thinks, when a model is picked by name. Auto picks its own.
    var thinking: String?
    var locale: Place
    /// The lines this iPhone adds below the request, like what it remembers about the user.
    var context: [String]
    /// The id the finished page is kept under, as sync writes ids: `UUID.uuidString`.
    var pageID: String
}

extension ComposeStart {
    /// A new page as this iPhone asks for it: its model and thinking, the reader's region, and
    /// what it adds about the user (`Prompts.context`).
    init(intent: String, image: CGImage?, page: UUID, context: [String]) {
        let model = Composer.dreamModelID
        self.init(
            request: intent,
            image: image.flatMap { JPEG.data($0, longest: 1024) }?.base64EncodedString(),
            model: model,
            thinking: model == Route.auto ? nil : ThinkingChoice.level,
            locale: Place(
                language: Languages.of(request: intent)?.rawValue ?? Languages.primary,
                region: Locale.current.region?.identifier ?? "",
                currency: Currency.code,
                measurementSystem: Locale.current.measurementSystem.identifier),
            context: context,
            pageID: page.uuidString)
    }
}

/// Photos as the server takes them.
enum JPEG {
    /// The image at most `longest` pixels on its longer side, as a JPEG. Never larger than it was.
    static func data(_ image: CGImage, longest: CGFloat, quality: Double = 0.8) -> Data? {
        let scale = min(1, longest / CGFloat(max(image.width, image.height, 1)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Events

/// Where the server's loop is: the same steps as the composer's here.
enum ServerPhase: String, Sendable {
    case researching, composing, fixing
}

/// One thing that happened to a page on the server, numbered in order (`seq`).
struct ComposeEvent: Equatable {
    enum Kind: Equatable {
        case phase(ServerPhase)
        /// A step of the work starting: a search, a page read, an article looked up.
        case trace(Trace.Kind, String)
        /// The page so far.
        case surface(Surface)
        /// Questions the loop waits on.
        case asking([Question])
        /// A line for Under the hood.
        case log(String)
        /// Finished, and kept in sync. The page is nil when this version can't read it.
        case done(Surface?, model: String)
        case failed(String)
        /// Something this version doesn't know, or can't read. It's counted, and passed over.
        case other(String)
    }

    var seq: Int
    var kind: Kind
}

extension ComposeEvent: Decodable {
    private enum Keys: String, CodingKey {
        case seq, type, phase, kind, text, surface, questions, line, model, message
    }

    /// Only `seq` and `type` must be there. Anything else that's missing or can't be read makes
    /// the event `other`, so one odd event never stops a page being followed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        let type = try c.decode(String.self, forKey: .type)
        func string(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        switch type {
        case "phase":
            kind = string(.phase).flatMap(ServerPhase.init).map(Kind.phase) ?? .other(type)
        case "trace":
            let traced: Trace.Kind? = switch string(.kind) ?? "" {
            case "search": .search
            case "read": .read
            case "lookup": .lookup
            default: nil
            }
            if let traced, let text = string(.text) { kind = .trace(traced, text) } else { kind = .other(type) }
        case "surface":
            kind = Self.surface(try? c.decodeIfPresent(JSONValue.self, forKey: .surface)).map(Kind.surface) ?? .other(type)
        case "asking":
            let questions = try? c.decodeIfPresent([AskedQuestion].self, forKey: .questions)
            kind = questions.map { Kind.asking($0.compactMap(\.question)) } ?? .other(type)
        case "log":
            kind = string(.line).map(Kind.log) ?? .other(type)
        case "done":
            kind = .done(Self.surface(try? c.decodeIfPresent(JSONValue.self, forKey: .surface)), model: string(.model) ?? "")
        case "failed":
            kind = .failed(string(.message).flatMap { $0.isEmpty ? nil : $0 } ?? "Dream's server couldn't make this page.")
        default:
            kind = .other(type)
        }
    }

    /// A page as the app's Codable reads it. A page so far may not have every part yet, so the
    /// ones a page always has start empty, as they do for a page forming here.
    static func surface(_ value: JSONValue?) -> Surface? {
        guard case .object(var fields)? = value else { return nil }
        for (key, empty) in emptySurface where fields[key] == nil || fields[key] == .null {
            fields[key] = empty
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else { return nil }
        return try? pageDecoder.decode(Surface.self, from: data)
    }

    private static let emptySurface: [String: JSONValue] = {
        let fields = (try? JSONEncoder().encode(Surface.empty)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.object ?? [:]
        return fields.filter { $0.value != .null }
    }()

    /// As SavedSurface stores pages: numbers too big for JSON travel as strings.
    private static let pageDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}

/// A question as the server asks it: the app's `Question`, or GapCheck's own answer
/// (`WireQuestion`), which the server may pass on as the model wrote it. Either is tidied the
/// same way, as if the gap check had run here.
private struct AskedQuestion: Decodable {
    let question: Question?

    private enum Keys: String, CodingKey {
        case text, question, topic, options, allowsTyping, typing, isPersonal, personal, remembered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func string(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        func flag(_ keys: Keys...) -> Bool { keys.lazy.compactMap { try? c.decodeIfPresent(Bool.self, forKey: $0) }.first ?? false }
        let wire = GapCheck.WireQuestion(
            question: string(.text) ?? string(.question) ?? "",
            topic: string(.topic) ?? "",
            options: (try? c.decodeIfPresent([String].self, forKey: .options)) ?? [],
            personal: flag(.isPersonal, .personal),
            typing: flag(.allowsTyping, .typing),
            remembered: string(.remembered) ?? "")
        question = Question(wire)
    }
}

/// Server-sent events, a line at a time. The server writes each event as one `data:` line of
/// JSON. Comments (its heartbeat), blank lines and other fields carry nothing to show.
enum EventLine {
    static func event(_ line: String) -> ComposeEvent? {
        var line = Substring(line)
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }
        return try? JSONDecoder().decode(ComposeEvent.self, from: Data(payload.utf8))
    }
}

// MARK: - Following a page

/// A page on the server as far as its events have got: what the screen shows of it, built up an
/// event at a time. Each event counts once, however often it arrives: reading again after the
/// line drops asks for those after the last one counted, and any older one that comes again is
/// passed over, so nothing shows twice.
struct PageProgress: Equatable {
    /// Questions the loop is waiting on, and the event that asked them.
    struct Asked: Equatable {
        var seq: Int
        var questions: [Question]
    }

    /// The last event counted; nil before the first.
    private(set) var seq: Int?
    private(set) var phase = Composer.Phase.composing
    private(set) var surface: Surface?
    private(set) var trail: [Trace] = []
    private(set) var log: [String] = []
    /// Working, with nothing new on the page: reasoning, or looking something up.
    private(set) var isThinking = true
    /// The model that wrote it, once it's done.
    private(set) var model = ""
    /// Questions waiting on an answer. Nil once they're answered or the loop goes on without them.
    private(set) var asked: Asked?
    /// The answers sent, which the finished page carries if the server left them off.
    private(set) var answers: [Answer] = []
    /// The request's language, if it's clear, and the reader's otherwise: what a finished page
    /// is labelled with if the server didn't say (Language.swift).
    private var likely: String?
    private var fallback = Languages.primary

    init(intent: String = "") {
        likely = Languages.guess(intent)?.rawValue
        fallback = Languages.of(request: intent)?.rawValue ?? Languages.primary
    }

    /// Where reading the events again picks up: after the last one counted.
    var after: Int { seq ?? 0 }

    var isOver: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    /// Counts an event, unless it was counted already or the page is over. Whether it was new.
    @discardableResult
    mutating func apply(_ event: ComposeEvent) -> Bool {
        if let seq, event.seq <= seq { return false }
        guard !isOver else { return false }
        seq = event.seq
        switch event.kind {
        case .phase(let next):
            phase = switch next {
            case .researching: .researching
            case .composing: .composing
            case .fixing: .fixing(0)
            }
            isThinking = true
            asked = nil
        case .trace(let kind, let text):
            trail.append(Trace(kind, text))
            if phase == .composing { phase = .researching }
            isThinking = true
            asked = nil
        case .surface(let page):
            surface = page
            if phase == .researching { phase = .composing }
            isThinking = false
            asked = nil
        case .asking(let questions):
            asked = questions.isEmpty ? nil : Asked(seq: event.seq, questions: questions)
            isThinking = false
        case .log(let line):
            log.append(line)
        case .done(let page, let model):
            finish(page ?? surface, model: model)
        case .failed(let message):
            end(message)
        case .other:
            break
        }
        return true
    }

    /// The questions were answered here, and the answers sent.
    mutating func answered(_ seq: Int, with answers: [Answer]) {
        guard asked?.seq == seq else { return }
        asked = nil
        self.answers = answers
        isThinking = true
    }

    /// A line of the phone's own, among the server's.
    mutating func note(_ line: String) {
        log.append(line)
    }

    /// It ended without the server saying so, or before it began.
    mutating func end(_ message: String) {
        guard !isOver else { return }
        phase = .failed(message)
        asked = nil
        isThinking = false
    }

    /// Finished with a page that came another way, like sync.
    mutating func finish(_ page: Surface?, model: String) {
        guard !isOver else { return }
        asked = nil
        isThinking = false
        guard var page, !page.isEmpty else {
            phase = .failed("Nothing came out of this. Try asking another way.")
            return
        }
        if page.answers == nil, !answers.isEmpty { page = page.answered(answers) }
        if page.locale == nil { page.locale = SurfaceLocale(written: page, likely: likely, fallback: fallback) }
        surface = page
        self.model = model
        phase = .done
    }
}

/// The three routes a page on the server is made through, so following one can be checked
/// without the network.
protocol ComposeTransport: Sendable {
    /// Starts a page; its job's id.
    func start(_ start: ComposeStart) async throws -> String
    /// The job's events after `seq`, then new ones as they happen, until it's over or the line drops.
    func events(_ job: String, after seq: Int) -> AsyncThrowingStream<ComposeEvent, Error>
    /// The user's answers to the questions the job waits on.
    func answer(_ job: String, _ answers: [Answer]) async throws
}

/// Follows one page on Dream's server to its end: reads its events, reads again from the last one
/// counted whenever the line drops, and puts its questions to the user.
@MainActor
final class ServerWatch {
    enum Ending: Equatable {
        case done, failed
        /// The server no longer has the job: it finished a while ago, and its page comes by sync.
        case gone
        /// Stopped from here, with the page still being made.
        case stopped
    }

    let job: ServerJob
    private(set) var progress: PageProgress
    private let transport: any ComposeTransport
    /// Each change, as it happens.
    var onChange: (PageProgress) -> Void = { _ in }
    /// Puts questions to the user, and gives back the answers. Stopping it (its task cancelled)
    /// takes them back off the screen.
    var ask: ([Question]) async -> [Answer] = { $0.map(\.leftToDream) }
    /// How long to wait before reading again, after this many drops in a row.
    var delay: (Int) -> Duration = { drops in .milliseconds(min(15_000, 500 * (1 << min(drops - 1, 5)))) }
    /// Read again from the first event, questions come before what came of them, all at once. They
    /// go on screen once events stop coming for this long, if nothing has answered them by then.
    var settle: Duration = .milliseconds(400)

    private var reading: Task<Void, Error>?
    private var asking: Task<Void, Never>?
    private var nudged = false

    init(job: ServerJob, progress: PageProgress, transport: any ComposeTransport) {
        self.job = job
        self.progress = progress
        self.transport = transport
    }

    /// Follows the page until it's over, the server no longer has it, or this is stopped.
    func run() async -> Ending {
        var drops = 0
        defer {
            asking?.cancel()
            reading?.cancel()
        }
        while !Task.isCancelled, !progress.isOver {
            let before = progress.seq
            let events = transport.events(job.id, after: progress.after)
            let read = Task {
                for try await event in events {
                    self.take(event)
                    if self.progress.isOver { return }
                }
            }
            reading = read
            do {
                try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            } catch ComposeFailure.gone {
                return .gone
            } catch ComposeFailure.refused(let message) {
                progress.end(message)
                onChange(progress)
                return .failed
            } catch {
                // The line dropped. It's read again below.
            }
            if progress.isOver || Task.isCancelled { break }
            drops = progress.seq == before ? drops + 1 : 1
            progress.note("The line to Dream's server dropped after event \(progress.after); reading again.")
            onChange(progress)
            await pause(delay(drops))
        }
        switch progress.phase {
        case .done: return .done
        case .failed: return .failed
        default: return .stopped
        }
    }

    /// Drops the line and reads again right away, as after coming back to the app, when a line
    /// that looks open may have died while the app was away.
    func reconnect() {
        nudged = true
        reading?.cancel()
    }

    private func take(_ event: ComposeEvent) {
        let waiting = progress.asked
        guard progress.apply(event) else { return }
        onChange(progress)
        if let asked = progress.asked, asked != waiting {
            put(asked)
        } else if waiting != nil, progress.asked == nil {
            // The loop went on without these answers (nobody answered in time), so they come
            // off the screen, and nothing is sent.
            asking?.cancel()
        }
    }

    private func put(_ asked: PageProgress.Asked) {
        asking?.cancel()
        asking = Task {
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, progress.asked == asked else { return }
            let answers = await ask(asked.questions)
            guard !Task.isCancelled, progress.asked == asked else { return }
            progress.answered(asked.seq, with: answers)
            progress.note("Answered: " + answers.map { $0.isLeftToDream ? "You choose" : $0.isRemembered ? "\($0.choice) (remembered)" : $0.choice }.joined(separator: "; "))
            onChange(progress)
            await send(answers)
        }
    }

    /// The answers, a few times if the line is down. If they never get there, the loop goes on as
    /// if they were "You choose".
    private func send(_ answers: [Answer]) async {
        for wait in [Duration.zero, .seconds(1), .seconds(4)] {
            try? await Task.sleep(for: wait)
            do {
                try await transport.answer(job.id, answers)
                return
            } catch {
                progress.note("Sending the answers failed (\(error.localizedDescription)).")
                onChange(progress)
            }
        }
    }

    /// Waits before reading again, unless stopped, or nudged since the line was last opened.
    private func pause(_ duration: Duration) async {
        let until = ContinuousClock.now + duration
        defer { nudged = false }
        while !Task.isCancelled, !nudged, ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Why the server didn't give what was asked, as following a page needs to know.
enum ComposeFailure: LocalizedError, Equatable {
    /// It no longer has the job.
    case gone
    /// It won't, in its own words: signed out, or a job that isn't this user's.
    case refused(String)
    /// It didn't answer properly. Worth asking again.
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .gone: "Dream's server no longer has this page."
        case .refused(let message), .unavailable(let message): message
        }
    }
}

// MARK: - Dream's server

/// The routes on Dream's server, with the signed-in user's session and the app's proof, as
/// `/api/model` takes them (DreamModel.swift).
struct ComposeClient: ComposeTransport {
    let base: URL

    /// Dream's server, while someone is signed in.
    static var dream: ComposeClient? {
        guard Session.isSignedIn, let base = ServerAddress.dream else { return nil }
        return ComposeClient(base: base)
    }

    /// Long enough for the model to think between events. The server's heartbeat keeps a quiet
    /// line open; if it goes quieter than this, the line is read again from the last event.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func start(_ start: ComposeStart) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(start)
        // A busy server often answers a moment later, and nothing has started yet, so asking
        // again is safe (DreamExecutor).
        for delay in DreamExecutor.retryDelays + [nil] {
            var request = try await signed("POST", "api/compose", body: body)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if Analytics.isOn { request.setValue("on", forHTTPHeaderField: "X-Dream-Analytics") }
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ComposeFailure.unavailable("Dream's server didn't answer.") }
            if (200..<300).contains(http.statusCode), let started = try? JSONDecoder().decode(Started.self, from: data), !started.id.isEmpty {
                return started.id
            }
            let error = DreamServiceError(response: http, body: data)
            guard error.isTransient, let delay else { throw error }
            Build.trace("[Dream/Compose] \(error.message) Asking again in \(delay).")
            try await Task.sleep(for: delay)
        }
        throw ComposeFailure.unavailable("Dream's server didn't answer.")
    }

    func events(_ job: String, after seq: Int) -> AsyncThrowingStream<ComposeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try await signed("GET", "api/compose/\(job)/events", query: [URLQueryItem(name: "after", value: String(seq))])
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await Self.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ComposeFailure.unavailable("Dream's server didn't answer.") }
                    guard http.statusCode == 200 else {
                        var data = Data()
                        for try await byte in bytes.prefix(16_000) { data.append(byte) }
                        throw failure(http, data)
                    }
                    for try await line in bytes.lines {
                        if let event = EventLine.event(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func answer(_ job: String, _ answers: [Answer]) async throws {
        let body = try JSONEncoder().encode(["answers": answers])
        var request = try await signed("POST", "api/compose/\(job)/answers", body: body)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ComposeFailure.unavailable("Dream's server didn't answer.") }
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data) }
    }

    private struct Started: Decodable {
        let id: String
    }

    /// A request carrying the session and the app's proof, which signs its method, path and body.
    private func signed(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data = Data()) async throws -> URLRequest {
        guard var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else { throw ComposeFailure.unavailable("No server.") }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ComposeFailure.unavailable("No server.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method != "GET" { request.httpBody = body }
        Session.authorize(&request)
        for (name, value) in await AppProof.headers(method: method, path: url.path(percentEncoded: true), body: body) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func failure(_ response: HTTPURLResponse, _ body: Data) -> ComposeFailure {
        let said = ChatCompletions.errorMessage(in: body)
        switch response.statusCode {
        case 404, 410:
            return .gone
        case 401:
            AppProof.serverAsks(response)
            return .refused(said ?? "Sign in to see this page.")
        case 400..<500 where response.statusCode != 408 && response.statusCode != 429:
            return .refused(said ?? "Dream's server won't show this page (\(response.statusCode)).")
        default:
            return .unavailable(said ?? "Dream's server didn't answer (\(response.statusCode)).")
        }
    }
}

extension GapCheck {
    /// Answers Dream can give itself to questions asked somewhere else, like a page made on Dream's
    /// server: one about a topic it remembers is answered from what it remembers, as when the
    /// check runs here.
    static func remembered(_ questions: [Question]) async -> [Answer] {
        let topics = await Recall.source.topics()
        var answers: [Answer] = []
        for question in questions {
            guard let topic = topics.first(where: { Recall.key($0) == Recall.key(question.topic) }) else { continue }
            let facts = await Recall.source.facts([topic])
            if !facts.isEmpty {
                answers.append(Answer(question: question, choice: facts.map(\.detail).joined(separator: ", "), isRemembered: true))
            }
        }
        return answers
    }
}
