import Foundation

/// Compile and run from the repo root:
///   swiftc -o /tmp/antigravity-acp-token-spec \
///     src/Verification/AntigravityACPTokenSpec.swift \
///     src/Sources/AntigravityACPToken.swift && /tmp/antigravity-acp-token-spec [--emit <dir>]
@main
struct AntigravityACPTokenSpec {
    static let client = AntigravityACPToken.OAuthClient(id: "synthetic-client.apps.example", secret: "synthetic-secret")
    static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    static func json(_ data: Data?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data!) as? [String: Any]) ?? [:]
    }

    static func makeProfile(_ home: URL, base: String, instance: String, authType: String) -> URL {
        let acp = home.appendingPathComponent(".t3/\(base)/providers/antigravity/\(instance)/antigravity-acp")
        try! FileManager.default.createDirectory(at: acp, withIntermediateDirectories: true)
        try! Data(#"{"auth":{"type":"\#(authType)"}}"#.utf8).write(to: acp.appendingPathComponent("settings.json"))
        return acp
    }

    static func main() {
        let fresh = json(AntigravityACPToken.blob(
            existing: nil, client: client, accessToken: "ya29.synthetic-a", refreshToken: "1//synthetic-a", expiry: expiry
        ))
        precondition(fresh["client_id"] as? String == client.id)
        precondition(fresh["client_secret"] as? String == client.secret)
        precondition(fresh["refresh_token"] as? String == "1//synthetic-a")
        precondition(fresh["token"] as? String == "ya29.synthetic-a")
        precondition(fresh["token_uri"] as? String == "https://oauth2.googleapis.com/token")
        precondition(fresh["scopes"] as? [String] == AntigravityACPToken.scopes)
        precondition(fresh["expiry"] as? String == "2027-01-15T08:00:00Z", "UTC, second precision, Z suffix")

        let serverWritten = try! JSONSerialization.data(withJSONObject: [
            "client_id": client.id, "client_secret": client.secret, "refresh_token": "1//synthetic-a",
            "token_uri": "https://oauth2.googleapis.com/token", "scopes": AntigravityACPToken.scopes,
            "project_id": "synthetic-project",
        ])
        let renewed = json(AntigravityACPToken.blob(
            existing: serverWritten, client: client, accessToken: "ya29.synthetic-a2", refreshToken: "1//synthetic-a", expiry: expiry
        ))
        precondition(renewed["project_id"] as? String == "synthetic-project", "renewal keeps the server's project")
        precondition(renewed["token"] as? String == "ya29.synthetic-a2")

        let switched = json(AntigravityACPToken.blob(
            existing: serverWritten, client: client, accessToken: "ya29.synthetic-b", refreshToken: "1//synthetic-b", expiry: expiry
        ))
        precondition(switched["project_id"] == nil, "another login must not inherit the previous project")
        precondition(switched["refresh_token"] as? String == "1//synthetic-b")

        let snap = AntigravityACPToken.snapshot(of: serverWritten)!
        precondition(snap.refreshToken == "1//synthetic-a" && snap.accessToken == nil && snap.expiry == nil)
        let full = AntigravityACPToken.snapshot(of: try! JSONSerialization.data(withJSONObject: [
            "refresh_token": "1//r", "token": "ya29.t", "expiry": "2027-01-15T08:00:00.123456",
        ]))!
        precondition(full.expiry == expiry, "naive google-auth expiry is UTC")
        precondition(AntigravityACPToken.snapshot(of: Data(#"{"token":"x"}"#.utf8)) == nil)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("acp-spec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let personal = makeProfile(home, base: "userdata", instance: "aaaa", authType: "oauth-personal")
        let dev = makeProfile(home, base: "dev", instance: "bbbb", authType: "oauth-personal")
        let business = makeProfile(home, base: "userdata", instance: "cccc", authType: "oauth-business")
        let real = { (url: URL) in url.resolvingSymlinksInPath().path }
        precondition(AntigravityACPToken.profiles(home: home).map(real) == [dev, personal].map(real).sorted())

        precondition(AntigravityACPToken.apply(
            client: client, accessToken: "ya29.x", refreshToken: nil, expiry: expiry, home: home
        ) == .missingRefreshToken)
        precondition(AntigravityACPToken.apply(
            client: client, accessToken: "ya29.x", refreshToken: "1//x", expiry: expiry,
            home: home.appendingPathComponent("empty")
        ) == .noProfiles)

        try! serverWritten.write(to: AntigravityACPToken.tokenURL(in: personal))
        let result = AntigravityACPToken.apply(
            client: client, accessToken: "ya29.synthetic-b", refreshToken: "1//synthetic-b", expiry: expiry, home: home
        )
        precondition(result == .updated(2))
        for profile in [personal, dev] {
            let url = AntigravityACPToken.tokenURL(in: profile)
            precondition(AntigravityACPToken.snapshot(at: profile)?.refreshToken == "1//synthetic-b")
            let mode = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
            precondition(mode == 0o600, "token file must be owner-only")
        }
        precondition(!FileManager.default.fileExists(atPath: AntigravityACPToken.tokenURL(in: business).path),
                     "non-personal profiles are left alone")
        let backup = AntigravityACPToken.tokenURL(in: personal).appendingPathExtension("viberouter-bak")
        precondition(AntigravityACPToken.snapshot(of: try! Data(contentsOf: backup))?.refreshToken == "1//synthetic-a")
        let leftovers = try! FileManager.default.contentsOfDirectory(atPath: personal.path).filter { $0.hasSuffix(".tmp") }
        precondition(leftovers.isEmpty, "no temp files left behind")

        if let i = CommandLine.arguments.firstIndex(of: "--emit"), i + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("acp_token.json")
            try! AntigravityACPToken.blob(
                existing: nil, client: client, accessToken: "ya29.synthetic", refreshToken: "1//synthetic",
                expiry: Date().addingTimeInterval(3600)
            )!.write(to: out)
        }
        print("AntigravityACPTokenSpec: all checks passed")
    }
}
