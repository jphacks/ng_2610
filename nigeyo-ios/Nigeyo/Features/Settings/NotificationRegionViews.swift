import SwiftUI

/// Small, isolated editor; the UI branch can restyle it without changing the contract or monitor.
struct NotificationRegionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: NotificationRegion] = [:]
    @State private var enabled = false
    @State private var lastAlerts: [String: RegionalAlert] = [:]
    private let table = NotificationRegionTable.shared

    private var registered: [DestinationSlot] { DestinationSlot.all.filter { model.settings.destination($0)?.site != nil } }
    private var ready: Bool { !registered.isEmpty && registered.allSatisfy { drafts[$0.key]?.isReady == true } }

    var body: some View {
        let t = model.strings
        Form {
            Section {
                Text(t["regions.body"])
                Text(t["regions.connection"]).font(.footnote)
                Toggle(t["regions.enabled"], isOn: $enabled).disabled(!ready)
                if !ready { Text(t["regions.needsConfirmation"]).foregroundStyle(.secondary) }
            }
            ForEach(registered, id: \.self) { slot in
                if let region = drafts[slot.key], let site = model.settings.destination(slot)?.site {
                    Section {
                        Text(site.name)
                        Text(site.address).font(.caption)
                        Picker(t["regions.earthquake"], selection: earthquakeBinding(slot)) {
                            Text(t["regions.unconfigured"]).tag("")
                            ForEach(table.earthquakeAreas, id: \.name) { area in Text(area.name).tag(area.name) }
                        }
                        Picker(t["regions.tsunami"], selection: tsunamiBinding(slot)) {
                            Text(t["regions.unconfigured"]).tag("unconfigured")
                            Text(t["regions.none"]).tag("none")
                            ForEach(table.tsunamiAreas, id: \.self) { Text($0).tag($0) }
                            Text(table.tsunamiAreas.joined(separator: " / ")).tag("both")
                        }
                        Text(t["regions.noneNote"]).font(.caption)
                        Toggle(t["regions.confirm"], isOn: confirmationBinding(slot))
                            .disabled(region.earthquakeArea == nil || region.tsunamiStatus == "unconfigured")
                    } header: {
                        Text("\(t[slot.place == .home ? "onboarding.places.home" : "onboarding.places.university"]) · \(t["hazard.\(slot.hazard.rawValue)"])")
                    }
                }
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
            Section {
                Button(t["regions.save"]) {
                    model.settings.notificationRegions = drafts
                    model.settings.regionalMonitoringEnabled = enabled && ready
                    Task { await model.services.delivery.sendHello() }
                    dismiss()
                }
            }
        }
        .navigationTitle(t["regions.title"])
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(t["common.cancel"]) { dismiss() } } }
        .task {
            drafts = Dictionary(uniqueKeysWithValues: registered.compactMap { slot in model.settings.region(for: slot).map { (slot.key, $0) } })
            enabled = model.settings.regionalSubscription.enabled
            lastAlerts = await model.services.regionalAlerts.latest()
        }
    }

    private func earthquakeBinding(_ slot: DestinationSlot) -> Binding<String> {
        Binding(get: { drafts[slot.key]?.earthquakeArea?.name ?? "" }, set: { name in
            drafts[slot.key]?.earthquakeArea = table.earthquakeAreas.first { $0.name == name }
            drafts[slot.key]?.confirmed = false
            enabled = false
        })
    }
    private func tsunamiBinding(_ slot: DestinationSlot) -> Binding<String> {
        Binding(get: {
            guard let d = drafts[slot.key] else { return "unconfigured" }
            return d.tsunamiStatus == "configured" ? (d.tsunamiAreas.count == 2 ? "both" : d.tsunamiAreas.first ?? "unconfigured") : d.tsunamiStatus
        }, set: { choice in
            drafts[slot.key]?.tsunamiStatus = ["none", "unconfigured"].contains(choice) ? choice : "configured"
            drafts[slot.key]?.tsunamiAreas = choice == "both" ? table.tsunamiAreas : table.tsunamiAreas.contains(choice) ? [choice] : []
            drafts[slot.key]?.confirmed = false
            enabled = false
        })
    }
    private func confirmationBinding(_ slot: DestinationSlot) -> Binding<Bool> {
        Binding(get: { drafts[slot.key]?.confirmed ?? false }, set: { value in
            drafts[slot.key]?.confirmed = value
            if !value { enabled = false }
        })
    }
}

struct NotificationRegionSuggestion: View {
    var site: EvacuationSite
    @Environment(AppModel.self) private var model
    var body: some View {
        let r = NotificationRegionTable.shared.suggest(site: site)
        let t = model.strings
        VStack(alignment: .leading, spacing: 4) {
            Text("\(t["regions.earthquake"]): \(r.earthquakeArea?.name ?? t["regions.unconfigured"])")
            Text("\(t["regions.tsunami"]): \(r.tsunamiStatus == "none" ? t["regions.none"] : r.tsunamiAreas.isEmpty ? t["regions.unconfigured"] : r.tsunamiAreas.joined(separator: ", "))")
            Text(t["regions.afterSave"])
        }.font(.caption).foregroundStyle(.secondary)
    }
}
