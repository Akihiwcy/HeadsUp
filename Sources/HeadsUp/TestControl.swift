import AppKit
import HeadsUpCore

/// Test hook, enabled only with HEADSUP_TEST_CONTROL=1. Commands arrive as distributed
/// notifications named "app.headsup.test" whose object is a command string, e.g. "snapshot /tmp/a.png".
@MainActor
final class TestControl {
    private unowned let app: AppDelegate
    private var observer: NSObjectProtocol?

    init(app: AppDelegate) {
        self.app = app
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.headsup.test"), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
    }

    private func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        let model = app.model!
        switch verb {
        case "snapshot":
            Self.capture(window: app.panel.panel, to: arg)
        case "snapshot-settings":
            if let w = app.settingsWindow.nsWindow { Self.capture(window: w, to: arg) }
        case "dump":
            dump(to: arg)
        case "select":
            if arg == "none" { model.select(nil) }
            else if arg == "first" { model.select(model.tracker.aircraft.first?.id) }
            else { model.select(arg) }
        case "radius":
            if let r = Double(arg) { model.settings.radiusKm = r }
        case "appearance":
            if let a = AppearanceMode(rawValue: arg) { model.settings.appearance = a }
        case "look":
            if let l = MapLook(rawValue: arg) { model.settings.mapLook = l }
        case "level":
            if let l = PanelLevel(rawValue: arg) { model.settings.panelLevel = l }
        case "labels":
            model.settings.showLabels = arg == "on"
        case "location":
            if arg == "auto" { model.settings.useManualLocation = false; break }
            let f = arg.split(separator: " ", maxSplits: 2).map(String.init)
            if f.count >= 2, let lat = Double(f[0]), let lon = Double(f[1]) {
                model.setManualLocation(Coordinate(latitude: lat, longitude: lon), name: f.count > 2 ? f[2] : "")
            }
        case "filter":
            if arg == "off" { model.settings.filterEnabled = false }
            else { model.settings.filterText = arg; model.settings.filterEnabled = true }
        case "tap", "rtap":
            // In-app mouse click at panel-local (top-left origin) point, routed through the window.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            if f.count == 2 { tap(CGPoint(x: f[0], y: f[1]), right: verb == "rtap") }
        case "routekey":
            // "routekey flightAware KEY" (empty KEY clears it)
            let f = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let kind = RouteProviderKind(rawValue: f.first ?? "") {
                model.settings.routeProvider = kind
                model.setRouteKey(f.count > 1 ? f[1] : "", for: kind)
            }
        case "size":
            if let s = Double(arg) { app.panel.setSide(s) }
        case "move":
            let f = arg.split(separator: " ").compactMap { Double($0) }
            if f.count == 2 { app.panel.panel.setFrameOrigin(NSPoint(x: f[0], y: f[1])) }
        case "show": app.panel.show()
        case "hide": app.panel.hide()
        case "settings": arg == "close" ? app.settingsWindow.close() : app.settingsWindow.show()
        case "refresh": model.tracker.refreshNow()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    private func tap(_ p: CGPoint, right: Bool) {
        let w = app.panel.panel
        let loc = NSPoint(x: p.x, y: w.frame.height - p.y)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if right {
            // Context menus track modally; just report whether the view under the point would show one.
            if let menu = app.buildMenu(forStatusItem: false) as NSMenu? { lastMenuTitles = menu.items.map(\.title) }
            return
        }
        if let up = ev(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = ev(.leftMouseDown) { w.sendEvent(down) }
    }

    private var lastMenuTitles: [String] = []

    private func dump(to path: String) {
        let m = app.model!
        let t = m.tracker
        let now = Date()
        let status: String
        switch t.status {
        case .waitingForLocation: status = "waitingForLocation"
        case .loading: status = "loading"
        case .live: status = "live"
        case .offline: status = "offline"
        case .error(let e): status = "error: \(e)"
        }
        var routeText = "nil"
        switch m.route {
        case .found(let r)?: routeText = "\(r.origin.code)->\(r.destination.code) plausible=\(m.selected.map { r.isPlausible(for: $0.aircraft.position, track: $0.aircraft.trackDeg, verticalRateFpm: $0.aircraft.verticalRateFpm) } ?? false)"
        case .loading?: routeText = "loading"
        case .unknown?: routeText = "unknown"
        case .failed?: routeText = "failed"
        case nil: break
        }
        let f = app.panel.panel.frame
        let obj: [String: Any] = [
            "status": status,
            "center": m.center.map { [$0.latitude, $0.longitude] } ?? NSNull(),
            "centerSource": "\(m.centerSource)",
            "locationState": "\(m.location.state)",
            "radiusKm": m.settings.radiusKm,
            "trackerRadiusKm": t.radiusKm,
            "rawCount": t.rawCount,
            "emptyStreak": t.emptyStreak,
            "feed": t.activeFeedName ?? NSNull(),
            "lastSuccessAgo": t.lastSuccess.map { now.timeIntervalSince($0) } ?? NSNull(),
            "paused": t.isPaused,
            "mapIsGCJ": m.mapIsGCJ,
            "selected": m.selectedID ?? NSNull(),
            "filterActive": t.filter != nil,
            "menu": lastMenuTitles,
            "routeProvider": m.settings.routeProvider.rawValue,
            "hasRouteKey": !m.routeKey(for: m.settings.routeProvider).isEmpty,
            "liveRouteError": m.liveRouteError?.localizedDescription ?? NSNull(),
            "filterSummary": m.filterSummary,
            "filterProblems": m.filterProblems,
            "rawInRadius": t.rawInRadius,
            "terrainLoaded": m.terrain.image != nil,
            "mapLook": m.settings.mapLook.rawValue,
            "route": routeText,
            "panelFrame": [f.origin.x, f.origin.y, f.width, f.height],
            "panelVisible": app.panel.isVisible,
            "panelLevel": app.panel.panel.level.rawValue,
            "appearance": NSApp.effectiveAppearance.name.rawValue,
            "aircraft": t.aircraft.map { a -> [String: Any] in
                let p = a.displayPosition(at: now)
                var pt: [Double] = []
                if let c = m.center, m.settings.mapLook == .paper {
                    let pr = Projector(rect: Projector.rect(center: c, radiusKm: m.settings.radiusKm), side: f.width)
                    let q = pr.point(p)
                    pt = [q.x, q.y]
                }
                return ["point": pt, "hex": a.id, "name": a.aircraft.displayName, "callsign": a.aircraft.callsign ?? "", "type": a.aircraft.typeCode ?? "",
                        "alt": a.aircraft.altitudeFt ?? -1, "distKm": (a.distanceMeters / 10).rounded() / 100,
                        "liveDistKm": m.center.map { (Geo.distance($0, p) / 10).rounded() / 100 } ?? -1,
                        "lat": p.latitude, "lon": p.longitude, "history": a.history.count]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Captures one of our own windows (no screen-recording permission needed for own windows).
    static func capture(window: NSWindow, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8; boundsIgnoreFraming = 1, bestResolution = 8
        guard let img = fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
