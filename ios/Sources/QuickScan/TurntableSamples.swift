import Foundation
import RealityKit
import AVFoundation
import Vision
import ImageIO
import CoreGraphics
import CoreVideo

/// Photogrammetry samples for turntable scans. Each photo gets an explicit object mask from
/// Vision's foreground (lift subject) request, so the still background is never used, plus
/// the LiDAR depth embedded in the HEIC for real scale. Samples are built lazily, one at a
/// time, to keep memory low.
struct TurntableSamples: Sequence {
    let urls: [URL]
    /// Longest image side fed to photogrammetry (reduced detail on iPhone does not need more).
    var maxDimension = 2048

    init(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        urls = files.filter { ["heic", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func makeIterator() -> Iterator { Iterator(urls: urls, maxDimension: maxDimension) }

    struct Iterator: IteratorProtocol {
        let urls: [URL]
        let maxDimension: Int
        var index = 0
        var nextID = 0

        mutating func next() -> PhotogrammetrySample? {
            while index < urls.count {
                let url = urls[index]
                index += 1
                if let sample = TurntableSamples.makeSample(url: url, id: nextID, maxDimension: maxDimension) {
                    nextID += 1
                    return sample
                }
            }
            return nil
        }
    }

    /// Image + mask (+ depth) for one photo, or nil when no subject is found.
    static func makeSample(url: URL, id: Int, maxDimension: Int) -> PhotogrammetrySample? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = bgraBuffer(from: full, maxDimension: maxDimension) else {
            LogStore.shared.write("turntable sample \(url.lastPathComponent): image unreadable", category: "turntable")
            return nil
        }
        guard let mask = subjectMask(for: image) else {
            LogStore.shared.write("turntable sample \(url.lastPathComponent): no subject found, skipped", category: "turntable")
            return nil
        }
        var sample = PhotogrammetrySample(id: id, image: image)
        sample.objectMask = mask
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw) {
            sample.orientation = orientation
        }
        if let depth = depthMap(source) {
            sample.depthDataMap = depth
        }
        return sample
    }

    /// Draws the image into a 32BGRA pixel buffer, downscaled so the long side is at most maxDimension.
    private static func bgraBuffer(from image: CGImage, maxDimension: Int) -> CVPixelBuffer? {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Vision foreground mask converted to an 8-bit, one-channel buffer at the image size.
    private static func subjectMask(for image: CVPixelBuffer) -> CVPixelBuffer? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first,
              let floatMask = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(floatMask)
        let height = CVPixelBufferGetHeight(floatMask)
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, nil, &output) == kCVReturnSuccess,
              let mask = output else { return nil }
        CVPixelBufferLockBaseAddress(floatMask, .readOnly)
        CVPixelBufferLockBaseAddress(mask, [])
        defer {
            CVPixelBufferUnlockBaseAddress(floatMask, .readOnly)
            CVPixelBufferUnlockBaseAddress(mask, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(floatMask), let dst = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(floatMask)
        let dstRow = CVPixelBufferGetBytesPerRow(mask)
        var covered = 0
        for y in 0..<height {
            let s = src.advanced(by: y * srcRow).assumingMemoryBound(to: Float32.self)
            let d = dst.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let on = s[x] > 0.5
                d[x] = on ? 255 : 0
                if on { covered += 1 }
            }
        }
        // A mask covering almost nothing or almost everything is not a usable subject.
        let fraction = Double(covered) / Double(max(1, width * height))
        return (fraction > 0.005 && fraction < 0.9) ? mask : nil
    }

    /// LiDAR depth embedded in the photo, as DepthFloat32.
    private static func depthMap(_ source: CGImageSource) -> CVPixelBuffer? {
        let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
        guard let dictionary = info as? [AnyHashable: Any],
              var depth = try? AVDepthData(fromDictionaryRepresentation: dictionary) else { return nil }
        if depth.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        return depth.depthDataMap
    }
}
