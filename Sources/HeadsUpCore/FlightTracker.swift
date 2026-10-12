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
    /// For wide views queried in several pieces: true when some pieces failed this round.
    @Published public private(set) var partialCoverage = false
    /// Pieces done and total while a wide view is being queried; nil otherwise.
    @Published public private(set) var wideProgress: (done: Int, total: Int)?

    /// Wider views move slowly on screen (dead reckoning fills in between reports), so they are
    /// polled less often, which also keeps the free feeds' rate limits at bay.
    var adaptiveInterval: TimeInterval {
        radiusKm <= 50 ? pollInterval : (radiusKm <= 200 ? pollInterval * 1.6 : pollInterval * 2)
    }

    /// How long an aircraft absent from the latest report is kept (moving by dead reckoning).
    public static let missingGrace: TimeInterval = 25
    /// Rate-limit or server errors within this long of the last good report are retried quietly.
    public static let quietErrorWindow: TimeInterval = 30

    /// The feeds answer within a circle of about 250 NM (463 km); wider views are queried piecewise.
    public static let maxSingleQueryKm = 450.0

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
    private var rotation = 0
    private var lastSweep: (center: Coordinate, radius: Double)?
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
        // Keep showing the last error while retrying, rather than flipping back to "loading".
        if lastSuccess == nil && failures == 0 { status = .loading }
        let plan = Self.queryPlan(center: center, radiusKm: radiusKm)
        rotation += 1
        if plan.count > 1 { return await pollWide(center: center, plan: plan) }
        partialCoverage = false
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
                return adaptiveInterval
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

    /// Centers of query circles (radius `maxSingleQueryKm`) that together cover the disk of
    /// `radiusKm` around `center`: points of a hexagonal lattice whose circles reach the disk.
    public static func queryPlan(center: Coordinate, radiusKm: Double) -> [Coordinate] {
        let r = maxSingleQueryKm
        guard radiusKm > r else { return [center] }
        // A hexagonal lattice with spacing √3·r leaves no point farther than r from a center;
        // a little tighter for overlap.
        let spacing = 3.0.squareRoot() * r * 0.95
        let rings = Int(((radiusKm + r) / spacing).rounded(.up)) + 1
        var out = [center]
        for j in -rings...rings {
            for i in -rings...rings where !(i == 0 && j == 0) {
                let x = spacing * (Double(i) + Double(j) / 2)
                let y = spacing * Double(j) * 3.0.squareRoot() / 2
                let d = (x * x + y * y).squareRoot()
                guard d - r < radiusKm else { continue }
                let bearing = atan2(x, y) * 180 / .pi
                out.append(Geo.destination(from: center, bearing: bearing, meters: d * 1000))
            }
        }
        return out
    }

    /// Queries a wide view piece by piece, spreading requests across feeds to respect rate limits.
    private func pollWide(center: Coordinate, plan: [Coordinate]) async -> TimeInterval {
        var merged: [String: Aircraft] = [:]
        var failed = 0
        var firstError: FeedError?
        var used = Set<String>()
        defer { wideProgress = nil }
        // First sweep of a new area: show pieces as they arrive rather than waiting for all of them.
        let firstSweep = lastSweep.map { Geo.distance($0.center, center) > 1000 || abs($0.radius - radiusKm) > 1 } ?? true
        for (i, point) in plan.enumerated() {
            wideProgress = (i, plan.count)
            let feeds = feedsInOrder()
            guard !feeds.isEmpty else { break }
            // Start with this piece's feed; if it fails, give the other feed one try.
            let order = Array(feeds[(i % feeds.count)...] + feeds[..<(i % feeds.count)])
            var got = false
            for feed in order.prefix(2) {
                do {
                    let list = try await feed.fetch(center: point, radiusKm: Self.maxSingleQueryKm)
                    used.insert(feed.name)
                    cooldowns[feed.name] = nil
                    for a in list where (merged[a.hex]?.positionTime ?? .distantPast) < a.positionTime { merged[a.hex] = a }
                    got = true
                    break
                } catch is CancellationError {
                    return pollInterval
                } catch let e as FeedError {
                    log.notice("\(feed.name, privacy: .public) failed: \(e.localizedDescription, privacy: .public)")
                    coolDown(feed.name, after: e)
                    if firstError == nil { firstError = e }
                } catch {
                    if firstError == nil { firstError = .network(error.localizedDescription) }
                }
                if Task.isCancelled { return pollInterval }
            }
            if !got { failed += 1 }
            if got && firstSweep && i % 3 == 2,
               self.center.map({ Geo.distance($0, center) < 1000 }) ?? false {
                ingest(Array(merged.values))
            }
            if Task.isCancelled { return pollInterval }
            // About one request per second per feed.
            try? await Task.sleep(nanoseconds: UInt64(1.1 / Double(max(1, feeds.count)) * 1_000_000_000))
            if Task.isCancelled { return pollInterval }
        }
        if failed == plan.count {
            fail(firstError ?? .network("未知错误"))
            return min(60, pollInterval * pow(2, Double(min(failures, 4)) - 1))
        }
        guard self.center.map({ Geo.distance($0, center) < 1000 }) ?? false else { return 0.1 }
        lastSweep = (center, radiusKm)
        activeFeedName = used.sorted().joined(separator: " + ")
        partialCoverage = failed > 0
        ingest(Array(merged.values))
        // A full sweep takes a while; don't start the next one straight away.
        return max(pollInterval, Double(plan.count) * 1.2)
    }

    /// Feeds not resting after an error, in preference order. If every feed is resting,
    /// the one whose rest ends first.
    func feedsInOrder() -> [FlightFeed] {
        let t = now()
        let ready = feeds.filter { (cooldowns[$0.name]?.until ?? .distantPast) <= t }
        // Take turns as the first choice, so each community feed sees half the requests.
        if !ready.isEmpty {
            let k = rotation % ready.count
            return Array(ready[k...] + ready[..<k])
        }
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
        let fresh = list.filter { t.timeIntervalSince($0.positionTime) < staleAfter }
        // An aircraft missing from one report (the other feed doesn't hear it, or its signal
        // dropped for a moment) stays for a short while instead of blinking out and back.
        let ids = Set(fresh.map(\.hex))
        let carried = latest.filter { !ids.contains($0.hex) && t.timeIntervalSince($0.positionTime) < Self.missingGrace }
        latest = fresh + carried
        refilter()
        emptyStreak = rawInRadius == 0 ? emptyStreak + 1 : 0
    }

    private func fail(_ error: FeedError) {
        failures += 1
        // A busy community feed refusing one request isn't worth an alarm while the sky on screen
        // is still fresh: keep showing it and retry. Offline is always reported.
        if error != .offline, let last = lastSuccess, now().timeIntervalSince(last) < Self.quietErrorWindow { return }
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
