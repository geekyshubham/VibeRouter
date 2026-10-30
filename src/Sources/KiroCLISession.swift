import Foundation
import SQLite3

/// Kiro CLI persists credentials as JSON text in SQLite's auth_kv table.
/// Keep the token, OIDC registration and selected profile together when switching.
/// Legacy Keychain entries are not the CLI session and must never prompt during refresh.
enum KiroCLISession {
    static let socialKey = "kirocli:social:token"
    static let oidcKey = "kirocli:odic:token" // Kiro's persisted spelling.
    static let registrationKey = "kirocli:odic:device-registration"
    static let profileKey = "api.codewhisperer.profile"

    static func databaseURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }

    static func payload(forKey key: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any]? {
        let url = databaseURL(home: home)
        guard var token = read(url, table: "auth_kv", key: key),
              AccountCredentialIdentity.access(token) != nil else { return nil }
        token["type"] = "kiro"
        token["auth_method"] = key == oidcKey ? "idc" : "social"
        if key == oidcKey,
           let registration = read(url, table: "auth_kv", key: registrationKey) {
            token.merge(registration) { current, _ in current }
        }
        if let profile = read(url, table: "state", key: profileKey) {
            token["kiro_cli_profile"] = profile
            if token["profile_arn"] == nil { token["profile_arn"] = profile["arn"] }
        }
        return token
    }

    static func currentPayload(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: Any]? {
        payload(forKey: socialKey, home: home)
            ?? payload(forKey: oidcKey, home: home)
    }

    static func apply(_ payload: [String: Any], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard AccountCredentialIdentity.isConsistent(payload),
              let access = AccountCredentialIdentity.access(payload),
              let expiry = TokenRefreshService.accessTokenExpiry(from: payload) else {
            throw SessionError.message("Kiro credentials need an access token and expiry. Re-import this account.")
        }
        let oidc = KiroAWSAuth.isAWSSession(payload)
        var token: [String: Any] = ["access_token": access, "expires_at": ISO8601DateFormatter().string(from: expiry)]
        for (target, aliases) in [
            ("refresh_token", ["refresh_token", "refreshToken"]), ("region", ["region"]),
            ("start_url", ["start_url", "startUrl"]), ("oauth_flow", ["oauth_flow", "oauthFlow"]),
            ("profile_arn", ["profile_arn", "profileArn"]), ("id_token", ["id_token", "idToken"]),
            ("user_id", ["user_id", "userId"]),
            ("provider", ["provider"])
        ] {
            token[target] = AccountCredentialIdentity.value(payload, aliases)
        }
        token["email"] = KiroAccountIdentity.email(payload)
        token["scopes"] = payload["scopes"] ?? KiroAWSAuth.scopes
        var registration: [String: Any]?
        if oidc {
            guard let client = AccountCredentialIdentity.value(payload, ["client_id", "clientId"]),
                  let secret = AccountCredentialIdentity.value(payload, ["client_secret", "clientSecret"]) else {
                throw SessionError.message("This Kiro AWS account is missing its OIDC registration. Re-import it before switching.")
            }
            token["region"] = token["region"] ?? KiroAWSAuth.defaultRegion
            token["start_url"] = token["start_url"] ?? KiroAWSAuth.builderIDStartURL
            token["oauth_flow"] = token["oauth_flow"] ?? "DeviceCode"
            registration = ["client_id": client, "client_secret": secret,
                            "region": token["region"]!, "oauth_flow": token["oauth_flow"]!, "scopes": token["scopes"]!]
            registration?["client_secret_expires_at"] = payload["client_secret_expires_at"]
        }
        var profile = payload["kiro_cli_profile"] as? [String: Any]
        if let arn = token["profile_arn"] as? String {
            profile = profile ?? [:]
            profile?["arn"] = arn
        }
        let values: [String: Data?] = [
            socialKey: oidc ? nil : try JSONSerialization.data(withJSONObject: token),
            oidcKey: oidc ? try JSONSerialization.data(withJSONObject: token) : nil,
            registrationKey: try registration.map { try JSONSerialization.data(withJSONObject: $0) }
        ]
        let url = databaseURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw SessionError.message("Could not open Kiro CLI's credential database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SessionError.message("Could not update Kiro CLI credentials: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE IF NOT EXISTS auth_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            for (key, value) in values { try write(db, table: "auth_kv", key: key, data: value) }
            try write(db, table: "state", key: profileKey,
                      data: try profile.map { try JSONSerialization.data(withJSONObject: $0) })
            for key in ["auth.idc.region", "auth.idc.start-url"] {
                let value = oidc ? token[key == "auth.idc.region" ? "region" : "start_url"] : nil
                try write(db, table: "state", key: key,
                          data: try value.map { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) })
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func read(_ url: URL, table: String, key: String) -> [String: Any]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM \(table) WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return decode(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private static func write(_ db: OpaquePointer, table: String, key: String, data: Data?) throws {
        var statement: OpaquePointer?
        let sql = data == nil ? "DELETE FROM \(table) WHERE key = ?"
            : "INSERT OR REPLACE INTO \(table) (key, value) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionError.message("Could not prepare Kiro CLI credential update.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        if let data {
            sqlite3_bind_text(statement, 2, String(decoding: data, as: UTF8.self), -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionError.message("Could not save Kiro CLI credentials.") }
    }

    enum SessionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
