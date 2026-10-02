import Foundation

enum KiroJSON {
    /// Tool output can contain escaped lone UTF-16 surrogates. Foundation
    /// rejects the entire JSON request for those; replace only invalid pairs,
    /// preserving ordinary escapes and valid surrogate pairs exactly.
    static func repaired(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output = Data()
        var i = 0
        func unit(_ at: Int) -> UInt16? {
            guard at + 6 <= bytes.count, bytes[at] == 92, bytes[at + 1] == 117 else { return nil }
            return UInt16(String(decoding: bytes[(at + 2)..<(at + 6)], as: UTF8.self), radix: 16)
        }
        while i < bytes.count {
            if bytes[i] == 92, i + 1 < bytes.count {
                if let code = unit(i), (0xD800...0xDFFF).contains(code) {
                    if code <= 0xDBFF, let low = unit(i + 6), (0xDC00...0xDFFF).contains(low) {
                        output.append(contentsOf: bytes[i..<(i + 12)]); i += 12
                    } else { output.append(contentsOf: Array("\\uFFFD".utf8)); i += 6 }
                } else {
                    output.append(contentsOf: bytes[i..<(i + 2)]); i += 2
                }
            } else { output.append(bytes[i]); i += 1 }
        }
        return output
    }
}
