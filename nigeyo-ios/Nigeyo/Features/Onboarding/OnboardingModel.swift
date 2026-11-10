import CoreLocation
import Foundation
import Observation

/// Holds the home / university positions in memory only until the four slots are saved,
/// then discards them (spec §13.1, §15.1).
@MainActor
@Observable
final class OnboardingModel {
    struct Place: Equatable {
        var title: String
        var coordinate: CLLocationCoordinate2D
        static func == (a: Place, b: Place) -> Bool {
            a.title == b.title && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    struct Candidate: Equatable, Identifiable, Sendable {
        var site: EvacuationSite
        var straight: Double
        var walking: Double?
        var walkingSeconds: Double? = nil
        var id: String { site.id }
    }

    enum SlotState: Equatable {
        case notSet, loading, noSite
        case ready(candidates: [Candidate], selected: Int, walkingUnavailable: Bool)
    }

    var places: [PlaceContext: Place] = [:]
    var slots: [DestinationSlot: SlotState] = [:]
    private(set) var computedFor: [PlaceContext: Place] = [:]
    struct RegionDraft {
        var suggestion: NationalNotificationRegions.Suggestion
        var earthquakeId: String?
        var tsunamiId: String?
        var tsunamiConfirmed: Bool

        var resolved: PlaceNotificationRegion? {
            guard let earthquakeId, tsunamiConfirmed else { return nil }
            return PlaceNotificationRegion(earthquakeId: earthquakeId, tsunamiId: tsunamiId)
        }

        var canSave: Bool { resolved != nil || (suggestion.earthquake.isEmpty && earthquakeId == nil) }
    }
    var regionDrafts: [PlaceContext: RegionDraft] = [:]

    var isComputing: Bool { slots.values.contains(.loading) }
    var regionsReady: Bool { places.keys.allSatisfy { regionDrafts[$0]?.canSave == true } }

    func compute(repository: EvacuationRepository) async {
        guard computedFor != places || slots.isEmpty || isComputing else { return }
        let selected = places
        computedFor = selected
        regionDrafts = [:]
        for slot in DestinationSlot.all { slots[slot] = places[slot.place] == nil ? .notSet : .loading }
        let points = selected.mapValues { ($0.coordinate.latitude, $0.coordinate.longitude) }
        let suggestions = await Task.detached(priority: .userInitiated) {
            points.mapValues { NationalNotificationRegions.suggest(latitude: $0.0, longitude: $0.1) }
        }.value
        guard !Task.isCancelled, computedFor == selected else { return }
        regionDrafts = suggestions.mapValues { suggestion in
            RegionDraft(suggestion: suggestion,
                        earthquakeId: suggestion.earthquake.count == 1 ? suggestion.earthquake.first?.id : nil,
                        tsunamiId: suggestion.tsunami.count == 1 ? suggestion.tsunami.first?.id : nil,
                        tsunamiConfirmed: suggestion.tsunami.count == 1 || (suggestion.tsunami.isEmpty && suggestion.municipalityFound))
        }
        let targets = DestinationSlot.all.compactMap { slot in places[slot.place].map { (slot, $0.coordinate) } }
        await withTaskGroup(of: (DestinationSlot, SlotState).self) { group in
            for (slot, coordinate) in targets {
                group.addTask {
                    let top = (try? await repository.nearest(latitude: coordinate.latitude, longitude: coordinate.longitude, hazard: slot.hazard, limit: 3)) ?? []
                    guard !top.isEmpty else { return (slot, .noSite) }
                    let walking = await WalkingDistance.batch(from: coordinate, to: top.map(\.site))
                    let candidates = top.map { Candidate(site: $0.site, straight: $0.meters, walking: (walking[$0.site.id] ?? nil)?.meters, walkingSeconds: (walking[$0.site.id] ?? nil)?.seconds) }
                    return (slot, .ready(candidates: OnboardingModel.order(candidates), selected: 0, walkingUnavailable: candidates.allSatisfy { $0.walking == nil }))
                }
            }
            for await (slot, state) in group where !Task.isCancelled && computedFor == selected { slots[slot] = state }
        }
    }

    /// Successful walking distances first (shortest first), failures after them by straight line.
    nonisolated static func order(_ c: [Candidate]) -> [Candidate] {
        c.sorted { a, b in
            switch (a.walking, b.walking) {
            case let (x?, y?): return x != y ? x < y : a.site.id < b.site.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.straight != b.straight ? a.straight < b.straight : a.site.id < b.site.id
            }
        }
    }

    func select(_ slot: DestinationSlot, index: Int) {
        if case .ready(let c, _, let w) = slots[slot] { slots[slot] = .ready(candidates: c, selected: index, walkingUnavailable: w) }
    }

    /// Saves only public facility data; straight-line distance is never stored as walking distance.
    func save(to settings: SettingsStore) {
        var saved = settings.destinations
        for slot in DestinationSlot.all {
            switch slots[slot] {
            case .ready(let c, let i, _):
                let pick = c[i]
                saved[slot.key] = SavedDestination(site: pick.site, meters: pick.walking ?? pick.straight, distanceKind: pick.walking == nil ? .straight : .walking, seconds: pick.walkingSeconds)
            case .noSite:
                saved[slot.key] = SavedDestination(site: nil, meters: nil, distanceKind: nil)
            default:
                break
            }
        }
        if !places.isEmpty {
            var regions = settings.placeNotificationRegions ?? [:]
            for place in places.keys { regions[place] = regionDrafts[place]?.resolved }
            settings.regionalMonitoringEnabled = false
            settings.placeNotificationRegions = regions
        }
        settings.destinations = saved
        discard()
    }

    func discard() {
        places = [:]
        computedFor = [:]
        slots = [:]
        regionDrafts = [:]
    }
}
