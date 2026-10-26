import Foundation
import Observation

// Asking before a connected service's tool runs (ROADMAP.md, workstream 8). Nothing is blocked
// in settings: when the model calls a tool, Dream decides whether to ask, and building waits on
// the user while it does, the way it waits on the questions asked before building.

/// Something personal a call would send: a detail Dream remembers, or an entry from a list.
struct PersonalDetail: Hashable, Sendable {
    var text: String
    /// Where it's from, as the card says it: "what Dream knows about you", "your lists".
    var from: String
}

/// One question before a tool runs: what it does, exactly what it sends, and what's personal in it.
struct ConsentRequest: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Only looks something up: asked once for a service, until "Always".
        case lookUp
        /// Changes something the service says it can undo or add to.
        case change
        /// May delete or overwrite something.
        case destroy
        /// The service doesn't say what it does, so it may change things.
        case unknown
        /// Carries something personal: always asked, never "Always".
        case personal
    }

    struct Value: Hashable, Sendable {
        var name: String
        var text: String
    }

    let id = UUID()
    var connection: Connection.ID
    var service: String
    var tool: String
    var kind: Kind
    /// The question, like "Let DeepWiki look this up?".
    var question: String
    /// A line under it, when there's something to warn about.
    var note: String?
    /// Exactly what's sent, by name.
    var values: [Value]
    var personal: [PersonalDetail]
    /// What "Always" means here, like "Always for DeepWiki". Nil when it isn't offered.
    var always: String?
}

enum ConsentAnswer: Hashable, Sendable {
    case once, always, deny
}

/// Whether a call needs asking, and how: the rules, in one place.
enum ConsentPolicy {
    /// What to ask before this call, or nil when the user's earlier answers cover it.
    /// - Look-ups with nothing personal: asked the first time for a service, then never again
    ///   once allowed always.
    /// - Changes, deletions, and tools whose service doesn't say: asked every time, unless the
    ///   user chose "Always allow this action" for that tool.
    /// - Anything carrying a personal detail: always asked, naming the details.
    static func request(_ connection: Connection, _ tool: ConnectedTool, values: JSONValue, personal: [PersonalDetail]) -> ConsentRequest? {
        let shown = self.values(values)
        let label = words(tool.label)
        if !personal.isEmpty {
            return ConsentRequest(connection: connection.id, service: connection.name, tool: tool.name, kind: .personal,
                                  question: "Send \(connection.name) something Dream knows about you?",
                                  note: "To \(tool.readsOnly ? "look this up" : label.lowercased()), it would get the details below.", values: shown, personal: personal, always: nil)
        }
        if tool.readsOnly {
            guard !connection.alwaysLooksUp && !tool.alwaysAllowed else { return nil }
            return ConsentRequest(connection: connection.id, service: connection.name, tool: tool.name, kind: .lookUp,
                                  question: "Let \(connection.name) look this up?", note: nil, values: shown, personal: [], always: "Always for \(connection.name)")
        }
        guard !tool.alwaysAllowed else { return nil }
        let kind: ConsentRequest.Kind = tool.readOnlyHint == nil ? .unknown : tool.effect == .destroys ? .destroy : .change
        let note: String? = switch kind {
        case .unknown: "\(connection.name) doesn't say whether this changes anything."
        case .destroy: "This can delete or overwrite things in \(connection.name)."
        default: nil
        }
        return ConsentRequest(connection: connection.id, service: connection.name, tool: tool.name, kind: kind,
                              question: "\(label) in \(connection.name)?", note: note, values: shown, personal: [], always: "Always allow this action")
    }

    /// The values as the card lists them: by name, in words, nested ones as written.
    static func values(_ values: JSONValue) -> [ConsentRequest.Value] {
        (values.object ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            ConsentRequest.Value(name: words(key), text: value.string ?? value.jsonString)
        }
    }

    /// due_date or dueDate as "Due date".
    static func words(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if character == "_" || character == "-" {
                result.append(" ")
            } else {
                if character.isUppercase, let previous, previous.isLowercase { result.append(" ") }
                result.append(contentsOf: character.lowercased())
            }
            previous = character
        }
        let tidy = result.split(separator: " ").joined(separator: " ")
        return tidy.prefix(1).uppercased() + tidy.dropFirst()
    }
}

/// The questions waiting on the user before tools run, one at a time. A tool's call waits inside
/// `ask` until the user answers on the card where the page is forming.
@MainActor @Observable
final class Consent {
    enum Answerer: Equatable {
        /// The card goes on screen and the call waits for the user.
        case user
        /// Nobody to ask, as on the bench: every question gets this answer, and is printed.
        /// "Always" is "Allow once" where it isn't offered.
        case automatic(ConsentAnswer)
    }

    /// The app sets this at launch. The bench has no screen, so it allows each call once.
    static var answerer = Answerer.automatic(.once)

    /// The question on screen, or nil.
    private(set) var pending: ConsentRequest?
    /// Questions after it, from calls the model made at the same time.
    private var queue: [(request: ConsentRequest, continuation: CheckedContinuation<ConsentAnswer, Never>)] = []
    private var current: CheckedContinuation<ConsentAnswer, Never>?

    var isWaiting: Bool { pending != nil }

    func ask(_ request: ConsentRequest) async -> ConsentAnswer {
        guard Self.answerer == .user, !Task.isCancelled else {
            var answer = ConsentAnswer.deny
            if case .automatic(let given) = Self.answerer { answer = given == .always && request.always == nil ? .once : given }
            let named: [ConsentAnswer: String] = [.once: "Allow once", .always: request.always ?? "", .deny: "Don't allow"]
            print("[Dream] Asked: \(request.question)\(request.note.map { " (\($0))" } ?? "") — "
                  + (request.values.map { "\($0.name): \($0.text)" } + request.personal.map { "personal: \($0.text), from \($0.from)" }).joined(separator: "; ")
                  + (request.always.map { " [Allow once / \($0) / Don't allow]" } ?? " [Allow once / Don't allow]") + " → \(named[answer] ?? "")")
            return answer
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if pending == nil {
                    pending = request
                    current = continuation
                } else {
                    queue.append((request, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// From the card. "Always" also answers any waiting question it covers.
    func answer(_ answer: ConsentAnswer) {
        guard let request = pending, let continuation = current else { return }
        pending = nil
        current = nil
        // The user has been answering, not the model stalling.
        ModelActivity.touch()
        continuation.resume(returning: answer)
        if answer == .always {
            let covered = queue.filter { covers(request, $0.request) }
            queue.removeAll { covers(request, $0.request) }
            covered.forEach { $0.continuation.resume(returning: .once) }
        }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            pending = next.request
            current = next.continuation
        }
    }

    /// Nobody's there to answer: everything waiting is refused, so building never waits on a
    /// screen that's gone.
    func cancel() {
        let waiting = queue
        queue = []
        waiting.forEach { $0.continuation.resume(returning: .deny) }
        if pending != nil { answer(.deny) }
    }

    /// Whether an "Always" for one question answers another: the same service's look-ups, or
    /// the same tool.
    private func covers(_ answered: ConsentRequest, _ other: ConsentRequest) -> Bool {
        guard other.kind != .personal, answered.connection == other.connection else { return false }
        return answered.kind == .lookUp ? other.kind == .lookUp : answered.tool == other.tool
    }
}
