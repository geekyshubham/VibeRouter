import Foundation

/// Quota checks share a budget with other clients. Auth-file events and manual
/// refreshes must not turn a throttled status endpoint into a retry loop.
actor ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller()
    static let minimumInterval: TimeInterval = 5 * 60

    struct Response {
        let snapshot: ProviderUsageSnapshot
        var rateLimited = false
        var retryAfter: String? = nil
    }

    private var pending: [String: Task<ProviderUsageSnapshot, Never>] = [:]
    private var snapshots: [String: ProviderUsageSnapshot] = [:]
    private var deadlines: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    func fetch(
        key: String,
        now: Date = Date(),
        operation: @escaping @Sendable () async -> Response
    ) async -> ProviderUsageSnapshot {
        if let snapshot = snapshots[key], let deadline = deadlines[key], now < deadline {
            return snapshot
        }
        if let task = pending[key] { return await task.value }
        let task = Task {
            let response = await operation()
            return self.record(response, key: key, now: now)
        }
        pending[key] = task
        return await task.value
    }

    private func record(_ response: Response, key: String, now: Date) -> ProviderUsageSnapshot {
        pending[key] = nil
        var snapshot = response.snapshot
        if response.rateLimited {
            let count = min((failures[key] ?? 0) + 1, 5)
            failures[key] = count
            let backoff = Self.minimumInterval * pow(2, Double(count - 1))
            let delay = max(backoff, Self.retryDelay(response.retryAfter, now: now))
            let deadline = now.addingTimeInterval(delay)
            deadlines[key] = deadline
            let previous = snapshots[key]
            snapshot = ProviderUsageSnapshot(
                id: snapshot.id, providerID: snapshot.providerID,
                source: previous?.source ?? snapshot.source,
                windows: previous?.windows ?? [], subAccounts: previous?.subAccounts ?? [],
                accountEmail: snapshot.accountEmail ?? previous?.accountEmail,
                planType: previous?.planType, planLabel: previous?.planLabel,
                rateLimitResets: previous?.rateLimitResets, updatedAt: previous?.updatedAt,
                errorMessage: "Claude usage check rate limited — retrying after \(ResetCountdownFormatter.shortDate(deadline))"
                    + ((previous?.windows.isEmpty == false) ? " (showing last known limits)" : "")
            )
        } else {
            failures[key] = nil
            // Auth rejection must allow a retry with newly adopted credentials.
            deadlines[key] = now.addingTimeInterval(snapshot.errorMessage == nil ? Self.minimumInterval : 0)
        }
        snapshots[key] = snapshot
        return snapshot
    }

    static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        guard let header else { return 0 }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(0, formatter.date(from: header)?.timeIntervalSince(now) ?? 0)
    }
}
