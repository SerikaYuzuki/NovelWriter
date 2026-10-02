import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailError: LocalizedError {
    case unreadable, encodingFailed
    public var errorDescription: String? {
        switch self {
        case .unreadable: "画像を読み込めませんでした。別の画像を選んでください。"
        case .encodingFailed: "画像を200 KB以内に縮小できませんでした。別の画像を選んでください。"
        }
    }
}

/// Coordinates are normalized, with origin at the top left of the oriented preview.
public struct ThumbnailCrop: Sendable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public init(centerX: Double = 0.5, centerY: Double = 0.5, zoom: Double = 1) {
        self.centerX = centerX; self.centerY = centerY; self.zoom = zoom
    }
}

public enum ThumbnailEncoder {
    public static let maximumBytes = 200 * 1024

    public static func preview(_ data: Data, maximumEdge: Int = 2048) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ThumbnailError.unreadable }
        return image
    }

    public static func encode(_ data: Data, owner: ThumbnailOwner, crop: ThumbnailCrop = .init()) throws -> Data {
        let image = try preview(data)
        let width = Double(image.width), height = Double(image.height)
        let zoom = crop.zoom.isFinite ? min(max(crop.zoom, 1), 8) : 1
        let cropWidth = min(width, height * owner.aspectRatio) / zoom
        let cropHeight = cropWidth / owner.aspectRatio
        let centerX = crop.centerX.isFinite ? crop.centerX : 0.5
        let centerY = crop.centerY.isFinite ? crop.centerY : 0.5
        let rect = CGRect(x: min(max(centerX * width - cropWidth / 2, 0), width - cropWidth),
                          y: min(max(centerY * height - cropHeight / 2, 0), height - cropHeight),
                          width: cropWidth, height: cropHeight)
        guard let cropped = image.cropping(to: rect) else { throw ThumbnailError.unreadable }
        let outHeight = min(owner.maximumEdge, max(1, Int(cropHeight)))
        let outWidth = max(1, Int(Double(outHeight) * owner.aspectRatio))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ThumbnailError.encodingFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        guard let rendered = context.makeImage() else { throw ThumbnailError.encodingFailed }
        for quality in stride(from: 0.9, through: 0.1, by: -0.1) {
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ThumbnailError.encodingFailed
            }
            // A fresh bitmap and destination: no source EXIF, GPS, comments, or orientation copied.
            CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                let bytes = try removingAncillaryMetadata(result as Data)
                if bytes.count <= maximumBytes {
                    return bytes
                }
            }
        }
        throw ThumbnailError.encodingFailed
    }

    /// ImageIO synthesizes EXIF dimensions even from a fresh bitmap. Keep only codec
    /// segments and the sRGB ICC profile; no EXIF, XMP, IPTC, or comment segments.
    private static func removingAncillaryMetadata(_ data: Data) throws -> Data {
        var result = Data(data.prefix(2))
        var offset = 2
        while offset + 3 < data.count {
            guard data[offset] == 0xFF else { throw ThumbnailError.encodingFailed }
            let marker = data[offset + 1]
            if marker == 0xDA || marker == 0xD9 {
                result.append(data[offset...])
                return result
            }
            let length = Int(data[offset + 2]) * 256 + Int(data[offset + 3])
            guard length >= 2, offset + 2 + length <= data.count else { throw ThumbnailError.encodingFailed }
            let end = offset + 2 + length
            if ![0xE1, 0xED, 0xFE].contains(marker) {
                result.append(data[offset ..< end])
            }
            offset = end
        }
        throw ThumbnailError.encodingFailed
    }
}
