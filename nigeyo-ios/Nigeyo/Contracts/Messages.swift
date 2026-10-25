import Foundation

// MARK: - WebSocket contract v2 (spec §8). UTF-8 JSON text, ≤16KB, schemaVersion 2.

enum WireConstants {
    static let schemaVersion = 2
    static let maxMessageBytes = 16 * 1024
    static let resourceVersion = 2
    static let clockSkewTolerance: TimeInterval = 5
}

struct HelloMessage: Encodable, Sendable {
    let schemaVersion = WireConstants.schemaVersion
    let type = "hello"
    var installationId: UUID
    var appVersion: String
    var preferredLanguage: LanguageID
    var languagePackageVersion: Int
    var resourceVersion = WireConstants.resourceVersion
    var liveActivitiesEnabled: Bool
    var notificationAuthorization: String
    var regionalSubscription: RegionalSubscription? = nil
}

struct HeartbeatMessage: Encodable, Sendable {
    let schemaVersion = WireConstants.schemaVersion
    let type = "heartbeat"
    var installationId: UUID
    var appState: String
    var protectedDataAvailable: Bool
    var currentSessionId: UUID?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(type, forKey: .type)
        try c.encode(installationId, forKey: .installationId)
        try c.encode(appState, forKey: .appState)
        try c.encode(protectedDataAvailable, forKey: .protectedDataAvailable)
        try c.encode(currentSessionId, forKey: .currentSessionId) // explicit null
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, type, installationId, appState, protectedDataAvailable, currentSessionId }
}

struct NotificationAck: Encodable, Equatable, Sendable {
    enum Status: String, Encodable, Sendable { case scheduled, duplicate, rejected, failed }
    let schemaVersion = WireConstants.schemaVersion
    let type = "notification-ack"
    var runId: UUID?
    var commandId: UUID?
    var sessionId: UUID?
    var hazardRevision: Int?
    var stateRevision: Int?
    var status: Status
    var errorCode: DeliveryErrorCode?
    var receivedAt: Date
    var scheduledAt: Date?
    var appState: String
    var protectedDataAvailable: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.runId == b.runId && a.commandId == b.commandId && a.status == b.status && a.errorCode == b.errorCode && a.stateRevision == b.stateRevision
    }
}

struct StartGuideCommand: Decodable, Sendable {
    var schemaVersion: Int
    var type: String
    var runId: UUID
    var mode: SessionMode
    var source: DemoSource
    var language: LanguageID
    var scenario: Scenario
    var languagePackageVersion: Int
    var stateRevision: Int
    var hazard: Hazard
    var sentAt: Date
    var expiresAt: Date
    var quake: QuakeSummary?
}

struct HazardUpdateCommand: Decodable, Sendable {
    var schemaVersion: Int
    var type: String
    var commandId: UUID
    var sessionId: UUID
    var hazardRevision: Int
    var hazard: Hazard
    var mode: SessionMode
    var source: DemoSource
    var language: LanguageID
    var languagePackageVersion: Int
    var sentAt: Date
    var expiresAt: Date
    var tsunami: TsunamiSummary?
}

enum IncomingMessage: Sendable {
    case startGuide(StartGuideCommand)
    case hazardUpdate(HazardUpdateCommand)
    case serverError(String)
    /// Rejected before parsing a command id: reply with an un-addressed error.
    case invalid(DeliveryErrorCode, runId: UUID?)

    private struct Envelope: Decodable {
        var schemaVersion: Int?
        var type: String?
        var runId: UUID?
        var commandId: UUID?
        var errorCode: String?
    }

    static func decode(_ data: Data) -> IncomingMessage {
        guard data.count <= WireConstants.maxMessageBytes,
              let env = try? JSONDecoder.nigeyo.decode(Envelope.self, from: data) else { return .invalid(.invalidPayload, runId: nil) }
        guard env.schemaVersion == WireConstants.schemaVersion else { return .invalid(.unsupportedVersion, runId: env.runId) }
        switch env.type {
        case "start-guide":
            guard let cmd = try? JSONDecoder.nigeyo.decode(StartGuideCommand.self, from: data) else { return .invalid(.invalidPayload, runId: env.runId) }
            return .startGuide(cmd)
        case "hazard-update":
            guard let cmd = try? JSONDecoder.nigeyo.decode(HazardUpdateCommand.self, from: data) else { return .invalid(.invalidPayload, runId: env.commandId) }
            return .hazardUpdate(cmd)
        case "error":
            return .serverError(env.errorCode ?? "unknown")
        default:
            return .invalid(.invalidPayload, runId: env.runId)
        }
    }
}
