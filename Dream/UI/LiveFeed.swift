import SwiftUI

// Keeping live values current on screen (ROADMAP.md, workstream 7): read when the screen opens,
// again while it's open as each source's readings age, when Dream comes back to the front, and
// on a pull.

/// The live values on one screen: what each source last read, and how reading it went. The
/// values themselves go into `SurfaceState.values`, like the user's own, so everything that
/// draws or reads the calculation sees them.
struct LiveFeed: Equatable {
    var readings: [String: SourceReading] = [:]
    var failures: [String: LiveError] = [:]
    /// Sources being read right now.
    var reading: Set<String> = []
}

extension SurfaceState {
    /// Reads the surface's sources and puts each live input's value in place. A reading that's
    /// still fresh comes from the cache, so this is cheap to call often; `again` reads past it.
    func refreshLive(_ surface: Surface, again: Bool = false) async {
        let sources = surface.liveSources.filter { !live.reading.contains($0.name) }
        guard !sources.isEmpty else { return }
        live.reading.formUnion(sources.map(\.name))
        await withTaskGroup(of: (String, SourceReading?, LiveError?).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        return (source.name, try await LiveSources.read(source, again: again), nil)
                    } catch {
                        return (source.name, nil, error as? LiveError ?? LiveError(.unavailable, "It couldn't be updated."))
                    }
                }
            }
            for await (name, reading, failure) in group {
                live.reading.remove(name)
                live.failures[name] = failure
                guard let reading else { continue }
                live.readings[name] = reading
                // Values that moved roll to their new numbers, which is the only motion here.
                withAnimation(.smooth) {
                    for (input, value) in surface.liveValues(reading, from: name) where values[input] != value {
                        values[input] = value
                    }
                }
            }
        }
    }
}

extension View {
    /// Keeps a surface's live values current while it's on screen.
    func keepingLive(_ surface: Surface, state: SurfaceState) -> some View {
        modifier(KeepingLive(surface: surface, state: state))
    }

    /// Pull to read a surface's live values again. Only a screen that has them can be pulled.
    @ViewBuilder func refreshingLive(_ surface: Surface?, state: SurfaceState) -> some View {
        if let surface, !surface.liveSources.isEmpty {
            refreshable { await state.refreshLive(surface, again: true) }
        } else {
            self
        }
    }
}

private struct KeepingLive: ViewModifier {
    let surface: Surface
    let state: SurfaceState
    @Environment(\.scenePhase) private var scenePhase

    /// As often as the quickest-changing source goes stale, and never more than once a minute.
    private var interval: TimeInterval {
        let freshness = surface.liveSources.compactMap { LiveSources.provider($0.kind)?.freshness }
        return max(freshness.min() ?? 15 * 60, 60)
    }

    func body(content: Content) -> some View {
        content
            .task(id: surface) {
                guard !surface.liveSources.isEmpty else { return }
                while !Task.isCancelled {
                    await state.refreshLive(surface)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
            .onChange(of: scenePhase) {
                guard scenePhase == .active, !surface.liveSources.isEmpty else { return }
                Task { await state.refreshLive(surface) }
            }
    }
}
