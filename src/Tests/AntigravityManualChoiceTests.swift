import XCTest
@testable import CLIProxyMenuBar

/// Antigravity auto-switch must not undo an account the user switched the IDE to.
final class AntigravityManualChoiceTests: XCTestCase {
    /// Runs `body` with no recorded choice and restores the real one afterwards.
    private func withoutRecordedChoice(_ body: () -> Void) {
        let saved = AntigravityAutoRouter.manualChoiceAccountID
        AntigravityAutoRouter.manualChoiceAccountID = nil
        body()
        AntigravityAutoRouter.manualChoiceAccountID = saved
    }

    private func account(_ id: String, type: ServiceType = .antigravity) -> AuthAccount {
        AuthAccount(
            id: id,
            email: "\(id)@example.com",
            login: nil,
            type: type,
            expired: nil,
            filePath: URL(fileURLWithPath: "/tmp/\(id).json"),
            isDisabled: false
        )
    }

    private func snapshot(used: Double, refreshing: Bool = false) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: "acct",
            providerID: "antigravity",
            windows: [RateWindow(usedPercent: used, label: "Claude and GPT models")],
            isRefreshing: refreshing
        )
    }

    private func keeps(_ current: AuthAccount, _ snapshot: ProviderUsageSnapshot?) -> Bool {
        AntigravityAutoRouter.keepsManualChoice(current: current, snapshot: snapshot, threshold: 95)
    }

    func testWithoutAManualChoiceAutoSwitchIsFree() {
        withoutRecordedChoice {
            XCTAssertFalse(keeps(account("a"), snapshot(used: 100)))
        }
    }

    func testManualChoiceOfAnExhaustedAccountIsKept() {
        withoutRecordedChoice {
            let chosen = account("chosen")
            AntigravityAutoRouter.noteManualSwitch(to: chosen)
            XCTAssertTrue(keeps(chosen, snapshot(used: 100)), "an exhausted pick stays")
            XCTAssertTrue(keeps(chosen, nil), "no usage yet: still the user's pick")
            XCTAssertTrue(keeps(chosen, snapshot(used: 10, refreshing: true)), "a sweep in flight proves nothing")
            XCTAssertEqual(AntigravityAutoRouter.manualChoiceAccountID, chosen.id)
        }
    }

    func testManualChoiceFailsOverOnceItRunsOutAfterBeingSeenHealthy() {
        withoutRecordedChoice {
            let chosen = account("chosen")
            AntigravityAutoRouter.noteManualSwitch(to: chosen)
            XCTAssertTrue(keeps(chosen, snapshot(used: 40)))
            XCTAssertNil(AntigravityAutoRouter.manualChoiceAccountID, "seen healthy: normal failover resumes")
            XCTAssertFalse(keeps(chosen, snapshot(used: 100)))
        }
    }

    func testManualChoiceIsDroppedWhenTheIDEIsOnAnotherAccount() {
        withoutRecordedChoice {
            AntigravityAutoRouter.noteManualSwitch(to: account("chosen"))
            XCTAssertFalse(keeps(account("other"), snapshot(used: 100)))
            XCTAssertNil(AntigravityAutoRouter.manualChoiceAccountID)
        }
    }

    func testOnlyAntigravitySwitchesAreRecorded() {
        withoutRecordedChoice {
            AntigravityAutoRouter.noteManualSwitch(to: account("codex-a", type: .codex))
            XCTAssertNil(AntigravityAutoRouter.manualChoiceAccountID)
        }
    }

    func testAgyKeychainItemGoesThroughTheToolItsACLTrusts() {
        XCTAssertTrue(NativeKeychain.usesSecurityTool(AntigravityCLIToken.keychainService),
                      "agy saves its login via go-keyring, which uses /usr/bin/security")
    }
}
