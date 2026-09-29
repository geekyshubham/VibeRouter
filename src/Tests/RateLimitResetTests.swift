import XCTest
@testable import CLIProxyMenuBar

final class RateLimitResetTests: XCTestCase {
    // MARK: - Capability gating

    func testResetBankSupportedProviders() {
        XCTAssertTrue(RateLimitResetService.supports(.codex))
        XCTAssertTrue(RateLimitResetService.supports(.grok))
        XCTAssertTrue(RateLimitResetService.supports(.claude))
        XCTAssertFalse(RateLimitResetService.supports(.gemini))
        XCTAssertFalse(RateLimitResetService.supports(.copilot))
        XCTAssertFalse(RateLimitResetService.supports(.kiro))
        XCTAssertFalse(RateLimitResetService.supports(.zai))
    }

    // MARK: - Bank model

    func testRateLimitResetBankSummaryLine() {
        let future = Date().addingTimeInterval(86_400 * 14)
        let single = RateLimitResetBank(availableCount: 1, nextExpiresAt: future)
        XCTAssertTrue(single.summaryLine.hasPrefix("1 rate-limit reset left"))
        XCTAssertTrue(single.summaryLine.contains("next expires"))

        let many = RateLimitResetBank(availableCount: 3)
        XCTAssertTrue(many.summaryLine.contains("3 rate-limit resets left"))

        let empty = RateLimitResetBank(availableCount: 0)
        XCTAssertEqual(empty.summaryLine, "No rate-limit resets left")
        XCTAssertFalse(empty.summaryLine.contains("next expires"))
    }

    // MARK: - Codex credits parsing

    func testParseCodexCreditsFiltersUnavailableAndExpired() {
        let json: [String: Any] = [
            "credits": [
                [
                    "id": "RateLimitResetCredit_abc",
                    "status": "available",
                    "title": "Full reset (Weekly + 5 hr)",
                    "expires_at": Self.iso(Date().addingTimeInterval(86_400)),
                ],
                [
                    "id": "RateLimitResetCredit_old",
                    "status": "available",
                    "expires_at": Self.iso(Date().addingTimeInterval(-3_600)),
                ],
                [
                    "id": "RateLimitResetCredit_spent",
                    "status": "redeemed",
                    "expires_at": Self.iso(Date().addingTimeInterval(86_400)),
                ],
            ]
        ]
        let credits = NativeUsageFetcher.parseCodexCredits(json: json)
        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits[0].id, "RateLimitResetCredit_abc")
        XCTAssertEqual(credits[0].title, "Full reset (Weekly + 5 hr)")
        XCTAssertNotNil(credits[0].expiresAt)
    }

    // MARK: - Grok gRPC-web parsing

    func testParseGrokRemainingResetsReadsTokensAndFiltersExpired() throws {
        let now = Date()
        let future = UInt64(now.addingTimeInterval(86_400 * 20).timeIntervalSince1970)
        let past = UInt64(now.addingTimeInterval(-86_400).timeIntervalSince1970)

        var live = Data()
        live.append(contentsOf: [0x52]) // field 10 (token_id), wire type 2
        live.appendProtoVarint("ConsumerResetToken_live".utf8.count)
        live.append(contentsOf: "ConsumerResetToken_live".utf8)
        live.append(contentsOf: [0xF2, 0x01]) // field 30 (validity_end), wire type 2
        live.appendProtoVarint(Self.timestampMessage(future).count)
        live.append(Self.timestampMessage(future))

        var expired = Data()
        expired.append(contentsOf: [0x52])
        expired.appendProtoVarint("tok_expired".utf8.count)
        expired.append(contentsOf: "tok_expired".utf8)
        expired.append(contentsOf: [0xF2, 0x01])
        expired.appendProtoVarint(Self.timestampMessage(past).count)
        expired.append(Self.timestampMessage(past))

        var response = Data()
        for token in [live, expired] {
            response.append(contentsOf: [0x52]) // repeated field 10 (tokens)
            response.appendProtoVarint(token.count)
            response.append(token)
        }

        let data = Self.grpcWebDataFrame(response)
        let tokens = RateLimitResetService.parseGrokRemainingResets(data, now: now)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.tokenID, "ConsumerResetToken_live")
        XCTAssertNotNil(tokens.first?.validUntil)
        XCTAssertTrue(abs((tokens.first!.validUntil!.timeIntervalSince(now)) - 86_400 * 20) < 5)
    }

    func testParseGrokRemainingResetsHandlesEmptyResponse() {
        let empty = Data([0x00, 0x00, 0x00, 0x00, 0x00]) // data frame with empty message
        let tokens = RateLimitResetService.parseGrokRemainingResets(empty)
        XCTAssertTrue(tokens.isEmpty)
    }

    func testGrokRedeemRequestBodyShape() {
        let body = RateLimitResetService.grokRedeemRequestBody(tokenID: "abc")
        // Frame header: flag 0 + big-endian payload length
        XCTAssertEqual(body.prefix(1), Data([0x00]))
        let expectedLength = Int(body[1]) << 24 | Int(body[2]) << 16 | Int(body[3]) << 8 | Int(body[4])
        let payload = body.dropFirst(5)
        XCTAssertEqual(payload.count, expectedLength)
        // ConsumerRedeemResetReq{token_id = 10}: tag 0x52, length, utf8 bytes
        XCTAssertEqual(payload.first, 0x52)
        XCTAssertEqual(Int(payload.dropFirst().first!), "abc".utf8.count)
        XCTAssertEqual(Data(payload.dropFirst(2)), Data("abc".utf8))
    }

    // MARK: - Claude resets

    func testClaudeCedarGrantIsBankedAndSpendable() {
        let inventory = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": true,
                "grants": [[
                    "id": "opus55",
                    "label": "Get extra wiggle room to explore Opus 5.5",
                    "resets_left": 1,
                    "ends_at": Self.iso(Date().addingTimeInterval(86_400 * 20)),
                    "usable_now": true,
                    "clears": ["five_hour", "seven_day"],
                ]],
                "next_grant_id": "opus55",
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: true
        )
        XCTAssertEqual(inventory?.bank.availableCount, 1)
        XCTAssertEqual(inventory?.bank.canRedeem, true)
        XCTAssertEqual(inventory?.offer?.id, "opus55")
        XCTAssertEqual(inventory?.offer?.program, .cedar)
        XCTAssertEqual(inventory?.bank.sampleTitle, "Get extra wiggle room to explore Opus 5.5")
        XCTAssertNotNil(RateLimitResetService.claudeBankForDisplay(inventory!))
    }

    func testClaudeCedarIgnoresSpentPausedAndExpiredGrants() {
        let inventory = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": true,
                "grants": [
                    ["id": "spent", "resets_left": 0, "usable_now": true],
                    ["id": "paused", "resets_left": 1, "paused": true, "usable_now": true],
                    [
                        "id": "expired",
                        "resets_left": 1,
                        "usable_now": true,
                        "ends_at": Self.iso(Date().addingTimeInterval(-3600)),
                    ],
                    [
                        "id": "saved",
                        "resets_left": 2,
                        "usable_now": false,
                        "use_requires_limit": true,
                        "ends_at": Self.iso(Date().addingTimeInterval(86_400)),
                        "clears": ["five_hour"],
                    ],
                ],
                "next_grant_id": "saved",
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: true
        )
        XCTAssertEqual(inventory?.bank.availableCount, 2)
        XCTAssertNil(inventory?.offer)
        XCTAssertEqual(inventory?.bank.canRedeem, false)
        XCTAssertEqual(inventory?.bank.sampleTitle, "Saved until you reach a usage limit")
    }

    func testClaudeSurfaceBlindGrantIsNotAFalseZero() {
        let inventory = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": false,
                "ineligible_reason": "surface",
                "grants": [],
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: true
        )
        XCTAssertEqual(inventory?.surfaceBlind, true)
        XCTAssertEqual(inventory?.bank.availableCount, 0)
        let shown = inventory.flatMap(RateLimitResetService.claudeBankForDisplay)
        XCTAssertEqual(shown?.surfaceOnly, true)
        XCTAssertEqual(shown?.canRedeem, false)
        XCTAssertEqual(shown?.summaryLine, "Reset for free is on claude.ai")
    }

    func testClaudeWallGrantIsShownWhenAnytimeReadIsSurfaceBlind() {
        let anytime = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": false,
                "ineligible_reason": "surface",
                "grants": [],
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: false
        )
        let wall = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": true,
                "next_grant_id": "opus55",
                "grants": [[
                    "id": "opus55",
                    "resets_left": 1,
                    "usable_now": true,
                    "clears": ["five_hour", "seven_day"],
                ]],
            ],
            cedarReached: true,
            juniperField: ["eligible": true, "arm": "reset", "available": true],
            juniperReached: true
        )
        let chosen = RateLimitResetService.preferClaudeResetInventory(anytime: anytime, atWall: wall)
        XCTAssertEqual(chosen?.offer?.program, .cedar)
        XCTAssertEqual(chosen?.offer?.id, "opus55")
        XCTAssertEqual(chosen?.bank.canRedeem, true)
        XCTAssertEqual(chosen?.bank.availableCount, 2)
        XCTAssertNotNil(chosen.flatMap(RateLimitResetService.claudeBankForDisplay))
    }

    func testClaudeSurfaceBlindAnytimeStaysHiddenWhenWallIsEmpty() {
        let anytime = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": false,
                "ineligible_reason": "surface",
                "grants": [],
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: false
        )
        let wall = RateLimitResetService.parseClaudeResetInventory(
            cedarField: ["eligible": false, "grants": []],
            cedarReached: true,
            juniperField: nil,
            juniperReached: true
        )
        let chosen = RateLimitResetService.preferClaudeResetInventory(anytime: anytime, atWall: wall)
        XCTAssertEqual(chosen?.surfaceBlind, true)
        XCTAssertEqual(chosen.flatMap(RateLimitResetService.claudeBankForDisplay)?.surfaceOnly, true)
    }

    func testClaudeSavedGrantStillDisplaysWhenItCannotBeSpentYet() {
        let anytime = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": true,
                "next_grant_id": "saved",
                "grants": [[
                    "id": "saved",
                    "resets_left": 1,
                    "usable_now": false,
                    "use_requires_limit": true,
                    "clears": ["five_hour"],
                ]],
            ],
            cedarReached: true,
            juniperField: nil,
            juniperReached: false
        )
        let wall = RateLimitResetService.parseClaudeResetInventory(
            cedarField: ["eligible": false, "grants": []],
            cedarReached: true,
            juniperField: nil,
            juniperReached: true
        )
        let chosen = RateLimitResetService.preferClaudeResetInventory(anytime: anytime, atWall: wall)
        XCTAssertEqual(chosen?.bank.availableCount, 1)
        XCTAssertEqual(chosen?.bank.canRedeem, false)
        XCTAssertNotNil(chosen.flatMap(RateLimitResetService.claudeBankForDisplay))
    }

    func testClaudeJuniperSessionResetIsOfferedAndCedarWinsWhenBothExist() {
        let juniperOnly = RateLimitResetService.parseClaudeResetInventory(
            cedarField: nil,
            cedarReached: true,
            juniperField: [
                "eligible": true,
                "arm": "reset",
                "available": true,
            ],
            juniperReached: true
        )
        XCTAssertEqual(juniperOnly?.bank.availableCount, 1)
        XCTAssertEqual(juniperOnly?.offer?.program, .juniper)
        XCTAssertEqual(juniperOnly?.bank.sampleTitle, "Session limit reset")

        let both = RateLimitResetService.parseClaudeResetInventory(
            cedarField: [
                "eligible": true,
                "next_grant_id": "grant1",
                "grants": [[
                    "id": "grant1",
                    "resets_left": 1,
                    "usable_now": true,
                    "clears": ["seven_day"],
                ]],
            ],
            cedarReached: true,
            juniperField: ["eligible": true, "arm": "reset", "available": true],
            juniperReached: true
        )
        XCTAssertEqual(both?.bank.availableCount, 2)
        XCTAssertEqual(both?.offer?.program, .cedar)
        XCTAssertEqual(both?.bank.sampleTitle, "Weekly limit reset")
    }

    func testClaudeResetProbesThatFailDoNotInventAnEmptyBank() {
        XCTAssertNil(
            RateLimitResetService.parseClaudeResetInventory(
                cedarField: nil,
                cedarReached: false,
                juniperField: nil,
                juniperReached: false
            )
        )
        XCTAssertNil(
            RateLimitResetService.parseClaudeResetInventory(
                cedarField: nil,
                cedarReached: false,
                juniperField: ["eligible": false, "arm": "reset", "available": false],
                juniperReached: true
            )
        )
    }

    func testClaudeRedeemResultMessages() {
        let reset = RateLimitResetService.claudeRedeemResult(
            "reset",
            program: .cedar,
            cleared: ["five_hour", "seven_day"]
        )
        guard case .success(let message) = reset else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(message.contains("session and weekly limits"))

        let session = RateLimitResetService.claudeRedeemResult("reset", program: .juniper, cleared: [])
        guard case .success(let sessionMessage) = session else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(sessionMessage.contains("weekly limit still applies"))

        let held = RateLimitResetService.claudeRedeemResult("not_limited", program: .cedar, cleared: [])
        guard case .failure(let heldMessage) = held else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(heldMessage.contains("Nothing was consumed"))
    }

    func testGrokGRPCFailureDetectsTrailerStatus() {
        let trailer = Self.grpcWebTrailerFrame(Data("grpc-status:16\r\ngrpc-message:no-credentials".utf8))
        let failure = RateLimitResetService.grokGRPCFailure(trailer)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure!.contains("grpc 16"))

        let ok = Self.grpcWebTrailerFrame(Data("grpc-status:0\r\n".utf8))
        XCTAssertNil(RateLimitResetService.grokGRPCFailure(ok))
    }

    // MARK: - Helpers

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// google.protobuf.Timestamp{seconds = 1}.
    private static func timestampMessage(_ seconds: UInt64) -> Data {
        var out = Data([0x08])
        var value = seconds
        while true {
            if value < 0x80 {
                out.append(UInt8(value))
                break
            }
            out.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        return out
    }

    private static func grpcWebDataFrame(_ payload: Data) -> Data {
        var out = Data([0x00])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    private static func grpcWebTrailerFrame(_ payload: Data) -> Data {
        var out = Data([0x80])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}
