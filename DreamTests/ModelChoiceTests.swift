import Foundation
import Testing
@testable import Dream

// The thinking level the pickers show as picked (Dream/Generation/Providers/DreamModel.swift),
// which has to match the level the server actually uses (Server/src/model.ts).

@Suite("Model choice")
struct ModelChoiceTests {
    @Test("an offered pick shows as itself")
    func offered() {
        #expect(ThinkingChoice.shown("medium", among: ["low", "medium", "high"]) == "medium")
        #expect(ThinkingChoice.shown("none", among: ThinkingChoice.levels) == "none")
    }

    @Test("a pick from another plan shows as the nearest offered, as the server moves it")
    func nearest() {
        // Dream Plus after testing every level: the server sends max as high, and off as low.
        #expect(ThinkingChoice.shown("max", among: ["low", "medium", "high"]) == "high")
        #expect(ThinkingChoice.shown("none", among: ["low", "medium", "high"]) == "low")
        // Two equally near: the longer, as the server leans.
        #expect(ThinkingChoice.shown("medium", among: ["low", "high"]) == "high")
    }

    @Test("nothing to pick shows nothing; an unknown pick shows low")
    func fallbacks() {
        #expect(ThinkingChoice.shown("low", among: []) == nil)
        #expect(ThinkingChoice.shown("", among: ["low", "high"]) == "low")
        #expect(ThinkingChoice.shown("", among: ["high", "max"]) == "high")
    }
}
