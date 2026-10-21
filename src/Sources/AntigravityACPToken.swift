import Foundation

/// The agy ACP server's file login, `<GEMINI_HOME>/antigravity-acp/acp_token.json`, in the private
/// profiles T3 Code runs it with (`AGY_ACP_FORCE_FILE_STORAGE=1`). The server loads it with
/// google-auth's `from_authorized_user_info`, so it needs the OAuth client that minted the refresh token.
enum AntigravityACPToken {
    struct OAuthClient: Equatable {
        let id: String
        let secret: String
    }

    struct Snapshot: Equatable {
        let refreshToken: String
        let accessToken: String?
        let expiry: Date?
    }

    enum ApplyResult: Equatable {
        case noProfiles
        case updated(Int)
        case missingRefreshToken
        case writeFailed
    }

    static let tokenFileName = "acp_token.json"
    static let tokenURI = "https://oauth2.googleapis.com/token"
    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/aicode",
    ]
    private static let personalAuthType = "oauth-personal"
    private static let t3ProfilesPath = "providers/antigravity"

    // MARK: - Profiles

    /// `antigravity-acp` directories of T3 Code's Antigravity instances that use personal Google sign-in.
    static func profiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        let t3Root = home.appendingPathComponent(".t3", isDirectory: true)
        guard let bases = try? fm.contentsOfDirectory(at: t3Root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for base in bases {
            let root = base.appendingPathComponent(t3ProfilesPath, isDirectory: true)
            guard let instances = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for instance in instances {
                let acp = instance.appendingPathComponent("antigravity-acp", isDirectory: true)
                if isPersonalProfile(acp) { out.append(acp) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func isPersonalProfile(_ acpDirectory: URL) -> Bool {
        guard let data = try? Data(contentsOf: acpDirectory.appendingPathComponent("settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = root["auth"] as? [String: Any]
        else { return false }
        return auth["type"] as? String == personalAuthType
    }

    static func tokenURL(in acpDirectory: URL) -> URL {
        acpDirectory.appendingPathComponent(tokenFileName)
    }

    // MARK: - Reading

    static func snapshot(at acpDirectory: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: tokenURL(in: acpDirectory)) else { return nil }
        return snapshot(of: data)
    }

    static func snapshot(of data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = nonEmpty(root["refresh_token"])
        else { return nil }
        return Snapshot(
            refreshToken: refresh,
            accessToken: nonEmpty(root["token"]),
            expiry: (root["expiry"] as? String).flatMap(parseExpiry)
        )
    }

    // MARK: - Writing

    /// Build the token file. A renewal of the same login keeps the server's own fields
    /// (such as its resolved `project_id`); a different login starts clean.
    static func blob(
        existing: Data?,
        client: OAuthClient,
        accessToken: String,
        refreshToken: String,
        expiry: Date
    ) -> Data? {
        var root: [String: Any] = [:]
        if let existing,
           let previous = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
           nonEmpty(previous["refresh_token"]) == refreshToken
        {
            root = previous
        }
        root["client_id"] = client.id
        root["client_secret"] = client.secret
        root["refresh_token"] = refreshToken
        root["token_uri"] = tokenURI
        root["scopes"] = scopes
        root["token"] = accessToken
        root["expiry"] = formatExpiry(expiry)
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Point every personal T3 Code Antigravity profile at this login.
    static func apply(
        client: OAuthClient,
        accessToken: String,
        refreshToken: String?,
        expiry: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ApplyResult {
        let targets = profiles(home: home)
        guard !targets.isEmpty else { return .noProfiles }
        guard let refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty
        else { return .missingRefreshToken }
        var updated = 0
        for profile in targets where write(
            profile: profile,
            client: client,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        ) {
            updated += 1
        }
        return updated == 0 ? .writeFailed : .updated(updated)
    }

    static func write(
        profile acpDirectory: URL,
        client: OAuthClient,
        accessToken: String,
        refreshToken: String,
        expiry: Date
    ) -> Bool {
        let url = tokenURL(in: acpDirectory)
        let existing = try? Data(contentsOf: url)
        guard let data = blob(
            existing: existing,
            client: client,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        ) else { return false }
        if let existing, snapshot(of: existing)?.refreshToken != refreshToken {
            backUpOnce(existing, next: url)
        }
        return writeOwnerOnly(data, to: url)
    }

    private static func backUpOnce(_ data: Data, next url: URL) {
        let backup = url.appendingPathExtension("viberouter-bak")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        _ = writeOwnerOnly(data, to: backup)
    }

    /// Create the file 0600 before any bytes land, then rename it over the target.
    private static func writeOwnerOnly(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// google-auth parses `expiry` as `%Y-%m-%dT%H:%M:%S` in UTC after trimming `Z` and fractions.
    static func formatExpiry(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: trimmed) { return date }
        return f.date(from: trimmed + "Z")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty
        else { return nil }
        return string
    }
}
