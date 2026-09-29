import Foundation

// `UsageVolumeUnit` lives in UsageVolumeUnit.swift.

struct ModelTokenUsage: Equatable, Identifiable {
    var id: String { model }
    let model: String
    /// Uncached input only; cache reads and writes are reported separately.
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    /// Volume in `volumeUnit` (tokens, millicredits, or estimated tokens).
    let totalTokens: Int
    let estimatedCostUSD: Double
    let requestCount: Int
    let volumeUnit: UsageVolumeUnit
    /// How an estimated row was derived (e.g. "context meter"), shown instead of a generic caption.
    let estimateBasis: String?

    init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int = 0,
        totalTokens: Int,
        estimatedCostUSD: Double,
        requestCount: Int,
        volumeUnit: UsageVolumeUnit = .tokens,
        estimateBasis: String? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.requestCount = requestCount
        self.volumeUnit = volumeUnit
        self.estimateBasis = estimateBasis
    }
}

extension ProviderCostSnapshot {
    static func make(
        providerID: String,
        sessionTokens: Int,
        sessionCostUSD: Double?,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double?,
        models: [ModelTokenUsage] = [],
        volumeUnit: UsageVolumeUnit = .tokens,
        updatedAt: Date? = Date(),
        estimatedTokensLowerBound30d: Int? = nil
    ) -> ProviderCostSnapshot {
        ProviderCostSnapshot(
            id: providerID,
            providerID: providerID,
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            models: models,
            volumeUnit: volumeUnit,
            updatedAt: updatedAt,
            estimatedTokensLowerBound30d: estimatedTokensLowerBound30d
        )
    }
}

/// Scans local CLI session logs (Codex `rollout-*.jsonl`, Claude `projects/**/*.jsonl`, …)
/// to estimate token volume, per-model breakdown, and API-equivalent $ per provider.
///
/// Correctness notes:
/// - Codex: `token_usage_record` lines (one per response, keyed by `response_id`) are the
///   source of truth when a rollout has them; older rollouts fall back to the per-turn
///   `last_token_usage` delta of `token_count` events. Subagent rollouts replay the parent's
///   history below `session_meta.subagent_history_start_ordinal`, and plain forks
///   (`forked_from_id`) open with a replay burst of the parent's turns; both are skipped.
/// - Claude writes ONE line per content block of an assistant turn, each repeating that
///   API request's usage. Requests are deduped by `message.id`|`requestId` — last line wins
///   within a file, the most complete copy (largest output) wins across files.
/// - Requests are priced one at a time so long-context tiers and 1-hour cache writes apply.
/// - Files are streamed line by line with a substring pre-filter, so no size cap is needed;
///   append-only `.jsonl` files resume from the last parsed byte offset.
/// - `kiro/…` models in Claude Code transcripts are Kiro proxy traffic, not Anthropic usage.
enum LocalTokenCostScanner {
    struct ScanRoots {
        let providerID: String
        let directories: [URL]
    }

    static func snapshot(for serviceType: ServiceType, now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let roots = roots(for: serviceType)
        guard !roots.directories.isEmpty else { return nil }
        let detail = scan(providerID: roots.providerID, directories: roots.directories, now: now, historyDays: historyDays)
        guard detail.sessionTokens > 0 || detail.last30DaysTokens > 0 else { return nil }
        return ProviderCostSnapshot.make(
            providerID: roots.providerID,
            sessionTokens: detail.sessionTokens,
            sessionCostUSD: detail.sessionCostUSD,
            last30DaysTokens: detail.last30DaysTokens,
            last30DaysCostUSD: detail.last30DaysCostUSD,
            models: detail.models,
            updatedAt: now
        )
    }

    static func codexSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        snapshot(for: .codex, now: now, historyDays: historyDays)
    }

    static func claudeSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        snapshot(for: .claude, now: now, historyDays: historyDays)
    }

    /// Per-day usage for every provider we can attribute to a calendar day.
    static func allProviderDailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [[UsageDayKey: DailyProviderUsage]] {
        allProviderDailyScans(now: now, historyDays: historyDays)
            .map(\.days)
            .filter { !$0.isEmpty }
    }

    /// Per-provider daily scans, each flagged authoritative (with its covered day range) only
    /// when every source was read successfully.
    ///
    /// Coverage matches `allProviderSnapshots`, deliberately: a provider omitted here
    /// would make the by-date view under-report the very same day the Overview reports
    /// correctly. Providers whose day attribution is weaker carry an honest
    /// `DailyUsageFidelity` and the UI shows the caveat.
    static func allProviderDailyScans(now: Date = Date(), historyDays: Int = 30) -> [ProviderDailyScan] {
        var results: [ProviderDailyScan] = []

        // Antigravity is handled by LocalAntigravityUsage (conversation DBs), not the empty ~/.antigravity tree.
        for type in [ServiceType.codex, .claude, .gemini] {
            let roots = roots(for: type)
            guard !roots.directories.isEmpty else { continue }
            results.append(dailyScan(providerID: roots.providerID, directories: roots.directories, now: now, historyDays: historyDays))
        }

        results.append(kiroDailyScan(now: now, historyDays: historyDays))

        // Aggregators are authoritative for their window only when every source was read.
        // Copilot has no generic-tree fallback here (unlike allProviderSnapshots): the
        // generic scan buckets by file mtime, which would pin an append-only transcript's
        // whole history onto the day it was last reopened.
        let specialized: [() -> LocalDailyUsageScan] = [
            { LocalOpenCodeUsage.dailyUsageScan(now: now, historyDays: historyDays) },
            { LocalAntigravityUsage.dailyUsageScan(now: now, historyDays: historyDays) },
            { LocalGrokUsage.dailyUsageScan(now: now, historyDays: historyDays) },
            { LocalCopilotUsage.dailyUsageScan(now: now, historyDays: historyDays) },
        ]
        for block in specialized {
            autoreleasepool {
                results.append(providerDailyScan(block()))
            }
        }
        autoreleasepool {
            let cursor = LocalCursorUsage.scan(now: now, historyDays: historyDays)
            results.append(providerDailyScan(LocalDailyUsageScan(
                providerID: "cursor",
                days: LocalCursorUsage.dailyUsage(from: cursor.entries),
                cutoffStart: analyticsCutoffStart(now: now, historyDays: historyDays),
                now: now,
                isComplete: cursor.complete,
                sources: cursor.sources,
                oldestSource: cursor.oldestChatStore
            )))
        }
        return results
    }

    static func providerDailyScan(_ scan: LocalDailyUsageScan) -> ProviderDailyScan {
        ProviderDailyScan(
            providerID: scan.providerID,
            days: scan.days,
            coverage: scan.isComplete
                ? DailyScanCoverage(from: scan.coveredFrom, through: scan.coveredThrough, sources: scan.sources)
                : nil
        )
    }

    /// One-off rebuild of whole-history rows (store migrations). Ignores the analytics window.
    static func fullHistoryDailyScans(
        providers: Set<String>,
        now: Date = Date(),
        historyDays: Int = UsageDailyStore.retentionDays
    ) -> [ProviderDailyScan] {
        var results: [ProviderDailyScan] = []
        for type in [ServiceType.codex, .claude, .gemini] {
            let roots = roots(for: type)
            guard providers.contains(roots.providerID), !roots.directories.isEmpty else { continue }
            results.append(dailyScan(providerID: roots.providerID, directories: roots.directories, now: now, historyDays: historyDays))
        }
        if providers.contains("kiro") {
            results.append(kiroDailyScan(now: now, historyDays: historyDays))
        }
        if providers.contains("antigravity") {
            results.append(providerDailyScan(LocalAntigravityUsage.dailyUsageScan(now: now, historyDays: historyDays)))
        }
        if providers.contains("opencode") {
            results.append(providerDailyScan(LocalOpenCodeUsage.dailyUsageScan(now: now, historyDays: historyDays)))
        }
        if providers.contains("grok") {
            results.append(providerDailyScan(LocalGrokUsage.dailyUsageScan(now: now, historyDays: historyDays)))
        }
        return results
    }

    /// All providers with local logs we know how to scan.
    ///
    /// Each provider is isolated so one bad tree/DB cannot blank the whole Analytics tab.
    static func allProviderSnapshots(now: Date = Date(), historyDays: Int = 30) -> [ProviderCostSnapshot] {
        var results: [ProviderCostSnapshot] = []

        func take(_ label: String, _ body: () -> ProviderCostSnapshot?) {
            // autoreleasepool keeps transient JSON/SQLite buffers from accumulating across providers.
            autoreleasepool {
                if let snap = body() {
                    results.append(snap)
                } else {
                    NSLog("[UsageScan] %@ produced no snapshot", label)
                }
            }
        }

        // Classic CLI jsonl trees (Antigravity uses LocalAntigravityUsage below).
        for type in [ServiceType.codex, .claude, .gemini] {
            take(type.rawValue) { snapshot(for: type, now: now, historyDays: historyDays) }
        }

        take("kiro") { LocalKiroCredits.costSnapshot(now: now, historyDays: historyDays) }
        take("grok") { LocalGrokUsage.costSnapshot(now: now, historyDays: historyDays) }
        take("cursor") { LocalCursorUsage.costSnapshot(now: now, historyDays: historyDays) }
        take("opencode") { LocalOpenCodeUsage.costSnapshot(now: now, historyDays: historyDays) }
        take("antigravity") { LocalAntigravityUsage.costSnapshot(now: now, historyDays: historyDays) }
        take("copilot") { LocalCopilotUsage.costSnapshot(now: now, historyDays: historyDays) }

        NSLog("[UsageScan] snapshots=%d providers=%@", results.count, results.map(\.providerID).joined(separator: ","))
        return results
    }

    /// Kiro-proxied requests that Claude Code logged with a `kiro/` model prefix, as ledger entries.
    static func kiroProxyEntriesFromClaudeLogs(since: Date) -> [KiroProxyUsageLedger.Entry] {
        kiroProxyEntries(inClaudeDirectories: roots(for: .claude).directories, since: since)
    }

    static func kiroProxyEntries(inClaudeDirectories directories: [URL], since: Date) -> [KiroProxyUsageLedger.Entry] {
        var winners: [String: KiroProxyUsageLedger.Entry] = [:]
        _ = walkFiles(providerID: "claude", directories: directories, cutoff: since) { _, aggregate in
            for (key, entry) in aggregate.kiroEntries where entry.timestamp >= since {
                if let existing = winners[key], existing.outputTokens >= entry.outputTokens { continue }
                winners[key] = entry
            }
        }
        return winners.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Drops every cached per-file parse (e.g. after a timezone change).
    static func invalidateFileCache() {
        cacheLock.lock()
        fileCache = [:]
        cacheLock.unlock()
    }

    // MARK: - Roots

    private static func roots(for serviceType: ServiceType) -> ScanRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch serviceType {
        case .codex:
            return ScanRoots(providerID: "codex", directories: [
                home.appendingPathComponent(".codex/sessions"),
                home.appendingPathComponent(".codex/archived_sessions"),
            ])
        case .claude:
            // Claude Code docs: CLAUDE_CONFIG_DIR relocates ~/.claude (including projects/).
            // Also scan legacy defaults and de-dupe resolved paths.
            var claudeDirs: [URL] = [
                home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects"),
            ]
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !configDir.isEmpty
            {
                claudeDirs.insert(
                    URL(fileURLWithPath: configDir, isDirectory: true)
                        .appendingPathComponent("projects"),
                    at: 0
                )
            }
            var seen = Set<String>()
            let unique = claudeDirs.filter { url in
                let key = url.standardizedFileURL.resolvingSymlinksInPath().path
                return seen.insert(key).inserted
            }
            return ScanRoots(providerID: "claude", directories: unique)
        case .gemini:
            return ScanRoots(providerID: "gemini", directories: [
                home.appendingPathComponent(".gemini/tmp"),
                home.appendingPathComponent(".config/gemini"),
            ])
        case .copilot:
            // LocalCopilotUsage parses session-state/jb by per-message timestamp; the generic
            // walker would bucket whole transcripts by file mtime.
            return ScanRoots(providerID: "copilot", directories: [])
        case .antigravity:
            // Token costs come from LocalAntigravityUsage (conversation DBs). Do not point the
            // generic jsonl walker at brain/ (51MB+ of transcripts without usage fields) — that
            // only burns CPU and used to make Analytics look stuck/empty.
            return ScanRoots(providerID: "antigravity", directories: [])
        default:
            return ScanRoots(providerID: serviceType.usageProviderID ?? serviceType.rawValue, directories: [])
        }
    }

    // MARK: - Aggregation types

    private struct AggregateDetail {
        var sessionTokens = 0
        var last30DaysTokens = 0
        var sessionCostUSD = 0.0
        var last30DaysCostUSD = 0.0
        var models: [ModelTokenUsage] = []
    }

    private struct ModelBucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0
        var requests = 0
        var cost = 0.0

        mutating func add(_ other: ModelBucket) {
            input += other.input
            output += other.output
            cacheRead += other.cacheRead
            cacheWrite += other.cacheWrite
            total += other.total
            requests += other.requests
            cost += other.cost
        }
    }

    /// One billed sampling pass attributed to one model. `bucket.requests` is 0 or 1.
    private struct UsagePart {
        let model: String
        let bucket: ModelBucket
    }

    /// Usage extracted from a single log line.
    private struct LineUsage {
        let parts: [UsagePart]
        let timestamp: Date?
        /// Stable per-request identity (Claude `message.id`|`requestId`, Codex `response_id`).
        var dedupKey: String? = nil
    }

    /// Final usage snapshot for one deduplicatable API request within a file.
    private struct KeyedRequest {
        let day: Int
        let parts: [UsagePart]

        var output: Int { parts.reduce(0) { $0 + $1.bucket.output } }
        var total: Int { parts.reduce(0) { $0 + $1.bucket.total } }
    }

    /// Parser state carried across lines, and across incremental resumes of the same file.
    private struct ParseState {
        var currentModel: String
        // Codex re-emits `token_count` events on rate-limit refreshes with an identical
        // `last_token_usage` while `total_token_usage` is unchanged; skip those.
        var codexPrevCumulative = -1
        var codexSawSessionMeta = false
        var codexHistoryStartOrdinal: Int?
        var codexUsesRecords = false
        var codexSkipForkReplay = false
        var codexForkCreatedAtMs: Int64?
        var codexForkReplayDeadline: Date?
        // Gemini CLI rewrites the same assistant message id with identical `tokens`.
        var seenGeminiMessageIDs = Set<String>()
    }

    /// Per-file parsed result, cached by (path, mtime, size, pricing key). Buckets are kept
    /// per-day so the history cutoff (and "today") are applied at aggregation time.
    private struct FileAggregate {
        var mtime: Date
        var size: Int
        let pricingKey: String
        var parsedOffset = 0
        var tailFingerprint = Data()
        var state: ParseState
        /// day-start epoch (local) -> (model -> bucket), for lines with no request identity
        var perDayModels: [Int: [String: ModelBucket]] = [:]
        /// request identity -> final usage snapshot, deduped globally in `scanPerDay`.
        var keyedRequests: [String: KeyedRequest] = [:]
        /// Claude-logged Kiro proxy requests keyed by message id.
        var kiroEntries: [String: KiroProxyUsageLedger.Entry] = [:]
        var readFailed = false
    }

    private struct WalkResult {
        var failedFiles = 0
        var enumerationFailed = false
        var oldestMtime: Date?
        var sources: [String: Double] = [:]
        var liveKeys = Set<String>()

        var succeeded: Bool { failedFiles == 0 && !enumerationFailed }
    }

    private struct PerDayScan {
        var perDay: [Int: [String: ModelBucket]] = [:]
        var walk = WalkResult()
        var cutoff: Date
    }

    private static let cacheLock = NSLock()
    private static var fileCache: [String: FileAggregate] = [:]
    private static let tailFingerprintLength = 64
    private static let readChunkSize = 1 << 20

    // MARK: - Scan

    /// Daily rows for one provider tree, with coverage only when every file was readable.
    static func dailyScan(
        providerID: String,
        directories: [URL],
        now: Date = Date(),
        historyDays: Int = 30
    ) -> ProviderDailyScan {
        let result = scanPerDay(providerID: providerID, directories: directories, now: now, historyDays: historyDays)
        let fidelity: DailyUsageFidelity = result.walk.succeeded ? .exact : .partial
        let coverage = result.walk.succeeded
            ? coverageRange(cutoff: result.cutoff, oldestSource: result.walk.oldestMtime, now: now, sources: result.walk.sources)
            : nil
        return ProviderDailyScan(
            providerID: providerID,
            days: dailyProviderUsage(providerID: providerID, perDay: result.perDay, fidelity: fidelity),
            coverage: coverage
        )
    }

    /// Covered days start after the oldest surviving source's last write: anything earlier
    /// may live in files the tool already pruned (Claude Code keeps ~30 days of transcripts).
    static func coverageRange(cutoff: Date, oldestSource: Date?, now: Date, sources: [String: Double]) -> DailyScanCoverage? {
        guard let oldestSource else { return nil }
        let calendar = Calendar.current
        let dayAfterOldest = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: oldestSource)) ?? oldestSource
        return DailyScanCoverage(
            from: UsageDayKey(date: max(calendar.startOfDay(for: cutoff), dayAfterOldest)),
            through: UsageDayKey(date: now),
            sources: sources
        )
    }

    private static func kiroDailyScan(now: Date, historyDays: Int) -> ProviderDailyScan {
        let scan = LocalKiroCredits.dailyUsageScan(now: now, historyDays: historyDays)
        let coverage = scan.isComplete ? kiroSessionCoverage(now: now, historyDays: historyDays) : nil
        return ProviderDailyScan(providerID: "kiro", days: scan.days, coverage: coverage)
    }

    /// Kiro session files are plain JSON on disk, so a readable tree with no oversized file
    /// means `LocalKiroCredits` saw every in-window turn.
    private static func kiroSessionCoverage(now: Date, historyDays: Int) -> DailyScanCoverage? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions/cli")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in failed = true; return true }
        ) else { return nil }
        var oldest: Date?
        var sources: [String: Double] = [:]
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else {
                failed = true
                continue
            }
            guard values.isRegularFile == true, let mtime = values.contentModificationDate else { continue }
            oldest = min(oldest ?? mtime, mtime)
            guard mtime >= cutoff else { continue }
            if (values.fileSize ?? 0) >= 80_000_000 { failed = true }
            sources[url.standardizedFileURL.resolvingSymlinksInPath().path] = mtime.timeIntervalSince1970
        }
        guard !failed else { return nil }
        return coverageRange(cutoff: cutoff, oldestSource: oldest, now: now, sources: sources)
    }

    private static func historyCutoff(now: Date, historyDays: Int) -> Date {
        // CodexBar: rolling window is inclusive — 30-day display starts 29 days before now.
        let lookback = max(0, historyDays - 1)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
        return Calendar.current.startOfDay(for: cutoffDate)
    }

    /// Visits the parsed aggregate of every log file touched at or after `cutoff`.
    private static func walkFiles(
        providerID: String,
        directories: [URL],
        cutoff: Date,
        _ visit: (String, FileAggregate) -> Void
    ) -> WalkResult {
        let fileManager = FileManager.default
        let pricingKey = currentPricingKey()
        var result = WalkResult()
        var seenPaths = Set<String>()

        for root in directories where fileManager.fileExists(atPath: root.path) {
            var enumerationFailed = false
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in enumerationFailed = true; return true }
            ) else {
                result.enumerationFailed = true
                continue
            }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "json" else { continue }

                // De-dup overlapping roots / symlinks.
                let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(canonical).inserted else { continue }

                guard let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ) else {
                    result.failedFiles += 1
                    continue
                }
                guard values.isRegularFile != false else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let size = values.fileSize ?? 0
                result.oldestMtime = min(result.oldestMtime ?? modified, modified)

                // A file untouched since before the window cannot hold an in-window event.
                guard modified >= cutoff else { continue }

                result.liveKeys.insert(canonical)
                result.sources[canonical] = modified.timeIntervalSince1970
                let aggregate = autoreleasepool {
                    fileAggregate(path: canonical, url: fileURL, providerID: providerID, mtime: modified, size: size, pricingKey: pricingKey)
                }
                if aggregate.readFailed {
                    result.failedFiles += 1
                    NSLog("[UsageScan] %@: could not read %@", providerID, fileURL.lastPathComponent)
                    continue
                }
                visit(canonical, aggregate)
            }
            if enumerationFailed { result.enumerationFailed = true }
        }
        return result
    }

    /// Walks the provider's log trees and returns per-day, per-model buckets within the
    /// history window: `day-start epoch (local) -> (model -> bucket)`.
    ///
    /// Both the rolled-up `scan()` and the date-indexed daily API build on this, so the
    /// two can never disagree about what a given day contains.
    private static func scanPerDay(
        providerID: String,
        directories: [URL],
        now: Date,
        historyDays: Int
    ) -> PerDayScan {
        let cutoff = historyCutoff(now: now, historyDays: historyDays)
        let cutoffDay = dayKey(for: cutoff)
        var perDay: [Int: [String: ModelBucket]] = [:]
        var winners: [String: KeyedRequest] = [:]
        var visited: [(path: String, aggregate: FileAggregate)] = []

        let walk = walkFiles(providerID: providerID, directories: directories, cutoff: cutoff) { path, aggregate in
            visited.append((path, aggregate))
        }

        // Float sums follow path and request-key order, so an unchanged tree always yields identical costs.
        for (_, aggregate) in visited.sorted(by: { $0.path < $1.path }) {
            // Codex perDayModels only hold token_count usage from before a rollout's first token_usage_record.
            for (day, models) in aggregate.perDayModels where day >= cutoffDay {
                var dayModels = perDay[day] ?? [:]
                for (model, bucket) in models {
                    dayModels[model, default: ModelBucket()].add(bucket)
                }
                perDay[day] = dayModels
            }
            // A forked or resumed file can hold a truncated mid-stream copy of a request;
            // keep the most complete snapshot rather than whichever file enumerates first.
            for (key, request) in aggregate.keyedRequests {
                if let existing = winners[key], (existing.output, existing.total) >= (request.output, request.total) {
                    continue
                }
                winners[key] = request
            }
        }

        for key in winners.keys.sorted() {
            guard let request = winners[key], request.day >= cutoffDay else { continue }
            var dayModels = perDay[request.day] ?? [:]
            for part in request.parts {
                dayModels[part.model, default: ModelBucket()].add(part.bucket)
            }
            perDay[request.day] = dayModels
        }

        pruneCache(keeping: walk.liveKeys, roots: directories)
        return PerDayScan(perDay: perDay, walk: walk, cutoff: cutoff)
    }

    /// Per-day, per-model usage for one provider, keyed by calendar day.
    /// Returns nil when this provider has no scannable log trees.
    static func dailyUsage(
        for serviceType: ServiceType,
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage]? {
        let roots = roots(for: serviceType)
        guard !roots.directories.isEmpty else { return nil }
        return dailyScan(providerID: roots.providerID, directories: roots.directories, now: now, historyDays: historyDays).days
    }

    /// Converts raw day buckets into the shared date-indexed model.
    /// These trees carry per-event timestamps, so fidelity is `.exact` unless a file was unreadable.
    private static func dailyProviderUsage(
        providerID: String,
        perDay: [Int: [String: ModelBucket]],
        fidelity: DailyUsageFidelity
    ) -> [UsageDayKey: DailyProviderUsage] {
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in perDay {
            let rows = models
                .map { model, bucket in
                    DailyModelUsage(
                        model: model,
                        inputTokens: bucket.input,
                        outputTokens: bucket.output,
                        cacheReadTokens: bucket.cacheRead,
                        cacheWriteTokens: bucket.cacheWrite,
                        totalVolume: bucket.total,
                        estimatedCostUSD: bucket.cost,
                        requestCount: bucket.requests,
                        volumeUnit: .tokens
                    )
                }
                .sorted { $0.totalVolume > $1.totalVolume }
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: providerID,
                models: rows,
                volumeUnit: .tokens,
                fidelity: fidelity
            )
        }
        return result
    }

    private static func scan(providerID: String, directories: [URL], now: Date, historyDays: Int) -> AggregateDetail {
        let perDay = scanPerDay(
            providerID: providerID,
            directories: directories,
            now: now,
            historyDays: historyDays
        ).perDay
        let todayKey = dayKey(for: now)

        var totalBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0

        // Attribute "today" precisely; everything in the window feeds the rolling total.
        for day in perDay.keys.sorted() {
            let isToday = (day == todayKey)
            for (model, bucket) in (perDay[day] ?? [:]).sorted(by: { $0.key < $1.key }) {
                totalBuckets[model, default: ModelBucket()].add(bucket)
                historyTokens += bucket.total
                historyCost += bucket.cost
                if isToday {
                    sessionTokens += bucket.total
                    sessionCost += bucket.cost
                }
            }
        }

        let models = totalBuckets
            .map { key, bucket in
                ModelTokenUsage(
                    model: key,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    totalTokens: bucket.total,
                    estimatedCostUSD: bucket.cost,
                    requestCount: bucket.requests
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.estimatedCostUSD > rhs.estimatedCostUSD
            }

        return AggregateDetail(
            sessionTokens: sessionTokens,
            last30DaysTokens: historyTokens,
            sessionCostUSD: sessionCost,
            last30DaysCostUSD: historyCost,
            models: models
        )
    }

    // MARK: - Per-file cache

    /// Cached costs are only valid for the price table and timezone they were computed with.
    private static func currentPricingKey() -> String {
        "\(RemotePricingCatalog.generation)|\(AppSettings.shared.autoUpdatePricing)|\(TimeZone.current.identifier)"
    }

    private static func fileAggregate(
        path: String,
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        pricingKey: String
    ) -> FileAggregate {
        cacheLock.lock()
        let cached = fileCache[path]
        cacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size, cached.pricingKey == pricingKey, !cached.readFailed {
            return cached
        }

        let parsed = parseFile(url: url, providerID: providerID, mtime: mtime, size: size, pricingKey: pricingKey, previous: cached)

        cacheLock.lock()
        fileCache[path] = parsed
        cacheLock.unlock()
        return parsed
    }

    /// Byte offset the cached parse of `path` stopped at, for tests.
    static func cachedParsedOffset(forPath path: String) -> Int? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return fileCache[canonical]?.parsedOffset
    }

    /// Append-only `.jsonl` logs resume from the last parsed offset when the bytes just
    /// before it are unchanged; anything else (rewrite, truncation, repricing) re-parses.
    private static func canResume(_ previous: FileAggregate, url: URL, size: Int, pricingKey: String) -> Bool {
        guard previous.pricingKey == pricingKey,
              !previous.readFailed,
              url.pathExtension.lowercased() == "jsonl",
              previous.parsedOffset > 0,
              size >= previous.parsedOffset,
              !previous.tailFingerprint.isEmpty
        else { return false }
        let start = previous.parsedOffset - previous.tailFingerprint.count
        return readBytes(url: url, offset: start, count: previous.tailFingerprint.count) == previous.tailFingerprint
    }

    private static func parseFile(
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        pricingKey: String,
        previous: FileAggregate?
    ) -> FileAggregate {
        let fresh = FileAggregate(
            mtime: mtime,
            size: size,
            pricingKey: pricingKey,
            state: ParseState(currentModel: defaultModel(for: providerID))
        )
        var aggregate = fresh
        if let previous, canResume(previous, url: url, size: size, pricingKey: pricingKey) {
            aggregate = previous
            aggregate.mtime = mtime
            aggregate.size = size
        }

        let needles = prefilterNeedles(for: providerID)
        let end = forEachLine(url: url, from: aggregate.parsedOffset) { base, count, trailing in
            if !trailing, !containsAny(base, count, needles) { return true }
            let object = try? JSONSerialization.jsonObject(with: Data(bytes: base, count: count))
            guard let object else { return !trailing }
            guard let json = object as? [String: Any], containsAny(base, count, needles) else { return true }
            consume(json, into: &aggregate, providerID: providerID)
            return true
        }

        guard let end else {
            var failed = fresh
            failed.readFailed = true
            return failed
        }
        aggregate.parsedOffset = end
        let fingerprintLength = min(tailFingerprintLength, end)
        aggregate.tailFingerprint = readBytes(url: url, offset: end - fingerprintLength, count: fingerprintLength) ?? Data()
        return aggregate
    }

    private static func consume(_ json: [String: Any], into aggregate: inout FileAggregate, providerID: String) {
        if let model = trackModel(from: json, providerID: providerID) {
            aggregate.state.currentModel = model
        }

        let usage: LineUsage?
        switch providerID {
        case "codex":
            usage = consumeCodex(json, state: &aggregate.state)
        case "claude":
            if let kiro = kiroProxyEntry(from: json, fallbackDate: aggregate.mtime) {
                aggregate.kiroEntries[kiro.key] = kiro.entry
                return
            }
            usage = extractClaudeUsage(from: json)
        case "gemini":
            guard let extracted = extractGeminiUsage(from: json, fallbackModel: aggregate.state.currentModel) else { return }
            if let messageID = json["id"] as? String, !messageID.isEmpty,
               !aggregate.state.seenGeminiMessageIDs.insert(messageID).inserted
            {
                return
            }
            usage = extracted
        default:
            usage = extractGenericUsage(from: json, fallbackModel: aggregate.state.currentModel)
        }
        guard let usage, !usage.parts.isEmpty else { return }

        // Attribute to the day the line happened (falls back to file mtime).
        let day = dayKey(for: usage.timestamp ?? aggregate.mtime)
        if let key = usage.dedupKey {
            aggregate.keyedRequests[key] = KeyedRequest(day: day, parts: usage.parts)
            return
        }
        var dayModels = aggregate.perDayModels[day] ?? [:]
        for part in usage.parts {
            dayModels[part.model, default: ModelBucket()].add(part.bucket)
        }
        aggregate.perDayModels[day] = dayModels
    }

    // MARK: - Streaming

    private static func prefilterNeedles(for providerID: String) -> [[UInt8]] {
        let strings: [String]
        switch providerID {
        case "codex": strings = ["token_count", "token_usage_record", "session_meta", "\"model"]
        case "claude": strings = ["\"usage\""]
        case "gemini": strings = ["\"tokens\"", "\"model"]
        default: strings = ["\"usage\"", "\"model"]
        }
        return strings.map { Array($0.utf8) }
    }

    private static func containsAny(_ base: UnsafeRawPointer, _ count: Int, _ needles: [[UInt8]]) -> Bool {
        needles.contains { needle in
            needle.withUnsafeBytes { memmem(base, count, $0.baseAddress, needle.count) != nil }
        }
    }

    /// Streams newline-separated lines starting at `offset`. `body` returns whether the line
    /// was consumed; an unterminated final line that is not yet valid JSON is left for the
    /// next pass. Returns the offset just past the last consumed line, or nil on read error.
    private static func forEachLine(
        url: URL,
        from offset: Int,
        _ body: (UnsafeRawPointer, Int, Bool) -> Bool
    ) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return nil
        }

        var buffer = Data()
        var bufferStart = offset
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: readChunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            let consumed = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var start = 0
                while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    if end > start { _ = body(base + start, end - start, false) }
                    start = end + 1
                }
                return start
            }
            if consumed > 0 {
                buffer.removeSubrange(0..<consumed)
                bufferStart += consumed
            }
        }

        if !buffer.isEmpty {
            let consumedTrailing = buffer.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return body(base, raw.count, true)
            }
            if consumedTrailing { bufferStart += buffer.count }
        }
        return bufferStart
    }

    private static func readBytes(url: URL, offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }

    // MARK: - Per-provider extraction

    private static func defaultModel(for providerID: String) -> String {
        switch providerID {
        case "codex": return "gpt-5.4" // current default family in local sessions
        case "claude": return "claude-sonnet-4"
        case "gemini": return "gemini-unknown"
        default: return providerID
        }
    }

    /// Returns a model name if this line *declares* one (turn_context / assistant), else nil.
    /// CodexBar: model lives on turn_context / session_meta; token_count lines use the last seen model.
    private static func trackModel(from json: [String: Any], providerID: String) -> String? {
        switch providerID {
        case "codex":
            let type = json["type"] as? String
            if let payload = json["payload"] as? [String: Any] {
                // session_meta / turn_context payload.model
                if let model = normalizeModel(stringValue(payload, keys: ["model", "model_name"])) {
                    return model
                }
                if let mode = payload["collaboration_mode"] as? [String: Any],
                   let settings = mode["settings"] as? [String: Any],
                   let model = normalizeModel(stringValue(settings, keys: ["model"]))
                {
                    return model
                }
                // Some builds nest model under info
                if let info = payload["info"] as? [String: Any],
                   let model = normalizeModel(stringValue(info, keys: ["model"]))
                {
                    return model
                }
            }
            // Top-level model on turn_context events
            if type == "turn_context" || type == "session_meta",
               let model = normalizeModel(stringValue(json, keys: ["model"]))
            {
                return model
            }
            return nil
        case "claude":
            return nil
        default:
            return normalizeModel(extractGenericModel(from: json))
        }
    }

    /// Codex: `token_usage_record` (exact per response) when the rollout has them, else the
    /// per-turn `token_count` delta. Replayed parent history in subagent and forked rollouts is skipped.
    private static func consumeCodex(_ json: [String: Any], state: inout ParseState) -> LineUsage? {
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any]

        if type == "session_meta" {
            if !state.codexSawSessionMeta {
                state.codexSawSessionMeta = true
                if let payload, payload["subagent_history_start_ordinal"] != nil {
                    state.codexHistoryStartOrdinal = intValue(payload, keys: ["subagent_history_start_ordinal"])
                } else if let payload, stringValue(payload, keys: ["forked_from_id"]) != nil {
                    state.codexSkipForkReplay = true
                    state.codexForkCreatedAtMs = uuidV7Milliseconds(stringValue(payload, keys: ["id"]))
                    let forkedAt = parseTimestamp(payload["timestamp"]) ?? parseTimestamp(json["timestamp"])
                    state.codexForkReplayDeadline = forkedAt?.addingTimeInterval(codexForkReplayBurst)
                }
            }
            return nil
        }

        if state.codexSkipForkReplay, endsForkReplay(json, type: type, payload: payload, state: state) {
            state.codexSkipForkReplay = false
        }

        let isReplay: Bool = {
            if state.codexSkipForkReplay { return true }
            guard let start = state.codexHistoryStartOrdinal, let ordinal = optionalInt(json["ordinal"]) else { return false }
            return ordinal < start
        }()

        if type == "token_usage_record" {
            guard !isReplay, let payload, let usage = payload["usage"] as? [String: Any] else { return nil }
            state.codexUsesRecords = true
            let model = normalizeModel(stringValue(payload, keys: ["model"])) ?? state.currentModel
            let key = stringValue(payload, keys: ["response_id"]).map { "codex-response:\($0)" }
                ?? "codex-record:\(stringValue(payload, keys: ["thread_id"]) ?? "")|\(optionalInt(json["ordinal"]) ?? -1)|\(stringValue(json, keys: ["timestamp"]) ?? "")"
            return codexLineUsage(usage, model: model, timestamp: parseTimestamp(json["timestamp"]), dedupKey: key)
        }

        guard type == "event_msg",
              let payload,
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return nil }

        if let total = info["total_token_usage"] as? [String: Any] {
            let cumulative = intValue(total, keys: ["total_tokens"])
            if cumulative == state.codexPrevCumulative { return nil }
            state.codexPrevCumulative = cumulative
        }
        // Use only the per-turn delta; total_token_usage is cumulative for the whole session.
        guard !isReplay, !state.codexUsesRecords, let last = info["last_token_usage"] as? [String: Any] else { return nil }

        let model = normalizeModel(stringValue(payload, keys: ["model"]))
            ?? normalizeModel(stringValue(info, keys: ["model"]))
            ?? state.currentModel
        return codexLineUsage(last, model: model, timestamp: parseTimestamp(json["timestamp"]), dedupKey: nil)
    }

    /// A fork without a subagent ordinal opens with a replay of the parent's turns, written in one burst.
    private static let codexForkReplayBurst: TimeInterval = 60

    /// Replay ends at the first turn whose UUIDv7 id postdates the fork, or the first line written after the burst.
    private static func endsForkReplay(_ json: [String: Any], type: String?, payload: [String: Any]?, state: ParseState) -> Bool {
        if let deadline = state.codexForkReplayDeadline, let at = parseTimestamp(json["timestamp"]), at > deadline {
            return true
        }
        let startsTurn = type == "turn_context" || (type == "event_msg" && (payload?["type"] as? String) == "task_started")
        guard startsTurn, let forkMs = state.codexForkCreatedAtMs,
              let turnMs = uuidV7Milliseconds(payload.flatMap { stringValue($0, keys: ["turn_id"]) })
        else { return false }
        return turnMs >= forkMs
    }

    /// Unix milliseconds in the leading 48 bits of a version-7 UUID, else nil.
    static func uuidV7Milliseconds(_ raw: String?) -> Int64? {
        guard let raw else { return nil }
        let hex = raw.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex[hex.index(hex.startIndex, offsetBy: 12)] == "7" else { return nil }
        return Int64(hex.prefix(12), radix: 16)
    }

    /// `input_tokens` includes cached reads and cache writes; the long-context tier is chosen
    /// from that full prompt size, per request.
    private static func codexLineUsage(_ usage: [String: Any], model: String, timestamp: Date?, dedupKey: String?) -> LineUsage? {
        let inputTokens = intValue(usage, keys: ["input_tokens"])
        let cachedInput = min(inputTokens, intValue(usage, keys: ["cached_input_tokens", "cache_read_input_tokens"]))
        let cacheWrite = min(max(0, inputTokens - cachedInput), intValue(usage, keys: ["cache_write_input_tokens"]))
        let outputTokens = intValue(usage, keys: ["output_tokens"])
        var total = intValue(usage, keys: ["total_tokens"])
        if total == 0 { total = inputTokens + outputTokens }
        if total == 0 { return nil }

        let uncached = max(0, inputTokens - cachedInput - cacheWrite)
        let cost = TokenPricingCatalog.requestCostUSD(
            model: model,
            uncachedInput: uncached,
            cacheRead: cachedInput,
            cacheWrite5m: cacheWrite,
            output: outputTokens,
            promptTokens: inputTokens
        )
        let bucket = ModelBucket(
            input: uncached,
            output: outputTokens,
            cacheRead: cachedInput,
            cacheWrite: cacheWrite,
            total: total,
            requests: 1,
            cost: cost
        )
        return LineUsage(parts: [UsagePart(model: model, bucket: bucket)], timestamp: timestamp, dedupKey: dedupKey)
    }

    private static func isKiroProxyModel(_ raw: String) -> Bool {
        raw.lowercased().hasPrefix(KiroDirectProvider.modelPrefix)
    }

    /// Claude: per assistant message under `message.usage`.
    private static func extractClaudeUsage(from json: [String: Any]) -> LineUsage? {
        guard (json["type"] as? String) == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let rawModel = stringValue(message, keys: ["model"])
        if let rawModel, isKiroProxyModel(rawModel) { return nil }
        let model = normalizeModel(rawModel) ?? "claude"
        // Skip Claude's internal synthetic/interrupt messages (<synthetic>).
        guard isPlausibleModel(model) else { return nil }

        let parts = claudeUsageParts(usage, model: model)
        guard !parts.isEmpty else { return nil }

        // Identity of the billed API request. Every content-block line of one turn (and any
        // copy in a resumed session's file) repeats it, so the scanner counts per key, not
        // per line. Keyless lines (very old logs) fall back to per-line counting.
        let messageID = stringValue(message, keys: ["id"])
        let requestID = stringValue(json, keys: ["requestId"])
        let dedupKey: String? = (messageID != nil || requestID != nil)
            ? "\(messageID ?? "")|\(requestID ?? "")"
            : nil

        return LineUsage(parts: parts, timestamp: parseTimestamp(json["timestamp"]), dedupKey: dedupKey)
    }

    /// Server-side fallback bills several sampling passes (`usage.iterations`), each on its own
    /// model; the top-level fields only describe the last one.
    private static func claudeUsageParts(_ usage: [String: Any], model: String) -> [UsagePart] {
        if let iterations = usage["iterations"] as? [[String: Any]], iterations.count > 1 {
            return iterations.enumerated().compactMap { index, iteration in
                let iterationModel = normalizeModel(stringValue(iteration, keys: ["model"])).flatMap { isPlausibleModel($0) ? $0 : nil }
                return anthropicPart(iteration, model: iterationModel ?? model, countsAsRequest: index == iterations.count - 1)
            }
        }
        return anthropicPart(usage, model: model, countsAsRequest: true).map { [$0] } ?? []
    }

    private static func anthropicPart(_ usage: [String: Any], model: String, countsAsRequest: Bool) -> UsagePart? {
        let input = intValue(usage, keys: ["input_tokens"])
        let output = intValue(usage, keys: ["output_tokens"])
        let cacheRead = intValue(usage, keys: ["cache_read_input_tokens"])
        let writes = cacheWriteSplit(usage)
        let cacheWrite = writes.fiveMinute + writes.oneHour
        let total = input + output + cacheRead + cacheWrite
        guard total > 0 else { return nil }
        let cost = TokenPricingCatalog.requestCostUSD(
            model: model,
            uncachedInput: input,
            cacheRead: cacheRead,
            cacheWrite5m: writes.fiveMinute,
            cacheWrite1h: writes.oneHour,
            output: output
        )
        let bucket = ModelBucket(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            total: total,
            requests: countsAsRequest ? 1 : 0,
            cost: cost
        )
        return UsagePart(model: model, bucket: bucket)
    }

    /// 5-minute vs 1-hour cache writes. Without a `cache_creation` breakdown every write is 5-minute.
    static func cacheWriteSplit(_ usage: [String: Any]) -> (fiveMinute: Int, oneHour: Int) {
        let flat = intValue(usage, keys: ["cache_creation_input_tokens", "cache_creation_tokens"])
        guard let breakdown = usage["cache_creation"] as? [String: Any] else { return (flat, 0) }
        let oneHour = intValue(breakdown, keys: ["ephemeral_1h_input_tokens"])
        let fiveMinute = intValue(breakdown, keys: ["ephemeral_5m_input_tokens"])
        let total = max(flat, fiveMinute + oneHour)
        return (total - oneHour, oneHour)
    }

    /// A `kiro/…` assistant line in a Claude Code transcript, as a Kiro ledger entry.
    private static func kiroProxyEntry(from json: [String: Any], fallbackDate: Date) -> (key: String, entry: KiroProxyUsageLedger.Entry)? {
        guard (json["type"] as? String) == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let rawModel = stringValue(message, keys: ["model"]),
              isKiroProxyModel(rawModel)
        else { return nil }
        let messageID = stringValue(message, keys: ["id"])
        guard let key = messageID ?? stringValue(json, keys: ["requestId"]) else { return nil }
        let upstream = String(rawModel.dropFirst(KiroDirectProvider.modelPrefix.count))
        let writes = cacheWriteSplit(usage)
        let entry = KiroProxyUsageLedger.Entry(
            id: "claude-log:\(key)",
            timestamp: parseTimestamp(json["timestamp"]) ?? fallbackDate,
            model: upstream.isEmpty ? rawModel : upstream,
            credits: nil,
            inputTokens: intValue(usage, keys: ["input_tokens"]),
            outputTokens: intValue(usage, keys: ["output_tokens"]),
            cacheReadTokens: intValue(usage, keys: ["cache_read_input_tokens"]),
            cacheWriteTokens: writes.fiveMinute + writes.oneHour,
            tokenSource: .claudeLog,
            contextUsagePercentage: nil,
            account: nil,
            accountUserHash: nil,
            claudeMessageID: messageID
        )
        return (key, entry)
    }

    /// Gemini CLI writes per-response lines as `{"type":"gemini","model":…,"timestamp":…,
    /// "tokens":{"input","output","cached","thoughts","tool","total"}}` — a TOP-LEVEL `tokens`
    /// object, NOT the OpenAI-style `usage` dict the generic extractor looks for.
    private static func extractGeminiUsage(from json: [String: Any], fallbackModel: String) -> LineUsage? {
        guard (json["type"] as? String) == "gemini",
              let tokens = json["tokens"] as? [String: Any]
        else { return nil }
        let model = normalizeModel(stringValue(json, keys: ["model"])) ?? fallbackModel
        guard isPlausibleModel(model) else { return nil }

        let b = geminiTokenBreakdown(tokens)
        if b.total == 0 { return nil }
        let cost = TokenPricingCatalog.requestCostUSD(
            model: model,
            uncachedInput: b.nonCachedInput,
            cacheRead: b.cacheRead,
            output: b.billedOutput
        )
        let bucket = ModelBucket(
            input: b.nonCachedInput,
            output: b.billedOutput,
            cacheRead: b.cacheRead,
            total: b.total,
            requests: 1,
            cost: cost
        )
        return LineUsage(parts: [UsagePart(model: model, bucket: bucket)], timestamp: parseTimestamp(json["timestamp"]))
    }

    /// Pure token math for a Gemini `tokens` object. `input` (promptTokenCount) already
    /// includes `cached`; `tool` (toolUsePromptTokenCount) is billed as input on top of it;
    /// thinking tokens (`thoughts`) are billed as output.
    static func geminiTokenBreakdown(_ tokens: [String: Any]) -> (nonCachedInput: Int, billedOutput: Int, cacheRead: Int, total: Int) {
        let rawInput = intValue(tokens, keys: ["input"])
        let cached = min(rawInput, intValue(tokens, keys: ["cached"]))
        let tool = intValue(tokens, keys: ["tool"])
        let output = intValue(tokens, keys: ["output"])
        let thoughts = intValue(tokens, keys: ["thoughts"])
        let nonCachedInput = max(0, rawInput - cached) + tool
        let billedOutput = output + thoughts
        let declared = intValue(tokens, keys: ["total"])
        let total = declared > 0 ? declared : rawInput + tool + output + thoughts
        return (nonCachedInput, billedOutput, cached, total)
    }

    /// Best-effort for other providers. Only counts lines with both a usage dict and a
    /// *plausible* model, so session titles / junk never show up as "random models".
    private static func extractGenericUsage(from json: [String: Any], fallbackModel: String) -> LineUsage? {
        guard let usage = genericUsageDict(from: json) else { return nil }
        let model = normalizeModel(extractGenericModel(from: json)) ?? fallbackModel
        guard isPlausibleModel(model) else { return nil }

        let input = intValue(usage, keys: ["input_tokens", "prompt_tokens", "inputTokens", "promptTokens"])
        let output = intValue(usage, keys: ["output_tokens", "completion_tokens", "outputTokens", "completionTokens"])
        let cacheRead = intValue(usage, keys: [
            "cache_read_input_tokens", "cache_read_tokens", "cacheReadInputTokens", "cached_tokens",
        ])
        let writes = cacheWriteSplit(usage)
        let cacheWrite = writes.fiveMinute + writes.oneHour
        let total = input + output + cacheRead + cacheWrite
        if total == 0 { return nil }

        let cost = TokenPricingCatalog.requestCostUSD(
            model: model,
            uncachedInput: input,
            cacheRead: cacheRead,
            cacheWrite5m: writes.fiveMinute,
            cacheWrite1h: writes.oneHour,
            output: output
        )
        let bucket = ModelBucket(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            total: total,
            requests: 1,
            cost: cost
        )
        return LineUsage(parts: [UsagePart(model: model, bucket: bucket)], timestamp: parseTimestamp(json["timestamp"]))
    }

    private static func genericUsageDict(from json: [String: Any]) -> [String: Any]? {
        if let usage = json["usage"] as? [String: Any] { return usage }
        if let message = json["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
            return usage
        }
        if let response = json["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
            return usage
        }
        if let body = json["body"] as? [String: Any], let usage = body["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private static func extractGenericModel(from json: [String: Any]) -> String? {
        // NOTE: "slug" intentionally excluded — it is a session title in Claude logs and
        // was the main cause of bogus "models" in analytics.
        if let direct = stringValue(json, keys: ["model", "model_name", "modelName"]) { return direct }
        if let message = json["message"] as? [String: Any],
           let m = stringValue(message, keys: ["model", "model_name"]) { return m }
        if let request = json["request"] as? [String: Any],
           let m = stringValue(request, keys: ["model", "model_name"]) { return m }
        return nil
    }

    // MARK: - Model helpers

    private static func normalizeModel(_ raw: String?) -> String? {
        TokenPricingCatalog.normalizeModelID(raw)
    }

    /// Rejects session titles, `<synthetic>`, prose, and other non-model strings.
    private static func isPlausibleModel(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.isEmpty || n == "unknown" { return false }
        if n.hasPrefix("<") { return false }        // <synthetic>
        if n.count > 80 { return false }
        if n.contains(" ") { return false }         // titles / sentences
        let families = [
            "gpt", "o1", "o3", "o4", "codex", "claude", "sonnet", "opus", "haiku",
            "gemini", "grok", "glm", "qwen", "kimi", "moonshot", "deepseek",
            "llama", "mistral", "gemma", "flash", "pro", "command", "nova",
            "kiro", "copilot", "opencode", "auto",
        ]
        return families.contains { n.contains($0) }
    }

    // MARK: - Primitive helpers

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let s = value as? String, !s.isEmpty {
            return isoFormatterWithFraction.date(from: s) ?? isoFormatter.date(from: s)
        }
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        }
        if let ms = value as? Int {
            let d = Double(ms)
            return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
        }
        return nil
    }

    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func intValue(_ dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let v = optionalInt(dict[key]) { return v }
        }
        return 0
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return JSONNumber.int(from: v) }
        if let v = value as? NSNumber { return JSONNumber.int(from: v.doubleValue) }
        if let v = value as? String, let i = Int(v) { return i }
        if let v = value as? String, let d = Double(v) { return JSONNumber.int(from: d) }
        return nil
    }

    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// Drop cache entries for files that no longer exist under the scanned roots,
    /// so the in-memory cache can't grow unbounded over time.
    private static func pruneCache(keeping liveKeys: Set<String>, roots: [URL]) {
        let rootPaths = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        fileCache = fileCache.filter { path, _ in
            // Keep entries outside these roots (other providers) untouched.
            let belongsToScan = rootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            return !belongsToScan || liveKeys.contains(path)
        }
    }
}
