import CoreGraphics
import Foundation
import HeadsUpCore

/// Which aircraft get a full mark (icon, trail, label) when the view is crowded.
///
/// Once there are more aircraft than the panel can show legibly, the whole panel is divided into
/// a screen grid and each cell keeps one aircraft; the rest are drawn as faint dots so the density
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

    static func sample(_ items: [TrackedAircraft], origin: Coordinate?,
                       projector: Projector, mapCoordinate: (Coordinate) -> Coordinate,
                       side: CGFloat, s: CGFloat, selectedID: String?, now: Date) -> AircraftSample {
        guard items.count > budget(side: side) else { return AircraftSample(drawn: items, hidden: []) }
        let cell = 44 * s
        func key(_ a: TrackedAircraft) -> Int {
            let p = projector.point(mapCoordinate(a.displayPosition(at: now)))
            return Int(floor(p.y / cell)) * 10_000 + Int(floor(p.x / cell))
        }
        // The selected aircraft first, then airborne before parked, then nearest to the origin.
        let ranked = items.map { a in (a, origin.map { Geo.distance($0, a.aircraft.position) } ?? a.distanceMeters) }
            .sorted { l, r in
                if (l.0.id == selectedID) != (r.0.id == selectedID) { return l.0.id == selectedID }
                if l.0.aircraft.onGround != r.0.aircraft.onGround { return !l.0.aircraft.onGround }
                return l.1 < r.1
            }
        var drawn: [TrackedAircraft] = [], hidden: [TrackedAircraft] = []
        var occupied = Set<Int>()
        for (a, _) in ranked {
            if occupied.insert(key(a)).inserted || a.id == selectedID { drawn.append(a) } else { hidden.append(a) }
        }
        return AircraftSample(drawn: drawn, hidden: hidden)
    }
}
