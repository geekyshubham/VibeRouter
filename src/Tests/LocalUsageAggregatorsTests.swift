import SQLite3
import XCTest
@testable import CLIProxyMenuBar

final class LocalUsageAggregatorsTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-agg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        RemotePricingCatalog.replaceRatesForTesting([:])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        RemotePricingCatalog.replaceRatesForTesting([:])
        super.tearDown()
    }

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func dayEpoch(_ date: Date) -> Int {
        Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
    }

    private func write(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func writeLines(_ objects: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Kiro

    private func kiroTurn(
        end: Date,
        credits: Double,
        requests: Int?,
        pct: Double,
        model: String? = nil
    ) -> [String: Any] {
        var turn: [String: Any] = [
            "end_timestamp": iso.string(from: end),
            "metering_usage": credits > 0 ? [["value": credits, "unit": "credit", "unitPlural": "credits"]] : [],
            "context_usage_percentage": pct,
            "input_token_count": 0,
            "output_token_count": 0,
        ]
        if let requests { turn["total_request_count"] = requests }
        if let model { turn["model"] = model }
        return turn
    }

    private func kiroSession(model: String, window: Int, turns: [[String: Any]], created: Date) -> [String: Any] {
        [
            "created_at": iso.string(from: created),
            "session_state": [
                "rts_model_state": ["model_info": ["model_id": model, "context_window_tokens": window]],
                "conversation_metadata": ["user_turn_metadatas": turns],
            ],
        ]
    }

    func testKiroRequestsComeFromTotalRequestCountAndZeroCreditTurnsStillCount() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("kiro")
        let session = kiroSession(
            model: "claude-opus-5.5",
            window: 1_000_000,
            turns: [
                kiroTurn(end: now.addingTimeInterval(-120), credits: 3.5, requests: 42, pct: 10),
                kiroTurn(end: now.addingTimeInterval(-60), credits: 0, requests: 3, pct: 20),
                kiroTurn(end: now.addingTimeInterval(-30), credits: 0, requests: 0, pct: 20),
            ],
            created: now.addingTimeInterval(-600)
        )
        try write(session, to: root.appendingPathComponent("a.json"))

        let snapshot = try XCTUnwrap(LocalKiroCredits.costSnapshot(now: now, sessionsRoot: root, proxyEntries: []))
        let creditRow = try XCTUnwrap(snapshot.models.first { $0.volumeUnit == .credits })
        XCTAssertEqual(creditRow.model, "claude-opus-5.5")
        XCTAssertEqual(creditRow.requestCount, 45)
        XCTAssertEqual(creditRow.totalTokens, 3500)
        XCTAssertEqual(snapshot.last30DaysTokens, 3500)
        XCTAssertEqual(snapshot.volumeUnit, .credits)
        XCTAssertEqual(snapshot.last30DaysCostUSD ?? 0, 3.5 * TokenPricingCatalog.kiroUSDPerCredit, accuracy: 1e-9)
        XCTAssertEqual(snapshot.models.first?.volumeUnit, .credits, "credit rows lead so the card's top model is a credit row")
    }

    func testKiroEstimatedTokensAreSeparateZeroCostRows() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("kiro")
        let session = kiroSession(
            model: "claude-opus-5.5",
            window: 1_000_000,
            turns: [
                kiroTurn(end: now.addingTimeInterval(-120), credits: 1, requests: 2, pct: 10),
                kiroTurn(end: now.addingTimeInterval(-60), credits: 1, requests: 4, pct: 30),
            ],
            created: now.addingTimeInterval(-600)
        )
        try write(session, to: root.appendingPathComponent("s1.json"))
        try writeLines([
            ["kind": "Prompt", "data": ["message_id": "p1", "content": []]],
            ["kind": "AssistantMessage", "data": ["message_id": "a1", "content": [
                ["kind": "text", "data": String(repeating: "x", count: 400)],
                ["kind": "thinking", "data": ["text": String(repeating: "t", count: 999)]],
            ]]],
            ["version": "v1", "kind": "ToolResults", "data": ["content": [["kind": "text", "data": String(repeating: "r", count: 800)]]]],
            ["kind": "Prompt", "data": ["message_id": "p2", "content": []]],
            ["kind": "AssistantMessage", "data": ["message_id": "a2", "content": [
                ["kind": "toolUse", "data": ["toolUseId": "t", "name": "read", "input": ["path": "abcd"]]],
            ]]],
        ], to: root.appendingPathComponent("s1.jsonl"))

        let scan = LocalKiroCredits.dailyUsageScan(now: now, sessionsRoot: root, proxyEntries: [])
        XCTAssertTrue(scan.isComplete)
        let day = try XCTUnwrap(scan.days[UsageDayKey(date: now)])
        XCTAssertEqual(day.fidelity, .exact)
        let estimated = try XCTUnwrap(day.models.first { $0.volumeUnit == .estimatedTokens })
        XCTAssertEqual(estimated.model, "claude-opus-5.5" + LocalKiroCredits.cliEstimateSuffix)
        // turn 1: 2 × (10+10)/2 % × 1M = 200k; turn 2: 4 × (10+30)/2 % × 1M = 800k
        XCTAssertEqual(estimated.inputTokens, 1_000_000)
        let toolChars = "read".count + #"{"path":"abcd"}"#.count
        XCTAssertEqual(estimated.outputTokens, 400 / 4 + toolChars / 4)
        XCTAssertEqual(estimated.estimatedCostUSD, 0)
        XCTAssertEqual(estimated.requestCount, 0, "requests live on the credit row only")
        XCTAssertEqual(day.requestCount, 6)
    }

    func testKiroContextWindowPrefersSessionThenMostCommonForModel() {
        let sessions = [
            LocalKiroCredits.ParsedSession(modelID: "gpt-5.6-sol", contextWindowTokens: 272_000, turns: []),
            LocalKiroCredits.ParsedSession(modelID: "gpt-5.6-sol", contextWindowTokens: 272_000, turns: []),
            LocalKiroCredits.ParsedSession(modelID: "gpt-5.6-sol", contextWindowTokens: 1_000_000, turns: []),
        ]
        let common = LocalKiroCredits.commonContextWindows(sessions)
        XCTAssertEqual(common["gpt-5.6-sol"], 272_000)
        XCTAssertEqual(
            LocalKiroCredits.contextWindow(forTurnModel: "gpt-5.6-sol", sessionModelID: "gpt-5.6-sol", sessionWindow: 1_000_000, commonWindows: common),
            1_000_000
        )
        XCTAssertEqual(
            LocalKiroCredits.contextWindow(forTurnModel: "gpt-5.6-sol", sessionModelID: "claude-opus-5", sessionWindow: 1_000_000, commonWindows: common),
            272_000
        )
        XCTAssertEqual(
            LocalKiroCredits.contextWindow(forTurnModel: "glm-5", sessionModelID: nil, sessionWindow: nil, commonWindows: common),
            LocalKiroCredits.defaultContextWindow
        )
        XCTAssertEqual(LocalKiroCredits.estimatedInputTokens(requests: 10, previousPercentage: nil, percentage: 50, window: 200_000), 1_000_000)
        XCTAssertEqual(LocalKiroCredits.estimatedInputTokens(requests: 10, previousPercentage: 0, percentage: 50, window: 200_000), 500_000)
    }

    private func proxyEntry(
        id: String,
        message: String?,
        credits: Double?,
        source: KiroProxyUsageLedger.TokenSource,
        model: String = "kiro/claude-opus-5.5",
        at date: Date
    ) -> KiroProxyUsageLedger.Entry {
        KiroProxyUsageLedger.Entry(
            id: id,
            timestamp: date,
            model: model,
            credits: credits,
            inputTokens: 1000,
            outputTokens: 100,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            tokenSource: source,
            contextUsagePercentage: nil,
            account: "cli-social",
            accountUserHash: nil,
            claudeMessageID: message
        )
    }

    func testKiroLedgerWinsOverClaudeLogByMessageID() {
        let now = Date()
        let ledger = [
            proxyEntry(id: "L1", message: "msg_1", credits: 1.3, source: .payloadBytes, at: now),
            proxyEntry(id: "L1", message: "msg_1", credits: 1.3, source: .payloadBytes, at: now),
        ]
        let claude = [
            proxyEntry(id: "C1", message: "msg_1", credits: nil, source: .claudeLog, at: now),
            proxyEntry(id: "C2", message: "msg_2", credits: nil, source: .claudeLog, at: now),
            proxyEntry(id: "C3", message: "msg_2", credits: nil, source: .claudeLog, at: now),
        ]
        let merged = LocalKiroCredits.mergeProxyEntries(ledger: ledger, claudeLog: claude)
        XCTAssertEqual(merged.map(\.id), ["L1", "C2"])
    }

    func testKiroProxyEntriesMergeUnderKiroWithCredits() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("kiro")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = LocalKiroCredits.mergeProxyEntries(
            ledger: [
                proxyEntry(id: "L1", message: "msg_1", credits: 1.5, source: .kiroMetadata, at: now),
                proxyEntry(id: "L2", message: "msg_3", credits: 0.5, source: .contextPercentage, at: now),
                proxyEntry(id: "L3", message: "msg_4", credits: 0.5, source: .payloadBytes, at: now),
            ],
            claudeLog: [
                proxyEntry(id: "C1", message: "msg_1", credits: nil, source: .claudeLog, at: now),
                proxyEntry(id: "C2", message: "msg_2", credits: nil, source: .claudeLog, at: now),
            ]
        )
        let snapshot = try XCTUnwrap(LocalKiroCredits.costSnapshot(now: now, sessionsRoot: root, proxyEntries: entries))
        XCTAssertEqual(snapshot.providerID, "kiro")
        let credit = try XCTUnwrap(snapshot.models.first { $0.volumeUnit == .credits })
        XCTAssertEqual(credit.model, "claude-opus-5.5")
        XCTAssertEqual(credit.requestCount, 3, "unmetered Claude-log requests stay off the credit row")
        XCTAssertEqual(credit.totalTokens, 2500)
        let expected: [(String, String)] = [
            (LocalKiroCredits.proxyMetadataSuffix, "exact from Kiro"),
            (LocalKiroCredits.proxyContextSuffix, "context % × window"),
            (LocalKiroCredits.proxyEstimateSuffix, "proxy payload ÷ 4"),
        ]
        for (suffix, basis) in expected {
            let ledger = try XCTUnwrap(snapshot.models.first { $0.model == "claude-opus-5.5" + suffix }, suffix)
            XCTAssertEqual(ledger.totalTokens, 1100)
            XCTAssertEqual(ledger.requestCount, 0)
            XCTAssertEqual(ledger.estimateBasis, basis)
            XCTAssertEqual(ledger.estimatedCostUSD, 0)
            XCTAssertTrue(LocalKiroCredits.isProxyEstimateRow(ledger.model))
        }
        let logged = try XCTUnwrap(snapshot.models.first { $0.model == "claude-opus-5.5" + LocalKiroCredits.proxyLogEstimateSuffix })
        XCTAssertEqual(logged.totalTokens, 1100)
        XCTAssertEqual(logged.requestCount, 1, "counted once, as an unmetered request")
        XCTAssertEqual(logged.estimateBasis, LocalKiroCredits.proxyLogEstimateBasis)
        XCTAssertEqual(snapshot.estimatedTokens30d, 4400)
        XCTAssertNil(snapshot.estimatedTokensLowerBound30d, "no CLI estimate, so no range")
    }

    func testKiroCLIEstimateCarriesALowerBoundWithFirstTurnsFromZero() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("kiro-range")
        let session = kiroSession(
            model: "claude-opus-5.5",
            window: 1_000_000,
            turns: [
                kiroTurn(end: now.addingTimeInterval(-120), credits: 1, requests: 2, pct: 10),
                kiroTurn(end: now.addingTimeInterval(-60), credits: 1, requests: 4, pct: 30),
            ],
            created: now.addingTimeInterval(-600)
        )
        try write(session, to: root.appendingPathComponent("s1.json"))
        let snapshot = try XCTUnwrap(LocalKiroCredits.costSnapshot(now: now, sessionsRoot: root, proxyEntries: []))
        XCTAssertEqual(snapshot.estimatedTokens30d, 1_000_000)
        // first turn from 0%: 2 × (0+10)/2 % × 1M = 100k instead of 200k
        XCTAssertEqual(snapshot.estimatedTokensLowerBound30d, 900_000)
        let pill = try XCTUnwrap(ProviderUsageCardView.estimatedTokensPill(snapshot))
        XCTAssertEqual(pill.label, "Est. tokens 30d (range)")
        XCTAssertEqual(pill.value, "900K–1M est")
    }

    func testKiroOtherModelTurnNeverUsesTheSessionModelsWindow() {
        XCTAssertEqual(
            LocalKiroCredits.contextWindow(
                forTurnModel: "glm-5", sessionModelID: "claude-opus-5", sessionWindow: 1_000_000, commonWindows: [:],
                catalogWindow: { _ in nil }
            ),
            LocalKiroCredits.defaultContextWindow
        )
        XCTAssertEqual(
            LocalKiroCredits.contextWindow(
                forTurnModel: "glm-5", sessionModelID: "claude-opus-5", sessionWindow: 1_000_000, commonWindows: [:],
                catalogWindow: { $0 == "glm-5" ? 128_000 : nil }
            ),
            128_000,
            "the cached list-models window wins over the default"
        )
        XCTAssertEqual(
            LocalKiroCredits.estimatedInputTokens(requests: 2, previousPercentage: nil, percentage: 25, window: 200_000),
            100_000
        )
    }

    func testKiroScanCoverageFlags() throws {
        let now = Date()
        let missing = LocalKiroCredits.dailyUsageScan(
            now: now, sessionsRoot: tempRoot.appendingPathComponent("absent"), proxyEntries: []
        )
        XCTAssertFalse(missing.isComplete)

        let root = tempRoot.appendingPathComponent("kiro")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = LocalKiroCredits.dailyUsageScan(now: now, sessionsRoot: root, proxyEntries: [])
        XCTAssertTrue(empty.isComplete)
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertEqual(empty.coveredThrough, UsageDayKey(date: now))

        try String(repeating: "{ \"truncated\": ", count: 10).write(
            to: root.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8
        )
        XCTAssertFalse(LocalKiroCredits.dailyUsageScan(now: now, sessionsRoot: root, proxyEntries: []).isComplete)
    }

    // MARK: - Grok

    private func grokUsage(turns: [(end: Date, model: String, input: Int, cached: Int, output: Int, calls: Int, ticks: Int)]) -> [String: Any] {
        [
            "sessionId": "s",
            "updatedAt": iso.string(from: Date()),
            "turns": turns.map { t in
                [
                    "endedAt": iso.string(from: t.end),
                    "modelUsage": [t.model: [
                        "inputTokens": t.input,
                        "cachedReadTokens": t.cached,
                        "cacheCreationTokens": 0,
                        "outputTokens": t.output,
                        "totalTokens": t.input + t.output,
                        "modelCalls": t.calls,
                        "costUsdTicks": t.ticks,
                    ]],
                ] as [String: Any]
            },
        ]
    }

    func testGrokUsageJSONIsExactAndUsesBilledTicks() throws {
        let now = Date()
        let data = try JSONSerialization.data(withJSONObject: grokUsage(turns: [
            (now, "grok-4.7-build", 1000, 800, 50, 7, 12_345_000_000),
        ]))
        let turns = try XCTUnwrap(LocalGrokUsage.parseUsageFile(data, fallbackDate: now))
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].uncachedInput, 200)
        XCTAssertEqual(turns[0].cacheRead, 800)
        XCTAssertEqual(turns[0].total, 1050)
        XCTAssertEqual(turns[0].modelCalls, 7)
        XCTAssertEqual(LocalGrokUsage.turnCostUSD(turns[0]), 1.2345, accuracy: 1e-12)
    }

    func testGrokBuildFallsBackToBuildRatesWhenTicksMissing() {
        let turn = LocalGrokUsage.TurnUsage(
            day: 0, model: "grok-4.6-build", uncachedInput: 1_000_000, cacheRead: 1_000_000,
            cacheWrite: 0, output: 1_000_000, total: 3_000_000, modelCalls: 1, costUsdTicks: 0
        )
        XCTAssertEqual(LocalGrokUsage.turnCostUSD(turn), 1.0 + 0.2 + 2.0, accuracy: 1e-9)
    }

    func testGrokPrefersUsageJSONCountsBilledTmpSessionsAndLabelsSignalEstimates() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("grok")
        let real = root.appendingPathComponent("%2FUsers%2Fme%2Fapp/s1")
        try write(grokUsage(turns: [(now, "grok-4.6", 10_000, 9_000, 100, 12, 0)]), to: real.appendingPathComponent("usage.json"))
        try write(["assistantMessageCount": 99, "contextTokensUsed": 5_000_000, "primaryModelId": "grok-4.6"],
                  to: real.appendingPathComponent("signals.json"))

        let scratch = root.appendingPathComponent("%2Fprivate%2Ftmp%2Fdeploy/s2")
        try write(grokUsage(turns: [(now, "grok-4.6", 2_000, 0, 10, 3, 5_000_000_000)]), to: scratch.appendingPathComponent("usage.json"))
        let idleScratch = root.appendingPathComponent("%2Fprivate%2Ftmp%2Fidle/s3")
        try write(grokUsage(turns: [(now, "grok-4.6", 0, 0, 0, 0, 0)]), to: idleScratch.appendingPathComponent("usage.json"))
        try write(["assistantMessageCount": 5, "contextTokensUsed": 70_000, "primaryModelId": "grok-4.5"],
                  to: root.appendingPathComponent("%2Fprivate%2Ftmp%2Fharness/s4/signals.json"))

        let legacy = root.appendingPathComponent("%2FUsers%2Fme%2Fold/s5")
        try write(["assistantMessageCount": 4, "contextTokensUsed": 1_000, "primaryModelId": "grok-4.5"],
                  to: legacy.appendingPathComponent("signals.json"))

        let snapshot = try XCTUnwrap(LocalGrokUsage.costSnapshot(now: now, root: root))
        XCTAssertEqual(snapshot.volumeUnit, .tokens)
        let exact = try XCTUnwrap(snapshot.models.first { $0.model == "grok-4.6" })
        XCTAssertEqual(exact.volumeUnit, .tokens)
        XCTAssertEqual(exact.requestCount, 15)
        XCTAssertEqual(exact.totalTokens, 10_100 + 2_010)
        XCTAssertEqual(exact.cacheReadTokens, 9_000)
        let estimate = try XCTUnwrap(snapshot.models.first { $0.model == "grok-4.5" + LocalGrokUsage.estimateSuffix })
        XCTAssertEqual(estimate.volumeUnit, .estimatedTokens)
        XCTAssertEqual(estimate.totalTokens, 1_000)
        XCTAssertEqual(snapshot.models.count, 2, "signals of a usage.json session and unbilled/tmp estimates are not counted")

        XCTAssertEqual(estimate.inputTokens, 700, "stored split matches the 70/30 split it is priced at")
        XCTAssertEqual(estimate.outputTokens, 300)
        XCTAssertEqual(estimate.estimatedCostUSD,
                       TokenPricingCatalog.estimateUSD(model: "grok-4.5", inputTokens: 700, outputTokens: 300), accuracy: 1e-12)
        XCTAssertEqual(snapshot.last30DaysTokens, exact.totalTokens, "the headline holds exact usage.json tokens only")
        XCTAssertEqual(snapshot.last30DaysCostUSD ?? -1, exact.estimatedCostUSD, accuracy: 1e-12)
        XCTAssertEqual(snapshot.estimatedTokens30d, 1_000)

        let scan = LocalGrokUsage.dailyUsageScan(now: now, root: root)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.days[UsageDayKey(date: now)]?.fidelity, .sessionApproximate)
        XCTAssertTrue(scan.sources.keys.contains { $0.hasSuffix("s1/usage.json") }, "sources let the store protect deleted sessions")
        XCTAssertTrue(scan.sources.keys.contains { $0.hasSuffix("s5/signals.json") })
    }

    func testGrokEstimateOnlySnapshotUsesEstimatedUnit() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("grok-est")
        try write(["assistantMessageCount": 2, "contextTokensUsed": 10_000, "primaryModelId": "grok-4.6"],
                  to: root.appendingPathComponent("%2FUsers%2Fme%2Fapp/s1/signals.json"))
        let snapshot = try XCTUnwrap(LocalGrokUsage.costSnapshot(now: now, root: root))
        XCTAssertEqual(snapshot.volumeUnit, .estimatedTokens)
        XCTAssertEqual(snapshot.last30DaysTokens, 10_000)
        XCTAssertEqual(snapshot.models.first?.estimateBasis, LocalGrokUsage.estimateBasis)
    }

    // MARK: - OpenCode

    private func makeOpenCodeDB(messages: [(created: Int64, json: [String: Any])]) throws -> URL {
        let url = tempRoot.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE session (time_updated INTEGER); CREATE TABLE message (time_created INTEGER, data TEXT);", nil, nil, nil)
        for message in messages {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message.json), as: UTF8.self)
                .replacingOccurrences(of: "'", with: "''")
            sqlite3_exec(db, "INSERT INTO message VALUES (\(message.created), '\(text)');", nil, nil, nil)
        }
        return url
    }

    func testOpenCodeReadsCacheWriteIntoTotalsAndCost() throws {
        let usage = LocalOpenCodeUsage.MessageTokens(message: [
            "tokens": ["input": 100, "output": 10, "reasoning": 5, "cache": ["read": 1000, "write": 400]],
        ])
        XCTAssertEqual(usage.cacheWrite, 400)
        XCTAssertEqual(usage.output, 15)
        XCTAssertEqual(usage.total, 1515)
        let expected = TokenPricingCatalog.estimateUSD(
            model: "glm-5.3", inputTokens: 100, outputTokens: 15, cacheReadTokens: 1000, cacheWriteTokens: 400
        )
        XCTAssertEqual(usage.costUSD(model: "glm-5.3"), expected, accuracy: 1e-12)

        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let url = try makeOpenCodeDB(messages: [
            (ms, ["role": "assistant", "modelID": "glm-5.3", "tokens": ["input": 0, "output": 0, "cache": ["read": 0, "write": 700]]]),
        ])
        let scan = LocalOpenCodeUsage.dailyUsageScan(now: now, dbURL: url)
        XCTAssertTrue(scan.isComplete)
        let row = try XCTUnwrap(scan.days[UsageDayKey(date: now)]?.models.first)
        XCTAssertEqual(row.totalVolume, 700, "write-only rows must not be dropped")
        XCTAssertEqual(row.inputTokens, 0)
        XCTAssertEqual(row.cacheWriteTokens, 700)
        XCTAssertFalse(LocalOpenCodeUsage.dailyUsageScan(now: now, dbURL: tempRoot.appendingPathComponent("none.db")).isComplete)
    }

    func testOpenCodeStoredZeroCostStaysFreeForZenAndIsLabelledElsewhere() throws {
        let tokens: [String: Any] = ["input": 100_000, "output": 10_000, "cache": ["read": 0, "write": 0]]
        let zen = LocalOpenCodeUsage.MessageTokens(message: ["providerID": "opencode", "cost": 0, "tokens": tokens])
        XCTAssertEqual(zen.costUSD(model: "opencode/big-pickle"), 0, "Zen's stored $0 is a free model")
        XCTAssertEqual(zen.rowModel("opencode/big-pickle"), "opencode/big-pickle")

        let thirdParty = LocalOpenCodeUsage.MessageTokens(message: ["providerID": "xai", "cost": 0, "tokens": tokens])
        XCTAssertGreaterThan(thirdParty.costUSD(model: "xai/grok-4.6"), 0)
        XCTAssertEqual(thirdParty.rowModel("xai/grok-4.6"), "xai/grok-4.6" + LocalOpenCodeUsage.listPriceSuffix)

        let missing = LocalOpenCodeUsage.MessageTokens(message: ["providerID": "opencode", "tokens": tokens])
        XCTAssertGreaterThan(missing.costUSD(model: "opencode/glm-5.3"), 0, "no stored cost falls back to list price")
        XCTAssertEqual(missing.rowModel("opencode/glm-5.3"), "opencode/glm-5.3")

        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let url = try makeOpenCodeDB(messages: [
            (ms - 90 * 86_400_000, ["role": "assistant", "modelID": "glm-5.3", "providerID": "opencode", "cost": 0.5, "tokens": tokens]),
            (ms, ["role": "assistant", "modelID": "big-pickle", "providerID": "opencode", "cost": 0, "tokens": tokens]),
        ])
        let scan = LocalOpenCodeUsage.dailyUsageScan(now: now, dbURL: url)
        XCTAssertEqual(scan.days[UsageDayKey(date: now)]?.models.first?.estimatedCostUSD, 0)
        XCTAssertEqual(scan.sources.count, 1, "the DB is the scan's source")
        XCTAssertEqual(scan.coveredFrom, UsageDayKey(date: analyticsCutoffStart(now: now, historyDays: 30)))

        let full = LocalOpenCodeUsage.dailyUsageScan(now: now, historyDays: UsageDailyStore.retentionDays, dbURL: url)
        let oldest = now.addingTimeInterval(-90 * 86_400)
        let dayAfterOldest = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: oldest))!
        XCTAssertEqual(full.coveredFrom, UsageDayKey(date: dayAfterOldest), "a full rebuild covers only what the DB still holds")
    }

    // MARK: - Antigravity

    private func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func field(_ number: Int, _ value: UInt64) -> Data { varint(UInt64(number << 3)) + varint(value) }
    private func field(_ number: Int, bytes: Data) -> Data { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ number: Int, string: String) -> Data { field(number, bytes: Data(string.utf8)) }

    private func generationBlob(
        model: String?, label: String? = nil, input: UInt64, output: UInt64, cacheWrite: UInt64 = 0,
        cacheRead: UInt64, rid: String, ts: UInt64, padding: Int = 0
    ) -> Data {
        var usage = field(2, input) + field(3, output) + field(4, cacheWrite) + field(5, cacheRead)
        usage += field(9, output / 2) + field(10, output - output / 2) + field(11, string: rid)
        var generation = field(4, bytes: usage)
        generation += field(7, UInt64.max)
        generation += field(9, bytes: field(4, bytes: field(1, ts)))
        if let model { generation += field(19, string: model) }
        if let label { generation += field(21, string: label) }
        var blob = field(1, bytes: generation)
        if padding > 0 { blob += field(2, bytes: Data(repeating: 0x41, count: padding)) }
        return blob
    }

    private func makeAntigravityDB(_ name: String, blobs: [Data], in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent(name).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER, size INTEGER, data BLOB);", nil, nil, nil)
        for (index, blob) in blobs.enumerated() {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO gen_metadata VALUES (?, ?, ?);", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_int(stmt, 2, Int32(blob.count))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func testAntigravityStructuredDecodeReadsCacheFields() throws {
        let ts = UInt64(Date().timeIntervalSince1970)
        let usage = try XCTUnwrap(LocalAntigravityUsage.decodeGeneration(
            generationBlob(model: "gemini-3.8-flash", input: 4096, output: 300, cacheWrite: 50, cacheRead: 120_000, rid: "r1", ts: ts)
        ))
        XCTAssertEqual(usage.model, "gemini-3.8-flash")
        XCTAssertEqual(usage.input, 4096, "real inputs equal to old 'budget constants' are kept")
        XCTAssertEqual(usage.output, 300)
        XCTAssertEqual(usage.cacheWrite, 50)
        XCTAssertEqual(usage.cacheRead, 120_000)
        XCTAssertEqual(usage.total, 4096 + 300 + 50 + 120_000)
        XCTAssertEqual(usage.responseID, "r1")
        XCTAssertEqual(usage.timestamp, TimeInterval(ts))
        XCTAssertTrue(usage.priced)

        let labelled = try XCTUnwrap(LocalAntigravityUsage.decodeGeneration(
            generationBlob(model: nil, label: "Gemini 3.8 Flash (High)", input: 900, output: 0, cacheRead: 0, rid: "r2", ts: ts)
        ))
        XCTAssertEqual(labelled.model, "gemini-3.8-flash (unpriced)", "kept apart from the priced gemini-3.8-flash row")
        XCTAssertFalse(labelled.priced, "prompt-only rows without a model are counted but not priced")
        XCTAssertTrue(TokenPricingCatalog.isUnpriced(labelled.model))
        XCTAssertEqual(
            LocalAntigravityUsage.decodeGeneration(
                generationBlob(model: nil, label: "Gemini 3.8 Flash (High)", input: 900, output: 5, cacheRead: 0, rid: "r4", ts: ts)
            )?.model,
            "gemini-3.8-flash",
            "a label with output is priced at the named model"
        )
        XCTAssertEqual(
            LocalAntigravityUsage.decodeGeneration(generationBlob(model: nil, input: 5, output: 5, cacheRead: 5, rid: "r3", ts: ts))?.model,
            LocalAntigravityUsage.unknownModel
        )
        XCTAssertNil(LocalAntigravityUsage.decodeGeneration(Data([0x0A, 0xFF, 0xFF])))
    }

    func testAntigravityAggregatesLargeRowsDedupesResponsesAndPricesCacheReads() throws {
        let now = Date()
        let ts = UInt64(now.timeIntervalSince1970) - 30
        let dir = tempRoot.appendingPathComponent("conversations")
        let big = generationBlob(model: "gemini-3.8-flash", input: 1000, output: 100, cacheRead: 50_000, rid: "dup", ts: ts, padding: 20_000)
        try makeAntigravityDB("a.db", blobs: [big], in: dir)
        try makeAntigravityDB("b.db", blobs: [
            big,
            generationBlob(model: "gemini-3.8-flash", input: 10_000, output: 10, cacheRead: 0, rid: "other", ts: ts),
        ], in: dir)

        let scan = LocalAntigravityUsage.dailyUsageScan(now: now, roots: [dir])
        XCTAssertTrue(scan.isComplete)
        let day = try XCTUnwrap(scan.days[UsageDayKey(date: now)])
        XCTAssertEqual(day.fidelity, .exact)
        let row = try XCTUnwrap(day.models.first)
        XCTAssertEqual(row.requestCount, 2)
        XCTAssertEqual(row.cacheReadTokens, 50_000)
        XCTAssertEqual(row.totalVolume, 1000 + 100 + 50_000 + 10_000 + 10)
        let expected = TokenPricingCatalog.requestCostUSD(model: "gemini-3.8-flash", uncachedInput: 1000, cacheRead: 50_000, output: 100)
            + TokenPricingCatalog.requestCostUSD(model: "gemini-3.8-flash", uncachedInput: 10_000, output: 10)
        XCTAssertEqual(row.estimatedCostUSD, expected, accuracy: 1e-12)
    }

    func testAntigravityReadsSymlinkedRootAndReportsSources() throws {
        let now = Date()
        let ts = UInt64(now.timeIntervalSince1970) - 30
        let real = tempRoot.appendingPathComponent("real-conversations")
        try makeAntigravityDB("a.db", blobs: [
            generationBlob(model: "gemini-3.8-flash", input: 1000, output: 10, cacheRead: 0, rid: "r1", ts: ts),
        ], in: real)
        let link = tempRoot.appendingPathComponent("conversations")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scan = LocalAntigravityUsage.dailyUsageScan(now: now, roots: [link])
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.days[UsageDayKey(date: now)]?.models.first?.totalVolume, 1010)
        XCTAssertEqual(scan.sources.keys.map { ($0 as NSString).lastPathComponent }, ["a.db"])
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        XCTAssertEqual(scan.coveredFrom, UsageDayKey(date: tomorrow), "nothing before the oldest surviving DB's last write is provable")
        let daily = LocalTokenCostScanner.providerDailyScan(scan)
        XCTAssertEqual(daily.coverage?.sources, scan.sources)
    }

    // MARK: - Copilot

    func testCopilotReadsSymlinkedSessionStateAndLabelsEstimates() throws {
        let now = Date()
        let root = tempRoot.appendingPathComponent("copilot-link")
        let realState = tempRoot.appendingPathComponent("state-real")
        try writeLines([
            ["type": "user.message", "timestamp": iso.string(from: now), "data": ["content": "abcd"]],
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["model": "gpt-5.4-mini", "outputTokens": 70, "requestId": "R1"]],
        ], to: realState.appendingPathComponent("sess-1/events.jsonl"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session-state"), withDestinationURL: realState)

        let snapshot = try XCTUnwrap(LocalCopilotUsage.costSnapshot(now: now, root: root))
        let row = try XCTUnwrap(snapshot.models.first)
        XCTAssertEqual(row.outputTokens, 70)
        XCTAssertEqual(row.estimateBasis, LocalCopilotUsage.sessionEstimateBasis)
        let scan = LocalCopilotUsage.dailyUsageScan(now: now, root: root)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.sources.count, 1)
    }

    func testCopilotSessionEventsGiveExactOutputPerRequest() {
        let lines: [[String: Any]] = [
            ["type": "user.message", "timestamp": "2026-09-20T10:00:00.000Z", "data": ["content": String(repeating: "q", count: 40)]],
            ["type": "assistant.message", "timestamp": "2026-09-20T10:00:05.000Z", "data": ["model": "gpt-5.4-mini", "outputTokens": 142, "requestId": "R1", "content": "hi"]],
            ["type": "assistant.message", "timestamp": "2026-09-20T10:00:06.000Z", "data": ["model": "gpt-5.4-mini", "outputTokens": 142, "requestId": "R1", "content": "hi"]],
            ["type": "assistant.message", "timestamp": "2026-09-20T10:00:09.000Z", "data": ["model": "gpt-5.4-mini", "outputTokens": 110, "requestId": "R2", "content": ""]],
        ]
        let data = Data(lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
        let days = LocalCopilotUsage.parseSessionEvents(data, fallbackDay: 0)
        let bucket = days.values.first?["gpt-5.4-mini"]
        XCTAssertEqual(bucket?.output, 252)
        XCTAssertEqual(bucket?.requests, 2)
        XCTAssertEqual(bucket?.input, 10)
    }

    func testCopilotTranscriptCountsAssistantMessagesOnlyAndSnapshotRespectsCutoff() throws {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        let root = tempRoot.appendingPathComponent("copilot")
        try writeLines([
            ["type": "user.message", "timestamp": iso.string(from: old), "data": ["content": String(repeating: "o", count: 4000)]],
            ["type": "user.message", "timestamp": iso.string(from: now), "data": ["content": String(repeating: "u", count: 400)]],
            ["type": "user.message", "timestamp": iso.string(from: now), "data": ["content": String(repeating: "u", count: 400)]],
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["messageId": "m1", "iterationNumber": 1, "content": String(repeating: "a", count: 80)]],
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["messageId": "m1", "iterationNumber": 1, "content": String(repeating: "a", count: 80)]],
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["messageId": "m1", "iterationNumber": 2, "content": String(repeating: "b", count: 80)]],
        ], to: root.appendingPathComponent("jb/sess-1/partition-1.jsonl"))
        try writeLines([
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["messageId": "x", "content": "ignored"]],
        ], to: root.appendingPathComponent("jb/sess-2/partition-1.jsonl"))
        try writeLines([
            ["type": "assistant.message", "timestamp": iso.string(from: now), "data": ["model": "gpt-5.4-mini", "outputTokens": 70, "requestId": "R9"]],
        ], to: root.appendingPathComponent("session-state/sess-2/events.jsonl"))

        let snapshot = try XCTUnwrap(LocalCopilotUsage.costSnapshot(now: now, root: root))
        let transcript = try XCTUnwrap(snapshot.models.first { $0.model == LocalCopilotUsage.transcriptModel })
        XCTAssertEqual(transcript.inputTokens, 200, "pre-window history must not leak into the rolling total")
        XCTAssertEqual(transcript.outputTokens, 40)
        XCTAssertEqual(transcript.requestCount, 2, "user messages and replayed iterations are not requests")
        let cli = try XCTUnwrap(snapshot.models.first { $0.model == "gpt-5.4-mini" })
        XCTAssertEqual(cli.outputTokens, 70)
        XCTAssertEqual(cli.requestCount, 1)
        XCTAssertEqual(snapshot.last30DaysTokens, 200 + 40 + 70)

        let scan = LocalCopilotUsage.dailyUsageScan(now: now, root: root)
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.days[UsageDayKey(date: now)]?.fidelity, .dayTotalsOnly)
        XCTAssertNil(scan.days[UsageDayKey(date: old)])
    }

    // MARK: - Real data (opt-in)

    func testPrintRealLocalTotals() throws {
        guard ProcessInfo.processInfo.environment["VIBE_REAL_DATA"] == "1" else {
            throw XCTSkip("set VIBE_REAL_DATA=1 to print real local totals")
        }
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeRouter/pricing-cache.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = RemotePricingCatalog.decodeCache(data) {
            RemotePricingCatalog.replaceRatesForTesting(cached.rates)
        }
        let now = ProcessInfo.processInfo.environment["VIBE_NOW"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        func describe(_ snapshot: ProviderCostSnapshot?) {
            guard let snapshot else { return print("REAL none") }
            print(String(format: "REAL %@ volume=%ld cost=$%.2f unit=%@", snapshot.providerID, snapshot.last30DaysTokens, snapshot.last30DaysCostUSD ?? 0, snapshot.volumeUnit.rawValue))
            for m in snapshot.models {
                print(String(format: "REAL   %@ in=%ld out=%ld cr=%ld total=%ld req=%ld $%.2f %@", m.model, m.inputTokens, m.outputTokens, m.cacheReadTokens, m.totalTokens, m.requestCount, m.estimatedCostUSD, m.volumeUnit.rawValue))
            }
        }
        func timed(_ label: String, _ body: () -> ProviderCostSnapshot?) {
            let start = Date()
            let snapshot = body()
            print(String(format: "REAL %@ took %.2fs", label, Date().timeIntervalSince(start)))
            describe(snapshot)
        }
        timed("kiro") { LocalKiroCredits.costSnapshot(now: now, proxyEntries: []) }
        timed("kiro cached") { LocalKiroCredits.costSnapshot(now: now, proxyEntries: []) }
        timed("grok") { LocalGrokUsage.costSnapshot(now: now) }
        timed("opencode") { LocalOpenCodeUsage.costSnapshot(now: now) }
        timed("antigravity") { LocalAntigravityUsage.costSnapshot(now: now) }
        timed("copilot") { LocalCopilotUsage.costSnapshot(now: now, historyDays: 90) }
        for scan in [
            LocalKiroCredits.dailyUsageScan(now: now, proxyEntries: []),
            LocalGrokUsage.dailyUsageScan(now: now),
            LocalOpenCodeUsage.dailyUsageScan(now: now),
            LocalAntigravityUsage.dailyUsageScan(now: now),
            LocalCopilotUsage.dailyUsageScan(now: now),
        ] {
            print("REAL scan \(scan.providerID) complete=\(scan.isComplete) days=\(scan.days.count) from=\(scan.coveredFrom)")
        }
    }
}
