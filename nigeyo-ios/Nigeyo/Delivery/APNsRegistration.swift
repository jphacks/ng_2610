import Observation
import UIKit

/// On-demand registration for the notification delivery check in Diagnostics.
/// The token stays in memory and is never included in diagnostic logs.
@MainActor
@Observable
final class APNsRegistration {
    static let shared = APNsRegistration()

    enum State {
        case idle, registering, registered(token: String), failed(message: String)
    }

    private(set) var state: State = .idle

    func register() {
        state = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    func tokenForLiveRegistration() async throws -> String {
        if case .registered(let token) = state { return token }
        register()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            switch state {
            case .registered(let token): return token
            case .failed: throw LiveNotificationRegistration.Failure.server
            case .idle, .registering: try await clock.sleep(for: .milliseconds(100))
            }
        }
        throw LiveNotificationRegistration.Failure.server
    }

    func didRegister(deviceToken: Data) {
        state = .registered(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func didFail(error: Error) {
        state = .failed(message: error.localizedDescription)
    }
}
