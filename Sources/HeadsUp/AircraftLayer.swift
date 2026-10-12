import AppKit
import HeadsUpCore
import SwiftUI

/// Draws every tracked aircraft, moving them by dead reckoning between feed updates.
///
/// Trails, aircraft and labels are painted in one Canvas so a busy sky costs one draw per frame
/// rather than a view tree per aircraft. Tap targets and the detail card live outside the
/// animation and refresh twice a second, which is plenty for objects moving a few points a second.
struct AircraftLayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tracker: FlightTracker
    let projector: Projector
    let palette: Palette
    let s: CGFloat
    let side: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let items = tracker.aircraft
        let paused = items.isEmpty || tracker.isPaused
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: frameInterval(items), paused: paused)) { tl in
                let placed = place(items, at: tl.date)
                let labeled = labels(for: placed)
                Canvas { ctx, _ in
                    draw(placed, labeled, in: &ctx)
                }
                .allowsHitTesting(false)
            }

            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let placed = place(items, at: tl.date)
                let labeled = labels(for: placed)
                ZStack(alignment: .topLeading) {
                    ForEach(placed, id: \.item.id) { p in
                        Color.clear
                            .frame(width: 34 * s, height: 34 * s)
                            .contentShape(Circle())
                            .onTapGesture { toggle(p.item.id) }
                            .help(p.item.aircraft.displayName)
                            .position(p.point)
                    }
                    ForEach(labeled, id: \.item.id) { p in
                        Color.clear
                            .frame(width: p.labelRect!.width, height: p.labelRect!.height)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(p.item.id) }
                            .position(x: p.labelRect!.midX, y: p.labelRect!.midY)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        model.select(model.selectedID == id ? nil : id)
    }

    // MARK: Layout

    struct Placed {
        var item: TrackedAircraft
        var point: CGPoint
        var trail: [CGPoint]
        var opacity: Double
        var labelRect: CGRect?
        var labelLeading = true
        var labelAbove = true
    }

    private func place(_ items: [TrackedAircraft], at now: Date) -> [Placed] {
        items.map { item in
            let pos = item.displayPosition(at: now)
            let pt = projector.point(model.mapCoordinate(pos))
            var trail = item.history.map { projector.point(model.mapCoordinate($0)) }
            trail.append(pt)
            if trail.count == 1, let track = item.aircraft.trackDeg, !item.aircraft.onGround {
                // No history yet: a short stub behind the aircraft shows its heading.
                let r = (track + 180) * .pi / 180
                let len = 22 * s
                trail.insert(CGPoint(x: pt.x + sin(r) * len, y: pt.y - cos(r) * len), at: 0)
            }
            let age = now.timeIntervalSince(item.firstSeen)
            return Placed(item: item, point: pt, trail: trail, opacity: min(1, max(0.15, age / 0.8)))
        }
    }

    static let labelSize = CGSize(width: 92, height: 36)

    /// Picks label positions greedily, selected and airborne aircraft first, skipping overlaps.
    private func labels(for placed: [Placed]) -> [Placed] {
        let showAll = model.settings.showLabels
        guard showAll || model.selectedID != nil else { return [] }
        let maxLabels = showAll ? max(3, Int(side / 55)) : 0
        let size = CGSize(width: Self.labelSize.width * s, height: Self.labelSize.height * s)
        var taken: [CGRect] = []
        var out: [Placed] = []
        let ordered = placed.sorted { a, b in
            if (a.item.id == model.selectedID) != (b.item.id == model.selectedID) { return a.item.id == model.selectedID }
            // Airborne traffic first: a busy apron shouldn't use up every label.
            if a.item.aircraft.onGround != b.item.aircraft.onGround { return !a.item.aircraft.onGround }
            return a.item.distanceMeters < b.item.distanceMeters
        }
        let bounds = CGRect(x: 6, y: 6, width: side - 12, height: side - 12)
        // Keep clear of the count/status chips in the top-left corner.
        taken.append(CGRect(x: 0, y: 0, width: side * 0.075 + 190 * s, height: side * 0.065 + 64 * s))
        let marks = placed.map { CGRect(x: $0.point.x - 11 * s, y: $0.point.y - 11 * s, width: 22 * s, height: 22 * s) }
        for var p in ordered {
            let isSelected = p.item.id == model.selectedID
            guard isSelected || out.count < maxLabels else { continue }
            let o = 16 * s
            let candidates: [(CGRect, Bool, Bool)] = [
                (CGRect(x: p.point.x + o, y: p.point.y - o - size.height, width: size.width, height: size.height), true, true),
                (CGRect(x: p.point.x + o, y: p.point.y + o * 0.5, width: size.width, height: size.height), true, false),
                (CGRect(x: p.point.x - o - size.width, y: p.point.y - o - size.height, width: size.width, height: size.height), false, true),
                (CGRect(x: p.point.x - o - size.width, y: p.point.y + o * 0.5, width: size.width, height: size.height), false, false),
            ]
            let fit = candidates.first { c in
                bounds.contains(c.0) && !taken.contains { $0.intersects(c.0) } && !marks.contains { $0.intersects(c.0) }
            } ?? (isSelected ? candidates.first { bounds.contains($0.0) } ?? candidates[0] : nil)
            guard let (r, leading, above) = fit else { continue }
            taken.append(r)
            p.labelRect = r
            p.labelLeading = leading
            p.labelAbove = above
            out.append(p)
        }
        return out
    }

    /// Redraw only as often as needed: aircraft move a pixel or two a second at typical zoom levels.
    private func frameInterval(_ items: [TrackedAircraft]) -> Double {
        guard let center = model.center, !items.isEmpty else { return 1 }
        let fastest = items.compactMap { $0.aircraft.onGround ? nil : $0.aircraft.groundSpeedKt }.max() ?? 0
        let pxPerSecond = projector.length(meters: fastest * 0.514444, at: center)
        guard pxPerSecond > 0.01 else { return 1 }
        // Steps of about half a point (one pixel on Retina); never faster than 12 fps.
        return min(1, max(1.0 / 12, 0.5 / pxPerSecond))
    }

    // MARK: Drawing

    private func draw(_ placed: [Placed], _ labeled: [Placed], in ctx: inout GraphicsContext) {
        let dark = scheme == .dark
        // Trails: one continuous dash rhythm along each path, fading toward the oldest point.
        for p in placed where p.trail.count > 1 {
            var travelled: CGFloat = 0
            let n = p.trail.count
            for i in 1..<n {
                let a = p.trail[i - 1], b = p.trail[i]
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 0.01 else { continue }
                var seg = Path()
                seg.move(to: a)
                seg.addLine(to: b)
                ctx.stroke(seg, with: .color(palette.ink.opacity(0.75 * Double(i) / Double(n) * p.opacity)),
                           style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .butt, dash: [6 * s, 4 * s], dashPhase: travelled))
                travelled += len
            }
        }

        // Shadows first, so no aircraft's shadow falls on top of another aircraft.
        for p in placed {
            let a = p.item.aircraft
            // Higher aircraft cast a longer, softer shadow, like a paper cut-out held above the map.
            let alt = Double(max(0, min(a.altitudeFt ?? 0, 42_000))) / 42_000
            let size = (a.onGround ? 18 : 26) * s
            let bucket = Int((alt * Double(PlaneSprites.blurLevels - 1)).rounded())
            guard let shadow = PlaneSprites.shared.shadow(bucket: bucket, size: size, dark: dark) else { continue }
            var l = ctx
            l.opacity = p.opacity
            l.translateBy(x: p.point.x + (1.5 + 9.5 * alt) * s, y: p.point.y + (2 + 13 * alt) * s)
            l.rotate(by: .degrees(a.trackDeg ?? 0))
            l.draw(Image(nsImage: shadow), in: CGRect(x: -shadow.size.width / 2, y: -shadow.size.height / 2,
                                                       width: shadow.size.width, height: shadow.size.height))
        }

        for p in placed {
            let a = p.item.aircraft
            let selected = p.item.id == model.selectedID
            let size = (a.onGround ? 18 : 26) * s
            if selected {
                let r = CGRect(x: p.point.x - 19 * s, y: p.point.y - 19 * s, width: 38 * s, height: 38 * s)
                ctx.fill(Path(ellipseIn: r.offsetBy(dx: 1, dy: 2)), with: .color(palette.shadow.opacity(0.12)))
                ctx.fill(Path(ellipseIn: r), with: .color(palette.card.opacity(0.6)))
                ctx.stroke(Path(ellipseIn: r), with: .color(palette.ink.opacity(0.75)), lineWidth: 1.5)
            }
            var l = ctx
            l.opacity = p.opacity
            l.translateBy(x: p.point.x, y: p.point.y)
            l.rotate(by: .degrees(a.trackDeg ?? 0))
            l.fill(PlaneShape().path(in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)),
                   with: .color(a.onGround ? palette.sub : palette.ink))
        }

        for p in labeled {
            drawLabel(p, in: &ctx, dark: dark)
        }
    }

    private func drawLabel(_ p: Placed, in ctx: inout GraphicsContext, dark: Bool) {
        guard let slot = p.labelRect else { return }
        let a = p.item.aircraft
        let selected = p.item.id == model.selectedID
        guard let sprite = LabelSprites.shared.sprite(title: a.displayName, subtitle: labelSubtitle(a),
                                                      selected: selected, dark: dark, palette: palette, s: s) else { return }
        // Sprites include a margin for the drop shadow around the chip itself.
        let m = LabelSprites.margin * s
        let w = sprite.size.width, h = sprite.size.height
        let x = p.labelLeading ? slot.minX - m : slot.maxX - w + m
        let y = p.labelAbove ? slot.maxY - h + m : slot.minY - m
        var l = ctx
        l.opacity = p.opacity
        l.draw(Image(nsImage: sprite), in: CGRect(x: x, y: y, width: w, height: h))
    }

    private func labelSubtitle(_ a: Aircraft) -> String {
        var parts: [String] = []
        if let t = a.typeCode { parts.append(t) }
        if a.onGround {
            parts.append("地面")
        } else if let alt = a.altitudeFt {
            parts.append("\(Format.int(alt)) ft" + Format.trendArrow(a.trend))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Pre-blurred aircraft silhouettes used as soft drop shadows, cached per size and blur level.
@MainActor
final class PlaneSprites {
    static let shared = PlaneSprites()
    static let blurLevels = 5
    private var cache: [String: NSImage] = [:]

    func shadow(bucket: Int, size: CGFloat, dark: Bool) -> NSImage? {
        let key = "\(bucket)-\(Int(size * 4))-\(dark)"
        if let img = cache[key] { return img }
        let blur = (1 + 3 * CGFloat(bucket) / CGFloat(Self.blurLevels - 1)) * size / 26
        let alpha = dark ? 0.6 : 0.36
        let pad = ceil(blur * 3)
        let box = CGSize(width: size + pad * 2, height: size + pad * 2)
        let scale: CGFloat = 2
        guard let cg = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: scale, y: scale)
        // Draw the shape far off-canvas and let only its shadow land inside.
        let far: CGFloat = 4000
        let color = dark ? CGColor(gray: 0, alpha: alpha) : CGColor(srgbRed: 0.227, green: 0.165, blue: 0.094, alpha: alpha)
        cg.setShadow(offset: CGSize(width: far * scale, height: 0), blur: blur * scale, color: color)
        cg.translateBy(x: -far, y: 0)
        // CGContext's y axis points up; flip so the nose stays at the top.
        cg.translateBy(x: 0, y: box.height)
        cg.scaleBy(x: 1, y: -1)
        let path = PlaneShape().path(in: CGRect(x: pad, y: pad, width: size, height: size)).cgPath
        cg.addPath(path)
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.fillPath()
        guard let img = cg.makeImage() else { return nil }
        let ns = NSImage(cgImage: img, size: box)
        cache[key] = ns
        return ns
    }
}

/// The selected aircraft's detail card, drawn above everything else in the panel.
struct SelectionCardLayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tracker: FlightTracker
    let projector: Projector
    let palette: Palette
    let s: CGFloat
    let side: CGFloat

    var body: some View {
        if let id = model.selectedID, let item = tracker.aircraft.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let anchor = projector.point(model.mapCoordinate(item.displayPosition(at: tl.date)))
                DetailCard(model: model, item: item, palette: palette, s: s, now: tl.date)
                    .frame(width: cardWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(CardPlacement(anchor: anchor, side: side, width: cardWidth, s: s))
            }
        }
    }

    private var cardWidth: CGFloat { min(max(side * 0.56, 196), 280) }
}

/// Places the detail card beside its aircraft without covering it, fully inside the panel.
struct CardPlacement: ViewModifier {
    let anchor: CGPoint
    let side: CGFloat
    let width: CGFloat
    let s: CGFloat
    @State private var height: CGFloat = 180

    func body(content: Content) -> some View {
        let origin = Self.origin(anchor: anchor, size: CGSize(width: width, height: height), side: side, gap: 24 * s)
        return content
            .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }
                .onChange(of: g.size.height) { _, h in height = h } })
            .offset(x: origin.x, y: origin.y)
    }

    static func origin(anchor a: CGPoint, size: CGSize, side: CGFloat, gap: CGFloat) -> CGPoint {
        let inset: CGFloat = 10
        func clamp(_ p: CGPoint) -> CGRect {
            CGRect(x: min(max(p.x, inset), side - inset - size.width),
                   y: min(max(p.y, inset), side - inset - size.height),
                   width: size.width, height: size.height)
        }
        let candidates = [
            CGPoint(x: a.x - size.width * 0.25, y: a.y + gap),               // below
            CGPoint(x: a.x - size.width * 0.25, y: a.y - gap - size.height), // above
            CGPoint(x: a.x + gap, y: a.y - size.height / 2),                  // right
            CGPoint(x: a.x - gap - size.width, y: a.y - size.height / 2),     // left
        ].map(clamp)
        let keepClear = CGRect(x: a.x - 18, y: a.y - 18, width: 36, height: 36)
        if let r = candidates.first(where: { !$0.intersects(keepClear) }) { return r.origin }
        // Panel too small to avoid the aircraft entirely: cover as little of it as possible.
        let best = candidates.min { $0.intersection(keepClear).area < $1.intersection(keepClear).area }!
        return best.origin
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Rendered label chips, cached by content, so the animation only blits images.
@MainActor
final class LabelSprites {
    static let shared = LabelSprites()
    static let margin: CGFloat = 8
    private var cache: [String: NSImage] = [:]

    func sprite(title: String, subtitle: String, selected: Bool, dark: Bool, palette: Palette, s: CGFloat) -> NSImage? {
        let key = "\(title)|\(subtitle)|\(selected)|\(dark)|\(Int(s * 100))"
        if let img = cache[key] { return img }
        let view = ChipView(title: title, subtitle: subtitle, selected: selected, dark: dark, palette: palette, s: s)
            .padding(Self.margin * s)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage else { return nil }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = img
        return img
    }

    private struct ChipView: View {
        let title: String, subtitle: String
        let selected: Bool, dark: Bool
        let palette: Palette
        let s: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5 * s, weight: .semibold).width(.condensed))
                    .foregroundStyle(selected ? palette.chipOnFG : palette.ink)
                Text(subtitle)
                    .font(.system(size: 10.5 * s, weight: .medium).width(.condensed))
                    .foregroundStyle(selected ? palette.chipOnSub : palette.sub)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7 * s)
            .padding(.vertical, 4 * s)
            .background(
                RoundedRectangle(cornerRadius: 4 * s)
                    .fill(selected ? palette.chipOnBG : palette.card)
                    .overlay(RoundedRectangle(cornerRadius: 4 * s)
                        .stroke(dark && !selected ? palette.cardBorder : .clear, lineWidth: 1))
                    .shadow(color: palette.shadow.opacity(dark ? 0.4 : 0.2), radius: 1, x: 0, y: 1)
                    .shadow(color: palette.shadow.opacity(dark ? 0.45 : 0.22), radius: 3, x: 2, y: 3)
            )
        }
    }
}
