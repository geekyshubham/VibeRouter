import Foundation

/// Compile and run from the repo root:
///   swiftc -o /tmp/antigravity-cli-token-spec \
///     src/Verification/AntigravityCLITokenSpec.swift \
///     src/Sources/AntigravityCLIToken.swift && /tmp/antigravity-cli-token-spec
@main
struct AntigravityCLITokenSpec {
    static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    static func update(_ json: Any, refresh: String? = "1//new_refresh", idToken: String? = nil) -> [String: Any]? {
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard let out = AntigravityCLIToken.update(
            data,
            accessToken: "ya29.new_access",
            refreshToken: refresh,
            idToken: idToken,
            email: "new@example.com",
            expiry: expiry
        ) else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    static func main() {
        let go = update([
            "access_token": "ya29.old_access",
            "token_type": "Bearer",
            "refresh_token": "1//old_refresh",
            "expiry": "2026-01-01T00:00:00.123456+05:30",
            "client_id": "synthetic-client",
        ])!
        precondition(go["access_token"] as? String == "ya29.new_access")
        precondition(go["refresh_token"] as? String == "1//new_refresh")
        precondition(go["token_type"] as? String == "Bearer", "unrelated fields must be kept")
        precondition(go["client_id"] as? String == "synthetic-client", "unrelated fields must be kept")
        precondition(ISO8601DateFormatter().date(from: go["expiry"] as! String) == expiry, "RFC 3339 expiry")

        let nested = update([
            "version": 2,
            "token": [
                "accessToken": "ya29.old",
                "refreshToken": "1//old",
                "expiresAt": 1_700_000_000_000,
                "email": "old@example.com",
            ],
        ])!
        let token = nested["token"] as! [String: Any]
        precondition(nested["version"] as? Int == 2)
        precondition(token["accessToken"] as? String == "ya29.new_access")
        precondition(token["refreshToken"] as? String == "1//new_refresh")
        precondition(token["expiresAt"] as? Int == 1_800_000_000_000, "millisecond expiry stays in milliseconds")
        precondition(token["email"] as? String == "new@example.com")

        let seconds = update(["access_token": "ya29.old", "expiry_timestamp": 1_700_000_000])!
        precondition(seconds["expiry_timestamp"] as? Int == 1_800_000_000, "second expiry stays in seconds")

        let staleID = update(["access_token": "ya29.old", "id_token": "old.jwt.sig"], idToken: nil)!
        precondition(staleID["id_token"] == nil, "previous account's id_token must be dropped")

        let keepRefresh = update(["access_token": "ya29.old", "refresh_token": "1//keep"], refresh: nil)!
        precondition(keepRefresh["refresh_token"] as? String == "1//keep")

        let raw = AntigravityCLIToken.update(
            try! JSONSerialization.data(withJSONObject: ["access_token": "x", "refresh_token": "1//a/b"]),
            accessToken: "ya29.a/b",
            refreshToken: "1//c/d",
            idToken: nil,
            email: nil,
            expiry: expiry
        )!
        precondition(!String(decoding: raw, as: UTF8.self).contains("\\/"), "slashes written unescaped")

        precondition(update(["something": "else"]) == nil, "no access token → refuse")
        precondition(AntigravityCLIToken.update(
            Data("not-json-opaque-blob".utf8),
            accessToken: "ya29.new",
            refreshToken: nil,
            idToken: nil,
            email: nil,
            expiry: expiry
        ) == nil, "non-JSON → refuse")

        let plainJSON = #"{"access_token":"ya29.old","refresh_token":"1//old","expiry":"2026-01-01T00:00:00Z"}"#
        func keyring(_ stored: String) -> String? {
            AntigravityCLIToken.updateKeyringValue(
                stored,
                accessToken: "ya29.new_access",
                refreshToken: "1//new_refresh",
                idToken: nil,
                email: nil,
                expiry: expiry
            )
        }
        func accessToken(in json: Data) -> String? {
            (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["access_token"] as? String
        }

        let b64 = keyring("go-keyring-base64:" + Data(plainJSON.utf8).base64EncodedString())!
        precondition(b64.hasPrefix("go-keyring-base64:"), "base64 scheme preserved")
        precondition(accessToken(in: Data(base64Encoded: String(b64.dropFirst(18)))!) == "ya29.new_access")

        let hexStored = "go-keyring-encoded:" + Data(plainJSON.utf8).map { String(format: "%02x", $0) }.joined()
        let hex = keyring(hexStored)!
        precondition(hex.hasPrefix("go-keyring-encoded:"), "hex scheme preserved")
        precondition(hex.dropFirst(19).allSatisfy(\.isHexDigit))

        let plain = keyring(plainJSON)!
        precondition(accessToken(in: Data(plain.utf8)) == "ya29.new_access", "plain JSON stays plain")

        precondition(keyring("go-keyring-base64:!!notbase64") == nil, "bad base64 → refuse")
        precondition(keyring("opaque-secret") == nil, "non-JSON keyring value → refuse")

        let goSnapshot = AntigravityCLIToken.snapshot(of: Data(
            #"{"access_token":"ya29.a","refresh_token":"1//r","id_token":"h.p.s","expiry":"2026-10-13T16:44:41.02521+05:30"}"#.utf8
        ))!
        precondition(goSnapshot.accessToken == "ya29.a")
        precondition(goSnapshot.refreshToken == "1//r")
        precondition(goSnapshot.idToken == "h.p.s")
        precondition(goSnapshot.expiry == Date(timeIntervalSince1970: 1_791_890_081), "Go RFC 3339 with nanoseconds")

        let msSnapshot = AntigravityCLIToken.snapshot(of: Data(
            #"{"token":{"accessToken":"ya29.b","expiresAt":1800000000000}}"#.utf8
        ))!
        precondition(msSnapshot.accessToken == "ya29.b" && msSnapshot.refreshToken == nil)
        precondition(msSnapshot.expiry == expiry, "millisecond epoch expiry")

        let keyringSnapshot = AntigravityCLIToken.snapshot(
            ofKeyringValue: "go-keyring-base64:" + Data(plainJSON.utf8).base64EncodedString()
        )!
        precondition(keyringSnapshot.refreshToken == "1//old")
        precondition(AntigravityCLIToken.snapshot(ofKeyringValue: hexStored)?.accessToken == "ya29.old")
        precondition(AntigravityCLIToken.snapshot(ofKeyringValue: "opaque-secret") == nil)

        let renewed = AntigravityCLIToken.snapshot(of: Data(AntigravityCLIToken.update(
            Data(#"{"access_token":"ya29.old","refresh_token":"1//r","id_token":"keep.me.ok"}"#.utf8),
            accessToken: "ya29.renewed",
            refreshToken: "1//r",
            idToken: "keep.me.ok",
            email: nil,
            expiry: expiry
        )!))!
        precondition(renewed == .init(accessToken: "ya29.renewed", refreshToken: "1//r", idToken: "keep.me.ok", expiry: expiry))

        let command = AntigravityCLIToken.keychainWriteCommand(#"a\b"c"#)!
        precondition(command == #"add-generic-password -U -a antigravity -s gemini -w "a\\b\"c""# + "\n")
        precondition(AntigravityCLIToken.keychainWriteCommand("line1\nline2") == nil, "newline would split the command")
        precondition(AntigravityCLIToken.keychainWriteCommand("") == nil)
        precondition(AntigravityCLIToken.keychainWriteCommand(String(repeating: "x", count: 1_900)) != nil)
        precondition(AntigravityCLIToken.keychainWriteCommand(String(repeating: "x", count: 4_000)) == nil, "over the stdin line cap")

        print("AntigravityCLITokenSpec: OK")
    }
}
