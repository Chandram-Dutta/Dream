import UIKit

/// A steps block one step at a time, for when your hands are busy, as with a recipe. Dream
/// reads a step, then listens for "next", "back", "repeat" or "stop". Speaking and listening
/// take turns, so it never hears itself.
@MainActor @Observable
final class HandsFree {
    private(set) var blockID: String?
    private(set) var step = 0
    private(set) var count = 0
    private(set) var isSpeaking = false
    let listener = Listener()

    @ObservationIgnored private let reader = Reader()
    @ObservationIgnored private var steps: () -> [String] = { [] }
    @ObservationIgnored private var lastCommand = ContinuousClock.now
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var hinted = false

    var isActive: Bool { blockID != nil }
    /// The step being read or waited on, for the page to mark.
    var readingID: String? { blockID.map { Narration.stepID($0, step) } }

    init() {
        listener.use = .conversation
        listener.pauseToStop = nil
        reader.use = .conversation
        listener.onTranscript = { [weak self] in self?.heard($0) }
    }

    /// `steps` is asked again before each step, so amounts follow the numbers on the page.
    func start(_ block: Block, steps: @escaping () -> [String]) {
        stop()
        let all = steps()
        guard !all.isEmpty else { return }
        self.steps = steps
        blockID = block.id
        count = all.count
        step = 0
        hinted = false
        lastCommand = .now
        // The screen stays on while you cook.
        UIApplication.shared.isIdleTimerDisabled = true
        speakStep()
        // The first step needn't wait for the microphone; without it, the buttons still step through.
        Task { await listener.start { _ in } }
        timeout = Task { [weak self] in
            // Left alone for a long while, it stops listening.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.isActive else { return }
                if ContinuousClock.now - self.lastCommand > .seconds(15 * 60) { self.stop() }
            }
        }
    }

    func next() {
        lastCommand = .now
        guard step + 1 < count else {
            say("That was the last step.")
            return
        }
        step += 1
        speakStep()
    }

    func back() {
        lastCommand = .now
        step = max(step - 1, 0)
        speakStep()
    }

    func again() {
        lastCommand = .now
        speakStep()
    }

    func stop() {
        guard isActive else { return }
        blockID = nil
        timeout?.cancel()
        reader.stop()
        listener.cancel()
        isSpeaking = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func speakStep() {
        let all = steps()
        guard isActive, all.indices.contains(step) else { return }
        // Said once, since commands can't be seen.
        let hint = !hinted && all.count > 1 ? " Say next when you're ready." : ""
        hinted = true
        say(all[step] + hint)
    }

    private func say(_ text: String) {
        isSpeaking = true
        listener.isMuted = true
        reader.say(text) { [weak self] in
            guard let self, self.isActive else { return }
            self.isSpeaking = false
            self.listener.clearTranscript()
            self.listener.isMuted = false
        }
    }

    private func heard(_ transcript: String) {
        guard isActive, !isSpeaking, ContinuousClock.now - lastCommand > .seconds(1) else { return }
        let words = transcript.lowercased().split { !$0.isLetter }.map(String.init)
        // Commands are short. Anything longer is someone talking, but not to Dream.
        guard words.count <= 5 else {
            listener.clearTranscript()
            return
        }
        guard let command = Command(words) else { return }
        listener.clearTranscript()
        switch command {
        case .next: next()
        case .back: back()
        case .again: again()
        case .stop: stop()
        }
    }

    private enum Command {
        case next, back, again, stop

        init?(_ words: [String]) {
            let said = Set(words)
            if !said.isDisjoint(with: ["stop", "done", "finish", "finished", "exit", "quit", "cancel", "enough"]) {
                self = .stop
            } else if !said.isDisjoint(with: ["back", "previous", "before"]) {
                self = .back
            } else if !said.isDisjoint(with: ["repeat", "again", "pardon"]) {
                self = .again
            } else if !said.isDisjoint(with: ["next", "continue", "forward", "skip", "ready"]) {
                self = .next
            } else {
                return nil
            }
        }
    }
}
