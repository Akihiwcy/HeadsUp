import CoreGraphics
import Foundation
import HeadsUpCore

/// Which aircraft get a full mark (icon, trail, label) when the view is zoomed out over a busy sky.
///
/// Everything inside the tracking radius around the origin is always drawn in full. Beyond it,
/// once there are more aircraft than the panel can show legibly, the panel is divided into a
/// screen grid and each cell keeps one aircraft; the rest are drawn as faint dots so the density
/// of traffic still shows. The choice is made when data, zoom or pan change, not every frame, so
/// marks don't flicker as aircraft cross cell boundaries.
struct AircraftSample {
    var drawn: [TrackedAircraft]
    var hidden: [TrackedAircraft]
    var isSampling: Bool { !hidden.isEmpty }
}

enum AircraftSampler {
    /// Full marks the panel can carry before sampling starts (about 60 on a 420 pt panel).
    static func budget(side: CGFloat) -> Int { max(30, Int(side / 7)) }

    static func sample(_ items: [TrackedAircraft], origin: Coordinate?, trackingRadiusKm: Double,
                       projector: Projector, mapCoordinate: (Coordinate) -> Coordinate,
                       side: CGFloat, s: CGFloat, selectedID: String?, now: Date) -> AircraftSample {
        guard items.count > budget(side: side), let origin else { return AircraftSample(drawn: items, hidden: []) }
        let cell = 44 * s
        func key(_ a: TrackedAircraft) -> Int {
            let p = projector.point(mapCoordinate(a.displayPosition(at: now)))
            return Int(floor(p.y / cell)) * 10_000 + Int(floor(p.x / cell))
        }
        let limit = trackingRadiusKm * 1000
        var drawn: [TrackedAircraft] = [], hidden: [TrackedAircraft] = []
        var occupied = Set<Int>()
        var outer: [(TrackedAircraft, Double)] = []
        for a in items {
            let d = Geo.distance(origin, a.aircraft.position)
            if d <= limit || a.id == selectedID {
                drawn.append(a)
                occupied.insert(key(a))
            } else {
                outer.append((a, d))
            }
        }
        // Airborne before parked, then nearest to the origin first.
        outer.sort { l, r in
            if l.0.aircraft.onGround != r.0.aircraft.onGround { return !l.0.aircraft.onGround }
            return l.1 < r.1
        }
        for (a, _) in outer {
            let k = key(a)
            if occupied.insert(k).inserted { drawn.append(a) } else { hidden.append(a) }
        }
        return AircraftSample(drawn: drawn, hidden: hidden)
    }
}
