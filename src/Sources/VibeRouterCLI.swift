import AppKit
import Darwin
import Foundation

/// Scriptable and interactive command surface for the same services used by the menu-bar app.
///
/// Design goals:
/// - stdout is stable machine-readable JSON when `--json` is present;
/// - mutations never prompt when `--yes` is present (safe for agents and automation);
/// - the no-argument `viberouter` launcher opens a TUI, while the app executable still
///   opens the normal GUI when launched by Finder.
enum VibeRouterCLI {
    static let version = "1.0"

    struct GlobalOptions {
        var json = false
        var plain = false
        var yes = false
        var color = isatty(STDOUT_FILENO) == 1
    }

    struct Failure: Error {
        let code: String
        let message: String
        let hint: String?
        let exitCode: Int32

        init(_ code: String, _ message: String, hint: String? = nil, exitCode: Int32 = 1) {
            self.code = code
            self.message = message
            self.hint = hint
            self.exitCode = exitCode
        }
    }

    static func shouldRun(arguments: [String]) -> Bool {
        let executable = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent.lowercased()
        if executable == "viberouter" || executable == "viberoutercli" { return true }
        guard arguments.count > 1 else { return false }
        return arguments[1] == "cli" || arguments[1] == "--cli" || arguments[1] == "tui"
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        var args = Array(arguments.dropFirst())
        if args.first == "cli" || args.first == "--cli" { args.removeFirst() }

        var options = GlobalOptions()
        args.removeAll { arg in
            switch arg {
            case "--json": options.json = true; options.color = false; return true
            case "--plain": options.plain = true; options.color = false; return true
            case "--yes", "-y": options.yes = true; return true
            case "--no-color": options.color = false; return true
            default: return false
            }
        }

        if args.isEmpty { args = ["tui"] }
        let command = args.removeFirst().lowercased()

        do {
            switch command {
            case "tui", "dashboard":
                guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                    throw Failure("tty_required", "The interactive dashboard needs a terminal.", hint: "Use `viberouter status --json` in scripts or agents.", exitCode: 2)
                }
                try await TerminalDashboard().run()
            case "help", "-h", "--help":
                printHelp()
            case "version", "--version", "-v":
                emit(["version": version], human: "VibeRouter CLI \(version)", options: options)
            case "completion", "completions":
                try completionCommand(args: args, options: options)
            case "install-cli":
                try installCLICommand(args: args, options: options)
            case "capabilities", "agent-guide", "schema":
                emit(capabilities(), human: agentGuide(), options: options)
            case "status", "overview":
                try await showStatus(args: args, options: options)
            case "accounts", "account":
                try await accountCommand(args: args, options: options)
            case "auth", "token", "tokens", "refresh-tokens":
                try await authCommand(args: args, options: options)
            case "usage", "limits", "quota":
                try await usageCommand(args: args, options: options)
            case "switch":
                try await switchCommand(args: args, options: options)
            case "wake", "trigger":
                try await wakeCommand(args: args, options: options)
            case "reset":
                try await resetCommand(args: args, options: options)
            case "analytics", "stats":
                try await analyticsCommand(args: args, options: options)
            case "server", "proxy":
                try await serverCommand(args: args, options: options)
            case "login", "connect":
                try await loginCommand(args: args, options: options)
            case "import":
                try await importCommand(args: args, options: options)
            case "providers", "provider":
                try await providerCommand(args: args, options: options)
            case "settings", "config":
                try settingsCommand(args: args, options: options)
            case "api":
                try await rawAPICommand(args: args, options: options)
            case "harness":
                let msg = try CLIHarnessAutoconfigure.autoconfigure(.claudeCode)
                emit(["ok": true, "message": msg], human: msg, options: options)
            case "doctor":
                try await doctor(options: options)
            default:
                throw Failure("unknown_command", "Unknown command: \(command)", hint: "Run `viberouter help`.", exitCode: 2)
            }
            return 0
        } catch let failure as Failure {
            emitFailure(failure, options: options)
            return failure.exitCode
        } catch {
            let failure = Failure("unexpected_error", error.localizedDescription)
            emitFailure(failure, options: options)
            return failure.exitCode
        }
    }

    // MARK: - Commands

    @MainActor
    private static func loadAccounts(detectCurrent: Bool = true) async -> (AuthManager, [AuthAccount]) {
        let manager = AuthManager()
        manager.checkAuthStatus()
        let grouped = manager.serviceAccounts.mapValues(\.accounts)
        if detectCurrent {
            await NativeSessionManager.shared.refreshNow(accounts: grouped)
        }
        return (manager, ServiceType.allCases.flatMap { grouped[$0] ?? [] })
    }

    @MainActor
    private static func showStatus(args: [String], options: GlobalOptions) async throws {
        try rejectExtra(args)
        let (_, accounts) = await loadAccounts()
        let running = await proxyIsReachable()
        let enabled = accounts.filter { !$0.isDisabled && !$0.isExpired }
        let current = ServiceType.allCases.compactMap { type -> [String: Any]? in
            guard let identity = NativeSessionManager.shared.currentIdentity(for: type) else { return nil }
            return [
                "provider": type.rawValue,
                "label": type.displayName,
                "email": identity.email ?? NSNull(),
                "account_id": identity.accountID ?? NSNull(),
                "plan": identity.plan ?? NSNull(),
            ]
        }
        let data: [String: Any] = [
            "proxy": ["running": running, "url": "http://127.0.0.1:8317", "management_url": ManagementCredentials.managementHTMLURL.absoluteString],
            "accounts": ["total": accounts.count, "enabled": enabled.count, "providers": Set(accounts.map { $0.type.rawValue }).count],
            "active_native_sessions": current,
        ]
        var lines = [
            title("VibeRouter", options),
            "Proxy       \(running ? green("● running", options) : red("○ stopped", options))  http://127.0.0.1:8317",
            "Accounts    \(enabled.count) enabled / \(accounts.count) total across \(Set(accounts.map { $0.type }).count) providers",
        ]
        if !current.isEmpty {
            lines.append("")
            lines.append("Active native sessions")
            for row in current {
                lines.append("  \(pad(row["label"] as? String ?? "", 18)) \((row["email"] as? String) ?? (row["account_id"] as? String) ?? "unknown")")
            }
        }
        emit(data, human: lines.joined(separator: "\n"), options: options)
    }

    @MainActor
    private static func accountCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let verb = (args.first?.hasPrefix("-") == false ? args.first?.lowercased() : nil) ?? "list"
        if let first = args.first, ["list", "ls"].contains(first.lowercased()) {
            args.removeFirst()
        }
        let provider = takeOption("--provider", from: &args)

        if ["list", "ls"].contains(verb) || (args.isEmpty && verb == "list") {
            try rejectExtra(args)
            let (_, all) = await loadAccounts()
            let accounts = filterAccounts(all, provider: provider)
            let rows = accounts.map(accountJSON)
            let human = accountTable(accounts)
            emit(["accounts": rows, "count": rows.count], human: human, options: options)
            return
        }

        args.removeFirst()
        switch verb {
        case "enable", "disable":
            guard let selector = args.first else { throw missing("account selector") }
            args.removeFirst(); try rejectExtra(args)
            let (manager, all) = await loadAccounts(detectCurrent: false)
            let account = try resolveAccount(selector, in: filterAccounts(all, provider: provider))
            let desiredDisabled = verb == "disable"
            if account.isDisabled != desiredDisabled {
                guard manager.toggleAccountDisabled(account) else {
                    throw Failure("account_update_failed", "Could not \(verb) \(account.displayName).", hint: "The last enabled account for a provider cannot be disabled.")
                }
            }
            emit(["account": account.id, "enabled": !desiredDisabled], human: "\(verb.capitalized)d \(account.displayName)", options: options)
        case "delete", "remove":
            guard let selector = args.first else { throw missing("account selector") }
            args.removeFirst(); try rejectExtra(args)
            let (manager, all) = await loadAccounts(detectCurrent: false)
            let account = try resolveAccount(selector, in: filterAccounts(all, provider: provider))
            try requireConfirmation("Delete \(account.displayName) and all files for this seat?", options: options)
            guard manager.deleteAccount(account) else { throw Failure("account_delete_failed", "Could not delete \(account.displayName).") }
            emit(["account": account.id, "deleted": true], human: "Deleted \(account.displayName)", options: options)
        case "refresh":
            let allFlag = takeFlag("--all", from: &args)
            let forceFlag = takeFlag("--force", from: &args)
            let selector = args.first
            if selector != nil { args.removeFirst() }
            try rejectExtra(args)
            try await refreshAccountsCommand(selector: selector, all: allFlag || selector == nil, force: forceFlag, provider: provider, options: options)
        default:
            throw Failure("unknown_subcommand", "Unknown account command: \(verb)", hint: "Use list, enable, disable, delete, or refresh.", exitCode: 2)
        }
    }

    @MainActor
    private static func authCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let verb = (args.first?.hasPrefix("-") == false ? args.first?.lowercased() : nil) ?? "status"
        if let first = args.first, ["refresh", "status", "list", "check"].contains(first.lowercased()) {
            args.removeFirst()
        }
        let provider = takeOption("--provider", from: &args)
        let forceFlag = takeFlag("--force", from: &args)
        let allFlag = takeFlag("--all", from: &args)

        switch verb {
        case "refresh":
            let selector = args.first
            if selector != nil { args.removeFirst() }
            try rejectExtra(args)
            try await refreshAccountsCommand(selector: selector, all: allFlag || selector == nil, force: forceFlag, provider: provider, options: options)
        case "status", "check", "list":
            try rejectExtra(args)
            try await authStatusCommand(provider: provider, options: options)
        default:
            let (_, all) = await loadAccounts(detectCurrent: false)
            let matching = filterAccounts(all, provider: provider)
            if let target = try? resolveAccount(verb, in: matching) {
                try rejectExtra(args)
                try await refreshAccountsCommand(selector: target.id, all: false, force: forceFlag, provider: provider, options: options)
                return
            }
            throw Failure("unknown_subcommand", "Unknown auth command: \(verb)", hint: "Use `viberouter auth refresh [--all | <account>]` or `viberouter auth status`.", exitCode: 2)
        }
    }

    @MainActor
    private static func refreshAccountsCommand(
        selector: String?,
        all: Bool,
        force: Bool,
        provider: String?,
        options: GlobalOptions
    ) async throws {
        let (_, allAccounts) = await loadAccounts(detectCurrent: false)
        var targets = filterAccounts(allAccounts, provider: provider)
        if let selector {
            targets = [try resolveAccount(selector, in: targets)]
        } else if !all {
            throw missing("account selector or --all")
        }

        let refreshable = targets.filter { TokenRefreshService.canRefresh(file: $0.filePath) }
        if refreshable.isEmpty {
            let msg = targets.isEmpty ? "No accounts found to refresh." : "None of the selected accounts use refreshable OAuth tokens."
            emit(["count": 0, "refreshed": 0, "results": []], human: msg, options: options)
            return
        }

        var results: [[String: Any]] = []
        var humanLines: [String] = []
        humanLines.append(title("Token Refresh", options))
        var refreshedCount = 0
        var skippedCount = 0
        var failedCount = 0

        for acc in refreshable {
            let beforePayload = NativeUsageFetcher.readAuthPayload(at: acc.filePath) ?? [:]
            let beforeExp = TokenRefreshService.accessTokenExpiry(from: beforePayload)
            let wasNearExpiry = TokenRefreshService.shouldRefresh(payload: beforePayload)

            let ok = await TokenRefreshService.refreshAccountFile(acc.filePath, force: force)
            let afterPayload = NativeUsageFetcher.readAuthPayload(at: acc.filePath) ?? [:]
            let afterExp = TokenRefreshService.accessTokenExpiry(from: afterPayload)

            let actuallyRotated = (afterExp != nil && beforeExp != nil && afterExp! > beforeExp!) || (beforeExp == nil && afterExp != nil)

            let status: String
            if ok {
                if actuallyRotated || force || wasNearExpiry {
                    status = "refreshed"
                    refreshedCount += 1
                } else {
                    status = "up_to_date"
                    skippedCount += 1
                }
            } else {
                status = "failed"
                failedCount += 1
            }

            let expStr = afterExp.map(iso) ?? "unknown"
            let remStr = afterExp.map(relativeTime(to:)) ?? "-"

            results.append([
                "id": acc.id,
                "display_name": acc.displayName,
                "provider": acc.type.rawValue,
                "status": status,
                "success": ok,
                "expires_at": expStr,
                "time_remaining": remStr,
            ])

            let statusIcon: String
            switch status {
            case "refreshed": statusIcon = green("✓ Refreshed", options)
            case "up_to_date": statusIcon = blue("● Valid", options)
            default: statusIcon = red("✗ Failed", options)
            }

            humanLines.append(
                "  \(pad(acc.type.displayName, 14)) \(pad(acc.displayName, 28)) \(pad(statusIcon, 16)) (expires \(remStr))"
            )
        }

        humanLines.append("")
        humanLines.append("Summary: \(refreshedCount) refreshed, \(skippedCount) already fresh, \(failedCount) failed.")

        emit([
            "total": refreshable.count,
            "refreshed": refreshedCount,
            "up_to_date": skippedCount,
            "failed": failedCount,
            "accounts": results,
        ], human: humanLines.joined(separator: "\n"), options: options)
    }

    @MainActor
    private static func authStatusCommand(provider: String?, options: GlobalOptions) async throws {
        let (_, allAccounts) = await loadAccounts(detectCurrent: false)
        let accounts = filterAccounts(allAccounts, provider: provider)
        var rows: [[String: Any]] = []
        var humanLines: [String] = []
        humanLines.append(title("OAuth & Auth Token Status", options))
        humanLines.append(
            "  \(pad("PROVIDER", 14)) \(pad("ACCOUNT", 28)) \(pad("REFRESHABLE", 12)) \(pad("EXPIRES IN", 14)) EXPIRY"
        )
        humanLines.append("  \(String(repeating: "-", count: 85))")

        let now = Date()
        for acc in accounts {
            let payload = NativeUsageFetcher.readAuthPayload(at: acc.filePath) ?? [:]
            let canRef = TokenRefreshService.canRefresh(file: acc.filePath)
            let exp = TokenRefreshService.accessTokenExpiry(from: payload)
            let isExp = exp != nil ? exp! <= now : acc.isExpired
            let remStr = exp.map(relativeTime(to:)) ?? (canRef ? "dynamic" : "static key")
            let expIso = exp.map(iso) ?? "-"

            let statusTag: String
            if canRef {
                if let exp {
                    if exp <= now {
                        statusTag = red("expired", options)
                    } else if exp <= now.addingTimeInterval(TokenRefreshService.graceInterval) {
                        statusTag = yellow(remStr, options)
                    } else {
                        statusTag = green(remStr, options)
                    }
                } else {
                    statusTag = blue("active", options)
                }
            } else {
                statusTag = dim("static key", options)
            }

            rows.append([
                "id": acc.id,
                "display_name": acc.displayName,
                "provider": acc.type.rawValue,
                "refreshable": canRef,
                "expires_at": expIso,
                "is_expired": isExp,
            ])

            humanLines.append(
                "  \(pad(acc.type.displayName, 14)) \(pad(acc.displayName, 28)) \(pad(canRef ? "yes" : "no", 12)) \(pad(statusTag, 14)) \(expIso)"
            )
        }

        humanLines.append("")
        humanLines.append("Auto-refresh daemon runs every 3m and proactively rotates tokens 15m before expiry.")

        emit(["accounts": rows, "count": rows.count], human: humanLines.joined(separator: "\n"), options: options)
    }

    @MainActor
    private static func usageCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        if args.first == "refresh" { args.removeFirst() }
        let provider = takeOption("--provider", from: &args)
        let selector = takeOption("--account", from: &args)
        try rejectExtra(args)
        let (_, all) = await loadAccounts(detectCurrent: false)
        var accounts = filterAccounts(all, provider: provider).filter { !$0.isDisabled }
        if let selector { accounts = [try resolveAccount(selector, in: accounts)] }
        let snapshots = await fetchUsage(accounts)
        let json = snapshots.map(usageJSON)
        emit(["usage": json, "count": json.count, "refreshed_at": iso(Date())], human: usageTable(snapshots, accounts: accounts), options: options)
    }

    @MainActor
    private static func switchCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        guard let selector = args.first else { throw missing("account selector") }
        args.removeFirst()
        let provider = takeOption("--provider", from: &args)
        let subscription = takeOption("--subscription", from: &args)
        let restart = !takeFlag("--no-restart", from: &args)
        try rejectExtra(args)
        let (_, all) = await loadAccounts()
        let account = try resolveAccount(selector, in: filterAccounts(all, provider: provider))
        guard NativeSessionManager.shared.supportsSwitching(account.type) else {
            throw Failure("switch_unsupported", "Native switching is not available for \(account.type.displayName).", hint: "Run `viberouter capabilities --json` for the switchable provider list.")
        }
        try requireConfirmation("Switch \(account.type.displayName) to \(account.displayName)?", options: options)
        let outcome = await NativeSessionManager.shared.switchTo(
            account,
            chatGPTAccountID: subscription,
            subscriptionLabel: account.planLabel,
            restartApp: restart
        )
        switch outcome {
        case .switched(let message): emit(["switched": true, "account": account.id, "message": message], human: message, options: options)
        case .failure(let message): throw Failure("switch_failed", message)
        }
    }

    @MainActor
    private static func wakeCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        guard let selector = args.first else { throw missing("account selector") }
        args.removeFirst()
        let provider = takeOption("--provider", from: &args)
        try rejectExtra(args)
        let (_, all) = await loadAccounts(detectCurrent: false)
        let account = try resolveAccount(selector, in: filterAccounts(all, provider: provider))
        guard QuotaWakeService.supportsWake(account.type) else {
            throw Failure("wake_unsupported", "\(account.type.displayName) does not expose a wakeable session/5-hour window.")
        }
        let result = await QuotaWakeService.wake(account: account)
        switch result {
        case .success(let message): emit(["woken": true, "account": account.id, "message": message], human: message, options: options)
        case .failure(let message): throw Failure("wake_failed", message)
        }
    }

    @MainActor
    private static func resetCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        guard let selector = args.first else { throw missing("account selector") }
        args.removeFirst()
        let provider = takeOption("--provider", from: &args)
        try rejectExtra(args)
        let (_, all) = await loadAccounts(detectCurrent: false)
        let account = try resolveAccount(selector, in: filterAccounts(all, provider: provider))
        guard RateLimitResetService.supports(account.type) else {
            throw Failure("reset_unsupported", "Manual rate-limit reset is not available for \(account.type.displayName).")
        }
        try requireConfirmation("Consume one rate-limit reset for \(account.displayName)?", options: options)
        let result = await RateLimitResetService.redeem(account: account)
        switch result {
        case .success(let message): emit(["redeemed": true, "account": account.id, "message": message], human: message, options: options)
        case .failure(let message): throw Failure("reset_failed", message)
        }
    }

    private static func analyticsCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let rawDays = takeOption("--days", from: &args) ?? "30"
        guard let days = Int(rawDays), (1...365).contains(days) else {
            throw Failure("invalid_value", "--days must be between 1 and 365.", exitCode: 2)
        }
        try rejectExtra(args)
        let snapshots = await Task.detached(priority: .userInitiated) {
            LocalTokenCostScanner.allProviderSnapshots(historyDays: days)
        }.value
        let overview = AnalyticsEngine.overview(from: snapshots)
        let rows = snapshots.sorted { $0.last30DaysTokens > $1.last30DaysTokens }.map(costJSON)
        let data: [String: Any] = [
            "period_days": days,
            "total_volume": overview.totalTokens30d,
            "estimated_cost_usd": overview.totalCostUSD30d,
            "providers": rows,
            "generated_at": iso(overview.generatedAt),
        ]
        emit(data, human: analyticsTable(snapshots, days: days), options: options)
    }

    @MainActor
    private static func serverCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let verb = args.first?.lowercased() ?? "status"
        if !args.isEmpty { args.removeFirst() }
        switch verb {
        case "status":
            try rejectExtra(args)
            let running = await proxyIsReachable()
            emit(["running": running, "url": "http://127.0.0.1:8317", "backend_url": ManagementCredentials.backendBaseURL], human: running ? "Proxy is running at http://127.0.0.1:8317" : "Proxy is stopped", options: options)
        case "start":
            try rejectExtra(args)
            if !menuBarAppIsRunning() { try await launchMenuBarApp() }
            DistributedNotificationCenter.default().postNotificationName(VibeRouterDistributedCommand.serverStart, object: nil, userInfo: nil, deliverImmediately: true)
            try await waitForProxy(wanted: true)
            emit(["running": true, "url": "http://127.0.0.1:8317"], human: "Proxy started at http://127.0.0.1:8317", options: options)
        case "stop", "restart":
            try rejectExtra(args)
            guard menuBarAppIsRunning() else { throw Failure("app_not_running", "The VibeRouter menu-bar app is not running.") }
            let name = verb == "stop" ? VibeRouterDistributedCommand.serverStop : VibeRouterDistributedCommand.serverRestart
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
            if verb == "stop" { try await waitForProxy(wanted: false) }
            else {
                try await waitForProxy(wanted: false, timeoutChecks: 50)
                try await waitForProxy(wanted: true, timeoutChecks: 70)
            }
            emit(["running": verb == "restart"], human: "Proxy \(verb == "stop" ? "stopped" : "restarted")", options: options)
        case "logs":
            let follow = takeFlag("--follow", from: &args) || takeFlag("-f", from: &args)
            try rejectExtra(args)
            repeat {
                let response = try await managementRequest(method: "GET", path: "/logs")
                if options.json { emit(response, human: "", options: options) }
                else { print(prettyJSON(response)) }
                if follow { try await Task.sleep(nanoseconds: 2_000_000_000) }
            } while follow
        case "open":
            try rejectExtra(args)
            NSWorkspace.shared.open(ManagementCredentials.managementHTMLURL)
            emit(["opened": ManagementCredentials.managementHTMLURL.absoluteString], human: "Opened the management console", options: options)
        default:
            throw Failure("unknown_subcommand", "Unknown server command: \(verb)", hint: "Use status, start, stop, restart, logs, or open.", exitCode: 2)
        }
    }

    @MainActor
    private static func loginCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        guard let provider = args.first?.lowercased() else { throw missing("provider") }
        args.removeFirst(); try rejectExtra(args)

        if provider == "kiro" {
            guard !options.json else {
                throw Failure("interactive_required", "Kiro login opens an interactive browser flow.", hint: "Run `viberouter login kiro` in a terminal without --json.", exitCode: 2)
            }
            let result = await KiroAWSAuth.addAccount()
            switch result {
            case .success(let message): emit(["connected": true, "provider": provider], human: message, options: options)
            case .failure(let message): throw Failure("login_failed", message)
            }
            return
        }

        let flags: [String: String] = [
            "claude": "claude-login", "codex": "codex-login", "gemini": "login",
            "kimi": "kimi-login", "antigravity": "antigravity-login", "grok": "xai-login", "xai": "xai-login",
        ]
        guard let flag = flags[provider] else {
            throw Failure("login_unsupported", "No direct OAuth login is available for \(provider).", hint: "Use `viberouter import \(provider)` for supported signed-in desktop apps, or the VibeRouter Settings window.", exitCode: 2)
        }
        guard !options.json, isatty(STDIN_FILENO) == 1 else {
            throw Failure("interactive_required", "OAuth login requires an interactive terminal/browser.", hint: "Run `viberouter login \(provider)` without --json.", exitCode: 2)
        }
        guard let binary = bundledProxyBinary() else {
            throw Failure("binary_not_found", "Could not find cli-proxy-api-plus.", hint: "Run the CLI from an installed VibeRouter.app bundle.")
        }
        guard let config = activeConfigPath() else {
            throw Failure("config_not_found", "Could not find VibeRouter's active config.", hint: "Launch VibeRouter once before logging in.")
        }
        let preAuthSnapshot = AuthAccountLifecycle.authFileSnapshot()
        print("Starting \(provider) login…")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--config", config.path, "-\(flag)"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do { try process.run(); process.waitUntilExit() }
        catch { throw Failure("login_failed", "Could not start login: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else { throw Failure("login_failed", "Login exited with status \(process.terminationStatus).") }
        AuthAccountLifecycle.clearTombstonesForPresentCodexSeats()
        let changedFiles = AuthAccountLifecycle.authFilesChanged(since: preAuthSnapshot)
        print("Login complete. Run `viberouter accounts` to verify the new account.")
        if !changedFiles.isEmpty {
            print("Saved: \(changedFiles.map(\.lastPathComponent).joined(separator: ", "))")
        }
    }

    @MainActor
    private static func importCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        guard let provider = args.first?.lowercased() else { throw missing("provider") }
        args.removeFirst()
        let source = takeOption("--source", from: &args)
        try rejectExtra(args)

        if provider == "list" {
            let discovered = await Task.detached(priority: .userInitiated) {
                ServiceType.allCases.flatMap { ConfiguredAccountDiscovery.discover(for: $0) }
            }.value
            let rows = discovered.map(importCandidateJSON)
            let human = discovered.isEmpty
                ? "No importable local sessions found."
                : discovered.map { "\(pad($0.serviceType.rawValue, 18)) \(pad($0.sourceAppName, 20)) \($0.displayName)  [\($0.id)]" }.joined(separator: "\n")
            emit(["candidates": rows, "count": rows.count], human: human, options: options)
            return
        }

        guard let serviceType = serviceType(forCLIProvider: provider) else {
            throw Failure(
                "import_unsupported",
                "Desktop-session import is not available for \(provider).",
                hint: "Run `viberouter import list` to discover supported local sessions.",
                exitCode: 2
            )
        }
        let discovered = await Task.detached(priority: .userInitiated) {
            ConfiguredAccountDiscovery.discover(for: serviceType)
        }.value
        guard !discovered.isEmpty else {
            throw Failure(
                "import_not_found",
                "No signed-in \(serviceType.displayName) session was found.",
                hint: "Sign in to the native app first, then run `viberouter import list`."
            )
        }
        let candidate: DiscoveredConfiguredAccount
        if let source {
            guard !source.isEmpty,
                  let match = discovered.first(where: {
                      $0.id.caseInsensitiveCompare(source) == .orderedSame
                          || $0.displayName.caseInsensitiveCompare(source) == .orderedSame
                  })
            else {
                throw Failure("import_source_not_found", "No \(serviceType.displayName) import source matches \(source).", hint: "Run `viberouter import list --json` and pass its exact id with --source.", exitCode: 4)
            }
            candidate = match
        } else if discovered.count == 1 {
            candidate = discovered[0]
        } else {
            throw Failure(
                "ambiguous_import_source",
                "Found \(discovered.count) \(serviceType.displayName) sessions.",
                hint: "Pass --source with one of: \(discovered.map(\.id).joined(separator: ", "))",
                exitCode: 4
            )
        }

        let result = await Task.detached(priority: .userInitiated) {
            ConfiguredAccountImporter.importAccount(candidate)
        }.value
        switch result {
        case .success(let message):
            emit(
                ["imported": true, "provider": serviceType.rawValue, "source": importCandidateJSON(candidate), "message": message],
                human: message,
                options: options
            )
        case .failure(let message): throw Failure("import_failed", message)
        }
    }

    private static func serviceType(forCLIProvider provider: String) -> ServiceType? {
        switch provider.lowercased() {
        case "copilot": return .copilot
        case "grok": return .grok
        case "z.ai", "z-ai", "glm": return .zai
        default: return ServiceType(rawValue: provider.lowercased())
        }
    }

    private static func importCandidateJSON(_ candidate: DiscoveredConfiguredAccount) -> [String: Any] {
        [
            "id": candidate.id,
            "provider": candidate.serviceType.rawValue,
            "account": candidate.displayName,
            "source_app": candidate.sourceAppName,
        ]
    }

    @MainActor
    private static func providerCommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let verb = args.first?.lowercased() ?? "list"
        if !args.isEmpty { args.removeFirst() }
        switch verb {
        case "list", "ls":
            try rejectExtra(args)
            let saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] ?? [:]
            let rows = ProviderCatalog.oauthProviderKeys.keys.sorted().map { key -> [String: Any] in
                ["id": key, "proxy_id": ProviderCatalog.oauthProviderKeys[key]!, "enabled": saved[key] ?? true]
            }
            let human = rows.map { "\(pad($0["id"] as! String, 20)) \(($0["enabled"] as! Bool) ? "enabled" : "disabled")" }.joined(separator: "\n")
            emit(["providers": rows], human: human, options: options)
        case "enable", "disable":
            guard let provider = args.first else { throw missing("provider") }
            args.removeFirst(); try rejectExtra(args)
            guard ProviderCatalog.oauthProviderKeys[provider] != nil else {
                throw Failure("unknown_provider", "Unknown provider: \(provider)", hint: "Run `viberouter providers list`.", exitCode: 2)
            }
            let enabled = verb == "enable"
            var saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] ?? [:]
            saved[provider] = enabled
            UserDefaults.standard.set(saved, forKey: "enabledProviders")
            DistributedNotificationCenter.default().postNotificationName(
                VibeRouterDistributedCommand.providerState,
                object: nil,
                userInfo: ["provider": provider, "enabled": enabled],
                deliverImmediately: true
            )
            emit(["provider": provider, "enabled": enabled], human: "\(enabled ? "Enabled" : "Disabled") \(provider)", options: options)
        case "status":
            try rejectExtra(args)
            let (manager, _) = await loadAccounts(detectCurrent: false)
            let connected = Set(manager.serviceAccounts.compactMap { $0.value.accounts.isEmpty ? nil : $0.key })
            let statuses = await ProviderStatusService.fetch(forConnected: connected)
            let rows = statuses.map(statusJSON)
            let human = statuses.map { "\(pad($0.displayName, 22)) \($0.level.displayName)\($0.incidents.isEmpty ? "" : " · \($0.incidents.count) incident(s)")" }.joined(separator: "\n")
            emit(["statuses": rows, "checked_at": iso(Date())], human: human, options: options)
        default:
            throw Failure("unknown_subcommand", "Unknown provider command: \(verb)", hint: "Use list, enable, disable, or status.", exitCode: 2)
        }
    }

    @MainActor
    private static func settingsCommand(args: [String], options: GlobalOptions) throws {
        var args = args
        let verb = args.first?.lowercased() ?? "list"
        if !args.isEmpty { args.removeFirst() }
        switch verb {
        case "list", "ls":
            try rejectExtra(args)
            let values = settingsValues()
            let human = values.keys.sorted().map { "\(pad($0, 35)) \(display(values[$0]!))" }.joined(separator: "\n")
            emit(["settings": values], human: human, options: options)
        case "get":
            guard let key = args.first else { throw missing("setting name") }
            args.removeFirst(); try rejectExtra(args)
            guard let value = settingsValues()[key] else { throw unknownSetting(key) }
            emit(["setting": key, "value": value], human: display(value), options: options)
        case "set":
            guard args.count >= 2 else { throw missing("setting name and value") }
            let key = args.removeFirst(), value = args.removeFirst()
            try rejectExtra(args)
            try applySetting(key, rawValue: value)
            DistributedNotificationCenter.default().postNotificationName(VibeRouterDistributedCommand.settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
            emit(["setting": key, "value": settingsValues()[key] ?? value], human: "Set \(key) to \(display(settingsValues()[key] ?? value))", options: options)
        default:
            throw Failure("unknown_subcommand", "Unknown settings command: \(verb)", hint: "Use list, get, or set.", exitCode: 2)
        }
    }

    private static func rawAPICommand(args: [String], options: GlobalOptions) async throws {
        var args = args
        let method = (args.first ?? "GET").uppercased()
        if !args.isEmpty { args.removeFirst() }
        guard let path = args.first else { throw missing("management API path") }
        args.removeFirst()
        let body = takeOption("--body", from: &args)
        try rejectExtra(args)
        let jsonBody: Any?
        if let body {
            guard let data = body.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure("invalid_json", "--body must be valid JSON.", exitCode: 2)
            }
            jsonBody = parsed
        } else { jsonBody = nil }
        let response = try await managementRequest(method: method, path: path, body: jsonBody)
        emit(response, human: prettyJSON(response), options: options)
    }

    @MainActor
    private static func doctor(options: GlobalOptions) async throws {
        let (_, accounts) = await loadAccounts()
        let appRunning = menuBarAppIsRunning()
        let proxyRunning = await proxyIsReachable()
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        let checks: [[String: Any]] = [
            ["name": "menu_bar_app", "ok": appRunning, "detail": appRunning ? "running" : "not running"],
            ["name": "proxy", "ok": proxyRunning, "detail": proxyRunning ? "127.0.0.1:8317 reachable" : "not reachable"],
            ["name": "auth_directory", "ok": FileManager.default.fileExists(atPath: authDir.path), "detail": authDir.path],
            ["name": "accounts", "ok": !accounts.isEmpty, "detail": "\(accounts.count) discovered"],
        ]
        let healthy = checks.allSatisfy { $0["ok"] as? Bool == true }
        let human = checks.map { row in
            "\((row["ok"] as! Bool) ? green("✓", options) : red("✗", options)) \(pad(row["name"] as! String, 20)) \(row["detail"] as! String)"
        }.joined(separator: "\n")
        emit(["healthy": healthy, "checks": checks], human: human, options: options)
        // `healthy` is explicit in both output formats. Doctor remains inspectable in
        // pipelines even on a partially configured first run.
    }

    // MARK: - Settings

    @MainActor
    static func settingsValues() -> [String: Any] {
        let s = AppSettings.shared
        return [
            "usage-refresh-minutes": s.usageRefreshMinutes,
            "status-refresh-minutes": s.statusRefreshMinutes,
            "analytics-history-days": s.analyticsHistoryDays,
            "show-cost-estimates": s.showCostEstimates,
            "show-status-tab": s.showStatusTab,
            "show-analytics-tab": s.showAnalyticsTab,
            "auto-update-pricing": s.autoUpdatePricing,
            "menu-bar-usage-badge": s.menuBarUsageBadge,
            "require-management-password": s.requireManagementPassword,
            "restart-app-on-switch": s.restartAppOnSwitch,
            "confirm-before-switch": s.confirmBeforeSwitch,
            "auto-wake-enabled": s.autoWakeEnabled,
            "auto-wake-providers": Array(s.autoWakeProviderIDs).sorted(),
            "auto-wake-grace-minutes": s.autoWakeGraceMinutes,
            "antigravity-auto-switch": s.antigravityAutoSwitchEnabled,
            "antigravity-exhaustion-threshold": s.antigravityExhaustionThreshold,
        ]
    }

    @MainActor
    static func applySetting(_ key: String, rawValue: String) throws {
        let s = AppSettings.shared
        func bool() throws -> Bool {
            switch rawValue.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: throw Failure("invalid_value", "\(key) expects true or false.", exitCode: 2)
            }
        }
        func double(_ range: ClosedRange<Double>) throws -> Double {
            guard let value = Double(rawValue), range.contains(value) else { throw Failure("invalid_value", "\(key) expects a number in \(range).", exitCode: 2) }
            return value
        }
        switch key {
        case "usage-refresh-minutes": s.usageRefreshMinutes = try double(1...30)
        case "status-refresh-minutes": s.statusRefreshMinutes = try double(2...60)
        case "analytics-history-days":
            guard let value = Int(rawValue), (1...365).contains(value) else { throw Failure("invalid_value", "analytics-history-days expects 1...365.", exitCode: 2) }
            s.analyticsHistoryDays = value
        case "show-cost-estimates": s.showCostEstimates = try bool()
        case "show-status-tab": s.showStatusTab = try bool()
        case "show-analytics-tab": s.showAnalyticsTab = try bool()
        case "auto-update-pricing": s.autoUpdatePricing = try bool()
        case "menu-bar-usage-badge": s.menuBarUsageBadge = try bool()
        case "require-management-password": s.requireManagementPassword = try bool()
        case "restart-app-on-switch": s.restartAppOnSwitch = try bool()
        case "confirm-before-switch": s.confirmBeforeSwitch = try bool()
        case "auto-wake-enabled": s.autoWakeEnabled = try bool()
        case "auto-wake-grace-minutes": s.autoWakeGraceMinutes = try double(0...60)
        case "antigravity-auto-switch": s.antigravityAutoSwitchEnabled = try bool()
        case "antigravity-exhaustion-threshold": s.antigravityExhaustionThreshold = try double(50...100)
        case "auto-wake-providers":
            let providers = Set(rawValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            let unknown = providers.subtracting(AppSettings.wakeableProviderIDs)
            guard unknown.isEmpty else { throw Failure("invalid_value", "Providers do not support auto-wake: \(unknown.sorted().joined(separator: ", ")).", exitCode: 2) }
            s.autoWakeProviderIDs = providers
        default: throw unknownSetting(key)
        }
    }

    private static func unknownSetting(_ key: String) -> Failure {
        Failure("unknown_setting", "Unknown setting: \(key)", hint: "Run `viberouter settings list`.", exitCode: 2)
    }

    // MARK: - Data acquisition

    fileprivate static func fetchUsage(_ accounts: [AuthAccount]) async -> [ProviderUsageSnapshot] {
        await withTaskGroup(of: ProviderUsageSnapshot?.self, returning: [ProviderUsageSnapshot].self) { group in
            for account in accounts where account.type.usageProviderID != nil {
                group.addTask {
                    await NativeUsageFetcher.fetchUsage(for: account.type, authFile: account.filePath, authAccountID: account.id)
                }
            }
            var result: [ProviderUsageSnapshot] = []
            for await snapshot in group { if let snapshot { result.append(snapshot) } }
            return result.sorted { lhs, rhs in
                if lhs.providerID != rhs.providerID { return lhs.providerID < rhs.providerID }
                return lhs.accountEmail ?? lhs.id < rhs.accountEmail ?? rhs.id
            }
        }
    }

    private static func proxyIsReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8317/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        request.setValue("Bearer viberouter-cli", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
        } catch { return false }
    }

    private static func managementRequest(method: String, path: String, body: Any? = nil) async throws -> Any {
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "\(ManagementCredentials.backendBaseURL)/v0/management\(normalized)") else {
            throw Failure("invalid_path", "Invalid management API path.", exitCode: 2)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(ManagementCredentials.secretKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure("api_error", "Management API returned an invalid response.") }
            let value: Any = data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? ["text": String(data: data, encoding: .utf8) ?? ""])
            guard (200..<300).contains(http.statusCode) else {
                let detail = (value as? [String: Any])?["error"] as? String
                throw Failure("api_error", detail ?? "Management API returned HTTP \(http.statusCode).", hint: http.statusCode == 401 ? "Check the management key and password setting." : nil)
            }
            return value
        } catch let failure as Failure { throw failure }
        catch { throw Failure("api_unreachable", "Could not reach the management API.", hint: "Run `viberouter server start`.") }
    }

    // MARK: - Account helpers

    private static func filterAccounts(_ accounts: [AuthAccount], provider: String?) -> [AuthAccount] {
        guard let provider else { return accounts }
        return accounts.filter { $0.type.rawValue.caseInsensitiveCompare(provider) == .orderedSame || $0.type.usageProviderID?.caseInsensitiveCompare(provider) == .orderedSame }
    }

    private static func resolveAccount(_ selector: String, in accounts: [AuthAccount]) throws -> AuthAccount {
        if let exact = accounts.first(where: { $0.id.caseInsensitiveCompare(selector) == .orderedSame }) { return exact }
        let needle = selector.lowercased()
        let matches = accounts.filter {
            $0.displayName.lowercased() == needle || $0.baseDisplayName.lowercased() == needle || $0.id.lowercased().contains(needle)
        }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw Failure("account_not_found", "No account matches \(selector).", hint: "Run `viberouter accounts --json` and use its id.", exitCode: 4) }
        throw Failure("ambiguous_account", "\(selector) matches \(matches.count) accounts.", hint: "Use the exact account id: \(matches.map(\.id).joined(separator: ", ")).", exitCode: 4)
    }

    private static func requireConfirmation(_ prompt: String, options: GlobalOptions) throws {
        if options.yes { return }
        if options.json || isatty(STDIN_FILENO) != 1 {
            throw Failure("confirmation_required", prompt, hint: "Re-run with --yes after verifying the target.", exitCode: 2)
        }
        FileHandle.standardError.write(Data("\(prompt) [y/N] ".utf8))
        guard readLine()?.lowercased() == "y" else { throw Failure("cancelled", "Cancelled.", exitCode: 2) }
    }

    // MARK: - App IPC

    private static func menuBarAppIsRunning() -> Bool {
        // `com.cliproxyapi.menubar` was used by older bundles. Keep it as a fallback so
        // the CLI can still control an app that has not been upgraded yet.
        ["com.viberouter.app", "com.cliproxyapi.menubar"].contains { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
                $0.processIdentifier != getpid() && !$0.isTerminated
            }
        }
    }

    @MainActor
    private static func launchMenuBarApp() async throws {
        let candidates = [
            URL(fileURLWithPath: "/Applications/VibeRouter.app"),
            Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("VibeRouter.app"),
        ].compactMap { $0 }
        guard let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw Failure("app_not_installed", "Could not find VibeRouter.app.", hint: "Install the app or run `make app` from the repository.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // The CLI is the same app-bundle executable. Force a separate instance so Launch
        // Services does not mistake this short-lived command process for the menu-bar app.
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: Failure("app_launch_failed", "Could not launch VibeRouter: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Shell installation

    private static func installCLICommand(args: [String], options: GlobalOptions) throws {
        var args = args
        let defaultPrefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let rawPrefix = takeOption("--prefix", from: &args) ?? defaultPrefix
        try rejectExtra(args)
        guard !rawPrefix.isEmpty else {
            throw Failure("invalid_prefix", "--prefix must name a directory.", exitCode: 2)
        }

        let prefix = URL(fileURLWithPath: (rawPrefix as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let link = prefix.appendingPathComponent("viberouter")
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw Failure("executable_not_found", "Could not resolve the current VibeRouter executable.")
        }

        do {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try FileManager.default.removeItem(at: link)
            } else if FileManager.default.fileExists(atPath: link.path) {
                throw Failure(
                    "install_target_exists",
                    "\(link.path) already exists and is not a symbolic link.",
                    hint: "Move that file or choose another directory with --prefix."
                )
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(
                "install_failed",
                "Could not install \(link.path): \(error.localizedDescription)",
                hint: "Choose a writable directory, for example `viberouter install-cli --prefix ~/.local/bin`."
            )
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let onPath = pathEntries.contains(prefix.path)
        let human = onPath
            ? "Installed viberouter at \(link.path)"
            : "Installed viberouter at \(link.path)\nAdd this to your shell profile:  export PATH=\"\(prefix.path):$PATH\""
        emit(
            ["installed": true, "path": link.path, "target": executable.path, "directory_on_path": onPath],
            human: human,
            options: options
        )
    }

    private static func waitForProxy(wanted: Bool, timeoutChecks: Int = 40) async throws {
        if await proxyIsReachable() == wanted { return }
        for _ in 0..<timeoutChecks {
            try await Task.sleep(nanoseconds: 150_000_000)
            if await proxyIsReachable() == wanted { return }
        }
        throw Failure("server_timeout", "Timed out waiting for the proxy to \(wanted ? "start" : "stop").")
    }

    private static func bundledProxyBinary() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("cli-proxy-api-plus"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src/Sources/Resources/cli-proxy-api-plus"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Resources/cli-proxy-api-plus"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func activeConfigPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".cli-proxy-api/merged-config.yaml"),
            home.appendingPathComponent(".cli-proxy-api/config.yaml"),
            Bundle.main.resourceURL?.appendingPathComponent("config.yaml"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - JSON shapes

    private static func accountJSON(_ account: AuthAccount) -> [String: Any] {
        [
            "id": account.id,
            "provider": account.type.rawValue,
            "provider_label": account.type.displayName,
            "display_name": account.displayName,
            "email": account.email ?? NSNull(),
            "login": account.login ?? NSNull(),
            "plan": account.planLabel ?? NSNull(),
            "enabled": !account.isDisabled,
            "expired": account.isExpired,
            "current": NativeSessionManager.shared.isCurrent(account),
            "switchable": NativeSessionManager.shared.supportsSwitching(account.type),
            "wakeable": QuotaWakeService.supportsWake(account.type),
            "resettable": RateLimitResetService.supports(account.type),
        ]
    }

    private static func usageJSON(_ snapshot: ProviderUsageSnapshot) -> [String: Any] {
        [
            "account_id": snapshot.id,
            "provider": snapshot.providerID,
            "account": snapshot.accountEmail ?? NSNull(),
            "plan": (snapshot.planLabel ?? snapshot.planType) as Any? ?? NSNull(),
            "source": snapshot.source ?? NSNull(),
            "windows": snapshot.windows.map(windowJSON),
            "subscriptions": snapshot.subAccounts.map { sub in
                ["id": sub.id, "title": sub.title, "subtitle": sub.subtitle ?? NSNull(), "plan": sub.planType ?? NSNull(), "windows": sub.windows.map(windowJSON), "error": sub.errorMessage ?? NSNull()] as [String: Any]
            },
            "rate_limit_resets": snapshot.rateLimitResets.map { reset -> [String: Any] in
                [
                    "available": reset.availableCount,
                    "expires_at": reset.nextExpiresAt.map(iso) as Any? ?? NSNull(),
                    "title": reset.sampleTitle as Any? ?? NSNull(),
                    "can_redeem": reset.canRedeem,
                    "surface_only": reset.surfaceOnly,
                ]
            } ?? NSNull(),
            "updated_at": snapshot.updatedAt.map(iso) ?? NSNull(),
            "error": snapshot.errorMessage ?? NSNull(),
        ]
    }

    private static func windowJSON(_ window: RateWindow) -> [String: Any] {
        [
            "label": window.displayTitle,
            "used_percent": window.usedPercent,
            "remaining_percent": window.remainingPercent,
            "window_minutes": window.windowMinutes ?? NSNull(),
            "resets_at": window.resetsAt.map(iso) ?? NSNull(),
            "reset_description": window.resetDescription ?? NSNull(),
            "remaining_value": window.remainingValue ?? NSNull(),
            "total_value": window.totalValue ?? NSNull(),
            "unit": window.unitLabel ?? NSNull(),
        ]
    }

    private static func costJSON(_ cost: ProviderCostSnapshot) -> [String: Any] {
        [
            "provider": cost.providerID,
            "session_volume": cost.sessionTokens,
            "period_volume": cost.last30DaysTokens,
            "volume_unit": cost.volumeUnit.rawValue,
            "session_cost_usd": cost.sessionCostUSD ?? NSNull(),
            "period_cost_usd": cost.last30DaysCostUSD ?? NSNull(),
            "models": cost.models.map { ["model": $0.model, "volume": $0.totalTokens, "requests": $0.requestCount, "estimated_cost_usd": $0.estimatedCostUSD] as [String: Any] },
        ]
    }

    private static func statusJSON(_ status: ProviderStatusSnapshot) -> [String: Any] {
        [
            "id": status.id,
            "provider": status.providerKey,
            "name": status.displayName,
            "level": status.level.rawValue,
            "description": status.description ?? NSNull(),
            "url": status.pageURL?.absoluteString ?? NSNull(),
            "updated_at": status.updatedAt.map(iso) ?? NSNull(),
            "error": status.errorMessage ?? NSNull(),
            "incidents": status.incidents.map { ["id": $0.id, "name": $0.name, "status": $0.status, "impact": $0.impact ?? NSNull()] as [String: Any] },
        ]
    }

    // MARK: - Human tables

    private static func accountTable(_ accounts: [AuthAccount]) -> String {
        guard !accounts.isEmpty else { return "No accounts found. Connect or import an account in VibeRouter Settings." }
        var lines = ["\(pad("PROVIDER", 18)) \(pad("ACCOUNT", 34)) \(pad("STATE", 12)) ID"]
        for account in accounts {
            let state = account.isDisabled ? "disabled" : account.isExpired ? "expired" : NativeSessionManager.shared.isCurrent(account) ? "● active" : "ready"
            lines.append("\(pad(account.type.displayName, 18)) \(pad(account.displayName, 34)) \(pad(state, 12)) \(account.id)")
        }
        return lines.joined(separator: "\n")
    }

    private static func usageTable(_ snapshots: [ProviderUsageSnapshot], accounts: [AuthAccount]) -> String {
        guard !snapshots.isEmpty else { return "No live quota data is available." }
        var lines: [String] = []
        for snapshot in snapshots {
            let account = accounts.first { $0.id == snapshot.id }
            lines.append("\n\(account?.type.displayName ?? snapshot.providerID) · \(snapshot.accountEmail ?? account?.displayName ?? snapshot.id)")
            if let error = snapshot.errorMessage { lines.append("  ! \(error)") }
            for window in snapshot.windows {
                lines.append("  \(pad(window.displayTitle, 22)) \(bar(window.usedPercent, width: 18))  \(window.primaryMetricText)\(window.resetDescription.map { " · \($0)" } ?? "")")
            }
            for sub in snapshot.subAccounts {
                lines.append("  \(sub.title) [subscription \(sub.id)]")
                for window in sub.windows {
                    lines.append("    \(pad(window.displayTitle, 20)) \(bar(window.usedPercent, width: 16))  \(window.primaryMetricText)")
                }
            }
            if let resets = snapshot.rateLimitResets { lines.append("  ↻ \(resets.summaryLine)") }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func analyticsTable(_ snapshots: [ProviderCostSnapshot], days: Int) -> String {
        guard !snapshots.isEmpty else { return "No local usage history found." }
        var lines = ["\(pad("PROVIDER", 18)) \(pad("SESSION", 16)) \(pad("\(days)-DAY VOLUME", 18)) EST. COST"]
        for row in snapshots.sorted(by: { $0.last30DaysTokens > $1.last30DaysTokens }) {
            lines.append("\(pad(row.providerID, 18)) \(pad(UsageNumberFormatter.volume(row.sessionTokens, unit: row.volumeUnit), 16)) \(pad(UsageNumberFormatter.volume(row.last30DaysTokens, unit: row.volumeUnit), 18)) \(money(row.last30DaysCostUSD))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Agent contract and help

    private static func capabilities() -> [String: Any] {
        [
            "contract_version": version,
            "global_flags": ["--json", "--plain", "--yes", "--no-color"],
            "commands": [
                "status": ["mutates": false],
                "accounts list [--provider ID]": ["mutates": false],
                "account enable|disable|delete|refresh ID": ["mutates": true],
                "auth refresh [--all|ID] [--force]": ["mutates": true, "network": true, "description": "Proactively refreshes OAuth tokens for accounts"],
                "auth status [--provider ID]": ["mutates": false, "description": "Inspect token expiry and refreshability"],
                "usage [--provider ID] [--account ID]": ["mutates": false, "network": true],
                "switch ID [--provider ID] [--subscription ID] [--no-restart]": ["mutates": true, "confirmation": true],
                "wake ID [--provider ID]": ["mutates": true, "description": "Starts a provider session/5-hour quota window"],
                "reset ID [--provider ID]": ["mutates": true, "confirmation": true, "description": "Consumes one manual rate-limit reset"],
                "analytics [--days N]": ["mutates": false],
                "provider list|enable|disable|status": ["mutates": "enable/disable"],
                "server status|start|stop|restart|logs|open": ["mutates": "except status/logs"],
                "login PROVIDER": ["mutates": true, "interactive": true],
                "import list|PROVIDER [--source ID]": ["mutates": "except list"],
                "install-cli [--prefix DIR]": ["mutates": true, "description": "Installs the viberouter command as a symlink"],
                "settings list|get|set": ["mutates": "set"],
                "api METHOD PATH [--body JSON]": ["mutates": "method-dependent", "description": "Escape hatch for every proxy management API"],
                "doctor": ["mutates": false],
                "tui": ["interactive": true],
            ],
            "switchable_providers": Array(NativeSessionManager.switchableProviderIDs).sorted(),
            "wakeable_providers": AppSettings.wakeableProviderIDs,
            "agent_rules": [
                "Always use --json.",
                "Resolve an account with accounts --json and pass its exact id.",
                "Pass --yes only after checking the exact target for switch, delete, or reset.",
                "Use wake to trigger a session/5-hour window; use reset only to consume a reset credit.",
                "Treat non-zero exit status as failure and inspect error.code and error.hint.",
            ],
            "exit_codes": ["0": "success", "1": "operation failed", "2": "invalid input or confirmation required", "4": "account or import-source resolution failed"],
        ]
    }

    private static func agentGuide() -> String {
        """
        VibeRouter agent guide

        Discover:  viberouter capabilities --json
        Inspect:   viberouter status --json
                   viberouter accounts --json
                   viberouter usage --json
        Switch:    viberouter switch ACCOUNT_ID --yes --json
        Start 5h:  viberouter wake ACCOUNT_ID --json
        Reset:     viberouter reset ACCOUNT_ID --yes --json

        Account selectors should be exact ids returned by `accounts --json`. A wake sends a
        tiny request to start a rolling session window; reset consumes a limited reset credit.
        Every JSON response is a single object with `ok`, `data`, and `meta` or `ok` and `error`.
        """
    }

    private static func printHelp() {
        print("""
        VibeRouter CLI — control accounts, quotas, routing, and analytics

        Usage: viberouter <command> [options]

          tui                              Interactive terminal dashboard (default)
          status                           Proxy, account, and native-session summary
          accounts [--provider ID]         List accounts and capabilities
          account enable|disable ID        Toggle a proxy account
          account delete ID --yes          Delete an account/seat
          account refresh [ID] [--all]     Refresh OAuth tokens
          auth refresh [--all|ID] [--force] Proactively refresh OAuth access tokens
          auth status                      Inspect OAuth expiration & refreshability
          usage [--provider ID]             Fetch live limits and reset times
          switch ID --yes                  Switch the native CLI/desktop account
          wake ID                          Trigger its session / 5-hour window
          reset ID --yes                   Consume a manual rate-limit reset
          analytics [--days 30]            Local token/credit/cost analytics
          providers list|enable|disable    Control proxy routing providers
          provider status                  Fetch provider health and incidents
          server status|start|stop|restart Control the local proxy
          server logs [--follow]           View backend logs
          server open                      Open the web management console
          login PROVIDER                   Run an interactive OAuth/browser login
          import list|PROVIDER             Discover or import a signed-in local session
          install-cli [--prefix DIR]       Install the viberouter shell command
          settings list|get|set            Read or update VibeRouter preferences
          api METHOD PATH [--body JSON]     Call any proxy management endpoint
          doctor                           Check app, proxy, auth, and accounts
          capabilities --json              Machine-readable agent contract
          completion zsh|bash|fish         Print shell completion setup

        Global: --json  --plain  --yes/-y  --no-color

        Run `viberouter agent-guide` for safe automation examples.
        """)
    }

    private static func completionCommand(args: [String], options: GlobalOptions) throws {
        guard let shell = args.first?.lowercased() else { throw missing("shell (zsh, bash, or fish)") }
        try rejectExtra(Array(args.dropFirst()))
        let script = try completionScript(for: shell)
        emit(["shell": shell, "script": script], human: script, options: options)
    }

    static func completionScript(for shell: String) throws -> String {
        let commands = "tui status accounts account auth usage switch wake reset analytics providers provider server login import install-cli settings api doctor capabilities agent-guide help version"
        switch shell {
        case "zsh":
            return """
            # Add to ~/.zshrc:  source <(viberouter completion zsh)
            _viberouter() {
              local -a commands
              commands=(\(commands.replacingOccurrences(of: " ", with: "\n    ")))
              if (( CURRENT == 2 )); then _describe 'command' commands
              else _arguments '*:argument:->args'; fi
            }
            compdef _viberouter viberouter
            """
        case "bash":
            return """
            # Add to ~/.bashrc:  source <(viberouter completion bash)
            _viberouter_complete() {
              COMPREPLY=( $(compgen -W "\(commands)" -- "${COMP_WORDS[COMP_CWORD]}") )
            }
            complete -F _viberouter_complete viberouter
            """
        case "fish":
            return "complete -c viberouter -f -n '__fish_use_subcommand' -a '\(commands)'"
        default:
            throw Failure("unsupported_shell", "Unsupported shell: \(shell)", hint: "Supported: zsh, bash, fish.", exitCode: 2)
        }
    }

    // MARK: - Output and parsing

    private static func emit(_ data: Any, human: String, options: GlobalOptions) {
        if options.json {
            let envelope: [String: Any] = ["ok": true, "data": data, "meta": ["contract_version": version, "timestamp": iso(Date())]]
            print(compactJSON(envelope))
        } else { print(human) }
    }

    private static func emitFailure(_ failure: Failure, options: GlobalOptions) {
        if options.json {
            var error: [String: Any] = ["code": failure.code, "message": failure.message]
            if let hint = failure.hint { error["hint"] = hint }
            fputs(compactJSON(["ok": false, "error": error, "meta": ["contract_version": version, "timestamp": iso(Date())]]) + "\n", stderr)
        } else {
            fputs("Error: \(failure.message)\n", stderr)
            if let hint = failure.hint { fputs("Hint: \(hint)\n", stderr) }
        }
    }

    private static func takeOption(_ name: String, from args: inout [String]) -> String? {
        if let index = args.firstIndex(where: { $0 == name || $0.hasPrefix("\(name)=") }) {
            let token = args.remove(at: index)
            if let equals = token.firstIndex(of: "=") { return String(token[token.index(after: equals)...]) }
            guard index < args.count else { return "" }
            return args.remove(at: index)
        }
        return nil
    }

    private static func takeFlag(_ name: String, from args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index); return true
    }

    private static func rejectExtra(_ args: [String]) throws {
        if let extra = args.first { throw Failure("unexpected_argument", "Unexpected argument: \(extra)", exitCode: 2) }
    }

    private static func missing(_ value: String) -> Failure {
        Failure("missing_argument", "Missing \(value).", hint: "Run `viberouter help`.", exitCode: 2)
    }

    private static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{\"ok\":false,\"error\":{\"code\":\"encoding_error\"}}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return String(describing: value) }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    fileprivate static func pad(_ string: String, _ width: Int) -> String { String(string.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0) }
    private static func display(_ value: Any) -> String {
        if let array = value as? [String] { return array.joined(separator: ",") }
        return String(describing: value)
    }
    private static func formatNumber(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }
    private static func money(_ value: Double?) -> String { value.map { String(format: "$%.2f", $0) } ?? "—" }
    fileprivate static func bar(_ percent: Double, width: Int) -> String {
        let filled = min(width, max(0, Int((percent / 100 * Double(width)).rounded())))
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled) + "]"
    }
    private static func title(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[1;38;5;141m\(value)\u{001B}[0m" : value }
    private static func green(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[32m\(value)\u{001B}[0m" : value }
    private static func red(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[31m\(value)\u{001B}[0m" : value }
    private static func yellow(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[33m\(value)\u{001B}[0m" : value }
    private static func blue(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[34m\(value)\u{001B}[0m" : value }
    private static func dim(_ value: String, _ options: GlobalOptions) -> String { options.color ? "\u{001B}[2m\(value)\u{001B}[0m" : value }
    private static func relativeTime(to date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff < 0 {
            let past = Int(-diff)
            if past < 60 { return "\(past)s ago" }
            if past < 3600 { return "\(past / 60)m ago" }
            if past < 86400 { return "\(past / 3600)h ago" }
            return "\(past / 86400)d ago"
        } else {
            let future = Int(diff)
            if future < 60 { return "in \(future)s" }
            if future < 3600 { return "in \(future / 60)m" }
            if future < 86400 { return "in \(future / 3600)h" }
            return "in \(future / 86400)d"
        }
    }
}

// MARK: - Interactive TUI

@MainActor
private final class TerminalDashboard {
    private enum Page: Int, CaseIterable { case overview, accounts, usage, help }
    private var page: Page = .overview
    private var accounts: [AuthAccount] = []
    private var usage: [String: ProviderUsageSnapshot] = [:]
    private var selected = 0
    private var message = "Loading live quotas…"
    private var oldTerm = termios()

    func run() async throws {
        try enableRawMode()
        defer { restoreTerminal() }
        await reload(fetchLimits: true)
        while true {
            render()
            guard let key = readKey() else { break }
            switch key {
            case "q", "Q": return
            case "\t": page = Page(rawValue: (page.rawValue + 1) % Page.allCases.count)!; selected = 0
            case "j", "↓": selected = min(max(0, visibleAccounts.count - 1), selected + 1)
            case "k", "↑": selected = max(0, selected - 1)
            case "r", "R": message = "Refreshing live quotas…"; render(); await reload(fetchLimits: true)
            case "s", "S": await switchSelected()
            case "w", "W": await wakeSelected()
            case "e", " ": toggleSelected()
            case "x": await resetSelected()
            case "?": page = .help
            case "1": page = .overview
            case "2": page = .accounts
            case "3": page = .usage
            case "4": page = .help
            default: break
            }
        }
    }

    private var visibleAccounts: [AuthAccount] { accounts }

    private func reload(fetchLimits: Bool) async {
        let manager = AuthManager(); manager.checkAuthStatus()
        accounts = ServiceType.allCases.flatMap { manager.accounts(for: $0) }
        await NativeSessionManager.shared.refreshNow(accounts: manager.serviceAccounts.mapValues(\.accounts))
        if fetchLimits {
            let snapshots = await VibeRouterCLI.fetchUsage(accounts.filter { !$0.isDisabled })
            usage = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        }
        selected = min(selected, max(0, accounts.count - 1))
        message = "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
    }

    private func switchSelected() async {
        guard accounts.indices.contains(selected) else { return }
        let account = accounts[selected]
        guard NativeSessionManager.shared.supportsSwitching(account.type) else { message = "Switching is not supported for \(account.type.displayName)"; return }
        guard confirm("Switch \(account.type.displayName) to \(account.displayName)?") else { message = "Switch cancelled"; return }
        message = "Switching…"; render()
        let result = await NativeSessionManager.shared.switchTo(account, subscriptionLabel: account.planLabel, restartApp: AppSettings.shared.restartAppOnSwitch)
        switch result { case .switched(let text), .failure(let text): message = text }
        await reload(fetchLimits: false)
    }

    private func wakeSelected() async {
        guard accounts.indices.contains(selected) else { return }
        let account = accounts[selected]
        guard QuotaWakeService.supportsWake(account.type) else { message = "No wakeable 5-hour/session window for \(account.type.displayName)"; return }
        message = "Sending a tiny wake request…"; render()
        let result = await QuotaWakeService.wake(account: account)
        switch result { case .success(let text), .failure(let text): message = text }
    }

    private func toggleSelected() {
        guard accounts.indices.contains(selected) else { return }
        let account = accounts[selected]
        let manager = AuthManager(); manager.checkAuthStatus()
        if manager.toggleAccountDisabled(account) { message = account.isDisabled ? "Enabled \(account.displayName)" : "Disabled \(account.displayName)" }
        else { message = "Could not toggle account (the final enabled account is protected)" }
        manager.checkAuthStatus(); accounts = ServiceType.allCases.flatMap { manager.accounts(for: $0) }
    }

    private func resetSelected() async {
        guard accounts.indices.contains(selected) else { return }
        let account = accounts[selected]
        guard RateLimitResetService.supports(account.type) else { message = "Manual reset is unavailable for \(account.type.displayName)"; return }
        guard confirm("Consume one rate-limit reset for \(account.displayName)?") else { message = "Reset cancelled"; return }
        let result = await RateLimitResetService.redeem(account: account)
        switch result { case .success(let text), .failure(let text): message = text }
    }

    private func render() {
        let size = terminalSize()
        var lines = ["\u{001B}[1;38;5;141m◆ VibeRouter\u{001B}[0m  \u{001B}[2mAI traffic control\u{001B}[0m", ""]
        let names = ["1 Overview", "2 Accounts", "3 Usage", "4 Help"]
        lines.append(names.enumerated().map { index, name in index == page.rawValue ? "\u{001B}[1;7m \(name) \u{001B}[0m" : " \(name) " }.joined(separator: " "))
        lines.append(String(repeating: "─", count: min(size.width, 100)))
        switch page {
        case .overview: renderOverview(into: &lines)
        case .accounts: renderAccounts(into: &lines)
        case .usage: renderUsage(into: &lines)
        case .help: renderHelp(into: &lines)
        }
        lines.append("")
        lines.append("\u{001B}[38;5;245m\(message)\u{001B}[0m")
        lines.append("\u{001B}[2mTab page  j/k move  r refresh  s switch  w wake  e toggle  x reset  q quit\u{001B}[0m")
        let clipped = Array(lines.prefix(max(1, size.height - 1))).map { String($0.prefix(max(1, size.width))) }.joined(separator: "\n")
        print("\u{001B}[H\u{001B}[2J" + clipped, terminator: "")
        fflush(stdout)
    }

    private func renderOverview(into lines: inout [String]) {
        let providers = Set(accounts.map(\.type)).count
        let enabled = accounts.filter { !$0.isDisabled }.count
        lines += ["", "  \u{001B}[1m\(enabled)\u{001B}[0m enabled accounts    \u{001B}[1m\(providers)\u{001B}[0m connected providers", ""]
        for type in ServiceType.allCases {
            let list = accounts.filter { $0.type == type }
            guard !list.isEmpty else { continue }
            let worst = list.compactMap { usage[$0.id] }.flatMap(\.windows).map(\.usedPercent).max()
            let current = NativeSessionManager.shared.currentIdentity(for: type)?.label ?? "—"
            lines.append("  \(VibeRouterCLI.pad(type.displayName, 19)) \(VibeRouterCLI.pad("\(list.count) account\(list.count == 1 ? "" : "s")", 12)) \(worst.map { VibeRouterCLI.bar($0, width: 14) + String(format: " %3.0f%%", $0) } ?? "no quota data         ")  active: \(current)")
        }
    }

    private func renderAccounts(into lines: inout [String]) {
        lines += ["", "  \(VibeRouterCLI.pad("PROVIDER", 17)) \(VibeRouterCLI.pad("ACCOUNT", 34)) \(VibeRouterCLI.pad("STATE", 11)) ACTIONS"]
        for (index, account) in visibleAccounts.enumerated() {
            let cursor = index == selected ? "\u{001B}[38;5;141m›\u{001B}[0m" : " "
            let state = account.isDisabled ? "disabled" : NativeSessionManager.shared.isCurrent(account) ? "● active" : account.isExpired ? "expired" : "ready"
            var actions: [String] = []
            if NativeSessionManager.shared.supportsSwitching(account.type) { actions.append("switch") }
            if QuotaWakeService.supportsWake(account.type) { actions.append("wake") }
            lines.append("\(cursor) \(VibeRouterCLI.pad(account.type.displayName, 17)) \(VibeRouterCLI.pad(account.displayName, 34)) \(VibeRouterCLI.pad(state, 11)) \(actions.joined(separator: "/"))")
        }
        if accounts.isEmpty { lines.append("\n  No accounts found. Import one from the VibeRouter Settings window.") }
    }

    private func renderUsage(into lines: inout [String]) {
        lines.append("")
        for (index, account) in visibleAccounts.enumerated() where !account.isDisabled {
            let cursor = index == selected ? "\u{001B}[38;5;141m›\u{001B}[0m" : " "
            lines.append("\(cursor) \u{001B}[1m\(account.type.displayName)\u{001B}[0m · \(account.displayName)")
            guard let snap = usage[account.id] else { lines.append("    no quota data"); continue }
            if let error = snap.errorMessage { lines.append("    \u{001B}[31m! \(error)\u{001B}[0m") }
            for window in snap.windows.prefix(4) {
                lines.append("    \(VibeRouterCLI.pad(window.displayTitle, 18)) \(VibeRouterCLI.bar(window.usedPercent, width: 18)) \(window.primaryMetricText)")
            }
            for sub in snap.subAccounts.prefix(3) {
                lines.append("    \(sub.title)")
                for window in sub.windows.prefix(2) { lines.append("      \(VibeRouterCLI.pad(window.displayTitle, 16)) \(VibeRouterCLI.bar(window.usedPercent, width: 16)) \(window.primaryMetricText)") }
            }
        }
    }

    private func renderHelp(into lines: inout [String]) {
        lines += [
            "", "  Keyboard", "    j / k or arrows   Move selection", "    s                 Switch selected native account", "    w                 Trigger selected 5h/session window", "    e / Space         Enable or disable selected proxy account", "    x                 Consume one manual rate-limit reset", "    r                 Refresh accounts and live quotas", "    Tab / 1…4         Change page", "    q                 Quit", "", "  Automation", "    viberouter capabilities --json", "    viberouter accounts --json", "    viberouter usage --json", "    viberouter switch ACCOUNT_ID --yes --json",
        ]
    }

    private func confirm(_ prompt: String) -> Bool {
        let size = terminalSize()
        print("\u{001B}[\(size.height);1H\u{001B}[2K\u{001B}[1;33m\(prompt) [y/N]\u{001B}[0m ", terminator: "")
        fflush(stdout)
        return readKey()?.lowercased() == "y"
    }

    private func enableRawMode() throws {
        guard tcgetattr(STDIN_FILENO, &oldTerm) == 0 else { throw VibeRouterCLI.Failure("tty_error", "Could not configure the terminal.") }
        var raw = oldTerm
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_cc.16 = 1 // VMIN on Darwin
        raw.c_cc.17 = 0 // VTIME on Darwin
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { throw VibeRouterCLI.Failure("tty_error", "Could not enter interactive terminal mode.") }
        print("\u{001B}[?1049h\u{001B}[?25l", terminator: "")
    }

    private func restoreTerminal() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTerm)
        print("\u{001B}[?25h\u{001B}[?1049l", terminator: "")
        fflush(stdout)
    }

    private func readKey() -> String? {
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        if byte == 27 {
            var seq = [UInt8](repeating: 0, count: 2)
            if Darwin.read(STDIN_FILENO, &seq, 2) == 2, seq[0] == 91 {
                if seq[1] == 65 { return "↑" }
                if seq[1] == 66 { return "↓" }
            }
            return "\u{001B}"
        }
        return String(bytes: [byte], encoding: .utf8)
    }

    private func terminalSize() -> (width: Int, height: Int) {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        return (max(60, Int(size.ws_col)), max(16, Int(size.ws_row)))
    }
}
