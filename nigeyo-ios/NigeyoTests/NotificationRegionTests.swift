import Foundation
import Testing
@testable import Nigeyo

@Suite struct NotificationRegionTests {
    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "regional-test-\(UUID().uuidString)")!)
    }
    private func site(_ city: String = "名古屋市") -> EvacuationSite {
        EvacuationSite(id: city, name: "School", address: "愛知県\(city)1-1", municipality: "愛知県\(city)",
                       latitude: 0, longitude: 0, supportsEarthquake: true, supportsTsunami: true)
    }
    @Test func automaticMappingAndLegacyMigrationRequireConfirmation() {
        let s = settings()
        let slot = DestinationSlot(place: .home, hazard: .earthquake)
        s.destinations = [slot.key: SavedDestination(site: site(), meters: nil, distanceKind: nil)]
        let suggestion = s.region(for: slot)!
        #expect(suggestion.earthquakeArea?.pref == "愛知")
        #expect(suggestion.earthquakeArea?.name == "愛知県西部")
        #expect(suggestion.tsunamiAreas == ["伊勢・三河湾"])
        #expect(!suggestion.isReady)
        s.regionalMonitoringEnabled = true
        #expect(!s.regionalSubscription.enabled)
        var confirmed = suggestion
        confirmed.confirmed = true
        s.notificationRegions = [slot.key: confirmed]
        #expect(s.regionalSubscription.enabled)
        s.destinations = [slot.key: SavedDestination(site: site("日進市"), meters: nil, distanceKind: nil)]
        #expect(!s.regionalSubscription.enabled)
        #expect(s.region(for: slot)?.tsunamiStatus == "none")
        #expect(s.region(for: slot)?.confirmed == false)
        #expect(NotificationRegionTable.shared.suggest(site: site("豊橋市")).tsunamiStatus == "unconfigured")
        #expect(NotificationRegionTable.shared.suggest(site: site("田原市")).tsunamiStatus == "unconfigured")
        #expect(NotificationRegionTable.shared.suggest(site: site("不明市")).earthquakeArea == nil)
    }

    @Test func realReceiverPersistsDedupesAndDoesNotUseDrillTitlesOrTreatWatchAsEvacuation() async throws {
        let s = settings()
        let slot = DestinationSlot(place: .home, hazard: .earthquake)
        s.destinations = [slot.key: SavedDestination(site: site(), meters: nil, distanceKind: nil)]
        var config = s.region(for: slot)!
        config.confirmed = true
        s.notificationRegions = [slot.key: config]
        s.regionalMonitoringEnabled = true
        await Fixtures.registry.load()
        let notifications = FakeNotifications()
        let persistence = MemoryPersistence()
        let store = SessionStore(persistence: MemoryPersistence())
        let receiver = RegionalAlertReceiver(settings: s, notifications: notifications, registry: Fixtures.registry, store: store, persistence: persistence)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var alert = RegionalAlert(schemaVersion: 2, type: "regional-alert", commandId: UUID(), hazard: .tsunami, sourceEventId: "t1",
                                  issuedAt: now, status: "active", grade: "Watch", notify: true,
                                  matches: [.init(slot: slot.key, siteId: site().id, region: "伊勢・三河湾")],
                                  tsunamiAreas: ["伊勢・三河湾": "Watch"], mode: "live", sentAt: now, expiresAt: now.addingTimeInterval(20))
        #expect(await receiver.receive(alert, now: now) != nil)
        #expect(try await store.snapshot() == nil, "Watch should not open high-ground guidance")
        let first = await notifications.scheduled
        #expect(first.count == 1)
        #expect(first.first?.title == "TSUNAMI_WATCH")
        #expect(first.first?.body.contains("Home") == true)
        let relaunched = RegionalAlertReceiver(settings: s, notifications: notifications, registry: Fixtures.registry, store: store, persistence: persistence)
        #expect(await relaunched.receive(alert, now: now) != nil)
        #expect(await notifications.scheduled.count == 1)
        alert.commandId = UUID()
        alert.status = "cancelled"
        alert.notify = false
        #expect(await relaunched.receive(alert, now: now) != nil)
        #expect(await notifications.scheduled.isEmpty)
        #expect(await relaunched.latest()["tsunami"]?.status == "cancelled")
        alert.commandId = UUID()
        alert.status = "active"
        alert.grade = "Warning"
        alert.notify = true
        #expect(await relaunched.receive(alert, now: now) != nil)
        let session = try await store.snapshot()
        #expect(session?.mode == .live)
        #expect(session?.hazard == .tsunami)
        #expect(await notifications.scheduled.count == 1)
        alert.commandId = UUID()
        alert.status = "cancelled"
        alert.notify = false
        #expect(await relaunched.receive(alert, now: now) != nil)
        #expect(try await store.snapshot()?.isActive == false)
        #expect(await notifications.scheduled.isEmpty)
    }
    @Test func persistenceFailureNeverSchedulesAndRecoveryRetriesSafely() async throws {
        let s = settings()
        let slot = DestinationSlot(place: .home, hazard: .earthquake)
        s.destinations = [slot.key: SavedDestination(site: site(), meters: nil, distanceKind: nil)]
        var config = s.region(for: slot)!
        config.confirmed = true
        s.notificationRegions = [slot.key: config]
        s.regionalMonitoringEnabled = true
        await Fixtures.registry.load()
        let persistence = MemoryPersistence()
        persistence.failSaves = true
        let notifications = FakeNotifications()
        let receiver = RegionalAlertReceiver(settings: s, notifications: notifications, registry: Fixtures.registry,
                                             store: SessionStore(persistence: MemoryPersistence()), persistence: persistence)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let alert = RegionalAlert(schemaVersion: 2, type: "regional-alert", commandId: UUID(), hazard: .earthquake, sourceEventId: "e1",
                                  issuedAt: now, status: "active", notify: true,
                                  matches: [.init(slot: slot.key, siteId: site().id, region: "愛知県西部")],
                                  mode: "live", sentAt: now, expiresAt: now.addingTimeInterval(20))
        #expect(await receiver.receive(alert, now: now) == nil)
        #expect(await notifications.scheduled.isEmpty)
        persistence.failSaves = false
        #expect(await receiver.receive(alert, now: now) != nil)
        #expect(await notifications.scheduled.count == 1)
        #expect(await notifications.scheduled.first?.title == "EARTHQUAKE_ALERT")
    }

}
