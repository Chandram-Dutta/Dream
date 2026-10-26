import SwiftUI

/// The services Dream can use while it builds a page: add one by its address, sign in, see its
/// tools, and choose what each may be used for and what it may receive.
struct ConnectionsView: View {
    private let store = ConnectionStore.shared
    @State private var adding = false

    var body: some View {
        List {
            if !store.connections.isEmpty {
                Section {
                    ForEach(store.connections) { connection in
                        NavigationLink {
                            ConnectionDetailView(id: connection.id)
                        } label: {
                            ConnectionRow(connection: connection, status: store.status(of: connection.id))
                        }
                    }
                } footer: {
                    Text("While it builds a page, Dream's model can use tools that only read, like looking up your issues or a project's docs. Tools that change things are never run by the model.")
                }
            }
            Section {
                Button("Add a service", systemImage: "plus") { adding = true }
            }
        }
        .overlay {
            if store.connections.isEmpty {
                ContentUnavailableView {
                    Label("No services yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Connect a service that works with MCP, like Linear or Notion, and Dream can use what's in it when it builds a page.")
                } actions: {
                    Button("Add a service") { adding = true }
                }
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { AddConnectionView() }
        .task { await store.refreshUnchecked() }
        .refreshable { await store.refreshAll() }
    }
}

/// Opens Connections from home.
struct ConnectionsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Connections")
        .sheet(isPresented: $showing) {
            NavigationStack {
                ConnectionsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showing = false }
                        }
                    }
            }
        }
    }
}

// MARK: - A service

private struct ConnectionRow: View {
    let connection: Connection
    let status: ConnectionStore.Status

    var body: some View {
        HStack(spacing: 12) {
            Monogram(name: connection.name, isOn: connection.isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status == .needsSignIn || isFailed ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var detail: String {
        guard connection.isOn else { return "Off" }
        switch status {
        case .checking: return "Checking…"
        case .needsSignIn: return "Needs you to sign in"
        case .failed: return "Couldn't reach it"
        case .ready:
            let reading = connection.tools.filter { $0.isOn && $0.readsOnly }.count
            return "\(connection.host) · \(reading) of \(connection.tools.count) tools usable"
        }
    }
}

/// A service's initial, in a color of its own that stays the same.
private struct Monogram: View {
    let name: String
    let isOn: Bool

    var body: some View {
        let palette = accent.palette
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.display(.headline))
            .foregroundStyle(isOn ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(.tertiary))
            .frame(width: 36, height: 36)
            .background(isOn ? palette.wash : Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn ? palette.edge : .clear, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private var accent: Accent {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Accent.allCases[sum % Accent.allCases.count]
    }
}

private struct ConnectionDetailView: View {
    let id: UUID
    private let store = ConnectionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var confirmingRemoval = false

    var body: some View {
        if let connection = store.connection(id) {
            form(connection)
        } else {
            ContentUnavailableView("Removed", systemImage: "trash")
        }
    }

    private func form(_ connection: Connection) -> some View {
        let status = store.status(of: id)
        let signedIn = store.isSignedIn(id)
        return Form {
            Section {
                Toggle("Use with Dream", isOn: setting(\.isOn))
                if status == .needsSignIn {
                    Button("Sign in to \(connection.name)") { signIn() }
                } else if signedIn {
                    Button("Sign out") { Task { await store.signOut(id) } }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                StatusLine(status: status)
            } footer: {
                Text(connection.url.absoluteString)
                    .textSelection(.enabled)
            }
            Section {
                Toggle("What Dream knows about you", isOn: setting(\.mayReceiveMemory))
                Toggle("Entries in your lists", isOn: setting(\.mayReceiveLists))
            } header: {
                Text("It may receive")
            } footer: {
                Text("Off unless you turn them on. Then Dream won't send \(connection.name) the details it remembers about you, like your home city, or what's in your lists.")
            }
            Section {
                ForEach(connection.tools) { tool in
                    NavigationLink {
                        ToolDetailView(id: id, name: tool.name)
                    } label: {
                        ToolRow(tool: tool)
                    }
                }
                if connection.tools.isEmpty {
                    Text(status == .needsSignIn ? "Sign in to see its tools." : "It offers no tools.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("The model can use a tool while it builds a page only if the tool just reads. Ones that change things wait for a button you tap.")
            }
            Section {
                Button("Remove \(connection.name)", role: .destructive) { confirmingRemoval = true }
            }
        }
        .navigationTitle(connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(id) }
        .confirmationDialog("Remove \(connection.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await store.remove(id) }
                dismiss()
            }
        } message: {
            Text("Dream forgets it and its sign-in. Nothing changes in \(connection.name) itself.")
        }
    }

    private func setting(_ path: WritableKeyPath<Connection, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.connection(id)?[keyPath: path] ?? false },
            set: { value in store.update(id) { $0[keyPath: path] = value } })
    }

    private func signIn() {
        problem = nil
        Task {
            do {
                try await store.signIn(id, present: { try await WebSignIn.present($0) })
            } catch SignIn.Failure.cancelled {
                // They changed their mind.
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct StatusLine: View {
    let status: ConnectionStore.Status

    var body: some View {
        switch status {
        case .checking: Text("Checking…")
        case .ready: Text("Connected")
        case .needsSignIn: Text("Needs you to sign in")
        case .failed(let message): Text(message).textCase(nil)
        }
    }
}

// MARK: - A tool

private struct ToolRow: View {
    let tool: ConnectedTool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(tool.label)
                    .foregroundStyle(tool.isOn ? .primary : .secondary)
                Spacer(minLength: 8)
                EffectLabel(tool: tool)
            }
            if !tool.summary.isEmpty {
                Text(tool.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What a tool does, by its service's hints, or by the user's word when the service gives none.
private struct EffectLabel: View {
    let tool: ConnectedTool

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var text: String {
        if !tool.isOn { return "Off" }
        if tool.readOnlyHint == true { return "Reads" }
        if tool.readsOnly { return "Reads, you said" }
        if tool.readOnlyHint == nil { return "Might change things" }
        return tool.effect == .destroys ? "Can delete" : "Changes things"
    }

    private var symbol: String {
        if !tool.isOn { return "minus.circle" }
        switch tool.effect {
        case .reads: return "eye"
        case .changes: return "pencil"
        case .destroys: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        guard tool.isOn else { return .secondary }
        switch tool.effect {
        case .reads: return .secondary
        case .changes: return .blue
        case .destroys: return .orange
        }
    }
}

private struct ToolDetailView: View {
    let id: UUID
    let name: String
    private let store = ConnectionStore.shared

    var body: some View {
        if let connection = store.connection(id), let tool = connection.tools.first(where: { $0.name == name }) {
            Form {
                Section {
                    Text(tool.summary.isEmpty ? "\(connection.name) doesn't describe it." : tool.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                } header: {
                    HStack {
                        Text(tool.name).textCase(nil)
                        Spacer()
                        EffectLabel(tool: tool).textCase(nil)
                    }
                }
                Section {
                    Toggle("Use this tool", isOn: setting(\.isOn, of: tool))
                } footer: {
                    if !tool.isRepresentable {
                        Text("Dream can't fill in this tool's inputs yet, so the model never sees it.")
                    }
                }
                if tool.readOnlyHint == nil {
                    Section {
                        Toggle("It only reads", isOn: setting(\.userSaysReadsOnly, of: tool))
                    } footer: {
                        Text("\(connection.name) doesn't say whether this tool changes anything, so Dream treats it as one that might, and the model never runs it. Turn this on only if you're sure it just reads.")
                    }
                }
                let inputs = Self.inputs(of: tool)
                if !inputs.isEmpty {
                    Section("What it takes") {
                        ForEach(inputs, id: \.name) { input in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(input.name).font(.callout.monospaced())
                                if !input.about.isEmpty {
                                    Text(input.about).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(tool.label)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func setting(_ path: WritableKeyPath<ConnectedTool, Bool>, of tool: ConnectedTool) -> Binding<Bool> {
        Binding(
            get: { store.connection(id)?.tools.first { $0.name == tool.name }?[keyPath: path] ?? false },
            set: { value in store.updateTool(tool.name, of: id) { $0[keyPath: path] = value } })
    }

    private static func inputs(of tool: ConnectedTool) -> [(name: String, about: String)] {
        let required = Set((tool.inputSchema["required"]?.array ?? []).compactMap(\.string))
        return (tool.inputSchema["properties"]?.object ?? [:])
            .map { name, schema in (name, (required.contains(name) ? "Required. " : "") + (schema["description"]?.string ?? "")) }
            .sorted { required.contains($0.0) != required.contains($1.0) ? required.contains($0.0) : $0.0 < $1.0 }
    }
}

// MARK: - Adding

private struct AddConnectionView: View {
    private let store = ConnectionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var working = false
    @State private var problem: String?
    /// Added, but waiting for a sign-in.
    @State private var waiting: Connection?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mcp.example.com/mcp", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(connect)
                        .disabled(working || waiting != nil)
                } header: {
                    Text("Server address")
                } footer: {
                    Text("The address of a remote MCP server. Linear's is mcp.linear.app/mcp, and Notion's is mcp.notion.com/mcp.")
                }
                if let waiting {
                    Section {
                        Button("Sign in to \(waiting.name)", action: signIn)
                            .disabled(working)
                    } footer: {
                        Text("\(waiting.name) needs you to sign in. Dream keeps the sign-in in this iPhone's Keychain.")
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add a service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(waiting == nil ? "Cancel" : "Later") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if waiting == nil {
                        Button("Connect", action: connect)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func connect() {
        guard !working, waiting == nil, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                let connection = try await store.add(address)
                if store.status(of: connection.id) == .needsSignIn {
                    waiting = connection
                } else {
                    dismiss()
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func signIn() {
        guard let waiting else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await store.signIn(waiting.id, present: { try await WebSignIn.present($0) })
                dismiss()
            } catch SignIn.Failure.cancelled {
                // They can try again, or later from Connections.
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
