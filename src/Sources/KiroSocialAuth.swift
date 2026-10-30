import AppKit
import Foundation

/// Google/GitHub use Kiro's social OAuth flow, independently of AWS Builder ID.
enum KiroSocialAuth {
    static let baseURL = "https://prod.us-east-1.auth.desktop.kiro.dev"

    static func addAccount(provider: String,
                           opensBrowser: Bool = true,
                           onAuthURL: ((String) -> Void)? = nil,
                           authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")) async -> ConfiguredAccountImportResult {
        guard ["Google", "Github"].contains(provider) else { return .failure(message: "Unsupported Kiro sign-in provider.") }
        let (authorization, status) = await KiroAWSAuth.postJSONStatus(
            url: baseURL + "/oauth/device/authorization", body: ["clientId": "kiro-cli", "loginProvider": provider])
        guard status == 200, let authorization,
              let code = authorization["deviceCode"] as? String,
              let verification = authorization["verificationUriComplete"] as? String,
              let url = URL(string: verification), url.scheme == "https", url.host == "app.kiro.dev" else {
            return .failure(message: "Could not start Kiro \(provider) login (HTTP \(status)). Try again.")
        }
        await MainActor.run {
            if opensBrowser {
                if let userCode = authorization["userCode"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                }
                NSWorkspace.shared.open(url)
            }
            onAuthURL?(url.absoluteString)
        }
        let timeout = (authorization["expiresInMilliseconds"] as? Double ?? 300_000) / 1000
        let deadline = Date().addingTimeInterval(timeout)
        var delay = max(1, (authorization["intervalInMilliseconds"] as? Double ?? 5_000) / 1000)
        do {
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let (json, status) = await KiroAWSAuth.postJSONStatus(
                    url: baseURL + "/oauth/device/poll", body: ["clientId": "kiro-cli", "deviceCode": code])
                guard let json else { throw KiroAWSAuth.LoginError.message("Kiro sign-in could not connect. Try again.") }
                switch pollState(json, status: status) {
                case "authorization_pending": continue
                case "slow_down": delay += 5; continue
                case "success":
                    var record = try authRecord(json, provider: provider)
                    record.merge(await NativeUsageFetcher.kiroAccountMetadata(payload: record)) { _, verified in verified }
                    try AccountCredentialStore.save(record, in: authDirectory)
                    NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
                    return .success(message: "Kiro \(provider) account saved" + (KiroAccountIdentity.email(record).map { ": \($0)" } ?? "."))
                default: throw KiroAWSAuth.LoginError.message("Kiro \(provider) sign-in was denied or expired. Try again.")
                }
            }
            return .failure(message: "Kiro \(provider) sign-in timed out. Try Add Account again.")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    static func pollState(_ json: [String: Any], status: Int) -> String {
        let progress = json["error"] as? String ?? json["status"] as? String
        if progress == "authorization_pending" || progress == "slow_down" { return progress! }
        if (200...299).contains(status), json["error"] == nil,
           AccountCredentialIdentity.value(json, ["accessToken", "access_token"]) != nil { return "success" }
        return "failure"
    }

    static func authRecord(_ json: [String: Any], provider: String, now: Date = Date()) throws -> [String: Any] {
        guard let access = AccountCredentialIdentity.value(json, ["accessToken", "access_token"]),
              let refresh = AccountCredentialIdentity.value(json, ["refreshToken", "refresh_token"]) else {
            throw KiroAWSAuth.LoginError.message("Kiro did not return a complete account session. Try signing in again.")
        }
        let expires = now.addingTimeInterval(json["expiresIn"] as? Double ?? 3600)
        var record: [String: Any] = [
            "type": "kiro", "auth_method": "social", "provider": provider, "region": "us-east-1",
            "access_token": access, "refresh_token": refresh,
            "expires_at": ISO8601DateFormatter().string(from: expires),
            "last_refresh": ISO8601DateFormatter().string(from: now), "disabled": false
        ]
        record["profile_arn"] = AccountCredentialIdentity.value(json, ["profileArn", "profile_arn"])
        record["id_token"] = AccountCredentialIdentity.value(json, ["idToken", "id_token"])
        record["email"] = KiroAccountIdentity.email(record) ?? KiroAccountIdentity.email(json)
        return record
    }
}
