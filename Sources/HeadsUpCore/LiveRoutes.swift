import Foundation

/// Optional flight-status services that know the actual route of today's flight, unlike the
/// crowd-sourced callsign databases. Both need an API key from the user.
public enum RouteProviderKind: String, CaseIterable, Sendable {
    case none, flightAware, airLabs

    public var displayName: String {
        switch self {
        case .none: return "不使用"
        case .flightAware: return "FlightAware AeroAPI"
        case .airLabs: return "AirLabs"
        }
    }
}

public enum LiveRouteError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized
    case rateLimited
    case http(Int)
    case network(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "API Key 无效或没有权限"
        case .rateLimited: return "查询过于频繁或额度用尽"
        case .http(let c): return "服务返回 HTTP \(c)"
        case .network(let m): return "网络错误：\(m)"
        case .badResponse: return "返回数据无法解析"
        }
    }
}

public struct LiveRouteClient: Sendable {
    public let kind: RouteProviderKind
    let key: String
    let session: URLSession
    let base: String?

    public init(kind: RouteProviderKind, key: String, session: URLSession = .shared, base: String? = nil) {
        self.kind = kind
        self.key = key
        self.session = session
        self.base = base
    }

    /// The route of the flight currently operating under `callsign`, or nil if the service has none.
    public func route(callsign: String, onGround: Bool, now: Date = Date()) async throws -> FlightRoute? {
        let cs = callsign.uppercased()
        guard cs.range(of: "^[A-Z0-9]{2,8}$", options: .regularExpression) != nil else { return nil }
        var req: URLRequest
        switch kind {
        case .none:
            return nil
        case .flightAware:
            req = URLRequest(url: URL(string: "\(base ?? "https://aeroapi.flightaware.com/aeroapi")/flights/\(cs)?max_pages=1")!)
            req.setValue(key, forHTTPHeaderField: "x-apikey")
        case .airLabs:
            var c = URLComponents(string: "\(base ?? "https://airlabs.co/api/v9")/flight")!
            c.queryItems = [URLQueryItem(name: "flight_icao", value: cs), URLQueryItem(name: "api_key", value: key)]
            req = URLRequest(url: c.url!)
        }
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw LiveRouteError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        switch code {
        case 200..<300: break
        case 401, 403: throw LiveRouteError.unauthorized
        case 404: return nil
        case 429: throw LiveRouteError.rateLimited
        default: throw LiveRouteError.http(code)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveRouteError.badResponse }
        switch kind {
        case .flightAware: return Self.parseAeroAPI(obj, onGround: onGround, now: now)
        case .airLabs: return try Self.parseAirLabs(obj)
        case .none: return nil
        }
    }

    // MARK: FlightAware AeroAPI v4 — GET /flights/{ident}

    static func parseAeroAPI(_ obj: [String: Any], onGround: Bool, now: Date) -> FlightRoute? {
        guard let flights = obj["flights"] as? [[String: Any]],
              let f = pickAeroAPIFlight(flights, onGround: onGround, now: now),
              let o = f["origin"] as? [String: Any], let d = f["destination"] as? [String: Any] else { return nil }
        func airport(_ a: [String: Any]) -> Airport {
            Airport(iata: a["code_iata"] as? String, icao: (a["code_icao"] as? String) ?? (a["code"] as? String),
                    name: a["name"] as? String, city: a["city"] as? String, position: nil)
        }
        return FlightRoute(airline: nil, origin: airport(o), destination: airport(d), source: "FlightAware", verified: true)
    }

    /// The flight in the list that this aircraft is operating right now.
    static func pickAeroAPIFlight(_ flights: [[String: Any]], onGround: Bool, now: Date) -> [String: Any]? {
        let iso = ISO8601DateFormatter()
        func date(_ f: [String: Any], _ k: String) -> Date? { (f[k] as? String).flatMap(iso.date(from:)) }
        // Airborne: the one that has taken off and not landed.
        if let enRoute = flights.first(where: { date($0, "actual_off") != nil && date($0, "actual_on") == nil }), !onGround {
            return enRoute
        }
        if onGround {
            // Just landed (within 90 minutes) or about to leave (within 3 hours), whichever is closer in time.
            let candidates: [(Double, [String: Any])] = flights.compactMap { f in
                if let on = date(f, "actual_on"), now.timeIntervalSince(on) < 90 * 60, now >= on { return (now.timeIntervalSince(on), f) }
                if date(f, "actual_off") == nil, let out = date(f, "estimated_out") ?? date(f, "scheduled_out"),
                   abs(out.timeIntervalSince(now)) < 3 * 3600 { return (abs(out.timeIntervalSince(now)), f) }
                return nil
            }
            return candidates.min { $0.0 < $1.0 }?.1
        }
        return nil
    }

    // MARK: AirLabs v9 — GET /flight?flight_icao=

    static func parseAirLabs(_ obj: [String: Any]) throws -> FlightRoute? {
        if let err = obj["error"] as? [String: Any] {
            let code = (err["code"] as? String) ?? ""
            if code.contains("key") || code.contains("unknown_api") { throw LiveRouteError.unauthorized }
            if code.contains("limit") { throw LiveRouteError.rateLimited }
            return nil
        }
        guard let r = obj["response"] as? [String: Any], !r.isEmpty else { return nil }
        let dep = Airport(iata: r["dep_iata"] as? String, icao: r["dep_icao"] as? String,
                          name: r["dep_name"] as? String, city: r["dep_city"] as? String, position: nil)
        let arr = Airport(iata: r["arr_iata"] as? String, icao: r["arr_icao"] as? String,
                          name: r["arr_name"] as? String, city: r["arr_city"] as? String, position: nil)
        guard dep.iata != nil || dep.icao != nil, arr.iata != nil || arr.icao != nil else { return nil }
        return FlightRoute(airline: r["airline_name"] as? String, origin: dep, destination: arr, source: "AirLabs", verified: true)
    }
}
