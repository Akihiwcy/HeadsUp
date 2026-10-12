import AppKit
import HeadsUpCore
import SwiftUI

/// Text and controls drawn over the map: aircraft count, status, empty state, hover buttons.
struct PanelChrome: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tracker: FlightTracker
    @ObservedObject var terrain: TerrainModel
    let palette: Palette
    let s: CGFloat
    let side: CGFloat
    let hovering: Bool
    let actions: PanelActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6 * s) {
                chip(countText, warn: false, prominent: true)
                if let status = statusText {
                    chip(status.text, warn: status.warn)
                }
            }
            .padding(.leading, side * 0.075)
            .padding(.top, side * 0.065)
            .frame(maxWidth: side * 0.72, alignment: .leading)
            .allowsHitTesting(false)

            if let empty = emptyMessage {
                VStack(spacing: 3 * s) {
                    Text(empty.title)
                        .font(.system(size: 13 * s, weight: .semibold).width(.condensed))
                        .foregroundStyle(palette.ink)
                    if let sub = empty.sub {
                        Text(sub)
                            .font(.system(size: 10.5 * s).width(.condensed))
                            .foregroundStyle(palette.sub)
                            .multilineTextAlignment(.center)
                    }
                    if empty.offerSettings {
                        Button("设置位置…", action: actions.openSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12 * s)
                .padding(.vertical, 8 * s)
                .background(RoundedRectangle(cornerRadius: 6 * s).fill(palette.card.opacity(0.92))
                    .shadow(color: palette.shadow.opacity(0.18), radius: 4, x: 1, y: 2))
                .frame(maxWidth: side * 0.72)
                .position(x: side / 2, y: side / 2 + (model.center == nil ? 0 : 52 * s))
            }

            if model.settings.mapLook == .paper && terrain.image != nil {
                Text("地形 © Mapzen · 水系 © OpenStreetMap 贡献者")
                    .font(.system(size: 8 * max(s, 1)).width(.condensed))
                    .foregroundStyle(palette.sub.opacity(0.75))
                    .padding(.bottom, side * 0.03)
                    .frame(width: side, height: side, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if hovering {
                HStack(spacing: 6) {
                    roundButton("gearshape", help: "设置", action: actions.openSettings)
                    roundButton("minus", help: "隐藏面板（菜单栏图标可再次显示）", action: actions.hidePanel)
                }
                .padding(.trailing, side * 0.06)
                .padding(.top, side * 0.055)
                .frame(width: side, height: side, alignment: .topTrailing)
                .transition(.opacity)

                ResizeGrip(onResize: actions.resize)
                    .frame(width: 22, height: 22)
                    .overlay(gripGlyph.allowsHitTesting(false))
                    .position(x: side - side * 0.06, y: side - side * 0.06)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var gripGlyph: some View {
        Path { p in
            for i in 0..<3 {
                let o = CGFloat(i) * 4
                p.move(to: CGPoint(x: 18 - o, y: 18)); p.addLine(to: CGPoint(x: 18, y: 18 - o))
            }
        }
        .stroke(palette.sub, lineWidth: 1.2)
        .frame(width: 22, height: 22)
    }

    private var countText: String {
        let n = tracker.aircraft.count
        let r = Format.km(model.settings.radiusKm)
        if model.center == nil { return "\(r) 公里范围" }
        if tracker.lastSuccess == nil { return "— 架 · \(r) 公里内" }
        return "\(n) 架 · \(r) 公里内" + (tracker.filter == nil ? "" : " · 已过滤")
    }

    private var statusText: (text: String, warn: Bool)? {
        if model.center == nil {
            switch model.location.state {
            case .denied: return ("定位权限未开启", true)
            case .servicesOff: return ("系统定位服务已关闭", true)
            case .failed(let m): return ("定位失败：\(m)", true)
            default: return ("正在定位…", false)
            }
        }
        switch tracker.status {
        case .offline: return ("网络不可用 · 恢复后自动更新", true)
        case .error(let m): return ("\(m) · 正在重试", true)
        case .loading: return ("正在获取附近航班…", false)
        case .waitingForLocation: return ("正在定位…", false)
        case .live: break
        }
        if model.settings.mapLook == .paper && terrain.image == nil && !terrain.loading {
            return ("地形数据暂不可用", true)
        }
        switch model.centerSource {
        case .manual:
            let name = model.settings.manualLocationName
            let reason: String
            switch model.location.state {
            case .denied where !model.settings.useManualLocation: reason = "定位未授权，"
            case .failed where !model.settings.useManualLocation: reason = "定位失败，"
            default: reason = ""
            }
            return ("\(reason)使用手动位置\(name.isEmpty ? "" : " · \(name)")", false)
        case .lastKnown: return ("使用上次定位的位置", false)
        default: return nil
        }
    }

    private var emptyMessage: (title: String, sub: String?, offerSettings: Bool)? {
        if model.center == nil {
            switch model.location.state {
            case .denied:
                return ("无法获取你的位置", "请在 系统设置 › 隐私与安全性 › 定位服务 中允许 HeadsUp，或手动设置位置。", true)
            case .servicesOff:
                return ("定位服务已关闭", "请在系统设置中打开定位服务，或手动设置位置。", true)
            case .failed:
                return ("暂时无法定位", "可以手动设置一个位置。", true)
            default:
                return nil
            }
        }
        guard tracker.status == .live, tracker.aircraft.isEmpty else { return nil }
        let r = Format.km(model.settings.radiusKm)
        if tracker.filter != nil {
            return ("\(r) 公里内没有符合过滤条件的航班", "范围内共有 \(tracker.rawInRadius) 架飞机，可在设置中调整过滤。", false)
        }
        let sub = tracker.emptyStreak >= 3
            ? "若长期如此，可能是这一带的社区 ADS-B 接收站覆盖有限，可在设置中扩大范围。"
            : nil
        return ("\(r) 公里内暂时没有飞机", sub, false)
    }

    private func chip(_ text: String, warn: Bool, prominent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: (prominent ? 12 : 11) * s, weight: .semibold).width(.condensed))
            .foregroundStyle(warn ? palette.danger : palette.ink)
            .lineLimit(2)
            .padding(.horizontal, 8 * s)
            .padding(.vertical, 4 * s)
            .background(
                RoundedRectangle(cornerRadius: 4 * s)
                    .fill(palette.card)
                    .overlay(RoundedRectangle(cornerRadius: 4 * s).stroke(scheme == .dark ? palette.cardBorder : .clear, lineWidth: 1))
                    .shadow(color: palette.shadow.opacity(scheme == .dark ? 0.45 : 0.22), radius: 3, x: 2, y: 3)
            )
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 26 * s, height: 26 * s)
                .background(Circle().fill(palette.card).shadow(color: palette.shadow.opacity(0.25), radius: 3, x: 1, y: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - AppKit helpers

/// Transparent area that moves the window when dragged, and reports plain clicks.
struct WindowDragArea: NSViewRepresentable {
    var onClick: () -> Void
    var menu: () -> NSMenu?

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.onClick = onClick
        v.menuProvider = menu
        return v
    }

    func updateNSView(_ v: DragView, context: Context) {
        v.onClick = onClick
        v.menuProvider = menu
    }

    final class DragView: NSView {
        var onClick: (() -> Void)?
        var menuProvider: (() -> NSMenu?)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = NSEvent.mouseLocation
            let origin = window.frame.origin
            var moved = false
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let now = NSEvent.mouseLocation
                if e.type == .leftMouseUp { break }
                if abs(now.x - start.x) + abs(now.y - start.y) > 3 { moved = true }
                if moved {
                    window.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
                }
            }
            if !moved { onClick?() }
        }

        override func rightMouseDown(with event: NSEvent) {
            if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }
}

/// Bottom-right grip: drag to resize the square panel, keeping its top-left corner in place.
struct ResizeGrip: NSViewRepresentable {
    var onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> GripView {
        let v = GripView()
        v.onResize = onResize
        return v
    }

    func updateNSView(_ v: GripView, context: Context) { v.onResize = onResize }

    final class GripView: NSView {
        var onResize: ((CGFloat) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = NSEvent.mouseLocation
            let startSide = window.frame.width
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if e.type == .leftMouseUp { break }
                let now = NSEvent.mouseLocation
                let delta = max(now.x - start.x, start.y - now.y)
                onResize?(startSide + delta)
            }
        }
    }
}
