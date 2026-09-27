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
        var tabs: [PanelTab] = [.overview]
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
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: MenuBarDesign.sectionSpacing) {
                    tabContent
                }
                .padding(12)
                .id(effectiveTab)
                .transition(.opacity)
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.35)
            footer
        }
        .frame(width: MenuBarDesign.panelWidth, height: panelHeight)
        .background(GlassPanelBackground())
        .onAppear {
            authManager.checkAuthStatus()
            nativeSession.refresh(accounts: authManager.serviceAccounts.mapValues { $0.accounts })
            Task {
                // Force a local cost rescan when Analytics is empty so a failed prior pass
                // (or launching a stale app binary) does not stick on "No local usage history".
                // Opening the panel should pick up sessions written since the last scan.
                // The 15-minute throttle otherwise left 8.2B / $5.3K on screen after new use.
                usageStore.invalidateCostScanThrottle()
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
        case .status:
            StatusIncidentsView(usageStore: usageStore, compact: true)
        case .analytics:
            AnalyticsDashboardView(usageStore: usageStore, compact: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PulsingDot(
                color: serverManager.isRunning ? MenuBarDesign.success : MenuBarDesign.danger,
                active: serverManager.isRunning,
                size: 9
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeRouter")
                    .font(.headline)
                // Use String(port) so SwiftUI LocalizedStringKey does not locale-format
                // the integer (e.g. "8,337" instead of "8337").
                if serverManager.isRunning {
                    Button(action: onOpenDashboard) {
                        HStack(spacing: 5) {
                            Text("Proxy live")
                                .foregroundStyle(MenuBarDesign.success)
                            Text("·").foregroundStyle(.tertiary)
                            Text("localhost:\(String(proxyPort))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Open management dashboard (lists all proxy models)")
                } else {
                    Text("Server stopped — tap Start below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            refreshControl
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if usageStore.isRefreshing || usageStore.isRefreshingStatus {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
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
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tabIcon(for tab: PanelTab) -> String {
        switch tab {
        case .overview: return "square.grid.2x2.fill"
        case .status: return "dot.radiowaves.left.and.right"
        case .analytics: return "chart.bar.fill"
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewContent: some View {
        if let analytics = usageStore.analytics, analytics.totalTokens30d > 0 {
            overviewPulse(analytics)
        }

        // "How much did I use on <date>" — reads the persisted day store, so changing
        // dates is a lookup rather than a rescan.
        UsageByDateView(usageStore: usageStore, compact: true)

        if visibleProviders.allSatisfy({ authManager.accounts(for: $0).isEmpty }) {
            emptyState
        }

        if totalAccountCount > 6 {
            Text("Tip: tap a provider header to collapse · tap an account to expand details")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("local CLI")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("30-day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                Text("Top: \(top.model)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                icon: "chart.line.uptrend.xyaxis",
                label: "30-day volume",
                value: formatTokens(analytics.totalTokens30d),
                detail: "today \(formatTokens(today.totalTokens))",
                valueColor: .primary
            )
            Divider().frame(height: 36)
            pulseStat(
                icon: "dollarsign.circle",
                label: "Est. API $",
                value: pulseDollars(analytics.totalCostUSD30d),
                detail: "today \(pulseDollars(today.totalCostUSD))",
                valueColor: MenuBarDesign.accent
            )
            if let shown = todayModel ?? monthModel {
                Divider().frame(height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Top model")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(shown)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let monthModel, shown != monthModel {
                        Text("30d \(monthModel)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
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

    private func pulseStat(icon: String, label: String, value: String, detail: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            ZStack {
                Circle()
                    .fill(MenuBarDesign.accent.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MenuBarDesign.accent)
            }
            VStack(spacing: DS.Space.xs) {
                Text("No providers connected yet")
                    .font(.subheadline.weight(.semibold))
                Text("Connect an account to see live usage limits, reset countdowns, status, and analytics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onOpenSettings) {
                Label("Connect a provider", systemImage: "plus.circle.fill")
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
            .buttonStyle(ProminentActionButtonStyle(
                tint: serverManager.isRunning ? MenuBarDesign.danger : MenuBarDesign.success
            ))
            .help(serverManager.isRunning ? "Stop the local proxy" : "Start the local proxy")

            Button(action: onOpenDashboard) {
                Image(systemName: "safari")
            }
            .buttonStyle(IconActionButtonStyle())
            .disabled(!serverManager.isRunning)
            .help("Open management UI at \(ManagementCredentials.backendBaseURL)/management.html (key copied)")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
