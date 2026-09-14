import Foundation

/// Sends a tiny "dummy" request so a provider's rolling 5-hour quota window
/// starts / advances on demand (Codex/ChatGPT, Claude, Antigravity, etc.).
enum QuotaWakeService {
    enum WakeResult: Equatable {
        case success(message: String)
        case failure(message: String)
    }

    /// Providers that have a rolling ~5-hour / session quota we can wake.
    /// Others (Copilot, Grok, Kiro, Z.AI, …) must not show a Wake button at all.
    static func supportsWake(_ type: ServiceType) -> Bool {
        switch type {
        case .codex, .claude, .antigravity, .gemini:
            return true
        default:
            return false
        }
    }

    /// Whether the Wake control should appear for this account right now.
    /// Hidden unless the provider supports 5h wake *and* (when usage is known)
    /// a session/5h window is actually present.
    static func shouldShowWake(for type: ServiceType, usage: ProviderUsageSnapshot?) -> Bool {
        guard supportsWake(type) else { return false }
        guard let usage else { return true } // still loading — show for supported providers
        if usage.isRefreshing, usage.windows.isEmpty, usage.subAccounts.isEmpty {
            return true
        }
        // Loaded usage with no session window → hide the button.
        if usage.windows.isEmpty, usage.subAccounts.isEmpty, usage.errorMessage != nil {
            return false
        }
        return hasSessionOrFiveHourWindow(usage)
    }

    static func hasSessionOrFiveHourWindow(_ usage: ProviderUsageSnapshot) -> Bool {
        let windows = usage.windows + usage.subAccounts.flatMap(\.windows)
        guard !windows.isEmpty else {
            // Supported provider, no window payload yet — keep available.
            return true
        }
        return windows.contains { isSessionOrFiveHourWindow($0) }
    }

    static func isSessionOrFiveHourWindow(_ window: RateWindow) -> Bool {
        if let minutes = window.windowMinutes, minutes > 0, minutes <= 360 {
            return true
        }
        let label = (window.label ?? window.displayTitle).lowercased()
        return label.contains("5h")
            || label.contains("5-hour")
            || label.contains("five")
            || label.contains("session")
    }

    static func wake(account: AuthAccount, proxyPort: Int = 8317) async -> WakeResult {
        // Always refresh first so native wakes use a live access token.
        _ = await TokenRefreshService.refreshAccountFile(account.filePath)

        guard let rawPayload = NativeUsageFetcher.readAuthPayload(at: account.filePath) else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName)")
        }
        let payload = TokenRefreshService.flattenedAuth(rawPayload)

        // 1) Per-account native wake FIRST. The proxy routes with fill-first, so a
        //    proxy wake engages whichever credential it picks — not necessarily the
        //    account whose card was clicked. Native calls target this account's own
        //    token + account id, which is the only way to wake *this* seat's window.
        let nativeResult = await nativeWake(account: account, payload: payload)
        if case .success(let msg) = nativeResult {
            return .success(message: msg)
        }

        // 2) Proxy wake fallback (covers providers without a native path, and
        //    accounts whose token refresh failed but the proxy can still route).
        let models = await resolveWakeModels(for: account.type, proxyPort: proxyPort)
        let proxyResult = await wakeViaLocalProxy(
            models: models,
            proxyPort: proxyPort,
            label: account.type.displayName
        )
        if case .success(let msg) = proxyResult {
            return .success(
                message: "Woke \(account.type.displayName) window for \(account.baseDisplayName). \(msg)"
            )
        }

        var details = [
            proxyDetail(nativeResult ?? .failure(message: "")),
            proxyDetail(proxyResult),
        ].filter { !$0.isEmpty }
        if details.isEmpty {
            details.append("No wake path available")
        }
        return .failure(
            message: "Could not wake \(account.type.displayName) for \(account.baseDisplayName). \(details.joined(separator: " · ")) Ensure the proxy is running and this account is enabled."
        )
    }

    // MARK: - Native per-account wake

    /// Outcome of a direct provider wake attempt.
    fileprivate enum NativeWakeOutcome {
        case engaged(detail: String)
        case failed(detail: String)
    }

    /// Sends a tiny request *directly to the provider* using this account's own
    /// credentials, so the rolling window starts for exactly this account.
    private static func nativeWake(account: AuthAccount, payload: [String: Any]) async -> WakeResult? {
        switch account.type {
        case .codex:
            guard let accessToken = stringValue(payload, keys: ["access_token"]) else { return nil }
            let accountID = stringValue(payload, keys: ["account_id"])
                ?? chatgptAccountIDFromJWT(accessToken)
            for model in codexWakeModels {
                let outcome = await postCodexResponse(accessToken: accessToken, accountID: accountID, model: model)
                if case .engaged(let detail) = outcome {
                    return .success(message: "Woke Codex window for \(account.baseDisplayName) via OpenAI (\(model))\(detail.isEmpty ? "" : " — \(detail)")")
                }
            }
            return .failure(message: "OpenAI rejected the wake request (all models failed)")
        case .claude:
            guard let accessToken = stringValue(payload, keys: ["access_token"]),
                  await postClaudeMessage(accessToken: accessToken)
            else {
                return .failure(message: "Anthropic rejected the wake request")
            }
            return .success(message: "Woke Claude 5h window for \(account.baseDisplayName) via Anthropic")
        case .antigravity, .gemini:
            guard let accessToken = stringValue(payload, keys: ["access_token"]) else { return nil }
            let projectID = stringValue(payload, keys: ["project_id"])
            for model in cloudCodeWakeModels {
                let outcome = await postCloudCodeGenerate(accessToken: accessToken, projectID: projectID, model: model)
                if case .engaged(let detail) = outcome {
                    return .success(message: "Woke \(account.type.displayName) window for \(account.baseDisplayName) via Cloud Code (\(model))\(detail.isEmpty ? "" : " — \(detail)")")
                }
            }
            return .failure(message: "Cloud Code rejected the wake request (all models failed)")
        default:
            return nil // no native path — caller falls back to the proxy
        }
    }

    /// Codex model IDs the ChatGPT backend currently accepts for OAuth accounts.
    /// (Registry slugs like gpt-5.4-mini are rejected with HTTP 400 "model is not
    /// supported when using Codex with a ChatGPT account" — keep this list in sync
    /// with what /v1/models reports as `owned_by: openai`.)
    private static let codexWakeModels = ["gpt-5.5", "gpt-5.6-luna", "codex-auto-review"]

    /// Cheap Cloud Code models for Antigravity/Gemini wakes.
    private static let cloudCodeWakeModels = ["gemini-3-flash", "gemini-3.1-flash-lite"]

    // MARK: - Model discovery

    /// Resolves wake models from the proxy's live `/v1/models` catalog. IDs are
    /// plain (`gpt-5.5`); there is no `[Provider] model` namespace.
    ///
    /// Matching prefers the catalog's `owned_by` field (e.g. Codex models are
    /// `gpt-5.5`/`codex-auto-review` under `owned_by: openai`) because ID prefixes
    /// alone miss provider-owned models: `gpt-5.5` contains no "codex", and
    /// Antigravity-served IDs look like `gemini-3-flash`, not "antigravity".
    private static func resolveWakeModels(for type: ServiceType, proxyPort: Int) async -> [String] {
        let ports = uniquePorts(proxyPort)
        var entries: [(id: String, owner: String)] = []
        for port in ports {
            if let list = await fetchModelEntries(port: port), !list.isEmpty {
                entries = list
                break
            }
        }

        let owners = Set(ownedByValues(for: type))
        let prefixes = providerPrefixes(for: type)
        let matching = entries.filter { entry in
            if owners.contains(entry.owner) { return true }
            let lower = entry.id.lowercased()
            return prefixes.contains { prefix in
                lower.hasPrefix(prefix) || lower.contains(prefix)
            }
        }

        // Prefer cheap / mini / flash first for a true "dummy" wake.
        let sorted = matching.map(\.id).sorted { lhs, rhs in
            wakePriority(lhs) < wakePriority(rhs)
        }

        var models = Array(sorted.prefix(8))
        // Fallbacks if discovery empty or incomplete.
        for fallback in preferredFallbackModels(for: type) where !models.contains(fallback) {
            models.append(fallback)
        }
        // Universal fallbacks route to whichever provider owns them, so they must
        // never stand in for a provider the proxy cannot serve — that would report
        // a successful wake after pinging somebody else's quota.
        guard hasServableModels(type) else { return models }
        for fallback in ["gpt-5.5", "claude-sonnet-4-20250514", "gemini-3-flash"]
            where !models.contains(fallback)
        {
            models.append(fallback)
        }
        return models
    }

    /// `/v1/models` `owned_by` values that actually serve this provider's quota.
    private static func ownedByValues(for type: ServiceType) -> [String] {
        switch type {
        case .codex: return ["openai"]
        case .claude: return ["anthropic"]
        case .antigravity: return ["antigravity"]
        case .gemini: return ["antigravity", "gemini"]
        case .copilot: return ["github-copilot", "copilot"]
        case .kiro: return ["kiro"]
        case .zai: return ["zai", "zhipu"]
        case .grok: return ["xai"]
        case .kimi: return ["kimi", "moonshot"]
        default: return [type.rawValue]
        }
    }

    private static func providerPrefixes(for type: ServiceType) -> [String] {
        switch type {
        case .codex: return ["[codex]", "codex"]
        case .claude: return ["[claude]", "claude"]
        // Antigravity-served model IDs look like `gemini-3-flash` / `claude-sonnet-4-6`.
        case .antigravity: return ["[antigravity]", "antigravity", "gemini"]
        case .gemini: return ["[gemini]", "gemini"]
        case .copilot: return ["[github-copilot]", "github-copilot", "copilot"]
        case .kiro: return ["[kiro]", "kiro"]
        case .zai: return ["[z", "glm", "zai"]
        case .grok: return ["[xai]", "[grok]", "grok", "xai"]
        case .kimi: return ["[kimi]", "kimi", "moonshot"]
        default: return [type.rawValue]
        }
    }

    private static func preferredFallbackModels(for type: ServiceType) -> [String] {
        switch type {
        case .codex:
            // ChatGPT OAuth rejects registry-era slugs (gpt-5.4 / gpt-5.4-mini /
            // codex-mini-latest) with HTTP 400 — only current backend models work.
            return [
                "gpt-5.5",
                "gpt-5.6-luna",
                "codex-auto-review",
            ]
        case .claude:
            return [
                "claude-3-5-haiku-20241022",
                "claude-sonnet-4-20250514",
                "claude-sonnet-4-5-20250929",
            ]
        case .antigravity:
            return [
                "gemini-3-flash",
                "gemini-3.1-flash-lite",
                "gemini-3.5-flash-lite",
            ]
        case .gemini:
            return [
                "gemini-3-flash",
                "gemini-3.1-flash-lite",
            ]
        case .zai:
            return ["glm-5.1", "glm-5.2"]
        case .grok:
            return ["grok-3-mini", "grok-3-mini-fast"]
        default:
            // Kiro and Copilot have no executor in the bundled proxy, so there is
            // no model to wake; returning none keeps the failure honest.
            return []
        }
    }

    /// Providers the bundled proxy can actually route a request to. Kiro and
    /// Copilot ship auth + usage metering only — no server-side executor.
    private static func hasServableModels(_ type: ServiceType) -> Bool {
        switch type {
        case .kiro, .copilot:
            return false
        default:
            return true
        }
    }

    private static func wakePriority(_ model: String) -> Int {
        let m = model.lowercased()
        if m.contains("mini") || m.contains("flash") || m.contains("haiku") || m.contains("lite") || m.contains("auto") {
            return 0
        }
        if m.contains("image") || m.contains("embedding") || m.contains("thinking") || m.contains("opus") {
            return 50
        }
        return 10
    }

    private static func fetchModelEntries(port: Int) async -> [(id: String, owner: String)]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]]
            else { return nil }
            return list.map { entry in
                (stringValue(entry, keys: ["id"]) ?? "", stringValue(entry, keys: ["owned_by"]) ?? "")
            }
        } catch {
            return nil
        }
    }

    // MARK: - Local proxy

    private static func uniquePorts(_ preferred: Int) -> [Int] {
        var seen = Set<Int>()
        return [preferred, 8317, 8318].filter { seen.insert($0).inserted }
    }

    private static func wakeViaLocalProxy(
        models: [String],
        proxyPort: Int,
        label: String
    ) async -> WakeResult {
        let ports = uniquePorts(proxyPort)
        var lastError = "Proxy not reachable on port \(proxyPort). Start the server from the menu bar."

        for port in ports {
            for model in models {
                switch await postLocalCompletion(port: port, model: model) {
                case .success:
                    return .success(message: "via localhost:\(port) · \(model)")
                case .failure(let message):
                    lastError = message
                    // Don't burn timeouts on unknown-model 4xx/5xx — continue quickly.
                    if message.contains("unknown provider") || message.contains("HTTP 40") || message.contains("HTTP 50") {
                        continue
                    }
                }
            }
        }
        return .failure(message: lastError)
    }

    private static func postLocalCompletion(port: Int, model: String) async -> WakeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            return .failure(message: "Invalid proxy URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Keep wake snappy — previous 90s timeouts made the button feel broken.
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer viberouter-wake", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Reply with the single word OK."]
            ],
            "max_tokens": 1,
            "stream": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Invalid proxy response")
            }
            if (200...299).contains(http.statusCode) {
                return .success(message: "ok")
            }
            // Rate limit still engages the window.
            if http.statusCode == 429 {
                return .success(message: "ok-rate-limited")
            }
            let snippet = String(data: data.prefix(160), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            return .failure(message: "Proxy HTTP \(http.statusCode) for \(model): \(snippet)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Direct provider wakes

    /// Codex wake against the ChatGPT backend. Mirrors what the bundled proxy's
    /// executor sends: `stream` MUST be true and `input` MUST be a list — the
    /// backend answers HTTP 400 "Input must be a list" / "Stream must be set to
    /// true" otherwise. HTTP 429 (usage_limit_reached) still means the request
    /// landed on this account and engaged the window, so it counts as success.
    private static func postCodexResponse(
        accessToken: String,
        accountID: String?,
        model: String
    ) async -> NativeWakeOutcome {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/responses") else {
            return .failed(detail: "Invalid Codex URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        let body: [String: Any] = [
            "model": model,
            "instructions": "",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "Reply with the single word OK."]
                    ],
                ]
            ],
            "store": false,
            "stream": true,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(detail: "Invalid Codex response")
            }
            if (200...299).contains(http.statusCode) {
                return .engaged(detail: "")
            }
            if http.statusCode == 429 {
                return .engaged(detail: codexRateLimitDetail(data))
            }
            let snippet = String(data: data.prefix(160), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? ""
            return .failed(detail: "OpenAI HTTP \(http.statusCode) for \(model): \(snippet)")
        } catch {
            return .failed(detail: error.localizedDescription)
        }
    }

    /// Extracts a short human hint from a Codex 429 body (`resets_at`).
    private static func codexRateLimitDetail(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "usage limit reached"
        }
        let resetSeconds: Int?
        if let value = json["resets_in_seconds"] as? NSNumber {
            resetSeconds = value.intValue
        } else if let value = json["resets_in_seconds"] as? Int {
            resetSeconds = value
        } else {
            resetSeconds = nil
        }
        if let resetSeconds, resetSeconds > 0 {
            let minutes = (resetSeconds + 59) / 60
            if minutes >= 60 {
                let hours = (minutes + 30) / 60
                return "window engaged but usage limit reached — resets in ~\(hours)h"
            }
            return "window engaged but usage limit reached — resets in ~\(max(1, minutes))m"
        }
        return "window engaged but usage limit reached"
    }

    private static func postClaudeMessage(accessToken: String) async -> Bool {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "ping"]
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode) || http.statusCode == 429
        } catch {
            return false
        }
    }

    /// Antigravity/Gemini wake against the Cloud Code backend using this
    /// account's own OAuth token — same `v1internal:generateContent` shape the
    /// bundled proxy and the Antigravity IDE send (daily host first, prod
    /// fallback). HTTP 429 still engages the account's window.
    private static func postCloudCodeGenerate(
        accessToken: String,
        projectID: String?,
        model: String
    ) async -> NativeWakeOutcome {
        let hosts = [
            "https://daily-cloudcode-pa.googleapis.com",
            "https://cloudcode-pa.googleapis.com",
        ]
        var body: [String: Any] = [
            "model": model,
            "request": [
                "contents": [
                    [
                        "role": "user",
                        "parts": [["text": "Reply with the single word OK."]],
                    ]
                ],
            ],
        ]
        if let projectID, !projectID.isEmpty {
            body["project"] = projectID
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failed(detail: "Could not build Cloud Code request")
        }

        var lastDetail = "No Cloud Code host tried"
        for host in hosts {
            guard let url = URL(string: "\(host)/v1internal:generateContent") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(NativeUsageFetcher.cloudCodeUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("gl-node/22.21.1", forHTTPHeaderField: "X-Goog-Api-Client")
            request.httpBody = bodyData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastDetail = "Invalid Cloud Code response"
                    continue
                }
                if (200...299).contains(http.statusCode) || http.statusCode == 429 {
                    return .engaged(detail: "")
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    // Auth problem — the fallback host will reject the same token.
                    return .failed(detail: "Cloud Code session rejected (HTTP \(http.statusCode))")
                }
                let snippet = String(data: data.prefix(160), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
                lastDetail = "Cloud Code HTTP \(http.statusCode) for \(model): \(snippet)"
            } catch {
                lastDetail = error.localizedDescription
            }
        }
        return .failed(detail: lastDetail)
    }

    private static func chatgptAccountIDFromJWT(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return (auth["chatgpt_account_id"] as? String) ?? (auth["account_id"] as? String)
    }

    private static func proxyDetail(_ result: WakeResult) -> String {
        if case .failure(let message) = result { return message }
        return ""
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
