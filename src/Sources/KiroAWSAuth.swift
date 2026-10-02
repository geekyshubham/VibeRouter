import AppKit
import CryptoKit
import Foundation

/// AWS Builder ID / IAM Identity Center device-code login for Kiro.
/// Social `kiro.dev` refresh cannot revive these sessions — they need OIDC `/token`.
enum KiroAWSAuth {
    static let defaultRegion = "us-east-1"
    static let builderIDStartURL = "https://view.awsapps.com/start"
    static let scopes = [
        "codewhisperer:completions",
        "codewhisperer:analysis",
        "codewhisperer:conversations",
        "codewhisperer:transformations",
        "codewhisperer:taskassist",
    ]

    static func isAWSSession(_ payload: [String: Any]) -> Bool {
        let method = (stringValue(payload, keys: ["auth_method", "authMethod"]) ?? "").lowercased()
        let provider = (stringValue(payload, keys: ["provider"]) ?? "").lowercased()
        let hasOIDC = stringValue(payload, keys: ["client_id", "clientId"]) != nil
            && stringValue(payload, keys: ["client_secret", "clientSecret"]) != nil
        return hasOIDC
            || method == "idc"
            || provider == "aws"
            || provider == "builderid"
    }

    static func addAccount(
        region: String = defaultRegion,
        authDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
    ) async -> ConfiguredAccountImportResult {
        do {
            let session = try await startDeviceLogin(region: region)
            if let url = URL(string: session.verificationURL) {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.userCode, forType: .string)
                    NSWorkspace.shared.open(url)
                }
            }
            let tokens = try await poll(session)
            let record = authRecord(from: tokens, session: session)
            return write(record, authDirectory: authDirectory)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    static func refresh(_ payload: [String: Any]) async -> [String: Any]? {
        guard isAWSSession(payload),
              let refresh = stringValue(payload, keys: ["refresh_token", "refreshToken"]),
              let clientID = stringValue(payload, keys: ["client_id", "clientId"]),
              let clientSecret = stringValue(payload, keys: ["client_secret", "clientSecret"])
        else { return nil }
        let region = stringValue(payload, keys: ["region"]) ?? defaultRegion
        let body: [String: Any] = [
            "clientId": clientID,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refresh,
        ]
        guard let json = await postJSON(url: oidcBase(region) + "/token", body: body),
              let access = stringValue(json, keys: ["accessToken", "access_token"])
        else { return nil }
        var updated = payload
        updated["access_token"] = access
        updated["accessToken"] = access
        if let newRefresh = stringValue(json, keys: ["refreshToken", "refresh_token"]) {
            updated["refresh_token"] = newRefresh
            updated["refreshToken"] = newRefresh
        }
        let expiresIn = (json["expiresIn"] as? Int)
            ?? (json["expires_in"] as? Int)
            ?? 3600
        let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
        updated["expires_in"] = expiresIn
        updated["expired"] = isoString(exp)
        updated["expires_at"] = isoString(exp)
        updated["last_refresh"] = isoString(Date())
        updated["auth_method"] = stringValue(payload, keys: ["auth_method", "authMethod"]) ?? "idc"
        updated["provider"] = stringValue(payload, keys: ["provider"]) ?? "AWS"
        return updated
    }

    static func oidcBase(_ region: String) -> String {
        "https://oidc.\(region).amazonaws.com"
    }

    static func clientIDHash(_ clientID: String) -> String {
        Insecure.SHA1.hash(data: Data(clientID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func filename(clientID: String) -> String {
        let safe = clientID.replacingOccurrences(of: "/", with: "_")
        return "kiro-builderid-\(safe).json"
    }

    // MARK: - Device login

    struct DeviceSession {
        let clientID: String
        let clientSecret: String
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let interval: TimeInterval
        let expiresAt: Date
        let region: String
    }

    struct Tokens {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    static func startDeviceLogin(region: String) async throws -> DeviceSession {
        let oidc = oidcBase(region)
        let registerBody: [String: Any] = [
            "clientName": "Kiro",
            "clientType": "public",
            "scopes": scopes,
            "grantTypes": [
                "urn:ietf:params:oauth:grant-type:device_code",
                "refresh_token",
            ],
            "issuerUrl": builderIDStartURL,
        ]
        guard let registered = await postJSON(url: oidc + "/client/register", body: registerBody),
              let clientID = stringValue(registered, keys: ["clientId", "client_id"]),
              let clientSecret = stringValue(registered, keys: ["clientSecret", "client_secret"])
        else {
            throw LoginError.message("Could not register a Kiro AWS login client. Check your network and try again.")
        }

        let authBody: [String: Any] = [
            "clientId": clientID,
            "clientSecret": clientSecret,
            "startUrl": builderIDStartURL,
        ]
        guard let authorized = await postJSON(url: oidc + "/device_authorization", body: authBody),
              let deviceCode = stringValue(authorized, keys: ["deviceCode", "device_code"]),
              let userCode = stringValue(authorized, keys: ["userCode", "user_code"])
        else {
            throw LoginError.message("Could not start Kiro AWS device login.")
        }

        let verification = stringValue(authorized, keys: ["verificationUriComplete", "verification_uri_complete"])
            ?? stringValue(authorized, keys: ["verificationUri", "verification_uri"])
            ?? builderIDStartURL
        let interval = (authorized["interval"] as? Int) ?? (authorized["interval"] as? Double).map { Int($0) } ?? 5
        let expiresIn = (authorized["expiresIn"] as? Int) ?? (authorized["expires_in"] as? Int) ?? 600
        return DeviceSession(
            clientID: clientID,
            clientSecret: clientSecret,
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verification,
            interval: TimeInterval(max(5, interval)),
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            region: region
        )
    }

    static func poll(_ session: DeviceSession) async throws -> Tokens {
        let url = oidcBase(session.region) + "/token"
        let body: [String: Any] = [
            "clientId": session.clientID,
            "clientSecret": session.clientSecret,
            "grantType": "urn:ietf:params:oauth:grant-type:device_code",
            "deviceCode": session.deviceCode,
        ]
        var delay = session.interval
        while Date() < session.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let (json, status) = await postJSONStatus(url: url, body: body)
            if status == 200, let json,
               let access = stringValue(json, keys: ["accessToken", "access_token"])
            {
                let refresh = stringValue(json, keys: ["refreshToken", "refresh_token"]) ?? ""
                let expiresIn = (json["expiresIn"] as? Int) ?? (json["expires_in"] as? Int) ?? 3600
                return Tokens(accessToken: access, refreshToken: refresh, expiresIn: expiresIn)
            }
            let err = (json?["error"] as? String ?? "").lowercased()
            if err == "authorization_pending" { continue }
            if err == "slow_down" {
                delay += 5
                continue
            }
            if err == "expired_token" {
                throw LoginError.message("Kiro AWS login timed out. Try Add Account again.")
            }
            if err == "access_denied" {
                throw LoginError.message("Kiro AWS login was denied in the browser.")
            }
            if status == 400 { continue }
            throw LoginError.message("Kiro AWS login failed (HTTP \(status)).")
        }
        throw LoginError.message("Kiro AWS login timed out. Try Add Account again.")
    }

    static func authRecord(from tokens: Tokens, session: DeviceSession, now: Date = Date()) -> [String: Any] {
        let exp = now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        return [
            "type": "kiro",
            "auth_method": "idc",
            "provider": "AWS",
            "region": session.region,
            "start_url": builderIDStartURL,
            "client_id": session.clientID,
            "client_secret": session.clientSecret,
            "client_id_hash": clientIDHash(session.clientID),
            "access_token": tokens.accessToken,
            "accessToken": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "refreshToken": tokens.refreshToken,
            "expires_in": tokens.expiresIn,
            "expired": isoString(exp),
            "expires_at": isoString(exp),
            "last_refresh": isoString(now),
            "email": "",
            "profile_arn": "",
            "disabled": false,
        ]
    }

    // MARK: - IO

    private static func write(_ record: [String: Any], authDirectory: URL) -> ConfiguredAccountImportResult {
        guard stringValue(record, keys: ["client_id"]) != nil else {
            return .failure(message: "Kiro AWS login did not return a client id")
        }
        do {
            try AccountCredentialStore.save(record, in: authDirectory)
            NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
            return .success(message: "✓ Kiro AWS account saved. Signed in via Builder ID in the browser.")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private static func postJSON(url: String, body: [String: Any]) async -> [String: Any]? {
        let (json, status) = await postJSONStatus(url: url, body: body)
        guard (200...299).contains(status) else { return nil }
        return json
    }

    private static func postJSONStatus(url: String, body: [String: Any]) async -> ([String: Any]?, Int) {
        guard let endpoint = URL(string: url),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return (nil, -1) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            return (json, status)
        } catch {
            return (nil, -1)
        }
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    enum LoginError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }
}
