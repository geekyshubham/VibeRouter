import Foundation
import SQLite3

/// Cursor IDE composer chats (`state.vscdb`) and Cursor Agent CLI chats (`~/.cursor/chats/*/*/store.db`),
/// estimated per request with context growth as uncached input and the previous context as cache read.
enum LocalCursorUsage {
    struct UsageEntry: Equatable {
        var timestamp: Date
        var model: String
        var uncachedInput: Int
        var cacheRead: Int
        var output: Int
        var requests: Int
        var timeIsExact: Bool

        var totalTokens: Int { uncachedInput + cacheRead + output }
        var costUSD: Double {
            TokenPricingCatalog.requestCostUSD(
                model: model,
                uncachedInput: uncachedInput,
                cacheRead: cacheRead,
                output: output
            )
        }
    }

    /// `complete == false` means at least one existing source could not be opened or read.
    struct ScanResult {
        var entries: [UsageEntry]
        var complete: Bool
        /// Source path -> last write (database or its WAL, whichever is newer).
        var sources: [String: Double] = [:]
        /// Oldest per-chat CLI store; the IDE databases hold their whole history, so they never bound coverage.
        var oldestChatStore: Date?
    }

    struct CLISnapshot: Equatable {
        var contextTokens: Int
        var window: Int?
        var pendingStartedAt: Date?
        var modelName: String?
        var toolCallIDs: [String]
        var outputTokens: Int
    }

    struct AITrackingRecord: Equatable {
        var timestamp: Date
        var model: String?
    }

    /// ai_code_hashes rows by requestId (= snapshot toolCallId) and by conversationId (= agent directory).
    struct AITracking: Equatable {
        var byRequest: [String: AITrackingRecord] = [:]
        var byConversation: [String: [Date]] = [:]
    }

    /// A CLI store's own parse, independent of ai-tracking so tracking writes never force a re-copy.
    struct CLIStoreParse: Equatable {
        var snapshots: [CLISnapshot]
        var createdAt: Date?
        var lastActivity: Date
        var lastUsedModel: String?
    }

    struct Sources {
        var ideDatabases: [URL]
        var cliStores: [URL]
        var aiTracking: URL?
    }

    private struct FileStamp: Equatable {
        var mtime: Date
        var size: Int
    }

    private static let cacheLock = NSLock()
    private static var entryCache: [String: (stamp: [FileStamp], entries: [UsageEntry])] = [:]
    private static var cliParseCache: [String: (stamp: [FileStamp], parse: CLIStoreParse)] = [:]
    private static var aiTrackingCache: (key: String, stamp: [FileStamp], tracking: AITracking)?
    private static var cliStoreLoads = 0

    /// Store copies made so far, for tests.
    static var cliStoreLoadCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cliStoreLoads
    }

    // MARK: - Public surface

    static func costSnapshot(now: Date = Date(), historyDays: Int = 30) -> ProviderCostSnapshot? {
        costSnapshot(from: scan(now: now, historyDays: historyDays).entries, now: now)
    }

    static func dailyUsage(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage] {
        dailyUsage(from: scan(now: now, historyDays: historyDays).entries)
    }

    /// Nil when any Cursor source existed but could not be read; empty when scanned with no usage.
    static func dailyUsageIfComplete(
        now: Date = Date(),
        historyDays: Int = 30
    ) -> [UsageDayKey: DailyProviderUsage]? {
        let result = scan(now: now, historyDays: historyDays)
        guard result.complete else { return nil }
        return dailyUsage(from: result.entries)
    }

    static func scan(now: Date = Date(), historyDays: Int = 30, sources: Sources? = nil) -> ScanResult {
        let cutoff = analyticsCutoffStart(now: now, historyDays: historyDays)
        let sources = sources ?? defaultSources()
        var entries: [UsageEntry] = []
        var complete = true
        var live = Set<String>()
        var sourceMtimes: [String: Double] = [:]
        var oldestChatStore: Date?
        func lastWrite(_ stamps: [FileStamp]) -> Date { stamps.prefix(2).map(\.mtime).max() ?? .distantPast }

        for url in sources.ideDatabases {
            let key = cacheKey(url)
            live.insert(key)
            let stamps = [stamp(url), stamp(URL(fileURLWithPath: url.path + "-wal"))]
            sourceMtimes[key] = lastWrite(stamps).timeIntervalSince1970
            guard let parsed = cachedEntries(key: key, stamps: stamps, load: { ideEntries(databaseURL: url) }) else {
                complete = false
                continue
            }
            entries.append(contentsOf: parsed)
        }

        if !sources.cliStores.isEmpty {
            let tracking = sources.aiTracking.flatMap(cachedAITracking) ?? AITracking()
            for url in sources.cliStores {
                let key = cacheKey(url)
                live.insert(key)
                let wal = URL(fileURLWithPath: url.path + "-wal")
                let stamps = [stamp(url), stamp(wal)]
                let written = lastWrite(stamps)
                oldestChatStore = min(oldestChatStore ?? written, written)
                if written >= cutoff { sourceMtimes[key] = written.timeIntervalSince1970 }
                guard let parse = cachedCLIParse(key: key, stamps: stamps, load: { parseCLIStore(storeURL: url) }) else {
                    complete = false
                    continue
                }
                entries.append(contentsOf: cliEntries(
                    snapshots: parse.snapshots,
                    createdAt: parse.createdAt,
                    lastActivity: parse.lastActivity,
                    lastUsedModel: parse.lastUsedModel,
                    aiTracking: tracking.byRequest,
                    conversationTimes: tracking.byConversation[url.deletingLastPathComponent().lastPathComponent] ?? []
                ))
            }
        }

        cacheLock.lock()
        entryCache = entryCache.filter { live.contains($0.key) }
        cliParseCache = cliParseCache.filter { live.contains($0.key) }
        cacheLock.unlock()

        return ScanResult(
            entries: entries.filter { $0.timestamp >= cutoff },
            complete: complete,
            sources: sourceMtimes,
            oldestChatStore: oldestChatStore
        )
    }

    static let estimateBasis = "est. from context meter"

    static func costSnapshot(from entries: [UsageEntry], now: Date) -> ProviderCostSnapshot? {
        let today = dayKey(for: now)
        var buckets: [String: ModelBucket] = [:]
        var sessionTokens = 0
        var sessionCost = 0.0
        var historyTokens = 0
        var historyCost = 0.0
        for entry in entries {
            let cost = entry.costUSD
            buckets[entry.model, default: ModelBucket()].add(entry, cost: cost)
            historyTokens += entry.totalTokens
            historyCost += cost
            if dayKey(for: entry.timestamp) == today {
                sessionTokens += entry.totalTokens
                sessionCost += cost
            }
        }
        guard historyTokens > 0 || !buckets.isEmpty else { return nil }

        let models = buckets.map { model, b in
            ModelTokenUsage(
                model: model,
                inputTokens: b.input,
                outputTokens: b.output,
                cacheReadTokens: b.cacheRead,
                totalTokens: b.total,
                estimatedCostUSD: b.cost,
                requestCount: b.requests,
                volumeUnit: .estimatedTokens,
                estimateBasis: estimateBasis
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

    static func dailyUsage(from entries: [UsageEntry]) -> [UsageDayKey: DailyProviderUsage] {
        var byDay: [Int: [String: ModelBucket]] = [:]
        var approximateDays = Set<Int>()
        for entry in entries {
            let day = dayKey(for: entry.timestamp)
            byDay[day, default: [:]][entry.model, default: ModelBucket()].add(entry, cost: entry.costUSD)
            if !entry.timeIsExact { approximateDays.insert(day) }
        }
        var result: [UsageDayKey: DailyProviderUsage] = [:]
        for (day, models) in byDay {
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
            .filter { $0.totalVolume > 0 || $0.requestCount > 0 }
            .sorted { $0.totalVolume > $1.totalVolume }
            guard !rows.isEmpty else { continue }
            result[UsageDayKey(epoch: day)] = DailyProviderUsage(
                providerID: "cursor",
                models: rows,
                volumeUnit: .estimatedTokens,
                fidelity: approximateDays.contains(day) ? .sessionApproximate : .exact
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

        mutating func add(_ entry: UsageEntry, cost entryCost: Double) {
            input += entry.uncachedInput
            output += entry.output
            cacheRead += entry.cacheRead
            total += entry.totalTokens
            requests += entry.requests
            cost += entryCost
        }
    }

    /// Time-ordered contexts to (growth, previous context); a shrinking context counts as fully uncached.
    static func splitContexts(_ contexts: [Int]) -> [(uncached: Int, cacheRead: Int)] {
        var previous = 0
        return contexts.map { raw in
            let context = max(0, raw)
            defer { previous = context }
            guard previous > 0, context >= previous else { return (context, 0) }
            return (context - previous, previous)
        }
    }

    // MARK: - Sources

    private static func defaultSources() -> Sources {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tracking = home.appendingPathComponent(".cursor/ai-tracking/ai-code-tracking.db")
        return Sources(
            ideDatabases: ideDatabaseURLs(home: home),
            cliStores: cliStoreURLs(chatsRoot: home.appendingPathComponent(".cursor/chats")),
            aiTracking: FileManager.default.fileExists(atPath: tracking.path) ? tracking : nil
        )
    }

    private static func ideDatabaseURLs(home: URL) -> [URL] {
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
                urls.append(kid.appendingPathComponent("state.vscdb"))
            }
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func cliStoreURLs(chatsRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard let hashes = try? fm.contentsOfDirectory(
            at: chatsRoot.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for hash in hashes {
            guard let agents = try? fm.contentsOfDirectory(at: hash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for agent in agents {
                let store = agent.appendingPathComponent("store.db")
                if fm.fileExists(atPath: store.path) { urls.append(store) }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func cacheKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// File attributes rather than URL resource values, which a reused URL can serve from a stale cache.
    private static func stamp(_ url: URL) -> FileStamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(
            mtime: attributes?[.modificationDate] as? Date ?? .distantPast,
            size: (attributes?[.size] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func cachedEntries(
        key: String,
        stamps: [FileStamp],
        load: () -> [UsageEntry]?
    ) -> [UsageEntry]? {
        cacheLock.lock()
        if let cached = entryCache[key], cached.stamp == stamps {
            cacheLock.unlock()
            return cached.entries
        }
        cacheLock.unlock()
        guard let entries = load() else { return nil }
        cacheLock.lock()
        entryCache[key] = (stamps, entries)
        cacheLock.unlock()
        return entries
    }

    private static func cachedCLIParse(key: String, stamps: [FileStamp], load: () -> CLIStoreParse?) -> CLIStoreParse? {
        cacheLock.lock()
        if let cached = cliParseCache[key], cached.stamp == stamps {
            cacheLock.unlock()
            return cached.parse
        }
        cliStoreLoads += 1
        cacheLock.unlock()
        guard let parse = load() else { return nil }
        cacheLock.lock()
        cliParseCache[key] = (stamps, parse)
        cacheLock.unlock()
        return parse
    }

    private static func cachedAITracking(_ url: URL) -> AITracking? {
        let key = cacheKey(url)
        let stamps = [stamp(url), stamp(URL(fileURLWithPath: url.path + "-wal"))]
        cacheLock.lock()
        if let cached = aiTrackingCache, cached.key == key, cached.stamp == stamps {
            cacheLock.unlock()
            return cached.tracking
        }
        cacheLock.unlock()
        guard let tracking = loadAITracking(at: url) else { return nil }
        cacheLock.lock()
        aiTrackingCache = (key, stamps, tracking)
        cacheLock.unlock()
        return tracking
    }

    // MARK: - SQLite helpers

    /// Opens a private copy (database plus WAL) so a live writer is never touched and un-checkpointed rows are seen.
    private static func withDatabaseCopy<T>(of url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("viberouter-cursor-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            return nil
        }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        guard (try? fm.copyItem(at: url, to: copy)) != nil else { return nil }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if fm.fileExists(atPath: wal.path) {
            try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        return body(db)
    }

    private static func withReadOnlyDatabase<T>(at url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        return body(db)
    }

    /// False when the statement cannot be prepared or fails mid-way.
    private static func query(_ db: OpaquePointer, _ sql: String, bind: String? = nil, row: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        if let bind {
            sqlite3_bind_text(stmt, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                row(stmt)
            } else {
                return rc == SQLITE_DONE
            }
        }
    }

    private static func columnData(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        let bytes = sqlite3_column_bytes(stmt, column)
        guard bytes > 0, let blob = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: blob, count: Int(bytes))
    }

    private static func columnText(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cstr)
    }

    // MARK: - Cursor Agent CLI (~/.cursor/chats)

    static func loadAITracking(at url: URL) -> AITracking? {
        withDatabaseCopy(of: url) { db in
            var tracking = AITracking()
            let requestsOK = query(db, "SELECT requestId, MIN(timestamp), MAX(model) FROM ai_code_hashes WHERE requestId IS NOT NULL AND timestamp IS NOT NULL GROUP BY requestId;") { stmt in
                guard let id = columnText(stmt, 0), !id.isEmpty else { return }
                let ms = sqlite3_column_int64(stmt, 1)
                guard ms > 0 else { return }
                tracking.byRequest[id] = AITrackingRecord(
                    timestamp: dateFromEpoch(Double(ms)),
                    model: columnText(stmt, 2)
                )
            }
            _ = query(db, "SELECT conversationId, timestamp FROM ai_code_hashes WHERE conversationId IS NOT NULL AND timestamp > 0 GROUP BY conversationId, timestamp ORDER BY conversationId, timestamp;") { stmt in
                guard let id = columnText(stmt, 0), !id.isEmpty else { return }
                tracking.byConversation[id, default: []].append(dateFromEpoch(Double(sqlite3_column_int64(stmt, 1))))
            }
            return requestsOK ? tracking : nil
        }
    }

    static func parseCLIStore(storeURL: URL) -> CLIStoreParse? {
        let mtime = [stamp(storeURL).mtime, stamp(URL(fileURLWithPath: storeURL.path + "-wal")).mtime].max() ?? .distantPast
        return withDatabaseCopy(of: storeURL) { db -> CLIStoreParse? in
            var meta: [String: Any] = [:]
            let metaOK = query(db, "SELECT value FROM meta;") { stmt in
                guard let text = columnText(stmt, 0), let json = decodeMeta(text) else { return }
                meta.merge(json) { current, _ in current }
            }
            var snapshots: [CLISnapshot] = []
            let blobsOK = query(db, "SELECT data FROM blobs;") { stmt in
                if let data = columnData(stmt, 0), let snap = cliSnapshot(fromBlob: data) { snapshots.append(snap) }
            }
            guard metaOK, blobsOK else { return nil }
            return CLIStoreParse(
                snapshots: snapshots,
                createdAt: parseCursorDate(meta["createdAt"]),
                lastActivity: mtime,
                lastUsedModel: meta["lastUsedModel"] as? String
            )
        }
    }

    private static func decodeMeta(_ text: String) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return json
        }
        guard text.count % 2 == 0, !text.isEmpty else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    /// Root blob: field 5 = context meter (5.1 used, 5.2 window), field 4 = pending assistant message JSON.
    static func cliSnapshot(fromBlob data: Data) -> CLISnapshot? {
        guard let first = data.first, first != UInt8(ascii: "{"), first != UInt8(ascii: "[") else { return nil }
        guard let fields = ProtoReader.fields(of: data),
              let meterBytes = fields.first(where: { $0.number == 5 })?.bytes,
              let meter = ProtoReader.fields(of: meterBytes),
              let used = meter.first(where: { $0.number == 1 })?.varint,
              used > 0, used < UInt64(Int32.max),
              fields.contains(where: { $0.number == 26 && $0.varint != nil })
        else { return nil }
        var snapshot = CLISnapshot(
            contextTokens: Int(used),
            window: meter.first(where: { $0.number == 2 })?.varint.map { Int(clamping: $0) },
            pendingStartedAt: nil,
            modelName: nil,
            toolCallIDs: [],
            outputTokens: 0
        )
        if let pending = fields.first(where: { $0.number == 4 })?.bytes,
           let json = (try? JSONSerialization.jsonObject(with: pending)) as? [String: Any]
        {
            applyPendingMessage(json, to: &snapshot)
        }
        return snapshot
    }

    private static func applyPendingMessage(_ json: [String: Any], to snapshot: inout CLISnapshot) {
        let cursor = (json["providerOptions"] as? [String: Any])?["cursor"] as? [String: Any]
        if let ms = cursor?["pendingToolCallStartedAtMs"], let date = parseCursorDate(ms) {
            snapshot.pendingStartedAt = date
        }
        var toolIDs = Set((cursor?["pendingToolExecutionContracts"] as? [String: Any])?.keys.map { $0 } ?? [])
        var chars = 0
        if let parts = json["content"] as? [[String: Any]] {
            for part in parts {
                let partCursor = (part["providerOptions"] as? [String: Any])?["cursor"] as? [String: Any]
                if let name = partCursor?["modelName"] as? String, !name.isEmpty {
                    snapshot.modelName = name
                }
                if let id = part["toolCallId"] as? String, !id.isEmpty {
                    toolIDs.insert(id)
                }
                if let text = part["text"] as? String { chars += text.count }
                if let args = part["args"] {
                    if let text = args as? String {
                        chars += text.count
                    } else if JSONSerialization.isValidJSONObject(args),
                              let data = try? JSONSerialization.data(withJSONObject: args) {
                        chars += data.count
                    }
                }
            }
        } else if let text = json["content"] as? String {
            chars += text.count
        }
        snapshot.toolCallIDs = toolIDs.sorted()
        snapshot.outputTokens = chars / 4
    }

    /// One request per distinct context; time from ai-code-tracking, tool-call start, dated neighbour, conversation activity, then createdAt…mtime.
    static func cliEntries(
        snapshots: [CLISnapshot],
        createdAt: Date?,
        lastActivity: Date,
        lastUsedModel: String?,
        aiTracking: [String: AITrackingRecord],
        conversationTimes: [Date] = []
    ) -> [UsageEntry] {
        var byContext: [Int: CLISnapshot] = [:]
        for snap in snapshots {
            guard var existing = byContext[snap.contextTokens] else {
                byContext[snap.contextTokens] = snap
                continue
            }
            existing.window = existing.window ?? snap.window
            existing.pendingStartedAt = existing.pendingStartedAt ?? snap.pendingStartedAt
            existing.modelName = existing.modelName ?? snap.modelName
            existing.toolCallIDs = Array(Set(existing.toolCallIDs + snap.toolCallIDs)).sorted()
            existing.outputTokens = max(existing.outputTokens, snap.outputTokens)
            byContext[snap.contextTokens] = existing
        }
        let distinct = byContext.values.sorted { $0.contextTokens < $1.contextTokens }
        guard !distinct.isEmpty else { return [] }

        var windowModels: [Int: [String: Int]] = [:]
        for snap in distinct {
            if let window = snap.window, let name = snap.modelName {
                windowModels[window, default: [:]][name, default: 0] += 1
            }
        }

        struct Row {
            var snap: CLISnapshot
            var time: Date?
            var exact: Bool
            var model: String
        }
        var rows: [Row] = distinct.map { snap in
            let tracked = snap.toolCallIDs.compactMap { aiTracking[$0] }
            let trackedTime = tracked.map(\.timestamp).min()
            let rawModel = snap.modelName
                ?? snap.window.flatMap { window in
                    windowModels[window]?.max { lhs, rhs in
                        lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
                    }?.key
                }
                ?? tracked.compactMap(\.model).first(where: { !isAutoModel($0) })
                ?? lastUsedModel
            let time = trackedTime ?? snap.pendingStartedAt
            return Row(snap: snap, time: time, exact: time != nil, model: normalizedCLIModel(rawModel))
        }

        let start = createdAt ?? lastActivity
        let end = max(start, lastActivity)
        var unanchored: [Int] = []
        for index in rows.indices where rows[index].time == nil {
            let earlier = rows[..<index].last(where: { $0.time != nil && $0.exact })?.time
            let later = rows[(index + 1)...].first(where: { $0.time != nil && $0.exact })?.time
            if let time = earlier ?? later {
                rows[index].time = time
            } else {
                unanchored.append(index)
            }
        }
        let activity = conversationTimes.sorted()
        for (rank, index) in unanchored.enumerated() {
            let fraction = (Double(rank) + 0.5) / Double(unanchored.count)
            if !activity.isEmpty {
                rows[index].time = activity[min(activity.count - 1, Int(fraction * Double(activity.count)))]
            } else {
                let spread = Double(rank + 1) / Double(unanchored.count + 1)
                rows[index].time = start.addingTimeInterval(end.timeIntervalSince(start) * spread)
            }
        }

        let ordered = rows.sorted { lhs, rhs in
            let lt = lhs.time ?? start
            let rt = rhs.time ?? start
            return lt == rt ? lhs.snap.contextTokens < rhs.snap.contextTokens : lt < rt
        }
        let split = splitContexts(ordered.map(\.snap.contextTokens))
        return zip(ordered, split).map { row, part in
            UsageEntry(
                timestamp: row.time ?? start,
                model: row.model,
                uncachedInput: part.uncached,
                cacheRead: part.cacheRead,
                output: row.snap.outputTokens,
                requests: 1,
                timeIsExact: row.exact
            )
        }
    }

    private static func isAutoModel(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || lower == "default" || lower == "auto"
    }

    static func normalizedCLIModel(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !isAutoModel(name) else {
            return "cursor-auto"
        }
        if name.lowercased().hasPrefix("cursor-"), name.lowercased() != "cursor-auto" {
            name = String(name.dropFirst("cursor-".count))
        }
        return TokenPricingCatalog.normalizeModelID(name) ?? name
    }

    // MARK: - Cursor IDE (state.vscdb)

    private static func ideEntries(databaseURL url: URL) -> [UsageEntry]? {
        let mtime = stamp(url).mtime
        return withReadOnlyDatabase(at: url) { db -> [UsageEntry]? in
            var composers: [(id: String, json: [String: Any])] = []
            let ok = query(db, "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%';") { stmt in
                guard let key = columnText(stmt, 0) else { return }
                let composerID = String(key.dropFirst("composerData:".count))
                guard composerID != "empty-state-draft", !composerID.isEmpty else { return }
                guard let json = blobJSON(stmt, column: 1) else { return }
                composers.append((composerID, json))
            }
            guard ok else { return nil }
            var entries: [UsageEntry] = []
            for composer in composers {
                let prefix = "bubbleId:\(composer.id):"
                var bubbles: [String: [String: Any]] = [:]
                let bubblesOK = query(db, "SELECT key, value FROM cursorDiskKV WHERE key LIKE ?;", bind: prefix + "%") { stmt in
                    guard let key = columnText(stmt, 0), let json = blobJSON(stmt, column: 1) else { return }
                    bubbles[String(key.dropFirst(prefix.count))] = json
                }
                guard bubblesOK else { return nil }
                entries.append(contentsOf: ideEntries(composer: composer.json, bubbles: bubbles, fallbackDate: mtime))
            }
            return entries
        }
    }

    /// Per-bubble date and model; undated bubbles inherit a dated neighbour, the composer date, then `fallbackDate`.
    static func ideEntries(
        composer json: [String: Any],
        bubbles: [String: [String: Any]],
        fallbackDate: Date
    ) -> [UsageEntry] {
        let composerModel = normalizedModel(json["modelConfig"] as? [String: Any])
        let composerDate = parseCursorDate(json["lastUpdatedAt"]) ?? parseCursorDate(json["createdAt"]) ?? fallbackDate
        let ordered = orderedBubbles(composer: json, bubbles: bubbles)

        let ownDates = ordered.map { parseCursorDate($0["createdAt"] ?? $0["timestamp"]) }
        var dates: [Date] = []
        var exact: [Bool] = []
        for index in ordered.indices {
            if let own = ownDates[index] {
                dates.append(own)
                exact.append(true)
            } else if let earlier = ownDates[..<index].last(where: { $0 != nil }) ?? nil {
                dates.append(earlier)
                exact.append(false)
            } else if let later = ownDates[(index + 1)...].first(where: { $0 != nil }) ?? nil {
                dates.append(later)
                exact.append(false)
            } else {
                dates.append(composerDate)
                exact.append(false)
            }
        }

        let hasExplicitTokens = ordered.contains { bubble in
            let tokens = bubble["tokenCount"] as? [String: Any]
            return intValue(tokens?["inputTokens"]) > 0 || intValue(tokens?["outputTokens"]) > 0
        }

        if hasExplicitTokens {
            var entries: [UsageEntry] = []
            for (index, bubble) in ordered.enumerated() {
                let tokens = bubble["tokenCount"] as? [String: Any]
                let input = intValue(tokens?["inputTokens"])
                let output = intValue(tokens?["outputTokens"])
                guard input > 0 || output > 0 else { continue }
                entries.append(UsageEntry(
                    timestamp: dates[index],
                    model: bubbleModel(bubble) ?? composerModel,
                    uncachedInput: input,
                    cacheRead: 0,
                    output: output,
                    requests: (bubble["type"] as? Int) == 2 ? 1 : 0,
                    timeIsExact: exact[index]
                ))
            }
            if !entries.isEmpty, !entries.contains(where: { $0.requests > 0 }) {
                entries[entries.count - 1].requests = 1
            }
            return entries
        }

        let assistantIndices = ordered.indices.filter { (ordered[$0]["type"] as? Int) == 2 }
        let meter = contextMeterTokens(json)
        if assistantIndices.isEmpty {
            guard meter > 0 else { return [] }
            return [UsageEntry(
                timestamp: composerDate,
                model: composerModel,
                uncachedInput: meter,
                cacheRead: 0,
                output: 0,
                requests: 1,
                timeIsExact: false
            )]
        }

        let count = assistantIndices.count
        let contexts = assistantIndices.enumerated().map { position, index -> Int in
            let own = contextMeterTokens(ordered[index])
            if own > 0 { return own }
            return meter > 0 ? Int((Double(meter) * Double(position + 1) / Double(count)).rounded()) : 0
        }
        let split = splitContexts(contexts)
        return zip(assistantIndices, split).map { index, part in
            let bubble = ordered[index]
            let chars = bubbleText(bubble).count
            return UsageEntry(
                timestamp: dates[index],
                model: bubbleModel(bubble) ?? composerModel,
                uncachedInput: part.uncached,
                cacheRead: part.cacheRead,
                output: chars > 0 ? max(1, chars / 4) : 0,
                requests: 1,
                timeIsExact: exact[index]
            )
        }
    }

    private static func orderedBubbles(
        composer json: [String: Any],
        bubbles: [String: [String: Any]]
    ) -> [[String: Any]] {
        var ordered: [[String: Any]] = []
        var used = Set<String>()
        for header in json["fullConversationHeadersOnly"] as? [[String: Any]] ?? [] {
            guard let id = header["bubbleId"] as? String, let bubble = bubbles[id], used.insert(id).inserted else { continue }
            ordered.append(bubble)
        }
        let rest = bubbles.filter { !used.contains($0.key) }.sorted { lhs, rhs in
            let ld = parseCursorDate(lhs.value["createdAt"] ?? lhs.value["timestamp"]) ?? .distantFuture
            let rd = parseCursorDate(rhs.value["createdAt"] ?? rhs.value["timestamp"]) ?? .distantFuture
            return ld == rd ? lhs.key < rhs.key : ld < rd
        }
        ordered.append(contentsOf: rest.map(\.value))
        return ordered
    }

    private static func bubbleModel(_ bubble: [String: Any]) -> String? {
        let raw = ((bubble["modelInfo"] as? [String: Any])?["modelName"] as? String)
            ?? (bubble["modelName"] as? String)
            ?? (bubble["model"] as? String)
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return normalizedModel(["modelName": raw])
    }

    static func contextMeterTokens(_ json: [String: Any]) -> Int {
        if let breakdown = json["promptTokenBreakdown"] as? [String: Any] {
            let total = intValue(breakdown["totalUsedTokens"])
            if total > 0 { return total }
        }
        if let status = json["contextWindowStatusAtCreation"] as? [String: Any] {
            let used = intValue(status["tokensUsed"])
            if used > 0 { return used }
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
            return value > 0 ? dateFromEpoch(value) : nil
        }
        if let value = raw as? Int {
            return value > 0 ? dateFromEpoch(Double(value)) : nil
        }
        if let value = raw as? NSNumber {
            return value.doubleValue > 0 ? dateFromEpoch(value.doubleValue) : nil
        }
        if let value = raw as? String {
            if let num = Double(value) { return num > 0 ? dateFromEpoch(num) : nil }
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
        if let text = columnText(stmt, column),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return json
        }
        guard let data = columnData(stmt, column) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func intValue(_ raw: Any?) -> Int {
        JSONNumber.int(raw)
    }

    private static func dayKey(for date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }
}

/// Minimal protobuf wire-format reader for Cursor CLI root blobs.
enum ProtoReader {
    struct Field {
        var number: Int
        var varint: UInt64?
        var bytes: Data?
    }

    static func fields(of data: Data) -> [Field]? {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []
        while index < bytes.count {
            guard let key = varint(bytes, &index) else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let value = varint(bytes, &index) else { return nil }
                fields.append(Field(number: number, varint: value, bytes: nil))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
                fields.append(Field(number: number, varint: nil, bytes: nil))
            case 2:
                guard let length = varint(bytes, &index), length <= UInt64(bytes.count - index) else { return nil }
                let end = index + Int(length)
                fields.append(Field(number: number, varint: nil, bytes: Data(bytes[index..<end])))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
                fields.append(Field(number: number, varint: nil, bytes: nil))
            default:
                return nil
            }
        }
        return fields
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
