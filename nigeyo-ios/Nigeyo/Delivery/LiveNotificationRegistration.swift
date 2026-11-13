import ActivityKit
import Foundation

@MainActor
enum LiveNotificationRegistration {
    enum Failure: Error {
        case missingEndpoint, notificationsDenied, deviceNotProvisioned, server
    }

    static var endpoint: URL? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "NigeyoLiveRegistrationHost") as? String,
              !host.isEmpty, host.utf8.allSatisfy({
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
              }) else { return nil }
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = "/subscription"
        return url.url
    }

    private struct Subscription: Encodable {
        var version: Int
        var enabled: Bool
        var targets: [RegionalTarget]
        var activity: ActivityRegistration?
    }

    private struct ActivityRegistration: Encodable, Equatable {
        var token: String
        var language: String
    }

    private static var synced = false
    private static var uploadedActivity: ActivityRegistration?
    private static var requests: Task<Void, Error>?
    private static var userUpdates = 0

    static func update(_ subscription: RegionalSubscription, language: LanguageID) async throws {
        userUpdates += 1
        defer { userUpdates -= 1 }
        try await enqueue(subscription, language: language)
    }

    private static func enqueue(_ subscription: RegionalSubscription, language: LanguageID) async throws {
        let data = subscription.enabled && ActivityAuthorizationInfo().areActivitiesEnabled
            ? Activity<NigeyoActivityAttributes>.pushToStartToken : nil
        let activity = data.map { ActivityRegistration(token: hex($0), language: language.rawValue) }
        let previous = requests
        let task = Task {
            _ = await previous?.result
            try await put(Subscription(version: subscription.version, enabled: subscription.enabled, targets: subscription.targets, activity: activity))
            uploadedActivity = activity
            synced = true
        }
        requests = task
        try await task.value
    }

    static func refreshActivity(settings: SettingsStore) async {
        guard userUpdates == 0, settings.liveRegistrationNeedsRevocation, settings.regionalSubscription.enabled else { return }
        let data = ActivityAuthorizationInfo().areActivitiesEnabled ? Activity<NigeyoActivityAttributes>.pushToStartToken : nil
        let desired = data.map { ActivityRegistration(token: hex($0), language: settings.language.rawValue) }
        guard !synced || desired != uploadedActivity else { return }
        try? await enqueue(settings.regionalSubscription, language: settings.language)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct UpdateToken: Encodable {
        var token: String
        var sessionId: UUID
        var hazard: Hazard
        var sourceEventId: String
        var issuedAt: Date
    }

    static func uploadUpdateToken(_ token: Data, command: RegionalAlert, settings: SettingsStore) async {
        guard settings.regionalSubscription.enabled,
              let endpoint = endpoint?.deletingLastPathComponent().appendingPathComponent("activity") else { return }
        let body = UpdateToken(token: hex(token), sessionId: command.commandId, hazard: command.hazard,
                               sourceEventId: command.sourceEventId, issuedAt: command.issuedAt)
        try? await put(body, at: endpoint)
    }

    private static func put(_ body: some Encodable, at url: URL? = nil) async throws {
        guard let endpoint = url ?? endpoint else { throw Failure.missingEndpoint }
        let token = try await APNsRegistration.shared.tokenForLiveRegistration()
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.nigeyo.encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 204: return
        case 403: throw Failure.deviceNotProvisioned
        default: throw Failure.server
        }
    }

    static func messageKey(_ error: Error) -> String {
        switch error {
        case Failure.missingEndpoint: "regions.registration.unavailable"
        case Failure.notificationsDenied: "practice.notificationsDenied"
        case Failure.deviceNotProvisioned: "regions.registration.device"
        default: "regions.registration.failed"
        }
    }
}
