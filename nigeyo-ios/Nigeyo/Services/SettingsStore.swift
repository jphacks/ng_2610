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
    var seconds: Double? = nil              // walking time; absent in data saved before it was recorded
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
        static let lockScreenTested = "nigeyo.lockScreenTested"
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

    /// Set once the onboarding Live Activity test has been started on this device.
    var lockScreenTested: Bool {
        get { defaults.bool(forKey: Key.lockScreenTested) }
        set { defaults.set(newValue, forKey: Key.lockScreenTested) }
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

    var destinations: [String: SavedDestination] {
        get {
            guard let data = defaults.data(forKey: Key.destinations) else { return [:] }
            return (try? JSONDecoder().decode([String: SavedDestination].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.destinations) }
    }

    func destination(_ slot: DestinationSlot) -> SavedDestination? { destinations[slot.key] }

    func eraseAll() {
        for key in [Key.language, Key.onboarding, Key.installation, Key.destinations, Key.shortcutsAdded, Key.shortcutsTested, Key.lockScreenTested, Key.demoAutoConnect] {
            defaults.removeObject(forKey: key)
        }
    }
}
