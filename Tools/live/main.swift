import Foundation

// Checks sources, live inputs and actions without the app: days and times, unit conversion, the
// checker's bindings, actions worked out at the screen's values, and the live tool against real
// exchange rates and MapKit (weather stands in, since WeatherKit won't authorize here). Build and
// run with Tools/live.sh. It makes a few network requests, and none to a model.

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures += 1 }
}

func near(_ a: Double?, _ b: Double, within tolerance: Double = 1e-6) -> Bool { a.map { Swift.abs($0 - b) <= tolerance } ?? false }

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
// Monday 26 October 2026, 3 pm in Bengaluru.
let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15))!
func day(_ text: String) -> Int? {
    LiveDay.date(text, now: now, calendar: calendar).map { calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0).day ?? -1 }
}

print("Days and times")
expect(day("today") == 0, "today is today")
expect(day("tomorrow") == 1, "tomorrow")
expect(day("saturday") == 5, "saturday is the coming one")
expect(day("this Saturday") == 5, "this Saturday")
expect(day("sat") == 5, "sat")
expect(day("monday") == 0, "monday, on a Monday, is today")
expect(day("weekend") == 5, "the weekend starts on Saturday")
expect(day("in 3 days") == 3, "in 3 days")
expect(day("2026-11-02") == 7, "a date")
expect(day("someday") == nil, "not a day")
expect(LiveDay.minutes("16:00") == 960, "16:00")
expect(LiveDay.minutes("4 pm") == 960, "4 pm")
expect(LiveDay.minutes("4:30pm") == 990, "4:30pm")
expect(LiveDay.minutes("12 am") == 0, "12 am")
expect(LiveDay.minutes("noon") == 720, "noon")
expect(LiveDay.minutes("25:00") == nil, "25:00 isn't a time")
expect(LiveDay.minutes("startHour") == nil, "a name isn't a time")

print("Units")
expect(near(LiveUnits.convert(20, from: "°C", to: "°F"), 68), "20 °C is 68 °F")
expect(near(LiveUnits.convert(90, from: "min", to: "h"), 1.5), "90 min is 1.5 h")
expect(near(LiveUnits.convert(10, from: "km", to: "mi"), 6.2137, within: 1e-3), "10 km in miles")
expect(LiveUnits.convert(10, from: "km", to: "°C") == nil, "km don't convert to °C")

print("Checking live inputs")
let weather = Source(name: "weather", kind: "weather", parameters: ["place": "Bengaluru", "day": "saturday"], fields: [
    SourceField(name: "high", value: 29, unit: "°C", format: .number, meaning: "the day's highest temperature"),
    SourceField(name: "rainChance", value: 70, format: .percent, meaning: "the chance of rain during the day"),
])
let rate = Source(name: "rate", kind: "exchangeRate", parameters: ["from": "USD", "to": "INR"], fields: [
    SourceField(name: "rate", value: 94.5, format: .number, meaning: "how many INR one USD buys"),
])
func input(_ name: String, role: InputRole, source: String = "", format: Format = .number, initial: Double = 0, unit: String = "") -> Input {
    Input(name: name, label: Checker.words(name), format: format, initial: initial, min: 0, max: 100, step: 1, options: [], role: role, unit: unit, source: source)
}

var umbrella = Surface(title: "Umbrella", summary: "", symbol: "umbrella", accent: .blue,
                       inputs: [input("rainChance", role: .live, source: "weather.rainchance", initial: 12), input("high", role: .live, source: "weather.high", unit: "°F")],
                       outputs: [], blocks: [Block(id: "a", kind: .hero, ref: "rainChance"), Block(id: "b", kind: .slider, ref: "high")],
                       related: [], reference: nil)
umbrella.sources = [weather, rate]
let umbrellaIssues = Checker.checkLogic(&umbrella)
expect(!umbrellaIssues.contains { $0.kind == .needsModel }, "live values need no results: \(umbrellaIssues)")
expect(umbrella.input("rainChance")?.source == "weather.rainChance", "a near-miss binding is read as the field")
expect(umbrella.input("rainChance")?.format == .percent, "a chance shows as a percentage")
expect(umbrella.input("rainChance")?.initial == 70, "the model's number is replaced by the field's")
expect(near(umbrella.input("high")?.initial, 84.2), "a field converts into the input's unit")
let blockIssues = Checker.checkBlocks(&umbrella)
expect(umbrella.blocks.first { $0.ref == "rainChance" }?.kind == .hero, "a live value can be the hero")
expect(umbrella.blocks.first { $0.ref == "high" }?.kind == .metric, "a live value's control becomes a metric")
expect(umbrella.sources?.map(\.name) == ["weather"], "a source nothing shows is dropped: \(blockIssues)")

var unbound = Surface(title: "Rain", summary: "", symbol: "cloud", accent: .blue,
                      inputs: [input("rain", role: .live, source: "forecast.rain")], outputs: [], blocks: [], related: [], reference: nil)
expect(Checker.checkLogic(&unbound).contains { $0.kind == .needsModel }, "a live input with nothing fetched goes back to the model")
unbound.sources = [rate]
expect(Checker.checkLogic(&unbound).contains { $0.kind == .needsModel && $0.message.contains("rate.rate") }, "an unknown field goes back with the ones there are")

var converter = Surface(title: "Dollars", summary: "", symbol: "dollarsign", accent: .green,
                        inputs: [input("amount", role: .adjustable, format: .currency, initial: 100, unit: "usd"),
                                 input("exchangeRate", role: .live, source: "rate"),
                                 input("whatIfRate", role: .adjustable, source: "rate.rate", initial: 80)],
                        outputs: [Output(name: "inRupees", label: "In rupees", formula: "amount * exchangeRate", format: .currency, unit: "INR"),
                                  Output(name: "whatIf", label: "What if", formula: "amount * whatIfRate", format: .currency, unit: "INR")],
                        blocks: [], related: [], reference: nil)
converter.sources = [rate]
let converterIssues = Checker.checkLogic(&converter)
expect(!converterIssues.contains { $0.kind == .needsModel }, "a converter checks: \(converterIssues)")
expect(converter.input("exchangeRate")?.source == "rate.rate", "a field named by its own name alone is found")
expect(converter.input("whatIfRate")?.initial == 94.5 && converter.input("whatIfRate")?.role == .adjustable, "a what-if starts at the live value and stays the user's")
expect(converter.input("amount")?.unit == "USD", "an amount keeps its currency code")
let values = converter.evaluate(converter.initialValues)
expect(near(values.values["inRupees"], 9450), "formulas use live values")
print("  100 USD shows as \(converter.display("amount", 100)); in rupees, \(converter.display("inRupees", values.values["inRupees"]))")

print("Showing values")
var trip = Surface(title: "Trip", summary: "", symbol: "car", accent: .blue,
                   inputs: [input("duration", role: .live, source: "trip.duration", unit: "min"), input("rainChance", role: .live, source: "weather.rainChance")],
                   outputs: [Output(name: "umbrella", label: "Take an umbrella", formula: "rainChance >= 40", format: .toggle),
                             Output(name: "hours", label: "Hours", formula: "duration / 60", format: .number, unit: "h")],
                   blocks: [], related: [], reference: nil)
trip.sources = [weather, Source(name: "trip", kind: "route", parameters: ["from": "current location", "to": "Mysuru"], fields: [SourceField(name: "duration", value: 153, unit: "min")])]
_ = Checker.checkLogic(&trip)
let tripValues = trip.evaluate(trip.initialValues).values
expect(trip.output("umbrella")?.format == .toggle && trip.display("umbrella", tripValues["umbrella"]) == "Yes", "a yes-or-no result reads Yes: \(trip.display("umbrella", tripValues["umbrella"]))")
print("  153 min shows as \(trip.display("duration", 153)); 2.55 h as \(trip.display("hours", tripValues["hours"]))")
expect(trip.display("hours", tripValues["hours"]) != "2.55 h" && trip.display("duration", 153) == "153\u{202F}min", "part of an hour reads in hours and minutes; minutes stay minutes")
expect(trip.forgettingLocation.input("duration")?.initial == 0 && trip.forgettingLocation.input("rainChance")?.initial == 70, "sharing forgets what was read about where the author was, only that")

print("Actions")
var picnic = Surface(title: "Picnic", summary: "", symbol: "basket", accent: .green,
                     inputs: [input("hours", role: .adjustable, initial: 2), input("rainChance", role: .live, source: "weather.rainChance")],
                     outputs: [], blocks: [Block(id: "a", kind: .hero, ref: "rainChance")], related: [], reference: nil)
picnic.sources = [weather]
picnic.actions = [
    Action(name: "addPicnic", kind: "calendarEvent", fields: ["title": "Picnic in Cubbon Park", "day": "saturday", "time": "16:00", "duration": "hours * 60", "place": "Cubbon Park", "notes": "Chance of rain: {rainChance}. Bring {nothing}."]),
    Action(name: "remind", kind: "reminder", fields: ["title": "Pack the basket", "day": "friday", "time": "sometime"]),
    Action(name: "go", kind: "directions", fields: ["title": "Cubbon Park", "travel": "on foot"]),
    Action(name: "never", kind: "calendarEvent", fields: ["title": "Never", "day": "someday"]),
]
_ = Checker.checkLogic(&picnic)
let actionIssues = Checker.checkBlocks(&picnic)
expect(picnic.actions?.map(\.name) == ["addPicnic", "remind", "go"], "an action whose day can't be read is dropped: \(actionIssues)")
expect(picnic.action("remind")?["time"] == "", "an unreadable time makes it last all day")
expect(picnic.action("go")?["place"] == "Cubbon Park" && picnic.action("go")?["travel"] == "walking", "directions go to the place named, on foot")
expect(picnic.action("addPicnic")?["notes"] == "Chance of rain: {rainChance}. Bring .", "unknown {name}s are dropped from its text")
expect(picnic.blocks.filter { $0.kind == .action }.count == 3, "every action gets a button")
let evaluation = picnic.evaluate(picnic.initialValues)
let resolved = picnic.action("addPicnic")!.resolved(in: picnic, evaluation: evaluation, now: now, calendar: calendar)
expect(resolved.minutes == 120 && resolved.hasTime, "its length comes from a formula")
expect(resolved.start.map { calendar.component(.hour, from: $0) } == 16 && resolved.start.map { calendar.component(.weekday, from: $0) } == 7, "it starts on Saturday at 4 pm")
expect(resolved["notes"].contains("70"), "its notes show the live value: \(resolved["notes"])")
for action in picnic.actions ?? [] {
    let resolved = action.resolved(in: picnic, evaluation: evaluation)
    print("  button: \(LiveActions.performer(action.kind)?.sentence(resolved) ?? "?")")
}

let directions = picnic.action("go")!.resolved(in: picnic, evaluation: evaluation)
expect(DirectionsPerformer.url(directions)?.absoluteString == "https://maps.apple.com/?daddr=Cubbon%20Park&dirflg=w", "directions hand Maps the place by name: \(DirectionsPerformer.url(directions)?.absoluteString ?? "none")")

print("Fetching (network)")
let log = LiveLog()
let tool = LiveTool(log: log)
for arguments in [
    LiveTool.Arguments(name: "rate", kind: .exchangeRate, place: "", day: "", time: "", from: "usd", to: "INR", travel: ""),
    LiveTool.Arguments(name: "trip", kind: .route, place: "", day: "", time: "", from: "Bengaluru", to: "Mysuru", travel: "driving"),
    LiveTool.Arguments(name: "weather", kind: .weather, place: "current location", day: "tomorrow", time: "", from: "", to: "", travel: ""),
    LiveTool.Arguments(name: "picnic", kind: .weather, place: "Bengaluru", day: "saturday", time: "16:00", from: "", to: "", travel: ""),
    LiveTool.Arguments(name: "airport", kind: .route, place: "", day: "", time: "", from: "current location", to: "airport", travel: "transit"),
    LiveTool.Arguments(name: "nowhere", kind: .route, place: "", day: "", time: "", from: "Bengaluru", to: "Qwxzvbnm Plkjh", travel: "driving"),
] {
    let text = try await tool.call(arguments: arguments)
    print(text.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
}
let sources = log.sources
expect(sources.map(\.name) == ["rate", "trip", "weather", "picnic", "airport"], "each source read is declared; a failed one isn't")
expect((sources.first { $0.name == "airport" }?.field("distance")?.value ?? 1000) < 150, "the airport is the nearest one, not one across the country")
expect((sources.first { $0.name == "rate" }?.field("rate")?.value ?? 0) > 1, "a real exchange rate")
expect((sources.first { $0.name == "trip" }?.field("distance")?.value ?? 0) > 100, "a real route, over 100 km")
expect(sources.first { $0.name == "weather" }?.parameters["place"] == "current location", "where the user is stays a word, never coordinates")
let again = try await LiveSources.read(sources.first { $0.name == "rate" }!)
expect(again.field("rate") != nil, "a second read comes from the cache")

print(failures == 0 ? "\nAll live checks passed." : "\n\(failures) live checks failed.")
exit(failures == 0 ? 0 : 1)
