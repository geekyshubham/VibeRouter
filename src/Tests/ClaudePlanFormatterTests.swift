import XCTest
@testable import CLIProxyMenuBar

final class ClaudePlanFormatterTests: XCTestCase {
    func testMaxPlanShowsMultiplier() {
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: "default_claude_max_20x"),
            "Claude Max 20x"
        )
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: "default_claude_max_5x"),
            "Claude Max 5x"
        )
        XCTAssertEqual(ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: nil), "Claude Max")
    }

    func testTeamPlanShowsSeatMultiplier() {
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(planType: "team", rateLimitTier: "default_claude_max_5x"),
            "Claude Team · 5x"
        )
        XCTAssertEqual(ClaudePlanFormatter.displayName(planType: "team", rateLimitTier: nil), "Claude Team")
    }

    func testProAndUnknownTiers() {
        XCTAssertEqual(ClaudePlanFormatter.displayName(planType: "pro", rateLimitTier: "default_claude_pro"), "Claude Pro")
        XCTAssertNil(ClaudePlanFormatter.displayName(planType: nil, rateLimitTier: nil))
        // Tier alone still identifies a Max plan.
        XCTAssertEqual(ClaudePlanFormatter.displayName(planType: nil, rateLimitTier: "default_claude_max_20x"), "Claude Max 20x")
    }

    func testOrganizationTypeWinsOverSubscriptionType() {
        XCTAssertEqual(ClaudePlanFormatter.planType(organizationType: "claude_team", subscriptionType: "max"), "team")
        XCTAssertEqual(ClaudePlanFormatter.planType(organizationType: nil, subscriptionType: "max"), "max")
    }

    func testAuthFileFields() {
        let keychain: [String: Any] = ["subscriptionType": "max", "rate_limit_tier": "default_claude_max_20x"]
        XCTAssertEqual(ClaudePlanFormatter.displayName(fromAuth: keychain), "Claude Max 20x")
        XCTAssertNil(ClaudePlanFormatter.displayName(fromAuth: ["access_token": "x"]))
    }

    func testProfileResponseMapsTeamSeat() {
        let profile: [String: Any] = [
            "account": ["has_claude_max": false, "has_claude_pro": false],
            "organization": ["organization_type": "claude_team", "rate_limit_tier": "default_claude_max_5x"],
        ]
        let plan = NativeUsageFetcher.claudeProfilePlan(from: profile)
        XCTAssertEqual(plan?.planType, "team")
        XCTAssertEqual(plan?.planLabel, "Claude Team · 5x")
    }

    func testProfileResponseMapsPersonalMax() {
        let profile: [String: Any] = [
            "account": ["has_claude_max": true],
            "organization": ["organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x"],
        ]
        XCTAssertEqual(NativeUsageFetcher.claudeProfilePlan(from: profile)?.planLabel, "Claude Max 20x")
        XCTAssertNil(NativeUsageFetcher.claudeProfilePlan(from: [:]))
    }

    func testThrottledPollKeepsLastKnownPlan() async {
        let poller = ClaudeUsagePoller()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = ProviderUsageSnapshot(
            id: "c", providerID: "claude", source: "Claude OAuth",
            windows: [RateWindow(usedPercent: 10, label: "5-hour")],
            planType: "team", planLabel: "Claude Team · 5x", updatedAt: now
        )
        _ = await poller.fetch(key: "k", now: now) { .init(snapshot: original) }
        let throttled = await poller.fetch(key: "k", now: now.addingTimeInterval(301)) {
            .init(snapshot: .empty(authAccountID: "c", providerID: "claude"), rateLimited: true)
        }
        XCTAssertEqual(throttled.planLabel, "Claude Team · 5x")
    }
}
