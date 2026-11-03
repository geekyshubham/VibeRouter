import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var nativeSession = NativeSessionManager.shared
    @ObservedObject private var settings = AppSettings.shared
    let proxyPort: Int
    /// The exact overall panel height, provided by the controller (which sets the
    /// popover's `contentSize` to match). The scroll area fills the space left after
    /// the header, tab bar, and footer, so content scrolls inside a fixed window
    /// that always fits on screen.
    var panelHeight: CGFloat = MenuBarDesign.panelMaxHeight
    let onOpenSettings: () -> Void
    let onToggleServer: () -> Void
    let onCopyURL: () -> Void
    let onOpenDashboard: () -> Void
    let onQuit: () -> Void

    @State private var selectedTab: PanelTab = .overview

    private enum PanelTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case pools = "Quota"
        case status = "Status"
        case analytics = "Analytics"
        var id: String { rawValue }
    }

    private var visibleProviders: [ServiceType] {        // Providers with more accounts first (easier to find crowded ones), then name.
        ServiceType.allCases
            .filter { authManager.hasAccounts(for: $0) }
            .sorted { lhs, rhs in
                let lc = authManager.accounts(for: lhs).count
                let rc = authManager.accounts(for: rhs).count
                if lc != rc { return lc > rc }
                return lhs.displayName < rhs.displayName
            }
    }

    private var totalAccountCount: Int {
        visibleProviders.reduce(0) { $0 + authManager.accounts(for: $1).count }
    }

    private var availableTabs: [PanelTab] {
        var tabs: [PanelTab] = [.overview, .pools]
        if settings.showStatusTab { tabs.append(.status) }
        if settings.showAnalyticsTab { tabs.append(.analytics) }
        return tabs
    }

    private var effectiveTab: PanelTab {
        availableTabs.contains(selectedTab) ? selectedTab : .overview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: MenuBarDesign.sectionSpacing) {
                    tabContent
                }
                .padding(12)
                .id(effectiveTab)
                .transition(.opacity)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: MenuBarDesign.panelWidth, height: panelHeight)
        .background(GlassPanelBackground())
        .onAppear {
            authManager.refreshInBackground()
            nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })
            Task {
                // Respect the local-history scan throttle when opening the panel.
                await usageStore.refreshVisibleProviders(
                    from: ServiceType.allCases,
                    accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                )
            }
            Task { await usageStore.refreshStatus() }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch effectiveTab {
        case .overview:
            overviewContent
        case .pools:
            QuotaPoolsView(usageStore: usageStore, compact: true)
        case .status:
            StatusIncidentsView(usageStore: usageStore, compact: true)
        case .analytics:
            AnalyticsDashboardView(usageStore: usageStore, compact: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            PulsingDot(
                color: MenuBarDesign.success,
                active: serverManager.isRunning,
                size: 8
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeRouter")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.text)
                // Use String(port) so SwiftUI LocalizedStringKey does not locale-format
                // the integer (e.g. "8,337" instead of "8337").
                if serverManager.isRunning {
                    Button(action: onOpenDashboard) {
                        HStack(spacing: DS.Space.xs) {
                            Text("Live on")
                                .foregroundStyle(Palette.textSecondary)
                            Text("localhost:\(String(proxyPort))")
                                .font(DS.Font.meta)
                                .foregroundStyle(Palette.text)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.textMuted)
                        }
                        .font(DS.Font.label)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Open management dashboard (lists all proxy models)")
                } else {
                    Text("Proxy stopped")
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            appearanceControl
            refreshControl
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
    }

    /// Cycles system → light → dark, so the popover can be checked in both themes.
    private var appearanceControl: some View {
        let next: String = switch settings.appearanceMode {
        case "system": "light"
        case "light": "dark"
        default: "system"
        }
        let icon: String = switch settings.appearanceMode {
        case "light": "sun.max"
        case "dark": "moon"
        default: "circle.lefthalf.filled"
        }
        return Button { settings.appearanceMode = next } label: {
            Image(systemName: icon)
        }
        .buttonStyle(IconActionButtonStyle())
        .help("Appearance: \(settings.appearanceMode == "system" ? "match system" : settings.appearanceMode)")
        .accessibilityLabel("Appearance")
    }

    @ViewBuilder
    private var refreshControl: some View {
        if usageStore.isRefreshing || usageStore.isRefreshingStatus {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Button {
                Task {
                    await usageStore.refreshVisibleProviders(
                        from: ServiceType.allCases,
                        accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                    )
                    await usageStore.refreshStatus()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconActionButtonStyle())
            .help("Refresh usage, costs & status")
        }
    }

    private var tabPicker: some View {
        SegmentedTabBar(
            tabs: availableTabs,
            selection: Binding(
                get: { effectiveTab },
                set: { selectedTab = $0 }
            ),
            title: { $0.rawValue },
            icon: { tabIcon(for: $0) }
        )
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.md)
    }

    private func tabIcon(for tab: PanelTab) -> String {
        switch tab {
        case .overview: return "square.grid.2x2"
        case .pools: return "gauge.with.dots.needle.33percent"
        case .status: return "waveform.path.ecg"
        case .analytics: return "chart.bar"
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewContent: some View {
        if let analytics = usageStore.analytics, analytics.totalTokens30d > 0 || analytics.estimatedTokens30d > 0 {
            overviewPulse(analytics)
        }

        // "How much did I use on <date>" — reads the persisted day store, so changing
        // dates is a lookup rather than a rescan.
        UsageByDateView(usageStore: usageStore, compact: true)

        if visibleProviders.allSatisfy({ authManager.accounts(for: $0).isEmpty }) {
            emptyState
        }

        if totalAccountCount > 6 {
            Text("Click a provider to collapse it, an account to expand it")
                .font(DS.Font.label)
                .foregroundStyle(Palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        ForEach(visibleProviders, id: \.self) { serviceType in
            ProviderUsageCardView(
                serviceType: serviceType,
                accounts: authManager.accounts(for: serviceType),
                usageForAccount: { usageStore.snapshot(for: $0) },
                cost: usageStore.cost(for: serviceType),
                isProviderEnabled: serverManager.isProviderEnabled(providerKey(for: serviceType)),
                statusLevel: usageStore.statusLevel(for: serviceType),
                proxyPort: proxyPort,
                onWakeCompleted: { _ in
                    Task {
                        await usageStore.refreshVisibleProviders(
                            from: [serviceType],
                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                        )
                    }
                },
                nativeSession: nativeSession,
                onSwitchAccount: { _ in
                    nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })
                    Task {
                        await usageStore.refreshVisibleProviders(
                            from: [serviceType],
                            accounts: authManager.serviceAccounts.mapValues { $0.accounts }
                        )
                    }
                },
                startCollapsed: true
            )
        }

        // Local CLI usage without a proxy seat (OpenCode DB, etc.) — still belongs on Overview.
        ForEach(localOnlyCostProviders, id: \.providerID) { cost in
            localCostCard(cost)
        }
    }

    /// Cost snapshots that have no matching ServiceType account card (OpenCode is the main case).
    private var localOnlyCostProviders: [ProviderCostSnapshot] {
        let accountProviderIDs = Set(
            ServiceType.allCases.compactMap(\.usageProviderID)
        )
        return usageStore.analytics?.byProvider.filter { cost in
            !accountProviderIDs.contains(cost.providerID)
                && (cost.last30DaysTokens > 0 || (cost.last30DaysCostUSD ?? 0) > 0)
        } ?? []
    }

    @ViewBuilder
    private func localCostCard(_ cost: ProviderCostSnapshot) -> some View {
        let tint = UsageProviderNaming.tint(forProviderID: cost.providerID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(UsageProviderNaming.displayName(forProviderID: cost.providerID))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("Local CLI")
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("30 days")
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textSecondary)
                    Text(UsageNumberFormatter.tokens(cost.last30DaysTokens))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if settings.showCostEstimates, let usd = cost.last30DaysCostUSD, usd > 0 {
                        Text(UsageNumberFormatter.usd(usd))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textSecondary)
                    Text(UsageNumberFormatter.tokens(cost.sessionTokens))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if settings.showCostEstimates, let usd = cost.sessionCostUSD, usd > 0 {
                        Text(UsageNumberFormatter.usd(usd))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let top = cost.models.first {
                Text("Top model \(top.model)")
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(MenuBarDesign.cardPadding)
        .cardSurface(tint: tint)
    }

    private func overviewPulse(_ analytics: AnalyticsOverview) -> some View {
        let today = usageStore.dailySummary
        let todayModel = today.modelsByCost.first?.usage.model
        let monthModel = analytics.topModels.first?.model
        return HStack(spacing: DS.Space.lg) {
            pulseStat(
                label: "30-day volume",
                value: analytics.totalTokens30d > 0
                    ? formatTokens(analytics.totalTokens30d)
                    : UsageNumberFormatter.volume(analytics.estimatedTokens30d, unit: .estimatedTokens),
                detail: "Today \(UsageNumberFormatter.tokens(today.totalTokens, estimated: today.totalEstimatedTokens))",
                valueColor: Palette.text
            )
            Rectangle().fill(Palette.hairline).frame(width: 1, height: 40)
            pulseStat(
                label: "API-equivalent",
                value: pulseDollars(analytics.totalCostUSD30d),
                detail: analytics.estimatedCostUSD30d >= 0.005
                    ? "Today \(pulseDollars(today.totalCostUSD)) · +\(UsageNumberFormatter.usd(analytics.estimatedCostUSD30d)) est"
                    : "Today \(pulseDollars(today.totalCostUSD))",
                valueColor: Palette.text
            )
            if let shown = todayModel ?? monthModel {
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 40)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Top model")
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textSecondary)
                    Text(shown)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let monthModel, shown != monthModel {
                        Text("30 days \(monthModel)")
                            .font(DS.Font.meta)
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    /// Full dollars below $100k. "$5.3K" hid every new session until the next hundred dollars.
    private func pulseDollars(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 100_000 { return UsageNumberFormatter.usd(value) }
        let sign = value < 0 ? "-" : ""
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let digits = formatter.string(from: NSNumber(value: magnitude)) ?? String(format: "%.2f", magnitude)
        return "\(sign)$\(digits)"
    }

    private func pulseStat(label: String, value: String, detail: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(DS.Font.meta)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
            VStack(spacing: DS.Space.xs) {
                Text("No providers connected yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text("Connect an account to see its limits, reset times, status and usage")
                    .font(DS.Font.label)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onOpenSettings) {
                Label("Connect a provider", systemImage: "plus")
            }
            .buttonStyle(ProminentActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxl)
        .padding(.horizontal, DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            // Keep text on Start/Stop only — everything else is icon-only.
            Button(action: onToggleServer) {
                Label(serverManager.isRunning ? "Stop" : "Start",
                      systemImage: serverManager.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(serverManager.isRunning
                ? AnyButtonStyle(SoftActionButtonStyle())
                : AnyButtonStyle(ProminentActionButtonStyle()))
            .help(serverManager.isRunning ? "Stop the local proxy" : "Start the local proxy")

            Button(action: onOpenDashboard) {
                Image(systemName: "safari")
            }
            .buttonStyle(IconActionButtonStyle())
            .disabled(!serverManager.isRunning)
            .help("Open management UI at \(ManagementCredentials.backendBaseURL)/management.html (key copied)")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconActionButtonStyle())
            .help("Open settings")

            Button(action: onCopyURL) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconActionButtonStyle())
            .disabled(!serverManager.isRunning)
            .help("Copy proxy URL (http://localhost:\(proxyPort))")

            Spacer(minLength: 0)

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(IconActionButtonStyle(tint: MenuBarDesign.danger))
            .help("Quit VibeRouter")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private func providerKey(for type: ServiceType) -> String {
        switch type {
        case .copilot: return "github-copilot"
        case .grok: return "xai"
        default: return type.rawValue
        }
    }

    private func formatTokens(_ count: Int) -> String {
        UsageNumberFormatter.tokens(count)
    }
}

/// Lets the footer swap Start (primary) and Stop (secondary) styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
