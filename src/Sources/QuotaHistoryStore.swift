import Foundation

/// Pooled quota per provider over time, so the Quota pools chart can draw what
/// was recorded and how fast it drains. Stores percentages only, never tokens
/// or credentials.
@MainActor
final class QuotaHistoryStore: ObservableObject {
    static let shared = QuotaHistoryStore(file: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/VibeRouter/quota-history.json"))

    /// One sample per provider per interval; a newer reading inside it replaces the last.
    static let sampleInterval: TimeInterval = 5 * 60
    static let retention: TimeInterval = 14 * 86_400

    @Published private(set) var samples: [String: [QuotaPoolSample]]
    private let file: URL?

    init(file: URL? = nil) {
        self.file = file
        samples = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [QuotaPoolSample]].self, from: $0) } ?? [:]
    }

    /// The window that limits an account for days, not hours: the longest one,
    /// and the emptier of two equally long windows.
    nonisolated static func poolAccount(for snapshot: ProviderUsageSnapshot) -> QuotaPoolAccount? {
        let windows = snapshot.windows + snapshot.subAccounts.flatMap(\.windows)
        guard let window = windows.max(by: { a, b in
            let la = a.windowMinutes ?? 0, lb = b.windowMinutes ?? 0
            return la != lb ? la < lb : a.usedPercent < b.usedPercent
        }) else { return nil }
        return QuotaPoolAccount(
            remaining: max(0, min(100, 100 - window.usedPercent)),
            resetsAt: window.resetsAt,
            periodMinutes: window.windowMinutes ?? 10_080
        )
    }

    /// Live accounts per provider; snapshots still loading or in error are skipped.
    nonisolated static func pools(from snapshots: [ProviderUsageSnapshot]) -> [String: [QuotaPoolAccount]] {
        var pools: [String: [QuotaPoolAccount]] = [:]
        for snapshot in snapshots where snapshot.errorMessage == nil && !snapshot.isRefreshing {
            guard let account = poolAccount(for: snapshot) else { continue }
            pools[snapshot.providerID, default: []].append(account)
        }
        return pools
    }

    func record(_ snapshots: [ProviderUsageSnapshot], now: Date = Date()) {
        let pools = Self.pools(from: snapshots)
        guard !pools.isEmpty else { return }
        var updated = samples
        for (providerID, accounts) in pools {
            let sample = QuotaPoolSample(
                at: now,
                remaining: accounts.reduce(0) { $0 + $1.remaining },
                capacity: Double(accounts.count * 100)
            )
            var series = (updated[providerID] ?? []).filter { now.timeIntervalSince($0.at) < Self.retention }
            if let last = series.last, now.timeIntervalSince(last.at) < Self.sampleInterval,
               last.capacity == sample.capacity, series.count > 1 {
                series[series.count - 1] = sample
            } else {
                series.append(sample)
            }
            updated[providerID] = series
        }
        guard updated != samples else { return }
        samples = updated
        save()
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: file, options: .atomic)
        } catch {
            NSLog("[QuotaHistory] Could not save quota history: %@", error.localizedDescription)
        }
    }
}
