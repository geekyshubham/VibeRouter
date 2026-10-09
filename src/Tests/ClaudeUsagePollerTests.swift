import XCTest
@testable import CLIProxyMenuBar

final class ClaudeUsagePollerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func quota(_ id: String = "claude", at date: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(id: id, providerID: "claude", source: "Claude OAuth",
                              windows: [RateWindow(usedPercent: 49, label: "Weekly")], updatedAt: date)
    }

    func testCachedQuotaAndCooldownKeepLastKnownWindows() async {
        let poller = ClaudeUsagePoller()
        let original = quota(at: now)
        _ = await poller.fetch(key: "a", now: now) { .init(snapshot: original) }
        let cached = await poller.fetch(key: "a", now: now.addingTimeInterval(299)) {
            XCTFail("Auth-file events must not bypass the polling interval")
            return .init(snapshot: original)
        }
        XCTAssertEqual(cached, original)
        let throttled = await poller.fetch(key: "a", now: now.addingTimeInterval(300)) {
            .init(snapshot: .empty(authAccountID: "claude", providerID: "claude"), rateLimited: true, retryAfter: "900")
        }
        XCTAssertEqual(throttled.windows, original.windows)
        XCTAssertEqual(throttled.updatedAt, original.updatedAt)
        XCTAssertTrue(throttled.errorMessage?.contains("last known limits") == true)
        let duringCooldown = await poller.fetch(key: "a", now: now.addingTimeInterval(1199)) {
            XCTFail("Retry-After must be honored")
            return .init(snapshot: original)
        }
        XCTAssertEqual(duringCooldown, throttled)
        let recovered = await poller.fetch(key: "a", now: now.addingTimeInterval(1200)) { .init(snapshot: original) }
        XCTAssertNil(recovered.errorMessage)
    }

    func testZeroRetryAfterStillBacksOffAndAccountIsIsolated() async {
        let poller = ClaudeUsagePoller()
        let failure = ClaudeUsagePoller.Response(snapshot: .empty(authAccountID: "a", providerID: "claude"),
                                                rateLimited: true, retryAfter: "0")
        _ = await poller.fetch(key: "a", now: now) { failure }
        _ = await poller.fetch(key: "a", now: now.addingTimeInterval(299)) {
            XCTFail("A zero header must not cause an immediate retry")
            return failure
        }
        _ = await poller.fetch(key: "a", now: now.addingTimeInterval(300)) { failure }
        _ = await poller.fetch(key: "a", now: now.addingTimeInterval(899)) {
            XCTFail("Repeated 429s must increase the cooldown")
            return failure
        }
        let other = quota("b", at: now)
        let result = await poller.fetch(key: "b", now: now) { .init(snapshot: other) }
        XCTAssertEqual(result, other)
    }

    func testConcurrentFetchesShareOneRequest() async {
        let poller = ClaudeUsagePoller()
        let counter = RequestCounter()
        let snapshot = quota(at: now)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await poller.fetch(key: "same") {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        return .init(snapshot: snapshot)
                    }
                }
            }
        }
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testAuthRejectionAllowsRetryWithNewCredentials() async {
        let poller = ClaudeUsagePoller()
        _ = await poller.fetch(key: "a", now: now) {
            .init(snapshot: .empty(authAccountID: "a", providerID: "claude", error: "Access token expired"))
        }
        let refreshed = quota(at: now)
        let result = await poller.fetch(key: "a", now: now) { .init(snapshot: refreshed) }
        XCTAssertEqual(result, refreshed)
    }

    func testRetryAfterParsesSecondsAndHTTPDate() {
        XCTAssertEqual(ClaudeUsagePoller.retryDelay(" 900 ", now: now), 900)
        XCTAssertEqual(ClaudeUsagePoller.retryDelay("-1", now: now), 0)
        XCTAssertEqual(ClaudeUsagePoller.retryDelay("nan", now: now), 0)
        XCTAssertEqual(ClaudeUsagePoller.retryDelay("garbage", now: now), 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(ClaudeUsagePoller.retryDelay(formatter.string(from: now.addingTimeInterval(600)), now: now), 600)
    }

    func testLastSuccessfulQuotaSurvivesRestartAndFailedChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheFile = directory.appendingPathComponent("claude-usage.json")
        let original = quota(at: now)
        let first = ClaudeUsagePoller(cacheFile: cacheFile)
        _ = await first.fetch(key: "a", now: now) { .init(snapshot: original) }
        let restarted = ClaudeUsagePoller(cacheFile: cacheFile)
        _ = await restarted.fetch(key: "a", now: now.addingTimeInterval(300)) {
            .init(snapshot: .empty(authAccountID: "claude", providerID: "claude", error: "Network unavailable"))
        }
        let throttled = await restarted.fetch(key: "a", now: now.addingTimeInterval(301)) {
            .init(snapshot: .empty(authAccountID: "claude", providerID: "claude"), rateLimited: true)
        }
        XCTAssertEqual(throttled.windows, original.windows)
        XCTAssertEqual(throttled.updatedAt, original.updatedAt)
        XCTAssertTrue(throttled.errorMessage?.contains("Last updated " + ResetCountdownFormatter.absoluteTime(now)) == true)
        XCTAssertTrue(throttled.errorMessage?.contains("rate limited — showing last known limits") == true)
        XCTAssertTrue(throttled.errorMessage?.contains("Next check after ") == true)
        let other = await restarted.fetch(key: "b", now: now) {
            .init(snapshot: .empty(authAccountID: "other", providerID: "claude"), rateLimited: true)
        }
        XCTAssertTrue(other.windows.isEmpty)
        XCTAssertNil(other.updatedAt)
        XCTAssertTrue(other.errorMessage?.contains("no previous limits available") == true)
    }
}

private actor RequestCounter {
    var value = 0
    func increment() { value += 1 }
}
