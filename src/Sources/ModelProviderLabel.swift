import Foundation

/// Labels the service supplying a model, rather than guessing its source from
/// the model family (OpenCode Go and Kiro can both serve other vendors' models).
enum ModelProviderLabel {
    private static let titles: [String: String] = [
        "kiro": "Kiro", "openai": "OpenAI", "codex": "OpenAI (Codex)",
        "anthropic": "Anthropic", "claude": "Anthropic (Claude Code)",
        "xai": "xAI", "grok": "xAI", "opencode-go": "OpenCode Go",
        "opencode": "OpenCode", "antigravity": "Antigravity",
        "gemini": "Google (Gemini)", "gemini-cli": "Google (Gemini)",
        "google": "Google", "github-copilot": "GitHub Copilot", "copilot": "GitHub Copilot",
        "zai": "Z.AI", "kimi": "Kimi", "qwen": "Qwen", "cursor": "Cursor",
        "codebuddy": "CodeBuddy", "gitlab": "GitLab", "kilo": "Kilo",
        "vertex": "Vertex AI", "vertex-ai": "Vertex AI",
        "openai-compat": "OpenAI-compatible",
    ]

    static func source(for entry: [String: Any]) -> String {
        let id = entry["id"] as? String ?? ""
        // The Kiro bridge is registered as a Claude API credential in the
        // backend. Its namespace is the authoritative source in that case.
        if id.lowercased().hasPrefix("kiro/") { return "Kiro" }
        var providers = (entry["providers"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if providers.isEmpty, let owner = entry["owned_by"] as? String {
            let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !owner.isEmpty && owner != "viberouter" { providers = [owner] }
        }
        let labels = Set(providers.map { titles[$0] ?? $0 })
        return labels.isEmpty ? "Unknown provider" : labels.sorted().joined(separator: " · ")
    }

    static func tag(_ original: [String: Any]) -> [String: Any] {
        guard let id = original["id"] as? String, !id.isEmpty else { return original }
        var entry = original
        let source = source(for: original)
        // Keep useful upstream names, replacing our older generic label.
        var name = (original["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.hasPrefix("[VibeRouter]") {
            name = String(name.dropFirst("[VibeRouter]".count)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("["), let end = name.firstIndex(of: "]") {
                name = String(name[name.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if name.isEmpty { name = id }
        entry["display_name"] = "[VibeRouter] [\(source)] \(name)"
        let route = "\(source) via VibeRouter"
        let description = (original["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entry["description"] = description.isEmpty || description == "via VibeRouter" || description.hasPrefix(route)
            ? (description.hasPrefix(route) ? description : route)
            : "\(route) — \(description)"
        if entry["type"] == nil { entry["type"] = "model" }
        return entry
    }

    static func pickerOption(for entry: [String: Any]) -> [String: Any]? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        guard entry["type"] as? String != "openai-image",
              !id.contains("-image"), !id.contains("-video") else { return nil }
        let tagged = tag(entry)
        return ["model": id, "label": tagged["display_name"]!, "description": tagged["description"]!]
    }
}
