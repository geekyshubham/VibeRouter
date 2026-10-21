import XCTest
@testable import CLIProxyMenuBar

final class AntigravityACPTokenTests: XCTestCase {
    private let client = AntigravityACPToken.OAuthClient(id: "synthetic-client.apps.example", secret: "synthetic-secret")
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("acp-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func makeProfile(base: String, instance: String, authType: String) throws -> URL {
        let acp = home.appendingPathComponent(".t3/\(base)/providers/antigravity/\(instance)/antigravity-acp")
        try FileManager.default.createDirectory(at: acp, withIntermediateDirectories: true)
        try Data(#"{"auth":{"type":"\#(authType)"}}"#.utf8).write(to: acp.appendingPathComponent("settings.json"))
        return acp
    }

    func testBlobMatchesGoogleAuthorizedUserShape() throws {
        let out = try object(AntigravityACPToken.blob(
            existing: nil, client: client, accessToken: "ya29.synthetic", refreshToken: "1//synthetic", expiry: expiry
        ))
        XCTAssertEqual(out["client_id"] as? String, client.id)
        XCTAssertEqual(out["client_secret"] as? String, client.secret)
        XCTAssertEqual(out["refresh_token"] as? String, "1//synthetic")
        XCTAssertEqual(out["token"] as? String, "ya29.synthetic")
        XCTAssertEqual(out["token_uri"] as? String, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(out["scopes"] as? [String], AntigravityACPToken.scopes)
        XCTAssertEqual(out["expiry"] as? String, "2027-01-15T08:00:00Z")
    }

    func testRenewalKeepsServerFieldsAndSwitchDropsThem() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "refresh_token": "1//synthetic-a", "project_id": "synthetic-project",
        ])
        let renewed = try object(AntigravityACPToken.blob(
            existing: existing, client: client, accessToken: "ya29.a2", refreshToken: "1//synthetic-a", expiry: expiry
        ))
        XCTAssertEqual(renewed["project_id"] as? String, "synthetic-project")
        let switched = try object(AntigravityACPToken.blob(
            existing: existing, client: client, accessToken: "ya29.b", refreshToken: "1//synthetic-b", expiry: expiry
        ))
        XCTAssertNil(switched["project_id"])
    }

    func testApplyWritesOnlyPersonalProfilesOwnerOnly() throws {
        let personal = try makeProfile(base: "userdata", instance: "aaaa", authType: "oauth-personal")
        let business = try makeProfile(base: "userdata", instance: "bbbb", authType: "oauth-business")

        XCTAssertEqual(AntigravityACPToken.apply(
            client: client, accessToken: "ya29.x", refreshToken: nil, expiry: expiry, home: home
        ), .missingRefreshToken)
        XCTAssertEqual(AntigravityACPToken.apply(
            client: client, accessToken: "ya29.x", refreshToken: "1//x", expiry: expiry, home: home
        ), .updated(1))

        let snapshot = try XCTUnwrap(AntigravityACPToken.snapshot(at: personal))
        XCTAssertEqual(snapshot.refreshToken, "1//x")
        XCTAssertEqual(snapshot.accessToken, "ya29.x")
        XCTAssertEqual(snapshot.expiry, expiry)
        let attributes = try FileManager.default.attributesOfItem(atPath: AntigravityACPToken.tokenURL(in: personal).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AntigravityACPToken.tokenURL(in: business).path))
    }

    func testApplyWithoutT3ProfilesDoesNothing() {
        XCTAssertEqual(AntigravityACPToken.apply(
            client: client, accessToken: "ya29.x", refreshToken: "1//x", expiry: expiry, home: home
        ), .noProfiles)
    }
}
