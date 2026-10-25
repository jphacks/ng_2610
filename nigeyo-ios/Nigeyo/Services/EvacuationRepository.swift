import CoreLocation
import Foundation

/// One record of the GSI 指定緊急避難場所 data, names and addresses verbatim.
struct EvacuationSite: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var address: String
    var municipality: String
    var latitude: Double
    var longitude: Double
    var supportsEarthquake: Bool
    var supportsTsunami: Bool
    var notes: String?

    func supports(_ hazard: Hazard) -> Bool { hazard == .tsunami ? supportsTsunami : supportsEarthquake }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct SiteDistance: Equatable, Sendable, Identifiable {
    var site: EvacuationSite
    var meters: Double
    var id: String { site.id }
}

enum Geo {
    static let earthRadius = 6_371_000.0

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r
        let dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}

/// Loads the bundled national dataset once, off the main thread, and answers nearest-site queries offline.
actor EvacuationRepository {
    static let searchRadius = 100_000.0

    private let source: @Sendable () throws -> Data
    private var sites: [EvacuationSite]?
    private var byId: [String: EvacuationSite] = [:]

    init(bundle: Bundle = .main) {
        self.source = {
            guard let url = bundle.url(forResource: "evacuation-sites", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    init(sites: [EvacuationSite]) {
        self.source = { try JSONEncoder().encode(sites) }
    }

    private func load() throws -> [EvacuationSite] {
        if let sites { return sites }
        let decoded = try JSONDecoder().decode([EvacuationSite].self, from: source())
        sites = decoded
        byId = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return decoded
    }

    func preload() { _ = try? load() }

    func site(id: String) -> EvacuationSite? {
        _ = try? load()
        return byId[id]
    }

    /// Hazard-compatible sites within 100 km, nearest first (ties by id). Nothing farther is
    /// presented as "nearby" (spec §14.3).
    func nearest(latitude: Double, longitude: Double, hazard: Hazard, limit: Int) throws -> [SiteDistance] {
        let all = try load()
        // Cheap bounding box before the exact distance.
        let dLat = Self.searchRadius / 111_000
        let dLon = Self.searchRadius / max(1, 111_000 * cos(latitude * .pi / 180))
        var hits: [SiteDistance] = []
        for site in all where site.supports(hazard) && abs(site.latitude - latitude) <= dLat && abs(site.longitude - longitude) <= dLon {
            if Task.isCancelled { throw CancellationError() }
            let d = Geo.haversine(latitude, longitude, site.latitude, site.longitude)
            if d <= Self.searchRadius { hits.append(SiteDistance(site: site, meters: d)) }
        }
        hits.sort { $0.meters != $1.meters ? $0.meters < $1.meters : $0.site.id < $1.site.id }
        return Array(hits.prefix(limit))
    }
}
