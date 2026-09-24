import Foundation
import SQLite3

/// Cursor composer chats in `state.vscdb` (`cursorDiskKV`).
///
/// Analytics previously had no Cursor scanner, so Agent/Composer work (including
/// chats that happen to use a Grok-named model) never appeared — while Grok CLI
/// tmp/harness sessions did. This reads explicit bubble token counts when present,
/// otherwise one context-meter credit per conversation (Cursor's own
/// `promptTokenBreakdown.totalUsedTokens`).
enum LocalCursorUsage {
    private static let cacheLock = NSLock()
    private static var dbCache: [String: (mtime: Date, size: Int, perDay: [Int: [String: ModelBucket]])] = [:]

    private struct ModelBucket {
        var input = 0
        var output = 0
        var cacheRead = 0
        var total = 0
        var requests = 0
        var cost = 0.0
    }

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let today = dayKey(for: now)
        let byDay = detailedByDay(cutoff: cutoff)
        var modelBuckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0

        for (day, models) in byDay {
            for (model, bucket) in models {
                var acc = modelBuckets[model] ?? ModelBucket()
                acc.input += bucket.input
                acc.output += bucket.output
                acc.total += bucket.total
                acc.requests += bucket.requests
                acc.cost += bucket.cost
                modelBuckets[model] = acc
                historyTokens += bucket.total
                historyCost += bucket.cost
                if day == today {
                    sessionTokens += bucket.total
                    sessionCost += bucket.cost
                }
            }
        }
        guard historyTokens > 0 || !modelBuckets.isEmpty else { return nil }

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
            providerID: "cursor",
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCost,
            last30DaysTokens: historyTokens,
            last30DaysCostUSD: historyCost,
            models: models,
            volumeUnit: .estimatedTokens,
            updatedAt: now
        )
    }

    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let cutoffDay = dayKey(for: cutoff)
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in detailedByDay(cutoff: cutoff) where day >= cutoffDay {
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
                providerID: "cursor",
                models: rows,
                volumeUnit: .estimatedTokens,
                fidelity: .sessionApproximate
            )
        }
        return result
    }

    private static func detailedByDay(cutoff: Date) -> [Int: [String: ModelBucket]] {
        var result: [Int: [String: ModelBucket]] = [:]
        var live = Set<String>()
        for url in databaseURLs() {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            live.insert(path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            let parsed = parseDatabase(path: path, url: url, mtime: mtime, size: size, cutoff: cutoff)
            for (day, models) in parsed {
                var dayMap = result[day] ?? [:]
                for (model, bucket) in models {
                    var acc = dayMap[model] ?? ModelBucket()
                    acc.input += bucket.input
                    acc.output += bucket.output
                    acc.total += bucket.total
                    acc.requests += bucket.requests
                    acc.cost += bucket.cost
                    dayMap[model] = acc
                }
                result[day] = dayMap
            }
        }
        cacheLock.lock()
        dbCache = dbCache.filter { live.contains($0.key) }
        cacheLock.unlock()
        return result
    }

    private static func databaseURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = [
            home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        ]
        let workspaceRoot = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for kid in kids.prefix(80) {
                let db = kid.appendingPathComponent("state.vscdb")
                if FileManager.default.fileExists(atPath: db.path) {
                    urls.append(db)
                }
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func parseDatabase(
        path: String,
        url: URL,
        mtime: Date,
        size: Int,
        cutoff: Date
    ) -> [Int: [String: ModelBucket]] {
        cacheLock.lock()
        if let cached = dbCache[path], cached.mtime == mtime, cached.size == size {
            cacheLock.unlock()
            return cached.perDay
        }
        cacheLock.unlock()

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        var composers: [(id: String, json: [String: Any])] = []
        var stmt: OpaquePointer?
        let sql = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else { return [:] }
        defer { sqlite3_finalize(query) }
        while sqlite3_step(query) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(query, 0) else { continue }
            let key = String(cString: keyC)
            let composerID = String(key.dropFirst("composerData:".count))
            guard composerID != "empty-state-draft", !composerID.isEmpty else { continue }
            guard let json = blobJSON(query, column: 1) else { continue }
            composers.append((composerID, json))
        }

        var perDay: [Int: [String: ModelBucket]] = [:]
        let cutoffDay = dayKey(for: cutoff)
        for composer in composers {
            let entries = usageEntries(composerID: composer.id, json: composer.json, db: db)
            for entry in entries where entry.day >= cutoffDay {
                var dayMap = perDay[entry.day] ?? [:]
                var bucket = dayMap[entry.model] ?? ModelBucket()
                bucket.input += entry.input
                bucket.output += entry.output
                bucket.total += entry.input + entry.output
                bucket.requests += entry.requests
                bucket.cost += TokenPricingCatalog.estimateUSD(
                    model: entry.model,
                    inputTokens: entry.input,
                    outputTokens: entry.output
                )
                dayMap[entry.model] = bucket
                perDay[entry.day] = dayMap
            }
        }

        cacheLock.lock()
        dbCache[path] = (mtime, size, perDay)
        cacheLock.unlock()
        return perDay
    }

    private struct UsageEntry {
        var day: Int
        var model: String
        var input: Int
        var output: Int
        var requests: Int
    }

    private static func usageEntries(
        composerID: String,
        json: [String: Any],
        db: OpaquePointer
    ) -> [UsageEntry] {
        let model = normalizedModel(json["modelConfig"] as? [String: Any])
        let composerDay = dayKey(for: parseCursorDate(json["createdAt"] ?? json["lastUpdatedAt"]) ?? Date())

        var bubbleInput = 0
        var bubbleOutput = 0
        var userTurns = 0
        var lastBubbleDay = composerDay
        var hasExplicitTokens = false

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM cursorDiskKV WHERE key LIKE ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else { return [] }
        defer { sqlite3_finalize(query) }
        let pattern = "bubbleId:\(composerID):%"
        sqlite3_bind_text(query, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        while sqlite3_step(query) == SQLITE_ROW {
            guard let bubble = blobJSON(query, column: 0) else { continue }
            let type = bubble["type"] as? Int ?? 0
            if type == 1 { userTurns += 1 }
            if let date = parseCursorDate(bubble["createdAt"] ?? bubble["timestamp"]) {
                lastBubbleDay = dayKey(for: date)
            }
            let tokens = bubble["tokenCount"] as? [String: Any]
            let input = intValue(tokens?["inputTokens"])
            let output = intValue(tokens?["outputTokens"])
            if input > 0 || output > 0 {
                hasExplicitTokens = true
                bubbleInput += input
                bubbleOutput += output
            } else if type == 2 {
                let chars = bubbleText(bubble).count
                if chars > 0 {
                    bubbleOutput += max(1, chars / 4)
                }
            }
        }

        if userTurns == 0, !hasExplicitTokens {
            let headers = json["fullConversationHeadersOnly"] as? [Any]
            if (headers?.isEmpty ?? true), contextMeterTokens(json) == 0 {
                return []
            }
        }

        if hasExplicitTokens {
            return [UsageEntry(
                day: lastBubbleDay,
                model: model,
                input: bubbleInput,
                output: bubbleOutput,
                requests: max(1, userTurns)
            )]
        }

        let meter = contextMeterTokens(json)
        let input = meter > 0 ? meter : 0
        let output = bubbleOutput
        guard input > 0 || output > 0 else { return [] }
        return [UsageEntry(
            day: lastBubbleDay,
            model: model,
            input: input,
            output: output,
            requests: max(1, userTurns)
        )]
    }

    static func contextMeterTokens(_ json: [String: Any]) -> Int {
        if let breakdown = json["promptTokenBreakdown"] as? [String: Any] {
            let total = intValue(breakdown["totalUsedTokens"])
            if total > 0 { return total }
        }
        return intValue(json["contextTokensUsed"])
    }

    private static func normalizedModel(_ config: [String: Any]?) -> String {
        let raw = (config?["modelName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw.lowercased() == "default" {
            return "cursor-auto"
        }
        return TokenPricingCatalog.normalizeModelID(raw) ?? raw
    }

    private static func bubbleText(_ json: [String: Any]) -> String {
        if let text = json["text"] as? String { return text }
        if let rich = json["richText"] as? String { return rich }
        return ""
    }

    static func parseCursorDate(_ raw: Any?) -> Date? {
        if let value = raw as? Double {
            return dateFromEpoch(value)
        }
        if let value = raw as? Int {
            return dateFromEpoch(Double(value))
        }
        if let value = raw as? NSNumber {
            return dateFromEpoch(value.doubleValue)
        }
        if let value = raw as? String {
            if let num = Double(value) { return dateFromEpoch(num) }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: value) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: value)
        }
        return nil
    }

    private static func dateFromEpoch(_ value: Double) -> Date {
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private static func blobJSON(_ stmt: OpaquePointer, column: Int32) -> [String: Any]? {
        if let cstr = sqlite3_column_text(stmt, column) {
            let text = String(cString: cstr)
            if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                return json
            }
        }
        let bytes = sqlite3_column_bytes(stmt, column)
        guard bytes > 0, let blob = sqlite3_column_blob(stmt, column) else { return nil }
        let data = Data(bytes: blob, count: Int(bytes))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func intValue(_ raw: Any?) -> Int {
        JSONNumber.int(raw)
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}
