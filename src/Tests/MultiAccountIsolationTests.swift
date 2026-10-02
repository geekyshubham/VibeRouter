import XCTest
@testable import CLIProxyMenuBar

final class MultiAccountIsolationTests: XCTestCase {
    func testCodexImportsPreserveTwoWorkspacesForOneEmailAndReimportUpdatesOnlyOne() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let email = "isolated@example.test"
        let first = codex(email: email, workspace: "personal", refresh: "personal-rt")
        let second = codex(email: email, workspace: "team", refresh: "team-rt")
        try importRecord(first, as: .codex, into: directory)
        try importRecord(second, as: .codex, into: directory)
        var records = try authRecords(directory)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["refresh_token"] as? String }), ["personal-rt", "team-rt"])

        try importRecord(codex(email: email, workspace: "personal", refresh: "new-personal-rt"), as: .codex, into: directory)
        records = try authRecords(directory)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["refresh_token"] as? String }), ["new-personal-rt", "team-rt"])
    }

    func testCodexImportsPreserveTeamMembersAndAnonymousSessions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try importRecord(codex(email: "a@example.test", workspace: "team", refresh: "rt-a"), as: .codex, into: directory)
        try importRecord(codex(email: "b@example.test", workspace: "team", refresh: "rt-b"), as: .codex, into: directory)
        for member in ["c", "d"] {
            try importRecord(["type": "codex", "access_token": "opaque-\(member)", "refresh_token": "rt-\(member)"], as: .codex, into: directory)
        }
        XCTAssertEqual(try authRecords(directory).count, 4)
    }

    func testKiroImportsPreserveAnonymousAccountsSharingClientRegistration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for member in ["a", "b"] {
            try importRecord(kiro(member), as: .kiro, into: directory)
        }
        try importRecord(kiro("a"), as: .kiro, into: directory)
        let records = try authRecords(directory)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["refresh_token"] as? String }), ["rt-a", "rt-b"])
        XCTAssertEqual(Set(records.compactMap { $0["client_id"] as? String }), ["shared-client"])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let keys = files.filter { $0.pathExtension == "json" }.map { file in
            AuthManager.identityKey(for: AuthAccount(id: file.lastPathComponent,
                email: "kiro-account", login: nil, type: .kiro, expired: nil, filePath: file, isDisabled: false))
        }
        XCTAssertEqual(Set(keys).count, 2, "Legacy placeholder emails must not collapse separate Kiro rows")
    }

    func testKiroSocialImportsPreserveTwoProfilesAndCamelCaseIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for member in ["a", "b"] {
            try importRecord(["accessToken": "access-\(member)", "refreshToken": "rt-\(member)",
                              "profileArn": "profile-\(member)"], as: .kiro, into: directory)
        }
        let records = try authRecords(directory)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["profile_arn"] as? String }), ["profile-a", "profile-b"])
    }

    func testKiroIDEImportDoesNotOverwriteAnotherLoginWithSameClientHash() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var original = kiro("a")
        original["email"] = "kiro-account"
        original["expires_at"] = "2026-01-01T00:00:00Z"
        let originalFile = directory.appendingPathComponent("kiro-builderid-shared-client.json")
        try write(original, to: originalFile)
        let originalBytes = try Data(contentsOf: originalFile)
        try writeIDECache(kiro("b"), home: home)

        guard case .success = ConfiguredAccountImporter.importKiroIDE(home: home, authDirectory: directory) else {
            return XCTFail("IDE import failed")
        }
        XCTAssertEqual(try Data(contentsOf: originalFile), originalBytes)
        let records = try authRecords(directory)
        XCTAssertEqual(records.count, 2)
        let imported = try XCTUnwrap(records.first { $0["refresh_token"] as? String == "rt-b" })
        XCTAssertEqual(imported["client_id"] as? String, "shared-client")
        XCTAssertEqual(imported["client_secret"] as? String, "shared-secret")
        XCTAssertEqual(imported["email"] as? String, "")
    }

    func testKiroIDEImportUpdatesMatchingRefreshLineageOnly() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var original = kiro("a")
        original["expires_at"] = "2026-01-01T00:00:00Z"
        let file = directory.appendingPathComponent("kiro-a.json")
        try write(original, to: file)
        var cache = kiro("a")
        cache["access_token"] = "new-access-a"
        try writeIDECache(cache, home: home)
        guard case .success = ConfiguredAccountImporter.importKiroIDE(home: home, authDirectory: directory) else {
            return XCTFail("IDE import failed")
        }
        XCTAssertEqual(try authRecords(directory).count, 1)
        XCTAssertEqual(NativeUsageFetcher.readAuthPayload(at: file)?["access_token"] as? String, "new-access-a")
    }

    func testCodexCLIOverlayRejectsDifferentMemberOfSameTeam() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("codex-a.json")
        let original = codex(email: "a@example.test", workspace: "team", refresh: "rt-a", expiry: 1)
        let local = codex(email: "b@example.test", workspace: "team", refresh: "rt-b")
        try write(original, to: file)
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(onto: file, localCodex: local))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        var mislabeled = original
        mislabeled["access_token"] = local["access_token"]
        XCTAssertFalse(TokenRefreshService.sameCodexSeat(mislabeled, as: local))
    }

    func testRefreshPropagationCannotReplaceDifferentMemberOrProvider() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = codex(email: "a@example.test", workspace: "team", refresh: "shared-rt")
        let other = codex(email: "b@example.test", workspace: "team", refresh: "shared-rt")
        var kiroRecord = kiro("c")
        kiroRecord["refresh_token"] = "shared-rt"
        let a = directory.appendingPathComponent("codex-a.json")
        let b = directory.appendingPathComponent("codex-b.json")
        let c = directory.appendingPathComponent("kiro-c.json")
        try write(original, to: a)
        try write(other, to: b)
        try write(kiroRecord, to: c)
        let bBytes = try Data(contentsOf: b)
        let cBytes = try Data(contentsOf: c)
        let updated = codex(email: "a@example.test", workspace: "team", refresh: "new-rt")
        XCTAssertEqual(TokenRefreshService.propagateRotatedTokens(oldRefresh: "shared-rt", updated: updated, authDirectory: directory), 1)
        XCTAssertEqual(try Data(contentsOf: b), bBytes)
        XCTAssertEqual(try Data(contentsOf: c), cBytes)
        XCTAssertEqual(NativeUsageFetcher.readAuthPayload(at: a)?["refresh_token"] as? String, "new-rt")
    }

    func testImportDiscoveryKeepsNewKiroLoginAndCodexWorkspaceAvailable() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let storedKiro = home.appendingPathComponent("kiro-a.json")
        try write(kiro("a"), to: storedKiro)
        let kiroAccount = AuthAccount(id: "kiro-a", email: nil, login: nil, type: .kiro,
                                     expired: nil, filePath: storedKiro, isDisabled: false)
        let kiroDiscovered = DiscoveredConfiguredAccount(id: "kiro-ide", serviceType: .kiro,
            displayName: "Kiro IDE session", sourceAppName: "Kiro IDE", importKind: .kiroIDE)
        try writeIDECache(kiro("b"), home: home)
        XCTAssertFalse(ConfiguredAccountDiscovery.isAlreadyConnected(kiroDiscovered,
            existingAccounts: [kiroAccount], home: home))
        try writeIDECache(kiro("a"), home: home)
        XCTAssertEqual(ConfiguredAccountDiscovery.isAlreadyConnected(kiroDiscovered,
            existingAccounts: [kiroAccount], home: home), true)

        let storedCodex = home.appendingPathComponent("codex-personal.json")
        let personal = codex(email: "person@example.test", workspace: "personal", refresh: "rt-personal")
        let team = codex(email: "person@example.test", workspace: "team", refresh: "rt-team")
        try write(personal, to: storedCodex)
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let local = codexDirectory.appendingPathComponent("auth.json")
        try write(["tokens": team], to: local)
        let codexAccount = AuthAccount(id: "codex-personal", email: "person@example.test", login: nil,
            type: .codex, expired: nil, filePath: storedCodex, isDisabled: false)
        let codexDiscovered = DiscoveredConfiguredAccount(id: "codex-app", serviceType: .codex,
            displayName: "person@example.test", sourceAppName: "Codex app", importKind: .codexApp)
        XCTAssertFalse(ConfiguredAccountDiscovery.isAlreadyConnected(codexDiscovered,
            existingAccounts: [codexAccount], home: home))
        try write(["tokens": personal], to: local)
        XCTAssertEqual(ConfiguredAccountDiscovery.isAlreadyConnected(codexDiscovered,
            existingAccounts: [codexAccount], home: home), true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("account-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func codex(email: String, workspace: String, refresh: String, expiry: TimeInterval = 4_000_000_000) -> [String: Any] {
        let claims: [String: Any] = ["email": email, "exp": expiry,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspace, "chatgpt_user_id": email]]
        let body = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ["type": "codex", "email": email, "access_token": "e30.\(body).sig",
                "refresh_token": refresh, "account_id": workspace]
    }

    private func kiro(_ member: String) -> [String: Any] {
        ["type": "kiro", "access_token": "access-\(member)", "refresh_token": "rt-\(member)",
         "client_id": "shared-client", "client_secret": "shared-secret",
         "client_id_hash": KiroAWSAuth.clientIDHash("shared-client")]
    }

    private func write(_ record: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }

    private func writeIDECache(_ record: [String: Any], home: URL) throws {
        let directory = home.appendingPathComponent(".aws/sso/cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache: [String: Any] = ["accessToken": record["access_token"]!, "refreshToken": record["refresh_token"]!,
            "clientIdHash": record["client_id_hash"]!, "expiresAt": "2030-01-01T00:00:00Z"]
        try write(cache, to: directory.appendingPathComponent("kiro-auth-token.json"))
    }

    private func importRecord(_ record: [String: Any], as type: ServiceType, into directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: record)
        guard case .success = ManualTokenImporter.importPasted(String(decoding: data, as: UTF8.self), preferredType: type, authDirectory: directory) else {
            return XCTFail("Account import failed")
        }
    }

    private func authRecords(_ directory: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: $0)) }
    }
}
