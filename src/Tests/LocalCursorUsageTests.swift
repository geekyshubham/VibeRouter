import Foundation
import SQLite3
import Testing
@testable import CLIProxyMenuBar

@Suite(.serialized)
final class LocalCursorUsageTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture helpers

    private func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func dayKey(_ date: Date) -> UsageDayKey {
        UsageDayKey(epoch: Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970))
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func pbVarint(_ field: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(field << 3)) + varint(value)
    }

    private func pbBytes(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    private func rootBlob(
        used: Int,
        window: Int,
        createdAtMs: Int64 = 1_780_000_000_000,
        pending: [String: Any]? = nil
    ) throws -> Data {
        var bytes = pbBytes(1, [UInt8](repeating: 7, count: 32))
        if let pending {
            bytes += pbBytes(4, [UInt8](try JSONSerialization.data(withJSONObject: pending)))
        }
        bytes += pbBytes(5, pbVarint(1, UInt64(used)) + pbVarint(2, UInt64(window)))
        bytes += pbBytes(22, Array("cli".utf8))
        bytes += pbVarint(26, UInt64(createdAtMs))
        return Data(bytes)
    }

    private func pendingMessage(model: String?, startedAt: Date?, toolID: String? = nil, text: String = "") -> [String: Any] {
        var cursor: [String: Any] = [:]
        if let startedAt { cursor["pendingToolCallStartedAtMs"] = Int64(startedAt.timeIntervalSince1970 * 1000) }
        var reasoning: [String: Any] = ["type": "redacted-reasoning", "data": "opaque"]
        if let model { reasoning["providerOptions"] = ["cursor": ["modelName": model]] }
        var content: [[String: Any]] = [reasoning]
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        if let toolID {
            content.append(["type": "tool-call", "toolCallId": toolID, "toolName": "Read", "args": ["path": "/tmp/x"]])
        }
        return ["id": "1", "role": "assistant", "content": content, "providerOptions": ["cursor": cursor]]
    }

    private func snapshot(
        _ used: Int,
        window: Int = 200_000,
        at date: Date? = nil,
        model: String? = nil,
        tools: [String] = [],
        output: Int = 0
    ) -> LocalCursorUsage.CLISnapshot {
        LocalCursorUsage.CLISnapshot(
            contextTokens: used,
            window: window,
            pendingStartedAt: date,
            modelName: model,
            toolCallIDs: tools,
            outputTokens: output
        )
    }

    private func openDB(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "sqlite", code: 1)
        }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func insert(_ db: OpaquePointer, _ sql: String, _ values: [Any]) {
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
            case let int as Int64:
                sqlite3_bind_int64(stmt, index, int)
            case let text as String:
                sqlite3_bind_text(stmt, index, text, -1, transient)
            default:
                sqlite3_bind_null(stmt, index)
            }
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    private func hexJSON(_ object: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: object).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Context split

    @Test func testSplitContextsTreatsGrowthAsUncachedAndPreviousAsCacheRead() {
        let split = LocalCursorUsage.splitContexts([100, 150, 80, 120])
        #expect(split.map(\.uncached) == [100, 50, 80, 40])
        #expect(split.map(\.cacheRead) == [0, 100, 0, 80])
    }

    // MARK: - CLI root blobs

    @Test func testCLISnapshotDecodesMeterModelTimeAndTools() throws {
        let started = localDate(2026, 9, 3, 10)
        let blob = try rootBlob(
            used: 42_000,
            window: 256_000,
            pending: pendingMessage(model: "cursor-grok-4.6-high-fast", startedAt: started, toolID: "tool_abc", text: String(repeating: "x", count: 400))
        )
        let snap = try #require(LocalCursorUsage.cliSnapshot(fromBlob: blob))
        #expect(snap.contextTokens == 42_000)
        #expect(snap.window == 256_000)
        #expect(snap.modelName == "cursor-grok-4.6-high-fast")
        #expect(snap.toolCallIDs == ["tool_abc"])
        #expect(abs((snap.pendingStartedAt?.timeIntervalSince1970 ?? 0) - (started.timeIntervalSince1970)) <= 0.01)
        #expect(snap.outputTokens >= 100)
    }

    @Test func testCLISnapshotRejectsMessageJSONAndNonRootProtobuf() throws {
        let message = try JSONSerialization.data(withJSONObject: ["role": "user", "content": "hi"])
        #expect(LocalCursorUsage.cliSnapshot(fromBlob: message) == nil)
        let noMeter = Data(pbBytes(1, [1, 2, 3]) + pbVarint(26, 5))
        #expect(LocalCursorUsage.cliSnapshot(fromBlob: noMeter) == nil)
        let noRootMarker = Data(pbBytes(5, pbVarint(1, 900) + pbVarint(2, 200_000)))
        #expect(LocalCursorUsage.cliSnapshot(fromBlob: noRootMarker) == nil)
    }

    @Test func testCLIEntriesDedupeSnapshotsAndPriceEachWithItsOwnModel() {
        let d1 = localDate(2026, 9, 2, 18)
        let d2 = localDate(2026, 9, 3, 9)
        let snaps = [
            snapshot(20_000, at: d1, model: "composer-2.5-fast"),
            snapshot(20_000),
            snapshot(30_000, at: d1.addingTimeInterval(60), model: "composer-2.5-fast"),
            snapshot(50_000, window: 256_000, at: d2, model: "cursor-grok-4.6-high-fast"),
        ]
        let entries = LocalCursorUsage.cliEntries(
            snapshots: snaps,
            createdAt: localDate(2026, 9, 1),
            lastActivity: d2,
            lastUsedModel: "grok-4.6",
            aiTracking: [:]
        )
        #expect(entries.count == 3)
        #expect(entries.map(\.model) == ["composer-2.5-fast", "composer-2.5-fast", "grok-4.6-high-fast"])
        #expect(entries.map(\.uncachedInput) == [20_000, 10_000, 20_000])
        #expect(entries.map(\.cacheRead) == [0, 20_000, 30_000])
        #expect(entries.reduce(0) { $0 + $1.uncachedInput + $1.cacheRead } == 100_000)
        #expect(entries.allSatisfy { $0.timeIsExact })
        #expect(dayKey(entries[2].timestamp) == dayKey(d2))
    }

    @Test func testCLIEntriesPreferAITrackingTimeAndNeverUseConversationCreation() {
        let created = localDate(2026, 9, 2, 8)
        let pending = localDate(2026, 9, 4, 1, 0)
        let tracked = localDate(2026, 9, 4, 0, 58)
        let entries = LocalCursorUsage.cliEntries(
            snapshots: [snapshot(10_000, at: pending, model: "composer-2.5", tools: ["tool_1"])],
            createdAt: created,
            lastActivity: pending,
            lastUsedModel: nil,
            aiTracking: ["tool_1": .init(timestamp: tracked, model: "composer-2.5")]
        )
        #expect(entries.first?.timestamp == tracked)
        #expect(dayKey(entries[0].timestamp) != dayKey(created))
    }

    @Test func testCLIEntriesFillUndatedSnapshotsFromNeighboursAndWindowModel() {
        let d1 = localDate(2026, 9, 3, 10)
        let d2 = localDate(2026, 9, 4, 10)
        let entries = LocalCursorUsage.cliEntries(
            snapshots: [
                snapshot(10_000, at: d1, model: "composer-2.5-fast"),
                snapshot(15_000),
                snapshot(40_000, window: 256_000, at: d2, model: "cursor-grok-4.6-high"),
                snapshot(45_000, window: 256_000),
            ],
            createdAt: localDate(2026, 9, 1),
            lastActivity: d2,
            lastUsedModel: "something-else",
            aiTracking: [:]
        )
        let byContext = Dictionary(uniqueKeysWithValues: entries.map { ($0.uncachedInput + $0.cacheRead, $0) })
        #expect(byContext[15_000]?.timestamp == d1)
        #expect(byContext[15_000]?.model == "composer-2.5-fast")
        #expect(byContext[15_000]?.timeIsExact == false)
        #expect(byContext[45_000]?.timestamp == d2)
        #expect(byContext[45_000]?.model == "grok-4.6-high")
    }

    @Test func testCLIEntriesWithoutAnyDateSpreadBetweenCreationAndLastWrite() {
        let created = localDate(2026, 9, 1, 12)
        let last = localDate(2026, 9, 3, 12)
        let entries = LocalCursorUsage.cliEntries(
            snapshots: [snapshot(1_000), snapshot(2_000), snapshot(3_000)],
            createdAt: created,
            lastActivity: last,
            lastUsedModel: "grok-4.6",
            aiTracking: [:]
        )
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.timestamp > created && $0.timestamp < last && !$0.timeIsExact })
        #expect(entries.allSatisfy { $0.model == "grok-4.6" })
        #expect(entries.map(\.uncachedInput) == [1_000, 1_000, 1_000])
    }

    @Test func testCLIEntriesAnchorUndatedSnapshotsOnTheConversationsTrackedActivity() {
        let created = localDate(2026, 8, 19, 9)
        let touched = localDate(2026, 9, 20, 9)
        let active = [localDate(2026, 8, 19, 10), localDate(2026, 8, 19, 11), localDate(2026, 8, 20, 13)]
        let entries = LocalCursorUsage.cliEntries(
            snapshots: [snapshot(1_000), snapshot(2_000), snapshot(3_000), snapshot(4_000)],
            createdAt: created,
            lastActivity: touched,
            lastUsedModel: "grok-4.6",
            aiTracking: [:],
            conversationTimes: active.reversed()
        )
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { active.contains($0.timestamp) && !$0.timeIsExact })
        #expect(entries.map { $0.uncachedInput + $0.cacheRead } == [1_000, 2_000, 3_000, 4_000], "context order is kept")
        #expect(Set(entries.map { dayKey($0.timestamp) }) == [dayKey(active[0]), dayKey(active[2])])
    }

    // MARK: - CLI store end-to-end

    @Test func testScanReadsLiveWALStoreThroughACopyAndLeavesOriginalUntouched() throws {
        let agentDir = tempDir.appendingPathComponent("chats/hash/agent-1", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        let store = agentDir.appendingPathComponent("store.db")
        let writer = try openDB(store)
        defer { sqlite3_close(writer) }
        exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        exec(writer, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")
        let createdMs = Int64(localDate(2026, 9, 1).timeIntervalSince1970 * 1000)
        insert(writer, "INSERT INTO meta VALUES (?, ?)", ["0", try hexJSON(["createdAt": createdMs, "lastUsedModel": "grok-4.6"])])
        let d1 = localDate(2026, 9, 2, 10)
        let d2 = localDate(2026, 9, 3, 10)
        let blobs: [Data] = [
            try rootBlob(used: 20_000, window: 200_000, createdAtMs: createdMs, pending: pendingMessage(model: "composer-2.5-fast", startedAt: d1)),
            try rootBlob(used: 20_000, window: 200_000, createdAtMs: createdMs),
            try rootBlob(used: 30_000, window: 200_000, createdAtMs: createdMs, pending: pendingMessage(model: "composer-2.5-fast", startedAt: d2, toolID: "tool_x")),
            try JSONSerialization.data(withJSONObject: ["role": "user", "content": "hello"]),
        ]
        for (i, blob) in blobs.enumerated() {
            insert(writer, "INSERT INTO blobs VALUES (?, ?)", ["b\(i)", blob])
        }
        let wal = URL(fileURLWithPath: store.path + "-wal")
        #expect((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0)

        let tracking = tempDir.appendingPathComponent("ai-code-tracking.db")
        let ai = try openDB(tracking)
        exec(ai, "CREATE TABLE ai_code_hashes (hash TEXT PRIMARY KEY, source TEXT NOT NULL, requestId TEXT, conversationId TEXT, timestamp INTEGER, model TEXT, createdAt INTEGER NOT NULL);")
        let trackedMs = Int64(localDate(2026, 9, 3, 9, 59).timeIntervalSince1970 * 1000)
        insert(ai, "INSERT INTO ai_code_hashes VALUES (?, 'cli', ?, 'agent-1', ?, 'composer-2.5', ?)", ["h1", "tool_x", trackedMs, trackedMs])
        sqlite3_close(ai)

        let before = try FileManager.default.attributesOfItem(atPath: store.path)
        let walBefore = try FileManager.default.attributesOfItem(atPath: wal.path)
        let stores = LocalCursorUsage.cliStoreURLs(chatsRoot: tempDir.appendingPathComponent("chats"))
        #expect(stores.map(\.lastPathComponent) == ["store.db"])
        let link = tempDir.appendingPathComponent("chats-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tempDir.appendingPathComponent("chats"))
        #expect(LocalCursorUsage.cliStoreURLs(chatsRoot: link).map(\.lastPathComponent) == ["store.db"])
        let result = LocalCursorUsage.scan(
            now: localDate(2026, 9, 10),
            historyDays: 30,
            sources: .init(ideDatabases: [], cliStores: stores, aiTracking: tracking)
        )
        #expect(result.complete)
        #expect(result.sources.keys.map { ($0 as NSString).lastPathComponent } == ["store.db"])
        #expect(result.oldestChatStore != nil)
        #expect(result.entries.count == 2)
        #expect(result.entries.map(\.uncachedInput) == [20_000, 10_000])
        #expect(result.entries.map(\.cacheRead) == [0, 20_000])
        #expect(abs((result.entries.last?.timestamp.timeIntervalSince1970 ?? 0) - (Double(trackedMs) / 1000)) <= 0.01)

        let after = try FileManager.default.attributesOfItem(atPath: store.path)
        let walAfter = try FileManager.default.attributesOfItem(atPath: wal.path)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(before[.size] as? Int == after[.size] as? Int)
        #expect(walBefore[.size] as? Int == walAfter[.size] as? Int)

        let daily = LocalCursorUsage.dailyUsage(from: result.entries)
        #expect(Set(daily.keys) == [dayKey(d1), dayKey(d2)])
        #expect(daily[dayKey(d2)]?.fidelity == .exact)
        #expect(daily[dayKey(d2)]?.volumeUnit == .estimatedTokens)

        let loads = LocalCursorUsage.cliStoreLoadCount
        let retracked = localDate(2026, 9, 3, 9, 30)
        let ai2 = try openDB(tracking)
        insert(ai2, "INSERT INTO ai_code_hashes VALUES (?, 'cli', ?, 'agent-1', ?, 'composer-2.5', ?)",
               ["h2", "tool_x", Int64(retracked.timeIntervalSince1970 * 1000), Int64(retracked.timeIntervalSince1970 * 1000)])
        sqlite3_close(ai2)
        let rescanned = LocalCursorUsage.scan(
            now: localDate(2026, 9, 10),
            historyDays: 30,
            sources: .init(ideDatabases: [], cliStores: stores, aiTracking: tracking)
        )
        #expect(LocalCursorUsage.cliStoreLoadCount == loads, "an ai-tracking write does not re-copy the chat stores")
        #expect(abs((rescanned.entries.last?.timestamp.timeIntervalSince1970 ?? 0) - retracked.timeIntervalSince1970) <= 0.01)
    }

    @Test func testScanFlagsUnreadableStoreAsIncompleteButEmptySourcesAsComplete() throws {
        let bogus = tempDir.appendingPathComponent("store.db")
        try Data("not a database".utf8).write(to: bogus)
        let failed = LocalCursorUsage.scan(
            now: localDate(2026, 9, 10),
            sources: .init(ideDatabases: [], cliStores: [bogus], aiTracking: nil)
        )
        #expect(!(failed.complete))
        #expect(failed.entries.isEmpty)

        let empty = LocalCursorUsage.scan(
            now: localDate(2026, 9, 10),
            sources: .init(ideDatabases: [], cliStores: [], aiTracking: nil)
        )
        #expect(empty.complete)
        #expect(empty.entries.isEmpty)
    }

    // MARK: - IDE composer

    @Test func testIDEBucketsEachBubbleOnItsOwnDayAndModel() {
        let d1 = localDate(2026, 9, 2, 22)
        let d2 = localDate(2026, 9, 4, 9)
        let composer: [String: Any] = [
            "modelConfig": ["modelName": "default"],
            "fullConversationHeadersOnly": [
                ["bubbleId": "u1", "type": 1], ["bubbleId": "a1", "type": 2],
                ["bubbleId": "u2", "type": 1], ["bubbleId": "a2", "type": 2],
            ],
        ]
        let iso = ISO8601DateFormatter()
        let bubbles: [String: [String: Any]] = [
            "a2": ["type": 2, "createdAt": iso.string(from: d2), "tokenCount": ["inputTokens": 900, "outputTokens": 90], "modelInfo": ["modelName": "claude-sonnet-4.6"]],
            "u1": ["type": 1, "createdAt": iso.string(from: d1)],
            "a1": ["type": 2, "createdAt": iso.string(from: d1), "tokenCount": ["inputTokens": 500, "outputTokens": 50]],
            "u2": ["type": 1, "createdAt": iso.string(from: d2)],
        ]
        let entries = LocalCursorUsage.ideEntries(composer: composer, bubbles: bubbles, fallbackDate: .distantPast)
        #expect(entries.count == 2)
        #expect(entries.map { dayKey($0.timestamp) } == [dayKey(d1), dayKey(d2)])
        #expect(entries.map(\.model) == ["cursor-auto", "claude-sonnet-4.6"])
        #expect(entries.map(\.uncachedInput) == [500, 900])
        #expect(entries.map(\.requests) == [1, 1])
    }

    @Test func testIDEEstimatesOneRequestPerAssistantBubbleWithInterpolatedMeter() {
        let composer: [String: Any] = [
            "modelConfig": ["modelName": "composer-2.5"],
            "promptTokenBreakdown": ["totalUsedTokens": 300],
            "fullConversationHeadersOnly": [
                ["bubbleId": "u1"], ["bubbleId": "a1"], ["bubbleId": "a2"], ["bubbleId": "u2"], ["bubbleId": "a3"],
            ],
        ]
        let bubbles: [String: [String: Any]] = [
            "u1": ["type": 1], "u2": ["type": 1],
            "a1": ["type": 2, "text": String(repeating: "a", count: 40)],
            "a2": ["type": 2], "a3": ["type": 2],
        ]
        let fallback = localDate(2026, 8, 20)
        let entries = LocalCursorUsage.ideEntries(composer: composer, bubbles: bubbles, fallbackDate: fallback)
        #expect(entries.count == 3)
        #expect(entries.map(\.uncachedInput) == [100, 100, 100])
        #expect(entries.map(\.cacheRead) == [0, 100, 200])
        #expect(entries.first?.output == 10)
        #expect(entries.allSatisfy { $0.timestamp == fallback && !$0.timeIsExact })
    }

    @Test func testIDEUndatedBubblesInheritNeighbourOrComposerDateNeverNow() {
        let composerDate = localDate(2026, 8, 25, 15)
        let dated = localDate(2026, 8, 26, 9)
        let composer: [String: Any] = [
            "createdAt": Int(composerDate.timeIntervalSince1970 * 1000),
            "promptTokenBreakdown": ["totalUsedTokens": 200],
            "fullConversationHeadersOnly": [["bubbleId": "a1"], ["bubbleId": "a2"]],
        ]
        let bubbles: [String: [String: Any]] = [
            "a1": ["type": 2, "createdAt": Int(dated.timeIntervalSince1970 * 1000)],
            "a2": ["type": 2],
        ]
        let entries = LocalCursorUsage.ideEntries(composer: composer, bubbles: bubbles, fallbackDate: .distantPast)
        #expect(entries.map(\.timestamp) == [dated, dated])
        #expect(entries.map(\.timeIsExact) == [true, false])

        let orphan = LocalCursorUsage.ideEntries(
            composer: ["createdAt": Int(composerDate.timeIntervalSince1970 * 1000), "promptTokenBreakdown": ["totalUsedTokens": 50]],
            bubbles: [:],
            fallbackDate: .distantPast
        )
        #expect(orphan.map(\.timestamp) == [composerDate])
    }

    @Test func testIDEDatabaseScanUsesHeaderOrderAndPerBubbleDays() throws {
        let url = tempDir.appendingPathComponent("state.vscdb")
        let db = try openDB(url)
        exec(db, "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        let d1 = localDate(2026, 9, 5, 23)
        let d2 = localDate(2026, 9, 6, 1)
        let composer: [String: Any] = [
            "modelConfig": ["modelName": "gpt-5.4"],
            "promptTokenBreakdown": ["totalUsedTokens": 1_000],
            "fullConversationHeadersOnly": [["bubbleId": "a1"], ["bubbleId": "a2"]],
        ]
        insert(db, "INSERT INTO cursorDiskKV VALUES (?, ?)", ["composerData:c1", String(data: try JSONSerialization.data(withJSONObject: composer), encoding: .utf8)!])
        let ms: (Date) -> Int64 = { Int64($0.timeIntervalSince1970 * 1000) }
        insert(db, "INSERT INTO cursorDiskKV VALUES (?, ?)", ["bubbleId:c1:a2", String(data: try JSONSerialization.data(withJSONObject: ["type": 2, "createdAt": ms(d2)]), encoding: .utf8)!])
        insert(db, "INSERT INTO cursorDiskKV VALUES (?, ?)", ["bubbleId:c1:a1", String(data: try JSONSerialization.data(withJSONObject: ["type": 2, "createdAt": ms(d1)]), encoding: .utf8)!])
        sqlite3_close(db)

        let result = LocalCursorUsage.scan(
            now: localDate(2026, 9, 10),
            sources: .init(ideDatabases: [url], cliStores: [], aiTracking: nil)
        )
        #expect(result.complete)
        #expect(result.entries.map { dayKey($0.timestamp) } == [dayKey(d1), dayKey(d2)])
        #expect(result.entries.map(\.uncachedInput) == [500, 500])
        #expect(result.entries.map(\.cacheRead) == [0, 500])
        let snapshot = try #require(LocalCursorUsage.costSnapshot(from: result.entries, now: localDate(2026, 9, 10)))
        #expect(snapshot.models.first?.requestCount == 2)
        #expect(snapshot.models.first?.cacheReadTokens == 500)
    }

    // MARK: - Aggregation

    @Test func testDailyUsageMarksDaysWithInferredTimesApproximate() {
        let day = localDate(2026, 9, 3)
        let entries = [
            LocalCursorUsage.UsageEntry(timestamp: day, model: "composer-2.5", uncachedInput: 10, cacheRead: 90, output: 5, requests: 1, timeIsExact: true),
            LocalCursorUsage.UsageEntry(timestamp: day.addingTimeInterval(60), model: "composer-2.5", uncachedInput: 20, cacheRead: 100, output: 5, requests: 1, timeIsExact: false),
        ]
        let daily = LocalCursorUsage.dailyUsage(from: entries)
        let row = daily[dayKey(day)]
        #expect(row?.fidelity == .sessionApproximate)
        #expect(row?.models.first?.cacheReadTokens == 190)
        #expect(row?.models.first?.inputTokens == 30)
        #expect(row?.models.first?.totalVolume == 230)
        #expect(row?.models.first?.requestCount == 2)
    }

    // MARK: - Billed spend

    @Test func testBilledSpendReadsPlanBreakdownAndOnDemandCents() {
        let json: [String: Any] = [
            "individualUsage": [
                "plan": ["used": 2000, "limit": 2000, "breakdown": ["included": 2000, "bonus": 850, "total": 2850]],
                "onDemand": ["enabled": true, "used": 125, "limit": 5000],
            ],
        ]
        let spend = CursorQuotaParser.billedSpend(from: json)
        #expect(abs((spend?.planUSD ?? 0) - (28.5)) <= 0.0001)
        #expect(abs((spend?.bonusUSD ?? 0) - (8.5)) <= 0.0001)
        #expect(abs((spend?.onDemandUSD ?? 0) - (1.25)) <= 0.0001)
        #expect(abs((spend?.totalUSD ?? 0) - (29.75)) <= 0.0001)
    }

    @Test func testBilledSpendIgnoresDisabledOnDemandAndMissingData() {
        let legacy: [String: Any] = [
            "planUsage": ["totalSpend": 450, "limit": 2000],
            "individualUsage": ["onDemand": ["enabled": false, "used": 999]],
        ]
        #expect(abs((CursorQuotaParser.billedSpend(from: legacy)?.totalUSD ?? 0) - (4.5)) <= 0.0001)
        #expect(CursorQuotaParser.billedSpend(from: ["membershipType": "pro"]) == nil)
    }

    // MARK: - Real data (opt-in)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBE_REAL_DATA"] == "1"))
    func testRealCursorCLIDataTotals() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tracking = home.appendingPathComponent(".cursor/ai-tracking/ai-code-tracking.db")
        let now = localDate(2026, 9, 28, 12)
        let result = LocalCursorUsage.scan(
            now: now,
            historyDays: 30,
            sources: .init(
                ideDatabases: [],
                cliStores: LocalCursorUsage.cliStoreURLs(chatsRoot: home.appendingPathComponent(".cursor/chats")),
                aiTracking: FileManager.default.fileExists(atPath: tracking.path) ? tracking : nil
            )
        )
        var byModel: [String: (uncached: Int, cache: Int, output: Int, requests: Int, cost: Double)] = [:]
        for entry in result.entries {
            var acc = byModel[entry.model] ?? (0, 0, 0, 0, 0)
            acc.uncached += entry.uncachedInput
            acc.cache += entry.cacheRead
            acc.output += entry.output
            acc.requests += entry.requests
            acc.cost += entry.costUSD
            byModel[entry.model] = acc
        }
        let prompt = result.entries.reduce(0) { $0 + $1.uncachedInput + $1.cacheRead }
        print("[cursor-real] complete=\(result.complete) requests=\(result.entries.count) promptTokens=\(prompt) exactTimes=\(result.entries.filter(\.timeIsExact).count)")
        for (model, v) in byModel.sorted(by: { $0.key < $1.key }) {
            print("[cursor-real] \(model) requests=\(v.requests) uncached=\(v.uncached) cacheRead=\(v.cache) output=\(v.output) cost=\(String(format: "%.2f", v.cost))")
        }
        for (day, usage) in LocalCursorUsage.dailyUsage(from: result.entries).sorted(by: { $0.key < $1.key }) {
            print("[cursor-real] \(day) volume=\(usage.totalVolume) requests=\(usage.requestCount) fidelity=\(usage.fidelity.rawValue)")
        }
        #expect(result.complete)
    }
}
