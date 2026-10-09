import XCTest
@testable import CLIProxyMenuBar

final class ClaudeProtocolTests: XCTestCase {
    func testNativeClaudeAndSafeguardRequestsBypassBodyTransforms() {
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: "{}", headers: [("User-Agent", "claude-cli/2.1.295")]))
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: "{}", headers: [("user-agent", "claude-code/2.1.295")]))
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: #"{"safeguards":[],"unknown_field":true}"#, headers: []))
        XCTAssertFalse(ThinkingProxy.preservesClaudeProtocol(body: #"{"messages":[]}"#, headers: []))
    }

    func testRuntimeConfigForwardsClaudeQuotaAndRetryHeaders() {
        let config = ConfigComposer.composeRuntimeConfig(
            baseRoot: ["passthrough-headers": false], reservedCustomProviderKeys: [], disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [], zaiAPIKeys: [], customProviderAuthRecords: [], includeManagedZAIProvider: false
        )
        XCTAssertEqual(config["passthrough-headers"] as? Bool, true)
    }
}
