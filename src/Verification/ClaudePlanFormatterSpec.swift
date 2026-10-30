import Foundation

/// Compile and run from the repo root:
///   swiftc -O -o /tmp/claude-plan-formatter-spec \
///     src/Verification/ClaudePlanFormatterSpec.swift \
///     src/Sources/ClaudePlanFormatter.swift && /tmp/claude-plan-formatter-spec
@main
struct ClaudePlanFormatterSpec {
    static func main() {
        // Personal Max observed 2026: organization_type=claude_max, rate_limit_tier=default_claude_max_20x.
        precondition(ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: "default_claude_max_20x") == "Claude Max 20x")
        precondition(ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: "default_claude_max_5x") == "Claude Max 5x")
        precondition(ClaudePlanFormatter.displayName(planType: "max", rateLimitTier: nil) == "Claude Max")

        // Team seat observed: organization_type=claude_team, rate_limit_tier=default_claude_max_5x.
        precondition(ClaudePlanFormatter.displayName(planType: "team", rateLimitTier: "default_claude_max_5x") == "Claude Team · 5x")
        precondition(ClaudePlanFormatter.displayName(planType: "team", rateLimitTier: nil) == "Claude Team")
        precondition(ClaudePlanFormatter.displayName(planType: "enterprise", rateLimitTier: nil) == "Claude Enterprise")

        precondition(ClaudePlanFormatter.displayName(planType: "pro", rateLimitTier: "default_claude_pro") == "Claude Pro")
        precondition(ClaudePlanFormatter.displayName(planType: nil, rateLimitTier: nil) == nil)
        precondition(ClaudePlanFormatter.displayName(planType: nil, rateLimitTier: "default_claude_max_20x") == "Claude Max 20x",
                     "tier alone still identifies Max")

        precondition(ClaudePlanFormatter.planType(organizationType: "claude_team", subscriptionType: "max") == "team",
                     "org type wins over keychain subscriptionType")
        precondition(ClaudePlanFormatter.planType(organizationType: nil, subscriptionType: "max") == "max")

        // Keychain-derived payload (claudeAppPayload stamps rate_limit_tier).
        let keychain: [String: Any] = ["subscriptionType": "max", "rate_limit_tier": "default_claude_max_20x"]
        precondition(ClaudePlanFormatter.displayName(fromAuth: keychain) == "Claude Max 20x")
        precondition(ClaudePlanFormatter.displayName(fromAuth: ["access_token": "x"]) == nil)

        print("ClaudePlanFormatterSpec: all checks passed")
    }
}
