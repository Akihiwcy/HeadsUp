import XCTest
@testable import HeadsUp

final class ScrollZoomTests: XCTestCase {
    private let range = 2.0...1200.0

    private func zoom(_ radius: Double, _ delta: Double, precise: Bool = false) -> Double {
        ScrollZoom.radius(from: radius, delta: delta, precise: precise, range: range)!
    }

    func testWheelUnitChangesScaleByTwentyPercent() {
        XCTAssertEqual(zoom(20, 1), 20 / 1.2, accuracy: 1e-10)
        XCTAssertEqual(zoom(20, -1), 24, accuracy: 1e-10)
    }

    func testCoalescedEventsPreserveDistanceInBothDirections() {
        for precise in [false, true] {
            for direction in [-1.0, 1.0] {
                let delta = direction * (precise ? 100 : 5)
                let together = zoom(100, delta, precise: precise)
                let separate = (0..<10).reduce(100.0) { radius, _ in
                    zoom(radius, delta / 10, precise: precise)
                }
                XCTAssertEqual(together, separate, accuracy: 1e-8)
            }
        }
        // Both deltas hit the old per-event cap; the larger movement must now zoom further.
        XCTAssertLessThan(zoom(100, 10), zoom(100, 5))
        XCTAssertLessThan(zoom(100, 200, precise: true), zoom(100, 100, precise: true))
    }

    func testWheelAndPixelDistancesHaveConsistentScale() {
        XCTAssertEqual(zoom(100, 3), zoom(100, 60, precise: true), accuracy: 1e-10)
    }

    func testOppositeScrollRestoresRadiusAndFractionalInputIsRetained() {
        for precise in [false, true] {
            let closer = zoom(20, 0.25, precise: precise)
            XCTAssertLessThan(closer, 20)
            XCTAssertEqual(zoom(closer, -0.25, precise: precise), 20, accuracy: 1e-10)
        }
    }

    func testOnlyViewportBoundsClampLargeFiniteDeltas() {
        for precise in [false, true] {
            XCTAssertEqual(zoom(20, .greatestFiniteMagnitude, precise: precise), 2)
            XCTAssertEqual(zoom(20, -.greatestFiniteMagnitude, precise: precise), 1200)
            XCTAssertEqual(zoom(2, 1, precise: precise), 2)
            XCTAssertEqual(zoom(1200, -1, precise: precise), 1200)
            XCTAssertGreaterThan(zoom(2, -1, precise: precise), 2)
            XCTAssertLessThan(zoom(1200, 1, precise: precise), 1200)
        }
    }

    func testZeroAndNonFiniteInputDoNotStartZoom() {
        for delta in [0.0, .nan, .infinity, -.infinity] {
            XCTAssertNil(ScrollZoom.radius(from: 20, delta: delta, precise: false, range: range))
        }
    }
}
