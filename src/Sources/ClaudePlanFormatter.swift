import Foundation

/// Claude subscription names from the OAuth profile (`organization_type`,
/// `rate_limit_tier`) or Claude Code's keychain (`subscriptionType`, `rateLimitTier`).
enum ClaudePlanFormatter {
    /// Normalized plan token: "max", "pro", "team", "enterprise", "free".
    static func planType(organizationType: String?, subscriptionType: String? = nil) -> String? {
        for raw in [organizationType, subscriptionType] {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty
            else { continue }
            let plan = raw.hasPrefix("claude_") ? String(raw.dropFirst("claude_".count)) : raw
            if !plan.isEmpty { return plan }
        }
        return nil
    }

    /// Usage multiplier such as "5x" / "20x" from `default_claude_max_20x`.
    static func multiplier(rateLimitTier: String?) -> String? {
        guard let tier = rateLimitTier?.lowercased(),
              let range = tier.range(of: #"(\d+)x$"#, options: .regularExpression)
        else { return nil }
        return String(tier[range])
    }

    /// "Claude Max 20x", "Claude Team · 5x", "Claude Pro".
    static func displayName(planType: String?, rateLimitTier: String?) -> String? {
        let multiplier = multiplier(rateLimitTier: rateLimitTier)
        // A Max tier without an org type is still a Max plan.
        let plan = planType ?? (rateLimitTier?.lowercased().contains("max") == true ? "max" : nil)
        guard let plan else { return nil }
        switch plan {
        case "max":
            return multiplier.map { "Claude Max \($0)" } ?? "Claude Max"
        case "pro":
            return "Claude Pro"
        case "free":
            return "Claude Free"
        case "team", "enterprise":
            let base = "Claude \(plan.capitalized)"
            return multiplier.map { "\(base) · \($0)" } ?? base
        default:
            let base = "Claude " + plan
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return multiplier.map { "\(base) · \($0)" } ?? base
        }
    }

    /// Plan label from stored auth JSON / Claude Code keychain fields (no network).
    static func displayName(fromAuth json: [String: Any]) -> String? {
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = json[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let plan = planType(
            organizationType: string(["organization_type", "organizationType"]),
            subscriptionType: string(["subscriptionType", "subscription_type", "plan_type"])
        )
        return displayName(planType: plan, rateLimitTier: string(["rate_limit_tier", "rateLimitTier"]))
    }
}
