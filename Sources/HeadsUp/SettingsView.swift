import AppKit
import HeadsUpCore
import MapKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var location: LocationService
    @ObservedObject var tracker: FlightTracker
    var panelSide: () -> CGFloat
    var setPanelSide: (CGFloat) -> Void

    @State private var radiusDraft: Double = SettingsStore.defaultRadiusKm
    @State private var sideDraft: Double = PanelController.defaultSide
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var routeKeyDraft = ""
    @State private var routeTestResult: String?

    struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let coordinate: Coordinate
    }

    var body: some View {
        Form {
            Section("追踪") {
                LabeledContent("追踪半径") {
                    HStack {
                        Slider(value: Binding(get: { radiusDraft }, set: { radiusDraft = $0.rounded() }),
                               in: SettingsStore.radiusRange) { editing in
                            if !editing { settings.radiusKm = radiusDraft }
                        }
                        .frame(minWidth: 180)
                        Text("\(Format.km(radiusDraft)) km").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                HStack {
                    Spacer()
                    ForEach([10.0, 20, 30, 50, 100], id: \.self) { r in
                        Button("\(Int(r)) km") { radiusDraft = r; settings.radiusKm = r }
                            .controlSize(.small)
                    }
                }
                Toggle("在地图上显示航班标签", isOn: $settings.showLabels)
            }

            Section("航司 / 航班过滤") {
                Toggle("只显示指定的航司或航班", isOn: $settings.filterEnabled)
                TextField("过滤条件", text: $settings.filterText, prompt: Text("例如：UAL, CES, MU5101, UA1577"))
                    .disabled(!settings.filterEnabled)
                Text("可填 ICAO 航司代码（UAL、CES）、IATA 航司代码（UA、MU）或航班号（UAL1577、MU5101），用逗号分隔。按飞机广播的呼号匹配，未广播呼号的飞机在过滤时不显示。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.filterEnabled && !model.filterSummary.isEmpty {
                    LabeledContent("匹配呼号") { Text(model.filterSummary).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                }
                ForEach(model.filterProblems, id: \.self) { p in
                    Text(p).font(.callout).foregroundStyle(.orange)
                }
            }

            Section("航线数据") {
                Picker("航线来源", selection: $settings.routeProvider) {
                    Text("免费航线库（adsbdb，可能不准）").tag(RouteProviderKind.none)
                    Text("FlightAware AeroAPI").tag(RouteProviderKind.flightAware)
                    Text("AirLabs").tag(RouteProviderKind.airLabs)
                }
                if settings.routeProvider != .none {
                    HStack {
                        SecureField("API Key", text: $routeKeyDraft, prompt: Text("粘贴 \(settings.routeProvider.displayName) 的 API Key"))
                        Button("保存") {
                            model.setRouteKey(routeKeyDraft, for: settings.routeProvider)
                            routeTestResult = "已保存到钥匙串"
                        }
                        Button("测试") {
                            model.setRouteKey(routeKeyDraft, for: settings.routeProvider)
                            routeTestResult = "测试中…"
                            Task { routeTestResult = await model.testRouteService() }
                        }
                        .disabled(routeKeyDraft.isEmpty)
                    }
                    if let r = routeTestResult { Text(r).font(.callout).foregroundStyle(.secondary) }
                    if let e = model.liveRouteError { Text("最近一次查询失败：\(e.localizedDescription)，已改用免费航线库").font(.callout).foregroundStyle(.orange) }
                }
                Text("飞机信号里没有航线。免费航线库按航班号记录，经常对不上；接入航班状态服务后，详情里显示的是今天这一班的真实起降机场。只在点开飞机时查询，结果缓存 20 分钟。Key 只保存在本机钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("位置") {
                Picker("位置来源", selection: $settings.useManualLocation) {
                    Text("自动定位").tag(false)
                    Text("手动位置").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("自动定位") {
                    Text(locationStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if location.state == .denied || location.state == .servicesOff {
                    Button("打开系统定位隐私设置…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                }
                LabeledContent("手动位置") {
                    Text(manualText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    TextField("搜索位置", text: $query, prompt: Text("城市、地址，或“纬度, 经度”"))
                        .onSubmit(search)
                    Button(searching ? "搜索中…" : "搜索", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let searchError { Text(searchError).foregroundStyle(.red).font(.callout) }
                ForEach(results) { r in
                    Button {
                        model.setManualLocation(r.coordinate, name: r.name)
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(r.name)
                            Text(r.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("外观") {
                Picker("外观", selection: $settings.appearance) {
                    Text("跟随系统").tag(AppearanceMode.system)
                    Text("浅色").tag(AppearanceMode.light)
                    Text("深色").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                Picker("地图样式", selection: $settings.mapLook) {
                    Text("纸感").tag(MapLook.paper)
                    Text("标准").tag(MapLook.standard)
                    Text("卫星").tag(MapLook.satellite)
                }
                .pickerStyle(.segmented)
            }

            Section("面板") {
                Picker("窗口层级", selection: $settings.panelLevel) {
                    Text("桌面（在其他窗口下方）").tag(PanelLevel.desktop)
                    Text("普通窗口").tag(PanelLevel.normal)
                    Text("始终置顶").tag(PanelLevel.floating)
                }
                LabeledContent("面板大小") {
                    HStack {
                        Slider(value: Binding(get: { sideDraft }, set: { sideDraft = ($0 / 10).rounded() * 10 }),
                               in: Double(PanelController.minSide)...Double(PanelController.maxSide)) { editing in
                            if !editing { setPanelSide(sideDraft) }
                        }
                        .frame(minWidth: 180)
                        Text("\(Int(sideDraft)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Text("拖动面板空白处可移动位置（允许拖动地图时改为按住 ⌘ 拖动），鼠标悬停时拖动右下角可调整大小。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("允许拖动地图查看其他区域", isOn: $settings.mapDragEnabled)
                Text("开启后拖动地图空白处可平移，飞机按当前看到的区域查询；原点和距离圈不动，点右上角的定位按钮回到原点。此时按住 ⌘ 拖动可移动面板。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("登录时自动启动", isOn: Binding(get: { loginItem }, set: setLoginItem))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            }

            Section("数据来源") {
                LabeledContent("飞机位置") { Text("adsb.lol（备用 adsb.fi），每 5 秒更新").foregroundStyle(.secondary) }
                LabeledContent("航线与机型") { Text("adsbdb.com，点击飞机时查询").foregroundStyle(.secondary) }
                LabeledContent("最近一次更新") { Text(lastUpdateText).foregroundStyle(.secondary) }
                Text("数据来自社区 ADS-B 接收网络，覆盖程度因地区而异；未广播的信息会显示为“—”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear {
            radiusDraft = settings.radiusKm
            sideDraft = Double(panelSide())
            loginItem = SMAppService.mainApp.status == .enabled
            routeKeyDraft = model.routeKey(for: settings.routeProvider)
        }
        .onChange(of: settings.routeProvider) { _, kind in
            routeKeyDraft = model.routeKey(for: kind)
            routeTestResult = nil
        }
        .onReceive(settings.$radiusKm) { radiusDraft = $0 }
    }

    private var locationStatus: String {
        switch location.state {
        case .idle: return "未启动"
        case .requesting: return "正在定位…"
        case .located:
            guard let c = location.coordinate else { return "已定位" }
            let acc = location.accuracy.map { String(format: " · 精度 ±%.0f m", $0) } ?? ""
            return String(format: "%.4f, %.4f", c.latitude, c.longitude) + acc
        case .denied: return "未获授权"
        case .servicesOff: return "系统定位服务已关闭"
        case .failed(let m): return "失败：\(m)"
        }
    }

    private var manualText: String {
        guard let c = settings.manualLocation else { return "未设置" }
        let name = settings.manualLocationName.isEmpty ? "" : "\(settings.manualLocationName) · "
        return name + String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    private var lastUpdateText: String {
        guard let t = tracker.lastSuccess else { return "尚无" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "\(f.string(from: t)) · \(tracker.activeFeedName ?? "") · 范围内 \(tracker.aircraft.count) 架"
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "无法更改登录项：\(error.localizedDescription)"
        }
        loginItem = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "需要在 系统设置 › 通用 › 登录项 中允许 HeadsUp。"
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchError = nil
        results = []
        if let c = Self.parseCoordinate(q) {
            results = [SearchResult(name: String(format: "%.4f, %.4f", c.latitude, c.longitude), detail: "坐标（WGS-84）", coordinate: c)]
            return
        }
        searching = true
        Task {
            defer { searching = false }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = [.address, .pointOfInterest]
            do {
                let items = try await MKLocalSearch(request: req).start().mapItems.prefix(5)
                var out: [SearchResult] = []
                for item in items {
                    var c = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                    // MapKit search returns coordinates in the datum of the map it serves.
                    if ChinaCoordinate.isInMainlandChina(c), await model.mapKitServesGCJ() {
                        c = ChinaCoordinate.gcj02ToWgs84(c)
                    }
                    let detail = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country]
                        .compactMap { $0 }.joined(separator: ", ")
                    out.append(SearchResult(name: item.name ?? q, detail: detail, coordinate: c))
                }
                results = out
                if out.isEmpty { searchError = "没有找到“\(q)”" }
            } catch {
                searchError = "搜索失败：\(error.localizedDescription)"
            }
        }
    }

    static func parseCoordinate(_ s: String) -> Coordinate? {
        let parts = s.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        let c = Coordinate(latitude: lat, longitude: lon)
        return c.isValid ? c : nil
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) { self.makeView = makeView }

    var nsWindow: NSWindow? { window }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "HeadsUp 设置"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: makeView())
            w.setContentSize(NSSize(width: 520, height: 640))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
