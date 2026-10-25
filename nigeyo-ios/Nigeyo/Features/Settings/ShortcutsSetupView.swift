import SwiftUI
import UIKit

/// Shared by the last onboarding step and Settings. One task at a time, with progress
/// saved before leaving for Shortcuts. iOS provides no API to read its installation state.
struct ShortcutsSetupView: View {
    var onDone: () -> Void
    var onBack: (() -> Void)? = nil
    var allowsSkip = false
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var step = 0
    @State private var progress = ShortcutPreparation()
    @State private var document: ShortcutDocument?
    @State private var showOpenError = false
    @State private var liveTestRunning = false
    @State private var initialized = false
    @State private var showCompleted = false

    private var canContinue: Bool {
        model.notificationAuthorization == .authorized
    }

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["onboarding.lock.nav"], onBack: showCompleted ? onDone : back) {
            if showCompleted {
                ScreenTitle(t["setup.readyTitle"])
                NoteCard(title: t["setup.readyStatus"], message: t["setup.readyBody"])
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<4) { index in
                        Capsule().fill(index <= step ? Color.ink : Color.line).frame(height: 4)
                    }
                }
                .accessibilityLabel(t("setup.progress", ["current": String(step + 1), "total": "4"]))
                Eyebrow(t("setup.progress", ["current": String(step + 1), "total": "4"]))
                ScreenTitle(t["setup.step\(step).title"])
                BodyText(t["setup.step\(step).body"])
                switch step {
                case 0: notificationStep
                case 1: addStep
                case 2: automationStep
                default: testStep
                }
            }
        } actions: {
            if showCompleted {
                NButton(t["common.done"]) { finish() }
                NButton(t["setup.review"], kind: .secondary) { showCompleted = false; step = 1 }
            } else if step > 0 {
                NButton(t["setup.advance\(step)"], kind: canContinue ? .primary : .disabled) {
                    switch step {
                    case 1:
                        progress.earthquakeAdded = true
                        progress.tsunamiAdded = true
                    case 2: progress.automationsEnabled = true
                    default:
                        progress.earthquakeTested = true
                        progress.tsunamiTested = true
                    }
                    model.settings.shortcutPreparation = progress
                    if step == 3 { finish() } else { step += 1 }
                }
            }
            if allowsSkip && !showCompleted {
                Button(t["onboarding.lock.later"]) { finish() }
                    .nFont(13).foregroundStyle(Color.muted).frame(minHeight: 44)
            }
        }
        .id(step)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            progress = model.settings.shortcutPreparation
            if model.notificationAuthorization == .authorized {
                showCompleted = progress.complete
                step = progress.automationsEnabled && progress.bothAdded ? 3 : progress.bothAdded ? 2 : 1
            }
        }
        .onChange(of: model.notificationAuthorization) { _, authorization in
            if authorization == .authorized, step == 0 { step = 1 }
            else if authorization != .authorized { showCompleted = false; step = 0 }
        }
        .onChange(of: progress) { _, value in model.settings.shortcutPreparation = value }
        .onDisappear { Task { await model.services.liveActivities.endTest() } }
        .sheet(item: $document) { doc in
            ShortcutFileHandoff(url: doc.url) { document = nil }
                .presentationDetents([.medium, .large])
        }
        .alert(t["setup.openFailed"], isPresented: $showOpenError) {
            Button(t["common.close"], role: .cancel) {}
        } message: { Text(t["setup.openFailedBody"]) }
    }

    private func back() {
        if step > 1 || (step == 1 && model.notificationAuthorization != .authorized) {
            step -= 1
        } else {
            (onBack ?? onDone)()
        }
    }

    private func finish() {
        model.settings.shortcutPreparation = progress
        Task { await model.services.liveActivities.endTest() }
        onDone()
    }

    private var notificationStep: some View {
        let t = model.strings
        return VStack(alignment: .leading, spacing: 16) {
            Card {
                if model.notificationAuthorization == .authorized {
                    Label(t["onboarding.lock.notificationsAllowed"], systemImage: "checkmark.circle.fill")
                        .nFont(16, .bold).foregroundStyle(Color.green).padding(.vertical, 8)
                } else if model.notificationAuthorization == .notDetermined {
                    BodyText(t["setup.notificationsPrompt"])
                    NButton(t["setup.allowNotifications"], kind: .accent) {
                        Task { await model.requestNotifications() }
                    }.padding(.top, 8)
                } else {
                    BodyText(t["onboarding.lock.notificationsDenied"])
                    NButton(t["setup.openSettings"], kind: .secondary) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }.padding(.top, 8)
                }
            }
            Footnote(t["setup.noServer"])
        }
    }

    private var addStep: some View {
        let t = model.strings
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(BundledShortcut.allCases) { shortcut in
                shortcutCard(shortcut, testing: false)
            }
            DisclosureGroup(t["setup.importHelp"]) {
                BodyText(t["setup.importHelpBody"], size: 13).padding(.top, 8)
            }.nFont(13, .bold).tint(.ink)
            Footnote(t["setup.manualConfirmation"])
        }
    }

    private var automationStep: some View {
        let t = model.strings
        return VStack(alignment: .leading, spacing: 16) {
            instruction("1", t["setup.automation1"], t["setup.automation1Body"])
            instruction("2", t["setup.automation2"], t["setup.automation2Body"])
            Card {
                ForEach(BundledShortcut.allCases) { shortcut in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t["hazard.\(shortcut.rawValue)"]).nFont(14, .bold)
                        Text(shortcut.notificationTitle).nFont(13, .semibold).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
                BodyText(t["setup.contains"], size: 12)
            }
            instruction("3", t["setup.automation3"], t["setup.automation3Body"])
            NButton(t["setup.openShortcuts"], kind: .secondary) { openShortcuts() }
            Footnote(t["setup.oldAutomation"])
        }
    }

    private var testStep: some View {
        let t = model.strings
        return VStack(alignment: .leading, spacing: 16) {
            NoteCard(title: t["setup.wallpaperNotice"], message: t["setup.wallpaperNoticeBody"])
            ForEach(BundledShortcut.allCases) { shortcut in
                shortcutCard(shortcut, testing: true)
            }
            BodyText(t["setup.testScope"], size: 12)
            DisclosureGroup(t["onboarding.lock.liveActivity"]) {
                BodyText(t["onboarding.lock.liveActivityBody"], size: 12)
                NButton(t[liveTestRunning ? "setup.endLiveTest" : "setup.startLiveTest"], kind: .secondary) {
                    Task { await toggleLiveTest() }
                }.padding(.top, 8)
                if liveTestRunning { BodyText(t["setup.liveTestBody"], size: 12) }
                if !model.liveActivitiesEnabled { BodyText(t["liveActivity.disabled"], size: 12) }
            }.nFont(13, .bold).tint(.ink)
        }
    }

    private func instruction(_ number: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).nFont(13, .bold).foregroundStyle(Color.white)
                .frame(width: 28, height: 28).background(Color.ink, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).nFont(16, .bold).foregroundStyle(Color.ink)
                BodyText(body, size: 13)
            }
        }
    }

    private func shortcutCard(_ shortcut: BundledShortcut, testing: Bool) -> some View {
        let t = model.strings
        let isQuake = shortcut == .earthquake
        return Card(background: isQuake ? .orangeSoft : Color(hex: 0xE3EFF8)) {
            HStack(alignment: .center, spacing: 16) {
                if let url = Bundle.main.url(forResource: shortcut.rawValue, withExtension: "png"),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(t["hazard.\(shortcut.rawValue)"]).nFont(20, .bold).foregroundStyle(Color.ink)
                    BodyText(t["setup.\(shortcut.rawValue)Preview"], size: 12)
                    Text(shortcut.importName).nFont(11).foregroundStyle(Color.muted)
                }
            }.padding(.bottom, 12)
            NButton(t[testing ? "setup.test.\(shortcut.rawValue)" : "shortcuts.\(shortcut.rawValue)Add"], kind: .secondary) {
                if testing {
                    openURL(shortcut.runURL) { accepted in if !accepted { showOpenError = true } }
                } else {
                    do { document = ShortcutDocument(url: try shortcut.exportURL()) }
                    catch { showOpenError = true }
                }
            }
        }
    }

    private func openShortcuts() {
        if let url = URL(string: "shortcuts://") {
            openURL(url) { accepted in if !accepted { showOpenError = true } }
        }
    }

    private func toggleLiveTest() async {
        if liveTestRunning {
            await model.services.liveActivities.endTest()
            liveTestRunning = false
        } else if let snap = await model.services.registry.snapshot(for: model.settings.language) {
            let sample = GuideSession.new(mode: .training, source: .local, scenario: .earthquake, quake: nil, snapshot: snap)
            liveTestRunning = await model.services.liveActivities.startTest(state: GuideContent.activityState(for: sample, interactive: false))
            if liveTestRunning { model.settings.lockScreenTested = true }
        }
    }
}

private struct ShortcutDocument: Identifiable {
    let id = UUID()
    let url: URL
}

/// Use the system's file handoff, never try to install a workflow silently or report
/// that dismissing the menu means success. Saving to Files is the OS fallback.
private struct ShortcutFileHandoff: UIViewControllerRepresentable {
    let url: URL
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> HandoffController {
        HandoffController(url: url, onClose: onClose)
    }

    func updateUIViewController(_ uiViewController: HandoffController, context: Context) {}

    final class HandoffController: UIViewController, @preconcurrency UIDocumentInteractionControllerDelegate {
        private let document: UIDocumentInteractionController
        private let onClose: () -> Void
        private var presented = false

        init(url: URL, onClose: @escaping () -> Void) {
            document = UIDocumentInteractionController(url: url)
            self.onClose = onClose
            super.init(nibName: nil, bundle: nil)
            document.delegate = self
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            if !document.presentOpenInMenu(from: view.bounds, in: view, animated: true) {
                let share = UIActivityViewController(activityItems: [document.url!], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = view
                share.popoverPresentationController?.sourceRect = view.bounds
                share.completionWithItemsHandler = { [weak self] _, _, _, _ in self?.onClose() }
                present(share, animated: true)
            }
        }

        func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) { onClose() }
    }
}
