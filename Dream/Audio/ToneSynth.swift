import AVFoundation
import Synchronization

/// Makes a sound's tones on the audio thread.
///
/// The main thread works out the formulas and only sets targets. The render callback reads them
/// through atomics once per buffer, then glides toward them a little every sample, so a slider
/// moving never clicks or steps. Nothing on the audio thread allocates, takes a lock or
/// evaluates a formula.
final class ToneSynth {
    let node: AVAudioSourceNode
    let format: AVAudioFormat
    private let targets: Targets
    private let voices: Voices

    init(sampleRate: Double) {
        let targets = Targets()
        let voices = Voices(sampleRate: sampleRate)
        self.targets = targets
        self.voices = voices
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, buffers in
            voices.render(frameCount, into: buffers, isSilence: isSilence, targets: targets)
            return noErr
        }
    }

    /// Where the tones start, before the engine runs: at their pitch at once, rather than
    /// sliding up from nothing.
    func prime(_ levels: [ToneLevel]) {
        set(levels)
        voices.start(at: levels)
    }

    func set(_ levels: [ToneLevel]) {
        for index in 0..<ToneLevel.voices {
            let level = index < levels.count ? levels[index] : nil
            targets.frequency[index].store((level?.frequency ?? 440).bitPattern, ordering: .relaxed)
            targets.amplitude[index].store((level?.amplitude ?? 0).bitPattern, ordering: .relaxed)
            targets.waveform[index].store(level.flatMap { Waveform.allCases.firstIndex(of: $0.waveform) } ?? 0, ordering: .relaxed)
        }
    }

    /// Fades in, or out. Faded out, the engine can stop without a click.
    func gate(_ open: Bool) {
        targets.gate.store(open, ordering: .relaxed)
    }
}

/// What the main thread asks for, one slot per voice (`ToneLevel.voices`). Doubles travel as
/// their bit patterns, and a waveform as its position in `Waveform.allCases`.
private final class Targets: Sendable {
    let frequency = InlineArray<4, Atomic<UInt64>> { _ in Atomic(440.0.bitPattern) }
    let amplitude = InlineArray<4, Atomic<UInt64>> { _ in Atomic(0) }
    let waveform = InlineArray<4, Atomic<Int>> { _ in Atomic(0) }
    let gate = Atomic(false)
}

/// The audio thread's own state. Only the render callback touches it once the engine runs,
/// and only `start` before then, so it needs no lock.
private final class Voices: @unchecked Sendable {
    private struct Voice {
        var phase = 0.0
        var frequency = 440.0
        var amplitude = 0.0
    }

    private let state: UnsafeMutablePointer<(voices: InlineArray<4, Voice>, gain: Double)>
    private let sampleRate: Double
    /// Per-sample steps toward a target: about 25 ms for pitch and loudness, 12 ms to fade.
    private let glide: Double
    private let fade: Double
    /// Pure tones are piercing at full scale.
    private let level = 0.35

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        glide = 1 - exp(-1 / (0.025 * sampleRate))
        fade = 1 - exp(-1 / (0.012 * sampleRate))
        state = .allocate(capacity: 1)
        state.initialize(to: (InlineArray(repeating: Voice()), 0))
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func start(at levels: [ToneLevel]) {
        for index in 0..<min(levels.count, ToneLevel.voices) {
            state.pointee.voices[index] = Voice(phase: 0, frequency: levels[index].frequency, amplitude: levels[index].amplitude)
        }
        state.pointee.gain = 0
    }

    func render(_ frameCount: AVAudioFrameCount, into list: UnsafeMutablePointer<AudioBufferList>, isSilence: UnsafeMutablePointer<ObjCBool>, targets: Targets) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first, let data = first.mData else { return }
        let out = data.assumingMemoryBound(to: Float.self)
        let frames = Int(frameCount)
        for frame in 0..<frames { out[frame] = 0 }

        let gate = targets.gate.load(ordering: .relaxed) ? 1.0 : 0.0
        if gate == 0, state.pointee.gain < 1e-5 {
            isSilence.pointee = true
            return
        }
        for index in 0..<ToneLevel.voices {
            let frequency = Double(bitPattern: targets.frequency[index].load(ordering: .relaxed))
            let amplitude = Double(bitPattern: targets.amplitude[index].load(ordering: .relaxed))
            let shape = targets.waveform[index].load(ordering: .relaxed)
            var voice = state.pointee.voices[index]
            if amplitude == 0, voice.amplitude < 1e-5 { continue }
            let loudness = Self.loudness(shape)
            for frame in 0..<frames {
                voice.frequency += (frequency - voice.frequency) * glide
                voice.amplitude += (amplitude - voice.amplitude) * glide
                let step = voice.frequency / sampleRate
                voice.phase += step
                if voice.phase >= 1 { voice.phase -= 1 }
                out[frame] += Float(voice.amplitude * loudness * Self.sample(shape, voice.phase, step))
            }
            state.pointee.voices[index] = voice
        }
        var gain = state.pointee.gain
        for frame in 0..<frames {
            gain += (gate - gain) * fade
            out[frame] *= Float(gain * level)
        }
        state.pointee.gain = gain
        // Every channel the same.
        for buffer in buffers.dropFirst() {
            guard let other = buffer.mData else { continue }
            other.copyMemory(from: data, byteCount: Int(min(buffer.mDataByteSize, first.mDataByteSize)))
        }
    }

    /// `Waveform.value(at:)`, by position in `Waveform.allCases`, with the jumps in square and sawtooth smoothed (PolyBLEP) so high
    /// notes don't alias into notes that aren't there.
    private static func sample(_ shape: Int, _ phase: Double, _ step: Double) -> Double {
        switch shape {
        case 1:
            return (phase < 0.5 ? 1 : -1) + blep(phase, step) - blep(wrapped(phase + 0.5), step)
        case 2:
            return phase < 0.25 ? 4 * phase : phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4
        case 3:
            let shifted = wrapped(phase + 0.5)
            return 2 * shifted - 1 - blep(shifted, step)
        default:
            return sin(2 * .pi * phase)
        }
    }

    /// Square and sawtooth sound far louder than a sine at the same amplitude.
    private static func loudness(_ shape: Int) -> Double {
        switch shape {
        case 1: 0.55
        case 3: 0.7
        default: 1
        }
    }

    private static func wrapped(_ phase: Double) -> Double {
        phase >= 1 ? phase - 1 : phase
    }

    private static func blep(_ phase: Double, _ step: Double) -> Double {
        guard step > 0 else { return 0 }
        if phase < step {
            let t = phase / step
            return t + t - t * t - 1
        }
        if phase > 1 - step {
            let t = (phase - 1) / step
            return t * t + t + t + 1
        }
        return 0
    }
}
