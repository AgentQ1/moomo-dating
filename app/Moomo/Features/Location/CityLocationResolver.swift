import CoreLocation
import Foundation
import MapKit
import os

/// Turns a map position or a search string into a `CityLocation`.
///
/// The one rule this type exists to enforce: **no coordinate ever reaches a
/// profile through it.** Latitude and longitude are function arguments and
/// local variables here and nowhere else — every value handed back is a city, a
/// region and a country code, exactly what `CityLocation` can hold and exactly
/// what other users are ever shown. Widening `CityLocation` to carry a
/// coordinate would need a policy change and a backend schema change first.
///
/// Proximity ranking does not go through this type. It has its own path,
/// `CoarseLocationReporter`, which rounds a position to a ~1 km grid and writes
/// it to the owner-only `users/{uid}/private/location` — private, never
/// published, and never mixed into the profile this file feeds.
enum CityLocationResolver {

    private static let log = Logger(subsystem: "com.moomo.dating", category: "location")

    /// The city a coordinate falls in. Nil when the geocoder can name no
    /// locality — mid-ocean, or a rate-limited/offline geocoder.
    static func city(at coordinate: CLLocationCoordinate2D) async -> CityLocation? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            return placemarks.lazy.compactMap(cityLocation(from:)).first
        } catch {
            log.error("reverse geocode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Cities matching a typed query.
    ///
    /// The bundled `CityCatalog` answers first and always — it needs no
    /// network, and it keeps the cities the app already knows about at the top
    /// of the list. MapKit fills in everywhere else.
    static func search(_ query: String) async -> [CityLocation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let catalogMatches = CityCatalog.cities.filter {
            $0.city.localizedCaseInsensitiveContains(trimmed)
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = .address

        var remote: [CityLocation] = []
        do {
            let response = try await MKLocalSearch(request: request).start()
            remote = response.mapItems.compactMap { cityLocation(from: $0.placemark) }
        } catch {
            // An offline or rate-limited search still leaves the catalogue.
            log.debug("city search failed: \(String(describing: error), privacy: .public)")
        }

        return dedupe(catalogMatches + remote)
    }

    /// A city's approximate centre, so choosing from search can move the map.
    /// Transient: the caller shows it, it is never saved.
    static func centre(of city: CityLocation) async -> CLLocationCoordinate2D? {
        let query = [city.city, city.region, city.countryCode]
            .compactMap { $0 }
            .joined(separator: ", ")
        do {
            let placemarks = try await CLGeocoder().geocodeAddressString(query)
            return placemarks.first?.location?.coordinate
        } catch {
            log.debug("forward geocode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Mapping

    /// A placemark is only a city to us if it names a locality and a country.
    /// Anything vaguer would store as a blank or half-blank line on a profile.
    private static func cityLocation(from placemark: CLPlacemark) -> CityLocation? {
        guard let locality = placemark.locality, !locality.isEmpty,
              let country = placemark.isoCountryCode, !country.isEmpty
        else { return nil }

        let region = placemark.administrativeArea.flatMap { $0.isEmpty ? nil : $0 }
        return CityLocation(city: locality, region: region, countryCode: country)
    }

    /// Order-preserving dedupe. Search returns one hit per matching street in a
    /// city, which all collapse to the same `CityLocation`.
    private static func dedupe(_ cities: [CityLocation]) -> [CityLocation] {
        var seen = Set<String>()
        return cities.filter { seen.insert($0.display).inserted }
    }
}

/// One-shot access to the device's own city.
///
/// Wraps `CLLocationManager` so the picker can `await` a city instead of
/// living with the delegate. Coarse accuracy is requested deliberately: the
/// answer only has to be good enough to name a city, so there is no reason to
/// ask iOS for a precise fix.
@MainActor
final class CurrentCityLocator: NSObject, ObservableObject {

    enum Failure: Error {
        case denied
        case unavailable
    }

    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// Requests permission if it has not been asked for, then resolves the
    /// device's position to a city. Throws rather than returning nil so the
    /// picker can tell "you said no" from "we couldn't work it out".
    func currentCity() async throws -> CityLocation {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
            let granted = await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
            }
            guard granted == .authorizedWhenInUse || granted == .authorizedAlways else {
                throw Failure.denied
            }
        }
        guard isAuthorized else { throw Failure.denied }

        let location = try await withCheckedThrowingContinuation { continuation in
            // A second request while one is in flight would strand the first
            // continuation; the newest caller wins and the older one is failed.
            pending?.resume(throwing: Failure.unavailable)
            pending = continuation
            manager.requestLocation()
        }

        guard let city = await CityLocationResolver.city(at: location.coordinate) else {
            throw Failure.unavailable
        }
        return city
    }
}

extension CurrentCityLocator: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorization = status
            guard status != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters = []
            waiters.forEach { $0.resume(returning: status) }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let continuation = pending
            pending = nil
            continuation?.resume(returning: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let continuation = pending
            pending = nil
            continuation?.resume(throwing: Failure.unavailable)
        }
    }
}
