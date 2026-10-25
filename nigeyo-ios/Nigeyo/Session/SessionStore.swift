import Foundation

protocol SessionPersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

/// Application Support/session-state.json, written atomically and readable while locked
/// after first unlock (spec §9.3).
struct FileSessionPersistence: SessionPersistence {
    let url: URL

    static func `default`() -> FileSessionPersistence {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return FileSessionPersistence(url: dir.appendingPathComponent("session-state.json"))
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

actor SessionStore: SessionStoreProtocol {
    struct PersistedState: Codable, Equatable {
        var session: GuideSession?
        var receipts: [NotificationReceipt] = []
    }

    static let maxReceipts = 100

    private let persistence: SessionPersistence
    private let now: @Sendable () -> Date
    private var state: PersistedState
    private var continuations: [UUID: AsyncStream<GuideSession?>.Continuation] = [:]

    init(persistence: SessionPersistence = FileSessionPersistence.default(), now: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        if let data = try? persistence.load(), let decoded = try? JSONDecoder.nigeyo.decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
    }

    // MARK: Reading

    func snapshot() throws -> GuideSession? { state.session }

    func receipt(for runId: UUID) throws -> NotificationReceipt? {
        state.receipts.last { $0.runId == runId }
    }

    func changes() -> AsyncStream<GuideSession?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GuideSession?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state.session)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    // MARK: Writing — every mutation persists first, then notifies observers.

    private func commit(_ next: PersistedState) throws {
        var trimmed = next
        if trimmed.receipts.count > Self.maxReceipts { trimmed.receipts.removeFirst(trimmed.receipts.count - Self.maxReceipts) }
        do {
            try persistence.save(try JSONEncoder.nigeyo.encode(trimmed))
        } catch {
            throw SessionStoreError.storageFailed
        }
        let changed = trimmed.session != state.session
        state = trimmed
        if changed { for c in continuations.values { c.yield(state.session) } }
    }

    private func mutate(_ sessionId: UUID, _ body: (inout GuideSession) throws -> Void) throws -> GuideSession {
        guard var session = state.session, session.sessionId == sessionId else { throw SessionStoreError.sessionNotFound }
        try body(&session)
        session.stateRevision += 1
        session.updatedAt = now()
        var next = state
        next.session = session
        try commit(next)
        return session
    }

    /// Atomic check-and-save. A different active session is never silently replaced.
    func prepare(_ session: GuideSession, receivedAt: Date) throws {
        if let current = state.session, current.isActive, current.sessionId != session.sessionId {
            throw SessionStoreError.sessionBusy
        }
        var next = state
        next.session = session
        next.receipts.append(NotificationReceipt(runId: session.sessionId, state: .prepared, receivedAt: receivedAt, fireAt: nil, errorCode: nil, stateRevision: session.stateRevision))
        try commit(next)
    }

    func markNotificationScheduled(sessionId: UUID, fireAt: Date) throws {
        var next = state
        if var s = next.session, s.sessionId == sessionId {
            s.notificationScheduledFor = fireAt
            next.session = s
        }
        if let i = next.receipts.lastIndex(where: { $0.runId == sessionId }) {
            next.receipts[i].state = .scheduled
            next.receipts[i].fireAt = fireAt
        }
        try commit(next)
    }

    func markHazardNotificationScheduled(commandId: UUID, fireAt: Date) throws {
        var next = state
        if let i = next.receipts.lastIndex(where: { $0.runId == commandId }) {
            next.receipts[i].state = .scheduled
            next.receipts[i].fireAt = fireAt
        }
        try commit(next)
    }

    func markNotificationFailed(runId: UUID, errorCode: DeliveryErrorCode) throws {
        var next = state
        if let i = next.receipts.lastIndex(where: { $0.runId == runId }) {
            next.receipts[i].state = .failed
            next.receipts[i].errorCode = errorCode
        } else {
            next.receipts.append(NotificationReceipt(runId: runId, state: .failed, receivedAt: now(), fireAt: nil, errorCode: errorCode, stateRevision: nil))
        }
        try commit(next)
    }

    static func isAllowed(from: GuidePhase, to: GuidePhase, hazard: Hazard) -> Bool {
        switch (from, to) {
        case (.protect, .safetyChecks): return hazard == .earthquake
        case (.safetyChecks, .choosePlace), (.tsunamiEvacuate, .choosePlace), (.protect, .choosePlace): return true
        case (.choosePlace, .safetyChecks): return hazard == .earthquake
        case (.choosePlace, .tsunamiEvacuate): return hazard == .tsunami
        case (.showDestination, .choosePlace): return true
        default: return false
        }
    }

    /// Idempotent for repeated taps: an old revision that already reached `phase` succeeds as a no-op.
    /// A late earthquake confirmation after a tsunami update is rejected (never rolls tsunami back).
    @discardableResult
    func transition(sessionId: UUID, expectedRevision: Int, to phase: GuidePhase) throws -> GuideSession {
        guard let current = state.session, current.sessionId == sessionId, current.isActive else { throw SessionStoreError.sessionNotFound }
        if current.phase == phase { return current }
        guard current.stateRevision == expectedRevision else { throw SessionStoreError.staleRevision }
        guard Self.isAllowed(from: current.phase, to: phase, hazard: current.hazard) else {
            throw current.hazard == .tsunami && [.protect, .safetyChecks].contains(phase) ? SessionStoreError.staleRevision : SessionStoreError.invalidTransition
        }
        return try mutate(sessionId) { s in
            s.phase = phase
            s.selectedDestinationId = nil
            if phase != .choosePlace {
                s.selectedPlaceContext = nil
                s.candidateDestinationIds = []
            }
        }
    }

    func selectPlace(sessionId: UUID, context: PlaceContext, candidateIds: [String]) throws {
        _ = try mutate(sessionId) { s in
            guard s.isActive else { throw SessionStoreError.invalidTransition }
            s.phase = .choosePlace
            s.selectedPlaceContext = context
            s.candidateDestinationIds = candidateIds
            s.selectedDestinationId = nil
        }
    }

    /// Facility id and phase are saved together so a relaunch can re-show the destination.
    func selectDestination(sessionId: UUID, destinationId: String) throws {
        _ = try mutate(sessionId) { s in
            guard s.isActive else { throw SessionStoreError.invalidTransition }
            s.selectedDestinationId = destinationId
            s.phase = .showDestination
        }
    }

    @discardableResult
    func confirmEvacuation(sessionId: UUID, expectedRevision: Int) throws -> GuideSession {
        guard let current = state.session, current.sessionId == sessionId, current.isActive else { throw SessionStoreError.sessionNotFound }
        if current.evacuationDecision == .going { return current }
        guard current.stateRevision == expectedRevision else { throw SessionStoreError.staleRevision }
        guard current.phase == .showDestination, current.selectedDestinationId != nil else { throw SessionStoreError.invalidTransition }
        return try mutate(sessionId) { $0.evacuationDecision = .going }
    }

    /// Tsunami for the same session wins over every earthquake phase (spec §8.4).
    func applyHazardUpdate(sessionId: UUID, commandId: UUID, revision: Int, summary: TsunamiSummary?, receivedAt: Date) throws -> HazardUpdateResult {
        guard let current = state.session, current.sessionId == sessionId, current.isActive else { throw SessionStoreError.sessionNotFound }
        if state.receipts.contains(where: { $0.runId == commandId && $0.state != .failed }) { return .duplicate(current) }
        guard revision > current.lastHazardRevision else { return .stale(current) }
        var session = current
        session.hazard = .tsunami
        session.phase = .tsunamiEvacuate
        session.lastHazardRevision = revision
        session.tsunami = summary
        session.lastTsunamiEventId = summary?.sourceEventId
        session.selectedPlaceContext = nil
        session.candidateDestinationIds = []
        session.selectedDestinationId = nil
        // An earthquake destination is not a tsunami destination: the user chooses again.
        session.evacuationDecision = .undecided
        session.pendingLocalHazard = nil
        session.stateRevision += 1
        session.updatedAt = now()
        var next = state
        next.session = session
        next.receipts.append(NotificationReceipt(runId: commandId, state: .prepared, receivedAt: receivedAt, fireAt: nil, errorCode: nil, stateRevision: session.stateRevision))
        try commit(next)
        return .applied(session)
    }

    func setLiveActivity(sessionId: UUID, id: String?, status: LiveActivityStatus) throws {
        guard let s = state.session, s.sessionId == sessionId, s.liveActivityId != id || s.liveActivityStatus != status else { return }
        var next = state
        next.session?.liveActivityId = id
        next.session?.liveActivityStatus = status
        try commit(next) // bookkeeping only; does not bump stateRevision
    }

    func schedulePendingHazard(sessionId: UUID, pending: PendingLocalHazard?) throws {
        guard let s = state.session, s.sessionId == sessionId else { throw SessionStoreError.sessionNotFound }
        var next = state
        next.session?.pendingLocalHazard = pending
        try commit(next)
    }

    func complete(sessionId: UUID) throws {
        guard let s = state.session, s.sessionId == sessionId else { return }
        if !s.isActive { return }
        _ = try mutate(sessionId) { s in
            s.phase = .completed
            s.completedAt = now()
            s.pendingLocalHazard = nil
        }
    }

    func reset() throws {
        do {
            try persistence.delete()
        } catch {
            throw SessionStoreError.storageFailed
        }
        state = PersistedState()
        for c in continuations.values { c.yield(nil) }
    }
}
