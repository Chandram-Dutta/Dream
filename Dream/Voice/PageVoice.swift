import Foundation

/// Everything a surface's screen does with voice: reading the page aloud, hands-free steps, and
/// listening for a change. One at a time; starting one stops the others.
@MainActor @Observable
final class PageVoice {
    let reader = Reader()
    let handsFree = HandsFree()
    /// For saying a change, like "make it monthly".
    let listener = Listener()
    @ObservationIgnored private var lastScrolled = ContinuousClock.now - .seconds(60)

    var isReading: Bool { reader.phase != .idle || handsFree.isActive }

    /// What's being read: a block, one step, or `Narration.headerID`.
    var readingID: String? { handsFree.isActive ? handsFree.readingID : reader.passageID }

    /// Whether the page should scroll to what's being read. Not while someone's scrolling it themselves.
    var follows: Bool { ContinuousClock.now - lastScrolled > .seconds(4) }

    func readPage(_ surface: Surface, state: SurfaceState) {
        stop()
        reader.read({ surface.narration(values: state.values) }, sample: surface.title + ". " + surface.summary)
    }

    func readSteps(_ block: Block, of surface: Surface, state: SurfaceState) {
        stop()
        handsFree.start(block) { surface.spokenSteps(of: block, values: state.values) }
    }

    func stop() {
        reader.stop()
        handsFree.stop()
        if listener.isActive { listener.cancel() }
    }

    func userScrolled() {
        lastScrolled = .now
    }
}
