import Foundation

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

    /// Newest non-disabled Kiro auth file, refreshed when the token has expired.
    static func accessToken() async -> String? {
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

        // history must be strict user/assistant pairs; the last user turn is current.
        let currentIndex = turns.lastIndex(where: { $0.role == "user" }) ?? (turns.count - 1)
        let current = turns[currentIndex]
        let historyTurns = Array(turns[..<currentIndex])

        var history: [[String: Any]] = []
        var pendingUser: Turn?
        for turn in historyTurns {
            if turn.role == "user" {
                pendingUser = turn
            } else if let user = pendingUser {
                history.append(["userInputMessage": userInputMessage(user, model: model, tools: [])])
                history.append(["assistantResponseMessage": assistantResponseMessage(turn)])
                pendingUser = nil
            }
        }
        // An unpaired trailing user turn would desync the pairing; fold it forward.
        var currentTurn = current
        if let dangling = pendingUser {
            currentTurn.text = [dangling.text, current.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            currentTurn.toolResults = dangling.toolResults + current.toolResults
        }

        let conversationState: [String: Any] = [
            "chatTriggerType": "MANUAL",
            "conversationId": UUID().uuidString,
            "currentMessage": ["userInputMessage": userInputMessage(currentTurn, model: model, tools: tools)],
            "history": history,
        ]

        let promptChars = turns.reduce(0) { $0 + $1.text.utf8.count } + systemText.utf8.count
        return TranslatedRequest(
            conversationState: conversationState,
            model: requestedModel,
            stream: stream,
            estimatedInputTokens: max(1, promptChars / 4)
        )
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

    static func send(conversationState: [String: Any]) async -> CallResult {
        guard let token = await accessToken() else {
            return .failure(status: 401, message: "No usable Kiro credentials — add a Kiro account in VibeRouter")
        }
        guard let url = URL(string: endpoint),
              let body = try? JSONSerialization.data(withJSONObject: ["conversationState": conversationState])
        else {
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
                return .failure(status: http.statusCode, message: text)
            }
            return .success(assemble(frames: decodeFrames(data)))
        } catch {
            return .failure(status: 502, message: error.localizedDescription)
        }
    }
}
