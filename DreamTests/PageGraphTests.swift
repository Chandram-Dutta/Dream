import Foundation
import Testing
@testable import Dream

// How pages relate (PageGraph.swift), what a page going on from another starts from, what's said
// to a page, and a page's earlier versions. No model.

@Suite("Page graph")
struct PageGraphTests {
    private func node(_ title: String, _ intent: String, subjects: [String] = [], parent: UUID? = nil, found: String = "", hoursAgo: Double = 1) -> PageGraph.Node {
        PageGraph.Node(id: UUID(), title: title, intent: intent, subjects: subjects, parent: parent, found: found, updatedAt: .now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test("A request finds the earlier pages about the same things")
    func relatedToRequest() {
        let launch = node("Hyena Dart launch plan", "check my project's gtm notes", subjects: ["Hyena Dart", "GTM plan"], found: "Notion: hyena_dart — launch plan (page 41526556)")
        let kenya = node("Languages of Kenya", "what languages are spoken in kenya", subjects: ["Kenya"])
        let bill = node("Dinner bill split", "split a dinner bill four ways")
        let nodes = [launch, kenya, bill]

        #expect(PageGraph.related(toRequest: "what's the hyena dart launch date", in: nodes).map(\.id) == [launch.id], "named by its subject")
        #expect(PageGraph.related(toRequest: "how do kenya's schools teach swahili", in: nodes).first?.id == kenya.id)
        #expect(PageGraph.related(toRequest: "square root of 420", in: nodes).isEmpty, "and nothing for something new")
        #expect(PageGraph.described(launch).contains("page 41526556"), "with what was found for it")
    }

    @Test("A page's thread, the pages that went on from it, and what's related")
    func threads() {
        let bill = node("Dinner bill split", "split a ₹2,400 dinner bill four ways", subjects: ["Bengaluru"], hoursAgo: 5)
        let mumbai = node("Dinner bill split in Mumbai", "split it in Mumbai", subjects: ["Mumbai"], parent: bill.id, hoursAgo: 4)
        let tip = node("Tipping in Mumbai", "how much do people tip in Mumbai", subjects: ["Mumbai"], parent: mumbai.id, hoursAgo: 3)
        let other = node("Mumbai monsoon", "when does the monsoon reach mumbai", subjects: ["Mumbai"], hoursAgo: 2)
        let nodes = [bill, mumbai, tip, other]

        #expect(PageGraph.thread(of: tip, in: nodes).map(\.id) == [bill.id, mumbai.id, tip.id], "oldest first")
        #expect(PageGraph.children(of: bill, in: nodes).map(\.id) == [mumbai.id])
        let related = PageGraph.related(to: mumbai, in: nodes).map(\.id)
        #expect(Array(related.prefix(2)).sorted { $0.uuidString < $1.uuidString } == [bill.id, tip.id].sorted { $0.uuidString < $1.uuidString }, "the pages it's linked to first")
        #expect(related.contains(other.id), "then the ones about the same place")

        let clusters = PageGraph.clusters(nodes)
        #expect(clusters.first?.subject == "Mumbai" && clusters.first?.pages.count == 3, "what several pages share is a hub on the map")
        #expect(!clusters.contains { $0.subject == "Bengaluru" }, "one page alone isn't")
    }

    @Test("A page made before subjects were named is known by the names in it")
    func olderPages() {
        let old = node("Who was Ada Lovelace", "tell me about Ada Lovelace")
        #expect(PageGraph.subjects(of: old).contains { $0.contains("Ada Lovelace") })
    }

    @Test("A page going on from another keeps its numbers, answers and what was found")
    func goingOn() {
        var surface = Surface.empty
        surface.title = "Dinner bill split"
        surface.summary = "Each pays ₹690 with a 15% tip."
        surface.inputs = [Input(name: "bill", label: "Bill", format: .currency, initial: 2400, min: 0, max: 20000, step: 100, options: []),
                          Input(name: "people", label: "People", format: .integer, initial: 4, min: 1, max: 20, step: 1, options: [])]
        surface.answers = [Answer(question: Question(text: "Which city?", topic: "City", options: []), choice: "Bengaluru")]
        let lines = Prompts.goingOn(from: surface, asked: "split a dinner bill", found: "Tipping: 10–15% is usual", values: ["people": 5]).joined()
        #expect(lines.contains("Dinner bill split") && lines.contains("Bill: 2400") && lines.contains("People: 5"), "with the numbers as the user left them")
        #expect(lines.contains("Which city? Bengaluru") && lines.contains("Tipping: 10–15% is usual"))
    }

    @Test("What's said to a page changes it, unless the model says it goes on")
    func followUps() {
        let further = FollowUp.decision(FollowUp.WireDecision(reading: "the same for Mumbai", kind: .further, request: "Split a ₹2,400 dinner bill four ways in Mumbai"), said: "what about mumbai")
        #expect(further == .init(kind: .further, request: "Split a ₹2,400 dinner bill four ways in Mumbai"))
        let bare = FollowUp.decision(FollowUp.WireDecision(reading: "", kind: .new, request: " "), said: "who won the match")
        #expect(bare == .init(kind: .new, request: "who won the match"), "a new page without a request takes the user's words")
        let change = FollowUp.decision(FollowUp.WireDecision(reading: "monthly", kind: .change, request: "ignored"), said: "make it monthly")
        #expect(change.kind == .change && change.request.isEmpty)
    }

    @Test("A page keeps its earlier versions, and going back can be undone")
    func versions() {
        var first = Surface.empty
        first.title = "Weekly budget"
        let saved = SavedSurface(intent: "my budget", surface: first, modelName: "", log: [])
        var second = first
        second.title = "Monthly budget"
        saved.keepVersion(before: "make it monthly")
        saved.surface = second
        #expect(saved.versions.map(\.title) == ["Weekly budget"] && saved.versions.first?.change == "make it monthly")

        saved.restore(saved.versions[0])
        #expect(saved.surface.title == "Weekly budget", "back to how it was")
        #expect(saved.versions.map(\.title) == ["Monthly budget"], "and the version it left is kept")

        for index in 0..<20 { saved.keepVersion(before: "change \(index)") }
        #expect(saved.versions.count == SavedSurface.versionLimit, "up to a limit")
    }
}
