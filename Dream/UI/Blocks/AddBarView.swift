import PhotosUI
import SwiftUI

/// A list's quick-add bar. Plain entries ("Milk", "Coffee 4.50", "milk, eggs, bread") are read
/// on the phone and land at once; a sentence, or a photo of a receipt or a handwritten list,
/// is worked out by a model. The keyboard stays up, so you can add one after another.
struct AddBarView: View {
    let block: Block
    let context: RenderContext
    let depth: Int

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    /// Counts what's been added here, for a tap of feedback each time.
    @State private var added = 0
    @FocusState private var focused: Bool

    private var palette: Palette { context.palette }

    var body: some View {
        if let collection = context.surface.collection(block.ref) {
            bar(collection)
        }
    }

    private func bar(_ collection: RecordCollection) -> some View {
        let working = context.state.lists.interpreting.contains(collection.name)
        // An entry named by its date, like a day's log, needs nothing typed.
        let needsText = collection.titleField?.type == .text
        let canAdd = !working && (!needsText || !text.trimmingCharacters(in: .whitespaces).isEmpty)
        return HStack(spacing: 10) {
            Button {
                add(to: collection)
            } label: {
                ZStack {
                    if working {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else {
                        Image(systemName: "plus")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(canAdd ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
                    }
                }
                .frame(width: 32, height: 32)
                .background(palette.accent.opacity(canAdd ? 0.16 : 0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("Add \(collection.anEntry)")
            TextField("Add \(collection.anEntry)", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit {
                    add(to: collection)
                    focused = true
                }
            if text.isEmpty {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "camera")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .disabled(working)
                .accessibilityLabel("Add from a photo")
                .transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(depth == 0 ? AnyShapeStyle(palette.wash) : AnyShapeStyle(Color(.systemBackground).opacity(0.7)), in: .capsule)
        .overlay {
            Capsule().strokeBorder(focused ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(palette.edge), lineWidth: focused ? 1.5 : 0.5)
        }
        .animation(.snappy, value: focused)
        .animation(.snappy, value: text.isEmpty)
        .sensoryFeedback(.impact(weight: .light), trigger: added)
        .onChange(of: photoItem) { _, item in
            Task { await addPhoto(item, to: collection) }
        }
    }

    private func add(to collection: RecordCollection) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (surface, state) = (context.surface, context.state)
        guard !typed.isEmpty else {
            if collection.titleField?.type != .text {
                state.change([.insert(collection: collection.name, values: [:])], in: surface, undoable: false)
                added += 1
            }
            return
        }
        text = ""
        added += 1
        let reading = QuickAdd.read(typed, for: collection)
        let local = reading.entries.map { RecordOperation.insert(collection: collection.name, values: $0) }
        if reading.isPlain {
            state.change(local, in: surface, undoable: local.count > 1)
            return
        }
        Task {
            guard await !RecordTalk.add(typed, to: collection, on: surface, state: state) else { return }
            // No model could read it: keep what the phone made of it, or give the words back.
            if local.isEmpty { text = typed } else { state.change(local, in: surface) }
        }
    }

    private func addPhoto(_ item: PhotosPickerItem?, to collection: RecordCollection) async {
        guard let item else { return }
        photoItem = nil
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data)?.downscaled(toFit: 1024).cgImage else { return }
        _ = await RecordTalk.add("", image: image, to: collection, on: context.surface, state: context.state)
    }
}
