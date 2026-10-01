import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generated pixels only; no photo, manuscript, or account fixtures.
enum SyntheticThumbnailImage {
    static func data(width: Int = 1600, height: Int = 1000, orientation: Int = 1) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.3, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.65, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        // Deterministic high-frequency detail exercises the JPEG budget.
        for index in 0 ..< 8000 {
            let posX = (index * 37) % width, posY = (index * 71) % height
            context.setFillColor(CGColor(gray: Double(index % 31) / 31, alpha: 1))
            context.fill(CGRect(x: posX, y: posY, width: 3, height: 3))
        }
        let image = context.makeImage()!
        let result = NSMutableData()
        let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SYNTHETIC-PRIVATE-METADATA"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 139, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return result as Data
    }
}
