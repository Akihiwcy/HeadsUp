import HeadsUpCore
import MapKit
import SwiftUI

/// Maps geographic coordinates (already in the map's datum) onto the square panel.
struct Projector {
    var rect: MKMapRect
    var side: CGFloat

    func point(_ c: Coordinate) -> CGPoint {
        let mp = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        return CGPoint(x: (mp.x - rect.minX) / rect.width * side,
                       y: (mp.y - rect.minY) / rect.height * side)
    }

    /// Screen length of `meters` at the latitude of `c`.
    func length(meters: Double, at c: Coordinate) -> CGFloat {
        meters * MKMapPointsPerMeterAtLatitude(c.latitude) / rect.width * side
    }

    /// The outer range ring sits at this share of the half-width, as in the mockup (184 of 200 px).
    static let ringFraction = 0.92

    static func rect(center c: Coordinate, radiusKm: Double) -> MKMapRect {
        let mp = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        let half = radiusKm * 1000 / ringFraction * MKMapPointsPerMeterAtLatitude(c.latitude)
        return MKMapRect(x: mp.x - half, y: mp.y - half, width: half * 2, height: half * 2)
    }
}

/// The Apple base map. Not interactive: the panel always shows the tracking area around the user.
struct MapLayer: View {
    let center: Coordinate
    let radiusKm: Double
    let look: MapLook
    @Binding var visibleRect: MKMapRect?

    @State private var position: MapCameraPosition = .automatic
    @State private var didAppear = false

    var body: some View {
        Map(position: $position, interactionModes: []) {}
            .mapStyle(style)
            .mapControls {}
            .onMapCameraChange(frequency: .continuous) { ctx in
                visibleRect = ctx.rect
            }
            .onAppear {
                position = .rect(Projector.rect(center: center, radiusKm: radiusKm))
                didAppear = true
            }
            .onChange(of: Key(center: center, radius: radiusKm)) { _, key in
                let target = Projector.rect(center: key.center, radiusKm: key.radius)
                withAnimation(.easeInOut(duration: 0.7)) { position = .rect(target) }
            }
    }

    private struct Key: Equatable { var center: Coordinate; var radius: Double }

    private var style: MapStyle {
        switch look {
        case .paper:
            return .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
        case .standard:
            return .standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll, showsTraffic: false)
        case .satellite:
            return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
        }
    }
}
