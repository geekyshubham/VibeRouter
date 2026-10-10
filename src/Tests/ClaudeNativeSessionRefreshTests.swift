import XCTest
@testable import CLIProxyMenuBar

final class ClaudeNativeSessionRefreshTests: XCTestCase {
    func testAccessOnlyProxyCanRenewMatchingExpiredNativeSession() {
        let proxy: [String: Any] = ["type": "claude", "email": "a@example.test", "access_token": "old",
                                    "expired": "2020-01-01T00:00:00Z"]
        var native = proxy
        native["refresh_token"] = "native-only"
        XCTAssertTrue(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: native))
        native["expired"] = "2099-01-01T00:00:00Z"
        XCTAssertFalse(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: native))
        XCTAssertTrue(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: native, force: true))
        native["email"] = "other@example.test"
        XCTAssertFalse(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: native, force: true))
        XCTAssertFalse(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: nil))
        native["email"] = "a@example.test"
        native.removeValue(forKey: "refresh_token")
        XCTAssertFalse(ClaudeNativeSessionRefresh.shouldRefresh(account: proxy, native: native, force: true))
    }

    func testRenewalCannotInheritGatewayCredentialsOrCustomKeychainDirectory() throws {
        let env = ClaudeNativeSessionRefresh.environment(from: [
            "ANTHROPIC_API_KEY": "gateway-secret", "ANTHROPIC_BASE_URL": "http://localhost:8317",
            "CLAUDE_CONFIG_DIR": "/tmp/proxy-session", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/proxy-session",
            "CLAUDE_CODE_OAUTH_TOKEN": "old-env-token", "CLAUDECODE": "1", "HOME": "/synthetic", "PATH": "/usr/bin",
        ])
        XCTAssertEqual(env, ["HOME": "/synthetic", "PATH": "/usr/bin", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"])
        let messages = try ClaudeNativeSessionRefresh.input.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0["type"] as? String == "control_request" })
        XCTAssertEqual((messages.last?["request"] as? [String: Any])?["subtype"] as? String, "get_usage")
        XCTAssertEqual((messages.last?["request"] as? [String: Any])?["skip_behaviors"] as? Bool, true)
        XCTAssertTrue(ClaudeNativeSessionRefresh.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(ClaudeNativeSessionRefresh.arguments.contains("{\"disableAllHooks\":true}"))
    }

    func testConcurrentRenewalsShareOneNativeProcessAndFailuresBackOff() async {
        let service = ClaudeNativeSessionRefresh()
        let counter = NativeRefreshCounter()
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await service.run(now: now) {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        return false
                    }
                }
            }
        }
        let firstCount = await counter.count
        XCTAssertEqual(firstCount, 1)
        _ = await service.run(now: now.addingTimeInterval(299)) {
            XCTFail("Repeated events must not spawn more native processes during backoff")
            return false
        }
        _ = await service.run(now: now.addingTimeInterval(300)) { await counter.increment(); return true }
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 2)
    }

    func testExpiredAccessOnlyFileIsNotReportedAsSuccessfullyRefreshed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("claude.json")
        let payload: [String: Any] = ["type": "claude", "email": "synthetic-renewal@example.invalid",
                                     "access_token": "expired-synthetic", "expired": "2020-01-01T00:00:00Z"]
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        try bytes.write(to: file)
        let refreshed = await TokenRefreshService.refreshAccountFile(file)
        XCTAssertFalse(refreshed)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}

private actor NativeRefreshCounter {
    var count = 0
    func increment() { count += 1 }
}
