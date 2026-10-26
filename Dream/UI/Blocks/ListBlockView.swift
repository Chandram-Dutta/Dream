import SwiftUI
import UniformTypeIdentifiers

/// A list the user keeps. Check entries off with the circle, tap one to edit it in place,
/// swipe it left to delete it, and hold and drag to reorder. Checked-off entries sink below
/// the rest, and totals worked out from the list move as it changes.
struct ListBlockView: View {
    let block: Block
    let context: RenderContext
    let depth: Int

    @State private var editing: UUID?
    @State private var dragging: UUID?
    @State private var showingAll = false
    /// Entries that just arrived, lit for a moment so you see where they went.
    @State private var arrived: Set<UUID> = []

    private var palette: Palette { context.palette }
    private var state: SurfaceState { context.state }

    var body: some View {
        if let collection = context.surface.collection(block.ref) {
            content(collection)
        }
    }

    @ViewBuilder private func content(_ collection: RecordCollection) -> some View {
        let all = collection.arranged(state.records[collection.name] ?? [])
        let check = collection.checkField
        let open = check.map { check in all.filter { !$0.isOn(check.name) } } ?? all
        let done = check.map { check in all.filter { $0.isOn(check.name) } } ?? []
        let limit = showingAll ? Int.max : 30
        let working = state.lists.interpreting.contains(collection.name)
        VStack(alignment: .leading, spacing: 0) {
            header(collection, total: all.count, done: done.count)
            if working {
                WorkingRow(palette: palette)
                    .transition(.opacity)
            }
            // One sequence, so an entry checked off slides down to its new place.
            let lines = open.prefix(limit).map(Line.entry) + (done.isEmpty ? [] : [Line.doneHeading]) + done.prefix(limit).map(Line.entry)
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                switch line {
                case .entry(let record):
                    row(record, in: collection)
                    if index + 1 < lines.count, case .entry = lines[index + 1] {
                        Rectangle()
                            .fill(palette.edge)
                            .frame(height: 0.5)
                            .padding(.leading, check == nil ? 0 : 44)
                    }
                case .doneHeading:
                    HStack {
                        Text(check?.label ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { state.delete(done.map(\.id), from: collection, in: context.surface) }
                            .font(.subheadline)
                            .foregroundStyle(palette.accent)
                    }
                    .padding(.top, open.isEmpty ? 4 : 18)
                    .padding(.bottom, 2)
                }
            }
            if open.count > limit || done.count > limit {
                Button("Show all \(all.count)") { withAnimation(.smooth) { showingAll = true } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.vertical, 12)
            }
            if all.isEmpty && !working {
                Text("No \(collection.entries) yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 12)
            }
            if let undo = state.lists.undo, undo.collections.contains(collection.name) {
                UndoBar(undo: undo, state: state, palette: palette)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth, value: all)
        .animation(.smooth, value: state.lists)
        .animation(.smooth, value: editing)
        .panel(palette, enabled: depth == 0)
        .onChange(of: all.map(\.id)) { old, new in
            let added = Set(new).subtracting(old)
            guard !added.isEmpty, !old.isEmpty else { return }
            arrived = added
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.8)) { arrived = [] }
            }
        }
    }

    /// The list's name, and with a check, how far through it you are.
    @ViewBuilder private func header(_ collection: RecordCollection, total: Int, done: Int) -> some View {
        let showsTitle = depth == 0 || !block.title.isEmpty
        let counts = collection.checkField != nil && total > 0
        if showsTitle || counts {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if showsTitle {
                        Text(block.title.isEmpty ? collection.label : block.title)
                            .font(.display(.title3))
                    }
                    Spacer(minLength: 12)
                    if counts {
                        Text("\(done) of \(total)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(done)))
                    }
                }
                if counts {
                    ProgressTrack(fraction: Double(done) / Double(total), palette: palette)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func row(_ record: Record, in collection: RecordCollection) -> some View {
        RecordRow(
            record: record,
            collection: collection,
            context: context,
            isEditing: editing == record.id,
            isNew: arrived.contains(record.id),
            onTap: { editing = editing == record.id ? nil : record.id },
            onDelete: {
                if editing == record.id { editing = nil }
                state.delete([record.id], from: collection, in: context.surface)
            },
            onChangeList: context.onChange.map { onChange in { onChange(block) } },
            canReorder: !collection.isLog && editing == nil,
            dragging: $dragging,
            onMove: { id, target in state.move(id, to: target, in: collection) })
    }

    /// What the list shows, in order: entries, and the heading over the checked-off ones.
    private enum Line: Identifiable {
        case entry(Record)
        case doneHeading

        var id: String {
            switch self {
            case .entry(let record): record.id.uuidString
            case .doneHeading: "done"
            }
        }
    }
}

// MARK: - Rows

private struct RecordRow: View {
    let record: Record
    let collection: RecordCollection
    let context: RenderContext
    let isEditing: Bool
    let isNew: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onChangeList: (() -> Void)?
    let canReorder: Bool
    @Binding var dragging: UUID?
    let onMove: (UUID, UUID) -> Void

    @GestureState private var swipe: CGFloat = 0
    private let deleteDistance: CGFloat = 110

    private var palette: Palette { context.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .offset(x: swipe)
                .background(alignment: .trailing) { deleteReveal }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .simultaneousGesture(swipeGesture)
                // Holding an entry shows its menu; moving while held picks it up to reorder.
                .contextMenu {
                    Button(isEditing ? "Done editing" : "Edit", systemImage: "pencil", action: onTap)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    if let onChangeList {
                        Divider()
                        Button("Change this list…", systemImage: "wand.and.stars", action: onChangeList)
                    }
                }
                .reorderable(record.id, enabled: canReorder, dragging: $dragging, move: onMove)
                .sensoryFeedback(.impact(weight: .medium), trigger: swipe < -deleteDistance)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isDone ? .isSelected : [])
                .accessibilityAction(named: collection.checkField?.label ?? "Edit") { collection.checkField == nil ? onTap() : toggleCheck() }
                .accessibilityAction(named: "Edit", onTap)
                .accessibilityAction(named: "Delete", onDelete)
            if isEditing {
                RecordEditor(record: record, collection: collection, context: context, onDelete: onDelete, onDone: onTap)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(palette.accent.opacity(isNew ? 0.14 : 0))
                .padding(.horizontal, -8)
        }
    }

    private var isDone: Bool { collection.checkField.map { record.isOn($0.name) } ?? false }

    private func toggleCheck() {
        guard let check = collection.checkField else { return }
        context.state.set(check.name, to: .number(record.isOn(check.name) ? 0 : 1), of: record.id, in: collection.name)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            if let check = collection.checkField {
                CheckButton(isOn: record.isOn(check.name), label: check.label, palette: palette, action: toggleCheck)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(2)
                details
                chips
            }
            Spacer(minLength: 8)
            if let amount = collection.amountField, let value = record[amount.name] {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(amount.display(value))
                        .font(.display(.headline))
                        .monospacedDigit()
                        .foregroundStyle(isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.numberGradient))
                        .contentTransition(.numericText(value: value.numberValue ?? 0))
                    if amount.type == .number {
                        Text(amount.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 11)
    }

    private var title: String {
        guard let field = collection.titleField else { return "" }
        let text = field.display(record[field.name])
        return text.isEmpty ? "Untitled" : text
    }

    /// Everything but the name, the check and the amount, in one quiet line.
    private var detailFields: [RecordField] {
        collection.fields.filter { field in
            field.name != collection.titleField?.name && field.name != collection.amountField?.name
                && field.type != .done && record[field.name] != nil
        }
    }

    @ViewBuilder private var details: some View {
        let fields = detailFields
        if !fields.isEmpty {
            HStack(spacing: 8) {
                ForEach(fields, id: \.name) { field in
                    switch field.type {
                    case .choice:
                        Text(field.display(record[field.name]))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(palette.accent.opacity(0.12), in: .capsule)
                    case .rating:
                        Text(field.display(record[field.name]))
                            .font(.caption)
                            .foregroundStyle(palette.gradient)
                    case .number, .currency:
                        Text("\(field.label) \(field.display(record[field.name]))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    default:
                        Text(field.display(record[field.name]))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
        }
    }

    /// With several things to check off per entry (a day's habits), each is a chip.
    @ViewBuilder private var chips: some View {
        let done = collection.fields.filter { $0.type == .done }
        if collection.checkField == nil, !done.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(done, id: \.name) { field in
                    Chip(label: field.label, isOn: record.isOn(field.name), palette: palette) {
                        context.state.set(field.name, to: .number(record.isOn(field.name) ? 0 : 1), of: record.id, in: collection.name)
                    }
                }
            }
            .padding(.top, 3)
        }
    }

    /// Swiping left past a point deletes; the red behind the entry grows as it goes.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($swipe) { drag, swipe, _ in
                let (dx, dy) = (drag.translation.width, drag.translation.height)
                guard dx < 0, Swift.abs(dx) > Swift.abs(dy) * 1.5 else { return }
                swipe = dx
            }
            .onEnded { drag in
                let (dx, dy) = (drag.translation.width, drag.translation.height)
                if dx < -deleteDistance, Swift.abs(dx) > Swift.abs(dy) * 1.5 { onDelete() }
            }
    }

    private var deleteReveal: some View {
        let width = Swift.max(0, -swipe)
        return ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 14).fill(Color.red.gradient)
            Image(systemName: "trash.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .scaleEffect(width > deleteDistance ? 1.2 : 0.9)
                .padding(.trailing, 16)
        }
        .frame(width: width)
        .opacity(width > 0 ? 1 : 0)
        .animation(.snappy, value: width > deleteDistance)
    }
}

/// The round check at the start of an entry. It fills with the surface's colors when checked.
private struct CheckButton: View {
    let isOn: Bool
    let label: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(palette.accent.opacity(isOn ? 0 : 0.5), lineWidth: 1.5)
                if isOn {
                    Circle().fill(palette.gradient)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.25), value: isOn)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Checked" : "Not checked")
    }
}

private struct Chip: View {
    let label: String
    let isOn: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                }
                Text(label).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isOn ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(palette.accent.opacity(0.1)), in: .capsule)
            .contentShape(.capsule)
            .animation(.snappy(duration: 0.25), value: isOn)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
        .accessibilityValue(isOn ? "Checked" : "Not checked")
    }
}

/// How much of the list is checked off, as a thin bar that fills as you go.
private struct ProgressTrack: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.accent.opacity(0.14))
                Capsule()
                    .fill(palette.gradient)
                    .frame(width: Swift.max(fraction > 0 ? 6 : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(.smooth, value: fraction)
        .accessibilityHidden(true)
    }
}

/// Where entries being worked out will land.
private struct WorkingRow: View {
    let palette: Palette

    var body: some View {
        HStack(spacing: 12) {
            Circle().frame(width: 24, height: 24).padding(4)
            Capsule().frame(width: 150, height: 12)
        }
        .foregroundStyle(palette.accent.opacity(0.12))
        .shimmering()
        .padding(.vertical, 11)
        .accessibilityLabel("Working it out")
    }
}

/// What just changed, and a way to take it back, for a few seconds.
private struct UndoBar: View {
    let undo: RecordUndo
    let state: SurfaceState
    let palette: Palette

    var body: some View {
        HStack(spacing: 12) {
            Text(undo.message)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") { state.undoLastChange() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding(.top, 12)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(6))
            if state.lists.undo?.id == undo.id { state.lists.undo = nil }
        }
    }
}

// MARK: - Reordering

private extension View {
    /// Hold an entry and drag it over another to move it there; the list makes room as you go.
    @ViewBuilder func reorderable(_ id: UUID, enabled: Bool, dragging: Binding<UUID?>, move: @escaping (UUID, UUID) -> Void) -> some View {
        if enabled {
            onDrag {
                dragging.wrappedValue = id
                return NSItemProvider(object: id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: ReorderDrop(target: id, dragging: dragging, move: move))
        } else {
            self
        }
    }
}

private struct ReorderDrop: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
