import Foundation
import Testing
@testable import Nigeyo

// MARK: - Test doubles

final class MemoryPersistence: SessionPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failSaves = false

    func load() throws -> Data? { lock.withLock { data } }
    func save(_ d: Data) throws {
        try lock.withLock {
            if failSaves { throw CocoaError(.fileWriteNoPermission) }
            data = d
        }
    }
    func delete() throws { lock.withLock { data = nil } }
}

actor FakeNotifications: NotificationScheduling {
    var auth: NotificationAuthorization = .authorized
    var scheduled: [GuideContent.NotificationContent] = []
    var fail = false

    func setAuth(_ a: NotificationAuthorization) { auth = a }
    func setFail(_ f: Bool) { fail = f }
    func authorization() async -> NotificationAuthorization { auth }
    func schedule(_ content: GuideContent.NotificationContent, after seconds: TimeInterval) async throws {
        if fail { throw CocoaError(.featureUnsupported) }
        scheduled.append(content)
    }
    func exists(identifier: String) async -> Bool { scheduled.contains { $0.identifier == identifier } }
    func cancel(identifiers: [String]) async { scheduled.removeAll { identifiers.contains($0.identifier) } }
    func cancelAllNigeyo() async { scheduled.removeAll() }
}

enum Fixtures {
    static let registry: LanguageRegistry = {
        let r = LanguageRegistry(bundle: Bundle(for: BundleToken.self).hostApp, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)"))
        return r
    }()

    static func snapshot(_ id: String = "en") async -> LanguageSnapshot {
        await registry.load()
        return await registry.snapshot(for: LanguageID(id))!
    }

    static let quake = QuakeSummary(sourceEventId: "6adc2a51e88ee598246bf418", code: 551, occurredAt: "2026-10-24T12:44:00+09:00",
                                    issuedAt: "2026-10-24T12:47:28+09:00", hypocenterName: "陸奥湾", magnitude: 2.9, maxScale: 10)

    static func session(_ id: UUID = UUID(), mode: SessionMode = .demo) async -> GuideSession {
        GuideSession.new(id: id, mode: mode, source: mode == .demo ? .liveAPI : .local, scenario: .earthquake, quake: mode == .demo ? quake : nil, snapshot: await snapshot())
    }
}

final class BundleToken {}

extension Bundle {
    /// Resources live in the host app bundle (the test bundle is injected into it).
    var hostApp: Bundle { Bundle.main }
}

// MARK: - SessionStore

@Suite struct SessionStoreTests {
    @Test func prepareRejectsADifferentActiveSessionButAllowsAfterCompletion() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        let a = await Fixtures.session()
        try await store.prepare(a, receivedAt: Date())
        await #expect(throws: SessionStoreError.sessionBusy) { try await store.prepare(await Fixtures.session(), receivedAt: Date()) }
        try await store.complete(sessionId: a.sessionId)
        try await store.prepare(await Fixtures.session(), receivedAt: Date())
    }

    @Test func stateSurvivesRelaunchAndNeverRewindsToProtect() async throws {
        let p = MemoryPersistence()
        let s = await Fixtures.session()
        do {
            let store = SessionStore(persistence: p)
            try await store.prepare(s, receivedAt: Date())
            try await store.transition(sessionId: s.sessionId, expectedRevision: 1, to: .safetyChecks)
            try await store.selectPlace(sessionId: s.sessionId, context: .other, candidateIds: ["gsi:a", "gsi:b"])
            try await store.selectDestination(sessionId: s.sessionId, destinationId: "gsi:b")
        }
        let relaunched = try await SessionStore(persistence: p).snapshot()
        #expect(relaunched?.phase == .showDestination)
        #expect(relaunched?.selectedDestinationId == "gsi:b")
        #expect(relaunched?.candidateDestinationIds == ["gsi:a", "gsi:b"])
    }

    @Test func confirmIsIdempotentAndStaleRevisionsAreRejected() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        let s = await Fixtures.session()
        try await store.prepare(s, receivedAt: Date())
        let first = try await store.transition(sessionId: s.sessionId, expectedRevision: 1, to: .safetyChecks)
        let again = try await store.transition(sessionId: s.sessionId, expectedRevision: 1, to: .safetyChecks)
        #expect(first == again, "a double tap does not advance twice")
        await #expect(throws: SessionStoreError.staleRevision) {
            try await store.transition(sessionId: s.sessionId, expectedRevision: 1, to: .choosePlace)
        }
    }

    @Test func tsunamiWinsOverEarthquakeAndALateConfirmationCannotRollItBack() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        let s = await Fixtures.session()
        try await store.prepare(s, receivedAt: Date())
        let result = try await store.applyHazardUpdate(sessionId: s.sessionId, commandId: UUID(), revision: 1, summary: nil, receivedAt: Date())
        guard case .applied(let t) = result else { Issue.record("not applied"); return }
        #expect(t.hazard == .tsunami && t.phase == .tsunamiEvacuate)
        await #expect(throws: SessionStoreError.staleRevision) {
            try await store.transition(sessionId: s.sessionId, expectedRevision: 1, to: .safetyChecks)
        }
        #expect(try await store.snapshot()?.phase == .tsunamiEvacuate)
    }

    @Test func hazardUpdatesAreOrderedByHazardRevisionAndDeduplicatedByCommand() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        let s = await Fixtures.session()
        try await store.prepare(s, receivedAt: Date())
        let cmd = UUID()
        _ = try await store.applyHazardUpdate(sessionId: s.sessionId, commandId: cmd, revision: 2, summary: nil, receivedAt: Date())
        // A local confirmation in between bumps stateRevision but must not hide newer hazard info.
        if case .duplicate = try await store.applyHazardUpdate(sessionId: s.sessionId, commandId: cmd, revision: 2, summary: nil, receivedAt: Date()) {} else { Issue.record("expected duplicate") }
        if case .stale = try await store.applyHazardUpdate(sessionId: s.sessionId, commandId: UUID(), revision: 1, summary: nil, receivedAt: Date()) {} else { Issue.record("expected stale") }
        if case .applied = try await store.applyHazardUpdate(sessionId: s.sessionId, commandId: UUID(), revision: 3, summary: nil, receivedAt: Date()) {} else { Issue.record("expected applied") }
    }

    @Test func evacuationRequiresAChosenDestination() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        let s = await Fixtures.session()
        try await store.prepare(s, receivedAt: Date())
        await #expect(throws: SessionStoreError.invalidTransition) { try await store.confirmEvacuation(sessionId: s.sessionId, expectedRevision: 1) }
        try await store.selectPlace(sessionId: s.sessionId, context: .home, candidateIds: ["gsi:a"])
        try await store.selectDestination(sessionId: s.sessionId, destinationId: "gsi:a")
        let rev = try await store.snapshot()!.stateRevision
        let going = try await store.confirmEvacuation(sessionId: s.sessionId, expectedRevision: rev)
        #expect(going.evacuationDecision == .going)
        #expect(!LiveActivityCoordinator.wantsActivity(going), "going ends the Live Activity")
    }

    @Test func storageFailureLeavesStateUnchanged() async throws {
        let p = MemoryPersistence()
        let store = SessionStore(persistence: p)
        p.failSaves = true
        await #expect(throws: SessionStoreError.storageFailed) { try await store.prepare(await Fixtures.session(), receivedAt: Date()) }
        #expect(try await store.snapshot() == nil)
    }

    @Test func receiptsKeepTheLatestHundred() async throws {
        let store = SessionStore(persistence: MemoryPersistence())
        var last: UUID?
        for _ in 0..<105 {
            let s = await Fixtures.session()
            try await store.prepare(s, receivedAt: Date())
            try await store.complete(sessionId: s.sessionId)
            last = s.sessionId
        }
        #expect(try await store.receipt(for: last!) != nil)
    }
}

// MARK: - CommandProcessor (spec §9.2)

@Suite struct CommandProcessorTests {
    func make(language: String = "en", persistence: MemoryPersistence = MemoryPersistence()) async -> (CommandProcessor, SessionStore, FakeNotifications) {
        await Fixtures.registry.load()
        let store = SessionStore(persistence: persistence)
        let notifications = FakeNotifications()
        let p = CommandProcessor(store: store, notifications: notifications, registry: Fixtures.registry,
                                 preferredLanguage: { LanguageID(language) }, deviceState: { DeviceState(appState: "background", protectedDataAvailable: false) })
        return (p, store, notifications)
    }

    func start(runId: UUID = UUID(), language: String = "en", sentAt: Date = Date(), expiresIn: TimeInterval = 20) -> StartGuideCommand {
        StartGuideCommand(schemaVersion: 2, type: "start-guide", runId: runId, mode: .demo, source: .liveAPI, language: LanguageID(language), scenario: .earthquake,
                          languagePackageVersion: 1, stateRevision: 1, hazard: .earthquake, sentAt: sentAt, expiresAt: sentAt.addingTimeInterval(expiresIn), quake: Fixtures.quake)
    }

    @Test func savesThenSchedulesAndAcks() async throws {
        let (p, store, n) = await make()
        let cmd = start()
        let ack = await p.handleStart(cmd)
        #expect(ack.status == .scheduled)
        #expect(ack.runId == cmd.runId)
        #expect(try await store.snapshot()?.sessionId == cmd.runId)
        let scheduled = await n.scheduled
        #expect(scheduled.count == 1)
        #expect(scheduled[0].title == "EARTHQUAKE_TEST")
        #expect(scheduled[0].identifier == "nigeyo.\(cmd.runId.uuidString.lowercased())")
        #expect(scheduled[0].body.count <= 200)
        #expect(scheduled[0].userInfo["sessionId"] == cmd.runId.uuidString)
    }

    @Test func sameRunIdTwiceNotifiesOnce() async throws {
        let (p, _, n) = await make()
        let cmd = start()
        _ = await p.handleStart(cmd)
        let second = await p.handleStart(cmd)
        #expect(second.status == .duplicate)
        #expect(await n.scheduled.count == 1)
    }

    @Test func otherRunWhileActiveReplacesSession() async throws {
        let (p, store, _) = await make()
        _ = await p.handleStart(start())
        let second = start()
        let ack = await p.handleStart(second)
        #expect(ack.status == .scheduled)
        #expect(try await store.snapshot()?.sessionId == second.runId)
    }

    @Test func deniedNotificationsAreRejectedWithoutSaving() async throws {
        let (p, store, n) = await make()
        await n.setAuth(.denied)
        let ack = await p.handleStart(start())
        #expect(ack.errorCode == .notificationsDenied)
        #expect(try await store.snapshot() == nil)
    }

    @Test func storageFailureNeverNotifies() async throws {
        let persistence = MemoryPersistence()
        persistence.failSaves = true
        let (p, _, n) = await make(persistence: persistence)
        let ack = await p.handleStart(start())
        #expect(ack.status == .failed && ack.errorCode == .storageFailed)
        #expect(await n.scheduled.isEmpty)
    }

    @Test func expiryClockSkewAndLanguageAreChecked() async throws {
        let (p, _, _) = await make(language: "ja")
        #expect(await p.handleStart(start(language: "ja", sentAt: Date().addingTimeInterval(-30))).errorCode == .expiredCommand)
        #expect(await p.handleStart(start(language: "ja", sentAt: Date().addingTimeInterval(10))).errorCode == .clockSkew)
        #expect(await p.handleStart(start(language: "en")).errorCode == .languageMismatch)
        #expect(await p.handleStart(start(language: "xx")).errorCode == .languagePackageMissing)
        #expect(await p.handleStart(start(language: "ja")).status == .scheduled)
    }

    @Test func notificationFailureIsReported() async throws {
        let (p, _, n) = await make()
        await n.setFail(true)
        let ack = await p.handleStart(start())
        #expect(ack.status == .failed && ack.errorCode == .notificationFailed)
    }

    @Test func tsunamiUpdateForTheSameSessionIsAppliedOnceAndNotified() async throws {
        let (p, store, n) = await make()
        let runId = UUID()
        _ = await p.handleStart(start(runId: runId))
        let cmd = HazardUpdateCommand(schemaVersion: 2, type: "hazard-update", commandId: UUID(), sessionId: runId, hazardRevision: 1, hazard: .tsunami, mode: .demo,
                                      source: .local, language: LanguageID("en"), languagePackageVersion: 1, sentAt: Date(), expiresAt: Date().addingTimeInterval(20), tsunami: nil)
        let ack = await p.handleHazard(cmd)
        #expect(ack.status == .scheduled && ack.commandId == cmd.commandId && ack.sessionId == runId)
        #expect(try await store.snapshot()?.phase == .tsunamiEvacuate)
        #expect(await n.scheduled.last?.title == "TSUNAMI_TEST")
        #expect(await p.handleHazard(cmd).status == .duplicate)
        #expect(await n.scheduled.count == 2)
        var other = cmd
        other.sessionId = UUID()
        other.commandId = UUID()
        #expect(await p.handleHazard(other).status == .rejected, "never overwrites another session")
    }

    @Test func messagesDecodeFromTheContractSample() throws {
        let json = """
        {"schemaVersion":2,"type":"start-guide","runId":"7b79b216-37a3-4ce9-9bc4-2a47bd76270c","mode":"demo","source":"live-api","language":"en","scenario":"earthquake",
         "languagePackageVersion":1,"stateRevision":1,"hazard":"earthquake","sentAt":"2026-10-24T06:54:34Z","expiresAt":"2026-10-24T06:54:54Z",
         "quake":{"sourceEventId":"6adc2a51e88ee598246bf418","code":551,"occurredAt":"2026-10-24T12:44:00+09:00","issuedAt":"2026-10-24T12:47:28+09:00","hypocenterName":"陸奥湾","magnitude":2.9,"maxScale":10}}
        """
        guard case .startGuide(let cmd) = IncomingMessage.decode(Data(json.utf8)) else { Issue.record("decode failed"); return }
        #expect(cmd.quake?.isValid == true)
        if case .invalid(.unsupportedVersion, _) = IncomingMessage.decode(Data(json.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":1").utf8)) {} else { Issue.record("v1 accepted") }
        if case .invalid(.invalidPayload, _) = IncomingMessage.decode(Data(#"{"schemaVersion":2,"type":"surprise"}"#.utf8)) {} else { Issue.record("unknown type accepted") }
    }
}

// MARK: - Languages

@Suite struct LanguageTests {
    @Test func bundledPackagesAreCompleteAndListedWithoutCodeChanges() async throws {
        await Fixtures.registry.load()
        let ids = await Fixtures.registry.available().map(\.id.rawValue)
        #expect(Set(ids).isSuperset(of: ["en", "ja", "ko"]))
        #expect(ids.first == "en")
        #expect(await Fixtures.registry.package(for: LanguageID("zz"))?.languageId == .english, "unknown → en")
    }

    @Test func aFourthLanguageJSONIsAddedAndABrokenOneIsRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let en = try Data(contentsOf: Bundle.main.url(forResource: "en", withExtension: "json")!)
        var pkg = try JSONDecoder().decode(LanguagePackage.self, from: en)
        pkg.languageId = LanguageID("vi")
        pkg.nativeName = "Tiếng Việt"
        try JSONEncoder().encode(pkg).write(to: dir.appendingPathComponent("vi.json"))
        var broken = pkg
        broken.languageId = LanguageID("fr")
        broken.strings.removeValue(forKey: "guide.unsafeButton")
        try JSONEncoder().encode(broken).write(to: dir.appendingPathComponent("fr.json"))
        let registry = LanguageRegistry(cacheDirectory: dir)
        await registry.load()
        let ids = await registry.available().map(\.id.rawValue)
        #expect(ids.contains("vi"))
        #expect(!ids.contains("fr"), "a package missing keys is rejected as a whole")
    }

    @Test func installRequiresMatchingChecksumAndKeepsThePreviousVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        let registry = LanguageRegistry(cacheDirectory: dir)
        await registry.load()
        let ja = try Data(contentsOf: Bundle.main.url(forResource: "ja", withExtension: "json")!)
        await #expect(throws: LanguageUpdateError.checksumMismatch) { try await registry.install(ja, expectedSHA256: String(repeating: "0", count: 64)) }
        #expect(await registry.package(for: LanguageID("ja"))?.packageVersion == 1)
    }

    @Test func snapshotsFreezeTheSessionLanguage() async throws {
        let ko = await Fixtures.snapshot("ko")
        let s = GuideSession.new(mode: .training, source: .local, scenario: .earthquake, quake: nil, snapshot: ko)
        let content = GuideContent.activityState(for: s)
        #expect(content.headline == ko.strings["guide.protect.short"])
        #expect(GuideContent.earthquakeNotification(for: s).body == ko.strings["notification.earthquake.bodyTraining"])
    }
}

// MARK: - Live Activity content

@Suite struct LiveActivityContentTests {
    @Test(arguments: ["en", "ja", "ko"])
    func everyLayoutFitsTheFourKilobyteBudget(language: String) async throws {
        var s = GuideSession.new(mode: .demo, source: .liveAPI, scenario: .earthquake, quake: Fixtures.quake, snapshot: await Fixtures.snapshot(language))
        for (phase, hazard) in [(GuidePhase.protect, Hazard.earthquake), (.safetyChecks, .earthquake), (.tsunamiEvacuate, .tsunami)] {
            s.phase = phase
            s.hazard = hazard
            let state = GuideContent.activityState(for: s)
            #expect(GuideContent.encodedActivitySize(sessionId: s.sessionId, state: state) <= 4096)
            #expect(state.pictograms.count == (phase == .safetyChecks ? 3 : 1))
        }
    }

    @Test func checksShowThreePictogramsAndManualHasNoDrillBadge() async throws {
        var s = GuideSession.new(mode: .manual, source: .manual, scenario: .earthquake, quake: nil, snapshot: await Fixtures.snapshot("ja"))
        s.phase = .safetyChecks
        let state = GuideContent.activityState(for: s)
        #expect(state.layout == .checks)
        #expect(state.pictograms == ["check-surroundings", "check-fire", "secure-exit"])
        #expect(state.badge == nil)
    }

    @Test func trainingStaysOffTheLockScreenUntilTheNotificationFires() async throws {
        var s = GuideSession.new(mode: .training, source: .local, scenario: .earthquake, quake: nil, snapshot: await Fixtures.snapshot())
        s.notificationScheduledFor = Date().addingTimeInterval(10)
        #expect(!LiveActivityCoordinator.wantsActivity(s))
        #expect(LiveActivityCoordinator.wantsActivity(s, now: Date().addingTimeInterval(11)))
    }
}

// MARK: - Evacuation data, maps, misc

@Suite struct EvacuationTests {
    func site(_ id: String, _ lat: Double, _ lon: Double, eq: Bool = true, ts: Bool = false) -> EvacuationSite {
        EvacuationSite(id: id, name: id, address: "", municipality: "", latitude: lat, longitude: lon, supportsEarthquake: eq, supportsTsunami: ts, notes: nil)
    }

    @Test func filtersByHazardSortsByDistanceThenIdAndCapsAt100km() async throws {
        let repo = EvacuationRepository(sites: [
            site("b", 35.001, 139.0), site("a", 35.001, 139.0), site("tsunami-only", 35.0005, 139.0, eq: false, ts: true),
            site("far", 36.5, 139.0), site("c", 35.01, 139.0),
        ])
        let eq = try await repo.nearest(latitude: 35.0, longitude: 139.0, hazard: .earthquake, limit: 5).map(\.site.id)
        #expect(eq == ["a", "b", "c"])
        let ts = try await repo.nearest(latitude: 35.0, longitude: 139.0, hazard: .tsunami, limit: 2).map(\.site.id)
        #expect(ts == ["tsunami-only"], "earthquake-only sites are never offered for a tsunami")
    }

    @Test func haversineMatchesAKnownDistance() {
        // Tokyo Station → Shinjuku Station ≈ 6.1 km
        let d = Geo.haversine(35.6812, 139.7671, 35.6896, 139.7006)
        #expect(abs(d - 6_080) < 150)
    }

    @Test func bundledNationalDataLoads() async throws {
        let repo = EvacuationRepository()
        let near = try await repo.nearest(latitude: 38.2682, longitude: 140.8694, hazard: .tsunami, limit: 2) // Sendai
        #expect(near.count == 2)
        #expect(near.allSatisfy { $0.site.supportsTsunami })
    }

    @Test func walkingFailuresSortAfterSuccesses() {
        let s = { (id: String) in EvacuationSite(id: id, name: id, address: "", municipality: "", latitude: 0, longitude: 0, supportsEarthquake: true, supportsTsunami: false, notes: nil) }
        let ordered = OnboardingModel.order([
            .init(site: s("x"), straight: 100, walking: nil), .init(site: s("y"), straight: 300, walking: 900), .init(site: s("z"), straight: 200, walking: 400),
        ])
        #expect(ordered.map(\.id) == ["z", "y", "x"])
    }

    @Test func appleMapsURLsOpenTheAppWalkingWithoutOrigin() {
        #expect(AppleMaps.directionsURL(latitude: 35.5, longitude: 139.25).absoluteString == "maps://?daddr=35.5,139.25&dirflg=w")
        #expect(AppleMaps.placeURL(latitude: 35.5, longitude: 139.25, name: "A B").absoluteString == "maps://?ll=35.5,139.25&q=A%20B")
    }

    @Test func pairingAcceptsOnlyWssDeviceURLs() {
        let token = String(repeating: "A", count: 43)
        let p = Pairing.parse("wss://demo.example.com/public/device?token=\(token)")
        #expect(p?.token == token)
        #expect(p?.origin.absoluteString == "https://demo.example.com")
        #expect(Pairing.parse("ws://demo.example.com/public/device?token=\(token)") == nil)
        #expect(Pairing.parse("wss://demo.example.com/other?token=\(token)") == nil)
        #expect(Pairing.parse("wss://demo.example.com/public/device") == nil)
    }

    @Test @MainActor func trainingDelayIsFiveToFifteenSeconds() {
        #expect(AppModel.trainingDelayRange == 5...15)
    }
}
