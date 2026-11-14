import Foundation
import FoundationModels
import NaturalLanguage
import Testing
@testable import Dream

// The generation harness without a model: the iPhone's narrower page, when a page goes to the
// other Apple model, the stages a request shows, a repair that restates what the session lost,
// and the language a finished page is labelled with. Whole pages on real models are
// Tools/bench-many.sh's job.

@Suite("Generation")
struct GenerationTests {
    @Test("The iPhone's narrower page becomes the same surface, checked like any other")
    func onDevicePage() {
        let wire = DeviceSurface(
            subject: .money, mode: .use, title: "Bill split", summary: "Each pays ₹600.", symbol: "fork.knife",
            question: "How much does each person pay?",
            inputs: [DeviceInput(name: "bill", label: "Bill", role: .adjustable, unit: "", format: .currency, initial: 2400, min: 0, max: 20000, step: 100, options: []),
                     DeviceInput(name: "people", label: "People", role: .adjustable, unit: "", format: .integer, initial: 4, min: 1, max: 20, step: 1, options: [])],
            outputs: [DeviceOutput(name: "share", label: "Each pays", unit: "", formula: "bill / people", format: .currency)],
            blocks: [DeviceBlock(kind: .hero, title: "", text: "", ref: "share", over: "", items: []),
                     DeviceBlock(kind: .slider, title: "", text: "", ref: "bill", over: "", items: []),
                     DeviceBlock(kind: .stepper, title: "", text: "", ref: "people", over: "", items: [])],
            related: ["Tipping customs in India"])
        var surface = wire.surface(reference: nil)
        #expect(surface.mode == .use && surface.blocks.map(\.kind) == [.hero, .slider, .stepper])
        #expect(surface.evaluate(surface.initialValues).values["share"] == 600, "the same engine works out its numbers")
        #expect(Checker.checkLogic(&surface).filter { $0.kind == .needsModel }.isEmpty, "and the same checker finds nothing to send back")
    }

    @Test("Tools share what's left of the window, and stop when it's spent")
    func budget() {
        let full = ContextBudget.forSession(window: 32_768, instructions: Prompts.surface, schema: WireSurface.generationSchema, tools: [], answer: 30_000, calls: 14)
        #expect(full.characters > 20_000 && full.characters < 80_000, "PCC's window leaves real room for tools beside the whole brief: \(full.characters)")
        let small = ContextBudget.forSession(window: 8_192, instructions: Prompts.surfaceOnDevice, schema: DeviceSurface.generationSchema, tools: [], answer: 6_000, calls: 4)
        #expect(small.characters < full.characters / 2, "the iPhone's window much less")

        let budget = ContextBudget(characters: 40_000, calls: 20)
        var given: [Int] = []
        for _ in 0..<10 where budget.mayCall() {
            let room = budget.allowance()
            given.append(room)
            budget.spend(room)
        }
        #expect(given.first == 8_000, "a first result gets up to the most")
        #expect(given == given.sorted(by: >), "each later one less, as many fetched at once: \(given)")
        #expect(given.reduce(0, +) <= 40_000 + ContextBudget.smallest, "never much past the budget")
        #expect(!budget.mayCall(), "and once it's spent, no more calls")

        let few = ContextBudget(characters: 100_000, calls: 2)
        #expect(few.mayCall() && few.mayCall() && !few.mayCall(), "calls are counted too")
    }

    @Test("A long result keeps its opening and the parts about the request")
    func excerpt() {
        let filler = (1...200).map { "Line \($0) about the office plants and the coffee rota." }
        let page = (["Hyena Dart — project notes", "Owner: Chandram"] + filler.prefix(100) + ["GTM plan: launch in Bengaluru first, with campus ambassadors and a waitlist."] + filler.suffix(100)).joined(separator: "\n")
        let kept = Excerpt.focused(page, on: "check my hyena dart gtm notes", limit: 1_500)
        #expect(kept.count <= 1_700)
        #expect(kept.hasPrefix("Hyena Dart — project notes"), "the opening says what it is")
        #expect(kept.contains("GTM plan: launch in Bengaluru"), "and the part asked about, from the middle")
        #expect(kept.contains("[…]"), "with the gaps marked")
        #expect(Excerpt.focused("short", on: "anything", limit: 100) == "short")
    }

    @Test("A long result is read apart, and only notes on it come back")
    func reader() async {
        let page = (1...400).map { "Line \($0) of a long Notion page about the launch." }.joined(separator: "\n")
        let asked = Asked()
        let reading = ContextBudget(characters: 40_000, calls: 10, reader: ResultReader { text, source, focus, limit in
            await asked.record(text.count, limit)
            return "Launch: 12 March, Bengaluru first (id 1f2e)."
        })
        let notes = await ContextBudget.$current.withValue(reading) {
            await ContextBudget.fit(page, from: "Notion's fetch", looking: "launch date", limit: 2_000)
        }
        #expect(notes.contains("Launch: 12 March") && notes.count < 300, "the writer gets the notes, not the page")
        let calls = await asked.calls, limits = await asked.limits
        #expect(calls == [page.count] && (limits.first ?? 0) <= 2_000, "the reader got all of it, and the room for notes")

        let short = await ContextBudget.$current.withValue(reading) {
            await ContextBudget.fit("A short answer.", from: "Notion", looking: "", limit: 2_000)
        }
        let after = await asked.calls.count
        #expect(short == "A short answer." && after == 1, "what fits isn't read apart")

        let failing = ContextBudget(characters: 40_000, calls: 10, reader: ResultReader { _, _, _, _ in throw DeadlinePassed() })
        let cut = await ContextBudget.$current.withValue(failing) {
            await ContextBudget.fit(page, from: "Notion", looking: "launch", limit: 2_000)
        }
        #expect(cut.count <= 2_100 && cut.contains("The parts about it"), "a reader that fails leaves the parts about the request")
        #expect(failing.readerGaveUp, "and the rest of the session doesn't wait on another")
    }

    @Test("Readers take turns, a few at a time")
    func gate() async throws {
        let gate = TakingTurns(width: 2)
        let counter = Asked()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.run {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let most = await counter.most
        #expect(most == 2)
    }

    @Test("A page goes to the other Apple model only when that might help")
    func otherModel() {
        #expect(AppleModels.isWorthTheOtherModel(PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "offline"))), "PCC out of reach: the iPhone writes it")
        #expect(AppleModels.isWorthTheOtherModel(PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "used up"))), "PCC's share used up for now")
        #expect(!AppleModels.isWorthTheOtherModel(CancellationError()), "not when the user stopped it")
    }

    @Test("Each stage of a request says whose turn it is")
    func stages() {
        let working: [Stage] = [.understanding, .researching, .writing, .checking]
        let waiting: [Stage] = [.yourTurn, .done, .failed]
        #expect(working.filter(\.isDreamsTurn).count == working.count)
        #expect(waiting.filter(\.isDreamsTurn).isEmpty)
    }

    @Test("A repair restates the request when the session lost it")
    func repair() {
        let problems = [Issue(kind: .needsModel, message: "The formula for 'share' uses 'bill', which isn't an input or output.")]
        let plain = Prompts.repair(problems)
        #expect(plain.contains("uses 'bill'") && !plain.contains("Request:"), "after a whole answer, the session has the rest")

        var kept = Surface(title: "Bill split", summary: "", symbol: "", accent: .blue, inputs: [], outputs: [], blocks: [], related: [], reference: nil)
        kept.outputs = [Output(name: "share", label: "Each pays", formula: "bill / people", format: .currency)]
        let asked = Prompts.surfaceRequest("split a 2400 rupee dinner bill four ways", hasImage: false, context: ["The request is in English, so write everything the user reads in English.", "Currency: Indian Rupee (INR, ₹)."])
        let restated = Prompts.repair(problems, restating: asked, screen: kept)
        #expect(restated.hasPrefix("Request: split a 2400 rupee dinner bill"), "the request comes first")
        #expect(restated.contains("write everything the user reads in English") && restated.contains("INR"), "with its language and currency")
        #expect(restated.contains("share: \"Each pays\"") && restated.contains("uses 'bill'"), "then the screen so far and its problems")
    }

    @Test("A page is labelled with the request's language when the text leaves it in the running")
    func pageLanguage() {
        var page = Surface(title: "होम लोन EMI", summary: "50 लाख के होम लोन पर 20 साल की EMI सालाना ब्याज दर से निकलती है।", symbol: "", accent: .blue, inputs: [], outputs: [], blocks: [], related: [], reference: nil)
        page.blocks = [Block(id: "block-0", kind: .paragraph, title: "", text: "किस्त घटते बैलेंस पर लगती है: हर महीने ब्याज बाकी मूलधन पर लगता है, और किस्त का बाकी हिस्सा मूलधन घटाता है।", ref: "", over: "", items: [], children: [])]
        #expect(Languages.of(page, likely: "hi") == .hindi, "a Hindi page asked for in Hindi")
        var spanish = page
        spanish.title = "División de la cuenta"
        spanish.summary = "Calcula la propina y cómo dividir la cuenta entre todos los que comieron."
        spanish.blocks[0].text = "Con una cuenta de 850 pesos y una propina del quince por ciento, cada persona paga su parte del total."
        #expect(Languages.of(spanish, likely: "en") == .spanish, "a page written in another language than asked is still read as what it is")
    }
}

/// What a test reader was asked, and how many ran at once.
private actor Asked {
    var calls: [Int] = []
    var limits: [Int] = []
    var now = 0
    var most = 0

    func record(_ count: Int, _ limit: Int) {
        calls.append(count)
        limits.append(limit)
    }

    func enter() {
        now += 1
        most = max(most, now)
    }

    func leave() {
        now -= 1
    }
}
