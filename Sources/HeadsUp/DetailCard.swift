import HeadsUpCore
import SwiftUI

/// Flight details for the selected aircraft. Fields the feed or lookups don't provide show "—".
struct DetailCard: View {
    @ObservedObject var model: AppModel
    let item: TrackedAircraft
    let palette: Palette
    let s: CGFloat
    let now: Date
    @Environment(\.colorScheme) private var scheme

    private var a: Aircraft { item.aircraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(a.displayName)
                    .font(.system(size: 17 * s, weight: .semibold).width(.condensed))
                    .foregroundStyle(palette.ink)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(a.typeCode ?? "—")
                    .font(.system(size: 12 * s, weight: .medium).width(.condensed))
                    .foregroundStyle(palette.sub)
                Button { model.select(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9 * s, weight: .bold))
                        .foregroundStyle(palette.sub)
                        .frame(width: 18 * s, height: 18 * s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭航班详情")
            }
            if let airline = subtitleLine {
                Text(airline)
                    .font(.system(size: 11 * s, weight: .medium).width(.condensed))
                    .foregroundStyle(palette.sub)
                    .lineLimit(1)
                    .padding(.top, -4 * s)
            }
            routeRow
            Rectangle().fill(palette.ink.opacity(0.1)).frame(height: 1)
            Grid(alignment: .leading, horizontalSpacing: 8 * s, verticalSpacing: 5 * s) {
                GridRow {
                    field("高度", altitude, altitudeSub)
                    field("地速", speed, nil)
                }
                GridRow {
                    field("垂直速度", vertical, nil)
                    field("航向", heading, nil)
                }
                GridRow {
                    field("距你", distance, nil)
                    field("注册号", registration, nil)
                }
            }
            Text(footer)
                .font(.system(size: 9 * s).width(.condensed))
                .foregroundStyle(palette.sub.opacity(0.8))
                .lineLimit(2)
        }
        .padding(.horizontal, 11 * s)
        .padding(.top, 9 * s)
        .padding(.bottom, 10 * s)
        .background(
            RoundedRectangle(cornerRadius: 8 * s)
                .fill(palette.card)
                .overlay(RoundedRectangle(cornerRadius: 8 * s).stroke(palette.cardBorder, lineWidth: 1))
                .shadow(color: palette.shadow.opacity(scheme == .dark ? 0.5 : 0.24), radius: 12, x: 0, y: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: Route

    @ViewBuilder private var routeRow: some View {
        switch model.route {
        case .found(let r)?:
            VStack(alignment: .leading, spacing: 3 * s) {
                HStack(alignment: .center, spacing: 8 * s) {
                    airport(r.origin, alignment: .leading)
                    ZStack {
                        Rectangle()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .foregroundStyle(palette.ink.opacity(0.4))
                            .frame(height: 1)
                        PlaneShape().fill(palette.ink)
                            .frame(width: 12 * s, height: 12 * s)
                            .rotationEffect(.degrees(90))
                            .padding(.horizontal, 3)
                            .background(palette.card)
                    }
                    .frame(minWidth: 24)
                    airport(r.destination, alignment: .trailing)
                }
                if !r.isPlausible(for: a.position, track: a.trackDeg, verticalRateFpm: a.onGround ? nil : a.verticalRateFpm) {
                    Text("航线库记录与当前位置不符，可能已过时")
                        .font(.system(size: 9.5 * s, weight: .medium).width(.condensed))
                        .foregroundStyle(palette.danger)
                }
            }
        case .loading?:
            placeholder("正在查询航线…")
        case .failed?:
            placeholder("航线查询失败")
        default:
            placeholder(a.callsign == nil ? "未广播航班号，无法查询航线" : "航线信息暂缺")
        }
    }

    private func airport(_ ap: Airport, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(ap.code)
                .font(.system(size: 15 * s, weight: .semibold).width(.condensed))
                .foregroundStyle(palette.ink)
            Text(ap.city ?? ap.name ?? "—")
                .font(.system(size: 10.5 * s).width(.condensed))
                .foregroundStyle(palette.sub)
                .lineLimit(1)
        }
        .help(ap.name ?? "")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5 * s, weight: .medium).width(.condensed))
            .foregroundStyle(palette.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private func field(_ title: String, _ value: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5 * s).width(.condensed))
                .foregroundStyle(palette.sub)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 12.5 * s, weight: .semibold).width(.condensed))
                    .foregroundStyle(palette.ink)
                if let sub {
                    Text(sub)
                        .font(.system(size: 10 * s).width(.condensed))
                        .foregroundStyle(palette.sub)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    // MARK: Values

    /// Operator and full aircraft type, whichever are known.
    private var subtitleLine: String? {
        var parts: [String] = []
        if case .found(let r)? = model.route, let name = r.airline { parts.append(name) }
        else if case .found(let info)? = model.airframe, let owner = info.owner { parts.append(owner) }
        if let t = typeName { parts.append(t) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var altitude: String {
        if a.onGround { return "地面" }
        guard let ft = a.altitudeFt else { return "—" }
        return "\(Format.int(ft)) ft" + Format.trendArrow(a.trend)
    }

    private var altitudeSub: String? {
        guard !a.onGround, let ft = a.altitudeFt else { return nil }
        return "\(Format.int(Int((Double(ft) * Geo.feetToMeters).rounded()))) m"
    }

    private var speed: String {
        guard let gs = a.groundSpeedKt else { return "—" }
        return "\(Format.int(Int((gs * Geo.knotsToKmh).rounded()))) km/h"
    }

    private var vertical: String {
        guard let v = a.verticalRateFpm else { return "—" }
        if abs(v) < 100 { return "平飞" }
        return (v > 0 ? "+" : "−") + "\(Format.int(abs(v))) ft/min"
    }

    private var heading: String {
        guard let t = a.trackDeg else { return "—" }
        return "\(Int(t.rounded()) % 360)° \(Geo.compassName(t))"
    }

    private var distance: String {
        guard let c = model.center else { return "—" }
        let pos = item.displayPosition(at: now)
        let d = Geo.distance(c, pos) / 1000
        return String(format: "%.1f km ", d) + Geo.compassName(Geo.bearing(from: c, to: pos))
    }

    private var registration: String {
        if let r = a.registration { return r }
        if case .found(let info)? = model.airframe, let r = info.registration { return r }
        return "—"
    }

    private var typeName: String? {
        if case .found(let info)? = model.airframe, let t = info.type {
            if let m = info.manufacturer, !t.lowercased().hasPrefix(m.lowercased()) { return "\(m) \(t)" }
            return t
        }
        return a.typeDescription
    }

    private var footer: String {
        let age = max(0, Int(now.timeIntervalSince(a.positionTime)))
        var parts = ["ICAO \(a.hex.uppercased())", "\(age) 秒前定位"]
        if let sq = a.squawk { parts.append("应答机 \(sq)") }
        if let feed = model.tracker.activeFeedName { parts.append("数据 \(feed)") }
        if case .found? = model.route { parts.append("航线 adsbdb") }
        return parts.joined(separator: " · ")
    }
}
