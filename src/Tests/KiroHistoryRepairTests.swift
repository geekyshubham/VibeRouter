import XCTest
@testable import CLIProxyMenuBar

final class KiroHistoryRepairTests: XCTestCase {
    private func translate(_ body: [String: Any]) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let json = String(data: data, encoding: .utf8)!
        let translated = KiroDirectProvider.translateRequest(anthropicBody: json)
        XCTAssertNotNil(translated)
        return translated!.conversationState
    }

    private func historyEntries(_ state: [String: Any]) -> [[String: Any]] {
        state["history"] as? [[String: Any]] ?? []
    }

    private func userEntry(_ entry: [String: Any]) -> [String: Any] {
        entry["userInputMessage"] as? [String: Any] ?? [:]
    }

    private func assistantEntry(_ entry: [String: Any]) -> [String: Any] {
        entry["assistantResponseMessage"] as? [String: Any] ?? [:]
    }

    private func context(_ user: [String: Any]) -> [String: Any] {
        user["userInputMessageContext"] as? [String: Any] ?? [:]
    }

    private func currentMessage(_ state: [String: Any]) -> [String: Any] {
        ((state["currentMessage"] as? [String: Any])?["userInputMessage"] as? [String: Any]) ?? [:]
    }

    private func uses(_ entry: [String: Any]) -> [[String: Any]] {
        assistantEntry(entry)["toolUses"] as? [[String: Any]] ?? []
    }

    private func results(_ user: [String: Any]) -> [[String: Any]] {
        context(user)["toolResults"] as? [[String: Any]] ?? []
    }

    private func bashTool() -> [[String: Any]] {
        [["name": "Bash", "description": "Run a shell command",
          "input_schema": ["type": "object", "properties": ["command": ["type": "string"]]]]]
    }

    private func body(
        _ messages: [[String: Any]],
        model: String = "kiro/claude-sonnet-5",
        tools: [[String: Any]] = []
    ) -> [String: Any] {
        var payload: [String: Any] = ["model": model, "max_tokens": 100, "messages": messages]
        if !tools.isEmpty { payload["tools"] = tools }
        return payload
    }

    func testOrphanedHistoryToolResultGetsSyntheticUse() {
        // The assistant turn that made the tool call was lost from history
        // (rewind/compaction), but the result is still there. Kiro rejects
        // that pairing with TOOL_USE_RESULT_MISMATCH, which Claude Code
        // surfaces as the orphaned-tool_result error.
        let state = translate(body([
            ["role": "user", "content": "What is 2+2?"],
            ["role": "assistant", "content": [["type": "text", "text": "4"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_LOST01", "content": "hi"]]],
            ["role": "user", "content": "Summarize."],
        ]))

        let entries = historyEntries(state)
        XCTAssertEqual(entries.count, 2)
        let historyUses = uses(entries[1])
        XCTAssertEqual(historyUses.count, 1)
        XCTAssertEqual(historyUses[0]["toolUseId"] as? String, "tooluse_LOST01")
        XCTAssertEqual(historyUses[0]["name"] as? String, "unknown_tool")
        XCTAssertEqual(results(currentMessage(state)).count, 1)
    }

    func testLeadingToolResultIsStripped() {
        // Kiro's history must start with a plain user turn. A leading
        // tool-result-only turn is dropped outright (nothing usable remains),
        // and the request still goes out with the current turn intact.
        let state = translate(body([
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_LOST01", "content": "hi"]]],
            ["role": "assistant", "content": [["type": "text", "text": "ok"]]],
            ["role": "user", "content": "Summarize."],
        ]))

        XCTAssertTrue(historyEntries(state).isEmpty)
        XCTAssertTrue((currentMessage(state)["content"] as? String)?.contains("Summarize.") ?? false)
    }

    func testLeadingUserTurnKeepsTextButDropsResults() {
        let state = translate(body([
            ["role": "user", "content": [
                ["type": "text", "text": "continued from before"],
                ["type": "tool_result", "tool_use_id": "tooluse_LOST01", "content": "hi"],
            ]],
            ["role": "assistant", "content": [["type": "text", "text": "ok"]]],
            ["role": "user", "content": "Summarize."],
        ]))

        let entries = historyEntries(state)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(results(userEntry(entries[0])).isEmpty)
        XCTAssertTrue((userEntry(entries[0])["content"] as? String)?.contains("continued from before") ?? false)
    }

    func testConsecutiveUserTurnsMergeInsteadOfDropping() {
        // The previous builder overwrote the pending user turn, losing its
        // text and tool results when two user messages arrived back to back.
        let state = translate(body([
            ["role": "user", "content": "Run echo hi."],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "tooluse_A1", "name": "Bash", "input": ["command": "echo hi"]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_A1", "content": "hi"]]],
            ["role": "user", "content": "Also tell me the date."],
        ], tools: bashTool()))

        let entries = historyEntries(state)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(results(currentMessage(state)).count, 1)
        let historyUses = uses(entries[1])
        XCTAssertEqual(historyUses.count, 1)
        XCTAssertEqual(historyUses[0]["toolUseId"] as? String, "tooluse_A1")
        XCTAssertEqual(historyUses[0]["name"] as? String, "Bash")
        XCTAssertTrue((currentMessage(state)["content"] as? String)?.contains("Also tell me the date.") ?? false)
    }

    func testCurrentTurnOrphanGetsSyntheticUseOnLastHistoryAssistant() {
        let state = translate(body([
            ["role": "user", "content": "What is 2+2?"],
            ["role": "assistant", "content": [["type": "text", "text": "4"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_LOST01", "content": "hi"]]],
        ]))

        let entries = historyEntries(state)
        XCTAssertEqual(entries.count, 2)
        let historyUses = uses(entries[1])
        XCTAssertEqual(historyUses.count, 1)
        XCTAssertEqual(historyUses[0]["toolUseId"] as? String, "tooluse_LOST01")
        XCTAssertEqual(results(currentMessage(state)).count, 1)
    }

    func testOldHistoryToolCallIsRenderedAsPlainText() {
        let state = translate(body([
            ["role": "user", "content": "Run echo hi."],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "tooluse_A1", "name": "Bash", "input": ["command": "echo hi"]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_A1", "content": "hi"]]],
            ["role": "assistant", "content": [["type": "text", "text": "Done."]]],
            ["role": "user", "content": "Summarize."],
        ]))

        let entries = historyEntries(state)
        XCTAssertTrue(uses(entries[1]).isEmpty)
        XCTAssertTrue(results(userEntry(entries[2])).isEmpty)
        XCTAssertTrue((assistantEntry(entries[1])["content"] as? String ?? "").contains("Called Bash"))
        XCTAssertTrue((userEntry(entries[2])["content"] as? String ?? "").contains("Bash result"))
    }

    func testCanonicalOldRoundTripBecomesReadableTranscript() {
        let state = translate(body([
            ["role": "user", "content": "Run echo hi."],
            ["role": "assistant", "content": [
                ["type": "text", "text": "I'll run it."],
                ["type": "tool_use", "id": "tooluse_A1", "name": "Bash", "input": ["command": "echo hi"]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_A1", "content": "hi"]]],
            ["role": "assistant", "content": [["type": "text", "text": "Done."]]],
            ["role": "user", "content": "Summarize."],
        ], tools: bashTool()))

        let entries = historyEntries(state)
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(uses(entries[1]).isEmpty)
        XCTAssertTrue(results(userEntry(entries[2])).isEmpty)
        XCTAssertTrue((assistantEntry(entries[1])["content"] as? String ?? "").contains("Called Bash"))
        XCTAssertTrue((userEntry(entries[2])["content"] as? String ?? "").contains("Bash result"))
        XCTAssertNil(assistantEntry(entries[3])["toolUses"])
    }

    func testUnansweredToolUsesAreTrimmed() {
        // Two parallel calls, but only one result exists. The unmatched use
        // would make Kiro demand a result that never arrives.
        let state = translate(body([
            ["role": "user", "content": "Run both."],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "tooluse_A1", "name": "Bash", "input": [:]],
                ["type": "tool_use", "id": "tooluse_A2", "name": "Bash", "input": [:]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_A1", "content": "hi"]]],
            ["role": "user", "content": "Summarize."],
        ], tools: bashTool()))

        let historyUses = uses(historyEntries(state)[1])
        XCTAssertEqual(historyUses.count, 1)
        XCTAssertEqual(historyUses[0]["toolUseId"] as? String, "tooluse_A1")
    }

    func testHistoryStillAlternatesUserAssistant() {
        let state = translate(body([
            ["role": "user", "content": "Run echo hi."],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "tooluse_A1", "name": "Bash", "input": ["command": "echo hi"]],
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tooluse_A1", "content": "hi"]]],
            ["role": "user", "content": "Also the date."],
            ["role": "assistant", "content": [["type": "text", "text": "Sure."]]],
            ["role": "user", "content": "Summarize."],
        ]))

        let entries = historyEntries(state)
        XCTAssertFalse(entries.isEmpty)
        for (index, entry) in entries.enumerated() {
            let expected = index.isMultiple(of: 2) ? "userInputMessage" : "assistantResponseMessage"
            XCTAssertEqual(Array(entry.keys), [expected], "entry \(index) must be \(expected)")
        }
    }

    func testLargeHistoryIsTrimmedWithoutOrphaningResults() {
        var messages: [[String: Any]] = []
        for index in 0..<8 {
            let id = "tooluse_\(index)"
            messages.append(["role": "user", "content": "Request \(index) " + String(repeating: "x", count: 60_000)])
            messages.append(["role": "assistant", "content": [[
                "type": "tool_use", "id": id, "name": "Bash", "input": ["command": "echo \(index)"],
            ]]])
            messages.append(["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": id, "content": "Result \(index)",
            ]]])
            messages.append(["role": "assistant", "content": "Done \(index)"])
        }
        messages.append(["role": "user", "content": "Current question"])
        var request = body(messages, tools: bashTool())
        request["system"] = "Always answer carefully."
        let state = translate(request)
        let payload: [String: Any] = ["conversationState": state]
        let trimmed = KiroDirectProvider.trimHistory(
            in: payload, systemPrompt: "Always answer carefully.", maxBytes: 240_000
        )
        XCTAssertLessThanOrEqual(KiroDirectProvider.payloadByteCount(trimmed), 240_000)
        let compactState = trimmed["conversationState"] as? [String: Any] ?? [:]
        let entries = historyEntries(compactState)
        XCTAssertLessThan(entries.count, historyEntries(state).count)
        XCTAssertEqual(entries.count % 2, 0)
        let first = userEntry(entries[0])
        XCTAssertTrue((first["content"] as? String ?? "").hasPrefix("Always answer carefully."))
        XCTAssertTrue(results(first).isEmpty)
        XCTAssertEqual(currentMessage(compactState)["content"] as? String, "Current question")
    }

    func testCurrentToolResultKeepsItsAssistantDuringTrimming() {
        let state = translate(body([
            ["role": "user", "content": "Old " + String(repeating: "x", count: 100_000)],
            ["role": "assistant", "content": "Old answer"],
            ["role": "user", "content": "Run a command"],
            ["role": "assistant", "content": [[
                "type": "tool_use", "id": "tooluse_latest", "name": "Bash", "input": [:],
            ]],
            ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "tooluse_latest", "content": "output",
            ]]],
        ], tools: bashTool()))
        let trimmed = KiroDirectProvider.trimHistory(
            in: ["conversationState": state], systemPrompt: "", maxBytes: 2_000
        )
        let compactState = trimmed["conversationState"] as? [String: Any] ?? [:]
        let entries = historyEntries(compactState)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(uses(entries[1]).first?["toolUseId"] as? String, "tooluse_latest")
        XCTAssertEqual(results(currentMessage(compactState)).first?["toolUseId"] as? String, "tooluse_latest")
    }

    func testOversizedCurrentToolOutputIsShortenedWithNotice() {
        let output = "START" + String(repeating: "x", count: 500_000) + "END"
        let state = translate(body([
            ["role": "user", "content": "Run a command"],
            ["role": "assistant", "content": [[
                "type": "tool_use", "id": "tooluse_big", "name": "Bash", "input": [:],
            ]],
            ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "tooluse_big", "content": output,
            ]]],
        ], tools: bashTool()))
        let trimmed = KiroDirectProvider.trimHistory(
            in: ["conversationState": state], systemPrompt: "", maxBytes: 100_000
        )
        let compactState = trimmed["conversationState"] as? [String: Any] ?? [:]
        let result = results(currentMessage(compactState))[0]
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(content.hasPrefix("START"))
        XCTAssertTrue(content.hasSuffix("END"))
        XCTAssertTrue(content.contains("output omitted"))
        XCTAssertLessThanOrEqual(KiroDirectProvider.payloadByteCount(trimmed), 100_000)
        XCTAssertEqual(uses(historyEntries(compactState)[1]).first?["toolUseId"] as? String, "tooluse_big")
    }
}
