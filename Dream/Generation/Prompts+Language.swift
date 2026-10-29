import Foundation

// Language, locale and units (ROADMAP.md, workstream 4).

extension Prompts {
    /// How to write for the user's language and region, and how to give values units.
    static var languageRules: String {
        """
        Language and region:
        - Write every word the user reads in the language you're told: the title, summary, labels, options, every block's text and items, and the related topics. Names in formulas stay English camelCase, and maths stays LaTeX.
        - Follow the user's region: its currency, how it writes numbers and dates, and its everyday units. Starting values, ranges, steps, formulas and data values are plain numbers like 2400.5, whatever the region.
        Units:
        - Give an input or output a unit whenever it measures something physical or a span of time: m, km, m/s, km/h, s, min, h, kg, °C, L, kWh, years. Use the user's measurement system for everyday things like a trip, a recipe or the weather, and SI units for science and maths, everywhere.
        - The unit goes in unit, as its symbol, never in the label: label Distance, unit km; not Distance (km).
        - Money, percentages and counts take no unit: their format shows what they are. Money in another currency than the user's, like an amount to convert, has format currency and the currency's ISO code as its unit, like USD.
        - Formulas calculate in the units you give, so convert inside a formula when units differ, like speed / 3.6 for km/h in m/s.
        - {name} and \\val{name} show a value with its unit, so never write the unit after them.
        """
    }

    /// The language of the request, and the user's region, currency, measurement system and
    /// way of writing numbers. A page made on Dream's server is told where the user is too, when
    /// they've let Dream know: `place`, like Bengaluru, Karnataka, India. The phone's own loop
    /// reads where they are only for the sources that need it.
    static func languageContext(for intent: String, in place: String? = nil) -> [String] {
        let locale = Locale.current
        let english = Locale(identifier: "en")
        var lines: [String] = []
        if let language = Languages.of(request: intent) {
            let name = Languages.name(language.rawValue)
            lines.append("The request is in \(name), so write everything the user reads in \(name).")
        } else {
            lines.append("Write everything the user reads in the language of the request; if you can't tell, in \(Languages.name(Languages.primary)).")
        }
        var region: [String] = []
        if let code = locale.region?.identifier, let name = english.localizedString(forRegionCode: code) {
            region.append("The user's region: \(name).")
        }
        let currency = Currency.code
        region.append("Currency: \(english.localizedString(forCurrencyCode: currency) ?? currency) (\(currency), \(Currency.symbol)).")
        switch locale.measurementSystem {
        case .us: region.append("Everyday quantities are in US units: miles, mph, feet, pounds, °F and gallons.")
        case .uk: region.append("Everyday quantities are metric, except road distances and speeds, in miles and mph.")
        default: region.append("Everyday quantities are metric: km, km/h, kg, °C and litres.")
        }
        region.append(numberStyle(locale))
        lines.append(region.joined(separator: " "))
        if let place, !place.isEmpty {
            lines.append("The user is in \(place).")
        }
        return lines
    }

    /// How the region writes numbers, shown rather than described, since separators and
    /// grouping vary: 12,34,567.5 in India, 1.234.567,5 in Germany.
    private static func numberStyle(_ locale: Locale) -> String {
        let sample = 1_234_567.5.formatted(.number.locale(locale))
        let separator = locale.groupingSeparator ?? ","
        let groups = sample.split(separator: locale.decimalSeparator ?? ".").first?.components(separatedBy: separator) ?? []
        // Groups of two before the last three: lakh and crore.
        let lakh = groups.count > 2 && groups.dropFirst().dropLast().allSatisfy { $0.count == 2 }
        return "In text, write numbers the user's way, whatever the language: like \(sample)" + (lakh ? ", with large amounts in lakh (1,00,000) and crore (1,00,00,000)." : ".")
    }
}
