import Foundation

/// Fill-first auto-failover for Antigravity multi-account pools.
///
/// Proxy level (CLIProxyAPI, always on):
/// - `routing.strategy: fill-first` in the bundled config uses the first healthy
///   auth until it 429s, then moves to the next. `quota-exceeded` switches
///   project/preview-model and falls back to credits as a last resort.
///
/// Native level (this router):
/// - Tracks per-account quota snapshots from `UsageStore`.
/// - An account is **exhausted** when its peak used% >= threshold (default 95%)
///   or its snapshot carries a quota/rate-limit error.
/// - `nextHealthy` returns the first non-exhausted, enabled, non-expired account
///   in Settings order (fill-first). `ensureHealthyNativeSession` switches the
///   Antigravity IDE pointer (`current_account.json` + state.vscdb) to that
///   account so opening Antigravity keeps working after exhaustion.
enum AntigravityAutoRouter {
    /// Peak used% across summary + detail windows for one snapshot.
    static func peakUsed(_ snapshot: ProviderUsageSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        let windows = snapshot.windows + snapshot.subAccounts.flatMap(\.windows)
        guard !windows.isEmpty else { return nil }
        return windows.map(\.usedPercent).max()
    }

    /// True when the account should no longer receive traffic.
    static func isExhausted(
        snapshot: ProviderUsageSnapshot?,
        threshold: Double = AppSettings.shared.antigravityExhaustionThreshold
    ) -> Bool {
        if let peak = peakUsed(snapshot), peak >= threshold { return true }
        let msg = (snapshot?.errorMessage ?? "").lowercased()
        if msg.isEmpty { return false }
        return msg.contains("exhaust")
            || msg.contains("quota")
            || msg.contains("rate limit")
            || msg.contains("rate-limit")
            || msg.contains("429")
            || msg.contains("resource_exhausted")
    }

    /// Fill-first order: Settings order, skipping disabled/expired/exhausted.
    /// Returns the account the proxy *and* the native IDE should use next.
    static func nextHealthy(
        accounts: [AuthAccount],
        usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?,
        threshold: Double = AppSettings.shared.antigravityExhaustionThreshold
    ) -> AuthAccount? {
        for account in accounts {
            if account.isDisabled || account.isExpired { continue }
            if isExhausted(snapshot: usageForAccount(account), threshold: threshold) { continue }
            return account
        }
        return nil
    }

    /// All exhausted accounts in fill order (for status UI / logging).
    static func exhaustedAccounts(
        accounts: [AuthAccount],
        usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?,
        threshold: Double = AppSettings.shared.antigravityExhaustionThreshold
    ) -> [AuthAccount] {
        accounts.filter { account in
            !account.isDisabled && !account.isExpired
                && isExhausted(snapshot: usageForAccount(account), threshold: threshold)
        }
    }

    /// One-line health summary, e.g. "3/5 healthy · next: a@gmail.com".
    static func healthLine(
        accounts: [AuthAccount],
        usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?,
        threshold: Double = AppSettings.shared.antigravityExhaustionThreshold
    ) -> String {
        let active = accounts.filter { !$0.isDisabled && !$0.isExpired }
        guard !active.isEmpty else { return "No active Antigravity accounts" }
        let healthy = active.filter {
            !isExhausted(snapshot: usageForAccount($0), threshold: threshold)
        }
        if healthy.count == active.count {
            return "\(healthy.count)/\(active.count) healthy · fill-first"
        }
        if let next = healthy.first {
            return "\(healthy.count)/\(active.count) healthy · next: \(next.baseDisplayName)"
        }
        return "All \(active.count) accounts exhausted — add or refresh quota"
    }

    /// If the native IDE is pinned to an exhausted account, switch it to the next
    /// healthy one. No-op when auto-switch is off, when everything is healthy,
    /// or when nothing healthy remains. Returns the account switched to, if any.
    @MainActor
    static func ensureHealthyNativeSession(
        accounts: [AuthAccount],
        usageForAccount: (AuthAccount) -> ProviderUsageSnapshot?,
        nativeSession: NativeSessionManager?,
        threshold: Double = AppSettings.shared.antigravityExhaustionThreshold
    ) async -> AuthAccount? {
        guard AppSettings.shared.antigravityAutoSwitchEnabled else { return nil }
        guard let nativeSession else { return nil }
        guard accounts.count > 1 else { return nil }

        let current = accounts.first(where: { nativeSession.isCurrent($0) })
        // Current is healthy (or unknown with no usage yet) → nothing to do.
        if let current, !isExhausted(snapshot: usageForAccount(current), threshold: threshold) {
            return nil
        }
        guard let next = nextHealthy(accounts: accounts, usageForAccount: usageForAccount, threshold: threshold)
        else { return nil }
        // Already on the best account.
        if current?.id == next.id { return nil }

        let outcome = await nativeSession.switchTo(
            next,
            restartApp: AppSettings.shared.restartAppOnSwitch
        )
        switch outcome {
        case .switched(let message):
            NSLog("[AntigravityFailover] Auto-switched native session: %@", message)
            return next
        case .failure(let message):
            NSLog("[AntigravityFailover] Auto-switch failed: %@", message)
            return nil
        }
    }
}
