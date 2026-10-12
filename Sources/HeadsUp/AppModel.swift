import Combine
import Foundation
import HeadsUpCore
import MapKit

/// Glue between settings, location, the flight feed and the selected aircraft.
@MainActor
final class AppModel: ObservableObject {
    enum CenterSource: Equatable { case live, manual, lastKnown, none }

    let settings: SettingsStore
    let location: LocationService
    let tracker: FlightTracker
    let routes: RouteService
    let terrain = TerrainModel()

    @Published private(set) var center: Coordinate?
    @Published private(set) var centerSource: CenterSource = .none
    @Published private(set) var selectedID: String?
    @Published private(set) var route: Lookup<FlightRoute>?
    @Published private(set) var airframe: Lookup<AircraftInfo>?
    /// Whether the Apple base map under the current center is drawn in GCJ-02.
    @Published private(set) var mapIsGCJ = false
    /// What the current filter text resolved to, for the settings window.
    @Published private(set) var filterSummary = ""
    @Published private(set) var filterProblems: [String] = []
    private var iataCache: [String: [String]] = [:]
    private var filterTask: Task<Void, Never>?

    private var gcjProbe: Bool?
    private var probing = false
    private var bag = Set<AnyCancellable>()

    init(settings: SettingsStore, location: LocationService, tracker: FlightTracker, routes: RouteService) {
        self.settings = settings
        self.location = location
        self.tracker = tracker
        self.routes = routes

        settings.$radiusKm.removeDuplicates().sink { [weak self] r in self?.tracker.radiusKm = r }.store(in: &bag)

        Publishers.CombineLatest4(location.$coordinate, location.$state, settings.$useManualLocation, settings.$manualLocation)
            .sink { [weak self] coord, state, useManual, manual in
                self?.updateCenter(live: coord, state: state, useManual: useManual, manual: manual)
            }
            .store(in: &bag)

        Publishers.CombineLatest(settings.$filterEnabled, settings.$filterText.removeDuplicates())
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] on, text in self?.applyFilter(enabled: on, text: text) }
            .store(in: &bag)

        location.$countryCode.sink { [weak self] _ in self?.updateDatum() }.store(in: &bag)

        // Forward nested changes so views observing the model redraw.
        tracker.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        location.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)

        tracker.$aircraft.sink { [weak self] list in
            guard let self, let id = self.selectedID else { return }
            if !list.contains(where: { $0.id == id }) { self.select(nil) }
        }.store(in: &bag)
    }

    var selected: TrackedAircraft? {
        guard let id = selectedID else { return nil }
        return tracker.aircraft.first { $0.id == id }
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        route = nil
        airframe = nil
        guard let id, let a = tracker.aircraft.first(where: { $0.id == id })?.aircraft else { return }
        if let cs = a.callsign {
            route = .loading
            Task {
                let r = await routes.route(callsign: cs)
                if self.selectedID == id { self.route = r }
            }
        } else {
            route = .unknown
        }
        airframe = .loading
        Task {
            let info = await routes.aircraft(hex: a.hex)
            if self.selectedID == id { self.airframe = info }
        }
    }

    /// Resolves IATA codes through adsbdb, then hands the filter to the tracker.
    private func applyFilter(enabled: Bool, text: String) {
        filterTask?.cancel()
        filterTask = Task {
            var lookupFailed: [String] = []
            for code in FlightFilter.iataCodes(in: text) where iataCache[code] == nil {
                if let codes = await routes.icaoCodes(forIATA: code) { iataCache[code] = codes }
                else { lookupFailed.append(code) }
                if Task.isCancelled { return }
            }
            let built = FlightFilter.build(from: text, iataToICAO: iataCache)
            var problems: [String] = []
            if !built.invalid.isEmpty { problems.append("无法识别：\(built.invalid.joined(separator: "、"))") }
            let unknown = built.unresolved.filter { e in !lookupFailed.contains { e.hasPrefix($0) } }
            if !unknown.isEmpty { problems.append("找不到对应航司：\(unknown.joined(separator: "、"))") }
            if !lookupFailed.isEmpty { problems.append("航司代码查询失败（网络？）：\(lookupFailed.joined(separator: "、"))") }
            filterProblems = problems
            filterSummary = built.filter.tokens.map { t -> String in
                switch t { case .airline(let a): return "\(a)*"; case .callsign(let c): return c }
            }.sorted().joined(separator: "、")
            let active = enabled && !built.filter.tokens.isEmpty
            tracker.filter = active ? built.filter : nil
            if let id = selectedID, !tracker.aircraft.contains(where: { $0.id == id }) { select(nil) }
        }
    }

    func setManualLocation(_ c: Coordinate, name: String) {
        settings.manualLocation = c
        settings.manualLocationName = name
        settings.useManualLocation = true
    }

    /// Converts a WGS-84 coordinate into the datum of the map being shown.
    func mapCoordinate(_ c: Coordinate) -> Coordinate {
        ChinaCoordinate.toMapDatum(c, enabled: mapIsGCJ && settings.mapLook != .paper)
    }

    private func updateCenter(live: Coordinate?, state: LocationService.State, useManual: Bool, manual: Coordinate?) {
        let next: Coordinate?
        let source: CenterSource
        if useManual, let manual {
            (next, source) = (manual, .manual)
        } else if let live {
            (next, source) = (live, .live)
            if settings.lastKnownLocation.map({ Geo.distance($0, live) > 500 }) ?? true {
                settings.lastKnownLocation = live
            }
        } else if let manual, state == .denied || state == .servicesOff || isFailed(state) {
            (next, source) = (manual, .manual)
        } else if let last = settings.lastKnownLocation {
            (next, source) = (last, .lastKnown)
        } else {
            (next, source) = (nil, .none)
        }
        centerSource = source
        if next != center {
            center = next
            tracker.center = next
        }
        updateDatum()
    }

    private func isFailed(_ s: LocationService.State) -> Bool {
        if case .failed = s { return true }
        return false
    }

    /// Decides whether to shift coordinates to GCJ-02. Apple only serves the GCJ-02 China map to
    /// some devices, so when the center is in mainland China we ask MapKit where a known landmark
    /// is and compare it with its WGS-84 position.
    private func updateDatum() {
        guard let c = center, ChinaCoordinate.isInMainlandChina(c) else { mapIsGCJ = false; return }
        if let code = location.countryCode, code != "CN", centerSource == .live { mapIsGCJ = false; return }
        if let probe = gcjProbe { mapIsGCJ = probe; return }
        mapIsGCJ = location.countryCode == "CN" || Locale.current.region?.identifier == "CN"
        guard !probing else { return }
        probing = true
        Task {
            let result = await Self.probeGCJ()
            self.probing = false
            if let result { self.gcjProbe = result; self.updateDatum() }
        }
    }

    /// Whether MapKit on this Mac serves the GCJ-02 China map (probed once, then cached).
    func mapKitServesGCJ() async -> Bool {
        if let p = gcjProbe { return p }
        if let r = await Self.probeGCJ() { gcjProbe = r; updateDatum(); return r }
        return Locale.current.region?.identifier == "CN"
    }

    /// The Monument to the People's Heroes, WGS-84, and what MapKit search returned for it on a WGS-84 map.
    static let landmarkQuery = "Monument to the People's Heroes, Beijing"
    static let landmarkWGS = Coordinate(latitude: 39.90306, longitude: 116.39167)

    static func probeGCJ() async -> Bool? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = landmarkQuery
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: landmarkWGS.latitude, longitude: landmarkWGS.longitude),
                                        latitudinalMeters: 5000, longitudinalMeters: 5000)
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else { return nil }
        let found = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        let toWGS = Geo.distance(found, landmarkWGS)
        let toGCJ = Geo.distance(found, ChinaCoordinate.wgs84ToGcj02(landmarkWGS))
        guard min(toWGS, toGCJ) < 400 else { return nil }
        return toGCJ < toWGS
    }
}
