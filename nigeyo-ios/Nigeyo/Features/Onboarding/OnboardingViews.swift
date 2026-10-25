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
    // settings.language lives in UserDefaults, which SwiftUI cannot observe; the highlight follows the
    // tapped id immediately and otherwise the language whose strings are on screen.
    @State private var tapped: LanguageID?

    var body: some View {
        let t = model.strings
        let current = tapped ?? t.languageId
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
                let selected = lang.id == current
                RowCard(title: lang.nativeName, subtitle: nil, accessory: .radio(selected), background: selected ? .orangeSoft : .white) {
                    tapped = lang.id
                    Task { await model.setLanguage(lang.id) }
                }
            }
            Footnote(t["onboarding.language.more"])
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
            if let p = places.places[.home] { MapPreview(coordinate: p.coordinate, caption: t["destination.mapCaption"], pinLabel: t["onboarding.places.home"], height: 120) }
            placeRow(.university, icon: "building.columns", title: t["onboarding.places.university"])
            if let p = places.places[.university] { MapPreview(coordinate: p.coordinate, caption: t["destination.mapCaption"], pinLabel: t["onboarding.places.university"], height: 120) }
            BodyText(t["onboarding.places.pinHint"], size: 13)
            NoteCard(title: t["onboarding.places.privacyTitle"], message: t["onboarding.places.privacyBody"])
        } actions: {
            NButton(t["onboarding.places.next"], action: onNext)
            Footnote(t["onboarding.places.footnote"])
        }
        .sheet(item: $searching) { context in
            PlaceSearchSheet(title: context == .home ? t["onboarding.places.home"] : t["onboarding.places.university"], strings: t) { place in
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
    var onPick: (OnboardingModel.Place) -> Void
    @State private var search = PlaceSearchModel()
    @State private var pin: CLLocationCoordinate2D?
    @State private var center = CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767)
    @State private var meters: Double = 30_000
    @State private var pickedTitle: String?
    @Environment(\.dismiss) private var dismiss

    /// Map first: the map fills the sheet, the search box floats on top. A search result moves the
    /// camera and the pin there; tap anywhere to adjust before saving.
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                PinMap(center: center, meters: meters, pinTitle: title, pin: $pin)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 8) {
                    TextField(strings["onboarding.places.searchHint"], text: $search.query)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.card))
                    if search.isSearching || search.noResults || !search.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            if search.isSearching { Text(strings["onboarding.places.searching"]).foregroundStyle(Color.muted).padding(12) }
                            if search.noResults { Text(strings["onboarding.places.noResults"]).foregroundStyle(Color.muted).padding(12) }
                            ForEach(search.suggestions, id: \.self) { s in
                                Button {
                                    Task {
                                        if let c = await search.resolve(s) {
                                            pickedTitle = s.title
                                            meters = 800
                                            center = c
                                            pin = c
                                            search.clear()
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(s.title).foregroundStyle(Color.ink)
                                        if !s.subtitle.isEmpty { Text(s.subtitle).font(.caption).foregroundStyle(Color.muted) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                }
                                Divider()
                            }
                        }
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                NButton(strings["onboarding.places.pinUse"], kind: pin == nil ? .disabled : .primary) {
                    if let pin { onPick(.init(title: pickedTitle ?? strings["onboarding.places.pinTitle"], coordinate: pin)) }
                }
                .padding(16)
                .background(Color.paper)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(strings["common.cancel"]) { dismiss() } } }
            .task {
                guard let fix = try? await LocationService().currentLocation() else { return }
                let here = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
                meters = 1_500
                center = here
                if pin == nil { pin = here }
            }
        }
    }
}

/// Apple Maps with a tap-to-place pin; the camera re-centres whenever `center` changes.
struct PinMap: View {
    var center: CLLocationCoordinate2D
    var meters: Double
    var pinTitle: String
    @Binding var pin: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                if let pin { Marker(pinTitle, coordinate: pin).tint(Color.orange) }
            }
            .mapControls { MapUserLocationButton() }
            .onTapGesture { point in pin = proxy.convert(point, from: .local) }
        }
        .onChange(of: [center.latitude, center.longitude, meters], initial: true) { _, _ in
            position = .region(MKCoordinateRegion(center: center, latitudinalMeters: meters, longitudinalMeters: meters))
        }
    }
}

/// Places or adjusts a pin. Starts at `initial` or else the current location; tap to move the pin.
/// The coordinate stays in memory.
struct PinPickerView: View {
    var strings: Strings
    var initial: CLLocationCoordinate2D?
    var onUse: (CLLocationCoordinate2D) -> Void
    @State private var pin: CLLocationCoordinate2D?
    @State private var center: CLLocationCoordinate2D
    @State private var meters: Double

    init(strings: Strings, initial: CLLocationCoordinate2D?, onUse: @escaping (CLLocationCoordinate2D) -> Void) {
        self.strings = strings
        self.initial = initial
        self.onUse = onUse
        _pin = State(initialValue: initial)
        _center = State(initialValue: initial ?? CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767))
        _meters = State(initialValue: initial == nil ? 30_000 : 800)
    }

    var body: some View {
        VStack(spacing: 12) {
            PinMap(center: center, meters: meters, pinTitle: strings["a11y.mapPin"], pin: $pin)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            NButton(strings["onboarding.places.pinUse"], kind: pin == nil ? .disabled : .primary) { if let pin { onUse(pin) } }
        }
        .padding(16)
        .background(Color.paper)
        .navigationTitle(strings["onboarding.places.pinTitle"])
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard initial == nil, let fix = try? await LocationService().currentLocation() else { return }
            let here = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
            meters = 1_500
            center = here
            if pin == nil { pin = here }
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
                NotificationRegionSuggestion(site: c.site)
                Text(distanceLine(c)).nFont(12).foregroundStyle(Color.muted)
                MapPreview(coordinate: c.site.coordinate, caption: t["destination.mapCaption"], pinLabel: c.site.name, height: 120)
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
        if let w = c.walking { return t.walking(meters: w, seconds: c.walkingSeconds) }
        return "\(t("distance.straight", ["distance": t.distance(c.straight)])) · \(t["onboarding.destinations.walkFailed"])"
    }
}

// MARK: 04 Lock screen setup (also Settings → Lock screen)

struct LockScreenSetupView: View {
    var counter: String?
    var onBack: () -> Void
    var onFinish: () -> Void

    var body: some View {
        ShortcutsSetupView(onDone: onFinish, onBack: onBack, allowsSkip: true)
    }
}
