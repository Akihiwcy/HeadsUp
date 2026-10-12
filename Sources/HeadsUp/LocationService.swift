import CoreLocation
import HeadsUpCore

@MainActor
final class LocationService: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case located
        case denied
        case servicesOff
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var coordinate: Coordinate?
    @Published private(set) var accuracy: Double?
    @Published private(set) var countryCode: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var geocodedAt: Coordinate?
    private var started = false
    private var simulated = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
    }

    func start() {
        started = true
        // Test hook: pretend CoreLocation reported a failure state.
        switch ProcessInfo.processInfo.environment["HEADSUP_SIMULATE_LOCATION"] {
        case "denied": simulated = true; state = .denied; return
        case "servicesOff": simulated = true; state = .servicesOff; return
        case "failed": simulated = true; state = .failed("模拟的定位失败"); return
        default: break
        }
        guard CLLocationManager.locationServicesEnabled() else {
            state = .servicesOff
            return
        }
        apply(manager.authorizationStatus)
    }

    func stop() {
        started = false
        manager.stopUpdatingLocation()
    }

    private func apply(_ status: CLAuthorizationStatus) {
        guard started, !simulated else { return }
        switch status {
        case .notDetermined:
            state = .requesting
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
            manager.stopUpdatingLocation()
        default:
            if state != .located { state = .requesting }
            manager.startUpdatingLocation()
        }
    }

    private func received(_ loc: CLLocation) {
        let c = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        guard c.isValid else { return }
        coordinate = c
        accuracy = loc.horizontalAccuracy
        state = .located
        if geocodedAt.map({ Geo.distance($0, c) > 20_000 }) ?? true {
            geocodedAt = c
            geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
                let code = marks?.first?.isoCountryCode
                Task { @MainActor in if let code { self?.countryCode = code } }
            }
        }
    }

    private func failed(_ error: Error) {
        let code = (error as? CLError)?.code
        switch code {
        case .denied:
            state = .denied
        case .locationUnknown:
            // Transient; CoreLocation keeps trying. Only surface it if we have nothing yet.
            if coordinate == nil { state = .failed("暂时无法确定位置") }
        default:
            if coordinate == nil { state = .failed(error.localizedDescription) }
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.apply(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.received(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.failed(error) }
    }
}
