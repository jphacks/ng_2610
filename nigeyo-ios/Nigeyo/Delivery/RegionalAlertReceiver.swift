import Foundation

struct RegionalAlert: Codable, Sendable {
    struct Match: Codable, Sendable {
        var slot: String
        var siteId: String
        var region: String
    }
    var schemaVersion: Int
    var type: String
    var commandId: UUID
    var hazard: Hazard
    var sourceEventId: String
    var issuedAt: Date
    var status: String
    var grade: String?
    var notify: Bool
    var matches: [Match]
    var tsunamiAreas: [String: String]?
    var mode: String
    var sentAt: Date
    var expiresAt: Date
}

struct RegionalAck: Encodable, Sendable {
    let schemaVersion = WireConstants.schemaVersion
    let type = "regional-ack"
    var commandId: UUID
    let status = "stored"
}

/// Separate from explicit demo runs: a real alert never uses fixture fallback or drill titles.
actor RegionalAlertReceiver {
    struct State: Codable {
        var receipts: [UUID] = []
        var alerts: [String: RegionalAlert] = [:]
        var notificationPrepared: [UUID: GuideContent.NotificationContentRecord] = [:]
    }
    private let settings: SettingsStore
    private let notifications: NotificationScheduling
    private let registry: LanguageRegistry
    private let store: SessionStoreProtocol
    private let persistence: SessionPersistence
    private var state: State
    private var pendingTask: Task<RegionalAck?, Never>?

    init(settings: SettingsStore, notifications: NotificationScheduling, registry: LanguageRegistry, store: SessionStoreProtocol,
         persistence: SessionPersistence = FileSessionPersistence(url: FileSessionPersistence.default().url.deletingLastPathComponent().appendingPathComponent("regional-alert-state.json"))) {
        self.settings = settings
        self.notifications = notifications
        self.registry = registry
        self.store = store
        self.persistence = persistence
        if let data = try? persistence.load(), let saved = try? JSONDecoder.nigeyo.decode(State.self, from: data) { state = saved }
        else { state = State() }
    }

    func latest() -> [String: RegionalAlert] { state.alerts }
    func reset() throws { try persistence.delete(); state = State() }
    private func commit(_ next: State) throws { try persistence.save(JSONEncoder.nigeyo.encode(next)); state = next }

    func receive(_ cmd: RegionalAlert, now: Date = Date()) async -> RegionalAck? {
        // Actors may reenter at awaits. Serialize whole commands so a late warning cannot
        // resume after a cancellation and restore the obsolete guidance.
        let previous = pendingTask
        let task = Task { [self] in
            _ = await previous?.value
            return await process(cmd, now: now)
        }
        pendingTask = task
        return await task.value
    }

    private func process(_ cmd: RegionalAlert, now: Date) async -> RegionalAck? {
        guard cmd.schemaVersion == WireConstants.schemaVersion, cmd.type == "regional-alert", cmd.mode == "live",
              cmd.expiresAt >= now, cmd.sentAt.timeIntervalSince(now) < 5,
              ["active", "cancelled", "unknown"].contains(cmd.status), !cmd.matches.isEmpty else { return nil }
        let subscription = settings.regionalSubscription
        guard subscription.enabled, cmd.matches.allSatisfy({ m in
            subscription.targets.contains { t in t.slot == m.slot && t.siteId == m.siteId &&
                (cmd.hazard == .earthquake ? t.earthquakeArea.name == m.region : t.tsunamiAreas.contains(m.region)) }
        }) else { return nil }
        if state.receipts.contains(cmd.commandId) { return RegionalAck(commandId: cmd.commandId) }
        let key = cmd.hazard.rawValue
        if let last = state.alerts[key], last.issuedAt > cmd.issuedAt { return RegionalAck(commandId: cmd.commandId) }
        guard let snapshot = await registry.snapshot(for: settings.language) else { return nil }
        let t = Strings(snapshot: snapshot)
        let locations = Array(Set(cmd.matches.map { m in
            "\(t[m.slot.hasPrefix("home.") ? "onboarding.places.home" : "onboarding.places.university"]) · \(m.region)"
        })).sorted().joined(separator: ", ")
        let identifier = "nigeyo.regional.\(cmd.commandId.uuidString.lowercased())"
        let previousAlert = state.alerts[key]
        // Explicit cancellation or a tsunami downgrade must not leave obsolete warning guidance visible.
        // Unknown/disconnected states keep the last protective guidance; neither implies all-clear.
        if cmd.status == "cancelled" || cmd.hazard == .tsunami && cmd.status == "active" && cmd.grade == "Watch" {
            if let current = try? await store.snapshot(), current.mode == .live, current.isActive,
               current.hazard == cmd.hazard,
               cmd.hazard == .tsunami || previousAlert?.sourceEventId == cmd.sourceEventId {
                do { try await store.complete(sessionId: current.sessionId) } catch { return nil }
            }
            if let previousAlert {
                await notifications.cancel(identifiers: ["nigeyo.regional.\(previousAlert.commandId.uuidString.lowercased())"])
            }
        }
        var next = state
        if !(cmd.hazard == .earthquake && cmd.status == "cancelled" && previousAlert?.status == "active" && previousAlert?.sourceEventId != cmd.sourceEventId) {
            next.alerts[key] = cmd
        }
        // Cancellation/unknown changes stored status only; it never announces safety or opens a new guide.
        if cmd.notify && cmd.status == "active" {
            var info: [String: String] = ["regionalAlert": cmd.commandId.uuidString]
            let opensGuide = cmd.hazard == .earthquake || ["Warning", "MajorWarning"].contains(cmd.grade ?? "")
            if opensGuide {
                if let current = try? await store.snapshot(), current.isActive {
                    if current.sessionId == cmd.commandId || current.mode == .live && current.hazard == .tsunami {
                        info["sessionId"] = current.sessionId.uuidString
                    } else {
                        try? await store.complete(sessionId: current.sessionId)
                    }
                }
                if info["sessionId"] == nil {
                    var session = GuideSession.new(id: cmd.commandId, mode: .live, source: .liveAPI,
                                                  scenario: cmd.hazard == .tsunami ? .tsunami : .earthquake, quake: nil,
                                                  snapshot: snapshot, hazard: cmd.hazard, now: now)
                    if cmd.hazard == .tsunami {
                        session.tsunami = TsunamiSummary(sourceEventId: cmd.sourceEventId, code: 552, issuedAt: ISO8601.string(cmd.issuedAt),
                                                        cancelled: false, area: cmd.matches.map(\.region).sorted().joined(separator: ", "), grade: cmd.grade ?? "Unknown")
                    }
                    do { try await store.prepare(session, receivedAt: now) } catch { return nil }
                    info["sessionId"] = session.sessionId.uuidString
                }
            }
            let actionKey = cmd.hazard == .earthquake ? "regions.alert.earthquake" : "regions.alert.\(cmd.grade ?? "Unknown")"
            let body = "\(t["regions.alert.registered"]) \(locations)\n\(t[actionKey])"
            let content = GuideContent.NotificationContentRecord(identifier: identifier,
                title: cmd.hazard == .earthquake ? "EARTHQUAKE_ALERT" : cmd.grade == "Watch" ? "TSUNAMI_WATCH" : "TSUNAMI_ALERT",
                body: body, userInfo: info)
            next.notificationPrepared[cmd.commandId] = content
        }
        do { try commit(next) } catch { return nil }
        if let content = state.notificationPrepared[cmd.commandId] {
            guard await notifications.authorization() == .authorized else { return nil }
            // Reconcile crash after scheduling using the deterministic identifier.
            if !(await notifications.exists(identifier: identifier)) {
                do { try await notifications.schedule(content.content, after: 1) } catch { return nil }
            }
        }
        next = state
        next.receipts.append(cmd.commandId)
        next.receipts = Array(next.receipts.suffix(200))
        next.notificationPrepared[cmd.commandId] = nil
        do { try commit(next) } catch { return nil }
        return RegionalAck(commandId: cmd.commandId)
    }
}

extension GuideContent {
    struct NotificationContentRecord: Codable, Sendable {
        var identifier: String
        var title: String
        var body: String
        var userInfo: [String: String]
        var content: NotificationContent { .init(identifier: identifier, title: title, body: body, userInfo: userInfo) }
    }
}
