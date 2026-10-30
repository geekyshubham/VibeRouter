import Foundation
import SQLite3
@testable import CLIProxyMenuBar

enum KiroAccountSessionSpec {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-session-spec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = home.appendingPathComponent("auth")
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let social: [String: Any] = [
            "type": "kiro", "auth_method": "social", "provider": "Google", "email": "paid@example.com",
            "access_token": "google-access", "refresh_token": "google-refresh", "expires_at": expiry,
            "profile_arn": "arn:aws:codewhisperer:us-east-1:123:profile/paid",
            "kiro_cli_profile": ["arn": "arn:aws:codewhisperer:us-east-1:123:profile/paid", "profile_name": "Paid"]
        ]
        try KiroCLISession.apply(social, home: home)
        let liveSocial = KiroCLISession.currentPayload(home: home)!
        var database: OpaquePointer?
        check(sqlite3_open(KiroCLISession.databaseURL(home: home).path, &database) == SQLITE_OK,
              "native Kiro database can be opened")
        var statement: OpaquePointer?
        check(sqlite3_prepare_v2(database, "SELECT typeof(value) FROM auth_kv LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              "native credential storage type can be inspected")
        check(sqlite3_step(statement) == SQLITE_ROW && String(cString: sqlite3_column_text(statement, 0)) == "text",
              "native Kiro reader requires JSON text, not SQLite blobs")
        sqlite3_finalize(statement)
        sqlite3_close(database)
        check(KiroAccountIdentity.email(liveSocial) == "paid@example.com", "Google email survives native switch")
        check(KiroAccountIdentity.sameAccount(liveSocial, social), "active Google session matches selected account")
        check(liveSocial["profile_arn"] as? String == social["profile_arn"] as? String, "paid profile stays with its token")
        check(KiroCLISession.payload(forKey: KiroCLISession.oidcKey, home: home) == nil,
              "Google switch clears the AWS token slot")
        if case .failure(let message) = ConfiguredAccountImporter.importKiroCLI(home: home, authDirectory: auth) {
            preconditionFailure(message)
        }
        let firstFiles = try FileManager.default.contentsOfDirectory(atPath: auth.path)
        check(firstFiles.count == 1, "CLI import saves an account")

        let aws: [String: Any] = ["type": "kiro", "auth_method": "idc", "email": "free@example.com",
            "access_token": "aws-access", "refresh_token": "aws-refresh", "expired": expiry,
            "client_id": "client", "client_secret": "secret", "client_secret_expires_at": expiry,
            "oauth_flow": "PKCE", "scopes": ["codewhisperer:completions"], "region": "us-east-1"]
        try KiroCLISession.apply(aws, home: home)
        let liveAWS = KiroCLISession.currentPayload(home: home)!
        check(KiroCLISession.payload(forKey: KiroCLISession.socialKey, home: home) == nil,
              "AWS switch clears the social token slot")
        check(liveAWS["profile_arn"] == nil, "AWS switch cannot inherit Google's profile")
        check(liveAWS["kiro_cli_profile"] == nil, "AWS switch clears the previous profile state")
        check(liveAWS["client_id"] as? String == "client", "OIDC registration is restored")
        check(liveAWS["client_secret"] as? String == "secret", "OIDC secret stays with selected login")
        check(liveAWS["oauth_flow"] as? String == "PKCE", "OIDC flow is preserved")
        check(liveAWS["scopes"] as? [String] == ["codewhisperer:completions"], "OIDC scopes are preserved")
        check(!KiroAccountIdentity.sameAccount(liveAWS, social), "unrelated Google and AWS accounts stay separate")
        var sameEmailAWS = aws
        sameEmailAWS["email"] = "paid@example.com"
        check(!KiroAccountIdentity.sameAccount(sameEmailAWS, social),
              "same Gmail under AWS and Google cannot mark both subscriptions active")
        if case .failure(let message) = ConfiguredAccountImporter.importKiroCLI(home: home, authDirectory: auth) {
            preconditionFailure(message)
        }
        let allFiles = try FileManager.default.contentsOfDirectory(atPath: auth.path)
        check(allFiles.count == 2, "switch preserves both imported accounts")
        try KiroCLISession.apply(social, home: home)
        let restored = KiroCLISession.currentPayload(home: home)!
        check(restored["access_token"] as? String == "google-access", "switching back restores Google's token")
        check(restored["client_id"] == nil, "social session cannot inherit the AWS registration")

        var broken = aws
        broken.removeValue(forKey: "client_secret")
        do {
            try KiroCLISession.apply(broken, home: home)
            preconditionFailure("incomplete AWS registration must fail")
        } catch {
            check(KiroCLISession.currentPayload(home: home)?["access_token"] as? String == "google-access",
                  "failed switch leaves the previous login intact")
        }
        var importedSocial = social
        importedSocial["client_id"] = "unrelated-application"
        importedSocial["client_secret"] = "unrelated-registration"
        check(!KiroAWSAuth.isAWSSession(importedSocial), "social imports always use social refresh")
        check(KiroSocialAuth.pollState(["status": "authorization_pending"], status: 200) == "authorization_pending",
              "HTTP 200 pending is not a successful login")
        check(KiroSocialAuth.pollState(["error": "slow_down"], status: 400) == "slow_down", "poll respects throttling")
        check(KiroSocialAuth.pollState([:], status: 200) == "failure", "empty poll cannot save credentials")
        let login = try KiroSocialAuth.authRecord(["accessToken": "social", "refreshToken": "refresh", "expiresIn": 3600,
            "profileArn": "paid-profile", "email": "paid@example.com"], provider: "Google")
        check(KiroAccountIdentity.email(login) == "paid@example.com", "social login keeps its reported email")
        check(login["profile_arn"] as? String == "paid-profile", "social login keeps its reported profile")
        check(!KiroAWSAuth.isAWSSession(login), "Google login must never use AWS OIDC refresh")

        let usage = NativeUsageFetcher.parseKiroLimits([
            "subscriptionInfo": ["subscriptionTitle": "KIRO PRO+"],
            "userInfo": ["email": "paid@example.com", "userId": "paid-user"],
            "usageBreakdownList": [["resourceType": "CREDIT", "currentUsageWithPrecision": 12.25,
                "usageLimitWithPrecision": 10_000.0]]
        ])
        check(usage.email == "paid@example.com", "GetUsageLimits email reaches account display")
        check(usage.planName == "KIRO PRO+", "vendor subscription title is preserved")
        check(usage.windows.first?.totalValue == 10_000, "10,000 credit allowance reaches the card")
        check(usage.windows.first?.remainingValue == 9_987.75, "fractional used credits are retained")
        let unknown = NativeUsageFetcher.KiroAPIUsage(planName: "KIRO PRO+", reportedPlan: "KIRO PRO+",
            totalUsed: 0, windows: [], userID: nil)
        check(!NativeUsageFetcher.kiroSameAccount(unknown, unknown), "a plan tier cannot merge anonymous accounts")
        let cli = KiroCLIUsageProbe.parse(output: "Estimated Usage | resets on 2026-11-01 | KIRO PRO+\nCredits (12.25 of 10,000 covered in plan)")
        check(cli?.planName == "KIRO PRO+", "CLI plan parser retains the plus sign")
        check(KiroCLIUsageProbe.parseEmail(output: "Logged in with Google\nEmail: paid@example.com") == "paid@example.com",
              "whoami email parser identifies the current Google account")
        check(NativeSessionManager.switchableProviderIDs.contains("kiro"), "Kiro exposes native switch controls")
        let authorize = "https://accounts.google.com/o/oauth2/v2/auth?state=original&redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Fcallback&code_challenge=a_b-c"
        check(ServerManager.extractAuthURL(from: "Visit the following URL:\n" + authorize + "\nWaiting...") == authorize,
              "Copy Link keeps the original authorize URL and encoded query intact")
        check(ServerManager.extractAuthURL(from: "Visit:\n" + authorize) == nil,
              "Copy Link waits for a complete output line before copying")
        check(ServerManager.extractAuthURL(from: "Visit:\nhttps://\nhttp://localhost/callback\nnot a link\n") == nil,
              "Copy Link rejects invalid links and local callback addresses")
        for command: AuthCommand in [.codexLogin, .claudeLogin, .geminiLogin, .antigravityLogin, .xaiLogin, .kimiLogin,
                                     .kiroLogin, .kiroGoogleLogin, .kiroGitHubLogin] {
            check(command.supportsCopyLink, "browser OAuth providers expose Copy Link")
        }
        check(!AuthCommand.cursorLogin.supportsCopyLink && !AuthCommand.copilotLogin.supportsCopyLink,
              "session imports do not offer a nonexistent sign-in link")
        let kiroSource = try String(contentsOfFile: "src/Sources/KiroCLISession.swift", encoding: .utf8)
        check(!kiroSource.contains("Process()") && !kiroSource.contains("SecItem") && !kiroSource.contains("import Security"),
              "Kiro refresh and switch cannot launch Keychain password prompts")
        return checks
    }
}
