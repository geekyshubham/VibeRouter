import XCTest
@testable import CLIProxyMenuBar

final class UsageIntegrationWiringTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    private func row(_ model: String, volume: Int, unit: UsageVolumeUnit, cacheWrite: Int = 0) -> DailyModelUsage {
        DailyModelUsage(
            model: model, inputTokens: volume, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: cacheWrite,
            totalVolume: volume, estimatedCostUSD: 0, requestCount: unit == .credits ? 1 : 0, volumeUnit: unit
        )
    }

    func testCompleteAggregatorScanIsAuthoritativeForItsWindow() {
        let scan = LocalDailyUsageScan(providerID: "grok", days: [:], cutoffStart: now.addingTimeInterval(-86_400 * 29), now: now, isComplete: true)
        let daily = LocalTokenCostScanner.providerDailyScan(scan)
        XCTAssertTrue(daily.isAuthoritative)
        XCTAssertEqual(daily.coverage?.from, scan.coveredFrom)
        XCTAssertEqual(daily.coverage?.through, scan.coveredThrough)
    }

    func testAggregatorScanSourcesProtectADeletedConversationDB() {
        let day = UsageDayKey(value: "2026-09-05")
        let dbWrite = day.date()!.addingTimeInterval(43_200).timeIntervalSince1970
        let usage = DailyProviderUsage(providerID: "antigravity", models: [row("gemini-3.8-flash", volume: 156, unit: .tokens)],
                                       volumeUnit: .tokens, fidelity: .exact)
        var days: UsageDailyStore.DayTable = [:]
        var sources: UsageDailyStore.SourceTable = [:]
        let cutoff = now.addingTimeInterval(-86_400 * 29)
        let first = LocalTokenCostScanner.providerDailyScan(LocalDailyUsageScan(
            providerID: "antigravity", days: [day: usage], cutoffStart: cutoff, now: now, isComplete: true,
            sources: ["/conv/a.db": dbWrite], oldestSource: Date(timeIntervalSince1970: dbWrite - 86_400 * 60)
        ))
        UsageDailyStore.merge([first], into: &days, sources: &sources) { _ in true }
        let afterDelete = LocalTokenCostScanner.providerDailyScan(LocalDailyUsageScan(
            providerID: "antigravity", days: [:], cutoffStart: cutoff, now: now, isComplete: true,
            sources: [:], oldestSource: Date(timeIntervalSince1970: dbWrite - 86_400 * 60)
        ))
        UsageDailyStore.merge([afterDelete], into: &days, sources: &sources) { _ in false }
        XCTAssertEqual(days[day.value]?["antigravity"]?.totalVolume, 156, "history of a deleted conversation DB survives")
        XCTAssertEqual(sources["antigravity"]?["/conv/a.db"], dbWrite)
    }

    func testAggregatorCoverageStartsAfterTheOldestSurvivingSource() {
        let oldest = now.addingTimeInterval(-86_400 * 3)
        let scan = LocalDailyUsageScan(providerID: "grok", days: [:], cutoffStart: now.addingTimeInterval(-86_400 * 29), now: now,
                                       isComplete: true, oldestSource: oldest)
        let dayAfter = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: oldest))!
        XCTAssertEqual(scan.coveredFrom, UsageDayKey(date: dayAfter))
    }

    func testIncompleteAggregatorScanNeverDeletes() {
        let scan = LocalDailyUsageScan(providerID: "opencode", days: [:], cutoffStart: now, now: now, isComplete: false)
        XCTAssertFalse(LocalTokenCostScanner.providerDailyScan(scan).isAuthoritative)
    }

    func testCreditProviderVolumeIgnoresEstimatedTokenRows() {
        let kiro = DailyProviderUsage(
            providerID: "kiro",
            models: [row("claude-opus-5", volume: 2_500, unit: .credits), row("claude-opus-5 (est. upper bound)", volume: 9_000_000, unit: .estimatedTokens)],
            volumeUnit: .credits,
            fidelity: .exact
        )
        XCTAssertEqual(kiro.totalVolume, 2_500)

        let grok = DailyProviderUsage(
            providerID: "grok",
            models: [row("grok-4.6", volume: 1_000, unit: .tokens), row("grok-4.6 (est.)", volume: 300, unit: .estimatedTokens)],
            volumeUnit: .tokens,
            fidelity: .sessionApproximate
        )
        XCTAssertEqual(grok.totalVolume, 1_000, "estimates never join a provider's exact volume")
        XCTAssertEqual(grok.estimatedTokenVolume, 300)
        XCTAssertEqual(kiro.estimatedTokenVolume, 9_000_000)

        let cursor = DailyProviderUsage(
            providerID: "cursor", models: [row("composer-2.5", volume: 700, unit: .estimatedTokens)],
            volumeUnit: .estimatedTokens, fidelity: .sessionApproximate
        )
        let summary = DailyUsageSummary(day: UsageDayKey(value: "2026-09-28"), providers: [kiro, grok, cursor])
        XCTAssertEqual(summary.totalTokens, 1_000, "exact tokens only")
        XCTAssertEqual(summary.totalEstimatedTokens, 9_001_000, "Kiro, Grok and Cursor estimates, labelled apart")
        XCTAssertEqual(UsageNumberFormatter.tokens(summary.totalTokens, estimated: summary.totalEstimatedTokens), "1K +9M est")
        XCTAssertEqual(UsageNumberFormatter.tokens(0, estimated: 700), "700 est")
        XCTAssertEqual(UsageNumberFormatter.tokens(1_000, estimated: 0), "1K")
    }

    func testOverviewMergeKeepsCacheWrites() {
        func snapshot(_ provider: String, cacheWrite: Int) -> ProviderCostSnapshot {
            ProviderCostSnapshot.make(
                providerID: provider, sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: 100 + cacheWrite, last30DaysCostUSD: 1,
                models: [ModelTokenUsage(
                    model: "glm-5.3", inputTokens: 100, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: cacheWrite,
                    totalTokens: 100 + cacheWrite, estimatedCostUSD: 1, requestCount: 1
                )]
            )
        }
        let overview = AnalyticsEngine.overview(from: [snapshot("opencode", cacheWrite: 40), snapshot("claude", cacheWrite: 60)], now: now)
        let merged = overview.topModels.first { $0.model == "glm-5.3" }
        XCTAssertEqual(merged?.cacheWriteTokens, 100)
        XCTAssertEqual(merged?.inputTokens, 200)
    }
}
