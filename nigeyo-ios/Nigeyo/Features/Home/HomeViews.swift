import SwiftUI

struct HomeFlow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.homePath) {
            HomeView()
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .practice: PracticeView()
                    case .settings: SettingsView()
                    case .language: LanguageSettingsView()
                    case .savedPlaces: SavedPlacesView()
                    case .redoPlaces: RedoPlacesView()
                    case .lockScreen: LockScreenSetupView(counter: nil, onBack: { pop() }, onFinish: { pop() })
                    case .shortcuts: ShortcutsSetupView { pop() }
                    case .languageUpdate: LanguageUpdateView()
                    case .demo: DemoConnectionView()
                    case .privacy: PrivacyView()
                    case .deleteData: DeleteDataView()
                    case .diagnostics: DiagnosticsView()
                    }
                }
        }
    }

    private func pop() {
        if !model.homePath.isEmpty { model.homePath.removeLast() }
    }
}

// MARK: 05 Home

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen {
            HStack(alignment: .firstTextBaseline) {
                Text(t["app.name"]).nFont(32, .bold).foregroundStyle(Color.ink)
                Spacer()
                Button(t["home.settings"]) { model.homePath.append(.settings) }
                    .nFont(14).foregroundStyle(Color.ink).frame(minWidth: 44, minHeight: 44)
            }
            if model.homeNotice == .missingSession {
                NoteCard(title: t["home.missingSession"], message: t["home.missingSessionBody"], tint: .danger, background: .orangeSoft)
                    .onTapGesture { model.homeNotice = nil }
            }
            Eyebrow(t["home.eyebrow"]).padding(.top, 8)
            ScreenTitle(t["home.title"])
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Pictogram(name: "protect-head", size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t["home.practiceTitle"]).nFont(22, .bold).foregroundStyle(Color.ink)
                        Text(t["home.practiceBody"]).nFont(14).foregroundStyle(Color.ink)
                    }
                }
                NButton(t["home.practiceStart"]) { model.homePath.append(.practice) }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: Radius.card))
            RowCard(title: t["home.feltShaking"], subtitle: t["home.feltShakingBody"], accessory: .external) {
                Task { await model.startManual() }
            }
            Eyebrow(t["home.savedPlaces"]).padding(.top, 4)
            RowCard(title: t["home.destinations"], subtitle: t["home.destinationsBody"]) { model.homePath.append(.savedPlaces) }
            NoteCard(title: t["home.offlineTitle"], message: t["home.offlineBody"])
        } actions: {
            HStack(spacing: 4) {
                ForEach(Array(model.languages.enumerated()), id: \.element.id) { i, lang in
                    if i > 0 { Text("·").foregroundStyle(Color.muted) }
                    Button(lang.nativeName) { Task { await model.setLanguage(lang.id) } }
                        .nFont(12, lang.id == model.strings.languageId ? .bold : .regular)
                        .foregroundStyle(lang.id == model.strings.languageId ? Color.ink : Color.muted)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: 06 Practice

struct PracticeView: View {
    @Environment(AppModel.self) private var model
    @State private var scenario: Scenario = .earthquake
    @State private var starting = false

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["practice.nav"], onBack: { model.homePath.removeLast() }) {
            Badge(text: t["training.badgeLong"])
            Eyebrow(t["practice.eyebrow"])
            ScreenTitle(t["practice.title"])
            BodyText(t["practice.body"])
            RowCard(title: t["practice.earthquake"], subtitle: t["practice.earthquakeBody"], accessory: .radio(scenario == .earthquake),
                    background: scenario == .earthquake ? .orangeSoft : .white) { scenario = .earthquake }
            RowCard(title: t["practice.tsunami"], subtitle: t["practice.tsunamiBody"], accessory: .radio(scenario == .earthquakeTsunami),
                    background: scenario == .earthquakeTsunami ? .orangeSoft : .white) { scenario = .earthquakeTsunami }
            Card {
                Pictogram(name: "protect-head", size: 56).padding(.bottom, 12)
                Text(t["practice.lockTitle"]).nFont(17, .bold).foregroundStyle(Color.ink)
                Text(t["practice.lockBody"]).nFont(14).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.notificationAuthorization == .denied {
                Text(t["practice.notificationsDenied"]).nFont(12, .bold).foregroundStyle(Color.danger)
            }
        } actions: {
            NButton(scenario == .earthquake ? t["practice.start"] : t["practice.startTsunami"], kind: starting ? .disabled : .accent) {
                starting = true
                Task {
                    if await model.startTraining(scenario: scenario) { model.homePath = [] }
                    starting = false
                }
            }
            Footnote(t["practice.footnote"])
        }
    }
}

// MARK: 07 Waiting for the drill notification

struct WaitingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.guideStrings
        Screen {
            Badge(text: t["training.badgeLong"]).padding(.top, 8)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card).fill(Color.orangeSoft)
                Image(systemName: "iphone").font(.system(size: 96, weight: .light)).foregroundStyle(Color.ink).accessibilityHidden(true)
            }
            .frame(height: 210)
            .padding(.vertical, 12)
            Eyebrow(t["waiting.eyebrow"])
            ScreenTitle(t["waiting.title"])
            BodyText(t["waiting.body"])
            Card {
                Label(t["waiting.scheduled"], systemImage: "clock").nFont(15, .bold).foregroundStyle(Color.ink)
                Text(t["waiting.scheduledBody"]).nFont(13).foregroundStyle(Color.muted)
            }
        } actions: {
            NButton(t["waiting.cancel"], kind: .secondary) { Task { await model.endSession() } }
            Footnote(t["waiting.footnote"])
        }
    }
}
