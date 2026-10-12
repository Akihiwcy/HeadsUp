import Foundation

/// One aircraft as reported by a readsb-style ADS-B feed.
public struct Aircraft: Identifiable, Equatable, Sendable {
    public var id: String { hex }
    public var hex: String
    public var callsign: String?
    public var registration: String?
    public var typeCode: String?
    public var typeDescription: String?
    public var position: Coordinate
    /// Barometric altitude in feet; nil when unknown.
    public var altitudeFt: Int?
    public var onGround: Bool
    public var groundSpeedKt: Double?
    public var trackDeg: Double?
    public var verticalRateFpm: Int?
    public var squawk: String?
    public var category: String?
    /// When the position above was measured.
    public var positionTime: Date

    public init(hex: String, callsign: String? = nil, registration: String? = nil, typeCode: String? = nil,
                typeDescription: String? = nil, position: Coordinate, altitudeFt: Int? = nil, onGround: Bool = false,
                groundSpeedKt: Double? = nil, trackDeg: Double? = nil, verticalRateFpm: Int? = nil,
                squawk: String? = nil, category: String? = nil, positionTime: Date) {
        self.hex = hex
        self.callsign = callsign
        self.registration = registration
        self.typeCode = typeCode
        self.typeDescription = typeDescription
        self.position = position
        self.altitudeFt = altitudeFt
        self.onGround = onGround
        self.groundSpeedKt = groundSpeedKt
        self.trackDeg = trackDeg
        self.verticalRateFpm = verticalRateFpm
        self.squawk = squawk
        self.category = category
        self.positionTime = positionTime
    }

    /// Callsign if broadcast, else registration, else the ICAO hex.
    public var displayName: String {
        if let c = callsign, !c.isEmpty { return c }
        if let r = registration, !r.isEmpty { return r }
        // Non-ICAO addresses (TIS-B, MLAT-only) arrive prefixed with "~".
        return hex.replacingOccurrences(of: "~", with: "").uppercased()
    }

    public enum Trend: Sendable { case climbing, descending, level }

    public var trend: Trend {
        guard let v = verticalRateFpm else { return .level }
        if v > 300 { return .climbing }
        if v < -300 { return .descending }
        return .level
    }

    /// Dead-reckoned position `date`, following the last reported track and speed.
    /// Extrapolation stops after `maxSeconds` so a lost aircraft doesn't drift away forever.
    public func extrapolatedPosition(at date: Date, maxSeconds: Double = 45) -> Coordinate {
        guard !onGround, let gs = groundSpeedKt, let track = trackDeg, gs > 1 else { return position }
        let dt = min(max(date.timeIntervalSince(positionTime), 0), maxSeconds)
        let meters = gs * Geo.metersPerNauticalMile / 3600 * dt
        return Geo.destination(from: position, bearing: track, meters: meters)
    }
}

// MARK: - Feed decoding

/// Decodes the JSON that adsb.lol (`ac`, `now` in ms) and adsb.fi (`aircraft`, `now` in s) return.
public enum ReadsbDecoder {
    struct Response: Decodable {
        var now: Double?
        var ac: [Raw]?
        var aircraft: [Raw]?
        var msg: String?
    }

    struct Raw: Decodable {
        var hex: String?
        var flight: String?
        var r: String?
        var t: String?
        var desc: String?
        var lat: Double?
        var lon: Double?
        var alt_baro: Altitude?
        var gs: Double?
        var track: Double?
        var true_heading: Double?
        var baro_rate: Double?
        var geom_rate: Double?
        var squawk: String?
        var category: String?
        var seen_pos: Double?
        var seen: Double?
    }

    enum Altitude: Decodable {
        case feet(Int), ground
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .feet(Int(n)) }
            else if let s = try? c.decode(String.self), s.lowercased() == "ground" { self = .ground }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "alt_baro") }
        }
    }

    public static func decode(_ data: Data, receivedAt: Date = Date()) throws -> [Aircraft] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let list = r.ac ?? r.aircraft else {
            throw FeedError.badResponse(r.msg ?? "缺少飞机列表")
        }
        var now = receivedAt
        if let n = r.now {
            now = Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
            // Guard against clock skew between the server and this Mac.
            if abs(now.timeIntervalSince(receivedAt)) > 120 { now = receivedAt }
        }
        return list.compactMap { raw in
            guard let hex = raw.hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty,
                  let lat = raw.lat, let lon = raw.lon else { return nil }
            let pos = Coordinate(latitude: lat, longitude: lon)
            guard pos.isValid else { return nil }
            var altitude: Int?
            var ground = false
            switch raw.alt_baro {
            case .feet(let f): altitude = f
            case .ground: ground = true; altitude = 0
            case nil: break
            }
            let seen = raw.seen_pos ?? raw.seen ?? 0
            let rate = raw.baro_rate ?? raw.geom_rate
            return Aircraft(
                hex: hex.lowercased(),
                callsign: clean(raw.flight),
                registration: clean(raw.r),
                typeCode: clean(raw.t),
                typeDescription: clean(raw.desc),
                position: pos,
                altitudeFt: altitude,
                onGround: ground,
                groundSpeedKt: raw.gs,
                trackDeg: raw.track ?? raw.true_heading,
                verticalRateFpm: rate.map { Int($0) },
                squawk: clean(raw.squawk),
                category: clean(raw.category),
                positionTime: now.addingTimeInterval(-seen)
            )
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

public enum FeedError: Error, Equatable, LocalizedError, Sendable {
    case offline
    case network(String)
    case http(Int)
    case rateLimited
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .offline: return "网络不可用"
        case .network(let m): return "无法连接数据服务（\(m)）"
        case .http(let code): return "数据服务返回错误 HTTP \(code)"
        case .rateLimited: return "数据服务限流，稍后重试"
        case .badResponse(let m): return "数据格式异常（\(m)）"
        }
    }
}
