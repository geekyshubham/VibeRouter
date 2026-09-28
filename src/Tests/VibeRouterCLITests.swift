import XCTest
@testable import CLIProxyMenuBar

final class VibeRouterCLITests: XCTestCase {
    func testClaudeProxyCleanupRemovesPersistedKiroModelWithoutLosingPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        let original: [String: Any] = [
            "model": "kiro/claude-opus-5.5",
            "theme": "dark",
            "env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8317", "MY_SETTING": "keep"],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try JSONSerialization.data(withJSONObject: ["model": "opus[1m]"])
            .write(to: URL(fileURLWithPath: settings.path + ".viberouter-bak"))

        try CLIHarnessAutoconfigure.stripProxySettingsFromMainClaudeSettings(in: dir)

        let data = try Data(contentsOf: settings)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["model"] as? String, "opus[1m]")
        XCTAssertEqual(result["theme"] as? String, "dark")
        XCTAssertEqual((result["env"] as? [String: String])?["MY_SETTING"], "keep")
        XCTAssertNil((result["env"] as? [String: String])?["ANTHROPIC_BASE_URL"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path + ".viberouter-bak"))
    }

    func testClaudeProxyCleanupPreservesNativeModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "claude-opus-5-5"])
            .write(to: settings)

        try CLIHarnessAutoconfigure.stripProxySettingsFromMainClaudeSettings(in: dir)

        let data = try Data(contentsOf: settings)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["model"] as? String, "claude-opus-5-5")
    }

    func testClaudeProxyCleanupDropsKiroModelWhenThereIsNoNativeBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "kiro/auto"])
            .write(to: settings)

        try CLIHarnessAutoconfigure.stripProxySettingsFromMainClaudeSettings(in: dir)

        let data = try Data(contentsOf: settings)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(result["model"])
    }

    func testCLIEntryPointDetection() {
        XCTAssertTrue(VibeRouterCLI.shouldRun(arguments: ["/usr/local/bin/viberouter"]))
        XCTAssertTrue(VibeRouterCLI.shouldRun(arguments: ["/tmp/VibeRouterCLI", "status"]))
        XCTAssertTrue(VibeRouterCLI.shouldRun(arguments: ["CLIProxyMenuBar", "cli", "status"]))
        XCTAssertTrue(VibeRouterCLI.shouldRun(arguments: ["CLIProxyMenuBar", "--cli", "status"]))
        XCTAssertTrue(VibeRouterCLI.shouldRun(arguments: ["CLIProxyMenuBar", "tui"]))
        XCTAssertFalse(VibeRouterCLI.shouldRun(arguments: ["CLIProxyMenuBar"]))
        XCTAssertFalse(VibeRouterCLI.shouldRun(arguments: ["CLIProxyMenuBar", "status"]))
    }

    func testCompletionScriptsContainInstallAndCoreCommands() throws {
        for shell in ["zsh", "bash", "fish"] {
            let script = try VibeRouterCLI.completionScript(for: shell)
            XCTAssertTrue(script.contains("viberouter"))
            XCTAssertTrue(script.contains("status"))
            XCTAssertTrue(script.contains("install-cli"))
        }
    }

    func testUnsupportedCompletionShellHasStableFailure() {
        XCTAssertThrowsError(try VibeRouterCLI.completionScript(for: "powershell")) { error in
            guard let failure = error as? VibeRouterCLI.Failure else {
                return XCTFail("Expected VibeRouterCLI.Failure")
            }
            XCTAssertEqual(failure.code, "unsupported_shell")
            XCTAssertEqual(failure.exitCode, 2)
        }
    }
}
