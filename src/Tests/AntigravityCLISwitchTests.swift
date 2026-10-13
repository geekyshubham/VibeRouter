import XCTest
@testable import CLIProxyMenuBar

final class AntigravityCLISwitchTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private func update(_ json: Any, refresh: String? = "1//new_refresh", idToken: String? = nil) -> [String: Any]? {
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard let out = AntigravityCLIToken.update(
            data,
            accessToken: "ya29.new_access",
            refreshToken: refresh,
            idToken: idToken,
            email: "new@example.com",
            expiry: expiry
        ) else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    func testGoOAuth2TokenShapeIsUpdatedAndExtraFieldsKept() throws {
        let out = try XCTUnwrap(update([
            "access_token": "ya29.old_access",
            "token_type": "Bearer",
            "refresh_token": "1//old_refresh",
            "expiry": "2026-01-01T00:00:00.123456+05:30",
            "client_id": "synthetic-client",
        ]))
        XCTAssertEqual(out["access_token"] as? String, "ya29.new_access")
        XCTAssertEqual(out["refresh_token"] as? String, "1//new_refresh")
        XCTAssertEqual(out["token_type"] as? String, "Bearer")
        XCTAssertEqual(out["client_id"] as? String, "synthetic-client")
        let parsed = ISO8601DateFormatter().date(from: try XCTUnwrap(out["expiry"] as? String))
        XCTAssertEqual(parsed, expiry)
    }

    func testNestedCamelCaseTokenWithMillisecondExpiry() throws {
        let out = try XCTUnwrap(update([
            "version": 2,
            "token": [
                "accessToken": "ya29.old",
                "refreshToken": "1//old",
                "expiresAt": 1_700_000_000_000,
                "email": "old@example.com",
            ],
        ]))
        let token = try XCTUnwrap(out["token"] as? [String: Any])
        XCTAssertEqual(out["version"] as? Int, 2)
        XCTAssertEqual(token["accessToken"] as? String, "ya29.new_access")
        XCTAssertEqual(token["refreshToken"] as? String, "1//new_refresh")
        XCTAssertEqual(token["expiresAt"] as? Int, 1_800_000_000_000)
        XCTAssertEqual(token["email"] as? String, "new@example.com")
    }

    func testStaleIDTokenFromPreviousAccountIsDropped() throws {
        let out = try XCTUnwrap(update(["access_token": "ya29.old", "id_token": "old.jwt.sig"], idToken: nil))
        XCTAssertNil(out["id_token"])
    }

    func testMissingRefreshKeepsExistingRefreshToken() throws {
        let out = try XCTUnwrap(update(["access_token": "ya29.old", "refresh_token": "1//keep"], refresh: nil))
        XCTAssertEqual(out["refresh_token"] as? String, "1//keep")
    }

    func testUnrecognizedFormatsAreRejected() {
        XCTAssertNil(update(["something": "else"]))
        XCTAssertNil(AntigravityCLIToken.update(
            Data("not-json-opaque-blob".utf8),
            accessToken: "ya29.new",
            refreshToken: nil,
            idToken: nil,
            email: nil,
            expiry: expiry
        ))
    }
}
