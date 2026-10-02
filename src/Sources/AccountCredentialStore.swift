import Foundation

/// Every onboarding path saves through this store, including the bundled OAuth
/// binary. Re-authentication may update a verified match; another login gets its
/// own file regardless of the filename or label supplied by the source app.
enum AccountCredentialStore {
    private static let lock = NSRecursiveLock()

    @discardableResult
    static func save(_ record: [String: Any], in directory: URL, overwrite: Bool = true) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard AccountCredentialIdentity.provider(record) != nil,
              AccountCredentialIdentity.isConsistent(record) else {
            throw StoreError.invalidIdentity
        }
        let flat = AccountCredentialIdentity.flattened(record)
        guard AccountCredentialIdentity.access(flat) != nil
            || AccountCredentialIdentity.value(flat, ["api_key", "apiKey", "refresh_token", "refreshToken"]) != nil else {
            throw StoreError.missingCredentials
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let canonical = directory.appendingPathComponent(AccountCredentialIdentity.filename(record))
        let matches = files.filter { file in
            guard let stored = NativeUsageFetcher.readAuthPayload(at: file),
                  AccountCredentialIdentity.provider(stored) == AccountCredentialIdentity.provider(record) else { return false }
            return AccountCredentialIdentity.sameAccount(stored, record)
        }
        var destination = matches.first(where: { $0 == canonical }) ?? matches.first ?? canonical
        if !overwrite, !matches.isEmpty { throw StoreError.alreadyExists }
        // Even an unexpected filename collision must never overwrite another account.
        while FileManager.default.fileExists(atPath: destination.path) && !matches.contains(destination) {
            let prefix = (record["type"] as? String ?? "account").replacingOccurrences(of: "/", with: "_")
            destination = directory.appendingPathComponent("\(prefix)-account-\(UUID().uuidString).json")
        }
        var output = NativeUsageFetcher.readAuthPayload(at: destination) ?? [:]
        let existingKey = output["viberouter_account_key"] as? String
        output.merge(record) { _, incoming in incoming }
        var incomingIdentity = record
        incomingIdentity.removeValue(forKey: "viberouter_account_key")
        output["viberouter_account_key"] = existingKey ?? AccountCredentialIdentity.key(incomingIdentity)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.standardizedFileURL
    }

    enum StoreError: LocalizedError {
        case invalidIdentity, alreadyExists, missingCredentials
        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "Account identity does not match its credentials. Import this login's own credentials."
            case .alreadyExists: return "This account is already imported."
            case .missingCredentials: return "The login did not provide account credentials."
            }
        }
    }
}
