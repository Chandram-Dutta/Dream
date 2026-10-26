import Foundation

// Sounds (ROADMAP.md, workstream 6).

extension Prompts {
    /// How to add a sound the user can play, from a formula or a recording.
    static var soundRules: String {
        """
        Sounds: when hearing something teaches, define it in sounds and play it with a sound block whose ref is the sound's name. Use one for pitch and waves, beats, chords and intervals, the Doppler effect, animal calls, instruments and pronunciation; never as decoration.
        - tones: made from the calculation, so the sound changes while it plays as the user moves a control. Each tone has a frequency in Hz and an amplitude from 0 to 1, each a formula using input and output names, and a waveform: sine, square, triangle or sawtooth. Tie a tone to what the screen teaches, like its frequency to a frequency input, or to the output for the pitch that's heard. A fixed pitch, like middle C, is a plain number, not an input. Two tones a few Hz apart make beats; three or more make a chord. An amplitude around 0.4 is comfortable. A tone can also use a chart's variable: dragging along the chart then plays each point.
        - recording: a real sound from Wikimedia Commons. search is what to look for: an animal's scientific name with call or song (Gavia immer call), an instrument and what it plays (cello C string), or for pronunciation the word and the language's three-letter code (quinoa eng, bonjour fra).
        Put a tone's sound block in the section with the controls that change it, after the chart; put a recording beside what it illustrates.
        """
    }
}

extension Surface {
    /// Sounds in the outline's shorthand, so the model sees them when it changes a screen.
    var soundOutline: [String] {
        guard let sounds, !sounds.isEmpty else { return [] }
        return ["sounds:"] + sounds.map { sound in
            guard !sound.isRecording else {
                let found = sound.recording.map { " (found \"\($0.title)\", \($0.licence)\($0.credit.isEmpty ? "" : ", \($0.credit)"))" } ?? ""
                return "- \(sound.name) \"\(sound.label)\": recording, search \"\(sound.search)\"\(found)"
            }
            let tones = sound.tones.map { "\($0.waveform.rawValue) at \($0.frequency) Hz, amplitude \($0.amplitude)" }
            return "- \(sound.name) \"\(sound.label)\": tones \(tones.joined(separator: "; "))"
        }
    }
}
