import CryptoKit
import Foundation

/// OAuth client registrations identify an application, not the person signed in.
/// Anonymous Kiro sessions stay separate unless their token lineage matches.
enum KiroAccountIdentity {
    static func key(_ payload: [String: Any]) -> String? {
        if let user = value(payload, ["user_id", "userId"]) { return "user:" + user }
        if let email = email(payload) { return "email:" + email.lowercased() }
        if let profile = value(payload, ["profile_arn", "profileArn"]) { return "profile:" + profile }
        return nil
    }

    static func email(_ payload: [String: Any]) -> String? {
        let candidate = JWTEmailExtractor.email(from: value(payload, ["access_token", "accessToken"]))
            ?? JWTEmailExtractor.email(from: value(payload, ["id_token", "idToken"]))
            ?? value(payload, ["email", "username"])
        // Older imports wrote "kiro-account" into every unidentified session.
        return candidate.flatMap { $0.contains("@") ? $0 : nil }
    }

    static func sameAccount(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        // A Gmail can own separate Google and AWS Builder ID subscriptions.
        if value(a, ["auth_method", "authMethod"]) != nil,
           value(b, ["auth_method", "authMethod"]) != nil,
           KiroAWSAuth.isAWSSession(a) != KiroAWSAuth.isAWSSession(b) { return false }
        let providers: Set<String> = ["google", "github", "aws", "builderid"]
        if let left = value(a, ["provider"])?.lowercased(),
           let right = value(b, ["provider"])?.lowercased(),
           providers.contains(left), providers.contains(right) {
            let normalizedLeft = left == "builderid" ? "aws" : left
            let normalizedRight = right == "builderid" ? "aws" : right
            if normalizedLeft != normalizedRight { return false }
        }
        var matchedIdentity = false
        for keys in [["user_id", "userId"], ["profile_arn", "profileArn"]] {
            if let left = value(a, keys), let right = value(b, keys) {
                guard left == right else { return false }
                matchedIdentity = true
            }
        }
        if let left = email(a), let right = email(b) {
            guard left.caseInsensitiveCompare(right) == .orderedSame else { return false }
            matchedIdentity = true
        }
        if matchedIdentity { return true }
        for keys in [["refresh_token", "refreshToken"], ["access_token", "accessToken"]] {
            if let left = value(a, keys), let right = value(b, keys), left == right { return true }
        }
        return false
    }

    static func filename(_ payload: [String: Any]) -> String {
        let identity = key(payload)
            ?? value(payload, ["refresh_token", "refreshToken", "access_token", "accessToken"])
            ?? UUID().uuidString
        return "kiro-account-\(digest(identity)).json"
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func value(_ payload: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
