import Foundation

/// Compile and run from the repo root:
///   swiftc -O -o /tmp/quota-pool-math-spec \
///     src/Verification/QuotaPoolMathSpec.swift \
///     src/Sources/QuotaPoolMath.swift && /tmp/quota-pool-math-spec
@main
struct QuotaPoolMathSpec {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 3600

        // Burn ignores resets and counts only drops.
        let samples = [
            QuotaPoolSample(at: now.addingTimeInterval(-3 * hour), remaining: 160, capacity: 200),
            QuotaPoolSample(at: now.addingTimeInterval(-2 * hour), remaining: 154, capacity: 200),
            QuotaPoolSample(at: now.addingTimeInterval(-1 * hour), remaining: 190, capacity: 200),
            QuotaPoolSample(at: now, remaining: 184, capacity: 200),
        ]
        let burn = QuotaPoolMath.burnPerHour(samples, over: 3, now: now)!
        precondition(abs(burn - 4) < 0.001, "12 points drained over 3h = 4%/h, got \(burn)")
        precondition(QuotaPoolMath.burnPerHour([samples[3]], over: 3, now: now) == nil, "one sample has no rate")

        // Two accounts, 10%/h: account A (20%) runs dry first, pool after 13h.
        let accounts = [
            QuotaPoolAccount(remaining: 20, resetsAt: nil, periodMinutes: 10_080),
            QuotaPoolAccount(remaining: 110, resetsAt: nil, periodMinutes: 10_080),
        ]
        let drained = QuotaPoolMath.project(accounts, burnPerHour: 10, now: now, horizon: 24 * hour)
        let firstHours = drained.firstEmptyAt!.timeIntervalSince(now) / hour
        let poolHours = drained.poolEmptyAt!.timeIntervalSince(now) / hour
        precondition(abs(firstHours - 4) < 0.01, "A empties at 4h (20 / 5%/h), got \(firstHours)")
        precondition(abs(poolHours - 12) < 0.01, "pool of 120 empties at 12h, got \(poolHours)")
        precondition(drained.points.last!.remaining == 0)

        // A reset refills one account and is reported with its gain.
        let resetting = [QuotaPoolAccount(remaining: 40, resetsAt: now.addingTimeInterval(2 * hour), periodMinutes: 300)]
        let refilled = QuotaPoolMath.project(resetting, burnPerHour: 5, now: now, horizon: 3 * hour)
        precondition(refilled.resets.first.map { abs($0.gain - 70) < 0.01 } == true, "40 - 10 drained, refill +70")
        precondition(refilled.resets.first?.at == now.addingTimeInterval(2 * hour))
        precondition(refilled.poolEmptyAt == nil)

        // No burn never reports an empty pool.
        let idle = QuotaPoolMath.project(accounts, burnPerHour: 0, now: now, horizon: 24 * hour)
        precondition(idle.poolEmptyAt == nil && idle.firstEmptyAt == nil)
        precondition(QuotaPoolMath.project([], burnPerHour: 5, now: now, horizon: hour).points.isEmpty)

        print("QuotaPoolMathSpec: all checks passed")
    }
}
