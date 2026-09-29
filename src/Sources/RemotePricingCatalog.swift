import Foundation

/// Live, auto-updating model list-prices so cost estimates track real pricing instead of a
/// frozen table. Source: **models.dev** (`https://models.dev/api.json`) — the same community
/// feed OpenCode uses. Per-provider JSON with `cost: { input, output, cache_read }` in $/1M tok.
///
/// Precedence: a remote rate (when present) wins in `TokenPricingCatalog.rate(forModel:)`;
/// the built-in static rules remain the offline / unknown-model fallback so the app never
/// shows $0 due to a network failure or a model the feed doesn't list.
///
/// Robustness:
/// - Disk cache (Application Support) is loaded synchronously at launch, so rates are ready
///   before the first cost scan even while a fresh fetch is in flight.
/// - Native provider pricing is preferred over resellers/aggregators for the same model id.
/// - models.dev omits 1-hour cache-write pricing; Anthropic bills it at 2× input, so it is
///   derived for claude families (5-minute writes use the feed value or 1.25× input).
/// - Long-context tiers come from `cost.tiers[]`; `context_over_200k` is used only without tiers.
enum RemotePricingCatalog {
    static let sourceURL = URL(string: "https://models.dev/api.json")!
    /// Refresh at most once per day; the disk cache bridges restarts.
    private static let ttl: TimeInterval = 24 * 3600

    private static let lock = NSLock()
    private static var rates: [String: TokenPricingCatalog.Rate] = [:]
    private static var fetchedAt: Date?
    private static var storeGeneration = 0
    private static let cacheSchema = 2

    // MARK: - Lookup (called from TokenPricingCatalog.rate on scan threads)

    /// Live rate for a normalized+dashed model key (e.g. "gpt-5-4", "claude-opus-4-8"), or nil.
    static func rate(forDashedID dashed: String) -> TokenPricingCatalog.Rate? {
        lock.lock(); defer { lock.unlock() }
        return rates[dashed]
    }

    static var lastUpdated: Date? { lock.lock(); defer { lock.unlock() }; return fetchedAt }
    static var modelCount: Int { lock.lock(); defer { lock.unlock() }; return rates.count }
    /// Bumped whenever the live table changes, so cost caches can invalidate.
    static var generation: Int { lock.lock(); defer { lock.unlock() }; return storeGeneration }

    /// Test hook: inject a rate table to verify remote-overrides-static wiring without a network
    /// fetch. Not used in production paths.
    static func replaceRatesForTesting(_ injected: [String: TokenPricingCatalog.Rate]) {
        lock.lock(); rates = injected; fetchedAt = Date(); storeGeneration += 1; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Load the disk cache immediately (cheap) so prices are available at launch, then kick off
    /// a background refresh when stale. Call once from `applicationDidFinishLaunching`.
    static func bootstrap() {
        loadDiskCache()
        Task.detached(priority: .utility) { await refreshIfStale() }
    }

    /// Fetch only when the cache is empty or older than the TTL. Safe to call frequently
    /// (e.g. before each analytics scan) — it short-circuits when fresh.
    static func refreshIfStale() async {
        let state = snapshot()
        let age = state.fetchedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if state.count > 0, age < ttl { return }
        await refresh()
    }

    /// Force a fetch (respecting the user's auto-update toggle).
    static func refresh() async {
        guard AppSettings.shared.autoUpdatePricing else { return }
        var request = URLRequest(url: sourceURL, timeoutInterval: 25)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let parsed = parse(data)
            guard !parsed.isEmpty else { return } // never clobber a good cache with garbage
            let now = Date()
            store(parsed, at: now)
            writeDiskCache(rates: parsed, at: now)
        } catch {
            // Offline / transient: keep the existing cache (or static fallback). No throw.
        }
    }

    // Synchronous locked accessors keep NSLock off the async call-path (Swift 6 safe).
    private static func snapshot() -> (count: Int, fetchedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (rates.count, fetchedAt)
    }

    private static func store(_ newRates: [String: TokenPricingCatalog.Rate], at date: Date) {
        lock.lock(); rates = newRates; fetchedAt = date; storeGeneration += 1; lock.unlock()
    }

    // MARK: - Parse models.dev

    /// Parse the models.dev payload into normalized rate keys. The model's owner (openai for
    /// gpt-*, anthropic for claude-*, …) wins, then other natives, then trusted clouds; equal
    /// ranks resolve by sorted provider id so the result never depends on dictionary order.
    static func parse(_ data: Data) -> [String: TokenPricingCatalog.Rate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: TokenPricingCatalog.Rate] = [:]
        var rankForKey: [String: Int] = [:]

        for providerID in root.keys.sorted() {
            guard let provider = root[providerID] as? [String: Any],
                  let models = provider["models"] as? [String: Any]
            else { continue }

            for modelID in models.keys.sorted() {
                guard let model = models[modelID] as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = number(cost["input"]),
                      let output = number(cost["output"]),
                      let key = TokenPricingCatalog.dashedKey(modelID)
                else { continue }
                // Skip a reseller's or coding plan's $0 row so it never clobbers a real list price
                // (e.g. zai-coding-plan glm-5.2 at 0/0 vs zai at $1.40/$4.40); the owner's $0 is the price.
                let rank = providerRank(providerID, forKey: key)
                guard input > 0 || output > 0 || rank >= 1000 else { continue }
                if let existing = rankForKey[key], existing >= rank { continue }

                let anthropic = isAnthropicKey(key)
                let cacheRead = number(cost["cache_read"]) ?? input * 0.1
                let cacheWrite = positive(cost["cache_write"]) ?? (anthropic ? input * 1.25 : nil)
                out[key] = TokenPricingCatalog.Rate(
                    inputPerMTok: input,
                    outputPerMTok: output,
                    cacheReadPerMTok: cacheRead,
                    cacheWritePerMTok: cacheWrite,
                    cacheWrite1hPerMTok: anthropic ? input * 2 : nil,
                    longContextTiers: parseTiers(
                        cost, key: key, input: input, cacheRead: cacheRead, anthropic: anthropic
                    )
                )
                rankForKey[key] = rank
            }
        }
        return out
    }

    private static func parseTiers(
        _ cost: [String: Any],
        key: String,
        input: Double,
        cacheRead: Double,
        anthropic: Bool
    ) -> [TokenPricingCatalog.LongContextTier] {
        var entries: [(threshold: Int, cost: [String: Any])] = []
        if let tiers = cost["tiers"] as? [Any] {
            for case let tier as [String: Any] in tiers {
                guard let spec = tier["tier"] as? [String: Any],
                      (spec["type"] as? String) == "context",
                      let size = number(spec["size"]).map({ Int($0) }), size > 0
                else { continue }
                // "200001" means "from 200,001 tokens", the same boundary as "above 200,000".
                entries.append((size % 1000 == 1 ? size - 1 : size, tier))
            }
        } else if let over = cost["context_over_200k"] as? [String: Any] {
            let threshold = TokenPricingCatalog.staticLongContextThreshold(forDashedKey: key) ?? 200_000
            entries.append((threshold, over))
        }

        var seen = Set<Int>()
        return entries.compactMap { entry in
            guard seen.insert(entry.threshold).inserted,
                  let tierInput = number(entry.cost["input"]),
                  let tierOutput = number(entry.cost["output"])
            else { return nil }
            let ratio = input > 0 ? tierInput / input : 1
            return TokenPricingCatalog.LongContextTier(
                thresholdTokens: entry.threshold,
                inputPerMTok: tierInput,
                outputPerMTok: tierOutput,
                cacheReadPerMTok: number(entry.cost["cache_read"]) ?? cacheRead * ratio,
                cacheWritePerMTok: positive(entry.cost["cache_write"]) ?? (anthropic ? tierInput * 1.25 : nil),
                cacheWrite1hPerMTok: anthropic ? tierInput * 2 : nil
            )
        }
    }

    private static func isAnthropicKey(_ key: String) -> Bool {
        key.contains("claude") || key.contains("opus") || key.contains("sonnet") || key.contains("haiku")
    }

    private static let familyOwners: [(prefix: String, owner: String)] = [
        ("gpt-", "openai"), ("chatgpt-", "openai"), ("codex-", "openai"),
        ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
        ("claude-", "anthropic"),
        ("grok-", "xai"),
        ("gemini-", "google"), ("gemma-", "google"),
        ("glm-", "zai"),
        ("kimi-", "moonshotai"),
        ("qwen", "alibaba"), ("qwq-", "alibaba"), ("qvq-", "alibaba"),
        ("deepseek-", "deepseek"),
        ("mistral-", "mistral"), ("codestral-", "mistral"), ("devstral-", "mistral"), ("magistral-", "mistral"),
    ]

    private static let nativeProviders: Set<String> = [
        "openai", "anthropic", "google", "xai", "deepseek", "zai", "z-ai", "zhipuai",
        "moonshotai", "alibaba", "meta", "meta-llama", "mistral", "cohere",
    ]

    private static let trustedProviders: Set<String> = [
        "google-vertex", "google-vertex-anthropic", "amazon-bedrock", "azure",
        "vercel", "openrouter", "requesty", "fireworks-ai", "togetherai", "deepinfra",
    ]

    static func ownerProvider(forKey key: String) -> String? {
        familyOwners.first { key.hasPrefix($0.prefix) }?.owner
    }

    /// Owner of the model family > other native model owners > trusted clouds > everything else.
    static func providerRank(_ id: String, forKey key: String) -> Int {
        if let owner = ownerProvider(forKey: key), owner == id { return 1000 }
        if nativeProviders.contains(id) { return 100 }
        if trustedProviders.contains(id) { return 50 }
        return 10
    }

    private static func positive(_ any: Any?) -> Double? {
        guard let value = number(any), value > 0 else { return nil }
        return value
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: - Disk cache

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("VibeRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pricing-cache.json")
    }

    private static func writeDiskCache(rates: [String: TokenPricingCatalog.Rate], at date: Date) {
        guard let url = cacheURL, let data = encodeCache(rates: rates, at: date) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadDiskCache() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = decodeCache(data)
        else { return }
        lock.lock(); rates = decoded.rates; fetchedAt = decoded.fetchedAt; storeGeneration += 1; lock.unlock()
    }

    /// `rates` keeps the original flat-number shape so older builds can still read the file;
    /// tiers live under a separate `tiers` key.
    static func encodeCache(rates: [String: TokenPricingCatalog.Rate], at date: Date) -> Data? {
        var serialized: [String: [String: Double]] = [:]
        var serializedTiers: [String: [[String: Double]]] = [:]
        for (key, rate) in rates {
            var r: [String: Double] = [
                "in": rate.inputPerMTok, "out": rate.outputPerMTok, "cr": rate.cacheReadPerMTok,
            ]
            if let cw = rate.cacheWritePerMTok { r["cw"] = cw }
            if let cw1h = rate.cacheWrite1hPerMTok { r["cw1h"] = cw1h }
            serialized[key] = r
            if !rate.longContextTiers.isEmpty {
                serializedTiers[key] = rate.longContextTiers.map { tier in
                    var t: [String: Double] = [
                        "t": Double(tier.thresholdTokens), "in": tier.inputPerMTok,
                        "out": tier.outputPerMTok, "cr": tier.cacheReadPerMTok,
                    ]
                    if let cw = tier.cacheWritePerMTok { t["cw"] = cw }
                    if let cw1h = tier.cacheWrite1hPerMTok { t["cw1h"] = cw1h }
                    return t
                }
            }
        }
        let payload: [String: Any] = [
            "schema": cacheSchema,
            "fetchedAt": date.timeIntervalSince1970,
            "rates": serialized,
            "tiers": serializedTiers,
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// Older caches (no schema/tiers/cw1h) still load: 1-hour writes are re-derived for Anthropic
    /// and `fetchedAt` is dropped so the next `refreshIfStale` refetches tiers promptly.
    static func decodeCache(_ data: Data) -> (rates: [String: TokenPricingCatalog.Rate], fetchedAt: Date?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serialized = root["rates"] as? [String: [String: Double]]
        else { return nil }
        let serializedTiers = root["tiers"] as? [String: [[String: Double]]] ?? [:]
        var loaded: [String: TokenPricingCatalog.Rate] = [:]
        for (key, r) in serialized {
            guard let input = r["in"], let output = r["out"] else { continue }
            let tiers: [TokenPricingCatalog.LongContextTier] = (serializedTiers[key] ?? []).compactMap { t in
                guard let threshold = t["t"], let tierInput = t["in"], let tierOutput = t["out"] else { return nil }
                return TokenPricingCatalog.LongContextTier(
                    thresholdTokens: Int(threshold),
                    inputPerMTok: tierInput,
                    outputPerMTok: tierOutput,
                    cacheReadPerMTok: t["cr"] ?? tierInput * 0.1,
                    cacheWritePerMTok: t["cw"],
                    cacheWrite1hPerMTok: t["cw1h"]
                )
            }
            loaded[key] = TokenPricingCatalog.Rate(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: r["cr"] ?? input * 0.1,
                cacheWritePerMTok: r["cw"],
                cacheWrite1hPerMTok: r["cw1h"] ?? (isAnthropicKey(key) ? input * 2 : nil),
                longContextTiers: tiers
            )
        }
        guard !loaded.isEmpty else { return nil }
        let current = (root["schema"] as? Int) == cacheSchema
        let fetched = current ? (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } : nil
        return (loaded, fetched)
    }
}
