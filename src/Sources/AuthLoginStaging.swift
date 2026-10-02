import Foundation
import Yams

/// Give each bundled CLI OAuth attempt a private auth directory. Its filename
/// conventions cannot overwrite live credentials before account identity is known.
struct AuthLoginStaging {
    let rootDirectory: URL
    let authDirectory: URL
    let configURL: URL
    let targetDirectory: URL

    init(configPath: String, targetDirectory: URL) throws {
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        guard var config = try Yams.load(yaml: text) as? [String: Any] else {
            throw StagingError.invalidConfig
        }
        self.targetDirectory = targetDirectory
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("viberouter-login-\(UUID().uuidString)")
        authDirectory = rootDirectory.appendingPathComponent("auth")
        configURL = rootDirectory.appendingPathComponent("config.yaml")
        do {
            try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
            config["auth-dir"] = authDirectory.path
            try Yams.dump(object: config).write(to: configURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            try? FileManager.default.removeItem(at: rootDirectory)
            throw error
        }
    }

    func importAccounts() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var saved: [URL] = []
        for file in files {
            guard let record = NativeUsageFetcher.readAuthPayload(at: file) else { throw StagingError.invalidCredentials }
            saved.append(try AccountCredentialStore.save(record, in: targetDirectory))
        }
        AuthAccountLifecycle.clearTombstonesForPresentCodexSeats(authDirectory: targetDirectory)
        return saved
    }

    func cleanup() { try? FileManager.default.removeItem(at: rootDirectory) }

    enum StagingError: LocalizedError {
        case invalidConfig, invalidCredentials
        var errorDescription: String? {
            switch self {
            case .invalidConfig: return "Could not prepare the OAuth login configuration."
            case .invalidCredentials: return "The login did not save valid account credentials."
            }
        }
    }
}
