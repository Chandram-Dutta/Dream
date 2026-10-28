import Foundation

let dims: [(String, Dimension)] = [
    ("mm", UnitLength.millimeters), ("cm", UnitLength.centimeters), ("m", UnitLength.meters), ("km", UnitLength.kilometers),
    ("in", UnitLength.inches), ("ft", UnitLength.feet), ("yd", UnitLength.yards), ("mi", UnitLength.miles),
    ("m/s", UnitSpeed.metersPerSecond), ("km/h", UnitSpeed.kilometersPerHour), ("mph", UnitSpeed.milesPerHour),
    ("g", UnitMass.grams), ("kg", UnitMass.kilograms), ("t", UnitMass.metricTons), ("oz", UnitMass.ounces), ("lb", UnitMass.pounds), ("ton", UnitMass.shortTons),
    ("°C", UnitTemperature.celsius), ("°F", UnitTemperature.fahrenheit),
    ("mL", UnitVolume.milliliters), ("L", UnitVolume.liters), ("m³", UnitVolume.cubicMeters),
    ("fl oz", UnitVolume.fluidOunces), ("cup", UnitVolume.cups), ("pt", UnitVolume.pints), ("qt", UnitVolume.quarts), ("gal", UnitVolume.gallons), ("ft³", UnitVolume.cubicFeet),
    ("cm²", UnitArea.squareCentimeters), ("m²", UnitArea.squareMeters), ("km²", UnitArea.squareKilometers), ("ha", UnitArea.hectares),
    ("in²", UnitArea.squareInches), ("ft²", UnitArea.squareFeet), ("mi²", UnitArea.squareMiles), ("ac", UnitArea.acres),
    ("L/100 km", UnitFuelEfficiency.litersPer100Kilometers), ("mpg", UnitFuelEfficiency.milesPerGallon),
    ("kPa", UnitPressure.kilopascals), ("bar", UnitPressure.bars), ("psi", UnitPressure.poundsForcePerSquareInch),
    ("imp gal", UnitVolume.imperialGallons), ("imp pt", UnitVolume.imperialPints), ("imp fl oz", UnitVolume.imperialFluidOunces),
    ("mpg (imp)", UnitFuelEfficiency.milesPerImperialGallon),
]
for (name, d) in dims {
    let c = d.converter
    let kind = c is UnitConverterLinear ? "linear" : "other"
    print(name, String(describing: type(of: d)), kind, String(c.baseUnitValue(fromValue: 1)), String(c.baseUnitValue(fromValue: 0)), String(c.baseUnitValue(fromValue: 2)))
}
print(Locale.commonISOCurrencyCodes.joined(separator: " "))
var numeric: [String] = []
for v in 0...0x10FFFF {
    guard let s = Unicode.Scalar(v) else { continue }
    if s.properties.numericType != nil {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: break
        default: numeric.append(String(format: "%X", v))
        }
    }
}
print("numeric non-N:", numeric.joined(separator: " "))
for c: Character in ["\u{093F}", "\u{094D}", "\u{0301}", "ª", "ː", "_", "٣", "一", "Ⅳ", "²"] {
    print(c.unicodeScalars.map { String(format: "%X", $0.value) }, c.isLetter, c.isNumber, c.isUppercase, c.isPunctuation, c.isSymbol)
}
print("é".count, "क्ष".count, "\r\n".count, Array("a\r\nb").count)
print(Double("5.") as Any, Double(".5") as Any, Double("1e5") as Any, Double("1.2.3") as Any, Double("01") as Any)
print("ﬁ".lowercased(), "İ".lowercased().unicodeScalars.count, "ΣΑΣ".lowercased())
print(["b", "B", "a", "_x", "Z", "é", "e\u{301}z"].sorted())
