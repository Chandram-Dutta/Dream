import Foundation
import NaturalLanguage
import Testing
@testable import Dream

// The generation harness without a model: spotting an answer that has turned to padding, the
// room thinking gets beside an answer's budget, a repair that restates what the session lost,
// which server answers are worth asking again, and the language a finished page is labelled
// with. Whole pages on real models are Tools/bench-many.sh's job.

@Suite("Generation")
struct GenerationTests {
    @Test("Padding stops an answer; real JSON never does")
    func padding() {
        var json = ChatCompletions.Padding()
        let page = #"{"title": "Quadratic formula", "inputs": [{"name": "a", "initial": 1, "min": -10, "max": 10, "step": 0.1}],"#
            + #" "blocks": [{"kind": "paragraph", "text": "$\\pi$ is 3.14159265358979323846264338327950288419716939937510, give or take."}]}"#
        #expect(json.read(page) == nil, "a page, even one quoting fifty digits of π")
        var pretty = ChatCompletions.Padding()
        #expect(pretty.read("{\n" + String(repeating: "  ", count: 40) + "\"title\": \"x\"\n}") == nil, "indentation is fine")

        var blanks = ChatCompletions.Padding()
        #expect(blanks.read(#"{"title": "Packing list", "collections": ["#) == nil)
        var stopped: String?
        for _ in 0..<100 where stopped == nil { stopped = blanks.read("\n\n\n\n\n") }
        #expect(stopped?.contains("blank") == true, "hundreds of blank characters in a row, even a few at a time")

        var digits = ChatCompletions.Padding()
        #expect(digits.read(#"{"inputs": [{"name": "a", "max": 2.0000000000"#) == nil)
        #expect(digits.read(String(repeating: "0", count: 40))?.contains("digits") == true, "a number that keeps growing digits")
    }

    @Test("Thinking gets room beside an answer's budget")
    func thinkingRoom() {
        #expect(ChatCompletions.thinkingRoom("none") > 0 && ChatCompletions.thinkingRoom("none") == ChatCompletions.thinkingRoom("low"), "never none, since the server may raise the level")
        #expect(ChatCompletions.thinkingRoom("high") > ChatCompletions.thinkingRoom("medium") && ChatCompletions.thinkingRoom("medium") > ChatCompletions.thinkingRoom("low"), "more for longer thinking")
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

    @Test("Only a busy or silent model is asked again")
    func transient() {
        func error(_ status: Int, _ body: String, retryAfter: String? = nil) -> DreamServiceError {
            let response = HTTPURLResponse(url: URL(string: "https://dream.example/api/model")!, statusCode: status, httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] })!
            return DreamServiceError(response: response, body: Data(body.utf8))
        }
        #expect(error(502, #"{"error":"The model didn't answer. Try again in a moment."}"#).isTransient, "a model that didn't answer")
        #expect(error(503, #"{"error":"The model is busy. Try again in a moment."}"#, retryAfter: "20").isTransient, "a busy model")
        #expect(!error(503, #"{"error":"Dream's model isn't set up on this server yet."}"#).isTransient, "not a server that isn't set up")
        #expect(!error(503, #"{"error":"Dream is very busy today.","reason":"allowance"}"#, retryAfter: "3600").isTransient, "not a spent budget")
        #expect(!error(429, #"{"error":"You've used today's allowance.","reason":"allowance"}"#, retryAfter: "3600").isTransient, "not a used-up allowance")
        #expect(!error(400, #"{"error":"The model couldn't take that request."}"#).isTransient, "not a request the model refused")
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
