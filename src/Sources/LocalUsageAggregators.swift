import Foundation
import SQLite3

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

private func localDayEpoch(_ date: Date) -> Int {
    Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
}

private func jsonInt(_ raw: Any?) -> Int? {
    if let n = raw as? Int { return n }
    if let n = raw as? Double, n.isFinite, abs(n) < 9e18 { return Int(n) }
    if let n = raw as? NSNumber { return n.intValue }
    return nil
}

private func jsonDouble(_ raw: Any?) -> Double? {
    if let n = raw as? Double { return n }
    if let n = raw as? Int { return Double(n) }
    if let n = raw as? NSNumber { return n.doubleValue }
    return nil
}

/// One provider's per-day scan. `isComplete` is true only when every source was read and parsed,
/// so days in `coveredFrom...coveredThrough` missing from `days` genuinely had no usage.
/// Coverage starts after `oldestSource`'s last write, since anything older may have lived in a
/// source the tool already deleted; `sources` (path -> mtime) lets the store protect deleted ones.
struct LocalDailyUsageScan {
    let providerID: String
    let days: [UsageDayKey: DailyProviderUsage]
    let coveredFrom: UsageDayKey
    let coveredThrough: UsageDayKey
    let isComplete: Bool
    let sources: [String: Double]

    init(
        providerID: String,
        days: [UsageDayKey: DailyProviderUsage],
        cutoffStart: Date,
        now: Date,
        isComplete: Bool,
        sources: [String: Double] = [:],
        oldestSource: Date? = nil
    ) {
        self.providerID = providerID
        self.days = days
        let calendar = Calendar.current
        var from = calendar.startOfDay(for: cutoffStart)
        if let oldestSource, let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: oldestSource)) {
            from = max(from, dayAfter)
        }
        self.coveredFrom = UsageDayKey(date: from)
        self.coveredThrough = UsageDayKey(date: now)
        self.isComplete = isComplete
        self.sources = sources
    }
}

/// Stable key for a source file, matching the generic scanner's canonical paths.
func usageSourcePath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

/// A model row shared by the snapshot and the per-day views, so both always agree.
struct LocalUsageRow: Equatable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    var cacheWriteTokens: Int = 0
    let totalVolume: Int
    let costUSD: Double
    let requests: Int
    let volumeUnit: UsageVolumeUnit
    var estimateBasis: String? = nil

    var modelTokenUsage: ModelTokenUsage {
        ModelTokenUsage(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: totalVolume,
            estimatedCostUSD: costUSD,
            requestCount: requests,
            volumeUnit: volumeUnit,
            estimateBasis: estimateBasis
        )
    }

    var dailyModelUsage: DailyModelUsage {
        DailyModelUsage(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalVolume: totalVolume,
            estimatedCostUSD: costUSD,
            requestCount: requests,
            volumeUnit: volumeUnit
        )
    }
}

// MARK: - Kiro local credits (session JSON metering + VibeRouter proxy ledger)

/// Reads `~/.kiro/sessions/cli/*.json` turn metadata (`metering_usage` credit arrays) and the
/// VibeRouter Kiro proxy ledger. Credits are the cost basis; token rows are estimates.
enum LocalKiroCredits {
    struct ParsedTurn: Equatable {
        let day: Int
        let model: String
        let credits: Double
        let requests: Int
        let contextPercentage: Double
        let previousContextPercentage: Double?
        let reportedInput: Int
        let reportedOutput: Int
        let reportedCacheRead: Int
        let reportedCacheWrite: Int
        var outputChars: Int
    }

    struct ParsedSession: Equatable {
        let modelID: String?
        let contextWindowTokens: Int?
        var turns: [ParsedTurn]

        func attaching(outputs: [Int]) -> ParsedSession {
            var copy = self
            for index in copy.turns.indices {
                copy.turns[index].outputChars = index < outputs.count ? outputs[index] : 0
            }
            return copy
        }
    }

    struct CreditBucket: Equatable {
        var credits = 0.0
        var requests = 0
    }

    struct TokenBucket: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        /// Proxy requests with no metering event, kept off the credit rows.
        var unmeteredRequests = 0
        /// CLI input with each session's first turn counted from 0% instead of its own context %.
        var inputLowerBound = 0
        var total: Int { input + output + cacheRead + cacheWrite }

        mutating func add(_ other: TokenBucket) {
            input += other.input
            output += other.output
            cacheRead += other.cacheRead
            cacheWrite += other.cacheWrite
            unmeteredRequests += other.unmeteredRequests
            inputLowerBound += other.inputLowerBound
        }
    }

    struct Collection {
        var credits: [Int: [String: CreditBucket]] = [:]
        var cliTokens: [Int: [String: TokenBucket]] = [:]
        var proxyTokens: [KiroProxyUsageLedger.TokenSource: [Int: [String: TokenBucket]]] = [:]
        var isComplete = true

        var proxyDays: Set<Int> { Set(proxyTokens.values.flatMap(\.keys)) }

        func proxyTokens(onDay day: Int) -> [KiroProxyUsageLedger.TokenSource: [String: TokenBucket]] {
            proxyTokens.compactMapValues { $0[day] }
        }
    }

    static let cliEstimateSuffix = " (est. upper bound)"
    static let proxyMetadataSuffix = " (VibeRouter, Kiro-reported)"
    static let proxyContextSuffix = " (VibeRouter, context %)"
    static let proxyEstimateSuffix = " (VibeRouter, est.)"
    /// Claude Code logged only the prompt it saw, before Kiro's tool/system payload was added.
    static let proxyLogEstimateSuffix = " (VibeRouter, est. lower bound)"
    static let cliEstimateBasis = "context % × window, upper bound"
    static let proxyMetadataBasis = "exact from Kiro"
    static let proxyContextBasis = "context % × window"
    static let proxyEstimateBasis = "proxy payload ÷ 4"
    static let proxyLogEstimateBasis = "Claude Code log, lower bound"
    static let proxySources: [KiroProxyUsageLedger.TokenSource] = [.kiroMetadata, .contextPercentage, .payloadBytes, .claudeLog]

    static func proxyLabel(_ source: KiroProxyUsageLedger.TokenSource) -> (suffix: String, basis: String) {
        switch source {
        case .kiroMetadata: return (proxyMetadataSuffix, proxyMetadataBasis)
        case .contextPercentage: return (proxyContextSuffix, proxyContextBasis)
        case .payloadBytes: return (proxyEstimateSuffix, proxyEstimateBasis)
        case .claudeLog: return (proxyLogEstimateSuffix, proxyLogEstimateBasis)
        }
    }

    /// Proxy rows, whose request count is requests Kiro billed but VibeRouter recorded no credits for.
    static func isProxyEstimateRow(_ model: String) -> Bool {
        proxySources.contains { model.hasSuffix(proxyLabel($0).suffix) }
    }
    static let defaultContextWindow = 200_000
    private static let maxSessionBytes = 80_000_000

    private struct CachedSession {
        let mtime: Date
        let size: Int
        let companionMtime: Date?
        let companionSize: Int?
        let outputsLoaded: Bool
        let session: ParsedSession
    }

    private static let cacheLock = NSLock()
    private static var fileCache: [String: CachedSession] = [:]

    /// Credits consumed on/after `since` (inclusive).
    static func creditsUsed(since: Date, now: Date = Date()) -> Double {
        let cutoffStart = Calendar.current.startOfDay(for: since)
        let collection = collect(cutoffStart: cutoffStart, sessionsRoot: nil, proxyEntries: nil)
        return collection.credits.values.reduce(0) { total, models in
            total + models.values.reduce(0) { $0 + $1.credits }
        }
    }

    /// Rolling-window snapshot. Cost is credits × overage rate (est.), not an invoice.
    static func costSnapshot(
        now: Date = Date(),
        historyDays: Int = 30,
        usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit,
        sessionsRoot: URL? = nil,
        proxyEntries: [KiroProxyUsageLedger.Entry]? = nil
    ) -> ProviderCostSnapshot? {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, sessionsRoot: sessionsRoot, proxyEntries: proxyEntries)
        let today = localDayEpoch(now)

        var credits: [String: CreditBucket] = [:]
        var cliTokens: [String: TokenBucket] = [:]
        var proxyTokens: [KiroProxyUsageLedger.TokenSource: [String: TokenBucket]] = [:]
        var historyCredits = 0.0
        var sessionCredits = 0.0
        for (day, models) in collection.credits {
            for (model, bucket) in models {
                credits[model, default: CreditBucket()].credits += bucket.credits
                credits[model, default: CreditBucket()].requests += bucket.requests
                historyCredits += bucket.credits
                if day == today { sessionCredits += bucket.credits }
            }
        }
        for models in collection.cliTokens.values {
            for (model, bucket) in models { cliTokens[model, default: TokenBucket()].add(bucket) }
        }
        for (source, days) in collection.proxyTokens {
            for models in days.values {
                for (model, bucket) in models { proxyTokens[source, default: [:]][model, default: TokenBucket()].add(bucket) }
            }
        }

        let rows = modelRows(
            credits: credits,
            cliTokens: cliTokens,
            proxyTokens: proxyTokens,
            usdPerCredit: usdPerCredit
        )
        let estimatedTotal = rows.filter { $0.volumeUnit == .estimatedTokens }.reduce(0) { $0 + $1.totalVolume }
        let cliSlack = cliTokens.values.reduce(0) { $0 + max(0, $1.input - $1.inputLowerBound) }
        NSLog(
            "[UsageScan] kiro: credits30d=%.2f today=%.2f rows=%ld estTokens=%ld",
            historyCredits, sessionCredits, rows.count,
            rows.filter { $0.volumeUnit == .estimatedTokens }.reduce(0) { $0 + $1.totalVolume }
        )
        guard historyCredits > 0.001 || !rows.isEmpty else { return nil }

        return ProviderCostSnapshot.make(
            providerID: "kiro",
            sessionTokens: millicredits(sessionCredits),
            sessionCostUSD: max(0, sessionCredits) * usdPerCredit,
            last30DaysTokens: millicredits(historyCredits),
            last30DaysCostUSD: max(0, historyCredits) * usdPerCredit,
            models: rows.map(\.modelTokenUsage),
            volumeUnit: .credits,
            updatedAt: now,
            estimatedTokensLowerBound30d: cliSlack > 0 ? estimatedTotal - cliSlack : nil
        )
    }

    /// Per-day credits (exact, per-turn metering timestamps) plus estimated-token rows.
    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30,
        usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit
    ) -> [UsageDayKey: DailyProviderUsage] {
        dailyUsageScan(now: now, historyDays: historyDays, usdPerCredit: usdPerCredit).days
    }

    static func dailyUsageScan(
        now: Date = Date(),
        historyDays: Int = 30,
        usdPerCredit: Double = TokenPricingCatalog.kiroUSDPerCredit,
        sessionsRoot: URL? = nil,
        proxyEntries: [KiroProxyUsageLedger.Entry]? = nil
    ) -> LocalDailyUsageScan {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, sessionsRoot: sessionsRoot, proxyEntries: proxyEntries)
        let days = Set(collection.credits.keys)
            .union(collection.cliTokens.keys)
            .union(collection.proxyDays)

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for day in days {
            let rows = modelRows(
                credits: collection.credits[day] ?? [:],
                cliTokens: collection.cliTokens[day] ?? [:],
                proxyTokens: collection.proxyTokens(onDay: day),
                usdPerCredit: usdPerCredit
            )
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "kiro",
                models: rows.map(\.dailyModelUsage),
                volumeUnit: .credits,
                fidelity: .exact
            )
        }
        return LocalDailyUsageScan(
            providerID: "kiro", days: result, cutoffStart: cutoffStart, now: now, isComplete: collection.isComplete
        )
    }

    /// Credit rows (metered requests live here) first, then zero-cost estimated-token rows whose
    /// only requests are proxy requests Kiro never metered.
    static func modelRows(
        credits: [String: CreditBucket],
        cliTokens: [String: TokenBucket],
        proxyTokens: [KiroProxyUsageLedger.TokenSource: [String: TokenBucket]] = [:],
        usdPerCredit: Double
    ) -> [LocalUsageRow] {
        let creditRows = credits.compactMap { model, bucket -> LocalUsageRow? in
            guard bucket.credits > 0 || bucket.requests > 0 else { return nil }
            let milli = millicredits(bucket.credits)
            return LocalUsageRow(
                model: model,
                inputTokens: milli,
                outputTokens: 0,
                cacheReadTokens: 0,
                totalVolume: milli,
                costUSD: max(0, bucket.credits) * usdPerCredit,
                requests: bucket.requests,
                volumeUnit: .credits
            )
        }
        .sorted { $0.totalVolume != $1.totalVolume ? $0.totalVolume > $1.totalVolume : $0.model < $1.model }

        func tokenRows(_ buckets: [String: TokenBucket], suffix: String, basis: String) -> [LocalUsageRow] {
            buckets.compactMap { model, bucket in
                guard bucket.total > 0 || bucket.unmeteredRequests > 0 else { return nil }
                return LocalUsageRow(
                    model: model + suffix,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    cacheReadTokens: bucket.cacheRead,
                    cacheWriteTokens: bucket.cacheWrite,
                    totalVolume: bucket.total,
                    costUSD: 0,
                    requests: bucket.unmeteredRequests,
                    volumeUnit: .estimatedTokens,
                    estimateBasis: basis
                )
            }
        }
        let proxyRows = proxySources.flatMap { source -> [LocalUsageRow] in
            let label = proxyLabel(source)
            return tokenRows(proxyTokens[source] ?? [:], suffix: label.suffix, basis: label.basis)
        }
        let estimated = (tokenRows(cliTokens, suffix: cliEstimateSuffix, basis: cliEstimateBasis) + proxyRows)
            .sorted { $0.totalVolume != $1.totalVolume ? $0.totalVolume > $1.totalVolume : $0.model < $1.model }
        return creditRows + estimated
    }

    static func collect(
        cutoffStart: Date,
        sessionsRoot: URL?,
        proxyEntries: [KiroProxyUsageLedger.Entry]?
    ) -> Collection {
        let root = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions/cli")
        var complete = true
        let sessions = readSessions(root: root, cutoffStart: cutoffStart, complete: &complete)
        let entries = proxyEntries ?? defaultProxyEntries(since: cutoffStart)
        var collection = aggregate(sessions: sessions, proxyEntries: entries, cutoffDay: localDayEpoch(cutoffStart))
        collection.isComplete = complete
        return collection
    }

    /// Ledger rows win over Claude-log rows for the same `claudeMessageID` (they carry credits).
    static func mergeProxyEntries(
        ledger: [KiroProxyUsageLedger.Entry],
        claudeLog: [KiroProxyUsageLedger.Entry]
    ) -> [KiroProxyUsageLedger.Entry] {
        var seenIDs = Set<String>()
        var claimedMessages = Set<String>()
        var merged: [KiroProxyUsageLedger.Entry] = []
        for entry in ledger where seenIDs.insert(entry.id).inserted {
            if let message = entry.claudeMessageID { claimedMessages.insert(message) }
            merged.append(entry)
        }
        for entry in claudeLog {
            if let message = entry.claudeMessageID, !claimedMessages.insert(message).inserted { continue }
            guard seenIDs.insert(entry.id).inserted else { continue }
            merged.append(entry)
        }
        return merged
    }

    static func aggregate(
        sessions: [ParsedSession],
        proxyEntries: [KiroProxyUsageLedger.Entry],
        cutoffDay: Int
    ) -> Collection {
        var collection = Collection()
        let windows = commonContextWindows(sessions)

        for session in sessions {
            for turn in session.turns where turn.day >= cutoffDay {
                guard turn.credits > 0 || turn.requests > 0 else { continue }
                let model = displayModel(turn.model)
                var credit = collection.credits[turn.day]?[model] ?? CreditBucket()
                credit.credits += max(0, turn.credits)
                credit.requests += turn.requests
                collection.credits[turn.day, default: [:]][model] = credit

                var tokens = TokenBucket()
                if turn.reportedInput + turn.reportedCacheRead + turn.reportedCacheWrite > 0 {
                    tokens.input = turn.reportedInput
                    tokens.inputLowerBound = turn.reportedInput
                    tokens.cacheRead = turn.reportedCacheRead
                    tokens.cacheWrite = turn.reportedCacheWrite
                } else {
                    let window = contextWindow(
                        forTurnModel: turn.model,
                        sessionModelID: session.modelID,
                        sessionWindow: session.contextWindowTokens,
                        commonWindows: windows
                    )
                    tokens.input = estimatedInputTokens(
                        requests: turn.requests,
                        previousPercentage: turn.previousContextPercentage,
                        percentage: turn.contextPercentage,
                        window: window
                    )
                    tokens.inputLowerBound = estimatedInputTokens(
                        requests: turn.requests,
                        previousPercentage: turn.previousContextPercentage ?? 0,
                        percentage: turn.contextPercentage,
                        window: window
                    )
                }
                tokens.output = turn.reportedOutput > 0 ? turn.reportedOutput : turn.outputChars / 4
                guard tokens.total > 0 else { continue }
                var existing = collection.cliTokens[turn.day]?[model] ?? TokenBucket()
                existing.add(tokens)
                collection.cliTokens[turn.day, default: [:]][model] = existing
            }
        }

        for entry in proxyEntries {
            let day = localDayEpoch(entry.timestamp)
            guard day >= cutoffDay else { continue }
            let model = proxyModelID(entry.model)
            if let credits = entry.credits {
                var credit = collection.credits[day]?[model] ?? CreditBucket()
                credit.credits += max(0, credits)
                credit.requests += 1
                collection.credits[day, default: [:]][model] = credit
            }

            let tokens = TokenBucket(
                input: max(0, entry.inputTokens),
                output: max(0, entry.outputTokens),
                cacheRead: max(0, entry.cacheReadTokens),
                cacheWrite: max(0, entry.cacheWriteTokens),
                unmeteredRequests: entry.credits == nil ? 1 : 0
            )
            guard tokens.total > 0 || tokens.unmeteredRequests > 0 else { continue }
            collection.proxyTokens[entry.tokenSource, default: [:]][day, default: [:]][model, default: TokenBucket()].add(tokens)
        }
        return collection
    }

    /// Resend-the-context upper bound: requests × mean(previous, current context %) × window.
    static func estimatedInputTokens(requests: Int, previousPercentage: Double?, percentage: Double, window: Int) -> Int {
        guard requests > 0, window > 0 else { return 0 }
        let start = previousPercentage ?? percentage
        let tokens = Double(requests) * (start + percentage) / 2 / 100 * Double(window)
        return tokens > 0 ? JSONNumber.int(from: tokens) : 0
    }

    /// The session's own window only applies to its own model; another model's turn uses that
    /// model's usual window, then the cached `--list-models` window, then the default.
    static func contextWindow(
        forTurnModel model: String,
        sessionModelID: String?,
        sessionWindow: Int?,
        commonWindows: [String: Int],
        catalogWindow: (String) -> Int? = KiroDirectProvider.cachedContextWindowTokens(forUpstreamID:)
    ) -> Int {
        if let sessionWindow, sessionWindow > 0, sessionModelID == model { return sessionWindow }
        if let common = commonWindows[model], common > 0 { return common }
        if let cataloged = catalogWindow(model), cataloged > 0 { return cataloged }
        return defaultContextWindow
    }

    static func commonContextWindows(_ sessions: [ParsedSession]) -> [String: Int] {
        var counts: [String: [Int: Int]] = [:]
        for session in sessions {
            guard let model = session.modelID, let window = session.contextWindowTokens, window > 0 else { continue }
            counts[model, default: [:]][window, default: 0] += 1
        }
        return counts.compactMapValues { windows in
            windows.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key
        }
    }

    static func proxyModelID(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("kiro/") { name = String(name.dropFirst("kiro/".count)) }
        return name.isEmpty ? "kiro" : displayModel(name)
    }

    static func parseSession(sessionData: Data, companionData: Data?, fallbackMtime: Date) -> ParsedSession? {
        guard let object = try? JSONSerialization.jsonObject(with: sessionData) else { return nil }
        guard let json = object as? [String: Any] else {
            return ParsedSession(modelID: nil, contextWindowTokens: nil, turns: [])
        }
        let sessionState = json["session_state"] as? [String: Any]
        let modelInfo = (sessionState?["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        let sessionModel = nonEmpty(modelInfo?["model_id"] as? String) ?? nonEmpty(modelInfo?["model_name"] as? String)
        let window = jsonInt(modelInfo?["context_window_tokens"]).flatMap { $0 > 0 ? $0 : nil }
        let rawTurns = ((sessionState?["conversation_metadata"] as? [String: Any])?["user_turn_metadatas"] as? [[String: Any]])
            ?? []

        // created_at is written once, so a rewritten session never spills prior-day turns into today.
        let fallbackDay = (json["created_at"] as? String).flatMap(parseKiroDate).map(localDayEpoch)
            ?? localDayEpoch(fallbackMtime)
        var previous: Double?
        var turns: [ParsedTurn] = []
        for turn in rawTurns {
            let percentage = jsonDouble(turn["context_usage_percentage"]) ?? 0
            let meter = turn["metering_usage"] as? [[String: Any]]
            let requests: Int = {
                if let total = jsonInt(turn["total_request_count"]) { return max(0, total) }
                if let count = meter?.count, count > 0 { return count }
                return 1
            }()
            turns.append(ParsedTurn(
                day: resolveTurnDayKey(endTimestamp: turn["end_timestamp"] as? String, fallbackDayKey: fallbackDay),
                model: nonEmpty(turn["model"] as? String) ?? sessionModel ?? "kiro",
                credits: sumCredits(meter),
                requests: requests,
                contextPercentage: percentage,
                previousContextPercentage: previous,
                reportedInput: max(0, jsonInt(turn["input_token_count"]) ?? 0),
                reportedOutput: max(0, jsonInt(turn["output_token_count"]) ?? 0),
                reportedCacheRead: max(0, jsonInt(turn["cache_read_input_token_count"]) ?? 0),
                reportedCacheWrite: max(0, jsonInt(turn["cache_write_input_token_count"]) ?? 0),
                outputChars: 0
            ))
            previous = percentage
        }
        let session = ParsedSession(modelID: sessionModel, contextWindowTokens: window, turns: turns)
        return companionData.map { session.attaching(outputs: outputCharsPerPrompt($0)) } ?? session
    }

    /// Assistant text + tool-use characters that follow each `Prompt` in the companion `.jsonl`.
    static func outputCharsPerPrompt(_ data: Data) -> [Int] {
        var outputs: [Int] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // ToolResults lines carry the bulk of the bytes and never add output; skip them unparsed.
            if String(decoding: line.prefix(96), as: UTF8.self).contains("\"kind\":\"ToolResults\"") { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let kind = json["kind"] as? String
            else { continue }
            if kind == "Prompt" {
                outputs.append(0)
            } else if kind == "AssistantMessage", !outputs.isEmpty {
                let content = (json["data"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                outputs[outputs.count - 1] += content.reduce(0) { $0 + contentChars($1) }
            }
        }
        return outputs
    }

    private static func contentChars(_ item: [String: Any]) -> Int {
        switch item["kind"] as? String {
        case "text":
            if let text = item["data"] as? String { return text.unicodeScalars.count }
            if let text = (item["data"] as? [String: Any])?["text"] as? String { return text.unicodeScalars.count }
            return 0
        case "toolUse":
            guard let data = item["data"] as? [String: Any] else { return 0 }
            let name = (data["name"] as? String)?.unicodeScalars.count ?? 0
            let input = data["input"].flatMap { value -> Int? in
                guard JSONSerialization.isValidJSONObject(value),
                      let encoded = try? JSONSerialization.data(withJSONObject: value)
                else { return nil }
                return String(decoding: encoded, as: UTF8.self).unicodeScalars.count
            } ?? 2
            return name + input
        default:
            return 0
        }
    }

    private static func readSessions(root: URL, cutoffStart: Date, complete: inout Bool) -> [ParsedSession] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            complete = false
            return []
        }

        let cutoffDay = localDayEpoch(cutoffStart)
        func needsOutputs(_ session: ParsedSession) -> Bool { session.turns.contains { $0.day >= cutoffDay } }
        var sessions: [ParsedSession] = []
        var live = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            guard mtime >= cutoffStart, size > 50 else { continue }
            guard size < maxSessionBytes else {
                complete = false
                continue
            }

            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let companion = url.deletingPathExtension().appendingPathExtension("jsonl")
            let companionValues = try? companion.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])

            cacheLock.lock()
            let cached = fileCache[path]
            cacheLock.unlock()
            if let cached, cached.mtime == mtime, cached.size == size,
               cached.companionMtime == companionValues?.contentModificationDate,
               cached.companionSize == companionValues?.fileSize,
               cached.outputsLoaded || !needsOutputs(cached.session)
            {
                sessions.append(cached.session)
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  var session = parseSession(sessionData: data, companionData: nil, fallbackMtime: mtime)
            else {
                complete = false
                continue
            }
            // Companion transcripts are large; only read them when a turn falls inside the window.
            var outputsLoaded = companionValues == nil
            if !outputsLoaded, needsOutputs(session) {
                if let companionData = try? Data(contentsOf: companion, options: .mappedIfSafe) {
                    session = session.attaching(outputs: outputCharsPerPrompt(companionData))
                    outputsLoaded = true
                } else {
                    complete = false
                }
            }
            cacheLock.lock()
            fileCache[path] = CachedSession(
                mtime: mtime,
                size: size,
                companionMtime: companionValues?.contentModificationDate,
                companionSize: companionValues?.fileSize,
                outputsLoaded: outputsLoaded,
                session: session
            )
            cacheLock.unlock()
            sessions.append(session)
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()
        return sessions
    }

    private static func defaultProxyEntries(since: Date) -> [KiroProxyUsageLedger.Entry] {
        mergeProxyEntries(
            ledger: KiroProxyUsageLedger.read(since: since),
            claudeLog: LocalTokenCostScanner.kiroProxyEntriesFromClaudeLogs(since: since)
        )
    }

    private static func sumCredits(_ raw: [[String: Any]]?) -> Double {
        guard let list = raw else { return 0 }
        var total = 0.0
        for item in list {
            let unit = (item["unit"] as? String)?.lowercased() ?? ""
            guard unit.contains("credit"), let value = jsonDouble(item["value"]) else { continue }
            total += value
        }
        return total
    }

    private static func displayModel(_ raw: String) -> String {
        TokenPricingCatalog.normalizeModelID(raw) ?? raw
    }

    private static func millicredits(_ credits: Double) -> Int {
        Int((credits * 1000).rounded())
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    /// Parse a Kiro ISO8601 timestamp (plain or 6-digit fractional microseconds).
    static func parseKiroDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.kiro.date(from: raw) ?? ISO8601DateFormatter.kiroFractional.date(from: raw)
    }

    /// Day bucket for a turn: its own `end_timestamp` when parseable, otherwise the session's
    /// stable fallback day (created_at, never the file's mtime). `internal` for the self-check.
    static func resolveTurnDayKey(endTimestamp: String?, fallbackDayKey: Int) -> Int {
        if let end = endTimestamp, let date = parseKiroDate(end) {
            return localDayEpoch(date)
        }
        return fallbackDayKey
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

// MARK: - Grok CLI (usage.json exact per-turn usage; signals.json estimate fallback)

enum LocalGrokUsage {
    struct TurnUsage: Equatable {
        let day: Int
        let model: String
        let uncachedInput: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let total: Int
        let modelCalls: Int
        let costUsdTicks: Int
    }

    struct Bucket: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    struct RowKey: Hashable {
        let model: String
        let unit: UsageVolumeUnit
    }

    struct Collection {
        var days: [Int: [RowKey: Bucket]] = [:]
        var isComplete = true
        var sources: [String: Double] = [:]
        var oldestSource: Date?
    }

    static let estimateSuffix = " (est.)"
    static let estimateBasis = "est. from session context occupancy"

    private static let cacheLock = NSLock()
    private static var usageCache: [String: (mtime: Date, size: Int, turns: [TurnUsage])] = [:]
    private static var signalsCache: [String: (mtime: Date, size: Int, tokens: Int, model: String, requests: Int)] = [:]

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, root: URL? = nil) -> ProviderCostSnapshot? {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, root: root)
        let today = localDayEpoch(now)

        // Exact usage.json rows set the headline; the signals estimate only stands in when there are none.
        let headlineUnit: UsageVolumeUnit = collection.days.values.contains { $0.keys.contains { $0.unit == .tokens } }
            ? .tokens : .estimatedTokens
        var merged: [RowKey: Bucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        for (day, rows) in collection.days {
            for (key, bucket) in rows {
                merged[key, default: Bucket()].add(bucket)
                if day == today, key.unit == headlineUnit {
                    sessionTokens += bucket.total
                    sessionCost += bucket.cost
                }
            }
        }
        let rows = usageRows(merged)
        let headlineRows = rows.filter { $0.volumeUnit == headlineUnit }
        let historyTokens = headlineRows.reduce(0) { $0 + $1.totalVolume }
        let historyCost = headlineRows.reduce(0) { $0 + $1.costUSD }
        guard historyTokens > 0 || historyCost > 0 else { return nil }

        return ProviderCostSnapshot.make(
            providerID: "grok",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: rows.map(\.modelTokenUsage),
            volumeUnit: headlineUnit,
            updatedAt: now
        )
    }

    /// Per-day usage. usage.json turns are exact; sessions without it fall back to the
    /// signals.json occupancy estimate pinned to the last-activity day (sessionApproximate).
    static func dailyUsage(now: Date = Date(), historyDays: Int = 30) -> [UsageDayKey: DailyProviderUsage] {
        dailyUsageScan(now: now, historyDays: historyDays).days
    }

    static func dailyUsageScan(now: Date = Date(), historyDays: Int = 30, root: URL? = nil) -> LocalDailyUsageScan {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, root: root)
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, buckets) in collection.days {
            let rows = usageRows(buckets)
            guard !rows.isEmpty else { continue }
            let estimated = buckets.keys.contains { $0.unit == .estimatedTokens }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "grok",
                models: rows.map(\.dailyModelUsage),
                volumeUnit: buckets.keys.contains { $0.unit == .tokens } ? .tokens : .estimatedTokens,
                fidelity: estimated ? .sessionApproximate : .exact
            )
        }
        return LocalDailyUsageScan(
            providerID: "grok", days: result, cutoffStart: cutoffStart, now: now, isComplete: collection.isComplete,
            sources: collection.sources, oldestSource: collection.oldestSource
        )
    }

    static func collect(cutoffStart: Date, root: URL?) -> Collection {
        let root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions")
        var collection = Collection()
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                  at: root.resolvingSymlinksInPath(),
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            collection.isComplete = false
            return collection
        }

        var sessionDirs = Set<URL>()
        for case let url as URL in enumerator where url.lastPathComponent == "signals.json" || url.lastPathComponent == "usage.json" {
            sessionDirs.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        let rootPath = root.resolvingSymlinksInPath().path

        let cutoffDay = localDayEpoch(cutoffStart)
        var liveUsage = Set<String>()
        var liveSignals = Set<String>()
        for dir in sessionDirs {
            let dirPath = dir.resolvingSymlinksInPath().path
            let ephemeral = isEphemeralSessionPath(dirPath.hasPrefix(rootPath) ? String(dirPath.dropFirst(rootPath.count)) : dirPath)
            let usageURL = dir.appendingPathComponent("usage.json")
            if let values = try? usageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                let mtime = values.contentModificationDate ?? .distantPast
                collection.oldestSource = min(collection.oldestSource ?? mtime, mtime)
                guard mtime >= cutoffStart else { continue }
                let path = usageURL.resolvingSymlinksInPath().path
                liveUsage.insert(path)
                collection.sources[usageSourcePath(usageURL)] = mtime.timeIntervalSince1970
                if let turns = usageTurns(path: path, url: usageURL, mtime: mtime, size: values.fileSize ?? 0) {
                    // Scratch-dir sessions still bill xAI, so only drop them when nothing was billed.
                    let billed = turns.contains { $0.modelCalls > 0 || $0.costUsdTicks > 0 }
                    guard !ephemeral || billed else { continue }
                    for turn in turns where turn.day >= cutoffDay {
                        let key = RowKey(model: turn.model, unit: .tokens)
                        collection.days[turn.day, default: [:]][key, default: Bucket()].add(Bucket(
                            input: turn.uncachedInput,
                            output: turn.output,
                            cacheRead: turn.cacheRead,
                            cacheWrite: turn.cacheWrite,
                            total: turn.total,
                            requests: turn.modelCalls,
                            cost: turnCostUSD(turn)
                        ))
                    }
                    continue
                }
                collection.isComplete = false
            }

            guard !ephemeral else { continue }
            let signalsURL = dir.appendingPathComponent("signals.json")
            guard let values = try? signalsURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                continue
            }
            let mtime = values.contentModificationDate ?? .distantPast
            collection.oldestSource = min(collection.oldestSource ?? mtime, mtime)
            let activity = sessionActivityDate(sessionDir: dir) ?? mtime
            guard activity >= cutoffStart || mtime >= cutoffStart else { continue }
            let path = signalsURL.resolvingSymlinksInPath().path
            liveSignals.insert(path)
            collection.sources[usageSourcePath(signalsURL)] = mtime.timeIntervalSince1970
            guard let parsed = signalsEstimate(path: path, url: signalsURL, mtime: mtime, size: values.fileSize ?? 0) else {
                collection.isComplete = false
                continue
            }
            let day = localDayEpoch(activity)
            guard parsed.tokens > 0, day >= cutoffDay else { continue }
            let input = Int(Double(parsed.tokens) * 0.7)
            let output = parsed.tokens - input
            let key = RowKey(model: parsed.model + estimateSuffix, unit: .estimatedTokens)
            collection.days[day, default: [:]][key, default: Bucket()].add(Bucket(
                input: input,
                output: output,
                cacheRead: 0,
                total: parsed.tokens,
                requests: parsed.requests,
                cost: TokenPricingCatalog.estimateUSD(model: parsed.model, inputTokens: input, outputTokens: output)
            ))
        }

        cacheLock.lock()
        usageCache = usageCache.filter { liveUsage.contains($0.key) }
        signalsCache = signalsCache.filter { liveSignals.contains($0.key) }
        cacheLock.unlock()
        return collection
    }

    /// Per-turn, per-model rows from a Grok CLI `usage.json`. Nil when the file is not valid JSON.
    static func parseUsageFile(_ data: Data, fallbackDate: Date) -> [TurnUsage]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fallbackDay = (json["updatedAt"] as? String).flatMap(parseGrokDate).map(localDayEpoch)
            ?? localDayEpoch(fallbackDate)
        var result: [TurnUsage] = []
        for turn in json["turns"] as? [[String: Any]] ?? [] {
            let day = (turn["endedAt"] as? String).flatMap(parseGrokDate).map(localDayEpoch) ?? fallbackDay
            var perModel = turn["modelUsage"] as? [String: [String: Any]] ?? [:]
            if perModel.isEmpty {
                perModel = [(turn["primaryModelId"] as? String) ?? "grok": turn]
            }
            for (rawModel, usage) in perModel.sorted(by: { $0.key < $1.key }) {
                let input = max(0, jsonInt(usage["inputTokens"]) ?? 0)
                let cached = max(0, jsonInt(usage["cachedReadTokens"]) ?? 0)
                let created = max(0, jsonInt(usage["cacheCreationTokens"]) ?? 0)
                let output = max(0, jsonInt(usage["outputTokens"]) ?? 0)
                let uncached = max(0, input - cached - created)
                let declared = max(0, jsonInt(usage["totalTokens"]) ?? 0)
                let calls = max(0, jsonInt(usage["modelCalls"]) ?? 0)
                let ticks = max(0, jsonInt(usage["costUsdTicks"]) ?? 0)
                let total = declared > 0 ? declared : uncached + cached + created + output
                guard total > 0 || calls > 0 || ticks > 0 else { continue }
                result.append(TurnUsage(
                    day: day,
                    model: TokenPricingCatalog.normalizeModelID(rawModel) ?? rawModel,
                    uncachedInput: uncached,
                    cacheRead: cached,
                    cacheWrite: created,
                    output: output,
                    total: total,
                    modelCalls: calls,
                    costUsdTicks: ticks
                ))
            }
        }
        return result
    }

    /// xAI's billed cost (1e-10 USD ticks) when present, else list price.
    static func turnCostUSD(_ turn: TurnUsage) -> Double {
        if turn.costUsdTicks > 0 { return Double(turn.costUsdTicks) / 1e10 }
        return TokenPricingCatalog.estimateUSD(
            model: turn.model,
            inputTokens: turn.uncachedInput,
            outputTokens: turn.output,
            cacheReadTokens: turn.cacheRead,
            cacheWriteTokens: turn.cacheWrite
        )
    }

    private static func usageRows(_ buckets: [RowKey: Bucket]) -> [LocalUsageRow] {
        buckets.compactMap { key, bucket in
            guard bucket.total > 0 || bucket.cost > 0 else { return nil }
            return LocalUsageRow(
                model: key.model,
                inputTokens: bucket.input,
                outputTokens: bucket.output,
                cacheReadTokens: bucket.cacheRead,
                cacheWriteTokens: bucket.cacheWrite,
                totalVolume: bucket.total,
                costUSD: bucket.cost,
                requests: bucket.requests,
                volumeUnit: key.unit,
                estimateBasis: key.unit == .estimatedTokens ? estimateBasis : nil
            )
        }
        .sorted { $0.totalVolume != $1.totalVolume ? $0.totalVolume > $1.totalVolume : $0.model < $1.model }
    }

    private static func usageTurns(path: String, url: URL, mtime: Date, size: Int) -> [TurnUsage]? {
        cacheLock.lock()
        if let cached = usageCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return cached.turns
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url), let turns = parseUsageFile(data, fallbackDate: mtime) else {
            return nil
        }
        cacheLock.lock()
        usageCache[path] = (mtime, size, turns)
        cacheLock.unlock()
        return turns
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

    private static func signalsEstimate(path: String, url: URL, mtime: Date, size: Int) -> (tokens: Int, model: String, requests: Int)? {
        cacheLock.lock()
        if let c = signalsCache[path], c.mtime == mtime, c.size == size {
            cacheLock.unlock()
            return (c.tokens, c.model, c.requests)
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let turns = jsonInt(json["assistantMessageCount"]) ?? 0
        let tokens = estimatedCumulativeTokens(
            before: jsonInt(json["totalTokensBeforeCompaction"]) ?? 0,
            context: jsonInt(json["contextTokensUsed"]) ?? 0,
            turns: turns
        )
        let model: String = {
            if let primary = TokenPricingCatalog.normalizeModelID(json["primaryModelId"] as? String) {
                return primary
            }
            if let used = json["modelsUsed"] as? [String] {
                var counts: [String: Int] = [:]
                for m in used {
                    if let n = TokenPricingCatalog.normalizeModelID(m) { counts[n, default: 0] += 1 }
                }
                if let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
                    return top
                }
            }
            return "grok-4.5"
        }()
        let requests = max(0, turns)
        cacheLock.lock()
        signalsCache[path] = (mtime, size, tokens, model, requests)
        cacheLock.unlock()
        return (tokens, model, requests)
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
}

private extension LocalGrokUsage.Bucket {
    mutating func add(_ other: LocalGrokUsage.Bucket) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite += other.cacheWrite
        total += other.total
        requests += other.requests
        cost += other.cost
    }
}

// MARK: - OpenCode (SQLite session table)

enum LocalOpenCodeUsage {
    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, dbURL: URL? = nil) -> ProviderCostSnapshot? {
        guard let db = openOpenCodeDB(dbURL) else { return nil }
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
    private static func databaseURL(_ override: URL?) -> URL? {
        let candidates = override.map { [$0] } ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/opencode.db"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func openOpenCodeDB(_ override: URL? = nil) -> OpaquePointer? {
        guard let dbURL = databaseURL(override) else { return nil }
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
        var cacheWrite = 0
        var total = 0
        var cost = 0.0
        var requests = 0

        mutating func add(_ usage: MessageTokens, cost: Double) {
            input += usage.input
            output += usage.output
            cache += usage.cacheRead
            cacheWrite += usage.cacheWrite
            total += usage.total
            self.cost += cost
            requests += 1
        }
    }

    /// Token fields of one assistant `message.data` blob; `output` already includes reasoning.
    struct MessageTokens: Equatable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let storedCost: Double
        /// False when the row carries no `cost` at all (older OpenCode), as opposed to a stored 0.
        var hasStoredCost = true
        var providerID: String?

        var total: Int { input + output + cacheRead + cacheWrite }

        init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, storedCost: Double, providerID: String? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.storedCost = storedCost
            self.providerID = providerID
        }

        init(message json: [String: Any]) {
            let tokens = json["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            input = max(0, jsonInt(tokens["input"]) ?? 0)
            output = max(0, jsonInt(tokens["output"]) ?? 0) + max(0, jsonInt(tokens["reasoning"]) ?? 0)
            cacheRead = max(0, jsonInt(cache["read"]) ?? 0)
            cacheWrite = max(0, jsonInt(cache["write"]) ?? 0)
            storedCost = jsonDouble(json["cost"]) ?? 0
            hasStoredCost = jsonDouble(json["cost"]) != nil
            providerID = (json["providerID"] as? String) ?? (json["providerId"] as? String)
        }

        /// A stored $0 from OpenCode Zen is a free model and stays free.
        var isFreeZenModel: Bool { hasStoredCost && storedCost <= 0 && providerID?.lowercased() == "opencode" }

        /// A third-party row whose stored $0 is overridden by list price, so the UI must call it an estimate.
        var isListPriceOverride: Bool { hasStoredCost && storedCost <= 0 && !isFreeZenModel && total > 0 }

        /// OpenCode's own per-message cost (already model-aware); list price only when it stored none.
        func costUSD(model: String) -> Double {
            if storedCost > 0 || isFreeZenModel { return max(0, storedCost) }
            return TokenPricingCatalog.estimateUSD(
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite
            )
        }

        func rowModel(_ model: String) -> String {
            isListPriceOverride ? model + LocalOpenCodeUsage.listPriceSuffix : model
        }
    }

    static let listPriceSuffix = " (list-price est.)"

    private static func assistantMessage(_ stmt: OpaquePointer, column: Int32) -> [String: Any]? {
        guard let c = sqlite3_column_text(stmt, column),
              let data = String(cString: c).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["role"] as? String) == "assistant"
        else { return nil }
        return json
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
            guard let json = assistantMessage(stmt, column: 1) else { continue }
            let usage = MessageTokens(message: json)
            guard usage.total > 0 || usage.storedCost > 0 else { continue }

            let model = messageModelID(json) ?? "opencode"
            let cost = usage.costUSD(model: model)
            models[usage.rowModel(model), default: TokenBucket()].add(usage, cost: cost)

            historyTokens += usage.total
            historyCost += cost
            if created >= todayStartTs {
                sessionTokens += usage.total
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
                cacheWriteTokens: b.cacheWrite,
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
        let sqlCandidates = [
            """
            SELECT model, tokens_input, tokens_output, tokens_cache_read, tokens_reasoning,
                   cost, time_updated, tokens_cache_write
            FROM session
            WHERE time_updated >= ?;
            """,
            """
            SELECT model, tokens_input, tokens_output, tokens_cache_read, tokens_reasoning,
                   cost, time_updated, 0
            FROM session
            WHERE time_updated >= ?;
            """,
        ]
        var prepared: OpaquePointer?
        for sql in sqlCandidates {
            if sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, prepared != nil { break }
            sqlite3_finalize(prepared)
            prepared = nil
        }
        guard let stmt = prepared else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTs)

        var models: [String: TokenBucket] = [:]
        var historyTokens = 0
        var historyCost = 0.0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let modelRaw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "{}"
            let model = TokenPricingCatalog.normalizeModelID(parseOpenCodeModel(modelRaw))
                ?? parseOpenCodeModel(modelRaw)
            let usage = MessageTokens(
                input: max(0, Int(sqlite3_column_int64(stmt, 1))),
                output: max(0, Int(sqlite3_column_int64(stmt, 2))) + max(0, Int(sqlite3_column_int64(stmt, 4))),
                cacheRead: max(0, Int(sqlite3_column_int64(stmt, 3))),
                cacheWrite: max(0, Int(sqlite3_column_int64(stmt, 7))),
                storedCost: sqlite3_column_double(stmt, 5),
                providerID: parseOpenCodeProvider(modelRaw)
            )
            guard usage.total > 0 || usage.storedCost > 0 else { continue }

            let cost = usage.costUSD(model: model)
            models[usage.rowModel(model), default: TokenBucket()].add(usage, cost: cost)
            historyTokens += usage.total
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
                cacheWriteTokens: b.cacheWrite,
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
        dailyUsageScan(now: now, historyDays: historyDays).days
    }

    static func dailyUsageScan(now: Date = Date(), historyDays: Int = 30, dbURL: URL? = nil) -> LocalDailyUsageScan {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        func incomplete() -> LocalDailyUsageScan {
            LocalDailyUsageScan(providerID: "opencode", days: [:], cutoffStart: cutoffStart, now: now, isComplete: false)
        }
        guard let resolvedURL = databaseURL(dbURL), let db = openOpenCodeDB(resolvedURL) else { return incomplete() }
        defer { sqlite3_close(db) }

        let scale = detectTimestampScale(db: db)
        let cutoffTs = Int64(cutoffStart.timeIntervalSince1970) * scale
        let lastWrite = [resolvedURL, URL(fileURLWithPath: resolvedURL.path + "-wal")].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        let sources = lastWrite.map { [usageSourcePath(resolvedURL): $0.timeIntervalSince1970] } ?? [:]
        let oldestMessage = oldestMessageDate(db: db, scale: scale)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT time_created, data FROM message WHERE time_created >= ?;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            // No `message` table (older OpenCode): no trustworthy per-day signal exists.
            return incomplete()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffTs)

        var perDay: [Int: [String: TokenBucket]] = [:]
        var daysMissingModel = Set<Int>()

        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            let created = sqlite3_column_int64(stmt, 0)
            guard let json = assistantMessage(stmt, column: 1) else { continue }
            let usage = MessageTokens(message: json)
            guard usage.total > 0 || usage.storedCost > 0 else { continue }

            let day = dayKey(forEpoch: created, scale: scale)
            let named = messageModelID(json)
            if named == nil { daysMissingModel.insert(day) }
            let model = named ?? "opencode"
            perDay[day, default: [:]][usage.rowModel(model), default: TokenBucket()].add(usage, cost: usage.costUSD(model: model))
        }

        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in perDay {
            let rows = models.map { name, b in
                DailyModelUsage(
                    model: name,
                    inputTokens: b.input,
                    outputTokens: b.output,
                    cacheReadTokens: b.cache,
                    cacheWriteTokens: b.cacheWrite,
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
        return LocalDailyUsageScan(
            providerID: "opencode", days: result, cutoffStart: cutoffStart, now: now, isComplete: rc == SQLITE_DONE,
            sources: sources, oldestSource: oldestMessage
        )
    }

    /// The DB holds all history, so its oldest surviving message bounds what a rescan can prove.
    private static func oldestMessageDate(db: OpaquePointer, scale: Int64) -> Date? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(time_created) FROM message;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)) / TimeInterval(max(1, scale)))
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
        return localDayEpoch(Date(timeIntervalSince1970: seconds))
    }

    private static func parseOpenCodeProvider(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["providerID"] as? String
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

    /// Today's assistant-message tokens/cost from the per-turn `message` table. Returns (0, 0)
    /// when the table is absent (older OpenCode) rather than mis-attributing a session total.
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
            guard let json = assistantMessage(stmt, column: 0) else { continue }
            let usage = MessageTokens(message: json)
            tokens += usage.total
            cost += usage.storedCost
        }
        return (tokens, cost)
    }
}

// MARK: - Antigravity IDE (conversation DBs under ~/.gemini/antigravity-ide)

/// Reads per-generation usage from Antigravity IDE `conversations/*.db` `gen_metadata` blobs.
/// Each blob's field 1 is the generation; its field 4 is Codeium's ModelUsageStats.
enum LocalAntigravityUsage {
    struct GenerationUsage: Equatable {
        let model: String
        let priced: Bool
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        let responseID: String?
        let timestamp: TimeInterval?

        var total: Int { input + output + cacheWrite + cacheRead }
    }

    struct Bucket: Equatable {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        var requests = 0
        var cost = 0.0

        var total: Int { input + output + cacheWrite + cacheRead }
    }

    struct Collection {
        var days: [Int: [String: Bucket]] = [:]
        var approximateDays = Set<Int>()
        var isComplete = true
        var sources: [String: Double] = [:]
        var oldestSource: Date?
    }

    static let unknownModel = "antigravity-unknown"

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, roots: [URL]? = nil) -> ProviderCostSnapshot? {
        let collection = aggregateByDay(now: now, historyDays: historyDays, roots: roots)
        guard !collection.days.isEmpty else {
            NSLog("[UsageScan] antigravity: no conversation days (roots=%ld)", (roots ?? conversationRoots()).count)
            return nil
        }

        let today = localDayEpoch(now)
        var models: [String: Bucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        for (day, dayModels) in collection.days {
            for (model, bucket) in dayModels {
                models[model, default: Bucket()].add(bucket)
                if day == today {
                    sessionTokens += bucket.total
                    sessionCost += bucket.cost
                }
            }
        }
        let rows = usageRows(models)
        let historyTokens = rows.reduce(0) { $0 + $1.totalVolume }
        let historyCost = rows.reduce(0) { $0 + $1.costUSD }
        guard historyTokens > 0 || historyCost > 0 else { return nil }

        NSLog(
            "[UsageScan] antigravity: tokens30d=%ld today=%ld models=%ld generations=%ld",
            historyTokens, sessionTokens, rows.count, rows.reduce(0) { $0 + $1.requests }
        )

        return ProviderCostSnapshot.make(
            providerID: "antigravity",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: rows.map(\.modelTokenUsage),
            updatedAt: now
        )
    }

    static func dailyUsage(now: Date = Date(), historyDays: Int = 30) -> [UsageDayKey: DailyProviderUsage] {
        dailyUsageScan(now: now, historyDays: historyDays).days
    }

    /// Per-generation timestamps make days exact; a day is approximate only when a row had none.
    static func dailyUsageScan(now: Date = Date(), historyDays: Int = 30, roots: [URL]? = nil) -> LocalDailyUsageScan {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = aggregateByDay(now: now, historyDays: historyDays, roots: roots)
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in collection.days {
            let rows = usageRows(models)
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "antigravity",
                models: rows.map(\.dailyModelUsage),
                volumeUnit: .tokens,
                fidelity: collection.approximateDays.contains(day) ? .sessionApproximate : .exact
            )
        }
        return LocalDailyUsageScan(
            providerID: "antigravity", days: result, cutoffStart: cutoffStart, now: now, isComplete: collection.isComplete,
            sources: collection.sources, oldestSource: collection.oldestSource
        )
    }

    private static func usageRows(_ models: [String: Bucket]) -> [LocalUsageRow] {
        models.compactMap { name, b in
            guard b.total > 0 || b.requests > 0 else { return nil }
            return LocalUsageRow(
                model: name,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cacheRead,
                cacheWriteTokens: b.cacheWrite,
                totalVolume: b.total,
                costUSD: b.cost,
                requests: b.requests,
                volumeUnit: .tokens
            )
        }
        .sorted { $0.totalVolume != $1.totalVolume ? $0.totalVolume > $1.totalVolume : $0.model < $1.model }
    }

    static func aggregateByDay(now: Date, historyDays: Int, roots: [URL]? = nil) -> Collection {
        var collection = Collection()
        let roots = roots ?? conversationRoots()
        guard !roots.isEmpty else {
            collection.isComplete = false
            return collection
        }

        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let cutoffEpoch = cutoffStart.timeIntervalSince1970
        var seenResponses = Set<String>()

        for root in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                collection.isComplete = false
                continue
            }

            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "db" {
                guard let mtime = lastWriteDate(forDatabase: url) else { continue }
                collection.oldestSource = min(collection.oldestSource ?? mtime, mtime)
                // Skip DBs last touched before the window (conversations are append-mostly).
                guard mtime >= cutoffStart else { continue }
                collection.sources[usageSourcePath(url)] = mtime.timeIntervalSince1970
                let ok = scanConversationDB(
                    at: url,
                    cutoffEpoch: cutoffEpoch,
                    fallbackDay: localDayEpoch(mtime),
                    seenResponses: &seenResponses,
                    into: &collection
                )
                if !ok { collection.isComplete = false }
            }
        }
        return collection
    }

    private static func lastWriteDate(forDatabase url: URL) -> Date? {
        let dates = [url, URL(fileURLWithPath: url.path + "-wal")].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max()
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
        seenResponses: inout Set<String>,
        into collection: inout Collection
    ) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return !hasTable(db, named: "gen_metadata")
        }
        defer { sqlite3_finalize(stmt) }

        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            guard let usage = decodeGeneration(data) else { continue }
            if let ts = usage.timestamp, ts < cutoffEpoch { continue }
            if let response = usage.responseID, !seenResponses.insert(response).inserted { continue }

            let day: Int
            if let ts = usage.timestamp {
                day = localDayEpoch(Date(timeIntervalSince1970: ts))
            } else {
                day = fallbackDay
                collection.approximateDays.insert(day)
            }
            let cost = usage.priced
                ? TokenPricingCatalog.requestCostUSD(
                    model: usage.model,
                    uncachedInput: usage.input,
                    cacheRead: usage.cacheRead,
                    cacheWrite5m: usage.cacheWrite,
                    output: usage.output
                )
                : 0
            collection.days[day, default: [:]][usage.model, default: Bucket()].add(Bucket(
                input: usage.input,
                output: usage.output,
                cacheWrite: usage.cacheWrite,
                cacheRead: usage.cacheRead,
                requests: 1,
                cost: cost
            ))
        }
        return rc == SQLITE_DONE
    }

    private static func hasTable(_ db: OpaquePointer, named name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            sqlite3_finalize(stmt)
            return true
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Structured ModelUsageStats decode: f2 uncached input, f3 output (thinking included),
    /// f4 cache write, f5 cache read, f11 response id; model f19 (label f21); time f9.4.1.
    static func decodeGeneration(_ data: Data) -> GenerationUsage? {
        guard let top = ProtoMessage(data),
              let generation = top.message(1),
              let usage = generation.message(4)
        else { return nil }

        let input = usage.int(2)
        let output = usage.int(3)
        let cacheWrite = usage.int(4)
        let cacheRead = usage.int(5)
        guard input + output + cacheWrite + cacheRead > 0 else { return nil }

        let model: String
        let priced: Bool
        if let raw = generation.string(19), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            model = TokenPricingCatalog.normalizeModelID(raw) ?? raw
            priced = true
        } else if let label = generation.string(21), let base = modelID(fromLabel: label) {
            priced = output > 0 || cacheRead > 0
            model = priced ? base : base + TokenPricingCatalog.unpricedSuffix
        } else {
            model = unknownModel
            priced = false
        }

        let seconds = generation.message(9)?.message(4)?.firstVarint(1)
        return GenerationUsage(
            model: model,
            priced: priced,
            input: input,
            output: output,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead,
            responseID: usage.string(11).flatMap { $0.isEmpty ? nil : $0 },
            timestamp: seconds.flatMap { $0 > 0 && $0 < 100_000_000_000 ? TimeInterval($0) : nil }
        )
    }

    /// "Gemini 3.8 Flash (High)" → "gemini-3.8-flash".
    static func modelID(fromLabel label: String) -> String? {
        var base = label
        if let paren = base.firstIndex(of: "(") { base = String(base[..<paren]) }
        let words = base.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: "-")
    }

    /// Strict protobuf field list; any malformed byte makes the whole message nil.
    struct ProtoMessage {
        struct Field {
            let number: Int
            let varint: UInt64?
            let bytes: Data?
        }

        let fields: [Field]

        init?(_ data: Data) {
            var fields: [Field] = []
            var i = data.startIndex
            while i < data.endIndex {
                guard let (key, afterKey) = ProtoMessage.readVarint(data, at: i) else { return nil }
                i = afterKey
                let number = Int(truncatingIfNeeded: key >> 3)
                guard number > 0 else { return nil }
                switch key & 0x7 {
                case 0:
                    guard let (value, next) = ProtoMessage.readVarint(data, at: i) else { return nil }
                    fields.append(Field(number: number, varint: value, bytes: nil))
                    i = next
                case 1:
                    guard data.distance(from: i, to: data.endIndex) >= 8 else { return nil }
                    fields.append(Field(number: number, varint: nil, bytes: nil))
                    i = data.index(i, offsetBy: 8)
                case 2:
                    guard let (length, next) = ProtoMessage.readVarint(data, at: i),
                          length <= UInt64(data.distance(from: next, to: data.endIndex))
                    else { return nil }
                    let end = data.index(next, offsetBy: Int(length))
                    fields.append(Field(number: number, varint: nil, bytes: data.subdata(in: next..<end)))
                    i = end
                case 5:
                    guard data.distance(from: i, to: data.endIndex) >= 4 else { return nil }
                    fields.append(Field(number: number, varint: nil, bytes: nil))
                    i = data.index(i, offsetBy: 4)
                default:
                    return nil
                }
            }
            self.fields = fields
        }

        func message(_ number: Int) -> ProtoMessage? {
            fields.first { $0.number == number && $0.bytes != nil }?.bytes.flatMap(ProtoMessage.init)
        }

        func string(_ number: Int) -> String? {
            fields.first { $0.number == number && $0.bytes != nil }?.bytes.map { String(decoding: $0, as: UTF8.self) }
        }

        func firstVarint(_ number: Int) -> UInt64? {
            fields.first { $0.number == number && $0.varint != nil }?.varint
        }

        /// Last occurrence wins; values that do not fit a sane Int (sentinels) read as 0.
        func int(_ number: Int) -> Int {
            guard let value = fields.last(where: { $0.number == number && $0.varint != nil })?.varint,
                  value <= UInt64(Int32.max) * 1024
            else { return 0 }
            return Int(value)
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
    }
}

private extension LocalAntigravityUsage.Bucket {
    mutating func add(_ other: LocalAntigravityUsage.Bucket) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        requests += other.requests
        cost += other.cost
    }
}

// MARK: - GitHub Copilot (CLI session-state events; JB panel transcripts as a char estimate)

enum LocalCopilotUsage {
    struct Bucket: Equatable {
        var input = 0
        var output = 0
        var requests = 0

        mutating func add(_ other: Bucket) {
            input += other.input
            output += other.output
            requests += other.requests
        }
    }

    typealias DayModels = [Int: [String: Bucket]]

    struct Collection {
        var days: DayModels = [:]
        var transcriptDays = Set<Int>()
        var isComplete = true
        var sources: [String: Double] = [:]
        var oldestSource: Date?
    }

    static let transcriptModel = "github-copilot (est.)"
    static let sessionEstimateBasis = "exact output · input est. (prompt text only)"
    static let transcriptEstimateBasis = "est. tokens (chars÷4)"
    private static let transcriptPricingModel = "gpt-4o"
    private static let maxFileBytes = 64_000_000

    private static let cacheLock = NSLock()
    private static var fileCache: [String: (mtime: Date, size: Int, days: DayModels)] = [:]

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30, root: URL? = nil) -> ProviderCostSnapshot? {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, root: root)
        let today = localDayEpoch(now)

        var merged: [String: Bucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        for (day, models) in collection.days {
            for (model, bucket) in models {
                merged[model, default: Bucket()].add(bucket)
                if day == today {
                    sessionTokens += bucket.input + bucket.output
                    sessionCost += costUSD(model: model, bucket: bucket)
                }
            }
        }
        let rows = usageRows(merged)
        let historyTokens = rows.reduce(0) { $0 + $1.totalVolume }
        guard historyTokens > 0 else { return nil }

        return ProviderCostSnapshot.make(
            providerID: "copilot",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: rows.reduce(0) { $0 + $1.costUSD },
            models: rows.map(\.modelTokenUsage),
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    /// Per-day usage. session-state days carry exact model + output tokens (input estimated);
    /// days fed by JB transcripts have no model dimension, so they are `.dayTotalsOnly`.
    static func dailyUsage(now: Date = Date(), historyDays: Int = 30) -> [UsageDayKey: DailyProviderUsage] {
        dailyUsageScan(now: now, historyDays: historyDays).days
    }

    static func dailyUsageScan(now: Date = Date(), historyDays: Int = 30, root: URL? = nil) -> LocalDailyUsageScan {
        let cutoffStart = analyticsCutoffStart(now: now, historyDays: historyDays)
        let collection = collect(cutoffStart: cutoffStart, root: root)
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in collection.days {
            let rows = usageRows(models)
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "copilot",
                models: rows.map(\.dailyModelUsage),
                volumeUnit: .estimatedTokens,
                fidelity: collection.transcriptDays.contains(day) ? .dayTotalsOnly : .exact
            )
        }
        return LocalDailyUsageScan(
            providerID: "copilot", days: result, cutoffStart: cutoffStart, now: now, isComplete: collection.isComplete,
            sources: collection.sources, oldestSource: collection.oldestSource
        )
    }

    static func collect(cutoffStart: Date, root: URL?) -> Collection {
        let root = (root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot"))
            .standardizedFileURL.resolvingSymlinksInPath()
        let stateRoot = root.appendingPathComponent("session-state").resolvingSymlinksInPath()
        let jbRoot = root.appendingPathComponent("jb").resolvingSymlinksInPath()
        let fm = FileManager.default
        var collection = Collection()
        collection.isComplete = fm.fileExists(atPath: stateRoot.path) || fm.fileExists(atPath: jbRoot.path)
        let cutoffDay = localDayEpoch(cutoffStart)
        var live = Set<String>()
        var sessionsWithEvents = Set<String>()

        func include(_ url: URL, transcript: Bool) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate
            else { return }
            collection.oldestSource = min(collection.oldestSource ?? mtime, mtime)
            guard mtime >= cutoffStart else { return }
            let size = values.fileSize ?? 0
            guard size > 0 else { return }
            guard size <= maxFileBytes else {
                collection.isComplete = false
                return
            }
            let path = url.resolvingSymlinksInPath().path
            live.insert(path)
            collection.sources[usageSourcePath(url)] = mtime.timeIntervalSince1970
            guard let days = parsedDays(path: path, url: url, mtime: mtime, size: size, transcript: transcript) else {
                collection.isComplete = false
                return
            }
            for (day, models) in days where day >= cutoffDay {
                for (model, bucket) in models {
                    collection.days[day, default: [:]][model, default: Bucket()].add(bucket)
                }
                if transcript { collection.transcriptDays.insert(day) }
            }
        }

        if fm.fileExists(atPath: stateRoot.path) {
            if let sessions = try? fm.contentsOfDirectory(at: stateRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for dir in sessions {
                    let events = dir.appendingPathComponent("events.jsonl")
                    guard fm.fileExists(atPath: events.path) else { continue }
                    sessionsWithEvents.insert(dir.lastPathComponent)
                    include(events, transcript: false)
                }
            } else {
                collection.isComplete = false
            }
        }

        if fm.fileExists(atPath: jbRoot.path) {
            if let enumerator = fm.enumerator(
                at: jbRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                let depth = jbRoot.pathComponents.count
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                    let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                    if components.count > depth, sessionsWithEvents.contains(components[depth]) { continue }
                    include(url, transcript: true)
                }
            } else {
                collection.isComplete = false
            }
        }

        cacheLock.lock()
        fileCache = fileCache.filter { live.contains($0.key) }
        cacheLock.unlock()
        return collection
    }

    /// Copilot CLI `session-state/*/events.jsonl`: exact output tokens and model per request,
    /// deduped by requestId; input is estimated from the user prompt text (chars/4).
    static func parseSessionEvents(_ data: Data, fallbackDay: Int) -> DayModels {
        var days: DayModels = [:]
        var seen = Set<String>()
        var pendingInput = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            let payload = json["data"] as? [String: Any] ?? [:]
            switch type {
            case "user.message":
                pendingInput += estimatedTokens(copilotText(from: payload))
            case "assistant.message":
                let key = (payload["requestId"] as? String) ?? (payload["messageId"] as? String) ?? (json["id"] as? String)
                if let key, !seen.insert(key).inserted { continue }
                let day = copilotDayKey(timestamp: json["timestamp"] as? String, fallbackDayKey: fallbackDay)
                let model = TokenPricingCatalog.normalizeModelID(payload["model"] as? String) ?? "copilot"
                let output = jsonInt(payload["outputTokens"]).map { max(0, $0) }
                    ?? estimatedTokens(copilotText(from: payload))
                days[day, default: [:]][model, default: Bucket()].add(Bucket(input: pendingInput, output: output, requests: 1))
                pendingInput = 0
            default:
                continue
            }
        }
        return days
    }

    /// JB panel transcripts: chars/4 of prompts (input) and replies (output); one request per
    /// distinct assistant (messageId, iterationNumber) model response, never per user message.
    static func parseTranscript(_ data: Data, fallbackDay: Int) -> DayModels {
        var days: DayModels = [:]
        var seen = Set<String>()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "assistant.message" || type == "user.message"
            else { continue }
            let payload = json["data"] as? [String: Any] ?? [:]
            let tokens = estimatedTokens(copilotText(from: payload))
            let day = copilotDayKey(timestamp: json["timestamp"] as? String, fallbackDayKey: fallbackDay)
            var bucket = Bucket()
            if type == "user.message" {
                bucket.input = tokens
            } else {
                let message = (payload["messageId"] as? String) ?? (json["id"] as? String)
                let key = message.map { "\($0)#\(jsonInt(payload["iterationNumber"]) ?? 0)" }
                if let key, !seen.insert(key).inserted { continue }
                bucket.output = tokens
                bucket.requests = 1
            }
            guard bucket.input + bucket.output + bucket.requests > 0 else { continue }
            days[day, default: [:]][transcriptModel, default: Bucket()].add(bucket)
        }
        return days
    }

    private static func parsedDays(path: String, url: URL, mtime: Date, size: Int, transcript: Bool) -> DayModels? {
        cacheLock.lock()
        if let c = fileCache[path], c.mtime == mtime, c.size == size {
            cacheLock.unlock()
            return c.days
        }
        cacheLock.unlock()
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fallbackDay = localDayEpoch(mtime)
        let days = transcript
            ? parseTranscript(data, fallbackDay: fallbackDay)
            : parseSessionEvents(data, fallbackDay: fallbackDay)
        cacheLock.lock()
        fileCache[path] = (mtime, size, days)
        cacheLock.unlock()
        return days
    }

    private static func usageRows(_ models: [String: Bucket]) -> [LocalUsageRow] {
        models.compactMap { model, bucket in
            let total = bucket.input + bucket.output
            guard total > 0 else { return nil }
            return LocalUsageRow(
                model: model,
                inputTokens: bucket.input,
                outputTokens: bucket.output,
                cacheReadTokens: 0,
                totalVolume: total,
                costUSD: costUSD(model: model, bucket: bucket),
                requests: bucket.requests,
                volumeUnit: .estimatedTokens,
                estimateBasis: model == transcriptModel ? transcriptEstimateBasis : sessionEstimateBasis
            )
        }
        .sorted { $0.totalVolume != $1.totalVolume ? $0.totalVolume > $1.totalVolume : $0.model < $1.model }
    }

    private static func costUSD(model: String, bucket: Bucket) -> Double {
        TokenPricingCatalog.estimateUSD(
            model: model == transcriptModel ? transcriptPricingModel : model,
            inputTokens: bucket.input,
            outputTokens: bucket.output
        )
    }

    private static func estimatedTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int((Double(trimmed.utf8.count) / 4.0).rounded(.up)))
    }

    private static let copilotISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Day bucket for a Copilot message: its own ISO8601 `timestamp` when present, else the
    /// file mtime day. `internal` for the self-check.
    static func copilotDayKey(timestamp: String?, fallbackDayKey: Int) -> Int {
        if let ts = timestamp, let date = copilotISO.date(from: ts) ?? ISO8601DateFormatter.kiro.date(from: ts) {
            return localDayEpoch(date)
        }
        return fallbackDayKey
    }

    private static func copilotText(from raw: Any?) -> String {
        guard let data = raw as? [String: Any] else { return "" }
        if let content = data["content"] as? String, !content.isEmpty { return content }
        if let text = data["text"] as? String { return text }
        if let parts = data["content"] as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined(separator: "\n")
        }
        return ""
    }
}
