import XCTest
@testable import CLIProxyMenuBar

/// Pins model→rate routing and the corrected 2026 list prices for the models the user's tools
/// actually log. Guards against a model silently falling through to the wrong `contains()` branch
/// or the Sonnet-priced fallback (the high-impact pricing bug class).
final class TokenPricingCatalogTests: XCTestCase {

    private func rate(_ model: String) -> TokenPricingCatalog.Rate {
        TokenPricingCatalog.rate(forModel: model)
    }
    private func assertRate(_ model: String, in inp: Double, out: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        let r = rate(model)
        XCTAssertEqual(r.inputPerMTok, inp, accuracy: 0.001, "\(model) input", file: file, line: line)
        XCTAssertEqual(r.outputPerMTok, out, accuracy: 0.001, "\(model) output", file: file, line: line)
    }

    // MARK: - The two headline mispricings that were fixed

    func testGPT56SolIsFlagshipPriced() {
        assertRate("gpt-5.6-sol", in: 4.0, out: 20.0)
        XCTAssertGreaterThan(rate("gpt-5.6-sol").inputPerMTok, rate("gpt-5").inputPerMTok)
    }

    func testGPT56TiersDistinct() {
        assertRate("gpt-5.6-terra", in: 2.0, out: 12.0)
        assertRate("gpt-5.6-luna", in: 0.2, out: 1.2)
        assertRate("gpt-5.6-luna-max", in: 0.2, out: 1.2)
        assertRate("gpt-5.6", in: 4.0, out: 20.0) // bare family id defaults to Sol
    }

    func testGrok45NotOverpriced() {
        assertRate("grok-4.5", in: 2.0, out: 6.0)
        XCTAssertEqual(rate("grok-4.5").cacheReadPerMTok, 0.3, accuracy: 0.001)
    }

    func testGrokComposerVsFastSplit() {
        assertRate("grok-composer-2.5-fast", in: 0.5, out: 2.5) // Composer wins over "fast"
        assertRate("grok-4.1-fast", in: 0.2, out: 0.5)
        assertRate("grok-build", in: 1.0, out: 2.0)
    }

    func testOpenWeightUpdated() {
        assertRate("deepseek-v4-pro", in: 0.435, out: 0.87)
        assertRate("kimi-k2.6", in: 0.95, out: 4.0)
        assertRate("kimi-k3", in: 3.0, out: 15.0)
        assertRate("moonshotai/kimi-k2.6", in: 0.95, out: 4.0) // provider prefix stripped
    }

    // MARK: - Regression guards for models that were already correct

    func testUnchangedRatesStaySane() {
        assertRate("gpt-5.4", in: 2.5, out: 15.0)
        assertRate("gpt-5.5", in: 5.0, out: 30.0)
        assertRate("gpt-5", in: 1.25, out: 10.0)
        assertRate("claude-opus-4.8", in: 5.0, out: 25.0)
        assertRate("claude-sonnet-4-6", in: 3.0, out: 15.0)
        assertRate("claude-haiku-4-5-20251001", in: 1.0, out: 5.0) // date suffix stripped
        assertRate("anthropic.claude-opus-4-6-v1", in: 5.0, out: 25.0) // bedrock prefix + opus 4.6
    }

    func testGemini35FlashNotLegacy20Rate() {
        // Was matching bare "flash" at gemini-2.0 rates ($0.10/$0.40).
        assertRate("gemini-3.5-flash", in: 1.5, out: 9.0)
        assertRate("gemini-2.5-flash", in: 0.3, out: 2.5)
        assertRate("gemini-2.0-flash", in: 0.1, out: 0.4)
    }

    // MARK: - Rate math + invariants

    func testEstimateUSDMath() {
        // 1M input + 1M output = input + output rate.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "gpt-5.6-sol", inputTokens: 1_000_000, outputTokens: 1_000_000),
            24.0, accuracy: 0.001
        )
        // Anthropic cache: read @0.1x + write @1.25x of $3 sonnet input = $0.30 + $3.75.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "claude-sonnet-4-6", inputTokens: 0, outputTokens: 0,
                                            cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000),
            4.05, accuracy: 0.001
        )
        // OpenAI models have no explicit cache-write rate → falls back to input rate.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "gpt-5.4", inputTokens: 0, outputTokens: 0,
                                            cacheReadTokens: 0, cacheWriteTokens: 1_000_000),
            2.5, accuracy: 0.001
        )
    }

    func testInvariantsAcrossUserModels() {
        for m in ["gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "grok-4.5",
                  "grok-composer-2.5-fast", "claude-opus-4.8", "claude-sonnet-4-6",
                  "deepseek-v4-pro", "kimi-k2.6", "glm-5.2", "gemini-3.5-flash"] {
            let r = rate(m)
            XCTAssertLessThanOrEqual(r.cacheReadPerMTok, r.inputPerMTok + 0.0001, "\(m): cacheRead ≤ input")
            XCTAssertGreaterThanOrEqual(r.outputPerMTok, r.inputPerMTok, "\(m): output ≥ input")
            XCTAssertGreaterThan(r.inputPerMTok, 0, "\(m): nonzero input rate")
        }
        // mini tier must stay cheaper than its base.
        XCTAssertLessThan(rate("gpt-5.4-mini").inputPerMTok, rate("gpt-5.4").inputPerMTok)
    }

    // MARK: - Pinned static table (LiteLLM / models.dev snapshot, 2026-09-28)

    private struct Pin {
        let model: String
        let inp: Double
        let out: Double
        let cr: Double
        var cw: Double? = nil
        var cw1h: Double? = nil
    }

    private let pins: [Pin] = [
        Pin(model: "gpt-6-astra", inp: 10, out: 50, cr: 1, cw: 12.5),
        Pin(model: "gpt-6-sol", inp: 2, out: 10, cr: 0.2, cw: 2.5),
        Pin(model: "gpt-6-luna", inp: 0.1, out: 0.5, cr: 0.01, cw: 0.125),
        Pin(model: "gpt-5.6-sol", inp: 4, out: 20, cr: 0.4, cw: 5),
        Pin(model: "gpt-5.6", inp: 4, out: 20, cr: 0.4, cw: 5),
        Pin(model: "gpt-5.6-terra", inp: 2, out: 12, cr: 0.2, cw: 2.5),
        Pin(model: "gpt-5.6-luna", inp: 0.2, out: 1.2, cr: 0.02, cw: 0.25),
        Pin(model: "gpt-5.6-luna-max", inp: 0.2, out: 1.2, cr: 0.02, cw: 0.25),
        Pin(model: "gpt-5.6-cyber", inp: 12.5, out: 75, cr: 1.25, cw: 15.625),
        Pin(model: "gpt-5.5", inp: 5, out: 30, cr: 0.5),
        Pin(model: "gpt-5.5-cyber", inp: 12.5, out: 75, cr: 1.25),
        Pin(model: "gpt-5.5-pro", inp: 30, out: 180, cr: 0),
        Pin(model: "codex-auto-review", inp: 5, out: 30, cr: 0.5),
        Pin(model: "gpt-5.4", inp: 2.5, out: 15, cr: 0.25),
        Pin(model: "gpt-5.4-mini", inp: 0.75, out: 4.5, cr: 0.075),
        Pin(model: "gpt-5.4-nano", inp: 0.2, out: 1.25, cr: 0.02),
        Pin(model: "gpt-5.4-pro", inp: 30, out: 180, cr: 0),
        Pin(model: "gpt-5.3-codex", inp: 1.75, out: 14, cr: 0.175),
        Pin(model: "gpt-5", inp: 1.25, out: 10, cr: 0.125),
        Pin(model: "claude-fable-5-1", inp: 10, out: 50, cr: 0.25, cw: 12.5, cw1h: 20),
        Pin(model: "claude-fable-5", inp: 10, out: 50, cr: 1.0, cw: 12.5, cw1h: 20),
        Pin(model: "claude-mythos-5-1", inp: 10, out: 50, cr: 0.25, cw: 12.5, cw1h: 20),
        Pin(model: "claude-mythos-preview", inp: 10, out: 50, cr: 1.0, cw: 12.5, cw1h: 20),
        Pin(model: "claude-opus-5-5", inp: 4, out: 20, cr: 0.2, cw: 5, cw1h: 8),
        Pin(model: "kiro/claude-opus-5.5", inp: 4, out: 20, cr: 0.2, cw: 5, cw1h: 8),
        Pin(model: "claude-opus-5", inp: 5, out: 25, cr: 0.5, cw: 6.25, cw1h: 10),
        Pin(model: "claude-opus-4-8", inp: 5, out: 25, cr: 0.5, cw: 6.25, cw1h: 10),
        Pin(model: "claude-opus-4.7", inp: 5, out: 25, cr: 0.5, cw: 6.25, cw1h: 10),
        Pin(model: "claude-opus-4-1-20250805", inp: 15, out: 75, cr: 1.5, cw: 18.75, cw1h: 30),
        Pin(model: "claude-sonnet-5", inp: 2, out: 10, cr: 0.2, cw: 2.5, cw1h: 4),
        Pin(model: "claude-sonnet-4-6", inp: 3, out: 15, cr: 0.3, cw: 3.75, cw1h: 6),
        Pin(model: "claude-haiku-4-5-20251001", inp: 1, out: 5, cr: 0.1, cw: 1.25, cw1h: 2),
        Pin(model: "gemini-3.1-pro-preview", inp: 2, out: 12, cr: 0.2),
        Pin(model: "gemini-3-pro-image", inp: 2, out: 12, cr: 0.2),
        Pin(model: "gemini-2.5-pro", inp: 1.25, out: 10, cr: 0.125),
        Pin(model: "gemini-3.8-flash", inp: 0.75, out: 3.75, cr: 0.075),
        Pin(model: "gemini-3.8-flash-exp-a", inp: 0.75, out: 3.75, cr: 0.075),
        Pin(model: "gemini-3.7-flash", inp: 0.75, out: 3.75, cr: 0.075),
        Pin(model: "gemini-3.6-flash", inp: 0.75, out: 3.75, cr: 0.075),
        Pin(model: "gemini-3.5-flash", inp: 1.5, out: 9, cr: 0.15),
        Pin(model: "gemini-3.5-flash-lite", inp: 0.3, out: 2.5, cr: 0.03),
        Pin(model: "gemini-3.1-flash-lite", inp: 0.25, out: 1.5, cr: 0.025),
        Pin(model: "gemini-3-flash-preview", inp: 0.5, out: 3, cr: 0.05),
        Pin(model: "gemini-2.5-flash", inp: 0.3, out: 2.5, cr: 0.03),
        Pin(model: "gemini-2.5-flash-lite", inp: 0.1, out: 0.4, cr: 0.01),
        Pin(model: "grok-4.5", inp: 2, out: 6, cr: 0.3),
        Pin(model: "grok-4.6", inp: 2, out: 6, cr: 0.5),
        Pin(model: "grok-4.7", inp: 2, out: 6, cr: 0.5),
        Pin(model: "grok-4.6-high-fast", inp: 2, out: 6, cr: 0.5),
        Pin(model: "grok-4.3", inp: 1.25, out: 2.5, cr: 0.2),
        Pin(model: "grok-4.20-0309-reasoning", inp: 1.25, out: 2.5, cr: 0.2),
        Pin(model: "grok-build-0.1", inp: 1, out: 2, cr: 0.2),
        Pin(model: "grok-4-6-build", inp: 1, out: 2, cr: 0.2),
        Pin(model: "grok-code-fast-1", inp: 1, out: 2, cr: 0.2),
        Pin(model: "grok-4.1-fast", inp: 0.2, out: 0.5, cr: 0.05),
        Pin(model: "composer-2.5", inp: 0.5, out: 2.5, cr: 0.05),
        Pin(model: "composer-2.5-fast", inp: 0.5, out: 2.5, cr: 0.05),
        Pin(model: "cursor-auto", inp: 1.25, out: 6, cr: 0.25, cw: 1.25),
        Pin(model: "glm-5.3", inp: 1.4, out: 4.4, cr: 0.26),
        Pin(model: "glm-5.2", inp: 1.4, out: 4.4, cr: 0.26),
        Pin(model: "glm-5.3-flash", inp: 0.15, out: 0.5, cr: 0.03),
        Pin(model: "glm-5", inp: 1.0, out: 3.2, cr: 0.2),
        Pin(model: "kimi-k3", inp: 3, out: 15, cr: 0.3),
        Pin(model: "kimi-k2.6", inp: 0.95, out: 4, cr: 0.16),
        Pin(model: "kimi-k2.7-code", inp: 0.95, out: 4, cr: 0.19),
        Pin(model: "deepseek-v4-pro", inp: 0.435, out: 0.87, cr: 0.003625),
        Pin(model: "deepseek-v4-flash", inp: 0.15, out: 0.6, cr: 0.003),
        Pin(model: "qwen3.8-max", inp: 2, out: 6, cr: 0.25, cw: 2.5),
        Pin(model: "opencode-go/muse-spark-1.3-contributor", inp: 0.1, out: 0.2, cr: 0.002),
        Pin(model: "muse-spark-1.3", inp: 1.25, out: 4.25, cr: 0.15),
    ]

    func testPinnedStaticRatesMatchSnapshot() {
        for pin in pins {
            let r = TokenPricingCatalog.staticRate(forModel: pin.model)
            XCTAssertEqual(r.inputPerMTok, pin.inp, accuracy: 1e-9, "\(pin.model) input")
            XCTAssertEqual(r.outputPerMTok, pin.out, accuracy: 1e-9, "\(pin.model) output")
            XCTAssertEqual(r.cacheReadPerMTok, pin.cr, accuracy: 1e-9, "\(pin.model) cache read")
            if let cw = pin.cw {
                XCTAssertEqual(r.cacheWritePerMTok ?? -1, cw, accuracy: 1e-9, "\(pin.model) cache write")
            }
            if let cw1h = pin.cw1h {
                XCTAssertEqual(r.cacheWrite1hPerMTok ?? -1, cw1h, accuracy: 1e-9, "\(pin.model) 1h cache write")
            }
        }
    }

    func testStaticRateIgnoresFeed() {
        RemotePricingCatalog.replaceRatesForTesting([
            "gpt-6-astra": TokenPricingCatalog.Rate(inputPerMTok: 99, outputPerMTok: 99, cacheReadPerMTok: 9),
        ])
        defer { RemotePricingCatalog.replaceRatesForTesting([:]) }
        XCTAssertEqual(TokenPricingCatalog.staticRate(forModel: "gpt-6-astra").inputPerMTok, 10, accuracy: 1e-9)
    }

    // MARK: - Long-context tiers (per request)

    func testStaticLongContextTiers() {
        let astra = TokenPricingCatalog.staticRate(forModel: "gpt-6-astra")
        XCTAssertEqual(astra.longContext?.thresholdTokens, 272_000)
        XCTAssertEqual(astra.longContext?.inputPerMTok ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(astra.longContext?.cacheReadPerMTok ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(astra.longContext?.cacheWritePerMTok ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(astra.longContext?.outputPerMTok ?? -1, 75, accuracy: 1e-9)

        for model in ["gpt-5.4", "gpt-5.5", "gpt-5.6-luna", "gpt-6-sol", "codex-auto-review", "gpt-5.4-pro"] {
            XCTAssertEqual(TokenPricingCatalog.staticRate(forModel: model).longContext?.thresholdTokens, 272_000, model)
        }
        for model in ["gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.3-codex", "claude-opus-5-5", "gemini-3.8-flash",
                      "composer-2.5", "grok-4.1-fast", "glm-5.3"] {
            XCTAssertNil(TokenPricingCatalog.staticRate(forModel: model).longContext, model)
        }

        let gemini = TokenPricingCatalog.staticRate(forModel: "gemini-3.1-pro-preview").longContext
        XCTAssertEqual(gemini?.thresholdTokens, 200_000)
        XCTAssertEqual(gemini?.inputPerMTok ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(gemini?.cacheReadPerMTok ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(gemini?.outputPerMTok ?? -1, 18, accuracy: 1e-9)

        let grok = TokenPricingCatalog.staticRate(forModel: "grok-4.6").longContext
        XCTAssertEqual(grok?.thresholdTokens, 200_000)
        XCTAssertEqual(grok?.inputPerMTok ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(grok?.cacheReadPerMTok ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(grok?.outputPerMTok ?? -1, 12, accuracy: 1e-9)

        let build = TokenPricingCatalog.staticRate(forModel: "grok-4-6-build").longContext
        XCTAssertEqual(build?.inputPerMTok ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(build?.outputPerMTok ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(build?.cacheReadPerMTok ?? -1, 0.4, accuracy: 1e-9)
    }

    func testTierAppliesPerRequestOnlyAboveThreshold() {
        // gpt-5.6-sol $4 / $0.40 / $20 → above 272k: $8 / $0.80 / $30.
        let atThreshold = TokenPricingCatalog.requestCostUSD(
            model: "gpt-5.6-sol", uncachedInput: 72_000, cacheRead: 200_000, output: 1_000
        )
        XCTAssertEqual(atThreshold, 0.388, accuracy: 1e-9, "272,000 is not above 272k")

        let above = TokenPricingCatalog.requestCostUSD(
            model: "gpt-5.6-sol", uncachedInput: 100_000, cacheRead: 200_000, output: 1_000
        )
        XCTAssertEqual(above, 0.99, accuracy: 1e-9)

        // Same tokens without a prompt size (aggregates) stay at base rates.
        let flat = TokenPricingCatalog.estimateUSD(
            model: "gpt-5.6-sol", inputTokens: 100_000, outputTokens: 1_000, cacheReadTokens: 200_000
        )
        XCTAssertEqual(flat, 0.5, accuracy: 1e-9)

        // Explicit prompt size wins over the summed split (Codex input_tokens includes cached).
        let explicit = TokenPricingCatalog.estimateUSD(
            model: "gpt-5.6-sol", inputTokens: 100_000, outputTokens: 1_000, cacheReadTokens: 200_000,
            promptTokens: 250_000
        )
        XCTAssertEqual(explicit, flat, accuracy: 1e-9)
    }

    func testOneHourCacheWritesBilledAtTwiceInput() {
        let cost = TokenPricingCatalog.estimateUSD(
            model: "claude-opus-5-5", inputTokens: 0, outputTokens: 0,
            cacheWriteTokens: 1_000_000, cacheWrite1hTokens: 1_000_000
        )
        XCTAssertEqual(cost, 13.0, accuracy: 1e-9)
        // Without a 1h rate (OpenAI) 1h writes fall back to the 5m rate, then input.
        XCTAssertEqual(
            TokenPricingCatalog.estimateUSD(model: "gpt-5.4", inputTokens: 0, outputTokens: 0, cacheWrite1hTokens: 1_000_000),
            2.5, accuracy: 1e-9
        )
    }

    func testMultipleTiersPickHighestCrossed() {
        let rate = TokenPricingCatalog.Rate(
            inputPerMTok: 1, outputPerMTok: 2, cacheReadPerMTok: 0.1,
            longContextTiers: [
                .init(thresholdTokens: 128_000, inputPerMTok: 3, outputPerMTok: 6, cacheReadPerMTok: 0.3),
                .init(thresholdTokens: 32_000, inputPerMTok: 2, outputPerMTok: 4, cacheReadPerMTok: 0.2),
            ]
        )
        XCTAssertEqual(rate.effective(forPromptTokens: 10_000).inputPerMTok, 1)
        XCTAssertEqual(rate.effective(forPromptTokens: 50_000).inputPerMTok, 2)
        XCTAssertEqual(rate.effective(forPromptTokens: 200_000).inputPerMTok, 3)
        XCTAssertEqual(rate.effective(forPromptTokens: nil).inputPerMTok, 1)
        // Missing tier cache-write scales the base rate by the tier's input ratio.
        let withWrite = TokenPricingCatalog.Rate(
            inputPerMTok: 2, outputPerMTok: 12, cacheReadPerMTok: 0.2, cacheWritePerMTok: 2.5,
            longContextTiers: [.init(thresholdTokens: 200_000, inputPerMTok: 4, outputPerMTok: 18, cacheReadPerMTok: 0.4)]
        )
        XCTAssertEqual(withWrite.effective(forPromptTokens: 300_000).cacheWritePerMTok ?? -1, 5, accuracy: 1e-9)
    }

    func testRemoteLookupKeysStripVariantSuffixes() {
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "gemini-3-8-flash-exp-a"),
                       ["gemini-3-8-flash-exp-a", "gemini-3-8-flash"])
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "gpt-5-6-luna-max"),
                       ["gpt-5-6-luna-max", "gpt-5-6-luna"])
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "grok-4-6-high-fast"),
                       ["grok-4-6-high-fast", "grok-4-6-high", "grok-4-6"])
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "gemini-2-5-flash-preview-05-20"),
                       ["gemini-2-5-flash-preview-05-20", "gemini-2-5-flash"])
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "claude-sonnet-4-6-thinking"),
                       ["claude-sonnet-4-6-thinking", "claude-sonnet-4-6"])
        XCTAssertEqual(TokenPricingCatalog.remoteLookupKeys(forDashedKey: "cursor-auto"), ["cursor-auto"])
    }
}
