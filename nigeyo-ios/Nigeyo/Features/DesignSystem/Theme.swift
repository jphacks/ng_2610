import MapKit
import SwiftUI

/// Figma "Nigeyo / Essentials" tokens.
extension Color {
    static let paper = Color(hex: 0xF7F6F0)
    static let ink = Color(hex: 0x20241F)
    static let muted = Color(hex: 0x656A62)
    static let line = Color(hex: 0xDADCD2)
    static let orange = Color(hex: 0xFF6B35)
    static let orangeSoft = Color(hex: 0xFFE7D9)
    static let green = Color(hex: 0x315D45)
    static let greenSoft = Color(hex: 0xE6EDE2)
    static let danger = Color(hex: 0xB3361B)

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Radius {
    static let button: CGFloat = 12
    static let card: CGFloat = 20
}

/// Fixed design sizes (36·28·20·17·16·14·12) that still follow Dynamic Type.
private struct ScaledFont: ViewModifier {
    @ScaledMetric var size: CGFloat
    var weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    func nFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        let style: Font.TextStyle = size >= 26 ? .title : size >= 20 ? .title3 : size >= 16 ? .body : size >= 14 ? .subheadline : .caption
        return modifier(ScaledFont(size: size, weight: weight, relativeTo: style))
    }
}

// MARK: - Buttons (Figma Nigeyo/Button: 44pt minimum, main actions 56pt)

enum NButtonStyleKind {
    case primary, accent, secondary, destructive, disabled
}

struct NButtonStyle: ButtonStyle {
    var kind: NButtonStyleKind

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = switch kind {
        case .primary: (.ink, .white)
        case .accent: (.orange, .ink)
        case .secondary: (.white, .ink)
        case .destructive: (.orangeSoft, .danger)
        case .disabled: (.line, .muted)
        }
        configuration.label
            .nFont(15, .bold)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: Radius.button))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.button))
    }
}

struct NButton: View {
    var title: String
    var kind: NButtonStyleKind = .primary
    var action: () -> Void

    init(_ title: String, kind: NButtonStyleKind = .primary, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(NButtonStyle(kind: kind))
            .disabled(kind == .disabled)
    }
}

// MARK: - Text

struct Eyebrow: View {
    var text: String
    var color: Color = .muted
    init(_ text: String, color: Color = .muted) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).nFont(12, .bold).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScreenTitle: View {
    var text: String
    var size: CGFloat = 28
    init(_ text: String, size: CGFloat = 28) {
        self.text = text
        self.size = size
    }
    var body: some View {
        Text(text).nFont(size, .bold).foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
}

struct BodyText: View {
    var text: String
    var size: CGFloat = 14
    init(_ text: String, size: CGFloat = 14) {
        self.text = text
        self.size = size
    }
    var body: some View {
        Text(text).nFont(size).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

struct Footnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).nFont(12).foregroundStyle(Color.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
}

// MARK: - Badges

struct Badge: View {
    enum Kind { case drill, green, danger, dark }
    var text: String
    var kind: Kind = .drill

    var body: some View {
        let (bg, fg): (Color, Color) = switch kind {
        case .drill: (.orangeSoft, .ink)
        case .green: (.greenSoft, .green)
        case .danger: (.orangeSoft, .danger)
        case .dark: (.ink, .white)
        }
        Text(text).nFont(11, .bold).foregroundStyle(fg)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(bg, in: Capsule())
    }
}

// MARK: - Cards and rows

struct Card<Content: View>: View {
    var background: Color = .white
    var border: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay {
                if let border { RoundedRectangle(cornerRadius: Radius.card).strokeBorder(border, lineWidth: 2) }
            }
    }
}

struct NoteCard: View {
    var title: String
    var message: String
    var tint: Color = .green
    var background: Color = .greenSoft

    var body: some View {
        Card(background: background) {
            Text(title).nFont(14, .bold).foregroundStyle(tint)
            Text(message).nFont(12).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RowCard: View {
    enum Accessory { case chevron, external, radio(Bool), refresh, none }
    var icon: String? = nil
    var title: String
    var subtitle: String?
    var accessory: Accessory = .chevron
    var background: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let icon { Image(systemName: icon).nFont(15, .semibold) }
                        Text(title).nFont(17, .bold)
                    }
                    .foregroundStyle(Color.ink)
                    if let subtitle { Text(subtitle).nFont(12).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessoryView
            }
            .padding(16)
            .frame(minHeight: 64)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isSelected: Bool {
        if case .radio(true) = accessory { return true }
        return false
    }

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .chevron: Image(systemName: "chevron.right").foregroundStyle(Color.muted).accessibilityHidden(true)
        case .external: Image(systemName: "arrow.up.right").foregroundStyle(Color.muted).accessibilityHidden(true)
        case .refresh: Image(systemName: "arrow.clockwise").foregroundStyle(Color.muted).accessibilityHidden(true)
        case .radio(let on):
            ZStack {
                Circle().strokeBorder(Color.muted, lineWidth: 1.5).frame(width: 20, height: 20)
                if on { Circle().fill(Color.muted).frame(width: 18, height: 18) }
            }
            .accessibilityHidden(true)
        case .none: EmptyView()
        }
    }
}

// MARK: - Pictograms (shared by every language, spec §11.1)

struct Pictogram: View {
    var name: String
    var size: CGFloat
    var color: Color = .ink
    var label: String?

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
    }
}

// MARK: - Layout

/// Phone screen scaffold: optional back header, scrolling content, pinned bottom actions.
struct Screen<Content: View, Actions: View>: View {
    var background: Color = .paper
    var navTitle: String? = nil
    var counter: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            if navTitle != nil || onBack != nil {
                HStack(spacing: 12) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left").nFont(17, .semibold).foregroundStyle(Color.ink).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text(verbatim: "Back"))
                    }
                    if let navTitle { Text(navTitle).nFont(15, .bold).foregroundStyle(Color.ink) }
                    Spacer()
                    if let counter { Text(counter).nFont(12).foregroundStyle(Color.muted) }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 12) { actions }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// "nigeyo" wordmark with the training badge (kept visible in every drill state).
struct GuideHeader: View {
    var appName: String
    var badge: String?
    var dark = false

    var body: some View {
        HStack {
            Text(appName).nFont(22, .bold).foregroundStyle(Color.ink)
            Spacer()
            if let badge { Badge(text: badge, kind: dark ? .dark : .drill) }
        }
        .padding(.top, 8)
    }
}

/// Facility position preview. For confirmation only: no routing (spec §15.3).
struct MapPreview: View {
    var coordinate: CLLocationCoordinate2D
    var caption: String
    var pinLabel: String
    var height: CGFloat = 200

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)), interactionModes: []) {
                Marker(pinLabel, coordinate: coordinate).tint(Color.orange)
            }
            .background(Color.greenSoft)
            Text(caption).nFont(10).foregroundStyle(Color.muted).padding(8)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pinLabel)
    }
}
