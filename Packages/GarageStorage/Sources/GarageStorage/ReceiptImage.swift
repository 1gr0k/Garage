import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ReceiptImageError: Error, Equatable, Sendable {
    case unreadableImage
    case encodingFailed
}

public enum ReceiptImage {
    public static let maxPixelSize = 2048
    static let compressionQuality = 0.8

    /// Downscales the photo to at most `maxPixelSize` on its long side and re-encodes it as JPEG.
    ///
    /// Orientation is baked into the pixels and no metadata (EXIF, GPS) is carried over.
    public static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ReceiptImageError.unreadableImage }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReceiptImageError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ReceiptImageError.encodingFailed }
        let destinationOptions = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ReceiptImageError.encodingFailed }
        return output as Data
    }
}
