import SwiftUI

// Units (ROADMAP.md, workstream 4): values on screen with their units, and controls that move in
// the reader's units while the formulas get the surface's own.

extension Text {
    /// A value with its unit set smaller, so the number leads: 9.81 m/s².
    init(reading: Reading, unitFont: Font) {
        if reading.unit.isEmpty {
            self.init(verbatim: reading.number)
        } else {
            self.init("\(reading.number)\(reading.attaches ? "" : "\u{202F}")\(Text(reading.unit).font(unitFont))")
        }
    }
}

@MainActor
extension RenderContext {
    /// An input's value in the reader's units, set back in the surface's for the formulas.
    func binding(_ input: Input) -> Binding<Double> {
        guard let unit = surface.shownUnit(input.name), unit.isConverted else { return state.binding(input) }
        let state = state
        return Binding(get: { unit.shown(state.value(input)) }, set: { state.values[input.name] = unit.stored($0) })
    }
}
