import SwiftUI

// MARK: - Design tokens

/// Central design system for VibeRouter.
///
/// Direction: an instrument panel for quota. Graphite surfaces that stay out of
/// the way, one cobalt accent for the primary action and selection, and color
/// reserved for data: provider series and quota state. Depth comes from surface
/// steps and hairlines, not glass, glows or gradients. Colors live in `Palette`
/// and resolve per appearance, so light and dark share one set of names.
enum DS {
    /// 4-pt rhythm, with a 2-pt step for nudges inside small controls.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 28
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let pill: CGFloat = 999
    }

    /// One ease-out curve, two durations. No springs that overshoot.
    /// Every animated call site should check `accessibilityReduceMotion`.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.14)
        static let smooth = Animation.easeOut(duration: 0.24)
        static let spring = Animation.easeOut(duration: 0.24)
        static let springSnappy = Animation.easeOut(duration: 0.18)
        static let expand = Animation.easeOut(duration: 0.22)
    }

    /// Figures are tabular everywhere so columns of numbers line up.
    enum Font {
        static let label = SwiftUI.Font.system(size: 11, weight: .regular)
        static let meta = SwiftUI.Font.system(size: 11, weight: .regular).monospacedDigit()
        static let figure = SwiftUI.Font.system(size: 20, weight: .medium).monospacedDigit()
        static let display = SwiftUI.Font.system(size: 30, weight: .medium).monospacedDigit()
    }
}

// MARK: - Live status dot

/// The proxy's live dot: the product's one signature detail. A solid dot with a
/// thin ring when live, a hollow muted ring when stopped. No looping pulse.
struct PulsingDot: View {
    var color: Color
    var active: Bool = true
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(active ? color.opacity(0.35) : Palette.textMuted, lineWidth: 1)
                .frame(width: size + 6, height: size + 6)
            if active {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Segmented tab bar

/// Segmented control on a sunken track. The selected segment is one surface step
/// up with a hairline, and slides with a short ease-out.
struct SegmentedTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String
    var icon: (Tab) -> String? = { _ in nil }
    var accent: Color = Palette.accent

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(for: tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceSunken)
        )
    }

    private func segment(for tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            if reduceMotion {
                selection = tab
            } else {
                withAnimation(DS.Motion.springSnappy) { selection = tab }
            }
        } label: {
            HStack(spacing: 6) {
                if let symbol = icon(tab) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                }
                Text(title(tab))
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            }
            .foregroundStyle(isSelected ? Palette.text : Palette.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(indicator(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func indicator(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .matchedGeometryEffect(id: "tab.indicator", in: namespace)
        }
    }
}

// MARK: - Section header

/// Section title with an optional muted icon, subtitle and trailing accessory.
/// Icons take the text color; they never get their own chip or tint.
struct SectionHeaderLabel<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var tint: Color = Palette.accent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.sm)
            trailing()
        }
    }
}

extension SectionHeaderLabel where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color = Palette.accent) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, trailing: { EmptyView() })
    }
}

// MARK: - Stat tile

/// A label, a figure and what the figure compares to. Nothing else.
struct StatTile: View {
    let label: String
    let value: String
    var sublabel: String? = nil
    var systemImage: String? = nil
    var tint: Color = Palette.accent
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(DS.Font.figure)
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sublabel, !sublabel.isEmpty {
                Text(sublabel)
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .padding(DS.Space.lg)
        .cardSurface(tint: tint)
    }
}

// MARK: - Hover highlight modifier

/// Hover lifts the hairline a step. Purely rendering, so no layout shift.
struct HoverHighlight: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = DS.Radius.md
    var lineWidth: CGFloat = 1
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.text.opacity(hovering ? 0.16 : 0), lineWidth: lineWidth)
            )
            .animation(DS.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Raises a card's hairline on pointer hover. Use on cards and list rows.
    func hoverHighlight(_ tint: Color, cornerRadius: CGFloat = DS.Radius.md, lineWidth: CGFloat = 1) -> some View {
        modifier(HoverHighlight(tint: tint, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }

    /// Sets the macOS pointing-hand cursor while hovering (for custom tap targets).
    ///
    /// Uses `set()`, not `push()`/`pop()`. SwiftUI `.onHover` fires `false` on appear
    /// and races across adjacent buttons; `NSCursor.pop()` with an empty stack raises
    /// `NSInternalInconsistencyException` and kills the menu-bar app.
    func pointerCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            guard enabled else { return }
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Card surface: one step up from the panel with a hairline, identical on
    /// every macOS version. `tint` is accepted for call-site compatibility only.
    func cardSurface(tint: Color, cornerRadius: CGFloat = MenuBarDesign.cardCornerRadius) -> some View {
        background(GlassCardBackground(tint: tint, cornerRadius: cornerRadius))
    }
}

// MARK: - Button styles

/// Filled primary action. Hover deepens a step; press scales to 0.98.
struct ProminentActionButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint, fullWidth: fullWidth)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        let fullWidth: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, DS.Space.lg)
                .frame(height: 28)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(hovering ? 0.08 : 0))
                        )
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(DS.Motion.quick, value: hovering)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Bordered secondary action on the surface. Hover fills one surface step.
struct SoftActionButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, DS.Space.lg)
                .frame(height: 28)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.surfaceSunken : Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(DS.Motion.quick, value: hovering)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Compact icon button. Muted at rest; hover shows a sunken square and text color.
struct IconActionButtonStyle: ButtonStyle {
    /// Applied on hover only, so destructive actions (Quit) still read as such.
    var tint: Color = Palette.text

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? tint : Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Palette.surfaceSunken : Color.clear)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(DS.Motion.quick, value: hovering)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
