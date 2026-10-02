import Foundation
import ImageIO
import UniformTypeIdentifiers

enum KiroImage {
    enum Invalid: LocalizedError {
        case source, decode, size
        var errorDescription: String? {
            switch self {
            case .source: return "Kiro images require base64 PNG, JPEG, GIF or WebP data."
            case .decode: return "An attached image could not be decoded. Reattach it as PNG or JPEG."
            case .size: return "The attached image could not be resized to fit Kiro's request limit."
            }
        }
    }

    // Kiro CLI serializes ImageSource.bytes as base64 in its AWS JSON request.
    // Decode a thumbnail directly, avoiding a full-resolution bitmap allocation.
    static func translate(_ block: [String: Any], maxBytes: Int = 180_000) throws -> [String: Any] {
        guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
              let mime = source["media_type"] as? String,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime.lowercased()),
              let encoded = source["data"] as? String, encoded.utf8.count <= 40_000_000,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        else { throw Invalid.source }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Invalid.decode }
        let actualType = CGImageSourceGetType(imageSource) as String? ?? ""
        if max(width, height) <= 1568, data.count <= maxBytes,
           [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier].contains(actualType) {
            let format = actualType == UTType.png.identifier ? "png" : actualType == UTType.gif.identifier ? "gif" : "jpeg"
            return ["format": format, "source": ["bytes": data.base64EncodedString()]]
        }
        for dimension in [1568, 1280, 1024, 768, 512, 256] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
            ] as CFDictionary) else { throw Invalid.decode }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw Invalid.decode }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maxBytes {
                return ["format": "jpeg", "source": ["bytes": (output as Data).base64EncodedString()]]
            }
        }
        throw Invalid.size
    }
}
