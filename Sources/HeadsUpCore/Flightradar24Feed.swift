import Foundation

/// Flightradar24's authenticated live positions endpoint.
public struct Flightradar24Feed: FlightFeed {
    public static let pollInterval: TimeInterval = 30
    public let name = "Flightradar24"
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func fetch(center: Coordinate, radiusKm: Double) async throws -> [Aircraft] {
        var positions: [String: Aircraft] = [:]
        for bounds in Self.queryBounds(center: center, radiusKm: radiusKm) {
            var url = URLComponents(string: "https://fr24api.flightradar24.com/api/live/flight-positions/full")!
            url.queryItems = [
                URLQueryItem(name: "bounds", value: bounds),
                URLQueryItem(name: "categories", value: "P,C,M,J,T,H,B,G,D,O,N")
            ]
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("v1", forHTTPHeaderField: "Accept-Version")
            let data = try await fetchFeedData(request, session: session)
            for aircraft in try Self.decode(data) where (positions[aircraft.hex]?.positionTime ?? .distantPast) < aircraft.positionTime {
                positions[aircraft.hex] = aircraft
            }
        }
        return Array(positions.values)
    }

    /// Rectangles enclosing the query circle, split at the antimeridian when necessary.
    static func queryBounds(center: Coordinate, radiusKm: Double) -> [String] {
        let angularRadius = radiusKm * 1000 / Geo.earthRadius
        let latDelta = angularRadius * 180 / .pi
        let north = min(90, center.latitude + latDelta)
        let south = max(-90, center.latitude - latDelta)
        func bounds(_ west: Double, _ east: Double) -> String {
            "\(north),\(south),\(west),\(east)"
        }
        guard north < 90, south > -90 else { return [bounds(-180, 180)] }
        let lonDelta = asin(sin(angularRadius) / cos(center.latitude * .pi / 180)) * 180 / .pi
        let west = center.longitude - lonDelta
        let east = center.longitude + lonDelta
        if west < -180 { return [bounds(west + 360, 180), bounds(-180, east)] }
        if east > 180 { return [bounds(west, 180), bounds(-180, east - 360)] }
        return [bounds(west, east)]
    }

    private struct Response: Decodable {
        let data: [Position]
    }

    private struct Position: Decodable {
        let hex: String?
        let callsign: String?
        let reg: String?
        let type: String?
        let lat: Double?
        let lon: Double?
        let alt: Int?
        let track: Double?
        let gspeed: Double?
        let vspeed: Int?
        let squawk: String?
        let timestamp: String?
        let source: String?
    }

    static func decode(_ data: Data) throws -> [Aircraft] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw FeedError.badResponse("Flightradar24 无法解析")
        }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return response.data.compactMap { report in
            guard report.source != "ESTIMATION",
                  let hex = report.hex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty,
                  let lat = report.lat, let lon = report.lon,
                  let timestamp = report.timestamp, let time = iso.date(from: timestamp) ?? fractional.date(from: timestamp)
            else { return nil }
            let position = Coordinate(latitude: lat, longitude: lon)
            guard position.isValid else { return nil }
            let callsign = report.callsign?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Aircraft(hex: hex.lowercased(), callsign: callsign == "" ? nil : callsign,
                            registration: report.reg, typeCode: report.type, position: position,
                            altitudeFt: report.alt, onGround: report.alt == 0 && (report.gspeed ?? 0) < 50,
                            groundSpeedKt: report.gspeed, trackDeg: report.track, verticalRateFpm: report.vspeed,
                            squawk: report.squawk, positionTime: time)
        }
    }
}
