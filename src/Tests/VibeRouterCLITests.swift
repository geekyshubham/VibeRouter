import XCTest
@testable import CLIProxyMenuBar

final class VibeRouterCLITests: XCTestCase {
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
