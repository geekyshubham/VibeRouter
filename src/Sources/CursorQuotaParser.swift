import Foundation

/// Maps Cursor `/api/usage-summary` JSON into quota windows.
///
/// Two payload generations exist:
/// - **Legacy (no `breakdown`)** — `*PercentUsed` fields are percent *remaining*
///   (a barely-used free plan reported `totalPercentUsed ≈ 94`), so they must be
///   inverted; `used`/`limit` cents described the whole allowance.
/// - **Current (`breakdown` with included/bonus/total)** — Cursor's own UI reads
///   `totalPercentUsed` as percent *used* ("You've used 42%" ↔ 41.78), while
///   `used`/`limit` only count the **included** bucket: a fully-spent included
///   quota reports `2000/2000` even though 12k bonus units remain. Trusting the
///   cents here made healthy accounts look exhausted. When `breakdown.total > 0`
///   the percent fields win, read directly.
enum CursorQuotaParser {
    static func windows(from json: [String: Any], billingCycleEnd: Date? = nil) -> [RateWindow] {
        let reset = billingCycleEnd
            ?? parseDate(json["billingCycleEnd"] as? String)
            ?? parseDate(json["billing_cycle_end"] as? String)
        let resetLine = reset.map { ResetCountdownFormatter.resetLine(for: $0) }

        let individual = json["individualUsage"] as? [String: Any]
            ?? json["individual_usage"] as? [String: Any]
        let team = json["teamUsage"] as? [String: Any]
            ?? json["team_usage"] as? [String: Any]
        let plan = (individual?["plan"] as? [String: Any])
            ?? (json["planUsage"] as? [String: Any])
            ?? (json["plan_usage"] as? [String: Any])
        let overall = individual?["overall"] as? [String: Any]
        let onDemand = (individual?["onDemand"] as? [String: Any])
            ?? (individual?["on_demand"] as? [String: Any])
        let teamOnDemand = (team?["onDemand"] as? [String: Any])
            ?? (team?["on_demand"] as? [String: Any])
        let pooled = (team?["pooled"] as? [String: Any])

        var windows: [RateWindow] = []

        if let window = window(
            from: plan ?? overall,
            percentKeys: ["totalPercentUsed", "total_percent_used"],
            label: "Total Usage",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if let window = window(
            from: plan,
            percentKeys: ["autoPercentUsed", "auto_percent_used"],
            label: "Auto + Composer",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if let window = window(
            from: plan,
            percentKeys: ["apiPercentUsed", "api_percent_used"],
            label: "API Usage",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }
        if windows.isEmpty, let window = window(
            from: pooled,
            percentKeys: ["totalPercentUsed", "total_percent_used"],
            label: "Team Pool",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }

        let odSource: [String: Any]? = {
            if let onDemand, (onDemand["enabled"] as? Bool) != false {
                return onDemand
            }
            return teamOnDemand
        }()
        if let window = window(
            from: odSource,
            percentKeys: ["onDemandPercentUsed", "on_demand_percent_used"],
            label: "On-Demand",
            resetsAt: reset,
            resetDescription: resetLine
        ) {
            windows.append(window)
        }

        return windows
    }

    struct BilledSpend: Equatable {
        let planUSD: Double
        let bonusUSD: Double
        let onDemandUSD: Double
        var totalUSD: Double { planUSD + onDemandUSD }
    }

    /// Cycle spend from usage-summary cents: plan usage (included + bonus) plus enabled on-demand spend.
    static func billedSpend(from json: [String: Any]) -> BilledSpend? {
        let individual = json["individualUsage"] as? [String: Any]
            ?? json["individual_usage"] as? [String: Any]
        let plan = (individual?["plan"] as? [String: Any])
            ?? (json["planUsage"] as? [String: Any])
            ?? (json["plan_usage"] as? [String: Any])
            ?? (individual?["overall"] as? [String: Any])
        let onDemand = (individual?["onDemand"] as? [String: Any])
            ?? (individual?["on_demand"] as? [String: Any])
        let breakdown = plan?["breakdown"] as? [String: Any]
        let planCents = breakdown.flatMap { number($0, keys: ["total"]) }
            ?? plan.flatMap { number($0, keys: ["used", "totalSpend", "total_spend", "includedSpend"]) }
        let bonusCents = breakdown.flatMap { number($0, keys: ["bonus"]) } ?? 0
        let onDemandCents: Double? = {
            guard let onDemand, (onDemand["enabled"] as? Bool) != false else { return nil }
            return number(onDemand, keys: ["used", "totalSpend", "total_spend"])
        }()
        guard planCents != nil || onDemandCents != nil else { return nil }
        return BilledSpend(
            planUSD: max(0, planCents ?? 0) / 100,
            bonusUSD: max(0, bonusCents) / 100,
            onDemandUSD: max(0, onDemandCents ?? 0) / 100
        )
    }

    /// `usedPercent` in 0...100. With a `breakdown` block (current API) the
    /// percent fields are percent used and authoritative; otherwise fall back
    /// to cents `used`/`limit`, then to legacy remaining-percent inversion.
    static func usedPercent(from object: [String: Any]?, percentKeys: [String]) -> Double? {
        guard let object else { return nil }

        // Current API: breakdown present → percents are percent used.
        let breakdownTotal = (object["breakdown"] as? [String: Any])
            .flatMap { number($0, keys: ["total"]) }
        if let breakdownTotal, breakdownTotal > 0 {
            for key in percentKeys {
                if let pct = number(object, keys: [key]) {
                    let scaled = pct <= 1 ? pct * 100 : pct
                    if scaled >= 0, scaled <= 100 {
                        return min(100, max(0, scaled))
                    }
                }
            }
            // Cents are only trustworthy when the limit spans the whole allowance, not just the included bucket.
            if let used = number(object, keys: ["used", "totalSpend", "total_spend", "includedSpend"]),
               let limit = number(object, keys: ["limit"]),
               limit >= breakdownTotal
            {
                return min(100, max(0, used / limit * 100))
            }
            return nil
        }

        if let used = number(object, keys: ["used", "totalSpend", "total_spend", "includedSpend"]),
           let limit = number(object, keys: ["limit", "total"]),
           limit > 0
        {
            return min(100, max(0, used / limit * 100))
        }

        // Legacy API: percent fields are percent remaining — invert them.
        for key in percentKeys {
            if let remaining = number(object, keys: [key]) {
                let pct = remaining <= 1 ? remaining * 100 : remaining
                if pct >= 0, pct <= 100 {
                    return min(100, max(0, 100 - pct))
                }
            }
        }
        return nil
    }

    private static func window(
        from object: [String: Any]?,
        percentKeys: [String],
        label: String,
        resetsAt: Date?,
        resetDescription: String?
    ) -> RateWindow? {
        guard let used = usedPercent(from: object, percentKeys: percentKeys) else {
            return nil
        }
        // `breakdown.total` is the whole allowance (included + bonus). `used`/`limit`
        // on the same object are only the included bucket, so a spent 2,000 included
        // plan reads as empty while thousands of bonus units remain.
        let breakdownTotal = (object?["breakdown"] as? [String: Any])
            .flatMap { number($0, keys: ["total"]) }
        let total: Double?
        let remaining: Double?
        if let breakdownTotal, breakdownTotal > 0 {
            // Percent used is not `included / breakdown.total`, so don't invent a
            // remaining from that product. Drop the included-only 0-of-2000 pair.
            total = breakdownTotal
            remaining = nil
        } else {
            remaining = number(object ?? [:], keys: ["remaining"])
            total = number(object ?? [:], keys: ["limit", "total"])
        }
        return RateWindow(
            usedPercent: used,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            label: label,
            remainingValue: remaining,
            totalValue: total,
            unitLabel: nil,
            displayStyle: .percent
        )
    }

    private static func number(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
