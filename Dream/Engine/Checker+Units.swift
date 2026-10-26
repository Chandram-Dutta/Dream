import Foundation

// Units (ROADMAP.md, workstream 4): the checker's rules for them, called from `checkLogic` and
// `checkBlocks`.

extension Checker {
    /// Units as Dream writes them: tidied, out of labels, and only where they mean something.
    static func checkUnits(_ surface: inout Surface) -> [Issue] {
        var tidied: [String] = []
        for index in surface.inputs.indices {
            let input = surface.inputs[index]
            let (label, unit) = tidiedUnit(label: input.label, unit: input.unit, format: input.format)
            if label != input.label || unit != input.unit { tidied.append(input.name) }
            (surface.inputs[index].label, surface.inputs[index].unit) = (label, unit)
        }
        for index in surface.outputs.indices {
            let output = surface.outputs[index]
            let (label, unit) = tidiedUnit(label: output.label, unit: output.unit, format: output.format)
            if label != output.label || unit != output.unit { tidied.append(output.name) }
            (surface.outputs[index].label, surface.outputs[index].unit) = (label, unit)
        }
        guard !tidied.isEmpty else { return [] }
        return [Issue(kind: .fixed, message: "Tidied the units of \(tidied.map { "'\($0)'" }.joined(separator: ", ")).")]
    }

    private static func tidiedUnit(label original: String, unit raw: String, format: Format) -> (label: String, unit: String) {
        var label = original
        var unit = Units.tidy(raw)
        // "Distance (km)": the unit belongs in the unit. "Tip (%)" and "Bill ($)" repeat what
        // the format already shows.
        if let match = label.wholeMatch(of: #/(.+?)\s*[(\[]\s*([^()\[\]]{1,16}?)\s*[)\]]/#) {
            let inside = String(match.output.2)
            let shownByFormat = (format == .percent && inside == "%")
                || (format == .currency && (inside == Currency.symbol || inside.uppercased() == Currency.code || "$€£¥₹".contains(inside)))
            let isUnit = format.isMeasured && (unit.isEmpty ? Units.isUnit(inside) : Units.tidy(inside) == unit)
            let isCurrency = format == .currency && Currency.isCode(inside.uppercased())
            if shownByFormat || isUnit || isCurrency {
                label = String(match.output.1)
                if unit.isEmpty, isUnit { unit = Units.tidy(inside) }
                if unit.isEmpty, isCurrency { unit = inside.uppercased() }
            }
        }
        // Money in another currency keeps its code, like USD.
        if format == .currency, Currency.isCode(unit.uppercased()) {
            unit = unit.uppercased()
        } else if !format.isMeasured {
            unit = ""
        }
        return (label, unit)
    }

    /// A live value already shows its unit, so "{distance} m" or `\val{v}\,\mathrm{m/s}` would
    /// say it twice.
    static func removeRepeatedUnits(_ surface: inout Surface) -> [Issue] {
        var units: [String: String] = [:]
        for (name, unit, format) in surface.inputs.map({ ($0.name, $0.unit, $0.format) }) + surface.outputs.map({ ($0.name, $0.unit, $0.format) })
        where !unit.isEmpty && format.isMeasured && units[name] == nil {
            units[name] = unit
        }
        guard !units.isEmpty else { return [] }
        var repeated: Set<String> = []

        func math(_ tex: String) -> String {
            guard tex.contains("\\val") else { return tex }
            return tex.replacing(#/(\\val(?:ue)?\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\})(?:\s|\\[,;:! ]|~)*(\\(?:mathrm|text|textrm|rm|mbox)\{[^{}]*\}(?:\^\{?-?[0-9]\}?)?)/#) { match in
                let name = String(match.output.2)
                guard let unit = units[name], Units.tidy(String(match.output.3)) == unit else { return String(match.output.0) }
                repeated.insert(name)
                return String(match.output.1)
            }
        }

        func prose(_ text: String) -> String {
            guard text.contains("{") else { return text }
            let parts = Placeholders.parts(text)
            var result: [Placeholders.Part] = []
            var changed = false
            for part in parts {
                switch part {
                case .text(let prose):
                    if case .name(let name)? = result.last, let unit = units[name], let rest = Units.dropping(unit, from: prose) {
                        repeated.insert(name)
                        changed = true
                        result.append(.text(rest))
                    } else {
                        result.append(part)
                    }
                case .math(let tex):
                    let fixed = math(tex)
                    changed = changed || fixed != tex
                    result.append(.math(fixed))
                case .name:
                    result.append(part)
                }
            }
            return changed ? Placeholders.join(result) : text
        }

        func fix(_ block: Block) -> Block {
            var block = block
            block.title = prose(block.title)
            block.text = block.kind == .equation ? math(block.text) : prose(block.text)
            block.items = block.items.map { Item(label: $0.label, value: prose($0.value)) }
            block.children = block.children.map(fix)
            return block
        }

        surface.blocks = surface.blocks.map(fix)
        guard !repeated.isEmpty else { return [] }
        return [Issue(kind: .fixed, message: "Removed units written after the live values of \(repeated.sorted().map { "'\($0)'" }.joined(separator: ", ")), which show their own.")]
    }
}
