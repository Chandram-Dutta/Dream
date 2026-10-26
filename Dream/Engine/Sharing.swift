import Foundation

// Sharing (ROADMAP.md, workstream 9). What's shared is a surface, never a chat: the template,
// with its reference, credits and locale. The user's numbers go only when they choose. Their
// answers, list entries, photo and memory never leave the phone.

/// A surface as it travels between phones, and to the web viewer (Server/).
struct SharedSurface: Codable {
    static let currentFormat = 1
    /// The most a shared surface may weigh. Real ones are 5 to 40 KB.
    static let maxSize = 200_000

    var format = Self.currentFormat
    var surface: Surface
    /// The sharer's own numbers, by input name. Nil unless they chose to share them.
    var values: [String: Double]?
    /// The currency money is written in, so the web viewer shows it as it was meant.
    var currency: String?
    /// What the engine works out for the web viewer, which can't calculate: values as shown,
    /// equations, and chart lines. Never read back by the app.
    var preview: WebPreview?
}

/// The engine's working for one shared surface, so the web viewer shows exactly what the app
/// would, without a formula engine of its own.
struct WebPreview: Codable, Hashable {
    struct Equation: Codable, Hashable {
        var equation: String
        var worked: String?
        var legend: [Symbol]
    }

    struct Symbol: Codable, Hashable {
        var symbol: String
        var meaning: String
    }

    struct Chart: Codable, Hashable {
        var axis: String
        var lines: [Line]
    }

    struct Line: Codable, Hashable {
        var label: String
        /// Pairs of x and y, in the units the axes are labelled in.
        var points: [[Double]]
    }

    /// Every input and output as the reader sees it, unit included.
    var values: [String: String]
    /// The same, as maths, for `\val{name}` in equations.
    var tex: [String: String]
    /// By output name, for equation blocks that show a calculation.
    var equations: [String: Equation]
    /// By chart block id.
    var charts: [String: Chart]
}

extension Surface {
    /// The template as it leaves the phone: the questions asked before building keep their
    /// answers here, and those can be personal (a city, a diet), so they're left out.
    var shareable: Surface {
        var surface = self
        surface.answers = nil
        return surface
    }

    /// Answers the user gave that the surface's own text repeats, like a city in its title.
    /// Stripping answers can't take them out of what the model wrote, so the share sheet says so.
    var mentionedAnswers: [String] {
        let text = readableTexts.joined(separator: "\n").lowercased()
        return (answers ?? []).compactMap { answer in
            let choice = answer.choice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard answer.question.isPersonal, choice.count >= 3, text.contains(choice.lowercased()) else { return nil }
            return choice
        }
    }

    /// Everyone's starting entries: the list starters the template carries, never the user's own.
    var starterRecords: [String: [Record]] {
        Dictionary(recordCollections.map { ($0.name, $0.starterRecords()) }, uniquingKeysWith: { first, _ in first })
    }
}

extension SharedSurface {
    /// A surface ready to share. `values` are the user's numbers when they chose to include
    /// them; only those they set themselves are kept.
    init(sharing surface: Surface, values: [String: Double]?, currency: String = Currency.code) {
        let template = surface.shareable
        let own = values.map { values in
            Dictionary(uniqueKeysWithValues: template.adjustableInputs.compactMap { input in
                values[input.name].flatMap { $0.isFinite && $0 != input.initial ? (input.name, $0) : nil }
            })
        }
        self.surface = template
        self.values = own?.isEmpty == false ? own : nil
        self.currency = currency
        self.preview = WebPreview(template, values: self.values ?? [:])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        surface = try container.decode(Surface.self, forKey: .surface)
        values = try container.decodeIfPresent([String: Double].self, forKey: .values)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        // The preview is for the web; what the app shows, it works out itself.
        preview = nil
    }

    var json: Data {
        get throws { try Self.encoder.encode(self) }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}

extension WebPreview {
    init(_ surface: Surface, values given: [String: Double]) {
        let records = surface.starterRecords
        var start = surface.initialValues
        start.merge(given) { _, own in own }
        let evaluation = surface.evaluate(start, records: records).values
        let names = surface.inputs.map(\.name) + surface.outputs.map(\.name)
        values = Dictionary(names.map { ($0, surface.display($0, evaluation[$0])) }, uniquingKeysWith: { first, _ in first })
        tex = Dictionary(names.map { ($0, surface.texValue($0, evaluation[$0] ?? .nan)) }, uniquingKeysWith: { first, _ in first })

        var equations: [String: Equation] = [:]
        var charts: [String: Chart] = [:]
        func visit(_ block: Block) {
            switch block.kind {
            case .equation where surface.output(block.ref) != nil:
                if let equation = surface.equation(for: block.ref) {
                    equations[block.ref] = Equation(equation: equation, worked: surface.workedEquation(for: block.ref, values: evaluation), legend: Self.legend(for: block.ref, in: surface))
                }
            case .chart:
                let lines = block.refs.map { name in
                    Line(label: surface.axisTitle(name), points: surface.series(of: name, over: block.over, given: start, records: records).map { point in
                        [Self.rounded(surface.shownValue(block.over, point.x)), Self.rounded(surface.shownValue(name, point.y))]
                    })
                }
                charts[block.id] = Chart(axis: surface.axisTitle(block.over), lines: lines)
            default:
                block.children.forEach(visit)
            }
        }
        surface.blocks.forEach(visit)
        self.equations = equations
        self.charts = charts
    }

    /// What each symbol in an output's formula stands for, as the equation block explains it.
    private static func legend(for name: String, in surface: Surface) -> [Symbol] {
        guard let output = surface.output(name), let expr = try? FormulaCache.parse(output.formula) else { return [] }
        let names = [name] + surface.inputs.map(\.name).filter(expr.names.contains) + surface.outputs.map(\.name).filter(expr.names.contains)
        var seen: Set<String> = []
        return names.compactMap { name in
            let symbol = surface.input(name)?.symbol ?? surface.output(name)?.symbol ?? ""
            guard !symbol.isEmpty, seen.insert(symbol).inserted else { return nil }
            return Symbol(symbol: symbol, meaning: surface.label(of: name))
        }
    }

    /// Six significant digits are plenty for a line on a page, and keep the upload small.
    private static func rounded(_ value: Double) -> Double {
        Double(String(format: "%.6g", value)) ?? value
    }
}

// MARK: - Receiving

/// A surface someone shared, checked and ready to keep.
struct ReceivedSurface {
    var surface: Surface
    /// The sharer's numbers, if they sent them: only adjustable inputs, inside their ranges.
    var values: [String: Double]
    /// What the checker fixed, for the log.
    var issues: [Issue]
}

enum ShareError: LocalizedError, Equatable {
    case tooBig, unreadable, newer, empty

    var errorDescription: String? {
        switch self {
        case .tooBig: "This shared screen is too big to open."
        case .unreadable: "This shared screen couldn't be read."
        case .newer: "This screen was shared from a newer version of Dream."
        case .empty: "This shared screen is empty."
        }
    }
}

extension SharedSurface {
    /// Opens what someone shared. It came over the network, so it's untrusted: bounded before
    /// it's read, stripped of anything that could point elsewhere or carry someone's personal
    /// answers, then fixed and checked by the same checker as anything the model writes.
    static func received(_ data: Data) throws -> ReceivedSurface {
        guard data.count <= maxSize else { throw ShareError.tooBig }
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], JSONLimits.allow(json) else { throw ShareError.unreadable }
        // Answers are personal and never kept, so they're dropped unread: however they're
        // written, they can't stop the rest from opening.
        if var surface = json["surface"] as? [String: Any] {
            surface["answers"] = nil
            json["surface"] = surface
        }
        let shared: SharedSurface
        do {
            shared = try decoder.decode(SharedSurface.self, from: JSONSerialization.data(withJSONObject: json))
        } catch {
            throw ShareError.unreadable
        }
        guard shared.format <= currentFormat else { throw ShareError.newer }

        var surface = shared.surface.bounded
        surface.answers = nil
        surface.reference = surface.reference?.trusted
        surface.sounds = surface.sounds?.map { sound in
            var sound = sound
            sound.recording = sound.recording?.trusted
            return sound
        }
        if let locale = surface.locale, !locale.isPlausible { surface.locale = nil }
        var issues = Checker.checkLogic(&surface)
        issues += Checker.checkBlocks(&surface)
        guard !surface.isEmpty, !surface.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShareError.empty }
        // Older shares say nothing about their language; tell it from the text, so a reader
        // elsewhere still gets it translated.
        if surface.locale == nil {
            surface.locale = SurfaceLocale(written: surface, likely: nil, fallback: Languages.primary)
        }

        var values: [String: Double] = [:]
        for input in surface.adjustableInputs {
            if let value = shared.values?[input.name], value.isFinite { values[input.name] = input.snapped(value) }
        }
        return ReceivedSurface(surface: surface, values: values, issues: issues)
    }
}

/// Bounds on any JSON that comes from elsewhere, before it's decoded: how deep it nests, how
/// much there is, and how long its strings and lists are. Brackets inside a string are bounded
/// too, since formulas and LaTeX are parsed by recursion.
enum JSONLimits {
    static let depth = 24
    static let nodes = 25_000
    static let string = 4_000
    static let array = 400
    static let bracketDepth = 32

    static func allow(_ value: Any) -> Bool {
        var count = 0
        func visit(_ node: Any, depth: Int) -> Bool {
            count += 1
            guard count <= nodes, depth <= Self.depth else { return false }
            switch node {
            case let text as String:
                return text.count <= string && nesting(of: text) <= bracketDepth
            case let list as [Any]:
                return list.count <= array && list.allSatisfy { visit($0, depth: depth + 1) }
            case let object as [String: Any]:
                return object.count <= array && object.allSatisfy { $0.key.count <= 200 && visit($0.value, depth: depth + 1) }
            default:
                return true
            }
        }
        return visit(value, depth: 0)
    }

    private static func nesting(of text: String) -> Int {
        var depth = 0
        var deepest = 0
        for character in text.unicodeScalars {
            switch character {
            case "(", "[", "{":
                depth += 1
                deepest = max(deepest, depth)
            case ")", "]", "}":
                depth = max(depth - 1, 0)
            default: break
            }
        }
        return deepest
    }
}

private extension Surface {
    /// No more of anything than a screen could use. The checker trims some kinds itself; these
    /// bound the rest, so a crafted share can't make layout or checking slow.
    var bounded: Surface {
        var surface = self
        func trimmed(_ blocks: [Block], depth: Int) -> [Block] {
            blocks.prefix(60).map { block in
                var block = block
                block.items = Array(block.items.prefix(60))
                block.children = depth < 3 ? trimmed(block.children, depth: depth + 1) : []
                return block
            }
        }
        surface.blocks = trimmed(blocks, depth: 0)
        surface.inputs = Array(inputs.prefix(40))
        surface.outputs = Array(outputs.prefix(60))
        surface.related = Array(related.prefix(12))
        surface.sounds = sounds.map { Array($0.prefix(8)) }
        surface.figures = figures.map { figures in
            figures.prefix(8).map { figure in
                var figure = figure
                figure.points = Array(figure.points.prefix(60))
                figure.shapes = Array(figure.shapes.prefix(60))
                return figure
            }
        }
        surface.diagrams = diagrams.map { diagrams in
            diagrams.prefix(8).map { diagram in
                var diagram = diagram
                diagram.nodes = Array(diagram.nodes.prefix(30))
                diagram.edges = Array(diagram.edges.prefix(60))
                return diagram
            }
        }
        return surface
    }
}

private extension Reference {
    /// Kept only when it points where Dream looks things up: Wikipedia, and its images on
    /// Wikimedia. Anything else could lead a reader somewhere they didn't choose.
    var trusted: Reference? {
        guard Trusted.https(url, hostSuffix: ".wikipedia.org") else { return nil }
        var reference = self
        if let image = imageURL, !Trusted.https(image, host: "upload.wikimedia.org") { reference.imageURL = nil }
        return reference
    }
}

private extension Recording {
    /// Recordings come from Wikimedia Commons; one from anywhere else is dropped, and so is its sound.
    var trusted: Recording? {
        guard Trusted.https(audioURL, host: "upload.wikimedia.org") else { return nil }
        var recording = self
        if !Trusted.https(pageURL, host: "commons.wikimedia.org") { recording.pageURL = "" }
        return recording
    }
}

private extension SurfaceLocale {
    var isPlausible: Bool {
        language.count <= 20 && language.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
            && ["metric", "ussystem", "uksystem"].contains(measurementSystem)
    }
}

private enum Trusted {
    static func https(_ string: String, host wanted: String) -> Bool {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == wanted
    }

    static func https(_ string: String, hostSuffix: String) -> Bool {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix(hostSuffix)
    }
}
