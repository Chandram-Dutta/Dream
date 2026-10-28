import SwiftUI
import UIKit

/// Ask out loud. Tap and talk: the field fills as you speak, and a pause, or another tap, sends
/// it as if typed. Tapping into the field instead keeps the words for editing.
struct MicButton: View {
    let listener: Listener
    @Binding var text: String
    let palette: Palette
    var onStart: (() -> Void)?
    let onFinish: (String) -> Void

    @State private var problem: Listener.Problem?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: tap) {
            ZStack {
                // A halo that swells with your voice.
                Circle()
                    .fill(palette.accent)
                    .opacity(isListening ? 0.3 : 0)
                    .scaleEffect(isListening && !reduceMotion ? 1.1 + 0.4 * listener.level : 1)
                Circle()
                    .fill(palette.accent)
                    .opacity(isUnavailable ? 0.4 : 1)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(progress, 0.02))
                        .stroke(palette.onAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                }
                Image(systemName: symbol)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(palette.onAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: isPreparing)
            }
            .frame(width: 38, height: 38)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.15), value: listener.level)
        .animation(.smooth, value: listener.phase)
        .accessibilityLabel(accessibilityLabel)
        .sensoryFeedback(.impact(weight: .light), trigger: listener.isActive)
        .onChange(of: listener.transcript) { _, heard in
            if listener.isActive || !heard.isEmpty { text = heard }
        }
        .onChange(of: listener.phase) { _, phase in
            if case .unavailable(let reason) = phase { problem = reason }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, listener.isActive { listener.cancel() }
        }
        .onDisappear {
            if listener.isActive { listener.cancel() }
        }
        .alert(problem.map(Self.title) ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }), presenting: problem) { problem in
            if problem == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(Self.message(problem))
        }
    }

    private var isListening: Bool { listener.phase == .listening }

    private var isPreparing: Bool {
        if case .preparing = listener.phase { return true }
        return false
    }

    private var isUnavailable: Bool {
        if case .unavailable = listener.phase { return true }
        return false
    }

    /// How far the speech model has downloaded, the first time.
    private var progress: Double? {
        if case .preparing(let progress?) = listener.phase { return progress }
        return nil
    }

    /// Listening, a tap sends what you've said, so it shows as sending.
    private var symbol: String {
        switch listener.phase {
        case .listening: "arrow.up"
        case .unavailable: "mic.slash.fill"
        case .idle, .preparing: "mic.fill"
        }
    }

    private var accessibilityLabel: String {
        switch listener.phase {
        case .listening: "Send what you said"
        case .preparing: "Getting ready to listen"
        case .idle, .unavailable: "Speak"
        }
    }

    private func tap() {
        switch listener.phase {
        case .listening:
            listener.finish()
        case .preparing:
            listener.cancel()
        case .idle, .unavailable:
            onStart?()
            Task {
                await listener.start { heard in
                    // The field has the last words before they're sent.
                    text = heard
                    onFinish(heard)
                }
            }
        }
    }

    private static func title(_ problem: Listener.Problem) -> String {
        switch problem {
        case .denied: "Microphone is off for Dream"
        case .unsupported: "Can't listen in this language"
        case .failed: "Couldn't start listening"
        }
    }

    private static func message(_ problem: Listener.Problem) -> String {
        switch problem {
        case .denied: "To ask out loud, turn on Microphone for Dream in Settings."
        case .unsupported: "This iPhone can't turn speech in your language into text yet."
        case .failed: "Something got in the way of the microphone. Try again in a moment."
        }
    }
}

extension View {
    /// The glass input, alive while it listens: a glow in the surface's colours that swells
    /// with your voice.
    func listeningGlow(_ listener: Listener, palette: Palette, in shape: some Shape) -> some View {
        modifier(ListeningGlow(listener: listener, palette: palette, shape: AnyShape(shape)))
    }

    /// What's being read aloud: a soft wash behind it, gentler than the outline a change gets.
    func readingMark(_ isReading: Bool, palette: Palette) -> some View {
        background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(palette.edge, lineWidth: 0.5))
                .padding(-8)
                .opacity(isReading ? 1 : 0)
                .animation(.smooth(duration: 0.4), value: isReading)
                .allowsHitTesting(false)
        }
    }

    /// Keeps what's being read on screen, unless the reader is scrolling themselves.
    func followsReading(_ voice: PageVoice, surface: Surface?, scroll: Binding<ScrollPosition>) -> some View {
        onChange(of: voice.readingID) { _, id in
            guard let id, let surface, voice.follows else { return }
            withAnimation(.smooth(duration: 0.7)) {
                if id == Narration.headerID {
                    scroll.wrappedValue.scrollTo(edge: .top)
                } else if let block = surface.topLevelID(containing: id) {
                    scroll.wrappedValue.scrollTo(id: block, anchor: UnitPoint(x: 0.5, y: 0.2))
                }
            }
        }
    }
}

private struct ListeningGlow: ViewModifier {
    let listener: Listener
    let palette: Palette
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Not while Dream itself is talking: it isn't listening then.
        let active = listener.phase == .listening && !listener.isMuted
        let level = active ? listener.level : 0
        content
            .background {
                shape
                    .fill(palette.accent)
                    .blur(radius: 10 + 14 * level)
                    .opacity(active ? 0.2 + 0.5 * level : 0)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.05 * level)
                    .allowsHitTesting(false)
            }
            .scaleEffect(active && !reduceMotion ? 1 + 0.012 * level : 1)
            .animation(.smooth(duration: 0.18), value: level)
            .animation(.smooth(duration: 0.4), value: active)
    }
}

/// The page's speaker button. With steps on the page, it also offers them hands-free; while
/// reading, it stops.
struct ReadAloudButton: View {
    let voice: PageVoice
    let surface: Surface?
    let state: SurfaceState

    var body: some View {
        if voice.isReading {
            Button("Stop reading", systemImage: "speaker.wave.2.fill") { voice.stop() }
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: voice.reader.phase == .speaking || voice.handsFree.isSpeaking)
        } else if let surface, let steps = surface.stepsBlock {
            Menu("Read aloud", systemImage: "speaker.wave.2") {
                Button("Read this page", systemImage: "text.alignleft") { voice.readPage(surface, state: state) }
                Button("Read the steps hands-free", systemImage: "hand.raised") { voice.readSteps(steps, of: surface, state: state) }
            }
        } else {
            Button("Read this page", systemImage: "speaker.wave.2") {
                if let surface { voice.readPage(surface, state: state) }
            }
        }
    }
}

/// Along the bottom while Dream reads: how far it's got, pause and stop. Hands-free, which step
/// it's on, back and next, and a mark that moves with your voice while it listens.
struct VoiceBar: View {
    let voice: PageVoice
    let palette: Palette

    var body: some View {
        Group {
            if voice.handsFree.isActive {
                stepsBar
            } else if voice.reader.phase != .idle {
                readingBar
            }
        }
        .animation(.smooth, value: voice.isReading)
    }

    private var readingBar: some View {
        let reader = voice.reader
        let paused = reader.phase == .paused
        return HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.headline)
                .foregroundStyle(palette.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !paused)
                .accessibilityHidden(true)
            Capsule()
                .fill(palette.edge)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(palette.accent)
                        .scaleEffect(x: reader.count > 0 ? Double(reader.position + 1) / Double(reader.count) : 0, anchor: .leading)
                }
                .frame(height: 4)
                .animation(.smooth(duration: 0.6), value: reader.position)
                .accessibilityElement()
                .accessibilityLabel("Reading")
                .accessibilityValue("\(reader.position + 1) of \(reader.count)")
            Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                paused ? reader.resume() : reader.pause()
            }
            .contentTransition(.symbolEffect(.replace))
            Button("Stop reading", systemImage: "xmark") { voice.stop() }
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 50)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var stepsBar: some View {
        let handsFree = voice.handsFree
        let listening = handsFree.listener.phase == .listening && !handsFree.isSpeaking
        return HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.backward") { handsFree.back() }
                .disabled(handsFree.step == 0)
            VStack(spacing: 5) {
                StepDots(step: handsFree.step, count: handsFree.count, level: listening ? handsFree.listener.level : 0, listening: listening, palette: palette)
                // Voice commands can't be seen, so this is the one place they're named.
                if listening {
                    Text("Say next, back, repeat or stop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: listening)
            Button("Next", systemImage: "chevron.forward") { handsFree.next() }
            Button("Stop", systemImage: "xmark") { voice.stop() }
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(height: 56)
        .glassEffect(.regular.interactive(), in: .capsule)
        .listeningGlow(handsFree.listener, palette: palette, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Which step, as a row of marks; the current one is long. While it listens, the current mark
/// breathes with your voice.
private struct StepDots: View {
    let step: Int
    let count: Int
    let level: Double
    let listening: Bool
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if count <= 12 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? AnyShapeStyle(palette.accent) : AnyShapeStyle(index < step ? palette.accent.opacity(0.45) : palette.edge))
                            .frame(width: index == step ? 22 : 6, height: 6)
                            .scaleEffect(index == step && listening && !reduceMotion ? 1 + 0.5 * level : 1)
                    }
                }
            } else {
                Text("\(step + 1) / \(count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
                    .contentTransition(.numericText(value: Double(step)))
            }
        }
        .animation(.smooth(duration: 0.18), value: level)
        .animation(.smooth, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(count)")
        .accessibilityHint(listening ? "Listening for next, back, repeat or stop." : "")
    }
}
