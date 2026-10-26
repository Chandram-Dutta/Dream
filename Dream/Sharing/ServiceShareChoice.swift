import SwiftUI

/// Said before a page that holds a connected service's data is shared, as a link or a picture:
/// which service, that what it gave is written into the page, and a choice to share it anyway.
/// What can go safely already has: its buttons for those services, and what Dream asked them.
struct ServiceShareChoice: View {
    let services: [String]
    let palette: Palette
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("This page shows what Dream read from \(names). It's written into the page, so whoever you share it with sees it, in a link or a picture.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline)
            Text("Dream leaves out its buttons for \(services.count == 1 ? "it" : "them") and what it asked, and nobody else's Dream reads \(services.count == 1 ? "it" : "them") for this page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Share what's from \(names)", isOn: $isOn)
                .font(.subheadline.weight(.semibold))
                .tint(palette.accent)
        }
        .panel(palette)
    }

    private var names: String {
        services.count <= 1 ? services.first ?? "a connected service" : services.dropLast().joined(separator: ", ") + " and " + services.last!
    }
}
