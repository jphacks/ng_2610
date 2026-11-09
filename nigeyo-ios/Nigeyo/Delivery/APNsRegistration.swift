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

    func didRegister(deviceToken: Data) {
        state = .registered(token: deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func didFail(error: Error) {
        state = .failed(message: error.localizedDescription)
    }
}
