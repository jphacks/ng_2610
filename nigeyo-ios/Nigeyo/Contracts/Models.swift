import Foundation

// MARK: - Contract v2 domain model (spec §4). Shared by delivery, session and UI; no UI-only copies.

/// BCP 47 language tag. Available languages come from LanguageRegistry, never from an enum.
struct LanguageID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ value: String) { self.rawValue = value }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    var description: String { rawValue }
    static let english = LanguageID("en")

    var isWellFormed: Bool {
        rawValue.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }
}

enum SessionMode: String, Codable, Sendable { case demo, training, manual }

enum DemoSource: String, Codable, Sendable {
    case liveAPI = "live-api", lastGood = "last-good", fixture, local, manual
}

enum Scenario: String, Codable, Sendable { case earthquake, earthquakeTsunami = "earthquake-tsunami", tsunami }

enum GuidePhase: String, Codable, Sendable {
    case protect
    case safetyChecks = "safety-checks"
    case tsunamiEvacuate = "tsunami-evacuate"
    case choosePlace = "choose-place"
    case showDestination = "show-destination"
    case completed
}

enum Hazard: String, Codable, Sendable { case earthquake, tsunami }

enum PlaceContext: String, Codable, Sendable, CaseIterable { case home, university, other }

enum EvacuationDecision: String, Codable, Sendable { case undecided, going }

enum LiveActivityStatus: String, Codable, Sendable { case none, active, ended, unavailable, failed }

struct QuakeSummary: Codable, Equatable, Sendable {
    var sourceEventId: String
    var code: Int
    /// JST ISO 8601 strings as received; kept verbatim so the original time is never rewritten.
    var occurredAt: String
    var issuedAt: String
    var hypocenterName: String?
    var magnitude: Double?
    var maxScale: Int?

    static let validScales: Set<Int> = [10, 20, 30, 40, 45, 50, 55, 60, 70]

    var isValid: Bool {
        code == 551 && !sourceEventId.isEmpty && ISO8601.parse(occurredAt) != nil && ISO8601.parse(issuedAt) != nil
            && (maxScale.map { Self.validScales.contains($0) } ?? true) && (magnitude.map { $0 >= 0 } ?? true)
    }
}

struct TsunamiSummary: Codable, Equatable, Sendable {
    var sourceEventId: String
    var code: Int
    var issuedAt: String
    var cancelled: Bool
    var area: String
    var grade: String

    var isValid: Bool { code == 552 && !sourceEventId.isEmpty && ISO8601.parse(issuedAt) != nil && !area.isEmpty }
}

/// Strings frozen at session start so notification, app and Live Activity never mix languages.
struct LanguageSnapshot: Codable, Equatable, Sendable {
    var languageId: LanguageID
    var packageVersion: Int
    var strings: [String: String]
    var direction: String?
}

/// A locally scheduled tsunami drill event (in-app training with the tsunami scenario).
struct PendingLocalHazard: Codable, Equatable, Sendable {
    var commandId: UUID
    var fireAt: Date
}

struct GuideSession: Codable, Equatable, Sendable {
    var sessionId: UUID
    var mode: SessionMode
    var source: DemoSource
    var language: LanguageID
    var scenario: Scenario
    var quake: QuakeSummary?
    var phase: GuidePhase
    var hazard: Hazard
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var selectedPlaceContext: PlaceContext?
    var candidateDestinationIds: [String]
    var selectedDestinationId: String?
    var notificationScheduledFor: Date?
    var languagePackageVersion: Int
    var languageSnapshot: LanguageSnapshot
    var stateRevision: Int
    var lastHazardRevision: Int
    var lastTsunamiEventId: String?
    var tsunami: TsunamiSummary?
    var evacuationDecision: EvacuationDecision
    var liveActivityId: String?
    var liveActivityStatus: LiveActivityStatus
    var pendingLocalHazard: PendingLocalHazard?

    var isActive: Bool { phase != .completed }

    static func new(id: UUID = UUID(), mode: SessionMode, source: DemoSource, scenario: Scenario, quake: QuakeSummary?,
                    snapshot: LanguageSnapshot, hazard: Hazard = .earthquake, now: Date = Date(), stateRevision: Int = 1) -> GuideSession {
        GuideSession(sessionId: id, mode: mode, source: source, language: snapshot.languageId, scenario: scenario, quake: quake,
                     phase: hazard == .tsunami ? .tsunamiEvacuate : .protect, hazard: hazard, startedAt: now, updatedAt: now,
                     completedAt: nil, selectedPlaceContext: nil, candidateDestinationIds: [], selectedDestinationId: nil,
                     notificationScheduledFor: nil, languagePackageVersion: snapshot.packageVersion, languageSnapshot: snapshot,
                     stateRevision: stateRevision, lastHazardRevision: 0, lastTsunamiEventId: nil, tsunami: nil,
                     evacuationDecision: .undecided, liveActivityId: nil, liveActivityStatus: .none, pendingLocalHazard: nil)
    }
}

struct NotificationReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case prepared, scheduled, failed }
    /// runId for start-guide, commandId for hazard-update.
    var runId: UUID
    var state: State
    var receivedAt: Date
    var fireAt: Date?
    var errorCode: DeliveryErrorCode?
    var stateRevision: Int?
}

enum DeliveryErrorCode: String, Codable, Error, Sendable {
    case unsupportedVersion = "unsupported-version"
    case invalidPayload = "invalid-payload"
    case expiredCommand = "expired-command"
    case clockSkew = "clock-skew"
    case notificationsDenied = "notifications-denied"
    case storageFailed = "storage-failed"
    case notificationFailed = "notification-failed"
    case sessionBusy = "session-busy"
    case languageMismatch = "language-mismatch"
    case languagePackageMissing = "language-package-missing"
    case staleRevision = "stale-revision"
}

enum SessionStoreError: Error, Equatable, Sendable {
    case sessionBusy
    case sessionNotFound
    case staleRevision
    case invalidTransition
    case storageFailed
}

enum ISO8601 {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ s: String) -> Date? {
        lock.withLock { fractional.date(from: s) ?? plain.date(from: s) }
    }

    static func string(_ d: Date) -> String {
        lock.withLock { fractional.string(from: d) }
    }
}

extension JSONDecoder {
    static let nigeyo: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }()
}

extension JSONEncoder {
    static let nigeyo: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.string(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
