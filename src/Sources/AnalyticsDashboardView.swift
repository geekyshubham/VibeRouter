import SwiftUI

/// Full-page analytics for Settings + compact strip for the menu bar.
struct AnalyticsDashboardView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact: Bool = false

    private var overview: AnalyticsOverview? { usageStore.analytics }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.lg : DS.Space.xxl) {
            if !compact {
                QuotaPoolsView(usageStore: usageStore)
            }
            header
            if let overview {
                totalsGrid(overview)
                if !overview.byProvider.isEmpty {
                    providerSection(overview)
                }
                if !overview.topModels.isEmpty {
                    modelsSection(overview)
                }
                footnote
            } else if usageStore.isRefreshing {
                ProgressView("Scanning local session logs")
                    .controlSize(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                emptyState
            }
        }
        .padding(compact ? 0 : 4)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(compact ? "Analytics" : "Usage")
                    .font(.system(size: compact ? 13 : 17, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(settings.showCostEstimates
                    ? "Local CLI logs · API-equivalent cost"
                    : "Local CLI logs · token and credit volume")
                    .font(DS.Font.label)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if usageStore.isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func totalsGrid(_ overview: AnalyticsOverview) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.md) {
            StatTile(
                label: "30-day volume",
                value: formatTokens(overview.totalTokens30d),
                sublabel: totalsSublabel(cost: overview.totalCostUSD30d, estimatedCost: overview.estimatedCostUSD30d, estimated: overview.estimatedTokens30d),
                tint: MenuBarDesign.accent
            )
            StatTile(
                label: "Today",
                value: formatTokens(overview.totalTokensSession),
                sublabel: totalsSublabel(cost: overview.totalCostUSDSession, estimatedCost: overview.estimatedCostUSDSession, estimated: overview.estimatedTokensSession),
                tint: MenuBarDesign.accent
            )
        }
    }

    /// Estimated tokens are never folded into the exact total; they ride alongside it.
    private func totalsSublabel(cost: Double, estimatedCost: Double, estimated: Int) -> String? {
        Self.totalsSublabel(cost: settings.showCostEstimates ? cost : nil, estimatedCost: estimatedCost, estimated: estimated)
    }

    static func totalsSublabel(cost: Double?, estimatedCost: Double, estimated: Int) -> String? {
        var parts: [String] = []
        if let cost { parts.append(UsageNumberFormatter.usd(cost, estimated: estimatedCost)) }
        if estimated > 0 { parts.append("+" + UsageNumberFormatter.volume(estimated, unit: .estimatedTokens)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func providerSection(_ overview: AnalyticsOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By provider")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            // Compact menu bar used to hide OpenCode/Antigravity behind a 4-row cap.
            ForEach(overview.byProvider.prefix(compact ? 8 : 14)) { provider in
                providerRow(provider, overview: overview)
            }
        }
    }

    private func providerRow(_ provider: ProviderCostSnapshot, overview: AnalyticsOverview) -> some View {
        // Share only within the same volume unit (credits never compete with tokens).
        let peers = overview.byProvider.filter { $0.volumeUnit == provider.volumeUnit }
        let peerTotal = max(1, peers.reduce(0) { $0 + $1.last30DaysTokens })
        let share = Double(provider.last30DaysTokens) / Double(peerTotal)
        let tint = providerTint(for: provider.providerID)
        let todayUSD = provider.sessionCostUSD ?? 0
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.md) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: provider.providerID))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                    // Surface today's $ so a Kiro-only total isn't mistaken for "Grok is missing".
                    if settings.showCostEstimates, todayUSD >= 0.01 {
                        Text("Today \(formatUSD(todayUSD))")
                            .font(DS.Font.meta)
                            .foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer()
                Text(formatVolume(provider.last30DaysTokens, unit: provider.volumeUnit))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.text)
                if let usd = provider.last30DaysCostUSD, settings.showCostEstimates {
                    Text(formatUSD(usd))
                        .font(DS.Font.meta)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceSunken)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * share))
                        .animation(reduceMotion ? nil : DS.Motion.spring, value: share)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, DS.Space.xs)
    }

    /// Maps an analytics provider ID to its brand tint (falls back to the app accent).
    private func providerTint(for providerID: String) -> Color {
        switch providerID.lowercased() {
        case "codex": return MenuBarDesign.providerTint(for: .codex)
        case "claude": return MenuBarDesign.providerTint(for: .claude)
        case "gemini": return MenuBarDesign.providerTint(for: .gemini)
        case "copilot": return MenuBarDesign.providerTint(for: .copilot)
        case "antigravity": return MenuBarDesign.providerTint(for: .antigravity)
        case "kiro": return MenuBarDesign.providerTint(for: .kiro)
        case "grok": return MenuBarDesign.providerTint(for: .grok)
        case "cursor": return MenuBarDesign.providerTint(for: .cursor)
        case "opencode", "opencode-go": return Color(red: 0.95, green: 0.55, blue: 0.20)
        case "zai", "z.ai": return MenuBarDesign.providerTint(for: .zai)
        case "kimi": return MenuBarDesign.providerTint(for: .kimi)
        case "qwen": return MenuBarDesign.providerTint(for: .qwen)
        default: return MenuBarDesign.accent
        }
    }

    private func modelsSection(_ overview: AnalyticsOverview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Most used models")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            ForEach(Array(overview.topModels.prefix(compact ? 5 : 10).enumerated()), id: \.offset) { _, model in
                modelRow(model)
            }
            if !overview.topEstimatedModels.isEmpty {
                Text("Estimated volume")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .padding(.top, DS.Space.md)
                ForEach(Array(overview.topEstimatedModels.prefix(compact ? 3 : 6).enumerated()), id: \.offset) { _, model in
                    modelRow(model)
                }
            }
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    private func modelRow(_ model: ModelTokenUsage) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.model)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(Self.modelDetailLine(model, format: formatTokens))
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textSecondary)
                if settings.showCostEstimates, let rate = Self.rateLabel(for: model) {
                    Text(rate)
                        .font(DS.Font.meta)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatVolume(model.totalTokens, unit: model.volumeUnit))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.text)
                if settings.showCostEstimates {
                    Text(formatUSD(model.estimatedCostUSD))
                        .font(DS.Font.meta)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    /// Estimated rows name how they were estimated; a zero request count is omitted, not shown as "0 msg".
    static func modelDetailLine(_ model: ModelTokenUsage, format: (Int) -> String) -> String {
        switch model.volumeUnit {
        case .credits:
            return "\(model.requestCount) req · credits (local sessions)"
        case .estimatedTokens:
            var parts: [String] = []
            if model.requestCount > 0 {
                let noun = LocalKiroCredits.isProxyEstimateRow(model.model) ? "req, credits not recorded" : "req"
                parts.append("\(model.requestCount) \(noun)")
            }
            parts.append(model.estimateBasis ?? "est. tokens")
            return parts.joined(separator: " · ")
        case .tokens:
            return tokenBreakdownLine(model, format: format)
        }
    }

    /// Uncached input, cache read, cache write, output — the same split for every provider.
    static func tokenBreakdownLine(_ model: ModelTokenUsage, format: (Int) -> String) -> String {
        var parts = ["\(model.requestCount) req", "\(format(model.inputTokens)) in"]
        if model.cacheReadTokens > 0 { parts.append("\(format(model.cacheReadTokens)) cache read") }
        if model.cacheWriteTokens > 0 { parts.append("\(format(model.cacheWriteTokens)) cache write") }
        parts.append("\(format(model.outputTokens)) out")
        return parts.joined(separator: " · ")
    }

    /// Nil for estimate rows that carry no cost, so no list price sits beside a $0 figure.
    static func rateLabel(for model: ModelTokenUsage) -> String? {
        if TokenPricingCatalog.isUnpriced(model.model) { return "unpriced — model unknown" }
        switch model.volumeUnit {
        case .credits:
            return "credits × overage rate (est.)"
        case .estimatedTokens:
            guard model.estimatedCostUSD > 0 else { return nil }
            return "est. volume · " + TokenPricingCatalog.rate(forModel: model.model).listPriceLabel
        case .tokens:
            return TokenPricingCatalog.rate(forModel: model.model).listPriceLabel
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No local usage history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
            Text("Run Claude Code, Codex, Grok CLI, Kiro CLI, OpenCode or Copilot. VibeRouter reads their local session logs for tokens, credits, models and API-equivalent cost.")
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: .secondary)
    }

    private var footnote: some View {
        Text(settings.showCostEstimates
            ? "Token totals are exact tokens only; estimated tokens and Kiro credits are listed separately. Models priced from list rates (CodexBar tables). Kiro analytics = local session credits × $0.04 overage rate (est.); quota bar uses Kiro GetUsageLimits per login. Not your invoice."
            : "Exact token volume from CLI logs; estimated tokens and Kiro credits are listed separately. Kiro quota uses Kiro GetUsageLimits per login (billing period), not the rolling window.")
            .font(DS.Font.label)
            .foregroundStyle(Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func displayName(for providerID: String) -> String {
        switch providerID.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "gemini": return "Gemini"
        case "copilot": return "GitHub Copilot"
        case "antigravity": return "Antigravity"
        case "kiro": return "Kiro CLI"
        case "grok": return "Grok CLI"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "zai", "z.ai": return "Z.AI"
        case "kimi": return "Kimi"
        case "qwen": return "Qwen"
        default: return providerID.capitalized
        }
    }

    private func formatTokens(_ count: Int) -> String {
        UsageNumberFormatter.tokens(count)
    }

    /// Formats volume in the provider's unit. Kiro stores millicredits (credits × 1000).
    private func formatVolume(_ count: Int, unit: UsageVolumeUnit) -> String {
        UsageNumberFormatter.volume(count, unit: unit)
    }

    private func formatUSD(_ value: Double) -> String {
        UsageNumberFormatter.usd(value)
    }
}

struct StatusIncidentsView: View {
    @ObservedObject var usageStore: UsageStore
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(compact ? "Status" : "Provider status")
                    .font(.system(size: compact ? 13 : 17, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                if usageStore.isRefreshingStatus {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await usageStore.refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(IconActionButtonStyle())
                    .help("Refresh status pages")
                }
            }

            if usageStore.providerStatuses.isEmpty {
                Text(
                    usageStore.isRefreshingStatus
                        ? "Loading status for your connected providers"
                        : "No status sources for your connected accounts yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Connected providers only")
                    .font(DS.Font.label)
                    .foregroundStyle(Palette.textMuted)
                ForEach(usageStore.providerStatuses) { status in
                    statusCard(status)
                }
            }
        }
    }

    private func statusCard(_ status: ProviderStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status.level))
                    .frame(width: 8, height: 8)
                Text(status.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(status.level.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(status.level))
            }

            if let description = status.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.isProbeOnly {
                Text("Inferred from API health (no public statuspage JSON)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !status.incidents.isEmpty {
                ForEach(status.incidents.prefix(compact ? 2 : 5)) { incident in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(MenuBarDesign.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(incident.name)
                                .font(.caption2.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(incident.status + (incident.impact.map { " · \($0)" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let url = status.pageURL {
                Link(status.isProbeOnly ? "Open status page in browser" : "Open status page", destination: url)
                    .font(.caption2)
            }
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: statusColor(status.level))
        .hoverHighlight(statusColor(status.level))
    }

    private func statusColor(_ level: ProviderStatusLevel) -> Color {
        switch level {
        case .none: return MenuBarDesign.success
        case .minor, .maintenance: return MenuBarDesign.warning
        case .major, .critical: return MenuBarDesign.danger
        case .unknown: return Palette.textMuted
        }
    }
}
