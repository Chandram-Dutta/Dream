import SwiftUI

/// An entry in a list a connected service fills, like one of the user's open issues. It reads
/// like an entry the user keeps, but nothing here changes it: no check, edit, swipe or reorder,
/// since the entry is the service's and the next reading would put it back.
struct ServiceEntryRow: View {
    let record: Record
    let collection: RecordCollection
    let palette: Palette

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let check = collection.checkField {
                Image(systemName: record.isOn(check.name) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(record.isOn(check.name) ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(2)
                if !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let amount = collection.amountField, let value = record[amount.name] {
                Text(amount.display(value))
                    .font(.display(.headline))
                    .monospacedDigit()
                    .foregroundStyle(palette.numberGradient)
                    .contentTransition(.numericText(value: value.numberValue ?? 0))
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }

    private var isDone: Bool { collection.checkField.map { record.isOn($0.name) } ?? false }

    private var title: String {
        guard let field = collection.titleField else { return "" }
        let text = field.display(record[field.name])
        return text.isEmpty ? "Untitled" : text
    }

    /// Everything but the name, the check and the amount, in one quiet line.
    private var details: String {
        collection.fields
            .filter { $0.name != collection.titleField?.name && $0.name != collection.amountField?.name && $0.type != .done }
            .compactMap { field in
                let shown = field.display(record[field.name])
                guard !shown.isEmpty else { return nil }
                return field.type == .number || field.type == .currency ? "\(field.label) \(shown)" : shown
            }
            .joined(separator: " · ")
    }
}
