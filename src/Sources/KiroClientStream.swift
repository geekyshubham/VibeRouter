import Foundation
import Network

/// Serializes SSE writes with transport backpressure. Pings keep long Kiro
/// reasoning turns alive even when there are no visible text deltas yet.
actor KiroClientStream {
    private let connection: NWConnection
    private var textStarted = false
    private var closed = false

    init(connection: NWConnection) { self.connection = connection }

    func start(model: String, messageID: String, inputTokens: Int) async throws {
        try await write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n")
        try await event("message_start", ["message": [
            "id": messageID, "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": inputTokens, "output_tokens": 0,
                      "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
        ]])
    }

    func ping() async throws {
        if !closed { try await event("ping", [:]) }
    }

    func consume(_ frame: KiroDirectProvider.Frame) async throws {
        guard !closed, frame.eventType == "assistantResponseEvent",
              let text = frame.payload["content"] as? String, !text.isEmpty else { return }
        if !textStarted {
            textStarted = true
            try await event("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]])
        }
        try await event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": text]])
    }

    func finish(reply: KiroDirectProvider.AssembledReply, usage: KiroDirectProvider.UsageFigures) async throws {
        guard !closed else { return }
        closed = true
        var index = 0
        if textStarted {
            try await event("content_block_stop", ["index": 0])
            index = 1
        }
        for call in reply.toolCalls {
            try await event("content_block_start", ["index": index, "content_block": [
                "type": "tool_use", "id": call.id, "name": call.name, "input": [String: Any](),
            ]])
            try await event("content_block_delta", ["index": index, "delta": ["type": "input_json_delta", "partial_json": call.argumentsJSON]])
            try await event("content_block_stop", ["index": index])
            index += 1
        }
        try await event("message_delta", [
            "delta": ["stop_reason": reply.stopReason, "stop_sequence": NSNull()],
            "usage": ["input_tokens": usage.inputTokens, "output_tokens": usage.outputTokens,
                      "cache_read_input_tokens": usage.cacheReadTokens, "cache_creation_input_tokens": usage.cacheWriteTokens],
        ])
        try await event("message_stop", [:])
        connection.cancel()
    }

    func fail(status: Int, message: String) async {
        guard !closed else { return }
        closed = true
        let kind = status == 429 ? "rate_limit_error" : status == 400 || status == 413 ? "invalid_request_error" : "api_error"
        try? await event("error", ["error": ["type": kind, "message": message]])
        connection.cancel()
    }

    private func event(_ name: String, _ object: [String: Any]) async throws {
        var object = object
        object["type"] = name
        let data = try JSONSerialization.data(withJSONObject: object)
        try await write("event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
    }

    private func write(_ text: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
