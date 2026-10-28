import Foundation
import Testing
@testable import Dream

// Auto (Dream/Generation/Providers/Route.swift): what a page runs on when Dream's server picks.

@Suite("Auto")
struct RouteTests {
    @Test("a pick is named the way the log and the model name show it")
    func label() {
        let pick = Route.Pick(page: "page-1", model: "deepseek-v4.1-flash", effort: "none", name: "DeepSeek V4.1 Flash",
                              category: "money", difficulty: "easy", why: "Simple sums")
        #expect(pick.label == "Auto → DeepSeek V4.1 Flash · none")
    }

    @Test("with a model picked by name, nothing is asked and no pick is kept")
    func notAuto() async {
        let line = await Route.start(page: "page-2", request: "split a bill", image: nil)
        #expect(line == nil)
        #expect(Route.current == nil)
        #expect(Route.pick(for: "page-2") == nil)
        #expect(Route.pick(for: nil) == nil)
    }
}
