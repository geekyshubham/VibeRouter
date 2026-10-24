import Foundation

enum ProviderCatalog {
    static let managedZAIProviderName = "zai"
    /// Bundled OpenAI-compatible provider (config.yaml openai-compatibility).
    /// Must NOT be in `reservedCustomProviderKeys` or Settings will hide it and validation fails.
    static let openCodeGoProviderName = "opencode-go"
    static let experientialLabsProviderName = "experientiallabs"
    static let experientialLabsDisplayName = "Experiential Labs"

    /// OAuth provider keys used in config.yaml oauth-excluded-models.
    static let oauthProviderKeys: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "gemini": "gemini-cli",
        "kimi": "kimi",
        "github-copilot": "github-copilot",
        "antigravity": "antigravity",
        "kiro": "kiro",
        "xai": "xai",
        "qwen": "qwen",
        "cursor": "cursor",
        "codebuddy": "codebuddy",
        "gitlab": "gitlab",
        "kilo": "kilo",
    ]

    /// IDs that must not be used as free-form custom provider names (OAuth + managed Z.AI).
    /// OpenCode Go is intentionally a normal openai-compatibility custom provider, not reserved.
    static let reservedCustomProviderKeys = Set(oauthProviderKeys.keys)
        .union(oauthProviderKeys.values)
        .union([managedZAIProviderName])

    static let openCodeGoDisplayName = "OpenCode Go"
}
