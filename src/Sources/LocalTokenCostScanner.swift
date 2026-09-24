import Foundation

// `UsageVolumeUnit` lives in UsageVolumeUnit.swift.

struct ModelTokenUsage: Equatable, Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    /// Volume in `volumeUnit` (tokens, millicredits, or estimated tokens).
    let totalTokens: Int
    let estimatedCostUSD: Double
    let requestCount: Int
    let volumeUnit: UsageVolumeUnit

    init(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        totalTokens: Int,
        estimatedCostUSD: Double,
        requestCount: Int,
        volumeUnit: UsageVolumeUnit = .tokens
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.requestCount = requestCount
        self.volumeUnit = volumeUnit
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
        updatedAt: Date? = Date()
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
            updatedAt: updatedAt
        )
    }
}

/// Scans local CLI session logs (Codex `rollout-*.jsonl`, Claude `projects/**/*.jsonl`, …)
/// to estimate token volume, per-model breakdown, and API-equivalent $ per provider.
///
/// Correctness notes (these were the source of the "wrong info / random models" bug):
/// - Codex stores usage in `payload.info.last_token_usage` (per-turn delta) and
///   `payload.info.total_token_usage` (cumulative). We sum the *deltas* so we never
///   double count, and attribute them to the model from the preceding `turn_context`.
/// - Claude writes ONE line per content block of an assistant turn, each repeating that
///   API request's usage (`message.id`/`requestId` identical, `output_tokens` growing
///   until the final line). Requests are deduped by that identity — last line wins —
///   including across files, since a resumed session copies history into a new jsonl.
///   Summing every line over-counted tokens and $ ~2.4× (verified against ccusage).
/// - Model names are validated so session titles (`slug`), `<synthetic>`, and other
///   junk never appear as "models".
/// - Providers only scan their own log trees (no gemini/antigravity overlap), and files
///   are de-duplicated by resolved path.
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
    ///
    /// Coverage matches `allProviderSnapshots`, deliberately: a provider omitted here
    /// would make the by-date view under-report the very same day the Overview reports
    /// correctly, which reads as a bug rather than as caution. Providers whose day
    /// attribution is weaker instead carry an honest `DailyUsageFidelity` and the UI shows
    /// the caveat — Grok pins a whole session's estimate to its last-activity day, and
    /// Copilot's transcripts never name the answering model.
    static func allProviderDailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [[UsageDayKey: DailyProviderUsage]] {
        var results: [[UsageDayKey: DailyProviderUsage]] = []

        // Per-event timestamps in jsonl trees → exact per-day, per-model attribution.
        // Antigravity is handled by LocalAntigravityUsage (conversation DBs), not the empty ~/.antigravity tree.
        let jsonlTypes: [ServiceType] = [.codex, .claude, .gemini]
        for type in jsonlTypes {
            if let daily = dailyUsage(for: type, now: now, historyDays: historyDays), !daily.isEmpty {
                results.append(daily)
            }
        }

        // Specialized aggregators, each reporting its own fidelity:
        //   Kiro         — per-turn credit metering, exact.
        //   OpenCode     — per-turn `message` rows, exact when they name a model.
        //   Antigravity  — IDE conversation gen_metadata, sessionApproximate.
        //   Grok         — occupancy snapshot on last-activity day; tmp sessions skipped.
        //   Cursor       — composer context meter / bubble tokens, sessionApproximate.
        //   Copilot      — real day totals, no model dimension, dayTotalsOnly.
        // Copilot has no generic-tree fallback here (unlike allProviderSnapshots): the
        // generic scan buckets by file mtime, which would pin an append-only transcript's
        // whole history onto the day it was last reopened.
        let specialized: [() -> [UsageDayKey: DailyProviderUsage]] = [
            { LocalKiroCredits.dailyUsage(now: now, historyDays: historyDays) },
            { LocalOpenCodeUsage.dailyUsage(now: now, historyDays: historyDays) },
            { LocalAntigravityUsage.dailyUsage(now: now, historyDays: historyDays) },
            { LocalGrokUsage.dailyUsage(now: now, historyDays: historyDays) },
            { LocalCursorUsage.dailyUsage(now: now, historyDays: historyDays) },
            { LocalCopilotUsage.dailyUsage(now: now, historyDays: historyDays) },
        ]
        for block in specialized {
            autoreleasepool {
                let daily = block()
                if !daily.isEmpty { results.append(daily) }
            }
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
        take("copilot") {
            LocalCopilotUsage.costSnapshot(now: now, historyDays: historyDays)
                ?? snapshot(for: .copilot, now: now, historyDays: historyDays)
        }

        NSLog("[UsageScan] snapshots=%d providers=%@", results.count, results.map(\.providerID).joined(separator: ","))
        return results
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
            return ScanRoots(providerID: "copilot", directories: [
                home.appendingPathComponent(".copilot"),
                home.appendingPathComponent(".config/github-copilot"),
            ])
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
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    /// One usage record extracted from a single log line.
    private struct LineUsage {
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let total: Int
        let cost: Double
        let timestamp: Date?
        /// Stable per-request identity (Claude `message.id`|`requestId`). Lines sharing it
        /// describe the same billed API request and must be counted once, last line wins.
        var dedupKey: String? = nil
    }

    /// Final usage snapshot for one deduplicatable API request within a file.
    private struct KeyedRequest {
        let day: Int
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let total: Int
        let cost: Double
    }

    /// Per-file parsed result, cached by (path, mtime, size) so unchanged files are
    /// never re-parsed. Keeps CPU flat even with large 30-day histories.
    /// Buckets are kept per-day so the 30-day cutoff (and "today") are applied at
    /// aggregation time — the cache stays valid across day boundaries.
    private struct FileAggregate {
        let mtime: Date
        let size: Int
        /// day-start epoch (local) -> (model -> bucket), for lines with no request identity
        var perDayModels: [Int: [String: ModelBucket]]
        /// request identity -> final usage snapshot. Deduped globally in `scanPerDay` so a
        /// request repeated across content-block lines or copied into a resumed session's
        /// file is counted exactly once.
        var keyedRequests: [String: KeyedRequest] = [:]
    }

    private static let cacheLock = NSLock()
    private static var fileCache: [String: FileAggregate] = [:]

    // MARK: - Scan

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
    ) -> [Int: [String: ModelBucket]] {
        let fileManager = FileManager.default
        // CodexBar: rolling window is inclusive — 30-day display starts 29 days before now.
        let lookback = max(0, historyDays - 1)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
        let cutoff = Calendar.current.startOfDay(for: cutoffDate)
        let cutoffDay = dayKey(for: cutoff)

        var perDay: [Int: [String: ModelBucket]] = [:]
        var seenPaths = Set<String>()
        var liveKeys = Set<String>()
        var seenRequestKeys = Set<String>()

        for root in directories where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "jsonl" || ext == "json" else { continue }

                // De-dup overlapping roots / symlinks.
                let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(canonical).inserted else { continue }

                guard let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ) else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let size = values.fileSize ?? 0

                // Skip files last touched before the history window and huge dumps.
                // NOTE: this is why a fresh scan cannot see arbitrarily far back — a file
                // untouched since before the window is never opened, so days inside the
                // window that live in an old file are invisible until persistence accrues.
                guard modified >= cutoff else { continue }
                if size > 60_000_000 { continue }

                liveKeys.insert(canonical)
                let aggregate = fileAggregate(
                    path: canonical,
                    url: fileURL,
                    providerID: providerID,
                    mtime: modified,
                    size: size,
                    cutoff: cutoff
                )

                // Only keep days within the history window.
                for (day, models) in aggregate.perDayModels where day >= cutoffDay {
                    var dayModels = perDay[day] ?? [:]
                    for (model, bucket) in models {
                        var merged = dayModels[model] ?? ModelBucket()
                        merged.input += bucket.input
                        merged.output += bucket.output
                        merged.cacheRead += bucket.cacheRead
                        merged.total += bucket.total
                        merged.requests += bucket.requests
                        merged.cost += bucket.cost
                        dayModels[model] = merged
                    }
                    perDay[day] = dayModels
                }

                // Identified requests are deduped across every scanned file: duplicates carry
                // identical usage, so whichever file is enumerated first can safely win.
                for (key, request) in aggregate.keyedRequests where request.day >= cutoffDay {
                    guard seenRequestKeys.insert(key).inserted else { continue }
                    var dayModels = perDay[request.day] ?? [:]
                    var merged = dayModels[request.model] ?? ModelBucket()
                    merged.input += request.input
                    merged.output += request.output
                    merged.cacheRead += request.cacheRead
                    merged.total += request.total
                    merged.requests += 1
                    merged.cost += request.cost
                    dayModels[request.model] = merged
                    perDay[request.day] = dayModels
                }
            }
        }

        pruneCache(keeping: liveKeys, roots: directories)
        return perDay
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
        let perDay = scanPerDay(
            providerID: roots.providerID,
            directories: roots.directories,
            now: now,
            historyDays: historyDays
        )
        return dailyProviderUsage(providerID: roots.providerID, perDay: perDay)
    }

    /// Converts raw day buckets into the shared date-indexed model.
    /// These trees carry per-event timestamps, so fidelity is `.exact`.
    private static func dailyProviderUsage(
        providerID: String,
        perDay: [Int: [String: ModelBucket]]
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
                fidelity: .exact
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
        )
        let todayKey = dayKey(for: now)

        var totalBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0

        // Attribute "today" precisely; everything in the window feeds the rolling total.
        for (day, models) in perDay {
            let isToday = (day == todayKey)
            for (model, bucket) in models {
                var merged = totalBuckets[model] ?? ModelBucket()
                merged.input += bucket.input
                merged.output += bucket.output
                merged.cacheRead += bucket.cacheRead
                merged.total += bucket.total
                merged.requests += bucket.requests
                merged.cost += bucket.cost
                totalBuckets[model] = merged

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

    private static func fileAggregate(
        path: String,
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        cutoff: Date
    ) -> FileAggregate {
        cacheLock.lock()
        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let parsed = parseFile(url: url, providerID: providerID, mtime: mtime, size: size, cutoff: cutoff)

        cacheLock.lock()
        fileCache[path] = parsed
        cacheLock.unlock()
        return parsed
    }

    private static func parseFile(
        url: URL,
        providerID: String,
        mtime: Date,
        size: Int,
        cutoff: Date
    ) -> FileAggregate {
        var perDayModels: [Int: [String: ModelBucket]] = [:]
        var keyedRequests: [String: KeyedRequest] = [:]

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8)
        else {
            return FileAggregate(mtime: mtime, size: size, perDayModels: perDayModels)
        }

        // Track the active model across a Codex session (usage lines carry no model).
        var currentModel = defaultModel(for: providerID)
        // Codex re-emits `token_count` events on rate-limit refreshes with an identical
        // `last_token_usage` while `total_token_usage` is unchanged; summing that delta again
        // over-counts (~4% on active sessions). Skip events whose cumulative hasn't advanced.
        var codexPrevCumulative = -1
        // Gemini CLI rewrites the same assistant message: first a plain `type:gemini` line,
        // then the same `id` again with `toolCalls` attached and identical `tokens`. Summing
        // both ~2× inflates analytics. Dedup by message id within the file.
        var seenGeminiMessageIDs = Set<String>()

        for line in content.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard let lineData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let model = trackModel(from: json, providerID: providerID) {
                currentModel = model
            }

            if providerID == "codex",
               (json["type"] as? String) == "event_msg",
               let payload = json["payload"] as? [String: Any],
               (payload["type"] as? String) == "token_count",
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any]
            {
                let cumulative = intValue(total, keys: ["total_tokens"])
                if cumulative == codexPrevCumulative { continue }
                codexPrevCumulative = cumulative
            }

            if providerID == "gemini",
               let messageID = json["id"] as? String, !messageID.isEmpty
            {
                if !seenGeminiMessageIDs.insert(messageID).inserted { continue }
            }

            guard let usage = extractUsage(
                from: json,
                providerID: providerID,
                fallbackModel: currentModel
            ) else { continue }

            // Attribute to the day the line happened (falls back to file mtime).
            let day = dayKey(for: usage.timestamp ?? mtime)

            // Lines with a request identity are collected last-write-wins: only the final
            // content-block line of a Claude turn carries the fully-billed output_tokens.
            if let key = usage.dedupKey {
                keyedRequests[key] = KeyedRequest(
                    day: day,
                    model: usage.model,
                    input: usage.input,
                    output: usage.output,
                    cacheRead: usage.cacheRead,
                    total: usage.total,
                    cost: usage.cost
                )
                continue
            }

            var dayModels = perDayModels[day] ?? [:]
            var bucket = dayModels[usage.model] ?? ModelBucket()
            bucket.input += usage.input
            bucket.output += usage.output
            bucket.cacheRead += usage.cacheRead
            bucket.total += usage.total
            bucket.requests += 1
            bucket.cost += usage.cost
            dayModels[usage.model] = bucket
            perDayModels[day] = dayModels
        }

        return FileAggregate(mtime: mtime, size: size, perDayModels: perDayModels, keyedRequests: keyedRequests)
    }

    // MARK: - Per-provider extraction

    private static func defaultModel(for providerID: String) -> String {
        switch providerID {
        case "codex": return "gpt-5.4" // current default family in local sessions
        case "claude": return "claude-sonnet-4"
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
            // Prefer explicit assistant model for sticky fallback
            if (json["type"] as? String) == "assistant",
               let message = json["message"] as? [String: Any],
               let model = normalizeModel(stringValue(message, keys: ["model"]))
            {
                return model
            }
            return nil
        default:
            return normalizeModel(extractGenericModel(from: json))
        }
    }

    private static func extractUsage(
        from json: [String: Any],
        providerID: String,
        fallbackModel: String
    ) -> LineUsage? {
        switch providerID {
        case "codex":
            return extractCodexUsage(from: json, fallbackModel: fallbackModel)
        case "claude":
            return extractClaudeUsage(from: json)
        case "gemini":
            return extractGeminiUsage(from: json)
        default:
            return extractGenericUsage(from: json, fallbackModel: fallbackModel)
        }
    }

    /// Codex: `payload.info.last_token_usage` (per-turn delta). We deliberately use the
    /// delta, not the cumulative `total_token_usage`, so multi-turn sessions aren't inflated.
    private static func extractCodexUsage(from json: [String: Any], fallbackModel: String) -> LineUsage? {
        guard (json["type"] as? String) == "event_msg",
              let payload = json["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return nil }

        let usageDict = (info["last_token_usage"] as? [String: Any])
        // Use only the per-turn delta. total_token_usage is cumulative for the whole
        // session, so summing it across token_count events would massively double count.
        guard let usageDict else { return nil }

        let inputTokens = intValue(usageDict, keys: ["input_tokens"])
        let cachedInput = intValue(usageDict, keys: ["cached_input_tokens"])
        let outputTokens = intValue(usageDict, keys: ["output_tokens"])
        var total = intValue(usageDict, keys: ["total_tokens"])
        if total == 0 { total = inputTokens + outputTokens }
        if total == 0 { return nil }

        // Prefer model stamped on this event if present; else sticky turn_context model.
        let model = normalizeModel(stringValue(payload, keys: ["model"]))
            ?? normalizeModel(stringValue(info, keys: ["model"]))
            ?? fallbackModel
        let nonCachedInput = max(0, inputTokens - cachedInput)
        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: nonCachedInput,
            outputTokens: outputTokens,
            cacheReadTokens: cachedInput
        )

        return LineUsage(
            model: model,
            input: inputTokens,
            output: outputTokens,
            cacheRead: cachedInput,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
    }

    /// Claude: per assistant message under `message.usage`.
    private static func extractClaudeUsage(from json: [String: Any]) -> LineUsage? {
        guard (json["type"] as? String) == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = normalizeModel(stringValue(message, keys: ["model"])) ?? "claude"
        // Skip Claude's internal synthetic/interrupt messages (<synthetic>).
        guard isPlausibleModel(model) else { return nil }

        let input = intValue(usage, keys: ["input_tokens"])
        let output = intValue(usage, keys: ["output_tokens"])
        let cacheCreate = intValue(usage, keys: ["cache_creation_input_tokens"])
        let cacheRead = intValue(usage, keys: ["cache_read_input_tokens"])
        let total = input + output + cacheCreate + cacheRead
        if total == 0 { return nil }

        // CodexBar: cache write = cacheCreation rate (≈1.25× input); cache read discounted.
        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheCreate
        )

        // Identity of the billed API request. Every content-block line of one turn (and any
        // copy in a resumed session's file) repeats it, so the scanner counts per key, not
        // per line. Keyless lines (very old logs) fall back to per-line counting.
        let messageID = stringValue(message, keys: ["id"])
        let requestID = stringValue(json, keys: ["requestId"])
        let dedupKey: String? = (messageID != nil || requestID != nil)
            ? "\(messageID ?? "")|\(requestID ?? "")"
            : nil

        return LineUsage(
            model: model,
            input: input + cacheCreate,
            output: output,
            cacheRead: cacheRead,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"]),
            dedupKey: dedupKey
        )
    }

    /// Gemini CLI writes per-response lines as `{"type":"gemini","model":…,"timestamp":…,
    /// "tokens":{"input","output","cached","thoughts","total"}}` — a TOP-LEVEL `tokens`
    /// object, NOT the OpenAI-style `usage` dict the generic extractor looks for. Without a
    /// dedicated path, every Gemini line was dropped and Gemini analytics were always empty.
    private static func extractGeminiUsage(from json: [String: Any]) -> LineUsage? {
        guard (json["type"] as? String) == "gemini",
              let tokens = json["tokens"] as? [String: Any]
        else { return nil }
        let model = normalizeModel(stringValue(json, keys: ["model"])) ?? "gemini"
        guard isPlausibleModel(model) else { return nil }

        let b = geminiTokenBreakdown(tokens)
        if b.total == 0 { return nil }
        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: b.nonCachedInput,
            outputTokens: b.billedOutput,
            cacheReadTokens: b.cacheRead
        )
        return LineUsage(
            model: model,
            input: b.nonCachedInput,
            output: b.billedOutput,
            cacheRead: b.cacheRead,
            total: b.total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
    }

    /// Pure token math for a Gemini `tokens` object. `input` (promptTokenCount) already
    /// includes `cached`, so non-cached input is `input - cached`; thinking tokens (`thoughts`)
    /// are billed as output. `internal` so the self-check can pin the schema mapping.
    static func geminiTokenBreakdown(_ tokens: [String: Any]) -> (nonCachedInput: Int, billedOutput: Int, cacheRead: Int, total: Int) {
        let rawInput = intValue(tokens, keys: ["input"])
        let cached = intValue(tokens, keys: ["cached"])
        let output = intValue(tokens, keys: ["output"])
        let thoughts = intValue(tokens, keys: ["thoughts"])
        let nonCachedInput = max(0, rawInput - cached)
        let billedOutput = output + thoughts
        let declared = intValue(tokens, keys: ["total"])
        let total = declared > 0 ? declared : nonCachedInput + billedOutput + cached
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
        let cacheCreate = intValue(usage, keys: ["cache_creation_input_tokens", "cache_creation_tokens"])
        let total = input + output + cacheRead + cacheCreate
        if total == 0 { return nil }

        let cost = TokenPricingCatalog.estimateUSD(
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheCreate
        )

        return LineUsage(
            model: model,
            input: input + cacheCreate,
            output: output,
            cacheRead: cacheRead,
            total: total,
            cost: cost,
            timestamp: parseTimestamp(json["timestamp"])
        )
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
            guard let raw = dict[key] else { continue }
            switch raw {
            case is Int, is Double, is NSNumber, is String:
                return JSONNumber.int(raw)
            default:
                continue
            }
        }
        return 0
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
