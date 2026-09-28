import CoreVideo
import Foundation
import simd

/// Plain-Swift checks for the Keyframes module (no XCTest). `run()` returns one line per
/// failing check ("name: detail"); empty means all passed. Deterministic, well under 2 s, and
/// it never runs an ARSession, the camera or the network: it copies and encodes synthetic
/// 64 x 48 '420f' buffers made with CVPixelBufferCreate, drives the keyframe gate with
/// synthetic poses, and writes files only under a fixed folder in
/// `FileManager.default.temporaryDirectory`, which it removes (KeyframesSelfTest+Files.swift).
enum KeyframesSelfTest {
    /// Runs every check and returns the failures.
    static func run() -> [String] {
        var failures: [String] = []
        checkCopierPool(&failures)
        checkPlaneCopy(&failures)
        checkGateThresholds(&failures)
        checkGateConditions(&failures)
        checkThermalGate(&failures)
        checkPoseTrack(&failures)
        checkRecordLine(&failures)
        checkPhotoRequest(&failures)
        checkJPEG(&failures)
        checkWrites(&failures)
        checkLifecycle(&failures)
        return failures
    }

    // MARK: - Frame copier (D7)

    /// Count 2 hands out 2 buffers then nil, a buffer again after a release; foreign and double
    /// releases are ignored; a source of another size is refused.
    private static func checkCopierPool(_ f: inout [String]) {
        expect(&f, "copier.poolSize", KeyframeRecorder.bufferCount == 4, "\(KeyframeRecorder.bufferCount)")
        let copier = FrameCopier(width: 64, height: 48, pixelFormat: biPlanarFormat, count: 2)
        expect(&f, "copier.count", copier.count == 2, "\(copier.count)")
        guard let source = makeSource(width: 64, height: 48, seed: 1) else {
            f.append("copier.source: CVPixelBufferCreate failed")
            return
        }
        let first = copier.copy(source)
        let second = copier.copy(source)
        let third = copier.copy(source)
        expect(&f, "copier.two", first != nil && second != nil, "a buffer was nil")
        expect(&f, "copier.distinct", first !== second)
        expect(&f, "copier.exhausted", third == nil)
        expect(&f, "copier.inUse", copier.inUse == 2, "\(copier.inUse)")
        if let first { copier.release(first) }
        expect(&f, "copier.released", copier.inUse == 1, "\(copier.inUse)")
        let again = copier.copy(source)
        expect(&f, "copier.again", again != nil)
        if let again {
            copier.release(again)
            copier.release(again)
        }
        copier.release(source)
        expect(&f, "copier.doubleAndForeign", copier.inUse == 1 && copier.available == 1,
               "inUse \(copier.inUse), available \(copier.available)")
        if let small = makeSource(width: 32, height: 24, seed: 2) {
            expect(&f, "copier.mismatch", !copier.matches(small) && copier.copy(small) == nil && copier.inUse == 1)
        }
    }

    /// The copied planes equal the source bytes for a synthetic 64 x 48 '420f' buffer.
    private static func checkPlaneCopy(_ f: inout [String]) {
        let copier = FrameCopier(width: 64, height: 48, pixelFormat: biPlanarFormat, count: 1)
        guard let source = makeSource(width: 64, height: 48, seed: 7), let copy = copier.copy(source) else {
            f.append("copy.planes: no source or copy")
            return
        }
        expect(&f, "copy.planeCount", CVPixelBufferGetPlaneCount(copy) == 2, "\(CVPixelBufferGetPlaneCount(copy))")
        expect(&f, "copy.lumaPlane", planesEqual(source, copy, plane: 0, bytesPerPixel: 1))
        expect(&f, "copy.chromaPlane", planesEqual(source, copy, plane: 1, bytesPerPixel: 2))
        copier.release(copy)
        expect(&f, "copy.release", copier.inUse == 0, "\(copier.inUse)")
    }

    // MARK: - Gate (D6, R15)

    /// Standard settings: 0.30 m or 15 degrees; a 0.35 m move is accepted and 0.1 m rejected;
    /// Keep all photos off scales the gate by 1.5.
    private static func checkGateThresholds(_ f: inout [String]) {
        var gate = KeyframeGate(settings: .room)
        let config = gate.selector.config
        expect(&f, "gate.standard", near(config.maxTranslation, 0.30) && near(config.maxRotationDegrees, 15),
               "\(config.maxTranslation) m, \(config.maxRotationDegrees) deg")
        let blurLimit: Bool = config.maxAngularVelocity == 1
        let neverThinned: Bool = config.maxKeyframes == Int.max
        let exposureRange: Bool = config.minExposureOffset == -2 && config.maxExposureOffset == 2
        expect(&f, "gate.limits", blurLimit && neverThinned && exposureRange)
        expect(&f, "gate.first", gate.evaluate(input(moved(0), t: 0)) == .accept)
        let short = gate.evaluate(input(moved(0.1), t: 1))
        expect(&f, "gate.reject0.1", short == .rejected(.rejectTooClose), "\(short)")
        let long = gate.evaluate(input(moved(0.35), t: 2))
        expect(&f, "gate.accept0.35", long == .accept, "\(long)")
        let small = gate.evaluate(input(simd_mul(moved(0.35), turned(10)), t: 3))
        expect(&f, "gate.reject10deg", small == .rejected(.rejectTooClose), "\(small)")
        let large = gate.evaluate(input(simd_mul(moved(0.35), turned(20)), t: 4))
        expect(&f, "gate.accept20deg", large == .accept, "\(large)")

        var settings = ScanSettings.room
        settings.keepAllPhotos = false
        let coarseConfig = KeyframeRecorder.selectorConfig(for: settings)
        expect(&f, "gate.keepAllOff", near(coarseConfig.maxTranslation, 0.45) && near(coarseConfig.maxRotationDegrees, 22.5),
               "\(coarseConfig.maxTranslation) m, \(coarseConfig.maxRotationDegrees) deg")
        var coarse = KeyframeGate(settings: settings)
        _ = coarse.evaluate(input(moved(0), t: 0))
        let coarseShort = coarse.evaluate(input(moved(0.35), t: 1))
        expect(&f, "gate.keepAllOff.reject0.35", coarseShort == .rejected(.rejectTooClose), "\(coarseShort)")
        let coarseLong = coarse.evaluate(input(moved(0.5), t: 2))
        expect(&f, "gate.keepAllOff.accept0.5", coarseLong == .accept, "\(coarseLong)")
    }

    /// The pure condition helper, pool exhaustion followed by the same pose, counting a lost
    /// viewpoint once, and reverting an accept whose copy failed.
    private static func checkGateConditions(_ f: inout [String]) {
        expect(&f, "consider.allOk", KeyframeRecorder.shouldConsider(buffersFree: 1, tracking: .normal, storage: .ok,
                                                                    memory: .ok, paused: false))
        expect(&f, "consider.noBuffer", !KeyframeRecorder.shouldConsider(buffersFree: 0, tracking: .normal, storage: .ok,
                                                                        memory: .ok, paused: false))
        expect(&f, "consider.tracking", !KeyframeRecorder.shouldConsider(buffersFree: 4, tracking: .limited, storage: .ok,
                                                                        memory: .ok, paused: false))
        expect(&f, "consider.storage", !KeyframeRecorder.shouldConsider(buffersFree: 4, tracking: .normal,
                                                                       storage: .stopKeyframes, memory: .ok, paused: false))
        expect(&f, "consider.memory", !KeyframeRecorder.shouldConsider(buffersFree: 4, tracking: .normal, storage: .ok,
                                                                      memory: .low, paused: false))
        expect(&f, "consider.paused", !KeyframeRecorder.shouldConsider(buffersFree: 4, tracking: .normal, storage: .ok,
                                                                      memory: .ok, paused: true))
        let first = KeyframeRecorder.skipReason(buffersFree: 0, tracking: .initializing, storage: .pause,
                                                memory: .critical, paused: true)
        expect(&f, "consider.order", first == .paused, "\(String(describing: first))")

        var gate = KeyframeGate(settings: .room)
        _ = gate.evaluate(input(moved(0), t: 0))
        let target = moved(0.35)
        let exhausted = gate.evaluate(input(target, t: 1, buffersFree: 0))
        expect(&f, "pool.skipped", exhausted == .skipped(.noBuffer, newViewpoint: true), "\(exhausted)")
        let repeated = gate.evaluate(input(target, t: 1.05, buffersFree: 0))
        expect(&f, "pool.countedOnce", repeated == .skipped(.noBuffer, newViewpoint: false), "\(repeated)")
        let freed = gate.evaluate(input(target, t: 1.1, buffersFree: 1))
        expect(&f, "pool.samePoseAccepted", freed == .accept, "\(freed)")
        expect(&f, "pool.accepted", gate.acceptedCount == 2, "\(gate.acceptedCount)")
        let limited = gate.evaluate(input(moved(0.7), t: 2, tracking: .excessiveMotion))
        expect(&f, "gate.trackingSkip", limited == .skipped(.tracking, newViewpoint: true), "\(limited)")

        var revert = KeyframeGate(settings: .room)
        _ = revert.evaluate(input(moved(0), t: 0))
        let pose = moved(0.4)
        _ = revert.evaluate(input(pose, t: 1))
        let lost = revert.revertLastAccept(pose: pose)
        expect(&f, "revert.counted", lost && revert.acceptedCount == 1, "lost \(lost), count \(revert.acceptedCount)")
        let retried = revert.evaluate(input(pose, t: 1.2))
        expect(&f, "revert.retryAccepted", retried == .accept, "\(retried)")
        expect(&f, "viewpoint.none", KeyframeRecorder.isNewViewpoint(moved(0), reference: nil, config: revert.selector.config))
        expect(&f, "viewpoint.close", !KeyframeRecorder.isNewViewpoint(moved(0.05), reference: moved(0),
                                                                      config: revert.selector.config))
    }

    /// Thermal interval: no effect at scale 1; at scale 2 at most one keyframe a second.
    private static func checkThermalGate(_ f: inout [String]) {
        expect(&f, "thermal.scale1", KeyframeRecorder.thermalAllows(scale: 1, secondsSinceLastKeyframe: 0.01))
        expect(&f, "thermal.first", KeyframeRecorder.thermalAllows(scale: 2, secondsSinceLastKeyframe: nil))
        expect(&f, "thermal.tooSoon", !KeyframeRecorder.thermalAllows(scale: 2, secondsSinceLastKeyframe: 0.5))
        expect(&f, "thermal.oneSecond", KeyframeRecorder.thermalAllows(scale: 2, secondsSinceLastKeyframe: 1.0))
        var gate = KeyframeGate(settings: .room)
        _ = gate.evaluate(input(moved(0), t: 0, thermalScale: 2))
        let early = gate.evaluate(input(moved(0.35), t: 0.5, thermalScale: 2))
        expect(&f, "thermal.gateSkip", early == .skipped(.thermal, newViewpoint: true), "\(early)")
        let later = gate.evaluate(input(moved(0.35), t: 1.2, thermalScale: 2))
        expect(&f, "thermal.gateAccept", later == .accept, "\(later)")
    }

    // MARK: - Pose track (D8)

    /// 3 samples round trip through `PoseTrackFile.decode`; 60 fps frames give 10 Hz samples;
    /// thermal codes are the ThermalLevel index.
    private static func checkPoseTrack(_ f: inout [String]) {
        let samples = (0..<3).map { i -> PoseSample in
            PoseSample(timestamp: 10 + Double(i) * 0.1, transform: simd_mul(moved(Float(i) * 0.5), turned(Float(i) * 30)),
                       tracking: UInt8(i), thermal: UInt8(3 - i), exposureDuration: 1 / Float(60 + i))
        }
        let data = KeyframeEncoding.poseTrackData(samples, includeHeader: true)
        let expectedSize = PoseTrackFile.headerSize + 3 * PoseTrackFile.recordSize
        expect(&f, "pose.size", data.count == expectedSize, "\(data.count)")
        do {
            let decoded = try PoseTrackFile.decode(data)
            expect(&f, "pose.roundTrip", decoded == samples, "\(decoded.count) samples")
        } catch {
            f.append("pose.roundTrip: \(error)")
        }
        var last: TimeInterval?
        var due = 0
        for frame in 0..<120 {
            let timestamp = Double(frame) / 60
            if PoseTrackRecorder.isDue(timestamp: timestamp, last: last) {
                due += 1
                last = timestamp
            }
        }
        expect(&f, "pose.tenHertz", due == 20, "\(due) samples in 2 s")
        let criticalCode = UInt8(clamping: ProcessInfo.ThermalState.critical.rawValue)
        let nominal: UInt8 = KeyframeEncoding.thermalCode(.nominal)
        let critical: UInt8 = KeyframeEncoding.thermalCode(.critical)
        expect(&f, "pose.thermalCode", nominal == 0 && critical == 3 && critical == criticalCode, "\(nominal) \(critical)")
    }

    // MARK: - Records, photos, JPEG

    /// The JSON Lines line of a keyframe is one line and decodes to the same record.
    private static func checkRecordLine(_ f: inout [String]) {
        let record = sampleRecord(index: 12, withDepth: true)
        expect(&f, "record.paths", record.imageFile == "keyframes/00012.jpg" && record.depthFile == "depth/00012.dpth",
               record.imageFile)
        do {
            let line = try KeyframeEncoding.jsonLine(record)
            let newlines = line.filter { $0 == 0x0A }.count
            expect(&f, "record.oneLine", line.last == 0x0A && newlines == 1, "\(newlines) newlines")
            let decoded = try ProjectStore.decoder.decode(KeyframeRecord.self, from: line.dropLast())
            expect(&f, "record.roundTrip", decoded == record)
        } catch {
            f.append("record.roundTrip: \(error)")
        }
    }

    /// A photo request is consumed exactly once; a second request while pending is merged.
    private static func checkPhotoRequest(_ f: inout [String]) {
        let recorder = PhotoRecorder()
        expect(&f, "photo.none", recorder.takePendingRequest() == nil && !recorder.hasPendingRequest)
        recorder.requestPhoto(note: "first")
        recorder.requestPhoto(note: "second")
        expect(&f, "photo.pending", recorder.hasPendingRequest)
        let taken = recorder.takePendingRequest()
        expect(&f, "photo.takenOnce", taken == "first", String(describing: taken))
        expect(&f, "photo.consumed", recorder.takePendingRequest() == nil && !recorder.hasPendingRequest)
    }

    /// JPEG encoding of a synthetic buffer starts with FF D8.
    private static func checkJPEG(_ f: inout [String]) {
        guard let source = makeSource(width: 64, height: 48, seed: 3) else {
            f.append("jpeg.source: CVPixelBufferCreate failed")
            return
        }
        let data = KeyframeEncoding.jpegData(from: source, quality: KeyframeEncoding.keyframeQuality)
        expect(&f, "jpeg.magic", data.map { KeyframeEncoding.isJPEG($0) } ?? false, "\(data?.count ?? 0) bytes")
        expect(&f, "jpeg.notJPEG", !KeyframeEncoding.isJPEG(Data([0x89, 0x50, 0x4E, 0x47])))
    }
}
