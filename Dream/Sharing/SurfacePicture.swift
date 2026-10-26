import SwiftUI

// A picture of a surface, for sharing where a link won't do (ROADMAP.md, workstream 9).
//
// ImageRenderer draws SwiftUI's own views (text, shapes, Canvas, Charts, mesh gradients) but not
// views UIKit provides, which come out blank or as placeholders, and it draws a single moment,
// so nothing that's still loading. So the picture:
// - draws wide maths shrunk to fit, since a scroll view comes out empty (MathView);
// - draws switches, menus and fields as still pictures of themselves (`StillControl`);
// - leaves out the quick-add bar, a text field with nothing to show;
// - fetches the article's image first, or leaves it out, rather than catching AsyncImage mid-load;
// - turns animations off, so charts that grow in are drawn grown.

extension EnvironmentValues {
    /// True while a surface is drawn as a still picture rather than on screen.
    @Entry var isPicture = false
}

/// A surface as one still image: the page as the reader would first see it, or with the user's
/// numbers, and a quiet line saying where it's from.
struct SurfacePicture: View {
    let surface: Surface
    let state: SurfaceState
    let image: UIImage?

    static let width: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Related topics are drawn as they look, not dimmed as they would be if disabled.
            SurfaceView(surface: surface, state: state, photo: image, onExplore: { _ in })
            HStack(spacing: 8) {
                Image(systemName: surface.symbolName)
                    .foregroundStyle(surface.palette.gradient)
                Text("Made with Dream")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .frame(width: Self.width, alignment: .topLeading)
        .background(alignment: .top) {
            Aura(palette: surface.palette, energy: 0)
                .frame(height: 620)
        }
        .background(Color(.systemBackground))
        .environment(\.isPicture, true)
        .transaction { $0.animation = nil }
    }
}

@MainActor
enum PictureMaker {
    /// The most pixels a picture may have, so a long page doesn't use hundreds of megabytes.
    private static let pixelBudget: CGFloat = 16_000_000

    /// Draws `surface` (the template, or with `values`) as an image, in the reader's appearance.
    static func picture(of surface: Surface, values: [String: Double], colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize) async -> UIImage? {
        var pictured = surface.shareable
        pictured.blocks = withoutAddBars(pictured.blocks)
        let image = await articleImage(pictured)
        if image == nil { pictured.reference?.imageURL = nil }
        let state = SurfaceState()
        state.values = values
        state.records = pictured.starterRecords
        let content = SurfacePicture(surface: pictured, state: state, image: image)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, min(dynamicTypeSize, .xxLarge))
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: SurfacePicture.width, height: nil)
        renderer.isOpaque = true
        // A first pass at 1x settles anything laid out from its own size, like a diagram, and
        // says how tall the page is; the second is drawn as sharp as the budget allows.
        renderer.scale = 1
        guard let draft = renderer.uiImage else { return nil }
        await Task.yield()
        let area = draft.size.width * draft.size.height
        renderer.scale = max(1, min(3, (pixelBudget / max(area, 1)).squareRoot()))
        return renderer.uiImage
    }

    private static func withoutAddBars(_ blocks: [Block]) -> [Block] {
        blocks.compactMap { block in
            guard block.kind != .add else { return nil }
            var block = block
            block.children = withoutAddBars(block.children)
            return block.kind.isContainer && block.children.isEmpty ? nil : block
        }
    }

    /// The image the page shows above its information, fetched before drawing. Nil if there's
    /// none, or it doesn't arrive in a few seconds.
    private static func articleImage(_ surface: Surface) async -> UIImage? {
        guard surface.hasInformation, let url = surface.reference?.imageURL.flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000 else { return nil }
        return UIImage(data: data)
    }
}

/// A control that ImageRenderer can't draw, drawn still at its value: a switch, a menu, a field.
/// Nil for controls drawn with SwiftUI's own shapes, which come out as they are.
struct StillControl: View {
    let kind: BlockKind
    let input: Input
    let context: RenderContext

    init?(kind: BlockKind, input: Input, context: RenderContext) {
        let isMenu = kind == .picker && !(input.options.count <= 3 && input.options.allSatisfy { $0.count <= 14 })
        guard kind == .toggle || kind == .field || isMenu else { return nil }
        self.kind = kind
        self.input = input
        self.context = context
    }

    var body: some View {
        let value = context.state.value(input)
        switch kind {
        case .toggle:
            HStack {
                Text(input.label)
                Spacer(minLength: 12)
                Capsule()
                    .fill(value != 0 ? AnyShapeStyle(context.accent) : AnyShapeStyle(Color(.systemFill)))
                    .frame(width: 51, height: 31)
                    .overlay(alignment: value != 0 ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .padding(2)
                    }
            }
        case .picker:
            HStack {
                Text(input.label).foregroundStyle(.secondary)
                Spacer()
                Text(context.surface.display(input.name, value))
                    .foregroundStyle(context.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(context.accent)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text(input.label).foregroundStyle(.secondary)
                Text(reading: context.surface.reading(input.name, value), unitFont: .display(.title3))
                    .font(.display(.title))
                    .monospacedDigit()
                    .foregroundStyle(context.palette.numberGradient)
                Capsule()
                    .fill(context.palette.edge)
                    .frame(height: 1)
            }
        }
    }
}
