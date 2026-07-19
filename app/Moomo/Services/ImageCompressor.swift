import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Downsamples and re-encodes picked photos before upload.
///
/// Uses ImageIO's thumbnail path rather than `UIImage(data:)` + `redraw`: a
/// modern iPhone photo is ~4000px wide, and fully decoding one to a bitmap costs
/// ~50MB of memory. Picking six at once that way is an out-of-memory crash on
/// older devices. `CGImageSourceCreateThumbnailAtIndex` decodes straight to the
/// target size and never materialises the full bitmap.
enum ImageCompressor {

    /// Long-edge cap. Profile photos are displayed at most full-screen-width, so
    /// 1080 is already generous on a 3x display.
    static let maxDimension = 1080

    /// Below ~0.7 JPEG artefacts show on faces, which is most of what a dating
    /// photo contains.
    static let jpegQuality = 0.8

    enum Failure: LocalizedError, Equatable {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "That photo couldn't be read. Try another."
            case .encodingFailed: "That photo couldn't be processed. Try another."
            }
        }
    }

    /// Downsample `data` to at most `maxDimension` on its long edge and encode
    /// as JPEG. Orientation is normalised by ImageIO, so portrait photos don't
    /// arrive sideways.
    static func compress(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw Failure.unreadableImage
        }

        guard CGImageSourceGetCount(source) > 0 else { throw Failure.unreadableImage }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation rather than leaving it as a tag the
            // uploaded JPEG's consumers might ignore.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw Failure.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw Failure.encodingFailed
        }

        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw Failure.encodingFailed
        }

        return output as Data
    }
}
