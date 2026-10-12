import Foundation

public struct PlaceResult: Equatable, Sendable {
    public var name: String
    public var detail: String
    /// WGS-84.
    public var coordinate: Coordinate
    public var source: String

    public init(name: String, detail: String, coordinate: Coordinate, source: String) {
        self.name = name; self.detail = detail; self.coordinate = coordinate; self.source = source
    }
}

/// OpenStreetMap's Nominatim geocoder: covers places Apple's map data lacks on some Macs
/// (e.g. many buildings in mainland China outside the China-region map). Coordinates are WGS-84.
/// Used only when the user presses Search, well within Nominatim's one-request-per-second policy.
public struct NominatimGeocoder: Sendable {
    let session: URLSession
    let base: String

    public init(session: URLSession = .shared, base: String = "https://nominatim.openstreetmap.org") {
        self.session = session
        self.base = base
    }

    public func search(_ query: String, language: String = "zh-CN,en") async throws -> [PlaceResult] {
        var c = URLComponents(string: "\(base)/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "jsonv2"),
                        URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "addressdetails", value: "0")]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 12
        req.setValue("HeadsUp/1.0 (personal macOS desktop aircraft widget)", forHTTPHeaderField: "User-Agent")
        req.setValue(language, forHTTPHeaderField: "Accept-Language")
        let (data, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            throw URLError(.badServerResponse)
        }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [PlaceResult] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let lat = Double(item["lat"] as? String ?? ""), let lon = Double(item["lon"] as? String ?? "") else { return nil }
            let full = item["display_name"] as? String ?? ""
            let parts = full.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parts.first ?? full
            // Drop the name, house numbers and postcodes from the detail line.
            let detail = parts.dropFirst().filter { $0.rangeOfCharacter(from: .letters) != nil }.prefix(4).joined(separator: ", ")
            return PlaceResult(name: name, detail: detail, coordinate: Coordinate(latitude: lat, longitude: lon), source: "OpenStreetMap")
        }
    }

    /// Apple results first, then OpenStreetMap ones that aren't the same place (within 300 m).
    public static func merge(_ apple: [PlaceResult], _ osm: [PlaceResult], limit: Int = 6) -> [PlaceResult] {
        var out = apple
        for p in osm where !out.contains(where: { Geo.distance($0.coordinate, p.coordinate) < 300 }) { out.append(p) }
        return Array(out.prefix(limit))
    }
}
