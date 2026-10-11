import Foundation
import Darwin

/// Ask Claude Code to refresh its own Keychain session. The native client owns
/// the cross-process OAuth locks; VibeRouter never posts its refresh token.
actor ClaudeNativeSessionRefresh {
    static let shared = ClaudeNativeSessionRefresh()
    private var pending: Task<Bool, Never>?
    private var nextAttempt = Date.distantPast

    func run(now: Date = Date(), operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let pending { return await pending.value }
        guard now >= nextAttempt else { return false }
        let task = Task { await operation() }
        pending = task
        let result = await task.value
        pending = nil
        // Failed/revoked sessions and usage-endpoint throttles must not spawn
        // a new CLI process on every file event or manual refresh.
        nextAttempt = now.addingTimeInterval(5 * 60)
        return result
    }

    static func shouldRefresh(account: [String: Any], native: [String: Any]?, force: Bool = false) -> Bool {
        guard let native,
              AccountCredentialIdentity.sameAccount(account, native),
              TokenRefreshService.refreshToken(from: native) != nil else { return false }
        return force || TokenRefreshService.shouldRefresh(payload: native)
    }

    static func environment(from inherited: [String: String]) -> [String: String] {
        var result = inherited.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE_CODE_")
                && !["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE"].contains(key)
        }
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return result
        // Do not set CLAUDE_CONFIG_DIR even to ~/.claude: the native client
        // selects a different Keychain service whenever that variable is set.
    }

    static let arguments = [
        "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
        "--permission-mode", "dontAsk", "--no-session-persistence",
    ]

    static let input = """
    {"type":"control_request","request_id":"viberouter-init","request":{"subtype":"initialize"}}
    {"type":"control_request","request_id":"viberouter-usage","request":{"subtype":"get_usage","skip_behaviors":true}}

    """

    static func requestNativeRefresh(executable override: String? = nil, timeout: TimeInterval = 45) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home.appendingPathComponent(".claude/local/claude").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        guard let executable = override ?? candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return false }
        // One helper per native credential store, including separate app/CLI
        // processes. Keep the lease until the child exits, even after a timeout.
        let leaseURL = home.appendingPathComponent("Library/Caches/VibeRouter/claude-native-refresh.lock")
        guard let lease = acquireLease(at: leaseURL) else {
            NSLog("[ClaudeNativeRefresh] Another native renewal is still running; deferring")
            return false
        }
        var leaseHandedToChild = false
        defer { if !leaseHandedToChild { releaseLease(lease) } }
        let directory = fm.temporaryDirectory.appendingPathComponent("viberouter-claude-refresh-\(UUID().uuidString)")
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        let outputURL = directory.appendingPathComponent("control.jsonl")
        guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            try? fm.removeItem(at: directory)
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            releaseLease(lease)
            try? FileManager.default.removeItem(at: directory)
            exited.signal()
        }
        defer {
            try? pipe.fileHandleForWriting.close()
            try? output.close()
            // Never SIGKILL a client during OAuth rotation: the server may have
            // invalidated the old grant before the client persists its successor.
            // EOF lets the native client drain its request and release its lock.
            if !process.isRunning { try? fm.removeItem(at: directory) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        func waitForReply(_ id: String) -> [String: Any]? {
            while Date() < deadline {
                if let data = try? Data(contentsOf: outputURL) {
                    if data.count > 1_048_576 { return nil }
                    if let reply = Self.reply(id: id, output: data) { return reply }
                }
                if !process.isRunning { return nil }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return nil
        }
        do {
            try process.run()
            leaseHandedToChild = true
            let messages = input.split(separator: "\n")
            try pipe.fileHandleForWriting.write(contentsOf: Data((messages[0] + "\n").utf8))
            guard let initialized = waitForReply("viberouter-init"), initialized["subtype"] as? String == "success" else {
                NSLog("[ClaudeNativeRefresh] Native initialization failed or timed out")
                return false
            }
            try pipe.fileHandleForWriting.write(contentsOf: Data((messages[1] + "\n").utf8))
            guard let usage = waitForReply("viberouter-usage"), usage["subtype"] as? String == "success",
                  let body = usage["response"] as? [String: Any], body["rate_limits_available"] as? Bool == true else {
                NSLog("[ClaudeNativeRefresh] Native usage check failed or has no signed-in session")
                return false
            }
            // Keep stdin open until the reply arrives, rather than exiting while
            // the native client's token refresh or Keychain write is in flight.
            try pipe.fileHandleForWriting.close()
            _ = exited.wait(timeout: .now() + 2)
            return true
        } catch {
            NSLog("[ClaudeNativeRefresh] Could not complete native control requests")
            return false
        }
    }

    static func acquireLease(at url: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    static func releaseLease(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    static func recordOutcome(completed: Bool, before: [String: Any]?, after: [String: Any]?) {
        let oldExpiry = before.flatMap(TokenRefreshService.accessTokenExpiry)
        let newExpiry = after.flatMap(TokenRefreshService.accessTokenExpiry)
        let state: String
        if after == nil { state = "native_credentials_missing_after_attempt" }
        else if let newExpiry, newExpiry > Date(), newExpiry != oldExpiry { state = "renewed" }
        else if completed { state = "native_check_completed_without_rotation" }
        else { state = "native_check_failed_or_deferred" }
        let formatter = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "checked_at": formatter.string(from: Date()), "outcome": state,
            "previous_access_expiry": oldExpiry.map(formatter.string) ?? "unknown",
            "current_access_expiry": newExpiry.map(formatter.string) ?? "missing",
        ]
        // Only dates and fixed status labels. Never credentials, native error
        // bodies, account emails, prompts, or transcript contents.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/VibeRouter/claude-renewal-status.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        NSLog("[ClaudeNativeRefresh] %@", state)
    }

    static func reply(id: String, output: Data) -> [String: Any]? {
        for line in output.split(separator: 10) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["type"] as? String == "control_response",
                  let reply = message["response"] as? [String: Any], reply["request_id"] as? String == id else { continue }
            return reply
        }
        return nil
    }
}
