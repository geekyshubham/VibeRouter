import Foundation

/// Tombstones + multi-file seat deletion so Settings remove/add stay honest.
///
/// Bugs this prevents:
/// 1. Remove deletes one `codex-*.json` while materialize / sibling files resurrect the seat
/// 2. OAuth re-login looks like a "no-op" because the new file is collapsed with an old seat
/// 3. Cockpit auto-materialize fights explicit user deletes
enum AuthAccountLifecycle {
    private static let tombstoneFileName = ".viberouter-deleted-seats.json"
    private static let legacyTombstoneFileName = ".vibeproxy-deleted-seats.json"
    private static let tombstoneKey = "seats"

    // MARK: - Public API

    /// Delete every auth file that belongs to the same ChatGPT login + workspace as `account`.
    /// For Codex: files matching both `chatgpt_account_id` and email (or chatgpt_user_id).
    /// Team members share a workspace id — matching on that alone would delete every other
    /// Team login on this Mac.
    /// For others: the single file path (email-keyed).
    /// Records a tombstone so background materialize cannot revive that login.
    @discardableResult
    static func deleteAccountCompletely(
        _ account: AuthAccount,
        authDirectory: URL? = nil
    ) -> (deleted: [URL], failed: [URL]) {
        let dir = authDirectory ?? defaultAuthDirectory()
        let targets = filesToDelete(for: account, in: dir)
        var deleted: [URL] = []
        var failed: [URL] = []

        for url in targets {
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(url)
                NSLog("[AuthLifecycle] Deleted %@", url.lastPathComponent)
            } catch {
                failed.append(url)
                NSLog(
                    "[AuthLifecycle] Failed to delete %@: %@",
                    url.lastPathComponent,
                    error.localizedDescription
                )
            }
        }

        if let seatKey = seatKey(for: account) {
            addTombstone(seatKey, authDirectory: dir)
        }

        return (deleted, failed)
    }

    /// Seat key used for tombstones / multi-file matching.
    /// Codex: `codex:<email>|<account_id>` so two Team members on the same org
    /// are not treated as one seat (they share `chatgpt_account_id`).
    static func seatKey(for account: AuthAccount) -> String? {
        if account.type == .codex {
            let identity = codexIdentity(in: account.filePath)
            if let id = identity.accountID {
                return seatKey(accountID: id, email: identity.email ?? account.email)
            }
            // Filename `codex-seat-{uuid}.json`
            let name = account.filePath.deletingPathExtension().lastPathComponent.lowercased()
            if name.hasPrefix("codex-seat-") {
                let id = String(name.dropFirst("codex-seat-".count))
                if !id.isEmpty {
                    return seatKey(accountID: id, email: account.email ?? identity.email)
                }
            }
            return nil
        }
        if let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return "\(account.type.rawValue):email:\(email.lowercased())"
        }
        return "\(account.type.rawValue):file:\(account.id.lowercased())"
    }

    static func isTombstoned(_ seatKey: String, authDirectory: URL? = nil) -> Bool {
        loadTombstones(authDirectory: authDirectory).contains(seatKey.lowercased())
    }

    static func seatKey(accountID: String, email: String?) -> String {
        let id = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !email.isEmpty
        {
            return "codex:\(email)|\(id)"
        }
        return "codex:" + id
    }

    static func clearTombstone(forAccountID accountID: String, email: String? = nil, authDirectory: URL? = nil) {
        let dir = authDirectory ?? defaultAuthDirectory()
        removeTombstone(seatKey(accountID: accountID, email: email), authDirectory: dir)
        // Legacy unscoped key from older builds (`codex:<account_id>`).
        removeTombstone("codex:" + accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), authDirectory: dir)
    }

    static func clearTombstone(seatKey: String, authDirectory: URL? = nil) {
        removeTombstone(seatKey.lowercased(), authDirectory: authDirectory)
    }

    /// After OAuth, clear tombstones for any codex seats present in `authDirectory`.
    static func clearTombstonesForPresentCodexSeats(authDirectory: URL? = nil) {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            guard file.lastPathComponent.lowercased().hasPrefix("codex-") else { continue }
            let identity = codexIdentity(in: file)
            guard let id = identity.accountID else { continue }
            clearTombstone(forAccountID: id, email: identity.email, authDirectory: dir)
        }
    }

    /// Snapshot of auth files (path + mtime) for detecting post-OAuth writes.
    static func authFileSnapshot(authDirectory: URL? = nil) -> [String: Date] {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var snap: [String: Date] = [:]
        for file in files where file.pathExtension == "json" {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            snap[file.lastPathComponent] = mtime
        }
        return snap
    }

    /// Files added or updated after `before`.
    static func authFilesChanged(
        since before: [String: Date],
        authDirectory: URL? = nil
    ) -> [URL] {
        let dir = authDirectory ?? defaultAuthDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var changed: [URL] = []
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let old = before[name] {
                if mtime > old.addingTimeInterval(0.5) {
                    changed.append(file)
                }
            } else {
                changed.append(file)
            }
        }
        return changed.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Matching files

    static func filesToDelete(for account: AuthAccount, in authDirectory: URL) -> [URL] {
        // Always include the visible row's file.
        var urls: [URL] = [account.filePath]

        if account.type != .codex,
           let target = NativeUsageFetcher.readAuthPayload(at: account.filePath),
           let files = try? FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
                guard let other = NativeUsageFetcher.readAuthPayload(at: file),
                      AccountCredentialIdentity.provider(target) == AccountCredentialIdentity.provider(other),
                      AccountCredentialIdentity.sameAccount(target, other) else { continue }
                urls.append(file)
            }
        }

        if account.type == .codex {
            let target = codexIdentity(in: account.filePath)
            let targetID = target.accountID
            let targetEmail = (target.email ?? account.email)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let targetUser = target.userID

            if let files = try? FileManager.default.contentsOfDirectory(
                at: authDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for file in files where file.pathExtension == "json" {
                    let name = file.lastPathComponent.lowercased()
                    guard name.hasPrefix("codex-") else { continue }
                    let other = codexIdentity(in: file)
                    if isSameCodexLogin(
                        targetID: targetID,
                        targetEmail: targetEmail,
                        targetUser: targetUser,
                        file: file,
                        fileIdentity: other
                    ) {
                        urls.append(file)
                    }
                }
            }
        }

        // Deduplicate by path.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// True when `file` is a duplicate auth file for the same ChatGPT login + workspace.
    /// Workspace id (`chatgpt_account_id`) is shared by every member of a Team org —
    /// matching on that alone would delete every other Team login on this Mac.
    static func isSameCodexLogin(
        targetID: String?,
        targetEmail: String?,
        targetUser: String?,
        file: URL,
        fileIdentity: CodexFileIdentity
    ) -> Bool {
        let fileID = fileIdentity.accountID
        let fileEmail = fileIdentity.email?.lowercased()
        let fileUser = fileIdentity.userID
        let seatName: String? = {
            guard let targetID, !targetID.isEmpty else { return nil }
            return "codex-seat-\(targetID.lowercased()).json"
        }()

        let sameWorkspace: Bool = {
            if let targetID, let fileID {
                return targetID.caseInsensitiveCompare(fileID) == .orderedSame
            }
            if let seatName, file.lastPathComponent.lowercased() == seatName {
                return true
            }
            return false
        }()
        guard sameWorkspace else { return false }

        if let targetEmail, !targetEmail.isEmpty, let fileEmail, !fileEmail.isEmpty {
            return targetEmail == fileEmail
        }
        if let targetUser, !targetUser.isEmpty, let fileUser, !fileUser.isEmpty {
            return targetUser.caseInsensitiveCompare(fileUser) == .orderedSame
        }
        // Seat clone with no email of its own: only delete if it belongs to this login.
        if let seatName, file.lastPathComponent.lowercased() == seatName {
            if let fileEmail, let targetEmail, !targetEmail.isEmpty {
                return fileEmail == targetEmail
            }
        }
        return false
    }

    struct CodexFileIdentity {
        var accountID: String?
        var email: String?
        var userID: String?
    }

    static func codexIdentity(in file: URL) -> CodexFileIdentity {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CodexFileIdentity() }

        let access = json["access_token"] as? String
        let idToken = json["id_token"] as? String
        let accountID = CodexWorkspaceCredentials.chatgptAccountID(from: access)
            ?? CodexWorkspaceCredentials.chatgptAccountID(from: idToken)
            ?? {
                let stored = (json["account_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (stored?.isEmpty == false) ? stored : nil
            }()
        let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty == false) ? email : (
            JWTEmailExtractor.email(from: idToken) ?? JWTEmailExtractor.email(from: access)
        )
        let userID = CodexWorkspaceCredentials.chatgptUserID(from: access)
            ?? CodexWorkspaceCredentials.chatgptUserID(from: idToken)
        return CodexFileIdentity(accountID: accountID, email: resolvedEmail, userID: userID)
    }

    static func codexAccountID(in file: URL) -> String? {
        codexIdentity(in: file).accountID
    }

    // MARK: - Tombstones

    static func loadTombstones(authDirectory: URL? = nil) -> Set<String> {
        let directory = authDirectory ?? defaultAuthDirectory()
        migrateLegacyTombstoneFile(in: directory)
        let url = directory.appendingPathComponent(tombstoneFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seats = json[tombstoneKey] as? [String]
        else { return [] }
        return Set(seats.map { $0.lowercased() })
    }

    /// Pre-rename builds wrote `.vibeproxy-deleted-seats.json`. Without this the
    /// list reads as empty and every previously deleted seat reappears.
    private static func migrateLegacyTombstoneFile(in directory: URL) {
        let current = directory.appendingPathComponent(tombstoneFileName)
        let legacy = directory.appendingPathComponent(legacyTombstoneFileName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }

    private static func addTombstone(_ key: String, authDirectory: URL) {
        var seats = loadTombstones(authDirectory: authDirectory)
        seats.insert(key.lowercased())
        saveTombstones(seats, authDirectory: authDirectory)
    }

    private static func removeTombstone(_ key: String, authDirectory: URL? = nil) {
        let dir = authDirectory ?? defaultAuthDirectory()
        var seats = loadTombstones(authDirectory: dir)
        if seats.remove(key.lowercased()) != nil {
            saveTombstones(seats, authDirectory: dir)
        }
    }

    private static func saveTombstones(_ seats: Set<String>, authDirectory: URL) {
        let url = authDirectory.appendingPathComponent(tombstoneFileName)
        let payload: [String: Any] = [
            tombstoneKey: seats.sorted(),
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func defaultAuthDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    }
}
