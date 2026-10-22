import Foundation

/// Credentials for the CLIProxyAPI Management UI (`/management.html`).
///
/// CLIProxyAPI disables all `/v0/management/*` routes when `remote-management.secret-key`
/// is empty (HTTP 404: "Management API not found").
enum ManagementCredentials {
    /// The globally-known default key shipped in this (public) repo. A network-
    /// exposed management API must never be protected by only this value.
    static let defaultSecretKey = "viberouter-admin"

    /// Per-user management key injected into merged-config.yaml, shared by the app and the CLI.
    /// Enter this in the management.html login field (Authorization: Bearer …).
    static let secretKey = loadOrCreateSecretKey()

    static var secretKeyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
            .appendingPathComponent("management-key.txt")
    }

    private static func loadOrCreateSecretKey() -> String {
        let url = secretKeyFileURL
        if let stored = storedSecretKey(at: url) {
            return stored
        }
        let key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for _ in 0..<2 {
            // O_EXCL so the app and the CLI starting together agree on one key.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                let data = Array((key + "\n").utf8)
                let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                if written != data.count {
                    try? FileManager.default.removeItem(at: url)
                }
                return key
            }
            if let stored = storedSecretKey(at: url) {
                return stored
            }
            try? FileManager.default.removeItem(at: url)
        }
        NSLog("[ManagementCredentials] Could not persist the management key; using a session-only key")
        return key
    }

    private static func storedSecretKey(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 32, key != defaultSecretKey else { return nil }
        return key
    }

    /// Backend that serves management.html and /v0/management/* (CLIProxyAPI process).
    static let backendPort = 8318

    static var managementHTMLURL: URL {
        URL(string: "http://127.0.0.1:\(backendPort)/management.html")!
    }

    static var backendBaseURL: String {
        "http://127.0.0.1:\(backendPort)"
    }
}
