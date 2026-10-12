import AppKit
import HeadsUpCore
import MapKit
import SwiftUI

/// Callbacks the panel needs from the app shell.
struct PanelActions {
    var openSettings: () -> Void = {}
    var hidePanel: () -> Void = {}
    var contextMenu: () -> NSMenu? = { nil }
    var resize: (CGFloat) -> Void = { _ in }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var visibleRect: MKMapRect?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let s = max(0.7, min(side / 400, 1.6))
            let look = model.settings.mapLook
            let palette = look == .satellite ? Palette.dark : Palette.of(scheme)
            let radius = model.settings.radiusKm
            ZStack(alignment: .topLeading) {
                palette.ground

                if let center = model.center {
                    let mapCenter = model.mapCoordinate(center)
                    if look == .paper {
                        TerrainLayer(terrain: model.terrain, projector: projector(mapCenter, side: side))
                            .allowsHitTesting(false)
                    } else {
                        MapLayer(center: mapCenter, radiusKm: radius, look: look, visibleRect: $visibleRect)
                            // Keep Apple's logo and legal link clear of the rounded corners.
                            .safeAreaPadding(EdgeInsets(top: 0, leading: side * 0.075, bottom: side * 0.045, trailing: side * 0.075))
                            .allowsHitTesting(false)
                    }
                }

                WindowDragArea(onClick: { model.select(nil) }, menu: actions.contextMenu)

                if let center = model.center {
                    let mapCenter = model.mapCoordinate(center)
                    let projector = projector(mapCenter, side: side)
                    RangeRings(projector: projector, center: mapCenter, radiusKm: radius, palette: palette, s: s)
                        .allowsHitTesting(false)
                    UserDot(palette: palette, s: s)
                        .position(projector.point(mapCenter))
                        .allowsHitTesting(false)
                    AircraftLayer(model: model, tracker: model.tracker, projector: projector, palette: palette, s: s, side: side)
                }

                PanelChrome(model: model, tracker: model.tracker, terrain: model.terrain, palette: palette, s: s, side: side,
                            hovering: hovering, actions: actions)

                if let center = model.center {
                    SelectionCardLayer(model: model, tracker: model.tracker, projector: projector(model.mapCoordinate(center), side: side),
                                       palette: palette, s: s, side: side)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.11, style: .continuous))
            .environment(\.colorScheme, look == .satellite ? .dark : scheme)
            .onHover { hovering = $0 }
            .onAppear { requestTerrain(side: side) }
            .onChange(of: TerrainTrigger(center: model.center, radius: radius, side: side, dark: scheme == .dark, look: look)) { _, _ in
                requestTerrain(side: side)
            }
            .onChange(of: look) { _, _ in visibleRect = nil }
        }
    }

    private struct TerrainTrigger: Equatable {
        var center: Coordinate?, radius: Double, side: CGFloat, dark: Bool, look: MapLook
    }

    private func requestTerrain(side: CGFloat) {
        guard model.settings.mapLook == .paper, let c = model.center else { return }
        model.terrain.request(center: c, radiusKm: model.settings.radiusKm,
                              pixels: Int(side * max(displayScale, 1)), dark: scheme == .dark)
    }

    /// The paper map is drawn exactly where we ask; Apple's map reports its actual visible rect.
    private func projector(_ center: Coordinate, side: CGFloat) -> Projector {
        let asked = Projector.rect(center: center, radiusKm: model.settings.radiusKm)
        let rect = model.settings.mapLook == .paper ? asked : (visibleRect ?? asked)
        return Projector(rect: rect, side: side)
    }
}

// MARK: - Rings and user

struct RangeRings: View {
    let projector: Projector
    let center: Coordinate
    let radiusKm: Double
    let palette: Palette
    let s: CGFloat

    var body: some View {
        let c = projector.point(center)
        let outer = projector.length(meters: radiusKm * 1000, at: center)
        let inner = outer / 2
        ZStack(alignment: .topLeading) {
            Path { p in p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)) }
                .stroke(palette.ring, lineWidth: 0.8)
            Path { p in p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)) }
                .stroke(palette.ring, style: StrokeStyle(lineWidth: 0.8, dash: [2, 4]))
            ringLabel("\(Format.km(radiusKm / 2)) km").position(x: c.x, y: c.y - inner)
            ringLabel("\(Format.km(radiusKm)) km").position(x: c.x, y: c.y - outer + 7 * s)
        }
    }

    private func ringLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * s, weight: .semibold).width(.condensed))
            .foregroundStyle(palette.sub)
            .shadow(color: palette.ringLabelHalo, radius: 1)
            .shadow(color: palette.ringLabelHalo, radius: 2)
            .shadow(color: palette.ringLabelHalo, radius: 3)
    }
}

/// The user's position. The pulse runs as a Core Animation layer animation, which the window
/// server drives without waking the app every frame.
struct UserDot: View {
    let palette: Palette
    let s: CGFloat

    var body: some View {
        ZStack {
            PulseRing(color: NSColor(palette.accent), diameter: 16 * s)
                .frame(width: 16 * s * 3.4, height: 16 * s * 3.4)
            Circle()
                .fill(palette.accent)
                .overlay(Circle().stroke(palette.accentRim, lineWidth: 3 * s))
                .frame(width: 16 * s, height: 16 * s)
                .shadow(color: palette.shadow.opacity(0.4), radius: 1.5, x: 1, y: 2)
        }
    }
}

struct PulseRing: NSViewRepresentable {
    let color: NSColor
    let diameter: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        update(v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { update(v) }

    private func update(_ v: NSView) {
        guard let root = v.layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let ring = CAShapeLayer()
        let side = diameter * 3.4
        ring.frame = CGRect(x: 0, y: 0, width: side, height: side)
        ring.path = CGPath(ellipseIn: CGRect(x: (side - diameter) / 2, y: (side - diameter) / 2, width: diameter, height: diameter), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 1.5
        root.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 3.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 3
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "pulse")
        ring.opacity = 0
    }
}
