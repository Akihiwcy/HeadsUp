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
        case "searchplace":
            Task {
                let r = await model.searchPlaces(arg)
                let lines = r.results.map { "\($0.name) | \($0.detail) | \($0.coordinate.latitude),\($0.coordinate.longitude) | \($0.source)" }
                try? (["bothFailed=\(r.bothFailed)"] + lines).joined(separator: "\n")
                    .write(toFile: "/tmp/headsup-search.txt", atomically: true, encoding: .utf8)
            }
        case "pinch":
            // "pinch x y total steps": synthesizes trackpad magnify events at a panel-local point.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            if f.count == 4 { pinch(at: CGPoint(x: f[0], y: f[1]), total: f[2], steps: Int(f[3])) }
        case "routecheck":
            // Compares the configured route service with adsbdb for up to N airborne aircraft in view.
            let n = Int(arg) ?? 8
            Task { await routeCheck(limit: n) }
        case "zoomsweep":
            // "zoomsweep FROM TO STEPS": changes the zoom 60 times a second, like a pinch.
            let f = arg.split(separator: " ").compactMap { Double($0) }
            guard f.count == 3 else { break }
            var i = 0.0
            let t0 = Date()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                MainActor.assumeIsolated {
                    i += 1
                    let r = f[0] + (f[1] - f[0]) * i / f[2]
                    model.zoom(to: r, final: i >= f[2])
                    if i >= f[2] {
                        timer.invalidate()
                        let ms = Date().timeIntervalSince(t0) * 1000
                        try? "steps=\(Int(f[2])) elapsedMs=\(Int(ms)) expectedMs=\(Int(f[2] / 60 * 1000))".write(toFile: "/tmp/headsup-sweep.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        case "unpause":
            // The display may be asleep during unattended tests; keep polling anyway.
            model.tracker.isPaused = false
        case "zoom":
            if let r = Double(arg) { model.zoom(to: r, final: true) }
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

    private var pinchLog: [String] = []

    private func routeCheck(limit: Int) async {
        let m = app.model!
        let kind = m.settings.routeProvider
        let client = LiveRouteClient(kind: kind, key: m.routeKey(for: kind))
        let db = RouteService()
        var lines: [String] = ["provider=\(kind.rawValue)"]
        let planes = m.tracker.aircraft.filter { !$0.aircraft.onGround && $0.aircraft.callsign != nil }.prefix(limit)
        for p in planes {
            let a = p.aircraft, cs = a.callsign!
            var live = "-"
            do {
                if let r = try await client.route(callsign: cs, onGround: false) { live = "\(r.origin.code)->\(r.destination.code)" } else { live = "none" }
            } catch { live = "error: \((error as? LiveRouteError)?.localizedDescription ?? "\(error)")" }
            var dbText = "-"
            if case .found(let r) = await db.route(callsign: cs) {
                dbText = "\(r.origin.code)->\(r.destination.code)" + (r.isPlausible(for: a.position, track: a.trackDeg, verticalRateFpm: a.verticalRateFpm) ? "" : " (implausible)")
            }
            lines.append("\(cs) alt=\(a.altitudeFt ?? -1) vr=\(a.verticalRateFpm ?? 0) trk=\(Int(a.trackDeg ?? -1)) | live: \(live) | adsbdb: \(dbText)")
        }
        try? lines.joined(separator: "\n").write(toFile: "/tmp/headsup-routecheck.txt", atomically: true, encoding: .utf8)
    }

    private func pinch(at p: CGPoint, total: Double, steps: Int) {
        let w = app.panel.panel
        // Global, top-left origin location of the point (CGEvent coordinates).
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: w.frame.minX + p.x, y: screenH - (w.frame.maxY - p.y))
        pinchLog = []
        for i in 0..<steps {
            guard let cg = CGEvent(source: nil) else { continue }
            cg.type = CGEventType(rawValue: 29)!                       // kCGEventGesture
            cg.location = global
            cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // gesture HID type: zoom
            cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: total / Double(steps))  // magnification
            let phase: Int64 = i == 0 ? 1 : (i == steps - 1 ? 4 : 2)        // began / changed / ended
            cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            // Address it to the panel, as the window server does for a pinch over it.
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
            guard let ev = NSEvent(cgEvent: cg) else { pinchLog.append("no NSEvent"); continue }
            pinchLog.append("\(ev.type.rawValue)/w\(ev.windowNumber)/m\(ev.magnification)")
            if ev.type == .magnify { NSApp.postEvent(ev, atStart: false) }
        }
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
            "pinchLog": pinchLog,
            "viewRadiusKm": m.viewRadiusKm ?? NSNull(),
            "viewCenter": m.viewCenter.map { [$0.latitude, $0.longitude] } ?? NSNull(),
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
