import AVFoundation

/// The app's audio session, shared by listening and reading aloud. Whoever needs it holds it,
/// and it's handed back to other apps once nobody does.
@MainActor
enum VoiceSession {
    enum Use {
        /// The microphone only, for asking out loud.
        case listening
        /// Reading a page aloud: plays even with the ringer off, like a podcast.
        case reading
        /// Hands-free steps: speaking and listening in turns, out of the speaker.
        case conversation
    }

    private static var holders = 0

    static func acquire(_ use: Use) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .listening:
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        case .reading:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .conversation:
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        }
        try session.setActive(true)
        holders += 1
    }

    static func release() {
        holders = max(holders - 1, 0)
        guard holders == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
