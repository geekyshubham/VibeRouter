import Foundation

/// Quota checks share a budget with other clients. Auth-file events and manual
/// refreshes must not turn a throttled status endpoint into a retry loop.
actor ClaudeUsagePoller {
    static let shared = ClaudeUsagePoller(cacheFile: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/VibeRouter/claude-usage.json"))
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
    private let cacheFile: URL?
    private var lastSuccessful: [String: SavedQuota]

    // Store quota values only; OAuth credentials never enter this cache.
    private struct SavedQuota: Codable {
        let windows: [RateWindow]
        let updatedAt: Date
    }

    init(cacheFile: URL? = nil) {
        self.cacheFile = cacheFile
        self.lastSuccessful = cacheFile.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: SavedQuota].self, from: $0) } ?? [:]
    }

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
            let previous = lastSuccessful[key]
            let notice: String
            if let previous {
                notice = "Claude usage check rate limited — showing last known limits.\nLast updated \(ResetCountdownFormatter.absoluteTime(previous.updatedAt))."
            } else {
                notice = "Claude usage check rate limited — no previous limits available yet."
            }
            snapshot = ProviderUsageSnapshot(
                id: snapshot.id, providerID: snapshot.providerID,
                source: previous == nil ? snapshot.source : "Claude OAuth (last known)",
                windows: previous?.windows ?? [],
                accountEmail: snapshot.accountEmail, updatedAt: previous?.updatedAt,
                errorMessage: notice + "\nNext check after \(ResetCountdownFormatter.absoluteTime(deadline))."
            )
        } else {
            failures[key] = nil
            // Auth rejection must allow a retry with newly adopted credentials.
            deadlines[key] = now.addingTimeInterval(snapshot.errorMessage == nil ? Self.minimumInterval : 0)
            if snapshot.errorMessage == nil, !snapshot.windows.isEmpty, let updatedAt = snapshot.updatedAt {
                lastSuccessful[key] = SavedQuota(windows: snapshot.windows, updatedAt: updatedAt)
                if let cacheFile {
                    do {
                        try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(lastSuccessful).write(to: cacheFile, options: .atomic)
                    } catch {
                        NSLog("[ClaudeUsagePoller] Could not save last known quotas: %@", error.localizedDescription)
                    }
                }
            }
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
