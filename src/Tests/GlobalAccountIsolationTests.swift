import XCTest
@testable import CLIProxyMenuBar

final class GlobalAccountIsolationTests: XCTestCase {
    private var oauthProviders: [ServiceType] { ServiceType.allCases.filter { $0 != .zai && $0 != .opencodeGo } }

    func testEveryOAuthProviderPreservesUnidentifiedAccountsAndReimports() throws {
        for provider in oauthProviders {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let a = credentials(provider.rawValue, member: "a", email: "\(provider.rawValue)-account")
            let b = credentials(provider.rawValue, member: "b", email: "\(provider.rawValue)-account")
            try importRecord(a, provider: provider, directory: directory)
            try importRecord(b, provider: provider, directory: directory)
            try importRecord(a, provider: provider, directory: directory)
            let files = try authFiles(directory)
            XCTAssertEqual(files.count, 2, "\(provider.rawValue) must preserve two anonymous logins")
            let records = files.compactMap { NativeUsageFetcher.readAuthPayload(at: $0) }
            XCTAssertEqual(Set(records.compactMap { $0["access_token"] as? String }), ["access-a", "access-b"])
            let identities = files.map { AuthManager.identityKey(for: account($0, provider: provider)) }
            XCTAssertEqual(Set(identities).count, 2, "\(provider.rawValue) must show both accounts")
        }
    }

    func testEveryOAuthProviderKeepsDifferentScopesForOneEmail() throws {
        for provider in oauthProviders {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            for member in ["a", "b"] {
                var record = credentials(provider.rawValue, member: member, email: "same@example.test")
                record["workspace_id"] = "workspace-\(member)"
                try importRecord(record, provider: provider, directory: directory)
            }
            let files = try authFiles(directory)
            XCTAssertEqual(files.count, 2, "\(provider.rawValue) must preserve distinct workspaces")
            XCTAssertEqual(Set(files.map { AuthManager.identityKey(for: account($0, provider: provider)) }).count, 2)
        }
    }

    func testEveryProviderRejectsRefreshPropagationToAnotherUser() throws {
        // Also cover a provider that has no special Swift onboarding implementation.
        for kind in oauthProviders.map(\.rawValue) + ["future-provider"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var a = credentials(kind, member: "a", email: "a@example.test")
            var b = credentials(kind, member: "b", email: "b@example.test")
            a["refresh_token"] = "shared-old"
            b["refresh_token"] = "shared-old"
            let fileA = try AccountCredentialStore.save(a, in: directory)
            let fileB = try AccountCredentialStore.save(b, in: directory)
            let bytesB = try Data(contentsOf: fileB)
            a["refresh_token"] = "new-a"
            a["access_token"] = "new-access-a"
            XCTAssertEqual(TokenRefreshService.propagateRotatedTokens(oldRefresh: "shared-old", updated: a, authDirectory: directory), 1)
            XCTAssertEqual(try Data(contentsOf: fileB), bytesB, "\(kind) must not replace the other login")
            XCTAssertEqual(NativeUsageFetcher.readAuthPayload(at: fileA)?["refresh_token"] as? String, "new-a")
        }
    }

    func testSameLabelCannotMergeDifferentUserIDs() throws {
        for provider in oauthProviders {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            for member in ["a", "b"] {
                var record = credentials(provider.rawValue, member: member, email: "shared-label")
                record["user_id"] = member
                record["username"] = "same-display-name"
                try importRecord(record, provider: provider, directory: directory)
            }
            XCTAssertEqual(try authFiles(directory).count, 2, "\(provider.rawValue) must honor the user identity")
        }
    }

    func testAnonymousLocalSessionsCannotReplaceClaudeOrGrokAccounts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in [ServiceType.claude, .grok] {
            var original = credentials(provider.rawValue, member: "a")
            original["expired"] = "2020-01-01T00:00:00Z"
            var native = credentials(provider.rawValue, member: "b")
            native["expired"] = "2099-01-01T00:00:00Z"
            let file = try AccountCredentialStore.save(original, in: directory)
            let before = try Data(contentsOf: file)
            if provider == .claude {
                XCTAssertFalse(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: native))
                XCTAssertTrue(TokenRefreshService.shouldNetworkRefreshClaude(payload: original, native: native))
            } else {
                XCTAssertFalse(NativeUsageFetcher.overlayGrokCLICredentialsIfFresher(onto: file, localGrok: native))
                let candidates = NativeUsageFetcher.grokBillingTokenCandidates(accountPayload: original, localGrok: native)
                XCTAssertEqual(candidates.map(\.source), ["auth-file"])
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testAPIKeysWithIdenticalLabelsAndSuffixesStaySeparate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zai = ZAIAPIKeyStore(directoryURL: directory)
        let keyA = "different-a-123456", keyB = "different-b-123456"
        let a = try zai.save(apiKey: keyA)
        let b = try zai.save(apiKey: keyB)
        XCTAssertFalse(a == b)
        XCTAssertEqual(try zai.save(apiKey: keyA).standardizedFileURL.path, a.standardizedFileURL.path)
        XCTAssertFalse(AuthManager.identityKey(for: account(a, provider: .zai)) == AuthManager.identityKey(for: account(b, provider: .zai)))

        let custom = CustomProviderCredentialStore(directoryURL: directory)
        _ = try custom.save(providerID: "opencode-go", apiKey: keyA, label: "same label")
        _ = try custom.save(providerID: "opencode-go", apiKey: keyB, label: "same label")
        _ = try custom.save(providerID: "another-provider", apiKey: keyA, label: "same label")
        let records = custom.loadAll().records
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map { AccountCredentialIdentity.key(NativeUsageFetcher.readAuthPayload(at: $0.filePath)!) }).count, 3)
    }

    func testUnexpectedFilenameCollisionPreservesExistingBytesAndPermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incoming = credentials("claude", member: "a", email: "a@example.test")
        let collision = directory.appendingPathComponent(AccountCredentialIdentity.filename(incoming))
        try write(credentials("claude", member: "b", email: "b@example.test"), to: collision)
        let original = try Data(contentsOf: collision)
        let saved = try AccountCredentialStore.save(incoming, in: directory)
        XCTAssertFalse(saved == collision)
        XCTAssertEqual(try Data(contentsOf: collision), original)
        let permissions = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testOAuthStagingProtectsLiveAccountsFromIdenticalProviderFilenames() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("source.yaml")
        try "port: 8317\nauth-dir: old-directory\n".write(to: config, atomically: true, encoding: .utf8)
        let live = directory.appendingPathComponent("live")
        for member in ["a", "b"] {
            let staging = try AuthLoginStaging(configPath: config.path, targetDirectory: live)
            defer { staging.cleanup() }
            let stagedConfig = try String(contentsOf: staging.configURL, encoding: .utf8)
            XCTAssertTrue(stagedConfig.contains(staging.authDirectory.path))
            try write(credentials("claude", member: member), to: staging.authDirectory.appendingPathComponent("claude-account.json"))
            XCTAssertEqual(try staging.importAccounts().count, 1)
        }
        let records = try authFiles(live).compactMap { NativeUsageFetcher.readAuthPayload(at: $0) }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["access_token"] as? String }), ["access-a", "access-b"])
    }

    func testRemovingAnAccountDeletesOnlyItsVerifiedSiblings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("claude-first.json")
        let sibling = directory.appendingPathComponent("claude-sibling.json")
        let other = directory.appendingPathComponent("claude-other.json")
        try write(credentials("claude", member: "a", email: "a@example.test"), to: first)
        try write(credentials("claude", member: "a", email: "a@example.test"), to: sibling)
        try write(credentials("claude", member: "b", email: "b@example.test"), to: other)
        let before = try Data(contentsOf: other)
        let result = AuthAccountLifecycle.deleteAccountCompletely(account(first, provider: .claude), authDirectory: directory)
        XCTAssertEqual(Set(result.deleted.map(\.lastPathComponent)), ["claude-first.json", "claude-sibling.json"])
        XCTAssertEqual(try Data(contentsOf: other), before)
    }

    func testAnonymousAccountIdentitySurvivesTokenRotation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = credentials("qwen", member: "a")
        let file = try AccountCredentialStore.save(record, in: directory)
        let before = AuthManager.identityKey(for: account(file, provider: .qwen))
        var updated = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        updated["access_token"] = "rotated-access"
        updated["refresh_token"] = "rotated-refresh"
        try write(updated, to: file)
        XCTAssertEqual(AuthManager.identityKey(for: account(file, provider: .qwen)), before)
    }

    func testMissingIdentityCannotMarkEveryAccountAsTheActiveNativeLogin() throws {
        for provider in oauthProviders {
            XCTAssertFalse(NativeSessionManager.matchesSession(accountType: provider, accountEmail: "",
                accountSeatID: "shared-workspace", identity: NativeSessionIdentity(email: "", accountID: "shared-workspace", plan: nil)))
        }
    }

    func testGenericImportLabelsCannotHideAnotherSessionOrWorkspace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try AccountCredentialStore.save(credentials("claude", member: "a", email: "claude-account"), in: directory)
        let discovered = DiscoveredConfiguredAccount(id: "claude-new", serviceType: .claude,
            displayName: "claude-account", sourceAppName: "Claude Code", importKind: .claudeCode)
        XCTAssertFalse(ConfiguredAccountDiscovery.isAlreadyConnected(discovered, existingAccounts: [account(file, provider: .claude)], home: directory))
        var scoped = credentials("gemini", member: "a", email: "same@example.test")
        scoped["project_id"] = "first-project"
        let projectFile = try AccountCredentialStore.save(scoped, in: directory)
        let otherProject = DiscoveredConfiguredAccount(id: "gemini-new", serviceType: .gemini,
            displayName: "same@example.test", sourceAppName: "Gemini CLI", importKind: .geminiCLI)
        XCTAssertFalse(ConfiguredAccountDiscovery.isAlreadyConnected(otherProject,
            existingAccounts: [account(projectFile, provider: .gemini)], home: directory))
    }

    func testCredentialWritesCannotChangeTheAccountOrProviderOfAnExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in oauthProviders {
            let file = try AccountCredentialStore.save(credentials(provider.rawValue, member: "a", email: "a@example.test"), in: directory)
            let before = try Data(contentsOf: file)
            XCTAssertFalse(NativeUsageFetcher.writeAuthPayload(credentials(provider.rawValue, member: "b", email: "b@example.test"), to: file))
            XCTAssertFalse(NativeUsageFetcher.writeAuthPayload(credentials("another-provider", member: "a", email: "a@example.test"), to: file))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testCodexMembersWithoutEmailsStayIndependentInOneWorkspace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for member in ["a", "b"] {
            let claims: [String: Any] = ["exp": 4_000_000_000,
                "https://api.openai.com/auth": ["chatgpt_account_id": "shared-team", "chatgpt_user_id": member]]
            let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            var record = credentials("codex", member: member)
            record["access_token"] = "e30.\(body).sig"
            record["account_id"] = "shared-team"
            try importRecord(record, provider: .codex, directory: directory)
            var corrupted = record
            corrupted["account_id"] = "wrong-team"
            XCTAssertFalse(AccountCredentialIdentity.isConsistent(corrupted))
        }
        let files = try authFiles(directory)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map { AuthManager.identityKey(for: account($0, provider: .codex)) }).count, 2)
    }

    private func credentials(_ kind: String, member: String, email: String = "") -> [String: Any] {
        ["type": kind, "email": email, "access_token": "access-\(member)", "refresh_token": "rt-\(member)"]
    }

    func testWorkspaceClaimsInsideTokensCannotMoveAnAccountToAnotherWorkspace() throws {
        for provider in oauthProviders {
            func token(_ workspace: String) throws -> String {
                let claims: [String: Any] = ["email": "same@example.test", "sub": "same-user", "workspace_id": workspace]
                let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "e30.\(body).sig"
            }
            var original = credentials(provider.rawValue, member: "a", email: "same@example.test")
            original["access_token"] = try token("original-workspace")
            var moved = original
            moved["access_token"] = try token("another-workspace")
            XCTAssertFalse(AccountCredentialIdentity.sameAccount(original, moved))
            XCTAssertFalse(TokenRefreshService.canCopyTokens(from: moved, onto: original))
            moved["workspace_id"] = "original-workspace"
            XCTAssertFalse(AccountCredentialIdentity.isConsistent(moved))
        }
    }

    func testNativeAccountMetadataRequiresMatchingCredentialLineage() throws {
        let source = credentials("claude", member: "a")
        let own = credentials("claude", member: "a", email: "a@example.test")
        let other = credentials("claude", member: "b", email: "b@example.test")
        XCTAssertEqual(AccountCredentialIdentity.email(source, matchingNative: own), "a@example.test")
        XCTAssertNil(AccountCredentialIdentity.email(source, matchingNative: other))
        XCTAssertNil(AccountCredentialIdentity.email(source, matchingNative: nil))
    }

    func testCopilotFriendlyLabelsCannotReplaceOrHideDifferentLogins() throws {
        for mode in ["login", "id", "anonymous"] {
            let home = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let sourceDirectory = home.appendingPathComponent(".config/github-copilot")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let entries: [[String: Any]] = ["a", "b"].enumerated().map { index, member in
                var identity: [String: Any] = ["label": "Shared friendly name"]
                if mode == "login" { identity["login"] = "login-\(member)" }
                if mode != "anonymous" { identity["id"] = index + 100 }
                return ["accessToken": "access-\(member)", "account": identity]
            }
            try write(["https://github.com/login/oauth": entries], to: sourceDirectory.appendingPathComponent("oauth.json"))
            let discovered = ConfiguredAccountDiscovery.discoverCopilot(home: home)
            XCTAssertEqual(discovered.count, 2)
            XCTAssertEqual(Set(discovered.map(\.id)).count, 2)
            let selected = try XCTUnwrap(discovered.last)
            let directory = home.appendingPathComponent("auth")
            guard case .success = ConfiguredAccountImporter.importCopilotApp(authDirectory: directory,
                displayName: selected.displayName, preferredIdentity: String(selected.id.dropFirst("copilot-".count)), home: home) else {
                return XCTFail("Copilot import failed for \(mode)")
            }
            let files = try authFiles(directory)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(NativeUsageFetcher.readAuthPayload(at: files[0])?["access_token"] as? String, "access-b")
            XCTAssertTrue(ConfiguredAccountDiscovery.isAlreadyConnected(selected, existingAccounts: [account(files[0], provider: .copilot)], home: home))
            XCTAssertFalse(ConfiguredAccountDiscovery.isAlreadyConnected(discovered[0], existingAccounts: [account(files[0], provider: .copilot)], home: home))
            for entry in entries {
                try importRecord(entry, provider: .copilot, directory: directory)
            }
            XCTAssertEqual(try authFiles(directory).count, 2)
        }
    }

    private func account(_ file: URL, provider: ServiceType) -> AuthAccount {
        AuthAccount(id: file.lastPathComponent, email: nil, login: nil, type: provider,
                    expired: nil, filePath: file, isDisabled: false)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("global-account-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func write(_ record: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }
    private func importRecord(_ record: [String: Any], provider: ServiceType, directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: record)
        guard case .success = ManualTokenImporter.importPasted(String(decoding: data, as: UTF8.self), preferredType: provider, authDirectory: directory) else {
            return XCTFail("\(provider.rawValue) import failed")
        }
    }
    private func authFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }
}
