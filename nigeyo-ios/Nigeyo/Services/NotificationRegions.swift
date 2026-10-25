import Foundation

struct EarthquakeRegion: Codable, Equatable, Sendable {
    var pref: String
    var name: String
}

struct NotificationRegion: Codable, Equatable, Sendable {
    var siteId: String
    var version: Int
    var earthquakeArea: EarthquakeRegion?
    /// configured = nonempty list; none = explicitly no mapped area; unconfigured = needs selection.
    var tsunamiStatus: String
    var tsunamiAreas: [String]
    var confirmed: Bool

    var isReady: Bool {
        confirmed && version == NotificationRegionTable.shared.version &&
        NotificationRegionTable.shared.earthquakeAreas.contains(where: { $0 == earthquakeArea }) &&
        (tsunamiStatus == "none" ? tsunamiAreas.isEmpty : tsunamiStatus == "configured" && !tsunamiAreas.isEmpty &&
         tsunamiAreas.allSatisfy { NotificationRegionTable.shared.tsunamiAreas.contains($0) })
    }
}

struct RegionalTarget: Codable, Equatable, Sendable {
    var slot: String
    var siteId: String
    var earthquakeArea: EarthquakeRegion
    var tsunamiStatus: String
    var tsunamiAreas: [String]
}

struct RegionalSubscription: Codable, Sendable {
    var version: Int
    var enabled: Bool
    var targets: [RegionalTarget]
}

struct NotificationRegionTable: Decodable, Sendable {
    struct Municipality: Decodable, Sendable {
        var name: String
        var earthquakeArea: EarthquakeRegion
        var tsunamiStatus: String
        var tsunamiAreas: [String]
    }
    var version: Int
    var earthquakeAreas: [EarthquakeRegion]
    var tsunamiAreas: [String]
    var municipalities: [Municipality]

    static let shared: Self = {
        guard let url = Bundle.main.url(forResource: "notification-regions-aichi", withExtension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(version: 0, earthquakeAreas: [], tsunamiAreas: [], municipalities: [])
        }
        return value
    }()

    func suggest(site: EvacuationSite) -> NotificationRegion {
        let values = [site.address, site.municipality].map {
            $0.precomposedStringWithCompatibilityMapping.components(separatedBy: .whitespacesAndNewlines).joined()
        }.filter { !$0.isEmpty }
        let candidates = municipalities.filter { m in
            values.contains { value in
                let local = value.hasPrefix("愛知県") ? String(value.dropFirst(3)) : value
                let withoutCounty = local.replacingOccurrences(of: "^[^市町村]+郡", with: "", options: .regularExpression)
                return withoutCounty.hasPrefix(m.name)
            }
        }
        let hasAichi = values.contains { $0.hasPrefix("愛知県") }
        let conflicting = values.contains { !$0.hasPrefix("愛知県") && $0.range(of: "^.+[都道府県]", options: .regularExpression) != nil }
        let found = hasAichi && !conflicting && candidates.count == 1 ? candidates.first : nil
        return NotificationRegion(siteId: site.id, version: version, earthquakeArea: found?.earthquakeArea,
                                  tsunamiStatus: found?.tsunamiStatus ?? "unconfigured", tsunamiAreas: found?.tsunamiAreas ?? [], confirmed: false)
    }
}

extension SettingsStore {
    func region(for slot: DestinationSlot) -> NotificationRegion? {
        guard let site = destination(slot)?.site else { return nil }
        if let saved = notificationRegions[slot.key], saved.siteId == site.id, saved.version == NotificationRegionTable.shared.version { return saved }
        return NotificationRegionTable.shared.suggest(site: site)
    }

    var regionalSubscription: RegionalSubscription {
        let slots = DestinationSlot.all.filter { destination($0)?.site != nil }
        let targets = slots.compactMap { slot -> RegionalTarget? in
            guard let r = region(for: slot), r.isReady, let area = r.earthquakeArea else { return nil }
            return RegionalTarget(slot: slot.key, siteId: r.siteId, earthquakeArea: area, tsunamiStatus: r.tsunamiStatus, tsunamiAreas: r.tsunamiAreas)
        }
        return RegionalSubscription(version: NotificationRegionTable.shared.version,
                                    enabled: regionalMonitoringEnabled && !slots.isEmpty && targets.count == slots.count, targets: targets)
    }
}
