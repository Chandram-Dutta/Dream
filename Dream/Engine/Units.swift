import Foundation

// Units (ROADMAP.md, workstream 4). A quantity's unit is shown beside every value of it.
// Formulas always calculate in the units the model chose. When a surface written for one
// measurement system is read in another, everyday quantities are shown in the reader's units
// instead: outputs are converted on the way out, and inputs both ways, so a slider moves in miles
// while its formula still gets kilometres.

/// A value as the reader sees it: the number, and its unit apart, so the unit can be set quieter.
struct Reading: Hashable {
    var number: String
    var unit = ""
    /// Written straight after the number, like 45° or 20°C.
    var attaches = false

    var text: String {
        unit.isEmpty ? number : number + (attaches ? "" : "\u{202F}") + unit
    }
}

/// How a quantity's unit reaches the reader: as written, or as the reader's own counterpart.
struct ShownUnit {
    /// What's written after the number.
    let symbol: String
    /// The surface's own unit and the reader's, when they differ.
    let conversion: (from: Dimension, to: Dimension)?

    var isConverted: Bool { conversion != nil }
    var attaches: Bool { symbol.hasPrefix("°") || symbol == "′" || symbol == "″" }

    /// From the surface's unit to the reader's.
    func shown(_ value: Double) -> Double {
        guard let conversion else { return value }
        return conversion.to.converter.value(fromBaseUnitValue: conversion.from.converter.baseUnitValue(fromValue: value))
    }

    /// From the reader's unit back to the surface's, for the formulas.
    func stored(_ value: Double) -> Double {
        guard let conversion else { return value }
        return conversion.from.converter.value(fromBaseUnitValue: conversion.to.converter.baseUnitValue(fromValue: value))
    }
}

extension Format {
    /// Only plain numbers and counts have units; money, percentages, toggles and choices show
    /// what they are through their format.
    var isMeasured: Bool { self == .number || self == .integer }
}

extension Surface {
    /// The unit a quantity is written in, or empty.
    func unit(of name: String) -> String {
        input(name)?.unit ?? output(name)?.unit ?? ""
    }

    /// The currency an amount is in when it isn't the user's own, like USD in a converter.
    func currency(of name: String) -> String? {
        let unit = unit(of: name)
        return Currency.isCode(unit) && unit != Currency.code ? unit : nil
    }

    /// How a quantity's unit reaches this reader. Nil when it has none.
    func shownUnit(_ name: String) -> ShownUnit? {
        let format = input(name)?.format ?? output(name)?.format ?? .number
        let unit = unit(of: name)
        guard !unit.isEmpty, format.isMeasured else { return nil }
        guard format == .number, let (symbol, conversion) = conversion(of: name, from: unit) else {
            return ShownUnit(symbol: unit, conversion: nil)
        }
        return ShownUnit(symbol: symbol, conversion: conversion)
    }

    /// When the surface was written for another measurement system, an everyday quantity's unit
    /// and the reader's counterpart. A quantity with a symbol belongs to equations, which
    /// calculate in the surface's own units, so it stays as written.
    private func conversion(of name: String, from unit: String) -> (String, (from: Dimension, to: Dimension))? {
        guard let locale, (input(name)?.symbol ?? output(name)?.symbol ?? "").isEmpty else { return nil }
        let written = Locale.MeasurementSystem(locale.measurementSystem)
        let reader = Locale.current.measurementSystem
        guard written != reader, let from = Units.dimension(unit, in: written),
              let (symbol, to) = Units.counterpart(of: unit, from: written, for: reader) else { return nil }
        return (symbol, (from, to))
    }

    /// Any value as the reader sees it, choices and missing values included.
    func reading(_ name: String, _ value: Double?) -> Reading {
        guard let value, value.isFinite, shownUnit(name) != nil else { return Reading(number: display(name, value)) }
        return reading(name, value)
    }

    /// A value, in the surface's own units, as the reader sees it.
    func reading(_ name: String, _ value: Double) -> Reading {
        let format = input(name)?.format ?? output(name)?.format ?? .number
        if format == .currency, let code = currency(of: name) { return Reading(number: Format.money(value, code: code)) }
        if format == .toggle, output(name) != nil { return Reading(number: value != 0 ? "Yes" : "No") }
        guard let unit = shownUnit(name) else { return Reading(number: format.display(value)) }
        let shown = unit.shown(value)
        let number = format.display(shown)
        return Units.span(shown, unit: unit.symbol, number: number) ?? Units.clock(shown, unit: unit.symbol)
            ?? Reading(number: number, unit: unit.symbol, attaches: unit.attaches)
    }

    /// A value already in the reader's units, as a chart's axis marks it: the number alone,
    /// since the axis title carries the unit.
    func tick(_ name: String, shown value: Double) -> String {
        (input(name)?.format ?? output(name)?.format ?? .number).display(value)
    }

    /// A label with the unit its values are shown in, for a chart's axis: Time (s).
    func axisTitle(_ name: String) -> String {
        guard let unit = shownUnit(name)?.symbol else { return label(of: name) }
        return "\(label(of: name)) (\(unit))"
    }

    /// A value in the reader's units, or the surface's own when nothing's converted.
    func shownValue(_ name: String, _ value: Double) -> Double {
        shownUnit(name)?.shown(value) ?? value
    }

    /// A value the reader set, in their units, back in the surface's for the formulas.
    func storedValue(_ name: String, _ value: Double) -> Double {
        shownUnit(name)?.stored(value) ?? value
    }

    /// An input as the reader sets it: its starting value, range and step in their units.
    func shown(_ input: Input) -> Input {
        guard let unit = shownUnit(input.name) else { return input }
        var shown = input
        shown.unit = unit.symbol
        guard unit.isConverted else { return shown }
        let ends = [unit.shown(input.min), unit.shown(input.max)]
        let (low, high) = (ends.min() ?? 0, ends.max() ?? 1)
        let steps = input.step > 0 ? Swift.max((input.max - input.min) / input.step, 1) : 100
        let step = Checker.niceStep((high - low) / steps)
        // Whole steps of the reader's unit, inside the range the formulas were written for.
        shown.min = (low / step - 1e-6).rounded(.up) * step
        shown.max = (high / step + 1e-6).rounded(.down) * step
        if shown.min >= shown.max { (shown.min, shown.max) = (low, high) }
        shown.step = step
        shown.initial = Swift.min(Swift.max(unit.shown(input.initial), shown.min), shown.max)
        return shown
    }

    /// An input's whole range in the reader's units, for a chart's axis.
    func shownRange(_ input: Input) -> ClosedRange<Double> {
        let range = input.safeRange
        let ends = [shownValue(input.name, range.lowerBound), shownValue(input.name, range.upperBound)]
        guard let low = ends.min(), let high = ends.max(), low < high else { return range }
        return low...high
    }

    /// A chart's points, in the reader's units.
    func shownSeries(of output: String, over inputName: String, given: [String: Double], records: [String: [Record]] = [:]) -> [ChartPoint] {
        guard shownUnit(output)?.isConverted == true || shownUnit(inputName)?.isConverted == true else {
            return series(of: output, over: inputName, given: given, records: records)
        }
        return series(of: output, over: inputName, given: given, records: records).map {
            ChartPoint(x: shownValue(inputName, $0.x), y: shownValue(output, $0.y))
        }
    }

    /// A value's unit in maths: always the surface's own, since equations calculate in it.
    func texUnit(_ name: String) -> String {
        guard (input(name)?.format ?? output(name)?.format ?? .number).isMeasured else { return "" }
        return TeX.unit(unit(of: name))
    }
}

extension TeX {
    /// A unit set upright after its number, as maths writes it: `9.81\,\mathrm{m/s}^{2}`, `45^{\circ}`.
    static func unit(_ unit: String) -> String {
        guard !unit.isEmpty else { return "" }
        let marks: Set<Character> = ["°", "µ", "μ", "·", "⋅", "%", "²", "³", "¹", "⁻", "⁰", "⁴"]
        // Words in other scripts are set as text; the maths font only has Latin letters.
        guard unit.allSatisfy({ $0.isASCII || marks.contains($0) }) else { return "\\text{ \(escaped(unit))}" }
        let powers: [Character: Character] = ["²": "2", "³": "3", "¹": "1", "⁻": "-", "⁰": "0", "⁴": "4"]
        var tex = ""
        var run = ""
        var power = ""
        func flush() {
            if !run.isEmpty { tex += "\\mathrm{\(run)}" }
            if !power.isEmpty { tex += "^{\(power)}" }
            (run, power) = ("", "")
        }
        for character in unit {
            if let digit = powers[character] {
                power.append(digit)
                continue
            }
            if !power.isEmpty { flush() }
            switch character {
            case "°": flush(); tex += "^{\\circ}"
            case "µ", "μ": flush(); tex += "\\mu "
            case " ": flush(); tex += "\\,"
            case "·", "⋅": flush(); tex += "\\cdot "
            case "%": flush(); tex += "\\%"
            case "{", "}", "\\", "$", "&", "#", "^", "_": break
            default: run.append(character)
            }
        }
        flush()
        return unit.hasPrefix("°") ? tex : "\\," + tex
    }
}

/// Recognising the units models write, and their counterparts in other measurement systems.
enum Units {
    /// A unit as Dream writes it: the model's spelling tidied, so "m/s^2" is m/s², "seconds"
    /// is s and "deg" is °.
    static func tidy(_ raw: String) -> String {
        var unit = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes write units as LaTeX.
        unit = unit.replacing(#/\\(?:mathrm|text|textrm|rm|mbox)\{([^{}]*)\}/#) { String($0.output.1) }
        for (written, symbol) in [("$", ""), ("\\,", " "), ("^{\\circ}", "°"), ("^\\circ", "°"), ("\\circ", "°"), ("\\mu", "µ"), ("\\cdot", "·"),
                                  ("^{2}", "²"), ("^2", "²"), ("^{3}", "³"), ("^3", "³"), ("^{-1}", "⁻¹"), ("^-1", "⁻¹"), ("℃", "°C"), ("℉", "°F")] {
            unit = unit.replacingOccurrences(of: written, with: symbol)
        }
        unit = unit.trimmingCharacters(in: .whitespaces)
        return words[unit.lowercased()] ?? unit
    }

    /// Whether text reads as a unit: one with a counterpart elsewhere, a span of time, or a
    /// common symbol.
    static func isUnit(_ text: String) -> Bool {
        let unit = tidy(text)
        return dimensions[unit] != nil || calendar[unit] != nil || symbols.contains(unit)
    }

    /// The unit as a Foundation dimension, for converting. The UK's gallons and pints are
    /// imperial ones.
    static func dimension(_ unit: String, in system: Locale.MeasurementSystem) -> Dimension? {
        if system == .uk, let imperial = imperial[unit] { return imperial }
        return dimensions[unit]
    }

    /// The reader's counterpart of a unit, for an everyday quantity: its symbol and dimension.
    /// Nil when the unit is already the reader's kind, or has no counterpart, like seconds.
    static func counterpart(of unit: String, from written: Locale.MeasurementSystem, for reader: Locale.MeasurementSystem) -> (String, Dimension)? {
        let target: String?
        switch reader {
        case .us: target = toCustomary[unit]
        case .uk: target = metric.contains(unit) ? toUKFromMetric[unit] : toUKFromCustomary[unit]
        default: target = toMetric[unit]
        }
        guard let target else { return nil }
        if target == "mpg (imp)" { return ("mpg", UnitFuelEfficiency.milesPerImperialGallon) }
        return dimension(target, in: reader).map { (target, $0) }
    }

    /// A whole number of days, weeks, months or years, in the reader's words: 1 year, 30 years.
    static func span(_ value: Double, unit: String, number: String) -> Reading? {
        guard let (component, allowed) = calendar[unit], value == value.rounded(), Swift.abs(value) < 100_000 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = allowed
        var components = DateComponents()
        components.setValue(Int(value), for: component)
        guard let words = formatter.string(from: components) else { return nil }
        // Keep Dream's own number, and set the word apart from it.
        let digits = words.prefix { $0.isNumber || ",.'٬\u{00A0}\u{202F}".contains($0) }
        guard !digits.isEmpty else { return Reading(number: words) }
        let rest = words.dropFirst(digits.count)
        return Reading(number: number, unit: rest.trimmingCharacters(in: .whitespaces), attaches: !(rest.first?.isWhitespace ?? true))
    }

    /// Text after a live value with its unit taken off the front: " m away" → " away". Nil when
    /// it doesn't start with the unit.
    static func dropping(_ unit: String, from text: String) -> String? {
        // "in" is also a word, so "{height} in total" keeps it.
        guard unit != "in" else { return nil }
        let start = text.prefix { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" }.count
        let rest = text.dropFirst(start)
        let tokens = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        for count in [2, 1] where tokens.count >= count {
            let candidate = tokens.prefix(count).joined(separator: " ")
            let word = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
            guard !word.isEmpty, tidy(word) == unit else { continue }
            return String(rest.dropFirst(word.count))
        }
        return nil
    }

    // MARK: - Tables

    /// Words and other spellings models use, by the symbol Dream writes. Keys are lowercase.
    private static let words: [String: String] = [
        "second": "s", "seconds": "s", "sec": "s", "secs": "s", "minute": "min", "minutes": "min", "mins": "min",
        "hour": "h", "hours": "h", "hr": "h", "hrs": "h",
        "day": "days", "days": "days", "week": "weeks", "weeks": "weeks", "wk": "weeks", "wks": "weeks",
        "month": "months", "months": "months", "mo": "months", "mos": "months", "year": "years", "years": "years", "yr": "years", "yrs": "years",
        "metre": "m", "metres": "m", "meter": "m", "meters": "m", "kilometre": "km", "kilometres": "km", "kilometer": "km", "kilometers": "km",
        "centimetre": "cm", "centimetres": "cm", "centimeter": "cm", "centimeters": "cm", "millimetre": "mm", "millimetres": "mm",
        "millimeter": "mm", "millimeters": "mm", "km": "km", "cm": "cm", "mm": "mm",
        "mile": "mi", "miles": "mi", "foot": "ft", "feet": "ft", "inch": "in", "inches": "in", "yard": "yd", "yards": "yd",
        "kmph": "km/h", "kph": "km/h", "km/hr": "km/h", "kmh": "km/h", "km/h": "km/h", "mph": "mph", "mi/h": "mph", "m/s": "m/s",
        "knot": "kn", "knots": "kn", "kt": "kn",
        "gram": "g", "grams": "g", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg", "kg": "kg", "kgs": "kg",
        "tonne": "t", "tonnes": "t", "pound": "lb", "pounds": "lb", "lbs": "lb", "ounce": "oz", "ounces": "oz",
        "l": "L", "litre": "L", "litres": "L", "liter": "L", "liters": "L", "ml": "mL", "millilitre": "mL", "millilitres": "mL",
        "milliliter": "mL", "milliliters": "mL", "gallon": "gal", "gallons": "gal", "cups": "cup", "fl. oz": "fl oz", "fl.oz": "fl oz",
        "°c": "°C", "deg c": "°C", "degc": "°C", "celsius": "°C", "degrees celsius": "°C", "°f": "°F", "deg f": "°F", "degf": "°F",
        "fahrenheit": "°F", "degrees fahrenheit": "°F", "kelvin": "K", "deg": "°", "degree": "°", "degrees": "°", "rad": "rad", "radians": "rad",
        "sq m": "m²", "sq. m": "m²", "square metres": "m²", "square meters": "m²", "sq km": "km²", "sq ft": "ft²", "sq. ft": "ft²",
        "square feet": "ft²", "sq mi": "mi²", "acre": "ac", "acres": "ac", "hectare": "ha", "hectares": "ha",
        "l/100km": "L/100 km", "l/100 km": "L/100 km", "km/l": "km/L", "kpa": "kPa", "kwh": "kWh", "kw": "kW", "kj": "kJ",
        "hz": "Hz", "khz": "kHz", "mhz": "MHz",
    ]

    /// Spans of time a calendar counts, which read as words: 30 years.
    static let calendar: [String: (Calendar.Component, NSCalendar.Unit)] = [
        "days": (.day, .day), "weeks": (.weekOfMonth, .weekOfMonth), "months": (.month, .month), "years": (.year, .year),
    ]

    /// Common symbols with no counterpart elsewhere, recognised so they can leave a label.
    private static let symbols: Set<String> = [
        "s", "ms", "µs", "ns", "min", "h", "K", "J", "kJ", "MJ", "cal", "kcal", "Wh", "kWh", "MWh", "W", "kW", "MW", "GW",
        "Hz", "kHz", "MHz", "GHz", "N", "kN", "Pa", "hPa", "MPa", "atm", "mmHg", "V", "mV", "kV", "A", "mA", "Ω", "kΩ",
        "mol", "rad", "°", "m/s²", "km/s", "dB", "lx", "lm", "B", "kB", "MB", "GB", "TB", "bpm", "rpm", "AU", "ly", "eV",
        "nm", "µm", "mg", "µg", "kn", "km/L", "Mbps", "kg/m³", "g/cm³", "N·m", "m³/s",
    ]

    private static let feetPerSecond = UnitSpeed(symbol: "ft/s", converter: UnitConverterLinear(coefficient: 0.3048))

    private static let dimensions: [String: Dimension] = [
        "mm": UnitLength.millimeters, "cm": UnitLength.centimeters, "m": UnitLength.meters, "km": UnitLength.kilometers,
        "in": UnitLength.inches, "ft": UnitLength.feet, "yd": UnitLength.yards, "mi": UnitLength.miles,
        "m/s": UnitSpeed.metersPerSecond, "km/h": UnitSpeed.kilometersPerHour, "mph": UnitSpeed.milesPerHour, "ft/s": feetPerSecond,
        "g": UnitMass.grams, "kg": UnitMass.kilograms, "t": UnitMass.metricTons, "oz": UnitMass.ounces, "lb": UnitMass.pounds, "ton": UnitMass.shortTons,
        "°C": UnitTemperature.celsius, "°F": UnitTemperature.fahrenheit,
        "mL": UnitVolume.milliliters, "L": UnitVolume.liters, "m³": UnitVolume.cubicMeters,
        "fl oz": UnitVolume.fluidOunces, "cup": UnitVolume.cups, "pt": UnitVolume.pints, "qt": UnitVolume.quarts, "gal": UnitVolume.gallons, "ft³": UnitVolume.cubicFeet,
        "cm²": UnitArea.squareCentimeters, "m²": UnitArea.squareMeters, "km²": UnitArea.squareKilometers, "ha": UnitArea.hectares,
        "in²": UnitArea.squareInches, "ft²": UnitArea.squareFeet, "mi²": UnitArea.squareMiles, "ac": UnitArea.acres,
        "L/100 km": UnitFuelEfficiency.litersPer100Kilometers, "mpg": UnitFuelEfficiency.milesPerGallon,
        "kPa": UnitPressure.kilopascals, "bar": UnitPressure.bars, "psi": UnitPressure.poundsForcePerSquareInch,
    ]

    private static let imperial: [String: Dimension] = [
        "gal": UnitVolume.imperialGallons, "pt": UnitVolume.imperialPints, "fl oz": UnitVolume.imperialFluidOunces,
        "mpg": UnitFuelEfficiency.milesPerImperialGallon,
    ]

    private static let metric: Set<String> = ["mm", "cm", "m", "km", "m/s", "km/h", "g", "kg", "t", "°C", "mL", "L", "m³", "cm²", "m²", "km²", "ha", "L/100 km", "kPa", "bar"]

    private static let toCustomary: [String: String] = [
        "mm": "in", "cm": "in", "m": "ft", "km": "mi", "m/s": "mph", "km/h": "mph", "g": "oz", "kg": "lb", "t": "ton", "°C": "°F",
        "mL": "fl oz", "L": "gal", "m³": "ft³", "cm²": "in²", "m²": "ft²", "km²": "mi²", "ha": "ac", "L/100 km": "mpg", "kPa": "psi", "bar": "psi",
    ]

    private static let toMetric: [String: String] = [
        "in": "cm", "ft": "m", "yd": "m", "mi": "km", "mph": "km/h", "ft/s": "m/s", "oz": "g", "lb": "kg", "ton": "t", "°F": "°C",
        "fl oz": "mL", "cup": "mL", "pt": "mL", "qt": "L", "gal": "L", "ft³": "m³", "in²": "cm²", "ft²": "m²", "mi²": "km²", "ac": "ha",
        "mpg": "L/100 km", "psi": "kPa",
    ]

    /// The UK drives in miles but otherwise measures much as the metric world does.
    private static let toUKFromMetric: [String: String] = ["km": "mi", "km/h": "mph", "m/s": "mph", "L/100 km": "mpg (imp)"]

    private static let toUKFromCustomary: [String: String] = [
        "oz": "g", "lb": "kg", "ton": "t", "°F": "°C", "fl oz": "mL", "cup": "mL", "pt": "mL", "qt": "L", "gal": "L", "ft³": "m³",
        "in²": "cm²", "ft²": "m²", "mpg": "mpg (imp)",
    ]
}
