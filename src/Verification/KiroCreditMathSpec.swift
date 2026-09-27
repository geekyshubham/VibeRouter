import Foundation

/// Compile and run from the repo root:
///   swiftc -O -o /tmp/kiro-credit-math-spec \
///     src/Verification/KiroCreditMathSpec.swift \
///     src/Sources/KiroCLIUsageProbe.swift && /tmp/kiro-credit-math-spec
@main
struct KiroCreditMathSpec {
    static func main() {
        // Builder-id free plan observed 2026-09-27: 7,909.89 total, 50 included,
        // 7,856.07 overage of a 10,000 cap. Adding overage again yields ~15,766.
        let free = KiroCreditMath.slices(
            totalUsed: 7909.89,
            planLimit: 50,
            overageUsed: 7856.07,
            overageCap: 10000
        )
        precondition(free.count == 3, "free plan shows total, overage, and included")
        precondition(free[0].label == "Credits")
        precondition(abs(free[0].used - 7909.89) < 0.001, "headline is total used, not the 50-credit allowance")
        precondition(abs(free[0].total - 10050) < 0.001)
        precondition(abs(free[0].used - (7909.89 + 7856.07)) > 1000, "do not add overage on top of currentUsage")
        precondition(free[1].label == "Overage")
        precondition(abs(free[1].used - 7856.07) < 0.001)
        precondition(abs(free[2].used - 50) < 0.001, "included row is the 50-credit allowance")

        let power = KiroCreditMath.slices(
            totalUsed: 8445.48,
            planLimit: 10000,
            overageUsed: 0,
            overageCap: 10000
        )
        precondition(power.count == 1, "power pool is one window")
        precondition(abs(power[0].used - 8445.48) < 0.001)
        precondition(abs(power[0].total - 10000) < 0.001, "do not inflate Power to 20,000")

        precondition(KiroCreditMath.samePlan("KIRO POWER", "KIRO POWER"))
        precondition(KiroCreditMath.samePlan("KIRO FREE", "Q_DEVELOPER_STANDALONE_FREE"))
        precondition(!KiroCreditMath.samePlan("KIRO POWER", "KIRO FREE"))
        precondition(!KiroCreditMath.samePlan("KIRO POWER", nil))
        print("ok")
    }
}
