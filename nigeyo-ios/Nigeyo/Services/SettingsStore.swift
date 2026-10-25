import Foundation

/// One of the four saved slots: home/university × earthquake/tsunami.
struct DestinationSlot: Hashable, Codable, Sendable {
    var place: PlaceContext
    var hazard: Hazard

    static let all: [DestinationSlot] = [
        .init(place: .home, hazard: .earthquake), .init(place: .home, hazard: .tsunami),
        .init(place: .university, hazard: .earthquake), .init(place: .university, hazard: .tsunami),
    ]
    var key: String { "\(place.rawValue).\(hazard.rawValue)" }
}

/// Only public facility data is saved; the user's own address and coordinates never are (spec §16).
struct SavedDestination: Codable, Equatable, Sendable {
    enum DistanceKind: String, Codable, Sendable { case walking, straight }
    var site: EvacuationSite?          // nil = confirmed "no suitable site nearby"
    var meters: Double?
    var distanceKind: DistanceKind?
}

/// Light settings in UserDefaults (spec §2).
final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let language = "nigeyo.language"
        static let onboarding = "nigeyo.onboardingCompleted"
        static let installation = "nigeyo.installationId"
        static let destinations = "nigeyo.destinations"
        static let shortcutsAdded = "nigeyo.shortcutsAdded"
        static let shortcutsTested = "nigeyo.shortcutsTested"
        static let shortcutPreparation = "nigeyo.shortcutPreparation.v1"
        static let demoAutoConnect = "nigeyo.demoAutoConnect"
    }

    /// False after the user disconnects: no automatic reconnect (spec §9.5).
    var demoAutoConnect: Bool {
        get { defaults.bool(forKey: Key.demoAutoConnect) }
        set { defaults.set(newValue, forKey: Key.demoAutoConnect) }
    }

    var language: LanguageID {
        get { LanguageID(defaults.string(forKey: Key.language) ?? LanguageID.english.rawValue) }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboarding) }
        set { defaults.set(newValue, forKey: Key.onboarding) }
    }

    var shortcutsAdded: Bool {
        get { defaults.bool(forKey: Key.shortcutsAdded) }
        set { defaults.set(newValue, forKey: Key.shortcutsAdded) }
    }

    var shortcutsTested: Bool {
        get { defaults.bool(forKey: Key.shortcutsTested) }
        set { defaults.set(newValue, forKey: Key.shortcutsTested) }
    }

    var shortcutPreparation: ShortcutPreparation {
        get {
            guard let data = defaults.data(forKey: Key.shortcutPreparation),
                  let value = try? JSONDecoder().decode(ShortcutPreparation.self, from: data) else { return .init() }
            return value
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcutPreparation)
            shortcutsAdded = newValue.bothAdded
            shortcutsTested = newValue.complete
        }
    }

    /// Random per install; no device identifiers (spec §8.1).
    var installationId: UUID {
        lock.withLock {
            if let s = defaults.string(forKey: Key.installation), let id = UUID(uuidString: s) { return id }
            let id = UUID()
            defaults.set(id.uuidString, forKey: Key.installation)
            return id
        }
    }

    var notificationRegions: [String: NotificationRegion] {
        get {
            guard let data = defaults.data(forKey: "nigeyo.notificationRegions") else { return [:] }
            return (try? JSONDecoder().decode([String: NotificationRegion].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "nigeyo.notificationRegions") }
    }

    var regionalMonitoringEnabled: Bool {
        get { defaults.bool(forKey: "nigeyo.regionalMonitoringEnabled") }
        set { defaults.set(newValue, forKey: "nigeyo.regionalMonitoringEnabled") }
    }

    var destinations: [String: SavedDestination] {
        get {
            guard let data = defaults.data(forKey: Key.destinations) else { return [:] }
            return (try? JSONDecoder().decode([String: SavedDestination].self, from: data)) ?? [:]
        }
        set {
            let old = destinations
            if DestinationSlot.all.contains(where: { old[$0.key]?.site != newValue[$0.key]?.site }) {
                regionalMonitoringEnabled = false
                var saved = notificationRegions
                for slot in DestinationSlot.all where old[slot.key]?.site != newValue[slot.key]?.site { saved[slot.key] = nil }
                notificationRegions = saved
            }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.destinations)
        }
    }

    func destination(_ slot: DestinationSlot) -> SavedDestination? { destinations[slot.key] }

    func eraseAll() {
        for key in [Key.language, Key.onboarding, Key.installation, Key.destinations, Key.shortcutsAdded, Key.shortcutsTested, Key.shortcutPreparation, Key.demoAutoConnect, "nigeyo.notificationRegions", "nigeyo.regionalMonitoringEnabled"] {
            defaults.removeObject(forKey: key)
        }
    }
}
