import ActivityKit
import Foundation

/// Serializes start / update / end of the one Live Activity per GuideSession, always from the
/// saved session (spec §13.4). Starting only happens in the foreground; background calls update or end.
actor LiveActivityCoordinator {
    typealias State = NigeyoActivityAttributes.ContentState

    private struct Running: Sendable {
        var id: String
        var sessionId: String
        var state: State
    }

    private let store: SessionStoreProtocol
    private let log: @Sendable (String) async -> Void
    private var testActivityId: String?

    init(store: SessionStoreProtocol, log: @escaping @Sendable (String) async -> Void) {
        self.store = store
        self.log = log
    }

    nonisolated var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // ActivityKit objects are not Sendable: only ids and Sendable state cross isolation boundaries.
    private nonisolated static func running() -> [Running] {
        Activity<NigeyoActivityAttributes>.activities.map { Running(id: $0.id, sessionId: $0.attributes.sessionId, state: $0.content.state) }
    }

    private nonisolated static func end(ids: Set<String>) async {
        for activity in Activity<NigeyoActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func update(id: String, state: State) async {
        for activity in Activity<NigeyoActivityAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
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

    func sync(_ session: GuideSession?, foreground: Bool) async {
        let all = Self.running()
        let sid = session?.sessionId.uuidString
        // Activities of other (old) sessions never linger.
        let stale = Set(all.filter { $0.sessionId != sid && $0.id != testActivityId }.map(\.id))
        if !stale.isEmpty { await Self.end(ids: stale) }
        guard let session else { return }
        let existing = all.filter { $0.sessionId == sid }
        guard Self.wantsActivity(session) else {
            if !existing.isEmpty { await Self.end(ids: Set(existing.map(\.id))) }
            if !existing.isEmpty || session.liveActivityStatus == .active {
                try? await store.setLiveActivity(sessionId: session.sessionId, id: session.liveActivityId, status: .ended)
                await log("live activity ended for \(session.sessionId)")
            }
            return
        }
        let state = GuideContent.activityState(for: session)
        if let current = existing.first {
            if existing.count > 1 { await Self.end(ids: Set(existing.dropFirst().map(\.id))) }
            if current.state != state {
                await Self.update(id: current.id, state: state)
                await log("live activity updated rev\(session.stateRevision) \(session.phase.rawValue)")
            }
            if session.liveActivityId != current.id || session.liveActivityStatus != .active {
                try? await store.setLiveActivity(sessionId: session.sessionId, id: current.id, status: .active)
            }
            return
        }
        // Never re-create after the user evacuated, and never request from the background.
        guard foreground else { return }
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
