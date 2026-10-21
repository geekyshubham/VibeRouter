import XCTest
@testable import CLIProxyMenuBar

final class ModelProviderLabelTests: XCTestCase {
    func testCatalogAndClaudePickerUseServingProvider() throws {
        let cases: [(String, String, String, String)] = [
            ("gpt-6-sol", "openai", "codex", "OpenAI (Codex)"),
            ("grok-4.7", "xai", "xai", "xAI"),
            ("glm-5.3-flash", "opencode-go", "opencode-go", "OpenCode Go"),
            ("gpt-6-sol", "openai", "opencode-go", "OpenCode Go"),
            ("claude-sonnet-4-6", "anthropic", "antigravity", "Antigravity"),
            ("kiro/gpt-5.6-sol", "anthropic", "claude", "Kiro"),
        ]
        for (id, owner, provider, source) in cases {
            let entry: [String: Any] = ["id": id, "owned_by": owner, "providers": [provider]]
            let tagged = ModelProviderLabel.tag(entry)
            XCTAssertEqual(tagged["id"] as? String, id)
            XCTAssertEqual(tagged["display_name"] as? String, "[VibeRouter] [\(source)] \(id)")
            XCTAssertEqual(tagged["description"] as? String, "\(source) via VibeRouter")
            let option = try XCTUnwrap(ModelProviderLabel.pickerOption(for: tagged))
            XCTAssertEqual(option["model"] as? String, id)
            XCTAssertEqual(option["label"] as? String, tagged["display_name"] as? String)
            XCTAssertEqual(option["description"] as? String, tagged["description"] as? String)
        }
    }

    func testOverlappingAliasListsEveryServingProvider() {
        let entry: [String: Any] = [
            "id": "gpt-6-sol", "owned_by": "openai",
            "providers": ["opencode-go", "codex", "codex"],
        ]
        XCTAssertEqual(ModelProviderLabel.source(for: entry), "OpenAI (Codex) · OpenCode Go")
    }

    func testFallbackUsesOwnerWithoutGuessingModelFamily() {
        XCTAssertEqual(ModelProviderLabel.source(for: ["id": "gpt-6-sol", "owned_by": "opencode-go"]), "OpenCode Go")
        XCTAssertEqual(ModelProviderLabel.source(for: ["id": "gpt-6-sol", "owned_by": "openai"]), "OpenAI")
        XCTAssertEqual(ModelProviderLabel.source(for: ["id": "grok-test"]), "Unknown provider")
        XCTAssertEqual(ModelProviderLabel.source(for: ["id": "custom", "providers": ["my-gateway"]]), "my-gateway")
    }

    func testRetaggingPreservesUpstreamDetailsAndIsStable() {
        let entry: [String: Any] = [
            "id": "grok-test", "owned_by": "xai",
            "display_name": "Grok Test", "description": "Supports tools", "context_length": 200_000,
        ]
        let tagged = ModelProviderLabel.tag(entry)
        XCTAssertEqual(tagged["display_name"] as? String, "[VibeRouter] [xAI] Grok Test")
        XCTAssertEqual(tagged["description"] as? String, "xAI via VibeRouter — Supports tools")
        XCTAssertEqual(tagged["context_length"] as? Int, 200_000)
        let retagged = ModelProviderLabel.tag(tagged)
        XCTAssertEqual(retagged["description"] as? String, tagged["description"] as? String)
        XCTAssertEqual(retagged["display_name"] as? String, tagged["display_name"] as? String)
    }

    func testOldGenericTagsAreReplaced() {
        let entry: [String: Any] = ["id": "kimi-k2.6", "owned_by": "opencode-go", "display_name": "[VibeRouter] kimi-k2.6", "description": "via VibeRouter"]
        XCTAssertEqual(ModelProviderLabel.tag(entry)["display_name"] as? String, "[VibeRouter] [OpenCode Go] kimi-k2.6")
        XCTAssertNil(ModelProviderLabel.pickerOption(for: ["id": ""]))
    }
}
