import XCTest
@testable import CLIProxyMenuBar

final class ClaudeProtocolTests: XCTestCase {
    private var enabledCatalog: [[String: Any]] {
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "kiro/claude-opus-5.5", "gpt-6.1-sol"]
            .map { ["id": $0, "providers": [$0.hasPrefix("kiro/") ? "kiro" : "claude"]] }
    }

    func testClaudePickerUsesEveryEnabledTextModelAndUpdatesFamilyAliases() throws {
        let root: [String: Any] = ["model": "gpt-6.1-sol", "permissions": ["keep": true],
            "env": ["KEEP": "value", "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001"],
            "modelPicker": ["replaceBuiltInOptions": true, "options": [["model": "disabled-model"]]]]
        let catalog = enabledCatalog + [["id": "gpt-image-2", "type": "openai-image"]]
        let updated = try XCTUnwrap(CLIHarnessAutoconfigure.refreshedClaudePicker(root: root, catalog: catalog))
        let options = (updated["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(options.compactMap { $0["model"] as? String }), Set(enabledCatalog.compactMap { $0["id"] as? String }))
        let env = try XCTUnwrap(updated["env"] as? [String: Any])
        for family in ["OPUS", "SONNET", "HAIKU"] {
            XCTAssertEqual(env["ANTHROPIC_DEFAULT_\(family)_MODEL"] as? String, "claude-\(family.lowercased())-5-5")
        }
        XCTAssertEqual(env["KEEP"] as? String, "value")
        XCTAssertEqual(updated["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(updated["permissions"] as? [String: Bool], ["keep": true])
    }

    func testManagedHarnessCatalogsStayInSyncAndPreserveUnrelatedSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ root: [String: Any]) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root).write(to: url)
        }
        func read(_ relative: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(relative))) as? [String: Any])
        }
        try write(".claude/settings.viberouter.json", ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8317", "KEEP": "value"]])
        try write(".config/opencode/opencode.json", ["provider": [
            "other": ["models": ["personal": [:]]],
            "viberouter": ["options": ["baseURL": "http://127.0.0.1:8317/v1", "apiKey": "fixture"], "models": ["disabled-model": [:]]]]])
        try write(".factory/config.json", ["custom_models": [
            ["model_display_name": "Personal", "model": "personal"],
            ["model_display_name": "VP: old", "model": "disabled-model", "base_url": "http://127.0.0.1:8317", "api_key": "fixture"]]])
        try write(".gemini/settings.json", ["env": ["GEMINI_API_BASE": "http://127.0.0.1:8317/v1"],
            "modelConfigs": ["customAliases": ["personal": ["modelConfig": ["model": "personal"]],
                                               "viberouter/disabled-model": ["modelConfig": ["model": "disabled-model"]]]]])
        let codex = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[profiles.viberouter]\nmodel_catalog_json = \"viberouter-models.json\"\n".write(to: codex, atomically: true, encoding: .utf8)
        XCTAssertTrue(CLIHarnessAutoconfigure.refreshManagedModelPickers(home: home, catalog: enabledCatalog))
        let expected = Set(enabledCatalog.compactMap { $0["id"] as? String })
        let claude = try read(".claude/settings.viberouter.json")
        let options = (claude["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(options.compactMap { $0["model"] as? String }), expected)
        let providers = try XCTUnwrap(try read(".config/opencode/opencode.json")["provider"] as? [String: [String: Any]])
        XCTAssertNotNil(providers["other"])
        XCTAssertEqual(Set((providers["viberouter"]?["models"] as? [String: Any] ?? [:]).keys), expected)
        let factory = try XCTUnwrap(try read(".factory/config.json")["custom_models"] as? [[String: Any]])
        XCTAssertTrue(factory.contains { $0["model"] as? String == "personal" })
        XCTAssertEqual(Set(factory.filter { ($0["model_display_name"] as? String)?.hasPrefix("VP:") == true }.compactMap { $0["model"] as? String }), expected)
        let codexModels = try XCTUnwrap(try read(".codex/viberouter-models.json")["models"] as? [[String: Any]])
        XCTAssertEqual(Set(codexModels.compactMap { $0["slug"] as? String }), expected)
        let aliases = (try read(".gemini/settings.json")["modelConfigs"] as? [String: Any])?["customAliases"] as? [String: Any] ?? [:]
        XCTAssertNotNil(aliases["personal"])
        XCTAssertEqual(Set(aliases.keys.filter { $0.hasPrefix("viberouter/") }), Set(expected.map { "viberouter/" + $0 }))
        // Turning every model off is a successful empty catalog, not a failed fetch.
        XCTAssertTrue(CLIHarnessAutoconfigure.refreshManagedModelPickers(home: home, catalog: []))
        let empty = try read(".claude/settings.viberouter.json")
        XCTAssertTrue(((empty["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertNil((empty["env"] as? [String: Any])?["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
        let custom = try XCTUnwrap(try read(".factory/config.json")["custom_models"] as? [[String: Any]])
        XCTAssertEqual(custom.count, 1)
        XCTAssertEqual(custom.first?["model"] as? String, "personal")
    }

    func testCatalogRefreshDoesNotConnectANativeHarnessToVibeRouter() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertTrue(CLIHarnessAutoconfigure.refreshManagedModelPickers(home: home, catalog: enabledCatalog))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    func testLauncherUsesLocalAutoClassifierAndPreservesServerReviewOptIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appendingPathComponent("claude-viberouter")
        try CLIHarnessAutoconfigure.claudeVibeRouterLauncher(baseURL: "http://127.0.0.1:8317", apiKey: "fixture")
            .write(to: launcher, atomically: true, encoding: .utf8)
        for (name, contents) in [
            "curl": "#!/bin/bash\nexit 0\n",
            "viberouter": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$HOME/refresh-calls\"\n",
            "claude": "#!/bin/bash\nprintf 'server=%s\\nconfig=%s\\n' \"$CLAUDE_CODE_AUTO_MODE_SERVER\" \"$CLAUDE_CONFIG_DIR\"\nprintf '<%s>\\n' \"$@\"\n",
        ] {
            let executable = directory.appendingPathComponent(name)
            try contents.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        for value: String? in [nil, "", "0", "1"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher.path, "--permission-mode", "auto", "-p", "argument with spaces"]
            process.environment = ["HOME": directory.path, "PATH": "\(directory.path):/usr/bin:/bin", "VIBEROUTER_CLI": directory.appendingPathComponent("viberouter").path]
            if let value { process.environment?["CLAUDE_CODE_AUTO_MODE_SERVER"] = value }
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let refreshCalls = try String(contentsOf: directory.appendingPathComponent("refresh-calls"), encoding: .utf8)
            XCTAssertTrue(refreshCalls.contains("harness refresh --json"))
            XCTAssertTrue(text.contains("server=\(value == "1" ? "1" : "0")\n"))
            XCTAssertTrue(text.contains("config=\(directory.path)/.claude-viberouter\n"))
            XCTAssertTrue(text.contains("<--settings>\n<\(directory.path)/.claude/settings.viberouter.json>\n<--permission-mode>\n<auto>\n<-p>\n<argument with spaces>\n"))
        }
    }

    func testNativeClaudeAndSafeguardRequestsBypassBodyTransforms() {
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: "{}", headers: [("User-Agent", "claude-cli/2.1.295")]))
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: "{}", headers: [("user-agent", "claude-code/2.1.295")]))
        XCTAssertTrue(ThinkingProxy.preservesClaudeProtocol(body: #"{"safeguards":[],"unknown_field":true}"#, headers: []))
        XCTAssertFalse(ThinkingProxy.preservesClaudeProtocol(body: #"{"messages":[]}"#, headers: []))
    }

    func testRuntimeConfigForwardsClaudeQuotaAndRetryHeaders() {
        let config = ConfigComposer.composeRuntimeConfig(
            baseRoot: ["passthrough-headers": false], reservedCustomProviderKeys: [], disabledCustomProviderIDs: [],
            disabledOAuthProviderKeys: [], zaiAPIKeys: [], customProviderAuthRecords: [], includeManagedZAIProvider: false
        )
        XCTAssertEqual(config["passthrough-headers"] as? Bool, true)
    }
}
