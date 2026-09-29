import XCTest
@testable import CLIProxyMenuBar

final class KiroProxyUsageTests: XCTestCase {
    // MARK: - Synthetic AWS event stream

    private func frame(_ eventType: String, _ payload: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: payload)
        var headers = Data()
        func header(_ name: String, _ value: String) {
            headers.append(UInt8(name.utf8.count))
            headers.append(contentsOf: Array(name.utf8))
            headers.append(7)
            let bytes = Array(value.utf8)
            headers.append(UInt8(bytes.count >> 8))
            headers.append(UInt8(bytes.count & 0xFF))
            headers.append(contentsOf: bytes)
        }
        header(":message-type", "event")
        header(":event-type", eventType)
        let total = 12 + headers.count + body.count + 4
        var out = Data()
        func be32(_ value: Int) {
            out.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        be32(total)
        be32(headers.count)
        be32(0)
        out.append(headers)
        out.append(body)
        be32(0)
        return out
    }

    func testNonStringHeadersBeforeEventTypeAreSkippedBySize() {
        let body = try! JSONSerialization.data(withJSONObject: ["content": "hello"])
        var headers = Data()
        func name(_ value: String) {
            headers.append(UInt8(value.utf8.count))
            headers.append(contentsOf: Array(value.utf8))
        }
        name(":message-flags"); headers.append(4); headers.append(contentsOf: [0, 0, 0, 1])
        name(":ok"); headers.append(0)
        name(":date"); headers.append(8); headers.append(contentsOf: [UInt8](repeating: 0, count: 8))
        name(":id"); headers.append(9); headers.append(contentsOf: [UInt8](repeating: 7, count: 16))
        name(":raw"); headers.append(6); headers.append(contentsOf: [0, 2, 0xAB, 0xCD])
        name(":event-type"); headers.append(7)
        let eventType = Array("assistantResponseEvent".utf8)
        headers.append(contentsOf: [UInt8(eventType.count >> 8), UInt8(eventType.count & 0xFF)])
        headers.append(contentsOf: eventType)
        var frame = Data()
        func be32(_ value: Int) {
            frame.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        be32(12 + headers.count + body.count + 4)
        be32(headers.count)
        be32(0)
        frame.append(headers)
        frame.append(body)
        be32(0)

        let frames = KiroDirectProvider.decodeFrames(frame)
        XCTAssertEqual(frames.map(\.eventType), ["assistantResponseEvent"])
        XCTAssertEqual(KiroDirectProvider.assemble(frames: frames).text, "hello")
    }

    private func stream(_ frames: [(String, [String: Any])]) -> KiroDirectProvider.AssembledReply {
        let data = frames.reduce(into: Data()) { $0.append(frame($1.0, $1.1)) }
        return KiroDirectProvider.assemble(frames: KiroDirectProvider.decodeFrames(data))
    }

    func testAssembleReadsContextUsageMetadataReasoningAndMetering() {
        let reply = stream([
            ("reasoningContentEvent", ["text": String(repeating: "r", count: 400)]),
            ("reasoningContentEvent", ["redactedContent": String(repeating: "x", count: 80)]),
            ("assistantResponseEvent", ["content": String(repeating: "a", count: 40)]),
            ("toolUseEvent", ["toolUseId": "t1", "name": "Bash", "input": "{\"command\":"]),
            ("toolUseEvent", ["toolUseId": "t1", "name": "Bash", "input": "\"ls\"}"]),
            ("meteringEvent", ["unit": "credit", "usage": 1]),
            ("meteringEvent", ["unit": "credit", "usage": 0.25]),
            ("contextUsageEvent", ["contextUsagePercentage": 12.5]),
            ("metadataEvent", ["tokenUsage": [
                "uncachedInputTokens": 1_200, "outputTokens": 340,
                "cacheReadInputTokens": 90_000, "cacheWriteInputTokens": 5_000, "totalTokens": 96_540,
            ]]),
        ])
        XCTAssertEqual(reply.text.count, 40)
        XCTAssertEqual(reply.toolCalls.first?.argumentsJSON, "{\"command\":\"ls\"}")
        XCTAssertEqual(reply.credits, 1.25, accuracy: 1e-9)
        XCTAssertTrue(reply.sawMetering)
        XCTAssertEqual(reply.contextUsagePercentage, 12.5)
        XCTAssertEqual(reply.reasoningChars, 480)
        XCTAssertEqual(reply.estimatedOutputTokens, (40 + 480 + 16) / 4, "thinking counts toward output")
        XCTAssertEqual(reply.tokenUsage, KiroDirectProvider.TokenUsage(
            uncachedInput: 1_200, output: 340, cacheRead: 90_000, cacheWrite: 5_000
        ))
    }

    func testMessageMetadataSnakeCaseAndZeroUsageIsIgnored() {
        let zero = stream([
            ("assistantResponseEvent", ["content": "hi"]),
            ("messageMetadataEvent", ["tokenUsage": ["uncachedInputTokens": 0, "outputTokens": 0, "totalTokens": 0]]),
        ])
        XCTAssertNil(zero.tokenUsage, "all-zero metadata is not a usage signal")
        XCTAssertFalse(zero.sawMetering)

        let snake = stream([
            ("messageMetadataEvent", ["usage": [
                "input_tokens": 700, "output_tokens": 50, "cache_read_input_tokens": 300,
                "context_usage_percentage": 3.0,
            ]]),
        ])
        XCTAssertEqual(snake.tokenUsage?.uncachedInput, 400)
        XCTAssertEqual(snake.tokenUsage?.cacheRead, 300)
        XCTAssertEqual(snake.tokenUsage?.output, 50)
        XCTAssertEqual(snake.contextUsagePercentage, 3.0)
    }

    func testUsageFiguresPreferMetadataThenContextPercentThenPayloadBytes() {
        var reply = KiroDirectProvider.AssembledReply()
        reply.text = String(repeating: "o", count: 400)

        let bytes = KiroDirectProvider.usageFigures(reply: reply, payloadBytes: 40_000, contextWindowTokens: 1_000_000)
        XCTAssertEqual(bytes.source, .payloadBytes)
        XCTAssertEqual(bytes.inputTokens, 10_000)
        XCTAssertEqual(bytes.outputTokens, 100)

        reply.contextUsagePercentage = 12.5
        let pct = KiroDirectProvider.usageFigures(reply: reply, payloadBytes: 40_000, contextWindowTokens: 272_000)
        XCTAssertEqual(pct.source, .contextPercentage)
        XCTAssertEqual(pct.inputTokens, 34_000)
        let noWindow = KiroDirectProvider.usageFigures(reply: reply, payloadBytes: 40_000, contextWindowTokens: nil)
        XCTAssertEqual(noWindow.source, .payloadBytes, "no hard-coded window fallback")

        reply.tokenUsage = KiroDirectProvider.TokenUsage(uncachedInput: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        let exact = KiroDirectProvider.usageFigures(reply: reply, payloadBytes: 40_000, contextWindowTokens: 272_000)
        XCTAssertEqual(exact, KiroDirectProvider.UsageFigures(
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 40, source: .kiroMetadata
        ))
    }

    // MARK: - Input estimate from the final payload

    private func anthropicBody(_ messages: [[String: Any]], system: String? = nil, tools: [[String: Any]] = []) -> String {
        var root: [String: Any] = ["model": "kiro/claude-opus-5.5", "max_tokens": 100, "messages": messages]
        if let system { root["system"] = system }
        if !tools.isEmpty { root["tools"] = tools }
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }

    func testInputEstimateCountsToolResultsSchemasAndSystemOnce() {
        let output = String(repeating: "line of shell output\n", count: 2_000)
        let tools: [[String: Any]] = [[
            "name": "Bash", "description": String(repeating: "Run a command. ", count: 200),
            "input_schema": ["type": "object", "properties": ["command": ["type": "string"]]],
        ]]
        let messages: [[String: Any]] = [
            ["role": "user", "content": "list files"],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": output],
            ]],
        ]
        let system = String(repeating: "S", count: 8_000)
        let translated = KiroDirectProvider.translateRequest(
            anthropicBody: anthropicBody(messages, system: system, tools: tools)
        )!
        XCTAssertEqual(translated.upstreamModel, "claude-opus-5.5")

        let payload = KiroDirectProvider.trimHistory(
            in: KiroDirectProvider.requestPayload(conversationState: translated.conversationState),
            systemPrompt: translated.systemPrompt,
            maxBytes: KiroDirectProvider.maxRequestBytes
        )
        let bytes = KiroDirectProvider.payloadByteCount(payload)
        XCTAssertEqual(translated.estimatedInputTokens, bytes / 4)
        XCTAssertGreaterThan(translated.estimatedInputTokens, (output.utf8.count + 3_000) / 4, "tool result and schema are counted")
        XCTAssertLessThan(translated.estimatedInputTokens, (output.utf8.count + 2 * system.utf8.count) / 4, "system prompt counted once")
    }

    func testCountTokensMatchesTrimmedPayloadNotRawHistory() {
        var messages: [[String: Any]] = []
        for index in 0..<40 {
            messages.append(["role": "user", "content": "question \(index) " + String(repeating: "q", count: 40_000)])
            messages.append(["role": "assistant", "content": "answer \(index)"])
        }
        messages.append(["role": "user", "content": "final"])
        let translated = KiroDirectProvider.translateRequest(anthropicBody: anthropicBody(messages))!
        let untrimmed = KiroDirectProvider.payloadByteCount(
            KiroDirectProvider.requestPayload(conversationState: translated.conversationState)
        )
        XCTAssertGreaterThan(untrimmed, KiroDirectProvider.maxRequestBytes)
        XCTAssertLessThanOrEqual(translated.estimatedInputTokens, KiroDirectProvider.maxRequestBytes / 4)
        XCTAssertGreaterThan(translated.estimatedInputTokens, KiroDirectProvider.maxRequestBytes / 8)
    }

    func testRequestPayloadMovesEffortOutOfConversationState() {
        let payload = KiroDirectProvider.requestPayload(conversationState: [
            "chatTriggerType": "MANUAL", "__effort": ["output_config": ["effort": "high"]],
        ])
        let state = payload["conversationState"] as? [String: Any]
        XCTAssertNil(state?["__effort"])
        XCTAssertNotNil(payload["additionalModelRequestFields"])
    }

    // MARK: - Anthropic responses and the ledger row

    func testResponsesCarryMessageIDAndUsage() throws {
        var reply = KiroDirectProvider.AssembledReply()
        reply.text = "hello"
        let usage = KiroDirectProvider.UsageFigures(
            inputTokens: 111, outputTokens: 22, cacheReadTokens: 33, cacheWriteTokens: 4, source: .kiroMetadata
        )
        let json = KiroDirectProvider.anthropicMessageJSON(reply: reply, model: "kiro/claude-opus-5.5", usage: usage, messageID: "msg_test")
        XCTAssertEqual(json["id"] as? String, "msg_test")
        let body = json["usage"] as? [String: Any]
        XCTAssertEqual(body?["input_tokens"] as? Int, 111)
        XCTAssertEqual(body?["output_tokens"] as? Int, 22)
        XCTAssertEqual(body?["cache_read_input_tokens"] as? Int, 33)
        XCTAssertEqual(body?["cache_creation_input_tokens"] as? Int, 4)

        let sse = KiroDirectProvider.anthropicSSE(reply: reply, model: "kiro/claude-opus-5.5", usage: usage, messageID: "msg_test")
        XCTAssertTrue(sse.contains("\"id\":\"msg_test\""))
        XCTAssertTrue(sse.contains("\"input_tokens\":111"))
        XCTAssertTrue(sse.contains("\"output_tokens\":22"))
    }

    func testLedgerEntryRecordsCreditsAccountAndClaudeMessageID() throws {
        var reply = KiroDirectProvider.AssembledReply()
        reply.credits = 1.3125
        reply.sawMetering = true
        reply.contextUsagePercentage = 4
        KiroDirectProvider.rememberUserID("synthetic-user-1", forAccount: "cli-social")
        let usage = KiroDirectProvider.UsageFigures(
            inputTokens: 40_000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0, source: .contextPercentage
        )
        let entry = KiroDirectProvider.ledgerEntry(
            reply: reply,
            delivery: .init(payloadBytes: 123_456, credential: .cliSocial),
            usage: usage,
            upstreamModel: "claude-opus-5.5",
            claudeMessageID: "msg_abc",
            at: Date(timeIntervalSince1970: 1_790_000_000)
        )
        XCTAssertEqual(entry.model, "claude-opus-5.5")
        XCTAssertEqual(entry.credits, 1.3125)
        XCTAssertEqual(entry.account, "cli-social")
        XCTAssertEqual(entry.accountUserHash, KiroDirectProvider.userHash("synthetic-user-1"))
        XCTAssertNotEqual(entry.accountUserHash, "synthetic-user-1")
        XCTAssertEqual(entry.claudeMessageID, "msg_abc")
        XCTAssertEqual(entry.tokenSource, .contextPercentage)
        XCTAssertEqual(entry.contextUsagePercentage, 4)
        XCTAssertEqual(UUID(uuidString: entry.id) != nil, true)

        let unmetered = KiroDirectProvider.ledgerEntry(
            reply: KiroDirectProvider.AssembledReply(),
            delivery: .init(payloadBytes: 10, credential: .authFile("kiro-synthetic.json")),
            usage: usage,
            upstreamModel: "claude-opus-5.5",
            claudeMessageID: "msg_def"
        )
        XCTAssertNil(unmetered.credits, "no meteringEvent is unknown, not zero")
        XCTAssertEqual(unmetered.account, "auth-file:kiro-synthetic.json")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        KiroProxyUsageLedger.append(entry, to: url)
        KiroProxyUsageLedger.append(entry, to: url)
        KiroProxyUsageLedger.append(unmetered, to: url)
        let read = KiroProxyUsageLedger.read(from: url)
        XCTAssertEqual(read.count, 2, "duplicate ids collapse")
        XCTAssertEqual(read.first?.claudeMessageID, "msg_abc")
    }

    func testListModelsKeepsContextWindowAndRate() {
        let json = """
        {"default_model":"auto","models":[
          {"model_name":"gpt-5.6-sol","description":"GPT","model_id":"gpt-5.6-sol","context_window_tokens":272000,"rate_multiplier":2.4,"rate_unit":"Credit"},
          {"model_name":"glm-5","description":"GLM","model_id":"glm-5","rate_unit":"Credit"}
        ]}
        """
        let models = KiroDirectProvider.parseListModelsJSON(Data(json.utf8))
        XCTAssertEqual(models.first?.contextWindowTokens, 272_000)
        XCTAssertEqual(models.first?.rateMultiplier, 2.4)
        XCTAssertNil(models.last?.contextWindowTokens)
    }

    func testReplyPathWindowUsesTheCacheOnlyAndRefreshesOffThePath() {
        KiroDirectProvider.resetCatalogForTesting()
        defer { KiroDirectProvider.resetCatalogForTesting() }
        var scheduled: [() -> Void] = []
        var refreshes = 0
        let refresh = { refreshes += 1 }
        let schedule: (@escaping () -> Void) -> Void = { scheduled.append($0) }

        XCTAssertNil(KiroDirectProvider.contextWindowTokens(forUpstreamID: "glm-5", refresh: refresh, schedule: schedule))
        XCTAssertEqual(refreshes, 0, "the reply path never runs the refresh itself")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertNil(KiroDirectProvider.contextWindowTokens(forUpstreamID: "glm-5", refresh: refresh, schedule: schedule))
        XCTAssertEqual(scheduled.count, 1, "one refresh in flight at a time")
        scheduled.removeFirst()()
        XCTAssertEqual(refreshes, 1)

        let listed = [KiroDirectProvider.CatalogModel(id: "glm-5", blurb: "GLM", contextWindowTokens: 200_000)]
        let fetched = Date()
        KiroDirectProvider.storeCatalog(listed, ttl: 600, at: fetched)
        XCTAssertEqual(KiroDirectProvider.contextWindowTokens(forUpstreamID: "glm-5", now: fetched.addingTimeInterval(10), refresh: refresh, schedule: schedule), 200_000)
        XCTAssertTrue(scheduled.isEmpty, "a fresh cache schedules nothing")
        XCTAssertEqual(KiroDirectProvider.contextWindowTokens(forUpstreamID: "glm-5", now: fetched.addingTimeInterval(900), refresh: refresh, schedule: schedule), 200_000, "a stale window still answers")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(refreshes, 1)
    }

    private func ledgerEntry(_ id: String, at date: Date, account: String? = "cli-social") -> KiroProxyUsageLedger.Entry {
        KiroProxyUsageLedger.Entry(
            id: id, timestamp: date, model: "claude-opus-5.5", credits: 1, inputTokens: 10, outputTokens: 1,
            cacheReadTokens: 0, cacheWriteTokens: 0, tokenSource: .payloadBytes, contextUsagePercentage: nil,
            account: account, accountUserHash: nil, claudeMessageID: nil
        )
    }

    func testLedgerParsesOnlyTheAppendedTailAndTracksTheLatestAccount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        KiroProxyUsageLedger.append(ledgerEntry("a", at: now.addingTimeInterval(-60), account: "auth-file:x.json"), to: url)
        XCTAssertEqual(KiroProxyUsageLedger.read(from: url, now: now).map(\.id), ["a"])
        XCTAssertEqual(KiroProxyUsageLedger.latestAccount(from: url), "auth-file:x.json")

        KiroProxyUsageLedger.append(ledgerEntry("b", at: now), to: url)
        KiroProxyUsageLedger.append(ledgerEntry("c", at: now.addingTimeInterval(-30), account: nil), to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"partial"#.utf8))
        try handle.close()
        XCTAssertEqual(KiroProxyUsageLedger.read(from: url, now: now).map(\.id), ["a", "b", "c"], "a half-written line waits for its newline")
        XCTAssertEqual(KiroProxyUsageLedger.latestAccount(from: url), "cli-social")
        XCTAssertEqual(KiroProxyUsageLedger.read(since: now.addingTimeInterval(-45), from: url, now: now).map(\.id), ["b", "c"])
    }

    func testLedgerCompactionDropsEntriesPastRetention() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let ancient = now.addingTimeInterval(-Double(UsageDailyStore.retentionDays + 5) * 86_400)
        KiroProxyUsageLedger.append(ledgerEntry("old", at: ancient), to: url)
        KiroProxyUsageLedger.append(ledgerEntry("new", at: now), to: url)
        KiroProxyUsageLedger.append(ledgerEntry("new", at: now), to: url)
        XCTAssertEqual(KiroProxyUsageLedger.read(from: url, now: now).map(\.id), ["new"])
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "old and duplicate lines are pruned from the file")
        KiroProxyUsageLedger.append(ledgerEntry("next", at: now), to: url)
        XCTAssertEqual(KiroProxyUsageLedger.read(from: url, now: now).map(\.id), ["new", "next"], "appends after a rewrite are read")
    }

    // MARK: - Credit math and GetUsageLimits

    func testDisabledOverageCapsCeilingAtPlanAndReportsBilledCharges() {
        let slices = KiroCreditMath.slices(
            totalUsed: 7_909.89, planLimit: 50, overageUsed: 7_856.07, overageCap: 10_000,
            overageStatus: "DISABLED", overageChargesUSD: 314.24
        )
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].total, 7_909.89, accuracy: 0.001, "no phantom 10,050 ceiling")
        XCTAssertEqual(slices[0].used, 7_909.89, accuracy: 0.001)
        XCTAssertEqual(slices[1].label, "Overage")
        XCTAssertEqual(slices[1].detail, "$314.24 billed, overage now disabled")
        XCTAssertEqual(slices[1].total, 7_856.07, accuracy: 0.001, "no overage headroom once disabled")

        let enabled = KiroCreditMath.slices(
            totalUsed: 7_909.89, planLimit: 50, overageUsed: 7_856.07, overageCap: 10_000, overageStatus: "ENABLED"
        )
        XCTAssertEqual(enabled[0].total, 10_050, accuracy: 0.001)

        XCTAssertEqual(
            KiroCreditMath.displayPlanName(reported: "KIRO FREE", planLimit: 50, totalUsed: 7_909.89, overageUsed: 7_856.07),
            "KIRO FREE + overage"
        )
        XCTAssertEqual(KiroCreditMath.displayPlanName(reported: "KIRO POWER", planLimit: 10_000, totalUsed: 0.02), "KIRO POWER")
    }

    private func limitsJSON(
        title: String, userID: String, used: Double, limit: Double, overages: Double, cap: Double,
        status: String, charges: Double, freeTrial: [String: Any]? = nil
    ) -> [String: Any] {
        var credit: [String: Any] = [
            "resourceType": "CREDIT", "currentUsageWithPrecision": used, "usageLimitWithPrecision": limit,
            "currentOveragesWithPrecision": overages, "overageCapWithPrecision": cap,
            "overageRate": 0.04, "overageCharges": charges, "currency": "USD", "unit": "INVOCATIONS",
        ]
        if let freeTrial { credit["freeTrialInfo"] = freeTrial }
        return [
            "subscriptionInfo": ["subscriptionTitle": title, "type": "Q_DEVELOPER_STANDALONE"],
            "overageConfiguration": ["overageStatus": status],
            "usageBreakdownList": [credit],
            "nextDateReset": 1_790_812_800,
            "userInfo": ["userId": userID],
        ]
    }

    func testParseKiroLimitsReadsOverageUserAndOptionalBonus() {
        let idc = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO FREE", userID: "user-a", used: 7_909.89, limit: 50, overages: 7_856.07, cap: 10_000,
            status: "DISABLED", charges: 314.24
        ))
        XCTAssertEqual(idc.planName, "KIRO FREE + overage")
        XCTAssertEqual(idc.reportedPlan, "KIRO FREE")
        XCTAssertEqual(idc.userID, "user-a")
        XCTAssertEqual(idc.windows.count, 2)
        XCTAssertEqual(idc.windows[0].label, "KIRO FREE credits")
        XCTAssertEqual(idc.windows[0].remainingValue, 0)
        XCTAssertEqual(idc.windows[0].usedPercent, 100)
        XCTAssertEqual(idc.windows[1].label, "Overage · $314.24 billed, overage now disabled")
        XCTAssertEqual(idc.windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_812_800))
        XCTAssertFalse(idc.windows.contains { $0.label == "Bonus" })

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let trial = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO FREE", userID: "user-c", used: 10, limit: 50, overages: 0, cap: 0,
            status: "DISABLED", charges: 0,
            freeTrial: ["usageLimitWithPrecision": 500, "currentUsageWithPrecision": 125, "daysRemaining": 10]
        ), now: now)
        let bonus = trial.windows.first { $0.label == "Bonus" }
        XCTAssertEqual(bonus?.totalValue, 500)
        XCTAssertEqual(bonus?.remainingValue, 375)
        XCTAssertEqual(bonus?.resetsAt, now.addingTimeInterval(10 * 86_400))
    }

    func testDifferentKiroCLILoginBecomesItsOwnSubAccount() {
        let idc = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO FREE", userID: "user-a", used: 7_909.89, limit: 50, overages: 7_856.07, cap: 10_000,
            status: "DISABLED", charges: 314.24
        ))
        let power = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO POWER", userID: "user-b", used: 0.02, limit: 10_000, overages: 0, cap: 10_000,
            status: "DISABLED", charges: 0
        ))
        XCTAssertFalse(NativeUsageFetcher.kiroSameAccount(idc, power))

        let snapshot = NativeUsageFetcher.kiroSnapshot(
            authAccountID: "kiro-file", providerID: "kiro", email: nil, api: idc, social: power, cliText: nil
        )
        XCTAssertEqual(snapshot.windows.first?.label, "KIRO FREE credits", "card headline stays on the auth file's account")
        XCTAssertEqual(snapshot.planLabel, "KIRO FREE + overage")
        XCTAssertEqual(snapshot.subAccounts.map(\.id), ["kiro-file", NativeUsageFetcher.kiroCLISocialAccountID])
        XCTAssertEqual(snapshot.subAccounts.last?.windows.first?.totalValue, 10_000)

        let samePower = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO POWER", userID: "user-a", used: 0.02, limit: 10_000, overages: 0, cap: 10_000,
            status: "DISABLED", charges: 0
        ))
        XCTAssertTrue(NativeUsageFetcher.kiroSameAccount(idc, samePower), "userId decides, not plan title")
        let merged = NativeUsageFetcher.kiroSnapshot(
            authAccountID: "kiro-file", providerID: "kiro", email: nil, api: idc, social: samePower, cliText: nil
        )
        XCTAssertTrue(merged.subAccounts.isEmpty)

        let authDown = NativeUsageFetcher.kiroSnapshot(
            authAccountID: "kiro-file", providerID: "kiro", email: nil, api: nil, social: power, cliText: nil
        )
        XCTAssertTrue(authDown.windows.isEmpty, "never show the kiro-cli login as this account")
        XCTAssertNotNil(authDown.subAccounts.first?.errorMessage)
        XCTAssertEqual(authDown.subAccounts.last?.title, "KIRO POWER")
    }

    func testBilledNoteFollowsTheLedgersLatestAccount() {
        let idc = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO FREE", userID: "user-a", used: 10, limit: 50, overages: 0, cap: 10_000, status: "DISABLED", charges: 0
        ))
        let power = NativeUsageFetcher.parseKiroLimits(limitsJSON(
            title: "KIRO POWER", userID: "user-b", used: 0.03, limit: 10_000, overages: 0, cap: 10_000, status: "DISABLED", charges: 0
        ))
        func subtitles(_ account: String?) -> [String?] {
            NativeUsageFetcher.kiroSnapshot(
                authAccountID: "kiro-file", providerID: "kiro", email: nil, api: idc, social: power, cliText: nil,
                authFileName: "kiro-idc.json", lastProxyAccount: account
            ).subAccounts.map(\.subtitle)
        }
        let note = " · Claude Code via VibeRouter last billed here"
        XCTAssertEqual(subtitles("auth-file:kiro-idc.json"), ["this login" + note, "kiro-cli login"])
        XCTAssertEqual(subtitles("cli-social"), ["this login", "kiro-cli login" + note])
        XCTAssertEqual(subtitles(nil), ["this login", "kiro-cli login"], "no ledger, no billing claim")
    }

    func testSameAccountFallsBackToArnThenPlan() {
        let a = NativeUsageFetcher.KiroAPIUsage(
            planName: "KIRO PRO", reportedPlan: "KIRO PRO", totalUsed: 1, windows: [], userID: nil, profileArn: "arn:a"
        )
        let b = NativeUsageFetcher.KiroAPIUsage(
            planName: "KIRO PRO", reportedPlan: "KIRO PRO", totalUsed: 1, windows: [], userID: nil, profileArn: "arn:b"
        )
        XCTAssertFalse(NativeUsageFetcher.kiroSameAccount(a, b))
        let c = NativeUsageFetcher.KiroAPIUsage(
            planName: "KIRO PRO", reportedPlan: "KIRO PRO", totalUsed: 1, windows: [], userID: nil, profileArn: nil
        )
        XCTAssertTrue(NativeUsageFetcher.kiroSameAccount(a, c))
    }

    func testCLITextWindowsAreNotClampedAndShowOverage() {
        let cli = KiroCLIUsageSnapshot(
            planName: "KIRO PRO", creditsUsed: 1_250, creditsTotal: 1_000, creditsPercent: 125,
            overageCreditsUsed: 250, estimatedOverageCostUSD: 10, resetsAt: nil, source: "kiro-cli /usage"
        )
        let windows = NativeUsageFetcher.kiroCLIWindows(cli)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].totalValue, 1_250)
        XCTAssertEqual(windows[0].usedPercent, 100)
        XCTAssertEqual(windows[1].label, "Overage · $10.00 billed")
    }

    func testMonthDayResetIsUTCMidnight() {
        let now = ISO8601DateFormatter().date(from: "2026-09-28T18:00:00Z")!
        let reset = KiroCLIUsageProbe.parseResetDate(in: "Estimated Usage | resets on 10/01 | KIRO POWER", now: now)
        XCTAssertEqual(reset, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let iso = KiroCLIUsageProbe.parseResetDate(in: "resets on 2026-10-01", now: now)
        XCTAssertEqual(iso, reset)
    }

    // MARK: - Real local data (VIBE_REAL_DATA=1)

    /// Rebuilds each kiro/ request from Claude Code transcripts (no system prompt or tool schemas) and totals the new estimate.
    func testRealClaudeTranscriptsKiroInputEstimate() throws {
        guard ProcessInfo.processInfo.environment["VIBE_REAL_DATA"] == "1" else { throw XCTSkip("VIBE_REAL_DATA not set") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        var requests = 0, reported = 0, estimated = 0, lastReported = 0, lastEstimated = 0
        for file in files {
            guard let data = try? Data(contentsOf: file), data.range(of: Data("\"model\":\"kiro/".utf8)) != nil else { continue }
            var messages: [[String: Any]] = []
            var seen = Set<String>()
            var lastAssistantID: String?
            for line in data.split(separator: 0x0A) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (row["isSidechain"] as? Bool) != true,
                      let type = row["type"] as? String, type == "user" || type == "assistant",
                      let message = row["message"] as? [String: Any]
                else { continue }
                let blocks: [[String: Any]] = (message["content"] as? [[String: Any]])
                    ?? ((message["content"] as? String).map { [["type": "text", "text": $0]] } ?? [])
                if type == "assistant" {
                    let id = message["id"] as? String ?? UUID().uuidString
                    if let model = message["model"] as? String, model.hasPrefix("kiro/"), seen.insert(id).inserted {
                        let body: [String: Any] = ["model": model, "max_tokens": 32_000, "messages": messages]
                        let json = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
                        if let translated = KiroDirectProvider.translateRequest(anthropicBody: json) {
                            requests += 1
                            lastReported = (message["usage"] as? [String: Any])?["input_tokens"] as? Int ?? 0
                            lastEstimated = translated.estimatedInputTokens
                            reported += lastReported
                            estimated += lastEstimated
                        }
                    }
                    if lastAssistantID == id, var last = messages.popLast() {
                        last["content"] = (last["content"] as? [[String: Any]] ?? []) + blocks
                        messages.append(last)
                    } else {
                        messages.append(["role": "assistant", "content": blocks])
                    }
                    lastAssistantID = id
                } else {
                    messages.append(["role": "user", "content": blocks])
                    lastAssistantID = nil
                }
            }
        }
        print("REAL kiro/ requests \(requests) reported input \(reported) new estimate \(estimated) last \(lastReported) -> \(lastEstimated)")
        XCTAssertGreaterThanOrEqual(estimated, reported)
    }
}
