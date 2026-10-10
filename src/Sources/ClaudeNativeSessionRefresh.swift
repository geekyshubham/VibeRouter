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

    static func requestNativeRefresh(timeout: TimeInterval = 45) -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/claude").path,
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home.appendingPathComponent(".claude/local/claude").path]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        guard let executable = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return false }
        let directory = fm.temporaryDirectory.appendingPathComponent("viberouter-claude-refresh-\(UUID().uuidString)")
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        defer { try? fm.removeItem(at: directory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = directory
        // Only two control requests are sent. No user message, prompt, tools,
        // hooks, MCP servers, or model inference are part of this operation.
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            return false
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return false
        }
        return process.terminationStatus == 0
    }
}
