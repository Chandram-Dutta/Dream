import SwiftUI

/// Something to hear: a play button, what it is, and a picture of it. Tones are drawn from the
/// same values they're played from, so the picture and the sound change together as a slider
/// moves. A recording shows how far it's got, and who made it.
struct SoundBlockView: View {
    let block: Block
    let context: RenderContext
    /// Which block is playing, since two blocks can play the same sound.
    @State private var owner = UUID()

    var body: some View {
        if let sound = context.surface.sound(block.ref) {
            let player = SoundPlayer.shared
            let isPlaying = player.playing == owner
            let levels = sound.levels(context.evaluation)
            HStack(alignment: .center, spacing: 16) {
                PlayButton(isPlaying: isPlaying, isLoading: isPlaying && player.isLoading, label: sound.label, palette: context.palette) {
                    if isPlaying {
                        player.stop(owner)
                    } else if let recording = sound.recording {
                        player.play(recording, for: owner)
                    } else {
                        player.play(levels, for: owner)
                    }
                }
                .disabled(sound.isRecording && sound.recording == nil)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(sound.label)
                            .font(.display(.headline))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(sound.isRecording ? Self.time(isPlaying ? player.elapsed : sound.recording?.duration) : Self.hertz(levels))
                            .font(.display(.subheadline))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: levels)
                    }
                    if sound.isRecording {
                        RecordingTrack(recording: sound.recording, progress: isPlaying ? player.elapsed : nil, failed: player.failed == owner, palette: context.palette)
                    } else {
                        WavePicture(levels: levels, window: Self.window(for: sound, in: context.surface), loudest: Self.loudest(sound, in: context.surface),
                                    isPlaying: isPlaying, startedAt: player.startedAt, palette: context.palette)
                    }
                }
            }
            .onChange(of: levels) { player.update(levels, for: owner) }
            .onDisappear { player.stop(owner) }
        }
    }

    /// How much time the picture shows: fixed from the starting values, so a higher pitch packs
    /// in more cycles rather than redrawing the same four. About four cycles of the lowest
    /// tone; for tones close enough to beat, a few beats, or a second if they start in unison,
    /// so detuning shows how many beats there are each second.
    static func window(for sound: Sound, in surface: Surface) -> Double {
        let frequencies = sound.levels(surface.evaluate(surface.initialValues)).map(\.frequency).sorted()
        guard let lowest = frequencies.first else { return 0.01 }
        let nice = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2]
        // Two tones are heard as beating when they're within about 20 Hz; further apart, as roughness.
        let beat = zip(frequencies, frequencies.dropFirst()).map { $1 - $0 }.filter { $0 < min(lowest * 0.1, 20) }.min()
        let wanted: Double
        switch beat {
        case .some(0): return 1
        case .some(let beat): wanted = 3 / beat
        case nil: wanted = 4 / lowest
        }
        return nice.min { abs(log($0 / wanted)) < abs(log($1 / wanted)) } ?? 0.01
    }

    /// The loudest the tones get as any one input moves across its range. That fills the
    /// picture's height, so turning a sound down visibly shrinks it.
    static func loudest(_ sound: Sound, in surface: Surface) -> Double {
        let start = surface.initialValues
        var trials = [start]
        for input in surface.inputs where input.role != .given {
            for end in [input.safeRange.lowerBound, input.safeRange.upperBound] {
                var values = start
                values[input.name] = end
                trials.append(values)
            }
        }
        let totals = trials.map { sound.levels(surface.evaluate($0)).reduce(0) { $0 + $1.amplitude } }
        return max(totals.max() ?? 1, 0.05)
    }

    private static func hertz(_ levels: [ToneLevel]) -> String {
        let heard = levels.filter { $0.amplitude > 0 }
        guard !heard.isEmpty else { return "Silent" }
        guard heard.count <= 3 else { return "\(heard.count) tones" }
        return heard.map { $0.frequency.formatted(.number.precision(.fractionLength($0.frequency < 100 ? 0...1 : 0...0))) }.joined(separator: " · ") + " Hz"
    }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let isLoading: Bool
    let label: String
    let palette: Palette
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isEnabled ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.accent.opacity(0.14)))
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Stop \(label)" : "Play \(label)")
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
    }
}

/// A picture of the tones, from the same levels the synthesizer plays. It moves while it
/// plays, a window's width each second.
private struct WavePicture: View {
    let levels: [ToneLevel]
    let window: Double
    /// The amplitude that fills the height.
    let loudest: Double
    let isPlaying: Bool
    let startedAt: Date
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = isPlaying && !reduceMotion
        TimelineView(.animation(paused: !moving)) { timeline in
            let start = moving ? timeline.date.timeIntervalSince(startedAt) * window : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [palette.accent, palette.companion]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                canvas.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.25, width: size.width, height: 0.5)), with: .color(palette.edge))
                let wave = WaveShape(levels: levels, window: window, loudest: loudest, start: start)
                if wave.isBand(width: size.width) {
                    canvas.fill(wave.path(in: CGRect(origin: .zero, size: size)), with: shading)
                } else {
                    canvas.stroke(wave.path(in: CGRect(origin: .zero, size: size)), with: shading, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 64)
        .opacity(isPlaying ? 1 : 0.5)
        .animation(.smooth, value: isPlaying)
        .overlay(alignment: .bottomTrailing) {
            Text(window < 1 ? "\(Int((window * 1000).rounded())) ms" : "\(Int(window)) s")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .offset(y: 4)
        }
        .accessibilityHidden(true)
    }
}

/// How far into the recording, and its credit, which its licence asks to be shown.
private struct RecordingTrack: View {
    let recording: Recording?
    /// Seconds in, while it's playing.
    let progress: Double?
    let failed: Bool
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let fraction = progress.flatMap { elapsed in recording?.duration.map { min(max(elapsed / $0, 0), 1) } } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.accent.opacity(0.14))
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: max(6, geometry.size.width * fraction))
                        .opacity(progress == nil ? 0 : 1)
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.05), value: progress)
            if failed {
                Text("This recording couldn't be played.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let recording, let page = URL(string: recording.pageURL) {
                let byline = [recording.credit, recording.licence].filter { !$0.isEmpty }.joined(separator: " · ")
                Link(destination: page) {
                    Text("\(byline.isEmpty ? "" : byline + " · ")\(Text("Wikimedia Commons").foregroundStyle(palette.accent))")
                        .multilineTextAlignment(.leading)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Capsule().fill(palette.wash).frame(width: 180, height: 10).shimmering()
            }
        }
    }
}
