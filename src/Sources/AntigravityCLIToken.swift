import Foundation

/// In-place rewrite of the `agy` CLI's saved OAuth token, keeping every unrelated field.
enum AntigravityCLIToken {
    private static let accessTokenKeys = ["access_token", "accessToken"]
    private static let refreshTokenKeys = ["refresh_token", "refreshToken"]
    private static let idTokenKeys = ["id_token", "idToken"]
    private static let emailKeys = ["email", "user_email"]
    private static let expiryKeys = ["expiry", "expiry_date", "expiresAt", "expires_at", "expiry_timestamp"]

    /// Replace token fields in the existing `agy` token JSON, keeping every other field.
    /// Returns nil when no object containing an access token is found.
    static func update(
        _ existing: Data,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        expiry: Date
    ) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let updated = updateObject(
                  root,
                  accessToken: accessToken,
                  refreshToken: refreshToken,
                  idToken: idToken,
                  email: email,
                  expiry: expiry
              )
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func updateObject(
        _ object: [String: Any],
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        expiry: Date
    ) -> [String: Any]? {
        guard let accessKey = accessTokenKeys.first(where: { object[$0] is String }) else {
            for (key, value) in object {
                guard let child = value as? [String: Any],
                      let updatedChild = updateObject(
                          child,
                          accessToken: accessToken,
                          refreshToken: refreshToken,
                          idToken: idToken,
                          email: email,
                          expiry: expiry
                      )
                else { continue }
                var out = object
                out[key] = updatedChild
                return out
            }
            return nil
        }

        let camel = accessKey == "accessToken"
        var out = object
        out[accessKey] = accessToken

        if let refreshToken {
            let key = refreshTokenKeys.first(where: { object[$0] != nil }) ?? (camel ? "refreshToken" : "refresh_token")
            out[key] = refreshToken
        }

        for key in idTokenKeys where object[key] != nil {
            if let idToken { out[key] = idToken } else { out.removeValue(forKey: key) }
        }

        if let email {
            for key in emailKeys where object[key] is String {
                out[key] = email
            }
        }

        if let key = expiryKeys.first(where: { object[$0] != nil }) {
            out[key] = encodeExpiry(expiry, like: object[key])
        } else {
            out["expiry"] = rfc3339(expiry)
        }
        return out
    }

    /// Match the existing expiry encoding: RFC 3339 string, or epoch seconds/milliseconds.
    private static func encodeExpiry(_ expiry: Date, like existing: Any?) -> Any {
        if let number = existing as? NSNumber {
            let seconds = expiry.timeIntervalSince1970
            return number.doubleValue > 100_000_000_000 ? Int(seconds * 1000) : Int(seconds)
        }
        return rfc3339(expiry)
    }

    private static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
