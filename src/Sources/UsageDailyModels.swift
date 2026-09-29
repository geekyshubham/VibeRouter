import Foundation

func analyticsCutoffStart(now: Date, historyDays: Int) -> Date {
    let lookback = max(0, historyDays - 1)
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
    return Calendar.current.startOfDay(for: cutoffDate)
}

/// Date-indexed usage types shared by the menu bar panel and the management console.
///
/// Why a separate day model at all: every local aggregator already buckets by
/// `Calendar.current.startOfDay` internally, then throws the per-day detail away and
/// publishes only "today" + "last 30 days" totals (see `LocalTokenCostScanner.scan`
/// and `LocalKiroCredits.costSnapshot`). Answering "what did I use on 12 July" needs
/// that detail kept, and kept across restarts.
///
/// Day keys are `yyyy-MM-dd` strings in the user's current calendar, not epochs.
/// The in-memory scanners key days by local `startOfDay` epoch, which silently shifts
/// if the machine changes timezone — fine for a value recomputed every scan, wrong for
/// something written to disk and re-read months later. ccusage stores date-key strings
/// for the same reason.
struct UsageDayKey: Hashable, Codable, Comparable, CustomStringConvertible {
    let value: String

    init(value: String) {
        self.value = value
    }

    init(date: Date, calendar: Calendar = .current) {
        self.value = UsageDayKey.formatter(for: calendar).string(from: date)
    }

    /// Local start-of-day epoch, matching the key the scanners bucket by.
    init(epoch: Int, calendar: Calendar = .current) {
        self.init(date: Date(timeIntervalSince1970: TimeInterval(epoch)), calendar: calendar)
    }

    func date(calendar: Calendar = .current) -> Date? {
        UsageDayKey.formatter(for: calendar).date(from: value)
    }

    var description: String { value }

    static func < (lhs: UsageDayKey, rhs: UsageDayKey) -> Bool {
        lhs.value < rhs.value
    }

    /// Fixed-format and locale-independent: a user in a non-Gregorian locale must not
    /// get day keys that fail to round-trip.
    private static func formatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// One model's usage on one day for one provider.
struct DailyModelUsage: Codable, Equatable {
    let model: String
    /// Uncached input only; cache reads and writes are reported separately.
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int = 0
    /// Volume in `volumeUnit` (tokens, millicredits, or estimated tokens).
    var totalVolume: Int
    var estimatedCostUSD: Double
    var requestCount: Int
    let volumeUnit: UsageVolumeUnit

    mutating func merge(_ other: DailyModelUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        totalVolume += other.totalVolume
        estimatedCostUSD += other.estimatedCostUSD
        requestCount += other.requestCount
    }
}

extension DailyModelUsage {
    /// Rows written before `cacheWriteTokens` existed decode with 0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        totalVolume = try container.decode(Int.self, forKey: .totalVolume)
        estimatedCostUSD = try container.decode(Double.self, forKey: .estimatedCostUSD)
        requestCount = try container.decode(Int.self, forKey: .requestCount)
        volumeUnit = try container.decode(UsageVolumeUnit.self, forKey: .volumeUnit)
    }
}

/// How precisely a provider's usage can be attributed to a specific calendar day.
///
/// Not cosmetic: Grok sessions without usage.json pin a whole session's estimate to its
/// last-activity day, and Copilot JetBrains transcripts have no per-model split.
/// Presenting those as exact per-day figures next to Codex/Claude would be dishonest.
enum DailyUsageFidelity: String, Codable, Equatable {
    /// Per-event timestamps bucketed per day, with a real per-model split.
    case exact
    /// Correct day totals, but no trustworthy per-model split for that day.
    case dayTotalsOnly
    /// A whole session's volume attributed to a single day; multi-day sessions smear.
    case sessionApproximate
    /// Some source logs could not be read, so the day may be understated.
    case partial
    /// Written by an older build whose source logs are gone, so it cannot be re-verified.
    case legacy

    var isApproximate: Bool { self != .exact }

    /// Short UI note, or nil when the number needs no caveat.
    var caveat: String? {
        switch self {
        case .exact: return nil
        case .dayTotalsOnly: return "day total only — no per-model split"
        case .sessionApproximate: return "approximate — whole sessions land on one day"
        case .partial: return "partial — some session logs could not be read"
        case .legacy: return "from an older build, unverified"
        }
    }
}

/// Day range a provider's scan fully covers, plus the source files it read (path -> mtime).
/// Inside the range the scan is authoritative: stored days it did not report had no usage.
struct DailyScanCoverage: Equatable {
    let from: UsageDayKey
    let through: UsageDayKey
    var sources: [String: Double] = [:]
}

/// One provider's result from one scan sweep. `coverage` is nil when the scan failed or
/// cannot prove completeness, in which case its rows only replace, never delete.
struct ProviderDailyScan: Equatable {
    let providerID: String
    let days: [UsageDayKey: DailyProviderUsage]
    let coverage: DailyScanCoverage?

    var isAuthoritative: Bool { coverage != nil }
}

/// One provider's usage on one day.
struct DailyProviderUsage: Codable, Equatable {
    let providerID: String
    var models: [DailyModelUsage]
    let volumeUnit: UsageVolumeUnit
    let fidelity: DailyUsageFidelity

    /// Sums only rows in the provider's own unit: no estimates in exact tokens, no tokens in millicredits.
    var totalVolume: Int {
        models.filter { $0.volumeUnit == volumeUnit }.reduce(0) { $0 + $1.totalVolume }
    }
    var totalCostUSD: Double { models.reduce(0) { $0 + $1.estimatedCostUSD } }
    var requestCount: Int { models.reduce(0) { $0 + $1.requestCount } }

    /// Exact tokens that may be summed into a cross-provider token total.
    var tokenLikeVolume: Int { volumeUnit == .tokens ? totalVolume : 0 }

    /// Estimated tokens from any row, whatever the provider's unit (Kiro, Grok, Cursor, Copilot).
    var estimatedTokenVolume: Int {
        models.filter { $0.volumeUnit == .estimatedTokens }.reduce(0) { $0 + $1.totalVolume }
    }
}

/// Everything the UI needs to answer "what did I use on this date".
struct DailyUsageSummary: Codable, Equatable {
    let day: UsageDayKey
    let providers: [DailyProviderUsage]

    /// Sum of exact tokens only. Kiro millicredits are deliberately excluded —
    /// adding them to tokens would inflate the total by ~1000× per credit.
    var totalTokens: Int { providers.reduce(0) { $0 + $1.tokenLikeVolume } }

    /// Estimated tokens, shown beside `totalTokens` as "+N est", never added to it.
    var totalEstimatedTokens: Int { providers.reduce(0) { $0 + $1.estimatedTokenVolume } }

    /// Costs are commensurable across every unit, so this total is always meaningful.
    var totalCostUSD: Double { providers.reduce(0) { $0 + $1.totalCostUSD } }

    var totalRequests: Int { providers.reduce(0) { $0 + $1.requestCount } }

    var isEmpty: Bool { providers.allSatisfy { $0.models.isEmpty } }

    /// Providers ranked by API-equivalent cost.
    ///
    /// Cost is the ONLY defensible basis for "which provider did I use most": ranking
    /// Kiro's millicredits against Codex's tokens compares unlike units, and every
    /// aggregator populates `estimatedCostUSD` (Kiro as credits × the $0.04 overage rate, an estimate).
    /// Ties break on volume within a unit, then provider ID for a stable order.
    var providersByCost: [DailyProviderUsage] {
        providers
            .filter { !$0.models.isEmpty }
            .sorted {
                if $0.totalCostUSD != $1.totalCostUSD { return $0.totalCostUSD > $1.totalCostUSD }
                if $0.volumeUnit == $1.volumeUnit, $0.totalVolume != $1.totalVolume {
                    return $0.totalVolume > $1.totalVolume
                }
                return $0.providerID < $1.providerID
            }
    }

    /// The provider used most that day, by cost.
    var topProvider: DailyProviderUsage? { providersByCost.first }

    /// Share of the day's total cost attributable to `topProvider`, 0...1.
    /// Nil when the day has no cost signal, so callers show volume instead of a bogus 0%.
    var topProviderCostShare: Double? {
        guard let top = topProvider, totalCostUSD > 0 else { return nil }
        return top.totalCostUSD / totalCostUSD
    }

    /// Models across all providers, ranked by cost then volume.
    /// Credit-unit rows keep their own identity so they never merge with token rows
    /// of the same name (mirrors the merge-key logic in `AnalyticsEngine.overview`).
    var modelsByCost: [(providerID: String, usage: DailyModelUsage)] {
        providers
            .flatMap { provider in provider.models.map { (provider.providerID, $0) } }
            .sorted {
                if $0.1.estimatedCostUSD != $1.1.estimatedCostUSD {
                    return $0.1.estimatedCostUSD > $1.1.estimatedCostUSD
                }
                if $0.1.volumeUnit == $1.1.volumeUnit, $0.1.totalVolume != $1.1.totalVolume {
                    return $0.1.totalVolume > $1.1.totalVolume
                }
                return $0.1.model < $1.1.model
            }
            .map { (providerID: $0.0, usage: $0.1) }
    }

    /// True when any contributing provider can only place usage on a day approximately.
    var hasApproximateData: Bool {
        providers.contains { !$0.models.isEmpty && $0.fidelity.isApproximate }
    }

    static func empty(day: UsageDayKey) -> DailyUsageSummary {
        DailyUsageSummary(day: day, providers: [])
    }
}
