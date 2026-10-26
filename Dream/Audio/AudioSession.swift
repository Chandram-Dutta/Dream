import AVFoundation

/// The app's one audio session, shared by everything that plays or listens: sounds on a page,
/// reading aloud, and the microphone. Each holds it for a use, and the category always suits
/// every use at once, so stopping one never cuts off another. It's handed back to other apps
/// once nobody holds it.
@MainActor
enum AudioSession {
    enum Use: Hashable {
        /// The microphone only, for asking out loud.
        case listening
        /// Reading a page aloud: plays even with the ringer off, like a podcast.
        case reading
        /// Hands-free steps: speaking and listening in turns, out of the speaker.
        case conversation
        /// A tone or a recording on a page, played when tapped, even with the ringer off.
        case sound
    }

    private static var holders: [Use: Int] = [:]

    static func acquire(_ use: Use) throws {
        holders[use, default: 0] += 1
        do {
            try apply()
        } catch {
            release(use)
            throw error
        }
    }

    static func release(_ use: Use) {
        guard let count = holders[use] else { return }
        holders[use] = count > 1 ? count - 1 : nil
        if holders.isEmpty {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            try? apply()
        }
    }

    /// One category for everything that's going on.
    private static func apply() throws {
        let session = AVAudioSession.sharedInstance()
        let uses = Set(holders.keys)
        let listens = uses.contains(.listening) || uses.contains(.conversation)
        let plays = uses.contains(.reading) || uses.contains(.sound) || uses.contains(.conversation)
        if listens && plays {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        } else if listens {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        } else if uses.contains(.reading) {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        } else {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }
}
