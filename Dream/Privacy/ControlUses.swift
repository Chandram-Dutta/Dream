import SwiftUI

extension View {
    /// Counts how much a page's controls are used while it's open (Analytics.swift), and sends
    /// the count once when the page closes: how many times something was changed, and how many
    /// controls. Never the values. One drag of a slider is one change.
    func countingControlUses(_ values: [String: Double], of surface: Surface?, settled: Bool) -> some View {
        modifier(ControlUseCounter(values: values, adjustable: Set(surface?.adjustableInputs.map(\.name) ?? []), settled: settled))
    }
}

private struct ControlUseCounter: ViewModifier {
    let values: [String: Double]
    let adjustable: Set<String>
    /// While the page is being made or changed, values move on their own.
    let settled: Bool
    @State private var changes = 0
    @State private var controls: Set<String> = []
    @State private var lastChange = Date.distantPast

    /// Changes closer together than this are one gesture.
    private static let gesture: TimeInterval = 1

    func body(content: Content) -> some View {
        content
            .onChange(of: values) { old, new in
                guard settled else { return }
                let moved = adjustable.filter { old[$0] != new[$0] }
                guard !moved.isEmpty else { return }
                if Date.now.timeIntervalSince(lastChange) > Self.gesture { changes += 1 }
                lastChange = .now
                controls.formUnion(moved)
            }
            .onDisappear {
                if changes > 0 { Analytics.send(.controlsUsed(changes: changes, controls: controls.count)) }
                changes = 0
                controls = []
            }
    }
}
