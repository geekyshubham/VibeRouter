import SwiftUI

// MARK: - Design tokens

/// Central design system for VibeRouter.
///
/// Builds on the brand tokens in `MenuBarDesign` (indigo-violet accent, glass
/// surfaces) with a consistent spacing / radius / motion scale and a small set of
/// reusable, hover-aware components shared by the menu-bar panel and the Settings
/// window. Keeping these in one place is what lets the two surfaces feel like the
/// same product instead of two different apps.
enum DS {
    /// 2-pt based spacing rhythm. Use these instead of ad-hoc magic numbers.
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

    /// Motion tokens. Exponential ease-out / gentle springs only — no bounce.
    /// Every animated call site should check `accessibilityReduceMotion`.
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.16)
        static let smooth = Animation.easeInOut(duration: 0.26)
        static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
        static let springSnappy = Animation.spring(response: 0.32, dampingFraction: 0.80)
        static let expand = Animation.spring(response: 0.36, dampingFraction: 0.86)
    }
}

// MARK: - Pulsing status dot

/// A status dot that gently pulses a soft halo when `active` (e.g. the proxy is
/// running). Respects Reduce Motion by rendering a static dot.
struct PulsingDot: View {
    var color: Color
    var active: Bool = true
    var size: CGFloat = 9

    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size, height: size)
                    .scaleEffect(animating ? 2.4 : 1)
                    .opacity(animating ? 0 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: active ? color.opacity(0.6) : .clear, radius: active ? 4 : 0)
        }
        .frame(width: size * 2.6, height: size * 2.6)
        .onAppear {
            guard active, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
    }
}

// MARK: - Segmented tab bar (sliding indicator)

/// A polished segmented control with a sliding, spring-animated selection pill
/// (via `matchedGeometryEffect`) and optional SF Symbol icons. Reusable for both
/// the panel tabs and the Settings panes so the two surfaces share one language.
struct SegmentedTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String
    var icon: (Tab) -> String? = { _ in nil }
    var accent: Color = MenuBarDesign.accent

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(for: tab)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
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
            HStack(spacing: 5) {
                if let symbol = icon(tab) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title(tab))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? accent : Color.secondary)
            .lineLimit(1)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(indicator(isSelected: isSelected))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func indicator(isSelected: Bool) -> some View {
        if isSelected {
            if #available(macOS 26.0, *) {
                Capsule(style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(accent.opacity(0.45)), in: Capsule(style: .continuous))
                    .matchedGeometryEffect(id: "tab.indicator", in: namespace)
            } else {
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.16))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(accent.opacity(0.30), lineWidth: 0.75)
                    )
                    .matchedGeometryEffect(id: "tab.indicator", in: namespace)
            }
        }
    }
}

// MARK: - Section header

/// A consistent section header: a small tinted icon chip, a title, an optional
/// subtitle, and an optional trailing accessory. Replaces one-off `Text(...).font(.caption)`
/// section labels so hierarchy reads the same everywhere.
struct SectionHeaderLabel<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var tint: Color = MenuBarDesign.accent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.14))
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.sm)
            trailing()
        }
    }
}

extension SectionHeaderLabel where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color = MenuBarDesign.accent) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, trailing: { EmptyView() })
    }
}

// MARK: - Stat tile

/// A single metric tile (label + big rounded value + optional sublabel). Animates
/// numeric changes. Used across the overview strip and analytics dashboard.
struct StatTile: View {
    let label: String
    let value: String
    var sublabel: String? = nil
    var systemImage: String? = nil
    var tint: Color = MenuBarDesign.accent
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sublabel, !sublabel.isEmpty {
                Text(sublabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .padding(DS.Space.lg)
        .cardSurface(tint: tint)
    }
}

// MARK: - Hover highlight modifier

/// Adds a subtle tinted border that fades in on hover. Purely rendering (no layout
/// shift), so it's safe inside dense scroll views.
struct HoverHighlight: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat = DS.Radius.md
    var lineWidth: CGFloat = 1
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(hovering ? 0.5 : 0), lineWidth: lineWidth)
            )
            .animation(DS.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Fades in a tinted border on pointer hover. Use on cards and list rows.
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

// MARK: - Liquid Glass surfaces

extension View {
    /// A card/tile surface that uses Apple's **Liquid Glass** (`.glassEffect`) on
    /// macOS 26+ and falls back to the layered material glass (`GlassCardBackground`)
    /// on earlier systems. Same rounded shape and brand tint on both paths, so the
    /// layout is identical — only the material differs by OS.
    @ViewBuilder
    func cardSurface(tint: Color, cornerRadius: CGFloat = MenuBarDesign.cardCornerRadius) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(tint.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(GlassCardBackground(tint: tint))
        }
    }
}

// MARK: - Button styles

/// Filled, prominent action (primary CTA). Hover brightens; press dims + shrinks.
struct ProminentActionButtonStyle: ButtonStyle {
    var tint: Color = MenuBarDesign.accent
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
            let label = configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm + 1)
                .frame(maxWidth: fullWidth ? .infinity : nil)

            if #available(macOS 26.0, *) {
                label
                    .glassEffect(.regular.tint(tint).interactive(), in: Capsule(style: .continuous))
                    .opacity(isEnabled ? 1 : 0.5)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .contentShape(Capsule(style: .continuous))
            } else {
                label
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(hovering ? 1.0 : 0.95), tint.opacity(hovering ? 0.86 : 0.78)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: tint.opacity(isEnabled ? 0.35 : 0), radius: hovering ? 8 : 5, y: 2)
                    )
                    .opacity(isEnabled ? 1 : 0.5)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .animation(DS.Motion.quick, value: hovering)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .onHover { hovering = $0 }
                    .contentShape(Capsule(style: .continuous))
            }
        }
    }
}

/// Subtle, bordered secondary action. Hover fills a soft tint.
struct SoftActionButtonStyle: ButtonStyle {
    var tint: Color = MenuBarDesign.accent
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
            let label = configuration.label
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.sm + 1)
                .frame(maxWidth: fullWidth ? .infinity : nil)

            if #available(macOS 26.0, *) {
                label
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                    .opacity(isEnabled ? 1 : 0.45)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .contentShape(Capsule(style: .continuous))
            } else {
                label
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? tint : Color.primary.opacity(0.9))
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(hovering ? 0.16 : 0.001))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        hovering ? tint.opacity(0.45) : Color.primary.opacity(0.14),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .opacity(isEnabled ? 1 : 0.45)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .animation(DS.Motion.quick, value: hovering)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .onHover { hovering = $0 }
                    .contentShape(Capsule(style: .continuous))
            }
        }
    }
}

/// Compact icon button (e.g. header refresh). Hover pops a soft circular tint.
struct IconActionButtonStyle: ButtonStyle {
    var tint: Color = MenuBarDesign.accent

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false

        var body: some View {
            if #available(macOS 26.0, *) {
                configuration.label
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .scaleEffect(configuration.isPressed ? 0.9 : 1)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .contentShape(Circle())
            } else {
                configuration.label
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hovering ? tint : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(tint.opacity(hovering ? 0.16 : 0.001))
                    )
                    .scaleEffect(configuration.isPressed ? 0.9 : 1)
                    .animation(DS.Motion.quick, value: hovering)
                    .animation(DS.Motion.quick, value: configuration.isPressed)
                    .onHover { hovering = $0 }
                    .contentShape(Circle())
            }
        }
    }
}
