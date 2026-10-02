import Foundation

struct DiscoveredConfiguredAccount: Identifiable, Equatable {
    let id: String
    let serviceType: ServiceType
    let displayName: String
    let sourceAppName: String
    let importKind: ConfiguredAccountImportKind
    let customProviderID: String?

    init(
        id: String,
        serviceType: ServiceType,
        displayName: String,
        sourceAppName: String,
        importKind: ConfiguredAccountImportKind,
        customProviderID: String? = nil
    ) {
        self.id = id
        self.serviceType = serviceType
        self.displayName = displayName
        self.sourceAppName = sourceAppName
        self.importKind = importKind
        self.customProviderID = customProviderID
    }
}

enum ConfiguredAccountImportKind: Equatable {
    case codexApp
    case codexOpenCode
    case claudeCode
    case geminiCLI
    case copilotApp
    case grokCLI
    case grokOpenCode
    case antigravityCockpit(email: String)
    case kiroIDE
    case cursorApp
    case zaiAPIKey(String)
    case opencodeGo(apiKey: String)
}

enum ConfiguredAccountDiscovery {
    static func discover(for serviceType: ServiceType) -> [DiscoveredConfiguredAccount] {
        switch serviceType {
        case .codex: return discoverCodex()
        case .claude: return discoverClaude()
        case .gemini: return discoverGemini()
        case .copilot: return discoverCopilot()
        case .antigravity: return discoverAntigravity()
        case .grok: return discoverGrok()
        case .kiro: return discoverKiro()
        case .zai: return discoverZai()
        case .kimi: return discoverKimi()
        case .qwen: return discoverQwen()
        case .cursor: return discoverCursor()
        case .codebuddy, .codebuddyCN, .gitlab, .kilo, .windsurf, .qoder, .trae, .zed:
            // OAuth / paste-JSON onboarding (no stable local import paths yet).
            return []
        case .opencodeGo:
            // Discovered as a custom openai-compatibility provider instead —
            // see discoverOpenCodeCustomProviders().
            return []
        }
    }

    static func discoverAll() -> [ServiceType: [DiscoveredConfiguredAccount]] {
        var result: [ServiceType: [DiscoveredConfiguredAccount]] = [:]
        for type in ServiceType.allCases {
            let accounts = discover(for: type)
            if !accounts.isEmpty {
                result[type] = accounts
            }
        }
        return result
    }

    static func discoverAllImportable(
        connectedAccounts: (ServiceType) -> [AuthAccount],
        zaiAPIKeys: [String],
        customCredentials: [String: [CustomProviderCredential]]
    ) -> [DiscoveredConfiguredAccount] {
        var seenIDs: Set<String> = []
        var accounts: [DiscoveredConfiguredAccount] = []

        for type in ServiceType.allCases {
            for account in discover(for: type) {
                guard seenIDs.insert(account.id).inserted else { continue }
                let existing = connectedAccounts(account.serviceType)
                guard !isAlreadyConnected(
                    account,
                    existingAccounts: existing,
                    zaiAPIKeys: zaiAPIKeys,
                    customCredentials: customCredentials
                ) else { continue }
                accounts.append(account)
            }
        }

        // Custom openai-compatibility providers (e.g. OpenCode Go) are not ServiceTypes.
        for account in discoverOpenCodeCustomProviders() {
            guard seenIDs.insert(account.id).inserted else { continue }
            guard !isAlreadyConnected(
                account,
                existingAccounts: [],
                zaiAPIKeys: zaiAPIKeys,
                customCredentials: customCredentials
            ) else { continue }
            accounts.append(account)
        }

        return accounts.sorted {
            if $0.sourceAppName == $1.sourceAppName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.sourceAppName.localizedCaseInsensitiveCompare($1.sourceAppName) == .orderedAscending
        }
    }

    static func isAlreadyConnected(
        _ discovered: DiscoveredConfiguredAccount,
        existingAccounts: [AuthAccount],
        zaiAPIKeys: [String] = [],
        customCredentials: [String: [CustomProviderCredential]] = [:],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        switch discovered.importKind {
        case let .zaiAPIKey(apiKey):
            return zaiAPIKeys.contains(apiKey)
        case let .opencodeGo(apiKey):
            let stored = customCredentials[ProviderCatalog.openCodeGoProviderName] ?? []
            return stored.contains { $0.apiKey == apiKey && !$0.isDisabled }
        case .kiroIDE:
            let cache = ConfiguredAccountImporter.kiroIDETokenRelativePaths.lazy
                .compactMap { NativeUsageFetcher.readAuthPayload(at: home.appendingPathComponent($0)) }.first
            guard let cache else { return false }
            return existingAccounts.contains { account in
                guard let stored = NativeUsageFetcher.readAuthPayload(at: account.filePath) else { return false }
                return KiroAccountIdentity.sameAccount(stored, cache)
            }
        case .codexApp, .codexOpenCode:
            let local: [String: Any]?
            if discovered.importKind == .codexApp {
                local = NativeUsageFetcher.readCodexAppPayload(at: home.appendingPathComponent(".codex/auth.json"))
            } else {
                let entry = readOpenCodeAuthPayload()?["openai"] as? [String: Any]
                var normalized = entry ?? [:]
                normalized["access_token"] = entry?["access"] ?? entry?["access_token"]
                normalized["account_id"] = entry?["accountId"] ?? entry?["account_id"]
                local = entry == nil ? nil : normalized
            }
            guard let local else { return false }
            return existingAccounts.contains { account in
                guard let stored = NativeUsageFetcher.readAuthPayload(at: account.filePath) else { return false }
                return TokenRefreshService.sameCodexSeat(stored, as: local)
            }
        case .copilotApp:
            guard discovered.id.hasPrefix("copilot-") else { return false }
            let identity = String(discovered.id.dropFirst("copilot-".count))
            return existingAccounts.contains { account in
                guard let stored = NativeUsageFetcher.readAuthPayload(at: account.filePath) else { return false }
                return AccountCredentialIdentity.key(stored) == identity
            }
        default:
            break
        }

        let normalized = discovered.displayName.lowercased()
        guard normalized.contains("@") else { return false }
        let identity: [String: Any] = ["type": discovered.serviceType.rawValue, "email": normalized]
        return existingAccounts.contains { account in
            guard let stored = NativeUsageFetcher.readAuthPayload(at: account.filePath) else { return false }
            return AccountCredentialIdentity.sameAccount(stored, identity)
        }
    }

    // MARK: - Codex

    private static func discoverCodex() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seen: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        let codexAuthCandidates = [
            home.appendingPathComponent(".codex/auth.json"),
            home.appendingPathComponent(".config/codex/auth.json"),
        ]
        for authURL in codexAuthCandidates {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: authURL),
                  let tokens = payload["tokens"] as? [String: Any],
                  tokens["access_token"] != nil
            else { continue }

            let email = JWTEmailExtractor.email(from: tokens["access_token"] as? String)
                ?? JWTEmailExtractor.email(from: tokens["id_token"] as? String)
                ?? "Codex account"
            let seat = CodexWorkspaceCredentials.chatgptAccountID(from: tokens["access_token"] as? String)
                ?? tokens["account_id"] as? String ?? ""
            let identity = email.lowercased() + "|" + seat
            guard seen.insert(identity).inserted else { continue }
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "codex-app-\(identity)",
                    serviceType: .codex,
                    displayName: email,
                    sourceAppName: "Codex app",
                    importKind: .codexApp
                )
            )
        }

        // OpenCode stores ChatGPT/Codex OAuth under the "openai" key.
        if let openCodeAuth = readOpenCodeAuthPayload(),
           let openai = openCodeAuth["openai"] as? [String: Any],
           let access = stringValue(openai, keys: ["access", "access_token"]),
           !access.isEmpty
        {
            let email = JWTEmailExtractor.email(from: access)
                ?? JWTEmailExtractor.email(from: stringValue(openai, keys: ["id_token", "idToken"]))
                ?? "Codex account"
            let seat = CodexWorkspaceCredentials.chatgptAccountID(from: access)
                ?? stringValue(openai, keys: ["accountId", "account_id"]) ?? ""
            let identity = email.lowercased() + "|" + seat
            if seen.insert(identity).inserted {
                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "codex-opencode-\(identity)",
                        serviceType: .codex,
                        displayName: email,
                        sourceAppName: "OpenCode",
                        importKind: .codexOpenCode
                    )
                )
            }
        }

        return accounts
    }

    // MARK: - Claude

    private static func discoverClaude() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seen: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        let credentialFiles = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".config/claude/.credentials.json"),
            home.appendingPathComponent(".config/claude/credentials.json"),
        ]
        for credentialsURL in credentialFiles {
            guard FileManager.default.fileExists(atPath: credentialsURL.path) else { continue }
            let label = claudeEmailFromCredentialsFile(credentialsURL)
                ?? (claudeCredentialsFileHasToken(credentialsURL) ? "Claude Code account" : nil)
            guard let label, seen.insert(label.lowercased()).inserted else { continue }
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "claude-file-\(label)",
                    serviceType: .claude,
                    displayName: label,
                    sourceAppName: "Claude Code",
                    importKind: .claudeCode
                )
            )
        }

        if let keychainEmail = claudeEmailFromKeychain(), seen.insert(keychainEmail.lowercased()).inserted {
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "claude-keychain-\(keychainEmail)",
                    serviceType: .claude,
                    displayName: keychainEmail,
                    sourceAppName: "Claude Code",
                    importKind: .claudeCode
                )
            )
        } else if accounts.isEmpty, claudeKeychainData() != nil {
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "claude-keychain",
                    serviceType: .claude,
                    displayName: "Claude Code account",
                    sourceAppName: "Claude Code",
                    importKind: .claudeCode
                )
            )
        }

        return accounts
    }

    private static func claudeCredentialsFileHasToken(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return false }
        return oauth["accessToken"] != nil
    }

    // MARK: - Gemini

    private static func discoverGemini() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seen: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        let credsCandidates = [
            home.appendingPathComponent(".gemini/oauth_creds.json"),
            home.appendingPathComponent(".gemini/oauth.json"),
            home.appendingPathComponent(".config/gemini/oauth_creds.json"),
            home.appendingPathComponent(".config/gcloud/application_default_credentials.json"),
        ]
        for credsURL in credsCandidates {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: credsURL),
                  payload["access_token"] != nil
                    || payload["refresh_token"] != nil
                    || payload["token"] != nil
            else { continue }

            let email = JWTEmailExtractor.email(from: payload["id_token"] as? String)
                ?? stringValue(payload, keys: ["email", "client_email"])
                ?? "Gemini account"
            guard seen.insert(email.lowercased()).inserted else { continue }
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "gemini-cli-\(email)",
                    serviceType: .gemini,
                    displayName: email,
                    sourceAppName: "Gemini CLI",
                    importKind: .geminiCLI
                )
            )
        }

        return accounts
    }

    // MARK: - Copilot

    static func discoverCopilot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seenLabels: Set<String> = []

        let candidateFiles = [
            home.appendingPathComponent(".config/github-copilot/oauth.json"),
            home.appendingPathComponent(".config/github-copilot/apps.json"),
            home.appendingPathComponent(".config/github-copilot/hosts.json"),
            home.appendingPathComponent("Library/Application Support/github-copilot/oauth.json"),
        ]

        for file in candidateFiles {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: file) else { continue }
            for entry in copilotEntries(from: payload) {
                guard stringValue(entry, keys: ["accessToken", "access_token", "token"]) != nil
                else { continue }
                let account = entry["account"] as? [String: Any]
                let label = (account?["login"] as? String)
                    ?? (account?["label"] as? String)
                    ?? (entry["login"] as? String)
                    ?? (entry["user"] as? String)
                    ?? (entry["id"] as? String).map { "GitHub \($0)" }
                    ?? "GitHub Copilot account"
                guard let parsed = try? ManualTokenImporter.copilotAccount(entry) else { continue }
                let identity = AccountCredentialIdentity.key(parsed.record)
                guard seenLabels.insert(identity).inserted else { continue }
                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "copilot-\(identity)",
                        serviceType: .copilot,
                        displayName: label,
                        sourceAppName: "GitHub Copilot",
                        importKind: .copilotApp
                    )
                )
            }
        }

        return accounts
    }

    /// Supports oauth.json list format and hosts.json map format.
    private static func copilotEntries(from payload: [String: Any]) -> [[String: Any]] {
        if let entries = payload["https://github.com/login/oauth"] as? [[String: Any]] {
            return entries
        }
        if let entries = payload["github.com"] as? [[String: Any]] {
            return entries
        }
        // hosts.json: { "github.com": { "user": "...", "oauth_token": "..." } }
        var collected: [[String: Any]] = []
        for (host, value) in payload {
            guard host.contains("github"), let entry = value as? [String: Any] else { continue }
            var normalized = entry
            if normalized["accessToken"] == nil {
                if let token = entry["oauth_token"] as? String ?? entry["token"] as? String {
                    normalized["accessToken"] = token
                }
            }
            if normalized["account"] == nil {
                if let user = entry["user"] as? String ?? entry["login"] as? String {
                    normalized["account"] = ["login": user, "label": user]
                }
            }
            collected.append(normalized)
        }
        // Flat single-object file
        if collected.isEmpty,
           stringValue(payload, keys: ["accessToken", "access_token", "oauth_token", "token"]) != nil
        {
            var normalized = payload
            if normalized["accessToken"] == nil {
                normalized["accessToken"] = stringValue(payload, keys: ["access_token", "oauth_token", "token"])
            }
            collected.append(normalized)
        }
        return collected
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

    // MARK: - Antigravity

    private static func discoverAntigravity() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seenEmails: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountDirs = [
            home.appendingPathComponent(".antigravity_cockpit/accounts"),
            home.appendingPathComponent(".antigravity/accounts"),
            home.appendingPathComponent("Library/Application Support/Antigravity/accounts"),
        ]

        for accountsDir in accountDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: accountsDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            for file in files {
                guard file.pathExtension == "json",
                      !file.lastPathComponent.hasSuffix(".bak"),
                      let payload = NativeUsageFetcher.readAuthPayload(at: file)
                else { continue }

                let token = payload["token"] as? [String: Any]
                let hasAccess = token?["access_token"] != nil
                    || payload["access_token"] != nil
                guard hasAccess else { continue }

                let email = (payload["email"] as? String)
                    ?? (token?["email"] as? String)
                    ?? (payload["name"] as? String)
                    ?? file.deletingPathExtension().lastPathComponent
                guard seenEmails.insert(email.lowercased()).inserted else { continue }

                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "antigravity-cockpit-\(email)",
                        serviceType: .antigravity,
                        displayName: email,
                        sourceAppName: "Antigravity",
                        importKind: .antigravityCockpit(email: email)
                    )
                )
            }
        }

        return accounts
    }

    // MARK: - Kimi / Qwen

    private static func discoverKimi() -> [DiscoveredConfiguredAccount] {
        // Kimi uses browser OAuth; no stable local token format for import yet.
        return []
    }

    private static func discoverQwen() -> [DiscoveredConfiguredAccount] {
        // Qwen auth is email-based; no stable local token import path yet.
        return []
    }

    // MARK: - Grok

    private static func discoverGrok() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seenNames: Set<String> = []

        let grokAuthCandidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/grok/auth.json"),
        ]
        for authURL in grokAuthCandidates {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: authURL),
                  let (_, entry) = grokPreferredEntry(in: payload),
                  entry["key"] != nil || entry["access_token"] != nil || entry["access"] != nil
            else { continue }

            let email = (entry["email"] as? String)
                ?? (entry["first_name"] as? String)
                ?? JWTEmailExtractor.email(from: entry["key"] as? String)
                ?? "Grok account"
            let normalized = email.lowercased()
            guard seenNames.insert(normalized).inserted else { continue }
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "grok-cli-\(email)",
                    serviceType: .grok,
                    displayName: email,
                    sourceAppName: "Grok CLI",
                    importKind: .grokCLI
                )
            )
        }

        if let openCodeAuth = readOpenCodeAuthPayload(),
           let xai = openCodeAuth["xai"] as? [String: Any],
           xai["access"] != nil || xai["key"] != nil || xai["access_token"] != nil
        {
            let access = (xai["access"] as? String) ?? (xai["access_token"] as? String)
            let email = JWTEmailExtractor.email(from: access)
                ?? (xai["email"] as? String)
                ?? "Grok account"
            if seenNames.insert(email.lowercased()).inserted {
                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "grok-opencode-\(email)",
                        serviceType: .grok,
                        displayName: email,
                        sourceAppName: "OpenCode",
                        importKind: .grokOpenCode
                    )
                )
            }
        }

        return accounts
    }

    // MARK: - Z.AI

    private static func discoverZai() -> [DiscoveredConfiguredAccount] {
        var accounts: [DiscoveredConfiguredAccount] = []
        var seenKeys: Set<String> = []

        if let openCodeAuth = readOpenCodeAuthPayload() {
            // Match any zai / glm-related OpenCode provider keys (coding-plan, zai, z-ai, …).
            for (providerKey, value) in openCodeAuth {
                let keyLower = providerKey.lowercased()
                guard keyLower.contains("zai") || keyLower.contains("glm") || keyLower == "z.ai"
                else { continue }
                guard let entry = value as? [String: Any],
                      let apiKey = (entry["key"] as? String) ?? (entry["apiKey"] as? String) ?? (entry["api_key"] as? String),
                      !apiKey.isEmpty,
                      seenKeys.insert(apiKey).inserted
                else { continue }

                let label: String
                if keyLower.contains("coding") {
                    label = "Z.AI GLM coding plan"
                } else {
                    label = "Z.AI GLM (\(providerKey))"
                }
                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "zai-opencode-\(providerKey)",
                        serviceType: .zai,
                        displayName: label,
                        sourceAppName: "OpenCode",
                        importKind: .zaiAPIKey(apiKey)
                    )
                )
            }
        }

        // Shell env (process + common user profile exports)
        for (envName, envKey) in discoveredZaiEnvironmentKeys() {
            guard seenKeys.insert(envKey).inserted else { continue }
            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "zai-env-\(envName)",
                    serviceType: .zai,
                    displayName: "Z.AI GLM (\(envName))",
                    sourceAppName: "Environment",
                    importKind: .zaiAPIKey(envKey)
                )
            )
        }

        for configPath in [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/codexbar/config.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codexbar/config.json"),
        ] {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: configPath),
                  let apiKey = zaiAPIKeyFromCodexbarConfig(payload),
                  !apiKey.isEmpty,
                  seenKeys.insert(apiKey).inserted
            else { continue }

            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "zai-codexbar-\(configPath.lastPathComponent)",
                    serviceType: .zai,
                    displayName: "Z.AI GLM (CodexBar)",
                    sourceAppName: "CodexBar",
                    importKind: .zaiAPIKey(apiKey)
                )
            )
        }

        // OpenCode config files sometimes store provider keys outside auth.json
        for configPath in openCodeConfigPaths() {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: configPath) else { continue }
            for apiKey in zaiAPIKeysFromOpenCodeConfig(payload) where seenKeys.insert(apiKey).inserted {
                accounts.append(
                    DiscoveredConfiguredAccount(
                        id: "zai-opencode-config-\(configPath.lastPathComponent)-\(apiKey.prefix(8))",
                        serviceType: .zai,
                        displayName: "Z.AI GLM",
                        sourceAppName: "OpenCode config",
                        importKind: .zaiAPIKey(apiKey)
                    )
                )
            }
        }

        return accounts
    }

    private static func discoveredZaiEnvironmentKeys() -> [(String, String)] {
        var results: [(String, String)] = []
        let env = ProcessInfo.processInfo.environment
        for name in ["Z_AI_API_KEY", "ZAI_API_KEY", "GLM_API_KEY"] {
            if let value = env[name], !value.isEmpty {
                results.append((name, value))
            }
        }
        return results
    }

    private static func openCodeConfigPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".config/opencode/opencode.json"),
            home.appendingPathComponent(".config/opencode/config.json"),
            home.appendingPathComponent(".opencode/config.json"),
            home.appendingPathComponent(".opencode/opencode.json"),
        ]
    }

    private static func zaiAPIKeysFromOpenCodeConfig(_ root: [String: Any]) -> [String] {
        var keys: [String] = []

        func considerProviderEntry(_ entry: [String: Any], providerID: String?) {
            let id = (providerID ?? "").lowercased()
            let looksLikeZai = id.contains("zai") || id.contains("glm") || id == "z.ai"
            guard looksLikeZai else { return }
            if let apiKey = entry["apiKey"] as? String ?? entry["key"] as? String ?? entry["api_key"] as? String,
               !apiKey.isEmpty
            {
                keys.append(apiKey)
            }
        }

        if let provider = root["provider"] as? [String: Any] {
            for (providerID, value) in provider {
                if let entry = value as? [String: Any] {
                    considerProviderEntry(entry, providerID: providerID)
                    if let options = entry["options"] as? [String: Any] {
                        considerProviderEntry(options, providerID: providerID)
                    }
                }
            }
        }

        if let providers = root["providers"] as? [String: Any] {
            for (providerID, value) in providers {
                if let entry = value as? [String: Any] {
                    considerProviderEntry(entry, providerID: providerID)
                }
            }
        }

        if let providers = root["providers"] as? [[String: Any]] {
            for entry in providers {
                let id = (entry["id"] as? String) ?? (entry["name"] as? String)
                considerProviderEntry(entry, providerID: id)
            }
        }

        return keys
    }

    // MARK: - OpenCode custom providers

    static func discoverOpenCodeCustomProviders() -> [DiscoveredConfiguredAccount] {
        guard let openCodeAuth = readOpenCodeAuthPayload() else { return [] }

        var accounts: [DiscoveredConfiguredAccount] = []

        // opencode-go / go subscription key
        for providerKey in [ProviderCatalog.openCodeGoProviderName, "opencode_go", "go"] {
            guard let entry = openCodeAuth[providerKey] as? [String: Any],
                  let apiKey = (entry["key"] as? String)
                    ?? (entry["apiKey"] as? String)
                    ?? (entry["api_key"] as? String),
                  !apiKey.isEmpty
            else { continue }

            accounts.append(
                DiscoveredConfiguredAccount(
                    id: "opencode-go-\(providerKey)",
                    // Placeholder service type for Identifiable plumbing; UI uses customProviderID.
                    serviceType: .zai,
                    displayName: ProviderCatalog.openCodeGoDisplayName,
                    sourceAppName: "OpenCode",
                    importKind: .opencodeGo(apiKey: apiKey),
                    customProviderID: ProviderCatalog.openCodeGoProviderName
                )
            )
            break
        }

        return accounts
    }

    // MARK: - Kiro

    private static func discoverKiro() -> [DiscoveredConfiguredAccount] {
        let tokenPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/kiro-auth-token.json"),
        ]

        guard tokenPaths.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return []
        }

        return [
            DiscoveredConfiguredAccount(
                id: "kiro-ide",
                serviceType: .kiro,
                displayName: "Kiro IDE session",
                sourceAppName: "Kiro IDE",
                importKind: .kiroIDE
            )
        ]
    }

    // MARK: - Cursor

    private static func discoverCursor() -> [DiscoveredConfiguredAccount] {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let email = VscdbStore.readString(dbURL: db, key: "cursorAuth/cachedEmail")
            ?? VscdbStore.readString(dbURL: db, key: "cursor.email"),
              VscdbStore.readString(dbURL: db, key: "cursorAuth/accessToken") != nil
        else { return [] }

        return [
            DiscoveredConfiguredAccount(
                id: "cursor-app-\(email.lowercased())",
                serviceType: .cursor,
                displayName: email,
                sourceAppName: "Cursor app",
                importKind: .cursorApp
            )
        ]
    }

    // MARK: - Claude helpers

    private static func claudeEmailFromCredentialsFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] != nil
        else { return nil }

        if let email = oauth["email"] as? String, !email.isEmpty { return email }
        if let email = JWTEmailExtractor.email(from: oauth["accessToken"] as? String) { return email }
        return readClaudeConfigEmail()
    }

    private static func claudeEmailFromKeychain() -> String? {
        guard let data = claudeKeychainData(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] != nil
        else { return nil }

        if let email = oauth["email"] as? String, !email.isEmpty { return email }
        if let email = JWTEmailExtractor.email(from: oauth["accessToken"] as? String) { return email }
        return readClaudeConfigEmail()
    }

    private static func readClaudeConfigEmail() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURLs = [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude/.claude.json"),
        ]
        for url in configURLs {
            if let data = try? Data(contentsOf: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauthAccount = root["oauthAccount"] as? [String: Any],
               let email = oauthAccount["emailAddress"] as? String,
               !email.isEmpty
            {
                return email
            }
        }
        return nil
    }

    private static func claudeKeychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let string = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return string.data(using: .utf8)
    }

    // MARK: - Shared helpers

    private static func readOpenCodeAuthPayload() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent(".config/opencode/auth.json"),
            home.appendingPathComponent(".opencode/auth.json"),
        ]
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            candidates.insert(URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json"), at: 0)
        }
        for url in candidates {
            if let payload = NativeUsageFetcher.readAuthPayload(at: url) {
                return payload
            }
        }
        return nil
    }

    private static func zaiAPIKeyFromCodexbarConfig(_ root: [String: Any]) -> String? {
        if let providers = root["providers"] as? [[String: Any]] {
            for provider in providers {
                let id = (provider["id"] as? String) ?? (provider["name"] as? String)
                guard id?.lowercased() == "zai" else { continue }
                if let apiKey = provider["apiKey"] as? String, !apiKey.isEmpty { return apiKey }
            }
        }

        if let tokenAccounts = root["tokenAccounts"] as? [String: Any],
           let accounts = tokenAccounts["accounts"] as? [[String: Any]]
        {
            for account in accounts where (account["id"] as? String)?.lowercased() == "zai" || account["label"] != nil {
                if let token = account["token"] as? String, !token.isEmpty { return token }
            }
        }

        return nil
    }

    // MARK: - Grok helpers

    private static func grokPreferredEntry(in root: [String: Any]) -> (String, [String: Any])? {
        let oidcPrefix = "https://auth.x.ai::"
        let legacyScope = "https://accounts.x.ai/sign-in"

        if let match = root.first(where: { $0.key.hasPrefix(oidcPrefix) }),
           let entry = match.value as? [String: Any]
        {
            return (match.key, entry)
        }
        if let entry = root[legacyScope] as? [String: Any] {
            return (legacyScope, entry)
        }
        return root.compactMap { key, value -> (String, [String: Any])? in
            guard let entry = value as? [String: Any], entry["key"] != nil else { return nil }
            return (key, entry)
        }.first
    }
}

enum JWTEmailExtractor {
    static func email(from token: String?) -> String? {
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

        if let email = json["email"] as? String, !email.isEmpty { return email }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty
        {
            return email
        }
        return nil
    }
}
