import Foundation

struct DeviceState: Sendable {
    var appState: String
    var protectedDataAvailable: Bool
}

/// Receives normalized server commands and enforces the processing order of spec §9.2:
/// validate → dedupe by runId → save atomically → schedule notification → record → ACK.
/// A notification is never scheduled for a command that was not saved first.
actor CommandProcessor {
    private let store: SessionStoreProtocol
    private let notifications: NotificationScheduling
    private let registry: LanguageRegistry
    private let preferredLanguage: @Sendable () async -> LanguageID
    private let deviceState: @Sendable () async -> DeviceState
    private let log: @Sendable (String) async -> Void
    private let now: @Sendable () -> Date
    static let notificationDelay: TimeInterval = 1

    init(store: SessionStoreProtocol, notifications: NotificationScheduling, registry: LanguageRegistry,
         preferredLanguage: @escaping @Sendable () async -> LanguageID, deviceState: @escaping @Sendable () async -> DeviceState,
         log: @escaping @Sendable (String) async -> Void = { _ in }, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.notifications = notifications
        self.registry = registry
        self.preferredLanguage = preferredLanguage
        self.deviceState = deviceState
        self.log = log
        self.now = now
    }

    func handle(_ message: IncomingMessage) async -> NotificationAck? {
        switch message {
        case .startGuide(let cmd): return await handleStart(cmd)
        case .hazardUpdate(let cmd): return await handleHazard(cmd)
        case .serverError(let code):
            await log("server error: \(code)")
            return nil
        case .invalid(let code, let runId):
            await log("rejected message: \(code.rawValue)")
            return await ack(runId: runId, status: .rejected, error: code, receivedAt: now())
        }
    }

    private func ack(runId: UUID? = nil, commandId: UUID? = nil, sessionId: UUID? = nil, hazardRevision: Int? = nil, stateRevision: Int? = nil,
                     status: NotificationAck.Status, error: DeliveryErrorCode? = nil, receivedAt: Date, scheduledAt: Date? = nil) async -> NotificationAck {
        let device = await deviceState()
        return NotificationAck(runId: runId, commandId: commandId, sessionId: sessionId, hazardRevision: hazardRevision, stateRevision: stateRevision,
                               status: status, errorCode: error, receivedAt: receivedAt, scheduledAt: scheduledAt,
                               appState: device.appState, protectedDataAvailable: device.protectedDataAvailable)
    }

    private func validateEnvelope(sentAt: Date, expiresAt: Date, receivedAt: Date) -> DeliveryErrorCode? {
        if sentAt.timeIntervalSince(receivedAt) >= WireConstants.clockSkewTolerance { return .clockSkew }
        if receivedAt > expiresAt { return .expiredCommand }
        return nil
    }

    private func validateLanguage(_ id: LanguageID, version: Int) async -> DeliveryErrorCode? {
        guard let pkg = await registry.package(for: id), pkg.languageId == id else { return .languagePackageMissing }
        if pkg.packageVersion != version { return .languageMismatch }
        if await preferredLanguage() != id { return .languageMismatch }
        return nil
    }

    // MARK: start-guide

    func handleStart(_ cmd: StartGuideCommand, receivedAt: Date? = nil) async -> NotificationAck {
        let receivedAt = receivedAt ?? now()
        func reject(_ code: DeliveryErrorCode, _ status: NotificationAck.Status = .rejected) async -> NotificationAck {
            await log("start \(cmd.runId) \(status.rawValue): \(code.rawValue)")
            return await ack(runId: cmd.runId, status: status, error: code, receivedAt: receivedAt)
        }

        // 1. Contract validation.
        guard cmd.type == "start-guide", cmd.mode == .demo, cmd.hazard == (cmd.scenario == .tsunami ? .tsunami : .earthquake), cmd.stateRevision == 1,
              [.liveAPI, .lastGood, .fixture].contains(cmd.source), let quake = cmd.quake, quake.isValid else { return await reject(.invalidPayload) }
        if let code = validateEnvelope(sentAt: cmd.sentAt, expiresAt: cmd.expiresAt, receivedAt: receivedAt) { return await reject(code) }

        // 2. Dedupe by runId (not by the quake id: the same quake can be replayed with a new runId).
        let identifier = "nigeyo.\(cmd.runId.uuidString.lowercased())"
        if let receipt = try? await store.receipt(for: cmd.runId) {
            switch receipt.state {
            case .scheduled:
                return await ack(runId: cmd.runId, stateRevision: receipt.stateRevision, status: .duplicate, receivedAt: receivedAt, scheduledAt: receipt.fireAt)
            case .prepared:
                // Saved but the app died before scheduling: reconcile instead of blindly re-notifying.
                if await notifications.exists(identifier: identifier) {
                    let fireAt = receipt.fireAt ?? receivedAt
                    try? await store.markNotificationScheduled(sessionId: cmd.runId, fireAt: fireAt)
                    return await ack(runId: cmd.runId, status: .duplicate, receivedAt: receivedAt, scheduledAt: fireAt)
                }
                if let session = try? await store.snapshot(), session.sessionId == cmd.runId {
                    return await schedule(session: session, receivedAt: receivedAt)
                }
            case .failed:
                break
            }
        }

        if let code = await validateLanguage(cmd.language, version: cmd.languagePackageVersion) { return await reject(code) }
        guard await notifications.authorization() == .authorized else { return await reject(.notificationsDenied) }
        guard let snapshot = await registry.snapshot(for: cmd.language) else { return await reject(.languagePackageMissing) }

        // A new demo run replaces any unfinished session so earthquake/tsunami demos can be repeated back to back.
        if let current = try? await store.snapshot(), current.isActive, current.sessionId != cmd.runId {
            await notifications.cancelAllNigeyo()
            try? await store.complete(sessionId: current.sessionId)
            await log("start \(cmd.runId) replaces \(current.sessionId)")
        }

        // 3. Save before notifying.
        let session = GuideSession.new(id: cmd.runId, mode: cmd.mode, source: cmd.source, scenario: cmd.scenario, quake: quake, snapshot: snapshot, hazard: cmd.hazard, now: receivedAt)
        do {
            try await store.prepare(session, receivedAt: receivedAt)
        } catch SessionStoreError.sessionBusy {
            return await reject(.sessionBusy)
        } catch {
            return await reject(.storageFailed, .failed)
        }
        return await schedule(session: session, receivedAt: receivedAt)
    }

    private func schedule(session: GuideSession, receivedAt: Date) async -> NotificationAck {
        // 4. Schedule. 5. Record. 6. ACK.
        let content = session.hazard == .tsunami ? GuideContent.tsunamiNotification(for: session, commandId: nil) : GuideContent.earthquakeNotification(for: session)
        do {
            try await notifications.schedule(content, after: Self.notificationDelay)
        } catch {
            try? await store.markNotificationFailed(runId: session.sessionId, errorCode: .notificationFailed)
            await log("start \(session.sessionId) notification failed")
            return await ack(runId: session.sessionId, status: .failed, error: .notificationFailed, receivedAt: receivedAt)
        }
        let fireAt = now().addingTimeInterval(Self.notificationDelay)
        try? await store.markNotificationScheduled(sessionId: session.sessionId, fireAt: fireAt)
        await log("start \(session.sessionId) scheduled (source \(session.source.rawValue))")
        return await ack(runId: session.sessionId, stateRevision: session.stateRevision, status: .scheduled, receivedAt: receivedAt, scheduledAt: fireAt)
    }

    // MARK: hazard-update (tsunami for the same session)

    func handleHazard(_ cmd: HazardUpdateCommand, receivedAt: Date? = nil) async -> NotificationAck {
        let receivedAt = receivedAt ?? now()
        func reply(_ status: NotificationAck.Status, _ code: DeliveryErrorCode? = nil, stateRevision: Int? = nil, scheduledAt: Date? = nil) async -> NotificationAck {
            await log("hazard \(cmd.commandId) rev\(cmd.hazardRevision) \(status.rawValue)\(code.map { ": \($0.rawValue)" } ?? "")")
            return await ack(commandId: cmd.commandId, sessionId: cmd.sessionId, hazardRevision: cmd.hazardRevision, stateRevision: stateRevision,
                             status: status, error: code, receivedAt: receivedAt, scheduledAt: scheduledAt)
        }

        guard cmd.type == "hazard-update", cmd.hazard == .tsunami, cmd.hazardRevision >= 1, cmd.mode == .demo,
              [.liveAPI, .lastGood, .fixture, .local].contains(cmd.source) else { return await reply(.rejected, .invalidPayload) }
        // A synthetic drill carries no source event; API-derived data must be complete.
        if cmd.source == .local, cmd.tsunami != nil { return await reply(.rejected, .invalidPayload) }
        if cmd.source != .local, cmd.tsunami?.isValid != true { return await reply(.rejected, .invalidPayload) }
        if cmd.tsunami?.cancelled == true { return await reply(.rejected, .invalidPayload) }
        if let code = validateEnvelope(sentAt: cmd.sentAt, expiresAt: cmd.expiresAt, receivedAt: receivedAt) { return await reply(.rejected, code) }

        guard let current = try? await store.snapshot(), current.sessionId == cmd.sessionId, current.isActive else {
            return await reply(.rejected, .invalidPayload)
        }
        if current.language != cmd.language || current.languagePackageVersion != cmd.languagePackageVersion { return await reply(.rejected, .languageMismatch) }

        let result: HazardUpdateResult
        do {
            result = try await store.applyHazardUpdate(sessionId: cmd.sessionId, commandId: cmd.commandId, revision: cmd.hazardRevision, summary: cmd.tsunami, receivedAt: receivedAt)
        } catch {
            return await reply(.failed, .storageFailed)
        }
        switch result {
        case .duplicate(let s):
            let receipt = try? await store.receipt(for: cmd.commandId)
            return await reply(.duplicate, stateRevision: receipt?.stateRevision ?? s.stateRevision, scheduledAt: receipt?.fireAt)
        case .stale(let s):
            return await reply(.rejected, .staleRevision, stateRevision: s.stateRevision)
        case .applied(let s):
            do {
                try await notifications.schedule(GuideContent.tsunamiNotification(for: s, commandId: cmd.commandId), after: Self.notificationDelay)
            } catch {
                try? await store.markNotificationFailed(runId: cmd.commandId, errorCode: .notificationFailed)
                return await reply(.failed, .notificationFailed, stateRevision: s.stateRevision)
            }
            let fireAt = now().addingTimeInterval(Self.notificationDelay)
            try? await store.markHazardNotificationScheduled(commandId: cmd.commandId, fireAt: fireAt)
            return await reply(.scheduled, stateRevision: s.stateRevision, scheduledAt: fireAt)
        }
    }
}
