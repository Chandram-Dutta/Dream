import Foundation
import FoundationModels

/// How much of a session's window what its tools return may take, so the page always has room.
///
/// A model's window holds everything at once: the brief, the page's schema, the tools' own
/// descriptions, the request, every tool result, and the page it writes. Private Cloud Compute's
/// is 32,768 tokens. Asked about someone's Notion, a model once opened ten pages at once, about
/// 160,000 characters, and the page never came. So each session gets a budget for tool results:
/// what's left of the window once the fixed parts and room for the answer are set aside. Each
/// result takes a share of what remains (half, at most `most`), so many calls at once each get
/// a smaller piece rather than one getting everything, and once it's spent, tools say so and
/// the model writes from what it has. Calls are counted too, so a model going round in circles
/// stops.
final class ContextBudget: @unchecked Sendable {
    /// Characters the tools' results may take in all.
    let characters: Int
    /// Calls the session may make.
    let calls: Int
    /// Who reads a long result apart and hands back notes on it (ResultReader.swift), or nil to cut it
    /// down instead.
    let reader: ResultReader?
    /// What the session's fixed parts take, in characters: its instructions, the answer's schema
    /// and the tools' descriptions. With what tools return, roughly what the model reads.
    var fixed = 0
    /// Told of each tool call as it finishes: the tool, how long it took, how much it returned
    /// and whether it failed. For analytics ($ai_span), never what was sent or returned.
    var onCall: (@Sendable (_ tool: String, _ seconds: Double, _ characters: Int, _ failed: Bool) -> Void)?

    private let lock = NSLock()
    private var used = 0
    private var made = 0

    /// The budget at work in the tool call running now, for the tool to size its result by.
    @TaskLocal static var current: ContextBudget?

    /// A result smaller than this isn't worth having; the room is spent.
    static let smallest = 1_200

    init(characters: Int, calls: Int, reader: ResultReader? = nil) {
        self.characters = max(characters, 0)
        self.calls = calls
        self.reader = reader
    }

    /// The budget for a session: the window, less its fixed parts (instructions, the answer's
    /// schema, the tools' descriptions and parameters) and the room the answer needs.
    ///
    /// Counted in characters at about 3.2 a token, which errs on the side of room: Apple's
    /// tokenizer gives about 3.5 for English, less for other scripts.
    static func forSession(window tokens: Int, instructions: String, schema: GenerationSchema?, tools: [any Tool], answer reserve: Int, calls: Int, reader: ResultReader? = nil) -> ContextBudget {
        func size(_ schema: GenerationSchema) -> Int {
            (try? JSONEncoder().encode(schema).count) ?? 4_000
        }
        let fixed = instructions.count
            + (schema.map(size) ?? 0)
            + tools.reduce(0) { $0 + $1.name.count + $1.description.count + size($1.parameters) }
        let window = Int(Double(tokens) * 3.2)
        let budget = ContextBudget(characters: window - fixed - reserve, calls: calls, reader: reader)
        budget.fixed = fixed
        return budget
    }

    /// Whether another call may go ahead, counting it if so.
    func mayCall() -> Bool {
        lock.withLock {
            guard made < calls, characters - used >= Self.smallest else { return false }
            made += 1
            return true
        }
    }

    /// How long the next result may be: half of what's left, at most `most`.
    func allowance(most: Int = 8_000) -> Int {
        lock.withLock { max(Self.smallest, min(most, (characters - used) / 2)) }
    }

    private var gaveUp = false

    /// Whether a reader failed in this session, so the rest aren't waited for.
    var readerGaveUp: Bool { lock.withLock { gaveUp } }

    func giveUpReading() {
        lock.withLock { gaveUp = true }
    }

    func spend(_ count: Int) {
        lock.withLock { used += count }
    }

    /// How many calls were made, and how many characters tools returned.
    var callsMade: Int { lock.withLock { made } }
    var returned: Int { lock.withLock { used } }

    /// How much of the budget is spent, 0 to 1.
    var spent: Double {
        lock.withLock { characters > 0 ? Double(used) / Double(characters) : 1 }
    }

    static let exhausted = "There's no room left on this screen for more from tools. Don't call any more: write the screen now from what you have."
}

/// A tool whose calls go through a session's budget: refused once it's spent, and run with the
/// budget at hand, so the tool can size what it returns (`ContextBudget.current`).
struct BudgetedTool<Inner: Tool>: Tool where Inner.Output == String {
    typealias Arguments = Inner.Arguments

    let inner: Inner
    let budget: ContextBudget

    var name: String { inner.name }
    var description: String { inner.description }
    var parameters: GenerationSchema { inner.parameters }
    var includesSchemaInInstructions: Bool { inner.includesSchemaInInstructions }

    func call(arguments: Inner.Arguments) async throws -> String {
        guard budget.mayCall() else {
            Build.trace("[Dream] Tool budget: refused \(name), the screen's room for tools is spent")
            return ContextBudget.exhausted
        }
        let started = Date()
        let output: String
        do {
            output = try await ContextBudget.$current.withValue(budget) {
                try await inner.call(arguments: arguments)
            }
        } catch {
            budget.onCall?(name, Date().timeIntervalSince(started), 0, true)
            throw error
        }
        defer { budget.onCall?(name, Date().timeIntervalSince(started), output.count, false) }
        // A tool that didn't size its own result is held to the allowance here.
        let room = budget.allowance(most: max(8_000, output.count))
        let kept = output.count > room ? String(output.prefix(room)) + "\n[Cut off here, for room on the screen.]" : output
        budget.spend(kept.count)
        return kept
    }
}

extension ContextBudget {
    /// The tools, each held to this budget.
    func holding(_ tools: [any Tool]) -> [any Tool] {
        tools.map { ($0 as? any StringTool)?.budgeted(by: self) ?? $0 }
    }
}

/// A tool that answers in text, which a budget can hold.
protocol StringTool {
    func budgeted(by budget: ContextBudget) -> any Tool
}

extension StringTool where Self: Tool, Self.Output == String {
    func budgeted(by budget: ContextBudget) -> any Tool { BudgetedTool(inner: self, budget: budget) }
}

extension LookupTool: StringTool {}
extension RecallTool: StringTool {}
extension LiveTool: StringTool {}
extension ConnectionTool: StringTool {}
extension SearchTool: StringTool {}
extension ReadTool: StringTool {}

/// The parts of a long text that matter to a request: its opening (a title, what it is), then
/// the paragraphs sharing the most words with the request, kept in their order, up to `limit`.
/// Cutting a long Notion page after its first few thousand characters kept its preamble and lost
/// what was asked about.
enum Excerpt {
    static func focused(_ text: String, on query: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let wanted = words(query)
        let parts = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard parts.count > 2, !wanted.isEmpty else { return String(text.prefix(limit)) + "\n[…]" }
        // The opening always, then the most relevant of the rest.
        var chosen = Set<Int>()
        var size = 0
        for index in parts.indices.prefix(3) where size + parts[index].count < limit / 4 {
            chosen.insert(index)
            size += parts[index].count + 1
        }
        var ranked: [(index: Int, score: Int)] = []
        for index in parts.indices where !chosen.contains(index) {
            let score = words(parts[index]).intersection(wanted).count
            if score > 0 { ranked.append((index, score)) }
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        for (index, _) in ranked {
            let part = parts[index]
            guard size + part.count + 1 <= limit else { continue }
            chosen.insert(index)
            size += part.count + 1
        }
        // Then whatever else fits, from the top.
        for index in parts.indices where !chosen.contains(index) && size + parts[index].count + 1 <= limit {
            chosen.insert(index)
            size += parts[index].count + 1
        }
        var lines: [String] = []
        var last = -1
        for index in chosen.sorted() {
            if index != last + 1 { lines.append("[…]") }
            lines.append(parts[index])
            last = index
        }
        if last != parts.count - 1 { lines.append("[…]") }
        return lines.joined(separator: "\n")
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}
