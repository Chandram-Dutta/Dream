import Foundation

// Talking to lists with a model: with -talk 1, the on-device model (then Grok, if it falls back)
// turns a few sentences into changes; with -edit 1, the composer changes a list's fields and the
// entries move onto them. Run with Tools/lists.sh, which first runs the checks that need no model
// (DreamTests/ListsTests.swift).

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_793_000_000)
let day: TimeInterval = 86_400

func record(_ values: [String: RecordValue], order: Double, daysAgo: Double) -> Record {
    Record(id: UUID(), values: values, order: order, created: now.addingTimeInterval(-daysAgo * day))
}

let expenses = RecordCollection(name: "expenses", label: "Expenses", entry: "expense", fields: [
    RecordField(name: "item", label: "Item", type: .text),
    RecordField(name: "amount", label: "Amount", type: .currency),
    RecordField(name: "category", label: "Category", type: .choice, options: ["Food", "Travel", "Bills"]),
    RecordField(name: "date", label: "Date", type: .date),
])
let groceries = RecordCollection(name: "groceries", label: "Groceries", entry: "grocery", fields: [
    RecordField(name: "name", label: "Name", type: .text),
    RecordField(name: "done", label: "Bought", type: .done),
])

let surface = Surface(title: "Spending", summary: "", symbol: "cart", accent: .green,
                      inputs: [Input(name: "budget", label: "Budget", format: .currency, initial: 1000, min: 0, max: 5000, step: 50, options: [])],
                      outputs: [
                          Output(name: "spent", label: "Spent", formula: "sum(expenses.amount)", format: .currency),
                          Output(name: "left", label: "Left", formula: "budget - spent", format: .currency),
                          Output(name: "average", label: "Average", formula: "avg(expenses.amount)", format: .currency),
                          Output(name: "latest", label: "Latest", formula: "last(expenses.amount)", format: .currency),
                          Output(name: "biggest", label: "Biggest", formula: "max(expenses.amount)", format: .currency),
                          Output(name: "bought", label: "Bought", formula: "count(groceries.done)", format: .integer),
                          Output(name: "toBuy", label: "To buy", formula: "count(groceries) - count(groceries.done)", format: .integer),
                      ],
                      blocks: [], related: [], reference: nil, collections: [expenses, groceries])

let entries: [String: [Record]] = [
    "expenses": [
        record(["item": .text("Lunch"), "amount": .number(400), "category": .text("Food"), "date": .number(now.addingTimeInterval(-2 * day).timeIntervalSince1970)], order: 0, daysAgo: 2),
        record(["item": .text("Taxi"), "amount": .number(250), "category": .text("Travel"), "date": .number(now.timeIntervalSince1970)], order: 1, daysAgo: 3),
        record(["item": .text("Rent"), "amount": .number(350), "date": .number(now.addingTimeInterval(-5 * day).timeIntervalSince1970)], order: 2, daysAgo: 0),
    ],
    "groceries": [
        record(["name": .text("Milk"), "done": .number(1)], order: 0, daysAgo: 1),
        record(["name": .text("Eggs")], order: 1, daysAgo: 1),
        record(["name": .text("Bread"), "done": .number(0)], order: 2, daysAgo: 1),
    ],
]

print("Prompt")
print(Prompts.recordRequest("mark the first two done", surface: surface, records: entries, hasImage: false, now: now).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))

if UserDefaults.standard.bool(forKey: "talk") {
    print("\nTalking to the lists")
    for sentence in ["add oat milk and a dozen eggs", "I spent 400 on lunch yesterday", "mark the first two done", "make it purple"] {
        print("  \"\(sentence)\"")
        let outcome = await RecordTalk.interpret(sentence, surface: surface, records: entries, now: now)
        switch outcome {
        case .screen?: print("    → a change to the screen")
        case .records(let operations)?: operations.forEach { print("    → \($0)") }
        case nil: print("    → nothing")
        }
    }
    print("  add bar: \"2 avocados and some limes\"")
    if case .records(let operations)? = await RecordTalk.interpret("2 avocados and some limes", surface: surface, records: entries, adding: "groceries", now: now) {
        operations.forEach { print("    → \($0)") }
    }
}

/// A change to the screen that changes a list's fields, through the composer, then the entries
/// moved onto the new fields.
@MainActor func editFields() async {
    print("\nChanging a list's fields through the composer")
    var shopping = Surface(title: "Grocery list", summary: "A grocery list you can check off as you shop.", symbol: "cart", accent: .green, inputs: [],
                           outputs: [Output(name: "remaining", label: "Still to get", formula: "count(groceries) - count(groceries.done)", format: .integer)],
                           blocks: [Block(id: "hero", kind: .hero, ref: "remaining"), Block(id: "add", kind: .add, ref: "groceries"), Block(id: "list", kind: .list, ref: "groceries")],
                           related: [], reference: nil, collections: [groceries])
    _ = Checker.checkLogic(&shopping)
    _ = Checker.checkBlocks(&shopping)
    let composer = Composer()
    await composer.edit(shopping, intent: "grocery list", instruction: "add a price column and show the total cost", focus: nil)
    guard let updated = composer.surface, updated != shopping else { print("  nothing changed"); return }
    print(updated.collectionSummary)
    print(updated.logicSummary)
    let moved = RecordMigration.migrate(entries, from: shopping.recordCollections, to: updated.recordCollections)
    let names = Set(updated.recordCollections.map(\.name))
    expect(moved.keys.contains { names.contains($0) && !(moved[$0] ?? []).isEmpty }, "the entries moved onto the changed list")
    let evaluation = updated.evaluate(updated.initialValues, records: moved)
    for output in updated.outputs { print("  \(output.label): \(updated.display(output.name, evaluation.values[output.name]))") }
}

if UserDefaults.standard.bool(forKey: "edit") { await editFields() }

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
