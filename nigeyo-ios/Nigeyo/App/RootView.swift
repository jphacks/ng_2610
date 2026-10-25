import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.root {
            case .onboarding: OnboardingFlow()
            case .waiting: WaitingView()
            case .guide: GuideFlowView()
            case .resumePrompt: ResumePromptView()
            case .home: HomeFlow()
            }
        }
        .animation(.default, value: model.root)
        .environment(\.layoutDirection, model.root == .guide || model.root == .waiting ? model.guideStrings.direction : model.strings.direction)
        .alert(model.strings["error.generic"], isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(model.strings["common.close"], role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Older than 30 minutes: ask before resuming (spec §10).
struct ResumePromptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.guideStrings
        Screen {
            GuideHeader(appName: t["app.name"], badge: model.session?.mode == .manual ? nil : t["training.badge"])
            Spacer(minLength: 40)
            Card {
                Text(t["home.resumeTitle"]).nFont(20, .bold).foregroundStyle(Color.ink)
                BodyText(t["home.resumeBody"])
            }
        } actions: {
            NButton(t["home.resume"]) { model.acknowledgeResume() }
            NButton(t["home.discard"], kind: .secondary) { Task { await model.endSession() } }
        }
    }
}
