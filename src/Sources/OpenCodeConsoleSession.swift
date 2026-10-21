import Foundation
import SQLite3

/// OpenCode v2 stores a Console device-login in `opencode.db`. That access
/// token is a bearer for `https://opencode.ai/zen/go/v1`. The API key saved
/// next to it expires on its own and signing in does not renew it.
enum OpenCodeConsoleSession {
    struct CredentialRow: Equatable {
        var json: String
        var updated: Int64
        var active: Bool
    }

    static func bearer(
        stored: String,
        providerID: String = ProviderCatalog.openCodeGoProviderName,
        now: Date = Date(),
        databaseURL: URL? = nil
    ) -> String {
        guard providerID == ProviderCatalog.openCodeGoProviderName else { return stored }
        return accessToken(in: databaseURL ?? defaultDatabaseURL(), now: now) ?? stored
    }

    static func accessToken(in databaseURL: URL, now: Date = Date()) -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        // Read-write so a live WAL is visible. query_only plus autocheckpoint 0
        // keeps this from writing opencode.db. A read-only open misses frames
        // while OpenCode holds the database, and the file is too large to copy.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA wal_autocheckpoint=0;", nil, nil, nil)

        let sql = """
        SELECT value, IFNULL(time_updated, 0), IFNULL(active, 0)
        FROM credential WHERE integration_id = 'opencode'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var rows: [CredentialRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            rows.append(CredentialRow(
                json: String(cString: cstr),
                updated: sqlite3_column_int64(stmt, 1),
                active: sqlite3_column_int64(stmt, 2) != 0
            ))
        }
        return selectAccessToken(from: rows, now: now)
    }

    /// Newest active, unexpired `type: oauth` access token. API-key rows are ignored.
    /// ponytail: no refresh here — OpenCode rotates this row. Refreshing the same
    /// refresh token from VibeRouter would invalidate the desktop login.
    static func selectAccessToken(from rows: [CredentialRow], now: Date) -> String? {
        struct Candidate {
            var access: String
            var updated: Int64
            var active: Bool
        }
        let candidates: [Candidate] = rows.compactMap { row in
            guard let object = jsonObject(row.json),
                  (object["type"] as? String) == "oauth",
                  let access = object["access"] as? String,
                  !access.isEmpty,
                  let expires = expiresDate(object["expires"]),
                  expires > now
            else { return nil }
            return Candidate(access: access, updated: row.updated, active: row.active)
        }
        return candidates.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            return lhs.updated > rhs.updated
        }.first?.access
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func expiresDate(_ value: Any?) -> Date? {
        let raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let number = value as? Double {
            raw = number
        } else if let number = value as? Int {
            raw = Double(number)
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
