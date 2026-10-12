import XCTest
@testable import HeadsUpCore

final class GeoTests: XCTestCase {
    func testDistanceAndDestinationRoundTrip() {
        let sfo = Coordinate(latitude: 37.6213, longitude: -122.379)
        let p = Geo.destination(from: sfo, bearing: 45, meters: 20_000)
        XCTAssertEqual(Geo.distance(sfo, p), 20_000, accuracy: 1)
        XCTAssertEqual(Geo.bearing(from: sfo, to: p), 45, accuracy: 0.1)
        XCTAssertEqual(Geo.compassName(44), "东北")
        XCTAssertEqual(Geo.compassName(359), "北")
    }

    func testGCJConversion() {
        let wgs = Coordinate(latitude: 39.90306, longitude: 116.39167)
        let gcj = ChinaCoordinate.wgs84ToGcj02(wgs)
        // Beijing shifts by roughly 500–600 m, mostly eastward.
        let shift = Geo.distance(wgs, gcj)
        XCTAssertGreaterThan(shift, 400)
        XCTAssertLessThan(shift, 800)
        XCTAssertEqual(Geo.distance(ChinaCoordinate.gcj02ToWgs84(gcj), wgs), 0, accuracy: 1)
    }

    func testMainlandChinaDetection() {
        XCTAssertTrue(ChinaCoordinate.isInMainlandChina(Coordinate(latitude: 31.23, longitude: 121.47)))   // Shanghai
        XCTAssertFalse(ChinaCoordinate.isInMainlandChina(Coordinate(latitude: 22.30, longitude: 114.17)))  // Hong Kong
        XCTAssertFalse(ChinaCoordinate.isInMainlandChina(Coordinate(latitude: 25.03, longitude: 121.56)))  // Taipei
        XCTAssertFalse(ChinaCoordinate.isInMainlandChina(Coordinate(latitude: 37.62, longitude: -122.38))) // SFO
        let sfo = Coordinate(latitude: 37.62, longitude: -122.38)
        XCTAssertEqual(ChinaCoordinate.toMapDatum(sfo, enabled: true), sfo)
    }
}

final class DecoderTests: XCTestCase {
    let lol = """
    {"ac":[
     {"hex":"a12ac5","flight":"UAL2462 ","r":"N12345","t":"B39M","alt_baro":"ground","gs":6.8,"track":120,"lat":37.62,"lon":-122.38,"seen_pos":0.5},
     {"hex":"~2c1a0e","alt_baro":11300,"gs":300,"track":320,"baro_rate":1600,"lat":37.7,"lon":-122.4,"seen_pos":2},
     {"hex":"abcdef","flight":"NOPOS"}
    ],"msg":"No error","now":1791772493501,"total":3}
    """

    let fi = """
    {"now":1791772494.000,"aircraft":[{"hex":"8990b1","flight":"EVA851  ","alt_baro":1925,"lat":22.28,"lon":113.76,"track":70.3,"gs":160}],"resultCount":1}
    """

    func testDecodesAdsbLol() throws {
        let received = Date(timeIntervalSince1970: 1791772493.6)
        let list = try ReadsbDecoder.decode(Data(lol.utf8), receivedAt: received)
        XCTAssertEqual(list.count, 2, "aircraft without a position are skipped")
        let ground = list[0]
        XCTAssertEqual(ground.callsign, "UAL2462")
        XCTAssertTrue(ground.onGround)
        XCTAssertEqual(ground.typeCode, "B39M")
        XCTAssertEqual(ground.positionTime.timeIntervalSince1970, 1791772493.001, accuracy: 0.01)
        let tisb = list[1]
        XCTAssertNil(tisb.callsign)
        XCTAssertEqual(tisb.displayName, "2C1A0E")
        XCTAssertEqual(tisb.altitudeFt, 11300)
        XCTAssertEqual(tisb.trend, .climbing)
    }

    func testDecodesAdsbFi() throws {
        let list = try ReadsbDecoder.decode(Data(fi.utf8), receivedAt: Date(timeIntervalSince1970: 1791772494))
        XCTAssertEqual(list.first?.callsign, "EVA851")
        XCTAssertEqual(list.first?.altitudeFt, 1925)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ReadsbDecoder.decode(Data("<html>429</html>".utf8)))
        XCTAssertThrowsError(try ReadsbDecoder.decode(Data(#"{"msg":"bad"}"#.utf8)))
    }

    func testExtrapolation() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let a = Aircraft(hex: "abc123", position: Coordinate(latitude: 0, longitude: 0), groundSpeedKt: 100, trackDeg: 0, positionTime: t0)
        let p = a.extrapolatedPosition(at: t0.addingTimeInterval(36))
        XCTAssertEqual(Geo.distance(a.position, p), 1852, accuracy: 2)   // 100 kt × 36 s = 1 NM
        // Capped so lost aircraft don't drift away.
        let far = a.extrapolatedPosition(at: t0.addingTimeInterval(3600))
        XCTAssertEqual(Geo.distance(a.position, far), 100 * 1852 / 3600 * 45, accuracy: 5)
    }

    func testQueryRadius() {
        XCTAssertEqual(ReadsbFeed.queryRadiusNM(forKm: 20), 12)
        XCTAssertEqual(ReadsbFeed.queryRadiusNM(forKm: 1000), 250)
    }
}

// MARK: - Tracker

final class StubFeed: FlightFeed, @unchecked Sendable {
    let name: String
    var result: Result<[Aircraft], FeedError>
    var calls = 0
    init(_ name: String, _ result: Result<[Aircraft], FeedError>) { self.name = name; self.result = result }
    func fetch(center: Coordinate, radiusKm: Double) async throws -> [Aircraft] {
        calls += 1
        return try result.get()
    }
}

@MainActor
final class TrackerTests: XCTestCase {
    let center = Coordinate(latitude: 37.6213, longitude: -122.379)
    var clock = Date(timeIntervalSince1970: 2_000_000)

    func plane(_ hex: String, km: Double, bearing: Double = 0, callsign: String? = nil) -> Aircraft {
        Aircraft(hex: hex, callsign: callsign, position: Geo.destination(from: center, bearing: bearing, meters: km * 1000),
                 altitudeFt: 10000, groundSpeedKt: 250, trackDeg: 90, positionTime: clock)
    }

    func makeTracker(_ feeds: [FlightFeed], radius: Double = 20) -> FlightTracker {
        let t = FlightTracker(feeds: feeds, radiusKm: radius, monitorNetwork: false, now: { [unowned self] in self.clock })
        t.isPaused = true          // drive polls by hand
        t.center = center
        return t
    }

    func testFiltersByExactRadiusAndUpdatesOnRadiusChange() async {
        let feed = StubFeed("a", .success([plane("in", km: 19.9), plane("out", km: 20.1), plane("far", km: 35)]))
        let t = makeTracker([feed])
        await t.pollOnce()
        XCTAssertEqual(t.aircraft.map(\.id), ["in"])
        XCTAssertEqual(t.status, .live)
        t.radiusKm = 40
        XCTAssertEqual(Set(t.aircraft.map(\.id)), ["in", "out", "far"])
        t.radiusKm = 10
        XCTAssertTrue(t.aircraft.isEmpty)
    }

    func testFallsBackToSecondFeed() async {
        let a = StubFeed("a", .failure(.http(503)))
        let b = StubFeed("b", .success([plane("x", km: 5)]))
        let t = makeTracker([a, b])
        await t.pollOnce()
        XCTAssertEqual(t.activeFeedName, "b")
        XCTAssertEqual(t.aircraft.count, 1)
    }

    func testRateLimitedFeedRestsInsteadOfBeingRetriedEveryPoll() async {
        let a = StubFeed("a", .failure(.rateLimited))
        let b = StubFeed("b", .success([plane("x", km: 5)]))
        let t = makeTracker([a, b])
        await t.pollOnce()
        await t.pollOnce()
        XCTAssertEqual(a.calls, 1, "rate-limited feed is skipped during its cool-down")
        XCTAssertEqual(b.calls, 2)
        clock = clock.addingTimeInterval(31)
        a.result = .success([])
        await t.pollOnce()
        XCTAssertEqual(a.calls, 2, "tried again after the cool-down")
        XCTAssertEqual(t.activeFeedName, "a")
    }

    func testErrorStatesAndStaleClearing() async {
        let feed = StubFeed("a", .success([plane("x", km: 5)]))
        let t = makeTracker([feed])
        await t.pollOnce()
        XCTAssertEqual(t.aircraft.count, 1)

        feed.result = .failure(.offline)
        await t.pollOnce()
        XCTAssertEqual(t.status, .offline)
        XCTAssertEqual(t.aircraft.count, 1, "recent data stays up through a short outage")

        feed.result = .failure(.http(500))
        clock = clock.addingTimeInterval(61)
        await t.pollOnce()
        XCTAssertEqual(t.status, .error("数据服务返回错误 HTTP 500"))
        XCTAssertTrue(t.aircraft.isEmpty, "stale aircraft are cleared, not shown as live")
    }

    func testEmptySkyCountsStreak() async {
        let feed = StubFeed("a", .success([]))
        let t = makeTracker([feed])
        await t.pollOnce()
        await t.pollOnce()
        XCTAssertEqual(t.status, .live)
        XCTAssertEqual(t.emptyStreak, 2)
    }

    func testNoCenterWaitsForLocation() async {
        let t = FlightTracker(feeds: [StubFeed("a", .success([]))], radiusKm: 20, monitorNetwork: false)
        t.isPaused = true
        await t.pollOnce()
        XCTAssertEqual(t.status, .waitingForLocation)
    }

    func testHistoryAndBlendingOnUpdate() async {
        let feed = StubFeed("a", .success([plane("x", km: 5)]))
        let t = makeTracker([feed])
        await t.pollOnce()
        clock = clock.addingTimeInterval(5)
        var moved = plane("x", km: 6)
        moved.positionTime = clock
        feed.result = .success([moved])
        await t.pollOnce()
        XCTAssertEqual(t.aircraft.first?.history.count, 1)
        // Right after the update the dot is still near where it was drawn, then eases to the report.
        let drawnNow = t.aircraft[0].displayPosition(at: clock)
        let later = t.aircraft[0].displayPosition(at: clock.addingTimeInterval(TrackedAircraft.blendDuration))
        XCTAssertGreaterThan(Geo.distance(drawnNow, moved.position), 300)
        XCTAssertLessThan(Geo.distance(later, moved.extrapolatedPosition(at: clock.addingTimeInterval(TrackedAircraft.blendDuration))), 1)
    }

    func testAirlineFilter() async {
        let feed = StubFeed("a", .success([plane("u", km: 3, callsign: "UAL1577"), plane("s", km: 4, callsign: "SWA920"),
                                           plane("n", km: 5, callsign: nil)]))
        let t = makeTracker([feed])
        await t.pollOnce()
        t.filter = FlightFilter(tokens: [.airline("UAL")])
        XCTAssertEqual(t.aircraft.map(\.id), ["u"])
        XCTAssertEqual(t.rawInRadius, 3)
        t.filter = nil
        XCTAssertEqual(t.aircraft.count, 3)
    }
}

// MARK: - Filter, routes, settings, terrain

final class FilterTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(FlightFilter.classify("ual"), .icaoAirline("UAL"))
        XCTAssertEqual(FlightFilter.classify("UAL1577"), .icaoCallsign("UAL1577"))
        XCTAssertEqual(FlightFilter.classify("MU"), .iataAirline("MU"))
        XCTAssertEqual(FlightFilter.classify("MU5101"), .iataFlight(airline: "MU", number: "5101"))
        XCTAssertEqual(FlightFilter.classify("3U8888"), .iataFlight(airline: "3U", number: "8888"))
        XCTAssertEqual(FlightFilter.classify("UA0157"), .iataFlight(airline: "UA", number: "157"))
        if case .invalid = FlightFilter.classify("U$A") {} else { XCTFail() }
    }

    func testBuildAndMatch() {
        let r = FlightFilter.build(from: "UAL, MU5101，CA；XX9 , ??", iataToICAO: ["MU": ["CES", "OTT"], "CA": ["CCA"]])
        XCTAssertEqual(r.filter.tokens, [.airline("UAL"), .callsign("CES5101"), .callsign("OTT5101"), .airline("CCA")])
        XCTAssertEqual(r.unresolved, ["XX9"])
        XCTAssertEqual(r.invalid, ["??"])
        func a(_ cs: String?) -> Aircraft { Aircraft(hex: "1", callsign: cs, position: Coordinate(latitude: 0, longitude: 0), positionTime: Date()) }
        XCTAssertTrue(r.filter.matches(a("UAL1")))
        XCTAssertTrue(r.filter.matches(a("CES5101")))
        XCTAssertFalse(r.filter.matches(a("CES5102")))
        XCTAssertFalse(r.filter.matches(a("UALX")))
        XCTAssertFalse(r.filter.matches(a(nil)))
    }
}

final class RouteTests: XCTestCase {
    func testParseAndPlausibility() throws {
        let json = """
        {"flightroute":{"callsign":"UAL1577","airline":{"name":"United Airlines"},
         "origin":{"iata_code":"RNO","icao_code":"KRNO","name":"Reno","municipality":"Reno","latitude":39.4991,"longitude":-119.768},
         "destination":{"iata_code":"SFO","icao_code":"KSFO","name":"San Francisco","municipality":"San Francisco","latitude":37.619,"longitude":-122.375}}}
        """
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let r = try XCTUnwrap(RouteService.parseRoute(obj))
        XCTAssertEqual(r.origin.code, "RNO")
        XCTAssertEqual(r.airline, "United Airlines")
        let nearSFO = Coordinate(latitude: 37.69, longitude: -122.42)
        // Descending toward SFO: consistent with RNO→SFO.
        XCTAssertTrue(r.isPlausible(for: nearSFO, track: 140, verticalRateFpm: -1200))
        // Climbing away from SFO: this is the return leg reusing the callsign.
        XCTAssertFalse(r.isPlausible(for: nearSFO, track: 320, verticalRateFpm: 1600))
        // Far off the corridor.
        XCTAssertFalse(r.isPlausible(for: Coordinate(latitude: 47.45, longitude: -122.3)))
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsPersistenceAndClamp() {
        let suite = "headsup.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s1 = SettingsStore(defaults: d)
        XCTAssertEqual(s1.radiusKm, 20, "default tracking radius is 20 km")
        XCTAssertEqual(s1.mapLook, .paper)
        s1.radiusKm = 35
        s1.appearance = .dark
        s1.panelLevel = .floating
        s1.filterText = "UAL"
        s1.filterEnabled = true
        s1.manualLocation = Coordinate(latitude: 1, longitude: 2)
        let s2 = SettingsStore(defaults: d)
        XCTAssertEqual(s2.radiusKm, 35)
        XCTAssertEqual(s2.appearance, .dark)
        XCTAssertEqual(s2.panelLevel, .floating)
        XCTAssertEqual(s2.filterText, "UAL")
        XCTAssertTrue(s2.filterEnabled)
        XCTAssertEqual(s2.manualLocation, Coordinate(latitude: 1, longitude: 2))
        s2.radiusKm = 9999
        XCTAssertEqual(s2.radiusKm, 150)
        s2.radiusKm = 1
        XCTAssertEqual(s2.radiusKm, 5)
    }
}

final class TerrainTests: XCTestCase {
    func testTilesCoverRect() {
        let rect = WorldRect.around(Coordinate(latitude: 37.62, longitude: -122.38), halfWidthMeters: 21_739)
        let z = TerrainRenderer.zoom(for: rect, pixels: 720)
        let tiles = TerrainRenderer.tiles(for: rect, zoom: z)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, 25)
        let p = WorldRect.point(Coordinate(latitude: 37.62, longitude: -122.38))
        XCTAssertEqual(rect.minX + rect.width / 2, p.x, accuracy: 1e-9)
        XCTAssertEqual(WorldRect.latitude(y: p.y), 37.62, accuracy: 1e-6)
    }

    func testContourStep() {
        XCTAssertEqual(TerrainRenderer.contourStep(min: 0, max: 8), 5, "never finer than 5 m")
        XCTAssertEqual(TerrainRenderer.contourStep(min: 0, max: 400), 50)
        XCTAssertEqual(TerrainRenderer.contourStep(min: 0, max: 3000), 500)
    }

    func testRenderMarksWater() {
        // Left half sea, right half a 300 m hill.
        let n = 64
        var e = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n { e[y * n + x] = x < n / 2 ? -20 : Float(300 * (x - n / 2)) / Float(n / 2) } }
        let rect = WorldRect(minX: 0.1, minY: 0.3, width: 0.001, height: 0.001)
        let img = try! XCTUnwrap(TerrainRenderer.render(elevation: e, n: n, pixelScale: 1, rect: rect, style: .light))
        XCTAssertEqual(img.width, n)
        let data = img.dataProvider!.data! as Data
        let water = TerrainRenderer.Style.light.water
        let px = (10 * n + 5) * 4
        XCTAssertEqual(Double(data[px]) / 255, water.r, accuracy: 0.03)
        XCTAssertEqual(Double(data[px + 2]) / 255, water.b, accuracy: 0.03)
    }

    func testDecodeTerrarium() throws {
        // Build a 256×256 PNG where every pixel encodes 100 m: 32868 = 128*256 + 100.
        let size = 256
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) { px[i * 4] = 128; px[i * 4 + 1] = 100; px[i * 4 + 2] = 0 }
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        let tile = try XCTUnwrap(ElevationTile.decodeTerrarium(data as Data))
        XCTAssertEqual(tile.elevations[1234], 100, accuracy: 0.01)
    }
}
