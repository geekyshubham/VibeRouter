import SwiftUI

enum MenuBarDesign {
    static let panelWidth: CGFloat = 392
    static let panelMaxHeight: CGFloat = 760
    static let cornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 12

    /// Indigo-violet VibeRouter accent (CodexBar-adjacent premium feel).
    static let accent = Color(red: 0.45, green: 0.42, blue: 0.98)
    static let success = Color(red: 0.18, green: 0.80, blue: 0.52)
    static let warning = Color(red: 0.98, green: 0.68, blue: 0.16)
    static let danger = Color(red: 0.94, green: 0.30, blue: 0.32)

    static func providerTint(for serviceType: ServiceType) -> Color {
        switch serviceType {
        case .claude: return Color(red: 0.87, green: 0.52, blue: 0.33)
        case .codex: return Color(red: 0.16, green: 0.67, blue: 0.49)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .copilot: return Color(red: 0.35, green: 0.35, blue: 0.95)
        case .antigravity: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .kimi: return Color(red: 0.42, green: 0.56, blue: 0.98)
        case .kiro: return Color(red: 0.98, green: 0.45, blue: 0.22)
        // Near-black was invisible on dark glass panels; keep neutral xAI gray but light enough to read.
        case .grok: return Color(red: 0.82, green: 0.82, blue: 0.86)
        case .qwen: return Color(red: 0.45, green: 0.25, blue: 0.95)
        case .zai: return Color(red: 0.18, green: 0.72, blue: 0.62)
        case .cursor: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case .codebuddy, .codebuddyCN: return Color(red: 0.10, green: 0.55, blue: 0.95)
        case .gitlab: return Color(red: 0.88, green: 0.30, blue: 0.22)
        case .kilo: return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .windsurf: return Color(red: 0.00, green: 0.72, blue: 0.85)
        case .qoder: return Color(red: 0.45, green: 0.40, blue: 0.95)
        case .trae: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .zed: return Color(red: 0.70, green: 0.55, blue: 0.35)
        case .opencodeGo: return Color(red: 0.20, green: 0.72, blue: 0.80)
        }
    }

    static func usageTint(remainingPercent: Double) -> Color {
        if remainingPercent > 50 { return success }
        if remainingPercent > 20 { return warning }
        return danger
    }

    /// Statuspage / health-probe indicator colors for Overview provider dots.
    static func statusDotColor(_ level: ProviderStatusLevel?) -> Color {
        guard let level else { return Color.secondary.opacity(0.45) }
        switch level {
        case .none: return success
        case .minor, .maintenance: return warning
        case .major, .critical: return danger
        case .unknown: return Color.secondary.opacity(0.65)
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

struct GlassPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: MenuBarDesign.cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                Color.white.opacity(0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }
}

struct GlassCardBackground: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.14), tint.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(
                RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MenuBarDesign.cardCornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.6)
            )
    }
}