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

    var isComputing: Bool { slots.values.contains(.loading) }

    func compute(repository: EvacuationRepository) async {
        guard computedFor != places || slots.isEmpty else { return }
        computedFor = places
        for slot in DestinationSlot.all { slots[slot] = places[slot.place] == nil ? .notSet : .loading }
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
            for await (slot, state) in group { slots[slot] = state }
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
        settings.destinations = saved
        discard()
    }

    func discard() {
        places = [:]
        computedFor = [:]
        slots = [:]
    }
}
