import Foundation

/// How a quota row should be presented in the UI.
enum QuotaDisplayStyle: String, Codable, Equatable {
    /// Default for Codex/Claude/Antigravity — percent used/left.
    case percent
    /// Absolute credits/units remaining (Kiro, Grok credits, prepaid pools).
    case creditsRemaining
}

struct RateWindow: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
    /// Human-readable title such as "Claude Opus", "5-hour", or "Premium".
    let label: String?
    /// Absolute remaining amount when the provider exposes credits/units.
    let remainingValue: Double?
    /// Absolute total/limit when known.
    let totalValue: Double?
    /// Unit label for absolute values, e.g. "credits".
    let unitLabel: String?
    let displayStyle: QuotaDisplayStyle

    init(
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetDescription: String? = nil,
        label: String? = nil,
        remainingValue: Double? = nil,
        totalValue: Double? = nil,
        unitLabel: String? = nil,
        displayStyle: QuotaDisplayStyle = .percent
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.label = label
        self.remainingValue = remainingValue
        self.totalValue = totalValue
        self.unitLabel = unitLabel
        self.displayStyle = displayStyle
    }

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var windowLabel: String {
        if let minutes = windowMinutes, minutes > 0 {
            if minutes < 120 { return "\(minutes)m" }
            if minutes < 2880 { return "\(minutes / 60)h" }
            return "\(minutes / 1440)d"
        }
        return ""
    }

    /// Prefer an explicit label, otherwise fall back to the window duration.
    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        return windowLabel
    }

    /// Primary headline for the quota row (percent or absolute credits).
    var primaryMetricText: String {
        switch displayStyle {
        case .creditsRemaining:
            if let remaining = remainingValue {
                let unit = unitLabel ?? "credits"
                if let total = totalValue, total > 0 {
                    return "\(formatAmount(remaining)) / \(formatAmount(total)) \(unit)"
                }
                return "\(formatAmount(remaining)) \(unit) left"
            }
            fallthrough
        case .percent:
            let used = usedPercent
            let remaining = remainingPercent
            let usedText = (used > 0 && used < 1) ? "<1% used" : "\(Int(used.rounded()))% used"
            let leftText = (remaining > 0 && remaining < 1) ? "<1% left" : "\(Int(remaining.rounded()))% left"
            return "\(usedText) · \(leftText)"
        }
    }

    private func formatAmount(_ value: Double) -> String {
        if value >= 1000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
        }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

/// One ChatGPT workspace / subscription under a single OAuth login (e.g. Go vs Team).
struct ProviderUsageSubAccount: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let planType: String?
    let windows: [RateWindow]
    let errorMessage: String?
}

struct ProviderUsageIdentity: Codable, Equatable {
    let accountEmail: String?
    let accountOrganization: String?
    let loginMethod: String?
}

struct ProviderUsagePayload: Codable, Equatable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let updatedAt: Date?
    let identity: ProviderUsageIdentity?
    let accountEmail: String?
}

/// Manual rate-limit reset bank shared across providers
/// (ChatGPT/Codex "Full reset" credits, SuperGrok one-time usage resets, …).
struct RateLimitResetBank: Equatable {
    /// Still-usable resets (available and not expired).
    let availableCount: Int
    /// Soonest expiry among available resets, if any.
    let nextExpiresAt: Date?
    /// Product title e.g. "Full reset (Weekly + 5 hr)".
    let sampleTitle: String?
    /// Whether VibeRouter can redeem/consume a reset programmatically.
    let canRedeem: Bool

    init(
        availableCount: Int,
        nextExpiresAt: Date? = nil,
        sampleTitle: String? = nil,
        canRedeem: Bool = true
    ) {
        self.availableCount = availableCount
        self.nextExpiresAt = nextExpiresAt
        self.sampleTitle = sampleTitle
        self.canRedeem = canRedeem
    }

    var summaryLine: String {
        if availableCount <= 0 {
            return "No rate-limit resets left"
        }
        let noun = availableCount == 1 ? "reset" : "resets"
        var line = "\(availableCount) rate-limit \(noun) left"
        if let nextExpiresAt {
            line += " · next expires \(ResetCountdownFormatter.shortDate(nextExpiresAt))"
        }
        return line
    }
}

/// Back-compat alias — the bank is no longer Codex-only (Grok ships one too).
typealias CodexRateLimitResetCredits = RateLimitResetBank

struct ProviderUsageSnapshot: Equatable, Identifiable {
    let id: String
    let providerID: String
    let source: String?
    /// Ordered quota rows shown in the UI (most important first).
    let windows: [RateWindow]
    /// Multi-subscription rows (ChatGPT Go + Team/Enterprise under one login).
    let subAccounts: [ProviderUsageSubAccount]
    let accountEmail: String?
    /// Raw plan token such as "go", "team", "enterprise".
    let planType: String?
    /// Pretty plan / workspace label for the primary row.
    let planLabel: String?
    /// Manual rate-limit reset inventory (ChatGPT/Codex, SuperGrok, …).
    let rateLimitResets: RateLimitResetBank?
    let updatedAt: Date?
    let errorMessage: String?
    let isRefreshing: Bool

    var primary: RateWindow? { windows.first }
    var secondary: RateWindow? { windows.count > 1 ? windows[1] : nil }
    var tertiary: RateWindow? { windows.count > 2 ? windows[2] : nil }

    init(
        id: String,
        providerID: String,
        source: String? = nil,
        windows: [RateWindow] = [],
        subAccounts: [ProviderUsageSubAccount] = [],
        accountEmail: String? = nil,
        planType: String? = nil,
        planLabel: String? = nil,
        rateLimitResets: RateLimitResetBank? = nil,
        updatedAt: Date? = nil,
        errorMessage: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.source = source
        self.windows = windows
        self.subAccounts = subAccounts
        self.accountEmail = accountEmail
        self.planType = planType
        self.planLabel = planLabel
        self.rateLimitResets = rateLimitResets
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.isRefreshing = isRefreshing
    }

    /// Back-compat constructor used by existing call sites during migration.
    init(
        id: String,
        providerID: String,
        source: String?,
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow?,
        accountEmail: String?,
        updatedAt: Date?,
        errorMessage: String?,
        isRefreshing: Bool
    ) {
        self.init(
            id: id,
            providerID: providerID,
            source: source,
            windows: [primary, secondary, tertiary].compactMap { $0 },
            subAccounts: [],
            accountEmail: accountEmail,
            planType: nil,
            planLabel: nil,
            rateLimitResets: nil,
            updatedAt: updatedAt,
            errorMessage: errorMessage,
            isRefreshing: isRefreshing
        )
    }

    static func empty(
        authAccountID: String,
        providerID: String,
        accountEmail: String? = nil,
        error: String? = nil,
        refreshing: Bool = false
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: authAccountID,
            providerID: providerID,
            source: nil,
            windows: [],
            subAccounts: [],
            accountEmail: accountEmail,
            planType: nil,
            planLabel: nil,
            rateLimitResets: nil,
            updatedAt: nil,
            errorMessage: error,
            isRefreshing: refreshing
        )
    }
}

struct ProviderCostSnapshot: Equatable, Identifiable {
    let id: String
    let providerID: String
    /// Session ("today") volume in `volumeUnit` (tokens or millicredits for credits).
    let sessionTokens: Int
    let sessionCostUSD: Double?
    /// Rolling analytics window volume in `volumeUnit` (not necessarily a billing period).
    let last30DaysTokens: Int
    let last30DaysCostUSD: Double?
    /// Top models by volume (analytics window).
    let models: [ModelTokenUsage]
    /// Unit for session/last30Days volume fields.
    let volumeUnit: UsageVolumeUnit
    let updatedAt: Date?

    init(
        id: String,
        providerID: String,
        sessionTokens: Int,
        sessionCostUSD: Double?,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double?,
        models: [ModelTokenUsage] = [],
        volumeUnit: UsageVolumeUnit = .tokens,
        updatedAt: Date?
    ) {
        self.id = id
        self.providerID = providerID
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.models = models
        self.volumeUnit = volumeUnit
        self.updatedAt = updatedAt
    }
}

struct AnalyticsOverview: Equatable {
    let totalTokens30d: Int
    let totalCostUSD30d: Double
    let totalTokensSession: Int
    let totalCostUSDSession: Double
    let byProvider: [ProviderCostSnapshot]
    let topModels: [ModelTokenUsage]
    let generatedAt: Date
}

enum ChatGPTPlanFormatter {
    /// Rank paid plans so we never demote Enterprise/Team to JWT "go".
    private static let planRank: [String: Int] = [
        "enterprise": 100,
        "business": 90,
        "team": 80,
        "edu": 70,
        "education": 70,
        "pro": 60,
        "prolite": 55,
        "pro_lite": 55,
        "plus": 50,
        "go": 40,
        "free": 10,
        "api_key": 5,
        "api-key": 5,
    ]

    /// Canonical plan token (enterprise, plus, go, …).
    static func normalizePlanType(
        _ raw: String?,
        structure: String? = nil,
        workspaceName: String? = nil
    ) -> String? {
        guard var plan = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else {
            return inferFromWorkspace(structure: structure, workspaceName: workspaceName)
        }
        plan = plan.lowercased()
            .replacingOccurrences(of: "chatgpt_", with: "")
            .replacingOccurrences(of: "chatgpt-", with: "")
            .replacingOccurrences(of: " ", with: "_")

        // Common aliases from JWT / memberships / usage payloads.
        switch plan {
        case "chatgptplus", "chatgpt_plus", "plus_plan", "plus-plan": plan = "plus"
        case "chatgptpro", "chatgpt_pro", "pro20", "pro_20", "pro-20x", "pro20x": plan = "pro"
        case "pro5", "pro_5", "pro-5x", "pro5x", "prolite", "pro-lite": plan = "prolite"
        case "chatgptteam", "chatgpt_team", "team_plan": plan = "team"
        case "chatgptenterprise", "chatgpt_enterprise", "enterprise_plan", "ent": plan = "enterprise"
        case "chatgptbusiness", "chatgpt_business": plan = "business"
        case "chatgptgo", "chatgpt_go", "go_plan": plan = "go"
        case "self_serve_business", "self-serve-business": plan = "business"
        default: break
        }

        // Workspace seats often still ship JWT plan_type=go for personal default account.
        // Prefer structure / name signals when raw plan looks too weak.
        if let inferred = inferFromWorkspace(structure: structure, workspaceName: workspaceName) {
            return higherPlan(plan, inferred)
        }
        return plan
    }

    /// Prefer the highest-signal plan among usage payload, membership, and JWT.
    static func preferredPlanType(
        usagePlan: String?,
        membershipPlan: String?,
        jwtPlan: String?,
        structure: String? = nil,
        workspaceName: String? = nil
    ) -> String? {
        let candidates = [
            normalizePlanType(usagePlan, structure: structure, workspaceName: workspaceName),
            normalizePlanType(membershipPlan, structure: structure, workspaceName: workspaceName),
            normalizePlanType(jwtPlan, structure: structure, workspaceName: workspaceName),
        ].compactMap { $0 }

        guard !candidates.isEmpty else {
            return inferFromWorkspace(structure: structure, workspaceName: workspaceName)
        }
        return candidates.max { rank(of: $0) < rank(of: $1) }
    }

    /// Human-readable plan names for Codex / ChatGPT subscription types.
    static func displayName(for planType: String?) -> String? {
        guard let normalized = normalizePlanType(planType) else { return nil }
        switch normalized {
        case "go": return "ChatGPT Go"
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "prolite": return "ChatGPT Pro 5x"
        case "team": return "ChatGPT Team"
        case "enterprise": return "ChatGPT Enterprise"
        case "business": return "ChatGPT Business"
        case "free": return "ChatGPT Free"
        case "edu", "education": return "ChatGPT Education"
        case "api_key", "api-key": return "API Key"
        default:
            return normalized
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    static func subscriptionTitle(planType: String?, workspaceName: String?, structure: String?) -> String {
        let normalized = preferredPlanType(
            usagePlan: planType,
            membershipPlan: nil,
            jwtPlan: nil,
            structure: structure,
            workspaceName: workspaceName
        )
        let plan = displayName(for: normalized) ?? "ChatGPT"
        if let workspaceName, !workspaceName.isEmpty {
            // Avoid "ChatGPT Go · Acme Enterprise" when name already signals tier.
            return "\(plan) · \(workspaceName)"
        }
        if let structure, structure.lowercased() == "workspace" {
            return "\(plan) (workspace)"
        }
        if let structure, structure.lowercased() == "personal" {
            return "\(plan) (personal)"
        }
        return plan
    }

    private static func rank(of plan: String) -> Int {
        planRank[plan.lowercased()] ?? 20
    }

    private static func higherPlan(_ a: String, _ b: String) -> String {
        rank(of: a) >= rank(of: b) ? a : b
    }

    private static func inferFromWorkspace(structure: String?, workspaceName: String?) -> String? {
        let blob = [structure, workspaceName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !blob.isEmpty else { return nil }
        if blob.contains("enterprise") { return "enterprise" }
        if blob.contains("business") { return "business" }
        if blob.contains("team") || blob.contains("workspace") { return "team" }
        if blob.contains("education") || blob.contains("edu") { return "edu" }
        if blob.contains("plus") { return "plus" }
        return nil
    }
}

enum AnalyticsEngine {
    static func overview(from costs: [ProviderCostSnapshot], now: Date = Date()) -> AnalyticsOverview {
        // Only token-like units feed global volume totals (exclude Kiro credits).
        let tokenLike = costs.filter { $0.volumeUnit.aggregatesAsTokens }
        let totalTokens30d = tokenLike.reduce(0) { $0 + $1.last30DaysTokens }
        let totalCost30d = costs.reduce(0.0) { $0 + ($1.last30DaysCostUSD ?? 0) }
        let totalTokensSession = tokenLike.reduce(0) { $0 + $1.sessionTokens }
        let totalCostSession = costs.reduce(0.0) { $0 + ($1.sessionCostUSD ?? 0) }

        var modelMerge: [String: (ModelTokenUsage, String)] = [:]
        for cost in costs {
            for model in cost.models {
                // Namespace credit/est models so they never merge with real token rows.
                let mergeKey: String = {
                    switch model.volumeUnit {
                    case .tokens: return model.model
                    case .credits: return "\(cost.providerID):credits:\(model.model)"
                    case .estimatedTokens: return "\(cost.providerID):est:\(model.model)"
                    }
                }()
                if let existing = modelMerge[mergeKey] {
                    // Only merge when units match.
                    guard existing.0.volumeUnit == model.volumeUnit else {
                        continue
                    }
                    let merged = ModelTokenUsage(
                        model: model.model,
                        inputTokens: existing.0.inputTokens + model.inputTokens,
                        outputTokens: existing.0.outputTokens + model.outputTokens,
                        cacheReadTokens: existing.0.cacheReadTokens + model.cacheReadTokens,
                        totalTokens: existing.0.totalTokens + model.totalTokens,
                        estimatedCostUSD: existing.0.estimatedCostUSD + model.estimatedCostUSD,
                        requestCount: existing.0.requestCount + model.requestCount,
                        volumeUnit: model.volumeUnit
                    )
                    modelMerge[mergeKey] = (merged, existing.1)
                } else {
                    modelMerge[mergeKey] = (model, cost.providerID)
                }
            }
        }

        // Rank primarily by API-equivalent $ when present; fall back to unit-local volume.
        let topModels = modelMerge.values
            .map(\.0)
            .sorted {
                if $0.estimatedCostUSD != $1.estimatedCostUSD {
                    return $0.estimatedCostUSD > $1.estimatedCostUSD
                }
                return $0.totalTokens > $1.totalTokens
            }
            .prefix(12)
            .map { $0 }

        return AnalyticsOverview(
            totalTokens30d: totalTokens30d,
            totalCostUSD30d: totalCost30d,
            totalTokensSession: totalTokensSession,
            totalCostUSDSession: totalCostSession,
            byProvider: costs.sorted { ($0.last30DaysCostUSD ?? 0) > ($1.last30DaysCostUSD ?? 0) },
            topModels: Array(topModels),
            generatedAt: now
        )
    }
}

extension ServiceType {
    var usageProviderID: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .copilot: return "copilot"
        case .antigravity: return "antigravity"
        case .kimi: return "kimi"
        case .kiro: return "kiro"
        case .grok: return "grok"
        case .zai: return "zai"
        case .cursor: return "cursor"
        case .codebuddy: return "codebuddy"
        case .codebuddyCN: return "codebuddy-cn"
        case .gitlab: return "gitlab"
        case .kilo: return "kilo"
        case .windsurf: return "windsurf"
        case .qoder: return "qoder"
        case .trae: return "trae"
        case .zed: return "zed"
        case .opencodeGo: return ProviderCatalog.openCodeGoProviderName
        case .qwen: return nil
        }
    }
}
