import Foundation
import Testing
@testable import Dream

// Lists without the app: totals over entries, the checker's repairs, record changes, moving
// entries when fields change, and the quick-add bar. Talking to a list with a model stays in
// Tools/lists.sh -talk 1.

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let day: TimeInterval = 86_400

private func record(_ values: [String: RecordValue], order: Double, daysAgo: Double) -> Record {
    Record(id: UUID(), values: values, order: order, created: now.addingTimeInterval(-daysAgo * day))
}

private let expenses = RecordCollection(name: "expenses", label: "Expenses", entry: "expense", fields: [
    RecordField(name: "item", label: "Item", type: .text),
    RecordField(name: "amount", label: "Amount", type: .currency),
    RecordField(name: "category", label: "Category", type: .choice, options: ["Food", "Travel", "Bills"]),
    RecordField(name: "date", label: "Date", type: .date),
])

private let groceries = RecordCollection(name: "groceries", label: "Groceries", entry: "grocery", fields: [
    RecordField(name: "name", label: "Name", type: .text),
    RecordField(name: "done", label: "Bought", type: .done),
])

private let spending = Surface(title: "Spending", summary: "", symbol: "cart", accent: .green,
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

private let entries: [String: [Record]] = [
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

@Suite("Lists")
struct ListsTests {
    @Test("Totals over entries")
    func totals() {
        let surface = spending
        let evaluation = surface.evaluate(surface.initialValues, records: entries)
        #expect(near(evaluation.values["spent"], 1000), "sum(expenses.amount) is 1000")
        #expect(near(evaluation.values["left"], 0), "budget - spent is 0")
        #expect(near(evaluation.values["average"], 1000.0 / 3), "avg is a third of 1000")
        #expect(near(evaluation.values["latest"], 250), "last() is the latest by date (taxi, today), not the latest added")
        #expect(near(evaluation.values["biggest"], 400), "max() over a list")
        #expect(near(evaluation.values["bought"], 1), "count(groceries.done) counts checked entries")
        #expect(near(evaluation.values["toBuy"], 2), "count(groceries) counts entries")
        #expect(near(evaluation.values["sum(expenses.amount)"], 1000), "each total is kept for worked equations")
        let empty = surface.evaluate(surface.initialValues)
        #expect(near(empty.values["spent"], 0) && near(empty.values["toBuy"], 0), "with no entries, sums and counts are 0")
        #expect(!(empty.values["average"]?.isFinite ?? true), "with no entries, there's no average")
        #expect(near(try? Expr.parse("min(3, 1, 2)").evaluate { _ in 0 }, 1), "min() of plain values still works")
        #expect(near(try? Expr.parse("count(1, 0, 5)").evaluate { _ in 0 }, 2), "count() of plain values counts the non-zero ones")
        var bare = surface
        bare.outputs[0].formula = "expenses.amount * 2"
        #expect(bare.evaluate(bare.initialValues, records: entries).errors["spent"]?.contains("total it") == true, "a list used as a number says how to total it")
    }

    @Test("Arranging entries, and charts of them")
    func arrangingAndCharts() throws {
        let shownExpenses = expenses.arranged(try #require(entries["expenses"])).map { $0["item"]?.textValue ?? "" }
        #expect(shownExpenses == ["Taxi", "Lunch", "Rent"], "a log is newest first by date")
        let shownGroceries = groceries.arranged(try #require(entries["groceries"])).map { $0["name"]?.textValue ?? "" }
        #expect(shownGroceries == ["Eggs", "Bread", "Milk"], "checked entries sink below the rest")

        let byCategory = expenses.series(of: "amount", along: "category", in: try #require(entries["expenses"]))
        #expect(byCategory.map { "\($0.label) \($0.value.plain)" } == ["Food 400", "Travel 250", "Other 350"], "amounts add up by category, in the options' order")
        let byDay = expenses.series(of: "amount", along: "date", in: try #require(entries["expenses"]))
        #expect(byDay.count == 3 && byDay.first?.value == 350 && byDay.last?.value == 250, "one point a day, oldest first")
        let counted = groceries.series(of: nil, along: "name", in: try #require(entries["groceries"]))
        #expect(counted.count == 3 && counted.allSatisfy { $0.value == 1 }, "counting entries by name")
    }

    @Test("The checker repairs lists, fields and the formulas over them")
    func checker() throws {
        var written = spending
        written.collections![0].name = "Expenses list"
        written.collections![0].fields.append(RecordField(name: "tip", label: "Tip", type: .number))
        written.outputs[0].formula = "sum(expenses.amount)"
        written.outputs[2].formula = "avg(Expenses.amout)"
        written.inputs = []
        written.outputs.remove(at: 1)
        let logic = Checker.checkLogic(&written)
        #expect(written.collections?.first?.name == "expensesList", "a list's name becomes an identifier")
        #expect(written.collections?.first?.fields.last?.type == .currency, "money in a number field is shown as money")
        #expect(!logic.contains { $0.kind == .needsModel }, "totals need no inputs")
        #expect(written.outputs[0].formula == "sum(expensesList.amount)", "a list the checker renamed is still found")
        #expect(written.outputs[1].formula == "avg(expensesList.amount)", "near-miss field names are repaired")

        var typo = spending
        typo.outputs[0].formula = "sum(expences.amount) + count(grocery)"
        _ = Checker.checkLogic(&typo)
        #expect(typo.outputs[0].formula == "sum(expenses.amount) + count(groceries)", "misspelt lists, and a list by its entry's name, are repaired")

        var unknown = spending
        unknown.outputs[0].formula = "sum(expenses.price)"
        #expect(Checker.checkLogic(&unknown).contains { $0.kind == .needsModel && $0.message.contains("expenses.price") }, "an unknown field goes back to the model")
    }

    @Test("The checker places list blocks and binds charts to lists")
    func blocks() {
        var blocks = spending
        blocks.blocks = [
            Block(id: "hero", kind: .hero, ref: "spent"),
            Block(id: "list", kind: .list, ref: "expense"),
            Block(id: "chart", kind: .data, title: "By category", ref: "expenses.amount", over: "category"),
            Block(id: "weights", kind: .data, title: "Nothing", ref: "weights.value"),
        ]
        _ = Checker.checkLogic(&blocks)
        _ = Checker.checkBlocks(&blocks)
        let kinds = blocks.blocks.map { "\($0.kind.rawValue):\($0.ref)" }
        #expect(kinds.starts(with: ["hero:spent", "add:expenses", "list:expenses"]), "a list gets an add bar above it, and a near-miss ref is read")
        #expect(blocks.blocks.contains { $0.kind == .data && $0.ref == "expenses.amount" && $0.over == "expenses.category" }, "a data chart can be bound to a list's fields")
        #expect(blocks.blocks.contains { $0.kind == .add && $0.ref == "groceries" } && blocks.blocks.contains { $0.kind == .list && $0.ref == "groceries" }, "a list nothing shows is placed")
        #expect(!blocks.blocks.contains { $0.id == "weights" }, "a data block with neither a list nor figures is dropped")
    }

    @Test("The checker tidies fields and starters")
    func starters() throws {
        var starters = Surface(title: "Packing", summary: "", symbol: "suitcase", accent: .teal, inputs: [], outputs: [], blocks: [], related: [], reference: nil,
                               collections: [RecordCollection(name: "items", label: "Items", entry: "", fields: [RecordField(name: "Item name", label: "", type: .text), RecordField(name: "packed", label: "Packed", type: .done), RecordField(name: "kind", label: "Kind", type: .choice, options: ["Clothes"])],
                                                              starters: [["Item name": .text("Towel")], ["Item name": .text("towel")], ["packed": .number(1)]])])
        _ = Checker.checkLogic(&starters)
        let packing = try #require(starters.collections?.first)
        #expect(packing.fields[0].name == "itemName" && packing.fields[0].label == "Item name", "field names become identifiers, with labels")
        #expect(packing.fields[2].type == .text, "a choice with one option becomes text")
        #expect(packing.starters.count == 1 && packing.starters.first?["itemName"] == .text("Towel"), "starters follow renamed fields, unnamed and repeated ones are dropped")
        #expect(packing.entry == "item", "an entry is named from the label when the model didn't")
    }

    @Test("Proposed record changes are checked, then applied")
    func recordChanges() {
        let surface = spending
        let proposed = [
            ProposedOperation(action: .insert, collection: "expenses", entry: 0, values: [.init(field: "item", value: "Coffee"), .init(field: "Amount", value: "₹1,200.50"), .init(field: "category", value: "food"), .init(field: "date", value: "yesterday")]),
            ProposedOperation(action: .update, collection: "grocery", entry: 1, values: [.init(field: "done", value: "yes")]),
            ProposedOperation(action: .delete, collection: "groceries", entry: 3, values: []),
            ProposedOperation(action: .update, collection: "groceries", entry: 9, values: [.init(field: "name", value: "Bread"), .init(field: "done", value: "yes")]),
            ProposedOperation(action: .insert, collection: "expenses", entry: 0, values: [.init(field: "amount", value: "lots")]),
            ProposedOperation(action: .update, collection: "groceries", entry: 2, values: [.init(field: "colour", value: "red")]),
        ]
        let checked = RecordChecker.check(proposed, in: surface, records: entries, now: now)
        #expect(checked.operations.count == 4, "four of six proposed changes are usable")
        #expect(checked.issues.contains { $0.contains("lots") } && checked.issues.contains { $0.contains("colour") }, "the rest are reported")
        if case .insert(_, let values) = checked.operations.first {
            #expect(values["amount"] == .number(1200.5) && values["category"] == .text("Food"), "amounts and choices are read from text")
            #expect(values["date"]?.numberValue.map { Calendar.current.isDate(Date(timeIntervalSince1970: $0), inSameDayAs: now.addingTimeInterval(-day)) } == true, "'yesterday' is yesterday")
        } else {
            Issue.record("the first change is the coffee")
        }
        var changed = entries
        surface.apply(checked.operations, to: &changed, at: now)
        let groceriesAfter = groceries.arranged(changed["groceries"] ?? []).map { "\($0["name"]?.textValue ?? ""):\($0.isOn("done") ? 1 : 0)" }
        #expect(groceriesAfter == ["Eggs:1", "Bread:1"], "entry 1 (Eggs) checked, entry 3 (Milk) deleted, Bread found by name")
        #expect(changed["expenses"]?.count == 4, "the coffee was added")
    }

    @Test("Entries move onto changed fields")
    func changingFields() {
        var renamed = expenses
        renamed.fields[1] = RecordField(name: "price", label: "Amount", type: .number)
        renamed.fields.append(RecordField(name: "logged", label: "Logged", type: .date))
        renamed.fields.removeAll { $0.name == "date" }
        renamed.fields.append(RecordField(name: "rating", label: "Worth it", type: .rating))
        let migrated = RecordMigration.migrate(entries, from: [expenses, groceries], to: [renamed, groceries])
        let lunch = migrated["expenses"]?.first { $0["item"] == .text("Lunch") }
        #expect(lunch?["price"] == .number(400), "a renamed field keeps its values (matched by label)")
        #expect(lunch?["amount"] == nil, "the old name is gone")
        #expect(lunch?["date"] != nil, "a removed field's values are kept, in case it comes back")
        #expect(lunch?["rating"] == nil, "a new field starts empty")
        #expect(lunch?["logged"]?.numberValue == lunch?.created.timeIntervalSince1970, "a new date starts as when the entry was added")
        var retyped = groceries
        retyped.name = "shopping"
        retyped.label = "Groceries"
        retyped.fields[1].type = .text
        let moved = RecordMigration.migrate(entries, from: [expenses, groceries], to: [expenses, retyped])
        #expect(moved["groceries"] == nil && moved["shopping"]?.count == 3, "a renamed list takes its entries")
        #expect(moved["shopping"]?.contains { $0["done"] != nil } == false, "a done field turned into text drops its yes/no")
    }

    @Test("The quick-add bar reads what it can and leaves sentences to a model")
    func quickAdd() {
        func quick(_ text: String, _ collection: RecordCollection) -> QuickAdd.Reading { QuickAdd.read(text, for: collection, now: now) }
        let coffee = quick("Coffee 4.50", expenses)
        #expect(coffee.isPlain && coffee.entries.first?["item"] == .text("Coffee") && coffee.entries.first?["amount"] == .number(4.5), "Coffee 4.50")
        let taxi = quick("taxi ₹1,300 yesterday travel", expenses).entries.first
        #expect(taxi?["item"] == .text("Taxi") && taxi?["amount"] == .number(1300) && taxi?["category"] == .text("Travel") && taxi?["date"] != nil, "taxi ₹1,300 yesterday travel")
        let three = quick("milk, eggs,bread", groceries)
        #expect(three.isPlain && three.entries.compactMap { $0["name"]?.textValue } == ["Milk", "Eggs", "Bread"], "milk, eggs,bread")
        #expect(!quick("I spent 400 on lunch at work", expenses).isPlain, "a sentence is left to a model")
        #expect(!quick("mac and cheese", groceries).isPlain, "'and' is left to a model, which knows mac and cheese is one thing")
        #expect(quick("B12 vitamins", groceries).entries.first?["name"] == .text("B12 vitamins"), "a number inside a word stays in the name")
        let insurance = quick("Travel insurance 200", expenses).entries.first
        #expect(insurance?["item"] == .text("Travel insurance") && insurance?["category"] == nil, "an option's name inside the name stays there")
        let habits = RecordCollection(name: "days", label: "Days", entry: "day", fields: [RecordField(name: "date", label: "Date", type: .date), RecordField(name: "exercise", label: "Exercise", type: .done)])
        #expect(quick("", habits).entries.isEmpty, "nothing typed is nothing added (the bar adds a blank day itself)")
    }

    @Test("The prompt for talking to lists names every entry and field")
    func prompt() {
        let prompt = Prompts.recordRequest("mark the first two done", surface: spending, records: entries, hasImage: false, now: now)
        #expect(prompt.contains("mark the first two done"))
        #expect(["Lunch", "Taxi", "Rent", "Milk", "Eggs", "Bread"].allSatisfy(prompt.contains), "every entry is shown")
    }
}
