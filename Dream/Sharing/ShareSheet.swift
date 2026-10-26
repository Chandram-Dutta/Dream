import SwiftUI

/// Shares the surface on screen.
struct ShareButton: View {
    let surface: Surface?
    let values: [String: Double]
    @State private var isSharing = false

    var body: some View {
        Button("Share", systemImage: "square.and.arrow.up") { isSharing = true }
            .sheet(isPresented: $isSharing) {
                if let surface {
                    ShareSheet(surface: surface, values: values)
                }
            }
    }
}

/// Sharing a surface: a link that opens in Dream (or on the web without it), or a picture.
/// What's shared is the template, so the person who opens it starts from the beginning. The
/// user's numbers go too only if they switch them on; their answers, list entries and photo never
/// do. The picture shows exactly what goes.
struct ShareSheet: View {
    let surface: Surface
    let values: [String: Double]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("shareServer") private var customServer = ""
    @State private var includesNumbers = false
    @State private var picture: UIImage?
    /// Links made while the sheet is open, with and without the user's numbers.
    @State private var links: [Bool: URL] = [:]
    @State private var isUploading = false
    @State private var failure: String?
    /// Whether the user chose to share what connected services gave the page. Until then a page
    /// that holds some can't go anywhere.
    @State private var sharesServices = false

    private var services: [String] { surface.services ?? [] }
    private var waitsForChoice: Bool { !services.isEmpty && !sharesServices }

    private var palette: Palette { surface.palette }
    private var shared: SharedSurface { SharedSurface(sharing: surface, values: includesNumbers ? values : nil) }
    /// Whether the user has changed any number, so there's something of theirs to include.
    private var hasOwnNumbers: Bool { SharedSurface(sharing: surface, values: values).values != nil }
    private var server: URL? {
        _ = customServer
        return ShareServer.base
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview
                    if hasOwnNumbers {
                        Toggle("Include my numbers", isOn: $includesNumbers)
                            .tint(palette.accent)
                            .panel(palette)
                    }
                    privacy
                    if !services.isEmpty {
                        ServiceShareChoice(services: services, palette: palette, isOn: $sharesServices)
                    }
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: includesNumbers) {
            failure = nil
            withAnimation(.smooth) { picture = nil }
            let image = await PictureMaker.picture(of: surface, values: includesNumbers ? values : [:], colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
            withAnimation(.smooth) { picture = image }
        }
    }

    /// The top of the picture, which is also what the link shows. A long page fades out below.
    private var preview: some View {
        Group {
            if let picture {
                let width: CGFloat = 230
                let height = width * picture.size.height / max(picture.size.width, 1)
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: min(height, 400), alignment: .top)
                    .clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: height > 400 ? 0.82 : 1), .init(color: .black.opacity(height > 400 ? 0 : 1), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(palette.edge, lineWidth: 0.5))
                    .shadow(color: palette.accent.opacity(0.18), radius: 18, y: 8)
                    .transition(.opacity)
                    .accessibilityLabel("A picture of \(surface.title)")
            } else {
                RoundedRectangle(cornerRadius: 22)
                    .fill(palette.wash)
                    .frame(width: 230, height: 400)
                    .shimmering()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(includesNumbers ? "Your numbers go with it." : "Shared blank: whoever opens it starts from the beginning.")
            Text("Your answers, list entries and photo stay on this iPhone.")
            let mentioned = surface.mentionedAnswers
            if !mentioned.isEmpty {
                Text("The page itself mentions \(mentioned.map { "“\($0)”" }.joined(separator: ", ")), from your answers.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var actions: some View {
        let title = surface.title
        VStack(spacing: 12) {
            if let url = links[includesNumbers] {
                ShareLink(item: url, subject: Text(title), preview: SharePreview(title, image: Image(uiImage: picture ?? UIImage()))) {
                    action("Share link", symbol: "link")
                }
                Text(url.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Button {
                    Task { await makeLink() }
                } label: {
                    action(isUploading ? "Making a link…" : "Make a link", symbol: "link", busy: isUploading)
                }
                .disabled(isUploading || server == nil || waitsForChoice)
            }
            if let picture, !waitsForChoice {
                ShareLink(item: Image(uiImage: picture), preview: SharePreview(title, image: Image(uiImage: picture))) {
                    action("Share picture", symbol: "photo", prominent: false)
                }
            } else {
                action("Share picture", symbol: "photo", prominent: false)
                    .opacity(0.5)
            }
            if server == nil {
                Text("Links need a sharing server. Set one in Under the hood.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: links)
        .animation(.smooth, value: isUploading)
    }

    private func action(_ title: String, symbol: String, prominent: Bool = true, busy: Bool = false) -> some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().tint(prominent ? .white : palette.accent)
            } else {
                Image(systemName: symbol)
            }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(palette.accent))
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background {
            if prominent {
                Capsule().fill(palette.gradient)
            } else {
                Capsule().fill(palette.wash)
            }
        }
        .contentShape(.capsule)
    }

    private func makeLink() async {
        guard let server else { return }
        let mode = includesNumbers
        isUploading = true
        failure = nil
        defer { isUploading = false }
        do {
            let link = try await ShareServer.upload(shared, to: server)
            links[mode] = link.url
        } catch {
            failure = error.localizedDescription
        }
    }
}
