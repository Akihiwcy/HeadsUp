import Foundation

public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8
    public static let metersPerNauticalMile = 1852.0
    public static let knotsToKmh = 1.852
    public static let feetToMeters = 0.3048

    /// Great-circle distance in meters.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// Initial bearing in degrees (0 = north, clockwise).
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point reached travelling `meters` along `bearing` degrees.
    public static func destination(from c: Coordinate, bearing: Double, meters: Double) -> Coordinate {
        let δ = meters / earthRadius
        let θ = bearing * .pi / 180
        let φ1 = c.latitude * .pi / 180, λ1 = c.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        var lon = λ2 * 180 / .pi
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return Coordinate(latitude: φ2 * 180 / .pi, longitude: lon)
    }

    /// Eight-point compass name in Chinese.
    public static func compassName(_ degrees: Double) -> String {
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }
}

/// Apple Maps in mainland China draws its base map in GCJ-02, while ADS-B and
/// CoreLocation report WGS-84. Without conversion aircraft and the user's dot
/// would be drawn a few hundred meters off the streets underneath.
public enum ChinaCoordinate {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    private struct Box { let minLat, maxLat, minLon, maxLon: Double
        func contains(_ c: Coordinate) -> Bool {
            c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon
        }
    }

    // Coarse mainland envelope, minus the regions whose Apple base map is WGS-84.
    // Neighbouring countries inside the envelope are handled by the caller, which
    // disables conversion when the user's own country is known not to be China.
    private static let mainland = Box(minLat: 18.0, maxLat: 53.56, minLon: 73.66, maxLon: 135.05)
    private static let excluded: [Box] = [
        Box(minLat: 22.13, maxLat: 22.57, minLon: 113.82, maxLon: 114.45),   // Hong Kong
        Box(minLat: 22.10, maxLat: 22.22, minLon: 113.52, maxLon: 113.61),   // Macau
        Box(minLat: 21.80, maxLat: 25.40, minLon: 119.30, maxLon: 122.10),   // Taiwan
    ]

    public static func isInMainlandChina(_ c: Coordinate) -> Bool {
        mainland.contains(c) && !excluded.contains { $0.contains(c) }
    }

    public static func wgs84ToGcj02(_ c: Coordinate) -> Coordinate {
        let x = c.longitude - 105.0, y = c.latitude - 35.0
        var dLat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        dLat += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        dLat += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        dLat += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        var dLon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        dLon += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        dLon += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        dLon += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return Coordinate(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    /// Converts to the datum the Apple base map uses at that point.
    public static func toMapDatum(_ c: Coordinate, enabled: Bool) -> Coordinate {
        guard enabled, isInMainlandChina(c) else { return c }
        return wgs84ToGcj02(c)
    }
}

extension ChinaCoordinate {
    /// Inverse of `wgs84ToGcj02`, by fixed-point iteration (sub-meter after a few rounds).
    public static func gcj02ToWgs84(_ c: Coordinate) -> Coordinate {
        var w = c
        for _ in 0..<6 {
            let g = wgs84ToGcj02(w)
            w = Coordinate(latitude: w.latitude - (g.latitude - c.latitude),
                           longitude: w.longitude - (g.longitude - c.longitude))
        }
        return w
    }
}
