import AppKit
import Foundation
import SQLite3

/// Identity of whatever account is *currently live* in a native tool.
struct NativeSessionIdentity: Equatable {
    let email: String?
    let accountID: String?
    let plan: String?

    var label: String { email ?? accountID ?? "unknown" }
}

enum NativeSwitchOutcome: Equatable {
    case switched(message: String)
    case failure(message: String)
}

/// Detects which account is active in the native CLI/desktop tools and switches the
/// active session by rewriting the native auth files and (optionally) restarting the
/// associated desktop app — the same technique Cockpit Tools uses.
///
/// VibeRouter stores accounts as CLIProxy auth files under `~/.cli-proxy-api/`; this
/// manager translates a selected account's tokens into the *native* auth location
/// (`~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.gemini/oauth_creds.json`,
/// Antigravity IDE `state.vscdb` + Cockpit `current_account.json`).
///
/// For ChatGPT/Codex, one OAuth login can own **multiple** workspaces (Go + Team/Enterprise).
/// `switchTo(..., chatGPTAccountID:)` writes that membership's id into `tokens.account_id`
/// so Codex/ChatGPT actually run under the chosen subscription — not always JWT "go".
final class NativeSessionManager: ObservableObject {
    static let shared = NativeSessionManager()

    /// Detected live identity per provider (nil = none / not logged in).
    @Published private(set) var currentByProvider: [ServiceType: NativeSessionIdentity] = [:]
    /// `AuthAccount.id`s that are the live native session (for hiding the Switch button).
    @Published private(set) var currentAccountIDs: Set<String> = []
    @Published private(set) var isRefreshing = false

    private let fileManager = FileManager.default
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Providers we can both detect and switch.
    /// Antigravity uses its own IDE state DB + Cockpit pointer — not Gemini's
    /// `~/.gemini/google_accounts.json`.
    static let switchableProviderIDs: Set<String> = ["codex", "claude", "gemini", "antigravity", "cursor"]

    func supportsSwitching(_ type: ServiceType) -> Bool {
        guard let id = type.usageProviderID else { return false }
        return Self.switchableProviderIDs.contains(id)
    }

    func isCurrent(_ account: AuthAccount) -> Bool {
        currentAccountIDs.contains(account.id)
    }

    /// True when the native Codex session is already on this ChatGPT workspace/subscription.
    func isCurrentSubscription(_ account: AuthAccount, chatGPTAccountID: String?) -> Bool {
        guard account.type == .codex else { return isCurrent(account) }
        guard let identity = currentByProvider[.codex] else { return false }
        guard matches(account, identity) else { return false }
        guard let wanted = chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wanted.isEmpty
        else {
            // No explicit membership: "current login" if email/account matches.
            return true
        }
        return identity.accountID?.caseInsensitiveCompare(wanted) == .orderedSame
    }

    func currentIdentity(for type: ServiceType) -> NativeSessionIdentity? {
        currentByProvider[type]
    }

    // MARK: - Detection

    /// Reads the native auth locations off the main thread and matches them against the
    /// provided VibeRouter accounts. Cheap (small files + one keychain read for Claude).
    func refresh(accounts: [ServiceType: [AuthAccount]]) {
        isRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let (identities, ids) = await self.detectAll(accounts: accounts)
            await MainActor.run {
                self.currentByProvider = identities
                self.currentAccountIDs = ids
                self.isRefreshing = false
            }
        }
    }

    /// Awaitable detection for command-line callers that must print a complete snapshot.
    @MainActor
    func refreshNow(accounts: [ServiceType: [AuthAccount]]) async {
        isRefreshing = true
        let (identities, ids) = await Task.detached(priority: .utility) { [self] in
            await detectAll(accounts: accounts)
        }.value
        currentByProvider = identities
        currentAccountIDs = ids
        isRefreshing = false
    }

    private func detectAll(
        accounts: [ServiceType: [AuthAccount]]
    ) async -> ([ServiceType: NativeSessionIdentity], Set<String>) {
        var identities: [ServiceType: NativeSessionIdentity] = [:]
        var ids = Set<String>()

        for type in ServiceType.allCases {
            guard let providerID = type.usageProviderID,
                  Self.switchableProviderIDs.contains(providerID),
                  let identity = detectIdentity(for: type)
            else { continue }
            identities[type] = identity

            // Mark every matching seat file (Codex can have Go + Team rows for one email).
            for account in accounts[type] ?? [] where matches(account, identity) {
                ids.insert(account.id)
            }
        }
        return (identities, ids)
    }

    private func detectIdentity(for type: ServiceType) -> NativeSessionIdentity? {
        switch type {
        case .codex: return detectCodexIdentity()
        case .claude: return detectClaudeIdentity()
        case .gemini: return detectGoogleIdentity()
        case .antigravity: return detectAntigravityIdentity()
        case .cursor: return detectCursorIdentity()
        default: return nil
        }
    }

    private func detectCodexIdentity() -> NativeSessionIdentity? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let json = readJSON(url) else { return nil }
        let tokens = (json["tokens"] as? [String: Any]) ?? json
        let access = tokens["access_token"] as? String
        let claims = access.flatMap(Self.decodeJWT)
        let accountID = (tokens["account_id"] as? String)
            ?? Self.openAIAccountID(from: claims)
        let email = Self.openAIEmail(from: claims)
        let plan = Self.openAIPlan(from: claims)
        guard accountID != nil || email != nil else { return nil }
        return NativeSessionIdentity(email: email, accountID: accountID, plan: plan)
    }

    private func detectClaudeIdentity() -> NativeSessionIdentity? {
        // Identity lives in ~/.claude.json (or ~/.claude/.claude.json) → oauthAccount.
        let configURLs = [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude/.claude.json"),
        ]
        for configURL in configURLs {
            if let json = readJSON(configURL),
               let oauth = json["oauthAccount"] as? [String: Any]
            {
                let email = oauth["emailAddress"] as? String
                let uuid = oauth["accountUuid"] as? String
                if email != nil || uuid != nil {
                    return NativeSessionIdentity(email: email, accountID: uuid, plan: nil)
                }
            }
        }
        // Fall back to presence of credentials (logged in but identity unknown).
        if readClaudeCredentials() != nil {
            return NativeSessionIdentity(email: nil, accountID: nil, plan: nil)
        }
        return nil
    }

    private func detectGoogleIdentity() -> NativeSessionIdentity? {
        let url = home.appendingPathComponent(".gemini/google_accounts.json")
        guard let json = readJSON(url) else { return nil }
        guard let active = json["active"] as? String, !active.isEmpty else { return nil }
        return NativeSessionIdentity(email: active, accountID: nil, plan: nil)
    }

    private func detectAntigravityIdentity() -> NativeSessionIdentity? {
        // 1) Cockpit pointer (written on switch).
        if let email = readAntigravityCurrentEmail() {
            return NativeSessionIdentity(email: email, accountID: nil, plan: nil)
        }
        // 2) Email embedded in Antigravity IDE userStatus state.
        if let email = readAntigravityIDEEmail() {
            return NativeSessionIdentity(email: email, accountID: nil, plan: nil)
        }
        // 3) Token present but identity unknown — still mark as logged-in.
        if readAntigravityStateValue(key: Self.antigravityOAuthTokenKey) != nil {
            return NativeSessionIdentity(email: nil, accountID: nil, plan: nil)
        }
        return nil
    }

    private func detectCursorIdentity() -> NativeSessionIdentity? {
        let db = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let email = VscdbStore.readString(dbURL: db, key: "cursorAuth/cachedEmail")
            ?? VscdbStore.readString(dbURL: db, key: "cursor.email")
        let token = VscdbStore.readString(dbURL: db, key: "cursorAuth/accessToken")
        guard email != nil || token != nil else { return nil }
        let plan = VscdbStore.readString(dbURL: db, key: "cursorAuth/stripeMembershipType")
        return NativeSessionIdentity(email: email, accountID: nil, plan: plan)
    }

    private func readAntigravityCurrentEmail() -> String? {
        let url = home.appendingPathComponent(".antigravity_cockpit/current_account.json")
        guard let json = readJSON(url),
              let email = nonEmpty(json["email"])
        else { return nil }
        return email
    }

    private func readAntigravityIDEEmail() -> String? {
        guard let raw = readAntigravityStateValue(key: Self.antigravityUserStatusKey) else { return nil }
        return Self.extractEmailFromAntigravityUserStatus(raw)
    }

    private func matches(_ account: AuthAccount, _ identity: NativeSessionIdentity) -> Bool {
        Self.matchesSession(
            accountType: account.type,
            accountEmail: account.email,
            accountSeatID: codexAccountID(from: account),
            identity: identity
        )
    }

    /// Pure session match used by detection + tests.
    ///
    /// Codex: seat id distinguishes Go vs Team for one login. Email distinguishes two
    /// people on the same Team org (shared `chatgpt_account_id`) — without email, both
    /// would show as the "Active" native session.
    static func matchesSession(
        accountType: ServiceType,
        accountEmail: String?,
        accountSeatID: String?,
        identity: NativeSessionIdentity
    ) -> Bool {
        if accountType == .codex {
            let fileID = accountSeatID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let identityID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let seatMatch: Bool = {
                guard let fileID, let identityID else { return false }
                return fileID.caseInsensitiveCompare(identityID) == .orderedSame
            }()

            let emailMatch: Bool? = {
                guard let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !email.isEmpty,
                      let other = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !other.isEmpty
                else { return nil }
                return email == other
            }()

            if seatMatch {
                // Same org seat: only the native login email is "current".
                return emailMatch == true
            }
            // Different seats (seat known on both sides) never match by email alone.
            if fileID != nil, identityID != nil {
                return false
            }
            // No seat id on either side — fall through to email.
            return emailMatch == true
        }
        if let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let other = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           email.contains("@"), other.contains("@"),
           email == other
        {
            return true
        }
        return false
    }

    private func codexAccountID(from account: AuthAccount) -> String? {
        guard let payload = readJSON(account.filePath) else { return nil }
        if let access = payload["access_token"] as? String,
           let id = Self.openAIAccountID(from: Self.decodeJWT(access)),
           !id.isEmpty
        {
            return id
        }
        if let id = payload["account_id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Switching

    /// Switch the native session to `account`.
    /// - Parameter chatGPTAccountID: For Codex multi-subscription logins, the membership /
    ///   workspace id whose **JWT-scoped** tokens must be written (Team/Enterprise vs Go).
    ///   Pinning `tokens.account_id` alone is not enough — the access token must belong to that seat
    ///   (same model as Cockpit Tools' per-seat account store).
    /// - Parameter subscriptionLabel: Human label for the toast (e.g. "ChatGPT Team · CR").
    @MainActor
    func switchTo(
        _ account: AuthAccount,
        chatGPTAccountID: String? = nil,
        subscriptionLabel: String? = nil,
        restartApp: Bool
    ) async -> NativeSwitchOutcome {
        guard supportsSwitching(account.type) else {
            return .failure(message: "Switching \(account.type.displayName) is not supported yet.")
        }
        guard let src = readJSON(account.filePath) else {
            return .failure(message: "Could not read credentials for \(account.baseDisplayName).")
        }
        guard AccountCredentialIdentity.isConsistent(src) else {
            return .failure(message: "This account's credentials do not match its identity. Re-import its own session before switching.")
        }

        // Disk + Keychain writes run off the main thread (the `security` subprocess can
        // block for ~100ms). Only the AppKit app-restart below stays on the main actor.
        let type = account.type
        let email = account.email
        let preferredAccountID = chatGPTAccountID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let authFilePath = account.filePath

        // Antigravity IDE keeps state.vscdb open; quit first when restart-on-switch is on
        // so the oauthToken write is not blocked / overwritten.
        if (type == .antigravity || type == .cursor), restartApp {
            _ = await quitApps(for: type)
        }

        let (writeError, cliResult): (String?, AntigravityCLISwitchResult?) = await Task.detached(
            priority: .userInitiated
        ) { [self] in
            do {
                switch type {
                case .codex:
                    try await writeCodexAuth(
                        from: src,
                        preferredAccountID: preferredAccountID,
                        email: email,
                        alsoUpdateAuthFile: authFilePath
                    )
                case .claude: try writeClaudeAuth(from: src)
                case .gemini: try writeGoogleAuth(from: src, email: email)
                case .antigravity: return (nil, try writeAntigravityAuth(from: src, email: email))
                case .cursor: try writeCursorAuth(from: src)
                default: return ("Switching \(type.displayName) is not supported yet.", nil)
                }
                return (nil, nil)
            } catch {
                return ("Switch failed: \(error.localizedDescription)", nil)
            }
        }.value

        if let writeError { return .failure(message: writeError) }

        // Update live identity from disk immediately (full account list refresh follows via UI).
        // Drop prior "current" markers for this provider's filenames so a sibling Team login
        // does not keep showing Active for a frame after switch.
        if let identity = detectIdentity(for: type) {
            currentByProvider[type] = identity
            let prefix = type.rawValue.lowercased()
            var next = currentAccountIDs.filter { id in
                let lower = id.lowercased()
                if lower.hasPrefix(prefix) { return false }
                if type == .codex, lower.hasPrefix("codex-seat") { return false }
                return true
            }
            if matches(account, identity) {
                next.insert(account.id)
            }
            currentAccountIDs = next
        }

        let targetName = subscriptionLabel?.nilIfEmpty
            ?? account.baseDisplayName
        var msg = "Switched \(type.displayName) to \(targetName)."
        if restartApp {
            // Antigravity was already quit above; only relaunch.
            let restarted: [String]
            if type == .antigravity || type == .cursor {
                restarted = await relaunchApps(for: type)
            } else {
                restarted = await restartApps(for: type)
            }
            if !restarted.isEmpty {
                msg += " Restarted \(restarted.joined(separator: ", "))."
            } else {
                msg += " Native auth written — launch \(type.displayName) to pick it up."
            }
        } else {
            msg += " Restart the app (or enable restart-on-switch in Settings) to load it."
        }
        switch cliResult {
        case .updated:
            msg += " agy CLI switched too; restart running agy sessions to load it."
        case .unrecognized:
            msg += " agy CLI token format was not recognized, so agy was left on its previous account."
        case .writeFailed:
            msg += " Could not update the agy CLI token, so agy was left on its previous account."
        case .notSignedIn, nil:
            break
        }
        return .switched(message: msg)
    }

    // MARK: - Native writers

    private func writeCodexAuth(
        from src: [String: Any],
        preferredAccountID: String? = nil,
        email: String? = nil,
        alsoUpdateAuthFile: URL? = nil
    ) async throws {
        // Resolve a token lineage whose JWT is scoped to the target seat, refreshing if needed
        // (same as Cockpit prepare_account_for_injection before inject).
        // Do not call materializeSeatAuthFiles here in a loop — one persist of the resolved seat
        // is enough and avoids FSEvent thrash.
        let resolved: CodexWorkspaceCredentials.Payload
        switch await CodexWorkspaceCredentials.resolveFresh(
            preferredAccountID: preferredAccountID,
            seed: src,
            email: email
        ) {
        case .success(let payload):
            resolved = payload
        case .failure(let err):
            throw SwitchError.resolveFailed(err.localizedDescription)
        }

        let access = resolved.accessToken
        let accountID = resolved.accountID

        let url = home.appendingPathComponent(".codex/auth.json")
        try ensureParent(url)

        var tokens: [String: Any] = [
            "access_token": access,
            "account_id": accountID,
        ]
        if let idToken = resolved.idToken { tokens["id_token"] = idToken }
        if let refresh = resolved.refreshToken { tokens["refresh_token"] = refresh }

        var out: [String: Any] = ["tokens": tokens]
        if let existing = readJSON(url), let key = existing["OPENAI_API_KEY"], !(key is NSNull) {
            out["OPENAI_API_KEY"] = key
        } else {
            out["OPENAI_API_KEY"] = NSNull()
        }
        out["last_refresh"] = Self.isoNow()

        try backupThenWrite(json: out, to: url)

        // Official Codex CLI/desktop read "Codex Auth" keychain first (Cockpit writes both).
        let codexHome = home.appendingPathComponent(".codex")
        _ = CodexWorkspaceCredentials.writeKeychain(authFileJSON: out, codexHome: codexHome)

        // Persist BOTH seats: snapshot outgoing, write incoming seat file, update active auth file.
        if let alsoUpdateAuthFile {
            try snapshotOutgoingCodexSeat(from: src, beforeWriting: resolved, near: alsoUpdateAuthFile)
            _ = CodexWorkspaceCredentials.persistSeat(resolved)

            var updated = src
            updated["access_token"] = resolved.accessToken
            if let refresh = resolved.refreshToken { updated["refresh_token"] = refresh }
            if let idToken = resolved.idToken { updated["id_token"] = idToken }
            updated["account_id"] = resolved.accountID
            if let plan = resolved.planType { updated["plan_type"] = plan }
            if let mail = resolved.email ?? email { updated["email"] = mail }
            updated["last_refresh"] = Self.isoNow()
            updated["type"] = "codex"
            // Switching the native workspace must not turn the source account's
            // managed file into the destination account. Its snapshot stays intact.
            if !AccountCredentialIdentity.hasConflict(src, updated) {
                try backupThenWrite(json: updated, to: alsoUpdateAuthFile)
            }

            // Durable per-seat file already written via persistSeat above.
        }
    }

    /// When leaving seat A for seat B, persist A under `codex-seat-{accountID}.json`.
    private func snapshotOutgoingCodexSeat(
        from src: [String: Any],
        beforeWriting incoming: CodexWorkspaceCredentials.Payload,
        near authFile: URL
    ) throws {
        guard let outgoingAccess = nonEmpty(src["access_token"]) else { return }
        let outgoingID = CodexWorkspaceCredentials.chatgptAccountID(from: outgoingAccess)
            ?? nonEmpty(src["account_id"])
        guard let outgoingID,
              outgoingID.caseInsensitiveCompare(incoming.accountID) != .orderedSame
        else { return }

        let plan = CodexWorkspaceCredentials.chatgptPlanType(from: outgoingAccess)
            ?? nonEmpty(src["plan_type"])
        let email = nonEmpty(src["email"])
            ?? JWTEmailExtractor.email(from: nonEmpty(src["id_token"]))
            ?? JWTEmailExtractor.email(from: outgoingAccess)

        var snap = src
        snap["type"] = "codex"
        snap["account_id"] = outgoingID
        if let plan { snap["plan_type"] = plan }
        if let email { snap["email"] = email }

        let seatURL = authFile.deletingLastPathComponent()
            .appendingPathComponent(AccountCredentialIdentity.filename(snap))
        // Prefer not to clobber a fresher live seat file with an older snapshot.
        if let existing = readJSON(seatURL),
           let existingAccess = nonEmpty(existing["access_token"]),
           let existingExp = CodexWorkspaceCredentials.accessTokenExpiry(existingAccess),
           let outgoingExp = CodexWorkspaceCredentials.accessTokenExpiry(outgoingAccess),
           existingExp > outgoingExp
        {
            return
        }
        try AccountCredentialStore.save(snap, in: authFile.deletingLastPathComponent())
    }

    private func writeClaudeAuth(from src: [String: Any]) throws {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        // Never clobber Claude Code's keychain with an access-token-only copy.
        // Imported VibeRouter files omit the refresh token on purpose.
        guard let refresh = nonEmpty(src["refresh_token"]) else {
            throw SwitchError.missingToken("refresh_token")
        }
        var oauth: [String: Any] = ["accessToken": access, "refreshToken": refresh]
        if let expiresAt = expiryMillis(from: src) { oauth["expiresAt"] = expiresAt }
        if let sub = nonEmpty(src["subscriptionType"]) ?? nonEmpty(src["plan_type"]) {
            oauth["subscriptionType"] = sub
        }
        oauth["scopes"] = ["user:inference", "user:profile"]
        let credentials: [String: Any] = ["claudeAiOauth": oauth]

        // macOS primary store is the Keychain; also write the plaintext file as fallback.
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
        if let jsonString = String(data: data, encoding: .utf8) {
            writeClaudeKeychain(jsonString)
        }
        let credURL = home.appendingPathComponent(".claude/.credentials.json")
        try? ensureParent(credURL)
        _ = try? backupThenWrite(json: credentials, to: credURL)

        // Merge identity into ~/.claude.json and ~/.claude/.claude.json so detection reflects the switch.
        if let email = nonEmpty(src["email"]) {
            let configURLs = [
                home.appendingPathComponent(".claude.json"),
                home.appendingPathComponent(".claude/.claude.json"),
            ]
            for configURL in configURLs {
                var config = readJSON(configURL) ?? [:]
                var oauthAccount = (config["oauthAccount"] as? [String: Any]) ?? [:]
                oauthAccount["emailAddress"] = email
                config["oauthAccount"] = oauthAccount
                _ = try? backupThenWrite(json: config, to: configURL)
            }
        }
    }

    private func writeGoogleAuth(from src: [String: Any], email: String?) throws {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        var creds: [String: Any] = ["access_token": access, "token_type": "Bearer"]
        if let refresh = nonEmpty(src["refresh_token"]) { creds["refresh_token"] = refresh }
        if let idToken = nonEmpty(src["id_token"]) { creds["id_token"] = idToken }
        if let expiry = expiryMillis(from: src) { creds["expiry_date"] = expiry }
        creds["scope"] = "https://www.googleapis.com/auth/cloud-platform"

        let credURL = home.appendingPathComponent(".gemini/oauth_creds.json")
        try ensureParent(credURL)
        try backupThenWrite(json: creds, to: credURL)

        // Update the active-account pointer.
        if let email {
            let accountsURL = home.appendingPathComponent(".gemini/google_accounts.json")
            var accounts = readJSON(accountsURL) ?? [:]
            var old = (accounts["old"] as? [String]) ?? []
            if let previous = accounts["active"] as? String,
               !previous.isEmpty,
               previous.lowercased() != email.lowercased(),
               !old.contains(previous)
            {
                old.append(previous)
            }
            old.removeAll { $0.lowercased() == email.lowercased() }
            accounts["active"] = email
            accounts["old"] = old
            try backupThenWrite(json: accounts, to: accountsURL)
        }
    }

    /// Inject OAuth into Antigravity IDE `state.vscdb` (same wire format Cockpit uses) and
    /// update Cockpit's `current_account.json` pointer for detection.
    private func writeAntigravityAuth(from src: [String: Any], email: String?) throws -> AntigravityCLISwitchResult {
        guard let access = nonEmpty(src["access_token"]) else {
            throw SwitchError.missingToken("access_token")
        }
        let refresh = nonEmpty(src["refresh_token"])
        let expirySeconds = antigravityExpirySeconds(from: src)

        let existing = readAntigravityStateValue(key: Self.antigravityOAuthTokenKey)
        let tokenValue = try Self.buildAntigravityOAuthTokenValue(
            accessToken: access,
            refreshToken: refresh,
            expirySeconds: expirySeconds,
            existingValue: existing
        )
        try writeAntigravityStateValue(key: Self.antigravityOAuthTokenKey, value: tokenValue)

        if let email {
            let url = home.appendingPathComponent(".antigravity_cockpit/current_account.json")
            try ensureParent(url)
            let payload: [String: Any] = [
                "email": email,
                "updated_at": Int(Date().timeIntervalSince1970),
            ]
            try backupThenWrite(json: payload, to: url)
        }

        return writeAntigravityCLIAuth(
            accessToken: access,
            refreshToken: refresh,
            idToken: nonEmpty(src["id_token"]),
            email: email,
            expiry: Date(timeIntervalSince1970: TimeInterval(expirySeconds))
        )
    }

    // MARK: - Antigravity CLI (`agy`)

    private var antigravityCLITokenURL: URL {
        home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    enum AntigravityCLISwitchResult: Equatable {
        case notSignedIn
        case updated
        case unrecognized
        case writeFailed
    }

    /// Rewrite the `agy` CLI's saved OAuth token in place so the CLI follows the IDE switch.
    /// Skipped when `agy` has never signed in; refuses to touch a token format it can't parse.
    private func writeAntigravityCLIAuth(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        expiry: Date
    ) -> AntigravityCLISwitchResult {
        let url = antigravityCLITokenURL
        guard let existing = try? Data(contentsOf: url) else { return .notSignedIn }
        guard let updated = AntigravityCLIToken.update(
            existing,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            email: email,
            expiry: expiry
        ) else { return .unrecognized }
        do {
            try backupThenWrite(data: updated, to: url)
        } catch {
            return .writeFailed
        }
        return .updated
    }

    private func writeCursorAuth(from src: [String: Any]) throws {
        guard let access = nonEmpty(src["access_token"]) ?? nonEmpty(src["accessToken"]) else {
            throw SwitchError.missingToken("access_token")
        }
        let db = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try VscdbStore.writeString(dbURL: db, key: "cursorAuth/accessToken", value: access)
        try VscdbStore.writeString(dbURL: db, key: "cursor.accessToken", value: access)
        if let refresh = nonEmpty(src["refresh_token"]) ?? nonEmpty(src["refreshToken"]) {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/refreshToken", value: refresh)
        }
        if let email = nonEmpty(src["email"]) ?? nonEmpty(src["cachedEmail"]) {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/cachedEmail", value: email)
            try VscdbStore.writeString(dbURL: db, key: "cursor.email", value: email)
        }
        if let plan = nonEmpty(src["membership_type"]) ?? nonEmpty(src["plan_type"]) {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/stripeMembershipType", value: plan)
        }
    }

    private func antigravityExpirySeconds(from src: [String: Any]) -> Int {
        if let expired = nonEmpty(src["expired"]) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: expired) ?? plain.date(from: expired) {
                return Int(date.timeIntervalSince1970)
            }
        }
        if let expiresIn = src["expires_in"] as? Int, expiresIn > 0 {
            return Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970)
        }
        if let ts = src["expiry_timestamp"] as? Double, ts > 0 {
            return Int(ts)
        }
        if let ts = src["expiry_timestamp"] as? Int, ts > 0 {
            return ts
        }
        return Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
    }

    // MARK: - Antigravity IDE state.vscdb (Cockpit-compatible)

    private static let antigravityOAuthTokenKey = "antigravityUnifiedStateSync.oauthToken"
    private static let antigravityUserStatusKey = "antigravityUnifiedStateSync.userStatus"
    private static let antigravityAuthStateSentinel = "authStateWithContextSentinelKey"
    private static let antigravityOAuthInfoSentinel = "oauthTokenInfoSentinelKey"
    private static let antigravitySignedInStateJSON =
        #"{"state":"signedIn","context":{"project":"","showProjectError":false,"errorMessage":"","ineligibleMessage":"","verificationUrl":"","isGcpTos":false,"browserOpenFailed":false,"appealUrl":"","appealLinkText":""}}"#

    private var antigravityStateDBURL: URL {
        home.appendingPathComponent(
            "Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
        )
    }

    private func readAntigravityStateValue(key: String) -> String? {
        let path = antigravityStateDBURL.path
        guard fileManager.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        let bytes = sqlite3_column_bytes(stmt, 0)
        if bytes > 0, let blob = sqlite3_column_blob(stmt, 0) {
            let data = Data(bytes: blob, count: Int(bytes))
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func writeAntigravityStateValue(key: String, value: String) throws {
        let url = antigravityStateDBURL
        try ensureParent(url)
        let path = url.path
        // Create empty DB + table if IDE has never been launched.
        if !fileManager.fileExists(atPath: path) {
            var createDB: OpaquePointer?
            guard sqlite3_open(path, &createDB) == SQLITE_OK else {
                sqlite3_close(createDB)
                throw SwitchError.resolveFailed("Could not create Antigravity IDE state database")
            }
            defer { sqlite3_close(createDB) }
            let createSQL = "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"
            if sqlite3_exec(createDB, createSQL, nil, nil, nil) != SQLITE_OK {
                throw SwitchError.resolveFailed("Could not initialize Antigravity IDE state database")
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw SwitchError.resolveFailed("Could not open Antigravity IDE state database (is Antigravity IDE fully closed?)")
        }
        defer { sqlite3_close(db) }

        let sql = "INSERT INTO ItemTable (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SwitchError.resolveFailed("Could not prepare Antigravity state write")
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let valueData = Data(value.utf8)
        valueData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress
            sqlite3_bind_blob(stmt, 2, ptr, Int32(valueData.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw SwitchError.resolveFailed("Antigravity state write failed: \(msg)")
        }
    }

    /// Build the base64 `antigravityUnifiedStateSync.oauthToken` blob Cockpit/IDE expect.
    /// Preserves other sentinel rows from `existingValue` when present.
    static func buildAntigravityOAuthTokenValue(
        accessToken: String,
        refreshToken: String?,
        expirySeconds: Int,
        existingValue: String?
    ) throws -> String {
        var sentinels = parseAntigravitySentinelMap(existingValue)
        sentinels[antigravityAuthStateSentinel] = antigravitySignedInStateJSON
        sentinels[antigravityOAuthInfoSentinel] = encodeAntigravityOAuthInfoB64(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expirySeconds: expirySeconds
        )
        // Prefer stable order: auth state first, then oauth info, then any extras.
        var ordered: [(String, String)] = []
        if let v = sentinels.removeValue(forKey: antigravityAuthStateSentinel) {
            ordered.append((antigravityAuthStateSentinel, v))
        }
        if let v = sentinels.removeValue(forKey: antigravityOAuthInfoSentinel) {
            ordered.append((antigravityOAuthInfoSentinel, v))
        }
        for key in sentinels.keys.sorted() {
            if let v = sentinels[key] { ordered.append((key, v)) }
        }
        let outer = encodeAntigravitySentinelMap(ordered)
        return outer.base64EncodedString()
    }

    /// Parse access token from an IDE oauthToken value (for tests / diagnostics).
    static func parseAntigravityAccessToken(fromOAuthTokenValue value: String) -> String? {
        let sentinels = parseAntigravitySentinelMap(value)
        guard let infoB64 = sentinels[antigravityOAuthInfoSentinel],
              let infoData = Data(base64Encoded: infoB64)
        else { return nil }
        let fields = protoParseLengthDelimited(infoData)
        return fields.first(where: { $0.field == 1 }).flatMap { String(data: $0.payload, encoding: .utf8) }
    }

    static func extractEmailFromAntigravityUserStatus(_ raw: String) -> String? {
        guard let outer = Data(base64Encoded: raw) else {
            return firstEmail(in: raw)
        }
        if let email = firstEmail(in: String(data: outer, encoding: .utf8) ?? "") {
            return email
        }
        // Nested base64 blobs inside the protobuf often hold name/email.
        let ascii = String(decoding: outer, as: UTF8.self)
        let pattern = try? NSRegularExpression(pattern: "[A-Za-z0-9+/=]{24,}")
        let range = NSRange(ascii.startIndex..., in: ascii)
        let matches = pattern?.matches(in: ascii, range: range) ?? []
        for match in matches {
            guard let r = Range(match.range, in: ascii) else { continue }
            let chunk = String(ascii[r])
            guard let decoded = Data(base64Encoded: chunk) else { continue }
            if let email = firstEmail(in: String(data: decoded, encoding: .utf8) ?? "") {
                return email
            }
            // Email may sit as a raw length-prefixed string without being UTF-8-clean overall.
            if let email = firstEmail(in: String(decoding: decoded, as: UTF8.self)) {
                return email
            }
        }
        return firstEmail(in: String(decoding: outer, as: UTF8.self))
    }

    private static func firstEmail(in text: String) -> String? {
        let pattern = try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern?.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text)
        else { return nil }
        return String(text[r])
    }

    private static func parseAntigravitySentinelMap(_ value: String?) -> [String: String] {
        guard let value,
              let outer = Data(base64Encoded: value)
        else { return [:] }
        var result: [String: String] = [:]
        // Top-level: repeated field 1 messages { field1: key, field2: { field1: value } }
        for entry in protoParseLengthDelimited(outer) where entry.field == 1 {
            let inner = protoParseLengthDelimited(entry.payload)
            guard let keyData = inner.first(where: { $0.field == 1 })?.payload,
                  let key = String(data: keyData, encoding: .utf8)
            else { continue }
            guard let valueMsg = inner.first(where: { $0.field == 2 })?.payload else { continue }
            let valueFields = protoParseLengthDelimited(valueMsg)
            if let valData = valueFields.first(where: { $0.field == 1 })?.payload,
               let val = String(data: valData, encoding: .utf8)
            {
                result[key] = val
            }
        }
        return result
    }

    private static func encodeAntigravitySentinelMap(_ entries: [(String, String)]) -> Data {
        var out = Data()
        for (key, value) in entries {
            let valueMsg = protoEncodeString(field: 1, string: value)
            var entry = Data()
            entry.append(protoEncodeString(field: 1, string: key))
            entry.append(protoEncodeBytes(field: 2, bytes: valueMsg))
            out.append(protoEncodeBytes(field: 1, bytes: entry))
        }
        return out
    }

    private static func encodeAntigravityOAuthInfoB64(
        accessToken: String,
        refreshToken: String?,
        expirySeconds: Int
    ) -> String {
        var token = Data()
        token.append(protoEncodeString(field: 1, string: accessToken))
        token.append(protoEncodeString(field: 2, string: "Bearer"))
        if let refreshToken, !refreshToken.isEmpty {
            token.append(protoEncodeString(field: 3, string: refreshToken))
        }
        // google.protobuf.Timestamp-like: field 4 message { field 1: seconds }
        let ts = protoEncodeVarintField(field: 1, value: UInt64(expirySeconds))
        token.append(protoEncodeBytes(field: 4, bytes: ts))
        return token.base64EncodedString()
    }

    // MARK: Minimal protobuf (length-delimited + varint only)

    private struct ProtoField {
        let field: Int
        let payload: Data
    }

    private static func protoParseLengthDelimited(_ data: Data) -> [ProtoField] {
        var fields: [ProtoField] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let (key, keyEnd) = protoReadVarint(data, at: i) else { break }
            i = keyEnd
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            guard field > 0, field < 1000 else { break }
            if wire == 0 {
                guard let (_, valEnd) = protoReadVarint(data, at: i) else { break }
                i = valEnd
            } else if wire == 2 {
                guard let (len, lenEnd) = protoReadVarint(data, at: i) else { break }
                i = lenEnd
                let length = Int(len)
                guard length >= 0, data.distance(from: i, to: data.endIndex) >= length else { break }
                let end = data.index(i, offsetBy: length)
                fields.append(ProtoField(field: field, payload: data[i..<end]))
                i = end
            } else if wire == 1 {
                guard data.distance(from: i, to: data.endIndex) >= 8 else { break }
                i = data.index(i, offsetBy: 8)
            } else if wire == 5 {
                guard data.distance(from: i, to: data.endIndex) >= 4 else { break }
                i = data.index(i, offsetBy: 4)
            } else {
                break
            }
        }
        return fields
    }

    private static func protoReadVarint(_ data: Data, at start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < data.endIndex {
            let byte = data[i]
            i = data.index(after: i)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, i)
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func protoEncodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v > 0x7F {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
        return out
    }

    private static func protoEncodeVarintField(field: Int, value: UInt64) -> Data {
        var out = protoEncodeVarint(UInt64(field << 3))
        out.append(protoEncodeVarint(value))
        return out
    }

    private static func protoEncodeBytes(field: Int, bytes: Data) -> Data {
        var out = protoEncodeVarint(UInt64((field << 3) | 2))
        out.append(protoEncodeVarint(UInt64(bytes.count)))
        out.append(bytes)
        return out
    }

    private static func protoEncodeString(field: Int, string: String) -> Data {
        protoEncodeBytes(field: field, bytes: Data(string.utf8))
    }

    // MARK: - App restart (quit + relaunch) — Cockpit-style

    private struct AppRestartSpec {
        let label: String
        let bundleIDs: [String]
        let names: [String]
        let pathFragments: [String]
        let processNames: [String]
    }

    private func restartSpec(for type: ServiceType) -> AppRestartSpec? {
        switch type {
        case .codex:
            return AppRestartSpec(
                label: "Codex",
                bundleIDs: ["com.openai.codex", "com.openai.chat"],
                names: ["Codex", "ChatGPT"],
                pathFragments: [
                    "Codex.app/Contents/MacOS/Codex",
                    "ChatGPT.app/Contents/MacOS/ChatGPT",
                ],
                processNames: ["codex"]
            )
        case .claude:
            return AppRestartSpec(
                label: "Claude",
                bundleIDs: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                names: ["Claude"],
                pathFragments: ["Claude.app/Contents/MacOS/Claude"],
                processNames: ["claude"]
            )
        case .gemini:
            return AppRestartSpec(
                label: "Gemini",
                bundleIDs: [],
                names: [],
                pathFragments: [],
                processNames: ["gemini"]
            )
        case .antigravity:
            return AppRestartSpec(
                label: "Antigravity IDE",
                bundleIDs: ["com.google.antigravity-ide", "com.google.antigravity"],
                names: ["Antigravity IDE", "Antigravity"],
                pathFragments: [
                    "Antigravity IDE.app/Contents/MacOS",
                    "Antigravity.app/Contents/MacOS",
                ],
                processNames: []
            )
        case .cursor:
            return AppRestartSpec(
                label: "Cursor",
                bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                names: ["Cursor"],
                pathFragments: ["Cursor.app/Contents/MacOS/Cursor"],
                processNames: []
            )
        default:
            return nil
        }
    }

    /// Kill provider desktop apps (and matching helper processes), then relaunch so they
    /// re-read native auth. Mirrors Cockpit: close Codex processes → rewrite auth already
    /// done → start Codex.app again.
    @MainActor
    private func restartApps(for type: ServiceType) async -> [String] {
        guard let spec = restartSpec(for: type) else { return [] }
        return await killAndRelaunch(
            label: spec.label,
            bundleIDs: spec.bundleIDs,
            names: spec.names,
            pathFragments: spec.pathFragments,
            processNames: spec.processNames
        )
    }

    /// Quit only (no relaunch) — used before Antigravity state.vscdb writes.
    @MainActor
    private func quitApps(for type: ServiceType) async -> [String] {
        guard let spec = restartSpec(for: type) else { return [] }
        return await killAndRelaunch(
            label: spec.label,
            bundleIDs: spec.bundleIDs,
            names: spec.names,
            pathFragments: spec.pathFragments,
            processNames: spec.processNames,
            relaunch: false
        )
    }

    /// Relaunch only (no kill) — used after Antigravity was quit + auth written.
    @MainActor
    private func relaunchApps(for type: ServiceType) async -> [String] {
        guard let spec = restartSpec(for: type) else { return [] }
        return await killAndRelaunch(
            label: spec.label,
            bundleIDs: spec.bundleIDs,
            names: spec.names,
            pathFragments: spec.pathFragments,
            processNames: spec.processNames,
            killRunning: false
        )
    }

    /// Returns human labels of apps that were restarted (or "CLI helpers" if only processes died).
    @MainActor
    private func killAndRelaunch(
        label: String,
        bundleIDs: [String],
        names: [String],
        pathFragments: [String],
        processNames: [String],
        killRunning: Bool = true,
        relaunch: Bool = true
    ) async -> [String] {
        var relaunchURLs: [URL] = []
        var sawRunning = false

        let apps: [NSRunningApplication]
        if killRunning {
            apps = NSWorkspace.shared.runningApplications.filter { app in
                if let bundle = app.bundleIdentifier, bundleIDs.contains(bundle) { return true }
                if let name = app.localizedName,
                   names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                {
                    return true
                }
                return false
            }
            for app in apps {
                sawRunning = true
                if let url = app.bundleURL { relaunchURLs.append(url) }
                app.terminate()
            }

            // Path-fragment kill (Cockpit uses pgrep -f "Codex.app/Contents/MacOS/Codex").
            let pgrepPIDs = Self.pgrepPIDs(pathFragments: pathFragments, processNames: processNames)
            if !pgrepPIDs.isEmpty {
                sawRunning = true
                Self.signalPIDs(pgrepPIDs, sig: SIGTERM)
            }

            // Wait up to ~6s for graceful quit, then SIGKILL stragglers.
            for _ in 0..<12 {
                let stillApps = apps.contains(where: { !$0.isTerminated })
                let stillPIDs = pgrepPIDs.contains(where: { Self.isPIDAlive($0) })
                if !stillApps && !stillPIDs { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            for app in apps where !app.isTerminated { app.forceTerminate() }
            let leftover = pgrepPIDs.filter { Self.isPIDAlive($0) }
            if !leftover.isEmpty { Self.signalPIDs(leftover, sig: SIGKILL) }
        } else {
            apps = []
        }

        guard relaunch else {
            return sawRunning ? ["\(label) processes"] : []
        }

        // Resolve launch URLs even if the app wasn't running (open from /Applications).
        if relaunchURLs.isEmpty {
            for name in names {
                let candidate = URL(fileURLWithPath: "/Applications/\(name).app")
                if fileManager.fileExists(atPath: candidate.path) {
                    relaunchURLs.append(candidate)
                }
            }
            for bundleID in bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    relaunchURLs.append(url)
                }
            }
        }

        // Deduplicate by path.
        var seen = Set<String>()
        let uniqueURLs = relaunchURLs.filter { seen.insert($0.path).inserted }

        guard !uniqueURLs.isEmpty else {
            // Only CLI processes were killed — nothing to relaunch.
            return sawRunning ? ["\(label) processes"] : []
        }

        // Always relaunch when restart-on-switch is on (Cockpit "launch on switch"), so the
        // user lands on the new subscription without a manual open.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        var launched: [String] = []
        for url in uniqueURLs {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                launched.append(url.deletingPathExtension().lastPathComponent)
            } catch {
                // Fall through — auth is still written.
            }
        }
        if launched.isEmpty, sawRunning {
            return ["\(label) processes"]
        }
        return launched
    }

    private static func pgrepPIDs(pathFragments: [String], processNames: [String]) -> [Int32] {
        var pids = Set<Int32>()
        for fragment in pathFragments where !fragment.isEmpty {
            for pid in runPgrep(arguments: ["-f", fragment]) { pids.insert(pid) }
        }
        for name in processNames where !name.isEmpty {
            for pid in runPgrep(arguments: ["-x", name]) { pids.insert(pid) }
        }
        // Never signal ourselves.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        pids.remove(selfPID)
        return Array(pids)
    }

    private static func runPgrep(arguments: [String]) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func signalPIDs(_ pids: [Int32], sig: Int32) {
        for pid in pids where pid > 1 {
            kill(pid, sig)
        }
    }

    private static func isPIDAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - Keychain (Claude)

    private func writeClaudeKeychain(_ json: String) {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-a", user,
            "-s", "Claude Code-credentials",
            "-w", json,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func readClaudeCredentials() -> [String: Any]? {
        // Try Keychain first, then plaintext file.
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", user, "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0,
               let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let jsonData = string.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            {
                return json
            }
        } catch {
            return nil
        }
        return readJSON(home.appendingPathComponent(".claude/.credentials.json"))
    }

    // MARK: - IO helpers

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func ensureParent(_ url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Back up the existing native file once, then write the new JSON atomically.
    /// These files hold OAuth tokens, so keep them owner-only (0600).
    private func backupThenWrite(json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try backupThenWrite(data: data, to: url)
    }

    private func backupThenWrite(data: Data, to url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("viberouter-bak")
            if !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.copyItem(at: url, to: backup)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        try data.write(to: url, options: .atomic)
        // atomic write replaces the file, resetting perms to the umask default (often 0644);
        // restore owner-only so tokens aren't world/group readable.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func expiryMillis(from src: [String: Any]) -> Int? {
        if let expiresIn = src["expires_in"] as? Int, expiresIn > 0 {
            return Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
        }
        if let expired = nonEmpty(src["expired"]) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: expired) ?? {
                let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: expired)
            }() {
                return Int(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    enum SwitchError: LocalizedError {
        case missingToken(String)
        case resolveFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingToken(let name):
                return "stored account is missing \(name)"
            case .resolveFailed(let message):
                return message
            }
        }
    }

    // MARK: - JWT helpers (OpenAI)

    static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func openAIAccountID(from claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            if let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { return id }
            if let id = auth["account_id"] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    static func openAIEmail(from claims: [String: Any]?) -> String? {
        guard let claims else { return nil }
        if let email = claims["email"] as? String, !email.isEmpty { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty
        {
            return email
        }
        return nil
    }

    static func openAIPlan(from claims: [String: Any]?) -> String? {
        guard let claims,
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty
        else { return nil }
        return plan
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
