import Foundation
let dims: [(String, Dimension)] = [
    ("km/h", UnitSpeed.kilometersPerHour), ("°C", UnitTemperature.celsius), ("°F", UnitTemperature.fahrenheit), ("mpg", UnitFuelEfficiency.milesPerGallon), ("mpg (imp)", UnitFuelEfficiency.milesPerImperialGallon), ("oz", UnitMass.ounces), ("ft²", UnitArea.squareFeet)
]
for (name, d) in dims {
    if let c = d.converter as? UnitConverterLinear {
        print(name, String(c.coefficient), String(c.constant))
    } else {
        print(name, type(of: d.converter), String(d.converter.baseUnitValue(fromValue: 1)), String(d.converter.value(fromBaseUnitValue: 10)))
    }
}
let f = UnitTemperature.fahrenheit.converter
print(String(f.value(fromBaseUnitValue: UnitTemperature.celsius.converter.baseUnitValue(fromValue: 21.5))))
print(String(UnitFuelEfficiency.milesPerGallon.converter.value(fromBaseUnitValue: UnitFuelEfficiency.litersPer100Kilometers.converter.baseUnitValue(fromValue: 7.2))))
