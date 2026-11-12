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
    @Test func nationwideCoordinatesAndSplitTsunamiMunicipality() {
        let sendai = NationalNotificationRegions.suggest(latitude: 38.268, longitude: 140.869)
        #expect(sendai.earthquake.map(\.id) == ["222"])
        #expect(sendai.tsunami.map(\.id) == ["220"])
        let toyohashi = NationalNotificationRegions.suggest(latitude: 34.7692, longitude: 137.3915)
        #expect(Set(toyohashi.tsunami.map(\.id)) == ["390", "391"])
        let inland = NationalNotificationRegions.suggest(latitude: 35.6556, longitude: 139.3389)
        #expect(inland.municipalityFound && inland.tsunami.isEmpty)
        let boundary = NationalNotificationRegions.suggest(latitude: 34.78895, longitude: 137.16832)
        #expect(Set(boundary.earthquake.map(\.id)) == ["450", "451"])
    }

    @Test @MainActor func confirmingTokyoHomeReplacesLegacySubscription() async {
        let s = settings()
        let homeEarthquake = DestinationSlot(place: .home, hazard: .earthquake)
        s.destinations = [homeEarthquake.key: SavedDestination(site: site(), meters: nil, distanceKind: nil)]
        let onboarding = OnboardingModel()
        onboarding.places[.home] = .init(title: "本郷", coordinate: .init(latitude: 35.7126, longitude: 139.7610))
        await onboarding.compute(repository: EvacuationRepository(sites: []))

        #expect(onboarding.regionsReady)
        #expect(onboarding.regionDrafts[.home]?.resolved?.earthquakeId == "350")
        onboarding.save(to: s)

        #expect(s.regionalSubscription.version == 2)
        #expect(s.regionalSubscription.targets.count == 1)
        #expect(s.regionalSubscription.targets.first?.earthquakeArea.name == "東京都２３区")
    }

    @Test func changingEvacuationSiteKeepsConfirmedPlaceArea() {
        let s = settings()
        let slot = DestinationSlot(place: .home, hazard: .earthquake)
        s.placeNotificationRegions = [.home: PlaceNotificationRegion(earthquakeId: "222", tsunamiId: "220")]
        s.regionalMonitoringEnabled = true
        s.destinations = [slot.key: SavedDestination(site: site(), meters: nil, distanceKind: nil)]
        #expect(s.regionalSubscription.enabled)
        #expect(s.regionalSubscription.targets.first?.earthquakeAreaId == "222")
        #expect(s.regionalSubscription.targets.first?.tsunamiAreaIds == ["220"])
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

    @Test(arguments: [false, true])
    func realReceiverPersistsDedupesAndDoesNotUseDrillTitlesOrTreatWatchAsEvacuation(deliveredRemotely: Bool) async throws {
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
        #expect(await receiver.receive(alert, now: now, deliveredRemotely: deliveredRemotely) != nil)
        #expect(try await store.snapshot() == nil, "Watch should not open high-ground guidance")
        let first = await notifications.scheduled
        #expect(first.count == (deliveredRemotely ? 0 : 1))
        if !deliveredRemotely {
            #expect(first.first?.title == "TSUNAMI_WATCH")
            #expect(first.first?.body.contains("Home") == true)
        }
        let relaunched = RegionalAlertReceiver(settings: s, notifications: notifications, registry: Fixtures.registry, store: store, persistence: persistence)
        #expect(await relaunched.receive(alert, now: now, deliveredRemotely: deliveredRemotely) != nil)
        #expect(await notifications.scheduled.count == (deliveredRemotely ? 0 : 1))
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
        #expect(await relaunched.receive(alert, now: now, deliveredRemotely: deliveredRemotely) != nil)
        let session = try await store.snapshot()
        #expect(session?.mode == .live)
        #expect(session?.hazard == .tsunami)
        #expect(await notifications.scheduled.count == (deliveredRemotely ? 0 : 1))
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
