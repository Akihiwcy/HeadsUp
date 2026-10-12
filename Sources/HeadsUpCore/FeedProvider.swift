import Foundation

public protocol FlightFeed: Sendable {
    var name: String { get }
    func fetch(center: Coordinate, radiusKm: Double) async throws -> [Aircraft]
}

/// A readsb-compatible point/radius endpoint (adsb.lol, adsb.fi, …).
public struct ReadsbFeed: FlightFeed {
    public let name: String
    let makeURL: @Sendable (Coordinate, Int) -> URL
    let session: URLSession

    public init(name: String, session: URLSession = .shared, makeURL: @escaping @Sendable (Coordinate, Int) -> URL) {
        self.name = name
        self.session = session
        self.makeURL = makeURL
    }

    public static func adsbLol(session: URLSession = .shared, base: String = "https://api.adsb.lol") -> ReadsbFeed {
        ReadsbFeed(name: "adsb.lol", session: session) { c, nm in
            URL(string: "\(base)/v2/point/\(fmt(c.latitude))/\(fmt(c.longitude))/\(nm)")!
        }
    }

    public static func adsbFi(session: URLSession = .shared, base: String = "https://opendata.adsb.fi") -> ReadsbFeed {
        ReadsbFeed(name: "adsb.fi", session: session) { c, nm in
            URL(string: "\(base)/api/v2/lat/\(fmt(c.latitude))/lon/\(fmt(c.longitude))/dist/\(nm)")!
        }
    }

    static func fmt(_ v: Double) -> String { String(format: "%.4f", v) }

    /// Query radius in nautical miles: rounded up, plus a small margin, capped at the API limit.
    public static func queryRadiusNM(forKm km: Double) -> Int {
        min(250, max(1, Int((km / 1.852).rounded(.up)) + 1))
    }

    public func fetch(center: Coordinate, radiusKm: Double) async throws -> [Aircraft] {
        var req = URLRequest(url: makeURL(center, Self.queryRadiusNM(forKm: radiusKm)))
        req.timeoutInterval = 12
        req.setValue("HeadsUp/1.0 (macOS desktop aircraft widget)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw FeedError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw FeedError.network(e.localizedDescription)
            }
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw FeedError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw FeedError.http(http.statusCode) }
        }
        do {
            return try ReadsbDecoder.decode(data)
        } catch let e as FeedError {
            throw e
        } catch {
            throw FeedError.badResponse("无法解析")
        }
    }
}
