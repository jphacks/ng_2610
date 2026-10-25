import CoreLocation
import Foundation
import MapKit
import Observation

/// Address / place search for onboarding: completer suggestions 300 ms after typing,
/// previous query cancelled, MKLocalSearch to resolve the coordinate (spec §15.1).
@MainActor
@Observable
final class PlaceSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { schedule() }
    }
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false
    private(set) var noResults = false

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var debounce: Task<Void, Never>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = MKCoordinateRegion(center: .init(latitude: 36.2, longitude: 138.25), span: .init(latitudeDelta: 20, longitudeDelta: 20))
    }

    private func schedule() {
        debounce?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            completer.cancel()
            suggestions = []
            isSearching = false
            noResults = false
            return
        }
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isSearching = true
            completer.cancel()
            completer.queryFragment = q
        }
    }

    // MKLocalSearchCompleter calls its delegate on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            let results = self.completer.results
            suggestions = Array(results.prefix(6))
            isSearching = false
            noResults = results.isEmpty
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            isSearching = false
            noResults = true
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response?.mapItems.first?.location.coordinate
    }

    func clear() {
        query = ""
    }
}

/// Walking distance and time for the onboarding top-3 only: ≤2 concurrent, 8 s each. No polyline
/// or steps are ever shown (spec §15.2).
enum WalkingDistance {
    typealias Route = (meters: Double, seconds: Double)
    static let timeout: Duration = .seconds(8)

    static func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> Route? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .walking
        // MKDirections is not Sendable; it is only touched by these two child tasks (calculate / cancel).
        nonisolated(unsafe) let directions = MKDirections(request: request)
        return await withTaskGroup(of: Route?.self) { group in
            group.addTask { (try? await directions.calculate().routes.first).map { ($0.distance, $0.expectedTravelTime) } }
            group.addTask {
                try? await Task.sleep(for: timeout)
                directions.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Returns the walking route (nil = failed) for each candidate, two requests at a time.
    static func batch(from origin: CLLocationCoordinate2D, to sites: [EvacuationSite]) async -> [String: Route?] {
        var result: [String: Route?] = [:]
        for chunk in stride(from: 0, to: sites.count, by: 2).map({ Array(sites[$0..<min($0 + 2, sites.count)]) }) {
            await withTaskGroup(of: (String, Route?).self) { group in
                for site in chunk { group.addTask { (site.id, await route(from: origin, to: site.coordinate)) } }
                for await (id, m) in group { result[id] = m }
            }
        }
        return result
    }
}

/// Hands off to the Apple Maps app via the `maps://` scheme (always the app, never a browser). No origin is sent;
/// Maps uses the device's own location. In-app navigation is never implemented.
enum AppleMaps {
    /// Walking directions to the site.
    static func directionsURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "maps://")!
        c.queryItems = [URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"), URLQueryItem(name: "dirflg", value: "w")]
        return c.url!
    }

    /// A pin on the site, labelled with its name.
    static func placeURL(latitude: Double, longitude: Double, name: String) -> URL {
        var c = URLComponents(string: "maps://")!
        c.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"), URLQueryItem(name: "q", value: name)]
        return c.url!
    }
}
