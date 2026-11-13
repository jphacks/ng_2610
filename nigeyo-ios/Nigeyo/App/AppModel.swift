import ActivityKit
import CoreLocation
import Foundation
import Observation
import UIKit

enum HomeRoute: Hashable {
    case practice, settings, language, savedPlaces, lockScreen, shortcuts, languageUpdate, demo, privacy, deleteData, diagnostics, redoPlaces
}

enum HomeNotice: Equatable { case missingSession }

/// The UI's view of the shared SessionStore plus app-level actions. Views never mutate the
/// session directly; every change goes through the store and comes back through `changes()`.
@MainActor
@Observable
final class AppModel {
    static let resumeWindow: TimeInterval = 30 * 60
    static let trainingDelay: TimeInterval = 3
    static let localTsunamiDelay: TimeInterval = 10

    @ObservationIgnored let services: Services
    @ObservationIgnored let location = LocationService()

    private(set) var session: GuideSession?
    private(set) var languages: [LanguageInfo] = []
    private(set) var strings: Strings = .empty
    private(set) var connection: ConnectionState = .disconnected
    private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    private(set) var liveActivitiesEnabled = true
    private(set) var onboardingCompleted: Bool
    private(set) var isForeground = false
    /// Bumped when a scheduled moment passes (training notification fire time) so views re-evaluate.
    private(set) var clock = Date()
    var homePath: [HomeRoute] = []
    var homeNotice: HomeNotice?
    var errorMessage: String?
    var resumeAcknowledged: Set<UUID> = []
    /// Last current-location fix for "other". Memory only, never persisted.
    var lastFix: LocationFix?
    var pairing: Pairing?

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let demoBackgroundGrace = DemoBackgroundGrace()
    @ObservationIgnored private var wasBackgrounded = false

    init(services: Services = .shared) {
        self.services = services
        onboardingCompleted = services.settings.onboardingCompleted
        pairing = PairingStore.load()
    }

    var guideStrings: Strings { session.map { Strings(snapshot: $0.languageSnapshot) } ?? strings }
    var settings: SettingsStore { services.settings }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await services.registry.loadIfNeeded()
        await reloadLanguages()
        Task {
            for await _ in Activity<NigeyoActivityAttributes>.pushToStartTokenUpdates {
                await LiveNotificationRegistration.refreshActivity(settings: settings)
            }
        }
        Task.detached(priority: .utility) { await Services.shared.evacuation.preload() }
        Task {
            for await s in await services.store.changes() {
                self.session = s
                self.scheduleTick()
                await self.services.liveActivities.sync(s, foreground: self.isForeground)
            }
        }
        Task {
            for await state in await services.delivery.states() {
                self.connection = state
                if state == .disconnected { self.demoBackgroundGrace.end() }
            }
        }
        notificationAuthorization = await services.notifications.authorization()
        #if DEBUG
        // Simulator E2E only: `-NigeyoDebugPairing wss://…` launch argument.
        if let text = UserDefaults.standard.string(forKey: "NigeyoDebugPairing"), await connect(pairingText: text) { return }
        #endif
        if let pairing, services.settings.demoAutoConnect { await services.delivery.connect(pairing) }
    }

    func reloadLanguages() async {
        languages = await services.registry.available()
        if let pkg = await services.registry.package(for: settings.language) {
            if pkg.languageId != settings.language { settings.language = pkg.languageId } // unknown → en
            strings = Strings(languageId: pkg.languageId, table: pkg.strings, isRTL: pkg.direction == "rtl")
        }
    }

    func becameActive() async {
        demoBackgroundGrace.end()
        let reconnect = wasBackgrounded
        wasBackgrounded = false
        isForeground = true
        clock = Date()
        notificationAuthorization = await services.notifications.authorization()
        liveActivitiesEnabled = services.liveActivities.areActivitiesEnabled
        await applyDueLocalHazard()
        await services.liveActivities.adoptRemoteActivities()
        let current = try? await services.store.snapshot()
        session = current
        await services.liveActivities.sync(current, foreground: true)
        Task { await LiveNotificationRegistration.refreshActivity(settings: settings) }
        if reconnect, let pairing, services.settings.demoAutoConnect {
            // A suspended socket may still appear connected until the next I/O.
            await services.delivery.connect(pairing)
        }
        else if connection == .connected { await services.delivery.sendHello() }
        else if connection == .disconnected, let pairing, services.settings.demoAutoConnect { await services.delivery.connect(pairing) }
    }

    func resignedActive() {
        isForeground = false
        if settings.demoAutoConnect, connection == .connected {
            demoBackgroundGrace.start()
        }
    }

    func enteredBackground() {
        wasBackgrounded = true
    }

    private func scheduleTick() {
        tickTask?.cancel()
        var next: Date?
        if let s = session, s.isActive {
            next = [s.notificationScheduledFor, s.pendingLocalHazard?.fireAt].compactMap { $0 }.filter { $0 > Date() }.min()
        }
        guard let next else { return }
        tickTask = Task {
            try? await Task.sleep(for: .seconds(max(0.1, next.timeIntervalSinceNow + 0.2)))
            guard !Task.isCancelled else { return }
            self.clock = Date()
            await self.applyDueLocalHazard()
            if let s = self.session { await self.services.liveActivities.sync(s, foreground: self.isForeground) }
            self.scheduleTick()
        }
    }

    // MARK: Routing (spec §10)

    enum Root: Equatable { case onboarding, waiting, guide, resumePrompt, home }

    var root: Root {
        if !onboardingCompleted { return .onboarding }
        guard let s = session, s.isActive else { return .home }
        if s.mode == .training, let fireAt = s.notificationScheduledFor, fireAt > clock { return .waiting }
        if clock.timeIntervalSince(s.startedAt) > Self.resumeWindow, !resumeAcknowledged.contains(s.sessionId) { return .resumePrompt }
        return .guide
    }

    func handle(url: URL) async {
        guard url.scheme == "nigeyo" else { return }
        switch url.host {
        case "guide":
            // Shortcut "open Nigeyo": an active session is shown directly by `root`, never via Home.
            if (try? await services.store.snapshot())?.isActive == true { homePath = [] }
        case "home":
            break
        case "evacuation":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sessionId" }?.value.flatMap(UUID.init)
            if let id { await services.liveActivities.adoptRemoteActivities(sessionId: id) }
            guard let id, let s = try? await services.store.snapshot(), s.sessionId == id, s.isActive else {
                homeNotice = .missingSession
                return
            }
            resumeAcknowledged.insert(id)
            if [.protect, .safetyChecks, .tsunamiEvacuate].contains(s.phase) {
                _ = try? await services.store.transition(sessionId: id, expectedRevision: s.stateRevision, to: .choosePlace)
            }
        case "shortcuts":
            if onboardingCompleted { homePath = [.settings, .shortcuts] }
        default:
            break
        }
    }

    func handleNotificationTap(userInfo: [String: String]) async {
        if userInfo[RemoteTrainingNotification.typeKey] == "regional-alert" {
            guard let json = userInfo["regionalAlert"],
                  let command = try? JSONDecoder.nigeyo.decode(RegionalAlert.self, from: Data(json.utf8)),
                  command.status == "active", command.notify else { return }
            await services.registry.loadIfNeeded()
            if await services.regionalAlerts.receive(command, deliveredRemotely: true) != nil {
                homeNotice = nil
                clock = Date()
            }
            return
        }
        guard userInfo[RemoteTrainingNotification.typeKey] != nil else {
            await handleNotification(userInfo: userInfo)
            return
        }
        await openRemoteTraining(userInfo: userInfo)
    }

    private func openRemoteTraining(userInfo: [String: String], onlyIfReplacingEarthquake: Bool = false) async {
        guard let notification = RemoteTrainingNotification(userInfo: userInfo),
              notification.expiresAt > Date() else { return }
        // A notification response may arrive before the first scene's startup task.
        await services.registry.loadIfNeeded()
        guard let language = await snapshot() else { return }
        do {
            guard let guide = try await services.store.openRemoteTraining(notification, language: language,
                onlyIfReplacingEarthquake: onlyIfReplacingEarthquake) else { return }
            resumeAcknowledged.insert(guide.sessionId)
            homeNotice = nil
            clock = Date()
        } catch {
            errorMessage = Strings(snapshot: language)["error.storage-failed"]
        }
    }

    func handleNotification(userInfo: [String: String]) async {
        if userInfo[RemoteTrainingNotification.typeKey] != nil {
            if isForeground, userInfo["hazard"] == Hazard.tsunami.rawValue {
                await openRemoteTraining(userInfo: userInfo, onlyIfReplacingEarthquake: true)
            }
            return
        }
        await applyDueLocalHazard()
        guard let sid = userInfo["sessionId"].flatMap(UUID.init) else { return }
        let current = try? await services.store.snapshot()
        if current?.sessionId == sid, current?.isActive == true {
            resumeAcknowledged.insert(sid)
            homeNotice = nil
        } else {
            homeNotice = .missingSession
        }
        clock = Date()
    }

    // MARK: Starting guidance

    private func snapshot() async -> LanguageSnapshot? {
        await services.registry.snapshot(for: settings.language)
    }

    /// "揺れを感じました": no API, notification or shortcut (spec §13.7).
    func startManual() async {
        if let s = session, s.isActive {
            resumeAcknowledged.insert(s.sessionId)
            return
        }
        guard let snap = await snapshot() else { return }
        let s = GuideSession.new(mode: .manual, source: .manual, scenario: .earthquake, quake: nil, snapshot: snap)
        do {
            try await services.store.prepare(s, receivedAt: Date())
            await services.diagnostics.record("manual guidance started \(s.sessionId)")
        } catch {
            errorMessage = strings["error.storage-failed"]
        }
    }

    /// Local drill: first alert after 3 seconds; a combined drill adds tsunami 10 seconds later.
    func startTraining(scenario: Scenario) async -> Bool {
        if notificationAuthorization == .notDetermined { notificationAuthorization = await services.notifications.requestAuthorization() }
        guard notificationAuthorization == .authorized || notificationAuthorization == .provisional else {
            errorMessage = strings["practice.notificationsDenied"]
            return false
        }
        guard let snap = await snapshot() else { return false }
        let fireAt = Date().addingTimeInterval(Self.trainingDelay)
        var s = GuideSession.new(mode: .training, source: .local, scenario: scenario, quake: nil, snapshot: snap,
                                 hazard: scenario == .tsunami ? .tsunami : .earthquake)
        s.notificationScheduledFor = fireAt
        if scenario == .earthquakeTsunami {
            s.pendingLocalHazard = PendingLocalHazard(commandId: UUID(), fireAt: fireAt.addingTimeInterval(Self.localTsunamiDelay))
        }
        let notification = scenario == .tsunami
            ? GuideContent.tsunamiNotification(for: s, commandId: nil)
            : GuideContent.earthquakeNotification(for: s)
        var scheduled = [String]()
        do {
            try await services.store.prepare(s, receivedAt: Date())
            try await services.notifications.schedule(notification, after: max(0.1, fireAt.timeIntervalSinceNow))
            scheduled.append(notification.identifier)
            try await services.store.markNotificationScheduled(sessionId: s.sessionId, fireAt: fireAt)
            if let pending = s.pendingLocalHazard {
                var preview = s
                preview.hazard = .tsunami
                let followUp = GuideContent.tsunamiNotification(for: preview, commandId: pending.commandId)
                try await services.notifications.schedule(followUp, after: max(0.1, pending.fireAt.timeIntervalSinceNow))
                scheduled.append(followUp.identifier)
            }
            await services.liveActivities.scheduleLocalTraining(s, at: fireAt)
            await services.diagnostics.record("training \(scenario.rawValue) scheduled in \(Int(Self.trainingDelay))s")
            resumeAcknowledged.insert(s.sessionId)
            return true
        } catch SessionStoreError.sessionBusy {
            return true
        } catch {
            await services.notifications.cancel(identifiers: scheduled)
            try? await services.store.complete(sessionId: s.sessionId)
            errorMessage = strings["error.generic"]
            return false
        }
    }

    /// Applies an in-app tsunami drill whose time has come, through the same store path as the server's.
    func applyDueLocalHazard() async {
        await services.liveActivities.applyDueLocalTsunami()
    }

    // MARK: Guide actions

    private func run(_ body: (GuideSession) async throws -> Void) async {
        guard let s = session else { return }
        do {
            try await body(s)
        } catch SessionStoreError.staleRevision {
            session = try? await services.store.snapshot()
        } catch {
            errorMessage = guideStrings["error.generic"]
        }
    }

    func confirmShakingStopped() async {
        await run { try await services.store.transition(sessionId: $0.sessionId, expectedRevision: $0.stateRevision, to: .safetyChecks) }
    }

    func goToChoosePlace() async {
        await run { try await services.store.transition(sessionId: $0.sessionId, expectedRevision: $0.stateRevision, to: .choosePlace) }
    }

    func backFromChoosePlace() async {
        await run { s in
            try await services.store.transition(sessionId: s.sessionId, expectedRevision: s.stateRevision, to: s.hazard == .tsunami ? .tsunamiEvacuate : .safetyChecks)
        }
    }

    func choose(context: PlaceContext, candidates: [String]) async {
        await run { try await services.store.selectPlace(sessionId: $0.sessionId, context: context, candidateIds: candidates) }
    }

    func selectDestination(_ id: String) async {
        await run { try await services.store.selectDestination(sessionId: $0.sessionId, destinationId: id) }
    }

    func backToChoosePlace() async {
        await run { try await services.store.transition(sessionId: $0.sessionId, expectedRevision: $0.stateRevision, to: .choosePlace) }
    }

    /// "この避難場所へ向かう": saves going and immediately ends the Live Activity (spec §13.2-6).
    func confirmEvacuation() async {
        await run { s in
            let updated = try await services.store.confirmEvacuation(sessionId: s.sessionId, expectedRevision: s.stateRevision)
            await services.liveActivities.sync(updated, foreground: isForeground)
        }
    }

    /// Ends drill or manual guidance: pending notifications, session and Live Activity together.
    func endSession() async {
        guard let s = session else { return }
        var ids = ["nigeyo.\(s.sessionId.uuidString.lowercased())"]
        if let pending = s.pendingLocalHazard { ids.append("nigeyo.\(s.sessionId.uuidString.lowercased()).\(pending.commandId.uuidString.lowercased())") }
        await services.notifications.cancel(identifiers: ids)
        try? await services.store.complete(sessionId: s.sessionId)
        await services.liveActivities.sync(try? await services.store.snapshot(), foreground: isForeground)
        await services.diagnostics.record("session \(s.sessionId) completed")
        homePath = []
    }

    func acknowledgeResume() {
        if let s = session { resumeAcknowledged.insert(s.sessionId) }
    }

    // MARK: Settings

    func setLanguage(_ id: LanguageID) async {
        settings.language = id
        await reloadLanguages()
        await LiveNotificationRegistration.refreshActivity(settings: settings)
        await services.delivery.sendHello()
    }

    func requestNotifications() async {
        notificationAuthorization = await services.notifications.requestAuthorization()
        await services.delivery.sendHello()
    }

    func completeOnboarding() {
        settings.onboardingCompleted = true
        onboardingCompleted = true
    }

    func connect(pairingText: String) async -> Bool {
        guard let p = Pairing.parse(pairingText) else { return false }
        PairingStore.save(p)
        pairing = p
        settings.demoAutoConnect = true
        await services.delivery.connect(p)
        return true
    }

    func disconnect() async {
        demoBackgroundGrace.end()
        settings.demoAutoConnect = false
        await services.delivery.disconnect()
    }

    func updateLanguages() async -> Result<LanguageUpdater.Outcome, LanguageUpdateError> {
        if session?.isActive == true { return .failure(.busy) }
        guard let origin = pairing?.origin else { return .failure(.noOrigin) }
        do {
            let outcome = try await LanguageUpdater(registry: services.registry).update(origin: origin)
            await reloadLanguages()
            await services.diagnostics.record("language update: +\(outcome.added) ~\(outcome.updated) rejected \(outcome.rejected)")
            return .success(outcome)
        } catch let e as LanguageUpdateError {
            return .failure(e)
        } catch {
            return .failure(.network)
        }
    }

    func resetSession() async {
        await endSession()
    }

    func setLiveRegistration(enabled: Bool) async throws {
        if enabled {
            guard await services.notifications.requestAuthorization() == .authorized else {
                throw LiveNotificationRegistration.Failure.notificationsDenied
            }
        }
        var subscription = settings.regionalSubscription
        subscription.enabled = enabled
        if !enabled { subscription.targets = [] }
        if enabled {
            guard LiveNotificationRegistration.endpoint != nil else {
                throw LiveNotificationRegistration.Failure.missingEndpoint
            }
            settings.liveRegistrationNeedsRevocation = true
        }
        try await LiveNotificationRegistration.update(subscription, language: settings.language)
        settings.liveRegistrationNeedsRevocation = enabled
        settings.regionalMonitoringEnabled = enabled
        if !enabled { await services.liveActivities.endRemoteActivities() }
        await services.delivery.sendHello()
    }

    func revokeLiveRegistrationIfNeeded() async -> Bool {
        guard settings.liveRegistrationNeedsRevocation else { return true }
        do {
            try await setLiveRegistration(enabled: false)
            return true
        } catch {
            errorMessage = strings[LiveNotificationRegistration.messageKey(error)]
            return false
        }
    }

    /// Deletes saved sites, language, guidance state and connection token (after confirmation in the UI).
    func deleteAllData() async {
        guard await revokeLiveRegistrationIfNeeded() else { return }
        demoBackgroundGrace.end()
        await services.notifications.cancelAllNigeyo()
        await services.liveActivities.endAll()
        await services.delivery.disconnect()
        try? await services.store.reset()
        try? await services.regionalAlerts.reset()
        PairingStore.delete()
        pairing = nil
        await services.diagnostics.clear()
        await services.registry.deleteCache()
        settings.eraseAll()
        onboardingCompleted = false
        homePath = []
        resumeAcknowledged = []
        await reloadLanguages()
    }

    func diagnosticsText() async -> String { await services.diagnostics.text() }

    // MARK: Destinations

    func savedDestination(place: PlaceContext, hazard: Hazard) -> SavedDestination? {
        settings.destination(DestinationSlot(place: place, hazard: hazard))
    }

    func site(id: String) async -> EvacuationSite? { await services.evacuation.site(id: id) }

    func nearest(latitude: Double, longitude: Double, hazard: Hazard, limit: Int) async throws -> [SiteDistance] {
        try await services.evacuation.nearest(latitude: latitude, longitude: longitude, hazard: hazard, limit: limit)
    }
}

@MainActor
final class UIApplicationProxy {
    static let shared = UIApplicationProxy()

    var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    var protectedDataAvailable: Bool { UIApplication.shared.isProtectedDataAvailable }
}
