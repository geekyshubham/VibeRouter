import Foundation

/// One account's share of a provider pool: percent left in its longest window.
struct QuotaPoolAccount: Equatable {
    var remaining: Double
    var resetsAt: Date?
    var periodMinutes: Int
}

/// Pooled remaining percent at one moment (capacity = accounts × 100).
struct QuotaPoolSample: Codable, Equatable {
    let at: Date
    let remaining: Double
    let capacity: Double
}

struct QuotaProjection: Equatable {
    struct Point: Equatable {
        let at: Date
        let remaining: Double
    }

    struct Reset: Equatable {
        let at: Date
        let gain: Double
        let remainingAfter: Double
    }

    let points: [Point]
    let resets: [Reset]
    /// Every account empty at once.
    let poolEmptyAt: Date?
    /// The first single account to run dry.
    let firstEmptyAt: Date?
}

/// Pure pool math so the chart and the specs share one model.
enum QuotaPoolMath {
    /// Percent drained per hour over the last `hours`. Rises (resets, new
    /// accounts) are not negative burn, and a capacity change is skipped.
    static func burnPerHour(_ samples: [QuotaPoolSample], over hours: Double, now: Date) -> Double? {
        let start = now.addingTimeInterval(-hours * 3600)
        let sorted = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        var series = sorted.filter { $0.at >= start }
        if let baseline = sorted.last(where: { $0.at < start }) { series.insert(baseline, at: 0) }
        guard let first = series.first, let last = series.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 600 else { return nil }
        var drained = 0.0
        for (a, b) in zip(series, series.dropFirst()) where a.capacity == b.capacity {
            drained += max(0, a.remaining - b.remaining)
        }
        return drained / (span / 3600)
    }

    /// Steps forward draining `burnPerHour` evenly across accounts that still
    /// have quota, and refills each account to 100 at its reset.
    static func project(
        _ accounts: [QuotaPoolAccount],
        burnPerHour: Double,
        now: Date,
        horizon: TimeInterval,
        step: TimeInterval = 900
    ) -> QuotaProjection {
        guard !accounts.isEmpty else {
            return QuotaProjection(points: [], resets: [], poolEmptyAt: nil, firstEmptyAt: nil)
        }
        var remaining = accounts.map { min(100, max(0, $0.remaining)) }
        let periods = accounts.map { TimeInterval(max(1, $0.periodMinutes) * 60) }
        var nextReset: [Date?] = accounts.enumerated().map { index, account in
            guard var reset = account.resetsAt else { return nil }
            while reset <= now { reset += periods[index] }
            return reset
        }
        let burn = max(0, burnPerHour)
        var total: Double { remaining.reduce(0, +) }
        var points = [QuotaProjection.Point(at: now, remaining: total)]
        var resets: [QuotaProjection.Reset] = []
        var poolEmptyAt: Date? = burn > 0 && total <= 0 ? now : nil
        var firstEmptyAt: Date? = remaining.contains { $0 <= 0 } ? now : nil

        func drain(from start: Date, to end: Date) {
            let amount = burn * end.timeIntervalSince(start) / 3600
            guard amount > 0 else { return }
            let active = remaining.indices.filter { remaining[$0] > 1e-9 }
            if firstEmptyAt == nil, let smallest = active.map({ remaining[$0] }).min() {
                let hours = smallest * Double(active.count) / burn
                let at = start.addingTimeInterval(hours * 3600)
                if at <= end { firstEmptyAt = at }
            }
            if poolEmptyAt == nil, total > 0, total <= amount {
                poolEmptyAt = start.addingTimeInterval(total / burn * 3600)
            }
            var left = amount
            while left > 1e-9 {
                let open = remaining.indices.filter { remaining[$0] > 1e-9 }
                guard !open.isEmpty else { break }
                let share = left / Double(open.count)
                for index in open {
                    let take = min(remaining[index], share)
                    remaining[index] -= take
                    left -= take
                }
            }
        }

        let end = now.addingTimeInterval(horizon)
        var t = now
        while t < end {
            let stepEnd = min(end, t.addingTimeInterval(step))
            let reset = nextReset.compactMap { $0 }.filter { $0 <= stepEnd }.min()
            let event = reset ?? stepEnd
            drain(from: t, to: event)
            if let reset {
                let before = total
                for index in remaining.indices where nextReset[index] == reset {
                    remaining[index] = 100
                    nextReset[index] = reset.addingTimeInterval(periods[index])
                }
                let after = total
                points.append(.init(at: reset, remaining: before))
                points.append(.init(at: reset, remaining: after))
                if after - before > 0.5 {
                    resets.append(.init(at: reset, gain: after - before, remainingAfter: after))
                }
            } else {
                points.append(.init(at: event, remaining: total))
            }
            t = event
        }
        return QuotaProjection(points: points, resets: resets, poolEmptyAt: poolEmptyAt, firstEmptyAt: firstEmptyAt)
    }
}
