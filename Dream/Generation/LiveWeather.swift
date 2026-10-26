import CoreLocation
import Foundation
import WeatherKit

// The weather (ROADMAP.md, workstream 7), from WeatherKit. Needs the WeatherKit entitlement and
// its App Service enabled for the app's bundle ID; its terms ask for the Apple Weather mark and
// legal link wherever its data appears (`WeatherCredit`).

/// The weather for a place and a day: now, at an hour, or for the whole day, up to ten days
/// ahead. Parameters: place (or current location), day, and time, an hour like 16:00.
struct WeatherProvider: LiveProvider {
    let kind = "weather"
    let freshness: TimeInterval = 15 * 60

    func read(_ source: Source) async throws -> SourceReading {
        let place = try await Places.find(source["place"])
        let calendar = place.calendar
        let now = Date.now
        guard let day = LiveDay.date(source["day"], now: now, calendar: calendar) else {
            throw LiveError(.notFound, "Dream can't tell which day \"\(source["day"])\" is.")
        }
        let ahead = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
        guard (0...9).contains(ahead) else { throw LiveError(.notFound, "Forecasts only reach 10 days ahead.") }
        let at = LiveDay.minutes(source["time"]).flatMap { calendar.date(byAdding: .minute, value: $0, to: day) }
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let forecast = Forecast(place: place, day: day, at: at, isToday: ahead == 0, calendar: calendar)
        do {
            let (current, hours, days) = try await WeatherService.shared.weather(
                for: place.location, including: .current, .hourly(startDate: day, endDate: end), .daily(startDate: day, endDate: end))
            guard let daily = days.forecast.first else { throw LiveError(.unavailable, "There's no forecast for that day yet.") }
            let hour = at.flatMap { at in hours.forecast.min { abs($0.date.timeIntervalSince(at)) < abs($1.date.timeIntervalSince(at)) } }
            return forecast.reading(current: current, hour: hour, day: daily)
        } catch let error as LiveError {
            throw error
        } catch {
            if LiveSources.standIns { return forecast.standIn() }
            // The reason stays in the console: it's for whoever set WeatherKit up, not the reader.
            print("[Dream] WeatherKit failed: \(error)")
            throw LiveError(.unavailable, "The weather isn't available right now.")
        }
    }
}

/// One request's forecast, turned into fields. Temperatures in °C, speeds in km/h, rain in mm,
/// chances and humidity as percentages.
private struct Forecast {
    let place: LivePlace
    let day: Date
    let at: Date?
    let isToday: Bool
    let calendar: Calendar

    /// "now", "at 16:00", "during the day".
    private var moment: String {
        if let at { return "at \(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)))" }
        return isToday ? "now" : "during the day"
    }

    private var when: String {
        let date = day.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide).day().month(.wide))
        let named = isToday ? "today" : date
        if let at { return "\(named) at \(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)))" }
        return isToday ? "now and today" : date
    }

    func reading(current: CurrentWeather, hour: HourWeather?, day: DayWeather) -> SourceReading {
        var fields: [SourceField] = []
        func add(_ name: String, _ value: Double, _ unit: String = "", _ format: Format = .number, _ meaning: String) {
            guard value.isFinite else { return }
            fields.append(SourceField(name: name, value: value, unit: unit, format: format, meaning: meaning))
        }
        func celsius(_ measurement: Measurement<UnitTemperature>) -> Double { measurement.converted(to: .celsius).value }
        func kmh(_ measurement: Measurement<UnitSpeed>) -> Double { measurement.converted(to: .kilometersPerHour).value }

        add("high", celsius(day.highTemperature), "°C", .number, "the day's highest temperature")
        add("low", celsius(day.lowTemperature), "°C", .number, "the day's lowest temperature")
        if let hour {
            add("temperature", celsius(hour.temperature), "°C", .number, "the temperature \(moment)")
            add("feelsLike", celsius(hour.apparentTemperature), "°C", .number, "what it feels like \(moment)")
            add("rainChance", hour.precipitationChance * 100, "", .percent, "the chance of rain \(moment)")
            add("humidity", hour.humidity * 100, "", .percent, "humidity \(moment)")
            add("windSpeed", kmh(hour.wind.speed), "km/h", .number, "wind speed \(moment)")
            add("uvIndex", Double(hour.uvIndex.value), "", .integer, "the UV index \(moment)")
            add("cloudCover", hour.cloudCover * 100, "", .percent, "cloud cover \(moment)")
        } else if isToday {
            add("temperature", celsius(current.temperature), "°C", .number, "the temperature now")
            add("feelsLike", celsius(current.apparentTemperature), "°C", .number, "what it feels like now")
            add("rainChance", day.precipitationChance * 100, "", .percent, "the chance of rain today")
            add("humidity", current.humidity * 100, "", .percent, "humidity now")
            add("windSpeed", kmh(current.wind.speed), "km/h", .number, "wind speed now")
            add("uvIndex", Double(current.uvIndex.value), "", .integer, "the UV index now")
            add("cloudCover", current.cloudCover * 100, "", .percent, "cloud cover now")
        } else {
            add("rainChance", day.precipitationChance * 100, "", .percent, "the chance of rain during the day")
            add("windSpeed", kmh(day.wind.speed), "km/h", .number, "wind speed during the day")
            add("uvIndex", Double(day.uvIndex.value), "", .integer, "the day's highest UV index")
        }
        add("rainAmount", day.precipitationAmountByType.precipitation.converted(to: .millimeters).value, "mm", .number, "how much rain is expected during the day")
        let condition = hour?.condition ?? (isToday ? current.condition : day.condition)
        return SourceReading(
            fields: fields,
            summary: "\(place.name), \(when): \(condition.description)",
            symbol: hour?.symbolName ?? (isToday ? current.symbolName : day.symbolName),
            asOf: min(current.metadata.date, .now),
            credit: .appleWeather,
            isStandIn: place.isStandIn)
    }

    /// For the bench, which WeatherKit won't authorize: plausible values that differ by day,
    /// marked as stand-ins everywhere they're shown.
    func standIn() -> SourceReading {
        let seed = calendar.component(.weekday, from: day)
        let wet = seed % 2 == 0
        var fields = [
            SourceField(name: "high", value: 28 + Double(seed % 3), unit: "°C", format: .number, meaning: "the day's highest temperature"),
            SourceField(name: "low", value: 19 + Double(seed % 2), unit: "°C", format: .number, meaning: "the day's lowest temperature"),
            SourceField(name: "rainChance", value: wet ? 70 : 15, format: .percent, meaning: "the chance of rain \(moment)"),
            SourceField(name: "windSpeed", value: 12, unit: "km/h", format: .number, meaning: "wind speed \(moment)"),
            SourceField(name: "uvIndex", value: 7, format: .integer, meaning: "the UV index \(moment)"),
            SourceField(name: "rainAmount", value: wet ? 6 : 0, unit: "mm", format: .number, meaning: "how much rain is expected during the day"),
        ]
        if at != nil || isToday {
            fields.insert(SourceField(name: "temperature", value: 26, unit: "°C", format: .number, meaning: "the temperature \(moment)"), at: 2)
            fields.insert(SourceField(name: "humidity", value: wet ? 82 : 55, format: .percent, meaning: "humidity \(moment)"), at: 3)
        }
        return SourceReading(
            fields: fields,
            summary: "\(place.name), \(when): \(wet ? "Showers" : "Mostly sunny")",
            symbol: wet ? "cloud.rain" : "sun.max",
            asOf: .now,
            credit: .appleWeather,
            isStandIn: true)
    }
}

/// The Apple Weather mark and the link to its legal attribution, which WeatherKit's terms ask
/// for wherever its data is shown.
enum WeatherCredit {
    struct Marks: Sendable, Equatable {
        var light: URL
        var dark: URL
        var legal: URL
    }

    /// Where the legal attribution lives if WeatherKit can't say.
    static let legalPage = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: Marks?

    static func marks() async -> Marks? {
        if let known = lock.withLock({ known }) { return known }
        guard let attribution = try? await WeatherService.shared.attribution else { return nil }
        let marks = Marks(light: attribution.combinedMarkLightURL, dark: attribution.combinedMarkDarkURL, legal: attribution.legalPageURL)
        lock.withLock { known = marks }
        return marks
    }
}
