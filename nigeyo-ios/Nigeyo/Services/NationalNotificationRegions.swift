import Foundation

struct NationalNotificationRegions: Decodable, Sendable {
    struct EarthquakeArea: Codable, Hashable, Sendable {
        var id: String
        var pref: String
        var name: String
    }

    struct TsunamiArea: Codable, Hashable, Sendable {
        var id: String
        var name: String
    }

    struct Suggestion: Equatable, Sendable {
        var earthquake: [EarthquakeArea]
        var tsunami: [TsunamiArea]
        var municipalityFound: Bool
    }

    var earthquakeAreas: [EarthquakeArea]
    var tsunamiAreas: [TsunamiArea]
    var municipalTsunamiAreas: [String: [String]]

    static let shared = load("notification-regions-national", as: Self.self)
        ?? Self(earthquakeAreas: [], tsunamiAreas: [], municipalTsunamiAreas: [:])
    private static let earthquakeBoundaries = loadBoundaries("notification-region-earthquake-boundaries")
    private static let municipalityBoundaries = loadBoundaries("notification-region-municipality-boundaries")

    private static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func loadBoundaries(_ name: String) -> [Boundary] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "deflate"),
              let compressed = try? NSData(contentsOf: url, options: []),
              let data = try? compressed.decompressed(using: .zlib) as Data else { return [] }
        return (try? JSONDecoder().decode([Boundary].self, from: data)) ?? []
    }

    static func suggest(latitude: Double, longitude: Double) -> Suggestion {
        let x = longitude * 100_000
        let y = latitude * 100_000
        let earthquakes = Set(earthquakeBoundaries.lazy.filter { $0.matches(x: x, y: y) }.map(\.id))
        let municipalities = Set(municipalityBoundaries.lazy.filter { $0.matches(x: x, y: y) }.map(\.id))
        let tsunami = Set(municipalities.flatMap { shared.municipalTsunamiAreas[$0] ?? [] })
        return Suggestion(earthquake: shared.earthquakeAreas.filter { earthquakes.contains($0.id) },
                          tsunami: shared.tsunamiAreas.filter { tsunami.contains($0.id) },
                          municipalityFound: !municipalities.isEmpty)
    }

    private struct Boundary: Decodable, Sendable {
        var id: String
        var bounds: [Int]
        var rings: [[Int]]

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            id = try values.decode(String.self)
            bounds = try values.decode([Int].self)
            rings = try values.decode([[Int]].self)
        }

        func matches(x: Double, y: Double) -> Bool {
            // Include nearby boundaries as candidates, accounting for simplified geometry.
            let margin = 35.0
            guard x >= Double(bounds[0]) - margin, x <= Double(bounds[2]) + margin,
                  y >= Double(bounds[1]) - margin, y <= Double(bounds[3]) + margin else { return false }
            var inside = false
            for ring in rings {
                guard ring.count >= 8 else { continue }
                for i in stride(from: 2, to: ring.count, by: 2) {
                    let ax = Double(ring[i - 2]), ay = Double(ring[i - 1])
                    let bx = Double(ring[i]), by = Double(ring[i + 1])
                    if min(ax, bx) - margin <= x, x <= max(ax, bx) + margin,
                       min(ay, by) - margin <= y, y <= max(ay, by) + margin {
                        let dx = bx - ax, dy = by - ay
                        let length = dx * dx + dy * dy
                        let fraction = length == 0 ? 0 : min(1, max(0, ((x - ax) * dx + (y - ay) * dy) / length))
                        let rx = x - (ax + fraction * dx), ry = y - (ay + fraction * dy)
                        if rx * rx + ry * ry <= margin * margin { return true }
                    }
                    if (ay > y) != (by > y), x < ax + (y - ay) * (bx - ax) / (by - ay) {
                        inside.toggle()
                    }
                }
            }
            return inside
        }
    }
}

struct PlaceNotificationRegion: Codable, Equatable, Sendable {
    var earthquakeId: String
    var tsunamiId: String?
}
