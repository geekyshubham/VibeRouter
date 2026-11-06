import XCTest
@testable import CLIProxyMenuBar

/// Multi-instance launch, isolation and token ownership. All credentials are synthetic.
final class AppInstanceTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vr-instances-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testInstancesSavedBeforeSurfacesExistStillLoadAndPickTheProviderDefault() throws {
        let saved = #"[{"id":"a","name":"Old","provider":"codex","userDataDir":"/tmp/a","extraArgs":[],"createdAt":0}]"#
        let list = try JSONDecoder().decode([ManagedAppInstance].self, from: Data(saved.utf8))
        XCTAssertEqual(list.first?.surface, nil)
        XCTAssertEqual(AppInstanceManager.surface(of: list[0]), .app)

        var gemini = ManagedAppInstance.make(name: "G", provider: .gemini)
        XCTAssertEqual(AppInstanceManager.surface(of: gemini), .terminal, "Gemini is a CLI")
        gemini.surface = "app"
        XCTAssertEqual(AppInstanceManager.surface(of: gemini), .terminal, "an unsupported surface falls back")

        var claude = ManagedAppInstance.make(name: "C", provider: .claude)
        XCTAssertFalse(AppInstanceManager.acceptsBoundAccount(claude), "the desktop app signs in with claude.ai")
        claude.surface = "terminal"
        XCTAssertTrue(AppInstanceManager.acceptsBoundAccount(claude))
        XCTAssertTrue(AppInstanceManager.acceptsBoundAccount(ManagedAppInstance.make(name: "X", provider: .codex)))
    }

    func testClaudeInstanceKeychainServiceMatchesClaudeCode() {
        // sha256("/tmp/vr-instance/claude")[:8], the suffix Claude Code computes.
        XCTAssertEqual(InstanceSessions.claudeKeychainService(configDir: "/tmp/vr-instance/claude"),
                       "Claude Code-credentials-b87f6b8f")
        XCTAssertTrue(NativeKeychain.usesSecurityTool("Claude Code-credentials-b87f6b8f"),
                      "instance items are created by Claude Code with the security tool")
        XCTAssertFalse(NativeKeychain.usesSecurityTool("Codex Auth"))
    }

    func testTerminalScriptIsolatesTheCLIAndDropsInheritedRouting() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("env.txt")
        let cli = dir.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|%s|%s' \"$CLAUDE_CONFIG_DIR\" \"$ANTHROPIC_BASE_URL\" \"$*\" > \(AppInstanceManager.shellQuoted(output.path))\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var instance = ManagedAppInstance.make(name: "Bob's Claude", provider: .claude,
                                               userDataDir: dir.appendingPathComponent("home dir"))
        instance.surface = "terminal"
        instance.extraArgs = ["--model", "it's"]
        let script = dir.appendingPathComponent("start.command")
        try AppInstanceManager.terminalScript(instance: instance, type: .claude,
                                              dataDir: URL(fileURLWithPath: instance.userDataDir), cli: cli)
            .write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:8317"
        env["CLAUDE_CONFIG_DIR"] = "/somewhere/else"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8),
                       "\(instance.userDataDir)||--model it's")
    }

    func testClaudeOwnershipFollowsTheInstancesLiveLogin() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = InstanceSessions.ClaudeHome(configDir: dir)
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": "a@x.com"]])
            .write(to: home.accountURL)
        let account: [String: Any] = ["type": "claude", "email": "a@x.com", "access_token": "a-at"]
        let session: [String: Any] = ["email": "a@x.com", "access_token": "a-at2", "refresh_token": "a-rt2"]

        let owned = InstanceSessions.claudeOwner(of: account, homes: [home], session: { _ in .signedIn(session) })
        XCTAssertEqual(owned?.home, home)
        XCTAssertEqual(owned?.session?["refresh_token"] as? String, "a-rt2")
        XCTAssertNil(InstanceSessions.claudeOwner(of: ["type": "claude", "email": "b@x.com"], homes: [home],
                                                  session: { _ in .signedIn(session) }))
        // A home without a login must not keep the account parked, whatever .claude.json says.
        XCTAssertNil(InstanceSessions.claudeOwner(of: account, homes: [home], session: { _ in .signedOut }))
        // An unreadable Keychain proves nothing: the account file still names the owner.
        let unreadable = InstanceSessions.claudeOwner(of: account, homes: [home], session: { _ in .unreadable })
        XCTAssertEqual(unreadable?.home, home)
        XCTAssertNil(unreadable?.session)
        XCTAssertNil(InstanceSessions.claudeOwner(of: ["type": "codex", "email": "a@x.com"], homes: [home],
                                                  session: { _ in .signedIn(session) }))
    }

    func testInstanceOwnedClaudeAccountIsParkedAndFollowsTheInstance() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parkedKey = TokenRefreshService.parkedRefreshTokenKey
        let file = dir.appendingPathComponent("claude-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "claude", "email": "a@x.com", "access_token": "a-at",
            "expired": "2020-01-01T00:00:00Z", "refresh_token": "a-rt",
        ]).write(to: file)
        let home = InstanceSessions.ClaudeHome(configDir: dir)
        let session: [String: Any] = ["email": "a@x.com", "access_token": "a-at2", "refresh_token": "a-rt2",
                                      "expired": "2099-01-01T00:00:00Z"]
        func overlay(_ owner: InstanceSessions.ClaudeOwnership?) -> Bool {
            NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
                onto: file, sessionAbsent: { true }, claudeCodeOwner: { ["type": "claude", "email": "b@x.com"] },
                readNative: { nil }, instanceOwner: { _ in owner })
        }

        XCTAssertTrue(overlay(.init(home: home, session: session)))
        var payload = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(payload["access_token"] as? String, "a-at2", "the instance's newer access token is used")
        XCTAssertNil(TokenRefreshService.refreshToken(from: payload), "neither VibeRouter nor the proxy may renew it")
        XCTAssertEqual(payload[parkedKey] as? String, "a-rt2", "the instance's newest refresh token is kept aside")
        XCTAssertFalse(overlay(.init(home: home, session: session)))
        // The main Claude Code is someone else and its session is absent, yet the
        // instance's account stays parked.
        XCTAssertFalse(overlay(.init(home: home, session: nil)))

        // Once no instance holds it, the main rules hand it back to VibeRouter.
        XCTAssertTrue(overlay(nil))
        payload = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(TokenRefreshService.refreshToken(from: payload), "a-rt2")
    }

    func testReclaimKeepsTheNewestClaudeLogin() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parkedKey = TokenRefreshService.parkedRefreshTokenKey
        let file = dir.appendingPathComponent("claude-a.json")
        let other = dir.appendingPathComponent("claude-b.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "claude", "email": "a@x.com", "access_token": "a-at",
            "expired": "2026-01-01T00:00:00Z", parkedKey: "a-rt",
        ]).write(to: file)
        try JSONSerialization.data(withJSONObject: [
            "type": "claude", "email": "b@x.com", "access_token": "b-at", "refresh_token": "b-rt",
        ]).write(to: other)

        // An older instance login never replaces a newer VibeRouter copy.
        let older: [String: Any] = ["email": "a@x.com", "access_token": "a-old", "refresh_token": "a-rt0",
                                    "expired": "2025-01-01T00:00:00Z"]
        XCTAssertEqual(InstanceSessions.reclaimClaudeSession(older, authDirectory: dir), 0)

        let newer: [String: Any] = ["email": "a@x.com", "access_token": "a-at2", "refresh_token": "a-rt2",
                                    "expired": "2099-01-01T00:00:00Z"]
        XCTAssertEqual(InstanceSessions.reclaimClaudeSession(newer, authDirectory: dir), 1)
        let a = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(a["access_token"] as? String, "a-at2")
        XCTAssertEqual(a[parkedKey] as? String, "a-rt2")
        XCTAssertNil(TokenRefreshService.refreshToken(from: a), "parked until ownership is re-evaluated")
        let b = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: other))
        XCTAssertEqual(b["refresh_token"] as? String, "b-rt", "other accounts are untouched")
    }

    func testCodexAccountAdoptsTokensAnInstanceRenewed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let live = Self.jwt(iat: now.addingTimeInterval(-60), exp: now.addingTimeInterval(3600))
        let dead = Self.jwt(iat: now.addingTimeInterval(-7200), exp: now.addingTimeInterval(-60))
        let file = dir.appendingPathComponent("codex-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "codex", "email": "instance-only@x.com", "access_token": dead,
            "refresh_token": "rt-old", "account_id": "acct-instance",
        ]).write(to: file)
        let instance: [String: Any] = ["email": "instance-only@x.com", "access_token": live,
                                       "refresh_token": "rt-new", "account_id": "acct-instance"]

        XCTAssertTrue(NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(
            onto: file, now: now, instanceSessions: { [instance] }))
        let updated = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(updated["access_token"] as? String, live)
        XCTAssertEqual(updated["refresh_token"] as? String, "rt-new",
                       "posting rt-old after the instance rotated it would revoke the family")
        XCTAssertFalse(NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(
            onto: file, now: now, instanceSessions: { [instance] }))
    }

    func testInstanceClaudeRenewalRunsInsideTheInstanceConfigDir() {
        let inherited = ["CLAUDE_CONFIG_DIR": "/elsewhere", "PATH": "/bin"]
        XCTAssertNil(ClaudeNativeSessionRefresh.environment(from: inherited)["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(ClaudeNativeSessionRefresh.environment(
            from: inherited, configDir: URL(fileURLWithPath: "/tmp/vr-instance/claude"))["CLAUDE_CONFIG_DIR"],
            "/tmp/vr-instance/claude")
    }

    private static func jwt(iat: Date, exp: Date) -> String {
        func encode(_ object: [String: Any]) -> String {
            (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return encode(["alg": "none", "typ": "JWT"]) + "."
            + encode(["iat": Int(iat.timeIntervalSince1970), "exp": Int(exp.timeIntervalSince1970)]) + ".sig"
    }
}
