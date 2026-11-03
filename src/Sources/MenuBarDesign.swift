import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension NSColor {
    /// Appearance-resolving NSColor, for AppKit surfaces such as window chrome.
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
    /// Same step as `Palette.background`, so the title bar and content read as one surface.
    static let paletteBackground = NSColor.adaptive(light: 0xF5F5F4, dark: 0x161617)
}

extension Color {
    /// Resolves per view appearance, so the light/dark override applies live.
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Graphite ramp with one cobalt signal accent. Surfaces stay neutral; color
/// belongs to data (provider series, quota state) and the one primary action.
enum Palette {
    static let background = Color.adaptive(light: 0xF5F5F4, dark: 0x161617)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x1E1E20)
    static let surfaceSunken = Color.adaptive(light: 0xEDEDEC, dark: 0x27272A)
    static let hairline = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.09)
    static let text = Color.adaptive(light: 0x1B1B1D, dark: 0xEDEDEF)
    static let textSecondary = Color.adaptive(light: 0x5C5C61, dark: 0xA3A3A9)
    /// Smallest text still clears 4.5:1 on `surface` in both themes.
    static let textMuted = Color.adaptive(light: 0x75757B, dark: 0x8A8A91)
    static let accent = Color.adaptive(light: 0x2E66D9, dark: 0x7DA8FF)
    /// Text on any filled semantic or accent control.
    static let onAccent = Color.adaptive(light: 0xFFFFFF, dark: 0x0F1830)
    static let chartGrid = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    static let barNeutral = Color.adaptive(light: 0xB4B4B9, dark: 0x55555B)
}

enum MenuBarDesign {
    static let panelWidth: CGFloat = 392
    static let panelMaxHeight: CGFloat = 760
    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 12

    static let accent = Palette.accent
    static let success = Color.adaptive(light: 0x1E8A4F, dark: 0x4CC38A)
    static let warning = Color.adaptive(light: 0xA86300, dark: 0xF0A63A)
    static let danger = Color.adaptive(light: 0xC4373A, dark: 0xF2716C)

    static func providerTint(for serviceType: ServiceType) -> Color {
        switch serviceType {
        case .claude: return Color.adaptive(light: 0xC2643A, dark: 0xE08A5E)
        case .codex: return Color.adaptive(light: 0x1F8A64, dark: 0x3FC08F)
        case .gemini: return Color.adaptive(light: 0x2F6FE0, dark: 0x6F9EF5)
        case .copilot: return Color(red: 0.35, green: 0.35, blue: 0.95)
        case .antigravity: return Color.adaptive(light: 0x7445D6, dark: 0xA488F2)
        case .kimi: return Color(red: 0.42, green: 0.56, blue: 0.98)
        case .kiro: return Color.adaptive(light: 0xD8541C, dark: 0xF5864F)
        // xAI is neutral; it still has to read on both themes.
        case .grok: return Color.adaptive(light: 0x55555B, dark: 0xCFCFD6)
        case .qwen: return Color(red: 0.45, green: 0.25, blue: 0.95)
        case .zai: return Color(red: 0.18, green: 0.72, blue: 0.62)
        case .cursor: return Color.adaptive(light: 0xA27800, dark: 0xF2C33A)
        case .codebuddy, .codebuddyCN: return Color(red: 0.10, green: 0.55, blue: 0.95)
        case .gitlab: return Color(red: 0.88, green: 0.30, blue: 0.22)
        case .kilo: return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .windsurf: return Color(red: 0.00, green: 0.72, blue: 0.85)
        case .qoder: return Color(red: 0.45, green: 0.40, blue: 0.95)
        case .trae: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .zed: return Color(red: 0.70, green: 0.55, blue: 0.35)
        case .opencodeGo: return Color.adaptive(light: 0x1A8D9A, dark: 0x45C2CF)
        case .experientialLabs: return Color(red: 0.62, green: 0.36, blue: 0.90)
        }
    }

    static func usageTint(remainingPercent: Double) -> Color {
        if remainingPercent > 50 { return success }
        if remainingPercent > 20 { return warning }
        return danger
    }

    /// Statuspage / health-probe indicator colors for Overview provider dots.
    static func statusDotColor(_ level: ProviderStatusLevel?) -> Color {
        guard let level else { return Palette.textMuted.opacity(0.6) }
        switch level {
        case .none: return success
        case .minor, .maintenance: return warning
        case .major, .critical: return danger
        case .unknown: return Palette.textMuted
        }
    }

    static func statusDotHelp(_ level: ProviderStatusLevel?) -> String {
        guard let level else { return "No status feed for this provider" }
        switch level {
        case .none: return "Operational"
        case .minor: return "Degraded performance"
        case .maintenance: return "Maintenance"
        case .major: return "Partial outage"
        case .critical: return "Major outage"
        case .unknown: return "Status unknown"
        }
    }
}

/// Popover body: the ramp's base step under a hairline.
struct GlassPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
            .fill(Palette.background)
            .overlay(
                RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// Card: one surface step up from the panel, with a hairline. `tint` is kept
/// for call-site compatibility; cards no longer wash in provider color.
struct GlassCardBackground: View {
    let tint: Color
    var cornerRadius: CGFloat = MenuBarDesign.cardCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}
