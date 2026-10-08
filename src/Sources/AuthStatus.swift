import Foundation

enum ServiceType: String, CaseIterable {
    case claude
    case codex
    case copilot = "github-copilot"
    case gemini
    case kimi
    case qwen
    case antigravity
    case kiro
    case grok = "xai"
    case zai
    /// CLIProxy OAuth providers also managed by Cockpit Tools
    case cursor
    case codebuddy
    case codebuddyCN = "codebuddy-cn"
    case gitlab
    case kilo
    /// Cockpit Tools desktop coverage — isolated instances + switch, quota when APIs exist.
    case windsurf
    case qoder
    case trae
    case zed
    /// OpenCode Zen "Go" subscription. Stored as an `openai-compat` auth file
    /// (`provider: opencode-go`), not an OAuth seat, but it has real quota
    /// windows so it gets a usage card like any other provider.
    case opencodeGo = "opencode-go"

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .copilot: return "GitHub Copilot"
        case .gemini: return "Gemini"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .antigravity: return "Antigravity"
        case .kiro: return "Kiro"
        case .grok: return "Grok"
        case .zai: return "Z.AI GLM"
        case .cursor: return "Cursor"
        case .codebuddy: return "CodeBuddy"
        case .codebuddyCN: return "CodeBuddy CN"
        case .gitlab: return "GitLab Duo"
        case .kilo: return "Kilo AI"
        case .windsurf: return "Windsurf"
        case .qoder: return "Qoder"
        case .trae: return "Trae"
        case .zed: return "Zed"
        case .opencodeGo: return ProviderCatalog.openCodeGoDisplayName
        }
    }
}

/// Represents a single authenticated account
struct AuthAccount: Identifiable, Equatable {
    let id: String  // filename
    let email: String?
    let login: String?  // for Copilot
    let type: ServiceType
    let expired: Date?
    let filePath: URL
    let isDisabled: Bool
    /// Subscription / plan label when known (e.g. "ChatGPT Go", "ChatGPT Team").
    let planLabel: String?

    init(
        id: String,
        email: String?,
        login: String?,
        type: ServiceType,
        expired: Date?,
        filePath: URL,
        isDisabled: Bool,
        planLabel: String? = nil
    ) {
        self.id = id
        self.email = email
        self.login = login
        self.type = type
        self.expired = expired
        self.filePath = filePath
        self.isDisabled = isDisabled
        self.planLabel = planLabel
    }
    
    var isExpired: Bool {
        guard let expired = expired else { return false }
        return expired < Date()
    }
    
    var displayName: String {
        let base: String
        if let email = email, !email.isEmpty {
            base = email
        } else if let login = login, !login.isEmpty {
            base = login
        } else {
            base = id
        }
        if let planLabel, !planLabel.isEmpty {
            return "\(base) · \(planLabel)"
        }
        return base
    }

    /// Identity without plan suffix (for matching imports / emails).
    var baseDisplayName: String {
        if let email = email, !email.isEmpty { return email }
        if let login = login, !login.isEmpty { return login }
        return id
    }
    
    static func == (lhs: AuthAccount, rhs: AuthAccount) -> Bool {
        lhs.id == rhs.id
            && lhs.isDisabled == rhs.isDisabled
            && lhs.planLabel == rhs.planLabel
            && lhs.email == rhs.email
    }
}

/// Tracks all accounts for a service type
struct ServiceAccounts: Equatable {
    var type: ServiceType
    var accounts: [AuthAccount] = []
    
    var hasAccounts: Bool { !accounts.isEmpty }
    var activeCount: Int { accounts.filter { !$0.isExpired }.count }
    var expiredCount: Int { accounts.filter { $0.isExpired }.count }
}

class AuthManager: ObservableObject {
    @Published var serviceAccounts: [ServiceType: ServiceAccounts] = [:]
    
    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [withFractional, standard]
    }()
    
    init() {
        // Initialize empty accounts for all service types
        for type in ServiceType.allCases {
            serviceAccounts[type] = ServiceAccounts(type: type)
        }
    }
    
    func accounts(for type: ServiceType) -> [AuthAccount] {
        serviceAccounts[type]?.accounts ?? []
    }
    
    func hasAccounts(for type: ServiceType) -> Bool {
        serviceAccounts[type]?.hasAccounts ?? false
    }
    
    func checkAuthStatus() {
        let scanned = scanAuthDirectory()
        applyAccounts(scanned)
    }

    /// Maps an auth file's `type` to a ServiceType. Custom openai-compatibility
    /// credentials share `type: "openai-compat"`, so they are disambiguated by
    /// their `provider` field — OpenCode Go is the one with real quota windows.
    static func serviceType(forAuthType type: String, raw: [String: Any]) -> ServiceType? {
        let normalized = type.lowercased()
        if normalized == CustomProviderCredentialStore.authType {
            let provider = (raw["provider"] as? String)?.lowercased()
            return provider == ProviderCatalog.openCodeGoProviderName ? .opencodeGo : nil
        }
        return ServiceType(rawValue: normalized)
    }

    private func scanAuthDirectory() -> [ServiceType: [AuthAccount]] {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")

        // NOTE: Do NOT materialize/write seat files here. Writing under ~/.cli-proxy-api trips the
        // FSEvent monitor → authDirectoryChanged → checkAuthStatus → write again (quota thrash).
        // Seat normalization only runs on explicit switch/import.

        var newAccounts: [ServiceType: [AuthAccount]] = [:]
        for type in ServiceType.allCases {
            newAccounts[type] = []
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: authDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            NSLog("[AuthStatus] Scanning %d files in auth directory", files.count)
            let nativeClaude = NativeUsageFetcher.readClaudeAppPayload()

            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = raw["type"] as? String,
                      let serviceType = Self.serviceType(forAuthType: type, raw: raw)
                else {
                    continue
                }
                let json = TokenRefreshService.flattenedAuth(raw)

                let email = json["email"] as? String
                let login = json["login"] as? String
                    ?? json["username"] as? String
                    ?? (serviceType == .opencodeGo ? json["label"] as? String : nil)
                let isDisabled = json["disabled"] as? Bool ?? false
                let planLabel = Self.extractPlanLabel(from: json, serviceType: serviceType)

                // IMPORTANT: `expired` / `expires_at` in auth files is usually the short-lived
                // *access token* expiry (~1h). CLIProxy refreshes via refresh_token automatically.
                // Only treat the account as needing re-auth when the session cannot be refreshed.
                let expiredDate = Self.sessionExpiryDate(from: json, serviceType: serviceType, nativeClaude: nativeClaude)

                let account = AuthAccount(
                    id: file.lastPathComponent,
                    email: email,
                    login: login,
                    type: serviceType,
                    expired: expiredDate,
                    filePath: file,
                    isDisabled: isDisabled,
                    planLabel: planLabel
                )

                newAccounts[serviceType]?.append(account)
                NSLog("[AuthStatus] Found %@ auth: %@", serviceType.displayName, account.displayName)
            }
        } catch {
            NSLog("[AuthStatus] Error checking auth status: %@", error.localizedDescription)
        }

        // Collapse re-logins / duplicate auth files that share the same identity.
        for type in ServiceType.allCases {
            let raw = newAccounts[type] ?? []
            let deduped = Self.deduplicateAccounts(raw)
            if deduped.count != raw.count {
                NSLog(
                    "[AuthStatus] Deduped %@ accounts: %d → %d",
                    type.displayName,
                    raw.count,
                    deduped.count
                )
            }
            newAccounts[type] = deduped
        }

        return newAccounts
    }

    /// One row per identity per provider.
    /// Identity includes the provider, login, scope, and token lineage or full API key.
    /// Prefer: enabled > session still usable > newer mtime > stable id.
    private static func deduplicateAccounts(_ accounts: [AuthAccount]) -> [AuthAccount] {
        guard accounts.count > 1 else { return accounts }

        var bestByKey: [String: AuthAccount] = [:]
        var order: [String] = []

        for account in accounts {
            let key = identityKey(for: account)
            if let existing = bestByKey[key] {
                if prefers(account, over: existing) {
                    bestByKey[key] = account
                }
            } else {
                bestByKey[key] = account
                order.append(key)
            }
        }

        return order.compactMap { bestByKey[$0] }
    }

    /// Stable identity used only for UI/list dedupe (does not delete files on disk).
    /// Shared rules keep workspaces, anonymous sessions, and API keys distinct.
    static func identityKey(for account: AuthAccount) -> String {
        guard let payload = NativeUsageFetcher.readAuthPayload(at: account.filePath),
              AccountCredentialIdentity.isConsistent(payload) else { return "file:" + account.id }
        return AccountCredentialIdentity.key(payload)
    }

    private static func prefers(_ candidate: AuthAccount, over existing: AuthAccount) -> Bool {
        // Enabled beats disabled.
        if candidate.isDisabled != existing.isDisabled {
            return !candidate.isDisabled
        }
        // Usable session beats expired.
        if candidate.isExpired != existing.isExpired {
            return !candidate.isExpired
        }
        // Prefer JWT-fresher access tokens (real re-login) over older duplicates.
        if candidate.type == .codex {
            let cExp = codexAccessExpiry(at: candidate.filePath) ?? .distantPast
            let eExp = codexAccessExpiry(at: existing.filePath) ?? .distantPast
            if cExp != eExp {
                return cExp > eExp
            }
        }
        // Prefer canonical filenames over seat clones / oauth noise.
        let cCanon = codexFilenamePreference(candidate.id)
        let eCanon = codexFilenamePreference(existing.id)
        if cCanon != eCanon {
            return cCanon > eCanon
        }
        // Newer auth file wins (re-login).
        let cMtime = (try? candidate.filePath.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let eMtime = (try? existing.filePath.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if cMtime != eMtime {
            return cMtime > eMtime
        }
        // Prefer a row that already has email/login populated.
        let cScore = (candidate.email?.isEmpty == false ? 2 : 0) + (candidate.login?.isEmpty == false ? 1 : 0)
        let eScore = (existing.email?.isEmpty == false ? 2 : 0) + (existing.login?.isEmpty == false ? 1 : 0)
        if cScore != eScore {
            return cScore > eScore
        }
        return candidate.id < existing.id
    }

    /// Higher = prefer for UI when multiple files share a seat.
    private static func codexFilenamePreference(_ filename: String) -> Int {
        let name = filename.lowercased()
        if name.hasPrefix("codex-seat-") { return 1 }
        if name.contains("-team.json") || name.contains("-go.json") { return 2 }
        // codex-email@host.json style (no uuid prefix)
        if name.hasPrefix("codex-"), name.contains("@") { return 3 }
        return 0
    }

    private static func codexAccessExpiry(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { return nil }
        return CodexWorkspaceCredentials.accessTokenExpiry(access)
    }

    private func applyAccounts(_ newAccounts: [ServiceType: [AuthAccount]]) {
        let update = {
            for type in ServiceType.allCases {
                self.serviceAccounts[type] = ServiceAccounts(
                    type: type,
                    accounts: newAccounts[type] ?? []
                )
            }
        }

        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
    
    /// Toggle the disabled state of a specific account's auth file
    func toggleAccountDisabled(_ account: AuthAccount) -> Bool {
        do {
            let data = try Data(contentsOf: account.filePath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[AuthStatus] Failed to parse auth file as JSON: %@", account.filePath.path)
                return false
            }
            let currentlyDisabled = json["disabled"] as? Bool ?? false
            if !currentlyDisabled {
                let enabledCount = serviceAccounts[account.type]?.accounts.filter { !$0.isDisabled }.count ?? 0
                guard enabledCount > 1 else {
                    NSLog("[AuthStatus] Refusing to disable last enabled account for %@", account.type.rawValue)
                    return false
                }
            }
            json["disabled"] = !currentlyDisabled
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try updatedData.write(to: account.filePath, options: .atomic)
            NSLog("[AuthStatus] Toggled disabled=%d for: %@", !currentlyDisabled, account.filePath.path)
            checkAuthStatus()
            return true
        } catch {
            NSLog("[AuthStatus] Failed to toggle disabled state: %@", error.localizedDescription)
            return false
        }
    }
    
    /// Delete an account completely: every file for that seat + tombstone so materialize cannot revive it.
    func deleteAccount(_ account: AuthAccount) -> Bool {
        let seatKeyBefore = AuthAccountLifecycle.seatKey(for: account)
        let result = AuthAccountLifecycle.deleteAccountCompletely(account)
        if result.deleted.isEmpty {
            NSLog("[AuthStatus] Failed to delete any files for %@", account.displayName)
            checkAuthStatus()
            return false
        }
        if !result.failed.isEmpty {
            NSLog(
                "[AuthStatus] Partial delete for %@: deleted=%d failed=%d",
                account.displayName,
                result.deleted.count,
                result.failed.count
            )
        } else {
            NSLog(
                "[AuthStatus] Deleted %d auth file(s) for %@",
                result.deleted.count,
                account.displayName
            )
        }
        // Refresh — tombstone prevents resurrection from Cockpit/siblings.
        checkAuthStatus()
        if let key = seatKeyBefore {
            let stillThere = accounts(for: account.type).contains {
                AuthAccountLifecycle.seatKey(for: $0) == key
            }
            if stillThere {
                NSLog("[AuthStatus] Seat still listed after delete: %@", key)
                return false
            }
        } else if accounts(for: account.type).contains(where: { $0.id == account.id }) {
            NSLog("[AuthStatus] Account file still listed after delete: %@", account.id)
            return false
        }
        // Do not post authDirectoryChanged here — the FSEvent monitor already sees the delete
        // and posting again caused double refresh storms after multi-file seat deletion.
        return true
    }

    /// Returns a date only when the *session* is truly unusable (needs re-login).
    /// Access-token timestamps alone do not count if a refresh token is present.
    static func sessionExpiryDate(from json: [String: Any], serviceType: ServiceType, nativeClaude: [String: Any]? = nil) -> Date? {
        // API-key providers never expire from access-token clocks.
        if serviceType == .zai || serviceType == .opencodeGo {
            return nil
        }

        let json = TokenRefreshService.flattenedAuth(json)
        // Imported Claude files contain only an access token. Its expiry is not
        // a logout while the matching native CLI still owns a refreshable session.
        if serviceType == .claude, let nativeClaude,
           AccountCredentialIdentity.sameAccount(json, nativeClaude),
           TokenRefreshService.refreshToken(from: nativeClaude) != nil {
            return nil
        }
        let refreshToken = nonEmptyString(json["refresh_token"])
            ?? nonEmptyString(json["refreshToken"])
            ?? nonEmptyString(json["refresh"])

        // A refresh token keeps the session alive. OpenAI refresh tokens are JWTs whose
        // `exp` often matches the access token (~10d) — that is NOT session death.
        // Keep-alive / usage-fetch refresh owns rotation; only a failed refresh is a re-login.
        if refreshToken != nil {
            return nil
        }

        // No refresh token: session dies with the access token (or stored expiry).
        if let access = nonEmptyString(json["access_token"])
            ?? nonEmptyString(json["accessToken"])
            ?? nonEmptyString(json["key"]),
           let accessExp = jwtExpiry(from: access)
        {
            return accessExp
        }

        return parseDateString(json["expired"] as? String)
            ?? parseDateString(json["expires_at"] as? String)
            ?? parseDateString(json["expiresAt"] as? String)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDateString(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        // Some files use "yyyy-MM-dd'T'HH:mm:ssZ" without colon in offset, already covered by ISO8601.
        // Fallback: epoch seconds / millis encoded as string.
        if let epoch = Double(value) {
            if epoch > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: epoch / 1000)
            }
            if epoch > 1_000_000_000 {
                return Date(timeIntervalSince1970: epoch)
            }
        }
        return nil
    }

    private static func jwtExpiry(from token: String) -> Date? {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let exp = json["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = json["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        if let exp = json["exp"] as? String, let value = Double(exp) {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }

    /// Best-effort plan label from stored auth JSON / JWT (no network).
    private static func extractPlanLabel(from json: [String: Any], serviceType: ServiceType) -> String? {
        switch serviceType {
        case .codex:
            if let plan = json["plan_type"] as? String, !plan.isEmpty {
                return ChatGPTPlanFormatter.displayName(for: ChatGPTPlanFormatter.normalizePlanType(plan))
            }
            let token = (json["access_token"] as? String) ?? (json["id_token"] as? String)
            if let plan = planTypeFromOpenAIJWT(token) {
                // JWT alone often says "go" for Plus/Enterprise seats — still show it,
                // but live usage fetch will upgrade from memberships when available.
                return ChatGPTPlanFormatter.displayName(for: ChatGPTPlanFormatter.normalizePlanType(plan))
            }
            return nil
        case .copilot:
            if let plan = json["plan_type"] as? String ?? json["copilot_plan"] as? String {
                return plan
            }
            return nil
        case .cursor:
            if let plan = json["membership_type"] as? String ?? json["plan_type"] as? String,
               !plan.isEmpty
            {
                switch plan.lowercased() {
                case "free": return "Cursor Free"
                case "pro", "individual": return "Cursor Pro"
                case "pro_plus", "pro-plus", "proplus": return "Cursor Pro+"
                case "business", "team": return "Cursor Business"
                case "enterprise": return "Cursor Enterprise"
                case "ultra": return "Cursor Ultra"
                default: return "Cursor \(plan.capitalized)"
                }
            }
            return nil
        case .antigravity, .gemini:
            if let plan = json["plan_label"] as? String ?? json["plan_type"] as? String,
               !plan.isEmpty
            {
                return NativeUsageFetcher.prettyCloudCodeTier(id: json["plan_type"] as? String, name: plan)
            }
            return nil
        default:
            if let plan = json["plan_type"] as? String, !plan.isEmpty {
                return plan
            }
            return nil
        }
    }

    private static func planTypeFromOpenAIJWT(_ token: String?) -> String? {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String,
           !plan.isEmpty
        {
            return plan
        }
        if let plan = json["chatgpt_plan_type"] as? String, !plan.isEmpty {
            return plan
        }
        return nil
    }
}
