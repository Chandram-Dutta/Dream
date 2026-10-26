import SwiftUI

/// An entry opened up in place: every field, each with the control that suits it. Changes land
/// as they're made, so totals move while you type.
struct RecordEditor: View {
    let record: Record
    let collection: RecordCollection
    let context: RenderContext
    let onDelete: () -> Void
    let onDone: () -> Void

    var body: some View {
        let palette = context.palette
        VStack(alignment: .leading, spacing: 0) {
            ForEach(collection.fields, id: \.name) { field in
                FieldEditor(field: field, value: binding(field), palette: palette, focusOnAppear: field.name == collection.titleField?.name && field.type == .text)
                    .padding(.vertical, 9)
                if field.name != collection.fields.last?.name {
                    Rectangle().fill(palette.edge).frame(height: 0.5)
                }
            }
            HStack {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Spacer()
                Button("Done", action: onDone)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(14)
        .background(palette.accent.opacity(0.07), in: .rect(cornerRadius: 18))
        .padding(.bottom, 10)
    }

    private func binding(_ field: RecordField) -> Binding<RecordValue?> {
        let state = context.state
        let (id, name) = (record.id, collection.name)
        return Binding(
            get: { state.record(id, in: name)?[field.name] },
            set: { state.set(field.name, to: $0, of: id, in: name) })
    }
}

/// One field, edited with what suits its type: text, a number pad, a date, a switch, a menu
/// of options, or stars.
private struct FieldEditor: View {
    let field: RecordField
    @Binding var value: RecordValue?
    let palette: Palette
    var focusOnAppear = false

    @State private var number = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(field.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            control
        }
        .onAppear {
            if focusOnAppear, value == nil { focused = true }
        }
    }

    @ViewBuilder private var control: some View {
        switch field.type {
        case .text:
            TextField(field.label, text: Binding(
                get: { value?.textValue ?? "" },
                set: { value = $0.isEmpty ? nil : .text($0) }))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .submitLabel(.done)
        case .number, .currency:
            HStack(spacing: 2) {
                if field.type == .currency {
                    Text(Currency.symbol).foregroundStyle(.secondary)
                }
                TextField("0", text: $number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focused)
                    .fixedSize()
            }
            .onAppear { number = value?.numberValue.map { $0 == $0.rounded() ? $0.plain : String(format: "%.2f", $0) } ?? "" }
            .onChange(of: number) { _, text in
                let parsed = RecordField.number(in: text).map { RecordValue.number($0) }
                if parsed != value { value = parsed }
            }
        case .date:
            DatePicker(field.label, selection: Binding(
                get: { value?.numberValue.map { Date(timeIntervalSince1970: $0) } ?? .now },
                set: { value = .number($0.timeIntervalSince1970) }), displayedComponents: .date)
                .labelsHidden()
                .tint(palette.accent)
        case .done:
            Toggle(field.label, isOn: Binding(
                get: { (value?.numberValue ?? 0) != 0 },
                set: { value = .number($0 ? 1 : 0) }))
                .labelsHidden()
                .tint(palette.accent)
        case .choice:
            Picker(field.label, selection: Binding(
                get: { value?.textValue ?? "" },
                set: { value = $0.isEmpty ? nil : .text($0) })) {
                Text("None").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(palette.accent)
        case .rating:
            Stars(value: Binding(
                get: { value?.numberValue.flatMap { $0.isFinite ? Int(Swift.min(Swift.max($0.rounded(), 0), 5)) : nil } ?? 0 },
                set: { value = $0 == 0 ? nil : .number(Double($0)) }), palette: palette)
        }
    }
}

/// Five stars; tap one to rate up to it, or tap the same one again to clear.
private struct Stars: View {
    @Binding var value: Int
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    value = value == star ? 0 : star
                } label: {
                    Image(systemName: star <= value ? "star.fill" : "star")
                        .font(.body)
                        .foregroundStyle(star <= value ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(value) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = Swift.min(value + 1, 5)
            case .decrement: value = Swift.max(value - 1, 0)
            @unknown default: break
            }
        }
    }
}
