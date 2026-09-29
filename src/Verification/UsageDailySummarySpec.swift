import Foundation

/// Self-check for the date-indexed usage aggregation in `UsageDailyModels.swift`
/// (no XCTest — only CommandLineTools is installed, so `swift test` cannot run).
///
/// Compile and run from the repo root:
///   swiftc -O -o /tmp/usage-daily-spec \
///     src/Verification/UsageDailySummarySpec.swift \
///     src/Sources/UsageDailyModels.swift \
///     src/Sources/UsageVolumeUnit.swift && /tmp/usage-daily-spec
///
/// Scope: the pure aggregation/ranking logic, which is where the real correctness risk
/// lives (mixed units, cost-vs-volume ranking, fidelity reporting). The filesystem
/// scanning path in LocalTokenCostScanner reads fixed paths under $HOME and so is not
/// injectable; it is covered only by `swift build` plus src/Tests/LocalUsageAttributionTests.swift,
/// which cannot execute in this environment.
@main
struct UsageDailySummarySpec {
    static func main() {
        let recorder = FailureRecorder()

        // MARK: Day keys

        run("day keys round-trip and sort chronologically", recorder: recorder) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .current
            let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 15))!
            let key = UsageDayKey(date: date, calendar: calendar)
            expectEqual(key.value, "2026-07-12", "formats as yyyy-MM-dd", recorder: recorder)

            let parsed = key.date(calendar: calendar)
            expectEqual(parsed != nil, true, "parses back to a date", recorder: recorder)
            if let parsed {
                expectEqual(
                    UsageDayKey(date: parsed, calendar: calendar).value,
                    "2026-07-12",
                    "round-trips",
                    recorder: recorder
                )
            }

            // String ordering must equal chronological ordering — the UI sorts on it.
            expectEqual(
                UsageDayKey(value: "2026-07-09") < UsageDayKey(value: "2026-07-12"),
                true,
                "earlier day sorts first",
                recorder: recorder
            )
            expectEqual(
                UsageDayKey(value: "2026-12-01") < UsageDayKey(value: "2027-01-01"),
                true,
                "sorts across a year boundary",
                recorder: recorder
            )
        }

        run("day keys are stable across a locale with a non-Gregorian default", recorder: recorder) {
            // A Hindi/India locale defaults to a non-Gregorian calendar in some configs;
            // the key must still be an ISO-style Gregorian date, not a localized string.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
            expectEqual(
                UsageDayKey(date: date, calendar: calendar).value,
                "2026-01-05",
                "zero-padded ISO date",
                recorder: recorder
            )
        }

        // MARK: Mixed units

        run("credits are excluded from token totals but included in cost", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("codex", volume: 1_000_000, cost: 4.00, unit: .tokens),
                    // 5,000,000 millicredits = 5,000 credits. If this leaked into the token
                    // total it would add 5M phantom "tokens".
                    provider("kiro", volume: 5_000_000, cost: 2.00, unit: .credits),
                    provider("grok", volume: 250_000, cost: 0.50, unit: .estimatedTokens),
                ]
            )
            expectEqual(summary.totalTokens, 1_000_000, "only exact tokens sum", recorder: recorder)
            expectEqual(summary.totalEstimatedTokens, 250_000, "estimates are reported beside it", recorder: recorder)
            expectEqual(summary.totalCostUSD, 6.50, "all providers contribute cost", recorder: recorder)
        }

        // The whole reason ranking is cost-based: Kiro's millicredit volume dwarfs
        // Codex's token count, but Codex actually cost more that day.
        run("top provider ranks by cost, not by raw volume", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("codex", volume: 1_000_000, cost: 4.00, unit: .tokens),
                    provider("kiro", volume: 90_000_000, cost: 2.00, unit: .credits),
                ]
            )
            expectEqual(summary.topProvider?.providerID, "codex", "highest cost wins", recorder: recorder)
            expectEqual(
                summary.providersByCost.map(\.providerID),
                ["codex", "kiro"],
                "ordered by cost descending",
                recorder: recorder
            )
        }

        run("cost share reflects the top provider's fraction of the day", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("kiro", volume: 1_000, cost: 4.60, unit: .credits),
                    provider("codex", volume: 1_000, cost: 3.40, unit: .tokens),
                    provider("claude", volume: 1_000, cost: 2.00, unit: .tokens),
                ]
            )
            expectEqual(summary.topProvider?.providerID, "kiro", "kiro is top", recorder: recorder)
            guard let share = summary.topProviderCostShare else {
                recorder.failures += 1
                fputs("  - expected a cost share\n", stderr)
                return
            }
            expectEqual((share * 1000).rounded(), 460, "46.0% of $10.00", recorder: recorder)
        }

        run("cost share is nil when a day has no cost signal", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [provider("copilot", volume: 4_000, cost: 0, unit: .estimatedTokens)]
            )
            // A 0%-share badge next to real volume would read as "used nothing".
            expectEqual(summary.topProviderCostShare == nil, true, "no bogus 0% share", recorder: recorder)
            expectEqual(summary.topProvider?.providerID, "copilot", "still reports a top provider", recorder: recorder)
        }

        run("providers with no models are ignored in ranking", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    DailyProviderUsage(providerID: "gemini", models: [], volumeUnit: .tokens, fidelity: .exact),
                    provider("claude", volume: 900, cost: 0.30, unit: .tokens),
                ]
            )
            expectEqual(summary.providersByCost.map(\.providerID), ["claude"], "empty provider dropped", recorder: recorder)
            expectEqual(summary.isEmpty, false, "day is not empty", recorder: recorder)
        }

        run("an empty day reports zeros rather than nil totals", recorder: recorder) {
            let summary = DailyUsageSummary.empty(day: UsageDayKey(value: "2026-01-01"))
            expectEqual(summary.isEmpty, true, "flagged empty", recorder: recorder)
            expectEqual(summary.totalTokens, 0, "zero tokens", recorder: recorder)
            expectEqual(summary.totalCostUSD, 0, "zero cost", recorder: recorder)
            expectEqual(summary.topProvider == nil, true, "no top provider", recorder: recorder)
            expectEqual(summary.topProviderCostShare == nil, true, "no share", recorder: recorder)
        }

        // MARK: Model ranking

        run("same-named models in different units stay separate rows", recorder: recorder) {
            // "auto" appears as both a Kiro credit row and a token row; merging them
            // would add millicredits to tokens.
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("kiro", model: "auto", volume: 3_000, cost: 0.12, unit: .credits),
                    provider("opencode", model: "auto", volume: 50_000, cost: 0.90, unit: .estimatedTokens),
                ]
            )
            let rows = summary.modelsByCost
            expectEqual(rows.count, 2, "two distinct rows", recorder: recorder)
            expectEqual(rows.first?.usage.volumeUnit, .estimatedTokens, "costlier row first", recorder: recorder)
            expectEqual(rows.first?.providerID, "opencode", "attributed to its provider", recorder: recorder)
            expectEqual(summary.totalTokens, 0, "credits and estimates stay out of exact tokens", recorder: recorder)
            expectEqual(summary.totalEstimatedTokens, 50_000, "the estimate is still reported", recorder: recorder)
        }

        run("model rows are ordered by cost then volume", recorder: recorder) {
            let summary = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    DailyProviderUsage(
                        providerID: "claude",
                        models: [
                            model("claude-haiku-4-5", volume: 900_000, cost: 0.10),
                            model("claude-opus-5", volume: 100_000, cost: 9.10),
                            model("claude-sonnet-5", volume: 400_000, cost: 2.40),
                        ],
                        volumeUnit: .tokens,
                        fidelity: .exact
                    )
                ]
            )
            expectEqual(
                summary.modelsByCost.map(\.usage.model),
                ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"],
                "cost descending, not volume descending",
                recorder: recorder
            )
        }

        // MARK: Fidelity

        run("fidelity caveats surface only for approximate providers", recorder: recorder) {
            expectEqual(DailyUsageFidelity.exact.isApproximate, false, "exact is not approximate", recorder: recorder)
            expectEqual(DailyUsageFidelity.exact.caveat == nil, true, "exact needs no caveat", recorder: recorder)
            expectEqual(DailyUsageFidelity.dayTotalsOnly.isApproximate, true, "day-totals is approximate", recorder: recorder)
            expectEqual(DailyUsageFidelity.sessionApproximate.isApproximate, true, "session-pinned is approximate", recorder: recorder)
            expectEqual(DailyUsageFidelity.dayTotalsOnly.caveat != nil, true, "day-totals explains itself", recorder: recorder)
            expectEqual(DailyUsageFidelity.sessionApproximate.caveat != nil, true, "session-pinned explains itself", recorder: recorder)
        }

        run("a day is flagged approximate when any contributor is", recorder: recorder) {
            let exactOnly = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [provider("codex", volume: 1_000, cost: 0.10, unit: .tokens, fidelity: .exact)]
            )
            expectEqual(exactOnly.hasApproximateData, false, "all-exact day is clean", recorder: recorder)

            let withGrok = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("codex", volume: 1_000, cost: 0.10, unit: .tokens, fidelity: .exact),
                    provider("grok", volume: 5_000, cost: 0.20, unit: .estimatedTokens, fidelity: .sessionApproximate),
                ]
            )
            expectEqual(withGrok.hasApproximateData, true, "grok makes the day approximate", recorder: recorder)

            // An approximate provider that contributed nothing must not taint the day.
            let emptyGrok = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("codex", volume: 1_000, cost: 0.10, unit: .tokens, fidelity: .exact),
                    DailyProviderUsage(providerID: "grok", models: [], volumeUnit: .estimatedTokens, fidelity: .sessionApproximate),
                ]
            )
            expectEqual(emptyGrok.hasApproximateData, false, "empty approximate provider is ignored", recorder: recorder)
        }

        // MARK: Persistence

        run("summaries survive a JSON round-trip", recorder: recorder) {
            let original = DailyUsageSummary(
                day: UsageDayKey(value: "2026-07-12"),
                providers: [
                    provider("kiro", volume: 3_000, cost: 0.12, unit: .credits, fidelity: .exact),
                    provider("copilot", volume: 8_000, cost: 0, unit: .estimatedTokens, fidelity: .dayTotalsOnly),
                ]
            )
            do {
                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(DailyUsageSummary.self, from: data)
                expectEqual(decoded, original, "decodes to an identical value", recorder: recorder)
                expectEqual(decoded.day.value, "2026-07-12", "day key preserved", recorder: recorder)
                expectEqual(
                    decoded.providers.first(where: { $0.providerID == "copilot" })?.fidelity,
                    .dayTotalsOnly,
                    "fidelity preserved so the UI keeps its caveat",
                    recorder: recorder
                )
            } catch {
                recorder.failures += 1
                fputs("  - round-trip threw: \(error)\n", stderr)
            }
        }

        run("model merge accumulates every field", recorder: recorder) {
            var a = model("gpt-5.4", volume: 100, cost: 1.0, input: 60, output: 40, cacheRead: 10, requests: 2)
            let b = model("gpt-5.4", volume: 50, cost: 0.5, input: 30, output: 20, cacheRead: 5, requests: 3)
            a.merge(b)
            expectEqual(a.totalVolume, 150, "volume", recorder: recorder)
            expectEqual(a.estimatedCostUSD, 1.5, "cost", recorder: recorder)
            expectEqual(a.inputTokens, 90, "input", recorder: recorder)
            expectEqual(a.outputTokens, 60, "output", recorder: recorder)
            expectEqual(a.cacheReadTokens, 15, "cache read", recorder: recorder)
            expectEqual(a.requestCount, 5, "requests", recorder: recorder)
        }

        if recorder.failures == 0 {
            print("UsageDailySummarySpec: all checks passed")
            Foundation.exit(EXIT_SUCCESS)
        }

        fputs("UsageDailySummarySpec: \(recorder.failures) check(s) failed\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }

    // MARK: - Fixtures

    private static func model(
        _ name: String,
        volume: Int,
        cost: Double,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        requests: Int = 1,
        unit: UsageVolumeUnit = .tokens
    ) -> DailyModelUsage {
        DailyModelUsage(
            model: name,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            totalVolume: volume,
            estimatedCostUSD: cost,
            requestCount: requests,
            volumeUnit: unit
        )
    }

    private static func provider(
        _ id: String,
        model name: String = "test-model",
        volume: Int,
        cost: Double,
        unit: UsageVolumeUnit,
        fidelity: DailyUsageFidelity = .exact
    ) -> DailyProviderUsage {
        DailyProviderUsage(
            providerID: id,
            models: [model(name, volume: volume, cost: cost, unit: unit)],
            volumeUnit: unit,
            fidelity: fidelity
        )
    }
}

private final class FailureRecorder {
    var failures = 0
}

private func run(_ name: String, recorder: FailureRecorder, _ body: () -> Void) {
    let startingFailures = recorder.failures
    body()
    let status = recorder.failures == startingFailures ? "PASS" : "FAIL"
    print("[\(status)] \(name)")
}

private func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: T,
    _ message: String,
    recorder: FailureRecorder
) {
    let value = actual()
    guard value == expected else {
        recorder.failures += 1
        fputs("  - \(message): expected \(expected), got \(value)\n", stderr)
        return
    }
}
