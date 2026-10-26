import Foundation
import MapKit

// Distance and travel time (ROADMAP.md, workstream 7), from MapKit.

/// How far it is from one place to another, and how long it takes now, by car, on foot or by
/// transit. Parameters: from (a place, or current location), to, and travel.
struct RouteProvider: LiveProvider {
    let kind = "route"
    /// Traffic changes quickly.
    let freshness: TimeInterval = 5 * 60

    func read(_ source: Source) async throws -> SourceReading {
        let travel = Travel(source["travel"])
        guard !source["to"].trimmingCharacters(in: .whitespaces).isEmpty else { throw LiveError(.notFound, "A route needs somewhere to go.") }
        let from = try await Places.find(source["from"])
        var to = try await Places.find(source["to"], near: from)
        // A name like "the airport" can find one across the country; the nearest is meant.
        if to.location.distance(from: from.location) > travel.farthest,
           let nearer = await Places.nearest(source["to"], to: from, within: travel.farthest) {
            to = nearer
        }
        let request = MKDirections.Request()
        request.source = from.mapItem
        request.destination = to.mapItem
        request.transportType = travel.transport
        request.departureDate = .now
        guard let eta = try? await MKDirections(request: request).calculateETA() else {
            throw LiveError(.notFound, "Maps has no route \(travel.words) from \(from.name) to \(to.name).")
        }
        var fields = [SourceField(name: "duration", value: (eta.expectedTravelTime / 60).rounded(), unit: "min", format: .number, meaning: "how long it takes \(travel.words), leaving now")]
        if eta.distance > 0 {
            fields.insert(SourceField(name: "distance", value: eta.distance / 1000, unit: "km", format: .number, meaning: "how far it is \(travel.words)"), at: 0)
        }
        return SourceReading(
            fields: fields,
            summary: "\(from.name) to \(to.name), \(travel.words)",
            symbol: travel.symbol,
            asOf: .now,
            credit: .link(text: "Routes from Apple Maps", url: "https://www.apple.com/legal/internet-services/maps/"),
            isStandIn: from.isStandIn || to.isStandIn)
    }
}

extension Travel {
    /// In metres, the farthest anyone would mean to go this way, beyond which a place found by
    /// name is probably a different one with the same name.
    var farthest: Double {
        switch self {
        case .driving: 1_500_000
        case .walking: 30_000
        case .transit: 150_000
        }
    }

    var transport: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
    }
}
