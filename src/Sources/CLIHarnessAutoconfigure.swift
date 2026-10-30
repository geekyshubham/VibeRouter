import Foundation

/// Detected coding CLI / IDE harness that can point at the local VibeRouter.
struct CLIHarness: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case openCode
        case geminiCLI
        case factory
        case kiroCLI
        case amp

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex CLI"
            case .openCode: return "OpenCode"
            case .geminiCLI: return "Gemini CLI"
            case .factory: return "Factory (Droid)"
            case .kiroCLI: return "Kiro CLI"
            case .amp: return "Amp CLI"
            }
        }

        var systemImage: String {
            switch self {
            case .claudeCode: return "brain.head.profile"
            case .codex: return "terminal"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
            case .geminiCLI: return "sparkles"
            case .factory: return "hammer"
            case .kiroCLI: return "bolt.fill"
            case .amp: return "waveform.path"
            }
        }

        var supportsAutoconfigure: Bool {
            switch self {
            case .claudeCode, .codex, .openCode, .geminiCLI, .factory: return true
            case .kiroCLI, .amp: return false // Kiro is a *source* subscription; Amp is special-cased upstream
            }
        }

        var notes: String {
            switch self {
            case .claudeCode:
                return "Writes ~/.claude/settings.viberouter.json + ~/bin/claude-viberouter (isolates proxy sessions in ~/.claude-viberouter)"
            case .codex:
                return "Adds a VibeRouter model_provider in ~/.codex/config.toml"
            case .openCode:
                return "Adds a viberouter provider in ~/.config/opencode/opencode.json"
            case .geminiCLI:
                return "Sets GEMINI_API_BASE / GOOGLE_GEMINI_BASE_URL in ~/.gemini/settings.json"
            case .factory:
                return "Writes custom_models base_url in ~/.factory/config.json"
            case .kiroCLI:
                return "Kiro is a provider you connect in Settings (source), not a client harness"
            case .amp:
                return "Amp management traffic is handled by the proxy when pointed at localhost"
            }
        }
    }

    let kind: Kind
    let binaryPath: String?
    let configPath: String?
    let isInstalled: Bool
    /// True when config already points at our proxy host/port.
    let isConfigured: Bool
    let detail: String

    var id: String { kind.rawValue }
}

/// Discovers local coding CLIs and rewrites their config to use VibeRouter.
enum CLIHarnessAutoconfigure {
    static let dummyAPIKey = "viberouter"
    private static let backupSuffix = ".viberouter-bak"

    // MARK: - Discovery

    static func discover(proxyPort: Int = 8317) -> [CLIHarness] {
        CLIHarness.Kind.allCases.map { kind in
            let binary = resolveBinary(for: kind)
            let config = resolveConfigPath(for: kind)
            let installed = binary != nil
                || (config.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            let configured = isConfigured(kind: kind, configURL: config, proxyPort: proxyPort)
            let detail: String = {
                if let binary { return binary }
                if let config { return config.path }
                return "Not found"
            }()
            return CLIHarness(
                kind: kind,
                binaryPath: binary,
                configPath: config?.path,
                isInstalled: installed,
                isConfigured: configured,
                detail: detail
            )
        }
    }

    // MARK: - Autoconfigure

    @discardableResult
    static func autoconfigure(_ kind: CLIHarness.Kind, proxyPort: Int = 8317) throws -> String {
        guard kind.supportsAutoconfigure else {
            throw AutoconfigureError.notSupported(kind.displayName)
        }
        let base = "http://127.0.0.1:\(proxyPort)"
        let baseV1 = "\(base)/v1"
        switch kind {
        case .claudeCode:
            try configureClaudeCode(baseURL: base, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Claude Code → claude-viberouter (\(base))"
        case .codex:
            try configureCodex(baseURL: baseV1, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Codex → \(baseV1)"
        case .openCode:
            try configureOpenCode(baseURL: baseV1, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "OpenCode → \(baseV1)"
        case .geminiCLI:
            try configureGemini(baseURL: baseV1, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Gemini CLI → \(baseV1)"
        case .factory:
            try configureFactory(baseURL: base, apiKey: dummyAPIKey, proxyPort: proxyPort)
            return "Factory → \(base)"
        case .kiroCLI, .amp:
            throw AutoconfigureError.notSupported(kind.displayName)
        }
    }

    static func autoconfigureAll(proxyPort: Int = 8317) -> (ok: [String], failed: [String]) {
        var ok: [String] = []
        var failed: [String] = []
        for harness in discover(proxyPort: proxyPort) where harness.isInstalled && harness.kind.supportsAutoconfigure {
            do {
                let msg = try autoconfigure(harness.kind, proxyPort: proxyPort)
                ok.append(msg)
            } catch {
                failed.append("\(harness.kind.displayName): \(error.localizedDescription)")
            }
        }
        return (ok, failed)
    }

    // MARK: - Per-tool writers

    private static func configureClaudeCode(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let catalog = fetchProxyModels(port: proxyPort).filter { ModelProviderLabel.pickerOption(for: $0) != nil }
        let ids = catalog.compactMap { $0["id"] as? String }
        guard let first = ids.first else { throw AutoconfigureError.noModels }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Clean up settings left by older installs and by Claude Code's /model
        // command. Proxy sessions get their own config directory below so later
        // model changes cannot be persisted into the native subscription.
        try stripProxySettingsFromMainClaudeSettings(in: claudeDir)

        let url = claudeDir.appendingPathComponent("settings.viberouter.json")
        try backupIfNeeded(url)
        func available(_ preferences: [String], fallback: String) -> String {
            preferences.first(where: ids.contains) ?? fallback
        }
        let previous = (try? readJSONForMerge(url))?["model"] as? String
        let main = defaultClaudeModel(available: ids)
            ?? previous.flatMap { ids.contains($0) ? $0 : nil }
            ?? available(fallbackClaudeModels, fallback: first)
        let aliases = claudeModelAliases(catalog: catalog)
        let options = claudePickerOptions(catalog: catalog, defaultModel: main)
        let root: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": baseURL,
                "ANTHROPIC_API_KEY": apiKey,
                "ANTHROPIC_AUTH_TOKEN": apiKey,
                "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
                // Identify maintenance requests so Codex can use low effort for
                // compaction while keeping the user's coding effort intact.
                "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1",
                "API_TIMEOUT_MS": "1800000",
                // Let Claude Code choose the selected model's compaction window.
                // A global percentage tuned for Kiro causes premature compaction
                // and repeated refills when switching to GPT or other providers.
            ].merging(aliases) { _, live in live },
            "model": main,
            // This file is passed with --settings, which is allowed to set the picker.
            // Only these rows, each labeled [VibeRouter], so the lineup is the proxy.
            "modelPicker": [
                "replaceBuiltInOptions": true,
                "options": options,
            ],
        ]
        try writeJSON(root, to: url)
        try installClaudeVibeRouterLauncher(baseURL: baseURL, apiKey: apiKey)
    }

    /// Launch default for `claude-viberouter`. The settings file is passed with
    /// --settings, so its `model` wins over the saved /model choice every launch.
    static let preferredClaudeModels = ["kiro/claude-opus-5.5"]
    static let fallbackClaudeModels = ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.5"]

    static func defaultClaudeModel(available ids: [String]) -> String? {
        preferredClaudeModels.first(where: ids.contains)
    }

    /// Picker rows in catalog order, with the launch default listed first.
    static func claudePickerOptions(catalog: [[String: Any]], defaultModel: String?) -> [[String: Any]] {
        let options = catalog.compactMap(ModelProviderLabel.pickerOption)
        guard let defaultModel,
              let index = options.firstIndex(where: { $0["model"] as? String == defaultModel })
        else { return options }
        var ordered = options
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    static func refreshedClaudePicker(root: [String: Any], catalog: [[String: Any]]) -> [String: Any]? {
        let ids = catalog.compactMap { ModelProviderLabel.pickerOption(for: $0)?["model"] as? String }
        var updated = root
        let current = root["model"] as? String
        if let preferred = defaultClaudeModel(available: ids) {
            updated["model"] = preferred
        } else if let current, !ids.contains(current),
                  let fallback = fallbackClaudeModels.first(where: ids.contains) ?? ids.first {
            updated["model"] = fallback
        }
        let options = claudePickerOptions(catalog: catalog, defaultModel: updated["model"] as? String)
        var picker = root["modelPicker"] as? [String: Any] ?? ["replaceBuiltInOptions": true]
        picker["options"] = options
        updated["modelPicker"] = picker
        var env = root["env"] as? [String: Any] ?? [:]
        for family in ["OPUS", "SONNET", "HAIKU"] {
            for suffix in ["", "_NAME", "_DESCRIPTION"] {
                env.removeValue(forKey: "ANTHROPIC_DEFAULT_\(family)_MODEL" + suffix)
            }
        }
        env.merge(claudeModelAliases(catalog: catalog)) { _, live in live }
        updated["env"] = env
        return updated
    }

    /// Prefer each family's newest published model, rather than pinning a legacy
    /// shortcut or inventing a model the proxy cannot route.
    static func claudeModelAliases(catalog: [[String: Any]]) -> [String: String] {
        let usable = catalog.filter { ModelProviderLabel.pickerOption(for: $0) != nil }
        let families: [(String, [String])] = [
            ("OPUS", ["claude-opus-5-5", "kiro/claude-opus-5.5", "claude-opus-5", "claude-opus-4-8"]),
            ("SONNET", ["claude-sonnet-5-5", "kiro/claude-sonnet-5.5", "claude-sonnet-5", "claude-sonnet-4-6"]),
            ("HAIKU", ["claude-haiku-5-5", "kiro/claude-haiku-5.5", "kiro/claude-haiku-4.5", "claude-haiku-4-5-20251001"]),
        ]
        var aliases: [String: String] = [:]
        for (family, preferences) in families {
            guard let entry = preferences.lazy.compactMap({ id in usable.first { $0["id"] as? String == id } }).first else { continue }
            let tagged = ModelProviderLabel.tag(entry)
            let prefix = "ANTHROPIC_DEFAULT_\(family)_MODEL"
            aliases[prefix] = entry["id"] as? String
            aliases[prefix + "_NAME"] = tagged["display_name"] as? String
            aliases[prefix + "_DESCRIPTION"] = tagged["description"] as? String
        }
        return aliases
    }

    private static let catalogSyncLock = NSLock()

    /// Refresh only harnesses already connected to this proxy. A single fetch is
    /// shared by all writers; unavailable catalogs leave the last good lists intact.
    @discardableResult
    static func refreshManagedModelPickers(proxyPort: Int = 8317,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          catalog supplied: [[String: Any]]? = nil) -> Bool {
        guard catalogSyncLock.try() else { return true }
        defer { catalogSyncLock.unlock() }
        guard let catalog = supplied ?? requestProxyModels(port: proxyPort) else { return false }
        let baseURL = "http://127.0.0.1:\(proxyPort)"
        func writeIfChanged(_ root: [String: Any], previous: [String: Any], to url: URL) throws {
            guard !NSDictionary(dictionary: previous).isEqual(to: root) else { return }
            try writeJSON(root, to: url)
        }
        do {
            let claude = home.appendingPathComponent(".claude/settings.viberouter.json")
            if let root = try? readJSONForMerge(claude),
               let env = root["env"] as? [String: Any],
               let base = env["ANTHROPIC_BASE_URL"] as? String,
               isLocalProxyURL(base, port: proxyPort),
               let updated = refreshedClaudePicker(root: root, catalog: catalog) {
                try writeIfChanged(updated, previous: root, to: claude)
            }
            for relative in [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"] {
                let url = home.appendingPathComponent(relative)
                guard let root = try? readJSONForMerge(url),
                      var providers = root["provider"] as? [String: Any],
                      var router = providers[providerKey] as? [String: Any],
                      let options = router["options"] as? [String: Any],
                      let base = options["baseURL"] as? String, isLocalProxyURL(base, port: proxyPort) else { continue }
                var updated = root
                router["models"] = openCodeModelEntries(catalog: catalog)
                providers[providerKey] = router
                updated["provider"] = providers
                try writeIfChanged(updated, previous: root, to: url)
            }
            let factory = home.appendingPathComponent(".factory/config.json")
            if let root = try? readJSONForMerge(factory), let existing = root["custom_models"] as? [[String: Any]],
               let managed = existing.first(where: { ($0["model_display_name"] as? String)?.hasPrefix("VP:") == true }),
               let base = managed["base_url"] as? String, isLocalProxyURL(base, port: proxyPort),
               let key = managed["api_key"] as? String {
                var updated = root
                updated["custom_models"] = existing.filter { !(($0["model_display_name"] as? String)?.hasPrefix("VP:") ?? false) }
                    + factoryModelEntries(catalog: catalog, baseURL: baseURL, apiKey: key)
                try writeIfChanged(updated, previous: root, to: factory)
            }
            let codexConfig = home.appendingPathComponent(".codex/config.toml")
            let codexCatalog = home.appendingPathComponent(".codex/viberouter-models.json")
            if let text = try? String(contentsOf: codexConfig, encoding: .utf8),
               text.contains("model_catalog_json"), text.contains("viberouter-models.json") {
                let previous = (try? readJSONForMerge(codexCatalog)) ?? [:]
                try writeIfChanged(["models": codexModelEntries(catalog: catalog)], previous: previous, to: codexCatalog)
            }
            let gemini = home.appendingPathComponent(".gemini/settings.json")
            if let root = try? readJSONForMerge(gemini), let env = root["env"] as? [String: Any],
               let base = env["GEMINI_API_BASE"] as? String, isLocalProxyURL(base, port: proxyPort) {
                try writeIfChanged(refreshedGeminiModels(root: root, catalog: catalog), previous: root, to: gemini)
            }
            return true
        } catch {
            NSLog("[HarnessModels] Could not refresh a managed picker: %@", error.localizedDescription)
            return false
        }
    }

    private static func isLocalProxyURL(_ value: String, port: Int) -> Bool {
        guard let url = URL(string: value), let host = url.host else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host) && url.port == port
    }

    static func openCodeModelEntries(catalog: [[String: Any]]) -> [String: Any] {
        var models: [String: Any] = [:]
        for entry in catalog where ModelProviderLabel.pickerOption(for: entry) != nil {
            guard let id = entry["id"] as? String else { continue }
            let name = ModelProviderLabel.tag(entry)["display_name"] as? String ?? id
            models[openCodeModelKey(id)] = openCodeModelEntry(id: id, displayName: name)
        }
        return models
    }

    static func codexModelEntries(catalog: [[String: Any]]) -> [[String: Any]] {
        catalog.enumerated().compactMap { index, entry in
            guard ModelProviderLabel.pickerOption(for: entry) != nil, let id = entry["id"] as? String else { return nil }
            let tagged = ModelProviderLabel.tag(entry)
            return [
                "slug": id, "display_name": tagged["display_name"] ?? id,
                "description": tagged["description"] ?? "VibeRouter", "visibility": "list",
                "supported_in_api": true, "priority": index, "supported_reasoning_levels": [],
                "default_reasoning_level": "medium", "shell_type": "shell_command",
                "base_instructions": "You are a helpful coding assistant.",
                "truncation_policy": ["mode": "tokens", "limit": 10_000],
                "support_verbosity": false, "default_verbosity": "medium", "apply_patch_tool_type": "freeform",
                "input_modalities": ["text"], "effective_context_window_percent": 95,
                "context_window": entry["context_length"] ?? entry["context_window"] ?? 128_000,
                "experimental_supported_tools": [],
            ]
        }
    }

    static func refreshedGeminiModels(root: [String: Any], catalog: [[String: Any]]) -> [String: Any] {
        var updated = root
        var configs = root["modelConfigs"] as? [String: Any] ?? [:]
        var aliases = configs["customAliases"] as? [String: Any] ?? [:]
        aliases = aliases.filter { !$0.key.hasPrefix("viberouter/") }
        for entry in catalog where ModelProviderLabel.pickerOption(for: entry) != nil {
            guard let id = entry["id"] as? String else { continue }
            aliases["viberouter/" + id] = ["modelConfig": ["model": id]]
        }
        configs["customAliases"] = aliases
        updated["modelConfigs"] = configs
        return updated
    }

    static func factoryModelEntries(catalog: [[String: Any]], baseURL: String, apiKey: String) -> [[String: Any]] {
        catalog.compactMap { entry in
            guard ModelProviderLabel.pickerOption(for: entry) != nil, let id = entry["id"] as? String else { return nil }
            return ["model_display_name": "VP: " + (ModelProviderLabel.tag(entry)["display_name"] as? String ?? id),
                    "model": id, "base_url": baseURL, "api_key": apiKey, "provider": "anthropic"]
        }
    }

    /// Removes proxy settings that may have been persisted by an older launcher.
    /// Keep native model choices and unrelated Claude preferences intact.
    static func stripProxySettingsFromMainClaudeSettings(in claudeDir: URL) throws {
        let main = claudeDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: main.path) else { return }
        var root = try readJSONForMerge(main)
        var env = root["env"] as? [String: Any] ?? [:]
        let oldRoot = root
        let proxyKeys = [
            "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
            "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION",
            "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME", "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION",
        ]
        for key in proxyKeys { env.removeValue(forKey: key) }
        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }
        if let model = root["model"] as? String,
           model.hasPrefix("kiro/") || model.hasPrefix("[Kiro]") {
            let backup = URL(fileURLWithPath: main.path + backupSuffix)
            let previous = (try? readJSONForMerge(backup))?["model"] as? String
            if let previous, !previous.hasPrefix("kiro/"), !previous.hasPrefix("[Kiro]") {
                root["model"] = previous
            } else {
                root.removeValue(forKey: "model")
            }
        }
        if root["modelPicker"] != nil {
            let picker = root["modelPicker"] as? [String: Any]
            let options = picker?["options"] as? [[String: Any]] ?? []
            if options.contains(where: { ($0["model"] as? String)?.hasPrefix("kiro/") == true }) {
                root.removeValue(forKey: "modelPicker")
            }
        }
        guard !NSDictionary(dictionary: root).isEqual(to: oldRoot) else { return }
        try backupIfNeeded(main)
        try writeJSON(root, to: main)
    }

    private static func resolveLiveKiroModel(port: Int) -> String? {
        let ids = fetchProxyModelIDs(port: port)
        let preferences = ["kiro/claude-sonnet-4.5", "kiro/claude-sonnet-4", "kiro/auto"]
        return resolveLiveModel(preferences, port: port, available: ids)
    }

    private static func installClaudeVibeRouterLauncher(baseURL: String, apiKey: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binDir = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let script = binDir.appendingPathComponent("claude-viberouter")
        try claudeVibeRouterLauncher(baseURL: baseURL, apiKey: apiKey)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let localBin = home.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let link = localBin.appendingPathComponent("claude-viberouter")
        if FileManager.default.fileExists(atPath: link.path) {
            try? FileManager.default.removeItem(at: link)
        }
        try? FileManager.default.copyItem(at: script, to: link)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.path)
    }

    static func claudeVibeRouterLauncher(baseURL: String, apiKey: String) -> String {
        """
        #!/bin/bash
        # Launch Claude Code via VibeRouter (Kiro, OpenCode Go, Codex, etc.).
        # Does NOT touch your Anthropic subscription — use `claude` for that.
        set -e
        proxy_ready() {
          curl --noproxy '*' --connect-timeout 1 --max-time 3 -sf -o /dev/null -H "Authorization: Bearer \(apiKey)" http://127.0.0.1:8318/v1/models &&
          curl --noproxy '*' --connect-timeout 1 --max-time 15 -sf -o /dev/null -H "Authorization: Bearer \(apiKey)" \(baseURL)/v1/models
        }
        if ! proxy_ready; then
          echo "Starting VibeRouter and waiting for the proxy..." >&2
          if [ -x /Applications/VibeRouter.app/Contents/MacOS/viberouter ]; then
            /Applications/VibeRouter.app/Contents/MacOS/viberouter server start --json >/dev/null || true
          fi
          for attempt in {1..20}; do
            if proxy_ready; then break; fi
            sleep 1
          done
        fi
        if ! proxy_ready; then
          echo "VibeRouter could not bring both proxy services online. Open /Applications/VibeRouter.app and check its server status." >&2
          exit 1
        fi
        # Refresh the picker after readiness checks so new or re-enabled models
        # appear even when the proxy has been running since before they changed.
        viberouter_cli="${VIBEROUTER_CLI:-/Applications/VibeRouter.app/Contents/MacOS/viberouter}"
        if [ -x "$viberouter_cli" ]; then
          "$viberouter_cli" harness refresh --json >/dev/null || true
        fi
        # Claude Code saves /model choices in its config directory. Keep proxy
        # selections separate from the native `claude` subscription.
        export CLAUDE_CONFIG_DIR="$HOME/.claude-viberouter"
        mkdir -p "$CLAUDE_CONFIG_DIR"
        unset CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
        export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
        export CLAUDE_CODE_GATEWAY_HINT_HEADERS=1
        # Kiro/GPT and other translated routes cannot return Anthropic safety
        # verdicts. Keep auto mode's local classifier enabled without the billing
        # notice. Opt into server review with 1 for a compatible Claude upstream.
        export CLAUDE_CODE_AUTO_MODE_SERVER="${CLAUDE_CODE_AUTO_MODE_SERVER:-0}"
        export API_TIMEOUT_MS="${API_TIMEOUT_MS:-1800000}"
        echo "Starting Claude Code via VibeRouter (\(baseURL)). Anthropic subscription: claude"
        exec claude --settings "$HOME/.claude/settings.viberouter.json" "$@"
        """
    }

    private static func configureCodex(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = renameLegacyProviderKey(inTOML: text)

        // Ensure model_provider + provider table. Avoid duplicating if already present.
        if text.contains("model_providers.viberouter") || text.contains("[model_providers.viberouter]") {
            // Update base_url lines inside the viberouter table (simple rewrite of known keys).
            text = replaceOrAppendTOMLKey(in: text, key: "base_url", value: "\"\(baseURL)\"", section: "model_providers.viberouter")
            if !text.contains("model_provider") || !text.contains("\"viberouter\"") {
                if text.contains("model_provider") {
                    text = text.replacingOccurrences(
                        of: #"model_provider\s*=\s*"[^"]*""#,
                        with: "model_provider = \"viberouter\"",
                        options: .regularExpression
                    )
                } else {
                    text = "model_provider = \"viberouter\"\n" + text
                }
            }
        } else {
            let block = """

            # --- VibeRouter (auto-configured) ---
            model_provider = "viberouter"

            [model_providers.viberouter]
            name = "VibeRouter"
            base_url = "\(baseURL)"
            wire_api = "chat"
            env_key = "VIBEROUTER_API_KEY"
            """
            text += block
        }
        // Seed env file hint via empty optional — codex reads env_key from environment.
        // Also write a tiny sidecar for the key so users can export it.
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let envHint = codexHome.appendingPathComponent("viberouter.env")
        try "export VIBEROUTER_API_KEY=\"\(apiKey)\"\n".write(to: envHint, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: codexHome.appendingPathComponent(legacyProviderKey + ".env"))
        guard let catalog = requestProxyModels(port: proxyPort), !catalog.isEmpty else { throw AutoconfigureError.noModels }
        let modelCatalog = codexHome.appendingPathComponent("viberouter-models.json")
        try writeJSON(["models": codexModelEntries(catalog: catalog)], to: modelCatalog)
        text = replaceOrAppendTOMLKey(in: text, key: "model_catalog_json",
                                     value: "\"\(modelCatalog.path)\"", section: "profiles.viberouter")
        text = replaceOrAppendTOMLKey(in: text, key: "model_provider", value: "\"viberouter\"", section: "profiles.viberouter")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func configureOpenCode(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/opencode.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/opencode.jsonc"),
        ]
        let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? candidates[0]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        var provider = root["provider"] as? [String: Any] ?? [:]

        guard let catalog = requestProxyModels(port: proxyPort), !catalog.isEmpty else { throw AutoconfigureError.noModels }
        let modelIDs = catalog.compactMap { $0["id"] as? String }
        let models = openCodeModelEntries(catalog: catalog)

        provider.removeValue(forKey: legacyProviderKey)
        if let pinned = root["model"] as? String, pinned.hasPrefix(legacyProviderKey + "/") {
            root["model"] = providerKey + pinned.dropFirst(legacyProviderKey.count)
        }
        provider[providerKey] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "VibeRouter",
            "options": [
                "baseURL": baseURL,
                "apiKey": apiKey,
            ],
            "models": models,
        ] as [String: Any]
        root["provider"] = provider

        // OpenCode treats enabled_providers as a whitelist when it is present,
        // so a provider missing from it is written but never offered.
        if var enabled = root["enabled_providers"] as? [String] {
            enabled.removeAll { $0 == legacyProviderKey }
            if !enabled.contains(providerKey) { enabled.append(providerKey) }
            root["enabled_providers"] = enabled
        }

        if root["model"] == nil {
            let preferred = resolveLiveModel(anthropicModelPreferences, port: proxyPort, available: modelIDs)
                ?? models.keys.sorted().first
            if let preferred {
                root["model"] = "\(providerKey)/\(openCodeModelKey(preferred))"
            }
        }
        try writeJSON(root, to: url)
    }

    private static func configureGemini(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        var env = root["env"] as? [String: Any] ?? [:]
        env["GEMINI_API_BASE"] = baseURL
        env["GOOGLE_GEMINI_BASE_URL"] = baseURL
        env["GEMINI_API_KEY"] = apiKey
        root["env"] = env
        guard let catalog = requestProxyModels(port: proxyPort), !catalog.isEmpty else { throw AutoconfigureError.noModels }
        root = refreshedGeminiModels(root: root, catalog: catalog)
        try writeJSON(root, to: url)
    }

    private static func configureFactory(baseURL: String, apiKey: String, proxyPort: Int) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfNeeded(url)
        var root = try readJSONForMerge(url)
        guard let catalog = requestProxyModels(port: proxyPort), !catalog.isEmpty else { throw AutoconfigureError.noModels }
        let models = factoryModelEntries(catalog: catalog, baseURL: baseURL, apiKey: apiKey)
        // Merge: replace previous VibeRouter-tagged entries, keep user custom models.
        let existing = root["custom_models"] as? [[String: Any]] ?? []
        let kept = existing.filter { entry in
            let name = (entry["model_display_name"] as? String) ?? ""
            return !name.hasPrefix("VP:")
        }
        root["custom_models"] = kept + models
        try writeJSON(root, to: url)
    }

    // MARK: - Detection helpers

    private static func resolveBinary(for kind: CLIHarness.Kind) -> String? {
        let names: [String]
        switch kind {
        case .claudeCode: names = ["claude"]
        case .codex: names = ["codex"]
        case .openCode: names = ["opencode"]
        case .geminiCLI: names = ["gemini"]
        case .factory: names = ["droid", "factory"]
        case .kiroCLI: names = ["kiro-cli", "kiro"]
        case .amp: names = ["amp"]
        }
        for name in names {
            if let path = which(name) { return path }
        }
        // App bundles
        switch kind {
        case .codex:
            let app = "/Applications/Codex.app"
            if FileManager.default.fileExists(atPath: app) { return app }
        case .claudeCode:
            let app = "/Applications/Claude.app"
            if FileManager.default.fileExists(atPath: app) { return app }
        default:
            break
        }
        return nil
    }

    private static func resolveConfigPath(for kind: CLIHarness.Kind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .claudeCode:
            return home.appendingPathComponent(".claude/settings.viberouter.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .openCode:
            let json = home.appendingPathComponent(".config/opencode/opencode.json")
            let jsonc = home.appendingPathComponent(".config/opencode/opencode.jsonc")
            if FileManager.default.fileExists(atPath: json.path) { return json }
            if FileManager.default.fileExists(atPath: jsonc.path) { return jsonc }
            return json
        case .geminiCLI:
            return home.appendingPathComponent(".gemini/settings.json")
        case .factory:
            return home.appendingPathComponent(".factory/config.json")
        case .kiroCLI:
            return home.appendingPathComponent(".kiro")
        case .amp:
            return home.appendingPathComponent(".config/amp")
        }
    }

    private static func isConfigured(kind: CLIHarness.Kind, configURL: URL?, proxyPort: Int) -> Bool {
        guard let configURL, FileManager.default.fileExists(atPath: configURL.path) else {
            return false
        }
        let needle = "127.0.0.1:\(proxyPort)"
        let needleLocal = "localhost:\(proxyPort)"
        if kind == .codex {
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            let named = text.contains(providerKey) || text.contains(legacyProviderKey)
            return named && (text.contains(needle) || text.contains(needleLocal))
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return text.contains(needle) || text.contains(needleLocal)
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    /// Provider key written into harness configs. `legacyProviderKey` is the
    /// pre-rename name, still present in configs written by older builds.
    static let providerKey = "viberouter"
    static let legacyProviderKey = "vibeproxy"

    /// Converts a pre-rename Codex block in place. Appending a second provider
    /// instead would leave two tables and an ambiguous `model_provider`.
    static func renameLegacyProviderKey(inTOML text: String) -> String {
        guard text.contains(legacyProviderKey) else { return text }
        return text
            .replacingOccurrences(of: "model_providers.\(legacyProviderKey)", with: "model_providers.\(providerKey)")
            .replacingOccurrences(of: "model_provider = \"\(legacyProviderKey)\"", with: "model_provider = \"\(providerKey)\"")
            .replacingOccurrences(of: "VIBEPROXY_API_KEY", with: "VIBEROUTER_API_KEY")
            .replacingOccurrences(of: "# --- VibeProxy (auto-configured) ---", with: "# --- VibeRouter (auto-configured) ---")
    }

    /// Anthropic-format IDs to pin, best first. Must be plain catalog IDs: the
    /// proxy has no provider-scoped `[Provider] model` namespace.
    static let anthropicModelPreferences = [
        "claude-sonnet-4-5-20250929",
        "claude-sonnet-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-20250514",
    ]

    static let openAIModelPreferences = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.4-mini",
    ]

    /// First preference the proxy actually advertises, or nil when none match.
    static func resolveLiveModel(_ preferences: [String], port: Int, available: [String]? = nil) -> String? {
        let ids = available ?? fetchProxyModelIDs(port: port)
        guard !ids.isEmpty else { return nil }
        return preferences.first(where: ids.contains)
    }

    struct ThinkingEffort {
        let label: String
        let budget: Int
    }

    /// ThinkingProxy caps a budget at 31,999, so "high" sits at the ceiling.
    static let thinkingEffortLevels = [
        ThinkingEffort(label: "low", budget: 4_000),
        ThinkingEffort(label: "medium", budget: 16_000),
        ThinkingEffort(label: "high", budget: 31_999),
    ]

    /// Only Claude Opus/Sonnet accept a thinking budget, and only the plain IDs —
    /// an already-suffixed or image/agent alias must not be expanded.
    static func thinkingEfforts(for id: String) -> [ThinkingEffort] {
        guard id.hasPrefix("claude-"), !id.contains("-thinking") else { return [] }
        guard id.contains("opus") || id.contains("sonnet") else { return [] }
        return thinkingEffortLevels
    }

    static func isReasoningModel(_ id: String) -> Bool {
        if id.contains("-thinking") { return true }
        if id.hasPrefix("claude-") { return id.contains("opus") || id.contains("sonnet") }
        if id.hasPrefix("gpt-5") { return true }
        if id.hasPrefix("grok-") { return !id.contains("non-reasoning") }
        return false
    }

    /// Context/output limits are deliberately omitted: nothing in the proxy or
    /// its catalog reports them, and a guessed window would silently truncate.
    static func openCodeModelEntry(id: String, displayName: String) -> [String: Any] {
        var entry: [String: Any] = ["name": displayName, "tool_call": true]
        if isReasoningModel(id) { entry["reasoning"] = true }
        return entry
    }

    /// OpenCode model keys cannot carry spaces or brackets.
    static func openCodeModelKey(_ id: String) -> String {
        id.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func fetchProxyModelIDs(port: Int) -> [String] {
        fetchProxyModels(port: port).compactMap { $0["id"] as? String }
    }

    private static func fetchProxyModels(port: Int) -> [[String: Any]] {
        requestProxyModels(port: port) ?? []
    }

    private static func requestProxyModels(port: Int) -> [[String: Any]]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer \(dummyAPIKey)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var models: [[String: Any]]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]]
            else { return }
            models = list
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return models
    }

    // MARK: - IO

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Reads an existing JSON config for in-place merging. Returns [:] only when
    /// the file is genuinely absent/empty; throws if it exists but cannot be
    /// parsed, so we never clobber a user's config (e.g. a .jsonc with comments
    /// or trailing commas) by silently replacing it with a stub.
    private static func readJSONForMerge(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutoconfigureError.unparseableConfig(url.lastPathComponent)
        }
        return json
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func backupIfNeeded(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bak = URL(fileURLWithPath: url.path + backupSuffix)
        if !FileManager.default.fileExists(atPath: bak.path) {
            try FileManager.default.copyItem(at: url, to: bak)
        }
    }

    private static func replaceOrAppendTOMLKey(
        in text: String,
        key: String,
        value: String,
        section: String
    ) -> String {
        // Scope the edit to the `[section]` table only — bounded by the next
        // `[...]` header (or EOF) — so we never clobber another provider's
        // base_url elsewhere in the file. Append the key if the table lacks it.
        guard let header = text.range(of: "[\(section)]") else { return text }
        let bodyStart = header.upperBound
        let rest = text[bodyStart...]
        let bodyEnd = rest.range(of: #"\n\s*\["#, options: .regularExpression)?.lowerBound ?? text.endIndex
        let body = String(text[bodyStart..<bodyEnd])
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"[^\"]*\""
        let newBody: String
        if body.range(of: pattern, options: .regularExpression) != nil {
            newBody = body.replacingOccurrences(
                of: pattern,
                with: "\(key) = \(value)",
                options: .regularExpression
            )
        } else {
            newBody = "\n\(key) = \(value)" + body
        }
        return text.replacingCharacters(in: bodyStart..<bodyEnd, with: newBody)
    }

    enum AutoconfigureError: LocalizedError {
        case notSupported(String)
        case unparseableConfig(String)
        case noModels
        var errorDescription: String? {
            switch self {
            case .notSupported(let name):
                return "\(name) is not autoconfigured as a client harness"
            case .noModels:
                return "No available text models were returned by VibeRouter. Start the proxy and enable a working provider first."
            case .unparseableConfig(let name):
                return "\(name) exists but couldn't be parsed (comments, trailing commas, or malformed JSON). Refusing to overwrite it — edit or remove it manually, then retry."
            }
        }
    }
}
