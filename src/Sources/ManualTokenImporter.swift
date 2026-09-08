import Foundation

/// Paste-in auth import for every provider (Codex `~/.codex/auth.json`, CLIProxy files,
/// Claude credentials, Cursor JSON, Copilot, Gemini, Kiro, etc.).
enum ManualTokenImporter {
    struct ParsedAccount: Equatable {
        let type: ServiceType
        let filename: String
        let displayName: String
        let record: [String: Any]

        static func == (lhs: ParsedAccount, rhs: ParsedAccount) -> Bool {
            lhs.type == rhs.type
                && lhs.filename == rhs.filename
                && lhs.displayName == rhs.displayName
        }
    }

    static func importPasted(
        _ text: String,
        preferredType: ServiceType,
        authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api"),
        overwrite: Bool = true
    ) -> ConfiguredAccountImportResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "Paste a token JSON blob first")
        }

        if preferredType == .zai {
            let isJSON = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
            if !isJSON {
                return ConfiguredAccountImporter.importZaiAPIKey(apiKey: trimmed, authDirectory: authDirectory)
            }
        }

        switch parse(trimmed, preferredType: preferredType) {
        case .failure(let error):
            return .failure(message: error.localizedDescription)
        case .success(let accounts):
            var imported: [String] = []
            for account in accounts {
                let result = write(account, authDirectory: authDirectory, overwrite: overwrite)
                switch result {
                case .success(let message):
                    imported.append(message)
                    if account.type == .codex {
                        _ = CodexWorkspaceCredentials.materializeSeatAuthFiles(authDirectory: authDirectory)
                        AuthAccountLifecycle.clearTombstonesForPresentCodexSeats(authDirectory: authDirectory)
                    } else if let email = account.record["email"] as? String {
                        AuthAccountLifecycle.clearTombstone(
                            seatKey: "\(account.type.rawValue):email:\(email.lowercased())",
                            authDirectory: authDirectory
                        )
                    }
                case .failure(let message):
                    if imported.isEmpty {
                        return .failure(message: message)
                    }
                    return .failure(message: "Imported \(imported.count), then failed: \(message)")
                }
            }
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            if imported.count == 1 {
                return .success(message: imported[0])
            }
            return .success(message: "Imported \(imported.count) accounts")
        }
    }

    static func parse(_ text: String, preferredType: ServiceType) -> Result<[ParsedAccount], ImportError> {
        let data = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.message("Not valid JSON. Paste the full auth file (for Codex, ~/.codex/auth.json)."))
        }

        let blobs: [[String: Any]]
        if let dict = object as? [String: Any] {
            if let nested = dict["accounts"] as? [[String: Any]] ?? dict["items"] as? [[String: Any]],
               !nested.isEmpty
            {
                blobs = nested
            } else {
                blobs = [dict]
            }
        } else if let array = object as? [[String: Any]], !array.isEmpty {
            blobs = array
        } else {
            return .failure(.message("JSON must be an object or an array of account objects"))
        }

        var parsed: [ParsedAccount] = []
        for (index, blob) in blobs.enumerated() {
            do {
                parsed.append(try normalize(blob, preferredType: preferredType))
            } catch {
                return .failure(.message("Account \(index + 1): \(error.localizedDescription)"))
            }
        }
        return .success(parsed)
    }

    // MARK: - Normalize

    private static func normalize(
        _ raw: [String: Any],
        preferredType: ServiceType
    ) throws -> ParsedAccount {
        let unwrapped = unwrapNestedTokens(raw)
        let detected = detectType(unwrapped, preferredType: preferredType)
        switch detected {
        case .codex: return try normalizeCodex(unwrapped)
        case .claude: return try normalizeClaude(unwrapped)
        case .gemini, .antigravity: return try normalizeGoogle(unwrapped, type: detected)
        case .copilot: return try normalizeCopilot(unwrapped)
        case .cursor: return try normalizeCursor(unwrapped)
        case .kiro: return try normalizeKiro(unwrapped)
        case .grok: return try normalizeGrok(unwrapped)
        case .kimi: return try normalizeGenericOAuth(unwrapped, type: .kimi, labelKeys: ["email", "username"])
        case .qwen: return try normalizeGenericOAuth(unwrapped, type: .qwen, labelKeys: ["email", "username"])
        case .codebuddy: return try normalizeGenericOAuth(unwrapped, type: .codebuddy, labelKeys: ["email", "username", "login"])
        case .codebuddyCN: return try normalizeGenericOAuth(unwrapped, type: .codebuddyCN, labelKeys: ["email", "username", "login"])
        case .windsurf: return try normalizeGenericOAuth(unwrapped, type: .windsurf, labelKeys: ["email", "username"])
        case .qoder: return try normalizeGenericOAuth(unwrapped, type: .qoder, labelKeys: ["email", "username"])
        case .trae: return try normalizeGenericOAuth(unwrapped, type: .trae, labelKeys: ["email", "username"])
        case .zed: return try normalizeGenericOAuth(unwrapped, type: .zed, labelKeys: ["email", "username"])
        case .gitlab: return try normalizeGenericOAuth(unwrapped, type: .gitlab, labelKeys: ["email", "username", "login"])
        case .kilo: return try normalizeGenericOAuth(unwrapped, type: .kilo, labelKeys: ["email", "username"])
        case .zai:
            if let key = firstString(unwrapped, keys: ["api_key", "apiKey", "key", "token"]) {
                return try normalizeZai(key: key)
            }
            throw ImportError.missingField("api_key")
        case .opencodeGo:
            // Stored by CustomProviderCredentialStore, not as a pasted auth record.
            throw ImportError.message(
                "Add \(ServiceType.opencodeGo.displayName) keys under Settings → Providers, not by pasting a token."
            )
        }
    }

    private static func unwrapNestedTokens(_ raw: [String: Any]) -> [String: Any] {
        var out = raw
        if let tokens = raw["tokens"] as? [String: Any] {
            for (key, value) in tokens where out[key] == nil {
                out[key] = value
            }
        }
        if let oauth = raw["claudeAiOauth"] as? [String: Any] {
            if out["access_token"] == nil { out["access_token"] = oauth["accessToken"] ?? oauth["access_token"] }
            if out["refresh_token"] == nil { out["refresh_token"] = oauth["refreshToken"] ?? oauth["refresh_token"] }
            if out["email"] == nil { out["email"] = oauth["email"] }
        }
        return out
    }

    static func detectType(_ raw: [String: Any], preferredType: ServiceType) -> ServiceType {
        if let type = (raw["type"] as? String)?.lowercased(),
           let mapped = ServiceType(rawValue: type)
        {
            return mapped
        }
        if raw["tokens"] is [String: Any]
            || (raw["auth_mode"] as? String)?.lowercased() == "chatgpt"
            || issuer(from: firstString(raw, keys: ["access_token", "id_token"]))?.contains("openai.com") == true
        {
            return .codex
        }
        if raw["claudeAiOauth"] != nil { return .claude }
        if raw["cachedEmail"] != nil || raw["cursor_access_token"] != nil
            || issuer(from: firstString(raw, keys: ["accessToken", "access_token"]))?.contains("cursor") == true
        {
            return .cursor
        }
        if raw["region"] != nil && (raw["refreshToken"] != nil || raw["refresh_token"] != nil) {
            return .kiro
        }
        if firstString(raw, keys: ["client_id"])?.contains("googleusercontent") == true {
            return preferredType == .antigravity ? .antigravity : .gemini
        }
        return preferredType
    }

    private static func normalizeCodex(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken", "access"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken", "refresh"]) ?? ""
        let idToken = firstString(raw, keys: ["id_token", "idToken"]) ?? ""
        let email = firstString(raw, keys: ["email"])
            ?? JWTEmailExtractor.email(from: idToken)
            ?? JWTEmailExtractor.email(from: access)
            ?? "codex-account"
        let accountID = firstString(raw, keys: ["account_id", "accountId"])
            ?? CodexWorkspaceCredentials.chatgptAccountID(from: access)
            ?? ""
        let now = Date()
        var record: [String: Any] = [
            "type": "codex",
            "email": email,
            "access_token": access,
            "refresh_token": refresh,
            "id_token": idToken,
            "account_id": accountID,
            "expires_in": 3600,
            "expired": iso(now.addingTimeInterval(3600)),
            "last_refresh": firstString(raw, keys: ["last_refresh"]) ?? iso(now),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]
        if let plan = firstString(raw, keys: ["plan_type", "plan"]) {
            record["plan_type"] = plan
        }
        return ParsedAccount(
            type: .codex,
            filename: "codex-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeClaude(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken"]) ?? ""
        let email = firstString(raw, keys: ["email", "emailAddress"])
            ?? JWTEmailExtractor.email(from: access)
            ?? "claude-account"
        let now = Date()
        let expired = firstString(raw, keys: ["expired", "expires_at"])
            ?? iso(now.addingTimeInterval(8 * 3600))
        let record: [String: Any] = [
            "type": "claude",
            "email": email,
            "access_token": access,
            "refresh_token": refresh,
            "expired": expired,
            "last_refresh": iso(now),
        ]
        return ParsedAccount(
            type: .claude,
            filename: "claude-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeGoogle(_ raw: [String: Any], type: ServiceType) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken"]) ?? ""
        let email = firstString(raw, keys: ["email"])
            ?? JWTEmailExtractor.email(from: firstString(raw, keys: ["id_token"]))
            ?? JWTEmailExtractor.email(from: access)
            ?? "\(type.rawValue)-account"
        let now = Date()
        var record: [String: Any] = [
            "type": type.rawValue,
            "email": email,
            "access_token": access,
            "refresh_token": refresh,
            "expires_in": intValue(raw, keys: ["expires_in"]) ?? 3600,
            "expired": firstString(raw, keys: ["expired", "expires_at"]) ?? iso(now.addingTimeInterval(3600)),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]
        if let idToken = firstString(raw, keys: ["id_token"]) {
            record["id_token"] = idToken
        }
        if let project = firstString(raw, keys: ["project_id", "projectId"]) {
            record["project_id"] = project
        }
        record["auto"] = true
        record["checked"] = true
        return ParsedAccount(
            type: type,
            filename: "\(type.rawValue)-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeCopilot(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken", "oauth_token", "token"]) else {
            throw ImportError.missingField("access_token")
        }
        let username = firstString(raw, keys: ["username", "login", "email"])
            ?? nestedAccountName(raw)
            ?? "copilot-account"
        let record: [String: Any] = [
            "type": "github-copilot",
            "access_token": access,
            "token_type": "bearer",
            "scope": firstString(raw, keys: ["scope"]) ?? "",
            "username": username,
            "email": username,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        return ParsedAccount(
            type: .copilot,
            filename: "github-copilot-\(sanitize(username)).json",
            displayName: username,
            record: record
        )
    }

    private static func normalizeCursor(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken", "token", "cursor_access_token"]) else {
            throw ImportError.missingField("access_token")
        }
        let email = firstString(raw, keys: ["email", "cachedEmail", "cursor_email"])
            ?? JWTEmailExtractor.email(from: access)
            ?? "cursor-account"
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken", "cursor_refresh_token"]) ?? ""
        let now = Date()
        var record: [String: Any] = [
            "type": "cursor",
            "email": email,
            "access_token": access,
            "accessToken": access,
            "refresh_token": refresh,
            "refreshToken": refresh,
            "expired": iso(now.addingTimeInterval(3600)),
            "last_refresh": iso(now),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]
        if let plan = firstString(raw, keys: ["membership_type", "membershipType", "stripeMembershipType", "plan", "plan_type"]) {
            record["plan_type"] = plan
            record["membership_type"] = plan
        }
        if let status = firstString(raw, keys: ["subscription_status", "subscriptionStatus"]) {
            record["subscription_status"] = status
        }
        return ParsedAccount(
            type: .cursor,
            filename: "cursor-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeKiro(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken"]) ?? ""
        let email = firstString(raw, keys: ["email", "username"])
            ?? JWTEmailExtractor.email(from: access)
            ?? "kiro-account"
        let region = firstString(raw, keys: ["region"]) ?? "us-east-1"
        let now = Date()
        var record: [String: Any] = [
            "type": "kiro",
            "email": email,
            "access_token": access,
            "accessToken": access,
            "refresh_token": refresh,
            "refreshToken": refresh,
            "region": region,
            "expired": firstString(raw, keys: ["expired", "expires_at", "expiresAt"]) ?? iso(now.addingTimeInterval(3600)),
            "last_refresh": iso(now),
        ]
        for key in ["client_id", "clientId", "client_secret", "clientSecret", "client_id_hash", "clientIdHash", "auth_method", "authMethod", "provider", "start_url", "profile_arn"] {
            if let value = firstString(raw, keys: [key]) {
                switch key {
                case "clientId": record["client_id"] = value
                case "clientSecret": record["client_secret"] = value
                case "clientIdHash": record["client_id_hash"] = value
                case "authMethod": record["auth_method"] = value
                default: record[key] = value
                }
            }
        }
        let filename: String
        if let clientID = firstString(raw, keys: ["client_id", "clientId"]) {
            filename = KiroAWSAuth.filename(clientID: clientID)
        } else {
            filename = "kiro-\(sanitize(email)).json"
        }
        return ParsedAccount(
            type: .kiro,
            filename: filename,
            displayName: email,
            record: record
        )
    }

    private static func normalizeGrok(_ raw: [String: Any]) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken", "key", "access"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken", "refresh"]) ?? ""
        let email = firstString(raw, keys: ["email"])
            ?? JWTEmailExtractor.email(from: access)
            ?? "grok-account"
        let now = Date()
        let record: [String: Any] = [
            "type": "xai",
            "email": email,
            "access_token": access,
            "refresh_token": refresh,
            "expires_in": 3600,
            "expired": firstString(raw, keys: ["expired", "expires_at"]) ?? iso(now.addingTimeInterval(3600)),
            "last_refresh": iso(now),
            "auth_kind": "oauth",
        ]
        return ParsedAccount(
            type: .grok,
            filename: "xai-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeGenericOAuth(
        _ raw: [String: Any],
        type: ServiceType,
        labelKeys: [String]
    ) throws -> ParsedAccount {
        guard let access = firstString(raw, keys: ["access_token", "accessToken", "token"]) else {
            throw ImportError.missingField("access_token")
        }
        let refresh = firstString(raw, keys: ["refresh_token", "refreshToken"]) ?? ""
        let email = firstString(raw, keys: labelKeys)
            ?? JWTEmailExtractor.email(from: access)
            ?? "\(type.rawValue)-account"
        let now = Date()
        var record: [String: Any] = [
            "type": type.rawValue,
            "email": email,
            "access_token": access,
            "refresh_token": refresh,
            "expired": firstString(raw, keys: ["expired", "expires_at"]) ?? iso(now.addingTimeInterval(3600)),
            "last_refresh": iso(now),
            "timestamp": Int(now.timeIntervalSince1970 * 1000),
        ]
        if let username = firstString(raw, keys: ["username", "login"]) {
            record["username"] = username
        }
        return ParsedAccount(
            type: type,
            filename: "\(type.rawValue)-\(sanitize(email)).json",
            displayName: email,
            record: record
        )
    }

    private static func normalizeZai(key: String) throws -> ParsedAccount {
        let suffix = String(key.suffix(6))
        let record: [String: Any] = [
            "type": "zai",
            "api_key": key,
            "email": "zai-…\(suffix)",
        ]
        return ParsedAccount(
            type: .zai,
            filename: "zai-\(sanitize(suffix)).json",
            displayName: "Z.AI key …\(suffix)",
            record: record
        )
    }

    // MARK: - Write

    private static func write(
        _ account: ParsedAccount,
        authDirectory: URL,
        overwrite: Bool
    ) -> ConfiguredAccountImportResult {
        do {
            try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
            let destination = authDirectory.appendingPathComponent(account.filename)
            if !overwrite, FileManager.default.fileExists(atPath: destination.path) {
                return .failure(message: "Account already exists at \(account.filename)")
            }
            if account.type == .zai, let key = account.record["api_key"] as? String {
                return ConfiguredAccountImporter.importZaiAPIKey(apiKey: key, authDirectory: authDirectory)
            }
            let data = try JSONSerialization.data(withJSONObject: account.record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return .success(message: "Added \(account.displayName) to \(account.type.displayName)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    enum ImportError: LocalizedError {
        case missingField(String)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .missingField(let field): return "Missing \(field)"
            case .message(let text): return text
            }
        }
    }

    static func firstString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func nestedAccountName(_ raw: [String: Any]) -> String? {
        let account = raw["account"] as? [String: Any]
        return firstString(account ?? [:], keys: ["label", "login"])
    }

    private static func intValue(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let number = json[key] as? NSNumber { return number.intValue }
            if let value = json[key] as? Int { return value }
            if let value = json[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func issuer(from token: String?) -> String? {
        guard let token, token.split(separator: ".").count >= 2 else { return nil }
        var payload = String(token.split(separator: ".")[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["iss"] as? String
    }

    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-")
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
