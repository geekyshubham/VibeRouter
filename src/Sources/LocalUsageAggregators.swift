import Foundation
import SQLite3

func analyticsCutoffStart(now: Date, historyDays: Int) -> Date {
    let lookback = max(0, historyDays - 1)
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
    return Calendar.current.startOfDay(for: cutoffDate)
}

/// `Int(Double)` traps on NaN / Inf / values outside Int (`EXC_BREAKPOINT`).
/// JSONSerialization boxes every number as Double-backed NSNumber, so a quota
/// field of `1e20` or a sentinel used to kill the menu-bar app during a scan.
enum JSONNumber {
    static func int(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return int(from: n) }
        if let n = raw as? NSNumber { return int(from: n.doubleValue) }
        if let s = raw as? String {
            if let i = Int(s) { return i }
            if let d = Double(s) { return int(from: d) }
        }
        return 0
    }

    static func int(from value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}

// MARK: - Kiro local credits (session JSON metering)

/// Reads `~/.kiro/sessions/cli/*.json` turn metadata (`metering_usage` credit arrays).
/// The GetUsageLimits API often under-reports free-tier burn; local metering matches kiro-cli.
enum LocalKiroCredits {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, dayCredits: [Int: Double], dayModels: [Int: [String: (credits: Double, requests: Int)]])] = [:]

    /// Credits consumed in sessions updated on/after `since` (inclusive).
    static func creditsUsed(since: Date, now: Date = Date()) -> Double {
        let dayMap = creditByDay(now: now, cutoffStart: Calendar.current.startOfDay(for: since))
        let sinceKey = dayKey(for: since)
        return dayMap.filter { $0.key >= sinceKey }.values.reduce(0, +)
    }

    /// Analytics snapshot from **local session metering** over the rolling `historyDays` window.
    ///
    /// CodexBar convention: `kiro-cli /usage` is **billing-period quota** only (menu bar).
    /// It must not overwrite rolling analytics — a period reset (`creditsUsed == 0`) would zero
    /// history, and mid-period CLI totals are a different time base than last-N-days.
    /// Cost is always API-equivalent `credits × $0.04` (not overage invoice $).
    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit) -> ProviderCostSnapshot? {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let byDay = detailedByDay(now: now, cutoffStart: cutoffStart)
        let today = dayKey(for: now)
        let cutoff = dayKey(for: cutoffStart)

        var modelBuckets: [String: (credits: Double, requests: Int)] = [:]
        var sessionCredits = 0.0
        var historyCredits = 0.0

        for (day, models) in byDay where day >= cutoff {
            for (model, bucket) in models {
                var acc = modelBuckets[model] ?? (0, 0)
                acc.credits += bucket.credits
                acc.requests += bucket.requests
                modelBuckets[model] = acc
                historyCredits += bucket.credits
                if day == today { sessionCredits += bucket.credits }
            }
        }

        NSLog(
            "[UsageScan] kiro: credits30d=%.2f today=%.2f models=%d",
            historyCredits, sessionCredits, modelBuckets.count
        )
        guard historyCredits > 0.001 || !modelBuckets.isEmpty else {
            return nil
        }

        let models = modelBuckets.map { model, bucket in
            let credits = bucket.credits
            // Millicredits for sub-credit precision; volumeUnit=.credits keeps them out of token totals.
            let milli = Int((credits * 1000).rounded())
            let cost = max(0, credits) * usdPerCredit
            let displayModel = TokenPricingCatalog.normalizeModelID(model) ?? model
            return ModelTokenUsage(
                model: displayModel,
                inputTokens: milli,
                outputTokens: 0,
                cacheReadTokens: 0,
                totalTokens: milli,
                estimatedCostUSD: cost,
                requestCount: bucket.requests,
                volumeUnit: .credits
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        let historyCost = max(0, historyCredits) * usdPerCredit
        let sessionCost = max(0, sessionCredits) * usdPerCredit

        return ProviderCostSnapshot.make(
            providerID: "kiro",
            sessionTokens: Int((sessionCredits * 1000).rounded()),
            sessionCostUSD: sessionCost,
            last30DaysTokens: Int((historyCredits * 1000).rounded()),
            last30DaysCostUSD: historyCost,
            models: models.isEmpty
                ? [
                    ModelTokenUsage(
                        model: "kiro",
                        inputTokens: Int((historyCredits * 1000).rounded()),
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        totalTokens: Int((historyCredits * 1000).rounded()),
                        estimatedCostUSD: historyCost,
                        requestCount: 1,
                        volumeUnit: .credits
                    )
                ]
                : models,
            volumeUnit: .credits,
            updatedAt: now
        )
    }

    /// Per-day, per-model credit usage for the date-indexed views.
    ///
    /// Fidelity is `.exact`: `metering_usage` carries per-turn credits with a real
    /// timestamp, so a day's figure is genuinely that day's spend — not a session total
    /// pinned to one date.
    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30,
        usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit
    ) -> [UsageDayKey: DailyProviderUsage] {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let byDay = detailedByDay(now: now, cutoffStart: cutoffStart)
        let cutoffDay = dayKey(for: cutoffStart)

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        // Out-of-window days must be dropped, not merely ignored. `detailedByDay` filters
        // *files* by mtime, so a session touched today still yields turns from before the
        // window — but only from the files that happened to be touched, making such a day's
        // figure partial. UsageDailyStore.record replaces per (day, provider), so writing a
        // partial old day would overwrite the complete record persisted while it was current.
        for (day, models) in byDay where day >= cutoffDay {
            let rows = models.compactMap { model, bucket -> DailyModelUsage? in
                guard bucket.credits > 0 || bucket.requests > 0 else { return nil }
                // Millicredits keep sub-credit precision; .credits keeps them out of token totals.
                let milli = Int((bucket.credits * 1000).rounded())
                let displayModel = TokenPricingCatalog.normalizeModelID(model) ?? model
                return DailyModelUsage(
                    model: displayModel,
                    inputTokens: milli,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    totalVolume: milli,
                    estimatedCostUSD: max(0, bucket.credits) * usdPerCredit,
                    requestCount: bucket.requests,
                    volumeUnit: .credits
                )
            }
            .sorted { $0.totalVolume > $1.totalVolume }

            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "kiro",
                models: rows,
                volumeUnit: .credits,
                fidelity: .exact
            )
        }
        return result
    }

    private static func creditByDay(now: Date, cutoffStart: Date) -> [Int: Double] {
        detailedByDay(now: now, cutoffStart: cutoffStart).mapValues { models in
            models.values.reduce(0) { $0 + $1.credits }
        }
    }

    private static func detailedByDay(now: Date, cutoffStart: Date) -> [Int: [String: (credits: Double, requests: Int)]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".kiro/sessions/cli")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }

        var result: [Int: [String: (credits: Double, requests: Int)]] = [:]
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json" else { continue }
            // Skip companion jsonl / nested dirs' non-session files by basename UUID-ish check later.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            guard mtime >= cutoffStart, size > 50, size < 80_000_000 else { continue }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let parsed = parseSessionFile(path: path, url: url, mtime: mtime, size: size)
            for (day, models) in parsed.dayModels {
                var dayMap = result[day] ?? [:]
                for (model, bucket) in models {
                    var acc = dayMap[model] ?? (0, 0)
                    acc.credits += bucket.credits
                    acc.requests += bucket.requests
                    dayMap[model] = acc
                }
                result[day] = dayMap
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()
        return result
    }

    private static func parseSessionFile(
        path: String,
        url: URL,
        mtime: Date,
        size: Int
    ) -> (dayCredits: [Int: Double], dayModels: [Int: [String: (credits: Double, requests: Int)]]) {
        cacheLock.lock()
        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return (cached.dayCredits, cached.dayModels)
        }
        cacheLock.unlock()

        var dayCredits: [Int: Double] = [:]
        var dayModels: [Int: [String: (credits: Double, requests: Int)]] = [:]

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ([:], [:])
        }

        let sessionState = json["session_state"] as? [String: Any]
        let modelInfo = (sessionState?["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        let sessionModel = (modelInfo?["model_id"] as? String)
            ?? (modelInfo?["model_name"] as? String)
            ?? "kiro"

        let turns = ((sessionState?["conversation_metadata"] as? [String: Any])?["user_turn_metadatas"] as? [[String: Any]])
            ?? []

        // A resumed/rewritten session has mtime=today but may hold turns from earlier days.
        // Fall back to the session's stable created_at day (written once), NOT the file's
        // rewrite time, so prior-day turns can't spill into "today". Per-turn end_timestamp
        // still wins when present.
        let fallbackDay = (json["created_at"] as? String).flatMap(parseKiroDate).map { dayKey(for: $0) }
            ?? dayKey(for: mtime)
        for turn in turns {
            let credits = sumCredits(turn["metering_usage"])
            guard credits > 0 else { continue }
            let model = turnModel(turn["model"]) ?? sessionModel
            let tsDay = resolveTurnDayKey(endTimestamp: turn["end_timestamp"] as? String, fallbackDayKey: fallbackDay)
            dayCredits[tsDay, default: 0] += credits
            var models = dayModels[tsDay] ?? [:]
            var bucket = models[model] ?? (0, 0)
            bucket.credits += credits
            bucket.requests += 1
            models[model] = bucket
            dayModels[tsDay] = models
        }

        cacheLock.lock()
        fileCache[path] = (mtime, size, dayCredits, dayModels)
        cacheLock.unlock()
        return (dayCredits, dayModels)
    }

    /// Per-turn `model` wins. A session can switch to Claude Opus 5.5 mid-way;
    /// filing every turn under `rts_model_state` hides that model's credits.
    private static func turnModel(_ raw: Any?) -> String? {
        guard let name = raw as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sumCredits(_ raw: Any?) -> Double {
        guard let list = raw as? [[String: Any]] else { return 0 }
        var total = 0.0
        for item in list {
            let unit = (item["unit"] as? String)?.lowercased() ?? ""
            guard unit.contains("credit") else { continue }
            if let n = item["value"] as? Double { total += n }
            else if let n = item["value"] as? Int { total += Double(n) }
            else if let n = item["value"] as? NSNumber { total += n.doubleValue }
        }
        return total
    }

    /// Parse a Kiro ISO8601 timestamp (plain or 6-digit fractional microseconds).
    static func parseKiroDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.kiro.date(from: raw) ?? ISO8601DateFormatter.kiroFractional.date(from: raw)
    }

    /// Day bucket for a turn: its own `end_timestamp` when parseable, otherwise the session's
    /// stable fallback day (created_at, never the file's mtime). `internal` for the self-check.
    static func resolveTurnDayKey(endTimestamp: String?, fallbackDayKey: Int) -> Int {
        if let end = endTimestamp, let date = parseKiroDate(end) {
            return dayKey(for: date)
        }
        return fallbackDayKey
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

private extension ISO8601DateFormatter {
    static let kiro: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let kiroFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Grok CLI (signals.json)

enum LocalGrokUsage {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, tokens: Int, cost: Double, model: String, day: Int, requests: Int)] = [:]

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".grok/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let today = dayKey(for: now)
        var modelBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard !isEphemeralSessionPath(url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            // Prefer summary.json updated_at/created_at when present so a session whose
            // signals.json wasn't rewritten still lands on the day it was last active.
            let activity = sessionActivityDate(sessionDir: url.deletingLastPathComponent()) ?? mtime
            guard activity >= cutoff || mtime >= cutoff else { continue }
            let size = values.fileSize ?? 0
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)

            let parsed = parseSignals(path: path, url: url, mtime: mtime, activity: activity, size: size)
            guard parsed.tokens > 0 else { continue }

            var bucket = modelBuckets[parsed.model] ?? ModelBucket()
            bucket.total += parsed.tokens
            bucket.input += parsed.tokens
            bucket.cost += parsed.cost
            bucket.requests += parsed.requests
            modelBuckets[parsed.model] = bucket

            historyTokens += parsed.tokens
            historyCost += parsed.cost
            if parsed.day == today {
                sessionTokens += parsed.tokens
                sessionCost += parsed.cost
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()

        guard historyTokens > 0 else { return nil }
        let models = modelBuckets.map { model, b in
            ModelTokenUsage(
                model: model,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cacheRead,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests,
                volumeUnit: .estimatedTokens
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return ProviderCostSnapshot.make(
            providerID: "grok",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: models,
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    /// Per-day usage for the date-indexed views.
    ///
    /// Fidelity is `.sessionApproximate`, and that is not a formality: `parseSignals`
    /// estimates a whole session's tokens from its final context occupancy and turn count,
    /// then pins the entire figure to the session's last-activity day. A session spanning
    /// Monday to Wednesday therefore reports all of its volume on Wednesday. The per-model
    /// split is real (one model per session), so only the day attribution is approximate.
    ///
    /// Walks the same tree as `costSnapshot` and hits the same per-file cache, so the
    /// second pass re-parses nothing.
    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".grok/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let cutoffDay = dayKey(for: cutoff)
        var perDay: [Int: [String: ModelBucket]] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard !isEphemeralSessionPath(url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let activity = sessionActivityDate(sessionDir: url.deletingLastPathComponent()) ?? mtime
            guard activity >= cutoff || mtime >= cutoff else { continue }
            let size = values.fileSize ?? 0
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path

            let parsed = parseSignals(path: path, url: url, mtime: mtime, activity: activity, size: size)
            guard parsed.tokens > 0 else { continue }

            // Drop days older than the window: the `mtime >= cutoff` branch above admits a
            // file whose activity day is out of window, and a partial old day would
            // overwrite the complete persisted one (see the note in Kiro's dailyUsage).
            guard parsed.day >= cutoffDay else { continue }

            var dayMap = perDay[parsed.day] ?? [:]
            var bucket = dayMap[parsed.model] ?? ModelBucket()
            // signals.json carries no in/out split; costSnapshot files the whole estimate
            // under input, and this must agree with it or the two views would disagree.
            bucket.total += parsed.tokens
            bucket.input += parsed.tokens
            bucket.cost += parsed.cost
            bucket.requests += parsed.requests
            dayMap[parsed.model] = bucket
            perDay[parsed.day] = dayMap
        }

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in perDay {
            let rows = models.map { model, bucket in
                DailyModelUsage(
                    model: model,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    totalVolume: bucket.total,
                    estimatedCostUSD: bucket.cost,
                    requestCount: bucket.requests,
                    volumeUnit: .estimatedTokens
                )
            }
            .sorted { $0.totalVolume > $1.totalVolume }
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "grok",
                models: rows,
                volumeUnit: .estimatedTokens,
                fidelity: .sessionApproximate
            )
        }
        return result
    }

    private struct ModelBucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    /// Best activity timestamp for a Grok session dir: summary `updated_at` → `created_at` → nil.
    private static func sessionActivityDate(sessionDir: URL) -> Date? {
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let updated = json["updated_at"] as? String, let d = parseGrokDate(updated) { return d }
        if let created = json["created_at"] as? String, let d = parseGrokDate(created) { return d }
        return nil
    }

    private static func parseGrokDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.kiro.date(from: raw) ?? ISO8601DateFormatter.kiroFractional.date(from: raw)
    }

    private static func parseSignals(path: String, url: URL, mtime: Date, activity: Date, size: Int) -> (tokens: Int, cost: Double, model: String, day: Int, requests: Int) {
        // Day = last activity (summary updated_at / signals mtime). Whole-session estimate
        // lands on that day — multi-day split would need per-turn updates.jsonl sums.
        let day = dayKey(for: activity)
        cacheLock.lock()
        if let c = fileCache[path], c.mtime == mtime, c.size == size {
            // Re-bucket when activity day moved but signals body is unchanged.
            if c.day != day {
                fileCache[path] = (mtime, size, c.tokens, c.cost, c.model, day, c.requests)
            }
            cacheLock.unlock()
            return (c.tokens, c.cost, c.model, day, c.requests)
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (0, 0, "grok", day, 0)
        }

        let before = intValue(json["totalTokensBeforeCompaction"])
        let context = intValue(json["contextTokensUsed"])
        let turns = intValue(json["assistantMessageCount"])
        // Snapshot occupancy (plus pre-compaction), not a triangular turn-ramp: the ramp
        // fabricated hundreds of millions of tokens from Grok CLI harness sessions and
        // made Grok look "used" when the user was in Cursor.
        let tokens = estimatedCumulativeTokens(before: before, context: context, turns: turns)
        let requests = max(0, turns)
        let model: String = {
            if let primary = TokenPricingCatalog.normalizeModelID(json["primaryModelId"] as? String) {
                return primary
            }
            if let used = json["modelsUsed"] as? [String] {
                var counts: [String: Int] = [:]
                for m in used {
                    if let n = TokenPricingCatalog.normalizeModelID(m) { counts[n, default: 0] += 1 }
                }
                if let top = counts.max(by: { $0.value < $1.value })?.key { return top }
            }
            return "grok-4.5"
        }()
        // No in/out split in signals — 70/30 on *this* model’s list price.
        let input = Int(Double(tokens) * 0.7)
        let output = tokens - input
        let cost = TokenPricingCatalog.estimateUSD(model: model, inputTokens: input, outputTokens: output)

        cacheLock.lock()
        fileCache[path] = (mtime, size, tokens, cost, model, day, requests)
        cacheLock.unlock()
        return (tokens, cost, model, day, requests)
    }

    /// Tokens for a Grok CLI session. Idle sessions (no assistant turns) count as zero
    /// even if the CLI wrote a leftover context snapshot. With turns, use occupancy
    /// (`before` + final `context`) — not a triangular turn-ramp.
    static func estimatedCumulativeTokens(before: Int, context: Int, turns: Int) -> Int {
        if turns <= 0 { return 0 }
        return max(0, before) + max(0, context)
    }

    /// Temp / CI scratch sessions are not interactive Grok CLI use.
    static func isEphemeralSessionPath(_ path: String) -> Bool {
        let decoded = (path.removingPercentEncoding ?? path).lowercased()
        let markers = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        return markers.contains { decoded.contains($0) }
    }

    private static func intValue(_ raw: Any?) -> Int {
        JSONNumber.int(raw)
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

// MARK: - OpenCode (SQLite session table)

enum LocalOpenCodeUsage {
    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        guard let db = openOpenCodeDB() else { return nil }
        defer { sqlite3_close(db) }

        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let todayStart = Calendar.current.startOfDay(for: now)
        let scale = detectTimestampScale(db: db)
        let cutoffTs = Int64(cutoffStart.timeIntervalSince1970) * scale
        let todayStartTs = Int64(todayStart.timeIntervalSince1970) * scale

        // Prefer per-turn `message` rows for BOTH history and today — cumulative `session`
        // rows dump multi-day lifetime totals into the window whenever a session is touched.
        if let fromMessages = aggregateFromMessages(db: db, cutoffTs: cutoffTs, todayStartTs: todayStartTs, now: now) {
            return fromMessages
        }

        // Older OpenCode DBs without a usable message table: fall back to session totals.
        return aggregateFromSessions(db: db, cutoffTs: cutoffTs, todayStartTs: todayStartTs, now: now)
    }

    /// Open read-only connection. Prefer plain path open — more reliable than URI mode
    /// across SQLite builds while OpenCode holds a WAL writer.
    private static func openOpenCodeDB() -> OpaquePointer? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/opencode.db"),
        ]
        guard let dbURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        var db: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX: safe if OpenCode is mid-write on the WAL.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db {
            // Best-effort: don't fail the whole analytics pass if a busy timeout can't be set.
            sqlite3_busy_timeout(db, 1500)
            return db
        }
        sqlite3_close(db)
        return nil
    }

    private static func detectTimestampScale(db: OpaquePointer) -> Int64 {
        var maxUpdated: Int64 = 0
        var maxStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(time_updated) FROM session;", -1, &maxStmt, nil) == SQLITE_OK {
            if sqlite3_step(maxStmt) == SQLITE_ROW { maxUpdated = sqlite3_column_int64(maxStmt, 0) }
        }
        sqlite3_finalize(maxStmt)
        // Message table may be newer than session on some builds.
        var msgMax: Int64 = 0
        var msgStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(time_created) FROM message;", -1, &msgStmt, nil) == SQLITE_OK {
            if sqlite3_step(msgStmt) == SQLITE_ROW { msgMax = sqlite3_column_int64(msgStmt, 0) }
        }
        sqlite3_finalize(msgStmt)
        let probe = max(maxUpdated, msgMax)
        return timeUpdatedIsMilliseconds(probe) ? 1000 : 1
    }

    private struct TokenBucket {
        var input = 0
        var output = 0
        var cache = 0
        var total = 0
        var cost = 0.0
        var requests = 0
    }

    private static func aggregateFromMessages(
        db: OpaquePointer,
        cutoffTs: Int64,
        todayStartTs: Int64,
        now: Date
    ) -> ProviderCostSnapshot? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT time_created, data FROM message WHERE time_created >= ?;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTs)

        var models: [String: TokenBucket] = [:]
        var historyTokens = 0
        var historyCost = 0.0
        var sessionTokens = 0
        var sessionCost = 0.0
        var rows = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_int64(stmt, 0)
            guard let c = sqlite3_column_text(stmt, 1),
                  let data = String(cString: c).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "assistant"
            else { continue }

            let tk = json["tokens"] as? [String: Any] ?? [:]
            let cacheBlob = tk["cache"] as? [String: Any] ?? [:]
            let input = (tk["input"] as? NSNumber)?.intValue ?? 0
            let output = (tk["output"] as? NSNumber)?.intValue ?? 0
            let reasoning = (tk["reasoning"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (cacheBlob["read"] as? NSNumber)?.intValue ?? 0
            let storedCost = (json["cost"] as? NSNumber)?.doubleValue ?? 0
            let total = input + output + reasoning + cacheRead
            guard total > 0 || storedCost > 0 else { continue }

            let model = messageModelID(json) ?? "opencode"
            let cost = storedCost > 0
                ? storedCost
                : TokenPricingCatalog.estimateUSD(
                    model: model,
                    inputTokens: input,
                    outputTokens: output + reasoning,
                    cacheReadTokens: cacheRead
                )

            var bucket = models[model] ?? TokenBucket()
            bucket.input += input
            bucket.output += output + reasoning
            bucket.cache += cacheRead
            bucket.total += total
            bucket.cost += cost
            bucket.requests += 1
            models[model] = bucket

            historyTokens += total
            historyCost += cost
            if created >= todayStartTs {
                sessionTokens += total
                sessionCost += cost
            }
            rows += 1
        }

        guard rows > 0, historyTokens > 0 || historyCost > 0 else { return nil }

        let modelRows = models.map { name, b in
            ModelTokenUsage(
                model: name,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cache,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return ProviderCostSnapshot.make(
            providerID: "opencode",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: modelRows,
            updatedAt: now
        )
    }

    private static func aggregateFromSessions(
        db: OpaquePointer,
        cutoffTs: Int64,
        todayStartTs: Int64,
        now: Date
    ) -> ProviderCostSnapshot? {
        let sql = """
        SELECT model, tokens_input, tokens_output, tokens_cache_read, tokens_reasoning,
               cost, time_updated
        FROM session
        WHERE time_updated >= ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTs)

        var models: [String: TokenBucket] = [:]
        var historyTokens = 0
        var historyCost = 0.0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let modelRaw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "{}"
            let model = TokenPricingCatalog.normalizeModelID(parseOpenCodeModel(modelRaw))
                ?? parseOpenCodeModel(modelRaw)
            let input = Int(sqlite3_column_int64(stmt, 1))
            let output = Int(sqlite3_column_int64(stmt, 2))
            let cache = Int(sqlite3_column_int64(stmt, 3))
            let reasoning = Int(sqlite3_column_int64(stmt, 4))
            let storedCost = sqlite3_column_double(stmt, 5)
            let total = input + output + cache + reasoning
            guard total > 0 || storedCost > 0 else { continue }

            let cost = storedCost > 0
                ? storedCost
                : TokenPricingCatalog.estimateUSD(
                    model: model,
                    inputTokens: input,
                    outputTokens: output + reasoning,
                    cacheReadTokens: cache
                )

            var bucket = models[model] ?? TokenBucket()
            bucket.input += input
            bucket.output += output + reasoning
            bucket.cache += cache
            bucket.total += total
            bucket.cost += cost
            bucket.requests += 1
            models[model] = bucket
            historyTokens += total
            historyCost += cost
        }

        let (sessionTokens, sessionCost) = openCodeTodayTotals(db: db, todayStartTs: todayStartTs)
        guard historyTokens > 0 || historyCost > 0 else { return nil }

        let modelRows = models.map { name, b in
            ModelTokenUsage(
                model: name,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cache,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        return ProviderCostSnapshot.make(
            providerID: "opencode",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: modelRows,
            updatedAt: now
        )
    }

    /// Per-day usage for the date-indexed views.
    ///
    /// Read from the per-turn `message` table, never the cumulative `session` row: a
    /// session resumed across several days carries one lifetime total with a single
    /// `time_updated`, so bucketing that row would dump the whole history onto one day
    /// (the same trap `openCodeTodayTotals` exists to avoid for "today").
    ///
    /// Fidelity is decided per day by what the data actually supports: `.exact` when every
    /// contributing message named its model, `.dayTotalsOnly` when any did not, since the
    /// per-model split is then incomplete even though the day total is right. Older DBs
    /// with no `message` table return nothing rather than a mis-attributed guess.
    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        guard let db = openOpenCodeDB() else { return [:] }
        defer { sqlite3_close(db) }

        let scale = detectTimestampScale(db: db)
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let cutoffTs = Int64(cutoffStart.timeIntervalSince1970) * scale

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT time_created, data FROM message WHERE time_created >= ?;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            // No `message` table (older OpenCode): no trustworthy per-day signal exists.
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTs)

        struct Bucket {
            var input = 0
            var output = 0
            var cache = 0
            var total = 0
            var cost = 0.0
            var requests = 0
        }
        var perDay: [Int: [String: Bucket]] = [:]
        var daysMissingModel = Set<Int>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_int64(stmt, 0)
            guard let c = sqlite3_column_text(stmt, 1),
                  let data = String(cString: c).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "assistant"
            else { continue }

            let tk = json["tokens"] as? [String: Any] ?? [:]
            let cacheBlob = tk["cache"] as? [String: Any] ?? [:]
            let input = (tk["input"] as? NSNumber)?.intValue ?? 0
            let output = (tk["output"] as? NSNumber)?.intValue ?? 0
            let reasoning = (tk["reasoning"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (cacheBlob["read"] as? NSNumber)?.intValue ?? 0
            let storedCost = (json["cost"] as? NSNumber)?.doubleValue ?? 0

            let total = input + output + reasoning + cacheRead
            guard total > 0 || storedCost > 0 else { continue }

            let day = dayKey(forEpoch: created, scale: scale)
            let named = messageModelID(json)
            if named == nil { daysMissingModel.insert(day) }
            let model = named ?? "opencode"

            // Prefer OpenCode's own per-message cost (already model-aware); else list price.
            let cost = storedCost > 0
                ? storedCost
                : TokenPricingCatalog.estimateUSD(
                    model: model,
                    inputTokens: input,
                    outputTokens: output + reasoning,
                    cacheReadTokens: cacheRead
                )

            var dayMap = perDay[day] ?? [:]
            var bucket = dayMap[model] ?? Bucket()
            bucket.input += input
            bucket.output += output + reasoning
            bucket.cache += cacheRead
            bucket.total += total
            bucket.cost += cost
            bucket.requests += 1
            dayMap[model] = bucket
            perDay[day] = dayMap
        }

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in perDay {
            let rows = models.map { name, b in
                DailyModelUsage(
                    model: name,
                    inputTokens: b.input,
                    outputTokens: b.output,
                    cacheReadTokens: b.cache,
                    totalVolume: b.total,
                    estimatedCostUSD: b.cost,
                    requestCount: b.requests,
                    volumeUnit: .tokens
                )
            }
            .sorted { $0.totalVolume > $1.totalVolume }
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "opencode",
                models: rows,
                volumeUnit: .tokens,
                fidelity: daysMissingModel.contains(day) ? .dayTotalsOnly : .exact
            )
        }
        return result
    }

    /// Model id from a `message.data` blob, normalised for pricing. Nil when the row does
    /// not name one, which is what downgrades that day's fidelity rather than inventing a
    /// model label that looks authoritative.
    private static func messageModelID(_ json: [String: Any]) -> String? {
        let raw = (json["modelID"] as? String)
            ?? (json["modelId"] as? String)
            ?? (json["model"] as? String)
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let provider = (json["providerID"] as? String) ?? (json["providerId"] as? String) ?? ""
        let normalized = TokenPricingCatalog.normalizeModelID(raw) ?? raw
        return provider.isEmpty ? normalized : "\(provider)/\(normalized)"
    }

    /// Local start-of-day epoch for an OpenCode timestamp in `scale` units per second.
    private static func dayKey(forEpoch value: Int64, scale: Int64) -> Int {
        let seconds = TimeInterval(value) / TimeInterval(max(1, scale))
        return Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: seconds)).timeIntervalSince1970)
    }

    /// OpenCode stores model as JSON: `{"id":"glm-5.2","providerID":"opencode-go",...}`
    private static func parseOpenCodeModel(_ raw: String) -> String {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let id = json["id"] as? String, !id.isEmpty {
                let provider = (json["providerID"] as? String) ?? ""
                return provider.isEmpty ? id : "\(provider)/\(id)"
            }
        }
        return raw.isEmpty ? "opencode" : raw
    }

    /// OpenCode changed epoch units across versions: values above ~1e11 are milliseconds
    /// (seconds wouldn't reach that until ~year 5138), below are seconds. `internal` for tests.
    static func timeUpdatedIsMilliseconds(_ maxValue: Int64) -> Bool {
        maxValue > 100_000_000_000
    }

    /// Sum today's assistant-message tokens/cost from the per-turn `message` table (each row's
    /// `data` is a JSON blob with `role`, `tokens{input,output,reasoning,cache{read}}`, `cost`).
    /// Returns (0, 0) when the table/columns are absent (older OpenCode) so callers just show
    /// no "today" rather than mis-attributing a cumulative session total.
    private static func openCodeTodayTotals(db: OpaquePointer, todayStartTs: Int64) -> (tokens: Int, cost: Double) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM message WHERE time_created >= ?;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return (0, 0)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, todayStartTs)

        var tokens = 0
        var cost = 0.0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0),
                  let data = String(cString: c).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["role"] as? String) == "assistant"
            else { continue }
            let tk = json["tokens"] as? [String: Any] ?? [:]
            let cache = tk["cache"] as? [String: Any] ?? [:]
            let input = (tk["input"] as? NSNumber)?.intValue ?? 0
            let output = (tk["output"] as? NSNumber)?.intValue ?? 0
            let reasoning = (tk["reasoning"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (cache["read"] as? NSNumber)?.intValue ?? 0
            tokens += input + output + reasoning + cacheRead
            cost += (json["cost"] as? NSNumber)?.doubleValue ?? 0
        }
        return (tokens, cost)
    }
}

// MARK: - Antigravity IDE (conversation DBs under ~/.gemini/antigravity-ide)

/// Reads per-generation usage from Antigravity IDE `conversations/*.db` `gen_metadata`
/// blobs (protobuf). Token fields are recovered from the same wire layout Cockpit-era
/// clients write — not from the empty `~/.antigravity` tree the generic scanner used.
enum LocalAntigravityUsage {
    private static let modelPattern = try! NSRegularExpression(
        pattern: #"^(gemini|claude|gpt)-[\w.\-]+"#,
        options: [.caseInsensitive]
    )

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let byDay = aggregateByDay(now: now, historyDays: historyDays)
        guard !byDay.isEmpty else {
            NSLog("[UsageScan] antigravity: no conversation days (roots=%d)", conversationRoots().count)
            return nil
        }

        let today = dayKey(for: now)
        var models: [String: (input: Int, output: Int, requests: Int, cost: Double)] = [:]
        var historyTokens = 0
        var historyCost = 0.0
        var sessionTokens = 0
        var sessionCost = 0.0

        for (day, dayModels) in byDay {
            for (model, bucket) in dayModels {
                var acc = models[model] ?? (0, 0, 0, 0)
                acc.input += bucket.input
                acc.output += bucket.output
                acc.requests += bucket.requests
                acc.cost += bucket.cost
                models[model] = acc
                let total = bucket.input + bucket.output
                historyTokens += total
                historyCost += bucket.cost
                if day == today {
                    sessionTokens += total
                    sessionCost += bucket.cost
                }
            }
        }

        guard historyTokens > 0 || historyCost > 0 else { return nil }

        let modelRows = models.map { name, b in
            ModelTokenUsage(
                model: name,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: 0,
                totalTokens: b.input + b.output,
                estimatedCostUSD: b.cost,
                requestCount: b.requests
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }

        NSLog(
            "[UsageScan] antigravity: tokens30d=%d today=%d models=%d steps≈%d",
            historyTokens,
            sessionTokens,
            modelRows.count,
            models.values.reduce(0) { $0 + $1.requests }
        )

        return ProviderCostSnapshot.make(
            providerID: "antigravity",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: modelRows,
            updatedAt: now
        )
    }

    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        let byDay = aggregateByDay(now: now, historyDays: historyDays)
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in byDay {
            let rows = models.map { name, b in
                DailyModelUsage(
                    model: name,
                    inputTokens: b.input,
                    outputTokens: b.output,
                    cacheReadTokens: 0,
                    totalVolume: b.input + b.output,
                    estimatedCostUSD: b.cost,
                    requestCount: b.requests,
                    volumeUnit: .tokens
                )
            }
            .sorted { $0.totalVolume > $1.totalVolume }
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "antigravity",
                models: rows,
                volumeUnit: .tokens,
                // Protobuf field recovery is best-effort; mark as estimated so UI caveats apply.
                fidelity: .sessionApproximate
            )
        }
        return result
    }

    private struct StepBucket {
        var input = 0
        var output = 0
        var requests = 0
        var cost = 0.0
    }

    private static func aggregateByDay(
        now: Date,
        historyDays: Int
    ) -> [Int: [String: StepBucket]] {
        let roots = conversationRoots()
        guard !roots.isEmpty else { return [:] }

        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let cutoffEpoch = cutoffStart.timeIntervalSince1970
        var result: [Int: [String: StepBucket]] = [:]

        for root in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in files where url.pathExtension.lowercased() == "db" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = values.contentModificationDate
                else { continue }
                // Skip DBs last touched before the window (conversations are append-mostly).
                guard mtime >= cutoffStart else { continue }
                let fallbackDay = dayKey(for: mtime)
                scanConversationDB(
                    at: url,
                    cutoffEpoch: cutoffEpoch,
                    fallbackDay: fallbackDay,
                    into: &result
                )
            }
        }
        return result
    }

    private static func conversationRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".gemini/antigravity-ide/conversations"),
            home.appendingPathComponent(".antigravity-ide/conversations"),
            home.appendingPathComponent(".antigravity/conversations"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func scanConversationDB(
        at url: URL,
        cutoffEpoch: TimeInterval,
        fallbackDay: Int,
        into result: inout [Int: [String: StepBucket]]
    ) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        // size column filters out full-trajectory dumps (multi-MB) that restate prior steps.
        // Fall back to unfiltered SELECT if the size column is missing on older DBs.
        let sqlCandidates = [
            "SELECT size, data FROM gen_metadata WHERE size IS NULL OR size < 8000;",
            "SELECT length(data), data FROM gen_metadata;",
        ]
        var prepared: OpaquePointer?
        for sql in sqlCandidates {
            if sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, prepared != nil {
                break
            }
            sqlite3_finalize(prepared)
            prepared = nil
        }
        guard let stmt = prepared else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let size = Int(sqlite3_column_int64(stmt, 0))
            guard size == 0 || size < 8000 else { continue }
            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let nbytes = Int(sqlite3_column_bytes(stmt, 1))
            guard nbytes > 20 else { continue }
            let data = Data(bytes: blob, count: nbytes)
            // extractStep must never trap: protobuf varints can be UInt64.max.
            guard let step = extractStep(from: data) else { continue }
            if let ts = step.timestamp, ts < cutoffEpoch { continue }
            let day = step.timestamp.map { dayKey(for: Date(timeIntervalSince1970: $0)) } ?? fallbackDay
            let model = TokenPricingCatalog.normalizeModelID(step.model) ?? step.model
            let cost = TokenPricingCatalog.estimateUSD(
                model: model,
                inputTokens: step.input,
                outputTokens: step.output,
                cacheReadTokens: 0
            )
            var dayMap = result[day] ?? [:]
            var bucket = dayMap[model] ?? StepBucket()
            bucket.input += step.input
            bucket.output += step.output
            bucket.requests += 1
            bucket.cost += cost
            dayMap[model] = bucket
            result[day] = dayMap
        }
    }

    private struct StepUsage {
        let model: String
        let input: Int
        let output: Int
        let timestamp: TimeInterval?
    }

    /// Recover model + input/output from a gen_metadata protobuf blob.
    /// Output prefers field pairs where depth-2 f3 == f10 (completion tokens); input is the
    /// first reasonable depth-2 f2 that is not a known budget constant.
    ///
    /// Crash fix: never `Int(UInt64)` — large varints (e.g. 0xFFFF_FFFF_FFFF_FFFF sentinels
    /// in Antigravity blobs) trap with "Not enough bits to represent the passed value".
    private static func extractStep(from data: Data) -> StepUsage? {
        let fields = protoWalk(data, maxDepth: 3)
        var model: String?
        for field in fields where field.kind == .string {
            let s = field.stringValue
            let range = NSRange(s.startIndex..., in: s)
            if modelPattern.firstMatch(in: s, range: range) != nil {
                model = s
                break
            }
        }
        guard let model else { return nil }

        var f2: [Int] = []
        var f3: [Int] = []
        var f10: [Int] = []
        var timestamps: [TimeInterval] = []
        let budgets: Set<Int> = [200, 512, 1000, 1024, 4096, 8192, 10_000, 40_000, 64_000, 200_000]

        for field in fields where field.kind == .varint {
            // Skip non-fitting UInt64 values (max-uint sentinels, packed nanos, etc.).
            guard let v = Int(exactly: field.varintValue) else { continue }
            if field.depth == 2, field.number == 2, (1...500_000).contains(v) { f2.append(v) }
            if field.depth == 2, field.number == 3, (1...64_000).contains(v) { f3.append(v) }
            if field.depth == 2, field.number == 10, (1...64_000).contains(v) { f10.append(v) }
            // Unix seconds in the 2023–2033 band.
            if (1_700_000_000...2_000_000_000).contains(v) {
                timestamps.append(TimeInterval(v))
            }
        }

        let f10set = Set(f10)
        var output: Int?
        for candidate in f3 where f10set.contains(candidate) {
            output = candidate
            break
        }
        if output == nil {
            let small = f3.filter { $0 < 32_000 }
            output = small.min()
        }

        var input: Int?
        for candidate in f2 where !budgets.contains(candidate) && candidate >= 10 {
            input = candidate
            break
        }

        let inTok = input ?? 0
        let outTok = output ?? 0
        guard inTok > 0 || outTok > 0 else { return nil }
        return StepUsage(
            model: model,
            input: inTok,
            output: outTok,
            timestamp: timestamps.first
        )
    }

    private enum ProtoKind { case varint, string }
    private struct ProtoField {
        let depth: Int
        let number: Int
        let kind: ProtoKind
        let varintValue: UInt64
        let stringValue: String
    }

    private static func protoWalk(_ data: Data, maxDepth: Int) -> [ProtoField] {
        var out: [ProtoField] = []
        func walk(_ data: Data, depth: Int) {
            guard depth <= maxDepth else { return }
            var i = data.startIndex
            while i < data.endIndex {
                guard let (key, keyEnd) = readVarint(data, at: i) else { break }
                i = keyEnd
                let field = Int(key >> 3)
                let wire = Int(key & 0x7)
                guard field > 0, field < 200 else { break }
                if wire == 0 {
                    guard let (val, valEnd) = readVarint(data, at: i) else { break }
                    i = valEnd
                    out.append(ProtoField(depth: depth, number: field, kind: .varint, varintValue: val, stringValue: ""))
                } else if wire == 2 {
                    guard let (len, lenEnd) = readVarint(data, at: i) else { break }
                    i = lenEnd
                    let n = Int(len)
                    guard n >= 0, data.distance(from: i, to: data.endIndex) >= n else { break }
                    let end = data.index(i, offsetBy: n)
                    let payload = data[i..<end]
                    i = end
                    if let s = String(data: payload, encoding: .utf8),
                       s.count >= 4, s.count < 200,
                       !s.unicodeScalars.contains(where: {
                           CharacterSet.controlCharacters.contains($0)
                               && !CharacterSet.whitespacesAndNewlines.contains($0)
                       })
                    {
                        out.append(ProtoField(depth: depth, number: field, kind: .string, varintValue: 0, stringValue: s))
                    }
                    walk(Data(payload), depth: depth + 1)
                } else if wire == 1 {
                    guard data.distance(from: i, to: data.endIndex) >= 8 else { break }
                    i = data.index(i, offsetBy: 8)
                } else if wire == 5 {
                    guard data.distance(from: i, to: data.endIndex) >= 4 else { break }
                    i = data.index(i, offsetBy: 4)
                } else {
                    break
                }
            }
        }
        walk(data, depth: 0)
        return out
    }

    private static func readVarint(_ data: Data, at start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            i = data.index(after: i)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

// MARK: - GitHub Copilot (JB panel transcripts — token estimate from message text)

enum LocalCopilotUsage {
    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, requests: Int, days: [Int: Int], dayRequests: [Int: Int])] = [:]
    /// Skip pathological multi‑MB transcripts (still count via cache once parsed).
    private static let maxFileBytes = 8_000_000

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/jb")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let today = dayKey(for: now)
        var sessionTokens = 0
        var historyTokens = 0
        var requests = 0
        var live = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate, mtime >= cutoff
            else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileBytes else { continue }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let parsed = parseFile(path: path, url: url, mtime: mtime, size: size)
            let fileTokens = parsed.days.values.reduce(0, +)
            guard fileTokens > 0 else { continue }
            historyTokens += fileTokens
            requests += parsed.requests
            sessionTokens += parsed.days[today] ?? 0
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()

        guard historyTokens > 0 else { return nil }
        // Copilot subscription — estimate mid-tier chat pricing for API-equivalent.
        let cost = TokenPricingCatalog.estimateUSD(
            model: "gpt-4o",
            inputTokens: Int(Double(historyTokens) * 0.6),
            outputTokens: Int(Double(historyTokens) * 0.4)
        )
        let sessionCost = historyTokens > 0
            ? cost * (Double(sessionTokens) / Double(historyTokens))
            : 0

        return ProviderCostSnapshot.make(
            providerID: "copilot",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: cost,
            models: [
                ModelTokenUsage(
                    model: "github-copilot (est.)",
                    inputTokens: Int(Double(historyTokens) * 0.6),
                    outputTokens: Int(Double(historyTokens) * 0.4),
                    cacheReadTokens: 0,
                    totalTokens: historyTokens,
                    estimatedCostUSD: cost,
                    requestCount: requests,
                    volumeUnit: .estimatedTokens
                )
            ],
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    /// Per-day usage for the date-indexed views.
    ///
    /// Fidelity is `.dayTotalsOnly`. The day attribution itself is trustworthy — every
    /// message is bucketed by its own ISO8601 `timestamp` (see `parseFile`), so an
    /// append-only transcript reopened today does not retag its history — but Copilot's
    /// JB transcripts never name the model that answered, so there is no per-model split
    /// to report. The single row is labelled as an estimate because the token count is
    /// derived from message text length, not from logged usage.
    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/jb")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }

        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let cutoffDay = dayKey(for: cutoff)
        var dayTokens: [Int: Int] = [:]
        var dayRequests: [Int: Int] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate, mtime >= cutoff
            else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileBytes else { continue }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let parsed = parseFile(path: path, url: url, mtime: mtime, size: size)
            // `mtime >= cutoff` admits the file, but a long-lived transcript also holds
            // messages from before the window. Those days would be partial here (only
            // recently-touched files contribute), and a partial day overwrites the complete
            // persisted record, so drop them.
            for (day, tokens) in parsed.days where tokens > 0 && day >= cutoffDay {
                dayTokens[day, default: 0] += tokens
                dayRequests[day, default: 0] += parsed.dayRequests[day] ?? 0
            }
        }

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, tokens) in dayTokens where tokens > 0 {
            // Same 60/40 split and same list price as costSnapshot, so the date view and
            // the rolling total cannot disagree about what a day cost.
            let input = Int(Double(tokens) * 0.6)
            let output = tokens - input
            let cost = TokenPricingCatalog.estimateUSD(
                model: "gpt-4o",
                inputTokens: input,
                outputTokens: output
            )
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "copilot",
                models: [
                    DailyModelUsage(
                        model: "github-copilot (est.)",
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: 0,
                        totalVolume: tokens,
                        estimatedCostUSD: cost,
                        requestCount: dayRequests[day] ?? 0,
                        volumeUnit: .estimatedTokens
                    )
                ],
                volumeUnit: .estimatedTokens,
                fidelity: .dayTotalsOnly
            )
        }
        return result
    }

    private static func parseFile(path: String, url: URL, mtime: Date, size: Int) -> (requests: Int, days: [Int: Int], dayRequests: [Int: Int]) {
        cacheLock.lock()
        if let c = fileCache[path], c.mtime == mtime, c.size == size {
            cacheLock.unlock()
            return (c.requests, c.days, c.dayRequests)
        }
        cacheLock.unlock()

        let mtimeDay = dayKey(for: mtime)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (0, [:], [:])
        }
        var days: [Int: Int] = [:]
        var dayRequests: [Int: Int] = [:]
        var requests = 0
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            guard type == "assistant.message" || type == "user.message" else { continue }
            let text = copilotText(from: json["data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // ~4 chars/token rough estimate when Copilot doesn't log usage.
            let tokens = max(1, Int((Double(text.utf8.count) / 4.0).rounded(.up)))
            // Bucket by the message's OWN timestamp; an append-only transcript reopened today
            // must not retag its whole history as "today" (the old file-mtime bug).
            let day = copilotDayKey(timestamp: json["timestamp"] as? String, fallbackDayKey: mtimeDay)
            days[day, default: 0] += tokens
            dayRequests[day, default: 0] += 1
            requests += 1
        }

        cacheLock.lock()
        fileCache[path] = (mtime, size, requests, days, dayRequests)
        cacheLock.unlock()
        return (requests, days, dayRequests)
    }

    private static let copilotISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Day bucket for a Copilot message: its own ISO8601 `timestamp` when present, else the
    /// file mtime day. `internal` for the self-check.
    static func copilotDayKey(timestamp: String?, fallbackDayKey: Int) -> Int {
        if let ts = timestamp, let date = copilotISO.date(from: ts) {
            return dayKey(for: date)
        }
        return fallbackDayKey
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private static func copilotText(from raw: Any?) -> String {
        guard let data = raw as? [String: Any] else { return "" }
        if let content = data["content"] as? String { return content }
        if let text = data["text"] as? String { return text }
        if let parts = data["content"] as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined(separator: "\n")
        }
        return ""
    }
}
