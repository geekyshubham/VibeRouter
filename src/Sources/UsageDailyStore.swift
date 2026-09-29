import Foundation

/// On-disk history of per-day usage, so the date picker can answer for days that a
/// fresh scan can no longer see.
///
/// Why this has to exist: `UsageStore` keeps `costByProvider` in memory only, and
/// `LocalTokenCostScanner` skips any log file whose mtime predates the history cutoff.
/// So a day's usage becomes invisible once its session files go untouched and age out —
/// even though that day is still inside the requested window. Persisting each scan's
/// per-day detail lets history accumulate past the limit of any single scan.
///
/// Storage layout mirrors `RemotePricingCatalog`'s disk cache (Application Support /
/// VibeRouter, atomic writes) so there is one convention for cached state in this app.
enum UsageDailyStore {
    /// Bump when the on-disk shape changes; unknown versions are discarded, not guessed at.
    /// v2: v1 Claude rows were ~2.4× inflated and v1 OpenCode rows billed free models at
    /// fallback rates, so those providers are dropped on migration.
    /// v3: Codex rows were inflated by replayed subagent history and Kiro rows were day-shifted,
    /// so both are rebuilt by a one-off full-history rescan, as are the other providers whose
    /// sources survive; in-window Claude rows lose Kiro proxy models; pre-window Claude rows lose
    /// day-shifted duplicates and are flagged legacy; in-window rows of providers whose scanners
    /// changed are dropped so the next scan rewrites them.
    private static let schemaVersion = 3

    /// Roughly 13 months, so year-over-year comparisons stay possible while the file
    /// remains bounded (a busy day is a few KB, so this caps out in the low single MB).
    static let retentionDays = 400

    static let fullRescanProvidersOnMigration: Set<String> = ["codex", "kiro", "claude", "gemini", "antigravity", "opencode", "grok"]
    static let rewrittenInWindowOnMigration: Set<String> = [
        "gemini", "antigravity", "cursor", "copilot", "grok", "opencode",
    ]

    typealias DayTable = [String: [String: DailyProviderUsage]]
    typealias SourceTable = [String: [String: Double]]

    private struct Payload: Codable {
        var version: Int
        var updatedAt: Double
        /// day key -> provider ID -> that provider's usage on that day.
        var days: [String: [String: DailyProviderUsage]]
        /// provider ID -> source file path -> mtime, from the last authoritative scan.
        var sources: [String: [String: Double]]?
        var pendingFullRescan: [String]?
    }

    private static let lock = NSLock()
    /// Mirrors the file so reads don't hit disk on every UI interaction.
    private static var days: DayTable = [:]
    private static var sources: SourceTable = [:]
    private static var pendingFullRescan: Set<String> = []
    private static var loaded = false
    private static var migrationHistoryDays = 30

    // MARK: - Paths

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("VibeRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("usage-daily.json")
    }

    /// Pre-v3 copy kept beside the store, because older builds discard v3 files and legacy rows cannot be rebuilt.
    static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("usage-daily.v2.bak.json")
    }

    // MARK: - Lifecycle

    /// Load the cache once. Cheap enough to call from app launch.
    /// `historyDays` sets the analytics window that schema migrations treat as rescannable.
    static func bootstrap(historyDays: Int? = nil) {
        lock.lock()
        let alreadyLoaded = loaded
        if let historyDays { migrationHistoryDays = historyDays }
        let windowDays = migrationHistoryDays
        lock.unlock()
        guard !alreadyLoaded else { return }
        load(windowStart: UsageDayKey(date: analyticsCutoffStart(now: Date(), historyDays: windowDays)))
    }

    struct LoadedState: Equatable {
        var days: DayTable
        var sources: SourceTable
        var pendingFullRescan: Set<String>
        /// True when the loaded state differs from the file's own schema and should be written back.
        var needsWrite: Bool
    }

    private static func load(windowStart: UsageDayKey) {
        guard let url = fileURL, let state = loadState(at: url, windowStart: windowStart) else {
            lock.lock(); loaded = true; lock.unlock()
            return
        }

        lock.lock()
        days = state.days
        sources = state.sources
        pendingFullRescan = state.pendingFullRescan
        loaded = true
        let snapshot = persistedStateLocked()
        lock.unlock()

        if state.needsWrite { write(snapshot, to: url) }
    }

    private static func decodePayload(_ data: Data?) -> Payload? {
        guard let data, let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1...schemaVersion).contains(payload.version)
        else { return nil }
        return payload
    }

    /// Backs up a pre-v3 file once before it is rewritten; an unreadable or unknown-version file falls back to the backup.
    static func loadState(at url: URL, windowStart: UsageDayKey) -> LoadedState? {
        let backup = backupURL(for: url)
        let raw = try? Data(contentsOf: url)
        let current = decodePayload(raw)
        let backupPayload = { decodePayload(try? Data(contentsOf: backup)) }

        guard let payload = current ?? backupPayload() else { return nil }
        let fromBackup = current == nil

        var backedUpNow = false
        if payload.version < schemaVersion, !fromBackup, let raw, !FileManager.default.fileExists(atPath: backup.path) {
            backedUpNow = (try? raw.write(to: backup, options: .atomic)) != nil
        }

        var migrated = migrate(payload.days, fromVersion: payload.version, windowStart: windowStart)
        if payload.version < 3, !fromBackup, !backedUpNow, let legacy = backupPayload(), legacy.version < 3 {
            let restored = migrate(legacy.days, fromVersion: legacy.version, windowStart: windowStart)
            for (day, providers) in restored where day < windowStart.value {
                for (providerID, usage) in providers where migrated[day]?[providerID] == nil {
                    migrated[day, default: [:]][providerID] = usage
                }
            }
        }

        var pending = Set(payload.pendingFullRescan ?? [])
        if payload.version < 3 { pending.formUnion(fullRescanProvidersOnMigration) }
        return LoadedState(
            days: migrated,
            sources: payload.sources ?? [:],
            pendingFullRescan: pending,
            needsWrite: payload.version != schemaVersion
        )
    }

    /// Pure migration from an older on-disk version, exposed for tests.
    static func migrate(_ stored: DayTable, fromVersion version: Int, windowStart: UsageDayKey) -> DayTable {
        var migrated = stored
        for (day, providers) in stored {
            var remaining = providers
            if version < 2 {
                remaining.removeValue(forKey: "claude")
                remaining.removeValue(forKey: "opencode")
            }
            if version < 3 {
                let inWindow = day >= windowStart.value
                if var claude = remaining["claude"] {
                    claude.models.removeAll { isKiroProxyModel($0.model, inWindow: inWindow) }
                    if claude.models.isEmpty || (!inWindow && isDayShiftedGhost(day: day, in: stored)) {
                        remaining["claude"] = nil
                    } else {
                        remaining["claude"] = inWindow ? claude : DailyProviderUsage(
                            providerID: claude.providerID,
                            models: claude.models,
                            volumeUnit: claude.volumeUnit,
                            fidelity: .legacy
                        )
                    }
                }
                if inWindow {
                    for providerID in rewrittenInWindowOnMigration { remaining.removeValue(forKey: providerID) }
                }
            }
            migrated[day] = remaining.isEmpty ? nil : remaining
        }
        return migrated
    }

    /// Kiro upstream ids keep dotted versions (`claude-opus-5.5`); Anthropic ids never do. Dotted
    /// ids are only treated as Kiro inside the window, where the Claude rescan rewrites the day;
    /// older dotted rows predate the Kiro proxy and cannot be rebuilt.
    static func isKiroProxyModel(_ model: String, inWindow: Bool = true) -> Bool {
        let lower = model.lowercased()
        if lower.hasPrefix("kiro") { return true }
        return inWindow && lower.hasPrefix("claude") && lower.contains(".")
    }

    /// Older builds wrote a Claude day twice, once shifted onto the previous day; the earlier copy is the ghost.
    static func isDayShiftedGhost(day: String, in stored: DayTable) -> Bool {
        guard let row = stored[day]?["claude"],
              let date = UsageDayKey(value: day).date(),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date),
              let following = stored[UsageDayKey(date: next).value]?["claude"]
        else { return false }
        // Token counts only: the copies' float costs differ in the last bits.
        let signature: (DailyProviderUsage) -> [String] = { usage in
            usage.models.map {
                "\($0.model)|\($0.volumeUnit)|\($0.totalVolume)|\($0.requestCount)|\($0.inputTokens)|\($0.outputTokens)|\($0.cacheReadTokens)|\($0.cacheWriteTokens)"
            }.sorted()
        }
        return !row.models.isEmpty && signature(row) == signature(following)
    }

    // MARK: - Recording

    /// Fold a scan's per-day results for one provider into the history.
    ///
    /// Semantics are **replace** per (day, provider), never add: every scan recomputes a
    /// day's totals from the full log files, so accumulating would double-count on the
    /// second scan of the same day. Days the scan didn't report are left untouched.
    static func record(_ daily: [UsageDayKey: DailyProviderUsage]) {
        guard !daily.isEmpty else { return }
        record(providers: [daily])
    }

    /// Record several providers at once (one scan sweep), with a single disk write.
    static func record(providers: [[UsageDayKey: DailyProviderUsage]]) {
        let scans = providers.compactMap { daily -> ProviderDailyScan? in
            guard let providerID = daily.values.first?.providerID else { return nil }
            return ProviderDailyScan(providerID: providerID, days: daily, coverage: nil)
        }
        record(scans: scans)
    }

    /// Record one sweep. Authoritative scans also delete their provider's stored days inside
    /// the covered range that the scan no longer reports (stale, day-shifted or ghost rows).
    static func record(scans: [ProviderDailyScan]) {
        guard !scans.isEmpty else { return }
        bootstrap()

        lock.lock()
        merge(scans, into: &days, sources: &sources)
        pruneLocked()
        let snapshot = persistedStateLocked()
        lock.unlock()

        if let url = fileURL { write(snapshot, to: url) }
    }

    /// Core merge, exposed for tests. A covered range never reaches back past the newest
    /// deleted in-range source file, so rows that only a deleted log could rebuild survive,
    /// and rows in that protected span are never replaced by a smaller figure.
    static func merge(
        _ scans: [ProviderDailyScan],
        into days: inout DayTable,
        sources: inout SourceTable,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        for scan in scans {
            let providerID = scan.providerID
            var protectedBefore: UsageDayKey?

            if let coverage = scan.coverage {
                let previous = sources[providerID] ?? [:]
                var carried: [String: Double] = [:]
                var newestDeleted: Double?
                for (path, mtime) in previous where coverage.sources[path] == nil && !fileExists(path) {
                    guard UsageDayKey(date: Date(timeIntervalSince1970: mtime)) >= coverage.from,
                          !wasMoved(path, mtime: mtime, previous: previous, current: coverage.sources)
                    else { continue }
                    carried[path] = mtime
                    newestDeleted = max(newestDeleted ?? mtime, mtime)
                }
                var from = coverage.from
                if let newestDeleted {
                    let calendar = Calendar.current
                    let deletedDay = calendar.startOfDay(for: Date(timeIntervalSince1970: newestDeleted))
                    if let next = calendar.date(byAdding: .day, value: 1, to: deletedDay) {
                        from = max(from, UsageDayKey(date: next))
                    }
                }
                protectedBefore = from

                if from <= coverage.through {
                    for (day, providers) in days
                    where day >= from.value && day <= coverage.through.value && providers[providerID] != nil
                        && scan.days[UsageDayKey(value: day)] == nil
                    {
                        var remaining = providers
                        remaining.removeValue(forKey: providerID)
                        days[day] = remaining.isEmpty ? nil : remaining
                    }
                }
                sources[providerID] = coverage.sources.merging(carried) { current, _ in current }
            }

            for (day, usage) in scan.days {
                let guarded = protectedBefore.map { day < $0 } ?? (usage.fidelity == .partial)
                if guarded, let existing = days[day.value]?[providerID], existing.totalVolume > usage.totalVolume {
                    continue
                }
                var forDay = days[day.value] ?? [:]
                forDay[providerID] = usage
                days[day.value] = forDay
            }
        }
    }

    /// A missing source whose distinctive file name reappears in this scan (e.g. a Codex rollout
    /// moved to archived_sessions) was rescanned at its new path, so it no longer protects its days.
    static func wasMoved(_ path: String, mtime: Double, previous: [String: Double], current: [String: Double]) -> Bool {
        let name = (path as NSString).lastPathComponent
        let named: ([String: Double]) -> [Double] = { table in
            table.compactMap { ($0.key as NSString).lastPathComponent == name ? $0.value : nil }
        }
        let matches = named(current)
        return named(previous).count == 1 && matches.count == 1 && matches[0] >= mtime
    }

    /// Providers still waiting for their one-off full-history rebuild.
    static func pendingFullRescanProviders() -> Set<String> {
        bootstrap()
        lock.lock()
        defer { lock.unlock() }
        return pendingFullRescan
    }

    /// Record a full-history rebuild and clear the pending flag for providers it covered.
    static func recordFullRescan(_ scans: [ProviderDailyScan]) {
        bootstrap()
        lock.lock()
        merge(scans, into: &days, sources: &sources)
        for scan in scans where scan.isAuthoritative {
            pendingFullRescan.remove(scan.providerID)
        }
        pruneLocked()
        let snapshot = persistedStateLocked()
        lock.unlock()

        if let url = fileURL { write(snapshot, to: url) }
    }

    // MARK: - Queries

    /// Everything known about one calendar day.
    static func summary(for day: UsageDayKey) -> DailyUsageSummary {
        bootstrap()
        lock.lock()
        let forDay = days[day.value] ?? [:]
        lock.unlock()

        // Stable provider order; the UI re-sorts by cost via `providersByCost`.
        let providers = forDay.values.sorted { $0.providerID < $1.providerID }
        return DailyUsageSummary(day: day, providers: providers)
    }

    /// Day keys that hold at least one usage row, most recent first.
    /// Drives the picker's "days with data" affordance so users don't hunt blindly.
    static func availableDays() -> [UsageDayKey] {
        bootstrap()
        lock.lock()
        let keys = days.filter { _, providers in
            providers.values.contains { !$0.models.isEmpty }
        }.keys
        lock.unlock()
        return keys.map { UsageDayKey(value: $0) }.sorted(by: >)
    }

    /// Summaries for an inclusive day range, ascending. Days with no data are omitted;
    /// callers that need a dense series should fill gaps themselves.
    static func summaries(from start: UsageDayKey, to end: UsageDayKey) -> [DailyUsageSummary] {
        bootstrap()
        let (lower, upper) = start <= end ? (start, end) : (end, start)
        lock.lock()
        let matching = days.filter { key, _ in
            key >= lower.value && key <= upper.value
        }
        lock.unlock()

        return matching
            .map { key, providers in
                DailyUsageSummary(
                    day: UsageDayKey(value: key),
                    providers: providers.values.sorted { $0.providerID < $1.providerID }
                )
            }
            .filter { !$0.isEmpty }
            .sorted { $0.day < $1.day }
    }

    /// Oldest day we hold data for — the honest lower bound for the date picker.
    static func earliestDay() -> UsageDayKey? {
        availableDays().last
    }

    // MARK: - Maintenance

    /// Drop days beyond the retention window. Caller must hold `lock`.
    private static func pruneLocked() {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else {
            return
        }
        let cutoff = UsageDayKey(date: cutoffDate).value
        days = days.filter { $0.key >= cutoff }
    }

    private struct PersistedState {
        let days: DayTable
        let sources: SourceTable
        let pendingFullRescan: Set<String>
    }

    /// Caller must hold `lock`.
    private static func persistedStateLocked() -> PersistedState {
        PersistedState(days: days, sources: sources, pendingFullRescan: pendingFullRescan)
    }

    private static func write(_ snapshot: PersistedState, to url: URL) {
        let payload = Payload(
            version: schemaVersion,
            updatedAt: Date().timeIntervalSince1970,
            days: snapshot.days,
            sources: snapshot.sources,
            pendingFullRescan: snapshot.pendingFullRescan.isEmpty ? nil : snapshot.pendingFullRescan.sorted()
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Atomic so a crash mid-write can't leave a truncated file that fails to decode
        // and silently wipes accumulated history.
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Test hooks

    /// Writes `state` as the current schema to `url`, as `load` does after a migration.
    static func writeForTesting(_ state: LoadedState, to url: URL) {
        write(PersistedState(days: state.days, sources: state.sources, pendingFullRescan: state.pendingFullRescan), to: url)
    }

    /// Replace in-memory state without touching disk, for the Verification specs.
    static func replaceForTesting(_ replacement: [UsageDayKey: [DailyProviderUsage]]) {
        lock.lock()
        days = replacement.reduce(into: [:]) { acc, entry in
            acc[entry.key.value] = entry.value.reduce(into: [:]) { inner, usage in
                inner[usage.providerID] = usage
            }
        }
        loaded = true
        lock.unlock()
    }

    /// Fold data in without writing to disk, so specs can verify merge semantics.
    static func recordForTesting(_ daily: [UsageDayKey: DailyProviderUsage]) {
        lock.lock()
        loaded = true
        for (day, usage) in daily {
            var forDay = days[day.value] ?? [:]
            forDay[usage.providerID] = usage
            days[day.value] = forDay
        }
        lock.unlock()
    }

    static func resetForTesting() {
        lock.lock(); days = [:]; sources = [:]; pendingFullRescan = []; loaded = true; lock.unlock()
    }
}
