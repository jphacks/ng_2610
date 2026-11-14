import ActivityKit
import Foundation

/// Serializes start / update / end of the one Live Activity per GuideSession, always from the
/// saved session. Local requests originate in the foreground, and iOS handles scheduled or push starts.
actor LiveActivityCoordinator {
    typealias State = NigeyoActivityAttributes.ContentState

    private struct Running: Sendable {
        var id: String
        var sessionId: String
        var state: State
        var staleDate: Date?
        var isPending: Bool
        var remoteTraining: NigeyoActivityAttributes.RemoteTraining?
        var regionalAlert: String?
        var isLocalTsunami: Bool

        var isRemote: Bool { remoteTraining != nil || regionalAlert != nil }
    }

    private let store: SessionStore
    private let settings: SettingsStore
    private let registry: LanguageRegistry
    private var observingRemoteActivities = false
    private var observingLiveTokens: Set<String> = []
    private let regionalAlerts: RegionalAlertReceiver
    private let log: @Sendable (String) async -> Void
    private var testActivityId: String?
    private var adoptedRemoteIDs: Set<String> = []

    init(store: SessionStore, settings: SettingsStore, registry: LanguageRegistry, regionalAlerts: RegionalAlertReceiver,
         log: @escaping @Sendable (String) async -> Void) {
        self.store = store
        self.settings = settings
        self.registry = registry
        self.regionalAlerts = regionalAlerts
        self.log = log
    }

    nonisolated var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // ActivityKit objects are not Sendable: only ids and Sendable state cross isolation boundaries.
    private nonisolated static func running() -> [Running] {
        Activity<NigeyoActivityAttributes>.activities.map {
            Running(id: $0.id, sessionId: $0.attributes.sessionId, state: $0.content.state,
                    staleDate: $0.content.staleDate, isPending: $0.activityState == .pending, remoteTraining: $0.attributes.remoteTraining,
                    regionalAlert: $0.attributes.regionalAlert, isLocalTsunami: $0.attributes.localTsunami == true)
        }
    }

    private nonisolated static func end(ids: Set<String>) async {
        for activity in Activity<NigeyoActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func update(id: String, state: State, staleDate: Date?) async {
        for activity in Activity<NigeyoActivityAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        }
    }

    private nonisolated static func request(sessionId: String, state: State, staleDate: Date? = nil) throws -> String {
        try Activity.request(attributes: NigeyoActivityAttributes(sessionId: sessionId), content: ActivityContent(state: state, staleDate: staleDate), pushType: nil).id
    }

    /// Should this session have a visible Live Activity right now?
    static func wantsActivity(_ s: GuideSession, now: Date = Date()) -> Bool {
        guard s.isActive, s.evacuationDecision != .going else { return false }
        // In-app training: nothing on the lock screen until the drill notification fires.
        if s.mode == .training, let fireAt = s.notificationScheduledFor, fireAt > now { return false }
        return true
    }

    func observeRemoteActivities() {
        guard !observingRemoteActivities else { return }
        observingRemoteActivities = true
        Task {
            let updates = Activity<NigeyoActivityAttributes>.activityUpdates
            await reconcileActivities()
            for await _ in updates { await reconcileActivities() }
        }
    }

    private func reconcileActivities() async {
        await applyDueLocalTsunami()
        await adoptRemoteActivities()
    }

    func applyDueLocalTsunami() async {
        guard let session = try? await store.snapshot(), session.isActive,
              let pending = session.pendingLocalHazard, pending.fireAt <= Date() else { return }
        do {
            _ = try await store.applyHazardUpdate(sessionId: session.sessionId, commandId: pending.commandId,
                                                revision: session.lastHazardRevision + 1, summary: nil, receivedAt: Date())
            try await store.markHazardNotificationScheduled(commandId: pending.commandId, fireAt: pending.fireAt)
            await sync(try await store.snapshot(), foreground: false)
        } catch {
            await log("local tsunami drill could not update its guide")
        }
    }

    func adoptRemoteActivities(sessionId: UUID? = nil) async {
        await registry.loadIfNeeded()
        for activity in Self.running() {
            guard activity.isRemote,
                  let id = UUID(uuidString: activity.sessionId), sessionId == nil || sessionId == id else { continue }
            if let json = activity.regionalAlert {
                guard let command = try? JSONDecoder.nigeyo.decode(RegionalAlert.self, from: Data(json.utf8)),
                      command.commandId == id, settings.regionalSubscription.enabled else {
                    await Self.end(ids: [activity.id])
                    continue
                }
                if (try? await store.snapshot())?.sessionId != id {
                    _ = await regionalAlerts.receive(command, deliveredRemotely: true)
                }
                if let current = try? await store.snapshot(), current.sessionId == id {
                    await sync(current, foreground: false)
                    if current.isActive { observeLiveToken(activityID: activity.id, command: command) }
                } else {
                    await Self.end(ids: [activity.id])
                }
                continue
            }
            guard settings.regionalSubscription.enabled else {
                await Self.end(ids: [activity.id])
                continue
            }
            if let current = try? await store.snapshot(), current.sessionId == id {
                await sync(current, foreground: false)
                continue
            }
            guard let remote = activity.remoteTraining,
                  let notification = RemoteTrainingNotification(userInfo: [
                    RemoteTrainingNotification.typeKey: "remote-training",
                    "eventId": id.uuidString, "hazard": remote.hazard, "expiresAt": remote.expiresAt
                  ]), notification.expiresAt > Date() else {
                await Self.end(ids: [activity.id])
                continue
            }
            guard let language = await registry.snapshot(for: settings.language) else { continue }
            do {
                if settings.regionalSubscription.enabled,
                   let guide = try await store.openRemoteTraining(notification, language: language) {
                    await sync(guide, foreground: false)
                } else {
                    await Self.end(ids: [activity.id])
                }
            } catch {
                // Keep the initial card until its expiry if storage is temporarily unavailable.
                await log("remote training live activity could not save its guide")
            }
        }
    }

    func sync(_ session: GuideSession?, foreground: Bool) async {
        // Ignore snapshots queued before a notification tap or intent saved a newer state.
        guard (try? await store.snapshot()) == session else { return }
        let all = Self.running()
        adoptedRemoteIDs.formIntersection(all.map(\.id))
        let sid = session?.sessionId
        // A just-delivered push may still be waiting for adoption.
        let stale = Set(all.filter {
            (sid == nil || UUID(uuidString: $0.sessionId) != sid) && $0.id != testActivityId &&
                (!$0.isRemote || adoptedRemoteIDs.contains($0.id) || $0.staleDate == nil)
        }.map(\.id))
        if !stale.isEmpty { await Self.end(ids: stale) }
        guard let session else { return }
        let matching = all.filter { UUID(uuidString: $0.sessionId) == sid }
        let waitingForTsunami = session.isActive && session.pendingLocalHazard != nil && session.evacuationDecision != .going
        let existing = matching.filter { !waitingForTsunami || !$0.isLocalTsunami }
            .sorted {
                func priority(_ item: Running) -> Int {
                    if item.isLocalTsunami && session.hazard == .tsunami { return 0 }
                    if item.isRemote && item.id == session.liveActivityId { return 1 }
                    return item.isRemote ? 2 : 3
                }
                return (priority($0), $0.id) < (priority($1), $1.id)
            }
        if session.isActive, session.evacuationDecision != .going, existing.first?.isPending == true { return }
        guard Self.wantsActivity(session) else {
            if !existing.isEmpty { await Self.end(ids: Set(existing.map(\.id))) }
            if !existing.isEmpty || session.liveActivityStatus == .active {
                try? await store.setLiveActivity(sessionId: session.sessionId, id: session.liveActivityId, status: .ended)
                await log("live activity ended for \(session.sessionId)")
            }
            return
        }
        var state = GuideContent.activityState(for: session)
        if let current = existing.first {
            if current.isRemote { adoptedRemoteIDs.insert(current.id) }
            if existing.count > 1 { await Self.end(ids: Set(existing.dropFirst().map(\.id))) }
            let staleDate = current.regionalAlert != nil || waitingForTsunami ? current.staleDate : nil
            state.staleMessage = current.state.staleMessage
            if current.state != state || staleDate != current.staleDate {
                await Self.update(id: current.id, state: state, staleDate: staleDate)
                await log("live activity updated rev\(session.stateRevision) \(session.phase.rawValue)")
            }
            if session.liveActivityId != current.id || session.liveActivityStatus != .active {
                try? await store.setLiveActivity(sessionId: session.sessionId, id: current.id, status: .active)
            }
            return
        }
        // Never re-create after the user evacuated, and never request from the background.
        guard foreground else { return }
        // A remote warning's card can be ended by APNs while the app is suspended.
        // A saved activity ID means iOS has already presented this session.
        if (session.mode == .live || session.source == .remoteTraining), session.liveActivityId != nil { return }
        guard areActivitiesEnabled else {
            if session.liveActivityStatus != .unavailable { try? await store.setLiveActivity(sessionId: session.sessionId, id: nil, status: .unavailable) }
            return
        }
        do {
            let id = try Self.request(sessionId: session.sessionId.uuidString, state: state)
            try? await store.setLiveActivity(sessionId: session.sessionId, id: id, status: .active)
            await log("live activity started \(id)")
        } catch {
            try? await store.setLiveActivity(sessionId: session.sessionId, id: nil, status: .failed)
            await log("live activity request failed: \(error.localizedDescription)")
        }
    }

    private func observeLiveToken(activityID: String, command: RegionalAlert) {
        guard observingLiveTokens.insert(activityID).inserted else { return }
        Task {
            await Self.uploadLiveTokens(activityID: activityID, command: command, settings: settings)
            observingLiveTokens.remove(activityID)
        }
    }

    private nonisolated static func uploadLiveTokens(activityID: String, command: RegionalAlert,
                                                      settings: SettingsStore) async {
        guard let activity = Activity<NigeyoActivityAttributes>.activities.first(where: { $0.id == activityID }) else { return }
        let updates = activity.pushTokenUpdates
        if let token = activity.pushToken {
            await LiveNotificationRegistration.uploadUpdateToken(token, command: command, settings: settings)
        }
        for await token in updates {
            await LiveNotificationRegistration.uploadUpdateToken(token, command: command, settings: settings)
        }
    }

    func scheduleLocalTraining(_ session: GuideSession, at date: Date) async {
        guard areActivitiesEnabled, date > Date(),
              let current = try? await store.snapshot(), current.sessionId == session.sessionId, current.isActive,
              !Self.running().contains(where: { UUID(uuidString: $0.sessionId) == session.sessionId }) else { return }
        let notification = session.hazard == .tsunami
            ? GuideContent.tsunamiNotification(for: session, commandId: nil)
            : GuideContent.earthquakeNotification(for: session)
        do {
            let id = try Self.schedule(session, at: date, notification: notification, staleDate: current.pendingLocalHazard?.fireAt)
            try await store.setLiveActivity(sessionId: session.sessionId, id: id, status: .active)
        } catch {
            await log("local training live activity scheduling failed")
        }
    }

    private nonisolated static func schedule(_ session: GuideSession, at date: Date,
                                             notification: GuideContent.NotificationContent,
                                             staleDate: Date? = nil) throws -> String {
        let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: notification.title),
                                       body: LocalizedStringResource(stringLiteral: notification.body), sound: .default)
        return try Activity.request(
            attributes: NigeyoActivityAttributes(sessionId: session.sessionId.uuidString),
            content: ActivityContent(state: GuideContent.activityState(for: session), staleDate: staleDate),
            style: .standard, alertConfiguration: alert, start: date
        ).id
    }

    func endRemoteActivities() async {
        await Self.end(ids: Set(Self.running().filter(\.isRemote).map(\.id)))
    }

    func endAll() async {
        await Self.end(ids: Set(Self.running().map(\.id)))
        testActivityId = nil
    }

    /// Onboarding preview: a non-interactive protect card so the user can see the lock-screen layout.
    func startTest(state: State) async -> Bool {
        await endTest()
        guard areActivitiesEnabled else { return false }
        do {
            testActivityId = try Self.request(sessionId: "test-\(UUID().uuidString)", state: state, staleDate: Date().addingTimeInterval(600))
            return true
        } catch {
            await log("test live activity failed: \(error.localizedDescription)")
            return false
        }
    }

    func endTest() async {
        guard let id = testActivityId else { return }
        await Self.end(ids: [id])
        testActivityId = nil
    }
}
