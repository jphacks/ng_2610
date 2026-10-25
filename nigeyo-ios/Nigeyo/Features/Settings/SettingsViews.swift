import SwiftUI

private extension AppModel {
    func pop() { if !homePath.isEmpty { homePath.removeLast() } }
}

// MARK: 08 Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["settings.nav"], onBack: { model.pop() }) {
            RowCard(title: t["settings.language"], subtitle: model.languages.first { $0.id == t.languageId }?.nativeName) { model.homePath.append(.language) }
            RowCard(title: t["settings.savedPlaces"], subtitle: t["settings.savedPlacesBody"]) { model.homePath.append(.savedPlaces) }
            RowCard(title: t["settings.lockScreen"], subtitle: t["settings.lockScreenBody"]) { model.homePath.append(.lockScreen) }
            RowCard(title: t["settings.updateLanguages"], subtitle: t["settings.updateLanguagesBody"], accessory: .refresh) { model.homePath.append(.languageUpdate) }
            RowCard(title: t["settings.demo"], subtitle: "\(t["settings.demoBody"]) · \(t["demo.state.\(model.connection.rawValue)"])") { model.homePath.append(.demo) }
            RowCard(title: t["settings.privacy"], subtitle: t["settings.privacyBody"]) { model.homePath.append(.privacy) }
            RowCard(title: t["settings.diagnostics"], subtitle: t["settings.diagnosticsBody"]) { model.homePath.append(.diagnostics) }
        } actions: {
            NButton(t["settings.deleteAll"], kind: .destructive) { model.homePath.append(.deleteData) }
            Footnote(t("settings.version", ["version": Bundle.main.appVersion]))
        }
    }
}

struct LanguageSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["settings.languageNav"], onBack: { model.pop() }) {
            ForEach(model.languages) { lang in
                let on = lang.id == t.languageId
                RowCard(title: lang.nativeName, subtitle: "\(lang.displayName) · v\(lang.packageVersion)", accessory: .radio(on), background: on ? .orangeSoft : .white) {
                    Task { await model.setLanguage(lang.id) }
                }
            }
            BodyText(t["settings.languageNote"], size: 12)
        } actions: {
            EmptyView()
        }
    }
}

// MARK: Saved places (four slots)

struct SavedPlacesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["savedPlaces.nav"], onBack: { model.pop() }) {
            ForEach(DestinationSlot.all, id: \.self) { slot in
                let saved = model.settings.destination(slot)
                Card {
                    Text(t("onboarding.destinations.slot", ["place": t[slot.place == .home ? "onboarding.places.home" : "onboarding.places.university"], "hazard": t["hazard.\(slot.hazard.rawValue)"]]))
                        .nFont(12, .bold).foregroundStyle(Color.muted)
                    if let saved, let site = saved.site {
                        Text(site.name).nFont(17, .bold).foregroundStyle(Color.ink)
                        Text(site.address).nFont(12).foregroundStyle(Color.muted)
                        if let m = saved.meters {
                            Text(saved.distanceKind == .walking ? t("distance.walking", ["distance": t.distance(m)]) : t("distance.straight", ["distance": t.distance(m)]))
                                .nFont(12).foregroundStyle(Color.muted)
                        }
                    } else if saved != nil {
                        Text(t["onboarding.destinations.none"]).nFont(17, .bold).foregroundStyle(Color.ink)
                    } else {
                        Text(t["savedPlaces.empty"]).nFont(15).foregroundStyle(Color.muted)
                    }
                }
            }
            BodyText(t["onboarding.destinations.note"], size: 12)
        } actions: {
            NButton(t["savedPlaces.redo"], kind: .secondary) { model.homePath.append(.redoPlaces) }
        }
    }
}

/// Settings → redo places: the same places → four-slot steps as onboarding, coordinates discarded after saving.
struct RedoPlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var places = OnboardingModel()
    @State private var showDestinations = false

    var body: some View {
        PlacesStepView(places: places, counter: nil, onBack: { model.pop() }) { showDestinations = true }
            .navigationDestination(isPresented: $showDestinations) {
                DestinationsStepView(places: places, counter: nil, onBack: { showDestinations = false }) {
                    places.save(to: model.settings)
                    model.homePath = [.settings, .savedPlaces]
                }
            }
            .onDisappear { if !showDestinations { places.discard() } }
    }
}

// MARK: 25 Shortcuts (earthquake + tsunami)

struct ShortcutsSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var onDone: () -> Void
    @State private var added = false
    @State private var tested = false

    private var wallpaperFiles: [URL] {
        ["earthquake", "tsunami"].compactMap { Bundle.main.url(forResource: $0, withExtension: "png") }
    }

    var body: some View {
        let t = model.strings
        let origin = model.pairing?.origin
        Screen(navTitle: t["shortcuts.nav"], onBack: onDone) {
            Eyebrow(t["shortcuts.eyebrow"])
            ScreenTitle(t["shortcuts.title"])
            BodyText(t["shortcuts.body"])
            if let origin {
                RowCard(title: t["shortcuts.setupPage"], subtitle: origin.host, accessory: .external) { openURL(origin.appending(path: "public/shortcuts/setup")) }
            } else {
                Text(t["shortcuts.noOrigin"]).nFont(12, .bold).foregroundStyle(Color.danger)
            }
            Toggle(t["shortcuts.addedBoth"], isOn: $added).toggleStyle(CheckboxStyle())
            Toggle(t["shortcuts.testedBoth"], isOn: $tested).toggleStyle(CheckboxStyle())
            BodyText(t["shortcuts.note"], size: 12)
        } actions: {
            NButton(t["shortcuts.finish"], kind: added && tested ? .primary : .disabled) {
                model.settings.shortcutsAdded = true
                model.settings.shortcutsTested = true
                onDone()
            }
            if !wallpaperFiles.isEmpty {
                ShareLink(items: wallpaperFiles) { Text(t["shortcuts.saveWallpapers"]).nFont(13, .bold).frame(minHeight: 44) }
            }
            Footnote(t["shortcuts.footnote"])
        }
        .onAppear {
            added = model.settings.shortcutsAdded
            tested = model.settings.shortcutsTested
        }
    }
}

struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square").foregroundStyle(Color.ink)
                configuration.label.nFont(14).foregroundStyle(Color.ink)
                Spacer()
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: Language pack update

struct LanguageUpdateView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var result: String?

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["languageUpdate.nav"], onBack: { model.pop() }) {
            BodyText(t["languageUpdate.body"])
            if let host = model.pairing?.origin.host { Text(host).nFont(12).foregroundStyle(Color.muted) }
            if let result { Card { Text(result).nFont(14, .bold).foregroundStyle(Color.ink) } }
            ForEach(model.languages) { lang in
                Text("\(lang.nativeName) · v\(lang.packageVersion)").nFont(13).foregroundStyle(Color.muted)
            }
        } actions: {
            NButton(running ? t["languageUpdate.running"] : t["languageUpdate.run"], kind: running ? .disabled : .primary) {
                running = true
                Task {
                    switch await model.updateLanguages() {
                    case .success(let o): result = t("languageUpdate.result", ["added": String(o.added), "updated": String(o.updated)])
                    case .failure(.noOrigin): result = t["languageUpdate.noOrigin"]
                    case .failure(.busy): result = t["languageUpdate.busy"]
                    case .failure: result = t["languageUpdate.failed"]
                    }
                    running = false
                }
            }
        }
    }
}

// MARK: 24 Demo connection

struct DemoConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        let t = model.strings
        let connected = model.connection == .connected
        Screen(navTitle: t["demo.nav"], onBack: { model.pop() }) {
            Eyebrow(t["demo.eyebrow"])
            ScreenTitle(t["demo.title"])
            BodyText(t["demo.body"])
            Card {
                Text(t["demo.urlLabel"]).nFont(17, .bold).foregroundStyle(Color.ink)
                // The pairing string carries a secret token: never shown back in full.
                SecureField("wss://…", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().nFont(13).frame(minHeight: 44)
                if let host = model.pairing?.endpoint.host { Text(host).nFont(12).foregroundStyle(Color.muted) }
                if invalid { Text(t["demo.invalidURL"]).nFont(12, .bold).foregroundStyle(Color.danger) }
            }
            NButton(t["demo.connect"]) {
                Task {
                    invalid = !(await model.connect(pairingText: text))
                    if !invalid { text = "" }
                }
            }
            Card {
                Label(t["demo.state.\(model.connection.rawValue)"], systemImage: connected ? "checkmark.circle.fill" : "circle").nFont(20, .bold).foregroundStyle(connected ? Color.green : Color.ink)
                Text(t[connected ? "demo.connectedBody" : "demo.disconnectedBody"]).nFont(13).foregroundStyle(Color.muted)
                if model.connection != .disconnected {
                    Button(t["demo.disconnect"]) { Task { await model.disconnect() } }.nFont(14, .bold).foregroundStyle(Color.danger).frame(minHeight: 44)
                }
            }
            NoteCard(title: t["demo.permissionsTitle"],
                     message: "\(t["demo.permissionsBody"])\nNotifications: \(model.notificationAuthorization.rawValue) · Live Activity: \(model.liveActivitiesEnabled ? "on" : "off")")
            BodyText(t["demo.note"], size: 12)
            if model.session?.isActive == true {
                NButton(t["settings.resetSession"], kind: .destructive) { Task { await model.resetSession() } }
            }
        } actions: {
            NButton(t["demo.backToSettings"], kind: .secondary) { model.pop() }
        }
    }
}

// MARK: 26 Privacy

struct PrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["privacy.nav"], onBack: { model.pop() }) {
            Eyebrow(t["privacy.eyebrow"])
            ScreenTitle(t["privacy.title"])
            section(t["privacy.savedTitle"], t["privacy.savedBody"])
            section(t["privacy.notSavedTitle"], t["privacy.notSavedBody"])
            section(t["privacy.mapsTitle"], t["privacy.mapsBody"])
            BodyText(t["privacy.googleNote"], size: 12)
        } actions: {
            NButton(t["demo.backToSettings"], kind: .secondary) { model.pop() }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        Card {
            Text(title).nFont(17, .bold).foregroundStyle(Color.ink)
            Text(body).nFont(13).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 28 Delete all data

struct DeleteDataView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["delete.nav"], onBack: { model.pop() }) {
            Badge(text: t["delete.badge"], kind: .danger).padding(.top, 24)
            Eyebrow(t["delete.eyebrow"])
            ScreenTitle(t["delete.title"])
            BodyText(t["delete.body"])
            Card {
                Text(t["delete.manualTitle"]).nFont(17, .bold).foregroundStyle(Color.ink)
                Text(t["delete.manualBody"]).nFont(14).foregroundStyle(Color.muted).padding(.bottom, 4)
                Text(t["delete.manualHint"]).nFont(12).foregroundStyle(Color.muted)
            }
        } actions: {
            NButton(t["delete.confirm"], kind: .destructive) { Task { await model.deleteAllData() } }
            NButton(t["common.cancel"], kind: .secondary) { model.pop() }
        }
    }
}

// MARK: Diagnostics

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["settings.diagnostics"], onBack: { model.pop() }) {
            Text(text.isEmpty ? "—" : text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            NButton(copied ? t["common.copied"] : t["common.copy"]) {
                UIPasteboard.general.string = text
                copied = true
            }
        }
        .task { text = await model.diagnosticsText() }
    }
}
