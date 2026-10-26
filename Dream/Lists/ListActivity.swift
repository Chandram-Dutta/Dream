import CoreGraphics
import Foundation
import SwiftUI

/// What's happening to a surface's lists right now, for the lists to show: a change being
/// worked out, and the last change, which can be undone.
struct ListActivity: Equatable {
    /// Lists a typed, spoken or photographed change is being worked out for.
    var interpreting: Set<String> = []
    var undo: RecordUndo?
}

/// A change to the user's entries that can be taken back: what they were before, and what
/// changed, in words.
struct RecordUndo: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let before: [String: [Record]]
    /// The lists it changed, which offer to undo it.
    let collections: Set<String>

    static func == (a: RecordUndo, b: RecordUndo) -> Bool { a.id == b.id }
}

extension SurfaceState {
    /// Changes the user's entries, keeping what was there so the change can be undone.
    func change(_ operations: [RecordOperation], in surface: Surface, undoable: Bool = true) {
        guard !operations.isEmpty else { return }
        let before = records
        withAnimation(.smooth) {
            surface.apply(operations, to: &records)
        }
        if undoable {
            lists.undo = RecordUndo(message: Self.describe(operations, in: surface, before: before), before: before, collections: Set(operations.map(\.collection)))
        }
        let added = operations.filter { if case .insert = $0 { true } else { false } }.count
        if added > 0 { Analytics.send(.listEntriesAdded(count: added)) }
    }

    func undoLastChange() {
        guard let undo = lists.undo else { return }
        withAnimation(.smooth) {
            records = undo.before
        }
        lists.undo = nil
    }

    /// "Added Milk", "Removed 3 expenses", "Added 2 groceries, changed 1".
    static func describe(_ operations: [RecordOperation], in surface: Surface, before: [String: [Record]]) -> String {
        var counts: [(verb: String, count: Int)] = [("Added", 0), ("Changed", 0), ("Removed", 0)]
        var collections: Set<String> = []
        var only: String?
        for operation in operations {
            switch operation {
            case .insert(let name, let values):
                counts[0].count += 1
                collections.insert(name)
                only = surface.collection(name)?.titleField.flatMap { values[$0.name]?.textValue }
            case .update(let name, let id, _):
                counts[1].count += 1
                collections.insert(name)
                only = title(of: id, in: name, surface: surface, records: before)
            case .delete(let name, let id):
                counts[2].count += 1
                collections.insert(name)
                only = title(of: id, in: name, surface: surface, records: before)
            }
        }
        let parts = counts.filter { $0.count > 0 }
        if operations.count == 1, let only, let verb = parts.first?.verb { return "\(verb) \(only)" }
        let label = collections.count == 1 ? collections.first.flatMap { surface.collection($0)?.label.lowercased() } : nil
        return parts.enumerated().map { index, part in
            if parts.count == 1, let label { return "\(part.verb) \(part.count) \(label)" }
            return "\(index == 0 ? part.verb : part.verb.lowercased()) \(part.count)"
        }.joined(separator: ", ")
    }

    private static func title(of id: UUID, in name: String, surface: Surface, records: [String: [Record]]) -> String? {
        guard let title = surface.collection(name)?.titleField, let record = records[name]?.first(where: { $0.id == id }) else { return nil }
        return title.display(record[title.name]).nilIfEmpty
    }
}

extension SurfaceState {
    func record(_ id: UUID, in collection: String) -> Record? {
        records[collection]?.first { $0.id == id }
    }

    /// Sets one field of one entry; nil clears it.
    func set(_ field: String, to value: RecordValue?, of id: UUID, in collection: String) {
        guard let index = records[collection]?.firstIndex(where: { $0.id == id }), records[collection]?[index][field] != value else { return }
        records[collection]?[index][field] = value
    }

    func delete(_ ids: [UUID], from collection: RecordCollection, in surface: Surface) {
        change(ids.map { .delete(collection: collection.name, id: $0) }, in: surface)
    }

    /// Moves an entry to where another one is, in a list the user arranges by hand.
    func move(_ id: UUID, to target: UUID, in collection: RecordCollection) {
        var shown = collection.arranged(records[collection.name] ?? [])
        guard let from = shown.firstIndex(where: { $0.id == id }), let to = shown.firstIndex(where: { $0.id == target }), from != to else { return }
        shown.insert(shown.remove(at: from), at: to)
        let orders = Dictionary(shown.enumerated().map { ($1.id, Double($0)) }, uniquingKeysWith: { first, _ in first })
        records[collection.name] = records[collection.name]?.map { $0.reordered(orders[$0.id] ?? $0.order) }
    }
}

extension RecordTalk {
    /// From the change bar. On a surface with lists, what's said may be about the entries ("add
    /// milk", "mark the first two done") rather than the screen. True when it was, and the
    /// entries have changed; false when the screen itself should change. Pointing at anything
    /// but a list is always about the screen.
    @MainActor static func handle(_ text: String, on surface: Surface, focus: Block?, state: SurfaceState) async -> Bool {
        guard !surface.recordCollections.isEmpty, focus.map({ $0.kind == .list || $0.kind == .add }) ?? true else { return false }
        state.lists.interpreting = Set(surface.recordCollections.map(\.name))
        defer { state.lists.interpreting = [] }
        switch await interpret(text, surface: surface, records: state.records) {
        case .records(let operations)?:
            state.change(operations, in: surface)
            return true
        case .screen?, nil:
            return false
        }
    }

    /// From a list's add bar, for what the phone can't read on its own, or a photo.
    @MainActor static func add(_ text: String, image: CGImage? = nil, to collection: RecordCollection, on surface: Surface, state: SurfaceState) async -> Bool {
        state.lists.interpreting.insert(collection.name)
        defer { state.lists.interpreting.remove(collection.name) }
        guard case .records(let operations)? = await interpret(text, image: image, surface: surface, records: state.records, adding: collection.name) else { return false }
        state.change(operations, in: surface, undoable: image != nil || operations.count > 1)
        return true
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
