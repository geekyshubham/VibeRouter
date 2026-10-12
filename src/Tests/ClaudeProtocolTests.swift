import XCTest
@testable import CLIProxyMenuBar

final class ClaudeProtocolTests: XCTestCase {
    func testLauncherUsesLocalAutoClassifierAndPreservesServerReviewOptIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appendingPathComponent("claude-viberouter")
        try CLIHarnessAutoconfigure.claudeVibeRouterLauncher(baseURL: "http://127.0.0.1:8317", apiKey: "fixture")
            .write(to: launcher, atomically: true, encoding: .utf8)
        for (name, contents) in [
            "curl": "#!/bin/bash\nexit 0\n",
            "claude": "#!/bin/bash\nprintf 'server=%s\\nconfig=%s\\n' \"$CLAUDE_CODE_AUTO_MODE_SERVER\" \"$CLAUDE_CONFIG_DIR\"\nprintf '<%s>\\n' \"$@\"\n",
        ] {
            let executable = directory.appendingPathComponent(name)
            try contents.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        for value: String? in [nil, "", "0", "1"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher.path, "--permission-mode", "auto", "-p", "argument with spaces"]
            process.environment = ["HOME": directory.path, "PATH": "\(directory.path):/usr/bin:/bin"]
            if let value { process.environment?["CLAUDE_CODE_AUTO_MODE_SERVER"] = value }
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(text.contains("server=\(value == "1" ? "1" : "0")\n"))
            XCTAssertTrue(text.contains("config=\(directory.path)/.claude-viberouter\n"))
            XCTAssertTrue(text.contains("<--settings>\n<\(directory.path)/.claude/settings.viberouter.json>\n<--permission-mode>\n<auto>\n<-p>\n<argument with spaces>\n"))
        }
    }

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
