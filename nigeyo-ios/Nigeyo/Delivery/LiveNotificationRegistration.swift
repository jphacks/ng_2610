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

    static func update(_ subscription: RegionalSubscription) async throws {
        guard let endpoint else { throw Failure.missingEndpoint }
        let token = try await APNsRegistration.shared.tokenForLiveRegistration()
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder.nigeyo.encode(subscription)
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
