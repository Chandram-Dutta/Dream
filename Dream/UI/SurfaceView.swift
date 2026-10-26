import SwiftUI

/// The user's current numbers for a surface. Kept apart from the surface itself (see `SavedSurface`).
@MainActor @Observable
final class SurfaceState {
    var values: [String: Double] = [:]
    /// The user's entries in the surface's lists, by collection. Kept on the phone by
    /// `keepingRecords`, never in the template.
    var records: [String: [Record]] = [:]
    var lists = ListActivity()

    func value(_ input: Input) -> Double { values[input.name] ?? input.initial }

    func binding(_ input: Input) -> Binding<Double> {
        Binding(get: { self.value(input) }, set: { self.values[input.name] = $0 })
    }
}

struct RenderContext {
    let surface: Surface
    let evaluation: Evaluation
    let state: SurfaceState
    let focusedID: String?
    let onChange: ((Block) -> Void)?
    /// What's being read aloud, marked more gently than a change.
    var readingID: String? = nil

    var palette: Palette { surface.palette }
    var accent: Color { palette.accent }
    func value(_ name: String) -> Double? { evaluation.values[name] }
}

/// Renders a surface. Blocks keep their ids across updates, so they appear one by one as the
/// model writes them and animate into their new form when the surface changes.
struct SurfaceView: View {
    let surface: Surface
    let state: SurfaceState
    var photo: UIImage?
    /// What the model is doing right now, as a symbol beside the title.
    var stage: String?
    var focusedID: String?
    var readingID: String?
    var onChange: ((Block) -> Void)?
    var onExplore: ((String) -> Void)?
    /// A different answer to one of the questions asked before building.
    var onAnswer: ((Answer, String) -> Void)?
    /// Shows a surface written in a language the reader doesn't read in theirs (TranslationNote.swift).
    @State private var translation = SurfaceTranslation()

    var body: some View {
        let surface = translation.shown(self.surface)
        let context = RenderContext(surface: surface, evaluation: surface.evaluate(state.values, records: state.records), state: state, focusedID: focusedID, onChange: onChange, readingID: readingID)
        let blocks = surface.displayBlocks
        VStack(alignment: .leading, spacing: 26) {
            SurfaceHeader(surface: surface, stage: stage, onAnswer: onAnswer)
                .readingMark(readingID == Narration.headerID, palette: surface.palette)
            if translation.status != .none {
                TranslationNote(translation: translation, palette: surface.palette)
                    .padding(.top, -14)
            }
            SurfaceImage(photo: photo, url: surface.hasInformation ? surface.reference?.imageURL.flatMap { URL(string: $0) } : nil, palette: surface.palette)
            ForEach(blocks) { block in
                BlockView(block: block, context: context, depth: 0)
                    .transition(.blurReplace)
                    .id(block.id)
            }
            if !surface.related.isEmpty {
                RelatedTopics(topics: surface.related, palette: surface.palette, onExplore: onExplore)
                    .transition(.blurReplace)
            }
            SourceNote(reference: surface.reference, hasInformation: surface.hasInformation)
        }
        .animation(.smooth(duration: 0.5), value: blocks)
        .animation(.smooth(duration: 0.5), value: surface.related)
        .translating(self.surface, with: translation)
    }
}

private struct SurfaceHeader: View {
    let surface: Surface
    let stage: String?
    var onAnswer: ((Answer, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let stage {
                    StageMark(symbol: stage, palette: surface.palette)
                }
                Text(surface.title.isEmpty ? " " : surface.title)
                    .font(.display(.largeTitle))
                    .lineLimit(3)
            }
            if !surface.summary.isEmpty {
                RichText(text: surface.summary, style: .title3)
                    .font(.title3)
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
            }
            if let answers = surface.answers {
                AnswerTags(answers: answers, palette: surface.palette, onChange: onAnswer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .animation(.smooth, value: stage)
    }
}

/// What the model is doing, shown rather than said: the symbol changes with each step.
struct StageMark: View {
    let symbol: String
    let palette: Palette

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.semibold))
            .foregroundStyle(palette.gradient)
            .symbolEffect(.pulse, options: .repeating)
            .contentTransition(.symbolEffect(.replace))
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .accessibilityLabel(Self.description(of: symbol))
    }

    static func description(of symbol: String) -> String {
        switch symbol {
        case "book.pages": "Looking it up"
        case "wrench.adjustable": "Fixing the calculation"
        default: "Putting it together"
        }
    }
}

/// While nothing's arrived: the request itself, and shapes where the surface will land. If the
/// model has questions first, they take the shapes' place until they're answered.
struct FormingView: View {
    let intent: String
    let stage: String?
    let palette: Palette
    var asking: Asking?

    var body: some View {
        let isAsking = asking?.isWaiting ?? false
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Waiting on the user isn't working.
                if let stage, !isAsking {
                    StageMark(symbol: stage, palette: palette)
                }
                Text(intent)
                    .font(.display(.title))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .padding(.top, 12)
            if let asking, asking.isWaiting || !asking.answers.isEmpty {
                AskingView(asking: asking, palette: palette)
            }
            if !isAsking {
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().frame(height: 14).frame(maxWidth: .infinity)
                    Capsule().frame(width: 220, height: 14)
                }
                .foregroundStyle(palette.wash)
                .shimmering()
                .transition(.opacity)
                RoundedRectangle(cornerRadius: 28)
                    .fill(palette.wash)
                    .frame(height: 160)
                    .shimmering()
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: isAsking ? .contain : .combine)
        .animation(.smooth(duration: 0.5), value: isAsking)
    }
}

/// The user's own photo if they started from one, otherwise the article's image.
private struct SurfaceImage: View {
    let photo: UIImage?
    let url: URL?
    let palette: Palette

    var body: some View {
        if let photo {
            frame { Image(uiImage: photo).resizable().scaledToFill() }
        } else if let url {
            frame {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().background(.white).transition(.opacity)
                    } else {
                        palette.wash.shimmering()
                    }
                }
            }
        }
    }

    private func frame(@ViewBuilder _ content: () -> some View) -> some View {
        Color.clear
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .overlay { content() }
            .clipShape(.rect(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(palette.edge, lineWidth: 0.5))
    }
}

/// Where to go next. Each topic opens a new surface.
private struct RelatedTopics: View {
    let topics: [String]
    let palette: Palette
    let onExplore: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(topics, id: \.self) { topic in
                Button {
                    onExplore?(topic)
                } label: {
                    HStack(spacing: 5) {
                        Text(topic)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(palette.gradient)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(palette.wash, in: .capsule)
                    .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(onExplore == nil)
            }
        }
        .padding(.top, 4)
    }
}

private struct SourceNote: View {
    let reference: Reference?
    let hasInformation: Bool

    var body: some View {
        Group {
            if let reference, let url = URL(string: reference.url) {
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: url) {
                        Label("From Wikipedia: \(reference.title)", systemImage: "book.closed")
                    }
                    Text("Wikipedia text is available under CC BY-SA 4.0.")
                        .foregroundStyle(.tertiary)
                }
            } else if hasInformation {
                Label("Written without a source. Check anything important.", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }
}

/// Lays out views left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: arrangement.width, height: arrangement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in arrangement.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}
