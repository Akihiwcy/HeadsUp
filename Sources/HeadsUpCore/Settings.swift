import Foundation

public enum AppearanceMode: String, CaseIterable, Sendable { case system, light, dark }
public enum PanelLevel: String, CaseIterable, Sendable { case desktop, normal, floating }
public enum MapLook: String, CaseIterable, Sendable { case paper, standard, satellite }

/// User settings, persisted to UserDefaults on every change.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let defaultRadiusKm = 20.0
    public static let radiusRange: ClosedRange<Double> = 5...150

    private let defaults: UserDefaults

    @Published public var radiusKm: Double { didSet {
        let c = Self.clampRadius(radiusKm)
        if c != radiusKm { radiusKm = c; return }
        defaults.set(radiusKm, forKey: Keys.radius)
    } }
    @Published public var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published public var panelLevel: PanelLevel { didSet { defaults.set(panelLevel.rawValue, forKey: Keys.level) } }
    @Published public var mapLook: MapLook { didSet { defaults.set(mapLook.rawValue, forKey: Keys.mapLook) } }
    @Published public var showLabels: Bool { didSet { defaults.set(showLabels, forKey: Keys.labels) } }
    @Published public var useManualLocation: Bool { didSet { defaults.set(useManualLocation, forKey: Keys.useManual) } }
    @Published public var manualLocation: Coordinate? { didSet { save(manualLocation, Keys.manual) } }
    @Published public var manualLocationName: String { didSet { defaults.set(manualLocationName, forKey: Keys.manualName) } }
    @Published public var filterEnabled: Bool { didSet { defaults.set(filterEnabled, forKey: Keys.filterOn) } }
    /// Airline codes and flight numbers, comma separated, e.g. "UAL, MU5101".
    @Published public var filterText: String { didSet { defaults.set(filterText, forKey: Keys.filterText) } }
    /// Optional flight-status service for routes; its API key lives in the Keychain, not here.
    @Published public var routeProvider: RouteProviderKind { didSet { defaults.set(routeProvider.rawValue, forKey: Keys.routeProvider) } }
    /// Whether dragging the map pans the view (the origin stays put).
    @Published public var mapDragEnabled: Bool { didSet { defaults.set(mapDragEnabled, forKey: Keys.mapDrag) } }
    /// Panel frame as x, y (bottom-left, screen points) and side length.
    @Published public var panelFrame: [Double]? { didSet { defaults.set(panelFrame, forKey: Keys.panelFrame) } }
    /// Last position CoreLocation gave us, used to start quickly on the next launch.
    @Published public var lastKnownLocation: Coordinate? { didSet { save(lastKnownLocation, Keys.lastKnown) } }

    enum Keys {
        static let radius = "radiusKm", appearance = "appearance", level = "panelLevel", mapLook = "mapLook"
        static let labels = "showLabels", useManual = "useManualLocation", manual = "manualLocation"
        static let manualName = "manualLocationName", lastKnown = "lastKnownLocation"
        static let filterOn = "filterEnabled", filterText = "filterText", panelFrame = "panelFrame", mapDrag = "mapDragEnabled", routeProvider = "routeProvider"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let r = defaults.object(forKey: Keys.radius) as? Double
        radiusKm = Self.clampRadius(r ?? Self.defaultRadiusKm)
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        panelLevel = PanelLevel(rawValue: defaults.string(forKey: Keys.level) ?? "") ?? .desktop
        mapLook = MapLook(rawValue: defaults.string(forKey: Keys.mapLook) ?? "") ?? .paper
        showLabels = defaults.object(forKey: Keys.labels) as? Bool ?? true
        useManualLocation = defaults.bool(forKey: Keys.useManual)
        manualLocation = Self.load(defaults, Keys.manual)
        manualLocationName = defaults.string(forKey: Keys.manualName) ?? ""
        lastKnownLocation = Self.load(defaults, Keys.lastKnown)
        filterEnabled = defaults.bool(forKey: Keys.filterOn)
        filterText = defaults.string(forKey: Keys.filterText) ?? ""
        mapDragEnabled = defaults.bool(forKey: Keys.mapDrag)
        routeProvider = RouteProviderKind(rawValue: defaults.string(forKey: Keys.routeProvider) ?? "") ?? .none
        let f = defaults.array(forKey: Keys.panelFrame) as? [Double]
        panelFrame = (f?.count == 3 && f!.allSatisfy(\.isFinite)) ? f : nil
    }

    public static func clampRadius(_ r: Double) -> Double {
        guard r.isFinite else { return defaultRadiusKm }
        return min(max(r.rounded(), radiusRange.lowerBound), radiusRange.upperBound)
    }

    private func save(_ c: Coordinate?, _ key: String) {
        if let c, let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static func load(_ d: UserDefaults, _ key: String) -> Coordinate? {
        guard let data = d.data(forKey: key), let c = try? JSONDecoder().decode(Coordinate.self, from: data), c.isValid else { return nil }
        return c
    }
}
