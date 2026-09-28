import CoreGraphics
import Foundation
import simd

/// An 8-bit RGBX bitmap in memory (4 bytes per pixel, the fourth byte unused), row 0 at the
/// top. Used for decoded keyframes and for atlases being baked.
struct TXRGBImage {
    /// Width in pixels.
    let width: Int
    /// Height in pixels.
    let height: Int
    /// Pixel bytes, `4 * width` per row, R G B X.
    var pixels: [UInt8]

    /// A black bitmap.
    init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Decodes `image` (resampled to `width` x `height` when given) into sRGB RGBX.
    /// Returns nil when a bitmap context cannot be created.
    init?(image: CGImage, width: Int? = nil, height: Int? = nil) {
        let w = width ?? image.width
        let h = height ?? image.height
        guard w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !drawn { return nil }
    }

    /// Color of pixel (x, y) as 0...255 floats. Coordinates must be in range.
    func pixel(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
    }

    /// Writes pixel (x, y) from 0...255 floats (clamped, rounded). Coordinates must be in range.
    mutating func setPixel(_ x: Int, _ y: Int, _ color: SIMD3<Float>) {
        let i = (y * width + x) * 4
        pixels[i] = TXRGBImage.byte(color.x)
        pixels[i + 1] = TXRGBImage.byte(color.y)
        pixels[i + 2] = TXRGBImage.byte(color.z)
        pixels[i + 3] = 255
    }

    /// A 0...255 float rounded and clamped to a byte; NaN becomes 0.
    static func byte(_ v: Float) -> UInt8 {
        guard v.isFinite, v > 0 else { return 0 }
        return v >= 254.5 ? 255 : UInt8(v + 0.5)
    }

    /// Bilinear sample at continuous pixel coordinates (pixel `i` centered at `i + 0.5`),
    /// clamped to the image edges. Returns 0...255 floats; black for an empty image.
    func sample(_ p: SIMD2<Float>) -> SIMD3<Float> {
        guard width > 0, height > 0 else { return .zero }
        let fx = min(max(p.x - 0.5, 0), Float(width - 1))
        let fy = min(max(p.y - 0.5, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = pixel(x0, y0) * (1 - tx) + pixel(x1, y0) * tx
        let bottom = pixel(x0, y1) * (1 - tx) + pixel(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Rec. 709 luma of a 0...255 color.
    static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// An opaque sRGB CGImage copy of the bitmap, or nil if it cannot be created.
    func makeCGImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A small grayscale copy of a keyframe for sharpness and exposure statistics.
struct TXLumaImage {
    /// Width in pixels.
    let width: Int
    /// Height in pixels.
    let height: Int
    /// Luma 0...255, row-major, row 0 at the top.
    var values: [Float]
    /// Thumbnail pixels per source image pixel (same on both axes up to rounding).
    let scale: SIMD2<Float>

    /// Downsamples `image` so its width is at most `maxWidth`; nil if decoding fails.
    init?(image: CGImage, maxWidth: Int = 320) {
        let w = max(1, min(maxWidth, image.width))
        let h = max(1, Int((Float(image.height) * Float(w) / Float(max(1, image.width))).rounded()))
        guard let rgb = TXRGBImage(image: image, width: w, height: h) else { return nil }
        width = w
        height = h
        scale = SIMD2<Float>(Float(w) / Float(max(1, image.width)), Float(h) / Float(max(1, image.height)))
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { v[y * w + x] = TXRGBImage.luma(rgb.pixel(x, y)) }
        }
        values = v
    }

    /// Bilinear luma at a pixel position given in SOURCE image pixels.
    func sample(sourcePixel p: SIMD2<Float>) -> Float {
        let fx = min(max(p.x * scale.x - 0.5, 0), Float(width - 1))
        let fy = min(max(p.y * scale.y - 0.5, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }
}
