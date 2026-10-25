import Foundation

/// Builds every user-facing text for a session from its frozen language snapshot, so the
/// notification, the app and the Live Activity always agree (spec §4.3, §12.3).
enum GuideContent {
    static let earthquakeTitle = "EARTHQUAKE_TEST"
    static let tsunamiTitle = "TSUNAMI_TEST"
    static let maxBodyLength = 200

    struct NotificationContent: Equatable, Sendable {
        var identifier: String
        var title: String
        var body: String
        var userInfo: [String: String]
    }

    static func earthquakeNotification(for s: GuideSession) -> NotificationContent {
        let t = Strings(snapshot: s.languageSnapshot)
        let body: String
        if let q = s.quake {
            body = t("notification.earthquake.body", ["time": t.dateTime(q.occurredAt), "place": q.hypocenterName ?? t["common.unknown"], "scale": t.scale(q.maxScale)])
        } else {
            body = t["notification.earthquake.bodyTraining"]
        }
        return NotificationContent(identifier: "nigeyo.\(s.sessionId.uuidString.lowercased())", title: earthquakeTitle, body: String(body.prefix(maxBodyLength)),
                                   userInfo: userInfo(s, commandId: nil, sourceEventId: s.quake?.sourceEventId))
    }

    /// commandId is nil when the tsunami starts the session (tsunami scenario); the identifier then matches start-guide's.
    static func tsunamiNotification(for s: GuideSession, commandId: UUID?) -> NotificationContent {
        let t = Strings(snapshot: s.languageSnapshot)
        let body: String
        if let ts = s.tsunami {
            body = t("notification.tsunami.body", ["time": t.dateTime(ts.issuedAt), "area": ts.area, "grade": gradeText(ts.grade, t)])
        } else {
            body = t["notification.tsunami.bodyTraining"]
        }
        let suffix = commandId.map { ".\($0.uuidString.lowercased())" } ?? ""
        return NotificationContent(identifier: "nigeyo.\(s.sessionId.uuidString.lowercased())\(suffix)", title: tsunamiTitle,
                                   body: String(body.prefix(maxBodyLength)), userInfo: userInfo(s, commandId: commandId, sourceEventId: s.tsunami?.sourceEventId))
    }

    static func gradeText(_ grade: String, _ t: Strings) -> String {
        t.table["guide.tsunami.grade.\(grade)"] ?? t["guide.tsunami.grade.Unknown"]
    }

    private static func userInfo(_ s: GuideSession, commandId: UUID?, sourceEventId: String?) -> [String: String] {
        var info = ["sessionId": s.sessionId.uuidString, "stateRevision": String(s.stateRevision), "hazard": s.hazard.rawValue, "mode": s.mode.rawValue]
        if let commandId { info["commandId"] = commandId.uuidString }
        if let sourceEventId { info["sourceEventId"] = sourceEventId }
        return info
    }

    static func activityState(for s: GuideSession, interactive: Bool = true) -> NigeyoActivityAttributes.ContentState {
        let t = Strings(snapshot: s.languageSnapshot)
        let badge = s.mode == .manual ? nil : t["training.badge"]
        let layout: NigeyoActivityAttributes.ContentState.Layout = s.hazard == .tsunami ? .tsunami : (s.phase == .protect ? .protect : .checks)
        let compact: String
        let state: NigeyoActivityAttributes.ContentState
        switch layout {
        case .protect:
            compact = t["liveActivity.compactProtect"]
            state = .init(layout: .protect, hazard: s.hazard.rawValue, phase: s.phase.rawValue, stateRevision: s.stateRevision, pictograms: ["protect-head"],
                          headline: t["guide.protect.short"], labels: [], buttonTitle: t["guide.shakingQuestion"], badge: badge, compactLabel: "", appName: t["app.name"], interactive: interactive)
        case .checks:
            compact = t["liveActivity.compactChecks"]
            state = .init(layout: .checks, hazard: s.hazard.rawValue, phase: s.phase.rawValue, stateRevision: s.stateRevision,
                          pictograms: ["check-surroundings", "check-fire", "secure-exit"], headline: t["guide.checks.title"],
                          labels: [t["guide.surroundings.title"], t["guide.fire.title"], t["guide.exit.title"]], buttonTitle: t["guide.unsafeButton"],
                          badge: badge, compactLabel: "", appName: t["app.name"], interactive: interactive)
        case .tsunami:
            compact = t["liveActivity.compactTsunami"]
            state = .init(layout: .tsunami, hazard: s.hazard.rawValue, phase: s.phase.rawValue, stateRevision: s.stateRevision, pictograms: ["tsunami-evacuate"],
                          headline: t["guide.tsunami.short"], labels: [], buttonTitle: t["liveActivity.checkPlaces"], badge: badge, compactLabel: "", appName: t["app.name"], interactive: interactive)
        }
        var result = state
        result.compactLabel = [badge, compact].compactMap { $0 }.joined(separator: "・")
        return result
    }

    /// Attributes + content must stay within ActivityKit's 4KB budget.
    static func encodedActivitySize(sessionId: UUID, state: NigeyoActivityAttributes.ContentState) -> Int {
        let attrs = (try? JSONEncoder().encode(NigeyoActivityAttributes(sessionId: sessionId.uuidString)).count) ?? 0
        let content = (try? JSONEncoder().encode(state).count) ?? 0
        return attrs + content
    }
}
