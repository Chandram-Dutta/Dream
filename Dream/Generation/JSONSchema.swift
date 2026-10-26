import Foundation
import FoundationModels

// Connected services (ROADMAP.md, workstream 8): JSON values, and the JSON Schemas of their
// tools turned into schemas guided generation can fill.

/// A JSON value: a tool's schema, the arguments it's called with, or what it returned.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(json: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Compact, with sorted keys, so the same value always reads the same.
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var number: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var bool: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Every string in it, keys included, for checking what a call would send.
    var strings: [String] {
        switch self {
        case .string(let string): [string]
        case .array(let items): items.flatMap(\.strings)
        case .object(let object): object.flatMap { [$0.key] + $0.value.strings }
        case .null, .bool, .number: []
        }
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        // Whole numbers go out without a decimal point, which integer fields need.
        case .number(let number) where number == number.rounded() && abs(number) < 1e15: try container.encode(Int64(number))
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONValue {
    /// What the model generated for a tool's arguments.
    init(_ content: GeneratedContent) {
        switch content.kind {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .number(let number): self = .number(number)
        case .string(let string): self = .string(string)
        case .array(let items): self = .array(items.map(JSONValue.init))
        case .structure(let properties, _): self = .object(properties.mapValues(JSONValue.init))
        @unknown default: self = .null
        }
    }
}

/// Turns a tool's JSON Schema into one guided generation fills, so the model's arguments come
/// out in the shape the tool takes.
///
/// It covers what tool schemas usually use: objects, arrays, strings and their enums, numbers,
/// integers and booleans with their ranges, nullable types, local `$ref`s, `allOf` of objects,
/// and `anyOf`/`oneOf`, where the first shape that can be represented is used. An optional part
/// that can't be represented is left out; a required one makes the tool unusable, and it's nil.
struct ToolSchema {
    /// `name` names the root and prefixes nested types, so it must be unique in a session.
    static func generationSchema(for schema: JSONValue, name: String) -> GenerationSchema? {
        var converter = ToolSchema(root: schema, prefix: name)
        guard let root = converter.object(schema, name: name, depth: 0) else { return nil }
        return try? GenerationSchema(root: root, dependencies: [])
    }

    private let root: JSONValue
    private let prefix: String
    private var names: Set<String> = []

    private init(root: JSONValue, prefix: String) {
        self.root = root
        self.prefix = prefix
    }

    /// Deep enough for real tools, shallow enough that a recursive schema ends.
    private static let maximumDepth = 5
    /// Server-written text goes to the model, so it's kept short.
    static let descriptionLimit = 240

    private struct Converted {
        var schema: DynamicGenerationSchema
        /// It also allows null, so it's optional even when required.
        var isNullable: Bool
    }

    // MARK: - Objects

    private mutating func object(_ schema: JSONValue, name: String, depth: Int) -> DynamicGenerationSchema? {
        let schema = resolved(schema)
        var properties: [String: JSONValue] = schema["properties"]?.object ?? [:]
        var required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        // allOf of objects is one object with all their properties.
        for part in (schema["allOf"]?.array ?? []).map(resolved) {
            properties.merge(part["properties"]?.object ?? [:]) { first, _ in first }
            required.formUnion((part["required"]?.array ?? []).compactMap(\.string))
        }
        // A map with free-form keys can't be generated.
        if properties.isEmpty, let additional = schema["additionalProperties"], additional != .bool(false) {
            return nil
        }
        // Required first, in their order, then the rest by name.
        let order = (schema["required"]?.array ?? []).compactMap(\.string).filter { properties[$0] != nil }
        let names = order + properties.keys.filter { !order.contains($0) }.sorted()
        var converted: [DynamicGenerationSchema.Property] = []
        for property in names.prefix(40) {
            guard let value = properties[property] else { continue }
            let isRequired = required.contains(property)
            guard let result = convert(value, name: "\(name)_\(Self.identifier(property))", depth: depth + 1) else {
                if isRequired { return nil }
                continue
            }
            converted.append(DynamicGenerationSchema.Property(
                name: property,
                description: Self.describe(value, resolved(value)),
                schema: result.schema,
                isOptional: !isRequired || result.isNullable))
        }
        return DynamicGenerationSchema(name: unique(name), description: Self.text(schema["description"]?.string), properties: converted)
    }

    // MARK: - Any value

    private mutating func convert(_ original: JSONValue, name: String, depth: Int) -> Converted? {
        guard depth <= Self.maximumDepth else { return nil }
        let schema = resolved(original)
        // anyOf and oneOf: null makes it optional; otherwise the first shape that works.
        if let choices = (schema["anyOf"] ?? schema["oneOf"])?.array {
            let shapes = choices.map(resolved)
            let others = shapes.filter { $0["type"]?.string != "null" }
            let isNullable = others.count < shapes.count
            let constants = others.compactMap { $0["const"]?.string ?? $0["enum"]?.array?.onlyString }
            if !others.isEmpty, constants.count == others.count {
                return Converted(schema: DynamicGenerationSchema(name: unique(name), anyOf: constants), isNullable: isNullable)
            }
            for shape in others {
                if var result = convert(shape, name: name, depth: depth) {
                    result.isNullable = result.isNullable || isNullable
                    return result
                }
            }
            return nil
        }
        var types = schema["type"]?.array?.compactMap(\.string) ?? schema["type"]?.string.map { [$0] } ?? []
        let isNullable = types.contains("null")
        types.removeAll { $0 == "null" }
        if types.isEmpty { types = Self.inferredTypes(schema) }
        for type in types {
            if let result = convert(schema, as: type, name: name, depth: depth) {
                return Converted(schema: result, isNullable: isNullable)
            }
        }
        return nil
    }

    private mutating func convert(_ schema: JSONValue, as type: String, name: String, depth: Int) -> DynamicGenerationSchema? {
        switch type {
        case "string":
            if let constant = schema["const"]?.string {
                return DynamicGenerationSchema(name: unique(name), anyOf: [constant])
            }
            if let options = schema["enum"]?.array {
                let strings = options.compactMap(\.string)
                return strings.isEmpty ? nil : DynamicGenerationSchema(name: unique(name), anyOf: strings)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            let low = Self.integer(schema["minimum"]?.number?.rounded(.up)) ?? Self.integer(schema["exclusiveMinimum"]?.number?.rounded(.down)).map { $0 + 1 }
            let high = Self.integer(schema["maximum"]?.number?.rounded(.down)) ?? Self.integer(schema["exclusiveMaximum"]?.number?.rounded(.up)).map { $0 - 1 }
            switch (low, high) {
            case let (low?, high?) where low <= high: return DynamicGenerationSchema(type: Int.self, guides: [.range(low...high)])
            case let (low?, nil): return DynamicGenerationSchema(type: Int.self, guides: [.minimum(low)])
            case let (nil, high?): return DynamicGenerationSchema(type: Int.self, guides: [.maximum(high)])
            default: return DynamicGenerationSchema(type: Int.self)
            }
        case "number":
            let low = schema["minimum"]?.number ?? schema["exclusiveMinimum"]?.number
            let high = schema["maximum"]?.number ?? schema["exclusiveMaximum"]?.number
            switch (low, high) {
            case let (low?, high?) where low <= high: return DynamicGenerationSchema(type: Double.self, guides: [.range(low...high)])
            case let (low?, nil): return DynamicGenerationSchema(type: Double.self, guides: [.minimum(low)])
            case let (nil, high?): return DynamicGenerationSchema(type: Double.self, guides: [.maximum(high)])
            default: return DynamicGenerationSchema(type: Double.self)
            }
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            guard let items = schema["items"], let item = convert(items, name: "\(name)_item", depth: depth + 1) else { return nil }
            let low = Self.integer(schema["minItems"]?.number).map { max(0, $0) }
            let high = Self.integer(schema["maxItems"]?.number).map { max($0, low ?? 0) }
            return DynamicGenerationSchema(arrayOf: item.schema, minimumElements: low, maximumElements: high)
        case "object":
            return object(schema, name: name, depth: depth)
        default:
            return nil
        }
    }

    // MARK: - Pieces

    /// Follows a local `$ref` (`#/$defs/...`, `#/definitions/...`, or `#` for the root),
    /// keeping a description written beside it.
    private func resolved(_ schema: JSONValue) -> JSONValue {
        var schema = schema
        for _ in 0..<8 {
            guard let reference = schema["$ref"]?.string, reference.hasPrefix("#") else { return schema }
            var target = root
            for part in reference.dropFirst().split(separator: "/") {
                let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let next = target[key] else { return .object([:]) }
                target = next
            }
            if let description = schema["description"], var object = target.object, object["description"] == nil {
                object["description"] = description
                target = .object(object)
            }
            schema = target
        }
        return schema
    }

    /// A bound as an integer, when it's a sensible one.
    private static func integer(_ value: Double?) -> Int? {
        guard let value, value.isFinite, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    /// For schemas that leave out `type`.
    private static func inferredTypes(_ schema: JSONValue) -> [String] {
        if schema["properties"] != nil || schema["allOf"] != nil { return ["object"] }
        if schema["items"] != nil { return ["array"] }
        if let options = schema["enum"]?.array, options.allSatisfy({ $0.string != nil }) { return ["string"] }
        if schema["const"]?.string != nil { return ["string"] }
        return []
    }

    /// A property's description, with what generation can't enforce said in words.
    private static func describe(_ original: JSONValue, _ schema: JSONValue) -> String? {
        var parts: [String] = []
        if let description = text(original["description"]?.string ?? schema["description"]?.string) { parts.append(description) }
        if let format = schema["format"]?.string { parts.append("Format: \(format).") }
        if let options = schema["enum"]?.array, options.contains(where: { $0.string == nil }) {
            parts.append("One of: \(options.map(\.jsonString).joined(separator: ", ")).")
        }
        if let example = schema["default"], example != .null { parts.append("Default: \(example.jsonString).") }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : String(joined.prefix(descriptionLimit))
    }

    /// Server-written text, trimmed and kept short.
    static func text(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > descriptionLimit ? String(cleaned.prefix(descriptionLimit - 1)) + "…" : cleaned
    }

    /// Letters, digits and underscores, which every model's tool format accepts.
    static func identifier(_ text: String) -> String {
        let mapped = text.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? Character(scalar) : "_"
        }
        let collapsed = String(mapped).split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return collapsed.isEmpty ? "value" : collapsed
    }

    /// Nested types are named, and names can't repeat.
    private mutating func unique(_ name: String) -> String {
        var candidate = name
        var number = 2
        while names.contains(candidate) {
            candidate = "\(name)_\(number)"
            number += 1
        }
        names.insert(candidate)
        return candidate
    }
}

private extension Array where Element == JSONValue {
    /// The single string of a one-value enum.
    var onlyString: String? {
        count == 1 ? first?.string : nil
    }
}
