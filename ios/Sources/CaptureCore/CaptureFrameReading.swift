import ARKit
import CoreVideo
import simd

/// Frame readers. Call only inside the ARFrame callback (hub queue): every reader copies
/// values out of ARKit's buffers and never keeps a reference to the frame or a buffer.
/// Sizes and pixel formats are read at runtime (RESEARCH 3.9 gotcha 20), rows honor
/// `bytesPerRow`, and a buffer with an unexpected format is skipped and logged once.
enum ARFrameReading {
    /// Intrinsics of the captured image (`ARCamera.intrinsics`, `imageResolution`).
    static func intrinsics(of camera: ARCamera) -> Intrinsics {
        let width = Int(camera.imageResolution.width.rounded())
        let height = Int(camera.imageResolution.height.rounded())
        return Intrinsics(matrix: camera.intrinsics, width: width, height: height)
    }

    /// Copies depthMap (Float32) and confidenceMap (UInt8) into Core's DepthMap, honoring
    /// bytesPerRow; nil when sceneDepth is nil or the pixel format is unexpected (logged once).
    /// The confidence is left empty when its map is missing or has another size.
    static func depthMap(of frame: ARFrame) -> DepthMap? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthRead = readPlane(sceneDepth.depthMap, format: kCVPixelFormatType_DepthFloat32,
                                  bytesPerPixel: 4, name: "depth") { (base, width, height, bytesPerRow) in
            copyRows(base, width: width, height: height, bytesPerRow: bytesPerRow, as: Float.self)
        }
        guard let depthPlane = depthRead else { return nil }
        var confidence: [UInt8] = []
        if let confidenceMap = sceneDepth.confidenceMap {
            let plane = readPlane(confidenceMap, format: kCVPixelFormatType_OneComponent8,
                                  bytesPerPixel: 1, name: "confidence") { (base, width, height, bytesPerRow) in
                copyRows(base, width: width, height: height, bytesPerRow: bytesPerRow, as: UInt8.self)
            }
            if let plane, plane.width == depthPlane.width, plane.height == depthPlane.height {
                confidence = plane.values
            } else if plane != nil {
                CaptureCoreLog.once("frame.confidence.size", "confidence map size differs from depth map; confidence dropped")
            }
        }
        return DepthMap(width: depthPlane.width, height: depthPlane.height,
                        depth: depthPlane.values, confidence: confidence)
    }

    /// Median of the 5x5 center depth pixels (meters, valid positive values only) and their
    /// mean confidence as 0...1 (`ARConfidenceLevel` / 2; 0.5 when the frame has no
    /// confidence map). Nil without depth or without a valid center pixel.
    static func centerDepth(of frame: ARFrame) -> (distance: Float, confidence: Float)? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let medianRead = readPlane(sceneDepth.depthMap, format: kCVPixelFormatType_DepthFloat32,
                                   bytesPerPixel: 4, name: "depth") { (base, width, height, bytesPerRow) -> Float? in
            var samples: [Float] = []
            samples.reserveCapacity(25)
            forEachCenterPixel(width: width, height: height) { x, y in
                let value = base.loadUnaligned(fromByteOffset: y * bytesPerRow + x * 4, as: Float.self)
                if value.isFinite && value > 0 { samples.append(value) }
            }
            guard !samples.isEmpty else { return nil }
            samples.sort()
            return samples[samples.count / 2]
        }
        guard let median = medianRead ?? nil else { return nil }
        var confidence: Float = 0.5
        if let confidenceMap = sceneDepth.confidenceMap {
            let meanRead = readPlane(confidenceMap, format: kCVPixelFormatType_OneComponent8,
                                     bytesPerPixel: 1, name: "confidence") { (base, width, height, bytesPerRow) -> Float? in
                var sum = 0
                var count = 0
                forEachCenterPixel(width: width, height: height) { x, y in
                    sum += Int(min(2, base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)))
                    count += 1
                }
                return count > 0 ? Float(sum) / Float(count) / 2 : nil
            }
            if let mean = meanRead ?? nil { confidence = mean }
        }
        return (median, confidence)
    }

    /// Mean depth confidence of the frame as 0...1 (`ARConfidenceLevel` / 2), sampling every
    /// `stride`-th pixel in both directions; nil without a confidence map.
    static func meanConfidence(of frame: ARFrame, stride: Int = 8) -> Float? {
        guard let histogram = confidenceHistogram(of: frame, stride: stride) else { return nil }
        let total = histogram.low + histogram.medium + histogram.high
        guard total > 0 else { return nil }
        let weighted = Float(histogram.medium) + 2 * Float(histogram.high)
        return weighted / Float(total) / 2
    }

    /// Counts of low, medium and high confidence pixels, sampling every `stride`-th pixel in
    /// both directions (diagnostics, open device question 3); nil without a confidence map.
    static func confidenceHistogram(of frame: ARFrame, stride: Int = 8) -> (low: Int, medium: Int, high: Int)? {
        guard let confidenceMap = frame.sceneDepth?.confidenceMap else { return nil }
        let step = max(1, stride)
        let countsRead = readPlane(confidenceMap, format: kCVPixelFormatType_OneComponent8,
                                   bytesPerPixel: 1, name: "confidence") { (base, width, height, bytesPerRow) -> [Int] in
            var bins = [0, 0, 0]
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let level = Int(min(2, base.load(fromByteOffset: y * bytesPerRow + x, as: UInt8.self)))
                    bins[level] += 1
                    x += step
                }
                y += step
            }
            return bins
        }
        guard let counts = countsRead, counts.count == 3 else { return nil }
        return (counts[0], counts[1], counts[2])
    }

    /// `ARLightEstimate.ambientIntensity` in lumens (1000 is a well-lit room); nil when light
    /// estimation delivered nothing.
    static func ambientIntensity(of frame: ARFrame) -> Float? {
        guard let estimate = frame.lightEstimate else { return nil }
        return Float(estimate.ambientIntensity)
    }

    /// Rotation speed between two camera poses, radians per second (the relative rotation
    /// angle divided by `seconds`); 0 when `seconds` is not positive.
    static func angularSpeed(from previous: simd_float4x4, to current: simd_float4x4, seconds: Double) -> Float {
        guard seconds > 0, seconds.isFinite else { return 0 }
        let relative = simd_mul(rotationPart(previous).transpose, rotationPart(current))
        let quaternion = simd_quatf(relative)
        let imaginary = simd_length(quaternion.imag)
        let real = abs(quaternion.real)
        let angle = 2 * atan2(imaginary, real)
        guard angle.isFinite else { return 0 }
        return angle / Float(seconds)
    }

    /// Translation speed between two camera poses, meters per second; 0 when `seconds` is not
    /// positive.
    static func linearSpeed(from previous: simd_float4x4, to current: simd_float4x4, seconds: Double) -> Float {
        guard seconds > 0, seconds.isFinite else { return 0 }
        let a = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let b = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        let distance = simd_distance(a, b)
        guard distance.isFinite else { return 0 }
        return distance / Float(seconds)
    }

    // MARK: - Helpers

    /// The upper-left 3x3 (rotation) of a rigid transform.
    static func rotationPart(_ m: simd_float4x4) -> simd_float3x3 {
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return simd_float3x3(columns: (c0, c1, c2))
    }

    /// Locks a one-plane pixel buffer read-only, checks its pixel format and row size, and
    /// runs `body` with (base address, width, height, bytesPerRow). Nil (logged once per
    /// `name`) when the format is unexpected or the buffer cannot be read.
    static func readPlane<T>(_ buffer: CVPixelBuffer, format: OSType, bytesPerPixel: Int, name: String,
                             _ body: (UnsafeRawPointer, Int, Int, Int) -> T) -> T? {
        let actual = CVPixelBufferGetPixelFormatType(buffer)
        guard actual == format else {
            CaptureCoreLog.once("frame.format.\(name)",
                                "unexpected \(name) pixel format \(CaptureDiagnostics.fourCC(actual)); skipped")
            return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            CaptureCoreLog.once("frame.lock.\(name)", "could not lock the \(name) buffer")
            return nil
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, bytesPerRow >= width * bytesPerPixel,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return body(UnsafeRawPointer(base), width, height, bytesPerRow)
    }

    /// Copies `height` rows of `width` values of type `T` out of a buffer with padded rows.
    private static func copyRows<T>(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                                    as type: T.Type) -> (width: Int, height: Int, values: [T]) where T: Numeric {
        let rowBytes = width * MemoryLayout<T>.stride
        var values = [T](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target + row * rowBytes, base + row * bytesPerRow, rowBytes)
            }
        }
        return (width, height, values)
    }

    /// Calls `body(x, y)` for the up to 5x5 pixels around the center of a width x height map.
    private static func forEachCenterPixel(width: Int, height: Int, _ body: (Int, Int) -> Void) {
        let cx = width / 2
        let cy = height / 2
        let x0 = max(0, cx - 2), x1 = min(width - 1, cx + 2)
        let y0 = max(0, cy - 2), y1 = min(height - 1, cy + 2)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 { body(x, y) }
        }
    }
}
