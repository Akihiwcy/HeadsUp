import CoreGraphics
import Foundation
import HeadsUpCore

/// Which aircraft get a full mark (icon, trail, label) when the view is crowded.
///
/// Once there are more aircraft than the panel can show legibly, the whole panel is divided into
/// a screen grid and each cell keeps one aircraft; the rest are drawn as faint dots so the density
/// of traffic still shows. Aircraft that had a full mark last time keep it while their cell is
/// free, so marks don't hop between aircraft as they drift across cell boundaries.

/// Remembers which aircraft were drawn in full and which carried labels (and on which side),
/// across redraws, so neither hops around as aircraft drift.
final class SampleMemory {
    var drawn: Set<String> = []
    var labels: [String: Int] = [:]
    /// For tests: labels gained or lost between consecutive frames.
    var labelChurn = 0
    var labelFrames = 0
    /// For tests: full marks gained or lost between consecutive samples.
    var churn = 0
    var samples = 0
}

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
                       side: CGFloat, s: CGFloat, selectedID: String?, now: Date,
                       keep: Set<String> = []) -> AircraftSample {
        guard items.count > budget(side: side) else { return AircraftSample(drawn: items, hidden: []) }
        let cell = 44 * s
        func key(_ a: TrackedAircraft) -> Int {
            let p = projector.point(mapCoordinate(a.displayPosition(at: now)))
            return Int(floor(p.y / cell)) * 10_000 + Int(floor(p.x / cell))
        }
        // The selected aircraft first, then those drawn last time, then airborne before parked,
        // then nearest to the origin.
        let ranked = items.map { a in (a, origin.map { Geo.distance($0, a.aircraft.position) } ?? a.distanceMeters) }
            .sorted { l, r in
                if (l.0.id == selectedID) != (r.0.id == selectedID) { return l.0.id == selectedID }
                if keep.contains(l.0.id) != keep.contains(r.0.id) { return keep.contains(l.0.id) }
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
