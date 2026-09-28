import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Value copy of one accepted keyframe, made inside the frame callback on the hub queue and
/// handed to the io queue. It holds a `FrameCopier` buffer, never an ARKit buffer.
struct KeyframeJob {
    /// The copied camera image (one of the copier's buffers, released after its JPEG is made).
    var buffer: CVPixelBuffer
    /// The copied depth and confidence maps, nil when the frame had no scene depth.
    var depth: DepthMap?
    /// The record appended to keyframes.jsonl once the image (and depth) files exist.
    var record: KeyframeRecord
}

/// Value copy of one requested photo, handed from the hub queue to the io queue.
struct PhotoJob {
    /// The copied camera image (a `FrameCopier` buffer).
    var buffer: CVPixelBuffer
    /// The record appended to photos.jsonl once the image file exists.
    var pin: PhotoPin
}

/// Recorder lifecycle shared by the three Keyframes recorders.
enum KeyframesRecorderPhase {
    /// Created, `beginRecording` not called yet.
    case idle
    /// Between `beginRecording` and `finishRecording`.
    case recording
    /// After `finishRecording`: hub callbacks are ignored until the next `beginRecording`.
    case finished
}

/// Log helpers for the Keyframes module: every line goes to `LogStore` with category
/// "keyframes"; `once` writes a message the first time its key is seen in this app run.
enum KeyframesLog {
    /// Guards `loggedKeys`.
    private static let lock = NSLock()
    /// Keys already written by `once`.
    private static var loggedKeys = Set<String>()

    /// Writes one line.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: "keyframes")
    }

    /// Writes `message` the first time `key` is seen.
    static func once(_ key: String, _ message: String) {
        lock.lock()
        let isNew = loggedKeys.insert(key).inserted
        lock.unlock()
        if isNew { write(message) }
    }
}

/// Encoding and io-queue writing for keyframes, photos and the pose track. JPEG encoding uses
/// one shared `CIContext` (thread-safe) and runs only on the io queue; nothing here touches
/// ARKit. The write functions run inside `RawScanWriter.perform`, where the writer's own
/// calls run at once, so each step can check its result before the next (a record line is
/// appended only after its files exist, ARCHITECTURE 3.3).
enum KeyframeEncoding {
    /// JPEG quality of texture keyframes (D7).
    static let keyframeQuality: Double = 0.85
    /// JPEG quality of Take Photo pictures (ARCHITECTURE 3.1).
    static let photoQuality: Double = 0.9

    /// The one Core Image context used for every JPEG (no intermediate caching: each image
    /// is encoded once).
    static let context: CIContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
    /// Output color space of the JPEGs (sRGB, device RGB when sRGB is unavailable).
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// `CIImageRepresentationOption` key of the lossy compression quality (ImageIO key).
    static let qualityOption = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    // MARK: - JPEG

    /// JPEG bytes of a copied camera buffer (YCbCr converted by Core Image) at `quality`
    /// (clamped to 0...1), or nil when Core Image fails. Io queue.
    static func jpegData(from buffer: CVPixelBuffer, quality: Double) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let clamped = min(1, max(0, quality))
        let options: [CIImageRepresentationOption: Any] = [qualityOption: clamped]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    /// True when `data` starts with the JPEG start-of-image marker FF D8.
    static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let first = data[data.startIndex]
        let second = data[data.index(after: data.startIndex)]
        return first == 0xFF && second == 0xD8
    }

    // MARK: - Records and pose track bytes

    /// One JSON Lines line exactly as `RawScanWriter.appendJSONLine` writes it:
    /// `ProjectStore.encoder` output plus "\n".
    static func jsonLine<T: Encodable>(_ value: T) throws -> Data {
        var line = try ProjectStore.encoder.encode(value)
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// The 8-byte `poses.ptrk` header.
    static func poseTrackHeader() -> Data {
        var bytes = ByteWriter(capacity: PoseTrackFile.headerSize)
        PoseTrackFile.appendHeader(to: &bytes)
        return bytes.data
    }

    /// Fixed-size pose records for `samples`, optionally preceded by the header.
    static func poseTrackData(_ samples: [PoseSample], includeHeader: Bool) -> Data {
        var bytes = ByteWriter(capacity: PoseTrackFile.headerSize + samples.count * PoseTrackFile.recordSize)
        if includeHeader { PoseTrackFile.appendHeader(to: &bytes) }
        for sample in samples { PoseTrackFile.append(sample, to: &bytes) }
        return bytes.data
    }

    /// Pose track thermal code: the `ThermalLevel` index (nominal 0, fair 1, serious 2,
    /// critical 3), which equals `ProcessInfo.ThermalState.rawValue`.
    static func thermalCode(_ level: ThermalLevel) -> UInt8 {
        UInt8(clamping: ThermalLevel.allCases.firstIndex(of: level) ?? 0)
    }

    // MARK: - Io queue writes (inside RawScanWriter.perform only)

    /// Io queue only. Encodes the JPEG, releases the buffer to `copier`, writes
    /// `keyframes/NNNNN.jpg`, then `depth/NNNNN.dpth` (Float16 plus confidence) when the job
    /// has depth, and only after both succeeded appends the record to keyframes.jsonl. Returns
    /// true when the record line was written; false when a write failed (the writer counted
    /// and logged it). Throws when encoding fails or a path is unsafe (`perform` counts it).
    static func writeKeyframe(_ job: KeyframeJob, folder: RawScanFolder, writer: RawScanWriter,
                              copier: FrameCopier, quality: Double) throws -> Bool {
        let encoded = jpegData(from: job.buffer, quality: quality)
        copier.release(job.buffer)
        guard let jpeg = encoded, isJPEG(jpeg) else {
            throw MapperError.ioFailed("keyframe \(job.record.index): JPEG encoding failed")
        }
        guard let imageURL = folder.resolve(job.record.imageFile) else {
            throw MapperError.ioFailed("keyframe \(job.record.index): unsafe image path")
        }
        guard writeInline(jpeg, to: imageURL, writer: writer) else { return false }
        if let depth = job.depth {
            guard let depthPath = job.record.depthFile, let depthURL = folder.resolve(depthPath) else {
                throw MapperError.ioFailed("keyframe \(job.record.index): missing or unsafe depth path")
            }
            let depthData = DepthFile.encode(width: depth.width, height: depth.height,
                                             depth: depth.depth, confidence: depth.confidence)
            guard writeInline(depthData, to: depthURL, writer: writer) else { return false }
        }
        return appendLineInline(job.record, to: folder.keyframesLogURL, writer: writer)
    }

    /// Io queue only. Encodes the photo JPEG, releases the buffer, writes `photos/<id>.jpg`
    /// and then appends the pin to photos.jsonl. Returns true when the line was written.
    static func writePhoto(_ job: PhotoJob, folder: RawScanFolder, writer: RawScanWriter,
                           copier: FrameCopier, quality: Double) throws -> Bool {
        let encoded = jpegData(from: job.buffer, quality: quality)
        copier.release(job.buffer)
        guard let jpeg = encoded, isJPEG(jpeg) else {
            throw MapperError.ioFailed("photo \(job.pin.id.uuidString): JPEG encoding failed")
        }
        guard let imageURL = folder.resolve(job.pin.imageFile) else {
            throw MapperError.ioFailed("photo \(job.pin.id.uuidString): unsafe image path")
        }
        guard writeInline(jpeg, to: imageURL, writer: writer) else { return false }
        return appendLineInline(job.pin, to: folder.photosLogURL, writer: writer)
    }

    /// Io queue only: `writer.writeFile` runs at once there (atomic, `createParents: false`);
    /// true when it did not add a failure.
    static func writeInline(_ data: Data, to url: URL, writer: RawScanWriter) -> Bool {
        let before = writer.failureCount
        writer.writeFile(data, to: url)
        return writer.failureCount == before
    }

    /// Io queue only: `writer.appendJSONLine` runs at once there (a failed append is truncated
    /// back); true when it did not add a failure.
    static func appendLineInline<T: Encodable>(_ value: T, to url: URL, writer: RawScanWriter) -> Bool {
        let before = writer.failureCount
        writer.appendJSONLine(value, to: url)
        return writer.failureCount == before
    }

    /// Flushes `writer` (after every write queued before), closes it, then calls `completion`
    /// on the io queue. Used by every recorder's `finishRecording`.
    static func finish(_ writer: RawScanWriter, completion: @escaping () -> Void) {
        writer.flush {
            writer.close()
            completion()
        }
    }
}
