import XCTest
@testable import CLIProxyMenuBar

final class GrokUsageSyncTests: XCTestCase {
    func testOIDCAuthJSONIsReadFromPrefixedIssuerKey() throws {
        let url = try writeTempJSON([
            "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828": [
                "key": "grok-live-token",
                "email": "user@example.com",
                "refresh_token": "grok-rt",
                "expires_at": "2026-08-29T10:52:47.697626Z",
                "oidc_client_id": "b1a00492-073a-47ea-816f-4c329264a828",
            ]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try XCTUnwrap(NativeUsageFetcher.readGrokAppPayload(at: url))
        XCTAssertEqual(payload["access_token"] as? String, "grok-live-token")
        XCTAssertEqual(payload["email"] as? String, "user@example.com")
        XCTAssertEqual(payload["refresh_token"] as? String, "grok-rt")
        XCTAssertEqual(payload["oidc_client_id"] as? String, "b1a00492-073a-47ea-816f-4c329264a828")
        XCTAssertEqual(payload["expired"] as? String, "2026-08-29T10:52:47.697626Z")
    }

    func testLiveGrokCLITokenIsTriedBeforeDeadCliProxyToken() {
        let now = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-29
        let live = Self.jwt(exp: now.addingTimeInterval(6 * 3600))
        let dead = Self.jwt(exp: now.addingTimeInterval(-30 * 24 * 3600))
        let candidates = NativeUsageFetcher.grokBillingTokenCandidates(
            accountPayload: [
                "email": "user@example.com",
                "access_token": dead,
            ],
            localGrok: [
                "email": "user@example.com",
                "access_token": live,
            ],
            now: now
        )
        XCTAssertEqual(candidates.map(\.source), ["grok-cli", "auth-file"])
        XCTAssertEqual(candidates.map(\.expired), [false, true])
        XCTAssertEqual(candidates.first?.token, live)
    }

    func testNamedGrokAccountIgnoresCLITokenWithNoEmail() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let live = Self.jwt(exp: now.addingTimeInterval(6 * 3600))
        let own = Self.jwt(exp: now.addingTimeInterval(6 * 3600))
        let candidates = NativeUsageFetcher.grokBillingTokenCandidates(
            accountPayload: [
                "email": "other@example.com",
                "access_token": own,
            ],
            localGrok: [
                "access_token": live,
            ],
            now: now
        )
        XCTAssertEqual(candidates.map(\.source), ["auth-file"])
        XCTAssertEqual(candidates.first?.token, own)
    }

    func testDifferentGrokIdentityDoesNotStealCLIToken() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let live = Self.jwt(exp: now.addingTimeInterval(6 * 3600))
        let other = Self.jwt(exp: now.addingTimeInterval(6 * 3600))
        let candidates = NativeUsageFetcher.grokBillingTokenCandidates(
            accountPayload: [
                "email": "other@example.com",
                "access_token": other,
            ],
            localGrok: [
                "email": "user@example.com",
                "access_token": live,
            ],
            now: now
        )
        XCTAssertEqual(candidates.map(\.source), ["auth-file"])
        XCTAssertEqual(candidates.first?.token, other)
    }

    func testJWTExpiryBeatsStaleExpiredField() {
        let now = Date()
        let live = Self.jwt(exp: now.addingTimeInterval(3600))
        XCTAssertFalse(
            NativeUsageFetcher.isGrokCredentialExpired(
                [
                    "access_token": live,
                    "expired": "2020-01-01T00:00:00Z",
                ],
                now: now
            )
        )
        let dead = Self.jwt(exp: now.addingTimeInterval(-60))
        XCTAssertTrue(
            NativeUsageFetcher.isGrokCredentialExpired(
                ["access_token": dead, "expired": "2099-01-01T00:00:00Z"],
                now: now
            )
        )
    }

    func testOverlayCopiesFresherCLICredentialsOntoAuthFile() throws {
        let now = Date()
        let live = Self.jwt(exp: now.addingTimeInterval(3600))
        let dead = Self.jwt(exp: now.addingTimeInterval(-3600))
        let authFile = try writeTempJSON([
            "type": "xai",
            "email": "user@example.com",
            "access_token": dead,
            "refresh_token": "old-rt",
        ])
        defer { try? FileManager.default.removeItem(at: authFile) }

        let wrote = NativeUsageFetcher.overlayGrokCLICredentialsIfFresher(
            onto: authFile,
            localGrok: [
                "email": "user@example.com",
                "access_token": live,
                "refresh_token": "new-rt",
                "expired": "2026-08-29T10:52:47.697626Z",
                "oidc_client_id": TokenRefreshService.xAIGrokClientID,
            ],
            now: now
        )
        XCTAssertTrue(wrote)
        let updated = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: authFile))
        XCTAssertEqual(updated["access_token"] as? String, live)
        XCTAssertEqual(updated["refresh_token"] as? String, "new-rt")
        XCTAssertEqual(updated["oidc_client_id"] as? String, TokenRefreshService.xAIGrokClientID)
        XCTAssertFalse(
            NativeUsageFetcher.overlayGrokCLICredentialsIfFresher(
                onto: authFile,
                localGrok: [
                    "email": "user@example.com",
                    "access_token": live,
                    "refresh_token": "new-rt",
                ],
                now: now
            )
        )
    }

    func testUpdateGrokAppPayloadWritesRotatedTokensBack() throws {
        let url = try writeTempJSON([
            "https://auth.x.ai::abcd": [
                "key": "old-at",
                "refresh_token": "old-rt",
                "email": "user@example.com",
            ]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(
            NativeUsageFetcher.updateGrokAppPayload(
                at: url,
                oldRefresh: "old-rt",
                accessToken: "new-at",
                refreshToken: "new-rt",
                expiresAt: "2026-08-29T12:00:00Z"
            )
        )
        let root = try XCTUnwrap(NativeUsageFetcher.readAuthPayload(at: url))
        let entry = try XCTUnwrap(root["https://auth.x.ai::abcd"] as? [String: Any])
        XCTAssertEqual(entry["key"] as? String, "new-at")
        XCTAssertEqual(entry["refresh_token"] as? String, "new-rt")
        XCTAssertEqual(entry["expires_at"] as? String, "2026-08-29T12:00:00Z")
        XCTAssertFalse(
            NativeUsageFetcher.updateGrokAppPayload(
                at: url,
                oldRefresh: "someone-else-rt",
                accessToken: "nope",
                refreshToken: nil,
                expiresAt: nil
            )
        )
    }

    func testBillingResponseParsesPercentAndKeepsDataFrameWhenTrailerFollows() {
        let hex = "000000005e0a5c0d0000924212001a00220c0890e3bbd40610f8caa8da032a0c0890d8e0d40610f8caa8da033a07080215000092423a0208043a020805421e0802120c0890e3bbd40610f8caa8da031a0c0890d8e0d40610f8caa8da03580162006801800000000f677270632d7374617475733a300d0a"
        let data = Data(hexEncoded: hex)!
        let frames = NativeUsageFetcher.grokGRPCWebDataFrames(from: data)
        XCTAssertEqual(frames.count, 1)

        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let parsed = NativeUsageFetcher.parseGrokBillingResponse(data, now: now)
        XCTAssertEqual(parsed?.usedPercent ?? -1, 73, accuracy: 0.01)
        XCTAssertEqual(parsed?.resetsAt?.timeIntervalSince1970, 1_788_357_648)
    }

    func testTruncatedSecondFrameDoesNotDropTheUsagePayload() {
        // Valid 99-byte data frame + 3 leftover bytes that look like a header.
        let hex = "000000005e0a5c0d0000924212001a00220c0890e3bbd40610f8caa8da032a0c0890d8e0d40610f8caa8da033a07080215000092423a0208043a020805421e0802120c0890e3bbd40610f8caa8da031a0c0890d8e0d40610f8caa8da03580162006801ffffff"
        let data = Data(hexEncoded: hex)!
        XCTAssertFalse(NativeUsageFetcher.grokGRPCWebDataFrames(from: data).isEmpty)
    }

    func testXAIRefreshUsesOIDCTokenEndpointAndClientID() {
        XCTAssertEqual(
            TokenRefreshService.xAITokenEndpoints.first,
            "https://auth.x.ai/oauth2/token"
        )
        XCTAssertFalse(
            TokenRefreshService.xAITokenEndpoints
                .contains("https://api.x.ai/oauth/token")
        )
        let now = Date()
        let token = Self.jwt(
            exp: now.addingTimeInterval(3600),
            extra: ["client_id": "from-jwt", "aud": "from-jwt"]
        )
        XCTAssertEqual(
            TokenRefreshService.xAIClientID(from: ["access_token": token]),
            "from-jwt"
        )
        XCTAssertEqual(
            TokenRefreshService.xAIClientID(from: ["oidc_client_id": "from-file"]),
            "from-file"
        )
        XCTAssertEqual(
            TokenRefreshService.xAIClientID(from: [:]),
            TokenRefreshService.xAIGrokClientID
        )
    }

    private func writeTempJSON(_ object: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-grok-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
        return url
    }

    private static func jwt(exp: Date, extra: [String: Any] = [:]) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLToken()
        var payloadObj: [String: Any] = ["exp": Int(exp.timeIntervalSince1970)]
        for (key, value) in extra { payloadObj[key] = value }
        let payload = try! JSONSerialization.data(withJSONObject: payloadObj).base64URLToken()
        return "\(header).\(payload).sig"
    }
}

private extension Data {
    init?(hexEncoded hex: String) {
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            let next = chars.index(index, offsetBy: 2)
            guard let byte = UInt8(String(chars[index..<next]), radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    func base64URLToken() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
