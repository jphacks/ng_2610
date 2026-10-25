import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate must be in place before a notification tap is delivered at launch.
        Services.shared.notifications.install()
        return true
    }
}

@main
struct NigeyoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        LiveActivityIntentBridge.confirmHandler = { sessionId, revision in
            try await Services.shared.confirmShakingStopped(sessionId: sessionId, expectedRevision: revision)
        }
        let model = AppModel()
        _model = State(initialValue: model)
        Services.shared.notifications.onTap = { info in await model.handleNotification(userInfo: info) }
        Services.shared.notifications.onPresent = { info in await model.handleNotification(userInfo: info) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { url in Task { await model.handle(url: url) } }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { Task { await model.becameActive() } } else { model.resignedActive() }
                    if phase == .background { model.enteredBackground() }
                }
        }
    }
}
