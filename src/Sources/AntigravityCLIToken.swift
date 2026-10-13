import Foundation

/// The `agy` CLI's saved OAuth login: macOS Keychain first (go-keyring), token file as fallback.
/// Updates are in place, keeping every unrelated field and the stored encoding.
enum AntigravityCLIToken {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    private static let keyringBase64Prefix = "go-keyring-base64:"
    private static let keyringHexPrefix = "go-keyring-encoded:"

    enum WriteResult: Equatable {
        case notSignedIn
        case updated
        case unrecognized
        case writeFailed
    }

    struct Snapshot: Equatable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiry: Date?
    }

    static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    // MARK: - Live store

    /// The login `agy` will use next, read in the same precedence `agy` applies.
    static func currentSnapshot() -> Snapshot? {
        if let stored = readKeychain() {
            return snapshot(ofKeyringValue: stored)
        }
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        return snapshot(of: data)
    }

    /// Write a token into both `agy` stores. The Keychain result wins because `agy` reads it first.
    static func apply(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        expiry: Date
    ) -> WriteResult {
        var keychainResult = WriteResult.notSignedIn
        if let stored = readKeychain() {
            if let updated = updateKeyringValue(
                stored,
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                email: email,
                expiry: expiry
            ) {
                keychainResult = writeKeychain(updated) ? .updated : .writeFailed
            } else {
                keychainResult = .unrecognized
            }
        }

        var fileResult = WriteResult.notSignedIn
        let url = tokenFileURL
        if let existing = try? Data(contentsOf: url) {
            if let updated = update(
                existing,
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                email: email,
                expiry: expiry
            ) {
                fileResult = writeFile(updated, to: url) ? .updated : .writeFailed
            } else {
                fileResult = .unrecognized
            }
        }

        return keychainResult == .notSignedIn ? fileResult : keychainResult
    }

    private static func readKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", keychainAccount, "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// `security -i` reads one command line per stdin line and truncates past 4,095 bytes.
    private static let securityInteractiveLineLimit = 4_000

    /// Sends the secret over stdin so it never appears in a process argument list.
    private static func writeKeychain(_ value: String) -> Bool {
        guard let line = keychainWriteCommand(value) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        input.fileHandleForWriting.write(Data(line.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Build the `security -i` line for a Keychain update; nil when the value can't be sent safely.
    static func keychainWriteCommand(_ value: String) -> String? {
        guard !value.isEmpty, !value.contains(where: \.isNewline) else { return nil }
        let quoted = "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let line = "add-generic-password -U -a \(keychainAccount) -s \(keychainService) -w \(quoted)\n"
        return line.utf8.count <= securityInteractiveLineLimit ? line : nil
    }

    /// Back up the original once, write atomically, and keep both owner-only.
    private static func writeFile(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let backup = url.appendingPathExtension("viberouter-bak")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    // MARK: - Parsing

    static func snapshot(ofKeyringValue stored: String) -> Snapshot? {
        guard let (_, payload) = decodeKeyringValue(stored) else { return nil }
        return snapshot(of: payload)
    }

    static func snapshot(of data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = tokenObject(in: root),
              let accessKey = accessTokenKeys.first(where: { token[$0] is String }),
              let access = token[accessKey] as? String
        else { return nil }
        let refresh = refreshTokenKeys.lazy.compactMap { token[$0] as? String }.first
        let idToken = idTokenKeys.lazy.compactMap { token[$0] as? String }.first
        let expiry = expiryKeys.lazy.compactMap { parseExpiry(token[$0]) }.first
        return Snapshot(accessToken: access, refreshToken: refresh, idToken: idToken, expiry: expiry)
    }

    private static func tokenObject(in object: [String: Any]) -> [String: Any]? {
        if accessTokenKeys.contains(where: { object[$0] is String }) { return object }
        for value in object.values {
            if let child = value as? [String: Any], let found = tokenObject(in: child) { return found }
        }
        return nil
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = value as? String else { return nil }
        let withoutFraction = string.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: withoutFraction)
    }

    // MARK: - Updating

    /// Update a go-keyring stored value, re-encoding it with the same scheme it was read with.
    static func updateKeyringValue(
        _ stored: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        email: String?,
        expiry: Date
    ) -> String? {
        guard let (prefix, payload) = decodeKeyringValue(stored),
              let updated = update(
                  payload,
                  accessToken: accessToken,
                  refreshToken: refreshToken,
                  idToken: idToken,
                  email: email,
                  expiry: expiry
              )
        else { return nil }
        switch prefix {
        case keyringBase64Prefix: return prefix + updated.base64EncodedString()
        case keyringHexPrefix: return prefix + updated.map { String(format: "%02x", $0) }.joined()
        default: return String(decoding: updated, as: UTF8.self)
        }
    }

    private static func decodeKeyringValue(_ stored: String) -> (prefix: String, payload: Data)? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(keyringBase64Prefix) {
            guard let data = Data(base64Encoded: String(trimmed.dropFirst(keyringBase64Prefix.count))) else { return nil }
            return (keyringBase64Prefix, data)
        }
        if trimmed.hasPrefix(keyringHexPrefix) {
            guard let data = hexDecode(String(trimmed.dropFirst(keyringHexPrefix.count))) else { return nil }
            return (keyringHexPrefix, data)
        }
        return ("", Data(trimmed.utf8))
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
            i += 2
        }
        return out
    }

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
