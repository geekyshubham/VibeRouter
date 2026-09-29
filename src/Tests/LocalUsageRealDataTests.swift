import XCTest
@testable import CLIProxyMenuBar

/// Prints scanner totals over this Mac's real logs. Opt-in (`VIBE_REAL_DATA=1`), read-only.
final class LocalUsageRealDataTests: XCTestCase {
    override func tearDown() {
        RemotePricingCatalog.replaceRatesForTesting([:])
        super.tearDown()
    }

    func testPrintRealDataTotals() throws {
        guard ProcessInfo.processInfo.environment["VIBE_REAL_DATA"] == "1" else { return }
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeRouter/pricing-cache.json")
        if let data = try? Data(contentsOf: cache), let decoded = RemotePricingCatalog.decodeCache(data) {
            RemotePricingCatalog.replaceRatesForTesting(decoded.rates)
        }

        let now = Date()
        for type in [ServiceType.claude, .codex, .gemini] {
            let started = Date()
            let days = LocalTokenCostScanner.dailyUsage(for: type, now: now, historyDays: 30) ?? [:]
            let elapsed = Date().timeIntervalSince(started)
            let models = days.values.flatMap(\.models)
            let tokens = models.reduce(0) { $0 + $1.totalVolume }
            let cost = models.reduce(0) { $0 + $1.estimatedCostUSD }
            let requests = models.reduce(0) { $0 + $1.requestCount }
            print(String(format: "REAL %@ window=30d requests=%d tokens=%.1fM cost=$%.2f scan=%.1fs", type.rawValue, requests, Double(tokens) / 1e6, cost, elapsed))
            for key in days.keys.sorted() {
                let rows = days[key]!.models
                print(String(format: "REAL %@ %@ tokens=%.1fM cost=$%.2f", type.rawValue, key.value,
                             Double(rows.reduce(0) { $0 + $1.totalVolume }) / 1e6, rows.reduce(0) { $0 + $1.estimatedCostUSD }))
            }
        }

        let kiro = LocalTokenCostScanner.kiroProxyEntriesFromClaudeLogs(since: analyticsCutoffStart(now: now, historyDays: 30))
        print("REAL kiro-from-claude entries=\(kiro.count) input=\(kiro.reduce(0) { $0 + $1.inputTokens }) output=\(kiro.reduce(0) { $0 + $1.outputTokens })")

        let full = LocalTokenCostScanner.fullHistoryDailyScans(providers: ["codex"], now: now)
        for scan in full {
            for day in ["2026-08-02", "2026-08-10", "2026-08-13", "2026-08-18", "2026-08-19"] {
                let rows = scan.days[UsageDayKey(value: day)]?.models ?? []
                print(String(format: "REAL full-codex %@ tokens=%.1fM cost=$%.2f", day,
                             Double(rows.reduce(0) { $0 + $1.totalVolume }) / 1e6, rows.reduce(0) { $0 + $1.estimatedCostUSD }))
            }
            print("REAL full-codex authoritative=\(scan.isAuthoritative) from=\(scan.coverage?.from.value ?? "-") days=\(scan.days.count)")
        }
    }
}
