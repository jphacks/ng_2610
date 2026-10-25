import Foundation
import UserNotifications

enum NotificationAuthorization: String, Sendable {
    case notDetermined = "not-determined", denied, authorized, provisional

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .ephemeral: self = .authorized
        case .provisional: self = .provisional
        case .denied: self = .denied
        default: self = .notDetermined
        }
    }
}

protocol NotificationScheduling: Sendable {
    func authorization() async -> NotificationAuthorization
    func schedule(_ content: GuideContent.NotificationContent, after seconds: TimeInterval) async throws
    func exists(identifier: String) async -> Bool
    func cancel(identifiers: [String]) async
    func cancelAllNigeyo() async
}

/// Local notifications only. Title is the fixed shortcut trigger (EARTHQUAKE_TEST / TSUNAMI_TEST);
/// the body is localized from the session snapshot. Only the OS default sound, no voice guidance.
final class NotificationService: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate, @unchecked Sendable {
    typealias TapHandler = @Sendable (_ userInfo: [String: String]) async -> Void
    typealias PresentHandler = @Sendable (_ userInfo: [String: String]) async -> Void

    private let center = UNUserNotificationCenter.current()
    // Assigned once on the main thread at launch, before notifications can arrive.
    nonisolated(unsafe) var onTap: TapHandler?
    nonisolated(unsafe) var onPresent: PresentHandler?

    func install() {
        center.delegate = self
    }

    func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await authorization()
    }

    func authorization() async -> NotificationAuthorization {
        NotificationAuthorization(await center.notificationSettings().authorizationStatus)
    }

    func schedule(_ content: GuideContent.NotificationContent, after seconds: TimeInterval) async throws {
        let c = UNMutableNotificationContent()
        c.title = content.title
        c.body = content.body
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = content.userInfo
        c.threadIdentifier = "nigeyo"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        try await center.add(UNNotificationRequest(identifier: content.identifier, content: c, trigger: trigger))
    }

    func exists(identifier: String) async -> Bool {
        let pending = await center.pendingNotificationRequests().contains { $0.identifier == identifier }
        if pending { return true }
        return await center.deliveredNotifications().contains { $0.request.identifier == identifier }
    }

    func cancel(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAllNigeyo() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("nigeyo.") }
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix("nigeyo.") }
        await cancel(identifiers: pending + delivered)
    }

    private static func strings(_ info: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in info { if let k = k as? String, let v = v as? String { out[k] = v } }
        return out
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await onPresent?(Self.strings(notification.request.content.userInfo))
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await onTap?(Self.strings(response.notification.request.content.userInfo))
    }
}
