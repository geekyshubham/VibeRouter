import Foundation

/// Single source of truth for rendering usage volumes, costs, and credits.
///
/// This exists because `formatTokens` was copy-pasted into three views with
/// *divergent* tiers: AnalyticsDashboardView handled billions, but
/// MenuBarPanelView and ProviderUsageCardView stopped at millions — so a
/// 3.1B-token total rendered as "3100.0M". Scaling now happens in exactly one
/// place and every surface routes through it, so values scale both up and down
/// consistently wherever they are displayed.
enum UsageNumberFormatter {
    private struct Tier {
        let threshold: Double
        let suffix: String
    }

    /// Descending, so the first threshold a value clears is the one used.
    private static let tiers: [Tier] = [
        Tier(threshold: 1_000_000_000_000, suffix: "T"),
        Tier(threshold: 1_000_000_000, suffix: "B"),
        Tier(threshold: 1_000_000, suffix: "M"),
        Tier(threshold: 1_000, suffix: "K"),
    ]

    /// Compact count that scales up *and* down: "0", "950", "12.4K", "4.2M", "3.1B".
    static func tokens(_ count: Int) -> String {
        scaled(Double(count))
    }

    /// Cost in USD: cents-precise where cents matter, scaled once they don't.
    /// "<$0.01", "$0.42", "$18.40", "$1.2K", "$3.4M".
    static func usd(_ value: Double) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        if magnitude == 0 { return "$0.00" }
        // Below a cent still means "you spent something", so don't render "$0.00".
        if magnitude < 0.01 { return "\(sign)<$0.01" }
        if magnitude < 1_000 { return sign + "$" + fixed(magnitude, places: 2) }
        return "\(sign)$\(scaled(magnitude))"
    }

    /// Volume in the provider's own unit. Kiro stores millicredits (credits × 1000),
    /// which must never be summed into, or labelled as, tokens.
    static func volume(_ count: Int, unit: UsageVolumeUnit) -> String {
        switch unit {
        case .credits: return credits(millicredits: count)
        case .estimatedTokens: return tokens(count) + " est"
        case .tokens: return tokens(count)
        }
    }

    /// Exact tokens with estimates alongside, never summed: "1.2M +3.4M est".
    static func tokens(_ exact: Int, estimated: Int) -> String {
        guard estimated > 0 else { return tokens(exact) }
        let estimate = volume(estimated, unit: .estimatedTokens)
        return exact > 0 ? "\(tokens(exact)) +\(estimate)" : estimate
    }

    /// Cost with estimate-only cost alongside: "$12.40 +$3.10 est".
    static func usd(_ exact: Double, estimated: Double) -> String {
        guard estimated >= 0.005 else { return usd(exact) }
        return "\(usd(exact)) +\(usd(estimated)) est"
    }

    /// Kiro plan credits, stored as millicredits for sub-credit precision.
    /// Keeps two decimals below 1 credit so a fractional spend never shows as "0".
    static func credits(millicredits: Int) -> String {
        let credits = Double(millicredits) / 1000.0
        if credits >= 1_000 { return "\(scaled(credits)) cr" }
        if credits >= 10 { return fixed(credits, places: 0) + " cr" }
        if credits >= 1 { return fixed(credits, places: 1) + " cr" }
        if credits > 0 { return fixed(credits, places: 2) + " cr" }
        return "0 cr"
    }

    // MARK: - Rounding

    /// Formats with a fixed number of decimals, rounding half **away from zero**.
    ///
    /// `String(format:)` delegates to C `printf`, which rounds half to *even*: 4.25 with
    /// one decimal becomes "4.2", while the management console's `toFixed(1)` on the same
    /// double gives "4.3". That made one number read differently in the app and the web
    /// console. Rounding explicitly first leaves the format string with nothing to do but
    /// pad, so both surfaces agree.
    ///
    /// Half-away matches JS rather than the other way round because it is also what a
    /// reader expects: 4.25 rounds up.
    private static func fixed(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return String(format: "%.\(places)f", value) }
        let factor = pow(10.0, Double(places))
        let rounded = ((value * factor).rounded(.toNearestOrAwayFromZero) / factor)
        return String(format: "%.\(places)f", rounded)
    }

    // MARK: - Scaling

    /// Picks the largest tier the value clears and renders ~3 significant digits.
    private static func scaled(_ value: Double) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""

        for (index, tier) in tiers.enumerated() where magnitude >= tier.threshold {
            var chosen = tier
            var scaledValue = magnitude / tier.threshold
            // Rounding can push a value into four digits (999,951 tokens → "1000K").
            // Promote to the next tier so it reads "1M" instead.
            if scaledValue >= 999.5, index > 0 {
                chosen = tiers[index - 1]
                scaledValue = magnitude / chosen.threshold
            }
            return sign + trimmed(scaledValue) + chosen.suffix
        }

        return sign + fixed(magnitude, places: 0)
    }

    /// One decimal below 100 (4.2M, 42.5M), none above (421M) — and never a
    /// bare trailing ".0", so an exact million reads "1M" rather than "1.0M".
    private static func trimmed(_ value: Double) -> String {
        var text = fixed(value, places: value < 100 ? 1 : 0)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }
}
