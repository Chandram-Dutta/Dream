import AuthenticationServices
import SwiftData
import SwiftUI

/// On home: the account when signed in (its initial, in the colors of the moment), or a way to
/// sign in when not.
struct AccountButton: View {
    let palette: Palette
    private let account = Account.shared
    @State private var showing = false

    var body: some View {
        Group {
            if account.isSignedIn {
                Button { showing = true } label: {
                    Text(account.profile?.initial ?? "")
                        .font(.display(.subheadline, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(palette.gradient, in: .circle)
                        .overlay {
                            if account.profile?.initial == nil {
                                Image(systemName: "person.fill").font(.footnote).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Account")
            } else {
                Button("Sign in") { account.askToSignIn("Sign in to Dream") }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
        .sheet(isPresented: $showing) { AccountView() }
    }
}

extension Account.Profile {
    /// The first letter of their name, if Apple shared it.
    var initial: String? {
        name?.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
    }
}

/// The account: who's signed in, where, their data, signing out, and deleting it all.
struct AccountView: View {
    private let account = Account.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var devices: [AccountServer.Device] = []
    @State private var devicesFailed = false
    @State private var exporting = false
    @State private var exported: ExportedFile?
    @State private var confirmingSignOut = false
    @State private var signingOut = false
    @State private var failure: String?
    @State private var onPhone = LocalData.Summary()

    private let palette = Palette.now

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                email
                devicesSection
                if LocalData.move == .declined, !onPhone.isEmpty {
                    Section {
                        Button("Move this iPhone's things to your account", systemImage: "icloud.and.arrow.up") {
                            LocalData.requestMove()
                            onPhone = LocalData.Summary()
                        }
                    } footer: {
                        Text("You kept what was made before you signed in on this iPhone only.")
                    }
                }
                Section {
                    Button(action: export) {
                        HStack {
                            Label("Export my data", systemImage: "square.and.arrow.up")
                            Spacer()
                            if exporting { ProgressView() }
                        }
                    }
                    .disabled(exporting)
                } footer: {
                    Text("A file of everything Dream's server keeps for you, to save or send.")
                }
                Section {
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { confirmingSignOut = true }
                        .disabled(signingOut)
                }
                Section {
                    NavigationLink {
                        DeleteAccountView()
                    } label: {
                        Label("Delete my account", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if let since = account.profile?.createdAt {
                        Text("With Dream since \(since.formatted(.dateTime.month(.wide).year())).")
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out of Dream?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { signOut() }
            } message: {
                Text(signOutWarning)
            }
            .alert("Something went wrong", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .sheet(item: $exported, onDismiss: removeExport) { file in
                ActivitySheet(items: [file.url])
                    .presentationDetents([.medium, .large])
            }
        }
        .task {
            onPhone = LocalData.summary(in: context)
            await account.check(force: true)
            await loadDevices()
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn { dismiss() }
        }
    }

    // MARK: - Who

    private var header: some View {
        VStack(spacing: 12) {
            Text(account.profile?.initial ?? "")
                .font(.display(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(palette.gradient, in: .circle)
                .overlay {
                    if account.profile?.initial == nil {
                        Image(systemName: "person.fill").font(.title).foregroundStyle(.white)
                    }
                }
                .shadow(color: palette.accent.opacity(0.35), radius: 16, y: 6)
            Text(account.profile?.name ?? "Signed in with Apple")
                .font(.display(.title2, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Their email as Dream has it, saying plainly when Apple hides the real one.
    private var email: some View {
        Section {
            if let address = account.profile?.email {
                VStack(alignment: .leading, spacing: 4) {
                    Text(address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if account.profile?.isPrivateEmail == true {
                        Label("Hidden by Apple", systemImage: "eye.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
            } else {
                Text("No email shared")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Email")
        } footer: {
            if account.profile?.isPrivateEmail == true {
                Text("You chose Hide My Email, so Dream has an address Apple forwards to you, not your own.")
            } else if account.profile?.email == nil {
                Text("You chose not to share an email with Dream.")
            } else {
                Text("You shared this address when you signed in with Apple.")
            }
        }
    }

    // MARK: - Where

    private var devicesSection: some View {
        Section {
            if devices.isEmpty {
                HStack {
                    Text(devicesFailed ? "Couldn't load your devices." : "Loading…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if devicesFailed {
                        Button("Try again") { Task { await loadDevices() } }
                    } else {
                        ProgressView()
                    }
                }
            }
            ForEach(devices) { device in
                DeviceRow(device: device, palette: palette)
                    .swipeActions {
                        if !device.current {
                            Button("Sign out", role: .destructive) { signOut(device) }
                        }
                    }
                    .contextMenu {
                        if !device.current {
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signOut(device) }
                        }
                    }
            }
        } header: {
            Text("Signed in on")
        } footer: {
            Text("Swipe to sign a device out. It stops syncing the next time it opens Dream.")
        }
    }

    private func loadDevices() async {
        devicesFailed = false
        do {
            devices = try await AccountServer.devices()
        } catch {
            devicesFailed = true
        }
    }

    private func signOut(_ device: AccountServer.Device) {
        withAnimation { devices.removeAll { $0.id == device.id } }
        Task {
            do {
                try await AccountServer.signOut(device.id)
            } catch {
                failure = error.localizedDescription
                await loadDevices()
            }
        }
    }

    // MARK: - Signing out

    private var signOutWarning: String {
        var warning = "Your pages, lists and what Dream knows are removed from this iPhone, and the services you connected are disconnected. What's in your account comes back when you sign in again."
        if LocalData.move != .moved, LocalData.move != .requested, !onPhone.isEmpty {
            warning += " Things you kept on this iPhone only are deleted."
        }
        return warning
    }

    private func signOut() {
        signingOut = true
        Task {
            await account.signOut()
            signingOut = false
        }
    }

    // MARK: - Export

    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let data = try await AccountServer.export()
                let file = FileManager.default.temporaryDirectory.appending(path: "Dream data \(Date.now.formatted(.iso8601.year().month().day())).json")
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                exported = ExportedFile(url: file)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// The export holds personal data: it doesn't stay behind once it's shared or saved.
    private func removeExport() {
        let file = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: file.path())) ?? [] where name.hasPrefix("Dream data ") {
            try? FileManager.default.removeItem(at: file.appending(path: name))
        }
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct DeviceRow: View {
    let device: AccountServer.Device
    let palette: Palette

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(device.current ? AnyShapeStyle(palette.gradient) : AnyShapeStyle(Color.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.device ?? "A device")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(device.current ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Color.secondary))
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let since = "Signed in \(device.createdAt.formatted(.dateTime.day().month(.abbreviated)))"
        return device.current ? "This iPhone · \(since)" : "Used \(device.lastUsedAt.formatted(.relative(presentation: .named))) · \(since)"
    }
}

/// The share sheet, for a file.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Deleting

/// Deleting the account, said plainly: what goes, that it can't be undone, and a way to keep a
/// copy first. Apple then asks the person to confirm it's them, which also lets Dream ask Apple
/// to forget it.
struct DeleteAccountView: View {
    private let account = Account.shared
    @Environment(\.authorizationController) private var authorizationController
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Delete your account?")
                    .font(.display(.title2, weight: .bold))
                Text("This erases everything Dream keeps for you, on its server and on this iPhone:")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    item("square.grid.2x2", "Your pages, with their numbers, photos and history")
                    item("checklist", "Your lists and everything in them")
                    item("person.crop.circle", "What Dream knows about you")
                    item("iphone", "Your sign-in on every device")
                    item("apple.logo", "Dream's access to your Apple ID")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: .rect(cornerRadius: 24))
                Text("This can't be undone. To keep a copy, export your data first.")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: delete) {
                    HStack(spacing: 10) {
                        if deleting { ProgressView().tint(.white) }
                        Text(deleting ? "Deleting…" : "Delete my account")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.red, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(deleting)
                Text("Apple will ask you to confirm it's you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(deleting)
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(.red)
                .frame(width: 24)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func delete() {
        failure = nil
        Task {
            let code: String?
            do {
                code = try await AppleSignIn.confirm(with: authorizationController)
            } catch {
                return  // They didn't confirm: nothing is deleted.
            }
            deleting = true
            defer { deleting = false }
            do {
                let revoked = try await account.delete(authorizationCode: code)
                account.notice = revoked
                    ? "Your account and everything in it is deleted."
                    : "Your account and everything in it is deleted. You can also remove Dream from your Apple ID, in Settings under Sign in with Apple."
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
