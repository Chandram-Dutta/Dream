import CoreLocation
import Foundation
import MapKit

// Places for sources and actions (ROADMAP.md, workstream 7): a place Maps can find, or where
// the user is, from CoreLocation with when-in-use permission.

/// A place, found.
struct LivePlace: Sendable {
    /// What to call it, like Mysuru, or your location.
    var name: String
    var latitude: Double
    var longitude: Double
    /// Where days start and end there, for "tomorrow" in another country.
    var timeZone: TimeZone
    var isHere = false
    /// On the bench, where "current location" is stood in.
    var isStandIn = false

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var mapItem: MKMapItem {
        let item = MKMapItem(location: location, address: nil)
        item.name = name
        item.timeZone = timeZone
        return item
    }

    /// Days as they fall there.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }
}

enum Places {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [String: LivePlace] = [:]
    nonisolated(unsafe) private static var lastHere: (place: LivePlace, at: Date)?

    /// A place by name, or where the user is for "current location" and the like. Names are
    /// looked for `near` a place first, so "the airport" on a route from Bengaluru is Bengaluru's.
    static func find(_ text: String, near: LivePlace? = nil) async throws -> LivePlace {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Source.isHere(name) { return try await here() }
        let key = name.lowercased() + (near.map { String(format: " near %.1f,%.1f", $0.latitude, $0.longitude) } ?? "")
        if let known = lock.withLock({ found[key] }) { return known }
        guard let request = MKGeocodingRequest(addressString: name) else { throw LiveError(.notFound, "Maps couldn't find \(name).") }
        if let near {
            request.region = MKCoordinateRegion(center: near.location.coordinate, latitudinalMeters: 300_000, longitudinalMeters: 300_000)
        }
        guard let item = try? await request.mapItems.first else {
            throw LiveError(.notFound, "Maps couldn't find \(name).")
        }
        let place = LivePlace(
            name: item.name ?? name,
            latitude: item.location.coordinate.latitude,
            longitude: item.location.coordinate.longitude,
            timeZone: item.timeZone ?? .current)
        lock.withLock { found[key] = place }
        return place
    }

    /// A place of a name within a distance of another, like the airport that serves home, from
    /// Maps' search rather than its address lookup: the best match whose name says what was
    /// asked for, so "airport" isn't a hotel near one. Nil when there's none that close.
    static func nearest(_ text: String, to origin: LivePlace, within radius: Double) async -> LivePlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = MKCoordinateRegion(center: origin.location.coordinate, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        request.regionPriority = .required
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 && $0 != "the" }
        guard let items = try? await MKLocalSearch(request: request).start().mapItems,
              let item = items.first(where: { item in
                  let name = (item.name ?? "").lowercased()
                  return item.location.distance(from: origin.location) <= radius && words.allSatisfy { name.contains($0) }
              })
        else { return nil }
        return LivePlace(
            name: item.name ?? text,
            latitude: item.location.coordinate.latitude,
            longitude: item.location.coordinate.longitude,
            timeZone: item.timeZone ?? origin.timeZone)
    }

    /// Where the user is, asking for permission the first time. Kept for a few minutes, since
    /// several sources on one screen usually want it at once.
    static func here() async throws -> LivePlace {
        if let last = lock.withLock({ lastHere }), Date.now.timeIntervalSince(last.at) < 300 { return last.place }
        if LiveSources.standIns {
            return LivePlace(name: "Bengaluru (standing in for your location)", latitude: 12.9716, longitude: 77.5946,
                             timeZone: TimeZone(identifier: "Asia/Kolkata") ?? .current, isHere: true, isStandIn: true)
        }
        let location = try await locate()
        var name = "your location"
        if let request = MKReverseGeocodingRequest(location: location), let item = try? await request.mapItems.first,
           let city = item.addressRepresentations?.cityName ?? item.name {
            name = city
        }
        let place = LivePlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, timeZone: .current, isHere: true)
        lock.withLock { lastHere = (place, .now) }
        return place
    }

    /// One fix from CoreLocation. Its first use asks for permission; while the user decides,
    /// the model writing a screen is told to wait rather than taking the quiet for a stall.
    private static func locate() async throws -> CLLocation {
        #if os(iOS)
        // Asks for when-in-use permission if the user hasn't decided yet.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        #endif
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                        throw LiveError(.denied, "Location is off for Dream.")
                    }
                    if let location = update.location { return location }
                }
                throw LiveError(.unavailable, "Dream couldn't find where you are.")
            }
            group.addTask {
                for _ in 0..<60 {
                    try await Task.sleep(for: .seconds(1))
                    ModelActivity.touch()
                }
                throw LiveError(.unavailable, "Dream couldn't find where you are.")
            }
            defer { group.cancelAll() }
            guard let location = try await group.next() else { throw LiveError(.unavailable, "Dream couldn't find where you are.") }
            return location
        }
    }
}
