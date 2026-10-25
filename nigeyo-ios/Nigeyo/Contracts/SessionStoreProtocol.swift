import Foundation

enum HazardUpdateResult: Equatable, Sendable {
    case applied(GuideSession)
    case duplicate(GuideSession)
    case stale(GuideSession)
}

/// The single source of truth for guidance state (spec §9.1). Delivery, UI, notifications and
/// Live Activity all go through this; none of them keeps a parallel copy.
protocol SessionStoreProtocol: Sendable {
    func prepare(_ session: GuideSession, receivedAt: Date) async throws
    func markNotificationScheduled(sessionId: UUID, fireAt: Date) async throws
    func markNotificationFailed(runId: UUID, errorCode: DeliveryErrorCode) async throws
    func snapshot() async throws -> GuideSession?
    @discardableResult
    func transition(sessionId: UUID, expectedRevision: Int, to phase: GuidePhase) async throws -> GuideSession
    func complete(sessionId: UUID) async throws
    func receipt(for runId: UUID) async throws -> NotificationReceipt?
    func applyHazardUpdate(sessionId: UUID, commandId: UUID, revision: Int, summary: TsunamiSummary?, receivedAt: Date) async throws -> HazardUpdateResult
    func markHazardNotificationScheduled(commandId: UUID, fireAt: Date) async throws
    @discardableResult
    func confirmEvacuation(sessionId: UUID, expectedRevision: Int) async throws -> GuideSession
    func selectPlace(sessionId: UUID, context: PlaceContext, candidateIds: [String]) async throws
    func selectDestination(sessionId: UUID, destinationId: String) async throws
    func setLiveActivity(sessionId: UUID, id: String?, status: LiveActivityStatus) async throws
    func schedulePendingHazard(sessionId: UUID, pending: PendingLocalHazard?) async throws
    func reset() async throws
    func changes() async -> AsyncStream<GuideSession?>
}
