import Foundation
import CoreGraphics
import ImageIO

/// A `CGImage` handed between the main actor and background tasks. `CGImage` is immutable,
/// so sharing it across queues is safe.
struct ViewerCGImage: @unchecked Sendable {
    /// The image.
    let image: CGImage
}

/// ImageIO and CoreGraphics helpers for texture pages, snapshots and the UV checker. Any
/// queue.
enum ViewerImages {
    /// Uniform type identifier of JPEG.
    static var jpegType: CFString { "public.jpeg" as CFString }

    /// Decodes the first image of the file at `url` with ImageIO (`CGImageSourceCreateWithURL`,
    /// `CGImageSourceCreateImageAtIndex`), decoded immediately so the pixels are ready before
    /// the image reaches the main actor. Nil when the file is missing or not an image.
    static func decodedImage(at url: URL) -> ViewerCGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return ViewerCGImage(image: image)
    }

    /// JPEG bytes of `image` at `quality` (0...1) with ImageIO; nil when encoding fails.
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, jpegType, 1, nil) else { return nil }
        let clamped = Swift.min(Swift.max(quality, 0), 1)
        let options = [kCGImageDestinationLossyCompressionQuality as String: clamped] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Data(referencing: data)
    }

    /// `image` scaled down so its longer side is at most `maxPixel` (aspect kept). Returns the
    /// image itself when it is already small enough or `maxPixel` is not positive; nil when a
    /// context cannot be made.
    static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let longest = Swift.max(width, height)
        guard longest > 0 else { return nil }
        guard maxPixel > 0, longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let targetWidth = Swift.max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = Swift.max(1, Int((Double(height) * scale).rounded()))
        guard let context = rgbContext(width: targetWidth, height: targetHeight) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// An 8-bit RGB bitmap context (alpha skipped) with the CoreGraphics origin at the bottom
    /// left; nil for an empty size.
    static func rgbContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// RGBA bytes of `image` drawn into a known layout: 4 bytes per pixel, row 0 is the top
    /// row of the image. Used by the self-test to check orientation. Nil for an empty image.
    static func rgbaPixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }
}
