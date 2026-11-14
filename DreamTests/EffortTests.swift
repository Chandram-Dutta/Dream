import Foundation
import Testing
@testable import Dream

// Easy requests made fast (Effort.swift): sums Dream answers itself (InstantPage.swift), saved
// pages asked again with other numbers (PageReuse.swift), and the level a request starts at.

@Suite("Effort")
struct EffortTests {
    private func result(_ surface: Surface, _ name: String) -> Double? {
        surface.evaluate(surface.initialValues).values[name]
    }

    private func passes(_ surface: Surface) -> Bool {
        var surface = surface
        return Checker.checkLogic(&surface).filter { $0.kind == .needsModel }.isEmpty
    }

    @Test("Sums are answered at once, and checked like any page")
    func instant() throws {
        let root = try #require(InstantPage.make(for: "square root of 420"))
        #expect(abs((result(root, "root") ?? 0) - 20.4939) < 0.001)
        #expect(root.title == "Square root of 420" && root.blocks.first?.kind == .hero && passes(root))

        let tax = try #require(InstantPage.make(for: "Calculate 15% tax on 200 rupees"))
        #expect(result(tax, "part") == 30 && result(tax, "total") == 230 && passes(tax))
        #expect(tax.title == "15% tax on ₹200" || tax.title.hasPrefix("15% tax on"), "\(tax.title)")

        let off = try #require(InstantPage.make(for: "20% off 1500"))
        #expect(result(off, "price") == 1200 && result(off, "saving") == 300 && passes(off))

        let gst = try #require(InstantPage.make(for: "18% GST on 1200"))
        #expect(result(gst, "part") == 216 && gst.title.contains("GST"))

        let share = try #require(InstantPage.make(for: "what is 15% of 80?"))
        #expect(result(share, "result") == 12)

        let sum = try #require(InstantPage.make(for: "12 x 7 + 3"))
        #expect(result(sum, "result") == 87 && sum.inputs.count == 3 && passes(sum))
        #expect(result(try #require(InstantPage.make(for: "what's 450 divided by 6")), "result") == 75)
        #expect(result(try #require(InstantPage.make(for: "45 times 12")), "result") == 540)
        #expect(result(try #require(InstantPage.make(for: "(3 + 4) * 2")), "result") == 14)

        #expect(result(try #require(InstantPage.make(for: "2 to the power of 10")), "result") == 1024)
        #expect(result(try #require(InstantPage.make(for: "12 squared")), "result") == 144)
        #expect(abs((result(try #require(InstantPage.make(for: "cube root of 27")), "root") ?? 0) - 3) < 1e-9)
        #expect(result(try #require(InstantPage.make(for: "sqrt 9")), "root") == 3)
    }

    @Test("Anything more than a sum goes to the model")
    func notInstant() {
        for request in ["square root of 420 in history", "what is a prime number", "split a dinner bill four ways", "tax on my salary",
                        "who was Ada Lovelace", "15% tax on my salary of 50000 per month in Bengaluru", "2024 olympics", "7", "convert 5 km to miles"] {
            #expect(InstantPage.make(for: request) == nil, "\(request)")
        }
    }

    @Test("A saved calculation is made again with the request's numbers")
    func reuse() throws {
        let earlier = try #require(InstantPage.make(for: "15% tax on 200 rupees"))
        let again = try #require(PageReuse.adapt(earlier, asked: "15% tax on 200 rupees", for: "15% tax on 300 rupees"))
        #expect(result(again, "part") == 45 && result(again, "total") == 345)
        #expect(again.title.contains("300") && !again.title.contains("200"), "its words quote the new numbers: \(again.title)")

        var bill = Surface.empty
        bill.mode = .use
        bill.title = "Split ₹2,400 four ways"
        bill.summary = "Each pays ₹600."
        bill.inputs = [Input(name: "bill", label: "Bill", format: .currency, initial: 2400, min: 0, max: 5000, step: 100, options: []),
                       Input(name: "people", label: "People", format: .integer, initial: 4, min: 1, max: 20, step: 1, options: [])]
        bill.outputs = [Output(name: "share", label: "Each pays", formula: "bill / people", format: .currency)]
        bill.blocks = [Block(id: "hero", kind: .hero, ref: "share")]
        let bigger = try #require(PageReuse.adapt(bill, asked: "split 2400 between 4 people", for: "split 9000 between 5 people"))
        #expect(result(bigger, "share") == 1800)
        #expect(bigger.inputs[0].max >= 9000, "a control reaches the new number")

        #expect(PageReuse.adapt(bill, asked: "split 2400 between 4 people", for: "split 2400 between 4 friends") == nil, "other words")
        #expect(PageReuse.adapt(bill, asked: "split 2400 between 4 people", for: "split 2400 between 4 people") == nil, "the same numbers: open the page")
        var live = bill
        live.sources = [Source(name: "rate", kind: "rates", parameters: [:], fields: [])]
        #expect(PageReuse.adapt(live, asked: "split 2400 between 4 people", for: "split 9000 between 5 people") == nil, "nothing with live values")
    }

    @Test("Each request starts at the level it needs")
    func levels() {
        #expect(Effort.level(for: "split 2400 between 4 people with a 10% tip", hasImage: false) == .quick)
        #expect(Effort.level(for: "EMI for a 50 lakh loan at 8.5% for 20 years", hasImage: false) == .quick)
        #expect(Effort.level(for: "my monthly budget with 60000 salary", hasImage: false) == .quick)
        #expect(Effort.level(for: "who was Ada Lovelace", hasImage: false) == .standard, "facts about the world are looked up")
        #expect(Effort.level(for: "rent in Bandra for a 2bhk under 50000", hasImage: false) == .standard, "a place may need looking up")
        #expect(Effort.level(for: "convert 100 usd to inr", hasImage: false) == .standard, "money between currencies needs today's rate")
        #expect(Effort.level(for: "latest iPhone price in India", hasImage: false) == .standard)
        #expect(Effort.level(for: "split the bill", hasImage: false) == .standard, "no numbers: something to understand first")
        #expect(Effort.level(for: "compare the three cheapest EVs in India in depth", hasImage: false) == .deep)
        #expect(Effort.level(for: "split 2400 four ways", hasImage: true) == .standard, "a photo is looked at first")
    }
}
