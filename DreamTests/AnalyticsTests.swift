import Foundation
import Testing
@testable import Dream

// What analytics may say about a page (Dream/Engine/Analytics.swift): its shape, never its words.

@Suite("Analytics")
struct AnalyticsTests {
    /// A page full of things that must never leave the phone in an event.
    private var personal: Surface {
        var surface = Surface.empty
        surface.title = "Priya's surprise party"
        surface.summary = "Budget for 12 guests at Priya's flat"
        surface.blocks = [
            Block(id: "intro", kind: .paragraph, text: "Keep it secret from Priya."),
            Block(id: "plan", kind: .section, title: "Plan", children: [
                Block(id: "people", kind: .slider, ref: "guests"),
                Block(id: "cost", kind: .hero, ref: "total"),
            ]),
        ]
        surface.inputs = [Input(name: "guests", label: "Guests", format: .integer, initial: 12, min: 1, max: 40, step: 1, options: [])]
        surface.outputs = [Output(name: "total", label: "Total", formula: "guests * 350", format: .currency)]
        surface.answers = [Answer(question: Question(text: "Whose party?", topic: "Guest of honour", options: []), choice: "Priya")]
        surface.citations = [Citation(title: "Party ideas", site: "Example", url: "https://example.com/priya")]
        return surface
    }

    @Test("a finished page is described by its shape")
    func shape() {
        let properties = Analytics.Event.pageBuilt(Analytics.Shape(personal), model: "Grok (grok-4.7)", seconds: 21.37).properties
        #expect(properties["blocks"] as? Int == 4)
        #expect(properties["block_kinds"] as? [String] == ["hero", "paragraph", "section", "slider"])
        #expect(properties["inputs"] as? Int == 1)
        #expect(properties["outputs"] as? Int == 1)
        #expect(properties["used_web"] as? Bool == true)
        #expect(properties["asked_questions"] as? Bool == true)
        #expect(properties["used_connections"] as? Bool == false)
        #expect(properties["seconds"] as? Double == 21.4)
    }

    @Test("no event carries what the page says")
    func noWords() {
        let shape = Analytics.Shape(personal)
        let events: [Analytics.Event] = [
            .pageBuilt(shape, model: "Grok (grok-4.7)", seconds: 3),
            .pageChanged(shape, pointedAtBlock: true, seconds: 2),
            .pageFailed(.network, changing: false, seconds: 1),
            .pageBuilt(shape, model: "PCC", seconds: 3, run: Analytics.Run(level: "quick", source: "follow_up", understoodSeconds: 2, firstBlockSeconds: 3)),
        ]
        for event in events {
            let written = "\(event.properties)"
            for word in ["Priya", "party", "secret", "Guests", "example.com", "350"] {
                #expect(!written.contains(word), "\(event.name) mentions \(word)")
            }
        }
    }

    @Test("event names are unique and snake case")
    func names() {
        let shape = Analytics.Shape(.empty)
        let events: [Analytics.Event] = [
            .appOpened, .signedIn, .signedOut, .pageRequested(withPhoto: false), .pageBuilt(shape, model: "", seconds: 0),
            .pageFailed(.other, changing: false, seconds: 0), .pageChanged(shape, pointedAtBlock: false, seconds: 0),
            .controlsUsed(changes: 1, controls: 1), .shared(.link, withNumbers: false), .openedShared(again: false),
            .listEntriesAdded(count: 1), .connectionAdded(needsSignIn: false), .toolPromptShown, .toolPromptAnswered(.once),
            .paywallShown, .subscriptionStarted(product: "monthly"), .subscriptionEnded, .limitReached(kind: "pages"),
        ]
        let generation = Analytics.Generation(trace: "t", step: "writing", model: "PCC", seconds: 1, inputTokens: 1, outputTokens: 1, reasoning: "light", level: "quick")
        let more: [Analytics.Event] = [
            .pageUnderstood(seconds: 1, toolCalls: 0, questions: 0, foundSomething: false, relatedPages: 0, trace: "t"),
            .questionsAnswered(count: 1, leftToDream: 0, remembered: 0, seconds: 1, trace: "t"), .firstBlock(seconds: 1, level: "quick", trace: "t"),
            .generation(generation), .toolCall(kind: "lookup", seconds: 1, characters: 1, trace: "t", failed: false),
            .pageTrace(trace: "t", seconds: 1, level: "quick", failed: false), .followUpDecided(kind: "change", seconds: 1), .versionRestored,
            .pageStarred(on: true), .suggestionTapped(position: 0, personal: true), .libraryOpened, .mapOpened(pages: 1), .linkedPageOpened(from: "map"),
        ]
        let names = (events + more).map(\.name)
        #expect(Set(names).count == names.count)
        // PostHog's own LLM analytics events start with $ai_.
        #expect(names.allSatisfy { $0.range(of: "^(\\$ai_)?[a-z]+(_[a-z]+)*$", options: .regularExpression) != nil })
    }

    @Test("nothing is sent while nobody listens, and flags fall back")
    func quiet() {
        Analytics.sink = nil
        Analytics.send(.appOpened)
        FeatureFlag.source = nil
        #expect(FeatureFlag("anything", fallback: true).isOn)
        #expect(!FeatureFlag("anything", fallback: false).isOn)
    }
}
