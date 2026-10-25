import CoreLocation
import Foundation

enum LocationError: Error, Equatable {
    case denied, timeout, unavailable
}

struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var age: TimeInterval
    /// Older than a minute or worse than 1 km: shown with a caution, never silently trusted (spec §16).
    var needsCaution: Bool { age > 60 || horizontalAccuracy > 1000 || horizontalAccuracy < 0 }
}

/// When-in-use, one-shot location for the "other" place choice only. Nothing is persisted.
/// The manager is created on the main thread, so its delegate callbacks arrive there too.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let timeout: Duration = .seconds(8)
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationFix, Error>?
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> LocationFix {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { c in
                authContinuation = c
                manager.requestWhenInUseAuthorization()
            }
        }
        if [.denied, .restricted].contains(manager.authorizationStatus) { throw LocationError.denied }
        return try await withCheckedThrowingContinuation { c in
            finish(.failure(LocationError.unavailable))
            continuation = c
            manager.requestLocation()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(LocationError.timeout))
            }
        }
    }

    private func finish(_ result: Result<LocationFix, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let loc = locations.last else { return }
            finish(.success(LocationFix(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                                        horizontalAccuracy: loc.horizontalAccuracy, age: -loc.timestamp.timeIntervalSinceNow)))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { finish(.failure(denied ? LocationError.denied : LocationError.unavailable)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard self.manager.authorizationStatus != .notDetermined else { return }
            authContinuation?.resume()
            authContinuation = nil
        }
    }
}
