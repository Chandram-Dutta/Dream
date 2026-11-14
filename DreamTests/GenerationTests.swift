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
