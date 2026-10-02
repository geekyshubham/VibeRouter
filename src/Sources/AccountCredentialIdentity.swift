import CryptoKit
import Foundation

/// Shared identity rules for every provider. Labels, OAuth client registrations,
/// and missing identity fields cannot authorize replacing another login.
enum AccountCredentialIdentity {
    static func flattened(_ root: [String: Any]) -> [String: Any] {
        var out = root
        for wrapper in ["tokens", "claudeAiOauth", "token"] {
            if let nested = root[wrapper] as? [String: Any] {
                for (key, value) in nested where out[key] == nil { out[key] = value }
            }
        }
        return out
    }

    static func provider(_ root: [String: Any]) -> String? {
        let payload = flattened(root)
        guard let kind = value(payload, ["type"])?.lowercased() else { return nil }
        switch kind {
        case "grok": return "xai"
        case "copilot": return "github-copilot"
        case "openai-compat": return kind + ":" + (value(payload, ["provider"]) ?? "")
        default: return kind
        }
    }

    static func email(_ root: [String: Any]) -> String? {
        let payload = flattened(root)
        for candidate in [JWTEmailExtractor.email(from: access(payload)),
                          JWTEmailExtractor.email(from: value(payload, ["id_token", "idToken"])),
                          value(payload, ["email", "emailAddress", "cachedEmail", "cursor_email"])] {
            if let candidate, candidate.contains("@") { return candidate.lowercased() }
        }
        return nil
    }

    static func hasConflict(_ first: [String: Any], _ second: [String: Any]) -> Bool {
        let a = flattened(first), b = flattened(second)
        if let left = provider(a), let right = provider(b), left != right { return true }
        guard isConsistent(a), isConsistent(b) else { return true }
        for (key, left) in principals(a) {
            if let right = principals(b)[key], left != right { return true }
        }
        for (key, left) in scopes(a) {
            if let right = scopes(b)[key], left != right { return true }
        }
        if let left = apiKey(a), let right = apiKey(b), left != right { return true }
        return false
    }

    /// Native apps sometimes keep the account email separately from opaque OAuth
    /// tokens. Attach that metadata only when the credential lineage matches.
    static func email(_ root: [String: Any], matchingNative native: [String: Any]?) -> String? {
        if let own = email(root) { return own }
        guard let native, sameAccount(root, native) else { return nil }
        return email(native)
    }

    static func sameAccount(_ first: [String: Any], _ second: [String: Any]) -> Bool {
        let a = flattened(first), b = flattened(second)
        guard !hasConflict(a, b) else { return false }
        if let left = apiKey(a), let right = apiKey(b) { return left == right }
        // A workspace/project may contain multiple people. Require a principal
        // or a matching token, and do not collapse different known scopes.
        let identityA = principals(a), identityB = principals(b)
        let scopeA = scopes(a), scopeB = scopes(b)
        if identityA.isEmpty != identityB.isEmpty {
            guard let left = value(a, ["refresh_token", "refreshToken", "refresh"]),
                  let right = value(b, ["refresh_token", "refreshToken", "refresh"]), left == right else { return false }
        }
        if scopeA == scopeB,
           identityA.contains(where: { identityB[$0.key] == $0.value }) { return true }
        for keys in [["refresh_token", "refreshToken", "refresh"], ["access_token", "accessToken", "access", "oauth_token", "token", "key"]] {
            if let left = value(a, keys), let right = value(b, keys), left == right,
               scopeA == scopeB { return true }
        }
        return false
    }

    static func key(_ root: [String: Any]) -> String {
        let payload = flattened(root)
        let kind = provider(payload) ?? "unknown"
        if let key = apiKey(payload) { return kind + ":key:" + digest(key) }
        let principal = principals(payload)
        let scope = scopes(payload)
        if !principal.isEmpty {
            return kind + ":identity:" + digest(encoded(principal) + "|" + encoded(scope))
        }
        if let stored = value(payload, ["viberouter_account_key"]), stored.hasPrefix(kind + ":session:") { return stored }
        let token = value(payload, ["refresh_token", "refreshToken", "refresh"]) ?? access(payload) ?? UUID().uuidString
        return kind + ":session:" + digest(token + "|" + encoded(scope))
    }

    static func filename(_ root: [String: Any]) -> String {
        let payload = flattened(root)
        if provider(payload) == "codex", email(payload) != nil {
            return ManualTokenImporter.codexFilename(payload)
        }
        let prefix = safeComponent(value(payload, ["type"])?.lowercased() ?? "account")
        return "\(prefix)-account-\(digest(key(payload))).json"
    }

    static func isConsistent(_ root: [String: Any]) -> Bool {
        let payload = flattened(root)
        let accessEmail = JWTEmailExtractor.email(from: access(payload))?.lowercased()
        let idEmail = JWTEmailExtractor.email(from: value(payload, ["id_token", "idToken"]))?.lowercased()
        if let accessEmail, let idEmail, accessEmail != idEmail { return false }
        if let actual = accessEmail ?? idEmail, let stored = value(payload, ["email"]), stored.contains("@"),
           actual != stored.lowercased() { return false }
        let claims = jwtClaims(access(payload))
        if let stored = value(payload, ["account_id", "accountId", "chatgpt_account_id"]),
           let actual = CodexWorkspaceCredentials.chatgptAccountID(from: access(payload)),
           stored.caseInsensitiveCompare(actual) != .orderedSame { return false }
        for aliases in [["account_id", "accountId"], ["project_id", "projectId"], ["workspace_id", "workspaceId"],
                        ["organization_id", "organizationId", "org_id"], ["profile_arn", "profileArn"]] {
            if let stored = value(payload, aliases), let actual = value(claims, aliases), stored != actual { return false }
        }
        if let stored = value(payload, ["user_id", "userId", "subject"]),
           let actual = CodexWorkspaceCredentials.chatgptUserID(from: access(payload))
                ?? value(claims, ["user_id", "userId", "sub"]), stored != actual { return false }
        return true
    }

    static func access(_ payload: [String: Any]) -> String? {
        value(payload, ["access_token", "accessToken", "access", "oauth_token", "token", "key"])
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func value(_ payload: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let candidate = payload[key] as? String {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func identifier(_ payload: [String: Any], _ keys: [String]) -> String? {
        if let text = value(payload, keys) { return text }
        for key in keys {
            if let number = payload[key] as? Int { return String(number) }
        }
        return nil
    }

    private static func principals(_ payload: [String: Any]) -> [String: String] {
        var identity: [String: String] = [:]
        if let email = email(payload) { identity["email"] = email }
        let claims = jwtClaims(access(payload))
        if let user = CodexWorkspaceCredentials.chatgptUserID(from: access(payload))
            ?? value(claims, ["user_id", "userId", "sub"])
            ?? value(payload, ["user_id", "userId", "subject", "uid"]) { identity["user"] = user }
        if let login = value(payload, ["login", "username"]), !login.contains("@"),
           !login.lowercased().hasSuffix("-account"), !login.lowercased().hasSuffix(" account") {
            identity["login"] = login.lowercased()
        }
        return identity
    }

    private static func scopes(_ payload: [String: Any]) -> [String: String] {
        var scope: [String: String] = [:]
        let claims = jwtClaims(access(payload))
        if let workspace = CodexWorkspaceCredentials.chatgptAccountID(from: access(payload))
            ?? value(claims, ["account_id", "accountId"])
            ?? value(payload, ["account_id", "accountId", "chatgpt_account_id"]) { scope["account"] = workspace }
        for (key, aliases) in [("project", ["project_id", "projectId"]),
                               ("workspace", ["workspace_id", "workspaceId"]),
                               ("organization", ["organization_id", "organizationId", "org_id"]),
                               ("profile", ["profile_arn", "profileArn"])] {
            if let value = value(claims, aliases) ?? value(payload, aliases) { scope[key] = value }
        }
        return scope
    }

    private static func apiKey(_ payload: [String: Any]) -> String? { value(payload, ["api_key", "apiKey"]) }

    private static func encoded(_ fields: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func safeComponent(_ text: String) -> String {
        String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
    }

    private static func jwtClaims(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }
}
