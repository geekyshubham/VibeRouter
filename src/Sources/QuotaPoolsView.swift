import SwiftUI
import Charts

/// Pooled quota per provider: what is left across every account, how fast it
/// drains, and when resets refill it. Solid is recorded, dashed is projected.
struct QuotaPoolsView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject private var history = QuotaHistoryStore.shared
    var compact: Bool = false

    @State private var filter: String? = nil
    @State private var burnHours: Double = 3

    private struct Pool: Identifiable {
        let id: String
        let accounts: [QuotaPoolAccount]
        var capacity: Double { Double(accounts.count * 100) }
        var remaining: Double { accounts.reduce(0) { $0 + $1.remaining } }
    }

    private var pools: [Pool] {
        QuotaHistoryStore.pools(from: usageStore.allSnapshots)
            .map { Pool(id: $0.key, accounts: $0.value) }
            .sorted { $0.accounts.count != $1.accounts.count ? $0.accounts.count > $1.accounts.count : $0.id < $1.id }
    }

    var body: some View {
        let all = pools
        VStack(alignment: .leading, spacing: compact ? DS.Space.lg : DS.Space.xl) {
            header(all)
            if all.isEmpty {
                Text(usageStore.isRefreshing ? "Reading quota from your accounts" : "Quota appears here once a connected account reports its limits")
                    .font(DS.Font.label)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.lg)
                    .cardSurface(tint: Palette.accent)
            } else {
                if all.count > 1 { filterBar(all) }
                ForEach(all.filter { filter == nil || $0.id == filter }) { pool in
                    PoolCard(
                        providerID: pool.id,
                        accounts: pool.accounts,
                        samples: history.samples[pool.id] ?? [],
                        burnHours: burnHours,
                        compact: compact
                    )
                }
            }
        }
    }

    private func header(_ all: [Pool]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            Text("Quota pools")
                .font(.system(size: compact ? 13 : 17, weight: .medium))
                .foregroundStyle(Palette.text)
            Text("\(all.reduce(0) { $0 + $1.accounts.count }) accounts")
                .font(DS.Font.meta)
                .foregroundStyle(Palette.textMuted)
            Spacer()
            Text("Burn")
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
            Picker("Burn window", selection: $burnHours) {
                Text("1h").tag(1.0)
                Text("3h").tag(3.0)
                Text("6h").tag(6.0)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 112)
        }
    }

    private func filterBar(_ all: [Pool]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                chip(title: "All", count: all.reduce(0) { $0 + $1.accounts.count }, id: nil, tint: nil)
                ForEach(all) { pool in
                    chip(title: UsageProviderNaming.displayName(forProviderID: pool.id),
                         count: pool.accounts.count, id: pool.id,
                         tint: UsageProviderNaming.tint(forProviderID: pool.id))
                }
            }
        }
    }

    private func chip(title: String, count: Int, id: String?, tint: Color?) -> some View {
        let selected = filter == id
        return Button { filter = id } label: {
            HStack(spacing: DS.Space.sm) {
                if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                Text("\(count)")
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Palette.surface : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? Palette.hairline : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// One provider's pool: headline figure, the four numbers that decide what to
/// burn next, and the chart.
private struct PoolCard: View {
    let providerID: String
    let accounts: [QuotaPoolAccount]
    let samples: [QuotaPoolSample]
    let burnHours: Double
    let compact: Bool

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let at: Date
        let remaining: Double
        let series: String
    }

    var body: some View {
        let now = Date()
        let capacity = Double(accounts.count * 100)
        let remaining = accounts.reduce(0) { $0 + $1.remaining }
        let burn = QuotaPoolMath.burnPerHour(samples, over: burnHours, now: now)
        let horizon: TimeInterval = (compact ? 3 : 7) * 86_400
        let projection = QuotaPoolMath.project(accounts, burnPerHour: burn ?? 0, now: now, horizon: horizon)
        let tint = UsageProviderNaming.tint(forProviderID: providerID)
        let nextReset = projection.resets.first

        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.sm) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(UsageProviderNaming.displayName(forProviderID: providerID))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(accounts.count == 1 ? "1 account" : "\(accounts.count) accounts")
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: DS.Space.xxl) {
                    headline(remaining: remaining, capacity: capacity)
                    Spacer(minLength: DS.Space.lg)
                    stats(projection: projection, nextReset: nextReset, burn: burn, now: now)
                }
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    headline(remaining: remaining, capacity: capacity)
                    stats(projection: projection, nextReset: nextReset, burn: burn, now: now)
                }
            }

            chart(projection: projection, capacity: capacity, tint: tint, now: now, horizon: horizon)
                .frame(height: compact ? 132 : 200)

            HStack(spacing: DS.Space.lg) {
                legend("Recorded", dashed: false, tint: tint)
                legend("Projected", dashed: true, tint: tint)
                Spacer()
                if burn == nil {
                    Text("Projection starts after a few refreshes")
                        .font(DS.Font.label)
                        .foregroundStyle(Palette.textMuted)
                }
            }
        }
        .padding(compact ? DS.Space.lg : DS.Space.xl)
        .cardSurface(tint: tint, cornerRadius: compact ? 12 : 14)
    }

    private func headline(remaining: Double, capacity: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text("\(Int(remaining.rounded()))%")
                .font(compact ? DS.Font.figure : DS.Font.display)
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
            Text("left of \(Int(capacity))%")
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func stats(projection: QuotaProjection, nextReset: QuotaProjection.Reset?, burn: Double?, now: Date) -> some View {
        HStack(alignment: .top, spacing: compact ? DS.Space.lg : DS.Space.xxl) {
            stat("Pool empty", projection.poolEmptyAt.map { ResetCountdownFormatter.absoluteTime($0) }
                 ?? (burn == nil ? "—" : "Not in range"),
                 emphasis: projection.poolEmptyAt != nil)
            stat("First empty", projection.firstEmptyAt.map {
                $0 <= now ? "Now" : ResetCountdownFormatter.countdown(until: $0, now: now)
            } ?? "—", emphasis: projection.firstEmptyAt.map { $0 <= now } ?? false)
            if !compact {
                stat("Next reset", nextReset.map { "+\(Int($0.gain.rounded()))% · \(ResetCountdownFormatter.countdown(until: $0.at, now: now))" } ?? "—")
            }
            stat("Burn, \(Int(burnHours))h", burn.map { String(format: "%.1f%%/h", $0) } ?? "—")
        }
    }

    private func stat(_ label: String, _ value: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(emphasis ? MenuBarDesign.warning : Palette.text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ title: String, dashed: Bool, tint: Color) -> some View {
        HStack(spacing: DS.Space.sm) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
            .frame(width: 14, height: 2)
            Text(title)
                .font(DS.Font.label)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func chart(projection: QuotaProjection, capacity: Double, tint: Color, now: Date, horizon: TimeInterval) -> some View {
        // Start at the oldest sample in range so a fresh install isn't days of blank axis.
        let earliest = now.addingTimeInterval(-(compact ? 1 : 3) * 86_400)
        let oldest = samples.map(\.at).filter { $0 >= earliest }.min() ?? now
        let start = min(oldest, now.addingTimeInterval(-6 * 3600))
        var recorded = samples
            .filter { $0.at >= start && $0.at <= now }
            .map { ChartPoint(at: $0.at, remaining: $0.remaining, series: "Recorded") }
        let current = projection.points.first?.remaining ?? 0
        recorded.append(ChartPoint(at: now, remaining: current, series: "Recorded"))
        let projected = projection.points.map { ChartPoint(at: $0.at, remaining: $0.remaining, series: "Projected") }
        let labelled = Array(projection.resets.prefix(compact ? 3 : 8))

        return Chart {
            ForEach(recorded) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Left", point.remaining), series: .value("Series", "RecordedArea"))
                    .foregroundStyle(tint.opacity(0.12))
                LineMark(x: .value("Time", point.at), y: .value("Left", point.remaining), series: .value("Series", point.series))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineJoin: .round))
            }
            ForEach(projected) { point in
                LineMark(x: .value("Time", point.at), y: .value("Left", point.remaining), series: .value("Series", point.series))
                    .foregroundStyle(tint.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
            }
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Palette.textMuted.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("Now").font(DS.Font.meta).foregroundStyle(Palette.textMuted)
                }
            PointMark(x: .value("Time", now), y: .value("Left", current))
                .foregroundStyle(tint)
                .symbolSize(24)
            ForEach(labelled, id: \.at) { reset in
                PointMark(x: .value("Time", reset.at), y: .value("Left", reset.remainingAfter))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2) {
                        Text("+\(Int(reset.gain.rounded()))%")
                            .font(DS.Font.meta)
                            .foregroundStyle(Palette.textSecondary)
                    }
            }
            if let empty = projection.poolEmptyAt {
                PointMark(x: .value("Time", empty), y: .value("Left", 0))
                    .foregroundStyle(MenuBarDesign.warning)
                    .symbolSize(28)
            }
        }
        .chartXScale(domain: start...now.addingTimeInterval(horizon))
        .chartYScale(domain: 0...max(capacity, 100) * 1.08)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, capacity / 2, capacity]) { value in
                AxisGridLine().foregroundStyle(Palette.chartGrid)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))%").font(DS.Font.meta).foregroundStyle(Palette.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisGridLine().foregroundStyle(Palette.chartGrid)
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: false)
                    .font(DS.Font.meta)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .accessibilityLabel("\(UsageProviderNaming.displayName(forProviderID: providerID)) pooled quota, \(Int(current)) of \(Int(capacity)) percent left")
    }
}
