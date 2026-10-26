import Foundation

// Sounds (ROADMAP.md, workstream 6).

/// Something the reader can hear, defined once at the top level of a surface and played by
/// `sound` blocks that name it. Tones are made from the calculation, so moving a slider changes
/// what you hear while it plays. A recording is a real sound, found on Wikimedia Commons.
struct Sound: Codable, Hashable {
    var name: String
    var label: String
    /// Played together: one for a pure tone, two a few hertz apart for beats, three or more for
    /// a chord. Empty for a recording.
    var tones: [Tone]
    /// What to search Wikimedia Commons for, like "Gavia immer call". Empty for tones.
    var search: String
    /// The file found for `search`, with its credit. Nil until it's been looked up, and for tones.
    var recording: Recording?

    var isRecording: Bool { tones.isEmpty }
}

struct Tone: Codable, Hashable {
    /// In hertz. Formulas over the surface's inputs and outputs, or plain numbers.
    var frequency: String
    /// From 0 to 1.
    var amplitude: String
    var waveform: Waveform
}

enum Waveform: String, Codable, CaseIterable {
    case sine, square, triangle, sawtooth

    /// One cycle, with `phase` from 0 to 1, starting at zero and rising like a sine, so every
    /// shape lines up with the others. The drawing and the synthesizer both use it.
    func value(at phase: Double) -> Double {
        switch self {
        case .sine: return sin(2 * .pi * phase)
        case .square: return phase < 0.5 ? 1 : -1
        case .triangle: return phase < 0.25 ? 4 * phase : phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4
        case .sawtooth: return phase < 0.5 ? 2 * phase : 2 * phase - 2
        }
    }
}

/// A recording from Wikimedia Commons, and what its licence asks to be shown with it.
struct Recording: Codable, Hashable {
    /// The file's own name for it, like "Common loon yodels".
    var title: String
    /// A version iOS can stream: the original if it's MP3 or WAV, otherwise Commons' MP3 copy.
    var audioURL: String
    /// The file's page on Commons, with its full description and licence.
    var pageURL: String
    /// Who made it, as plain text. Empty if the file doesn't say.
    var credit: String
    /// Like "CC BY-SA 4.0" or "Public domain".
    var licence: String
    /// Seconds, if Commons knows.
    var duration: Double?
}

/// One tone as it sounds right now: its formulas worked out with the surface's live values.
struct ToneLevel: Hashable {
    var frequency: Double
    var amplitude: Double
    var waveform: Waveform

    /// What people hear. Anything outside it is clamped, and a tone that isn't a number is silent.
    static let audible: ClosedRange<Double> = 20...20_000
    /// How many tones a sound can play at once: enough for beats and most chords.
    static let voices = 4
}

extension Surface {
    func sound(_ name: String) -> Sound? { sounds?.first { $0.name == name } }
}

extension Sound {
    /// Each tone at these values. Loudness is shared out so the tones together never clip.
    func levels(_ evaluation: Evaluation) -> [ToneLevel] {
        let raw = tones.map { tone -> ToneLevel in
            let frequency = Self.value(of: tone.frequency, in: evaluation)
            let amplitude = Self.value(of: tone.amplitude, in: evaluation)
            guard let frequency, let amplitude, frequency > 0 else { return ToneLevel(frequency: 440, amplitude: 0, waveform: tone.waveform) }
            return ToneLevel(
                frequency: min(max(frequency, ToneLevel.audible.lowerBound), ToneLevel.audible.upperBound),
                amplitude: min(max(amplitude, 0), 1),
                waveform: tone.waveform)
        }
        let total = raw.reduce(0) { $0 + $1.amplitude }
        guard total > 1 else { return raw }
        return raw.map { ToneLevel(frequency: $0.frequency, amplitude: $0.amplitude / total, waveform: $0.waveform) }
    }

    /// A formula worked out with the surface's values. Nil if it can't be, or isn't a number.
    static func value(of formula: String, in evaluation: Evaluation) -> Double? {
        guard let expr = try? FormulaCache.parse(formula),
              let value = try? expr.evaluate({ name in
                  if let known = evaluation.values[name] { return known }
                  if let constant = Expr.constants[name] { return constant }
                  throw FormulaError("'\(name)' isn't an input or output")
              }),
              value.isFinite
        else { return nil }
        return value
    }
}
