import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NigeyoLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        NigeyoLiveActivityWidget()
    }
}

private extension Color {
    static let ink = Color(red: 0x20 / 255, green: 0x24 / 255, blue: 0x1F / 255)
    static let paper = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    static let orangeSoft = Color(red: 1, green: 0xE7 / 255, blue: 0xD9 / 255)
    static let drillRed = Color(red: 0xB3 / 255, green: 0x36 / 255, blue: 0x1B / 255)
}

/// No server access, no location, no session file: everything comes from ContentState (spec §13.4).
struct NigeyoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NigeyoActivityAttributes.self) { context in
            LockScreenView(sessionId: context.attributes.sessionId, state: context.state)
                .activityBackgroundTint(Color.paper)
                .activitySystemActionForegroundColor(Color.ink)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(s.appName).font(.caption.bold())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let badge = s.badge { Text(badge).font(.caption.bold()).foregroundStyle(Color.orangeSoft) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        PictogramRow(state: s, size: 40, tint: .white, labelColor: .white)
                        ActionButton(sessionId: context.attributes.sessionId, state: s, inverted: true)
                    }
                }
            } compactLeading: {
                Pict(name: s.pictograms.first ?? "protect-head", size: 20, tint: .ink)
                    .padding(3)
                    .background(Circle().fill(Color.orangeSoft))
            } compactTrailing: {
                Text(s.compactLabel).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
            } minimal: {
                Pict(name: s.pictograms.first ?? "protect-head", size: 18, tint: .ink)
                    .padding(3)
                    .background(Circle().fill(Color.orangeSoft))
            }
            .keylineTint(Color.orangeSoft)
        }
    }
}

struct Pict: View {
    var name: String
    var size: CGFloat
    var tint: Color

    var body: some View {
        Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size).foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

struct PictogramRow: View {
    var state: NigeyoActivityAttributes.ContentState
    var size: CGFloat
    var tint: Color = .ink
    var labelColor: Color = .ink

    var body: some View {
        if state.layout == .checks {
            // The three checks side by side, same size, short labels (spec §13.6).
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(zip(state.pictograms, state.labels)), id: \.0) { name, label in
                    VStack(spacing: 4) {
                        Pict(name: name, size: size, tint: tint)
                        Text(label).font(.caption2.bold()).foregroundStyle(labelColor).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            HStack(spacing: 12) {
                Pict(name: state.pictograms.first ?? "protect-head", size: size, tint: tint)
                Text(state.headline).font(.subheadline.bold()).foregroundStyle(labelColor).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }
}

struct ActionButton: View {
    var sessionId: String
    var state: NigeyoActivityAttributes.ContentState
    var inverted = false

    private var label: some View {
        Text(state.buttonTitle)
            .font(.footnote.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(inverted ? Color.ink : .white)
            .background(inverted ? Color.orangeSoft : Color.ink, in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        if !state.interactive {
            label
        } else if state.layout == .protect {
            // Only a non-sensitive step forward; the app verifies session and revision before saving.
            Button(intent: ConfirmShakingStoppedIntent(sessionId: sessionId, expectedRevision: state.stateRevision)) { label }
                .buttonStyle(.plain)
        } else {
            // "安全でないと感じたら" / "避難場所を確認": a link into the app (OS decides on unlock).
            Link(destination: NigeyoDeepLink.evacuation(sessionId: sessionId)) { label }
        }
    }
}

struct LockScreenView: View {
    var sessionId: String
    var state: NigeyoActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.appName).font(.caption.bold()).foregroundStyle(Color.ink)
                Spacer()
                if let badge = state.badge { Text(badge).font(.caption2.bold()).foregroundStyle(Color.drillRed) }
            }
            PictogramRow(state: state, size: state.layout == .checks ? 40 : 44)
            ActionButton(sessionId: sessionId, state: state)
        }
        .padding(12)
    }
}
