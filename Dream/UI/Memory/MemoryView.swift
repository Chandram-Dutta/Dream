import SwiftData
import SwiftUI

/// What Dream knows about the user: every fact, where it came from, and the ones it noticed,
/// which wait here to be confirmed before they're used.
struct MemoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryFact.updatedAt, order: .reverse) private var facts: [MemoryFact]
    @State private var editing: MemoryFact?
    @State private var adding = false

    var body: some View {
        let noticed = facts.filter { !$0.isConfirmed }
        let known = facts.filter(\.isConfirmed)
        NavigationStack {
            List {
                if !noticed.isEmpty {
                    Section {
                        ForEach(noticed) { fact in
                            FactRow(fact: fact)
                                .swipeActions {
                                    Button("Forget", systemImage: "trash", role: .destructive) { forget(fact) }
                                    Button("Remember", systemImage: "checkmark") { Memory.confirm(fact, in: context) }
                                        .tint(.green)
                                }
                                .contextMenu { actions(for: fact) }
                        }
                    } header: {
                        Text("Is this right?")
                    } footer: {
                        Text("Dream noticed these in what you asked. It won't use them until you swipe to remember them.")
                    }
                }
                Section {
                    ForEach(known) { fact in
                        Button { editing = fact } label: { FactRow(fact: fact) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { forget(fact) }
                            }
                            .contextMenu { actions(for: fact) }
                    }
                    Button("Add something", systemImage: "plus") { adding = true }
                } footer: {
                    Text("\(Session.isSignedIn ? "Kept in your account, on each device you use." : "Kept on this iPhone.") With each request, Dream tells the model what it knows about, like your home city, and sends the detail only when the page needs it.")
                }
            }
            .overlay {
                if facts.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "person.crop.circle")
                    } description: {
                        Text("When you answer a question about yourself, or tell Dream something, it shows here.")
                    } actions: {
                        Button("Add something") { adding = true }
                    }
                }
            }
            .navigationTitle("What Dream knows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { FactEditor(fact: $0) }
            .sheet(isPresented: $adding) { FactEditor(fact: nil) }
        }
    }

    @ViewBuilder private func actions(for fact: MemoryFact) -> some View {
        if !fact.isConfirmed {
            Button("Remember", systemImage: "checkmark") { Memory.confirm(fact, in: context) }
        }
        Button("Edit", systemImage: "pencil") { editing = fact }
        Button("Forget", systemImage: "trash", role: .destructive) { forget(fact) }
    }

    private func forget(_ fact: MemoryFact) {
        context.delete(fact)
        try? context.save()
    }
}

private struct FactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fact.topic)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(fact.text)
            Text(provenance)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var provenance: String {
        let date = fact.createdAt.formatted(.dateTime.day().month(.abbreviated))
        let origin = switch fact.source {
        case .said: "You added this"
        case .answered: "You answered"
        case .inferred: fact.request.isEmpty ? "Dream noticed this" : "From “\(fact.request)”"
        }
        let used = fact.lastUsedAt.map { " · Used \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return "\(origin) · \(date)\(used)"
    }
}

/// Adds or changes one fact. Saving confirms it, since the user wrote it.
private struct FactEditor: View {
    let fact: MemoryFact?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("About, like Diet", text: $topic)
                        .focused($focused)
                    TextField("What Dream should know, like Vegetarian", text: $text, axis: .vertical)
                } footer: {
                    Text("The model sees what it's about with each request, and what it says only when the page needs it.")
                }
                if let fact {
                    Section {
                        Button("Forget this", role: .destructive) {
                            context.delete(fact)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(fact == nil ? "Add something" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(clean(topic).isEmpty || clean(text).isEmpty)
                }
            }
            .onAppear {
                topic = fact?.topic ?? ""
                text = fact?.text ?? ""
                if fact == nil { focused = true }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        if let fact {
            fact.topic = clean(topic)
            fact.text = clean(text)
            fact.updatedAt = .now
            Memory.confirm(fact, in: context)
        } else {
            Memory.remember(topic: clean(topic), text: clean(text), source: .said, in: context)
        }
        dismiss()
    }
}

/// After a request, something Dream noticed the user say about themselves in it, offered once
/// to remember. Until they say yes, it isn't used.
struct NoticedFacts: View {
    let palette: Palette
    @Environment(\.modelContext) private var context
    @Query private var noticed: [MemoryFact]

    init(request: String, palette: Palette) {
        self.palette = palette
        _noticed = Query(filter: #Predicate<MemoryFact> { $0.request == request && $0.isConfirmed == false }, sort: \.createdAt)
    }

    var body: some View {
        Group {
            if let fact = noticed.first {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember this about you?")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(fact.statement)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Remember") { Memory.confirm(fact, in: context) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(palette.accent, in: .capsule)
                    Button("Don't remember", systemImage: "xmark") {
                        context.delete(fact)
                        try? context.save()
                    }
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: noticed.first?.id)
    }
}
