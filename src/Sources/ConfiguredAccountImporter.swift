import Foundation

enum ConfiguredAccountImportResult {
    case success(message: String)
    case failure(message: String)
}

enum ConfiguredAccountImporter {
    static func importAccount(
        _ account: DiscoveredConfiguredAccount,
        authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
    ) -> ConfiguredAccountImportResult {
        switch account.importKind {
        case .kiroIDE:
            return importKiroIDE(authDirectory: authDirectory)
        case .codexApp:
            return importCodexApp(authDirectory: authDirectory, displayName: account.displayName)
        case .codexOpenCode:
            return importCodexOpenCode(authDirectory: authDirectory, displayName: account.displayName)
        case .claudeCode:
            return importClaudeCode(authDirectory: authDirectory, displayName: account.displayName)
        case .geminiCLI:
            return importGeminiCLI(authDirectory: authDirectory, displayName: account.displayName)
        case .copilotApp:
            return importCopilotApp(authDirectory: authDirectory, displayName: account.displayName,
                                    preferredIdentity: account.id.hasPrefix("copilot-") ? String(account.id.dropFirst("copilot-".count)) : nil)
        case .grokCLI:
            return importGrokCLI(authDirectory: authDirectory, displayName: account.displayName)
        case .grokOpenCode:
            return importGrokOpenCode(authDirectory: authDirectory, displayName: account.displayName)
        case let .antigravityCockpit(email):
            return importAntigravityCockpit(authDirectory: authDirectory, email: email, displayName: account.displayName)
        case .cursorApp:
            return importCursorApp(authDirectory: authDirectory, displayName: account.displayName)
        case let .zaiAPIKey(apiKey):
            return importZaiAPIKey(apiKey: apiKey, authDirectory: authDirectory)
        case .opencodeGo:
            return .failure(message: "OpenCode Go import uses the custom provider credential store")
        }
    }

    static func importZaiAPIKey(
        apiKey: String,
        authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
    ) -> ConfiguredAccountImportResult {
        do {
            let store = ZAIAPIKeyStore(directoryURL: authDirectory)
            let filePath = try store.save(apiKey: apiKey)
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            return .success(message: "Imported Z.AI API key to \(filePath.lastPathComponent)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// Kiro IDE / AWS SSO cache. The bundled proxy has no `-kiro-login` / `-kiro-import`.
    static let kiroIDETokenRelativePaths = [
        ".aws/sso/cache/kiro-auth-token.json",
        ".kiro/kiro-auth-token.json",
    ]

    static func importKiroIDE(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
    ) -> ConfiguredAccountImportResult {
        if let merged = mergeKiroSSOCacheOntoAWSFiles(home: home, authDirectory: authDirectory) {
            return merged
        }
        var lastFailure = "No Kiro IDE session found. Sign into Kiro IDE first, then try again — or paste token JSON."
        for rel in kiroIDETokenRelativePaths {
            let url = home.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path),
                  let cache = NativeUsageFetcher.readAuthPayload(at: url),
                  let data = try? JSONSerialization.data(withJSONObject:
                    kiroCacheWithRegistration(cache, home: home, authDirectory: authDirectory)),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            switch ManualTokenImporter.importPasted(
                text,
                preferredType: .kiro,
                authDirectory: authDirectory,
                overwrite: true
            ) {
            case .success(let message):
                return .success(message: message)
            case .failure(let message):
                lastFailure = message
            }
        }
        return .failure(message: lastFailure)
    }

    /// Overlay a verified account's live SSO tokens, preserving its OIDC registration.
    /// A matching client hash alone cannot distinguish two people using the same IDE.
    static func mergeKiroSSOCacheOntoAWSFiles(
        home: URL,
        authDirectory: URL
    ) -> ConfiguredAccountImportResult? {
        var cache: [String: Any]?
        for rel in kiroIDETokenRelativePaths {
            let url = home.appendingPathComponent(rel)
            if let payload = NativeUsageFetcher.readAuthPayload(at: url) {
                cache = payload
                break
            }
        }
        guard let cache,
              let access = (cache["accessToken"] as? String) ?? (cache["access_token"] as? String),
              !access.isEmpty
        else { return nil }
        let hash = ((cache["clientIdHash"] as? String) ?? (cache["client_id_hash"] as? String) ?? "")
            .lowercased()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard var existing = NativeUsageFetcher.readAuthPayload(at: file),
                  (existing["type"] as? String)?.lowercased() == "kiro"
            else { continue }
            let existingHash = ((existing["client_id_hash"] as? String) ?? "").lowercased()
            let existingID = (existing["client_id"] as? String).map(KiroAWSAuth.clientIDHash) ?? ""
            let hashMatch = !hash.isEmpty && (hash == existingHash || hash == existingID.lowercased())
            guard hashMatch, KiroAccountIdentity.sameAccount(existing, cache) else { continue }
            let cacheExp = (cache["expiresAt"] as? String) ?? (cache["expires_at"] as? String)
            let fileExp = (existing["expires_at"] as? String) ?? (existing["expired"] as? String)
            if let cacheExp, let fileExp, cacheExp <= fileExp {
                return .success(message: "This Kiro account is already imported (\(file.lastPathComponent)).")
            }
            existing["access_token"] = access
            existing["accessToken"] = access
            if let refresh = (cache["refreshToken"] as? String) ?? (cache["refresh_token"] as? String) {
                existing["refresh_token"] = refresh
                existing["refreshToken"] = refresh
            }
            if let exp = (cache["expiresAt"] as? String) ?? (cache["expires_at"] as? String) {
                existing["expired"] = exp
                existing["expires_at"] = exp
            }
            existing["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(
                withJSONObject: existing,
                options: [.prettyPrinted, .sortedKeys]
            ) else { continue }
            do {
                try data.write(to: file, options: [.atomic])
            } catch {
                return .failure(message: error.localizedDescription)
            }
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            return .success(message: "Updated Kiro AWS account from the local IDE session (\(file.lastPathComponent)).")
        }
        return nil
    }

    /// Reuse client registration metadata without copying the previous login's identity or tokens.
    private static func kiroCacheWithRegistration(
        _ cache: [String: Any], home: URL, authDirectory: URL
    ) -> [String: Any] {
        guard let hash = ((cache["clientIdHash"] as? String) ?? (cache["client_id_hash"] as? String)),
              !hash.isEmpty, hash.allSatisfy({ $0.isHexDigit })
        else { return cache }
        var enriched = cache
        var registrations: [[String: Any]] = []
        if let registration = NativeUsageFetcher.readAuthPayload(
            at: home.appendingPathComponent(".aws/sso/cache/\(hash).json")
        ) { registrations.append(registration) }
        let files = (try? FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let existing = NativeUsageFetcher.readAuthPayload(at: file),
                  (existing["type"] as? String)?.lowercased() == "kiro"
            else { continue }
            let existingHash = existing["client_id_hash"] as? String
                ?? (existing["client_id"] as? String).map(KiroAWSAuth.clientIDHash)
            if existingHash?.caseInsensitiveCompare(hash) == .orderedSame { registrations.append(existing) }
        }
        for registration in registrations {
            for (canonical, camel) in [("client_id", "clientId"), ("client_secret", "clientSecret")] {
                if enriched[canonical] == nil, enriched[camel] == nil {
                    enriched[canonical] = registration[canonical] ?? registration[camel]
                }
            }
        }
        return enriched
    }

    static func importFromDesktopApp(for command: AuthCommand) -> ConfiguredAccountImportResult {
        let authDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
        switch command {
        case .kiroImport:
            return importKiroIDE(authDirectory: authDirectory)
        case .cursorLogin:
            return importCursorApp(authDirectory: authDirectory, displayName: "Cursor")
        case .copilotLogin:
            return importCopilotApp(authDirectory: authDirectory, displayName: "")
        default:
            return .failure(message: command.missingOAuthMessage)
        }
    }

    // MARK: - Codex

    private static func importCodexApp(authDirectory: URL, displayName: String) -> ConfiguredAccountImportResult {
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let payload = NativeUsageFetcher.readAuthPayload(at: source),
              let tokens = payload["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String
        else {
            return .failure(message: "Could not read Codex app credentials from ~/.codex/auth.json")
        }

        let email = JWTEmailExtractor.email(from: accessToken)
            ?? JWTEmailExtractor.email(from: tokens["id_token"] as? String)
            ?? ""
        let now = Date()
        let expired = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))

        var record: [String: Any] = [
            "type": "codex",
            "email": email,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "account_id": CodexWorkspaceCredentials.chatgptAccountID(from: accessToken)
                ?? (tokens["account_id"] as? String) ?? "",
            "id_token": tokens["id_token"] as? String ?? "",
            "expires_in": 3600,
            "expired": expired,
            "last_refresh": expired,
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]

        if let lastRefresh = payload["last_refresh"] as? String {
            record["last_refresh"] = lastRefresh
        }

        return writeAuthRecord(
            record,
            filename: ManualTokenImporter.codexFilename(record),
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from Codex app"
        )
    }

    // MARK: - Codex (OpenCode)

    private static func importCodexOpenCode(
        authDirectory: URL,
        displayName: String
    ) -> ConfiguredAccountImportResult {
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        let xdgSource = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("opencode/auth.json") }
        let candidates = [
            source,
            xdgSource,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/auth.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/auth.json"),
        ].compactMap { $0 }

        var openai: [String: Any]?
        for candidate in candidates {
            if let payload = NativeUsageFetcher.readAuthPayload(at: candidate),
               let entry = payload["openai"] as? [String: Any]
            {
                openai = entry
                break
            }
        }

        guard let openai,
              let accessToken = (openai["access"] as? String) ?? (openai["access_token"] as? String),
              !accessToken.isEmpty
        else {
            return .failure(message: "Could not read Codex/OpenAI credentials from OpenCode auth.json")
        }

        let refreshToken = (openai["refresh"] as? String) ?? (openai["refresh_token"] as? String) ?? ""
        let email = JWTEmailExtractor.email(from: accessToken)
            ?? JWTEmailExtractor.email(from: openai["id_token"] as? String)
            ?? ""
        let accountID = CodexWorkspaceCredentials.chatgptAccountID(from: accessToken)
            ?? (openai["accountId"] as? String)
            ?? (openai["account_id"] as? String)
            ?? ""
        let now = Date()
        let expired = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))

        let record: [String: Any] = [
            "type": "codex",
            "email": email,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "account_id": accountID,
            "id_token": openai["id_token"] as? String ?? "",
            "expires_in": 3600,
            "expired": expired,
            "last_refresh": ISO8601DateFormatter().string(from: now),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]

        return writeAuthRecord(
            record,
            filename: ManualTokenImporter.codexFilename(record),
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from OpenCode"
        )
    }

    // MARK: - Claude

    private static func importClaudeCode(authDirectory: URL, displayName: String) -> ConfiguredAccountImportResult {
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")

        let data: Data?
        if let fileData = try? Data(contentsOf: credentialsURL),
           let root = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
           root["claudeAiOauth"] != nil
        {
            data = fileData
        } else if let keychainData = claudeKeychainString().data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: keychainData) as? [String: Any],
                  root["claudeAiOauth"] != nil
        {
            data = keychainData
        } else {
            return .failure(message: "Could not read Claude Code credentials. Sign into Claude Code first.")
        }

        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else {
            return .failure(message: "Claude Code credentials are missing an access token")
        }

        let expiresAtMs = oauth["expiresAt"] as? Double
        let expiresAt = expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        let email = AccountCredentialIdentity.email(oauth,
            matchingNative: AccountCredentialIdentity.email(oauth) == nil ? NativeUsageFetcher.readClaudeAppPayload() : nil) ?? ""

        let now = Date()
        let expired = expiresAt.map { ISO8601DateFormatter().string(from: $0) }
            ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))

        // Keep the rotating refresh token in Claude Code's keychain only.
        // Importing it into ~/.cli-proxy-api makes VibeRouter a second OAuth
        // client on the same family; the next refresh logs `claude` out.
        let record: [String: Any] = [
            "type": "claude",
            "email": email,
            "access_token": accessToken,
            "expired": expired,
            "last_refresh": ISO8601DateFormatter().string(from: now),
        ]

        return writeAuthRecord(
            record,
            filename: "claude-\(sanitizeFilename(email)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from Claude Code"
        )
    }

    // MARK: - Gemini

    private static func importGeminiCLI(authDirectory: URL, displayName: String) -> ConfiguredAccountImportResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources = [
            home.appendingPathComponent(".gemini/oauth_creds.json"),
            home.appendingPathComponent(".gemini/oauth.json"),
            home.appendingPathComponent(".config/gemini/oauth_creds.json"),
            home.appendingPathComponent(".config/gcloud/application_default_credentials.json"),
        ]
        guard let source = sources.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let payload = NativeUsageFetcher.readAuthPayload(at: source)
        else {
            return .failure(message: "Could not read Gemini CLI credentials")
        }

        let email = AccountCredentialIdentity.email(payload) ?? ""
        let projectID = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/projects.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["active"] as? String }
            ?? "default"

        var record = payload
        record["type"] = "gemini"
        record["email"] = email
        record["project_id"] = projectID
        record["auto"] = true
        record["checked"] = true

        let filename: String
        if projectID.isEmpty || projectID == "default" {
            filename = "gemini-\(sanitizeFilename(email))-all.json"
        } else {
            filename = "gemini-\(sanitizeFilename(email))-\(sanitizeFilename(projectID)).json"
        }

        return writeAuthRecord(
            record,
            filename: filename,
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from Gemini CLI"
        )
    }

    // MARK: - Copilot

    static func importCopilotApp(authDirectory: URL, displayName: String, preferredIdentity: String? = nil,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfiguredAccountImportResult {
        let sources = [
            home.appendingPathComponent(".config/github-copilot/oauth.json"),
            home.appendingPathComponent(".config/github-copilot/apps.json"),
            home.appendingPathComponent(".config/github-copilot/hosts.json"),
            home.appendingPathComponent("Library/Application Support/github-copilot/oauth.json"),
        ]

        var entries: [[String: Any]] = []
        for source in sources {
            guard let payload = NativeUsageFetcher.readAuthPayload(at: source) else { continue }
            if let list = payload["https://github.com/login/oauth"] as? [[String: Any]] {
                entries.append(contentsOf: list)
            } else if let list = payload["github.com"] as? [[String: Any]] {
                entries.append(contentsOf: list)
            } else if let host = payload["github.com"] as? [String: Any] {
                var normalized = host
                if normalized["accessToken"] == nil {
                    normalized["accessToken"] = host["oauth_token"] ?? host["token"]
                }
                if normalized["account"] == nil, let user = host["user"] as? String {
                    normalized["account"] = ["login": user, "label": user]
                }
                entries.append(normalized)
            }
        }

        guard !entries.isEmpty else {
            return .failure(message: "Could not read GitHub Copilot credentials")
        }

        let normalizedDisplay = displayName.lowercased()
        let matchedEntry = entries.first(where: { candidate in
            if let preferredIdentity {
                guard let parsed = try? ManualTokenImporter.copilotAccount(candidate) else { return false }
                return AccountCredentialIdentity.key(parsed.record) == preferredIdentity
            }
            let account = candidate["account"] as? [String: Any]
            let label = (account?["label"] as? String)?.lowercased()
            let login = (account?["login"] as? String)?.lowercased()
            return label == normalizedDisplay || login == normalizedDisplay
        })
        guard let entry = preferredIdentity == nil && normalizedDisplay.isEmpty ? entries.first : matchedEntry,
              let accessToken = (entry["accessToken"] as? String)
                ?? (entry["access_token"] as? String)
                ?? (entry["oauth_token"] as? String)
                ?? (entry["token"] as? String),
              !accessToken.isEmpty
        else {
            return .failure(message: "No GitHub Copilot access token found")
        }

        guard let parsed = try? ManualTokenImporter.copilotAccount(entry) else {
            return .failure(message: "Could not read the selected GitHub Copilot login.")
        }
        let record = parsed.record
        let username = parsed.displayName

        return writeAuthRecord(
            record,
            filename: "github-copilot-\(sanitizeFilename(username)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(username) from GitHub Copilot",
            overwrite: true
        )
    }

    // MARK: - Grok

    private static func importGrokCLI(authDirectory: URL, displayName: String) -> ConfiguredAccountImportResult {
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
        guard let payload = NativeUsageFetcher.readAuthPayload(at: source),
              let (_, entry) = grokPreferredEntry(in: payload),
              let accessToken = entry["key"] as? String
        else {
            return .failure(message: "Could not read Grok credentials from ~/.grok/auth.json")
        }

        let email = JWTEmailExtractor.email(from: accessToken) ?? (entry["email"] as? String) ?? ""
        let refreshToken = entry["refresh_token"] as? String ?? ""
        let expiresAt = grokExpiresAt(from: entry)
        let now = Date()

        var record: [String: Any] = [
            "type": "xai",
            "email": email,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_in": 3600,
            "expired": expiresAt.map { ISO8601DateFormatter().string(from: $0) }
                ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)),
            "last_refresh": ISO8601DateFormatter().string(from: now),
            "auth_kind": "oauth",
        ]
        if let clientID = (entry["oidc_client_id"] as? String) ?? (entry["client_id"] as? String),
           !clientID.isEmpty
        {
            record["oidc_client_id"] = clientID
            record["client_id"] = clientID
        }

        return writeAuthRecord(
            record,
            filename: "xai-\(sanitizeFilename(email)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from Grok CLI"
        )
    }

    // MARK: - Grok (OpenCode)

    private static func importGrokOpenCode(
        authDirectory: URL,
        displayName: String
    ) -> ConfiguredAccountImportResult {
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let payload = NativeUsageFetcher.readAuthPayload(at: source),
              let xai = payload["xai"] as? [String: Any],
              let accessToken = xai["access"] as? String,
              !accessToken.isEmpty
        else {
            return .failure(message: "Could not read Grok credentials from OpenCode auth.json")
        }

        let email = JWTEmailExtractor.email(from: accessToken) ?? (xai["email"] as? String) ?? ""
        let refreshToken = xai["refresh"] as? String ?? ""
        let now = Date()
        let expired = grokExpiresAt(from: xai)
            .map { ISO8601DateFormatter().string(from: $0) }
            ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))

        let record: [String: Any] = [
            "type": "xai",
            "email": email,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_in": 3600,
            "expired": expired,
            "last_refresh": ISO8601DateFormatter().string(from: now),
            "auth_kind": "oauth",
        ]

        return writeAuthRecord(
            record,
            filename: "xai-\(sanitizeFilename(email)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from OpenCode"
        )
    }

    // MARK: - Antigravity

    private static func importAntigravityCockpit(
        authDirectory: URL,
        email: String,
        displayName: String
    ) -> ConfiguredAccountImportResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountDirs = [
            home.appendingPathComponent(".antigravity_cockpit/accounts"),
            home.appendingPathComponent(".antigravity/accounts"),
            home.appendingPathComponent("Library/Application Support/Antigravity/accounts"),
        ]

        let normalizedEmail = email.lowercased()
        var matchedPayload: [String: Any]?
        var matchedToken: [String: Any]?

        for accountsDir in accountDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: accountsDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            if let file = files.first(where: { candidate in
                guard candidate.pathExtension == "json",
                      !candidate.lastPathComponent.hasSuffix(".bak"),
                      let payload = NativeUsageFetcher.readAuthPayload(at: candidate)
                else { return false }
                let candidateEmail = (
                    (payload["email"] as? String)
                        ?? ((payload["token"] as? [String: Any])?["email"] as? String)
                        ?? ""
                ).lowercased()
                return candidateEmail == normalizedEmail
            }),
               let payload = NativeUsageFetcher.readAuthPayload(at: file)
            {
                matchedPayload = payload
                matchedToken = payload["token"] as? [String: Any]
                break
            }
        }

        guard let payload = matchedPayload,
              let accessToken = (matchedToken?["access_token"] as? String)
                ?? (payload["access_token"] as? String)
        else {
            return .failure(message: "Could not find Antigravity credentials for \(displayName)")
        }
        let token = matchedToken ?? [:]

        let refreshToken = token["refresh_token"] as? String
            ?? payload["refresh_token"] as? String
            ?? ""
        let expiresIn = token["expires_in"] as? Int ?? payload["expires_in"] as? Int ?? 3600
        let now = Date()
        let expired = (token["expiry_timestamp"] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
            .map { ISO8601DateFormatter().string(from: $0) }
            ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(expiresIn)))

        var record: [String: Any] = [
            "type": "antigravity",
            "email": JWTEmailExtractor.email(from: accessToken) ?? payload["email"] as? String ?? "",
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_in": expiresIn,
            "expired": expired,
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]

        if let projectID = payload["project_id"] as? String, !projectID.isEmpty {
            record["project_id"] = projectID
        }

        let resolvedEmail = record["email"] as? String ?? ""
        return writeAuthRecord(
            record,
            filename: "antigravity-\(sanitizeFilename(resolvedEmail)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(resolvedEmail) from Antigravity"
        )
    }

    // MARK: - Cursor

    private static func importCursorApp(authDirectory: URL, displayName: String) -> ConfiguredAccountImportResult {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let accessToken = VscdbStore.readString(dbURL: db, key: "cursorAuth/accessToken")
            ?? VscdbStore.readString(dbURL: db, key: "cursor.accessToken")
        else {
            return .failure(message: "Could not read Cursor credentials from the local Cursor app")
        }
        let email = JWTEmailExtractor.email(from: accessToken)
            ?? VscdbStore.readString(dbURL: db, key: "cursorAuth/cachedEmail")
            ?? VscdbStore.readString(dbURL: db, key: "cursor.email")
            ?? ""
        let refresh = VscdbStore.readString(dbURL: db, key: "cursorAuth/refreshToken") ?? ""
        let plan = VscdbStore.readString(dbURL: db, key: "cursorAuth/stripeMembershipType")
        let now = Date()
        var record: [String: Any] = [
            "type": "cursor",
            "email": email,
            "access_token": accessToken,
            "accessToken": accessToken,
            "refresh_token": refresh,
            "refreshToken": refresh,
            "expired": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)),
            "last_refresh": ISO8601DateFormatter().string(from: now),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]
        if let plan, !plan.isEmpty {
            record["plan_type"] = plan
            record["membership_type"] = plan
        }
        return writeAuthRecord(
            record,
            filename: "cursor-\(sanitizeFilename(email)).json",
            authDirectory: authDirectory,
            successLabel: "Imported \(email) from Cursor",
            overwrite: true
        )
    }

    // MARK: - Shared helpers

    private static func writeAuthRecord(
        _ record: [String: Any],
        filename: String,
        authDirectory: URL,
        successLabel: String,
        overwrite: Bool = true
    ) -> ConfiguredAccountImportResult {
        do {
            try AccountCredentialStore.save(record, in: authDirectory, overwrite: overwrite)
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            return .success(message: successLabel)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-")
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func claudeKeychainString() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func grokExpiresAt(from entry: [String: Any]) -> Date? {
        if let iso = entry["expires_at"] as? String, !iso.isEmpty {
            let formatters: [ISO8601DateFormatter] = {
                let withFractional = ISO8601DateFormatter()
                withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                return [withFractional, standard]
            }()
            for formatter in formatters {
                if let date = formatter.date(from: iso) { return date }
            }
        }
        if let ms = entry["expires"] as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let seconds = entry["expires_at"] as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

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
