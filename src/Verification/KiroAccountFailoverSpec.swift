import Foundation
@testable import CLIProxyMenuBar

enum KiroAccountFailoverSpec {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let a = KiroAccountPool.Candidate(token: "synthetic-old-cli", credential: .cliOIDC)
        let b = KiroAccountPool.Candidate(token: "synthetic-free", credential: .authFile("kiro-free.json"))
        let c = KiroAccountPool.Candidate(token: "synthetic-new-paid", credential: .authFile("kiro-paid.json"))
        let body = KiroStabilitySpec.body([
            ["role": "user", "content": "Continue the same task"],
            ["role": "assistant", "content": [["type": "tool_use", "id": "call1", "name": "Read", "input": ["path": "main.swift"]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call1", "content": "file text"]]],
        ], extra: ["tools": [["name": "Read", "input_schema": ["type": "object"]]]])
        let translated = KiroDirectProvider.translateRequest(anthropicBody: body)!
        let expected = KiroDirectProvider.requestPayload(conversationState: translated.conversationState)
        func sameJSON(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            NSDictionary(dictionary: lhs).isEqual(to: rhs)
        }
        func success(_ account: KiroAccountPool.Candidate) -> KiroDirectProvider.CallResult {
            var reply = KiroDirectProvider.AssembledReply(); reply.text = "continued"
            return .success(reply, .init(payloadBytes: 123, credential: account.credential))
        }
        let pool = KiroAccountPool()
        var calls: [String] = []
        let post: KiroDirectProvider.AccountPost = { account, payload, _ in
            calls.append(account.token)
            check(sameJSON(payload, expected), "failover preserves conversation ID, model, history, tools and results")
            if account.token == a.token { return .failure(status: 402, message: "MONTHLY_REQUEST_COUNT") }
            if account.token == b.token { return .failure(status: 400, message: "INVALID_MODEL_ID") }
            return success(account)
        }
        for _ in 0..<2 {
            let result = await KiroDirectProvider.send(conversationState: translated.conversationState,
                pool: pool, readCandidates: { _ in [a, b, c] }, post: post)
            if case .success(_, let delivery) = result {
                check(delivery.credential == c.credential, "successful account receives usage attribution")
            } else { preconditionFailure("exhaustion should rotate automatically") }
        }
        check(calls == [a.token, b.token, c.token, c.token], "next turn skips exhausted and model-denied accounts")
        let concurrent = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<20 {
                group.addTask { await pool.select([a, b, c], model: translated.upstreamModel, excluding: [])?.token }
            }
            var selected: [String?] = []
            for await token in group { selected.append(token) }
            return selected
        }
        check(concurrent.count == 20 && concurrent.allSatisfy { $0 == c.token }, "concurrent sessions share cooldowns and keep the healthy account")
        let other = await pool.select([a, b, c], model: "claude-sonnet-5", excluding: [])
        check(other?.token == b.token, "monthly quota is account-wide; model entitlement cooldown is model-specific")
        let future = await pool.select([a, b, c], model: "claude-sonnet-5", excluding: [], now: Date().addingTimeInterval(1801))
        check(future?.token == a.token, "cooldowns expire so upgraded accounts can recover")

        for status in [401, 403, 429, 503] {
            var attempted: [String] = []; var refreshes: [KiroDirectProvider.Credential] = []
            let result = await KiroDirectProvider.send(conversationState: translated.conversationState,
                pool: KiroAccountPool(), readCandidates: { forced in
                    if let forced { refreshes.append(forced) }
                    return [a, c]
                }, post: { account, _, _ in
                    attempted.append(account.token)
                    return account.token == a.token ? .failure(status: status, message: "account unavailable") : success(account)
                })
            if case .success = result { check(attempted.last == c.token, "account failover after HTTP \(status)") }
            else { preconditionFailure("account failover failed for \(status)") }
            check(refreshes == (status == 401 ? [a.credential] : []), "401 refresh targets original account before switching")
        }
        var refreshCalls = 0
        let rotated = KiroAccountPool.Candidate(token: "synthetic-rotated", credential: a.credential)
        let refreshResult = await KiroDirectProvider.send(conversationState: translated.conversationState,
            pool: KiroAccountPool(), readCandidates: { force in
                if force != nil { refreshCalls += 1; return [rotated, c] }
                return [a, c]
            }, post: { account, _, _ in
                account.token == a.token ? .failure(status: 401, message: "expired") : success(account)
            })
        if case .success(_, let delivery) = refreshResult {
            check(delivery.credential == a.credential && refreshCalls == 1, "successful refresh keeps the original login")
        } else { preconditionFailure("refresh should recover") }

        for visible in [false, true] {
            var attempted = 0
            let result = await KiroDirectProvider.send(conversationState: translated.conversationState,
                pool: KiroAccountPool(), readCandidates: { _ in [a, c] }, post: { account, _, emit in
                    attempted += 1
                    if account.token == a.token {
                        try! await emit(.init(eventType: visible ? "assistantResponseEvent" : "metadataEvent",
                            payload: visible ? ["content": "partial"] : ["contextUsagePercentage": 1]))
                        return .failure(status: 429, message: "throttled")
                    }
                    return success(account)
                })
            if visible {
                if case .failure = result { check(attempted == 1, "never replay a partially delivered response") }
                else { preconditionFailure("visible content must suppress retries") }
            } else {
                if case .success = result { check(attempted == 2, "metadata before quota error allows failover") }
                else { preconditionFailure("metadata must not block retry") }
            }
        }
        var invalidCalls = 0
        _ = await KiroDirectProvider.send(conversationState: translated.conversationState,
            pool: KiroAccountPool(), readCandidates: { _ in [a, c] }, post: { _, _, _ in
                invalidCalls += 1; return .failure(status: 400, message: "invalid_request_error")
            })
        check(invalidCalls == 1, "malformed requests do not churn through accounts")
        let exhaustedPool = KiroAccountPool(); var exhaustedCalls = 0
        for _ in 0..<2 {
            let result = await KiroDirectProvider.send(conversationState: translated.conversationState,
                pool: exhaustedPool, readCandidates: { _ in [a, c] }, post: { _, _, _ in
                    exhaustedCalls += 1; return .failure(status: 402, message: "MONTHLY_REQUEST_COUNT")
                })
            if case .failure(let status, _) = result { check(status == 402, "all exhausted preserves the quota error") }
            else { preconditionFailure("all exhausted must fail") }
        }
        check(exhaustedCalls == 2, "all exhausted does not loop or retry cooled accounts next turn")
        let added = KiroAccountPool.Candidate(token: "synthetic-added", credential: .authFile("kiro-added.json"))
        let selected = await exhaustedPool.select([a, c, added], model: translated.upstreamModel, excluding: [])
        check(selected?.token == added.token, "new account joins a depleted pool without restart")

        let cancelled = Task {
            await KiroDirectProvider.send(conversationState: translated.conversationState,
                pool: KiroAccountPool(), readCandidates: { _ in [a] }, post: { _, _, _ in
                    preconditionFailure("cancelled request must not call upstream")
                })
        }
        cancelled.cancel()
        if case .failure(let status, _) = await cancelled.value { check(status == 499, "cancellation prevents failover work") }

        // Exercise the real filesystem discovery with synthetic tokens only.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func payload(_ token: String, disabled: Bool = false, expired: Bool = false) -> [String: Any] {
            ["access_token": token, "refresh_token": "refresh-" + token, "disabled": disabled,
             "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(expired ? -10 : 3600))]
        }
        func write(_ name: String, _ body: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: body).write(to: directory.appendingPathComponent(name))
        }
        try write("kiro-disabled.json", payload("disabled", disabled: true))
        try write("kiro-duplicate.json", payload("oidc"))
        try write("kiro-enabled.json", payload("saved"))
        try write("kiro-expired.json", payload("expired", expired: true))
        var refreshedFiles: [String] = []
        let discovered = await KiroDirectProvider.loadAccountCandidates(authDirectory: directory,
            readSocial: { payload("social") }, readOIDC: { payload("oidc") }, refreshCLI: { false },
            refreshFile: { file in refreshedFiles.append(file.lastPathComponent); return false })
        check(Set(discovered.map(\.token)) == Set(["social", "oidc", "saved"]), "both CLI accounts and enabled saved accounts are discovered; duplicate and expired tokens excluded")
        check(refreshedFiles == ["kiro-expired.json"], "disabled accounts are never refreshed")
        let blockedCLI = await KiroDirectProvider.loadAccountCandidates(authDirectory: directory,
            readSocial: { payload("disabled") }, readOIDC: { nil }, refreshCLI: { false }, refreshFile: { _ in false })
        check(!blockedCLI.contains { $0.token == "disabled" }, "disabled import cannot return through CLI")
        let revived = await KiroDirectProvider.loadAccountCandidates(authDirectory: directory,
            readSocial: { nil }, readOIDC: { nil }, refreshCLI: { false }, refreshFile: { file in
                try! write(file.lastPathComponent, payload("revived")); return true
            })
        check(revived.contains { $0.token == "revived" }, "expired saved account is refreshed and becomes a candidate")
        let replacement = KiroAccountPool.Candidate(token: "new-login-at-same-source", credential: a.credential)
        let recovered = await exhaustedPool.select([replacement], model: translated.upstreamModel, excluding: [])
        check(recovered?.token == replacement.token, "logging into a new account clears old source's cooldown")
        print("PASS: \(checks) Kiro account failover checks")
        return checks
    }
}
