import CoreGraphics
import Foundation
import FoundationModels

// Talking to a list: "add milk and eggs", "I spent 400 on lunch", "mark the first two done", or
// a receipt photo become changes to the user's entries. They're kept apart from changes to the
// screen, which go through the composer.

/// Turns what the user says about their lists into checked changes to their entries.
///
/// The schema the model fills is built from the lists' own fields, so it can only name fields
/// that exist and options a choice has; the checker still reads every value. If a model can't
/// run, fails, or proposes something the checker can't use, the next one gets the same request.
///
/// Which model goes first depends on what's at stake. Adding from a list's bar can only add,
/// so Apple's on-device model goes first: it's private and free, and a misread entry is plain
/// to see. What's said in the change bar can change or remove entries, or be about the screen
/// instead; the on-device model misreads those in ways no checker can catch (in testing, "make
/// it purple" removed every entry), so the cloud model goes first there, and the on-device
/// model only stands in when there's no cloud model.
enum RecordTalk {
    enum Outcome: Equatable {
        /// They want the screen itself changed: the composer's job.
        case screen
        /// Checked changes to their entries.
        case records([RecordOperation])
    }

    /// `adding` is a list's add bar: only new entries for that list. Nil when nothing could make
    /// sense of it.
    static func interpret(_ text: String, image: CGImage? = nil, surface: Surface, records: [String: [Record]], adding: String? = nil, now: Date = .now) async -> Outcome? {
        // A list a connected service fills is the service's, not the user's to change here.
        let surface = surface.keepingOwnLists
        let collections = surface.recordCollections.filter { adding == nil || $0.name == adding }
        guard !collections.isEmpty, let schema = try? RecordSchema.schema(for: collections, adding: adding != nil) else { return nil }
        let request = Prompts.recordRequest(text, surface: surface, records: records, hasImage: image != nil, adding: adding, now: now)
        var best: [RecordOperation]?
        for model in await models(hasImage: image != nil, privateFirst: adding != nil) {
            let started = Date()
            do {
                let content = try await respond(on: model, to: request, image: image, schema: schema)
                let reading = RecordSchema.read(content, collections: collections)
                if reading.isAboutScreen && reading.proposed.isEmpty {
                    note("\(model.name) read it as a change to the screen (\(elapsed(since: started))).")
                    return .screen
                }
                let (operations, issues) = RecordChecker.check(reading.proposed, in: surface, records: records, now: now)
                note("\(model.name): \(operations.count) change\(operations.count == 1 ? "" : "s") in \(elapsed(since: started))\(issues.isEmpty ? "" : "; " + issues.joined(separator: " "))")
                if issues.isEmpty && !operations.isEmpty { return .records(operations) }
                if operations.count > best?.count ?? 0 { best = operations }
            } catch {
                note("\(model.name) couldn't: \(error.localizedDescription)")
            }
        }
        return best.map { .records($0) }
    }

    // MARK: - Models

    private enum Model {
        case onDevice
        case cloud(Composer.Provider)

        var name: String {
            switch self {
            case .onDevice: "On-device model"
            case .cloud(let provider): provider.name
            }
        }
    }

    /// The on-device model and the cloud model the user chose for screens, in the order to try them.
    @MainActor private static func models(hasImage: Bool, privateFirst: Bool) -> [Model] {
        let system = SystemLanguageModel.default
        let onDevice: [Model] = system.isAvailable && (!hasImage || system.capabilities.contains(.vision)) ? [.onDevice] : []
        let chosen = Composer.provider
        let cloud: [Model] = ([chosen] + Composer.Provider.allCases.filter { $0 != chosen }).first(where: \.isUsable).map { [.cloud($0)] } ?? []
        return privateFirst ? onDevice + cloud : (cloud.isEmpty ? onDevice : cloud)
    }

    private static func respond(on model: Model, to request: String, image: CGImage?, schema: GenerationSchema) async throws -> GeneratedContent {
        let prompt = Prompt {
            request
            if let image { Attachment(image) }
        }
        let session: LanguageModelSession
        switch model {
        case .onDevice:
            session = LanguageModelSession(instructions: Prompts.recordInstructions)
        case .cloud(.dream):
            session = LanguageModelSession(model: DreamLanguageModel(modelID: Composer.xaiModelID, page: nil), instructions: Prompts.recordInstructions)
        case .cloud(.xai):
            session = LanguageModelSession(model: XAILanguageModel(apiKey: XAILanguageModel.savedKey ?? "", modelID: Composer.xaiModelID), instructions: Prompts.recordInstructions)
        case .cloud(.privateCloud):
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Prompts.recordInstructions)
        }
        return try await session.respond(to: prompt, schema: schema, options: GenerationOptions(samplingMode: .greedy)).content
    }

    private static func note(_ line: String) {
        Build.trace("[Dream] Lists: \(line)")
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }
}

/// The shape of a change to the user's lists, built from their fields:
/// `{ about, groceries: { add: [{ name, done }], change: [{ entry, field, value }], remove: [3] } }`.
enum RecordSchema {
    static func schema(for collections: [RecordCollection], adding: Bool) throws -> GenerationSchema {
        let lists = collections.map { collection in
            DynamicGenerationSchema.Property(name: collection.name, description: collection.label, schema: changes(to: collection, adding: adding))
        }
        // From the add bar it's only ever new entries, so there's nothing to decide first.
        let about = DynamicGenerationSchema.Property(
            name: "about",
            description: "records: adding, changing or removing entries. screen: changing the screen itself.",
            schema: DynamicGenerationSchema(name: "About", anyOf: ["records", "screen"]))
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Change", properties: (adding ? [] : [about]) + lists), dependencies: [])
    }

    private static func changes(to collection: RecordCollection, adding: Bool) -> DynamicGenerationSchema {
        let entry = DynamicGenerationSchema(name: "\(collection.name)Entry", properties: collection.fields.map(property))
        var properties = [DynamicGenerationSchema.Property(name: "add", description: "New entries", schema: DynamicGenerationSchema(arrayOf: entry, maximumElements: 40))]
        if !adding {
            let change = DynamicGenerationSchema(name: "\(collection.name)Change", properties: [
                .init(name: "entry", description: "The entry's number", schema: DynamicGenerationSchema(type: Int.self)),
                .init(name: "field", schema: DynamicGenerationSchema(name: "\(collection.name)Field", anyOf: collection.fields.map(\.name))),
                .init(name: "value", description: "The new value", schema: DynamicGenerationSchema(type: String.self)),
            ])
            properties += [
                .init(name: "change", description: "Changes to entries, one field each", schema: DynamicGenerationSchema(arrayOf: change, maximumElements: 40)),
                .init(name: "remove", description: "Entries to remove, by their numbers", schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: Int.self), maximumElements: 40)),
            ]
        }
        return DynamicGenerationSchema(name: "\(collection.name)Changes", properties: properties)
    }

    /// Every field is filled in; empty means not given.
    private static func property(_ field: RecordField) -> DynamicGenerationSchema.Property {
        switch field.type {
        case .done:
            return .init(name: field.name, description: field.label, schema: DynamicGenerationSchema(type: Bool.self))
        case .choice:
            return .init(name: field.name, description: "\(field.label), or empty", schema: DynamicGenerationSchema(name: "\(field.name)Option", anyOf: field.options + [""]))
        case .date:
            return .init(name: field.name, description: "\(field.label) as YYYY-MM-DD, or empty for today", schema: DynamicGenerationSchema(type: String.self))
        case .number, .currency, .rating:
            return .init(name: field.name, description: "\(field.label): a number\(field.type == .rating ? " from 1 to 5" : ""), or empty", schema: DynamicGenerationSchema(type: String.self))
        case .text:
            return .init(name: field.name, description: field.label, schema: DynamicGenerationSchema(type: String.self))
        }
    }

    struct Reading {
        var isAboutScreen: Bool
        var proposed: [ProposedOperation]
    }

    static func read(_ content: GeneratedContent, collections: [RecordCollection]) -> Reading {
        let about = (try? content.value(String.self, forProperty: "about")) ?? "records"
        var proposed: [ProposedOperation] = []
        for collection in collections {
            guard let changes = try? content.value(GeneratedContent.self, forProperty: collection.name) else { continue }
            for entry in elements(changes, "add") {
                guard case .structure(let properties, _) = entry.kind else { continue }
                let values = collection.fields.compactMap { field in properties[field.name].flatMap(text).map { ProposedOperation.Value(field: field.name, value: $0) } }
                proposed.append(ProposedOperation(action: .insert, collection: collection.name, entry: 0, values: values))
            }
            for change in elements(changes, "change") {
                guard let number = try? change.value(Int.self, forProperty: "entry"), let field = try? change.value(String.self, forProperty: "field"),
                      let value = try? change.value(String.self, forProperty: "value") else { continue }
                proposed.append(ProposedOperation(action: .update, collection: collection.name, entry: number, values: [.init(field: field, value: value)]))
            }
            for number in elements(changes, "remove").compactMap({ try? $0.value(Int.self) }) {
                proposed.append(ProposedOperation(action: .delete, collection: collection.name, entry: number, values: []))
            }
        }
        return Reading(isAboutScreen: about == "screen", proposed: proposed)
    }

    private static func elements(_ content: GeneratedContent, _ property: String) -> [GeneratedContent] {
        guard let list = try? content.value(GeneratedContent.self, forProperty: property), case .array(let items) = list.kind else { return [] }
        return items
    }

    /// A value as text, for the checker to read by the field's type.
    private static func text(_ content: GeneratedContent) -> String? {
        switch content.kind {
        case .string(let string): string.isEmpty ? nil : string
        case .number(let number): number.plain
        case .bool(let flag): flag ? "yes" : "no"
        default: nil
        }
    }
}
