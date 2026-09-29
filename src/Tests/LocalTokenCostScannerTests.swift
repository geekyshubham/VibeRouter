import XCTest
@testable import CLIProxyMenuBar

final class LocalTokenCostScannerTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        RemotePricingCatalog.replaceRatesForTesting([:])
    }

    override func tearDownWithError() throws {
        RemotePricingCatalog.replaceRatesForTesting([:])
        LocalTokenCostScanner.invalidateFileCache()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func write(_ name: String, _ lines: [[String: Any]], trailingNewline: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try body.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func claudeLine(
        id: String,
        model: String = "claude-opus-5-5",
        ts: String = "2026-09-28T10:00:00.000Z",
        usage: [String: Any]
    ) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": ts,
            "requestId": "req_\(id)",
            "message": ["id": id, "model": model, "usage": usage],
        ]
    }

    private func codexTokenCount(ordinal: Int, cumulative: Int, last: [String: Any], ts: String = "2026-09-28T10:00:00.000Z") -> [String: Any] {
        [
            "timestamp": ts,
            "ordinal": ordinal,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["total_tokens": cumulative], "last_token_usage": last],
            ],
        ]
    }

    private func codexRecord(ordinal: Int, responseID: String, usage: [String: Any], ts: String = "2026-09-28T10:00:00.000Z") -> [String: Any] {
        [
            "timestamp": ts,
            "ordinal": ordinal,
            "type": "token_usage_record",
            "payload": ["response_id": responseID, "usage": usage],
        ]
    }

    private func turnContext(_ model: String, ordinal: Int = 0) -> [String: Any] {
        ["timestamp": "2026-09-28T09:59:00.000Z", "ordinal": ordinal, "type": "turn_context", "payload": ["model": model]]
    }

    private func scan(_ providerID: String) -> ProviderDailyScan {
        LocalTokenCostScanner.dailyScan(providerID: providerID, directories: [root], now: now, historyDays: 30)
    }

    private func rows(_ scan: ProviderDailyScan) -> [DailyModelUsage] {
        scan.days.values.flatMap(\.models)
    }

    private func row(_ scan: ProviderDailyScan, _ model: String) -> DailyModelUsage? {
        let matching = rows(scan).filter { $0.model == model }
        guard var first = matching.first else { return nil }
        for other in matching.dropFirst() { first.merge(other) }
        return first
    }

    // MARK: - Claude

    func testClaudeOneHourCacheWritesUseOneHourRate() throws {
        try write("p/a.jsonl", [claudeLine(id: "m1", usage: [
            "input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 5_000,
            "cache_creation_input_tokens": 3_000,
            "cache_creation": ["ephemeral_5m_input_tokens": 1_000, "ephemeral_1h_input_tokens": 2_000],
        ])])
        let usage = try XCTUnwrap(row(scan("claude"), "claude-opus-5-5"))
        let expected = TokenPricingCatalog.requestCostUSD(
            model: "claude-opus-5-5", uncachedInput: 10, cacheRead: 5_000, cacheWrite5m: 1_000, cacheWrite1h: 2_000, output: 100
        )
        let allFiveMinute = TokenPricingCatalog.estimateUSD(
            model: "claude-opus-5-5", inputTokens: 10, outputTokens: 100, cacheReadTokens: 5_000, cacheWriteTokens: 3_000
        )
        XCTAssertEqual(usage.estimatedCostUSD, expected, accuracy: 1e-12)
        XCTAssertGreaterThan(usage.estimatedCostUSD, allFiveMinute)
        XCTAssertEqual(usage.inputTokens, 10, "input must be uncached input only")
        XCTAssertEqual(usage.cacheWriteTokens, 3_000)
        XCTAssertEqual(usage.cacheReadTokens, 5_000)
        XCTAssertEqual(usage.totalVolume, 8_110)
    }

    func testClaudeWithoutBreakdownTreatsWritesAsFiveMinute() {
        let split = LocalTokenCostScanner.cacheWriteSplit(["cache_creation_input_tokens": 700])
        XCTAssertEqual(split.fiveMinute, 700)
        XCTAssertEqual(split.oneHour, 0)
        let mismatched = LocalTokenCostScanner.cacheWriteSplit([
            "cache_creation_input_tokens": 0,
            "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 339],
        ])
        XCTAssertEqual(mismatched.oneHour, 339)
        XCTAssertEqual(mismatched.fiveMinute, 0)
    }

    func testClaudeKiroProxyLinesAreNotAnthropicUsage() throws {
        try write("p/a.jsonl", [
            claudeLine(id: "msg_kiro", model: "kiro/claude-opus-5.5", usage: ["input_tokens": 28_715, "output_tokens": 600]),
            claudeLine(id: "msg_real", usage: ["input_tokens": 5, "output_tokens": 50]),
        ])
        let result = scan("claude")
        XCTAssertEqual(rows(result).map(\.model), ["claude-opus-5-5"])
        XCTAssertNil(row(result, "claude-opus-5.5"))

        let since = now.addingTimeInterval(-86_400 * 3)
        let entries = LocalTokenCostScanner.kiroProxyEntries(inClaudeDirectories: [root], since: since)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "claude-log:msg_kiro")
        XCTAssertEqual(entry.claudeMessageID, "msg_kiro")
        XCTAssertEqual(entry.model, "claude-opus-5.5")
        XCTAssertEqual(entry.tokenSource, .claudeLog)
        XCTAssertEqual(entry.inputTokens, 28_715)
        XCTAssertEqual(entry.outputTokens, 600)
        XCTAssertNil(entry.credits)

        let later = ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z")!
        XCTAssertTrue(LocalTokenCostScanner.kiroProxyEntries(inClaudeDirectories: [root], since: later).isEmpty)
    }

    func testClaudeFallbackIterationsArePricedPerModel() throws {
        try write("p/a.jsonl", [claudeLine(id: "m1", model: "claude-opus-4-8", usage: [
            "input_tokens": 2, "output_tokens": 2_058, "cache_read_input_tokens": 77_880, "cache_creation_input_tokens": 0,
            "cache_creation": ["ephemeral_1h_input_tokens": 339, "ephemeral_5m_input_tokens": 0],
            "iterations": [
                ["input_tokens": 2, "output_tokens": 343, "cache_read_input_tokens": 78_771, "cache_creation_input_tokens": 339,
                 "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 339],
                 "type": "message", "model": "claude-fable-5-1"],
                ["input_tokens": 2, "output_tokens": 2_058, "cache_read_input_tokens": 77_880, "cache_creation_input_tokens": 0,
                 "type": "fallback_message", "model": "claude-opus-4-8"],
            ],
        ])])
        let result = scan("claude")
        let fable = try XCTUnwrap(row(result, "claude-fable-5-1"))
        let opus = try XCTUnwrap(row(result, "claude-opus-4-8"))
        XCTAssertEqual(fable.outputTokens, 343)
        XCTAssertEqual(fable.cacheWriteTokens, 339)
        XCTAssertEqual(fable.requestCount, 0)
        XCTAssertEqual(opus.outputTokens, 2_058)
        XCTAssertEqual(opus.requestCount, 1)
        let expectedFable = TokenPricingCatalog.requestCostUSD(
            model: "claude-fable-5-1", uncachedInput: 2, cacheRead: 78_771, cacheWrite1h: 339, output: 343
        )
        XCTAssertEqual(fable.estimatedCostUSD, expectedFable, accuracy: 1e-12)
    }

    func testClaudeCrossFileKeepsMostCompleteCopyRegardlessOfOrder() throws {
        let partial = claudeLine(id: "m1", usage: ["input_tokens": 5, "output_tokens": 10])
        let full = claudeLine(id: "m1", usage: ["input_tokens": 5, "output_tokens": 900])
        try write("a/first.jsonl", [partial])
        try write("b/second.jsonl", [full])
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.outputTokens, 900)
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.requestCount, 1)

        try write("a/first.jsonl", [full])
        try write("b/second.jsonl", [partial])
        LocalTokenCostScanner.invalidateFileCache()
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.outputTokens, 900)
    }

    // MARK: - Codex

    func testCodexLongContextTierAppliesPerRequest() throws {
        let big: [String: Any] = ["input_tokens": 300_000, "cached_input_tokens": 200_000, "output_tokens": 1_000, "total_tokens": 301_000]
        let small: [String: Any] = ["input_tokens": 100_000, "cached_input_tokens": 50_000, "output_tokens": 1_000, "total_tokens": 101_000]
        try write("s/rollout-a.jsonl", [
            turnContext("gpt-5.6-sol"),
            codexTokenCount(ordinal: 1, cumulative: 301_000, last: big),
            codexTokenCount(ordinal: 2, cumulative: 402_000, last: small),
        ])
        let usage = try XCTUnwrap(row(scan("codex"), "gpt-5.6-sol"))
        let tiered = TokenPricingCatalog.requestCostUSD(
            model: "gpt-5.6-sol", uncachedInput: 100_000, cacheRead: 200_000, output: 1_000, promptTokens: 300_000
        )
        let base = TokenPricingCatalog.requestCostUSD(
            model: "gpt-5.6-sol", uncachedInput: 50_000, cacheRead: 50_000, output: 1_000, promptTokens: 100_000
        )
        let flatBig = TokenPricingCatalog.estimateUSD(model: "gpt-5.6-sol", inputTokens: 100_000, outputTokens: 1_000, cacheReadTokens: 200_000)
        XCTAssertGreaterThan(tiered, flatBig, "static GPT tier above 272k must apply")
        XCTAssertEqual(usage.estimatedCostUSD, tiered + base, accuracy: 1e-9)
        XCTAssertEqual(usage.inputTokens, 150_000, "Codex input is uncached input")
        XCTAssertEqual(usage.cacheReadTokens, 250_000)
        XCTAssertEqual(usage.requestCount, 2)
    }

    func testCodexCacheWritesAreSplitOutOfInput() throws {
        try write("s/rollout-a.jsonl", [
            turnContext("gpt-6-astra"),
            codexTokenCount(ordinal: 1, cumulative: 11_000, last: [
                "input_tokens": 10_000, "cached_input_tokens": 4_000, "cache_write_input_tokens": 3_000,
                "output_tokens": 1_000, "total_tokens": 11_000,
            ]),
        ])
        let usage = try XCTUnwrap(row(scan("codex"), "gpt-6-astra"))
        XCTAssertEqual(usage.inputTokens, 3_000)
        XCTAssertEqual(usage.cacheReadTokens, 4_000)
        XCTAssertEqual(usage.cacheWriteTokens, 3_000)
        XCTAssertEqual(usage.totalVolume, 11_000)
        let expected = TokenPricingCatalog.requestCostUSD(
            model: "gpt-6-astra", uncachedInput: 3_000, cacheRead: 4_000, cacheWrite5m: 3_000, output: 1_000, promptTokens: 10_000
        )
        XCTAssertEqual(usage.estimatedCostUSD, expected, accuracy: 1e-12)
    }

    func testCodexSubagentReplayIsSkipped() throws {
        let replayed: [String: Any] = ["input_tokens": 900_000, "output_tokens": 9_000, "total_tokens": 909_000]
        let own: [String: Any] = ["input_tokens": 1_000, "output_tokens": 100, "total_tokens": 1_100]
        try write("s/rollout-child.jsonl", [
            ["timestamp": "2026-09-28T10:00:00.000Z", "ordinal": 0, "type": "session_meta",
             "payload": ["subagent_history_start_ordinal": 10, "forked_from_id": "parent"]],
            ["timestamp": "2026-09-28T10:00:00.000Z", "ordinal": 1, "type": "session_meta", "payload": [:] as [String: Any]],
            turnContext("gpt-5.6-sol", ordinal: 2),
            codexTokenCount(ordinal: 5, cumulative: 909_000, last: replayed),
            codexRecord(ordinal: 6, responseID: "resp_parent", usage: replayed),
            turnContext("gpt-5.6-sol", ordinal: 11),
            codexTokenCount(ordinal: 12, cumulative: 1_100, last: own),
        ])
        let usage = try XCTUnwrap(row(scan("codex"), "gpt-5.6-sol"))
        XCTAssertEqual(usage.totalVolume, 1_100)
        XCTAssertEqual(usage.requestCount, 1)
    }

    private func forkMeta(id: String) -> [String: Any] {
        ["timestamp": "2026-09-28T10:00:00.000Z", "type": "session_meta",
         "payload": ["id": id, "forked_from_id": "01a0a000-0000-7000-8000-00000000aaaa", "timestamp": "2026-09-28T10:00:00.000Z"]]
    }

    private func taskStarted(_ turnID: String, ts: String) -> [String: Any] {
        ["timestamp": ts, "type": "event_msg", "payload": ["type": "task_started", "turn_id": turnID, "model_context_window": 1]]
    }

    func testCodexForkReplayIsSkippedUntilATurnNewerThanTheFork() throws {
        let replayed: [String: Any] = ["input_tokens": 900_000, "output_tokens": 9_000, "total_tokens": 909_000]
        let own: [String: Any] = ["input_tokens": 1_000, "output_tokens": 100, "total_tokens": 1_100]
        try write("s/rollout-fork.jsonl", [
            forkMeta(id: "01a0b000-0000-7000-8000-000000000001"),
            taskStarted("01a0a000-0000-7000-8000-000000000002", ts: "2026-09-28T10:00:00.002Z"),
            ["timestamp": "2026-09-28T10:00:00.002Z", "type": "turn_context",
             "payload": ["model": "gpt-5.6-sol", "turn_id": "01a0a000-0000-7000-8000-000000000002"]],
            codexTokenCount(ordinal: 0, cumulative: 909_000, last: replayed, ts: "2026-09-28T10:00:00.003Z"),
            codexRecord(ordinal: 0, responseID: "resp_parent", usage: replayed, ts: "2026-09-28T10:00:00.003Z"),
            taskStarted("01a0c000-0000-7000-8000-000000000003", ts: "2026-09-28T10:03:00.000Z"),
            codexTokenCount(ordinal: 0, cumulative: 909_000, last: replayed, ts: "2026-09-28T10:03:01.000Z"),
            codexTokenCount(ordinal: 0, cumulative: 910_100, last: own, ts: "2026-09-28T10:03:05.000Z"),
        ])
        let usage = try XCTUnwrap(row(scan("codex"), "gpt-5.6-sol"))
        XCTAssertEqual(usage.totalVolume, 1_100, "the parent's replayed history is not the fork's usage")
        XCTAssertEqual(usage.requestCount, 1)
    }

    func testCodexForkReplayEndsAfterTheBurstWithoutUUIDTurnIDs() throws {
        let replayed: [String: Any] = ["input_tokens": 50_000, "output_tokens": 500, "total_tokens": 50_500]
        let own: [String: Any] = ["input_tokens": 2_000, "output_tokens": 20, "total_tokens": 2_020]
        try write("s/rollout-fork-legacy.jsonl", [
            forkMeta(id: "fork-without-uuid"),
            turnContext("gpt-5.6-sol"),
            codexTokenCount(ordinal: 0, cumulative: 50_500, last: replayed, ts: "2026-09-28T10:00:00.004Z"),
            codexTokenCount(ordinal: 0, cumulative: 52_520, last: own, ts: "2026-09-28T10:04:00.000Z"),
        ])
        XCTAssertEqual(row(scan("codex"), "gpt-5.6-sol")?.totalVolume, 2_020)
    }

    func testCodexUUIDv7Milliseconds() {
        XCTAssertEqual(LocalTokenCostScanner.uuidV7Milliseconds("01a0b000-0000-7000-8000-000000000001"), 0x01a0b0000000)
        XCTAssertNil(LocalTokenCostScanner.uuidV7Milliseconds("01a0b000-0000-4000-8000-000000000001"), "v4 carries no time")
        XCTAssertNil(LocalTokenCostScanner.uuidV7Milliseconds("turn-1"))
    }

    func testCodexTokenCountsBeforeTheFirstRecordStillCount() throws {
        let early: [String: Any] = ["input_tokens": 3_000, "output_tokens": 30, "total_tokens": 3_030]
        let recorded: [String: Any] = ["input_tokens": 1_000, "output_tokens": 10, "total_tokens": 1_010]
        try write("s/rollout-resumed.jsonl", [
            turnContext("gpt-5.6-sol"),
            codexTokenCount(ordinal: 1, cumulative: 3_030, last: early),
            codexRecord(ordinal: 2, responseID: "resp_new", usage: recorded),
            codexTokenCount(ordinal: 3, cumulative: 4_040, last: recorded),
        ])
        let usage = try XCTUnwrap(row(scan("codex"), "gpt-5.6-sol"))
        XCTAssertEqual(usage.totalVolume, 3_030 + 1_010, "pre-record usage from an older CLI survives the upgrade")
        XCTAssertEqual(usage.requestCount, 2)
    }

    func testCodexUsageRecordsWinOverTokenCountAndDedupAcrossFiles() throws {
        let usage: [String: Any] = [
            "input_tokens": 40_471, "cached_input_tokens": 26_368, "cache_write_input_tokens": 0,
            "output_tokens": 790, "total_tokens": 41_261,
        ]
        let lines: [[String: Any]] = [
            turnContext("gpt-6-sol"),
            codexRecord(ordinal: 15, responseID: "resp_1", usage: usage),
            codexTokenCount(ordinal: 18, cumulative: 41_261, last: usage),
            codexRecord(ordinal: 34, responseID: "resp_2", usage: usage),
            codexTokenCount(ordinal: 36, cumulative: 82_522, last: usage),
        ]
        try write("s/rollout-a.jsonl", lines)
        try write("archived/rollout-a-copy.jsonl", lines)
        let result = try XCTUnwrap(row(scan("codex"), "gpt-6-sol"))
        XCTAssertEqual(result.requestCount, 2)
        XCTAssertEqual(result.totalVolume, 82_522)
        XCTAssertEqual(result.inputTokens, 2 * (40_471 - 26_368))
    }

    func testCodexDuplicateSnapshotStillSkipped() throws {
        let last: [String: Any] = ["input_tokens": 1_000, "output_tokens": 10, "total_tokens": 1_010]
        try write("s/rollout-a.jsonl", [
            turnContext("gpt-5.6-sol"),
            codexTokenCount(ordinal: 1, cumulative: 1_010, last: last),
            codexTokenCount(ordinal: 2, cumulative: 1_010, last: last),
        ])
        XCTAssertEqual(row(scan("codex"), "gpt-5.6-sol")?.requestCount, 1)
    }

    // MARK: - Gemini

    func testGeminiUsesStickyModelAndSentinelBeforeAnyModel() throws {
        let tokens: [String: Any] = ["input": 1_000, "output": 10, "cached": 0, "thoughts": 0, "total": 1_010]
        try write("g/chats/a.jsonl", [
            ["type": "gemini", "id": "0", "timestamp": "2026-09-28T09:00:00.000Z", "tokens": tokens],
            ["type": "gemini", "id": "1", "timestamp": "2026-09-28T10:00:00.000Z", "model": "gemini-3.5-flash", "tokens": tokens],
            ["type": "gemini", "id": "2", "timestamp": "2026-09-28T11:00:00.000Z", "tokens": tokens],
            ["type": "gemini", "id": "2", "timestamp": "2026-09-28T11:00:00.000Z", "tokens": tokens, "toolCalls": [] as [Any]],
        ])
        let result = scan("gemini")
        XCTAssertEqual(row(result, "gemini-3.5-flash")?.requestCount, 2)
        XCTAssertEqual(row(result, "gemini-unknown")?.requestCount, 1)
        XCTAssertEqual(row(result, "gemini-unknown")?.estimatedCostUSD, 0, "no generic Gemini rate is invented for an unknown model")
        XCTAssertGreaterThan(row(result, "gemini-3.5-flash")?.estimatedCostUSD ?? 0, 0)
        XCTAssertNil(row(result, "gemini"))
        let unknown = ModelTokenUsage(model: "gemini-unknown", inputTokens: 1_000, outputTokens: 10, cacheReadTokens: 0,
                                      totalTokens: 1_010, estimatedCostUSD: 0, requestCount: 1)
        XCTAssertEqual(AnalyticsDashboardView.rateLabel(for: unknown), "unpriced — model unknown")
    }

    func testPerDayCostIsIdenticalWhateverTheFileLayout() throws {
        let requests: [[String: Any]] = (0..<150).map { (i: Int) -> [String: Any] in
            let usage: [String: Any] = [
                "input_tokens": 7 + i * 13,
                "output_tokens": 3 + i * 7,
                "cache_read_input_tokens": 1_000 + i * 977,
                "cache_creation_input_tokens": (i % 5) * 311,
            ]
            return claudeLine(id: String(format: "m%03d", i), usage: usage)
        }
        func layout(_ files: Int, reversed: Bool) throws -> DailyProviderUsage? {
            try? FileManager.default.removeItem(at: root)
            LocalTokenCostScanner.invalidateFileCache()
            let ordered = reversed ? Array(requests.reversed()) : requests
            for file in 0..<files {
                let slice: [[String: Any]] = ordered.enumerated().filter { $0.offset % files == file }.map { $0.element }
                try write("p/f\(file).jsonl", slice)
            }
            return scan("claude").days.values.first
        }
        let a = try XCTUnwrap(try layout(3, reversed: false))
        let b = try XCTUnwrap(try layout(7, reversed: true))
        XCTAssertEqual(a.totalVolume, b.totalVolume)
        XCTAssertEqual(a.totalCostUSD.bitPattern, b.totalCostUSD.bitPattern, "cost sums follow request-key order, not dictionary order")
        XCTAssertEqual(a, b)
    }

    func testGeminiToolPromptTokensBilledAsInput() {
        let b = LocalTokenCostScanner.geminiTokenBreakdown(["input": 1_000, "cached": 400, "tool": 250, "output": 50, "thoughts": 20])
        XCTAssertEqual(b.nonCachedInput, 850)
        XCTAssertEqual(b.cacheRead, 400)
        XCTAssertEqual(b.billedOutput, 70)
        XCTAssertEqual(b.total, 1_320)
    }

    // MARK: - Streaming and caching

    func testFilesOverSixtyMegabytesAreStreamedNotSkipped() throws {
        let url = root.appendingPathComponent("p/big.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data((line(claudeLine(id: "first", usage: ["input_tokens": 1, "output_tokens": 1])) + "\n").utf8))
        let filler = Data(("{\"type\":\"progress\",\"text\":\"" + String(repeating: "x", count: 1_048_000) + "\"}\n").utf8)
        for _ in 0..<62 { try handle.write(contentsOf: filler) }
        let huge = Data(("{\"type\":\"progress\",\"text\":\"" + String(repeating: "y", count: 3_500_000) + "\"}\n").utf8)
        try handle.write(contentsOf: huge)
        try handle.write(contentsOf: Data((line(claudeLine(id: "last", usage: ["input_tokens": 1, "output_tokens": 1])) + "\n").utf8))
        try handle.close()
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 60_000_000)

        let result = scan("claude")
        XCTAssertEqual(row(result, "claude-opus-5-5")?.requestCount, 2)
        XCTAssertNotNil(result.coverage)
    }

    func testAppendedLinesResumeFromOffsetWithoutDoubleCounting() throws {
        let last1: [String: Any] = ["input_tokens": 100, "output_tokens": 1, "total_tokens": 101]
        let last2: [String: Any] = ["input_tokens": 200, "output_tokens": 2, "total_tokens": 202]
        let url = try write("s/rollout-a.jsonl", [
            turnContext("gpt-5.6-sol"),
            codexTokenCount(ordinal: 1, cumulative: 101, last: last1),
        ], trailingNewline: false)
        XCTAssertEqual(row(scan("codex"), "gpt-5.6-sol")?.totalVolume, 101)
        let firstOffset = try XCTUnwrap(LocalTokenCostScanner.cachedParsedOffset(forPath: url.path))

        try append(url, "\n" + line(codexTokenCount(ordinal: 2, cumulative: 303, last: last2)) + "\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(row(scan("codex"), "gpt-5.6-sol")?.totalVolume, 303)
        XCTAssertEqual(row(scan("codex"), "gpt-5.6-sol")?.requestCount, 2)
        let secondOffset = try XCTUnwrap(LocalTokenCostScanner.cachedParsedOffset(forPath: url.path))
        XCTAssertGreaterThan(secondOffset, firstOffset)
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(secondOffset, size)
    }

    func testPartialTrailingLineIsReadOnceComplete() throws {
        let complete = line(claudeLine(id: "m1", usage: ["input_tokens": 3, "output_tokens": 4]))
        let url = root.appendingPathComponent("p/a.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cut = complete.index(complete.startIndex, offsetBy: complete.count / 2)
        try String(complete[..<cut]).write(to: url, atomically: false, encoding: .utf8)
        XCTAssertNil(row(scan("claude"), "claude-opus-5-5"))

        try append(url, String(complete[cut...]) + "\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.outputTokens, 4)
    }

    func testRewrittenFileIsReparsedFromScratch() throws {
        let url = try write("p/a.jsonl", [claudeLine(id: "m1", usage: ["input_tokens": 3, "output_tokens": 4])])
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.outputTokens, 4)
        try write("p/a.jsonl", [
            claudeLine(id: "m2", usage: ["input_tokens": 3, "output_tokens": 5]),
            claudeLine(id: "m3", usage: ["input_tokens": 3, "output_tokens": 6]),
        ])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(row(scan("claude"), "claude-opus-5-5")?.outputTokens, 11)
    }

    func testPricingRefreshRepricesCachedFiles() throws {
        try write("p/a.jsonl", [claudeLine(id: "m1", model: "claude-test-reprice", usage: ["input_tokens": 1_000_000, "output_tokens": 0])])
        let before = try XCTUnwrap(row(scan("claude"), "claude-test-reprice")).estimatedCostUSD
        RemotePricingCatalog.replaceRatesForTesting([
            "claude-test-reprice": TokenPricingCatalog.Rate(inputPerMTok: 123, outputPerMTok: 0, cacheReadPerMTok: 0),
        ])
        let after = try XCTUnwrap(row(scan("claude"), "claude-test-reprice")).estimatedCostUSD
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, 123, accuracy: 1e-9)
    }

    // MARK: - Coverage

    func testCoverageStartsAfterOldestSurvivingFile() {
        let oldest = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!
        let cutoff = ISO8601DateFormatter().date(from: "2026-08-30T00:00:00Z")!
        let coverage = LocalTokenCostScanner.coverageRange(cutoff: cutoff, oldestSource: oldest, now: now, sources: [:])
        let expected = UsageDayKey(date: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: oldest))!)
        XCTAssertEqual(coverage?.from, expected)
        XCTAssertEqual(coverage?.through, UsageDayKey(date: now))
        XCTAssertNil(LocalTokenCostScanner.coverageRange(cutoff: cutoff, oldestSource: nil, now: now, sources: [:]))
    }

    func testUnreadableFileMakesScanNonAuthoritative() throws {
        let url = try write("p/a.jsonl", [claudeLine(id: "m1", usage: ["input_tokens": 3, "output_tokens": 4])])
        try write("p/b.jsonl", [claudeLine(id: "m2", usage: ["input_tokens": 3, "output_tokens": 4])])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let result = scan("claude")
        XCTAssertNil(result.coverage)
        XCTAssertEqual(result.days.values.first?.fidelity, .partial)
    }

    // MARK: - UI

    func testTokenBreakdownLineShowsCacheReadAndWrite() {
        let model = ModelTokenUsage(
            model: "claude-opus-5-5", inputTokens: 1_000, outputTokens: 20, cacheReadTokens: 30_000, cacheWriteTokens: 2_000,
            totalTokens: 33_020, estimatedCostUSD: 1, requestCount: 3
        )
        let text = AnalyticsDashboardView.tokenBreakdownLine(model) { "\($0)" }
        XCTAssertEqual(text, "3 req · 1000 in · 30000 cache read · 2000 cache write · 20 out")
        let plain = ModelTokenUsage(model: "x", inputTokens: 5, outputTokens: 6, cacheReadTokens: 0, totalTokens: 11, estimatedCostUSD: 0, requestCount: 1)
        XCTAssertEqual(AnalyticsDashboardView.tokenBreakdownLine(plain) { "\($0)" }, "1 req · 5 in · 6 out")
    }

    func testEstimateRowsNameTheirBasisAndHideListPriceWhenFree() {
        func estimate(_ model: String, requests: Int, cost: Double, basis: String?) -> ModelTokenUsage {
            ModelTokenUsage(
                model: model, inputTokens: 10, outputTokens: 0, cacheReadTokens: 0, totalTokens: 10,
                estimatedCostUSD: cost, requestCount: requests, volumeUnit: .estimatedTokens, estimateBasis: basis
            )
        }
        let kiroCLI = estimate("claude-opus-5" + LocalKiroCredits.cliEstimateSuffix, requests: 0, cost: 0, basis: LocalKiroCredits.cliEstimateBasis)
        XCTAssertEqual(AnalyticsDashboardView.modelDetailLine(kiroCLI) { "\($0)" }, "context % × window, upper bound")
        XCTAssertNil(AnalyticsDashboardView.rateLabel(for: kiroCLI), "no list price beside a $0 estimate")

        let proxyLog = estimate("claude-opus-5.5" + LocalKiroCredits.proxyLogEstimateSuffix, requests: 120, cost: 0,
                                basis: LocalKiroCredits.proxyLogEstimateBasis)
        XCTAssertEqual(AnalyticsDashboardView.modelDetailLine(proxyLog) { "\($0)" }, "120 req, credits not recorded · Claude Code log, lower bound")

        let cursor = estimate("composer-2.5", requests: 4, cost: 0.5, basis: LocalCursorUsage.estimateBasis)
        XCTAssertEqual(AnalyticsDashboardView.modelDetailLine(cursor) { "\($0)" }, "4 req · est. from context meter")
        XCTAssertNotNil(AnalyticsDashboardView.rateLabel(for: cursor))
    }

    func testOverviewKeepsEstimatesOutOfTheExactTotal() {
        func model(_ name: String, _ unit: UsageVolumeUnit, volume: Int, cost: Double) -> ModelTokenUsage {
            ModelTokenUsage(model: name, inputTokens: volume, outputTokens: 0, cacheReadTokens: 0, totalTokens: volume,
                            estimatedCostUSD: cost, requestCount: 1, volumeUnit: unit)
        }
        let grok = ProviderCostSnapshot.make(
            providerID: "grok", sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: 1_000, last30DaysCostUSD: 1,
            models: [model("grok-4.6", .tokens, volume: 1_000, cost: 1), model("grok-4.6 (est.)", .estimatedTokens, volume: 300, cost: 0.9)]
        )
        let cursor = ProviderCostSnapshot.make(
            providerID: "cursor", sessionTokens: 5, sessionCostUSD: 0, last30DaysTokens: 500, last30DaysCostUSD: 0.2,
            models: [model("composer-2.5", .estimatedTokens, volume: 500, cost: 0.2)], volumeUnit: .estimatedTokens
        )
        let kiro = ProviderCostSnapshot.make(
            providerID: "kiro", sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: 9_000, last30DaysCostUSD: 0.36,
            models: [model("claude-opus-5", .credits, volume: 9_000, cost: 0.36),
                     model("claude-opus-5 (est. upper bound)", .estimatedTokens, volume: 70_000, cost: 0)],
            volumeUnit: .credits
        )
        let overview = AnalyticsEngine.overview(from: [grok, cursor, kiro])
        XCTAssertEqual(overview.totalTokens30d, 1_000)
        XCTAssertEqual(overview.estimatedTokens30d, 300 + 500 + 70_000)
        XCTAssertEqual(overview.estimatedTokensSession, 5)
        XCTAssertFalse(overview.topModels.contains { $0.volumeUnit == .estimatedTokens })
        XCTAssertEqual(overview.topEstimatedModels.first?.model, "claude-opus-5 (est. upper bound)", "estimates rank by volume")
        XCTAssertEqual(overview.totalCostUSD30d, 1 + 0.36, accuracy: 1e-9, "exact and billed cost only")
        XCTAssertEqual(overview.estimatedCostUSD30d, 0.9 + 0.2, accuracy: 1e-9, "Grok signals rows and the Cursor estimate")
        XCTAssertEqual(overview.estimatedCostUSDSession, 0)
        XCTAssertEqual(
            AnalyticsDashboardView.totalsSublabel(cost: overview.totalCostUSD30d, estimatedCost: overview.estimatedCostUSD30d, estimated: overview.estimatedTokens30d),
            "$1.36 +$1.10 est · +70.8K est"
        )
        XCTAssertEqual(AnalyticsDashboardView.totalsSublabel(cost: nil, estimatedCost: 0, estimated: 0), nil)
    }
}
