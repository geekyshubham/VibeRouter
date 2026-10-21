import CryptoKit
import Foundation

/// Kiro runs outside CLIProxyAPI's auth manager, so it needs its own account
/// cooldowns. Only enabled Kiro credentials participate; the model never changes.
actor KiroAccountPool {
    static let shared = KiroAccountPool()

    struct Candidate {
        let token: String
        let credential: KiroDirectProvider.Credential
        let identity: String
        let tokenDigest: String
        let region: String
        let profileArn: String?

        init(token: String, credential: KiroDirectProvider.Credential,
             refreshToken: String? = nil, region: String = "us-east-1", profileArn: String? = nil) {
            self.token = token
            self.credential = credential
            self.tokenDigest = Self.digest(token)
            self.identity = Self.digest(refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? token)
            self.region = region
            self.profileArn = profileArn
        }

        private static func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct Failure {
        let until: Date
        let status: Int
        let message: String
    }
    private var failures: [String: Failure] = [:]
    private var preferred: [String: String] = [:]

    private func key(_ candidate: Candidate, model: String) -> String {
        candidate.identity + ":" + model
    }

    func select(_ candidates: [Candidate], model: String, excluding: Set<String>, now: Date = Date()) -> Candidate? {
        failures = failures.filter { $0.value.until > now }
        var seen = Set<String>()
        var identities = Set<String>()
        let available = candidates.filter {
            !excluding.contains($0.identity) && seen.insert($0.tokenDigest).inserted && identities.insert($0.identity).inserted
                && failures[key($0, model: "*")] == nil && failures[key($0, model: model)] == nil
        }
        return available.first { $0.identity == preferred[model] } ?? available.first
    }

    func succeeded(_ candidate: Candidate, model: String) {
        preferred[model] = candidate.identity
        failures.removeValue(forKey: key(candidate, model: model))
    }

    /// Returns false for request-shape errors: another account cannot fix them.
    @discardableResult
    func failed(_ candidate: Candidate, model: String, status: Int, message: String, now: Date = Date()) -> Bool {
        let upper = message.uppercased()
        let modelDenied = upper.contains("INVALID_MODEL_ID") || upper.contains("MODEL_NOT_SUPPORTED")
        let monthly = upper.contains("MONTHLY_REQUEST_COUNT") || upper.contains("MONTHLY REQUEST LIMIT")
        let seconds: TimeInterval
        let scope: String
        if modelDenied {
            seconds = 12 * 3600; scope = model
        } else if monthly || [401, 402, 403].contains(status) {
            // Recheck within thirty minutes so a top-up/plan upgrade can recover.
            seconds = 30 * 60; scope = "*"
        } else if status == 429 {
            seconds = 60; scope = model
        } else if [408, 500, 502, 503, 504].contains(status) {
            seconds = 60; scope = model
        } else {
            return false
        }
        failures[key(candidate, model: scope)] = Failure(until: now.addingTimeInterval(seconds), status: status, message: message)
        return true
    }

    func unavailable(_ candidates: [Candidate], model: String, now: Date = Date()) -> KiroDirectProvider.CallResult {
        let failure = candidates.compactMap {
            failures[key($0, model: "*")] ?? failures[key($0, model: model)]
        }.filter { $0.until > now }.min { $0.until < $1.until }
        guard let failure else {
            return .failure(status: 401, message: "No usable enabled Kiro credentials. Add or sign in to a Kiro account in VibeRouter.")
        }
        return .failure(status: failure.status, message: "All available Kiro accounts were tried or are cooling down for \(model). Last error: \(failure.message)")
    }
}
