import XCTest
@testable import CLIProxyMenuBar

final class UsageDailyStoreTests: XCTestCase {
    private func usage(_ providerID: String, model: String = "m", volume: Int, fidelity: DailyUsageFidelity = .exact) -> DailyProviderUsage {
        DailyProviderUsage(
            providerID: providerID,
            models: [DailyModelUsage(
                model: model, inputTokens: volume, outputTokens: 0, cacheReadTokens: 0,
                totalVolume: volume, estimatedCostUSD: Double(volume) / 1_000, requestCount: 1, volumeUnit: .tokens
            )],
            volumeUnit: .tokens,
            fidelity: fidelity
        )
    }

    private func key(_ value: String) -> UsageDayKey { UsageDayKey(value: value) }

    private func epoch(_ day: String) -> Double {
        key(day).date()!.addingTimeInterval(12 * 3600).timeIntervalSince1970
    }

    func testAuthoritativeScanDeletesGhostRowsOnlyInsideCoverage() {
        var days: UsageDailyStore.DayTable = [
            "2026-08-18": ["codex": usage("codex", volume: 1_300)],
            "2026-09-03": ["codex": usage("codex", volume: 128), "grok": usage("grok", volume: 5)],
            "2026-09-20": ["codex": usage("codex", volume: 9)],
            "2026-09-21": ["codex": usage("codex", volume: 1)],
        ]
        var sources: UsageDailyStore.SourceTable = [:]
        let scan = ProviderDailyScan(
            providerID: "codex",
            days: [key("2026-09-21"): usage("codex", volume: 50)],
            coverage: DailyScanCoverage(from: key("2026-08-30"), through: key("2026-09-28"), sources: ["/a": epoch("2026-09-21")])
        )
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { _ in true }
        XCTAssertEqual(days["2026-08-18"]?["codex"]?.totalVolume, 1_300, "out-of-window history must survive")
        XCTAssertNil(days["2026-09-03"]?["codex"])
        XCTAssertEqual(days["2026-09-03"]?["grok"]?.totalVolume, 5, "other providers untouched")
        XCTAssertNil(days["2026-09-20"], "empty day is removed")
        XCTAssertEqual(days["2026-09-21"]?["codex"]?.totalVolume, 50)
        XCTAssertEqual(sources["codex"], ["/a": epoch("2026-09-21")])
    }

    func testNonAuthoritativeScanNeverDeletes() {
        var days: UsageDailyStore.DayTable = ["2026-09-09": ["gemini": usage("gemini", volume: 3_044)]]
        var sources: UsageDailyStore.SourceTable = [:]
        let scan = ProviderDailyScan(providerID: "gemini", days: [:], coverage: nil)
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { _ in true }
        XCTAssertEqual(days["2026-09-09"]?["gemini"]?.totalVolume, 3_044)
    }

    func testEmptySuccessfulScanClearsCoveredDays() {
        var days: UsageDailyStore.DayTable = ["2026-09-16": ["kiro": usage("kiro", volume: 71_210)]]
        var sources: UsageDailyStore.SourceTable = [:]
        let scan = ProviderDailyScan(
            providerID: "kiro", days: [:],
            coverage: DailyScanCoverage(from: key("2026-08-30"), through: key("2026-09-28"))
        )
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { _ in true }
        XCTAssertNil(days["2026-09-16"])
    }

    func testDeletedSourceProtectsItsDaysFromDeletionAndShrinking() {
        var days: UsageDailyStore.DayTable = [
            "2026-09-05": ["claude": usage("claude", volume: 900)],
            "2026-09-06": ["claude": usage("claude", volume: 400)],
            "2026-09-12": ["claude": usage("claude", volume: 7)],
        ]
        var sources: UsageDailyStore.SourceTable = ["claude": ["/gone.jsonl": epoch("2026-09-06"), "/kept.jsonl": epoch("2026-09-12")]]
        let scan = ProviderDailyScan(
            providerID: "claude",
            days: [key("2026-09-05"): usage("claude", volume: 100)],
            coverage: DailyScanCoverage(from: key("2026-08-30"), through: key("2026-09-28"), sources: ["/kept.jsonl": epoch("2026-09-12")])
        )
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { $0 != "/gone.jsonl" }
        XCTAssertEqual(days["2026-09-05"]?["claude"]?.totalVolume, 900, "a partial rescan must not shrink a protected day")
        XCTAssertEqual(days["2026-09-06"]?["claude"]?.totalVolume, 400, "days a deleted log covered are kept")
        XCTAssertNil(days["2026-09-12"], "days after the deleted log's last write are still authoritative")
        XCTAssertEqual(sources["claude"]?["/gone.jsonl"], epoch("2026-09-06"), "deleted in-window source is remembered")
    }

    func testPartialFidelityNeverShrinksStoredRow() {
        var days: UsageDailyStore.DayTable = ["2026-09-20": ["claude": usage("claude", volume: 271)]]
        var sources: UsageDailyStore.SourceTable = [:]
        let partial = ProviderDailyScan(
            providerID: "claude", days: [key("2026-09-20"): usage("claude", volume: 37, fidelity: .partial)], coverage: nil
        )
        UsageDailyStore.merge([partial], into: &days, sources: &sources) { _ in true }
        XCTAssertEqual(days["2026-09-20"]?["claude"]?.totalVolume, 271)
        let exact = ProviderDailyScan(providerID: "claude", days: [key("2026-09-20"): usage("claude", volume: 37)], coverage: nil)
        UsageDailyStore.merge([exact], into: &days, sources: &sources) { _ in true }
        XCTAssertEqual(days["2026-09-20"]?["claude"]?.totalVolume, 37, "an exact scan still replaces")
    }

    func testMigrationToV3() {
        let claudeDay = DailyProviderUsage(
            providerID: "claude",
            models: [
                DailyModelUsage(model: "claude-opus-5.5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                totalVolume: 2, estimatedCostUSD: 14.02, requestCount: 120, volumeUnit: .tokens),
                DailyModelUsage(model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                totalVolume: 2, estimatedCostUSD: 1, requestCount: 1, volumeUnit: .tokens),
            ],
            volumeUnit: .tokens,
            fidelity: .exact
        )
        let kiroOnlyClaude = DailyProviderUsage(
            providerID: "claude",
            models: [DailyModelUsage(model: "claude-opus-5.5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                     totalVolume: 2, estimatedCostUSD: 1, requestCount: 1, volumeUnit: .tokens)],
            volumeUnit: .tokens,
            fidelity: .exact
        )
        let stored: UsageDailyStore.DayTable = [
            "2026-07-01": ["claude": usage("claude", volume: 10), "gemini": usage("gemini", volume: 5), "codex": usage("codex", volume: 3)],
            "2026-09-09": ["gemini": usage("gemini", volume: 3_044), "grok": usage("grok", volume: 1), "codex": usage("codex", volume: 2)],
            "2026-09-27": ["claude": claudeDay, "opencode": usage("opencode", volume: 9)],
            "2026-09-28": ["claude": kiroOnlyClaude],
        ]
        let migrated = UsageDailyStore.migrate(stored, fromVersion: 2, windowStart: key("2026-08-30"))
        XCTAssertEqual(migrated["2026-07-01"]?["claude"]?.totalVolume, 10, "claude history before the transcripts is never dropped")
        XCTAssertEqual(migrated["2026-07-01"]?["gemini"]?.totalVolume, 5, "out-of-window rows are kept")
        XCTAssertNil(migrated["2026-09-09"]?["gemini"])
        XCTAssertNil(migrated["2026-09-09"]?["grok"])
        XCTAssertEqual(migrated["2026-09-09"]?["codex"]?.totalVolume, 2, "codex waits for the full rebuild")
        XCTAssertEqual(migrated["2026-09-27"]?["claude"]?.models.map(\.model), ["claude-opus-5-5"])
        XCTAssertNil(migrated["2026-09-27"]?["opencode"])
        XCTAssertNil(migrated["2026-09-28"])

        let fromV1 = UsageDailyStore.migrate(stored, fromVersion: 1, windowStart: key("2026-08-30"))
        XCTAssertNil(fromV1["2026-07-01"]?["claude"])
        XCTAssertEqual(UsageDailyStore.migrate(stored, fromVersion: 3, windowStart: key("2026-08-30")), stored)
    }

    func testKiroProxyModelDetection() {
        XCTAssertTrue(UsageDailyStore.isKiroProxyModel("claude-opus-5.5"))
        XCTAssertTrue(UsageDailyStore.isKiroProxyModel("kiro/claude-sonnet-4.5"))
        XCTAssertFalse(UsageDailyStore.isKiroProxyModel("claude-opus-5-5"))
        XCTAssertFalse(UsageDailyStore.isKiroProxyModel("claude-fable-5-1"))
        XCTAssertFalse(UsageDailyStore.isKiroProxyModel("claude-opus-4.8", inWindow: false), "pre-window dotted rows predate the proxy")
        XCTAssertTrue(UsageDailyStore.isKiroProxyModel("kiro/claude-opus-4.8", inWindow: false))
    }

    private func claudeRow(_ model: String, volume: Int, cost: Double, requests: Int) -> DailyProviderUsage {
        DailyProviderUsage(
            providerID: "claude",
            models: [DailyModelUsage(model: model, inputTokens: volume, outputTokens: 0, cacheReadTokens: 0,
                                     totalVolume: volume, estimatedCostUSD: cost, requestCount: requests, volumeUnit: .tokens)],
            volumeUnit: .tokens,
            fidelity: .exact
        )
    }

    func testMigrationDropsDayShiftedClaudeGhostsAndFlagsLegacyRows() {
        let ghost = claudeRow("claude-opus-5-5", volume: 16_770_000, cost: 51.78, requests: 90)
        let dotted = claudeRow("claude-opus-4.8", volume: 27_078_643, cost: 135.71, requests: 40)
        let stored: UsageDailyStore.DayTable = [
            "2026-08-13": ["claude": claudeRow("claude-opus-5-5", volume: 16_770_000, cost: 51.78 + 1e-11, requests: 90)],
            "2026-08-14": ["claude": ghost],
            "2026-08-20": ["claude": dotted],
            "2026-08-22": ["claude": claudeRow("claude-opus-5-5", volume: 500, cost: 1, requests: 2)],
            "2026-08-23": ["claude": claudeRow("claude-opus-5-5", volume: 501, cost: 1, requests: 2)],
            "2026-09-10": ["claude": dotted],
        ]
        let migrated = UsageDailyStore.migrate(stored, fromVersion: 2, windowStart: key("2026-08-30"))
        XCTAssertNil(migrated["2026-08-13"], "the earlier copy of an identical consecutive pair is the ghost")
        XCTAssertEqual(migrated["2026-08-14"]?["claude"]?.totalVolume, 16_770_000)
        XCTAssertEqual(migrated["2026-08-14"]?["claude"]?.fidelity, .legacy)
        XCTAssertEqual(migrated["2026-08-20"]?["claude"]?.models.map(\.model), ["claude-opus-4.8"], "old dotted rows are not Kiro")
        XCTAssertEqual(migrated["2026-08-22"]?["claude"]?.totalVolume, 500, "different neighbours are both kept")
        XCTAssertNil(migrated["2026-09-10"], "in-window dotted rows are Kiro proxy traffic the rescan rebuilds")
        XCTAssertEqual(DailyUsageFidelity.legacy.caveat, "from an older build, unverified")
        XCTAssertTrue(DailyUsageFidelity.legacy.isApproximate)
    }

    func testMigrationRebuildsEveryProviderWhoseSourcesSurvive() {
        XCTAssertTrue(UsageDailyStore.fullRescanProvidersOnMigration.isSuperset(of: ["codex", "kiro", "claude", "gemini", "antigravity", "opencode"]))
        XCTAssertTrue(UsageDailyStore.fullRescanProvidersOnMigration.contains("grok"), "day-shifted pre-window Grok rows are rebuilt from surviving sessions")
    }

    private func storeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func v2File(_ days: [String: [String: DailyProviderUsage]]) throws -> Data {
        let payload: [String: Any] = [
            "version": 2,
            "updatedAt": 0,
            "days": try JSONSerialization.jsonObject(with: JSONEncoder().encode(days)),
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func testMigrationBacksUpTheV2FileOnceBeforeTheFirstV3Write() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage-daily.json")
        let original = try v2File(["2026-07-01": ["claude": usage("claude", volume: 10)]])
        try original.write(to: url)
        let windowStart = key("2026-08-31")

        let state = try XCTUnwrap(UsageDailyStore.loadState(at: url, windowStart: windowStart))
        XCTAssertTrue(state.needsWrite)
        XCTAssertTrue(state.pendingFullRescan.contains("grok"))
        let backup = UsageDailyStore.backupURL(for: url)
        XCTAssertEqual(backup.lastPathComponent, "usage-daily.v2.bak.json")
        XCTAssertEqual(try Data(contentsOf: backup), original, "byte-for-byte copy of the v2 file")

        UsageDailyStore.writeForTesting(state, to: url)
        try v2File(["2026-09-10": ["codex": usage("codex", volume: 3)]]).write(to: url)
        _ = UsageDailyStore.loadState(at: url, windowStart: windowStart)
        XCTAssertEqual(try Data(contentsOf: backup), original, "an existing backup is never overwritten")
    }

    func testOlderBuildOverwriteGetsLegacyRowsBackFromTheBackup() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage-daily.json")
        let legacy = usage("claude", volume: 16_770_000)
        try v2File(["2026-07-01": ["claude": legacy], "2026-09-10": ["codex": usage("codex", volume: 5)]])
            .write(to: UsageDailyStore.backupURL(for: url))
        try v2File(["2026-09-12": ["codex": usage("codex", volume: 8)]]).write(to: url)

        let state = try XCTUnwrap(UsageDailyStore.loadState(at: url, windowStart: key("2026-08-31")))
        XCTAssertEqual(state.days["2026-07-01"]?["claude"]?.totalVolume, 16_770_000, "pre-window rows no scan can rebuild come back")
        XCTAssertEqual(state.days["2026-07-01"]?["claude"]?.fidelity, .legacy)
        XCTAssertNil(state.days["2026-09-10"], "in-window rows are left to the rescans")
        XCTAssertEqual(state.days["2026-09-12"]?["codex"]?.totalVolume, 8)
    }

    func testUnreadableOrUnknownVersionStoreFallsBackToTheBackup() throws {
        let dir = try storeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage-daily.json")
        let backup = UsageDailyStore.backupURL(for: url)
        let saved = try v2File(["2026-07-01": ["claude": usage("claude", volume: 42)]])
        try saved.write(to: backup)

        for corrupt in [Data("{not json".utf8), try JSONSerialization.data(withJSONObject: ["version": 99, "updatedAt": 0, "days": [:]])] {
            try corrupt.write(to: url)
            let state = try XCTUnwrap(UsageDailyStore.loadState(at: url, windowStart: key("2026-08-31")))
            XCTAssertEqual(state.days["2026-07-01"]?["claude"]?.totalVolume, 42)
            XCTAssertEqual(try Data(contentsOf: backup), saved, "the backup is kept")
        }
        try FileManager.default.removeItem(at: backup)
        XCTAssertNil(UsageDailyStore.loadState(at: url, windowStart: key("2026-08-31")))
    }

    func testMovedSourceIsRescannedAtItsNewPathAndStopsProtecting() {
        var days: UsageDailyStore.DayTable = [
            "2026-09-03": ["codex": usage("codex", volume: 128)],
            "2026-09-10": ["codex": usage("codex", volume: 5)],
        ]
        var sources: UsageDailyStore.SourceTable = ["codex": ["/sessions/rollout-a.jsonl": epoch("2026-09-10")]]
        let scan = ProviderDailyScan(
            providerID: "codex",
            days: [key("2026-09-10"): usage("codex", volume: 5)],
            coverage: DailyScanCoverage(from: key("2026-08-31"), through: key("2026-09-29"),
                                        sources: ["/archived_sessions/rollout-a.jsonl": epoch("2026-09-10")])
        )
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { $0.hasPrefix("/archived") }
        XCTAssertNil(days["2026-09-03"], "the ghost row is cleaned up once the moved file was rescanned")
        XCTAssertEqual(sources["codex"]?.keys.sorted(), ["/archived_sessions/rollout-a.jsonl"])
    }

    func testMissingGenericallyNamedSourceStillProtects() {
        var days: UsageDailyStore.DayTable = ["2026-09-03": ["grok": usage("grok", volume: 77)]]
        var sources: UsageDailyStore.SourceTable = ["grok": ["/s/a/usage.json": epoch("2026-09-05"), "/s/b/usage.json": epoch("2026-09-06")]]
        let scan = ProviderDailyScan(
            providerID: "grok", days: [:],
            coverage: DailyScanCoverage(from: key("2026-08-31"), through: key("2026-09-29"),
                                        sources: ["/s/b/usage.json": epoch("2026-09-06")])
        )
        UsageDailyStore.merge([scan], into: &days, sources: &sources) { $0 == "/s/b/usage.json" }
        XCTAssertEqual(days["2026-09-03"]?["grok"]?.totalVolume, 77, "a deleted usage.json is not mistaken for a moved one")
    }

    func testDailyModelUsageDecodesRowsWithoutCacheWrite() throws {
        let legacy = #"{"model":"m","inputTokens":1,"outputTokens":2,"cacheReadTokens":3,"totalVolume":6,"estimatedCostUSD":0.5,"requestCount":1,"volumeUnit":"tokens"}"#
        let decoded = try JSONDecoder().decode(DailyModelUsage.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.cacheWriteTokens, 0)
        var withWrite = decoded
        withWrite.cacheWriteTokens = 9
        let roundTrip = try JSONDecoder().decode(DailyModelUsage.self, from: JSONEncoder().encode(withWrite))
        XCTAssertEqual(roundTrip, withWrite)
    }
}
