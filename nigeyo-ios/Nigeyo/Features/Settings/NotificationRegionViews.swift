import SwiftUI

struct NotificationRegionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var updating = false
    @State private var shortcutDocument: ShortcutDocument?
    @State private var shortcutExportFailed = false

    private var usesLiveRegistration: Bool {
        LiveNotificationRegistration.endpoint != nil || model.settings.liveRegistrationNeedsRevocation
    }
    @State private var lastAlerts: [String: RegionalAlert] = [:]

    private var registered: [DestinationSlot] {
        DestinationSlot.all.filter { model.settings.destination($0)?.site != nil }
    }

    private var ready: Bool {
        let targets = model.settings.regionalSubscription.targets
        if model.settings.placeNotificationRegions != nil { return !targets.isEmpty }
        return !registered.isEmpty && targets.count == registered.count
    }

    var body: some View {
        let t = model.strings
        Form {
            Section {
                Text(t["regions.body"])
                if usesLiveRegistration {
                    Toggle(t["regions.enabled"], isOn: Binding(get: { enabled }, set: { update($0) }))
                        .disabled(!ready && !enabled)
                    if updating {
                        ProgressView()
                    } else if enabled {
                        Text(t["regions.registration.registered"]).font(.footnote)
                    } else if model.settings.liveRegistrationNeedsRevocation {
                        Button(t["regions.registration.revoke"]) { update(false) }
                    }
                } else {
                    Text(t["regions.connection"]).font(.footnote)
                    Toggle(t["regions.enabled"], isOn: $enabled).disabled(!ready)
                }
                if !ready { Text(t["regions.needsConfirmation"]).foregroundStyle(.secondary) }
                ForEach(BundledShortcut.live) { shortcut in
                    Button(t["regions.shortcuts.\(shortcut.rawValue)"]) {
                        do { shortcutDocument = ShortcutDocument(url: try shortcut.exportURL()) }
                        catch { shortcutExportFailed = true }
                    }
                }
                Text(t["regions.shortcuts.help"]).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach([PlaceContext.home, .university], id: \.self) { place in
                let slots = DestinationSlot.all.filter { $0.place == place }
                let targets = model.settings.regionalSubscription.targets.filter { target in
                    slots.contains { $0.key == target.slot }
                }
                if !targets.isEmpty || slots.contains(where: { model.settings.destination($0) != nil }) {
                    let earthquakeAreas = Set(targets.map(\.earthquakeArea.name)).sorted()
                    let tsunamiAreas = Set(targets.flatMap(\.tsunamiAreas)).sorted()
                    Section(t[place == .home ? "onboarding.places.home" : "onboarding.places.university"]) {
                        LabeledContent(t["regions.earthquake"], value: earthquakeAreas.isEmpty
                                       ? t["regions.unconfigured"] : earthquakeAreas.joined(separator: " / "))
                        LabeledContent(t["regions.tsunami"], value: targets.isEmpty ? t["regions.unconfigured"]
                                       : tsunamiAreas.isEmpty ? t["regions.none"] : tsunamiAreas.joined(separator: " / "))
                    }
                }
            }
            Button(t["savedPlaces.redo"]) {
                model.homePath.append(.redoPlaces)
                dismiss()
            }
            if !lastAlerts.isEmpty {
                Section(t["regions.latest"]) {
                    ForEach(lastAlerts.keys.sorted(), id: \.self) { key in
                        if let alert = lastAlerts[key] {
                            Text("\(t["hazard.\(key)"]) · \(t["regions.status.\(alert.status)"])\n\(alert.grade ?? "")\n\(alert.matches.map(\.region).joined(separator: ", "))")
                            Text(alert.issuedAt, style: .date).font(.caption)
                        }
                    }
                }
            }
            if !usesLiveRegistration {
                Button(t["regions.save"]) {
                    model.settings.regionalMonitoringEnabled = enabled && ready
                    Task { await model.services.delivery.sendHello() }
                    dismiss()
                }
            }
        }
        .sheet(item: $shortcutDocument) { document in
            ShortcutFileHandoff(url: document.url) { shortcutDocument = nil }
                .presentationDetents([.medium, .large])
        }
        .alert(t["setup.openFailed"], isPresented: $shortcutExportFailed) {
            Button(t["common.close"], role: .cancel) {}
        } message: { Text(t["setup.openFailedBody"]) }
        .disabled(updating)
        .interactiveDismissDisabled(updating)
        .navigationTitle(t["regions.title"])
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(t["common.cancel"]) { dismiss() }.disabled(updating) } }
        .task {
            enabled = model.settings.regionalSubscription.enabled &&
                (!usesLiveRegistration || model.settings.liveRegistrationNeedsRevocation)
            lastAlerts = await model.services.regionalAlerts.latest()
        }
    }

    private func update(_ value: Bool) {
        guard !updating else { return }
        updating = true
        Task {
            defer { updating = false }
            do {
                try await model.setLiveRegistration(enabled: value)
                enabled = value
            } catch {
                model.errorMessage = model.strings[LiveNotificationRegistration.messageKey(error)]
            }
        }
    }
}
