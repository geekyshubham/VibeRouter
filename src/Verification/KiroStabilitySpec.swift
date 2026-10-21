import Foundation
import CoreGraphics
import ImageIO
import Network
import UniformTypeIdentifiers
@testable import CLIProxyMenuBar

@main
struct KiroStabilitySpec {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func body(_ messages: [[String: Any]], extra: [String: Any] = [:]) -> String {
        var root = extra
        root["model"] = "kiro/claude-opus-5.5"
        root["messages"] = messages
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    static func jwt(email: String, expiry: TimeInterval) -> String {
        let claims: [String: Any] = ["exp": expiry, "https://api.openai.com/profile": ["email": email],
            "https://api.openai.com/auth": ["chatgpt_account_id": "spec-shared-workspace", "chatgpt_plan_type": "team"]]
        let data = try! JSONSerialization.data(withJSONObject: claims)
        return "e30." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".sig"
    }

    static func main() async throws {
        check(ModelProviderLabel.pickerOption(for: ["id": "gpt-image-2"]) == nil, "image-only models stay out of the Claude picker")
        check(ModelProviderLabel.pickerOption(for: ["id": "grok-imagine-video"]) == nil, "video-only models stay out of the Claude picker")
        check(ModelProviderLabel.pickerOption(for: ["id": "gpt-6.1-sol", "providers": ["codex"]]) != nil, "Codex text models remain selectable")
        checks += try await KiroAccountFailoverSpec.run()
        // An unchanged token in the early-refresh window must never switch
        // the request onto an account with different model entitlements.
        let tokenNow = Date(timeIntervalSince1970: 1_800_000_000)
        func socialToken(_ token: String, seconds: TimeInterval) -> [String: Any] {
            ["access_token": token, "expires_at": ISO8601DateFormatter().string(from: tokenNow.addingTimeInterval(seconds))]
        }
        var social: [String: Any]? = socialToken("power-token", seconds: 90)
        var oidc: [String: Any]?
        var refreshes = 0
        var fallbacks = 0
        let readSocial = { social }
        let refresh = { refreshes += 1; return true }
        let fallback: () async -> (token: String, credential: KiroDirectProvider.Credential)? = {
            fallbacks += 1
            return ("builder-token", .authFile("kiro-synthetic.json"))
        }
        func resolve(force: Bool = false, refresher: (() -> Bool)? = nil) async -> (token: String, credential: KiroDirectProvider.Credential)? {
            await KiroDirectProvider.resolveAccessToken(
                forceCLIRefresh: force, readSocialPayload: readSocial,
                readOIDCPayload: { oidc },
                refreshSocialSession: refresher ?? refresh, readAuthFileToken: fallback, now: { tokenNow }
            )
        }
        let early = await resolve()
        check(early?.token == "power-token" && early?.credential == .cliSocial, "unchanged early-refresh token retains Power login")
        check(refreshes == 1 && fallbacks == 0, "early refresh cannot select Builder ID")
        let failedRefresh = await resolve(refresher: { false })
        check(failedRefresh?.token == "power-token", "CLI failure cannot discard a still-valid social token")
        social = socialToken("expired-token", seconds: -1)
        let expired = await resolve()
        check(expired == nil && fallbacks == 0, "expired social login returns auth failure instead of switching accounts")
        social = socialToken("boundary-token", seconds: 0)
        let boundary = await resolve()
        check(boundary == nil, "token at exact expiry is not sent")
        social = socialToken("fresh-token", seconds: 3600)
        let beforeFresh = refreshes
        let fresh = await resolve()
        check(fresh?.token == "fresh-token" && refreshes == beforeFresh, "fresh tokens bypass CLI refresh")
        let rotated = await resolve(force: true, refresher: {
            social = socialToken("rotated-token", seconds: 3600); return true
        })
        check(rotated?.token == "rotated-token" && rotated?.credential == .cliSocial, "401 refresh stays on original login")
        social = socialToken("expired-token", seconds: -1)
        let persisted = await resolve(refresher: {
            social = socialToken("persisted-token", seconds: 3600); return false
        })
        check(persisted?.token == "persisted-token", "token persisted before CLI failure is re-read")
        social = ["access_token": "undated-token"]
        let undated = await resolve()
        check(undated == nil && fallbacks == 0, "unknown social expiry does not switch accounts")
        social = nil
        let builderOnly = await resolve()
        check(builderOnly?.credential == .authFile("kiro-synthetic.json") && fallbacks == 1, "Builder ID still works when no social login exists")

        oidc = socialToken("current-cli-builder", seconds: 3600)
        let currentBuilder = await resolve()
        check(currentBuilder?.token == "current-cli-builder" && currentBuilder?.credential == .cliOIDC && fallbacks == 1, "current CLI Builder ID login wins over an unrelated saved auth file")
        oidc = socialToken("early-cli-builder", seconds: 90)
        let earlyBuilder = await resolve()
        check(earlyBuilder?.token == "early-cli-builder" && earlyBuilder?.credential == .cliOIDC, "unchanged early-refresh OIDC token stays on CLI account")
        oidc = socialToken("expired-cli-builder", seconds: -1)
        let expiredBuilder = await resolve()
        check(expiredBuilder == nil && fallbacks == 1, "expired CLI OIDC login never falls back to another account")
        let refreshedBuilder = await resolve(force: true, refresher: {
            oidc = socialToken("rotated-cli-builder", seconds: 3600); return true
        })
        check(refreshedBuilder?.token == "rotated-cli-builder" && refreshedBuilder?.credential == .cliOIDC, "401 retry refreshes the original CLI OIDC login")
        oidc = socialToken("boundary-cli-builder", seconds: 0)
        let boundaryBuilder = await resolve()
        check(boundaryBuilder == nil, "OIDC token at exact expiry is rejected")
        social = socialToken("selected-social", seconds: -1)
        oidc = socialToken("other-cli-builder", seconds: 3600)
        let noSwitch = await resolve()
        check(noSwitch == nil && fallbacks == 1, "refresh does not switch from expired social to another CLI login")
        social = socialToken("selected-social", seconds: 3600)
        let selectedSocial = await resolve()
        check(selectedSocial?.credential == .cliSocial && selectedSocial?.token == "selected-social", "social login keeps precedence when both CLI entries exist")
        check(KiroDirectProvider.Credential.cliOIDC.isCLI && KiroDirectProvider.Credential.cliOIDC.ledgerAccount == "cli-oidc", "OIDC refresh and ledger attribution use CLI account")

        // Full histories and historical tool output must be visible to compaction.
        var messages: [[String: Any]] = []
        for i in 0..<20 {
            messages.append(["role": "user", "content": "q\(i)" + String(repeating: "x", count: 80_000)])
            messages.append(["role": "assistant", "content": "a\(i)"])
        }
        messages.append(["role": "user", "content": "latest task"])
        let translated = KiroDirectProvider.translateRequest(anthropicBody: body(messages, extra: ["system": "SYSTEM_KEEP"]))!
        check(translated.estimatedInputTokens > 400_000, "large local contexts must trigger compaction")
        let trimmed = KiroDirectProvider.trimHistory(in: KiroDirectProvider.requestPayload(conversationState: translated.conversationState), systemPrompt: translated.systemPrompt, maxBytes: 900_000)
        check(KiroDirectProvider.payloadByteCount(trimmed) <= 900_000, "upstream request budget")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: trimmed), as: UTF8.self)
        check(json.contains("SYSTEM_KEEP") && json.contains("latest task"), "system and current turn survive")
        check(json.components(separatedBy: "SYSTEM_KEEP").count == 2, "system is not duplicated while trimming")
        let toolMessages: [[String: Any]] = [
            ["role": "user", "content": "initial"],
            ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "run"]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": String(repeating: "字", count: 600_000)]]],
        ]
        let tool = KiroDirectProvider.translateRequest(anthropicBody: body(toolMessages))!
        let toolTrimmed = KiroDirectProvider.trimHistory(in: KiroDirectProvider.requestPayload(conversationState: tool.conversationState), systemPrompt: "", maxBytes: 900_000)
        check(KiroDirectProvider.payloadByteCount(toolTrimmed) <= 900_000, "Unicode tool output respects byte budget")
        let state = toolTrimmed["conversationState"] as! [String: Any]
        check((state["history"] as! [[String: Any]]).count == 2, "active tool pairing survives trimming")
        let historical = KiroDirectProvider.translateRequest(anthropicBody: body(toolMessages + [["role": "assistant", "content": "done"], ["role": "user", "content": "next"]]))!
        check(historical.estimatedInputTokens > 400_000, "historical tools aren't silently shortened before token counting")

        check(KiroDirectProvider.acceptsEffort("claude-opus-4.8"), "dotted Kiro model ID supports effort")
        check(KiroDirectProvider.clampedEffort("xhigh", model: "claude-opus-4.6") == "max", "4.6 effort clamping")
        check(!KiroDirectProvider.acceptsEffort("claude-haiku-4.5"), "no unsupported Haiku effort")
        let repaired = KiroJSON.repaired(#"{"text":"\ud800x\udc00","emoji":"\ud83d\ude00","literal":"\\ud800"}"#)
        let repairedJSON = try JSONSerialization.jsonObject(with: repaired) as! [String: String]
        check(repairedJSON["text"] == "�x�", "lone surrogates are repaired")
        check(repairedJSON["emoji"] == "😀" && repairedJSON["literal"] == #"\ud800"#, "valid escapes are preserved")

        // A large bitmap is resized and carried in both direct and tool-result images.
        let bitmap = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let imageData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination), "image fixture")
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": (imageData as Data).base64EncodedString()]]
        let normalized = try KiroImage.translate(image)
        let imageBytes = Data(base64Encoded: (normalized["source"] as! [String: String])["bytes"]!)!
        let imageSource = CGImageSourceCreateWithData(imageBytes as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as! [CFString: Any]
        check((props[kCGImagePropertyPixelWidth] as! Int) <= 1568 && imageBytes.count <= 180_000, "large image normalization")
        let imageTurn = KiroDirectProvider.translateRequest(anthropicBody: body([["role": "user", "content": [image]]]))!
        let current = (imageTurn.conversationState["currentMessage"] as! [String: Any])["userInputMessage"] as! [String: Any]
        check((current["images"] as? [[String: Any]])?.count == 1, "image is forwarded to Kiro")
        let toolImage = KiroDirectProvider.translateRequest(anthropicBody: body([["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": [image]]]]]))!
        let toolImageCurrent = (toolImage.conversationState["currentMessage"] as! [String: Any])["userInputMessage"] as! [String: Any]
        check((toolImageCurrent["images"] as? [[String: Any]])?.count == 1, "tool-result image is forwarded")
        let invalidImage = KiroDirectProvider.translateRequest(anthropicBody: body([["role": "user", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "invalid"]]]]]))!
        check(invalidImage.validationError != nil, "invalid images produce an error instead of disappearing")

        let a: [String: Any] = ["access_token": jwt(email: "spec-a@example.invalid", expiry: Date().timeIntervalSince1970 + 3600), "email": "wrong-label@example.invalid"]
        let b: [String: Any] = ["access_token": jwt(email: "spec-b@example.invalid", expiry: Date().timeIntervalSince1970 + 7200), "email": "wrong-label@example.invalid"]
        check(!TokenRefreshService.sameCodexSeat(a, as: b), "same workspace and label cannot merge different logins")
        check(!NativeUsageFetcher.shouldAdoptCodexCLITokens(local: b, file: a), "fresher foreign login cannot overwrite tokens")
        check(TokenRefreshService.seatEmail(a) == "spec-a@example.invalid", "access-token identity beats stored label")
        check(!TokenRefreshService.codexIdentityIsConsistent(a), "mislabeled account is rejected before fetching another user's status")
        check(CodexWorkspaceCredentials.resolve(preferredAccountID: "spec-shared-workspace", seed: b, email: "spec-a@example.invalid") == nil, "seed fallback refuses a foreign login")
        check(CodexWorkspaceCredentials.allSeats(seed: a).allSatisfy { $0.email == "spec-a@example.invalid" }, "candidate pool excludes native foreign logins")

        // Actual URLSession byte streaming, malformed frames, upstream errors and cancellation.
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "src/Verification/kiro-fixture-server.py"]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run(); defer { process.terminate() }
        let port = Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
        let httpAccounts = [
            KiroAccountPool.Candidate(token: "synthetic-old", credential: .cliOIDC),
            KiroAccountPool.Candidate(token: "synthetic-free", credential: .authFile("kiro-free.json")),
            KiroAccountPool.Candidate(token: "synthetic-paid", credential: .authFile("kiro-paid.json")),
        ]
        var httpAttempts: [String] = []
        let httpPool = KiroAccountPool()
        let httpRequest = KiroDirectProvider.translateRequest(anthropicBody: body([["role": "user", "content": "continue"]]))!
        for _ in 0..<2 {
            let result = await KiroDirectProvider.send(conversationState: httpRequest.conversationState,
                pool: httpPool, readCandidates: { _ in httpAccounts }, post: { account, payload, emit in
                    httpAttempts.append(account.token)
                    return await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/account-failover")!,
                        token: account.token, credential: account.credential, payload: payload, onFrame: emit)
                })
            if case .success(let reply, let delivery) = result {
                check(reply.text == "first second" && delivery.credential == httpAccounts[2].credential, "HTTP 402 and INVALID_MODEL_ID fail over through actual URLSession/AWS frames")
            } else { preconditionFailure("HTTP account failover failed") }
        }
        check(httpAttempts == ["synthetic-old", "synthetic-free", "synthetic-paid", "synthetic-paid"], "real transport skips cooled accounts on subsequent turns")
        let monthlyException = await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/monthly-exception")!,
            token: "synthetic", credential: .cliOIDC, payload: [:]) { _ in }
        if case .failure(let status, _) = monthlyException { check(status == 402, "AWS monthly quota exceptions use billing cooldown") }
        else { preconditionFailure("monthly exception must fail") }
        let start = Date(); var first: TimeInterval = 999; var frames = 0
        let reply = await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/delayed")!, token: "synthetic", credential: .cliSocial, payload: [:]) { _ in
            first = min(first, Date().timeIntervalSince(start)); frames += 1
        }
        if case .success(let response, _) = reply { check(response.text == "first second" && frames == 3, "split frames assemble correctly") }
        else { preconditionFailure("valid fixture failed") }
        check(first < 1 && Date().timeIntervalSince(start) > 1.2, "first content arrives before generation completes")
        for path in ["truncated", "exception", "tool", "unfinished-tool"] {
            let result = await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, token: "synthetic", credential: .cliSocial, payload: [:]) { _ in }
            if case .failure = result { checks += 1 } else { preconditionFailure("\(path) must fail") }
        }
        let noArguments = await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/empty-tool")!, token: "synthetic", credential: .cliSocial, payload: [:]) { _ in }
        if case .success(let reply, _) = noArguments { check(reply.toolCalls.first?.argumentsJSON == "{}", "completed zero-argument tool is valid") }
        else { preconditionFailure("completed empty tool failed") }
        let cancellation = Task { await KiroDirectProvider.postKiro(url: URL(string: "http://127.0.0.1:\(port)/cancel")!, token: "synthetic", credential: .cliSocial, payload: [:]) { _ in } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelStart = Date(); cancellation.cancel()
        _ = await cancellation.value
        check(Date().timeIntervalSince(cancelStart) < 2, "client cancellation stops upstream promptly")

        // Exercise the real downstream SSE writer over a TCP connection.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                Task {
                    let stream = KiroClientStream(connection: connection)
                    try await stream.start(model: "kiro/claude-opus-5.5", messageID: "msg_spec", inputTokens: 450_000)
                    try await stream.consume(.init(eventType: "assistantResponseEvent", payload: ["content": "first "]))
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try await stream.ping()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try await stream.consume(.init(eventType: "assistantResponseEvent", payload: ["content": "second"]))
                    var reply = KiroDirectProvider.AssembledReply(); reply.text = "first second"
                    try await stream.finish(reply: reply, usage: .init(inputTokens: 450_000, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0, source: .payloadBytes))
                }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        for _ in 0..<100 where listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        let (sse, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
        let text = String(decoding: sse, as: UTF8.self)
        check(text.contains("event: ping") && text.contains("event: message_stop"), "heartbeats and completion survive actual TCP transport")
        check(text.components(separatedBy: "event: message_start").count == 2, "single message_start")
        check(text.components(separatedBy: "event: content_block_start").count == 2, "single incremental text block")
        check(text.contains("450000"), "downstream usage retains local context size")
        print("PASS: \(checks) Kiro stability regression checks")
    }
}
