import SwiftUI

/// Canonical display names for usage provider IDs, shared by every usage surface so
/// "kiro" never renders as "Kiro CLI" in one place and "Kiro" in another.
enum UsageProviderNaming {
    static func displayName(forProviderID providerID: String) -> String {
        switch providerID.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        case "antigravity": return "Antigravity"
        case "copilot": return "Copilot"
        case "kiro": return "Kiro CLI"
        case "grok": return "Grok CLI"
        case "opencode", "opencode-go": return "OpenCode"
        case "zai", "z.ai": return "Z.AI"
        case "kimi": return "Kimi"
        case "qwen": return "Qwen"
        case "cursor": return "Cursor"
        case "codebuddy": return "CodeBuddy"
        case "gitlab": return "GitLab"
        case "kilo": return "Kilo"
        default: return providerID.capitalized
        }
    }

    /// Provider tint, resolved through `ServiceType` when the ID maps to one.
    static func tint(forProviderID providerID: String) -> Color {
        let id = providerID.lowercased()
        if id == "opencode" || id == "opencode-go" {
            return Color(red: 0.95, green: 0.55, blue: 0.20)
        }
        guard let type = ServiceType.allCases.first(where: { $0.usageProviderID == id }) else {
            return MenuBarDesign.accent
        }
        return MenuBarDesign.providerTint(for: type)
    }
}

/// "What did I use on this date" — a date picker plus that day's totals, the provider
/// used most, and the per-model breakdown.
///
/// Reads only the persisted day store via `UsageStore`, so switching dates is a
/// dictionary lookup rather than a filesystem scan.
struct UsageByDateView: View {
    @ObservedObject var usageStore: UsageStore
    /// Compact trims the model list for the narrow menu bar panel.
    var compact: Bool = false

    private var summary: DailyUsageSummary { usageStore.dailySummary }

    /// Clamp selection to [earliest recorded day ... today]. Days before the store's
    /// earliest entry hold no data by definition, so offering them invites confusion.
    private var dateRange: ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        guard let earliest = usageStore.earliestDayWithUsage?.date(),
              earliest < today
        else {
            // No history yet (or only today): a single-day range keeps the picker valid.
            return today...today
        }
        return earliest...today
    }

    private var selectedDate: Date {
        usageStore.selectedDay.date() ?? Calendar.current.startOfDay(for: Date())
    }

    private var isToday: Bool {
        usageStore.selectedDay == UsageDayKey(date: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            picker
            if summary.isEmpty {
                emptyState
            } else {
                totals
                if let top = summary.topProvider {
                    topProviderRow(top)
                }
                modelBreakdown
                if summary.hasApproximateData {
                    fidelityNote
                }
            }
        }
        .padding(DS.Space.lg)
        .cardSurface(tint: MenuBarDesign.accent)
    }

    // MARK: - Picker

    private var picker: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Usage on")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            DatePicker(
                "Usage on",
                selection: Binding(
                    get: { selectedDate },
                    set: { usageStore.selectDay(date: $0) }
                ),
                in: dateRange,
                displayedComponents: [.date]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .fixedSize()

            Spacer(minLength: 0)

            if !isToday {
                Button("Today") {
                    usageStore.selectDay(date: Date())
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MenuBarDesign.accent)
                .help("Jump back to today")
            }
        }
    }

    // MARK: - Totals

    private var totals: some View {
        HStack(spacing: DS.Space.lg) {
            stat(
                icon: "number",
                label: "Tokens",
                value: UsageNumberFormatter.tokens(summary.totalTokens, estimated: summary.totalEstimatedTokens),
                tint: .primary
            )
            Divider().frame(height: 28)
            stat(
                icon: "dollarsign.circle",
                label: "Est. API $",
                value: UsageNumberFormatter.usd(summary.totalCostUSD),
                tint: MenuBarDesign.accent
            )
            Divider().frame(height: 28)
            stat(
                icon: "arrow.triangle.2.circlepath",
                label: "Requests",
                value: UsageNumberFormatter.tokens(summary.totalRequests),
                tint: .primary
            )
        }
    }

    private func stat(icon: String, label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Top provider

    private func topProviderRow(_ top: DailyProviderUsage) -> some View {
        HStack(spacing: DS.Space.md) {
            Circle()
                .fill(UsageProviderNaming.tint(forProviderID: top.providerID))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text("Most used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(UsageProviderNaming.displayName(forProviderID: top.providerID))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                // Share is cost-based; nil when the day carries no cost signal, in which
                // case volume alone is the honest headline.
                if let share = summary.topProviderCostShare {
                    Text("\(Int((share * 100).rounded()))% of spend")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MenuBarDesign.accent)
                        .monospacedDigit()
                }
                Text(UsageNumberFormatter.volume(top.totalVolume, unit: top.volumeUnit))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Models

    private var modelBreakdown: some View {
        let rows = summary.modelsByCost
        let shown = compact ? Array(rows.prefix(5)) : Array(rows.prefix(12))

        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Models used")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DS.Space.sm) {
                    Circle()
                        .fill(UsageProviderNaming.tint(forProviderID: row.providerID))
                        .frame(width: 5, height: 5)
                    Text(row.usage.model)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.sm)
                    Text(UsageNumberFormatter.volume(row.usage.totalVolume, unit: row.usage.volumeUnit))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if row.usage.estimatedCostUSD > 0 {
                        Text(UsageNumberFormatter.usd(row.usage.estimatedCostUSD))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MenuBarDesign.accent)
                            .monospacedDigit()
                    }
                }
            }

            if rows.count > shown.count {
                Text("+\(rows.count - shown.count) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Caveats & empty state

    /// Grok pins a whole session to its last-activity day and Copilot keeps no per-model
    /// split, so those days are labelled rather than presented as exact.
    private var fidelityNote: some View {
        let notes = summary.providers
            .filter { !$0.models.isEmpty && $0.fidelity.isApproximate }
            .compactMap { provider -> String? in
                guard let caveat = provider.fidelity.caveat else { return nil }
                return "\(UsageProviderNaming.displayName(forProviderID: provider.providerID)): \(caveat)"
            }

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(notes, id: \.self) { note in
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8))
                    Text(note)
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("No usage recorded for this day")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Be explicit that history starts when tracking starts — an empty older date
            // is expected, not a bug.
            Text(
                usageStore.earliestDayWithUsage == nil
                    ? "History builds as VibeRouter scans your CLI sessions."
                    : "Recorded history starts \(usageStore.earliestDayWithUsage?.value ?? "—")."
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
