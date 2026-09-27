import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Mirrors CodexBar's `KiroStatusProbe`: run `kiro-cli chat --no-interactive /usage`
/// and parse `Credits (X of Y covered in plan)`. This is the ground truth for org/power plans;
/// AWS GetUsageLimits often under-reports (e.g. 0.11 while CLI shows 285.62 of 10000).
///
/// Conventions (CodexBar docs + real CLI output):
/// - Plan pools vary: Free ≈ 50, Pro ≈ 1000, Power/Pro+ ≈ 10000 — never invent a default total.
/// - Percent from the block-bar `█+ N%` next to monthly credits, or recompute from used/total.
/// - CLI figures are **billing-period** quota; local session metering is the rolling analytics window.
struct KiroCLIUsageSnapshot: Equatable {
    let planName: String?
    let creditsUsed: Double
    let creditsTotal: Double
    let creditsPercent: Double
    let overageCreditsUsed: Double?
    let estimatedOverageCostUSD: Double?
    let resetsAt: Date?
    let source: String

    var creditsRemaining: Double { max(0, creditsTotal - creditsUsed) }

    /// True when absolute used/total were parsed (not percent-only).
    var hasAbsoluteCredits: Bool { creditsTotal > 0 }
}

enum KiroCLIUsageProbe {
    private static let cacheLock = NSCondition()
    private static var cached: (at: Date, value: KiroCLIUsageSnapshot?)?
    private static var isFetching = false
    /// Positive results stay warm this long.
    private static let cacheTTL: TimeInterval = 90
    /// Soft failures (timeout/missing binary) use a short negative cache so we don't hammer CLI.
    private static let negativeCacheTTL: TimeInterval = 15

    static func fetch(timeoutSeconds: TimeInterval = 22) -> KiroCLIUsageSnapshot? {
        cacheLock.lock()
        // Wait for in-flight probe (single-flight) so concurrent quota + cost scans share one run.
        while isFetching {
            cacheLock.wait()
        }
        if let cached, isCacheFreshLocked(cached) {
            let value = cached.value
            cacheLock.unlock()
            return value
        }
        isFetching = true
        cacheLock.unlock()

        defer {
            cacheLock.lock()
            isFetching = false
            cacheLock.broadcast()
            cacheLock.unlock()
        }

        guard let binary = resolveKiroCLI() else {
            storeCache(nil, softFailure: true)
            return nil
        }
        guard let output = run(binary: binary, arguments: ["chat", "--no-interactive", "/usage"], timeout: timeoutSeconds) else {
            storeCache(nil, softFailure: true)
            return nil
        }
        let result = parse(output: output)
        storeCache(result, softFailure: result == nil)
        return result
    }

    /// Caller must hold `cacheLock`.
    private static func isCacheFreshLocked(_ entry: (at: Date, value: KiroCLIUsageSnapshot?)) -> Bool {
        let age = Date().timeIntervalSince(entry.at)
        let ttl = entry.value == nil ? negativeCacheTTL : cacheTTL
        return age < ttl
    }

    private static func storeCache(_ value: KiroCLIUsageSnapshot?, softFailure: Bool) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        // CodexBar-style: keep a good parse across transient timeouts / soft failures.
        if softFailure, value == nil,
           let existing = cached, existing.value != nil,
           Date().timeIntervalSince(existing.at) < cacheTTL
        {
            return
        }
        cached = (Date(), value)
    }

    // MARK: - Parse (CodexBar-compatible)

    static func parse(output: String) -> KiroCLIUsageSnapshot? {
        let stripped = stripANSI(output)
            .replacingOccurrences(of: "\r", with: "\n")
        let lowered = stripped.lowercased()

        if lowered.contains("not logged in")
            || lowered.contains("login required")
            || lowered.contains("kiro-cli login")
            || lowered.contains("failed to initialize auth")
            || lowered.contains("oauth error")
            || lowered.contains("could not retrieve usage information")
        {
            return nil
        }

        // Percent: block-bar only (CodexBar). Never take the first bare `%` in banner/help text.
        var creditsPercent: Double = 0
        var matchedPercent = false
        if let match = firstMatch(in: stripped, pattern: #"█+\s*(\d+(?:\.\d+)?)%"#),
           let pct = parseNumber(match)
        {
            creditsPercent = pct
            matchedPercent = true
        }

        var creditsUsed: Double = 0
        var creditsTotal: Double = 0
        var matchedCredits = false
        // CodexBar: "(X.XX of Y covered in plan)" — Y is plan pool (50 / 1000 / 10000 / …).
        let creditsPattern = #"\(([0-9][0-9,]*(?:\.\d+)?)\s+of\s+([0-9][0-9,]*(?:\.\d+)?)\s+covered"#
        if let usedStr = firstMatch(in: stripped, pattern: creditsPattern),
           let totalStr = secondMatch(in: stripped, pattern: creditsPattern),
           let used = parseNumber(usedStr),
           let total = parseNumber(totalStr),
           total > 0
        {
            creditsUsed = used
            creditsTotal = total
            matchedCredits = true
        }

        // Prefer absolute credits when present so bar % never disagrees with used/total.
        if matchedCredits, creditsTotal > 0 {
            creditsPercent = (creditsUsed / creditsTotal) * 100.0
        }

        guard matchedPercent || matchedCredits else { return nil }
        // Percent-only: leave total at 0 — caller must not invent 10_000 / 50.
        // Free tier is often 50, Pro 1000, Power 10000; inventing any default mislabels remaining.

        let planName = parsePlanName(from: stripped)
        let resetsAt = parseResetDate(in: stripped)
        let overageUsed = firstMatch(in: stripped, pattern: #"(?i)Credits used:\s*([0-9][0-9,]*(?:\.\d+)?)"#).flatMap(parseNumber)
        let estCost = firstMatch(in: stripped, pattern: #"(?i)Est\.\s*cost:\s*\$?([0-9][0-9,]*(?:\.\d+)?)\s*USD"#).flatMap(parseNumber)

        return KiroCLIUsageSnapshot(
            planName: planName,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            overageCreditsUsed: overageUsed,
            estimatedOverageCostUSD: estCost,
            resetsAt: resetsAt,
            source: "kiro-cli /usage"
        )
    }

    // MARK: - Process

    private static func resolveKiroCLI() -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kiro-cli").path,
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/bin/kiro-cli").path,
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // which
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["kiro-cli"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    private static func run(binary: String, arguments: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments
        proc.environment = ProcessInfo.processInfo.environment
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do {
            try proc.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate() // SIGTERM
            Thread.sleep(forTimeInterval: 0.2)
            if proc.isRunning {
                #if canImport(Darwin)
                kill(proc.processIdentifier, SIGKILL)
                #else
                proc.interrupt()
                #endif
            }
        }
        proc.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = stdout + "\n" + stderr
        return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : combined
    }

    // MARK: - Text helpers

    private static func stripANSI(_ text: String) -> String {
        // ESC[ … letter
        guard let regex = try? NSRegularExpression(pattern: #"\x1B\[[0-9;?]*[a-zA-Z]"#) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func secondMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 3,
              let r = Range(match.range(at: 2), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func parseNumber(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func parsePlanName(from text: String) -> String? {
        // "Estimated Usage | resets on 2026-06-01 | KIRO POWER"
        if let name = firstMatch(
            in: text,
            pattern: #"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)"#
        ) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = firstMatch(in: text, pattern: #"(?i)Plan:\s*([^\n]+)"#) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Legacy box format: "| KIRO FREE"
        if let name = firstMatch(in: text, pattern: #"\|[ \t]*(KIRO[ \t]+\w+)"#) {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func parseResetDate(in text: String) -> Date? {
        // "resets on 2026-08-01" or "resets on 01/15"
        if let dateStr = firstMatch(in: text, pattern: #"(?i)resets on\s+(\d{4}-\d{2}-\d{2})"#) {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: dateStr)
        }
        if let md = firstMatch(in: text, pattern: #"(?i)resets on\s+(\d{1,2}/\d{1,2})"#) {
            let parts = md.split(separator: "/")
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
            let calendar = Calendar.current
            let now = Date()
            var components = DateComponents()
            components.month = month
            components.day = day
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date >= calendar.startOfDay(for: now) {
                return date
            }
            components.year = (components.year ?? 0) + 1
            return calendar.date(from: components)
        }
        return nil
    }
}

/// Credit windows for one Kiro account's `GetUsageLimits` payload.
///
/// `currentUsage` already includes overage. Adding `currentOverages` on top
/// reports ~15,766 when the account has used ~7,910, and the 50-credit included
/// allowance is what a free-plan card shows if that total is dropped.
enum KiroCreditMath {
    struct Slice: Equatable {
        let label: String
        let used: Double
        let total: Double
    }

    static func slices(
        totalUsed: Double,
        planLimit: Double,
        overageUsed: Double,
        overageCap: Double
    ) -> [Slice] {
        let used = max(0, totalUsed)
        let plan = max(0, planLimit)
        let overUsed = max(0, overageUsed)
        let overCap = max(0, overageCap)
        // Free is 50 included under a 10,000 overage cap. Power's plan limit is
        // already the 10,000 pool, so adding the cap again would show 20,000.
        let smallPlanUnderOverage = plan > 0 && overCap > plan
        let ceiling = smallPlanUnderOverage ? plan + overCap : max(plan, overCap)
        guard ceiling > 0 || used > 0 else { return [] }

        var out = [Slice(label: "Credits", used: used, total: max(ceiling, used))]
        if overCap > 0, overUsed > 0 || smallPlanUnderOverage {
            out.append(Slice(label: "Overage", used: overUsed, total: max(overCap, overUsed)))
        }
        if smallPlanUnderOverage {
            let included = min(plan, max(0, used - overUsed))
            out.append(Slice(label: "Included in plan", used: included, total: plan))
        }
        return out
    }

    /// True when both names are the same Kiro tier. A CLI Power login must not
    /// replace a builder-id Free account (or the reverse) on the same card.
    static func samePlan(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = planKey(lhs), let b = planKey(rhs) else { return false }
        return a == b
    }

    static func planKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let drop: Set<String> = ["KIRO", "Q", "DEVELOPER", "STANDALONE"]
        let parts = raw.uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !drop.contains($0) }
        let key = parts.joined(separator: " ")
        return key.isEmpty ? nil : key
    }
}
