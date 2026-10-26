import AVFoundation
import Observation
import UIKit

/// Plays one sound at a time, for the block that asked last: tones through `ToneSynth`, or a
/// recording streamed with AVPlayer.
///
/// Nothing plays until someone taps. The audio session is set to playback, which plays even with
/// the ringer silenced, only while something's playing, and handed back afterwards. Leaving the
/// app, a call, or unplugging headphones stops it.
@MainActor @Observable
final class SoundPlayer {
    static let shared = SoundPlayer()

    /// The block that's playing, if any.
    private(set) var playing: UUID?
    /// When it started, so a picture of the sound can move in step with it.
    private(set) var startedAt = Date.now
    /// A recording waiting for enough of itself to arrive.
    private(set) var isLoading = false
    /// How far into the recording, in seconds.
    private(set) var elapsed: Double = 0
    /// The block whose recording couldn't be played, until it's tried again.
    private(set) var failed: UUID?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var synth: ToneSynth?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var statusObservations: [NSKeyValueObservation] = []

    private init() {
        let center = NotificationCenter.default
        let stopAll: @Sendable (Notification) -> Void = { _ in Task { @MainActor in SoundPlayer.shared.stop() } }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main, using: stopAll)
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: stopAll)
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main, using: stopAll)
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { notification in
            // Headphones coming out shouldn't move the sound to the speaker.
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in SoundPlayer.shared.stop() }
        }
    }

    // MARK: - Tones

    func play(_ levels: [ToneLevel], for owner: UUID) {
        stop()
        guard activate() else { return }
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let synth = ToneSynth(sampleRate: rate > 0 ? rate : 48_000)
        synth.prime(levels)
        engine.attach(synth.node)
        do {
            try engine.connectNode(synth.node, to: engine.mainMixerNode, format: synth.format)
            try engine.start()
        } catch {
            deactivate()
            return
        }
        synth.gate(true)
        self.engine = engine
        self.synth = synth
        begin(owner)
    }

    /// New values for the tones that are playing, as a slider moves.
    func update(_ levels: [ToneLevel], for owner: UUID) {
        guard playing == owner else { return }
        synth?.set(levels)
    }

    // MARK: - Recordings

    func play(_ recording: Recording, for owner: UUID) {
        stop()
        guard let url = URL(string: recording.audioURL), activate() else {
            failed = owner
            return
        }
        // Wikimedia asks apps to say who they are.
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: "Dream/0.1 (iOS prototype)"])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        statusObservations = [
            item.observe(\.status) { item, _ in
                let failed = item.status == .failed
                Task { @MainActor in
                    guard failed, SoundPlayer.shared.playing == owner else { return }
                    SoundPlayer.shared.stop()
                    SoundPlayer.shared.failed = owner
                }
            },
            player.observe(\.timeControlStatus) { player, _ in
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                Task { @MainActor in
                    guard SoundPlayer.shared.playing == owner else { return }
                    SoundPlayer.shared.isLoading = waiting
                }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            let seconds = time.seconds
            Task { @MainActor in
                guard SoundPlayer.shared.playing == owner, seconds.isFinite else { return }
                SoundPlayer.shared.elapsed = seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            Task { @MainActor in SoundPlayer.shared.stop(owner) }
        }
        self.player = player
        begin(owner)
        isLoading = true
        player.play()
    }

    // MARK: - Stopping

    /// Stops `owner`'s sound, or whatever is playing.
    func stop(_ owner: UUID? = nil) {
        guard playing != nil, owner == nil || owner == playing else { return }
        playing = nil
        isLoading = false
        elapsed = 0
        if let player {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            (timeObserver, endObserver) = (nil, nil)
            statusObservations = []
            self.player = nil
            deactivate()
        }
        if let engine, let synth {
            // Fade out first, so it never ends on a click.
            synth.gate(false)
            self.engine = nil
            self.synth = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                engine.stop()
                self.deactivate()
            }
        }
    }

    private func begin(_ owner: UUID) {
        playing = owner
        failed = nil
        elapsed = 0
        startedAt = .now
    }

    // MARK: - Audio session

    private func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    /// Back to the system's default once nothing's playing, so other audio can carry on.
    private func deactivate() {
        guard playing == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient)
    }
}
