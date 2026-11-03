import XCTest
import Security
@testable import CLIProxyMenuBar

final class TokenRefreshServiceTests: XCTestCase {
    func testGroupedByRefreshTokenCollapsesDuplicates() {
        let shared = "rt.1.shared"
        let a = URL(fileURLWithPath: "/tmp/codex-a.json")
        let b = URL(fileURLWithPath: "/tmp/codex-seat.json")
        let c = URL(fileURLWithPath: "/tmp/codex-other.json")
        let groups = TokenRefreshService.groupedByRefreshToken([
            .init(file: a, payload: [:], type: "codex", refresh: shared),
            .init(file: b, payload: [:], type: "codex", refresh: shared),
            .init(file: c, payload: [:], type: "codex", refresh: "rt.1.other"),
        ])
        XCTAssertEqual(groups.count, 2)
        let sizes = Set(groups.map(\.count))
        XCTAssertEqual(sizes, [1, 2])
        let sharedGroup = groups.first { $0.count == 2 }!
        XCTAssertEqual(Set(sharedGroup.map(\.file)), [a, b])
    }

    func testShouldRefreshWhenAccessTokenIsSevenDaysOld() {
        let iat = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let exp = Date().addingTimeInterval(2 * 24 * 60 * 60)
        let payload: [String: Any] = [
            "refresh_token": "rt.1.alive",
            "access_token": Self.jwt(iat: iat, exp: exp),
        ]
        XCTAssertTrue(TokenRefreshService.shouldRefresh(payload: payload))
    }

    func testShouldNotRefreshFreshAccessToken() {
        let iat = Date().addingTimeInterval(-2 * 60 * 60)
        let exp = Date().addingTimeInterval(9 * 24 * 60 * 60)
        let payload: [String: Any] = [
            "refresh_token": "rt.1.alive",
            "access_token": Self.jwt(iat: iat, exp: exp),
        ]
        XCTAssertFalse(TokenRefreshService.shouldRefresh(payload: payload))
    }

    func testPropagateRotatedTokensUpdatesEveryFileSharingTheOldRefreshToken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, refresh: String, email: String) throws {
            let rec: [String: Any] = [
                "type": "codex",
                "email": email,
                "refresh_token": refresh,
                "access_token": "old-at",
            ]
            try JSONSerialization.data(withJSONObject: rec).write(to: dir.appendingPathComponent(name))
        }
        try write("codex-a.json", refresh: "rt-old", email: "a@x.com")
        try write("codex-seat.json", refresh: "rt-old", email: "a@x.com")
        try write("codex-other.json", refresh: "rt-other", email: "b@x.com")

        let updated: [String: Any] = [
            "type": "codex",
            "refresh_token": "rt-new",
            "access_token": "new-at",
            "last_refresh": "now",
        ]
        let n = TokenRefreshService.propagateRotatedTokens(
            oldRefresh: "rt-old",
            updated: updated,
            authDirectory: dir
        )
        XCTAssertEqual(n, 2)

        func read(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let a = try read("codex-a.json")
        let seat = try read("codex-seat.json")
        let other = try read("codex-other.json")
        XCTAssertEqual(a["refresh_token"] as? String, "rt-new")
        XCTAssertEqual(a["access_token"] as? String, "new-at")
        XCTAssertEqual(a["email"] as? String, "a@x.com")
        XCTAssertEqual(seat["refresh_token"] as? String, "rt-new")
        XCTAssertEqual(other["refresh_token"] as? String, "rt-other")
        XCTAssertEqual(other["access_token"] as? String, "old-at")
    }

    func testXAIRefreshTargetsOIDCTokenEndpoint() {
        XCTAssertEqual(TokenRefreshService.xAITokenEndpoints.first, "https://auth.x.ai/oauth2/token")
        XCTAssertTrue(TokenRefreshService.xAITokenEndpoints.contains("https://auth.x.ai/oauth/token"))
    }

    func testOpenAIRefreshFieldsIncludeOfflineAccessScope() {
        let fields = TokenRefreshService.openAIRefreshFields(refreshToken: "rt.1.x")
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["refresh_token"], "rt.1.x")
        XCTAssertEqual(fields["scope"], TokenRefreshService.openAIRefreshScope)
        XCTAssertTrue(TokenRefreshService.openAIRefreshScope.contains("offline_access"))
        XCTAssertNotNil(fields["client_id"])
    }

    func testSameCodexSeatRequiresEmailAndAccountID() {
        let teamJWT = Self.jwtWithAuth(
            accountID: "f7268a18-b7e1-42d3-b4b1-286f67b74b4d",
            plan: "team"
        )
        let goJWT = Self.jwtWithAuth(
            accountID: "b8490ad0-efd0-4413-a1f3-38e7e1dcb977",
            plan: "go"
        )
        let team = [
            "email": "a@x.com",
            "access_token": teamJWT,
            "account_id": "f7268a18-b7e1-42d3-b4b1-286f67b74b4d",
        ]
        let teamSibling = [
            "email": "a@x.com",
            "access_token": teamJWT,
            "account_id": "f7268a18-b7e1-42d3-b4b1-286f67b74b4d",
        ]
        let otherMember = [
            "email": "b@x.com",
            "access_token": teamJWT,
            "account_id": "f7268a18-b7e1-42d3-b4b1-286f67b74b4d",
        ]
        let go = [
            "email": "a@x.com",
            "access_token": goJWT,
            "account_id": "b8490ad0-efd0-4413-a1f3-38e7e1dcb977",
        ]
        XCTAssertTrue(TokenRefreshService.sameCodexSeat(team, as: teamSibling))
        XCTAssertFalse(TokenRefreshService.sameCodexSeat(team, as: otherMember))
        XCTAssertFalse(TokenRefreshService.sameCodexSeat(team, as: go))
    }

    func testShouldRefreshSeesNestedRefreshToken() {
        let iat = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let exp = Date().addingTimeInterval(2 * 24 * 60 * 60)
        let payload: [String: Any] = [
            "type": "codex",
            "tokens": [
                "refresh_token": "rt.1.nested",
                "access_token": Self.jwt(iat: iat, exp: exp),
            ],
        ]
        XCTAssertTrue(TokenRefreshService.shouldRefresh(payload: payload))
    }

    func testFlattenedAuthCopiesNestedTokens() {
        let flat = TokenRefreshService.flattenedAuth([
            "type": "codex",
            "email": "a@x.com",
            "tokens": [
                "access_token": "at",
                "refresh_token": "rt",
            ],
        ])
        XCTAssertEqual(flat["access_token"] as? String, "at")
        XCTAssertEqual(flat["refresh_token"] as? String, "rt")
        XCTAssertEqual(flat["email"] as? String, "a@x.com")
    }

    func testRefreshableCodexSessionIsNotExpiredWhenRefreshJWTExpIsPast() {
        let deadRT = Self.jwt(
            iat: Date().addingTimeInterval(-20 * 24 * 60 * 60),
            exp: Date().addingTimeInterval(-60)
        )
        let liveAT = Self.jwt(
            iat: Date().addingTimeInterval(-2 * 60 * 60),
            exp: Date().addingTimeInterval(8 * 24 * 60 * 60)
        )
        let expiry = AuthManager.sessionExpiryDate(
            from: [
                "type": "codex",
                "refresh_token": deadRT,
                "access_token": liveAT,
            ],
            serviceType: .codex
        )
        XCTAssertNil(expiry)
        let nested = AuthManager.sessionExpiryDate(
            from: [
                "type": "codex",
                "tokens": ["refresh_token": deadRT, "access_token": liveAT],
            ],
            serviceType: .codex
        )
        XCTAssertNil(nested)
    }

    func testShouldAdoptFresherMatchingCodexCLITokens() {
        let now = Date()
        let live = Self.jwt(iat: now.addingTimeInterval(-60), exp: now.addingTimeInterval(3600))
        let dead = Self.jwt(iat: now.addingTimeInterval(-7200), exp: now.addingTimeInterval(-60))
        XCTAssertTrue(
            NativeUsageFetcher.shouldAdoptCodexCLITokens(
                local: [
                    "email": "a@x.com",
                    "access_token": live,
                    "refresh_token": "rt-new",
                    "account_id": "acct-1",
                ],
                file: [
                    "email": "a@x.com",
                    "access_token": dead,
                    "refresh_token": "rt-old",
                    "account_id": "acct-1",
                ],
                now: now
            )
        )
    }

    func testShouldNotAdoptDifferentCodexSeat() {
        let now = Date()
        let liveTeam = Self.jwtWithAuth(
            accountID: "f7268a18-b7e1-42d3-b4b1-286f67b74b4d",
            plan: "team"
        )
        let liveGo = Self.jwtWithAuth(
            accountID: "b8490ad0-efd0-4413-a1f3-38e7e1dcb977",
            plan: "go"
        )
        XCTAssertFalse(
            NativeUsageFetcher.shouldAdoptCodexCLITokens(
                local: [
                    "email": "a@x.com",
                    "access_token": liveTeam,
                    "refresh_token": "rt-team",
                ],
                file: [
                    "email": "a@x.com",
                    "access_token": liveGo,
                    "refresh_token": "rt-go",
                ],
                now: now
            )
        )
    }

    func testShouldNotAdoptOlderCLITokenOverLiveFile() {
        let now = Date()
        let live = Self.jwt(iat: now.addingTimeInterval(-60), exp: now.addingTimeInterval(3600))
        let older = Self.jwt(iat: now.addingTimeInterval(-7200), exp: now.addingTimeInterval(600))
        XCTAssertFalse(
            NativeUsageFetcher.shouldAdoptCodexCLITokens(
                local: [
                    "email": "a@x.com",
                    "access_token": older,
                    "refresh_token": "rt-old",
                ],
                file: [
                    "email": "a@x.com",
                    "access_token": live,
                    "refresh_token": "rt-new",
                ],
                now: now
            )
        )
    }

    func testOverlayCopiesFresherCodexCLICredentialsOntoAuthFile() throws {
        let now = Date()
        let live = Self.jwt(iat: now.addingTimeInterval(-60), exp: now.addingTimeInterval(3600))
        let dead = Self.jwt(iat: now.addingTimeInterval(-7200), exp: now.addingTimeInterval(-60))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-codex-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authFile = dir.appendingPathComponent("codex-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "email": "a@x.com",
            "access_token": dead,
            "refresh_token": "rt-old",
            "account_id": "acct-1",
        ]).write(to: authFile)

        XCTAssertTrue(
            NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(
                onto: authFile,
                localCodex: [
                    "email": "a@x.com",
                    "access_token": live,
                    "refresh_token": "rt-new",
                    "account_id": "acct-1",
                ],
                now: now
            )
        )
        let updated = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: authFile))
        XCTAssertEqual(updated["access_token"] as? String, live)
        XCTAssertEqual(updated["refresh_token"] as? String, "rt-new")
        XCTAssertFalse(
            NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(
                onto: authFile,
                localCodex: [
                    "email": "a@x.com",
                    "access_token": live,
                    "refresh_token": "rt-new",
                    "account_id": "acct-1",
                ],
                now: now
            )
        )
    }

    func testOverlayClaudeDoesNotCopyNativeRefreshToken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-claude-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authFile = dir.appendingPathComponent("claude-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "claude",
            "email": "a@x.com",
            "access_token": "old-at",
            "refresh_token": "rt-imported",
            "expired": "2020-01-01T00:00:00Z",
        ]).write(to: authFile)

        XCTAssertTrue(
            NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
                onto: authFile,
                localClaude: [
                    "email": "a@x.com",
                    "access_token": "live-at",
                    "refresh_token": "rt-native",
                    "expired": "2099-01-01T00:00:00Z",
                ]
            )
        )
        let updated = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: authFile))
        XCTAssertEqual(updated["access_token"] as? String, "live-at")
        XCTAssertNil(updated["refresh_token"] as? String)
        XCTAssertNil(updated["refreshToken"] as? String)
    }

    func testShouldNotNetworkRefreshClaudeWhenNativeSessionExists() {
        XCTAssertFalse(
            TokenRefreshService.shouldNetworkRefreshClaude(
                payload: [
                    "email": "a@x.com",
                    "access_token": "file-at",
                    "refresh_token": "rt-file",
                ],
                native: [
                    "email": "a@x.com",
                    "access_token": "cli-at",
                    "refresh_token": "rt-cli",
                ]
            )
        )
        XCTAssertTrue(
            TokenRefreshService.shouldNetworkRefreshClaude(
                payload: [
                    "email": "other@x.com",
                    "access_token": "file-at",
                    "refresh_token": "rt-file",
                ],
                native: [
                    "email": "a@x.com",
                    "access_token": "cli-at",
                    "refresh_token": "rt-cli",
                ]
            )
        )
        XCTAssertTrue(
            TokenRefreshService.shouldNetworkRefreshClaude(
                payload: ["email": "a@x.com", "refresh_token": "rt-file"],
                native: nil
            )
        )
    }

    func testClaudeAccessOnlyOverlayIsIdempotentAndNativeRefreshKeepsSessionAlive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude.json")
        let payload: [String: Any] = ["type": "claude", "email": "a@x.com", "access_token": "same-at",
                                     "expired": "2020-01-01T00:00:00Z"]
        var native = payload
        native["refresh_token"] = "native-only-rt"
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        // The first pass parks the native refresh token; later passes change nothing.
        XCTAssertTrue(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: native))
        let before = try Data(contentsOf: file)
        XCTAssertFalse(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: native))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertNil(AuthManager.sessionExpiryDate(from: payload, serviceType: .claude, nativeClaude: native))
        native["email"] = "someone-else@x.com"
        XCTAssertNotNil(AuthManager.sessionExpiryDate(from: payload, serviceType: .claude, nativeClaude: native))
        XCTAssertNotNil(AuthManager.sessionExpiryDate(from: payload, serviceType: .claude))
    }

    func testClaudeAccountStaysRenewableAfterClaudeCodeSwitchesAccounts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "claude", "email": "a@x.com", "access_token": "a-at",
            "refresh_token": "a-rt-imported", "expired": "2020-01-01T00:00:00Z",
        ]).write(to: file)
        let parked = TokenRefreshService.parkedRefreshTokenKey

        // Claude Code is signed into A: it owns the family, the proxy cannot POST it.
        let nativeA: [String: Any] = ["email": "a@x.com", "access_token": "a-live", "refresh_token": "a-rt-native",
                                      "expired": "2099-01-01T00:00:00Z"]
        NativeUsageFetcher.overlayClaudeCLICredentials(inDirectory: dir, localClaude: nativeA)
        var stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertNil(TokenRefreshService.refreshToken(from: stored))
        XCTAssertEqual(stored[parked] as? String, "a-rt-native")
        XCTAssertFalse(TokenRefreshService.shouldRefresh(payload: stored))

        // Claude Code rotates; the parked copy follows.
        var rotated = nativeA
        rotated["refresh_token"] = "a-rt-rotated"
        XCTAssertTrue(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: rotated))
        stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(stored[parked] as? String, "a-rt-rotated")

        // A native session with no known identity releases nothing.
        XCTAssertFalse(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
            onto: file, localClaude: ["access_token": "anonymous-at", "refresh_token": "anonymous-rt"]))

        // Claude Code signs into B: A's newest token comes back to VibeRouter.
        let nativeB: [String: Any] = ["email": "b@x.com", "access_token": "b-live", "refresh_token": "b-rt",
                                      "expired": "2099-01-01T00:00:00Z"]
        XCTAssertTrue(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: nativeB))
        stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(stored["refresh_token"] as? String, "a-rt-rotated")
        XCTAssertNil(stored[parked])
        XCTAssertEqual(stored["access_token"] as? String, "a-live")
        XCTAssertTrue(TokenRefreshService.shouldNetworkRefreshClaude(payload: stored, native: nativeB))
        XCTAssertFalse(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(onto: file, localClaude: nativeB))
    }

    func testParkedClaudeAccountIsRenewableNotExpired() {
        let parked: [String: Any] = [
            "type": "claude", "email": "a@x.com", "access_token": "a-at",
            "expired": "2020-01-01T00:00:00Z", TokenRefreshService.parkedRefreshTokenKey: "a-rt",
        ]
        XCTAssertNil(AuthManager.sessionExpiryDate(from: parked, serviceType: .claude))
        var lost = parked
        lost.removeValue(forKey: TokenRefreshService.parkedRefreshTokenKey)
        XCTAssertNotNil(AuthManager.sessionExpiryDate(from: lost, serviceType: .claude))
    }

    func testParkedClaudeTokenIsReleasedWhenClaudeCodeIsSignedOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-a.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "claude", "email": "a@x.com", "access_token": "a-at",
            "expired": "2020-01-01T00:00:00Z", TokenRefreshService.parkedRefreshTokenKey: "a-rt",
        ]).write(to: file)

        XCTAssertFalse(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
            onto: file, localClaude: [:], sessionAbsent: { false }))
        var stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertNil(stored["refresh_token"])

        XCTAssertTrue(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
            onto: file, localClaude: [:], sessionAbsent: { true }))
        stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(stored["refresh_token"] as? String, "a-rt")
        XCTAssertNil(stored[TokenRefreshService.parkedRefreshTokenKey])
    }

    func testClaudeSessionAbsenceNeedsPositiveEvidence() throws {
        let signedOut = try JSONSerialization.data(withJSONObject: ["mcpOAuth": [:]])
        let live = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "at", "refreshToken": "rt"]])
        XCTAssertTrue(NativeUsageFetcher.claudeSessionIsAbsent(keychain: signedOut, status: errSecSuccess, file: live))
        XCTAssertTrue(NativeUsageFetcher.claudeSessionIsAbsent(keychain: nil, status: errSecItemNotFound, file: nil))
        XCTAssertFalse(NativeUsageFetcher.claudeSessionIsAbsent(keychain: nil, status: errSecItemNotFound, file: live))
        XCTAssertFalse(NativeUsageFetcher.claudeSessionIsAbsent(keychain: live, status: errSecSuccess, file: nil))
        XCTAssertFalse(NativeUsageFetcher.claudeSessionIsAbsent(keychain: Data("bad".utf8), status: errSecSuccess, file: nil))
        XCTAssertFalse(NativeUsageFetcher.claudeSessionIsAbsent(keychain: nil, status: errSecAuthFailed, file: nil))
        XCTAssertFalse(NativeUsageFetcher.claudeSessionIsAbsent(keychain: nil, status: errSecNotAvailable, file: nil))
    }

    func testClaudeNativeSessionPrefersKeychainOverLeftoverFile() throws {
        func credentials(_ access: String, expiresAt: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
                "accessToken": access, "refreshToken": access + "-rt", "expiresAt": expiresAt,
            ]])
        }
        let keychain = try credentials("keychain-at", expiresAt: 1_000_000_000_000)
        let leftover = try credentials("leftover-at", expiresAt: 4_000_000_000_000)
        XCTAssertEqual(
            NativeUsageFetcher.claudeAppPayload(keychain: keychain, file: leftover)?["access_token"] as? String,
            "keychain-at"
        )
        XCTAssertEqual(
            NativeUsageFetcher.claudeAppPayload(keychain: nil, file: leftover)?["access_token"] as? String,
            "leftover-at"
        )
        // A Keychain item without a Claude login means signed out, not "use the file".
        let signedOut = try JSONSerialization.data(withJSONObject: ["mcpOAuth": [:]])
        XCTAssertNil(NativeUsageFetcher.claudeAppPayload(keychain: signedOut, file: leftover))
        XCTAssertNil(NativeUsageFetcher.claudeAppPayload(keychain: Data("invalid".utf8), file: leftover))
    }

    func testClaudeImportKeepsRefreshTokenBeforeFirstPollAndReimportParksItAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nativeA: [String: Any] = [
            "email": "a@x.com", "access_token": "a-live", "refresh_token": "a-rt",
            "expired": "2099-01-01T00:00:00Z",
        ]
        func importA() throws -> URL {
            guard case .success = ConfiguredAccountImporter.importClaudeCode(
                authDirectory: dir, displayName: "Claude Code", localClaude: nativeA
            ) else { XCTFail("Claude import failed"); throw NSError(domain: "test", code: 1) }
            return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        }
        let file = try importA()
        var stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(stored[TokenRefreshService.parkedRefreshTokenKey] as? String, "a-rt")
        XCTAssertNil(TokenRefreshService.refreshToken(from: stored))
        // The account switches immediately, before the first background pass.
        XCTAssertTrue(NativeUsageFetcher.overlayClaudeCLICredentialsIfFresher(
            onto: file, localClaude: ["email": "b@x.com", "access_token": "b-live"]))
        stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertEqual(stored["refresh_token"] as? String, "a-rt")
        // Switching back and reimporting cannot leave a proxy-usable copy.
        XCTAssertEqual(try importA(), file)
        stored = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: file))
        XCTAssertNil(TokenRefreshService.refreshToken(from: stored))
        XCTAssertEqual(stored[TokenRefreshService.parkedRefreshTokenKey] as? String, "a-rt")
    }

    func testConcurrentClaudeOAuthRenewalsShareOneGrant() async {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let flight = OAuthRefreshFlight()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let result = await flight.run(token: "claude:synthetic-refresh") {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return .success(["access_token": "rotated-access"])
                    }
                    guard case .success(let json) = result else { return XCTFail("Missing grant") }
                    XCTAssertEqual(json["access_token"] as? String, "rotated-access")
                }
            }
        }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        let now = Date()
        await flight.block(token: "claude:synthetic-refresh", until: now.addingTimeInterval(600))
        _ = await flight.run(token: "claude:synthetic-refresh", now: now.addingTimeInterval(599)) {
            XCTFail("A rate-limited grant must respect its retry deadline")
            return .failed
        }
        _ = await flight.run(token: "claude:synthetic-refresh", now: now.addingTimeInterval(600)) {
            await counter.increment()
            return .success(["access_token": "retried-access"])
        }
        let retryCount = await counter.count
        XCTAssertEqual(retryCount, 2)
    }

    func testCopyTokenFieldsIncludesCamelCaseAliases() {
        let original: [String: Any] = [
            "type": "cursor",
            "email": "a@x.com",
            "accessToken": "old",
        ]
        let updated: [String: Any] = [
            "access_token": "new-at",
            "accessToken": "new-at",
            "refresh_token": "new-rt",
            "refreshToken": "new-rt",
        ]
        let merged = TokenRefreshService.copyTokenFields(from: updated, onto: original)
        XCTAssertEqual(merged["access_token"] as? String, "new-at")
        XCTAssertEqual(merged["accessToken"] as? String, "new-at")
        XCTAssertEqual(merged["refreshToken"] as? String, "new-rt")
        XCTAssertEqual(merged["email"] as? String, "a@x.com")
    }

    private static func jwt(iat: Date, exp: Date) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLToken()
        let payloadObj: [String: Any] = [
            "iat": Int(iat.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
        ]
        let payload = try! JSONSerialization.data(withJSONObject: payloadObj).base64URLToken()
        return "\(header).\(payload).sig"
    }

    private static func jwtWithAuth(accountID: String, plan: String) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLToken()
        let payloadObj: [String: Any] = [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_plan_type": plan,
            ],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ]
        let payload = try! JSONSerialization.data(withJSONObject: payloadObj).base64URLToken()
        return "\(header).\(payload).sig"
    }
}

private extension Data {
    func base64URLToken() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
