import Foundation

/// AWS frames can be split at any byte boundary by the network transport.
struct KiroEventDecoder {
    private var buffer = Data()
    private var expected: Int?

    enum Invalid: LocalizedError {
        case frame, truncated
        var errorDescription: String? {
            switch self {
            case .frame: return "Kiro returned a malformed event stream. Retry the turn."
            case .truncated: return "Kiro's response ended before the last event completed. Retry the turn."
            }
        }
    }

    mutating func append(_ byte: UInt8) throws -> KiroDirectProvider.Frame? {
        buffer.append(byte)
        if buffer.count == 12 {
            let bytes = [UInt8](buffer)
            func value(_ i: Int) -> Int {
                (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            }
            let total = value(0), headers = value(4)
            guard total >= 16, total <= 16_000_000, headers <= total - 16 else { throw Invalid.frame }
            expected = total
        }
        if let expected, buffer.count == expected {
            let frames = KiroDirectProvider.decodeFrames(buffer)
            guard frames.count == 1, !frames[0].eventType.isEmpty else { throw Invalid.frame }
            buffer.removeAll(keepingCapacity: true)
            self.expected = nil
            return frames[0]
        }
        return nil
    }

    func finish() throws {
        if !buffer.isEmpty { throw Invalid.truncated }
    }

    static func failure(_ frame: KiroDirectProvider.Frame) -> KiroDirectProvider.CallResult? {
        let kind = frame.eventType.lowercased()
        guard kind.contains("exception") || kind.contains("error") else { return nil }
        let message = frame.payload["message"] as? String ?? frame.payload["reason"] as? String ?? frame.eventType
        let data = try? JSONSerialization.data(withJSONObject: frame.payload)
        let details = data.flatMap { String(data: $0, encoding: .utf8) } ?? message
        let status = kind.contains("throttl") ? 429 : kind.contains("validation") ? 400 : 502
        return .failure(status: status, message: "\(frame.eventType): \(details)")
    }
}
