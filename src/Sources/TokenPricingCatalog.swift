import Foundation

/// List-price catalog aligned with CodexBar `CostUsagePricing` (per-token → USD / 1M tokens).
///
/// Pipeline:
/// 1. **Detect model** from the log line (Claude `message.model`, Codex preceding `turn_context`,
///    Kiro `rts_model_state.model_id`, Grok `primaryModelId`, OpenCode session.model JSON).
/// 2. **Normalize** ID (strip provider prefixes / date suffixes).
/// 3. **Price tokens** for that model only — never blend rates across models.
enum TokenPricingCatalog {
    struct LongContextTier: Equatable {
        let thresholdTokens: Int
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double
        let cacheWritePerMTok: Double?
        let cacheWrite1hPerMTok: Double?

        init(
            thresholdTokens: Int,
            inputPerMTok: Double,
            outputPerMTok: Double,
            cacheReadPerMTok: Double,
            cacheWritePerMTok: Double? = nil,
            cacheWrite1hPerMTok: Double? = nil
        ) {
            self.thresholdTokens = thresholdTokens
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cacheReadPerMTok = cacheReadPerMTok
            self.cacheWritePerMTok = cacheWritePerMTok
            self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        }
    }

    struct Rate: Equatable {
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double
        let cacheWritePerMTok: Double?
        let cacheWrite1hPerMTok: Double?
        let longContextTiers: [LongContextTier]
        /// Human label for UI, e.g. "$2.50 / $15.00 per 1M"
        var listPriceLabel: String {
            String(format: "$%.2f / $%.2f per 1M tok", inputPerMTok, outputPerMTok)
        }

        var longContext: LongContextTier? { longContextTiers.first }

        init(
            inputPerMTok: Double,
            outputPerMTok: Double,
            cacheReadPerMTok: Double,
            cacheWritePerMTok: Double? = nil,
            cacheWrite1hPerMTok: Double? = nil,
            longContextTiers: [LongContextTier] = []
        ) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cacheReadPerMTok = cacheReadPerMTok
            self.cacheWritePerMTok = cacheWritePerMTok
            self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
            self.longContextTiers = longContextTiers.sorted { $0.thresholdTokens < $1.thresholdTokens }
        }

        func tier(forPromptTokens promptTokens: Int?) -> LongContextTier? {
            guard let promptTokens else { return nil }
            return longContextTiers.last { promptTokens > $0.thresholdTokens }
        }

        /// Rate for ONE request of the given full prompt size; nil never selects a tier.
        func effective(forPromptTokens promptTokens: Int?) -> Rate {
            guard let tier = tier(forPromptTokens: promptTokens) else { return self }
            let ratio = inputPerMTok > 0 ? tier.inputPerMTok / inputPerMTok : 1
            return Rate(
                inputPerMTok: tier.inputPerMTok,
                outputPerMTok: tier.outputPerMTok,
                cacheReadPerMTok: tier.cacheReadPerMTok,
                cacheWritePerMTok: tier.cacheWritePerMTok ?? cacheWritePerMTok.map { $0 * ratio },
                cacheWrite1hPerMTok: tier.cacheWrite1hPerMTok ?? cacheWrite1hPerMTok.map { $0 * ratio }
            )
        }

        /// `cacheWrite` is 5-minute writes; pass `promptTokens` only for a single request, never totals.
        func costUSD(
            input: Int,
            output: Int,
            cacheRead: Int = 0,
            cacheWrite: Int = 0,
            cacheWrite1h: Int = 0,
            promptTokens: Int? = nil
        ) -> Double {
            let r = effective(forPromptTokens: promptTokens)
            let write5m = r.cacheWritePerMTok ?? r.inputPerMTok
            let write1h = r.cacheWrite1hPerMTok ?? write5m
            return Double(input) / 1_000_000 * r.inputPerMTok
                + Double(output) / 1_000_000 * r.outputPerMTok
                + Double(cacheRead) / 1_000_000 * r.cacheReadPerMTok
                + Double(cacheWrite) / 1_000_000 * write5m
                + Double(cacheWrite1h) / 1_000_000 * write1h
        }

        func withLongContext(thresholdTokens: Int, input: Double, cache: Double, output: Double) -> Rate {
            Rate(
                inputPerMTok: inputPerMTok,
                outputPerMTok: outputPerMTok,
                cacheReadPerMTok: cacheReadPerMTok,
                cacheWritePerMTok: cacheWritePerMTok,
                cacheWrite1hPerMTok: cacheWrite1hPerMTok,
                longContextTiers: [
                    LongContextTier(
                        thresholdTokens: thresholdTokens,
                        inputPerMTok: inputPerMTok * input,
                        outputPerMTok: outputPerMTok * output,
                        cacheReadPerMTok: cacheReadPerMTok * cache,
                        cacheWritePerMTok: cacheWritePerMTok.map { $0 * cache },
                        cacheWrite1hPerMTok: cacheWrite1hPerMTok.map { $0 * cache }
                    ),
                ]
            )
        }
    }

    static let fallback = Rate(
        inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75, cacheWrite1hPerMTok: 6.0
    )
    static let kiroUSDPerCredit: Double = 0.04

    /// CodexBar stores per-token; we use per-1M.
    private static func m(_ perToken: Double) -> Double { perToken * 1_000_000 }

    // MARK: - Normalize (CodexBar-compatible)

    /// Canonical model id for pricing lookup + analytics grouping.
    static func normalizeModelID(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        // Strip "[Codex] gpt-5" style labels
        if name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // provider/model or anthropic.claude-…
        if name.hasPrefix("openai/") { name = String(name.dropFirst("openai/".count)) }
        if name.hasPrefix("anthropic.") { name = String(name.dropFirst("anthropic.".count)) }
        if name.hasPrefix("xai/") { name = String(name.dropFirst("xai/".count)) }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        // Bedrock-style …claude-xxx tail after last dot when tail starts with claude-
        if let lastDot = name.lastIndex(of: "."), name.contains("claude-") {
            let tail = String(name[name.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { name = tail }
        }
        // Strip :0 / -v1:0 suffixes
        if let r = name.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            name.removeSubrange(r)
        }
        // Strip dated suffix -20251001 if base is known later via contains matching
        if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(name[..<r.lowerBound])
            if !base.isEmpty { name = base }
        }
        // Kiro uses dots in versions (claude-opus-4.8) — normalize to dashes for matching
        // but keep a form that still contains family tokens.
        return name.isEmpty ? nil : name
    }

    /// Canonical lower-cased, dash-versioned key for pricing lookup and remote-feed matching
    /// (e.g. "GPT-5.4", "openai/gpt-5.4" → "gpt-5-4"). Mirrors the key `rate()` matches on so the
    /// remote catalog and the static rules key models identically.
    static func dashedKey(_ raw: String?) -> String? {
        guard let normalized = normalizeModelID(raw) else { return nil }
        return normalized.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    static func rate(forModel rawModel: String?) -> Rate {
        guard let dashed = dashedKey(rawModel) else { return fallback }
        if isFreeKey(dashed) { return free }

        // Live remote list-price (models.dev) wins when the feed knows this model and the user
        // has auto-update enabled. When the toggle is off, ignore any in-memory/disk cache so
        // estimates match the built-in table only (as the Settings copy promises).
        if AppSettings.shared.autoUpdatePricing, let dynamic = remoteRate(forDashedKey: dashed) {
            return dynamic.longContextTiers.isEmpty ? withStaticLongContext(dynamic, dashedKey: dashed) : dynamic
        }
        return staticRate(dashedKey: dashed)
    }

    /// Built-in table only (no feed), including static long-context tiers.
    static func staticRate(forModel rawModel: String?) -> Rate {
        guard let dashed = dashedKey(rawModel) else { return fallback }
        return staticRate(dashedKey: dashed)
    }

    /// Exact key first, then variant suffixes peeled off ("gpt-5-6-luna-max" → "gpt-5-6-luna").
    static func remoteLookupKeys(forDashedKey dashed: String) -> [String] {
        var keys = [dashed]
        var current = dashed
        while let next = strippingVariantSuffix(current), next != current, next.contains("-") {
            keys.append(next)
            current = next
        }
        return keys
    }

    /// Long-context threshold the built-in rules assume for a model family (nil = no tier).
    static func staticLongContextThreshold(forDashedKey dashed: String) -> Int? {
        staticLongContextSpec(dashed)?.threshold
    }

    private static let free = Rate(
        inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0, cacheWritePerMTok: 0, cacheWrite1hPerMTok: 0
    )

    // Free-tier ids ("…-free") are $0 by definition (e.g. x-preview-f-free).
    private static func isFreeKey(_ dashed: String) -> Bool {
        dashed.split(separator: "-").contains("free")
    }

    private static func remoteRate(forDashedKey dashed: String) -> Rate? {
        for key in remoteLookupKeys(forDashedKey: dashed) {
            if let rate = RemotePricingCatalog.rate(forDashedID: key) { return rate }
        }
        return nil
    }

    private static let variantSuffixPatterns = [
        #"-exp(-[a-z0-9]+)*$"#,
        #"-preview(-[a-z0-9]+)*$"#,
        #"-thinking$"#,
        #"-fast$"#,
        #"-(high|low|medium|xhigh|minimal)$"#,
        #"-max$"#,
    ]

    private static func strippingVariantSuffix(_ key: String) -> String? {
        for pattern in variantSuffixPatterns {
            if let r = key.range(of: pattern, options: .regularExpression), r.lowerBound > key.startIndex {
                return String(key[..<r.lowerBound])
            }
        }
        return nil
    }

    private static func matches(_ key: String, _ pattern: String) -> Bool {
        key.range(of: pattern, options: .regularExpression) != nil
    }

    private static func staticLongContextSpec(_ d: String) -> (threshold: Int, input: Double, cache: Double, output: Double)? {
        let openAI = matches(d, #"gpt-(5-[456]|6)(-|$)"#)
            && !matches(d, #"gpt-5-4-(mini|nano)"#)
            && !d.contains("gpt-5-5-cyber")
        if openAI || d.contains("codex-auto-review") { return (272_000, 2, 2, 1.5) }
        if matches(d, #"gemini-(2-5|3(-\d+)?)-pro"#) { return (200_000, 2, 2, 1.5) }
        if d.contains("grok"), !d.contains("composer"), !d.contains("mini"), !matches(d, #"grok-4(-1)?-fast"#),
           d.contains("grok-4") || d.contains("grok-code") || d.split(separator: "-").contains("build")
        {
            return (200_000, 2, 2, 2)
        }
        return nil
    }

    private static func withStaticLongContext(_ rate: Rate, dashedKey d: String) -> Rate {
        guard let spec = staticLongContextSpec(d) else { return rate }
        return rate.withLongContext(thresholdTokens: spec.threshold, input: spec.input, cache: spec.cache, output: spec.output)
    }

    private static func staticRate(dashedKey d: String) -> Rate {
        if isFreeKey(d) { return free }
        return withStaticLongContext(staticBaseRate(d), dashedKey: d)
    }

    private static func anthropic(_ input: Double, _ output: Double, cacheRead: Double) -> Rate {
        Rate(
            inputPerMTok: input,
            outputPerMTok: output,
            cacheReadPerMTok: cacheRead,
            cacheWritePerMTok: input * 1.25,
            cacheWrite1hPerMTok: input * 2
        )
    }

    private static func staticBaseRate(_ d: String) -> Rate {
        // --- Cursor (checked first so "cursor-auto" never reaches a generic rule) ---
        if d.hasPrefix("cursor-auto") {
            return Rate(inputPerMTok: 1.25, outputPerMTok: 6.0, cacheReadPerMTok: 0.25, cacheWritePerMTok: 1.25)
        }
        if d.hasPrefix("composer") || d.contains("-composer") {
            return Rate(inputPerMTok: 0.5, outputPerMTok: 2.5, cacheReadPerMTok: 0.05)
        }

        // --- OpenAI / Codex (most-specific first) ---
        if d.contains("gpt-6-astra") {
            return Rate(inputPerMTok: 10.0, outputPerMTok: 50.0, cacheReadPerMTok: 1.0, cacheWritePerMTok: 12.5)
        }
        if d.contains("gpt-6-luna") {
            return Rate(inputPerMTok: 0.1, outputPerMTok: 0.5, cacheReadPerMTok: 0.01, cacheWritePerMTok: 0.125)
        }
        if d.contains("gpt-6") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 10.0, cacheReadPerMTok: 0.2, cacheWritePerMTok: 2.5)
        }
        if d.contains("gpt-5-6-cyber") {
            return Rate(inputPerMTok: 12.5, outputPerMTok: 75.0, cacheReadPerMTok: 1.25, cacheWritePerMTok: 15.625)
        }
        if d.contains("gpt-5-6-terra") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 12.0, cacheReadPerMTok: 0.2, cacheWritePerMTok: 2.5)
        }
        if d.contains("gpt-5-6-luna") {
            return Rate(inputPerMTok: 0.2, outputPerMTok: 1.2, cacheReadPerMTok: 0.02, cacheWritePerMTok: 0.25)
        }
        if d.contains("gpt-5-6") {
            // Sol (flagship) and the bare family id.
            return Rate(inputPerMTok: 4.0, outputPerMTok: 20.0, cacheReadPerMTok: 0.4, cacheWritePerMTok: 5.0)
        }
        if d.contains("gpt-5-5-pro") {
            return Rate(inputPerMTok: 30.0, outputPerMTok: 180.0, cacheReadPerMTok: 0)
        }
        if d.contains("gpt-5-5-cyber") {
            return Rate(inputPerMTok: 12.5, outputPerMTok: 75.0, cacheReadPerMTok: 1.25)
        }
        if d.contains("gpt-5-5") || d.contains("chat-latest") || d.contains("codex-auto-review") {
            return Rate(inputPerMTok: 5.0, outputPerMTok: 30.0, cacheReadPerMTok: 0.5)
        }
        if d.contains("gpt-5-4-pro") {
            return Rate(inputPerMTok: m(3e-5), outputPerMTok: m(1.8e-4), cacheReadPerMTok: 0)
        }
        if d.contains("gpt-5-4-mini") {
            return Rate(inputPerMTok: m(7.5e-7), outputPerMTok: m(4.5e-6), cacheReadPerMTok: m(7.5e-8))
        }
        if d.contains("gpt-5-4-nano") {
            return Rate(inputPerMTok: m(2e-7), outputPerMTok: m(1.25e-6), cacheReadPerMTok: m(2e-8))
        }
        if d.contains("gpt-5-4") {
            return Rate(inputPerMTok: m(2.5e-6), outputPerMTok: m(1.5e-5), cacheReadPerMTok: m(2.5e-7))
        }
        if d.contains("gpt-5-3-codex-spark") {
            return Rate(inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0)
        }
        if d.contains("gpt-5-3") {
            return Rate(inputPerMTok: m(1.75e-6), outputPerMTok: m(1.4e-5), cacheReadPerMTok: m(1.75e-7))
        }
        if d.contains("gpt-5-2-pro") {
            return Rate(inputPerMTok: m(2.1e-5), outputPerMTok: m(1.68e-4), cacheReadPerMTok: 0)
        }
        if d.contains("gpt-5-2") {
            return Rate(inputPerMTok: m(1.75e-6), outputPerMTok: m(1.4e-5), cacheReadPerMTok: m(1.75e-7))
        }
        if d.contains("gpt-5-pro") {
            return Rate(inputPerMTok: m(1.5e-5), outputPerMTok: m(1.2e-4), cacheReadPerMTok: 0)
        }
        if d.contains("gpt-5-nano") {
            return Rate(inputPerMTok: m(5e-8), outputPerMTok: m(4e-7), cacheReadPerMTok: m(5e-9))
        }
        if d.contains("gpt-5-mini") || d.contains("codex-mini") {
            return Rate(inputPerMTok: m(2.5e-7), outputPerMTok: m(2e-6), cacheReadPerMTok: m(2.5e-8))
        }
        if d.contains("gpt-5") || d.contains("codex") {
            return Rate(inputPerMTok: m(1.25e-6), outputPerMTok: m(1e-5), cacheReadPerMTok: m(1.25e-7))
        }
        if d.contains("o3") || d.contains("o4") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 8.0, cacheReadPerMTok: 0.5)
        }
        if d.contains("o1") {
            return Rate(inputPerMTok: 15.0, outputPerMTok: 60.0, cacheReadPerMTok: 7.5)
        }
        if d.contains("gpt-4o-mini") {
            return Rate(inputPerMTok: 0.15, outputPerMTok: 0.6, cacheReadPerMTok: 0.075)
        }
        if d.contains("gpt-4o") {
            return Rate(inputPerMTok: 2.5, outputPerMTok: 10.0, cacheReadPerMTok: 1.25)
        }
        if d.contains("gpt-4") {
            return Rate(inputPerMTok: 10.0, outputPerMTok: 30.0, cacheReadPerMTok: 5.0)
        }

        // --- Anthropic / Kiro Claude (cache write 1.25x input for 5m, 2x for 1h) ---
        if d.contains("fable-5-1") || d.contains("mythos-5-1") {
            return anthropic(10.0, 50.0, cacheRead: 0.25)
        }
        if d.contains("fable-5") || d.contains("mythos-5") || d.contains("mythos-preview") {
            return anthropic(10.0, 50.0, cacheRead: 1.0)
        }
        if d.contains("opus-5-5") {
            return anthropic(4.0, 20.0, cacheRead: 0.2)
        }
        if d.contains("sonnet-5") {
            return anthropic(2.0, 10.0, cacheRead: 0.2)
        }
        if d.contains("opus-4-8") || d.contains("opus-4-7") || d.contains("opus-4-6") || d.contains("opus-4-5") {
            return anthropic(5.0, 25.0, cacheRead: 0.5)
        }
        // Legacy Opus (Opus 3 / 4 / 4.1 = $15/$75; 4.5+ = $5/$25).
        if d.contains("claude-3-opus") || d.contains("opus-3") || d.contains("opus-4") {
            return anthropic(15.0, 75.0, cacheRead: 1.5)
        }
        // Generic / current Opus family (Opus 5 and unpinned versions).
        if d.contains("opus") {
            return anthropic(5.0, 25.0, cacheRead: 0.5)
        }
        if d.contains("sonnet") {
            return anthropic(3.0, 15.0, cacheRead: 0.3)
        }
        if d.contains("haiku") {
            return anthropic(1.0, 5.0, cacheRead: 0.1)
        }
        if d.contains("claude") {
            return anthropic(3.0, 15.0, cacheRead: 0.3)
        }

        // --- Google (most-specific first; bare "flash" is the 2.0 rate) ---
        if d.contains("gemini") {
            if d.contains("3-8-flash-cyber") {
                return Rate(inputPerMTok: 1.5, outputPerMTok: 7.5, cacheReadPerMTok: 0.15)
            }
            if d.contains("3-5-flash-lite") {
                return Rate(inputPerMTok: 0.3, outputPerMTok: 2.5, cacheReadPerMTok: 0.03)
            }
            if d.contains("3-5-flash") {
                return Rate(inputPerMTok: 1.5, outputPerMTok: 9.0, cacheReadPerMTok: 0.15)
            }
            if matches(d, #"gemini-3-[6-9]-flash"#) {
                return Rate(inputPerMTok: 0.75, outputPerMTok: 3.75, cacheReadPerMTok: 0.075)
            }
            if d.contains("3-1-flash-lite") {
                return Rate(inputPerMTok: 0.25, outputPerMTok: 1.5, cacheReadPerMTok: 0.025)
            }
            if d.contains("3-1-flash") || d.contains("gemini-3-flash") {
                return Rate(inputPerMTok: 0.5, outputPerMTok: 3.0, cacheReadPerMTok: 0.05)
            }
            if d.contains("2-5-flash-lite") {
                return Rate(inputPerMTok: 0.1, outputPerMTok: 0.4, cacheReadPerMTok: 0.01)
            }
            if d.contains("2-5-flash") {
                return Rate(inputPerMTok: 0.3, outputPerMTok: 2.5, cacheReadPerMTok: 0.03)
            }
            if d.contains("flash") {
                return Rate(inputPerMTok: 0.1, outputPerMTok: 0.4, cacheReadPerMTok: 0.025)
            }
            if matches(d, #"gemini-3(-\d+)?-pro"#) {
                return Rate(inputPerMTok: 2.0, outputPerMTok: 12.0, cacheReadPerMTok: 0.2)
            }
            if d.contains("pro") {
                return Rate(inputPerMTok: 1.25, outputPerMTok: 10.0, cacheReadPerMTok: 0.125)
            }
            return Rate(inputPerMTok: 0.5, outputPerMTok: 1.5, cacheReadPerMTok: 0.1)
        }

        // --- xAI ---
        if d.contains("grok") {
            // "build" in any position: grok-build, grok-build-0-1, grok-4-6-build.
            if d.split(separator: "-").contains("build") || d.contains("grok-code") {
                return Rate(inputPerMTok: 1.0, outputPerMTok: 2.0, cacheReadPerMTok: 0.2)
            }
            if matches(d, #"grok-4(-1)?-fast"#) || d.contains("mini") {
                return Rate(inputPerMTok: 0.2, outputPerMTok: 0.5, cacheReadPerMTok: 0.05)
            }
            if d.contains("grok-4-20") || d.contains("grok-4-3") {
                return Rate(inputPerMTok: 1.25, outputPerMTok: 2.5, cacheReadPerMTok: 0.2)
            }
            if d.contains("grok-4-5") {
                return Rate(inputPerMTok: 2.0, outputPerMTok: 6.0, cacheReadPerMTok: 0.3)
            }
            // Grok 4.6 / 4.7 and the family default.
            return Rate(inputPerMTok: 2.0, outputPerMTok: 6.0, cacheReadPerMTok: 0.5)
        }

        // --- Open-weight / China ---
        if d.contains("deepseek") {
            if d.contains("flash") {
                return Rate(inputPerMTok: 0.15, outputPerMTok: 0.6, cacheReadPerMTok: 0.003)
            }
            return Rate(inputPerMTok: 0.435, outputPerMTok: 0.87, cacheReadPerMTok: 0.003625)
        }
        if d.contains("qwen3-8-max") {
            return Rate(inputPerMTok: 2.0, outputPerMTok: 6.0, cacheReadPerMTok: 0.25, cacheWritePerMTok: 2.5)
        }
        if d.contains("qwen") {
            return Rate(inputPerMTok: 0.4, outputPerMTok: 1.2, cacheReadPerMTok: 0.1)
        }
        if d.contains("muse-spark") {
            if d.hasSuffix("-contributor") {
                return Rate(inputPerMTok: 0.1, outputPerMTok: 0.2, cacheReadPerMTok: 0.002)
            }
            return Rate(inputPerMTok: 1.25, outputPerMTok: 4.25, cacheReadPerMTok: 0.15)
        }
        if d.contains("kimi") || d.contains("moonshot") {
            if d.contains("kimi-k3") {
                return Rate(inputPerMTok: 3.0, outputPerMTok: 15.0, cacheReadPerMTok: 0.3)
            }
            if d.contains("kimi-k2-7") {
                return Rate(inputPerMTok: 0.95, outputPerMTok: 4.0, cacheReadPerMTok: 0.19)
            }
            if d.contains("kimi-k2-5") {
                return Rate(inputPerMTok: 0.6, outputPerMTok: 3.0, cacheReadPerMTok: 0.1)
            }
            return Rate(inputPerMTok: 0.95, outputPerMTok: 4.0, cacheReadPerMTok: 0.16)
        }
        if d.contains("glm") {
            if d.contains("glm-5") {
                if d.contains("flashx") {
                    return Rate(inputPerMTok: 0.37, outputPerMTok: 1.25, cacheReadPerMTok: 0.075)
                }
                if d.contains("flash") {
                    return Rate(inputPerMTok: 0.15, outputPerMTok: 0.5, cacheReadPerMTok: 0.03)
                }
                if matches(d, #"glm-5-\d"#) {
                    return Rate(inputPerMTok: 1.4, outputPerMTok: 4.4, cacheReadPerMTok: 0.26)
                }
                return Rate(inputPerMTok: 1.0, outputPerMTok: 3.2, cacheReadPerMTok: 0.2)
            }
            return Rate(inputPerMTok: 0.5, outputPerMTok: 2.0, cacheReadPerMTok: 0.1)
        }

        return fallback
    }

    /// Legacy flat estimate. Pass `promptTokens` only when the counts describe ONE request.
    static func estimateUSD(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheWrite1hTokens: Int = 0,
        promptTokens: Int? = nil
    ) -> Double {
        rate(forModel: model).costUSD(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheWriteTokens,
            cacheWrite1h: cacheWrite1hTokens,
            promptTokens: promptTokens
        )
    }

    /// Per-request cost with long-context tiers; prompt defaults to the sum of the input parts.
    static let unpricedSuffix = " (unpriced)"
    /// Sentinels for usage whose model is unknown, so no family rate is invented for them.
    static let unpricedModelIDs: Set<String> = ["gemini-unknown", "antigravity-unknown"]

    static func isUnpriced(_ model: String?) -> Bool {
        guard let model else { return false }
        return unpricedModelIDs.contains(model) || model.hasSuffix(unpricedSuffix)
    }

    static func requestCostUSD(
        model: String?,
        uncachedInput: Int,
        cacheRead: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        output: Int,
        promptTokens: Int? = nil
    ) -> Double {
        guard !isUnpriced(model) else { return 0 }
        let prompt = promptTokens ?? (uncachedInput + cacheRead + cacheWrite5m + cacheWrite1h)
        return rate(forModel: model).costUSD(
            input: uncachedInput,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite5m,
            cacheWrite1h: cacheWrite1h,
            promptTokens: prompt
        )
    }

    /// Kiro analytics $ is credits × overage rate ($0.04, est.), not an API-equivalent or the invoice.
    /// Do **not** substitute CLI "Est. cost" overage invoice $ here — that is a different metric
    /// (bill-shaped, often only the overage portion) and is not comparable to other providers.
    static func kiroCostUSD(credits: Double) -> Double {
        max(0, credits) * kiroUSDPerCredit
    }
}
