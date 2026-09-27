import Foundation
import SQLite3

/// Serves Kiro-backed models directly, because the bundled proxy has no Kiro
/// executor and upstream CLIProxyAPI does not ship one either.
///
/// Kiro answers on the CodeWhisperer surface with an AWS event stream. This
/// translates the Anthropic Messages API in both directions, so Claude Code can
/// spend a Kiro subscription the same way it spends an Anthropic one.
///
/// Requests are buffered and then replayed as SSE rather than relayed
/// incrementally: correctness first, and a Kiro turn is short enough that the
/// added latency is the model's own think time, not ours.
enum KiroDirectProvider {
    static let endpoint = "https://codewhisperer.us-east-1.amazonaws.com/generateAssistantResponse"
    static let modelPrefix = "kiro/"

    struct CatalogModel: Equatable {
        let id: String
        let blurb: String
    }

    /// Used when `kiro-cli chat --list-models` is unavailable. Kept in the
    /// same order the CLI prints, so the picker matches Kiro.
    static let fallbackModels: [CatalogModel] = [
        CatalogModel(id: "auto", blurb: "Kiro picks the model"),
        CatalogModel(id: "claude-opus-5.5", blurb: "Claude Opus 5.5"),
        CatalogModel(id: "claude-opus-5", blurb: "Claude Opus 5"),
        CatalogModel(id: "claude-sonnet-5", blurb: "Claude Sonnet 5"),
        CatalogModel(id: "claude-opus-4.8", blurb: "Claude Opus 4.8"),
        CatalogModel(id: "gpt-5.6-sol", blurb: "GPT 5.6 Sol"),
        CatalogModel(id: "gpt-5.6-terra", blurb: "GPT 5.6 Terra"),
        CatalogModel(id: "gpt-5.6-luna", blurb: "GPT 5.6 Luna"),
        CatalogModel(id: "claude-opus-4.7", blurb: "Claude Opus 4.7"),
        CatalogModel(id: "claude-opus-4.6", blurb: "Claude Opus 4.6"),
        CatalogModel(id: "claude-sonnet-4.6", blurb: "Claude Sonnet 4.6"),
        CatalogModel(id: "claude-opus-4.5", blurb: "Claude Opus 4.5"),
        CatalogModel(id: "claude-sonnet-4.5", blurb: "Claude Sonnet 4.5"),
        CatalogModel(id: "claude-sonnet-4", blurb: "Claude Sonnet 4"),
        CatalogModel(id: "claude-haiku-4.5", blurb: "Claude Haiku 4.5"),
        CatalogModel(id: "deepseek-3.2", blurb: "DeepSeek 3.2"),
        CatalogModel(id: "minimax-m2.5", blurb: "MiniMax M2.5"),
        CatalogModel(id: "minimax-m2.1", blurb: "MiniMax M2.1"),
        CatalogModel(id: "glm-5", blurb: "GLM-5"),
        CatalogModel(id: "qwen3-coder-next", blurb: "Qwen3 Coder Next"),
    ]

    /// Bare IDs the first executor accepted. New models are `kiro/<id>` only,
    /// so a plain `claude-opus-4-8` still belongs to whatever provider serves it.
    private static let legacyBareIDs: Set<String> = [
        "auto", "claude-sonnet-4.5", "claude-sonnet-4", "claude-haiku-4.5",
    ]

    private static let catalogLock = NSLock()
    private static var catalogCache: (at: Date, ttl: TimeInterval, models: [CatalogModel])?

    /// Live `kiro-cli --list-models` when it answers, otherwise `fallbackModels`.
    static func catalog() -> [CatalogModel] {
        catalogLock.lock()
        if let catalogCache, Date().timeIntervalSince(catalogCache.at) < catalogCache.ttl {
            let models = catalogCache.models
            catalogLock.unlock()
            return models
        }
        catalogLock.unlock()
        if let live = fetchCLIModels(), !live.isEmpty {
            storeCatalog(live, ttl: 600)
            return live
        }
        storeCatalog(fallbackModels, ttl: 60)
        return fallbackModels
    }

    static func parseListModelsJSON(_ data: Data) -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        var models: [CatalogModel] = []
        for row in rows {
            guard let id = row["model_id"] as? String ?? row["modelId"] as? String,
                  isSafeModelID(id), seen.insert(id).inserted
            else { continue }
            let blurb = (row["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            models.append(CatalogModel(id: id, blurb: blurb.isEmpty ? id : blurb))
        }
        return models
    }

    static var advertisedModelIDs: [String] { catalog().map { modelPrefix + $0.id } }

    /// Picker title. Claude Code shows this instead of the raw id.
    static func pickerLabel(forUpstreamID id: String) -> String {
        "[VibeRouter] Kiro · \(prettyModelName(id))"
    }

    static func catalogEntry(for model: CatalogModel) -> [String: Any] {
        [
            "id": modelPrefix + model.id,
            "object": "model",
            "type": "model",
            "owned_by": "viberouter",
            "display_name": pickerLabel(forUpstreamID: model.id),
            "description": "Kiro via VibeRouter — \(model.blurb)",
        ]
    }

    static func isKiroModel(_ model: String) -> Bool {
        upstreamModel(for: model) != nil
    }

    /// Claude Code posts `/v1/messages?beta=true` and `/v1/messages/count_tokens`.
    /// The query string is not part of the route.
    enum HTTPRoute: Equatable {
        case messages
        case countTokens
    }

    static func httpRoute(for path: String) -> HTTPRoute? {
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if bare.hasSuffix("/v1/messages/count_tokens") { return .countTokens }
        if bare.hasSuffix("/v1/messages") { return .messages }
        return nil
    }

    static func modelName(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["model"] as? String
    }

    /// `kiro/claude-opus-5.5` and the original bare Sonnet/Haiku/auto IDs.
    static func upstreamModel(for model: String) -> String? {
        let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix(modelPrefix) {
            let id = String(raw.dropFirst(modelPrefix.count))
            return isSafeModelID(id) ? id : nil
        }
        return legacyBareIDs.contains(raw) ? raw : nil
    }

    static func isSafeModelID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 80, !id.contains("/"), !id.contains(" ") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    private static func prettyModelName(_ id: String) -> String {
        id.split(separator: "-").map { part in
            guard let first = part.first else { return "" }
            if first.isNumber { return String(part) }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    private static func storeCatalog(_ models: [CatalogModel], ttl: TimeInterval) {
        catalogLock.lock()
        catalogCache = (Date(), ttl, models)
        catalogLock.unlock()
    }

    private static func fetchCLIModels() -> [CatalogModel]? {
        let binary = resolveKiroCLI()
        guard let binary else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["chat", "--list-models", "--format", "json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(12)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let models = parseListModelsJSON(data)
        return models.isEmpty ? nil : models
    }

    private static func resolveKiroCLI() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kiro-cli").path,
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Credentials

    /// The kiro-cli social login is the Power subscription. The builder-id file
    /// in ~/.cli-proxy-api can be a different, already-limited account.
    static func accessToken() async -> String? {
        if let token = cliSocialAccessToken() { return token }
        if cliSocialPayload() != nil, refreshCLISession(), let token = cliSocialAccessToken() {
            return token
        }
        return await authFileAccessToken()
    }

    /// Newest non-disabled Kiro auth file, refreshed when the token has expired.
    private static func authFileAccessToken() async -> String? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let candidates = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("kiro-") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }

        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["disabled"] as? Bool) != true
            else { continue }

            if let token = payload["access_token"] as? String, !token.isEmpty, !isExpired(payload) {
                return token
            }
            if let refreshed = await KiroAWSAuth.refresh(payload) {
                if let out = try? JSONSerialization.data(withJSONObject: refreshed, options: [.prettyPrinted, .sortedKeys]) {
                    try? out.write(to: file, options: .atomic)
                }
                if let token = refreshed["access_token"] as? String, !token.isEmpty { return token }
            }
        }
        return nil
    }

    private static func cliSocialPayload() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM auth_kv WHERE key = 'kirocli:social:token' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else { return nil }
        let raw = String(cString: cString)
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload
    }

    private static func cliSocialAccessToken() -> String? {
        guard let payload = cliSocialPayload(),
              let token = payload["access_token"] as? String, !token.isEmpty,
              !isExpired(payload)
        else { return nil }
        return token
    }

    /// Lets kiro-cli refresh its own social token and write it back. We do not
    /// rotate that refresh token ourselves.
    private static func refreshCLISession() -> Bool {
        guard let binary = resolveKiroCLI() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["chat", "--list-models", "--format", "json"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        let deadline = Date().addingTimeInterval(20)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { proc.terminate(); return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private static func isExpired(_ payload: [String: Any]) -> Bool {
        let keys = ["expires_at", "expired"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for key in keys {
            guard let raw = payload[key] as? String else { continue }
            if let date = formatter.date(from: raw) ?? plain.date(from: raw) {
                // Refresh a little early so a long turn cannot expire mid-flight.
                return date.timeIntervalSinceNow < 120
            }
        }
        return true
    }

    // MARK: - Anthropic → CodeWhisperer

    struct TranslatedRequest {
        let conversationState: [String: Any]
        let model: String
        let stream: Bool
        let systemPrompt: String
        /// Rough char/4 figure. Kiro reports credits, never tokens, so the
        /// Anthropic-shaped `usage` block can only ever be an estimate.
        let estimatedInputTokens: Int
    }

    static func translateRequest(anthropicBody: String) -> TranslatedRequest? {
        guard let data = anthropicBody.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestedModel = root["model"] as? String,
              let model = upstreamModel(for: requestedModel),
              let messages = root["messages"] as? [[String: Any]]
        else { return nil }

        let stream = (root["stream"] as? Bool) ?? false
        let systemText = systemPrompt(from: root["system"])
        let tools = toolSpecifications(from: root["tools"])

        var turns: [Turn] = messages.compactMap(Turn.init(message:))
        guard !turns.isEmpty else { return nil }

        // Kiro rebuilds the conversation from scratch on every call, so the
        // system prompt rides on the first user turn and stays stable.
        if !systemText.isEmpty, let index = turns.firstIndex(where: { $0.role == "user" }) {
            turns[index].text = systemText + "\n\n" + turns[index].text
        }

        // Kiro validates history strictly: user/assistant must alternate, every
        // toolResult must pair with the toolUse of the assistant right before
        // it, and every tool name used in history must exist in the request's
        // tool list. Claude Code histories can violate all of that after a
        // rewind, compaction, or a mid-session model switch, and Kiro then 400s
        // the call ("unexpected `tool_use_id` found in `tool_result`"), which
        // Claude Code surfaces as the orphaned-tool_result error that only
        // /rewind recovers from. Fold and repair the shape instead.
        let merged = mergedTurns(
            turns.filter { !($0.role == "assistant" && $0.text.isEmpty && $0.toolUses.isEmpty) }
        )
        guard !merged.isEmpty else { return nil }

        let currentIndex = merged.lastIndex(where: { $0.role == "user" }) ?? (merged.count - 1)
        var current = merged[currentIndex]
        var history = repairHistory(Array(merged[..<currentIndex]), currentResults: current.toolResults)

        // The current user turn's results need matching uses in the last
        // history assistant; synthesize any that the history no longer carries.
        if !current.toolResults.isEmpty {
            if var last = history.popLast() {
                let paired = Set(last.toolUses.compactMap { $0["toolUseId"] as? String })
                let missing = current.toolResults.filter {
                    !paired.contains($0["toolUseId"] as? String ?? "")
                }
                if !missing.isEmpty {
                    if last.text.isEmpty { last.text = "Tool calls were made." }
                    last.toolUses += missing.map { syntheticUse(for: $0) }
                }
                history.append(last)
            } else {
                // Nothing precedes the turn, so the results cannot be paired
                // at all; dropping them beats failing the whole request.
                current.toolResults = []
            }
        }

        // Kiro checks tool names referenced in history against the request's
        // tool list; re-add any the current turn no longer advertises.
        var requestTools = tools
        let historyToolNames = Set(history.flatMap { $0.toolUses.compactMap { $0["name"] as? String } })
        let advertised = Set(requestTools.compactMap {
            ($0["toolSpecification"] as? [String: Any])?["name"] as? String
        })
        for name in historyToolNames.sorted() where !advertised.contains(name) {
            requestTools.append(["toolSpecification": [
                "name": name,
                "description": "Tool",
                "inputSchema": ["json": ["type": "object", "properties": [String: Any]()]],
            ]])
        }

        var conversationState: [String: Any] = [
            "chatTriggerType": "MANUAL",
            "conversationId": UUID().uuidString,
            "currentMessage": ["userInputMessage": userInputMessage(current, model: model, tools: requestTools)],
            "history": history.map { turn in
                turn.role == "user"
                    ? ["userInputMessage": userInputMessage(turn, model: model, tools: [])]
                    : ["assistantResponseMessage": assistantResponseMessage(turn)]
            },
        ]
        let effortFields = modelRequestFields(from: root, model: model)
        if !effortFields.isEmpty {
            conversationState["__effort"] = effortFields
        }

        let promptChars = merged.reduce(0) { $0 + $1.text.utf8.count } + systemText.utf8.count
        return TranslatedRequest(
            conversationState: conversationState,
            model: requestedModel,
            stream: stream,
            systemPrompt: systemText,
            estimatedInputTokens: max(1, promptChars / 4)
        )
    }

    /// Claude Code sends `output_config.effort` (and adaptive thinking) on the
    /// Messages body. Kiro reads that as `additionalModelRequestFields`, and
    /// only some models accept it.
    static func modelRequestFields(from root: [String: Any], model: String) -> [String: Any] {
        guard acceptsEffort(model) else { return [:] }
        var fields: [String: Any] = [:]
        if let output = root["output_config"] as? [String: Any],
           let effort = clampedEffort(output["effort"] as? String, model: model) {
            fields["output_config"] = ["effort": effort]
        }
        if let thinking = root["thinking"] as? [String: Any],
           (thinking["type"] as? String)?.lowercased() == "adaptive" {
            var block: [String: Any] = ["type": "adaptive"]
            if let display = (thinking["display"] as? String)?.lowercased(),
               display == "summarized" || display == "omitted" {
                block["display"] = display
            }
            fields["thinking"] = block
        }
        return fields
    }

    static func acceptsEffort(_ model: String) -> Bool {
        let id = model.lowercased()
        if id == "auto" || id.contains("haiku") || id.hasPrefix("gpt-")
            || id.hasPrefix("glm") || id.hasPrefix("qwen")
            || id.hasPrefix("deepseek") || id.hasPrefix("minimax") {
            return false
        }
        return id.contains("opus-5") || id.contains("opus-4-8") || id.contains("opus-4-7")
            || id.contains("opus-4-6") || id.contains("sonnet-5") || id.contains("sonnet-4-6")
    }

    /// Opus/Sonnet 4.6 have no `xhigh`; the next step those models accept is `max`.
    static func clampedEffort(_ raw: String?, model: String) -> String? {
        guard var effort = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !effort.isEmpty
        else { return nil }
        if effort == "x-high" || effort == "extra-high" || effort == "extrahigh" { effort = "xhigh" }
        let noXHigh = model.lowercased().contains("opus-4-6") || model.lowercased().contains("sonnet-4-6")
        let allowed: Set<String> = noXHigh
            ? ["low", "medium", "high", "max"]
            : ["low", "medium", "high", "xhigh", "max"]
        if allowed.contains(effort) { return effort }
        if effort == "xhigh", allowed.contains("max") { return "max" }
        return nil
    }

    struct Turn {
        var role: String
        var text: String
        var toolUses: [[String: Any]] = []
        var toolResults: [[String: Any]] = []

        init?(message: [String: Any]) {
            guard let role = message["role"] as? String else { return nil }
            self.role = role
            var text = ""
            if let plain = message["content"] as? String {
                text = plain
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let value = block["text"] as? String { text += value }
                    case "tool_use":
                        if let id = block["id"] as? String, let name = block["name"] as? String {
                            toolUses.append([
                                "toolUseId": id,
                                "name": name,
                                "input": block["input"] as? [String: Any] ?? [:],
                            ])
                        }
                    case "tool_result":
                        if let id = block["tool_use_id"] as? String {
                            let isError = (block["is_error"] as? Bool) ?? false
                            toolResults.append([
                                "toolUseId": id,
                                "status": isError ? "error" : "success",
                                "content": [["text": KiroDirectProvider.toolResultText(block["content"])]],
                            ])
                        }
                    default:
                        break
                    }
                }
            }
            self.text = text
        }
    }

    /// Fold consecutive same-role turns so the sequence strictly alternates.
    /// Claude Code merges tool results and queued messages into back-to-back
    /// user turns; the previous builder silently dropped the earlier ones.
    static func mergedTurns(_ turns: [Turn]) -> [Turn] {
        var merged: [Turn] = []
        for turn in turns {
            if let last = merged.last, last.role == turn.role {
                let joiner = (!last.text.isEmpty && !turn.text.isEmpty) ? "\n\n" : ""
                merged[merged.count - 1].text += joiner + turn.text
                merged[merged.count - 1].toolUses += turn.toolUses
                merged[merged.count - 1].toolResults += turn.toolResults
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    /// Shape a raw turn sequence into history Kiro accepts:
    /// - starts with a plain user turn,
    /// - strictly alternates user/assistant,
    /// - every assistant toolUse is answered by the following user turn,
    /// - every toolResult is covered by the preceding assistant's toolUses.
    /// `currentResults` are the results riding on the current user turn; they
    /// answer the last history assistant's uses.
    static func repairHistory(_ turns: [Turn], currentResults: [[String: Any]] = []) -> [Turn] {
        var entries = mergedTurns(turns)
        // Kiro's history must start with a plain user turn. Drop leading
        // assistant turns; a leading user turn cannot carry toolResults, so
        // strip those — and drop the entry entirely when nothing but the
        // results would remain, since Bedrock rejects whitespace-only turns.
        while !entries.isEmpty {
            if entries[0].role != "user" { entries.removeFirst(); continue }
            if !entries[0].toolResults.isEmpty {
                let keepText = !entries[0].text.isEmpty
                entries[0].toolResults = []
                if !keepText { entries.removeFirst(); continue }
            }
            break
        }
        guard !entries.isEmpty else { return entries }

        // Uses the following user turn never answers make Kiro demand their
        // results; trim each assistant down to what was actually reported.
        // The last entry's results may ride on the current turn instead.
        for index in entries.indices where entries[index].role == "assistant" {
            guard !entries[index].toolUses.isEmpty else { continue }
            let answered = index + 1 < entries.count
                ? Set(entries[index + 1].toolResults.compactMap { $0["toolUseId"] as? String })
                : Set(currentResults.compactMap { $0["toolUseId"] as? String })
            entries[index].toolUses = entries[index].toolUses.filter {
                answered.contains($0["toolUseId"] as? String ?? "")
            }
        }

        // Results whose uses the history no longer carries get a synthetic use
        // on the assistant right before them so the pairing holds.
        for index in entries.indices
        where entries[index].role == "user" && !entries[index].toolResults.isEmpty {
            guard index > 0, entries[index - 1].role == "assistant" else { continue }
            let paired = Set(entries[index - 1].toolUses.compactMap { $0["toolUseId"] as? String })
            let missing = entries[index].toolResults.filter {
                !paired.contains($0["toolUseId"] as? String ?? "")
            }
            guard !missing.isEmpty else { continue }
            if entries[index - 1].text.isEmpty { entries[index - 1].text = "Tool calls were made." }
            entries[index - 1].toolUses += missing.map { syntheticUse(for: $0) }
        }
        return entries
    }

    private static func syntheticUse(for result: [String: Any]) -> [String: Any] {
        ["toolUseId": result["toolUseId"] ?? "", "name": "unknown_tool", "input": [String: Any]()]
    }

    static func toolResultText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let blocks = raw as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let nested = block["content"] as? String { return nested }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let raw, let data = try? JSONSerialization.data(withJSONObject: raw),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private static func userInputMessage(_ turn: Turn, model: String, tools: [[String: Any]]) -> [String: Any] {
        var message: [String: Any] = [
            // An empty content field is rejected; a tool-result-only turn still needs one.
            "content": turn.text.isEmpty ? " " : turn.text,
            "modelId": model,
            "origin": "AI_EDITOR",
        ]
        var context: [String: Any] = [:]
        if !tools.isEmpty { context["tools"] = tools }
        if !turn.toolResults.isEmpty { context["toolResults"] = turn.toolResults }
        if !context.isEmpty { message["userInputMessageContext"] = context }
        return message
    }

    private static func assistantResponseMessage(_ turn: Turn) -> [String: Any] {
        var message: [String: Any] = ["content": turn.text]
        if !turn.toolUses.isEmpty { message["toolUses"] = turn.toolUses }
        return message
    }

    static func systemPrompt(from raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        return ""
    }

    static func toolSpecifications(from raw: Any?) -> [[String: Any]] {
        guard let tools = raw as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["input_schema"] as? [String: Any]
                ?? ["type": "object", "properties": [:]]
            return [
                "toolSpecification": [
                    "name": name,
                    "description": (tool["description"] as? String) ?? name,
                    "inputSchema": ["json": schema],
                ],
            ]
        }
    }

    // MARK: - AWS event stream

    struct Frame {
        let eventType: String
        let payload: [String: Any]
    }

    /// Frame layout: 4B total length, 4B header length, 4B prelude CRC, headers,
    /// payload, 4B message CRC. Only `:event-type` and the JSON payload matter here.
    static func decodeFrames(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        let bytes = [UInt8](data)
        var offset = 0

        func be32(_ index: Int) -> Int {
            guard index + 4 <= bytes.count else { return 0 }
            return (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16)
                | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
        }

        while offset + 16 <= bytes.count {
            let total = be32(offset)
            let headerLength = be32(offset + 4)
            guard total >= 16, offset + total <= bytes.count else { break }

            var eventType = ""
            var cursor = offset + 12
            let headerEnd = cursor + headerLength
            while cursor < headerEnd, cursor < bytes.count {
                let nameLength = Int(bytes[cursor])
                cursor += 1
                guard cursor + nameLength <= bytes.count else { break }
                let name = String(decoding: bytes[cursor..<(cursor + nameLength)], as: UTF8.self)
                cursor += nameLength
                guard cursor < bytes.count else { break }
                let valueType = bytes[cursor]
                cursor += 1
                guard valueType == 7, cursor + 2 <= bytes.count else { break }
                let valueLength = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
                cursor += 2
                guard cursor + valueLength <= bytes.count else { break }
                let value = String(decoding: bytes[cursor..<(cursor + valueLength)], as: UTF8.self)
                cursor += valueLength
                if name == ":event-type" { eventType = value }
            }

            let payloadStart = offset + 12 + headerLength
            let payloadEnd = offset + total - 4
            if payloadStart < payloadEnd, payloadEnd <= bytes.count {
                let payloadData = Data(bytes[payloadStart..<payloadEnd])
                if let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    frames.append(Frame(eventType: eventType, payload: json))
                }
            }
            offset += total
        }
        return frames
    }

    // MARK: - CodeWhisperer → Anthropic

    struct AssembledReply {
        var text = ""
        var toolCalls: [ToolCall] = []
        var credits: Double = 0

        struct ToolCall {
            let id: String
            let name: String
            var argumentsJSON: String
        }

        var stopReason: String { toolCalls.isEmpty ? "end_turn" : "tool_use" }
        var estimatedOutputTokens: Int {
            let chars = text.utf8.count + toolCalls.reduce(0) { $0 + $1.argumentsJSON.utf8.count }
            return max(1, chars / 4)
        }
    }

    static func assemble(frames: [Frame]) -> AssembledReply {
        var reply = AssembledReply()
        var order: [String] = []
        var byID: [String: AssembledReply.ToolCall] = [:]

        for frame in frames {
            switch frame.eventType {
            case "assistantResponseEvent":
                if let content = frame.payload["content"] as? String { reply.text += content }
            case "toolUseEvent":
                guard let id = frame.payload["toolUseId"] as? String else { continue }
                let name = (frame.payload["name"] as? String) ?? ""
                if byID[id] == nil {
                    order.append(id)
                    byID[id] = AssembledReply.ToolCall(id: id, name: name, argumentsJSON: "")
                }
                // `input` arrives as incremental JSON fragments that concatenate.
                if let fragment = frame.payload["input"] as? String {
                    byID[id]?.argumentsJSON += fragment
                }
            case "meteringEvent":
                if let usage = frame.payload["usage"] as? Double { reply.credits += usage }
            default:
                break
            }
        }
        reply.toolCalls = order.compactMap { byID[$0] }
        return reply
    }

    static func anthropicMessageJSON(
        reply: AssembledReply,
        model: String,
        inputTokens: Int
    ) -> [String: Any] {
        var content: [[String: Any]] = []
        if !reply.text.isEmpty {
            content.append(["type": "text", "text": reply.text])
        }
        for call in reply.toolCalls {
            content.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": parsedToolInput(call.argumentsJSON),
            ])
        }
        if content.isEmpty {
            content.append(["type": "text", "text": ""])
        }
        return [
            "id": "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": reply.stopReason,
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": inputTokens, "output_tokens": reply.estimatedOutputTokens],
        ]
    }

    static func parsedToolInput(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func anthropicSSE(reply: AssembledReply, model: String, inputTokens: Int) -> String {
        func event(_ name: String, _ object: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let json = String(data: data, encoding: .utf8)
            else { return "" }
            return "event: \(name)\ndata: \(json)\n\n"
        }

        let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"
        var out = event("message_start", [
            "type": "message_start",
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": ["input_tokens": inputTokens, "output_tokens": 0],
            ],
        ])

        var index = 0
        if !reply.text.isEmpty {
            out += event("content_block_start", [
                "type": "content_block_start", "index": index,
                "content_block": ["type": "text", "text": ""],
            ])
            out += event("content_block_delta", [
                "type": "content_block_delta", "index": index,
                "delta": ["type": "text_delta", "text": reply.text],
            ])
            out += event("content_block_stop", ["type": "content_block_stop", "index": index])
            index += 1
        }

        for call in reply.toolCalls {
            out += event("content_block_start", [
                "type": "content_block_start", "index": index,
                "content_block": ["type": "tool_use", "id": call.id, "name": call.name, "input": [:]],
            ])
            out += event("content_block_delta", [
                "type": "content_block_delta", "index": index,
                "delta": ["type": "input_json_delta", "partial_json": call.argumentsJSON],
            ])
            out += event("content_block_stop", ["type": "content_block_stop", "index": index])
            index += 1
        }

        out += event("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": reply.stopReason, "stop_sequence": NSNull()],
            "usage": ["output_tokens": reply.estimatedOutputTokens],
        ])
        out += event("message_stop", ["type": "message_stop"])
        return out
    }

    // MARK: - Upstream call

    enum CallResult {
        case success(AssembledReply)
        case failure(status: Int, message: String)
    }

    static func send(conversationState: [String: Any], systemPrompt: String = "") async -> CallResult {
        guard let token = await accessToken() else {
            return .failure(status: 401, message: "No usable Kiro credentials — add a Kiro account in VibeRouter")
        }
        var state = conversationState
        let effort = state.removeValue(forKey: "__effort") as? [String: Any]
        var payload: [String: Any] = ["conversationState": state]
        if let effort, !effort.isEmpty {
            payload["additionalModelRequestFields"] = effort
        }
        guard let url = URL(string: endpoint) else {
            return .failure(status: 500, message: "Could not build the Kiro request")
        }
        // Kiro limits the complete request, including history, tool results and
        // schemas. Its limit can be lower than the model's advertised context.
        // Keep the current turn and the newest history, then shrink further if
        // Kiro's own content-length check still rejects the estimate.
        payload = trimHistory(in: payload, systemPrompt: systemPrompt, maxBytes: 900_000)
        for attempt in 0...3 {
            let result = await postKiro(url: url, token: token, payload: payload)
            guard case .failure(_, let message) = result else { return result }
            if payload["additionalModelRequestFields"] != nil,
               message.contains("additionalModelRequestFields") {
                payload.removeValue(forKey: "additionalModelRequestFields")
                continue
            }
            guard message.contains("CONTENT_LENGTH_EXCEEDS_THRESHOLD"), attempt < 3 else {
                return result
            }
            let bytes = payloadByteCount(payload)
            let smaller = trimHistory(
                in: payload, systemPrompt: systemPrompt,
                maxBytes: max(80_000, bytes * 7 / 10)
            )
            guard payloadByteCount(smaller) < bytes else {
                return .failure(
                    status: 413,
                    message: "The current message exceeds Kiro's input limit. Shorten the message or tool output and retry."
                )
            }
            payload = smaller
        }
        return .failure(status: 413, message: "The Kiro request is still too large after trimming history")
    }

    static func payloadByteCount(_ payload: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: payload).count) ?? Int.max
    }

    /// Remove complete old user/assistant pairs. Results on the new first user
    /// belonged to the removed assistant, so strip those too. Carry the system
    /// prompt forward because Kiro has no separate system field.
    static func trimHistory(
        in payload: [String: Any], systemPrompt: String, maxBytes: Int
    ) -> [String: Any] {
        var result = payload
        guard var state = result["conversationState"] as? [String: Any],
              var history = state["history"] as? [[String: Any]],
              var current = state["currentMessage"] as? [String: Any]
        else { return result }

        let currentUser = current["userInputMessage"] as? [String: Any] ?? [:]
        let currentContext = currentUser["userInputMessageContext"] as? [String: Any] ?? [:]
        let hasCurrentResults = !(currentContext["toolResults"] as? [[String: Any]] ?? []).isEmpty
        let minimumHistory = hasCurrentResults ? 2 : 0

        while payloadByteCount(result) > maxBytes && history.count > minimumHistory {
            guard history.count >= 2 else { break }
            history.removeFirst(2)
            if !history.isEmpty {
                var first = history[0]["userInputMessage"] as? [String: Any] ?? [:]
                if var context = first["userInputMessageContext"] as? [String: Any] {
                    context.removeValue(forKey: "toolResults")
                    if context.isEmpty { first.removeValue(forKey: "userInputMessageContext") }
                    else { first["userInputMessageContext"] = context }
                }
                let text = (first["content"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A tool-result-only turn cannot begin a Kiro history. Give
                // the remaining assistant a plain user turn to answer.
                let keptText = text.isEmpty ? "Earlier tool output was omitted." : text
                first["content"] = systemPrompt.isEmpty ? keptText : systemPrompt + "\n\n" + keptText
                history[0]["userInputMessage"] = first
            }
            if history.isEmpty, !systemPrompt.isEmpty,
               var user = current["userInputMessage"] as? [String: Any] {
                let text = user["content"] as? String ?? ""
                user["content"] = systemPrompt + "\n\n" + text
                current["userInputMessage"] = user
            }
            state["history"] = history
            state["currentMessage"] = current
            result["conversationState"] = state
        }

        // A single shell result can itself exceed the whole request budget.
        // Keep its beginning and end so the model sees both the command output
        // and any trailing diagnostics, with an explicit omission marker.
        if payloadByteCount(result) > maxBytes,
           var user = current["userInputMessage"] as? [String: Any],
           var context = user["userInputMessageContext"] as? [String: Any],
           var results = context["toolResults"] as? [[String: Any]], !results.isEmpty {
            let cap = max(2_000, maxBytes / max(4, results.count * 4))
            var changed = false
            for index in results.indices {
                guard var content = results[index]["content"] as? [[String: Any]] else { continue }
                for item in content.indices {
                    guard let text = content[item]["text"] as? String, text.count > cap else { continue }
                    let head = cap * 3 / 4
                    let tail = cap - head
                    content[item]["text"] = String(text.prefix(head))
                        + "\n[Older tool output omitted to fit Kiro's input limit]\n"
                        + String(text.suffix(tail))
                    changed = true
                }
                results[index]["content"] = content
            }
            if changed {
                context["toolResults"] = results
                user["userInputMessageContext"] = context
                current["userInputMessage"] = user
                state["currentMessage"] = current
                result["conversationState"] = state
            }
        }
        return result
    }

    private static func postKiro(url: URL, token: String, payload: [String: Any]) async -> CallResult {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(status: 500, message: "Could not build the Kiro request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("aws-sdk-rust/kiro", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(status: 502, message: "No response from Kiro")
            }
            guard (200...299).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? "Kiro request failed"
                let friendly = text.contains("MONTHLY_REQUEST_COUNT")
                    ? "Kiro monthly request limit reached on this login"
                    : text
                return .failure(status: http.statusCode, message: friendly)
            }
            return .success(assemble(frames: decodeFrames(data)))
        } catch {
            return .failure(status: 502, message: error.localizedDescription)
        }
    }
}
