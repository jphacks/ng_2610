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

/// Walking distance for the onboarding top-3 only: ≤2 concurrent, 8 s each. No polyline,
/// steps or ETA are ever shown (spec §15.2).
enum WalkingDistance {
    static let timeout: Duration = .seconds(8)

    static func meters(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async -> Double? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .walking
        // MKDirections is not Sendable; it is only touched by these two child tasks (calculate / cancel).
        nonisolated(unsafe) let directions = MKDirections(request: request)
        return await withTaskGroup(of: Double?.self) { group in
            group.addTask { try? await directions.calculate().routes.first?.distance }
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

    /// Returns walking metres (nil = failed) for each candidate, two requests at a time.
    static func batch(from origin: CLLocationCoordinate2D, to sites: [EvacuationSite]) async -> [String: Double?] {
        var result: [String: Double?] = [:]
        for chunk in stride(from: 0, to: sites.count, by: 2).map({ Array(sites[$0..<min($0 + 2, sites.count)]) }) {
            await withTaskGroup(of: (String, Double?).self) { group in
                for site in chunk { group.addTask { (site.id, await meters(from: origin, to: site.coordinate)) } }
                for await (id, m) in group { result[id] = m }
            }
        }
        return result
    }
}

enum GoogleMaps {
    /// https://www.google.com/maps/dir/?api=1&destination=lat%2Clon&travelmode=walking — no origin, no API key.
    static func directionsURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://www.google.com/maps/dir/")!
        c.queryItems = [URLQueryItem(name: "api", value: "1"),
                        URLQueryItem(name: "destination", value: "\(latitude),\(longitude)"),
                        URLQueryItem(name: "travelmode", value: "walking")]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: ",", with: "%2C")
        return c.url!
    }

    static func searchURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://www.google.com/maps/search/")!
        c.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: "\(latitude),\(longitude)")]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: ",", with: "%2C")
        return c.url!
    }
}
