import SwiftData
import SwiftUI

/// On a page someone shared with the user: report it, or choose not to see pages from whoever
/// shared it again (App Store guideline 1.2). Reports don't say who sent them. Blocking is kept
/// with the user's account, so it needs them signed in; without that, the page can still go.
struct SharedPageMenu: View {
    let saved: SavedSurface
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<SavedSurface> { $0.sharedFrom != nil }) private var received: [SavedSurface]
    @State private var reporting = false
    @State private var blockAfterReport = false
    @State private var confirmingBlock = false
    @State private var failure: String?
    /// Blocked or removed: the page goes once the screen showing it has.
    @State private var removing = false

    private var link: SharedLink? { saved.sharedFrom.flatMap(SharedLink.init(address:)) }

    var body: some View {
        Menu("This shared page", systemImage: "flag") {
            Button("Report this page", systemImage: "flag") { reporting = true }
            Button("Don't show pages from this person", systemImage: "hand.raised") { confirmingBlock = true }
        }
        .disabled(link == nil)
        .sheet(isPresented: $reporting, onDismiss: {
            if blockAfterReport { confirmingBlock = true }
            blockAfterReport = false
        }) {
            if let link {
                ReportSheet(link: link, title: saved.surface.title, palette: saved.surface.palette) { blockAfterReport = true }
            }
        }
        .confirmationDialog(Session.isSignedIn ? "Don't show pages from this person?" : "Sign in to stop seeing someone's pages", isPresented: $confirmingBlock, titleVisibility: .visible) {
            if Session.isSignedIn {
                Button("Don't show their pages", role: .destructive) { Task { await block() } }
            } else {
                Button("Remove this page", role: .destructive) { remove() }
            }
        } message: {
            if Session.isSignedIn {
                Text("Dream removes this page, and any others you've opened from them, and their links won't open for you. You can undo this in Your shared links.")
            } else {
                Text("Dream remembers who you've blocked with your account. Without one, it can still remove this page.")
            }
        }
        .alert("Couldn't block them", isPresented: .init(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onDisappear {
            guard removing else { return }
            RecordStore.deleteAll(of: saved.id, in: context)
            context.delete(saved)
            try? context.save()
        }
    }

    /// Blocks the sharer, then removes their pages: the others now, this one as the screen closes.
    private func block() async {
        guard let link else { return }
        let opened = received.compactMap { $0.sharedFrom.flatMap(SharedLink.init(address:))?.id }
        do {
            let hidden = Set(try await ShareServer.block(sharerOf: link, opened: opened))
            for page in received where page.id != saved.id {
                guard let id = page.sharedFrom.flatMap(SharedLink.init(address:))?.id, hidden.contains(id) else { continue }
                RecordStore.deleteAll(of: page.id, in: context)
                context.delete(page)
            }
            try? context.save()
            remove()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() {
        removing = true
        dismiss()
    }
}

/// Reporting a shared page: what's wrong with it, and a note if the user wants. Afterwards it
/// offers to stop seeing pages from whoever shared it.
private struct ReportSheet: View {
    let link: SharedLink
    let title: String
    let palette: Palette
    let onBlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if sent {
                    thanks
                } else {
                    form
                }
            }
            .navigationTitle("Report this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if sending {
                            ProgressView()
                        } else {
                            Button("Send") { Task { await send() } }
                                .disabled(reason == nil)
                        }
                    }
                }
            }
            .animation(.smooth, value: sent)
        }
        .presentationDetents([.large])
    }

    private var form: some View {
        List {
            Section {
                ForEach(ReportReason.allCases) { option in
                    Button {
                        reason = option
                    } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                            if reason == option {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("What's wrong with “\(title)”?")
            }
            Section {
                TextField("Anything else we should know (optional)", text: $note, axis: .vertical)
                    .lineLimit(3...6)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reports don't say who sent them.")
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var thanks: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(palette.gradient)
                .symbolEffect(.bounce, value: sent)
            VStack(spacing: 6) {
                Text("Thanks for telling us")
                    .font(.display(.title3))
                Text("We'll look at this page, and take it down if it breaks Dream's rules.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                onBlock()
                dismiss()
            } label: {
                Label("Don't show pages from this person", systemImage: "hand.raised")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(palette.wash, in: .capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func send() async {
        guard let reason else { return }
        sending = true
        defer { sending = false }
        do {
            try await ShareServer.report(link, reason: reason, note: note)
            sent = true
        } catch {
            failure = error.localizedDescription
        }
    }
}
