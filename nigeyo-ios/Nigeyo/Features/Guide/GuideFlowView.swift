import MapKit
import SwiftUI

/// The guide is driven by the saved phase; local navigation only covers the "where are you" sub-steps.
struct GuideFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingEnd = false

    var body: some View {
        Group {
            if let s = model.session {
                switch s.phase {
                case .protect: ProtectView(session: s, onEnd: { confirmingEnd = true })
                case .safetyChecks: SafetyChecksView(session: s, onEnd: { confirmingEnd = true })
                case .tsunamiEvacuate: TsunamiView(session: s, onEnd: { confirmingEnd = true })
                case .choosePlace: ChoosePlaceFlow(session: s)
                case .showDestination:
                    if s.evacuationDecision == .going { OnTheWayView(session: s, onEnd: { confirmingEnd = true }) }
                    else { DestinationView(session: s) }
                case .completed: EmptyView()
                }
            }
        }
        .fullScreenCover(isPresented: $confirmingEnd) {
            if let s = model.session { EndConfirmView(session: s) { confirmingEnd = false } }
        }
    }
}

private extension GuideSession {
    var strings: Strings { Strings(snapshot: languageSnapshot) }
    var badge: String? { mode == .manual ? nil : strings["training.badge"] }
    var badgeLong: String? { mode == .manual ? nil : strings["training.badgeLong"] }
    var endTitle: String { strings[mode == .manual ? "manual.end" : "training.end"] }
}

// MARK: 09 Protect

struct ProtectView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    var onEnd: () -> Void

    var body: some View {
        let t = session.strings
        Screen(background: .orangeSoft) {
            GuideHeader(appName: t["app.name"], badge: session.badge)
            Eyebrow(t["guide.protect.step"]).padding(.top, 8)
            ScreenTitle(t["guide.protect.title"])
            Pictogram(name: "protect-head", size: 180, label: t["a11y.pictogram.protect-head"])
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            Text(t["guide.protect.body"]).nFont(16).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
        } actions: {
            NButton(t["guide.shakingQuestion"]) { Task { await model.confirmShakingStopped() } }
            Footnote(t["guide.shakingHint"])
            NButton(session.endTitle, kind: .secondary, action: onEnd)
        }
    }
}

// MARK: 10 Safety checks (three at once)

struct SafetyChecksView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    var onEnd: () -> Void

    var body: some View {
        let t = session.strings
        Screen {
            GuideHeader(appName: t["app.name"], badge: session.badge)
            Eyebrow(t["guide.checks.step"])
            ScreenTitle(t["guide.checks.title"])
            check("check-surroundings", t["guide.surroundings.title"], t["guide.surroundings.body"], t)
            check("check-fire", t["guide.fire.title"], t["guide.fire.body"], t)
            check("secure-exit", t["guide.exit.title"], t["guide.exit.body"], t)
        } actions: {
            NButton(t["guide.unsafeButton"]) { Task { await model.goToChoosePlace() } }
            Footnote(t["guide.unsafeHint"])
            NButton(session.endTitle, kind: .secondary, action: onEnd)
        }
    }

    private func check(_ picto: String, _ title: String, _ body: String, _ t: Strings) -> some View {
        Card {
            HStack(spacing: 16) {
                Pictogram(name: picto, size: 56, label: t["a11y.pictogram.\(picto)"])
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).nFont(17, .bold).foregroundStyle(Color.ink)
                    Text(body).nFont(12).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 11 Tsunami

struct TsunamiView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    var onEnd: () -> Void

    var body: some View {
        let t = session.strings
        Screen(background: .orange) {
            GuideHeader(appName: t["app.name"], badge: session.badge, dark: true)
            Eyebrow(t[session.mode == .manual ? "guide.tsunami.stepManual" : "guide.tsunami.step"], color: .ink)
            ScreenTitle(t["guide.tsunami.title"], size: 32)
            Pictogram(name: "tsunami-evacuate", size: 180, label: t["a11y.pictogram.tsunami-evacuate"])
                .frame(maxWidth: .infinity).padding(.vertical, 16)
            Text(t["guide.tsunami.body"]).nFont(16).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            if let ts = session.tsunami {
                Text(t("guide.tsunami.sourceInfo", ["time": t.dateTime(ts.issuedAt), "area": ts.area, "grade": GuideContent.gradeText(ts.grade, t)]))
                    .nFont(13, .bold).foregroundStyle(Color.ink)
            }
            if session.mode != .manual {
                Card(background: .orangeSoft) {
                    Text(t["guide.tsunami.drillTitle"]).nFont(14, .bold).foregroundStyle(Color.ink)
                    Text(t["guide.tsunami.drillBody"]).nFont(12).foregroundStyle(Color.ink)
                }
            }
        } actions: {
            NButton(t["guide.tsunami.checkPlaces"]) { Task { await model.goToChoosePlace() } }
            NButton(session.endTitle, kind: .secondary, action: onEnd)
        }
    }
}

// MARK: 12 / 29 Choose place and its sub-steps

enum PlaceStep: Hashable {
    case candidates(PlaceSearchOrigin)
    case none(PlaceContext)
    case pin
}

enum PlaceSearchOrigin: Hashable {
    case currentLocation
    case pinned(latitude: Double, longitude: Double)
}

struct ChoosePlaceFlow: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    @State private var path: [PlaceStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            ChoosePlaceView(session: session, path: $path)
                .navigationDestination(for: PlaceStep.self) { step in
                    switch step {
                    case .candidates(let origin): CandidatesView(session: session, origin: origin, path: $path)
                    case .none(let context): NoCandidatesView(session: session, context: context, path: $path)
                    case .pin:
                        PinPickerView(strings: session.strings, initial: model.lastFix.map { .init(latitude: $0.latitude, longitude: $0.longitude) }) { c in
                            path = [.candidates(.pinned(latitude: c.latitude, longitude: c.longitude))]
                        }
                    }
                }
        }
    }
}

struct ChoosePlaceView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    @Binding var path: [PlaceStep]

    var body: some View {
        let t = session.strings
        let tsunami = session.hazard == .tsunami
        Screen(navTitle: t[tsunami ? "place.navTsunami" : "place.nav"], onBack: { Task { await model.backFromChoosePlace() } }) {
            HStack {
                if let b = session.badgeLong { Badge(text: b) }
                if tsunami { Badge(text: t["place.tsunamiOnly"]) }
            }
            Eyebrow(t["place.eyebrow"])
            ScreenTitle(t["place.title"])
            BodyText(t[tsunami ? "place.bodyTsunami" : "place.body"])
            RowCard(icon: "house", title: t["place.home"], subtitle: t[tsunami ? "place.homeBodyTsunami" : "place.homeBody"]) { pick(.home) }
            RowCard(icon: "building.columns", title: t["place.university"], subtitle: t[tsunami ? "place.universityBodyTsunami" : "place.universityBody"]) { pick(.university) }
            RowCard(icon: "location.circle", title: t["place.other"], subtitle: t[tsunami ? "place.otherBodyTsunami" : "place.otherBody"], background: .orangeSoft) {
                path.append(.candidates(.currentLocation))
            }
            if tsunami { BodyText(t["place.tsunamiNote"], size: 12) }
            else { NoteCard(title: t["place.locationNoteTitle"], message: t["place.locationNoteBody"]) }
        } actions: {
            NButton(t[tsunami ? "place.backToTsunami" : "place.backToChecks"], kind: .secondary) { Task { await model.backFromChoosePlace() } }
        }
    }

    /// Home / school use the saved slot for the current hazard; a tsunami never falls back to an earthquake-only site.
    private func pick(_ context: PlaceContext) {
        guard let site = model.savedDestination(place: context, hazard: session.hazard)?.site, site.supports(session.hazard) else {
            path.append(.none(context))
            return
        }
        Task {
            await model.choose(context: context, candidates: [site.id])
            await model.selectDestination(site.id)
        }
    }
}

// MARK: 13 / 30 Candidates near the current location (straight line only, no routing API)

struct CandidatesView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    var origin: PlaceSearchOrigin
    @Binding var path: [PlaceStep]

    enum LoadState: Equatable { case locating, searching, failed, empty, ready([SiteDistance]) }
    @State private var state: LoadState = .locating
    @State private var selected: String?
    @State private var caution = false

    var body: some View {
        let t = session.strings
        let tsunami = session.hazard == .tsunami
        Group {
            if state == .failed {
                LocationErrorView(session: session, retry: { Task { await load() } }, pin: { path.append(.pin) }, saved: { path = [] })
            } else if state == .empty {
                NoCandidatesView(session: session, context: .other, path: $path)
            } else {
                Screen(navTitle: t[tsunami ? "candidates.navTsunami" : "candidates.nav"], onBack: { path.removeAll() }) {
                    HStack {
                        if let b = session.badgeLong { Badge(text: b) }
                        if tsunami { Badge(text: t["place.tsunamiOnly"]) }
                    }
                    Eyebrow(t[tsunami ? "candidates.eyebrowTsunami" : "candidates.eyebrow"])
                    ScreenTitle(t[tsunami ? "candidates.titleTsunami" : "candidates.title"])
                    BodyText(t[tsunami ? "candidates.bodyTsunami" : "candidates.body"])
                    content(t)
                } actions: {
                    if case .ready = state {
                        NButton(t["candidates.confirm"], kind: selected == nil ? .disabled : .primary) { confirm() }
                    }
                }
            }
        }
        .task(id: origin) { await load() }
    }

    @ViewBuilder private func content(_ t: Strings) -> some View {
        switch state {
        case .locating, .searching:
            HStack(spacing: 12) {
                ProgressView()
                BodyText(t[state == .locating ? "candidates.locating" : "candidates.searching"])
            }
            .padding(.vertical, 24)
        case .ready(let list):
            if let first = list.first { MapPreview(coordinate: first.site.coordinate, caption: t["destination.mapCaption"], pinLabel: first.site.name, height: 120) }
            if caution, let fix = model.lastFix {
                Text(t("candidates.lowAccuracy", ["accuracy": t.distance(max(0, fix.horizontalAccuracy))])).nFont(12, .bold).foregroundStyle(Color.danger)
            }
            ForEach(list) { item in
                Button { selected = item.id } label: {
                    Card(border: selected == item.id ? .ink : nil) {
                        Badge(text: t[session.hazard == .tsunami ? "hazard.tsunamiSupported" : "hazard.earthquakeSupported"], kind: session.hazard == .tsunami ? .drill : .green)
                        Text(item.site.name).nFont(20, .bold).foregroundStyle(Color.ink).padding(.top, 6)
                        Text(t("distance.straight", ["distance": t.distance(item.meters)])).nFont(13).foregroundStyle(Color.muted)
                        Text(item.site.address).nFont(13).foregroundStyle(Color.muted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == item.id ? .isSelected : [])
            }
            BodyText(t["candidates.note"], size: 12)
        default:
            EmptyView()
        }
    }

    private func load() async {
        let lat: Double
        let lon: Double
        switch origin {
        case .currentLocation:
            state = .locating
            do {
                let fix = try await model.location.currentLocation()
                model.lastFix = fix
                caution = fix.needsCaution
                lat = fix.latitude
                lon = fix.longitude
            } catch {
                state = .failed
                return
            }
        case .pinned(let la, let lo):
            model.lastFix = LocationFix(latitude: la, longitude: lo, horizontalAccuracy: 0, age: 0)
            caution = false
            lat = la
            lon = lo
        }
        state = .searching
        guard let list = try? await model.nearest(latitude: lat, longitude: lon, hazard: session.hazard, limit: 2) else { return }
        state = list.isEmpty ? .empty : .ready(list)
        selected = list.first?.id
    }

    private func confirm() {
        guard case .ready(let list) = state, let selected else { return }
        Task {
            await model.choose(context: .other, candidates: list.map(\.id))
            await model.selectDestination(selected)
        }
    }
}

// MARK: 16 Location unavailable

struct LocationErrorView: View {
    var session: GuideSession
    var retry: () -> Void
    var pin: () -> Void
    var saved: () -> Void

    var body: some View {
        let t = session.strings
        Screen(navTitle: t["locationError.nav"], onBack: saved) {
            if let b = session.badgeLong { Badge(text: b) }
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card).fill(Color.orangeSoft)
                Image(systemName: "location.slash").font(.system(size: 56)).foregroundStyle(Color.ink).accessibilityHidden(true)
            }
            .frame(height: 130)
            Eyebrow(t["locationError.eyebrow"])
            ScreenTitle(t["locationError.title"])
            BodyText(t["locationError.body"])
        } actions: {
            NButton(t["locationError.retry"], action: retry)
            NButton(t["locationError.pin"], kind: .secondary, action: pin)
            NButton(t["locationError.saved"], kind: .secondary, action: saved)
            Footnote(t["locationError.note"])
        }
    }
}

// MARK: 23 No candidates

struct NoCandidatesView: View {
    var session: GuideSession
    var context: PlaceContext
    @Binding var path: [PlaceStep]

    var body: some View {
        let t = session.strings
        let tsunami = session.hazard == .tsunami
        Screen(navTitle: t["place.nav"], onBack: { path.removeAll() }) {
            HStack {
                if let b = session.badgeLong { Badge(text: b) }
                if tsunami { Badge(text: t["noCandidates.badgeTsunami"]) }
            }
            Eyebrow(t["noCandidates.eyebrow"])
            ScreenTitle(t["noCandidates.title"])
            BodyText(t("noCandidates.body", ["hazard": t["hazard.\(session.hazard.rawValue)"]]))
            if context != .other { BodyText(t["place.notSaved"], size: 12) }
            Card {
                Pictogram(name: tsunami ? "tsunami-evacuate" : "check-surroundings", size: 72).padding(.bottom, 12)
                Text(t[tsunami ? "noCandidates.cardTitle" : "noCandidates.cardTitleEarthquake"]).nFont(17, .bold).foregroundStyle(Color.ink)
                Text(t["noCandidates.cardBody"]).nFont(13).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            NButton(t["noCandidates.changePlace"]) { path = [.candidates(.currentLocation)] }
            NButton(t["locationError.saved"], kind: .secondary) { path.removeAll() }
        }
    }
}

// MARK: 14 / 31 Destination

struct DestinationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var session: GuideSession
    @State private var site: EvacuationSite?
    @State private var openFailed = false

    var body: some View {
        let t = session.strings
        let tsunami = session.hazard == .tsunami
        Screen(navTitle: t["destination.nav"], onBack: { Task { await model.backToChoosePlace() } }) {
            if let b = session.badgeLong { Badge(text: b) }
            Badge(text: t[tsunami ? "hazard.tsunamiSupported" : "hazard.earthquakeSupported"], kind: tsunami ? .drill : .green)
            if let site {
                ScreenTitle(site.name)
                BodyText(site.address)
                MapPreview(coordinate: site.coordinate, caption: t["destination.mapCaption"], pinLabel: t["a11y.mapPin"])
                if let d = distance(site) {
                    Card {
                        Text(t.distance(d.meters)).nFont(28, .bold).foregroundStyle(Color.ink)
                        Text(d.label).nFont(13).foregroundStyle(Color.muted)
                    }
                }
                BodyText(t["destination.note"], size: 12)
                if openFailed { CopyAddressCard(site: site, strings: t) }
            } else {
                ProgressView()
            }
        } actions: {
            NButton(t["destination.go"], kind: site == nil ? .disabled : .primary) { Task { await model.confirmEvacuation() } }
            NButton(t["destination.openMap"], kind: .secondary) {
                guard let site else { return }
                openURL(GoogleMaps.searchURL(latitude: site.latitude, longitude: site.longitude)) { openFailed = !$0 }
            }
        }
        .task(id: session.selectedDestinationId) {
            if let id = session.selectedDestinationId { site = await model.site(id: id) }
        }
    }

    private func distance(_ site: EvacuationSite) -> (meters: Double, label: String)? {
        let t = session.strings
        if session.selectedPlaceContext == .other, let fix = model.lastFix {
            return (Geo.haversine(fix.latitude, fix.longitude, site.latitude, site.longitude), t["distance.straightLabel"])
        }
        if let ctx = session.selectedPlaceContext, ctx != .other, let saved = model.savedDestination(place: ctx, hazard: session.hazard), let m = saved.meters {
            let kind = saved.distanceKind == .walking ? t("distance.walking", ["distance": ""]).trimmingCharacters(in: .whitespaces) : t["distance.savedLabel"]
            return (m, kind)
        }
        return nil
    }
}

struct CopyAddressCard: View {
    var site: EvacuationSite
    var strings: Strings
    @State private var copied = false

    var body: some View {
        NoteCard(title: strings["destination.openFailed"], message: "\(site.name)\n\(site.address)\n\(site.latitude), \(site.longitude)", tint: .danger, background: .orangeSoft)
        NButton(copied ? strings["common.copied"] : strings["destination.copyAddress"], kind: .secondary) {
            UIPasteboard.general.string = "\(site.name)\n\(site.address)\n\(site.latitude),\(site.longitude)"
            copied = true
        }
    }
}

// MARK: 15 / 32 On your way

struct OnTheWayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var session: GuideSession
    var onEnd: () -> Void
    @State private var site: EvacuationSite?
    @State private var openFailed = false

    var body: some View {
        let t = session.strings
        let tsunami = session.hazard == .tsunami
        Screen(navTitle: t["onTheWay.nav"], onBack: { Task { await model.backToChoosePlace() } }) {
            if let b = session.badgeLong { Badge(text: b) }
            Badge(text: t[tsunami ? "onTheWay.badgeTsunami" : "onTheWay.badge"], kind: tsunami ? .drill : .green)
            Eyebrow(t[tsunami ? "onTheWay.eyebrowTsunami" : "onTheWay.eyebrow"])
            ScreenTitle(t[tsunami ? "onTheWay.titleTsunami" : "onTheWay.title"])
            if let site {
                Card {
                    Text(site.name).nFont(20, .bold).foregroundStyle(Color.ink)
                    Text(site.address).nFont(13).foregroundStyle(Color.muted)
                    Text(t[tsunami ? "hazard.tsunamiSupported" : "hazard.earthquakeSupported"]).nFont(13).foregroundStyle(Color.muted)
                }
                MapPreview(coordinate: site.coordinate, caption: t["destination.mapCaption"], pinLabel: t["a11y.mapPin"], height: 120)
                NoteCard(title: t["onTheWay.mapsTitle"], message: t[tsunami ? "onTheWay.mapsBodyTsunami" : "onTheWay.mapsBody"])
                if openFailed { CopyAddressCard(site: site, strings: t) }
            }
        } actions: {
            NButton(t["onTheWay.openMaps"]) {
                guard let site else { return }
                openURL(GoogleMaps.directionsURL(latitude: site.latitude, longitude: site.longitude)) { openFailed = !$0 }
            }
            NButton(session.endTitle, kind: .secondary, action: onEnd)
        }
        .task(id: session.selectedDestinationId) {
            if let id = session.selectedDestinationId { site = await model.site(id: id) }
        }
    }
}

// MARK: 27 End confirmation

struct EndConfirmView: View {
    @Environment(AppModel.self) private var model
    var session: GuideSession
    var dismiss: () -> Void

    var body: some View {
        let t = session.strings
        let manual = session.mode == .manual
        Screen {
            if let b = session.badgeLong { Badge(text: b).padding(.top, 8) }
            Spacer(minLength: 60)
            Card {
                Text(t[manual ? "endConfirm.titleManual" : "endConfirm.title"]).nFont(22, .bold).foregroundStyle(Color.ink).padding(.bottom, 8)
                Text(t[manual ? "endConfirm.bodyManual" : "endConfirm.body"]).nFont(15).foregroundStyle(Color.muted).padding(.bottom, 8)
                Text(t[manual ? "endConfirm.safety" : "endConfirm.wallpaper"]).nFont(13).foregroundStyle(Color.muted)
            }
        } actions: {
            NButton(t[manual ? "endConfirm.endManual" : "endConfirm.end"]) {
                Task {
                    await model.endSession()
                    dismiss()
                }
            }
            NButton(t[manual ? "endConfirm.keepManual" : "endConfirm.keep"], kind: .secondary, action: dismiss)
        }
    }
}
