import AppKit
import Foundation

/// Isolated desktop-app profiles (Cockpit-style multi-instance).
/// Each instance has its own user-data directory and can bind one VibeRouter account.
struct ManagedAppInstance: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var provider: String
    var userDataDir: String
    var boundAccountFile: String?
    var extraArgs: [String]
    var createdAt: Date
    /// `app` (desktop window) or `terminal` (the provider's CLI). Nil = provider default.
    var surface: String? = nil

    enum Surface: String, CaseIterable {
        case app, terminal
    }

    var serviceType: ServiceType? { ServiceType(rawValue: provider) }

    static func make(name: String, provider: ServiceType, userDataDir: URL? = nil) -> ManagedAppInstance {
        let id = UUID().uuidString.lowercased()
        let dir = userDataDir ?? AppInstanceManager.defaultDataDirectory(provider: provider, instanceID: id)
        return ManagedAppInstance(
            id: id,
            name: name,
            provider: provider.rawValue,
            userDataDir: dir.path,
            boundAccountFile: nil,
            extraArgs: [],
            createdAt: Date()
        )
    }
}

enum AppInstanceLaunchResult: Equatable {
    case launched(message: String)
    case failure(message: String)
}

enum AppInstanceManager {
    static let launchableProviders: [ServiceType] = [
        .cursor, .codex, .claude, .antigravity, .copilot, .kiro, .gemini,
        .codebuddy, .codebuddyCN, .windsurf, .qoder, .trae, .zed,
    ]

    /// Where each provider can run. The first entry is the default.
    static func surfaces(for type: ServiceType) -> [ManagedAppInstance.Surface] {
        switch type {
        case .codex, .claude: return [.app, .terminal]
        case .gemini: return [.terminal]
        default: return [.app]
        }
    }

    static func surface(of instance: ManagedAppInstance) -> ManagedAppInstance.Surface {
        let allowed = instance.serviceType.map(surfaces(for:)) ?? [.app]
        if let raw = instance.surface, let chosen = ManagedAppInstance.Surface(rawValue: raw), allowed.contains(chosen) {
            return chosen
        }
        return allowed[0]
    }

    static func surfaceLabel(_ surface: ManagedAppInstance.Surface, type: ServiceType) -> String {
        switch (type, surface) {
        case (.codex, .app): return "Codex app"
        case (.codex, .terminal): return "Codex CLI in Terminal"
        case (.claude, .app): return "Claude desktop app"
        case (.claude, .terminal): return "Claude Code in Terminal"
        case (_, .terminal): return "\(type.displayName) CLI in Terminal"
        case (_, .app): return "\(type.displayName) app"
        }
    }

    /// The Claude desktop app signs in with a claude.ai web session, which an
    /// OAuth account file cannot provide. Everything else accepts a bound account.
    static func acceptsBoundAccount(_ instance: ManagedAppInstance) -> Bool {
        !(instance.serviceType == .claude && surface(of: instance) == .app)
    }

    private static let fileName = "app-instances.json"

    private static var storeURL: URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeRouter")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(fileName)
    }

    static func defaultDataDirectory(provider: ServiceType, instanceID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeRouter/instances")
            .appendingPathComponent(provider.rawValue)
            .appendingPathComponent(instanceID)
    }

    static func load() -> [ManagedAppInstance] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([ManagedAppInstance].self, from: data)
        else { return [] }
        return list.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    static func save(_ instances: [ManagedAppInstance]) -> Bool {
        do {
            let data = try JSONEncoder().encode(instances)
            try data.write(to: storeURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            return true
        } catch {
            NSLog("[AppInstances] Failed to save: %@", error.localizedDescription)
            return false
        }
    }

    static func upsert(_ instance: ManagedAppInstance) {
        var list = load()
        if let index = list.firstIndex(where: { $0.id == instance.id }) {
            list[index] = instance
        } else {
            list.append(instance)
        }
        save(list)
    }

    static func delete(_ instance: ManagedAppInstance) {
        // Hand the instance's newest Claude login back first; once the instance
        // is gone VibeRouter renews the account again and needs that token.
        if instance.serviceType == .claude, surface(of: instance) == .terminal,
           case .signedIn(let session) = InstanceSessions.claudeSession(
               home: .init(configDir: URL(fileURLWithPath: instance.userDataDir)), waitingUpTo: 10, fresh: true) {
            InstanceSessions.reclaimClaudeSession(session, authDirectory: authDirectory)
        }
        if instance.serviceType == .codex,
           let session = InstanceSessions.codexPayload(home: URL(fileURLWithPath: instance.userDataDir)) {
            reclaimCodexSession(session)
        }
        var list = load()
        list.removeAll { $0.id == instance.id }
        save(list)
    }

    /// Copy an instance (new id + fresh data dir) keeping provider + bound account.
    static func duplicate(_ instance: ManagedAppInstance, name: String? = nil) -> ManagedAppInstance {
        let copy = ManagedAppInstance.make(
            name: name ?? "\(instance.name) copy",
            provider: instance.serviceType ?? .cursor
        )
        var out = copy
        // A login cannot be shared: the copy starts unbound and is bound to another account.
        out.boundAccountFile = nil
        out.extraArgs = instance.extraArgs
        out.surface = instance.surface
        upsert(out)
        return out
    }

    static func revealInFinder(_ instance: ManagedAppInstance) {
        NSWorkspace.shared.open(URL(fileURLWithPath: instance.userDataDir))
    }

    static var authDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    }

    /// The Electron profile of a Codex or Claude desktop instance. Kept beside
    /// (not equal to) the Codex home / Claude Code config dir in the same folder.
    static func appProfileDirectory(_ instance: ManagedAppInstance) -> URL {
        let dataDir = URL(fileURLWithPath: instance.userDataDir)
        switch instance.serviceType {
        case .codex, .claude: return dataDir.appendingPathComponent("app-profile")
        default: return dataDir
        }
    }

    // MARK: - Running state

    /// Every launch puts the instance folder on a command line: `--user-data-dir`
    /// for apps, the start script's path for Terminal sessions.
    static func isRunning(_ instance: ManagedAppInstance) -> Bool {
        !processIDs(matching: instance.userDataDir).isEmpty
    }

    private static func processIDs(matching dir: String) -> [pid_t] {
        guard !dir.isEmpty else { return [] }
        return pgrep(["-f", NSRegularExpression.escapedPattern(for: dir)])
    }

    private static func pgrep(_ arguments: [String]) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 != getpid() }
        } catch {
            return []
        }
    }

    /// Quit the instance: its app processes, or its Terminal script and the CLI it runs.
    /// SIGTERM lets a client finish writing a rotated token before it exits.
    static func stop(_ instance: ManagedAppInstance) -> AppInstanceLaunchResult {
        let roots = processIDs(matching: instance.userDataDir)
        guard !roots.isEmpty else { return .launched(message: "\(instance.name) is not running") }
        var all = Set(roots)
        var frontier = roots
        while let pid = frontier.popLast() {
            for child in pgrep(["-P", String(pid)]) where all.insert(child).inserted {
                frontier.append(child)
            }
        }
        for pid in all { kill(pid, SIGTERM) }
        return .launched(message: "Stopped \(instance.name)")
    }

    // MARK: - Launch

    /// Inject the bound account (if any) and start a new isolated copy.
    static func launch(_ instance: ManagedAppInstance) async -> AppInstanceLaunchResult {
        guard let type = instance.serviceType else {
            return .failure(message: "Unknown provider \(instance.provider)")
        }
        guard !instance.userDataDir.isEmpty else { return .failure(message: "Instance has no data folder") }
        if isRunning(instance) {
            return .failure(message: "\(instance.name) is already running. Stop it before starting it again.")
        }
        let dataDir = URL(fileURLWithPath: instance.userDataDir)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            return .failure(message: "Could not create instance folder: \(error.localizedDescription)")
        }

        var note = ""
        if let fileName = instance.boundAccountFile, !fileName.isEmpty {
            if acceptsBoundAccount(instance) {
                let authFile = authDirectory.appendingPathComponent(fileName)
                guard NativeUsageFetcher.readAuthPayload(at: authFile) != nil else {
                    return .failure(message: "Bound account file \(fileName) is missing. Re-bind it in Instances.")
                }
                do {
                    try prepareAccount(for: instance, type: type, authFile: authFile, dataDir: dataDir)
                } catch {
                    return .failure(message: error.localizedDescription)
                }
            } else {
                note = " Sign in once inside this window: the Claude desktop app uses a claude.ai web login, so a bound account only applies to Claude Code in Terminal."
            }
        }

        switch await start(instance, type: type, dataDir: dataDir) {
        case .launched(let message): return .launched(message: message + note)
        case .failure(let message): return .failure(message: message)
        }
    }

    private static func prepareAccount(for instance: ManagedAppInstance, type: ServiceType,
                                       authFile: URL, dataDir: URL) throws {
        switch type {
        case .codex:
            try prepareCodex(instance, authFile: authFile, home: dataDir)
        case .claude:
            try prepareClaudeCode(instance, authFile: authFile, home: InstanceSessions.ClaudeHome(configDir: dataDir))
        default:
            guard let payload = NativeUsageFetcher.readAuthPayload(at: authFile) else { throw InjectionError.missingToken }
            try inject(payload, type: type, into: dataDir)
        }
    }

    /// A Codex seat may be signed in to one client at a time: OpenAI rotates its
    /// refresh token on every renewal and revokes the family when an old one returns.
    /// Copy a Codex instance's login onto the matching VibeRouter files when it is newer.
    private static func reclaimCodexSession(_ session: [String: Any]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json"
            && (NativeUsageFetcher.readAuthPayload(at: file)?["type"] as? String)?.lowercased() == "codex" {
            NativeUsageFetcher.overlayCodexCLICredentialsIfFresher(onto: file, localCodex: session)
        }
    }

    private static func prepareCodex(_ instance: ManagedAppInstance, authFile: URL, home: URL) throws {
        // The instance may have renewed its current login since the last Start.
        // Copy that newest token back before anything overwrites it.
        let current = InstanceSessions.codexPayload(home: home)
        if let current { reclaimCodexSession(current) }
        guard let payload = NativeUsageFetcher.readAuthPayload(at: authFile).map(TokenRefreshService.flattenedAuth) else {
            throw InjectionError.missingToken
        }
        let label = accountLabel(payload)
        if let main = NativeUsageFetcher.readCodexAppPayload(), TokenRefreshService.sameCodexSeat(main, as: payload) {
            throw InjectionError.sharedLogin("\(label) is the account your main Codex is signed in to. One ChatGPT login can't run in two copies at once, because each renewal invalidates the other copy's token. Bind a different account to this instance.")
        }
        for other in load() where other.id != instance.id && other.serviceType == .codex && isRunning(other) {
            if let theirs = InstanceSessions.codexPayload(home: URL(fileURLWithPath: other.userDataDir)),
               TokenRefreshService.sameCodexSeat(theirs, as: payload) {
                throw InjectionError.sharedLogin("\(label) is already running in instance \(other.name). Stop that instance or bind a different account.")
            }
        }
        if let current, TokenRefreshService.sameCodexSeat(current, as: payload),
           !NativeUsageFetcher.shouldAdoptCodexCLITokens(local: payload, file: current) {
            return // The instance already holds this seat's newest login.
        }
        try injectCodex(payload, into: home)
    }

    /// Claude Code in an instance owns the login it holds, as the main Claude Code
    /// does: VibeRouter parks the account's refresh token and follows the instance.
    private static func prepareClaudeCode(_ instance: ManagedAppInstance, authFile: URL,
                                          home: InstanceSessions.ClaudeHome) throws {
        let current: [String: Any]?
        switch InstanceSessions.claudeSession(home: home, waitingUpTo: 20, fresh: true) {
        case .unreadable:
            throw InjectionError.sharedLogin("Could not read this instance's Claude Code login from the Keychain, so replacing it now could lose its newest sign-in. Try again in a moment.")
        case .signedOut:
            current = nil
        case .signedIn(let session):
            current = session
            InstanceSessions.reclaimClaudeSession(session, authDirectory: authDirectory)
        }
        guard var payload = NativeUsageFetcher.readAuthPayload(at: authFile).map(TokenRefreshService.flattenedAuth) else {
            throw InjectionError.missingToken
        }
        let label = accountLabel(payload)
        if let main = NativeUsageFetcher.claudeCodeAccount(), AccountCredentialIdentity.sameAccount(payload, main) {
            throw InjectionError.sharedLogin("\(label) is the account your main Claude Code is signed in to. One Claude login can't run in two places, because Anthropic renews it for only one client. Bind a different account, or switch the main Claude Code to another account first.")
        }
        if let other = claudeHomes(excluding: instance)
            .first(where: { InstanceSessions.claudeOwner(of: payload, homes: [$0.home]) != nil }) {
            throw InjectionError.sharedLogin("\(label) is already signed in to Claude Code instance \(other.instance.name). Bind a different account, or delete that instance first.")
        }
        if let current, AccountCredentialIdentity.sameAccount(current, payload) {
            return // Same account: the instance already holds its newest login.
        }

        guard let access = stringValue(payload, keys: ["access_token"]) else { throw InjectionError.missingToken }
        guard let refresh = TokenRefreshService.refreshToken(from: payload)
            ?? stringValue(payload, keys: [TokenRefreshService.parkedRefreshTokenKey]) else {
            throw InjectionError.missingRefreshToken(label)
        }
        var oauth: [String: Any] = [
            "accessToken": access,
            "refreshToken": refresh,
            "scopes": ["user:inference", "user:profile", "user:sessions:claude_code"],
        ]
        if let expiry = expiryMillis(payload) { oauth["expiresAt"] = expiry }
        if let plan = stringValue(payload, keys: ["subscriptionType", "plan_type"]) { oauth["subscriptionType"] = plan }
        let credentials: [String: Any] = ["claudeAiOauth": oauth]
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        // Claude Code reads its Keychain item first, so the file alone would
        // leave an older login in charge.
        guard NativeKeychain.write(data, service: home.keychainService, account: user, waitingUpTo: 20) else {
            throw InjectionError.sharedLogin("Could not save the login to this instance's Claude Code Keychain entry. Unlock the login Keychain and try again.")
        }
        try FileManager.default.createDirectory(at: home.configDir, withIntermediateDirectories: true)
        try writePrivateJSON(credentials, to: home.credentialsURL)

        var config = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.accountURL))) as? [String: Any] ?? [:]
        var oauthAccount = (config["oauthAccount"] as? [String: Any]) ?? [:]
        if let email = stringValue(payload, keys: ["email"]) { oauthAccount["emailAddress"] = email }
        config["oauthAccount"] = oauthAccount
        if config["hasCompletedOnboarding"] == nil { config["hasCompletedOnboarding"] = true }
        try writePrivateJSON(config, to: home.accountURL)

        // The instance owns the token family from now on.
        TokenRefreshService.parkRefreshToken(refresh, in: &payload)
        _ = NativeUsageFetcher.writeAuthPayload(payload, to: authFile)
    }

    private static func claudeHomes(excluding instance: ManagedAppInstance) -> [(instance: ManagedAppInstance, home: InstanceSessions.ClaudeHome)] {
        load().filter { $0.id != instance.id && $0.serviceType == .claude && surface(of: $0) == .terminal }
            .map { ($0, InstanceSessions.ClaudeHome(configDir: URL(fileURLWithPath: $0.userDataDir))) }
    }

    private static func accountLabel(_ payload: [String: Any]) -> String {
        stringValue(payload, keys: ["email"]) ?? "This account"
    }

    // MARK: - Injection

    static func inject(_ payload: [String: Any], type: ServiceType, into dataDir: URL) throws {
        switch type {
        case .cursor:
            try injectCursor(payload, into: dataDir)
        case .gemini:
            try injectGemini(payload, into: dataDir)
        case .antigravity:
            try injectAntigravity(payload, into: dataDir)
        case .copilot:
            try injectCopilot(payload, into: dataDir)
        case .kiro:
            try injectCursorLikeOAuth(payload, into: dataDir, keys: CursorAuthKeys.kiro)
        case .codebuddy, .codebuddyCN, .windsurf, .qoder, .trae:
            try injectCursorLikeOAuth(payload, into: dataDir, keys: CursorAuthKeys.generic(type.rawValue))
        default:
            throw InjectionError.unsupported(type.displayName)
        }
    }

    private enum CursorAuthKeys {
        static let cursor = [
            "cursorAuth/accessToken",
            "cursorAuth/refreshToken",
            "cursorAuth/cachedEmail",
            "cursor.accessToken",
            "cursor.email",
        ]
        static let kiro = ["kiro.accessToken", "kiro.refreshToken", "kiro.email"]
        static func generic(_ prefix: String) -> [String] {
            ["\(prefix).accessToken", "\(prefix).refreshToken", "\(prefix).email"]
        }
    }

    /// Isolated Antigravity profile: write the real IDE oauthToken blob
    /// (`antigravityUnifiedStateSync.oauthToken`) into the instance's own
    /// `state.vscdb`, same wire format Cockpit/IDE use. Falls back to plain
    /// keys only if the blob build fails.
    private static func injectAntigravity(_ payload: [String: Any], into dataDir: URL) throws {
        let access = stringValue(payload, keys: ["access_token"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        let refresh = stringValue(payload, keys: ["refresh_token"])
        let expirySeconds: Int = {
            if let expired = stringValue(payload, keys: ["expired"]),
               let date = ISO8601DateFormatter().date(from: expired)
            {
                return Int(date.timeIntervalSince1970)
            }
            if let expiresIn = payload["expires_in"] as? Int, expiresIn > 0 {
                return Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970)
            }
            return Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        }()
        let db = dataDir.appendingPathComponent("User/globalStorage/state.vscdb")
        do {
            let blob = try NativeSessionManager.buildAntigravityOAuthTokenValue(
                accessToken: access,
                refreshToken: refresh,
                expirySeconds: expirySeconds,
                existingValue: VscdbStore.readString(
                    dbURL: db,
                    key: "antigravityUnifiedStateSync.oauthToken"
                )
            )
            try VscdbStore.writeString(dbURL: db, key: "antigravityUnifiedStateSync.oauthToken", value: blob)
        } catch {
            // Best-effort fallback so a stale helper never blocks instance launch.
            try VscdbStore.writeString(dbURL: db, key: "antigravity.accessToken", value: access)
            if let refresh, !refresh.isEmpty {
                try VscdbStore.writeString(dbURL: db, key: "antigravity.refreshToken", value: refresh)
            }
            if let email = stringValue(payload, keys: ["email"]), !email.isEmpty {
                try VscdbStore.writeString(dbURL: db, key: "antigravity.email", value: email)
            }
        }
        if let email = stringValue(payload, keys: ["email"]), !email.isEmpty {
            // Companion pointer some tooling reads for display.
            try? VscdbStore.writeString(dbURL: db, key: "antigravity.cachedEmail", value: email)
        }
    }

    private static func injectCursor(_ payload: [String: Any], into dataDir: URL) throws {
        let db = dataDir.appendingPathComponent("User/globalStorage/state.vscdb")
        let access = stringValue(payload, keys: ["access_token", "accessToken"]) ?? ""
        let refresh = stringValue(payload, keys: ["refresh_token", "refreshToken"]) ?? ""
        let email = stringValue(payload, keys: ["email", "cachedEmail"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        try VscdbStore.writeString(dbURL: db, key: "cursorAuth/accessToken", value: access)
        try VscdbStore.writeString(dbURL: db, key: "cursor.accessToken", value: access)
        if !refresh.isEmpty {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/refreshToken", value: refresh)
        }
        if !email.isEmpty {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/cachedEmail", value: email)
            try VscdbStore.writeString(dbURL: db, key: "cursor.email", value: email)
        }
        if let plan = stringValue(payload, keys: ["membership_type", "plan_type"]) {
            try VscdbStore.writeString(dbURL: db, key: "cursorAuth/stripeMembershipType", value: plan)
        }
    }

    private static func injectCursorLikeOAuth(
        _ payload: [String: Any],
        into dataDir: URL,
        keys: [String]
    ) throws {
        let db = dataDir.appendingPathComponent("User/globalStorage/state.vscdb")
        let access = stringValue(payload, keys: ["access_token", "accessToken"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        if let key = keys.first {
            try VscdbStore.writeString(dbURL: db, key: key, value: access)
        }
        if keys.count > 1, let refresh = stringValue(payload, keys: ["refresh_token", "refreshToken"]) {
            try VscdbStore.writeString(dbURL: db, key: keys[1], value: refresh)
        }
        if keys.count > 2, let email = stringValue(payload, keys: ["email"]) {
            try VscdbStore.writeString(dbURL: db, key: keys[2], value: email)
        }
    }

    private static func injectCopilot(_ payload: [String: Any], into dataDir: URL) throws {
        let access = stringValue(payload, keys: ["access_token", "accessToken"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        let db = dataDir.appendingPathComponent("User/globalStorage/state.vscdb")
        try VscdbStore.writeString(dbURL: db, key: "github.copilot.token", value: access)
        if let user = stringValue(payload, keys: ["username", "login", "email"]) {
            try VscdbStore.writeString(dbURL: db, key: "github.copilot.user", value: user)
        }
    }

    private static func injectCodex(_ payload: [String: Any], into home: URL) throws {
        let access = stringValue(payload, keys: ["access_token"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        var tokens: [String: Any] = ["access_token": access]
        if let refresh = stringValue(payload, keys: ["refresh_token"]) { tokens["refresh_token"] = refresh }
        if let idToken = stringValue(payload, keys: ["id_token"]) { tokens["id_token"] = idToken }
        if let accountID = stringValue(payload, keys: ["account_id"]) { tokens["account_id"] = accountID }
        let root: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": tokens,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        try writePrivateJSON(root, to: home.appendingPathComponent("auth.json"))
        _ = CodexWorkspaceCredentials.writeKeychain(authFileJSON: root, codexHome: home)
    }

    /// Gemini CLI keeps everything under `$GEMINI_CLI_HOME/.gemini`.
    private static func injectGemini(_ payload: [String: Any], into home: URL) throws {
        let access = stringValue(payload, keys: ["access_token"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        let geminiDir = home.appendingPathComponent(".gemini")
        var creds: [String: Any] = [
            "access_token": access,
            "token_type": "Bearer",
            "scope": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile openid",
        ]
        if let refresh = stringValue(payload, keys: ["refresh_token"]) { creds["refresh_token"] = refresh }
        if let idToken = stringValue(payload, keys: ["id_token"]) { creds["id_token"] = idToken }
        if let expiry = expiryMillis(payload) { creds["expiry_date"] = expiry }
        try writePrivateJSON(creds, to: geminiDir.appendingPathComponent("oauth_creds.json"))
        if let email = stringValue(payload, keys: ["email"]) {
            try writePrivateJSON(["active": email, "old": [String]()], to: geminiDir.appendingPathComponent("google_accounts.json"))
        }
        let settings = geminiDir.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: settings.path) {
            try writePrivateJSON(["security": ["auth": ["selectedType": "oauth-personal"]]], to: settings)
        }
    }

    private static func writePrivateJSON(_ json: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func expiryMillis(_ payload: [String: Any]) -> Int64? {
        let formatter = ISO8601DateFormatter()
        for key in ["expired", "expires_at", "expiry"] {
            if let text = stringValue(payload, keys: [key]) {
                if let date = formatter.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return Int64(date.timeIntervalSince1970 * 1000) }
                formatter.formatOptions = [.withInternetDateTime]
            }
        }
        return TokenRefreshService.accessTokenExpiry(from: payload).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    // MARK: - Process

    private static func start(_ instance: ManagedAppInstance, type: ServiceType, dataDir: URL) async -> AppInstanceLaunchResult {
        switch surface(of: instance) {
        case .terminal:
            return startInTerminal(instance, type: type, dataDir: dataDir)
        case .app:
            return startApp(instance, type: type, dataDir: dataDir)
        }
    }

    /// `open -n` starts a separate copy through LaunchServices, the same way the
    /// Codex app launches its own isolated copies. Each Electron app keys its
    /// single-instance lock on the profile folder, so copies never merge.
    private static func startApp(_ instance: ManagedAppInstance, type: ServiceType, dataDir: URL) -> AppInstanceLaunchResult {
        guard let bundle = appBundle(for: type) else {
            return .failure(message: "Could not find the \(type.displayName) app on this Mac. Install it in /Applications first.")
        }
        let profile = appProfileDirectory(instance)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var arguments = ["-n"]
        if type == .codex {
            arguments += ["--env", "CODEX_HOME=\(dataDir.path)", "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(profile.path)"]
        }
        arguments += [bundle.path, "--args", "--user-data-dir=\(profile.path)"] + instance.extraArgs
        let (status, error) = run("/usr/bin/open", arguments)
        guard status == 0 else {
            return .failure(message: "Launch failed: \(error.isEmpty ? "open exited with \(status)" : error)")
        }
        return .launched(message: "Started \(instance.name) as a separate \(surfaceLabel(.app, type: type)) with its own profile.")
    }

    /// CLIs need a terminal. A start script in the instance folder sets the
    /// provider's home variable, so the CLI keeps its login, history and settings
    /// there instead of in the main ones.
    private static func startInTerminal(_ instance: ManagedAppInstance, type: ServiceType, dataDir: URL) -> AppInstanceLaunchResult {
        guard let cli = cliExecutable(for: type) else {
            return .failure(message: "Could not find the \(cliName(for: type)) command-line tool. Install it, then press Start again.")
        }
        let script = dataDir.appendingPathComponent("viberouter-start.command")
        do {
            try terminalScript(instance: instance, type: type, dataDir: dataDir, cli: cli)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return .failure(message: "Could not write the start script: \(error.localizedDescription)")
        }
        let (status, error) = run("/usr/bin/open", ["-a", "Terminal", script.path])
        guard status == 0 else {
            return .failure(message: "Could not open Terminal: \(error.isEmpty ? "open exited with \(status)" : error)")
        }
        return .launched(message: "Started \(instance.name) as \(surfaceLabel(.terminal, type: type)) in its own folder.")
    }

    static func environment(for type: ServiceType, dataDir: URL) -> [(String, String)] {
        switch type {
        case .codex: return [("CODEX_HOME", dataDir.path)]
        case .claude: return [("CLAUDE_CONFIG_DIR", dataDir.path)]
        case .gemini: return [("GEMINI_CLI_HOME", dataDir.path), ("GEMINI_FORCE_FILE_STORAGE", "true")]
        default: return []
        }
    }

    static func terminalScript(instance: ManagedAppInstance, type: ServiceType, dataDir: URL, cli: URL) -> String {
        var lines = [
            "#!/bin/zsh -l",
            "# Started by VibeRouter for instance \(shellQuoted(instance.name)). Safe to delete; Start writes it again.",
            "export PATH=\(shellQuoted(cli.deletingLastPathComponent().path)):\"$PATH\"",
        ]
        // A variable inherited from the main session would point back at its login.
        lines.append("unset CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR GEMINI_CLI_HOME ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL OPENAI_API_KEY")
        for (key, value) in environment(for: type, dataDir: dataDir) {
            lines.append("export \(key)=\(shellQuoted(value))")
        }
        lines.append("printf '\\033]0;%s\\007' \(shellQuoted(instance.name))")
        lines.append("cd \"$HOME\"")
        lines.append(([shellQuoted(cli.path)] + instance.extraArgs.map(shellQuoted)).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, message)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// True when Start can work for this instance's app or CLI.
    static func isAppInstalled(for instance: ManagedAppInstance) -> Bool {
        guard let type = instance.serviceType else { return false }
        switch surface(of: instance) {
        case .app: return appBundle(for: type) != nil
        case .terminal: return cliExecutable(for: type) != nil
        }
    }

    static func cliName(for type: ServiceType) -> String {
        switch type {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        default: return type.rawValue
        }
    }

    /// GUI apps don't inherit the shell PATH, so look where installers put CLIs.
    static func cliExecutable(for type: ServiceType) -> URL? {
        let name = cliName(for: type)
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            home.appendingPathComponent(".bun/bin/\(name)").path,
            home.appendingPathComponent(".volta/bin/\(name)").path,
            home.appendingPathComponent(".npm-global/bin/\(name)").path,
        ]
        if type == .claude { candidates.append(home.appendingPathComponent(".claude/local/claude").path) }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        // nvm: newest Node version first.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvm.path) {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append(nvm.appendingPathComponent("\(version)/bin/\(name)").path)
            }
        }
        if type == .codex, let app = appBundle(for: .codex) {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
        }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// The installed app bundle. Codex now ships as ChatGPT.app with Codex's
    /// bundle id, so apps are matched by bundle id, never by a similar name.
    static func appBundle(for type: ServiceType) -> URL? {
        let names: [String]
        switch type {
        case .cursor: names = ["Cursor"]
        case .antigravity: names = ["Antigravity IDE", "Antigravity"]
        case .copilot: names = ["Visual Studio Code", "Code"]
        case .kiro: names = ["Kiro"]
        case .codex: names = ["Codex"]
        case .claude: names = ["Claude"]
        case .codebuddy: names = ["CodeBuddy"]
        case .codebuddyCN: names = ["CodeBuddy CN"]
        case .windsurf: names = ["Windsurf"]
        case .qoder: names = ["Qoder"]
        case .trae: names = ["Trae", "TRAE SOLO", "Trae CN"]
        case .zed: names = ["Zed"]
        default: return nil
        }
        for name in names {
            let bundleID = bundleIdentifier(forAppName: name)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
            let direct = URL(fileURLWithPath: "/Applications/\(name).app")
            if Bundle(url: direct)?.bundleIdentifier == bundleID { return direct }
        }
        return nil
    }

    private static func bundleIdentifier(forAppName name: String) -> String {
        switch name {
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "Visual Studio Code", "Code": return "com.microsoft.VSCode"
        case "Claude": return "com.anthropic.claudefordesktop"
        case "Codex": return "com.openai.codex"
        case "ChatGPT": return "com.openai.chat"
        case "Antigravity IDE", "Antigravity": return "com.google.antigravity-ide"
        case "Kiro": return "dev.kiro.desktop"
        case "Kiro CLI": return "com.amazon.codewhisperer"
        case "Gemini": return "com.google.GeminiMacOS"
        case "CodeBuddy": return "com.tencent.codebuddy"
        case "CodeBuddy CN": return "com.tencent.codebuddy.cn"
        case "Windsurf": return "com.exafunction.windsurf"
        case "Qoder": return "com.qoder.app"
        case "Trae": return "com.trae.app"
        case "TRAE SOLO": return "com.trae.solo"
        case "Trae CN": return "com.trae.cn"
        case "Zed": return "dev.zed.Zed"
        default: return ""
        }
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        ManualTokenImporter.firstString(json, keys: keys)
    }

    enum InjectionError: LocalizedError {
        case missingToken
        case missingRefreshToken(String)
        case sharedLogin(String)
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .missingToken: return "Account is missing an access token"
            case .missingRefreshToken(let label): return "\(label) has no refresh token, so the instance could not stay signed in. Reconnect the account in VibeRouter first."
            case .sharedLogin(let message): return message
            case .unsupported(let name): return "Multi-instance is not available for \(name) yet"
            }
        }
    }
}
