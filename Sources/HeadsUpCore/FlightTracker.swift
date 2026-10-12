import Foundation
import Network
import os

private let log = Logger(subsystem: "app.headsup.HeadsUp", category: "feed")

/// An aircraft on screen, with the bookkeeping needed to move it smoothly between feed updates.
public struct TrackedAircraft: Identifiable, Sendable {
    public var id: String { aircraft.hex }
    public var aircraft: Aircraft
    public var distanceMeters: Double
    public var bearingFromCenter: Double
    public var firstSeen: Date
    public var lastUpdated: Date
    /// Earlier reported positions (WGS-84), oldest first, for drawing the flown path.
    public var history: [Coordinate] = []
    public static let historyLimit = 40
    /// Offset (degrees) between where the dot was drawn and where the new report puts it; decays to zero.
    var blendOffset: (lat: Double, lon: Double) = (0, 0)
    var blendStart: Date = .distantPast

    public static let blendDuration: TimeInterval = 1.6

    /// Where to draw the aircraft at `date`: dead-reckoned, eased from the previous drawn position.
    public func displayPosition(at date: Date) -> Coordinate {
        let p = aircraft.extrapolatedPosition(at: date)
        let t = min(max(date.timeIntervalSince(blendStart) / Self.blendDuration, 0), 1)
        let k = 1 - (1 - pow(1 - t, 3))   // ease-out cubic, remaining share of the offset
        return Coordinate(latitude: p.latitude + blendOffset.lat * k, longitude: p.longitude + blendOffset.lon * k)
    }
}

@MainActor
public final class FlightTracker: ObservableObject {
    public enum Status: Equatable, Sendable {
        case waitingForLocation
        case loading
        case live
        case offline
        case error(String)
    }

    @Published public private(set) var aircraft: [TrackedAircraft] = []
    @Published public private(set) var status: Status = .waitingForLocation
    @Published public private(set) var lastSuccess: Date?
    @Published public private(set) var activeFeedName: String?
    /// Successful polls in a row that returned no aircraft within the radius.
    @Published public private(set) var emptyStreak = 0
    /// Number of aircraft the feed returned before the exact radius filter (for diagnostics).
    @Published public private(set) var rawCount = 0
    /// Aircraft inside the radius before the airline/flight filter.
    @Published public private(set) var rawInRadius = 0

    public var center: Coordinate? {
        didSet {
            guard center != oldValue else { return }
            let moved = (oldValue == nil || center == nil) ? Double.infinity : Geo.distance(oldValue!, center!)
            if moved > 200 { refilter(); refreshNow() } else { refilter() }
        }
    }

    public var radiusKm: Double {
        didSet { if radiusKm != oldValue { refilter(); refreshNow() } }
    }

    /// When set, only aircraft matching it are shown.
    @Published public var filter: FlightFilter? {
        didSet { if filter != oldValue { refilter() } }
    }

    @Published public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { loop?.cancel(); loop = nil } else { refreshNow() }
        }
    }

    public var pollInterval: TimeInterval
    /// Reports older than this are dropped; also the time after which a failing feed clears the sky.
    public var staleAfter: TimeInterval = 60

    private let feeds: [FlightFeed]
    private var latest: [Aircraft] = []
    private var loop: Task<Void, Never>?
    private var failures = 0
    private var cooldowns: [String: (until: Date, strikes: Int)] = [:]
    private var pathMonitor: NWPathMonitor?
    private var networkAvailable = true
    private let now: () -> Date

    public init(feeds: [FlightFeed], radiusKm: Double, pollInterval: TimeInterval = 5,
                monitorNetwork: Bool = true, now: @escaping () -> Date = Date.init) {
        self.feeds = feeds
        self.radiusKm = radiusKm
        self.pollInterval = pollInterval
        self.now = now
        if monitorNetwork { startPathMonitor() }
    }

    deinit {
        loop?.cancel()
        pathMonitor?.cancel()
    }

    /// Cancels any pending wait and polls immediately.
    public func refreshNow() {
        loop?.cancel()
        guard !isPaused else { return }
        guard center != nil else { status = .waitingForLocation; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Fetches once, trying each feed in turn. Returns how long to wait before the next poll.
    @discardableResult
    public func pollOnce() async -> TimeInterval {
        guard let center else { status = .waitingForLocation; return pollInterval }
        if !networkAvailable {
            fail(.offline)
            return pollInterval
        }
        if lastSuccess == nil && status != .live { status = .loading }
        var firstError: FeedError?
        for feed in feedsInOrder() {
            do {
                let list = try await feed.fetch(center: center, radiusKm: radiusKm)
                if Task.isCancelled { return pollInterval }
                cooldowns[feed.name] = nil
                // The center may have moved while the request was in flight.
                guard self.center.map({ Geo.distance($0, center) < 1000 }) ?? false else { return 0.1 }
                activeFeedName = feed.name
                ingest(list)
                return pollInterval
            } catch is CancellationError {
                return pollInterval
            } catch let e as FeedError {
                log.notice("\(feed.name, privacy: .public) failed: \(e.localizedDescription, privacy: .public)")
                coolDown(feed.name, after: e)
                if firstError == nil || firstError == .offline { firstError = e }
            } catch {
                if firstError == nil { firstError = .network(error.localizedDescription) }
            }
            if Task.isCancelled { return pollInterval }
        }
        fail(firstError ?? .network("未知错误"))
        return min(60, pollInterval * pow(2, Double(min(failures, 4)) - 1))
    }

    /// Feeds not resting after an error, in preference order. If every feed is resting,
    /// the one whose rest ends first.
    func feedsInOrder() -> [FlightFeed] {
        let t = now()
        let ready = feeds.filter { (cooldowns[$0.name]?.until ?? .distantPast) <= t }
        if !ready.isEmpty { return ready }
        return feeds.min { (cooldowns[$0.name]?.until ?? .distantPast) < (cooldowns[$1.name]?.until ?? .distantPast) }.map { [$0] } ?? []
    }

    /// Rests a feed that rate-limited us or failed on the server side, backing off on repeats,
    /// so we don't keep a community service's limiter tripped by retrying every poll.
    private func coolDown(_ name: String, after error: FeedError) {
        let base: TimeInterval
        switch error {
        case .rateLimited: base = 30
        case .http(let code) where code >= 500: base = 20
        case .badResponse: base = 20
        default: return
        }
        let strikes = (cooldowns[name]?.strikes ?? 0) + 1
        let rest = min(300, base * pow(2, Double(strikes - 1)))
        cooldowns[name] = (now().addingTimeInterval(rest), strikes)
    }

    /// Replaces the sky with a fresh report.
    public func ingest(_ list: [Aircraft]) {
        let t = now()
        failures = 0
        lastSuccess = t
        status = .live
        rawCount = list.count
        latest = list.filter { t.timeIntervalSince($0.positionTime) < staleAfter }
        refilter()
        emptyStreak = rawInRadius == 0 ? emptyStreak + 1 : 0
    }

    private func fail(_ error: FeedError) {
        failures += 1
        status = error == .offline ? .offline : .error(error.errorDescription ?? "错误")
        if let last = lastSuccess, now().timeIntervalSince(last) > staleAfter {
            latest = []
            refilter()
        } else if lastSuccess == nil {
            latest = []
            refilter()
        }
    }

    /// Applies the exact circular radius to the latest report and updates the tracked set.
    func refilter() {
        guard let center else { aircraft = []; return }
        let t = now()
        let limit = radiusKm * 1000
        let previous = Dictionary(uniqueKeysWithValues: aircraft.map { ($0.id, $0) })
        var next: [TrackedAircraft] = []
        var inRadius = 0
        for a in latest {
            let d = Geo.distance(center, a.position)
            guard d <= limit else { continue }
            inRadius += 1
            if let filter, !filter.matches(a) { continue }
            var item = TrackedAircraft(aircraft: a, distanceMeters: d,
                                       bearingFromCenter: Geo.bearing(from: center, to: a.position),
                                       firstSeen: t, lastUpdated: t)
            if let old = previous[a.id] {
                item.firstSeen = old.firstSeen
                item.history = old.history
                if old.aircraft.position != a.position {
                    item.history.append(old.aircraft.position)
                    if item.history.count > TrackedAircraft.historyLimit {
                        item.history.removeFirst(item.history.count - TrackedAircraft.historyLimit)
                    }
                }
                if old.aircraft.positionTime != a.positionTime {
                    let drawn = old.displayPosition(at: t)
                    let fresh = a.extrapolatedPosition(at: t)
                    let dLat = drawn.latitude - fresh.latitude, dLon = drawn.longitude - fresh.longitude
                    // Snap instead of gliding across the map after a long gap or a bad report.
                    if abs(dLat) < 0.05 && abs(dLon) < 0.05 {
                        item.blendOffset = (dLat, dLon)
                        item.blendStart = t
                    }
                } else {
                    item.blendOffset = old.blendOffset
                    item.blendStart = old.blendStart
                    item.lastUpdated = old.lastUpdated
                }
            }
            next.append(item)
        }
        next.sort { $0.distanceMeters < $1.distanceMeters }
        rawInRadius = inRadius
        aircraft = next
    }

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.networkAvailable != ok else { return }
                self.networkAvailable = ok
                if ok { self.refreshNow() } else { self.fail(.offline) }
            }
        }
        m.start(queue: DispatchQueue(label: "HeadsUp.path"))
        pathMonitor = m
    }
}
