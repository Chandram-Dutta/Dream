import Foundation
import Testing
@testable import Dream

// The checker's judgement of a whole page, without a model: what counts as money, a control that
// changes nothing, a page about the world that looked nothing up, and whose picture belongs on it.

private func number(_ name: String, label: String? = nil, unit: String = "", role: InputRole = .adjustable) -> Input {
    Input(name: name, label: label ?? Checker.words(name), format: .number, initial: 10, min: 0, max: 100, step: 1, options: [], role: role, unit: unit)
}

private func page(_ title: String = "Page", mode: Mode? = nil, blocks: [Block] = []) -> Surface {
    var surface = Surface(title: title, summary: "", symbol: "", accent: .blue, inputs: [], outputs: [], blocks: blocks, related: [], reference: nil)
    surface.mode = mode
    return surface
}

@Suite("Checker")
struct CheckerTests {
    @Test("A rate, a growth or a term beside a money word isn't money")
    func money() {
        #expect(Checker.looksLikeMoney("rent Monthly rent"), "rent is money")
        #expect(Checker.looksLikeMoney("evCostPerKm Electric cost per km"), "a cost per km is money")
        #expect(!Checker.looksLikeMoney("rate Home loan rate"), "a loan's rate isn't")
        #expect(!Checker.looksLikeMoney("rentGrowth Rent rise each year"), "how fast rent grows isn't")
        #expect(!Checker.looksLikeMoney("tenure Loan tenure"), "a loan's term isn't")

        var surface = page()
        surface.inputs = [number("rate", label: "Home loan rate"), number("rent", label: "Monthly rent"), number("loanFee", label: "Loan fee", unit: "%")]
        surface.outputs = [Output(name: "total", label: "Total", formula: "rent * (1 + rate / 100) + loanFee", format: .number)]
        _ = Checker.checkLogic(&surface)
        #expect(surface.input("rate")?.format == .number, "the rate stays a number")
        #expect(surface.input("rent")?.format == .currency, "the rent becomes money")
        #expect(surface.input("loanFee")?.format == .number, "a unit of its own says what it measures")
    }

    @Test("A control that changes no result goes back to the model")
    func idleControl() {
        var surface = page()
        surface.inputs = [number("price"), number("rent")]
        surface.outputs = [Output(name: "emi", label: "EMI", formula: "price / 100", format: .currency)]
        let issues = Checker.checkLogic(&surface)
        #expect(issues.contains { $0.kind == .needsModel && $0.message.contains("'rent'") }, "rent, which nothing uses, is sent back")

        var shown = page(blocks: [Block(id: "p", kind: .paragraph, text: "You'd pay {rent} a month.")])
        shown.inputs = [number("price"), number("rent")]
        shown.outputs = [Output(name: "emi", label: "EMI", formula: "price / 100", format: .currency)]
        #expect(!Checker.checkLogic(&shown).contains { $0.kind == .needsModel }, "a value the text shows is used")

        var fixed = page()
        fixed.inputs = [number("price"), number("gravity", role: .given)]
        fixed.outputs = [Output(name: "emi", label: "EMI", formula: "price / 100", format: .currency)]
        #expect(!Checker.checkLogic(&fixed).contains { $0.kind == .needsModel }, "an unused given is only clutter")
    }

    @Test("A page about the world that looked nothing up goes back once")
    func sourcing() {
        let nothing = ReadingList()
        #expect(!Checker.checkSourcing(page("Hampi", mode: .read), read: nothing).isEmpty, "a page to read needs sources")
        #expect(!Checker.checkSourcing(page("Rent", mode: .decide, blocks: [Block(id: "f", kind: .facts)]), read: nothing).isEmpty, "so do facts on any page")
        #expect(Checker.checkSourcing(page("Split", mode: .use), read: nothing).isEmpty, "a tool for the user's own numbers doesn't")

        var cited = page("Hampi", mode: .read)
        cited.reference = Reference(title: "Hampi", extract: "", url: "https://en.wikipedia.org/wiki/Hampi")
        #expect(Checker.checkSourcing(cited, read: nothing).isEmpty, "a page that looked something up is fine")
    }

    @Test("The article's picture shows only when it's what the page is about")
    func picture() {
        func with(_ article: String, title: String, mode: Mode?) -> Surface {
            var surface = page(title, mode: mode, blocks: [Block(id: "p", kind: .paragraph, text: "Text.")])
            surface.reference = Reference(title: article, extract: "", url: "https://en.wikipedia.org/wiki/x", imageURL: "https://upload.wikimedia.org/x.jpg")
            return surface
        }
        #expect(with("Hampi", title: "Hampi in 3 Days", mode: .read).pictureURL != nil, "Hampi's page shows Hampi")
        #expect(with("Vaccine", title: "How Vaccines Work", mode: .learn).pictureURL != nil, "a plural is the same thing")
        #expect(with("Cow tipping", title: "Split the Dinner", mode: .read).pictureURL == nil, "a side issue's picture isn't shown")
        #expect(with("Hampi", title: "Hampi Trip Cost", mode: .use).pictureURL == nil, "a tool has no article picture")
    }
}
