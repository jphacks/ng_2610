import AppIntents
import Foundation

/// "揺れがおさまりましたか" on the lock screen. LiveActivityIntent runs in the main app's process,
/// where NigeyoApp installs the handler that drives the shared SessionStore (spec §13.5).
struct ConfirmShakingStoppedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Shaking has stopped"
    static let isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Revision") var expectedRevision: Int

    init() {}

    init(sessionId: String, expectedRevision: Int) {
        self.sessionId = sessionId
        self.expectedRevision = expectedRevision
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityIntentBridge.confirmShakingStopped(sessionId: sessionId, expectedRevision: expectedRevision)
        return .result()
    }
}

enum LiveActivityIntentBridge {
    typealias Handler = @Sendable (_ sessionId: String, _ expectedRevision: Int) async throws -> Void

    struct NotInstalled: Error {}

    // Set once from NigeyoApp.init before any intent can run; never mutated afterwards.
    nonisolated(unsafe) static var confirmHandler: Handler?

    static func confirmShakingStopped(sessionId: String, expectedRevision: Int) async throws {
        guard let handler = confirmHandler else { throw NotInstalled() }
        try await handler(sessionId, expectedRevision)
    }
}
