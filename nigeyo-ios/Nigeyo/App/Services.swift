import Foundation

/// Process-wide, non-UI dependencies. Also reachable from LiveActivityIntent, which can run
/// with no scene (spec §13.5). Created once; every component shares the same SessionStore.
final class Services: Sendable {
    static let shared = Services()

    let settings: SettingsStore
    let store: SessionStore
    let registry: LanguageRegistry
    let notifications: NotificationService
    let diagnostics: DiagnosticsLog
    let evacuation: EvacuationRepository
    let liveActivities: LiveActivityCoordinator
    let processor: CommandProcessor
    let delivery: WebSocketDeliveryService

    private init() {
        let settings = SettingsStore()
        let store = SessionStore()
        let registry = LanguageRegistry()
        let notifications = NotificationService()
        let diagnostics = DiagnosticsLog()
        let log: @Sendable (String) async -> Void = { await diagnostics.record($0) }
        let liveActivities = LiveActivityCoordinator(store: store, log: log)
        let processor = CommandProcessor(store: store, notifications: notifications, registry: registry,
                                         preferredLanguage: { settings.language }, deviceState: { await Services.deviceState() }, log: log)
        self.settings = settings
        self.store = store
        self.registry = registry
        self.notifications = notifications
        self.diagnostics = diagnostics
        self.evacuation = EvacuationRepository()
        self.liveActivities = liveActivities
        self.processor = processor
        self.delivery = WebSocketDeliveryService(
            processor: processor,
            helloInfo: {
                let language = settings.language
                return .init(installationId: settings.installationId, appVersion: Bundle.main.appVersion, language: language,
                             languagePackageVersion: await registry.package(for: language)?.packageVersion ?? 0,
                             liveActivitiesEnabled: liveActivities.areActivitiesEnabled,
                             notificationAuthorization: await notifications.authorization())
            },
            deviceState: { await Services.deviceState() },
            currentSessionId: { (try? await store.snapshot()).flatMap { $0.isActive ? $0.sessionId : nil } },
            log: log)
    }

    @MainActor
    static func currentDeviceState() -> DeviceState {
        let app = UIApplicationProxy.shared
        return DeviceState(appState: app.appState, protectedDataAvailable: app.protectedDataAvailable)
    }

    static func deviceState() async -> DeviceState {
        await MainActor.run { currentDeviceState() }
    }

    /// Lock-screen "shaking stopped": save first, then update the Activity from the saved state.
    /// A stale or tsunami-superseded confirmation leaves the newer state on screen.
    func confirmShakingStopped(sessionId: String, expectedRevision: Int) async throws {
        guard let id = UUID(uuidString: sessionId) else { throw SessionStoreError.sessionNotFound }
        do {
            let session = try await store.transition(sessionId: id, expectedRevision: expectedRevision, to: .safetyChecks)
            await diagnostics.record("live activity: shaking stopped rev\(expectedRevision)")
            await liveActivities.sync(session, foreground: false)
        } catch {
            await diagnostics.record("live activity: confirmation rejected (\(error))")
            await liveActivities.sync(try? await store.snapshot(), foreground: false)
            throw error
        }
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
}
