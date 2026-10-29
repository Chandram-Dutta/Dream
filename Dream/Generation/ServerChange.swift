import Foundation

// Changes to a page made on Dream's server (docs/ServerGeneration.md, Stage 2): a typed or spoken
// change, a different answer to one of the page's questions, or the page made again after the
// user connected a service it names. Like a new page, a change goes on when the app is left, and
// lands on the same page, under the same id, however it comes back (ServerPages, and
// SavedSurface+Change.swift). Lists stay on the phone: "add milk" never comes here (RecordTalk).

/// A change to a page on the shelf: what the user asked, and the page and their numbers as they
/// were, which is all it takes to land it on the page as a change made here would.
struct PageChange: Codable, Equatable {
    enum Kind: String, Codable {
        /// "Make it monthly", maybe about one block.
        case instruction
        /// A different answer to one of the questions the page was built from.
        case answer
        /// Made again from the request, as it was.
        case again
    }

    var kind: Kind
    /// What the user said: the change; the answer's new choice; or the request, made again.
    var text: String
    /// The id of the block they pointed at, if any.
    var focus: String?
    /// For a different answer, the answer as it was.
    var answer: Answer?
    /// The page as it was when they asked.
    var base: Surface
    /// Their numbers then, kept where the change leaves the input alone.
    var values: [String: Double]
    var askedAt = Date.now

    static func instruction(_ text: String, focus: String?, on page: Surface, values: [String: Double]) -> PageChange {
        PageChange(kind: .instruction, text: text, focus: focus, base: page, values: values)
    }

    static func answer(_ answer: Answer, to choice: String, on page: Surface, values: [String: Double]) -> PageChange {
        PageChange(kind: .answer, text: choice, answer: answer, base: page, values: values)
    }

    static func again(_ intent: String, on page: Surface, values: [String: Double]) -> PageChange {
        PageChange(kind: .again, text: intent, base: page, values: values)
    }

    /// The `editing` field of the request (Server/src/compose/contract.ts).
    var editing: ComposeStart.Editing {
        var editing = ComposeStart.Editing(surface: Self.json(base))
        switch kind {
        case .instruction:
            editing.instruction = text
            editing.focus = focus
        case .answer:
            if let answer { editing.answer = .init(question: answer.question, choice: text) }
        case .again:
            editing.again = true
        }
        return editing
    }

    /// The answers the changed page is built from: the page's own, with the one that changed;
    /// none when it's made again, which may ask them again.
    var answers: [Answer] {
        switch kind {
        case .instruction: base.answers ?? []
        case .answer: (base.answers ?? []).map { $0.question == answer?.question ? Answer(question: $0.question, choice: text) : $0 }
        case .again: []
        }
    }

    /// The change as the phone's own loop puts it to the model (Composer.edit, Composer.rebuild).
    var instruction: String {
        switch kind {
        case .instruction, .again: text
        case .answer: answer.map { Prompts.changedAnswer($0, to: text) } ?? text
        }
    }

    /// What the connected services' tools are picked by, as for a change made here: the request
    /// and the change together.
    func request(_ intent: String) -> String {
        kind == .again ? intent : "\(intent). \(instruction)"
    }

    /// For the page's record of the changes asked for (SavedSurface.editRequests). Made again, it
    /// isn't one.
    var editRequest: String? {
        kind == .again ? nil : instruction
    }

    /// The user's numbers after the change: each kept while its input starts where it did, so a
    /// change about that number takes it back to the page's. Made again, they stay as they were.
    func kept(after page: Surface) -> [String: Double] {
        guard kind != .again else { return values }
        return values.filter { name, _ in
            guard let before = base.input(name), let after = page.input(name) else { return false }
            return before.initial == after.initial
        }
    }

    /// The first line of the log, as a change made here starts it.
    var line: String {
        switch kind {
        case .instruction: "Change: \(text)\(focus.map { " (pointing at #\($0))" } ?? "")"
        case .answer: "Change: \(instruction)"
        case .again: "Made again: \(text)"
        }
    }

    // MARK: - Stored

    /// As the app stores pages: numbers too big for JSON travel as strings.
    func encoded() -> Data? {
        try? Self.encoder.encode(self)
    }

    static func decoded(_ data: Data?) -> PageChange? {
        data.flatMap { try? decoder.decode(PageChange.self, from: $0) }
    }

    /// A page as the app's Surface encodes it, for the server.
    static func json(_ page: Surface) -> JSONValue {
        (try? encoder.encode(page)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .object([:])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}
