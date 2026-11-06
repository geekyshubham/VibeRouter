import CryptoKit
import Foundation

/// Logins that live in VibeRouter instance folders.
///
/// Each one is a separate copy of the official client holding its own copy of an
/// account's OAuth tokens. OpenAI and Anthropic rotate refresh tokens, so an
/// instance and VibeRouter must never both renew one login from stale copies.
/// VibeRouter treats every instance home the way it treats the main client's:
/// it adopts newer tokens from it, writes rotated tokens into it, and leaves a
/// Claude login to the instance whose Claude Code holds it.
enum InstanceSessions {
    // MARK: Codex

    /// `CODEX_HOME` of every Codex instance that holds a login.
    static func codexHomes(_ instances: [ManagedAppInstance] = AppInstanceManager.load()) -> [URL] {
        instances.filter { $0.serviceType == .codex && !$0.userDataDir.isEmpty }
            .map { URL(fileURLWithPath: $0.userDataDir) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("auth.json").path) }
    }

    static func codexPayload(home: URL) -> [String: Any]? {
        NativeUsageFetcher.readCodexAppPayload(at: home.appendingPathComponent("auth.json"))
    }

    // MARK: Claude Code

    /// A `CLAUDE_CONFIG_DIR` used by a Claude Code instance.
    struct ClaudeHome: Equatable {
        let configDir: URL

        /// Claude Code names its Keychain item after the config dir string it was given.
        var keychainService: String { InstanceSessions.claudeKeychainService(configDir: configDir.path) }
        var credentialsURL: URL { configDir.appendingPathComponent(".credentials.json") }
        var accountURL: URL { configDir.appendingPathComponent(".claude.json") }
    }

    enum ClaudeSession {
        case signedIn([String: Any])
        case signedOut
        /// The Keychain refused the read; the login is unknown, not absent.
        case unreadable
    }

    struct ClaudeOwnership {
        let home: ClaudeHome
        /// Nil when the Keychain could not be read but `.claude.json` names the account.
        let session: [String: Any]?
    }

    /// Same rule Claude Code uses: `Claude Code-credentials-` + the first 8 hex
    /// digits of SHA-256 over the NFC config dir path.
    static func claudeKeychainService(configDir: String) -> String {
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// Config dirs of Claude Code instances (the desktop app keeps no Claude Code login).
    static func claudeHomes(_ instances: [ManagedAppInstance] = AppInstanceManager.load()) -> [ClaudeHome] {
        var homes: [ClaudeHome] = []
        for instance in instances where instance.serviceType == .claude && !instance.userDataDir.isEmpty {
            guard AppInstanceManager.surface(of: instance) == .terminal else { continue }
            homes.append(ClaudeHome(configDir: URL(fileURLWithPath: instance.userDataDir)))
        }
        return homes
    }

    static func claudeSession(home: ClaudeHome, waitingUpTo wait: TimeInterval = 0.5, fresh: Bool = false) -> ClaudeSession {
        let keychain = NativeKeychain.read(service: home.keychainService, waitingUpTo: wait, fresh: fresh)
        guard keychain.status == errSecSuccess || keychain.status == errSecItemNotFound else { return .unreadable }
        guard var payload = NativeUsageFetcher.claudeAppPayload(
            keychain: keychain.status == errSecSuccess ? keychain.data : nil,
            file: try? Data(contentsOf: home.credentialsURL)
        ) else { return .signedOut }
        if (payload["email"] as? String)?.isEmpty != false,
           let email = NativeUsageFetcher.claudeCodeAccount(home: home.configDir)?["email"] {
            payload["email"] = email
        }
        return .signedIn(payload)
    }

    /// The instance whose Claude Code is signed into `account`, if any.
    static func claudeOwner(
        of account: [String: Any],
        homes: [ClaudeHome]? = nil,
        session: (ClaudeHome) -> ClaudeSession = { InstanceSessions.claudeSession(home: $0) }
    ) -> ClaudeOwnership? {
        guard (account["type"] as? String).map({ $0.lowercased() == "claude" }) ?? true else { return nil }
        for home in homes ?? claudeHomes() {
            switch session(home) {
            case .signedIn(let payload):
                if AccountCredentialIdentity.sameAccount(account, payload) {
                    return ClaudeOwnership(home: home, session: payload)
                }
            case .unreadable:
                // Only an unreadable Keychain falls back to the account file: a
                // home with no login must not keep an account parked forever.
                if let owner = NativeUsageFetcher.claudeCodeAccount(home: home.configDir),
                   AccountCredentialIdentity.sameAccount(account, owner) {
                    return ClaudeOwnership(home: home, session: nil)
                }
            case .signedOut:
                continue
            }
        }
        return nil
    }

    /// Copy an instance's newest login back onto the matching VibeRouter files,
    /// with its refresh token parked until ownership is re-evaluated. Run before
    /// the instance's login is replaced or the instance is deleted, so the
    /// newest rotated token is never lost.
    @discardableResult
    static func reclaimClaudeSession(_ session: [String: Any], authDirectory: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: nil),
              TokenRefreshService.refreshToken(from: session) != nil else { return 0 }
        var wrote = 0
        for file in files where file.pathExtension == "json" {
            guard var payload = NativeUsageFetcher.readAuthPayload(at: file),
                  (payload["type"] as? String)?.lowercased() == "claude",
                  AccountCredentialIdentity.sameAccount(payload, session) else { continue }
            payload = TokenRefreshService.flattenedAuth(payload)
            // Never trade a newer VibeRouter copy for an older instance login.
            if NativeUsageFetcher.shouldAdoptClaudeCLITokens(local: session, file: payload) {
                payload = TokenRefreshService.copyTokenFields(from: session, onto: payload)
            } else if payload["access_token"] as? String != session["access_token"] as? String {
                continue
            }
            TokenRefreshService.parkRefreshToken(TokenRefreshService.refreshToken(from: session), in: &payload)
            if NativeUsageFetcher.writeAuthPayload(payload, to: file) { wrote += 1 }
        }
        return wrote
    }
}
