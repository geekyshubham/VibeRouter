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
    ]

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
        out.boundAccountFile = instance.boundAccountFile
        out.extraArgs = instance.extraArgs
        upsert(out)
        return out
    }

    static func revealInFinder(_ instance: ManagedAppInstance) {
        NSWorkspace.shared.open(URL(fileURLWithPath: instance.userDataDir))
    }

    /// True when a process was started with this instance's data dir.
    /// Best-effort via pgrep (matches the `--user-data-dir <dir>` arg or env).
    static func isRunning(_ instance: ManagedAppInstance) -> Bool {
        guard !instance.userDataDir.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", instance.userDataDir]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Inject the bound account (if any) and start a new isolated process.
    static func launch(_ instance: ManagedAppInstance) async -> AppInstanceLaunchResult {
        guard let type = instance.serviceType else {
            return .failure(message: "Unknown provider \(instance.provider)")
        }
        let dataDir = URL(fileURLWithPath: instance.userDataDir)
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            return .failure(message: "Could not create instance folder: \(error.localizedDescription)")
        }

        if let fileName = instance.boundAccountFile, !fileName.isEmpty {
            let authFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cli-proxy-api")
                .appendingPathComponent(fileName)
            if let payload = NativeUsageFetcher.readAuthPayload(at: authFile) {
                do {
                    try inject(payload, type: type, into: dataDir)
                } catch {
                    return .failure(message: "Could not inject account: \(error.localizedDescription)")
                }
            } else {
                return .failure(message: "Bound account file \(fileName) is missing. Re-bind it in Instances.")
            }
        }

        return await startProcess(type: type, dataDir: dataDir, extraArgs: instance.extraArgs, name: instance.name)
    }

    static func stop(_ instance: ManagedAppInstance) -> AppInstanceLaunchResult {
        let dir = instance.userDataDir
        guard !dir.isEmpty else {
            return .failure(message: "Instance has no data directory")
        }
        let escaped = NSRegularExpression.escapedPattern(for: dir)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", escaped]
        do {
            try process.run()
            process.waitUntilExit()
            return .launched(message: "Stopped \(instance.name)")
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    // MARK: - Injection

    static func inject(_ payload: [String: Any], type: ServiceType, into dataDir: URL) throws {
        switch type {
        case .cursor:
            try injectCursor(payload, into: dataDir)
        case .codex:
            try injectCodex(payload, into: dataDir)
        case .claude:
            try injectClaude(payload, into: dataDir)
        case .gemini:
            try injectGemini(payload, into: dataDir)
        case .antigravity:
            try injectAntigravity(payload, into: dataDir)
        case .copilot:
            try injectCopilot(payload, into: dataDir)
        case .kiro:
            try injectCursorLikeOAuth(payload, into: dataDir, keys: CursorAuthKeys.kiro)
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

    private static func injectCodex(_ payload: [String: Any], into dataDir: URL) throws {
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
        let url = dataDir.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        _ = CodexWorkspaceCredentials.writeKeychain(authFileJSON: root, codexHome: dataDir)
    }

    private static func injectClaude(_ payload: [String: Any], into dataDir: URL) throws {
        let access = stringValue(payload, keys: ["access_token"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        var oauth: [String: Any] = ["accessToken": access]
        if let refresh = stringValue(payload, keys: ["refresh_token"]) { oauth["refreshToken"] = refresh }
        if let email = stringValue(payload, keys: ["email"]) { oauth["email"] = email }
        let credentials: [String: Any] = ["claudeAiOauth": oauth]
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let url = dataDir.appendingPathComponent(".credentials.json")
        let data = try JSONSerialization.data(withJSONObject: credentials, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func injectGemini(_ payload: [String: Any], into dataDir: URL) throws {
        let access = stringValue(payload, keys: ["access_token"]) ?? ""
        guard !access.isEmpty else { throw InjectionError.missingToken }
        var creds: [String: Any] = ["access_token": access, "token_type": "Bearer"]
        if let refresh = stringValue(payload, keys: ["refresh_token"]) { creds["refresh_token"] = refresh }
        if let idToken = stringValue(payload, keys: ["id_token"]) { creds["id_token"] = idToken }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let url = dataDir.appendingPathComponent("oauth_creds.json")
        let data = try JSONSerialization.data(withJSONObject: creds, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    // MARK: - Process

    private static func startProcess(
        type: ServiceType,
        dataDir: URL,
        extraArgs: [String],
        name: String
    ) async -> AppInstanceLaunchResult {
        guard let spec = executable(for: type) else {
            return .failure(message: "Could not find \(type.displayName) on this Mac. Install it in /Applications first.")
        }

        let process = Process()
        process.executableURL = spec.executable
        var env = ProcessInfo.processInfo.environment
        var args = spec.arguments(dataDir)
        args.append(contentsOf: extraArgs)

        switch type {
        case .codex:
            env["CODEX_HOME"] = dataDir.path
        case .claude:
            env["CLAUDE_CONFIG_DIR"] = dataDir.path
        case .gemini:
            env["GEMINI_CONFIG_DIR"] = dataDir.path
            env["HOME"] = dataDir.path
        default:
            break
        }
        process.environment = env
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return .launched(message: "Started \(name) as a separate \(type.displayName) instance")
        } catch {
            return .failure(message: "Launch failed: \(error.localizedDescription)")
        }
    }

    /// True when the backing app/CLI exists, so Start can work.
    /// Used by the UI to disable Start with an explanatory badge instead of
    /// failing at launch time.
    static func isAppInstalled(for type: ServiceType) -> Bool {
        executable(for: type) != nil
    }

    private struct ExecutableSpec {
        let executable: URL
        let arguments: (URL) -> [String]
    }

    private static func executable(for type: ServiceType) -> ExecutableSpec? {
        switch type {
        case .cursor:
            return macApp("Cursor", userDataFlag: "--user-data-dir")
        case .antigravity:
            return macApp("Antigravity IDE", userDataFlag: "--user-data-dir")
                ?? macApp("Antigravity", userDataFlag: "--user-data-dir")
        case .copilot:
            return macApp("Visual Studio Code", userDataFlag: "--user-data-dir")
                ?? macApp("Code", userDataFlag: "--user-data-dir")
        case .kiro:
            return macApp("Kiro", userDataFlag: "--user-data-dir")
                ?? macApp("Kiro CLI", userDataFlag: "--user-data-dir")
        case .codex:
            return macApp("Codex", userDataFlag: nil) ?? macApp("ChatGPT", userDataFlag: nil)
        case .claude:
            return macApp("Claude", userDataFlag: nil)
        case .gemini:
            if let url = which("gemini") {
                return ExecutableSpec(executable: url) { _ in [] }
            }
            return nil
        default:
            return nil
        }
    }

    private static func macApp(_ name: String, userDataFlag: String?) -> ExecutableSpec? {
        // Candidate bundle locations: /Applications first, then LaunchServices.
        var bundleURLs: [URL] = []
        let direct = URL(fileURLWithPath: "/Applications/\(name).app")
        if FileManager.default.fileExists(atPath: direct.path) {
            bundleURLs.append(direct)
        }
        let bundleID = bundleIdentifier(forAppName: name)
        if !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           !bundleURLs.contains(url)
        {
            bundleURLs.append(url)
        }
        for bundle in bundleURLs {
            if let spec = executableSpec(in: bundle, userDataFlag: userDataFlag) {
                return spec
            }
        }
        return nil
    }

    /// Resolve the real executable inside an app bundle via Info.plist
    /// `CFBundleExecutable` (Electron apps like Antigravity IDE ship `Electron`,
    /// not the app name). Falls back to common exe names.
    private static func executableSpec(in bundle: URL, userDataFlag: String?) -> ExecutableSpec? {
        var candidates: [String] = []
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plist),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let exe = info["CFBundleExecutable"] as? String,
           !exe.isEmpty
        {
            candidates.append(exe)
        }
        // Common fallbacks for Electron / VS Code forks.
        candidates.append(contentsOf: [
            bundle.deletingPathExtension().lastPathComponent,
            "Electron",
            "Code",
        ])
        for exeName in candidates {
            let exe = bundle.appendingPathComponent("Contents/MacOS/\(exeName)")
            if FileManager.default.isExecutableFile(atPath: exe.path) {
                return ExecutableSpec(executable: exe) { dataDir in
                    if let userDataFlag {
                        return [userDataFlag, dataDir.path]
                    }
                    return []
                }
            }
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
        default: return ""
        }
    }

    private static func which(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func stringValue(_ json: [String: Any], keys: [String]) -> String? {
        ManualTokenImporter.firstString(json, keys: keys)
    }

    enum InjectionError: LocalizedError {
        case missingToken
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .missingToken: return "Account is missing an access token"
            case .unsupported(let name): return "Multi-instance is not available for \(name) yet"
            }
        }
    }
}
