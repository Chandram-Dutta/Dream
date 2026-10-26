import SwiftUI

// Beside live values (ROADMAP.md, workstream 7): what they're for, when they're from, and who
// they're from, which some providers' terms require wherever their data appears.

extension View {
    /// Under a top-level block that shows live values, one quiet line per source. Blocks in a
    /// row from the same source share one, under the last of them.
    @ViewBuilder func liveStamp(_ block: Block, context: RenderContext, depth: Int) -> some View {
        let sources = depth == 0 ? context.stampedSources(block) : []
        if sources.isEmpty {
            self
        } else {
            VStack(alignment: .leading, spacing: 10) {
                self
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sources, id: \.self) { LiveStamp(source: $0, context: context) }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

extension RenderContext {
    /// The sources a top-level block's stamp names: those it shows that the block after it
    /// doesn't also show.
    fileprivate func stampedSources(_ block: Block) -> [String] {
        let shown = surface.sources(shownBy: block)
        guard !shown.isEmpty else { return [] }
        let blocks = surface.displayBlocks
        // A row draws its blocks as if they were on the page; the row's own stamp covers them.
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return [] }
        guard index + 1 < blocks.count else { return shown }
        let next = Set(surface.sources(shownBy: blocks[index + 1]))
        return shown.filter { !next.contains($0) }
    }
}

/// One source's line: "Bengaluru, Saturday 31 October: Showers · As of 4:05 pm", its credit,
/// and what to do if it can't be read.
struct LiveStamp: View {
    let source: String
    let context: RenderContext

    var body: some View {
        let feed = context.state.live
        let reading = feed.readings[source]
        let failure = feed.failures[source]
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol = reading?.symbol, !symbol.isEmpty {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(context.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(status(reading, failure: failure, isReading: feed.reading.contains(source)))
                    .contentTransition(.opacity)
            }
            HStack(spacing: 10) {
                if let credit = reading?.credit { CreditView(credit: credit) }
                if reading?.isStandIn == true {
                    Text("Stand-in values, not real data").foregroundStyle(.orange)
                }
            }
            if failure?.reason == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow in Settings", destination: settings).fontWeight(.semibold)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .animation(.smooth, value: reading)
        .accessibilityElement(children: .combine)
    }

    private func status(_ reading: SourceReading?, failure: LiveError?, isReading: Bool) -> String {
        if let failure { return reading == nil ? failure.message : "\(failure.message) Showing what was read before." }
        guard let reading else { return isReading ? "Updating…" : "" }
        let time = reading.asOf.formatted(date: Calendar.current.isDateInToday(reading.asOf) ? .omitted : .abbreviated, time: .shortened)
        return "\(reading.summary) · As of \(time)"
    }
}

/// Who the values come from: the Apple Weather mark and its legal link, or a provider's link.
private struct CreditView: View {
    let credit: LiveCredit
    @Environment(\.colorScheme) private var colorScheme
    @State private var marks: WeatherCredit.Marks?

    var body: some View {
        switch credit {
        case .appleWeather:
            HStack(spacing: 8) {
                if let marks {
                    AsyncImage(url: colorScheme == .dark ? marks.dark : marks.light) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text("\u{F8FF} Weather")
                    }
                    .frame(height: 12)
                    .accessibilityLabel("Apple Weather")
                } else {
                    Text("\u{F8FF} Weather")
                }
                Link("Legal", destination: marks?.legal ?? WeatherCredit.legalPage).underline()
            }
            .task { marks = await WeatherCredit.marks() }
        case .link(let text, let url):
            if let destination = URL(string: url) {
                Link(text, destination: destination).underline()
            } else {
                Text(text)
            }
        }
    }
}
