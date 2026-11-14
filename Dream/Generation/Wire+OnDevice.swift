import Foundation
import FoundationModels

// The page as the on-device model writes it. Apple's model on the iPhone has a window of about
// 8,000 tokens for everything: the brief, the schema, the request, what it looks up and the page
// itself. The full format (Wire.swift) needs more than that for its schema alone, so the iPhone
// writes a narrower version of it: the same pages, made of the blocks it uses most (text, facts,
// timelines, a calculation with its controls, charts), without figures, scenes, sounds, lists or
// connected services. It becomes the same `Surface`, goes through the same checker and is drawn
// by the same renderer. A page needing more is written on Private Cloud Compute.

/// What both formats give the composer: a surface, whole or as it streams in.
protocol SurfaceFormat: Generable {
    func surface(reference: Reference?) -> Surface
    static func surface(partial: PartiallyGenerated, reference: Reference?) -> Surface
    /// Whether the related topics were reached, so every block before them is finished.
    static func blocksFinished(_ partial: PartiallyGenerated) -> Bool
}

extension WireSurface: SurfaceFormat {
    func surface(reference: Reference?) -> Surface { Surface(self, reference: reference) }
    static func surface(partial: PartiallyGenerated, reference: Reference?) -> Surface { Surface(partial: partial, reference: reference) }
    static func blocksFinished(_ partial: PartiallyGenerated) -> Bool { partial.related != nil }
}

@Generable
enum DeviceBlockKind {
    case hero, metric, slider, stepper, toggle, picker, chart
    case paragraph, facts, bullets, steps, timeline, stat, equation
}

@Generable
struct DeviceItem {
    @Guide(description: "facts: the name. timeline: the date. stat: the number. Otherwise empty.")
    var label: String
    var value: String
}

@Generable
struct DeviceBlock {
    var kind: DeviceBlockKind
    @Guide(description: "Short heading, or empty")
    var title: String
    @Guide(description: "paragraph: 2 to 4 sentences. equation: LaTeX. Otherwise empty.")
    var text: String
    @Guide(description: "Controls, hero, metric, chart and equation: the input or output name. Otherwise empty.")
    var ref: String
    @Guide(description: "chart: the input along the bottom. Otherwise empty.")
    var over: String
    @Guide(.count(0...6))
    var items: [DeviceItem]
}

@Generable
enum DeviceRole { case adjustable, given, variable }

@Generable
struct DeviceInput {
    @Guide(description: "camelCase")
    var name: String
    var label: String
    var role: DeviceRole
    @Guide(description: "Like km, kg or years. Empty for money, percent and counts.")
    var unit: String
    var format: WireFormat
    var initial: Double
    var min: Double
    var max: Double
    var step: Double
    @Guide(description: "choice only; otherwise empty")
    var options: [String]
}

@Generable
struct DeviceOutput {
    @Guide(description: "camelCase")
    var name: String
    var label: String
    var unit: String
    @Guide(description: "Uses input names and earlier outputs")
    var formula: String
    var format: WireFormat
}

@Generable(description: "A screen that answers the request")
struct DeviceSurface {
    var subject: WireSubject
    var mode: WireMode
    @Guide(description: "1 to 4 words")
    var title: String
    @Guide(description: "One sentence that answers the request")
    var summary: String
    @Guide(description: "SF Symbols name")
    var symbol: String
    @Guide(description: "The question changing numbers answers, or empty for facts")
    var question: String
    @Guide(.count(0...5))
    var inputs: [DeviceInput]
    @Guide(.count(0...4))
    var outputs: [DeviceOutput]
    @Guide(.count(1...10))
    var blocks: [DeviceBlock]
    @Guide(description: "3 to 5 nearby topics", .maximumCount(5))
    var related: [String]
}

extension DeviceSurface: SurfaceFormat {
    func surface(reference: Reference?) -> Surface {
        var surface = Surface(
            title: title,
            summary: summary,
            symbol: symbol,
            accent: Subject(subject).accent,
            inputs: inputs.map(Input.init),
            outputs: outputs.map(Output.init),
            blocks: blocks.enumerated().map { Block($1, id: "block-\($0)") },
            related: related,
            reference: reference,
            question: question.isEmpty ? nil : question,
            collections: nil)
        surface.mode = Mode(mode)
        return surface
    }

    static func surface(partial wire: PartiallyGenerated, reference: Reference?) -> Surface {
        var surface = Surface(
            title: wire.title ?? "",
            summary: wire.summary ?? "",
            symbol: wire.symbol ?? "sparkles",
            accent: wire.subject.map { Subject($0).accent } ?? .blue,
            inputs: (wire.inputs ?? []).compactMap(Input.init(partial:)),
            outputs: (wire.outputs ?? []).compactMap(Output.init(partial:)),
            blocks: (wire.blocks ?? []).enumerated().compactMap { Block(partial: $1, id: "block-\($0)") },
            related: wire.related ?? [],
            reference: reference,
            question: wire.question.flatMap { $0.isEmpty ? nil : $0 },
            collections: nil)
        surface.mode = wire.mode.map(Mode.init)
        return surface
    }

    static func blocksFinished(_ partial: PartiallyGenerated) -> Bool { partial.related != nil }
}

extension Block {
    init(_ wire: DeviceBlock, id: String) {
        self.init(id: id, kind: BlockKind(rawValue: String(describing: wire.kind)) ?? .paragraph, title: wire.title, text: wire.text,
                  ref: wire.ref, over: wire.over, items: wire.items.map { Item(label: $0.label, value: $0.value) }, children: [])
    }

    init?(partial wire: DeviceBlock.PartiallyGenerated, id: String) {
        guard let kind = wire.kind else { return nil }
        self.init(id: id, kind: BlockKind(rawValue: String(describing: kind)) ?? .paragraph, title: wire.title ?? "", text: wire.text ?? "",
                  ref: wire.ref ?? "", over: wire.over ?? "", items: (wire.items ?? []).map { Item(label: $0.label ?? "", value: $0.value ?? "") }, children: [])
    }
}

extension Input {
    init(_ wire: DeviceInput) {
        let role: InputRole = switch wire.role {
        case .adjustable: .adjustable
        case .given: .given
        case .variable: .variable
        }
        self.init(name: wire.name, label: wire.label, format: Format(wire.format), initial: wire.initial, min: wire.min, max: wire.max,
                  step: wire.step, options: wire.options, role: role, symbol: "", unit: wire.unit, source: "")
    }

    init?(partial wire: DeviceInput.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        let initial = wire.initial ?? 0
        let lowest = wire.min ?? Swift.min(0, initial)
        let role: InputRole = switch wire.role {
        case .given: .given
        case .variable: .variable
        default: .adjustable
        }
        self.init(name: name, label: wire.label ?? "", format: wire.format.map { Format($0) } ?? .number, initial: initial, min: lowest,
                  max: wire.max ?? Swift.max(lowest + 1, initial * 2), step: wire.step ?? 0, options: wire.options ?? [], role: role,
                  symbol: "", unit: wire.unit ?? "", source: "")
    }
}

extension Output {
    init(_ wire: DeviceOutput) {
        self.init(name: wire.name, label: wire.label, formula: wire.formula, format: Format(wire.format), symbol: "", unit: wire.unit)
    }

    init?(partial wire: DeviceOutput.PartiallyGenerated) {
        guard let name = wire.name, !name.isEmpty else { return nil }
        self.init(name: name, label: wire.label ?? "", formula: wire.formula ?? "", format: wire.format.map { Format($0) } ?? .number, symbol: "", unit: wire.unit ?? "")
    }
}
