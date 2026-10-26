import Foundation

// Checking sounds (ROADMAP.md, workstream 6). Like blocks, sounds are always fixed locally:
// a tone that can't be worked out is dropped rather than sent back to the model.

extension Checker {
    /// Names, formulas and recordings. Runs before the blocks are checked, so a block can only
    /// keep a sound that survived.
    static func checkSounds(_ surface: inout Surface) -> [Issue] {
        guard let original = surface.sounds else { return [] }
        var issues: [Issue] = []
        func fixed(_ message: String) { issues.append(Issue(kind: .fixed, message: message)) }
        func warning(_ message: String) { issues.append(Issue(kind: .warning, message: message)) }

        let values = Set(surface.inputs.map(\.name) + surface.outputs.map(\.name))
        let start = surface.evaluate(surface.initialValues)
        var names: Set<String> = []

        /// A formula the tone can use: near-miss names renamed. Nil if it can't be worked out.
        func formula(_ raw: String, in sound: String) -> String? {
            guard let expr = try? Expr.parse(raw), expr.functionNames.isSubset(of: Expr.functions) else { return nil }
            var renames: [String: String] = [:]
            for name in expr.names.subtracting(values).subtracting(Expr.constants.keys) {
                guard let match = closestName(to: name, in: values) else { return nil }
                renames[name] = match
            }
            guard !renames.isEmpty else { return raw }
            fixed("In the sound '\(sound)', read \(renames.sorted { $0.key < $1.key }.map { "'\($0.key)' as '\($0.value)'" }.joined(separator: ", ")).")
            return expr.renamed(renames).description
        }

        let sounds = original.compactMap { candidate -> Sound? in
            var sound = candidate
            sound.name = identifier(sound.name.isEmpty ? sound.label : sound.name)
            guard !sound.name.isEmpty else { fixed("Dropped a sound with no name."); return nil }
            // Blocks name sounds the way they name inputs, so the two mustn't be confused.
            if values.contains(sound.name) { sound.name += "Sound" }
            guard names.insert(sound.name).inserted else { fixed("Dropped a second sound named '\(sound.name)'."); return nil }
            sound.label = sound.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if sound.label.isEmpty { sound.label = words(sound.name) }

            if !sound.tones.isEmpty {
                sound.search = ""
                sound.recording = nil
                sound.tones = sound.tones.prefix(ToneLevel.voices).compactMap { tone in
                    guard let frequency = formula(tone.frequency, in: sound.name) else {
                        fixed("Dropped a tone of '\(sound.name)' whose frequency can't be worked out: \(tone.frequency)")
                        return nil
                    }
                    let amplitude = tone.amplitude.trimmingCharacters(in: .whitespaces).isEmpty ? nil : formula(tone.amplitude, in: sound.name)
                    if amplitude == nil { fixed("Gave a tone of '\(sound.name)' a moderate loudness.") }
                    return Tone(frequency: frequency, amplitude: amplitude ?? "0.4", waveform: tone.waveform)
                }
                guard !sound.tones.isEmpty else { fixed("Dropped the sound '\(sound.name)', which has no tone left."); return nil }
                for level in sound.tones.map({ Sound.value(of: $0.frequency, in: start) }) {
                    if let level, !ToneLevel.audible.contains(level) {
                        warning("'\(sound.name)' starts at \(level.plain) Hz, which people can't hear.")
                    }
                }
            } else {
                sound.search = sound.search.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sound.recording != nil else {
                    fixed(sound.search.isEmpty ? "Dropped the sound '\(sound.name)', which has neither tones nor a recording." : "Dropped the sound '\(sound.name)': no recording was found for \"\(sound.search)\".")
                    return nil
                }
            }
            return sound
        }
        surface.sounds = sounds.isEmpty ? nil : sounds
        return issues
    }

    /// A sound block plays one sound: a near-miss name is read as the sound it means, and with
    /// only one sound, a block naming none plays that. It's headed by the sound's own label;
    /// models tend to caption it with an instruction, like "Play the triad", that the play
    /// button already gives.
    static func soundBlock(_ original: Block, in surface: Surface, fixed: (String) -> Void) -> Block? {
        var block = original
        (block.title, block.over, block.text, block.items, block.children) = ("", "", "", [], [])
        let names = Set((surface.sounds ?? []).map(\.name))
        if names.contains(block.ref) { return block }
        if let match = closestName(to: block.ref, in: names) ?? (names.count == 1 && block.ref.isEmpty ? names.first : nil) {
            block.ref = match
            return block
        }
        fixed("Removed a sound block for '\(block.ref)', which isn't a sound.")
        return nil
    }

    /// Every sound is heard once. One that no block plays gets a block of its own; a tone shaped
    /// by controls in a single section joins them there. In a section, a sound comes after any
    /// chart and before the controls: see it, hear it, then change it while it plays.
    static func placeSounds(_ surface: inout Surface) -> [Issue] {
        guard let sounds = surface.sounds else { return [] }
        var issues: [Issue] = []
        var placed: Set<String> = []

        func deduplicated(_ blocks: [Block]) -> [Block] {
            blocks.compactMap { original in
                var block = original
                if block.kind == .sound {
                    guard placed.insert(block.ref).inserted else {
                        issues.append(Issue(kind: .fixed, message: "Removed a second block playing '\(block.ref)'."))
                        return nil
                    }
                    return block
                }
                block.children = deduplicated(block.children)
                // A row is for results side by side; a player needs the width.
                if block.kind == .row, block.children.contains(where: { $0.kind == .sound }) { block.kind = .section }
                if block.kind.isContainer, block.children.isEmpty { return nil }
                return block
            }
        }
        surface.blocks = deduplicated(surface.blocks)

        var ids = Set(allIDs(surface.blocks))
        for sound in sounds where !placed.contains(sound.name) {
            var id = "\(sound.name)-sound"
            while !ids.insert(id).inserted { id += "-2" }
            surface.blocks.append(Block(id: id, kind: .sound, ref: sound.name))
            issues.append(Issue(kind: .fixed, message: "Added a block to play '\(sound.name)'."))
        }

        func controls(in block: Block) -> Set<String> {
            block.kind.isControl ? [block.ref] : block.children.reduce(into: []) { $0.formUnion(controls(in: $1)) }
        }
        let adjustable = Set(surface.adjustableInputs.map(\.name))
        for index in surface.blocks.indices.reversed() where surface.blocks[index].kind == .sound {
            let block = surface.blocks[index]
            guard let sound = surface.sound(block.ref), !sound.isRecording else { continue }
            let shaping = sound.tones.reduce(into: Set<String>()) { inputs, tone in
                for formula in [tone.frequency, tone.amplitude] {
                    for name in (try? FormulaCache.parse(formula))?.names ?? [] {
                        inputs.formUnion(surface.inputs(feeding: name))
                    }
                }
            }.intersection(adjustable)
            guard !shaping.isEmpty else { continue }
            let holders = surface.blocks.indices.filter { $0 != index && !controls(in: surface.blocks[$0]).isDisjoint(with: shaping) }
            guard holders.count == 1, surface.blocks[holders[0]].kind == .section else { continue }
            surface.blocks.remove(at: index)
            let home = holders[0] > index ? holders[0] - 1 : holders[0]
            let children = surface.blocks[home].children
            let position = children.firstIndex { $0.kind.isControl } ?? children.endIndex
            surface.blocks[home].children.insert(block, at: position)
            issues.append(Issue(kind: .fixed, message: "Put the sound '\(sound.name)' with the controls that change it."))
        }
        for index in surface.blocks.indices where surface.blocks[index].kind == .section {
            var children = surface.blocks[index].children
            guard let firstControl = children.firstIndex(where: { $0.kind.isControl }) else { continue }
            let late = children.indices.filter { $0 > firstControl && children[$0].kind == .sound }
            guard !late.isEmpty else { continue }
            let moved = late.map { children[$0] }
            for position in late.reversed() { children.remove(at: position) }
            children.insert(contentsOf: moved, at: firstControl)
            surface.blocks[index].children = children
        }
        return issues
    }

    private static func allIDs(_ blocks: [Block]) -> [String] {
        blocks.flatMap { [$0.id] + allIDs($0.children) }
    }
}
