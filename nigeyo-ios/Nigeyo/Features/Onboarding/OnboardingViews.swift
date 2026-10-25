import MapKit
import SwiftUI

enum OnboardingStep: Hashable { case places, destinations, lockScreen }

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var path: [OnboardingStep] = []
    @State private var places = OnboardingModel()

    var body: some View {
        NavigationStack(path: $path) {
            LanguageStepView { path.append(.places) }
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .places:
                        PlacesStepView(places: places, counter: model.strings("common.stepCounter", ["current": "1", "total": "3"]), onBack: { path.removeLast() }) {
                            path.append(.destinations)
                        }
                    case .destinations:
                        DestinationsStepView(places: places, counter: model.strings("common.stepCounter", ["current": "2", "total": "3"]), onBack: { path.removeLast() }) {
                            places.save(to: model.settings)
                            path.append(.lockScreen)
                        }
                    case .lockScreen:
                        LockScreenSetupView(counter: model.strings("common.stepCounter", ["current": "3", "total": "3"]), onBack: { path.removeLast() }) {
                            model.completeOnboarding()
                        }
                    }
                }
        }
    }
}

// MARK: 01 Language

struct LanguageStepView: View {
    @Environment(AppModel.self) private var model
    var onContinue: () -> Void

    var body: some View {
        let t = model.strings
        Screen {
            Text(t["app.name"]).nFont(36, .bold).foregroundStyle(Color.ink).padding(.top, 16)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card).fill(Color.orangeSoft)
                Pictogram(name: "tsunami-evacuate", size: 60)
            }
            .frame(height: 100)
            .padding(.vertical, 8)
            Eyebrow(t["onboarding.language.eyebrow"])
            ScreenTitle(t["onboarding.language.title"])
            BodyText(t["onboarding.language.body"])
            ForEach(model.languages) { lang in
                let selected = lang.id == model.settings.language
                RowCard(title: lang.nativeName, subtitle: nil, accessory: .radio(selected), background: selected ? .orangeSoft : .white) {
                    Task { await model.setLanguage(lang.id) }
                }
            }
        } actions: {
            NButton(t["onboarding.language.continue"], action: onContinue)
            Footnote(t["onboarding.language.footnote"])
        }
    }
}

// MARK: 02 Places

struct PlacesStepView: View {
    @Environment(AppModel.self) private var model
    var places: OnboardingModel
    var counter: String?
    var onBack: () -> Void
    var onNext: () -> Void
    @State private var searching: PlaceContext?

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["onboarding.places.nav"], counter: counter, onBack: onBack) {
            Eyebrow(t["onboarding.places.eyebrow"])
            ScreenTitle(t["onboarding.places.title"])
            BodyText(t["onboarding.places.body"])
            placeRow(.home, icon: "house", title: t["onboarding.places.home"])
            placeRow(.university, icon: "building.columns", title: t["onboarding.places.university"])
            if let first = places.places[.home] ?? places.places[.university] {
                MapPreview(coordinate: first.coordinate, caption: t["destination.mapCaption"], pinLabel: first.title, height: 120)
            }
            BodyText(t["onboarding.places.pinHint"], size: 13)
            NoteCard(title: t["onboarding.places.privacyTitle"], message: t["onboarding.places.privacyBody"])
        } actions: {
            NButton(t["onboarding.places.next"], action: onNext)
            Footnote(t["onboarding.places.footnote"])
        }
        .sheet(item: $searching) { context in
            PlaceSearchSheet(title: context == .home ? t["onboarding.places.home"] : t["onboarding.places.university"], strings: t, initial: places.places[context]?.coordinate) { place in
                places.places[context] = place
                searching = nil
            }
        }
    }

    private func placeRow(_ context: PlaceContext, icon: String, title: String) -> some View {
        let t = model.strings
        let selected = places.places[context]
        return Button { searching = context } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: icon).nFont(17, .bold).foregroundStyle(Color.ink)
                    Text(selected.map { "\(t["onboarding.places.selected"]): \($0.title)" } ?? t["onboarding.places.searchHint"])
                        .nFont(12).foregroundStyle(selected == nil ? Color.muted : Color.green).lineLimit(2)
                }
                Spacer()
                Image(systemName: selected == nil ? "magnifyingglass" : "checkmark.circle.fill").foregroundStyle(selected == nil ? Color.muted : Color.green)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
    }
}

extension PlaceContext: Identifiable {
    var id: String { rawValue }
}

struct PlaceSearchSheet: View {
    var title: String
    var strings: Strings
    var initial: CLLocationCoordinate2D?
    var onPick: (OnboardingModel.Place) -> Void
    @State private var search = PlaceSearchModel()
    @State private var showPin = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(strings["onboarding.places.searchHint"], text: $search.query)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                }
                if search.isSearching { Text(strings["onboarding.places.searching"]).foregroundStyle(Color.muted) }
                if search.noResults { Text(strings["onboarding.places.noResults"]).foregroundStyle(Color.muted) }
                ForEach(search.suggestions, id: \.self) { s in
                    Button {
                        Task {
                            if let c = await search.resolve(s) { onPick(.init(title: s.title, coordinate: c)) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(s.title).foregroundStyle(Color.ink)
                            if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption).foregroundStyle(Color.muted) }
                        }
                    }
                }
                Section {
                    Button { showPin = true } label: { Label(strings["onboarding.places.pinTitle"], systemImage: "mappin.and.ellipse") }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(strings["common.cancel"]) { dismiss() } } }
            .navigationDestination(isPresented: $showPin) {
                PinPickerView(strings: strings, initial: initial) { c in onPick(.init(title: strings["onboarding.places.pinTitle"], coordinate: c)) }
            }
        }
    }
}

/// Fallback when search fails: tap the map to place a pin. The coordinate stays in memory.
struct PinPickerView: View {
    var strings: Strings
    var initial: CLLocationCoordinate2D?
    var onUse: (CLLocationCoordinate2D) -> Void
    @State private var pin: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 12) {
            MapReader { proxy in
                Map(position: $position) {
                    if let pin { Marker(strings["a11y.mapPin"], coordinate: pin).tint(Color.orange) }
                }
                .onTapGesture { point in pin = proxy.convert(point, from: .local) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            NButton(strings["onboarding.places.pinUse"], kind: pin == nil ? .disabled : .primary) { if let pin { onUse(pin) } }
        }
        .padding(16)
        .background(Color.paper)
        .navigationTitle(strings["onboarding.places.pinTitle"])
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let center = initial ?? CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767)
            position = .region(MKCoordinateRegion(center: center, latitudinalMeters: initial == nil ? 30_000 : 2_000, longitudinalMeters: initial == nil ? 30_000 : 2_000))
        }
    }
}

// MARK: 03 Destinations (four slots)

struct DestinationsStepView: View {
    @Environment(AppModel.self) private var model
    var places: OnboardingModel
    var counter: String?
    var onBack: () -> Void
    var onSave: () -> Void

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["onboarding.destinations.nav"], counter: counter, onBack: onBack) {
            Eyebrow(t["onboarding.destinations.eyebrow"])
            ScreenTitle(t["onboarding.destinations.title"])
            BodyText(t["onboarding.destinations.body"])
            if places.isComputing {
                HStack(spacing: 8) { ProgressView(); BodyText(t["onboarding.destinations.loading"], size: 13) }
            }
            ForEach(DestinationSlot.all, id: \.self) { slot in slotCard(slot) }
            BodyText(t["onboarding.destinations.note"], size: 12)
        } actions: {
            NButton(t["onboarding.destinations.save"], kind: places.isComputing ? .disabled : .primary, action: onSave)
        }
        .task { await places.compute(repository: model.services.evacuation) }
    }

    @ViewBuilder private func slotCard(_ slot: DestinationSlot) -> some View {
        let t = model.strings
        let label = t("onboarding.destinations.slot", ["place": t[slot.place == .home ? "onboarding.places.home" : "onboarding.places.university"], "hazard": t["hazard.\(slot.hazard.rawValue)"]])
        Card {
            Text(label).nFont(12, .bold).foregroundStyle(Color.muted)
            switch places.slots[slot] ?? .notSet {
            case .notSet:
                Text(t["onboarding.destinations.notSet"]).nFont(17, .bold).foregroundStyle(Color.muted)
            case .loading:
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            case .noSite:
                Text(t["onboarding.destinations.none"]).nFont(17, .bold).foregroundStyle(Color.ink)
                Text(t["onboarding.destinations.noneBody"]).nFont(12).foregroundStyle(Color.muted)
            case .ready(let candidates, let selected, let walkingUnavailable):
                let c = candidates[selected]
                Text(c.site.name).nFont(17, .bold).foregroundStyle(Color.ink)
                Text(distanceLine(c)).nFont(12).foregroundStyle(Color.muted)
                if walkingUnavailable { Text(t["onboarding.destinations.walkUnavailable"]).nFont(11).foregroundStyle(Color.danger) }
                if candidates.count > 1 {
                    Menu {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { i, cand in
                            Button("\(cand.site.name) · \(distanceLine(cand))") { places.select(slot, index: i) }
                        }
                    } label: {
                        Text(t["onboarding.destinations.change"]).nFont(13, .bold).foregroundStyle(Color.ink).frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private func distanceLine(_ c: OnboardingModel.Candidate) -> String {
        let t = model.strings
        if let w = c.walking { return t("distance.walking", ["distance": t.distance(w)]) }
        return "\(t("distance.straight", ["distance": t.distance(c.straight)])) · \(t["onboarding.destinations.walkFailed"])"
    }
}

// MARK: 04 Lock screen setup (also Settings → Lock screen)

struct LockScreenSetupView: View {
    @Environment(AppModel.self) private var model
    var counter: String?
    var onBack: () -> Void
    var onFinish: () -> Void
    @State private var showShortcuts = false
    @State private var testRunning = false

    var body: some View {
        let t = model.strings
        Screen(navTitle: t["onboarding.lock.nav"], counter: counter, onBack: onBack) {
            Eyebrow(t["onboarding.lock.eyebrow"])
            ScreenTitle(t["onboarding.lock.title"])
            BodyText(t["onboarding.lock.body"])
            Card {
                step(t["onboarding.lock.step1"], t["onboarding.lock.step1Body"])
                notificationStatus
                step(t["onboarding.lock.step2"], t["onboarding.lock.step2Body"])
                step(t["onboarding.lock.step3"], t["onboarding.lock.step3Body"])
            }
            RowCard(title: t["onboarding.lock.shortcuts"], subtitle: nil, accessory: .none) { showShortcuts = true }
            RowCard(title: t["onboarding.lock.liveActivity"], subtitle: model.liveActivitiesEnabled ? t["onboarding.lock.liveActivityBody"] : t["liveActivity.disabled"],
                    accessory: .chevron, background: .greenSoft) {
                Task { await toggleTest() }
            }
            if testRunning { BodyText(t["liveActivity.testTitle"] + " ✓", size: 12) }
            BodyText(t["onboarding.lock.note"], size: 12)
        } actions: {
            NButton(t["onboarding.lock.finish"]) { finish() }
            Button(t["onboarding.lock.later"]) { finish() }.nFont(13).foregroundStyle(Color.muted).frame(minHeight: 44)
        }
        .navigationDestination(isPresented: $showShortcuts) { ShortcutsSetupView { showShortcuts = false } }
        .onDisappear { Task { await model.services.liveActivities.endTest() } }
    }

    private func finish() {
        Task { await model.services.liveActivities.endTest() }
        onFinish()
    }

    private func step(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).nFont(17, .bold).foregroundStyle(Color.ink)
            Text(body).nFont(12).foregroundStyle(Color.muted)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var notificationStatus: some View {
        let t = model.strings
        switch model.notificationAuthorization {
        case .authorized:
            Label(t["onboarding.lock.notificationsAllowed"], systemImage: "checkmark.circle.fill").nFont(13, .bold).foregroundStyle(Color.green)
        case .notDetermined:
            NButton(t["onboarding.lock.step1"].trimmingCharacters(in: CharacterSet.decimalDigits.union(.whitespaces)), kind: .accent) {
                Task { await model.requestNotifications() }
            }
        default:
            Text(t["onboarding.lock.notificationsDenied"]).nFont(12, .bold).foregroundStyle(Color.danger)
            Button(t["home.settings"]) {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            }
            .nFont(13, .bold).frame(minHeight: 44)
        }
    }

    private func toggleTest() async {
        if testRunning {
            await model.services.liveActivities.endTest()
            testRunning = false
            return
        }
        guard let snap = await model.services.registry.snapshot(for: model.settings.language) else { return }
        let sample = GuideSession.new(mode: .training, source: .local, scenario: .earthquake, quake: nil, snapshot: snap)
        testRunning = await model.services.liveActivities.startTest(state: GuideContent.activityState(for: sample, interactive: false))
    }
}
