import Foundation

/// Proactively refreshes OAuth access tokens before they expire.
/// Access tokens are short-lived; refresh tokens keep sessions alive.
enum TokenRefreshService {
    /// Refresh when the access token expires within this grace window.
    static let graceInterval: TimeInterval = 15 * 60 // 15 minutes
    /// How often the background timer checks auth files.
    static let pollInterval: TimeInterval = 3 * 60 // 3 minutes
    /// Codex access tokens last ~10 days; OpenAI refresh tokens die around ~30 days if never rotated.
    /// Rotate unused sessions well before that wall so idle accounts stay valid.
    static let unusedSessionRefreshAge: TimeInterval = 7 * 24 * 60 * 60

    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Must match the original authorize grant. Refreshing without `offline_access`
    /// can yield tokens that cannot be refreshed again after ~30 days.
    static let openAIRefreshScope = "openid email profile offline_access"
    private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let googleClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let googleClientSecret = "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"
    private static let kimiClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// Public Cursor desktop OAuth client (same one Cockpit Tools uses).
    private static let cursorClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    private static var timer: Timer?
    private static let isoFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    @discardableResult
    static func startAutoRefresh() -> Timer {
        stopAutoRefresh()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { await refreshAllNearExpiry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refreshAllNearExpiry() }
        return timer
    }

    static func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// Refresh every refreshable auth file whose access token is within the grace period (or already past).
    ///
    /// OpenAI rotates the refresh token on every success and immediately invalidates the previous one.
    /// Duplicate Codex files (email-named + `codex-seat-*.json`) share that token — refresh once
    /// per token and write the new one to every sibling, or the leftover file's next refresh
    /// sends `refresh_token_reused` and OpenAI revokes the whole family.
    @discardableResult
    static func refreshAllNearExpiry(force: Bool = false) async -> Int {
        let authDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var jobs: [AuthRefreshJob] = []
        for file in files where file.pathExtension == "json" {
            guard var payload = NativeUsageFetcher.readAuthPayload(at: file),
                  let type = payload["type"] as? String
            else { continue }
            if payload["disabled"] as? Bool == true { continue }
            let kind = type.lowercased()
            if kind == "codex" {
                // Adopt the live CLI/desktop session before considering a network refresh.
                // Posting a leftover RT is `refresh_token_reused` and kills the family.
                _ = NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(onto: file)
                payload = NativeUsageFetcher.readAuthPayload(at: file) ?? payload
            } else if kind == "claude" {
                _ = await refreshNativeClaudeSessionIfNeeded(account: payload, force: force)
                _ = NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file)
                payload = NativeUsageFetcher.readAuthPayload(at: file) ?? payload
            }
            payload = flattenedAuth(payload)
            if kind == "claude", refreshToken(from: payload) == nil { continue }
            if force || shouldRefresh(payload: payload) {
                jobs.append(
                    AuthRefreshJob(
                        file: file,
                        payload: payload,
                        type: kind,
                        refresh: refreshToken(from: payload)
                    )
                )
            } else if kind == "codex" {
                _ = pushCodexTokensToCLIIfFresher(payload)
            }
        }

        var refreshed = 0
        for group in groupedByRefreshToken(jobs) {
            guard let first = group.first else { continue }
            // Re-read: Codex CLI / the Go proxy may have rotated while we scanned.
            var livePayload = NativeUsageFetcher.readAuthPayload(at: first.file).map(flattenedAuth)
                ?? first.payload
            if first.type == "codex" {
                _ = NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(onto: first.file)
                livePayload = NativeUsageFetcher.readAuthPayload(at: first.file).map(flattenedAuth)
                    ?? livePayload
                // Overlay wrote a newer RT onto this file — fan it out before anyone
                // POSTs a leftover sibling copy.
                if let old = first.refresh, !old.isEmpty,
                   let liveRT = refreshToken(from: livePayload),
                   liveRT != old
                {
                    _ = propagateRotatedTokens(
                        oldRefresh: old,
                        updated: livePayload,
                        authDirectory: authDir,
                        skipping: [first.file.path]
                    )
                }
            } else if first.type == "claude" {
                _ = NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: first.file)
                livePayload = NativeUsageFetcher.readAuthPayload(at: first.file).map(flattenedAuth)
                    ?? livePayload
            }
            if !force && !shouldRefresh(payload: livePayload) {
                if first.type == "codex" { _ = pushCodexTokensToCLIIfFresher(livePayload) }
                continue
            }
            let oldRefresh = refreshToken(from: livePayload) ?? first.refresh
            guard let updated = await refreshPayload(livePayload, type: first.type, forceOAuth: force) else { continue }

            var skipped = Set<String>()
            for job in group {
                let current = NativeUsageFetcher.readAuthPayload(at: job.file) ?? job.payload
                guard canCopyTokens(from: updated, onto: current) else { continue }
                let merged = copyTokenFields(from: updated, onto: current)
                if writeAuthFile(merged, to: job.file) {
                    refreshed += 1
                    skipped.insert(job.file.path)
                    NSLog("[TokenRefresh] Refreshed %@", job.file.lastPathComponent)
                }
            }
            if let oldRefresh, !oldRefresh.isEmpty {
                refreshed += propagateRotatedTokens(
                    oldRefresh: oldRefresh,
                    updated: updated,
                    authDirectory: authDir,
                    skipping: skipped
                )
                syncNativeCredentialStores(type: first.type, oldRefresh: oldRefresh, updated: updated)
            }
        }

        if refreshed > 0 {
            await MainActor.run {
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
        }
        return refreshed
    }

    static func refreshAccountFile(_ file: URL, force: Bool = false) async -> Bool {
        guard var payload = NativeUsageFetcher.readAuthPayload(at: file),
              let type = payload["type"] as? String
        else { return false }
        let kind = type.lowercased()
        if kind == "codex" {
            _ = NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(onto: file)
            payload = NativeUsageFetcher.readAuthPayload(at: file) ?? payload
        } else if kind == "claude" {
            _ = await refreshNativeClaudeSessionIfNeeded(account: payload, force: force)
            _ = NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file)
            payload = NativeUsageFetcher.readAuthPayload(at: file) ?? payload
            if refreshToken(from: payload) == nil,
               let expiry = accessTokenExpiry(from: payload), expiry <= Date() {
                // An unchanged expired access-only file is not a successful
                // renewal, even if the native CLI could not run or was throttled.
                return false
            }
        }
        payload = flattenedAuth(payload)
        if !force && !shouldRefresh(payload: payload) {
            if kind == "codex" {
                _ = pushCodexTokensToCLIIfFresher(payload)
            }
            return true
        }
        let oldRefresh = refreshToken(from: payload)
        guard let updated = await refreshPayload(payload, type: kind, forceOAuth: force) else { return false }
        guard canCopyTokens(from: updated, onto: payload) else { return false }
        let ok = writeAuthFile(updated, to: file)
        if ok {
            if let oldRefresh, !oldRefresh.isEmpty {
                _ = propagateRotatedTokens(
                    oldRefresh: oldRefresh,
                    updated: updated,
                    skipping: [file.path]
                )
                syncNativeCredentialStores(type: kind, oldRefresh: oldRefresh, updated: updated)
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            }
        }
        return ok
    }

    // MARK: - Decision

    @discardableResult
    static func refreshNativeClaudeSessionIfNeeded(account: [String: Any], force: Bool = false) async -> Bool {
        guard ClaudeNativeSessionRefresh.shouldRefresh(
            account: account, native: NativeUsageFetcher.readClaudeAppPayload(), force: force
        ) else { return false }
        _ = await ClaudeNativeSessionRefresh.shared.run {
            await Task.detached(priority: .utility) {
                ClaudeNativeSessionRefresh.requestNativeRefresh()
            }.value
        }
        guard let native = NativeUsageFetcher.readClaudeAppPayload(),
              AccountCredentialIdentity.sameAccount(account, native),
              let expiry = accessTokenExpiry(from: native), expiry > Date() else { return false }
        return true
    }

    /// True when the access token is near/past expiry, or when a Codex-style session is old
    /// enough that its refresh token would otherwise hit OpenAI's idle-expiry wall.
    static func shouldRefresh(payload: [String: Any]) -> Bool {
        let payload = flattenedAuth(payload)
        guard refreshToken(from: payload) != nil else { return false }

        let now = Date()
        let deadline = now.addingTimeInterval(graceInterval)

        if let exp = accessTokenExpiry(from: payload) {
            if exp <= deadline { return true }
            if let iat = accessTokenIssuedAt(from: payload),
               iat.addingTimeInterval(unusedSessionRefreshAge) <= now
            {
                return true
            }
            return false
        }

        // No parseable expiry — refresh opportunistically if last_refresh is old.
        if let last = parseDateAny(payload["last_refresh"])
            ?? parseDateAny(payload["expired"])
        {
            return last.addingTimeInterval(30 * 60) <= now
        }
        return true
    }

    struct AuthRefreshJob {
        let file: URL
        let payload: [String: Any]
        let type: String
        let refresh: String?
    }

    /// One group per (provider, refresh_token). Files without a refresh token stay unique.
    static func groupedByRefreshToken(_ jobs: [AuthRefreshJob]) -> [[AuthRefreshJob]] {
        var groups: [String: [AuthRefreshJob]] = [:]
        var order: [String] = []
        for job in jobs {
            let key: String
            if let rt = job.refresh, !rt.isEmpty {
                key = job.type + "\u{1e}" + rt
            } else {
                key = job.type + "\u{1e}file\u{1e}" + job.file.path
            }
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(job)
        }
        return order.compactMap { groups[$0] }
    }

    /// Copy rotated tokens onto every auth file that still holds `oldRefresh`,
    /// plus same-seat siblings (email + chatgpt_account_id) even if their RT is already stale.
    /// Cockpit copies live under `tokens` and used to keep a dead RT that switch then sent first.
    @discardableResult
    static func propagateRotatedTokens(
        oldRefresh: String,
        updated: [String: Any],
        authDirectory: URL? = nil,
        skipping skipped: Set<String> = []
    ) -> Int {
        let trimmed = oldRefresh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let authDir = authDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var wrote = 0
        for file in files where file.pathExtension == "json" {
            if skipped.contains(file.path) { continue }
            guard let payload = NativeUsageFetcher.readAuthPayload(at: file) else { continue }
            guard canCopyTokens(from: updated, onto: payload) else { continue }
            let matchesRefresh = refreshToken(from: payload) == trimmed
            let matchesSeat = (updated["type"] as? String)?.lowercased() == "codex"
                && sameCodexSeat(payload, as: updated)
            guard matchesRefresh || matchesSeat else { continue }
            // Matching lineages receive rotated tokens only after identity checks.
            // Seat fan-out must also preserve a fresher copy.
            if !matchesRefresh {
                if seatsConflict(payload, updated: updated) { continue }
                if hasNewerAccessToken(payload, than: updated) { continue }
            }
            let merged = copyTokenFields(from: updated, onto: payload)
            if writeAuthFile(merged, to: file) {
                wrote += 1
                NSLog("[TokenRefresh] Synced rotated refresh token to %@", file.lastPathComponent)
            }
        }
        // Native/Cockpit copies only when operating on the real auth dir — tests pass a temp path.
        if authDirectory == nil {
            if syncCodexAuthJSON(oldRefresh: trimmed, updated: updated) {
                wrote += 1
            }
            wrote += syncCockpitCodexAccounts(oldRefresh: trimmed, updated: updated)
        }
        return wrote
    }

    /// Official Codex CLI/desktop share the same rotating token via ~/.codex/auth.json + keychain.
    /// Leave that copy stale and the next CLI refresh sends refresh_token_reused.
    @discardableResult
    private static func syncCodexAuthJSON(oldRefresh: String, updated: [String: Any]) -> Bool {
        guard (updated["type"] as? String)?.lowercased() == "codex" else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        guard canCopyTokens(from: updated, onto: root) else { return false }
        let stored = stringValue(tokens, keys: ["refresh_token"])
            ?? stringValue(root, keys: ["refresh_token"])
        let matchesRefresh = stored == oldRefresh
        let matchesSeat = sameCodexSeat(root, as: updated)
        guard matchesRefresh || matchesSeat else { return false }
        if !matchesRefresh {
            if seatsConflict(root, updated: updated) { return false }
            if hasNewerAccessToken(root, than: updated) { return false }
        }

        if let access = updated["access_token"] {
            tokens["access_token"] = access
            root["access_token"] = access
        }
        if let refresh = updated["refresh_token"] {
            tokens["refresh_token"] = refresh
            root["refresh_token"] = refresh
        }
        if let idToken = updated["id_token"] {
            tokens["id_token"] = idToken
            root["id_token"] = idToken
        }
        root["tokens"] = tokens
        root["last_refresh"] = isoString(Date())
        guard writeAuthFile(root, to: url) else { return false }
        _ = CodexWorkspaceCredentials.writeKeychain(
            authFileJSON: root,
            codexHome: home.appendingPathComponent(".codex")
        )
        NSLog("[TokenRefresh] Synced rotated refresh token to ~/.codex/auth.json")
        return true
    }

    /// Nested Cockpit `~/.antigravity_cockpit/codex_accounts/*.json` share the rotating RT.
    @discardableResult
    private static func syncCockpitCodexAccounts(oldRefresh: String, updated: [String: Any]) -> Int {
        guard (updated["type"] as? String)?.lowercased() == "codex" else { return 0 }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".antigravity_cockpit/codex_accounts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var wrote = 0
        for file in files where file.pathExtension == "json" {
            guard var root = NativeUsageFetcher.readAuthPayload(at: file) else { continue }
            guard canCopyTokens(from: updated, onto: root) else { continue }
            var tokens = (root["tokens"] as? [String: Any]) ?? [:]
            let stored = stringValue(tokens, keys: ["refresh_token"])
                ?? stringValue(root, keys: ["refresh_token"])
            let matchesRefresh = stored == oldRefresh
            let matchesSeat = sameCodexSeat(root, as: updated)
            guard matchesRefresh || matchesSeat else { continue }
            if !matchesRefresh {
                if seatsConflict(root, updated: updated) { continue }
                if hasNewerAccessToken(root, than: updated) { continue }
            }
            if let access = stringValue(updated, keys: ["access_token"]) {
                tokens["access_token"] = access
                root["access_token"] = access
            }
            if let refresh = stringValue(updated, keys: ["refresh_token"]) {
                tokens["refresh_token"] = refresh
                root["refresh_token"] = refresh
            }
            if let idToken = stringValue(updated, keys: ["id_token"]) {
                tokens["id_token"] = idToken
                root["id_token"] = idToken
            }
            root["tokens"] = tokens
            root["token_updated_at"] = isoString(Date())
            if writeAuthFile(root, to: file) {
                wrote += 1
                NSLog("[TokenRefresh] Synced rotated refresh token to cockpit %@", file.lastPathComponent)
            }
        }
        return wrote
    }

    /// Same ChatGPT login + workspace. Team members share account_id — email must match too.
    static func sameCodexSeat(_ payload: [String: Any], as updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard codexIdentityIsConsistent(a), codexIdentityIsConsistent(b) else { return false }
        guard canCopyTokens(from: b, onto: a) else { return false }
        guard let idA = seatAccountID(a), let idB = seatAccountID(b),
              idA.caseInsensitiveCompare(idB) == .orderedSame
        else { return false }
        guard let emailA = seatEmail(a), let emailB = seatEmail(b),
              emailA.caseInsensitiveCompare(emailB) == .orderedSame
        else { return false }
        return true
    }

    /// A shared refresh token is not permission to replace a different provider,
    /// ChatGPT member, or workspace's access token and identity.
    static func canCopyTokens(from updated: [String: Any], onto original: [String: Any]) -> Bool {
        let a = flattenedAuth(original)
        let b = flattenedAuth(updated)
        guard !AccountCredentialIdentity.hasConflict(a, b) else { return false }
        let typeA = stringValue(a, keys: ["type"])?.lowercased()
        let typeB = stringValue(b, keys: ["type"])?.lowercased()
        if let typeA, let typeB, typeA != typeB { return false }
        if typeA == "codex" || typeB == "codex" {
            guard codexIdentityIsConsistent(a), codexIdentityIsConsistent(b) else { return false }
            if let left = seatAccountID(a), let right = seatAccountID(b),
               left.caseInsensitiveCompare(right) != .orderedSame { return false }
            if let left = seatEmail(a), let right = seatEmail(b),
               left.caseInsensitiveCompare(right) != .orderedSame { return false }
            let userA = CodexWorkspaceCredentials.chatgptUserID(from: stringValue(a, keys: ["access_token"]))
            let userB = CodexWorkspaceCredentials.chatgptUserID(from: stringValue(b, keys: ["access_token"]))
            if let userA, let userB, userA != userB { return false }
        }
        if typeA == "kiro" || typeB == "kiro" {
            if let left = KiroAccountIdentity.key(a), let right = KiroAccountIdentity.key(b), left != right {
                return false
            }
        }
        return true
    }

    static func codexIdentityIsConsistent(_ json: [String: Any]) -> Bool {
        let json = flattenedAuth(json)
        let accessEmail = JWTEmailExtractor.email(from: stringValue(json, keys: ["access_token"]))
        let idEmail = JWTEmailExtractor.email(from: stringValue(json, keys: ["id_token"]))
        if let accessEmail, let idEmail, accessEmail.caseInsensitiveCompare(idEmail) != .orderedSame { return false }
        if let actual = accessEmail ?? idEmail, let stored = stringValue(json, keys: ["email"]), !stored.isEmpty {
            return actual.caseInsensitiveCompare(stored) == .orderedSame
        }
        return true
    }

    /// JWT seats disagree — do not copy Team tokens onto a Go file (or vice versa).
    private static func seatsConflict(_ payload: [String: Any], updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard let idA = CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(a, keys: ["access_token"])),
              let idB = CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(b, keys: ["access_token"]))
        else { return false }
        return idA.caseInsensitiveCompare(idB) != .orderedSame
    }

    private static func hasNewerAccessToken(_ payload: [String: Any], than updated: [String: Any]) -> Bool {
        let a = flattenedAuth(payload)
        let b = flattenedAuth(updated)
        guard let oldExp = jwtExpiry(stringValue(a, keys: ["access_token"]) ?? ""),
              let newExp = jwtExpiry(stringValue(b, keys: ["access_token"]) ?? "")
        else { return false }
        return oldExp > newExp
    }

    static func flattenedAuth(_ json: [String: Any]) -> [String: Any] {
        var out = json
        if let tokens = json["tokens"] as? [String: Any] {
            for (key, value) in tokens where out[key] == nil {
                out[key] = value
            }
        }
        return out
    }

    private static func seatAccountID(_ json: [String: Any]) -> String? {
        CodexWorkspaceCredentials.chatgptAccountID(from: stringValue(json, keys: ["access_token"]))
            ?? stringValue(json, keys: ["account_id", "chatgpt_account_id"])
    }

    static func seatEmail(_ json: [String: Any]) -> String? {
        // The access token is the identity queried upstream. A stale label or
        // ID token must never authorize copying another Team member's tokens.
        JWTEmailExtractor.email(from: stringValue(json, keys: ["access_token"]))
            ?? JWTEmailExtractor.email(from: stringValue(json, keys: ["id_token"]))
            ?? stringValue(json, keys: ["email"])
    }

    static func copyTokenFields(from updated: [String: Any], onto original: [String: Any]) -> [String: Any] {
        var out = original
        for key in [
            "access_token", "refresh_token", "id_token",
            "accessToken", "refreshToken",
            "expires_in", "expired", "expires_at", "last_refresh",
            "account_id", "plan_type",
        ] {
            if let value = updated[key] {
                out[key] = value
            }
        }
        return out
    }

    /// Keep native CLI/desktop copies in lockstep after a rotating refresh.
    /// Stale ~/.claude, ~/.gemini, ~/.grok, or Cursor state.vscdb copies reuse the old token and kill the family.
    static func syncNativeCredentialStores(type: String, oldRefresh: String, updated: [String: Any]) {
        let trimmed = oldRefresh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch type {
        case "codex":
            break // handled by syncCodexAuthJSON inside propagateRotatedTokens
        case "claude":
            syncClaudeCredentials(oldRefresh: trimmed, updated: updated)
        case "gemini", "antigravity":
            syncGeminiCredentials(oldRefresh: trimmed, updated: updated)
        case "cursor":
            syncCursorState(oldRefresh: trimmed, updated: updated)
        case "xai", "grok":
            syncGrokCLICredentials(oldRefresh: trimmed, updated: updated)
        default:
            break
        }
    }

    private static func syncClaudeCredentials(oldRefresh: String, updated: [String: Any]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        var root: [String: Any] = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]

        if let kcData = readClaudeKeychainData(),
           let kcJSON = try? JSONSerialization.jsonObject(with: kcData) as? [String: Any] {
            if root.isEmpty { root = kcJSON }
        }

        // Check if this account corresponds to the local CLI/Keychain session before overwriting.
        // Never clobber the primary account's keychain with tokens from a secondary account!
        let oauthObj = (root["claudeAiOauth"] as? [String: Any]) ?? root
        let existingRefresh = stringValue(oauthObj, keys: ["refreshToken", "refresh_token"])

        if existingRefresh != oldRefresh || !canCopyTokens(from: updated, onto: oauthObj) {
            // Native Claude Code already rotated. Writing our leftover family into
            // the keychain is what logs `claude` out every other refresh.
            NSLog("[TokenRefresh] Skipping Keychain sync; Claude Code refresh token already moved on")
            return
        }

        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        if let access = stringValue(updated, keys: ["access_token"]) {
            oauth["accessToken"] = access
            root["access_token"] = access
        }
        if let refresh = stringValue(updated, keys: ["refresh_token"]) {
            oauth["refreshToken"] = refresh
            root["refresh_token"] = refresh
        }
        if let exp = parseDateAny(updated["expired"]) ?? parseDateAny(updated["expires_at"]) {
            oauth["expiresAt"] = exp.timeIntervalSince1970 * 1000
        }
        root["claudeAiOauth"] = oauth

        _ = writeAuthFile(root, to: url)
        if let data = try? JSONSerialization.data(withJSONObject: root),
           let json = String(data: data, encoding: .utf8) {
            writeClaudeKeychain(json)
            NSLog("[TokenRefresh] Synced rotated tokens to Claude Code-credentials keychain")
        }
    }

    private static func readClaudeKeychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return output.isEmpty ? nil : output
    }

    private static func writeClaudeKeychain(_ json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-s", "Claude Code-credentials",
            "-a", NSUserName(),
            "-w", json,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func syncGeminiCredentials(oldRefresh: String, updated: [String: Any]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        guard var root = NativeUsageFetcher.readAuthPayload(at: url),
              stringValue(root, keys: ["refresh_token", "refreshToken"]) == oldRefresh,
              canCopyTokens(from: updated, onto: root)
        else { return }
        if let access = stringValue(updated, keys: ["access_token"]) {
            root["access_token"] = access
        }
        if let refresh = stringValue(updated, keys: ["refresh_token"]) {
            root["refresh_token"] = refresh
        }
        if let idToken = stringValue(updated, keys: ["id_token"]) {
            root["id_token"] = idToken
        }
        if writeAuthFile(root, to: url) {
            NSLog("[TokenRefresh] Synced rotated refresh token to ~/.gemini/oauth_creds.json")
        }
    }

    private static func syncCursorState(oldRefresh: String, updated: [String: Any]) {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let stored = VscdbStore.readString(dbURL: db, key: "cursorAuth/refreshToken")
        guard stored == oldRefresh else { return }
        let native: [String: Any] = [
            "type": "cursor",
            "email": VscdbStore.readString(dbURL: db, key: "cursorAuth/cachedEmail") ?? "",
            "access_token": VscdbStore.readString(dbURL: db, key: "cursorAuth/accessToken") ?? "",
            "refresh_token": stored ?? "",
        ]
        guard canCopyTokens(from: updated, onto: native) else { return }
        if let access = stringValue(updated, keys: ["access_token", "accessToken"]) {
            try? VscdbStore.writeString(dbURL: db, key: "cursorAuth/accessToken", value: access)
            try? VscdbStore.writeString(dbURL: db, key: "cursor.accessToken", value: access)
        }
        if let refresh = stringValue(updated, keys: ["refresh_token", "refreshToken"]) {
            try? VscdbStore.writeString(dbURL: db, key: "cursorAuth/refreshToken", value: refresh)
        }
        NSLog("[TokenRefresh] Synced rotated refresh token to Cursor state.vscdb")
    }

    static func canRefresh(file: URL) -> Bool {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: file),
              let type = payload["type"] as? String else { return false }
        let kind = type.lowercased()
        guard ["codex", "claude", "antigravity", "gemini", "xai", "grok", "kiro", "kimi", "cursor"].contains(kind) else {
            return false
        }
        let flat = flattenedAuth(payload)
        if (flat["type"] as? String)?.lowercased() == "claude",
           let native = NativeUsageFetcher.readClaudeAppPayload(),
           AccountCredentialIdentity.sameAccount(flat, native),
           refreshToken(from: native) != nil { return true }
        return refreshToken(from: flat) != nil
    }

    static func accessTokenExpiry(from payload: [String: Any]) -> Date? {
        let flat = flattenedAuth(payload)
        if let token = stringValue(flat, keys: ["access_token", "accessToken", "key"]),
           let exp = jwtExpiry(token)
        {
            return exp
        }
        for key in ["expired", "expires_at", "expiresAt", "expiry"] {
            if let date = parseDateAny(flat[key]) {
                return date
            }
        }
        // Fallback: derive from last_refresh/timestamp + expires_in
        if let expiresIn = (flat["expires_in"] as? NSNumber)?.doubleValue
            ?? (flat["expiresIn"] as? NSNumber)?.doubleValue
            ?? Double(stringValue(flat, keys: ["expires_in", "expiresIn"]) ?? "")
        {
            let baseDate = parseDateAny(flat["last_refresh"])
                ?? parseDateAny(flat["lastRefresh"])
                ?? parseDateAny(flat["timestamp"])
                ?? parseDateAny(flat["created_at"])
            if let baseDate {
                return baseDate.addingTimeInterval(expiresIn)
            }
        }
        return nil
    }

    static func refreshToken(from payload: [String: Any]) -> String? {
        stringValue(flattenedAuth(payload), keys: ["refresh_token", "refreshToken", "refresh"])
    }

    /// Keep `~/.codex/auth.json` + keychain on the newest cli-proxy copy so the
    /// official CLI cannot POST a leftover RT and revoke the family.
    @discardableResult
    static func pushCodexTokensToCLIIfFresher(_ payload: [String: Any]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let flat = flattenedAuth(payload)
        guard stringValue(flat, keys: ["access_token"]) != nil else { return false }
        guard let local = NativeUsageFetcher.readCodexAppPayload(),
              NativeUsageFetcher.shouldAdoptCodexCLITokens(local: flat, file: local) else { return false }
        return writeCodexCLITokens(from: flat, to: url, codexHome: home.appendingPathComponent(".codex"))
    }

    @discardableResult
    private static func writeCodexCLITokens(
        from updated: [String: Any],
        to url: URL,
        codexHome: URL
    ) -> Bool {
        var root = NativeUsageFetcher.readAuthPayload(at: url) ?? [:]
        var tokens = (root["tokens"] as? [String: Any]) ?? [:]
        if let access = stringValue(updated, keys: ["access_token"]) {
            tokens["access_token"] = access
            root["access_token"] = access
        }
        if let refresh = stringValue(updated, keys: ["refresh_token"]) {
            tokens["refresh_token"] = refresh
            root["refresh_token"] = refresh
        }
        if let idToken = stringValue(updated, keys: ["id_token"]) {
            tokens["id_token"] = idToken
            root["id_token"] = idToken
        }
        if let accountID = stringValue(updated, keys: ["account_id"]) {
            tokens["account_id"] = accountID
            root["account_id"] = accountID
        }
        root["tokens"] = tokens
        root["last_refresh"] = isoString(Date())
        guard writeAuthFile(root, to: url) else { return false }
        _ = CodexWorkspaceCredentials.writeKeychain(authFileJSON: root, codexHome: codexHome)
        return true
    }

    // MARK: - Provider refresh

    private static func refreshPayload(_ payload: [String: Any], type: String, forceOAuth: Bool = false) async -> [String: Any]? {
        guard AccountCredentialIdentity.isConsistent(payload) else { return nil }
        switch type {
        case "codex":
            return await refreshOpenAI(payload)
        case "claude":
            return await refreshAnthropic(payload, forceOAuth: forceOAuth)
        case "antigravity", "gemini":
            return await refreshGoogle(payload)
        case "xai", "grok":
            return await refreshXAI(payload)
        case "kiro":
            return await refreshKiro(payload)
        case "kimi":
            return await refreshKimi(payload)
        case "cursor":
            return await refreshCursor(payload)
        default:
            return nil
        }
    }

    enum OAuthGrantResult {
        case success([String: Any])
        /// OpenAI saw a previously rotated RT. The family may already be revoked — do not try older copies.
        case reuseRevoked
        case failed
    }

    static func openAIRefreshFields(refreshToken: String) -> [String: String] {
        [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": openAIClientID,
            "scope": openAIRefreshScope,
        ]
    }

    /// Single-flight OpenAI refresh so switch + keep-alive cannot rotate the same RT twice.
    static func refreshOpenAIGrant(refreshToken: String) async -> OAuthGrantResult {
        let trimmed = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }
        return await OpenAIRefreshFlight.shared.run(token: trimmed) {
            await postOpenAIRefresh(refreshToken: trimmed)
        }
    }

    private static func refreshOpenAI(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        switch await refreshOpenAIGrant(refreshToken: refresh) {
        case .success(let json):
            return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
        case .reuseRevoked, .failed:
            return nil
        }
    }

    /// Claude Code and VibeRouter cannot both POST the same rotating refresh token.
    /// A leftover RT is rejected (or reused) and Anthropic revokes the family —
    /// `claude` then prints "Login expired · Please run /login".
    static func shouldNetworkRefreshClaude(
        payload: [String: Any],
        native: [String: Any]?
    ) -> Bool {
        guard let native else { return true }
        let local = flattenedAuth(native)
        let file = flattenedAuth(payload)
        guard stringValue(local, keys: ["access_token", "refresh_token"]) != nil else {
            return true
        }
        return !AccountCredentialIdentity.sameAccount(file, local)
    }

    private static func refreshAnthropic(_ payload: [String: Any], forceOAuth: Bool = false) async -> [String: Any]? {
        let local = NativeUsageFetcher.readClaudeAppPayload()
        // Native Claude Code owns this token family. Overlay the live access token
        // and never POST the refresh token — even on force, even if the file looks newer.
        if let local, !shouldNetworkRefreshClaude(payload: payload, native: local) {
            var adopted = copyTokenFields(from: local, onto: payload)
            adopted.removeValue(forKey: "refresh_token")
            adopted.removeValue(forKey: "refreshToken")
            NSLog("[TokenRefresh] Skipping Anthropic refresh; Claude Code owns this token family")
            return adopted
        }
        if !forceOAuth,
           let local,
           NativeUsageFetcher.shouldAdoptClaudeCLITokens(local: local, file: payload)
        {
            var adopted = copyTokenFields(from: local, onto: payload)
            adopted.removeValue(forKey: "refresh_token")
            adopted.removeValue(forKey: "refreshToken")
            return adopted
        }

        guard let refresh = refreshToken(from: payload) else { return nil }
        let endpoint = "https://platform.claude.com/v1/oauth/token"
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": anthropicClientID,
            "scope": "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code",
        ]
        guard let postURL = URL(string: endpoint),
              let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }

        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/2.1.271", forHTTPHeaderField: "User-Agent")

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else { return nil }
            return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
        } catch {
            return nil
        }
    }

    private static func refreshGoogle(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let body = formBody([
            "client_id": googleClientID,
            "client_secret": googleClientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        guard let json = await postForm(
            url: "https://oauth2.googleapis.com/token",
            body: body
        ) else { return nil }
        // Google does not always return a new refresh_token.
        return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: false)
    }

    /// Public Grok CLI OIDC client (same id Grok Build stores under `oidc_client_id`).
    static let xAIGrokClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    /// OIDC discovery (`/.well-known/openid-configuration`) lists `/oauth2/token`.
    /// The legacy `/oauth/token` path is Cloudflare 403 and must not be first.
    static let xAITokenEndpoints = [
        "https://auth.x.ai/oauth2/token",
        "https://auth.x.ai/oauth/token",
    ]

    static func xAIClientID(from payload: [String: Any]) -> String {
        if let id = stringValue(payload, keys: ["oidc_client_id", "client_id"]), !id.isEmpty {
            return id
        }
        if let token = stringValue(payload, keys: ["access_token", "key"]) {
            if let id = jwtClaimString(token, key: "client_id"), !id.isEmpty { return id }
            if let id = jwtClaimString(token, key: "aud"), !id.isEmpty { return id }
        }
        return xAIGrokClientID
    }

    private static func refreshXAI(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let clientID = xAIClientID(from: payload)
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ])
        for endpoint in xAITokenEndpoints {
            if let json = await postForm(url: endpoint, body: body) {
                guard var updated = applyOAuthTokenResponse(
                    json,
                    to: payload,
                    preferRefreshFromResponse: true
                ) else { continue }
                updated["oidc_client_id"] = clientID
                updated["client_id"] = clientID
                return updated
            }
        }
        return nil
    }

    private static func syncGrokCLICredentials(oldRefresh: String, updated: [String: Any]) {
        guard let access = stringValue(updated, keys: ["access_token", "key"]) else { return }
        if NativeUsageFetcher.updateGrokAppPayload(
            oldRefresh: oldRefresh,
            accessToken: access,
            refreshToken: stringValue(updated, keys: ["refresh_token"]),
            expiresAt: stringValue(updated, keys: ["expired", "expires_at", "expiresAt"])
        ) {
            NSLog("[TokenRefresh] Synced rotated refresh token to ~/.grok/auth.json")
        }
    }

    private static func refreshKiro(_ payload: [String: Any]) async -> [String: Any]? {
        if let aws = await KiroAWSAuth.refresh(payload) {
            return aws
        }
        guard let refresh = stringValue(payload, keys: ["refreshToken", "refresh_token"]) else {
            return nil
        }
        let region = stringValue(payload, keys: ["region"]) ?? "us-east-1"
        let endpoints = [
            "https://prod.\(region).auth.desktop.kiro.dev/refreshToken",
            "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken",
        ]
        let jsonBody: [String: Any] = ["refreshToken": refresh]
        for endpoint in endpoints {
            if let json = await postJSON(url: endpoint, body: jsonBody) {
                var updated = payload
                if let access = stringValue(json, keys: ["accessToken", "access_token"]) {
                    updated["access_token"] = access
                    updated["accessToken"] = access
                }
                if let newRefresh = stringValue(json, keys: ["refreshToken", "refresh_token"]) {
                    updated["refresh_token"] = newRefresh
                    updated["refreshToken"] = newRefresh
                }
                if let expiresAt = stringValue(json, keys: ["expiresAt", "expires_at"]) {
                    updated["expires_at"] = expiresAt
                    updated["expired"] = expiresAt
                } else if let expiresIn = json["expiresIn"] as? Int ?? json["expires_in"] as? Int {
                    let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
                    updated["expired"] = isoString(exp)
                    updated["expires_at"] = isoString(exp)
                    updated["expires_in"] = expiresIn
                }
                updated["last_refresh"] = isoString(Date())
                return updated
            }
        }
        return nil
    }

    private static func refreshKimi(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let body = formBody([
            "client_id": kimiClientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        guard let json = await postForm(
            url: "https://auth.kimi.com/api/oauth/token",
            body: body
        ) else { return nil }
        return applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true)
    }

    private static func refreshCursor(_ payload: [String: Any]) async -> [String: Any]? {
        guard let refresh = refreshToken(from: payload) else { return nil }
        let jsonBody: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": cursorClientID,
            "refresh_token": refresh,
        ]
        guard let json = await postJSON(url: "https://api2.cursor.sh/oauth/token", body: jsonBody),
              json["shouldLogout"] as? Bool != true
        else { return nil }
        guard let updated = applyOAuthTokenResponse(json, to: payload, preferRefreshFromResponse: true) else {
            return nil
        }
        var out = updated
        if let access = stringValue(out, keys: ["access_token"]) {
            out["accessToken"] = access
        }
        if let newRefresh = stringValue(out, keys: ["refresh_token"]) {
            out["refreshToken"] = newRefresh
        }
        return out
    }

    private static func applyOAuthTokenResponse(
        _ json: [String: Any],
        to payload: [String: Any],
        preferRefreshFromResponse: Bool
    ) -> [String: Any]? {
        guard let access = stringValue(json, keys: ["access_token", "accessToken"]) else { return nil }
        var updated = payload
        updated["access_token"] = access
        if let idToken = stringValue(json, keys: ["id_token", "idToken"]) {
            updated["id_token"] = idToken
        }
        if preferRefreshFromResponse, let newRefresh = stringValue(json, keys: ["refresh_token", "refreshToken"]) {
            updated["refresh_token"] = newRefresh
        }
        let expiresIn = (json["expires_in"] as? Int)
            ?? (json["expires_in"] as? Double).map { Int($0) }
            ?? 3600
        updated["expires_in"] = expiresIn
        let expDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        updated["expired"] = isoString(expDate)
        updated["last_refresh"] = isoString(Date())
        return updated
    }

    // MARK: - HTTP helpers

    private static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents adds a leading "?" — strip it for form bodies.
        let encoded = components.percentEncodedQuery ?? ""
        return Data(encoded.utf8)
    }

    private static func postOpenAIRefresh(refreshToken: String) async -> OAuthGrantResult {
        guard let endpoint = URL(string: "https://auth.openai.com/oauth/token") else { return .failed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = formBody(openAIRefreshFields(refreshToken: refreshToken))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if bodyText.lowercased().contains("refresh_token_reused") {
                NSLog("[TokenRefresh] OpenAI refresh_token_reused — stopping sibling attempts")
                return .reuseRevoked
            }
            guard let http = response as? HTTPURLResponse else { return .failed }
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil,
                  stringValue(json, keys: ["access_token"]) != nil
            else {
                NSLog("[TokenRefresh] OpenAI refresh failed status %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return .failed
            }
            return .success(json)
        } catch {
            NSLog("[TokenRefresh] OpenAI refresh request error: %@", error.localizedDescription)
            return .failed
        }
    }

    private static func postForm(url: String, body: Data) async -> [String: Any]? {
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    private static func postJSON(url: String, body: [String: Any]) async -> [String: Any]? {
        guard let endpoint = URL(string: url),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            else { return nil }
            return json
        } catch {
            return nil
        }
    }

    private static func writeAuthFile(_ payload: [String: Any], to file: URL) -> Bool {
        guard AccountCredentialIdentity.isConsistent(payload) else { return false }
        if let original = NativeUsageFetcher.readAuthPayload(at: file), AccountCredentialIdentity.hasConflict(original, payload) { return false }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("[TokenRefresh] Failed to write %@: %@", file.lastPathComponent, error.localizedDescription)
            return false
        }
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

    static func parseDateAny(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let date = value as? Date { return date }
        if let num = value as? NSNumber {
            let t = num.doubleValue
            if t > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: t / 1000.0)
            } else if t > 1_000_000_000 {
                return Date(timeIntervalSince1970: t)
            }
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t = Double(trimmed) {
                if t > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: t / 1000.0)
                } else if t > 1_000_000_000 {
                    return Date(timeIntervalSince1970: t)
                }
            }
            return parseDate(trimmed)
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func accessTokenIssuedAt(from payload: [String: Any]) -> Date? {
        guard let token = stringValue(payload, keys: ["access_token", "accessToken", "key"]) else {
            return nil
        }
        return jwtClaimDate(token, key: "iat")
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        jwtClaimDate(token, key: "exp")
    }

    private static func jwtClaimDate(_ token: String, key: String) -> Date? {
        guard let json = jwtPayload(token) else { return nil }
        if let value = json[key] as? TimeInterval {
            return Date(timeIntervalSince1970: value)
        }
        if let value = json[key] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func jwtClaimString(_ token: String, key: String) -> String? {
        guard let json = jwtPayload(token),
              let value = json[key] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// One in-flight OpenAI grant per refresh token. A second POST with the old token
/// returns `refresh_token_reused` and OpenAI revokes the family.
private actor OpenAIRefreshFlight {
    static let shared = OpenAIRefreshFlight()
    private var inflight: [String: Task<TokenRefreshService.OAuthGrantResult, Never>] = [:]

    func run(
        token: String,
        work: @Sendable @escaping () async -> TokenRefreshService.OAuthGrantResult
    ) async -> TokenRefreshService.OAuthGrantResult {
        if let existing = inflight[token] {
            return await existing.value
        }
        let task = Task { await work() }
        inflight[token] = task
        let result = await task.value
        inflight[token] = nil
        return result
    }
}
