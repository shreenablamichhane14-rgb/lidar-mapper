import CoreVideo
import Foundation
import simd

/// File checks and fixtures of `KeyframesSelfTest`: the io-queue keyframe and photo writes
/// into a temporary scan folder, the recorders' lifecycle (finish before any frame, callbacks
/// after finish), synthetic buffers, poses and records. Every file lives under one fixed
/// folder in `FileManager.default.temporaryDirectory`, removed before and after.
extension KeyframesSelfTest {
    /// '420f', the pixel format of ARKit's capturedImage.
    static let biPlanarFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// Folder name under the temporary directory.
    static let tempFolderName = "mapper-keyframes-selftest"
    /// Longest wait for a writer or a recorder finish, seconds.
    static let waitSeconds: Double = 5

    // MARK: - Io-queue writes

    /// A keyframe job writes its JPEG, depth file and record line and releases its buffer; a
    /// failed depth write leaves no record line; a photo writes its JPEG and pin line.
    static func checkWrites(_ f: inout [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(tempFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let folder = makeFolder(root, name: "good", subfolders: ["keyframes", "depth", "photos"]),
              let broken = makeFolder(root, name: "broken", subfolders: ["keyframes"]),
              let source = makeSource(width: 64, height: 48, seed: 5) else {
            f.append("writes.setup: could not create the temporary folders or the source buffer")
            return
        }
        let copier = FrameCopier(width: 64, height: 48, pixelFormat: biPlanarFormat, count: 1)
        let depth = DepthMap(width: 4, height: 3, depth: [0.5, 1, 1.5, 2, 2.5, 3, 0.75, 1.25, 1.75, 2.25, 2.75, 3.25],
                             confidence: [0, 1, 2, 2, 1, 0, 2, 2, 2, 1, 1, 0])
        let record = sampleRecord(index: 0, withDepth: true)
        if let buffer = copier.copy(source) {
            let writer = RawScanWriter(folder: folder)
            let outcome = Outcome()
            let job = KeyframeJob(buffer: buffer, depth: depth, record: record)
            writer.perform {
                outcome.value = try KeyframeEncoding.writeKeyframe(job, folder: folder, writer: writer, copier: copier,
                                                                   quality: KeyframeEncoding.keyframeQuality)
            }
            expect(&f, "write.flushed", waitFlush(writer))
            expect(&f, "write.written", outcome.value, "failures \(writer.failureCount)")
            expect(&f, "write.released", copier.inUse == 0, "\(copier.inUse)")
            let jpeg = folder.resolve(record.imageFile).flatMap { try? Data(contentsOf: $0) }
            expect(&f, "write.jpeg", jpeg.map { KeyframeEncoding.isJPEG($0) } ?? false)
            let storedDepth = folder.resolve(RawScanFolder.depthPath(0)).flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? DepthFile.decode($0) }
            expect(&f, "write.depth", storedDepth == depth)
            let records = (try? RawScanReader(folder: folder).keyframes()) ?? []
            expect(&f, "write.record", records == [record], "\(records.count) records")
            writePhoto(&f, folder: folder, source: source)
        } else {
            f.append("write.copy: no buffer")
        }
        if let buffer = copier.copy(source) {
            let writer = RawScanWriter(folder: broken)
            let outcome = Outcome()
            let job = KeyframeJob(buffer: buffer, depth: depth, record: record)
            writer.perform {
                outcome.value = try KeyframeEncoding.writeKeyframe(job, folder: broken, writer: writer, copier: copier,
                                                                   quality: KeyframeEncoding.keyframeQuality)
            }
            _ = waitFlush(writer)
            let records = (try? RawScanReader(folder: broken).keyframes()) ?? []
            expect(&f, "write.noLineWithoutDepth", !outcome.value && records.isEmpty && writer.failureCount > 0,
                   "written \(outcome.value), \(records.count) records, failures \(writer.failureCount)")
            expect(&f, "write.releasedOnFailure", copier.inUse == 0, "\(copier.inUse)")
        }
    }

    /// A photo job writes photos/<id>.jpg and one photos.jsonl pin.
    private static func writePhoto(_ f: inout [String], folder: RawScanFolder, source: CVPixelBuffer) {
        let copier = FrameCopier(width: 64, height: 48, pixelFormat: biPlanarFormat, count: 1)
        guard let id = UUID(uuidString: "00000000-0000-0000-0000-00000000A001"), let buffer = copier.copy(source) else {
            f.append("photo.write: no id or buffer")
            return
        }
        let pin = PhotoPin(id: id, timestamp: 42.5, transform: Transform4(moved(1)), intrinsics: sampleIntrinsics,
                           imageFile: RawScanFolder.photoPath(id), note: "kitchen outlet")
        let writer = RawScanWriter(folder: folder)
        let outcome = Outcome()
        writer.perform {
            outcome.value = try KeyframeEncoding.writePhoto(PhotoJob(buffer: buffer, pin: pin), folder: folder,
                                                            writer: writer, copier: copier,
                                                            quality: KeyframeEncoding.photoQuality)
        }
        _ = waitFlush(writer)
        let pins = (try? RawScanReader(folder: folder).photos()) ?? []
        let jpeg = folder.resolve(pin.imageFile).flatMap { try? Data(contentsOf: $0) }
        expect(&f, "photo.write", outcome.value && pins == [pin] && copier.inUse == 0, "\(pins.count) pins")
        expect(&f, "photo.jpeg", jpeg.map { KeyframeEncoding.isJPEG($0) } ?? false)
    }

    // MARK: - Lifecycle

    /// All three recorders tolerate `finishRecording` before any frame and ignore samples after
    /// it; the pose recorder writes the header at begin and 10 Hz samples.
    static func checkLifecycle(_ f: inout [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(tempFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let folder = makeFolder(root, name: "life", subfolders: ["keyframes", "depth", "photos"]),
              let empty = makeFolder(root, name: "empty", subfolders: ["keyframes", "depth", "photos"]) else {
            f.append("life.setup: could not create the temporary folders")
            return
        }
        let profile = ScanProfile(mode: .room, settings: .room)
        let unused = KeyframeRecorder()
        let immediate = Outcome()
        unused.finishRecording { immediate.value = true }
        expect(&f, "life.finishWithoutBegin", immediate.value)

        let keyframes = KeyframeRecorder()
        keyframes.beginRecording(into: folder, profile: profile, startTimestamp: 100)
        keyframes.isPaused = true
        expect(&f, "life.paused", keyframes.isPaused)
        expect(&f, "life.keyframesFinish", waitFinish(keyframes))
        let noRecords = !FileManager.default.fileExists(atPath: folder.keyframesLogURL.path)
        expect(&f, "life.noKeyframes", keyframes.stats.keyframes == 0 && noRecords)

        let photos = PhotoRecorder()
        photos.beginRecording(into: folder, profile: profile, startTimestamp: 100)
        photos.requestPhoto(note: "")
        expect(&f, "life.photoFinish", waitFinish(photos))
        expect(&f, "life.photoDropped", !photos.hasPendingRequest && photos.stats.photos == 0)

        let poses = PoseTrackRecorder()
        poses.beginRecording(into: folder, profile: profile, startTimestamp: 100)
        for frame in 0..<120 {
            poses.ingest(PoseSample(timestamp: 100 + Double(frame) / 60, transform: moved(Float(frame) * 0.01),
                                    tracking: 2, thermal: 0, exposureDuration: 1 / 120))
        }
        expect(&f, "life.poseFinish", waitFinish(poses))
        poses.ingest(PoseSample(timestamp: 105, transform: moved(0), tracking: 2, thermal: 0, exposureDuration: 0.01))
        let stored = (try? RawScanReader(folder: folder).poseSamples()) ?? []
        expect(&f, "life.poseSamples", stored.count == 20 && poses.stats.poseSamples == 20,
               "\(stored.count) stored, \(poses.stats.poseSamples) counted")
        expect(&f, "life.poseFirst", stored.first?.timestamp == 100 && stored.first?.tracking == 2)

        let idle = PoseTrackRecorder()
        idle.beginRecording(into: empty, profile: profile, startTimestamp: 0)
        expect(&f, "life.poseEmptyFinish", waitFinish(idle))
        let headerOnly = (try? Data(contentsOf: empty.poseTrackURL))?.count ?? -1
        let emptySamples = (try? RawScanReader(folder: empty).poseSamples()) ?? [PoseSample]()
        expect(&f, "life.poseHeaderOnly", headerOnly == PoseTrackFile.headerSize && emptySamples.isEmpty, "\(headerOnly) bytes")
        let again = Outcome()
        idle.finishRecording { again.value = true }
        expect(&f, "life.finishTwice", again.value)
    }

    // MARK: - Fixtures

    /// Mutable result box shared with an io-queue block (read after the flush wait).
    final class Outcome {
        /// The result.
        var value = false
    }

    /// Appends "name: detail" when `condition` is false.
    static func expect(_ failures: inout [String], _ name: String, _ condition: Bool,
                       _ detail: @autoclosure () -> String = "failed") {
        if !condition { failures.append("\(name): \(detail())") }
    }

    /// True when `a` and `b` differ by at most 1e-4.
    static func near(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) <= 1e-4
    }

    /// Waits until everything queued on the writer before this call ran.
    static func waitFlush(_ writer: RawScanWriter) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writer.flush(completion: { done.signal() })
        return done.wait(timeout: .now() + waitSeconds) == .success
    }

    /// Calls `finishRecording` and waits for its completion.
    static func waitFinish(_ recorder: ScanRecorder) -> Bool {
        let done = DispatchSemaphore(value: 0)
        recorder.finishRecording { done.signal() }
        return done.wait(timeout: .now() + waitSeconds) == .success
    }

    /// Creates `root/name` with the given subfolders, or nil on failure.
    static func makeFolder(_ root: URL, name: String, subfolders: [String]) -> RawScanFolder? {
        let url = root.appendingPathComponent(name, isDirectory: true)
        do {
            for sub in subfolders {
                try FileManager.default.createDirectory(at: url.appendingPathComponent(sub, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return RawScanFolder(url: url)
    }

    /// A '420f' buffer made with CVPixelBufferCreate whose plane bytes follow a pattern of `seed`.
    static func makeSource(width: Int, height: Int, seed: Int) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, biPlanarFormat, nil, &created)
        guard status == kCVReturnSuccess, let buffer = created else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                for column in 0..<bytesPerRow {
                    let value = (column * 7 + row * 13 + plane * 31 + seed * 17) & 0xFF
                    bytes[row * bytesPerRow + column] = UInt8(value)
                }
            }
        }
        return buffer
    }

    /// True when the pixel bytes of `plane` (width times `bytesPerPixel` per row) match.
    static func planesEqual(_ a: CVPixelBuffer, _ b: CVPixelBuffer, plane: Int, bytesPerPixel: Int) -> Bool {
        guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let rows = CVPixelBufferGetHeightOfPlane(a, plane)
        let rowBytes = CVPixelBufferGetWidthOfPlane(a, plane) * bytesPerPixel
        guard rows == CVPixelBufferGetHeightOfPlane(b, plane), rowBytes > 0,
              let baseA = CVPixelBufferGetBaseAddressOfPlane(a, plane),
              let baseB = CVPixelBufferGetBaseAddressOfPlane(b, plane) else { return false }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(a, plane)
        let strideB = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
        for row in 0..<rows where memcmp(baseA + row * strideA, baseB + row * strideB, rowBytes) != 0 {
            return false
        }
        return true
    }

    /// A camera pose moved `x` meters along +x.
    static func moved(_ x: Float) -> simd_float4x4 {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(x, 0, 0, 1)
        return pose
    }

    /// A rotation of `degrees` about +y.
    static func turned(_ degrees: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: degrees * Float.pi / 180, axis: SIMD3<Float>(0, 1, 0)))
    }

    /// Gate input with everything ok unless overridden.
    static func input(_ pose: simd_float4x4, t: Double, buffersFree: Int = 4, tracking: TrackingSummary = .normal,
                      thermalScale: Double = 1) -> KeyframeGateInput {
        KeyframeGateInput(pose: pose, timestamp: t, exposureOffset: 0, buffersFree: buffersFree, tracking: tracking,
                          storage: .ok, memory: .ok, paused: false, thermalScale: thermalScale)
    }

    /// Intrinsics of a 1920 x 1440 capture.
    static let sampleIntrinsics = Intrinsics(fx: 1400.5, fy: 1400.25, cx: 960.5, cy: 720.25, width: 1920, height: 1440)

    /// A keyframe record as the recorder builds it.
    static func sampleRecord(index: Int, withDepth: Bool) -> KeyframeRecord {
        KeyframeRecord(index: index, timestamp: 123.456, transform: Transform4(simd_mul(moved(1.25), turned(33))),
                       intrinsics: sampleIntrinsics, imageFile: RawScanFolder.keyframeImagePath(index),
                       depthFile: withDepth ? RawScanFolder.depthPath(index) : nil, exposureDuration: 1.0 / 120,
                       exposureOffset: -0.5, ambientIntensity: 850, angularSpeed: 0.25, trackingNormal: true)
    }
}
