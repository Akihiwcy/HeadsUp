import Foundation

public struct Airport: Equatable, Sendable {
    public var iata: String?
    public var icao: String?
    public var name: String?
    public var city: String?
    public var position: Coordinate?

    public var code: String { iata ?? icao ?? "—" }
}

public struct FlightRoute: Equatable, Sendable {
    public var airline: String?
    public var origin: Airport
    public var destination: Airport
    /// Where the route came from, for the card's footer.
    public var source: String = "adsbdb"
    /// True when a flight-status service reported it for today's flight (not a callsign database guess).
    public var verified = false

    public init(airline: String?, origin: Airport, destination: Airport, source: String = "adsbdb", verified: Bool = false) {
        self.airline = airline
        self.origin = origin
        self.destination = destination
        self.source = source
        self.verified = verified
    }

    /// adsbdb's routes are keyed by callsign and can be stale. Treat a route as doubtful when the
    /// aircraft is far from the great-circle path between the two airports.
    public func isPlausible(for position: Coordinate, track: Double? = nil, verticalRateFpm: Int? = nil) -> Bool {
        if verified { return true }
        guard let o = origin.position, let d = destination.position else { return true }
        let direct = Geo.distance(o, d)
        let via = Geo.distance(o, position) + Geo.distance(position, d)
        guard via <= direct * 1.25 + 150_000 else { return false }
        // Near either end, the climb or descent must agree with the direction of flight:
        // a callsign reused for the return leg would otherwise pass the corridor test.
        if let track, let v = verticalRateFpm {
            func headingToward(_ p: Coordinate) -> Bool {
                let diff = abs((Geo.bearing(from: position, to: p) - track + 540).truncatingRemainder(dividingBy: 360) - 180)
                return diff < 90
            }
            if Geo.distance(position, d) < 80_000, v > 800, !headingToward(d) { return false }
            if Geo.distance(position, o) < 80_000, v < -800, headingToward(o) { return false }
        }
        return true
    }
}

public struct AircraftInfo: Equatable, Sendable {
    public var type: String?
    public var manufacturer: String?
    public var registration: String?
    public var owner: String?
}

public enum Lookup<T: Sendable & Equatable>: Equatable, Sendable {
    case loading
    case found(T)
    case unknown
    case failed
}

/// Looks up origin/destination and airframe details from adsbdb.com, caching results.
public actor RouteService {
    private let session: URLSession
    private let base: String
    private var routes: [String: Lookup<FlightRoute>] = [:]
    private var airframes: [String: Lookup<AircraftInfo>] = [:]
    private var iataAirlines: [String: [String]] = [:]
    private var live: LiveRouteClient?
    private var liveRoutes: [String: (route: FlightRoute?, at: Date)] = [:]
    /// The last error from the flight-status service, if its most recent lookup failed.
    public private(set) var liveError: LiveRouteError?

    public init(session: URLSession = .shared, base: String = "https://api.adsbdb.com") {
        self.session = session
        self.base = base
    }

    /// Uses a flight-status service (with the user's key) before the callsign database; nil turns it off.
    public func setLiveProvider(_ client: LiveRouteClient?) {
        live = client
        liveRoutes = [:]
        liveError = nil
    }

    /// Route for the flight now operating as `callsign`: the flight-status service if configured,
    /// else (or if it has nothing) adsbdb.
    public func route(callsign: String, onGround: Bool) async -> Lookup<FlightRoute> {
        if let live {
            let key = callsign.uppercased() + (onGround ? "/g" : "/a")
            if let hit = liveRoutes[key], Date().timeIntervalSince(hit.at) < 20 * 60 {
                if let r = hit.route { return .found(r) }
            } else {
                do {
                    let r = try await live.route(callsign: callsign, onGround: onGround)
                    liveRoutes[key] = (r, Date())
                    liveError = nil
                    if let r { return .found(r) }
                } catch let e as LiveRouteError {
                    liveError = e
                } catch {
                    liveError = .network(error.localizedDescription)
                }
            }
        }
        return await route(callsign: callsign)
    }

    public func route(callsign: String) async -> Lookup<FlightRoute> {
        let key = callsign.uppercased()
        if let cached = routes[key], cached != .failed { return cached }
        guard key.range(of: "^[A-Z0-9]{2,8}$", options: .regularExpression) != nil,
              let url = URL(string: "\(base)/v0/callsign/\(key)") else { return .unknown }
        let result: Lookup<FlightRoute>
        switch await get(url) {
        case .some(let json):
            result = Self.parseRoute(json).map { .found($0) } ?? .unknown
        case .none:
            result = .failed
        }
        routes[key] = result
        return result
    }

    public func aircraft(hex: String) async -> Lookup<AircraftInfo> {
        let key = hex.uppercased()
        if let cached = airframes[key], cached != .failed { return cached }
        guard key.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil,
              let url = URL(string: "\(base)/v0/aircraft/\(key)") else { return .unknown }
        let result: Lookup<AircraftInfo>
        switch await get(url) {
        case .some(let json):
            result = Self.parseAircraft(json).map { .found($0) } ?? .unknown
        case .none:
            result = .failed
        }
        airframes[key] = result
        return result
    }

    /// ICAO designators for an IATA airline code (several airlines can share one), or nil on failure.
    public func icaoCodes(forIATA code: String) async -> [String]? {
        let key = code.uppercased()
        if let cached = iataAirlines[key] { return cached }
        guard key.range(of: "^[A-Z0-9]{2}$", options: .regularExpression) != nil,
              let url = URL(string: "\(base)/v0/airline/\(key)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("HeadsUp/1.0 (macOS desktop aircraft widget)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (obj["response"] as? [[String: Any]]) ?? []
        let codes = list.compactMap { $0["icao"] as? String }.filter { !$0.isEmpty }
        iataAirlines[key] = codes
        return codes
    }

    /// Returns the decoded `response` object, `[:]` for a definite "unknown", nil for a failure.
    private func get(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("HeadsUp/1.0 (macOS desktop aircraft widget)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let r = obj["response"] as? [String: Any] { return r }
        if obj["response"] is String || code == 404 { return [:] }   // "unknown callsign"
        return nil
    }

    static func parseRoute(_ r: [String: Any]) -> FlightRoute? {
        guard let fr = r["flightroute"] as? [String: Any],
              let o = fr["origin"] as? [String: Any], let d = fr["destination"] as? [String: Any] else { return nil }
        func airport(_ a: [String: Any]) -> Airport {
            var pos: Coordinate?
            if let lat = a["latitude"] as? Double, let lon = a["longitude"] as? Double { pos = Coordinate(latitude: lat, longitude: lon) }
            return Airport(iata: a["iata_code"] as? String, icao: a["icao_code"] as? String,
                           name: a["name"] as? String, city: a["municipality"] as? String, position: pos)
        }
        let airline = (fr["airline"] as? [String: Any])?["name"] as? String
        return FlightRoute(airline: airline, origin: airport(o), destination: airport(d))
    }

    static func parseAircraft(_ r: [String: Any]) -> AircraftInfo? {
        guard let a = r["aircraft"] as? [String: Any] else { return nil }
        return AircraftInfo(type: a["type"] as? String, manufacturer: a["manufacturer"] as? String,
                            registration: a["registration"] as? String, owner: a["registered_owner"] as? String)
    }
}
