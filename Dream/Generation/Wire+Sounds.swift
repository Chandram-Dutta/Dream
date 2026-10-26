import Foundation
import FoundationModels

// What the model writes for sounds (ROADMAP.md, workstream 6). `WireSurface.sounds` holds them.

@Generable
enum WireWaveform { case sine, square, triangle, sawtooth }

@Generable
enum WireSoundKind { case tones, recording }

@Generable
struct WireTone {
    @Guide(description: "In Hz: a formula using input and output names, or a number")
    var frequency: String
    @Guide(description: "From 0 to 1: a formula or a number, like 0.4")
    var amplitude: String
    var waveform: WireWaveform
}

@Generable(description: "Something the user can hear")
struct WireSound {
    @Guide(description: "camelCase name that sound blocks refer to")
    var name: String
    @Guide(description: "What it is, in a few words, like Middle C, Two notes beating or Loon's wail")
    var label: String
    var kind: WireSoundKind
    @Guide(description: "tones: played together. Otherwise empty.", .count(0...4))
    var tones: [WireTone]
    @Guide(description: "recording: what to search Wikimedia Commons for. Otherwise empty.")
    var search: String
}

extension Sound {
    init(_ wire: WireSound) {
        let isRecording = wire.kind == .recording
        self.init(
            name: wire.name,
            label: wire.label,
            tones: isRecording ? [] : wire.tones.map { Tone($0) },
            search: isRecording ? wire.search : "",
            recording: nil)
    }

    /// While the model is still writing. A tone appears once its frequency has.
    init?(partial wire: WireSound.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        let isRecording = wire.kind.map { $0 == .recording } ?? false
        self.init(
            name: name,
            label: wire.label ?? "",
            tones: isRecording ? [] : (wire.tones ?? []).compactMap { Tone(partial: $0) },
            search: isRecording ? wire.search ?? "" : "",
            recording: nil)
    }

    static func list(_ wires: [WireSound]) -> [Sound]? {
        wires.isEmpty ? nil : wires.map { Sound($0) }
    }

    static func list(partial wires: [WireSound.PartiallyGenerated]?) -> [Sound]? {
        let sounds = (wires ?? []).compactMap { Sound(partial: $0) }
        return sounds.isEmpty ? nil : sounds
    }
}

extension Tone {
    init(_ wire: WireTone) {
        self.init(frequency: wire.frequency, amplitude: wire.amplitude, waveform: Waveform(wire.waveform))
    }

    init?(partial wire: WireTone.PartiallyGenerated) {
        guard let frequency = wire.frequency, !frequency.isEmpty else { return nil }
        self.init(frequency: frequency, amplitude: wire.amplitude ?? "", waveform: wire.waveform.map { Waveform($0) } ?? .sine)
    }
}

extension Waveform {
    init(_ wire: WireWaveform) {
        self = Waveform(rawValue: String(describing: wire)) ?? .sine
    }
}
