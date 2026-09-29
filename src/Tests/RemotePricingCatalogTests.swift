import XCTest
@testable import CLIProxyMenuBar

/// Guards the auto-updating pricing pipeline: models.dev parsing, native-provider preference,
/// Anthropic cache-write derivation, and that a live rate overrides the static catalog.
final class RemotePricingCatalogTests: XCTestCase {

    override func tearDown() {
        // Never leak an injected table into other tests / the running app.
        RemotePricingCatalog.replaceRatesForTesting([:])
        super.tearDown()
    }

    private let sample = Data("""
    {
      "openai":   { "models": {
          "gpt-5.4": { "cost": { "input": 2.5, "output": 15, "cache_read": 0.25, "cache_write": 3.125 } },
          "gpt-5.6": { "cost": { "input": 5,   "output": 30, "cache_read": 0.5 } } } },
      "anthropic":{ "models": {
          "claude-opus-4-8": { "cost": { "input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25 } } } },
      "google":   { "models": {
          "gemini-3.5-flash": { "cost": { "input": 1.5, "output": 9 } } } },
      "zai-coding-plan": { "models": {
          "glm-5.2": { "cost": { "input": 0, "output": 0, "cache_read": 0 } } } },
      "zai": { "models": {
          "glm-5.2": { "cost": { "input": 1.4, "output": 4.4, "cache_read": 0.26 } } } },
      "somereseller": { "models": {
          "gpt-5.4": { "cost": { "input": 9, "output": 99, "cache_read": 9 } } } }
    }
    """.utf8)

    func testParsesCostIntoNormalizedKeys() {
        let r = RemotePricingCatalog.parse(sample)
        XCTAssertEqual(r["gpt-5-4"]?.outputPerMTok, 15, "gpt-5.4 -> dashed key 'gpt-5-4'")
        XCTAssertEqual(r["gpt-5-6"]?.inputPerMTok, 5)
        XCTAssertEqual(r["claude-opus-4-8"]?.inputPerMTok, 5)
    }

    func testNativeProviderBeatsReseller() {
        let r = RemotePricingCatalog.parse(sample)
        // Both "openai" (native) and "somereseller" list gpt-5.4; native list price must win.
        XCTAssertEqual(r["gpt-5-4"]?.inputPerMTok, 2.5)
        XCTAssertEqual(r["gpt-5-4"]?.outputPerMTok, 15)
    }

    func testAnthropicCacheWriteFromFeedOrDerived() {
        let r = RemotePricingCatalog.parse(sample)
        // Feed ships cache_write for Anthropic — prefer it over re-deriving.
        XCTAssertEqual(r["claude-opus-4-8"]?.cacheWritePerMTok, 6.25)
        // OpenAI feed cache_write is kept too.
        XCTAssertEqual(r["gpt-5-4"]?.cacheWritePerMTok, 3.125)
        // gpt-5.6 has no cache_write in the fixture and is not Anthropic → nil.
        XCTAssertNil(r["gpt-5-6"]?.cacheWritePerMTok)
    }

    func testCacheReadDefaultsToTenPercentWhenMissing() {
        let r = RemotePricingCatalog.parse(sample)
        // gemini line has no cache_read -> default 0.1x input.
        XCTAssertEqual(r["gemini-3-5-flash"]?.cacheReadPerMTok ?? -1, 0.15, accuracy: 0.0001)
    }

    func testSkipsZeroCostFreePlanRows() {
        let r = RemotePricingCatalog.parse(sample)
        // zai-coding-plan lists glm-5.2 at $0; native zai list price must win (and free row skipped).
        XCTAssertEqual(r["glm-5-2"]?.inputPerMTok, 1.4, accuracy: 0.001)
        XCTAssertEqual(r["glm-5-2"]?.outputPerMTok, 4.4, accuracy: 0.001)
    }

    func testOwnerZeroCostBeatsResellerPrice() {
        let data = Data("""
        {
          "somereseller": { "models": { "glm-4.7-flash": { "cost": { "input": 0.06, "output": 0.4 } } } },
          "zai": { "models": { "glm-4.7-flash": { "cost": { "input": 0, "output": 0 } } } },
          "zai-coding-plan": { "models": { "glm-4.6v-flash": { "cost": { "input": 0, "output": 0 } } } },
          "zz-reseller": { "models": { "glm-4.6v-flash": { "cost": { "input": 0.3, "output": 0.9 } } } }
        }
        """.utf8)
        let r = RemotePricingCatalog.parse(data)
        XCTAssertEqual(r["glm-4-7-flash"]?.inputPerMTok, 0, "the family owner lists it as free")
        XCTAssertEqual(r["glm-4-7-flash"]?.outputPerMTok, 0)
        XCTAssertEqual(r["glm-4-6v-flash"]?.inputPerMTok, 0.3, "a non-owner $0 row is still skipped")
    }

    func testAnthropicCacheWriteDerivedWhenFeedOmitsIt() {
        let data = Data("""
        {"anthropic":{"models":{"claude-sonnet-4-6":{"cost":{"input":3,"output":15,"cache_read":0.3}}}}}
        """.utf8)
        let r = RemotePricingCatalog.parse(data)
        XCTAssertEqual(r["claude-sonnet-4-6"]?.cacheWritePerMTok, 3.75, accuracy: 0.001)
    }

    func testGarbageParsesToEmpty() {
        XCTAssertTrue(RemotePricingCatalog.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(RemotePricingCatalog.parse(Data("{}".utf8)).isEmpty)
    }

    func testRemoteRateOverridesStaticCatalog() {
        let staticGlm = TokenPricingCatalog.rate(forModel: "glm-5.2")
        XCTAssertEqual(staticGlm.inputPerMTok, 1.4, accuracy: 0.001)

        RemotePricingCatalog.replaceRatesForTesting([
            "glm-5-2": TokenPricingCatalog.Rate(inputPerMTok: 1.1, outputPerMTok: 3.85, cacheReadPerMTok: 0.275),
        ])
        let liveGlm = TokenPricingCatalog.rate(forModel: "glm-5.2")
        XCTAssertEqual(liveGlm.inputPerMTok, 1.1, accuracy: 0.001, "live feed must override static")
        XCTAssertEqual(liveGlm.outputPerMTok, 3.85, accuracy: 0.001)

        // A model the feed doesn't have still falls back to static rules.
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "grok-composer-2.5-fast").outputPerMTok, 2.5, accuracy: 0.001)

        RemotePricingCatalog.replaceRatesForTesting([:])
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "glm-5.2").inputPerMTok, 1.4, accuracy: 0.001,
                       "clearing the feed restores the static fallback")
    }

    // MARK: - Long-context tiers

    private let tierSample = Data("""
    {
      "openai": { "models": {
          "gpt-6-astra": { "cost": { "input": 10, "output": 50, "cache_read": 1, "cache_write": 12.5,
              "tiers": [{ "input": 20, "output": 75, "cache_read": 2, "cache_write": 25,
                          "tier": { "type": "context", "size": 272000 } }],
              "context_over_200k": { "input": 20, "output": 75, "cache_read": 2, "cache_write": 25 } } },
          "gpt-5.5": { "cost": { "input": 5, "output": 30, "cache_read": 0.5,
              "context_over_200k": { "input": 10, "output": 45, "cache_read": 1 } } },
          "gpt-5.4": { "cost": { "input": 2.5, "output": 15, "cache_read": 0.25 } } } },
      "google": { "models": {
          "gemini-3.1-pro-preview": { "cost": { "input": 2, "output": 12, "cache_read": 0.2,
              "tiers": [{ "input": 4, "output": 18, "tier": { "type": "context", "size": 200001 } }] } } } },
      "anthropic": { "models": {
          "claude-sonnet-4-5": { "cost": { "input": 3, "output": 15, "cache_read": 0.3,
              "context_over_200k": { "input": 6, "output": 22.5, "cache_read": 0.6 } } } } }
    }
    """.utf8)

    func testTiersUseTierSizeNotContextOver200k() {
        let r = RemotePricingCatalog.parse(tierSample)
        let tier = r["gpt-6-astra"]?.longContext
        XCTAssertEqual(tier?.thresholdTokens, 272_000)
        XCTAssertEqual(tier?.inputPerMTok, 20)
        XCTAssertEqual(tier?.cacheWritePerMTok, 25)
        XCTAssertEqual(r["gpt-6-astra"]?.longContextTiers.count, 1)
        // 250k-token prompt sits between 200k and 272k: base rates.
        XCTAssertEqual(r["gpt-6-astra"]?.effective(forPromptTokens: 250_000).inputPerMTok, 10)
        XCTAssertEqual(r["gpt-6-astra"]?.effective(forPromptTokens: 272_001).inputPerMTok, 20)
    }

    func testContextOver200kFallbackOnlyWithoutTiers() {
        let r = RemotePricingCatalog.parse(tierSample)
        // OpenAI family without tiers[]: the 272k boundary, not a literal 200k.
        XCTAssertEqual(r["gpt-5-5"]?.longContext?.thresholdTokens, 272_000)
        XCTAssertEqual(r["gpt-5-5"]?.longContext?.outputPerMTok, 45)
        XCTAssertEqual(r["claude-sonnet-4-5"]?.longContext?.thresholdTokens, 200_000)
        XCTAssertEqual(r["claude-sonnet-4-5"]?.longContext?.cacheWrite1hPerMTok ?? -1, 12, accuracy: 1e-9)
        XCTAssertNil(r["gpt-5-4"]?.longContext)
    }

    func testTierSizeOffByOneAndMissingCacheRead() {
        let tier = RemotePricingCatalog.parse(tierSample)["gemini-3-1-pro-preview"]?.longContext
        XCTAssertEqual(tier?.thresholdTokens, 200_000)
        XCTAssertEqual(tier?.cacheReadPerMTok ?? -1, 0.4, accuracy: 1e-9, "scaled by the tier's input ratio")
    }

    func testAnthropicOneHourWriteDerived() {
        let r = RemotePricingCatalog.parse(sample)
        XCTAssertEqual(r["claude-opus-4-8"]?.cacheWrite1hPerMTok ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(r["gpt-5-4"]?.cacheWrite1hPerMTok)
    }

    func testFeedRateWithoutTiersGetsStaticTier() {
        RemotePricingCatalog.replaceRatesForTesting(RemotePricingCatalog.parse(tierSample))
        let gpt54 = TokenPricingCatalog.rate(forModel: "gpt-5.4")
        XCTAssertEqual(gpt54.longContext?.thresholdTokens, 272_000)
        XCTAssertEqual(gpt54.longContext?.inputPerMTok ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(gpt54.longContext?.outputPerMTok ?? -1, 22.5, accuracy: 1e-9)
        // Feed-provided tiers are kept as-is.
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "gpt-6-astra").longContext?.outputPerMTok, 75)
        XCTAssertEqual(
            TokenPricingCatalog.requestCostUSD(model: "gpt-6-astra", uncachedInput: 300_000, output: 0),
            6.0, accuracy: 1e-9
        )
    }

    // MARK: - Lookup fallbacks

    func testSuffixedIdFallsBackToFeedBaseKey() {
        RemotePricingCatalog.replaceRatesForTesting([
            "gemini-3-8-flash": TokenPricingCatalog.Rate(inputPerMTok: 0.8, outputPerMTok: 4, cacheReadPerMTok: 0.08),
            "gpt-5-6-luna": TokenPricingCatalog.Rate(inputPerMTok: 0.21, outputPerMTok: 1.3, cacheReadPerMTok: 0.021),
            "auto": TokenPricingCatalog.Rate(inputPerMTok: 0.85, outputPerMTok: 1.55, cacheReadPerMTok: 0.085),
        ])
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "gemini-3.8-flash-exp-a").inputPerMTok, 0.8)
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "gpt-5.6-luna-max").inputPerMTok, 0.21)
        XCTAssertEqual(TokenPricingCatalog.rate(forModel: "cursor-auto").inputPerMTok, 1.25,
                       "cursor-auto must not use the feed's generic 'auto' key")
    }

    // MARK: - Deterministic provider precedence (REMOTE-1)

    func testOwnerBeatsOtherNativeAndResellerTiesAreSorted() {
        let data = Data("""
        {
          "alibaba": { "models": { "glm-5.2": { "cost": { "input": 2, "output": 5 } },
                                   "kimi-k3": { "cost": { "input": 4, "output": 16 } } } },
          "zai": { "models": { "glm-5.2": { "cost": { "input": 1.4, "output": 4.4, "cache_read": 0.26 } } } },
          "moonshotai": { "models": { "kimi-k3": { "cost": { "input": 3, "output": 15, "cache_read": 0.3 } } } },
          "zzz-reseller": { "models": { "x-ai/grok-4.6": { "cost": { "input": 9, "output": 9 } } } },
          "aaa-reseller": { "models": { "x-ai/grok-4.6": { "cost": { "input": 2, "output": 6 } } } },
          "mmm-reseller": { "models": { "x-ai/grok-4.6": { "cost": { "input": 5, "output": 5 } } } }
        }
        """.utf8)
        for _ in 0..<5 {
            let r = RemotePricingCatalog.parse(data)
            XCTAssertEqual(r["glm-5-2"]?.inputPerMTok, 1.4)
            XCTAssertEqual(r["kimi-k3"]?.inputPerMTok, 3)
            XCTAssertEqual(r["grok-4-6"]?.inputPerMTok, 2, "equal ranks resolve by sorted provider id")
        }
        XCTAssertEqual(RemotePricingCatalog.providerRank("togetherai", forKey: "glm-5-2"), 50)
        XCTAssertEqual(RemotePricingCatalog.providerRank("together-ai", forKey: "glm-5-2"), 10)
        XCTAssertEqual(RemotePricingCatalog.ownerProvider(forKey: "gpt-6-astra"), "openai")
    }

    // MARK: - Disk cache

    func testCacheRoundTripKeepsTiersAndOneHourWrites() throws {
        let parsed = RemotePricingCatalog.parse(tierSample).merging(RemotePricingCatalog.parse(sample)) { a, _ in a }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let data = try XCTUnwrap(RemotePricingCatalog.encodeCache(rates: parsed, at: date))
        let decoded = try XCTUnwrap(RemotePricingCatalog.decodeCache(data))
        XCTAssertEqual(decoded.rates, parsed)
        XCTAssertEqual(decoded.fetchedAt, date)
    }

    func testLegacyCacheStillLoads() throws {
        let legacy = Data("""
        {"fetchedAt": 1790000000, "rates": {
          "claude-opus-4-8": {"in": 5, "out": 25, "cr": 0.5, "cw": 6.25},
          "gpt-5-4": {"in": 2.5, "out": 15, "cr": 0.25}
        }}
        """.utf8)
        let decoded = try XCTUnwrap(RemotePricingCatalog.decodeCache(legacy))
        XCTAssertEqual(decoded.rates["claude-opus-4-8"]?.cacheWrite1hPerMTok ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(decoded.rates["gpt-5-4"]?.cacheWrite1hPerMTok)
        XCTAssertTrue(decoded.rates["gpt-5-4"]?.longContextTiers.isEmpty ?? false)
        XCTAssertNil(decoded.fetchedAt, "legacy cache is treated as stale so tiers are refetched")
    }
}
