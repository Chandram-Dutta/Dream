import Foundation
import SwiftData
import Testing
@testable import Dream

// A change made on Dream's server landing on the page it changed (SavedSurface+Change.swift):
// one page under its id, with the user's numbers kept as a change made on the phone keeps them,
// whether the watch, the page's screen or sync gets there first. In a store in memory, as the app
// keeps pages.

private func split(people: Double) -> Surface {
    Surface(title: "Dinner split", summary: "₹2,400 between friends.", symbol: "fork.knife", accent: .green,
            inputs: [Input(name: "bill", label: "Bill", format: .currency, initial: 2400, min: 0, max: 20000, step: 50, options: []),
                     Input(name: "people", label: "People", format: .integer, initial: people, min: 1, max: 20, step: 1, options: [])],
            outputs: [Output(name: "share", label: "Each pays", formula: "bill / people", format: .currency)],
            blocks: [Block(id: "hero", kind: .hero, ref: "share")], related: [], reference: nil)
}

@Suite("A change landing on its page")
@MainActor
struct SavedChangeTests {
    private let container = try! ModelContainer(for: SavedSurface.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))

    private func saved(_ surface: Surface, values: [String: Double]) throws -> SavedSurface {
        let page = SavedSurface(intent: "split a 2400 rupee dinner", surface: surface, modelName: "grok-4.7", log: ["Request: split a 2400 rupee dinner"])
        page.values = values
        page.history = [PageTurn(.asked, page.intent, at: .now.addingTimeInterval(-60))]
        container.mainContext.insert(page)
        try container.mainContext.save()
        return page
    }

    private func copies(of id: UUID) throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.id == id }))
    }

    @Test("Landed by the watch and again by the screen, the page keeps the change once")
    func twice() throws {
        let page = try saved(split(people: 3), values: ["bill": 3000, "people": 5])
        let change = PageChange.instruction("make it 4 people", focus: "hero", on: page.surface, values: page.values)
        let changed = split(people: 4)
        page.land(change, as: changed, model: "grok-4.7-fast", log: ["Change: make it 4 people", "Done"])
        page.land(change, as: changed, model: "grok-4.7-fast", log: ["Change: make it 4 people", "Done"])
        try container.mainContext.save()
        #expect(try copies(of: page.id) == 1, "one page, under its own id")
        #expect(page.surface == changed && page.modelName == "grok-4.7-fast")
        #expect(page.values == ["bill": 3000], "their bill stays; people starts where the change put it")
        #expect(page.history.map(\.kind) == [.asked, .changed] && page.history.last?.text == "make it 4 people", "the change in its conversation, once")
        #expect(page.editRequests == ["make it 4 people"])
        #expect(page.generationLog == ["Request: split a 2400 rupee dinner", "Change: make it 4 people", "Done"], "its log, once")
    }

    @Test("After sync brought the server's copy first, the user's numbers come back")
    func syncFirst() throws {
        let page = try saved(split(people: 3), values: ["bill": 3000, "people": 5])
        let change = PageChange.instruction("make it 4 people", focus: nil, on: page.surface, values: page.values)
        // As Sync+Apply makes the server's item here: the changed page, its own numbers, its turn.
        let changed = split(people: 4)
        page.surface = changed
        page.values = [:]
        page.history = page.history + [PageTurn(.changed, "make it 4 people")]
        page.editRequests = ["make it 4 people"]
        page.land(change, as: changed, model: "grok-4.7", log: ["Change: make it 4 people"])
        try container.mainContext.save()
        #expect(try copies(of: page.id) == 1)
        #expect(page.values == ["bill": 3000], "the numbers the change left alone are theirs again")
        #expect(page.history.filter { $0.kind == .changed }.count == 1 && page.editRequests == ["make it 4 people"], "the turn the server noted isn't noted twice")
    }

    @Test("A different answer, and the page made again, are noted as changes made here are")
    func otherKinds() throws {
        let question = Question(text: "Is the tip in the bill?", topic: "Tip", options: ["Yes", "No"])
        var built = split(people: 3)
        built.answers = [Answer(question: question, choice: "Yes")]
        let page = try saved(built, values: ["bill": 3000, "people": 5])

        var rebuilt = split(people: 3)
        rebuilt.answers = [Answer(question: question, choice: "No")]
        let answer = PageChange.answer(built.answers![0], to: "No", on: built, values: page.values)
        page.land(answer, as: rebuilt, model: "grok-4.7", log: [])
        #expect(page.history.last?.kind == .answered && page.history.last?.text == "No" && page.history.last?.answers == rebuilt.answers)
        #expect(page.editRequests.last == Prompts.changedAnswer(built.answers![0], to: "No"))
        #expect(page.values == ["bill": 3000, "people": 5], "every input starts where it did, so every number stays")

        let again = PageChange.again(page.intent, on: page.surface, values: page.values)
        page.land(again, as: split(people: 6), model: "grok-4.7", log: [])
        #expect(page.history.last?.kind == .rebuilt && page.history.last?.text == page.intent)
        #expect(page.values == ["bill": 3000, "people": 5], "made again, the numbers stay as they were")
        #expect(page.editRequests.count == 1, "and it isn't a change asked for")
        #expect(try copies(of: page.id) == 1)
    }
}
