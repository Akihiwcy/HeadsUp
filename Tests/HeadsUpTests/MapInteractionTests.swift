import AppKit
import HeadsUpCore
import XCTest
@testable import HeadsUp

/// Deliberately resumes cancelled waits too, so tests exercise stale callbacks without sleeping.
@MainActor
private final class ScrollWaiter {
    var waits: [CheckedContinuation<Void, Error>] = []
    func wait() async throws {
        try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func finishFirst() { waits.removeFirst().resume() }
    func finishAll() { while !waits.isEmpty { finishFirst() } }
}

@MainActor
final class MapInteractionTests: XCTestCase {
    private let origin = Coordinate(latitude: 37.62, longitude: -122.38)

    private func model(_ waiter: ScrollWaiter, located: Bool = true) -> AppModel {
        let suite = "headsup.interaction-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.mapDragEnabled = true
        if located {
            settings.manualLocation = origin
            settings.useManualLocation = true
        }
        let tracker = FlightTracker(feeds: [], radiusKm: settings.radiusKm, monitorNetwork: false)
        tracker.isPaused = true // no feeds, network polling, location requests or terrain rendering
        return AppModel(settings: settings, location: LocationService(), tracker: tracker, routes: RouteService(),
                        waitForScrollEnd: { try await waiter.wait() })
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Main-actor task did not reach the expected state", file: file, line: line)
    }

    func testBurstCommitsOnlyAfterLatestWaitCompletes() async {
        let waiter = ScrollWaiter(), m = model(waiter)
        defer { waiter.finishAll() }
        m.scrollZoom(by: 1, precise: false)
        await eventually { waiter.waits.count == 1 }
        m.scrollZoom(by: 1, precise: false)
        await eventually { waiter.waits.count == 2 }
        XCTAssertTrue(m.isInteracting)
        XCTAssertEqual(m.tracker.radiusKm, 20)
        waiter.finishFirst() // cancelled timer must not commit or end the newer interaction
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(m.isInteracting)
        XCTAssertEqual(m.tracker.radiusKm, 20)
        waiter.finishFirst()
        await eventually { !m.isInteracting }
        XCTAssertEqual(m.tracker.radiusKm, m.displayRadius)
        XCTAssertEqual(m.tracker.center, m.displayCenter)
        XCTAssertEqual(m.displayRadius, 20 / (1.2 * 1.2), accuracy: 1e-9)
    }

    func testPanTakesOverWheelAndDefersBothQueryChangesUntilMouseUp() async {
        let waiter = ScrollWaiter(), m = model(waiter)
        defer { waiter.finishAll() }
        m.scrollZoom(by: 3, precise: false)
        await eventually { waiter.waits.count == 1 }
        let panned = Coordinate(latitude: 38, longitude: -122)
        m.pan(to: panned, final: false)
        XCTAssertEqual(m.tracker.radiusKm, 20, "Do not query the old center with the new radius")
        XCTAssertEqual(m.tracker.center, origin)
        waiter.finishFirst()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(m.isInteracting)
        m.pan(to: panned, final: true)
        XCTAssertFalse(m.isInteracting)
        XCTAssertEqual(m.tracker.center, panned)
        XCTAssertEqual(m.tracker.radiusKm, m.displayRadius)
    }

    func testPinchTakesOverWheelWithoutStaleCommit() async {
        let waiter = ScrollWaiter(), m = model(waiter)
        defer { waiter.finishAll() }
        m.scrollZoom(by: 1, precise: false)
        await eventually { waiter.waits.count == 1 }
        m.zoom(to: 10, final: false)
        waiter.finishFirst()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(m.isInteracting)
        XCTAssertEqual(m.tracker.radiusKm, 20)
        m.zoom(to: 8, final: true)
        XCTAssertFalse(m.isInteracting)
        XCTAssertEqual(m.tracker.radiusKm, 8)
    }

    func testResetDisableAndRadiusChangeCancelPendingCommit() async {
        for action in ["reset", "disable", "radius"] {
            let waiter = ScrollWaiter(), m = model(waiter)
            m.scrollZoom(by: 2, precise: false)
            await eventually { waiter.waits.count == 1 }
            switch action {
            case "reset": m.resetView()
            case "disable": m.settings.mapDragEnabled = false
            default: m.settings.radiusKm = 35
            }
            waiter.finishAll()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertFalse(m.isInteracting, action)
            XCTAssertNil(m.viewRadiusKm, action)
            XCTAssertEqual(m.tracker.radiusKm, action == "radius" ? 35 : 20, action)
        }
    }

    func testDisabledUnlocatedAndInvalidScrollDoNotStartInteraction() async {
        let waiter = ScrollWaiter(), m = model(waiter)
        m.settings.mapDragEnabled = false
        m.scrollZoom(by: 1, precise: false)
        XCTAssertNil(m.viewRadiusKm)
        m.settings.mapDragEnabled = true
        for delta in [0.0, .nan, .infinity, -.infinity] { m.scrollZoom(by: delta, precise: false) }
        XCTAssertNil(m.viewRadiusKm)
        let unlocated = model(waiter, located: false)
        unlocated.scrollZoom(by: 1, precise: false)
        XCTAssertNil(unlocated.viewRadiusKm)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(waiter.waits.isEmpty)
        XCTAssertFalse(m.isInteracting)
        XCTAssertFalse(unlocated.isInteracting)
    }

    func testScrollAtLimitStillFinishesAndCommits() async {
        let waiter = ScrollWaiter(), m = model(waiter)
        defer { waiter.finishAll() }
        m.scrollZoom(by: -1000, precise: true)
        await eventually { waiter.waits.count == 1 }
        XCTAssertEqual(m.displayRadius, 1200)
        waiter.finishFirst()
        await eventually { !m.isInteracting }
        XCTAssertEqual(m.tracker.radiusKm, 1200)
    }

    func testScrollBarrierRequiresReceiptAndCommit() async throws {
        let waiter = ScrollWaiter(), m = model(waiter)
        defer { waiter.finishAll() }
        let marker = Int64.random(in: 1...Int64.max)
        do {
            try await TestControl.waitForScroll(marker: marker, model: m, timeout: .zero)
            XCTFail("An idle model is not proof that a posted event has arrived")
        } catch {}
        m.scrollZoom(by: 1, precise: false)
        await eventually { waiter.waits.count == 1 }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                      wheel1: 1, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.eventSourceUserData, value: marker)
        TestControl.noteScroll(try XCTUnwrap(NSEvent(cgEvent: cg)))
        do {
            try await TestControl.waitForScroll(marker: marker, model: m, timeout: .zero)
            XCTFail("Receiving the last event is not proof that the viewport has committed")
        } catch {}
        waiter.finishFirst()
        await eventually { !m.isInteracting }
        try await TestControl.waitForScroll(marker: marker, model: m, timeout: .zero)
        XCTAssertEqual(m.tracker.radiusKm, m.displayRadius)
    }

    func testDumpProjectionUsesPannedCenterAndZoomedRadius() {
        let waiter = ScrollWaiter(), m = model(waiter)
        let panned = Coordinate(latitude: 38, longitude: -122)
        m.pan(to: panned, final: true)
        let centerPoint = TestControl.paperPoint(panned, model: m, side: 400)
        XCTAssertEqual(centerPoint[0], 200, accuracy: 1e-6)
        XCTAssertEqual(centerPoint[1], 200, accuracy: 1e-6)
        let east = Coordinate(latitude: 38, longitude: -121.98)
        let before = TestControl.paperPoint(east, model: m, side: 400)[0] - 200
        m.zoom(to: 10, final: true)
        let after = TestControl.paperPoint(east, model: m, side: 400)[0] - 200
        XCTAssertEqual(after, before * 2, accuracy: 1e-6)
        m.settings.mapLook = .standard
        XCTAssertTrue(TestControl.paperPoint(east, model: m, side: 400).isEmpty,
                      "Do not report guessed screen positions for Apple's actual visible rect")
    }
}
