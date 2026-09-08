import Foundation
import Combine

/// User-facing preferences for VibeRouter, persisted in `UserDefaults`.
/// Kept intentionally small and observable so views update live and services
/// (auto-refresh, wake scheduler, account switching) can read a single source of truth.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: Refresh cadence

    /// How often usage/quota is refreshed, in minutes (1…30).
    @Published var usageRefreshMinutes: Double {
        didSet { persist(usageRefreshMinutes.clamped(to: 1...30), forKey: Keys.usageRefreshMinutes) }
    }

    /// How often provider status pages are polled, in minutes (2…60).
    @Published var statusRefreshMinutes: Double {
        didSet { persist(statusRefreshMinutes.clamped(to: 2...60), forKey: Keys.statusRefreshMinutes) }
    }

    /// History window for local analytics scans, in days.
    @Published var analyticsHistoryDays: Int {
        didSet { persist(analyticsHistoryDays, forKey: Keys.analyticsHistoryDays) }
    }

    // MARK: Analytics / UI customization

    @Published var showCostEstimates: Bool {
        didSet { persist(showCostEstimates, forKey: Keys.showCostEstimates) }
    }

    @Published var showStatusTab: Bool {
        didSet { persist(showStatusTab, forKey: Keys.showStatusTab) }
    }

    @Published var showAnalyticsTab: Bool {
        didSet { persist(showAnalyticsTab, forKey: Keys.showAnalyticsTab) }
    }

    /// Auto-update model list-prices from the remote pricing feed (models.dev) so cost
    /// estimates track real prices. When off, the built-in static catalog is used.
    @Published var autoUpdatePricing: Bool {
        didSet { persist(autoUpdatePricing, forKey: Keys.autoUpdatePricing) }
    }

    /// Show the menu-bar icon with a colored dot reflecting worst quota pressure.
    @Published var menuBarUsageBadge: Bool {
        didSet { persist(menuBarUsageBadge, forKey: Keys.menuBarUsageBadge) }
    }

    // MARK: Management console

    /// Require a password to open the management console.
    ///
    /// Off by default: the console binds to loopback, so a login prompt on a
    /// single-user machine adds friction without adding protection. Turning this on
    /// restores the password gate (useful on a shared Mac).
    ///
    /// Either way the server refuses non-local management requests while auth is off,
    /// so this can never publish API keys or linked accounts over a tunnel — see
    /// `AuthenticateManagementKey` in the Go handler.
    @Published var requireManagementPassword: Bool {
        didSet { persist(requireManagementPassword, forKey: Keys.requireManagementPassword) }
    }

    // MARK: Account switching

    /// Quit + relaunch the associated desktop app after switching accounts.
    @Published var restartAppOnSwitch: Bool {
        didSet { persist(restartAppOnSwitch, forKey: Keys.restartAppOnSwitch) }
    }

    /// Ask for confirmation before switching the active native session.
    @Published var confirmBeforeSwitch: Bool {
        didSet { persist(confirmBeforeSwitch, forKey: Keys.confirmBeforeSwitch) }
    }

    // MARK: Wake scheduler

    /// Master switch for the automatic "wake 5h window" scheduler.
    @Published var autoWakeEnabled: Bool {
        didSet { persist(autoWakeEnabled, forKey: Keys.autoWakeEnabled) }
    }

    /// Provider IDs the scheduler is allowed to wake automatically.
    @Published var autoWakeProviderIDs: Set<String> {
        didSet { persist(Array(autoWakeProviderIDs), forKey: Keys.autoWakeProviderIDs) }
    }

    /// Minutes to wait after a quota window resets before firing the keep-alive.
    @Published var autoWakeGraceMinutes: Double {
        didSet { persist(autoWakeGraceMinutes.clamped(to: 0...60), forKey: Keys.autoWakeGraceMinutes) }
    }

    // MARK: - Antigravity auto-failover

    /// Automatically switch the native Antigravity IDE session to the next healthy
    /// account when the current one is exhausted (>= threshold or quota error).
    /// Proxy-level failover (fill-first + 429 retry) is always on in the bundled
    /// config; this controls the native IDE pointer (`current_account.json`).
    @Published var antigravityAutoSwitchEnabled: Bool {
        didSet { persist(antigravityAutoSwitchEnabled, forKey: Keys.antigravityAutoSwitchEnabled) }
    }

    /// Peak used% at or above which an Antigravity account counts as exhausted.
    @Published var antigravityExhaustionThreshold: Double {
        didSet { persist(antigravityExhaustionThreshold.clamped(to: 50...100), forKey: Keys.antigravityExhaustionThreshold) }
    }

    // MARK: Derived

    var usageRefreshInterval: TimeInterval { usageRefreshMinutes.clamped(to: 1...30) * 60 }
    var statusRefreshInterval: TimeInterval { statusRefreshMinutes.clamped(to: 2...60) * 60 }

    /// Providers that can be auto-woken (same set QuotaWakeService supports).
    static let wakeableProviderIDs: [String] = ["codex", "claude", "antigravity", "gemini"]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true

        usageRefreshMinutes = defaults.number(forKey: Keys.usageRefreshMinutes, default: 3)
        statusRefreshMinutes = defaults.number(forKey: Keys.statusRefreshMinutes, default: 10)
        analyticsHistoryDays = defaults.integer(forKey: Keys.analyticsHistoryDays, default: 30)
        showCostEstimates = defaults.bool(forKey: Keys.showCostEstimates, default: true)
        showStatusTab = defaults.bool(forKey: Keys.showStatusTab, default: true)
        showAnalyticsTab = defaults.bool(forKey: Keys.showAnalyticsTab, default: true)
        autoUpdatePricing = defaults.bool(forKey: Keys.autoUpdatePricing, default: true)
        menuBarUsageBadge = defaults.bool(forKey: Keys.menuBarUsageBadge, default: false)
        // Default off: no login page unless the user asks for one.
        requireManagementPassword = defaults.bool(forKey: Keys.requireManagementPassword, default: false)
        restartAppOnSwitch = defaults.bool(forKey: Keys.restartAppOnSwitch, default: true)
        confirmBeforeSwitch = defaults.bool(forKey: Keys.confirmBeforeSwitch, default: true)
        autoWakeEnabled = defaults.bool(forKey: Keys.autoWakeEnabled, default: false)
        autoWakeGraceMinutes = defaults.number(forKey: Keys.autoWakeGraceMinutes, default: 3)
        antigravityAutoSwitchEnabled = defaults.bool(forKey: Keys.antigravityAutoSwitchEnabled, default: true)
        antigravityExhaustionThreshold = defaults.number(forKey: Keys.antigravityExhaustionThreshold, default: 95)

        if let stored = defaults.array(forKey: Keys.autoWakeProviderIDs) as? [String] {
            autoWakeProviderIDs = Set(stored)
        } else {
            autoWakeProviderIDs = ["codex"]
        }

        isLoading = false
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let usageRefreshMinutes = "ultra.usageRefreshMinutes"
        static let statusRefreshMinutes = "ultra.statusRefreshMinutes"
        static let analyticsHistoryDays = "ultra.analyticsHistoryDays"
        static let showCostEstimates = "ultra.showCostEstimates"
        static let showStatusTab = "ultra.showStatusTab"
        static let showAnalyticsTab = "ultra.showAnalyticsTab"
        static let autoUpdatePricing = "ultra.autoUpdatePricing"
        static let menuBarUsageBadge = "ultra.menuBarUsageBadge"
        static let requireManagementPassword = "ultra.requireManagementPassword"
        static let restartAppOnSwitch = "ultra.restartAppOnSwitch"
        static let confirmBeforeSwitch = "ultra.confirmBeforeSwitch"
        static let autoWakeEnabled = "ultra.autoWakeEnabled"
        static let autoWakeProviderIDs = "ultra.autoWakeProviderIDs"
        static let autoWakeGraceMinutes = "ultra.autoWakeGraceMinutes"
        static let antigravityAutoSwitchEnabled = "ultra.antigravityAutoSwitchEnabled"
        static let antigravityExhaustionThreshold = "ultra.antigravityExhaustionThreshold"
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }

    func integer(forKey key: String, default fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }

    func number(forKey key: String, default fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
