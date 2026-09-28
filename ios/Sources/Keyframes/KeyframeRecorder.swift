import ARKit
import Foundation
import simd

/// Records motion-gated texture keyframes during an ARKit capture (D6, D7): per accepted frame
/// a JPEG of the camera image (`keyframes/NNNNN.jpg`), the Float16 depth plus confidence map
/// (`depth/NNNNN.dpth`) and one `KeyframeRecord` line in keyframes.jsonl with the pose,
/// per-frame intrinsics, exposure, light, angular speed and tracking.
///
/// Threading: every `ScanRecorder` call runs on the hub queue. Inside the frame callback the
/// recorder only decides (`KeyframeGate`) and copies (`FrameCopier`, `ARFrameReading`); JPEG
/// encoding, Float16 conversion and every write run on Store's io queue through the recorder's
/// own `RawScanWriter`. At most `bufferCount` keyframes are in flight; when no buffer is free
/// the keyframe is skipped and counted, never queued. No ARFrame or ARKit buffer is retained.
/// `isPaused` and the counters behind `stats` are lock-protected.
final class KeyframeRecorder: ScanRecorder {
    /// Preallocated frame buffers, so at most 4 keyframes are in flight (D7).
    static let bufferCount = 4
    /// Seconds between the per-minute log lines.
    static let logInterval: TimeInterval = 60
    /// Ambient intensity stored when a frame has no light estimate: ARKit's neutral value
    /// (1000 lumens), so a missing estimate is not mistaken for a dark room.
    static let neutralAmbientIntensity: Float = 1000

    /// JPEG quality of the keyframe images.
    let jpegQuality: Double

    // MARK: Lock-protected state

    /// Guards the lock-protected group.
    private let lock = NSLock()
    /// Backing store of `isPaused`.
    private var pausedFlag = false
    /// Keyframes whose record line was written, and lost viewpoints counted as skipped.
    private var writtenCount = 0, skippedCount = 0
    /// Keyframe write jobs finished on the io queue, their total and longest duration.
    private var jobCount = 0, jobNanos: UInt64 = 0, slowestJobNanos: UInt64 = 0

    // MARK: Hub queue state

    /// Lifecycle phase.
    private var phase: KeyframesRecorderPhase = .idle
    /// Folder and writer of the current (or last) recording.
    private var folder: RawScanFolder?, writer: RawScanWriter?
    /// Frames older than this (the scan start, frame timebase) are ignored.
    private var startTimestamp: TimeInterval = 0
    /// The keyframe gate of the current recording.
    private var gate = KeyframeGate(settings: .room)
    /// The frame copier, made at the first frame with its size and pixel format.
    private var copier: FrameCopier?
    /// Index of the next keyframe (file stem).
    private var nextIndex = 0
    /// Pose and timestamp of the previous frame, for the angular speed.
    private var previousFrame: (timestamp: TimeInterval, transform: simd_float4x4)?
    /// Start of the current log window (frame timebase) and its counters.
    private var windowStart: TimeInterval?
    /// Keyframes accepted in the current log window.
    private var windowAccepted = 0
    /// Lost viewpoints per skip reason in the current log window.
    private var windowSkips: [KeyframeSkipReason: Int] = [:]
    /// Frames rejected as blurred or badly exposed in the current log window.
    private var windowBlurRejects = 0, windowExposureRejects = 0

    /// Creates an idle recorder; `jpegQuality` is clamped to 0...1 when encoding.
    init(jpegQuality: Double = 0.85) {
        self.jpegQuality = jpegQuality
    }

    /// Logs a line so two scans in a row show the recorder was released.
    deinit {
        KeyframesLog.write("keyframe recorder deinit")
    }

    /// Any thread. While true no keyframe is taken (the engine sets it while paused, 3.21).
    /// Reset to false by `beginRecording`.
    var isPaused: Bool {
        get { locked { pausedFlag } }
        set { locked { pausedFlag = newValue } }
    }

    /// Hub queue. Keyframes written, lost viewpoints skipped, and failed writes.
    var stats: RecorderStats {
        var result = RecorderStats()
        locked { () -> Void in
            result.keyframes = writtenCount
            result.skippedKeyframes = skippedCount
        }
        result.writeFailures = writer?.failureCount ?? 0
        return result
    }

    // MARK: - ScanRecorder

    /// Hub queue. Starts recording into `folder` (made by `InProgressScans.create`, with its
    /// keyframes/ and depth/ subfolders): a new writer, a gate from `profile.settings`
    /// (`selectorConfig(for:)`), keyframe numbering from 0 and cleared counters. A recording
    /// still open is closed first (build 5 House starts the next room this way after a finish).
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        if phase == .recording, let previous = writer {
            KeyframesLog.write("keyframes: begin while recording; closing the previous recording")
            KeyframeEncoding.finish(previous) {}
        }
        self.folder = folder
        writer = RawScanWriter(folder: folder)
        self.startTimestamp = startTimestamp
        gate = KeyframeGate(settings: profile.settings)
        copier = nil
        nextIndex = 0
        previousFrame = nil
        resetWindow(at: nil)
        locked { () -> Void in
            pausedFlag = false
            writtenCount = 0
            skippedCount = 0
            jobCount = 0
            jobNanos = 0
            slowestJobNanos = 0
        }
        phase = .recording
        let config = gate.selector.config
        KeyframesLog.write("keyframes: begin \(folder.url.lastPathComponent), mode \(profile.mode.rawValue), gate "
                           + "\(config.maxTranslation) m or \(config.maxRotationDegrees) deg, quality \(jpegQuality)")
    }

    /// Hub queue. Gates the frame and, for an accepted keyframe, copies the image, depth,
    /// intrinsics and camera facts, then queues the encode and writes on the io queue.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        guard phase == .recording, let folder, let writer else { return }
        let timestamp = frame.timestamp
        guard timestamp + 0.001 >= startTimestamp else { return }
        let camera = frame.camera
        let pose = camera.transform
        let angularSpeed = updateAngularSpeed(pose: pose, timestamp: timestamp)
        logWindowIfDue(timestamp)
        let image = frame.capturedImage
        let input = KeyframeGateInput(pose: pose, timestamp: timestamp, exposureOffset: camera.exposureOffset,
                                      buffersFree: prepareCopier(for: image),
                                      tracking: TrackingMonitor.summary(camera.trackingState),
                                      storage: hub.storage.state, memory: hub.status.memory, paused: isPaused,
                                      thermalScale: hub.thermal.policy.keyframeIntervalScale)
        switch gate.evaluate(input) {
        case .skipped(let reason, let newViewpoint):
            noteSkipped(reason, counted: newViewpoint)
            return
        case .rejected(let decision):
            noteRejected(decision)
            return
        case .accept:
            break
        }
        guard let activeCopier = copier, let buffer = activeCopier.copy(image) else {
            noteSkipped(.noBuffer, counted: gate.revertLastAccept(pose: pose))
            return
        }
        let index = nextIndex
        nextIndex += 1
        windowAccepted += 1
        let depth = ARFrameReading.depthMap(of: frame)
        let ambient = ARFrameReading.ambientIntensity(of: frame) ?? KeyframeRecorder.neutralAmbientIntensity
        let record = KeyframeRecord(index: index, timestamp: timestamp, transform: Transform4(pose),
                                    intrinsics: ARFrameReading.intrinsics(of: camera),
                                    imageFile: RawScanFolder.keyframeImagePath(index),
                                    depthFile: depth == nil ? nil : RawScanFolder.depthPath(index),
                                    exposureDuration: camera.exposureDuration, exposureOffset: camera.exposureOffset,
                                    ambientIntensity: ambient, angularSpeed: angularSpeed,
                                    trackingNormal: input.tracking == .normal)
        submit(KeyframeJob(buffer: buffer, depth: depth, record: record), folder: folder, writer: writer,
               copier: activeCopier)
    }

    /// Hub queue. Stops taking keyframes, waits for every queued keyframe write, closes the
    /// writer and then calls `completion` (on the io queue). Without an open recording (never
    /// begun, or already finished) `completion` runs at once. Later hub callbacks are ignored.
    func finishRecording(completion: @escaping () -> Void) {
        guard phase == .recording, let writer else {
            if phase == .recording { phase = .finished }
            completion()
            return
        }
        phase = .finished
        logWindow(isFinal: true)
        copier = nil
        let name = folder?.url.lastPathComponent ?? "-"
        KeyframeEncoding.finish(writer) { [weak self] in
            if let summary = self?.summaryLine() {
                KeyframesLog.write("keyframes: finished \(name): \(summary), \(writer.failureCount) write failures")
            }
            completion()
        }
    }

    // MARK: - Io queue

    /// Queues one keyframe on the io queue: encode, release, depth, record line; counts the
    /// written record and the job time.
    private func submit(_ job: KeyframeJob, folder: RawScanFolder, writer: RawScanWriter, copier: FrameCopier) {
        let quality = jpegQuality
        writer.perform { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var written = false
            defer {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                self?.noteJobFinished(written: written, nanos: elapsed)
            }
            written = try KeyframeEncoding.writeKeyframe(job, folder: folder, writer: writer,
                                                         copier: copier, quality: quality)
        }
    }

    /// Io queue. Counts a finished job (and its record when written).
    private func noteJobFinished(written: Bool, nanos: UInt64) {
        locked { () -> Void in
            if written { writtenCount += 1 }
            jobCount += 1
            jobNanos &+= nanos
            if nanos > slowestJobNanos { slowestJobNanos = nanos }
        }
    }

    // MARK: - Hub queue helpers

    /// Free copier buffers for this image. Makes the copier at the first frame (size and pixel
    /// format read at runtime); remakes it when the format changed and nothing is in flight.
    private func prepareCopier(for image: CVPixelBuffer) -> Int {
        if let existing = copier {
            if existing.matches(image) { return existing.available }
            if existing.inUse > 0 { return 0 }
        }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let format = CVPixelBufferGetPixelFormatType(image)
        let made = FrameCopier(width: width, height: height, pixelFormat: format, count: KeyframeRecorder.bufferCount)
        copier = made
        KeyframesLog.write("keyframes: frame copier \(made.count) buffers of \(width)x\(height) "
                           + "\(CaptureDiagnostics.fourCC(format)), planes \(CVPixelBufferGetPlaneCount(image))")
        return made.available
    }

    /// Angular speed since the previous frame (rad/s), and remembers this frame.
    private func updateAngularSpeed(pose: simd_float4x4, timestamp: TimeInterval) -> Float {
        var speed: Float = 0
        if let previous = previousFrame {
            speed = ARFrameReading.angularSpeed(from: previous.transform, to: pose, seconds: timestamp - previous.timestamp)
        }
        previousFrame = (timestamp, pose)
        return speed
    }

    /// Counts a skip in the window; a lost viewpoint (not while paused) also counts in `stats`.
    private func noteSkipped(_ reason: KeyframeSkipReason, counted: Bool) {
        guard counted else { return }
        windowSkips[reason, default: 0] += 1
        if reason != .paused { locked { skippedCount += 1 } }
    }

    /// Counts blur and exposure rejections for the log (too close and too soon are the normal
    /// case between keyframes).
    private func noteRejected(_ decision: KeyframeSelector.Decision) {
        switch decision {
        case .rejectBlur: windowBlurRejects += 1
        case .rejectExposure: windowExposureRejects += 1
        case .accept, .rejectTooClose, .rejectTooSoon: break
        }
    }

    // MARK: - Per-minute log

    /// Writes the window line when `logInterval` passed since the window started.
    private func logWindowIfDue(_ timestamp: TimeInterval) {
        guard let start = windowStart else {
            resetWindow(at: timestamp)
            return
        }
        if timestamp - start >= KeyframeRecorder.logInterval || timestamp < start {
            logWindow(isFinal: false)
            resetWindow(at: timestamp)
        }
    }

    /// Logs the current window: accepted, lost viewpoints per reason, rejections, in flight.
    private func logWindow(isFinal: Bool) {
        let skips = KeyframeSkipReason.allCases.compactMap { reason -> String? in
            guard let value = windowSkips[reason], value > 0 else { return nil }
            return "\(reason.rawValue) \(value)"
        }
        let skipText = skips.isEmpty ? "none" : skips.joined(separator: ", ")
        let inFlight = copier?.inUse ?? 0
        let label = isFinal ? "last window" : "last minute"
        KeyframesLog.write("keyframes \(label): accepted \(windowAccepted), skipped \(skipText), "
                           + "rejected blur \(windowBlurRejects) exposure \(windowExposureRejects), "
                           + "in flight \(inFlight); \(summaryLine())")
    }

    /// Clears the window counters and starts a new window at `timestamp`.
    private func resetWindow(at timestamp: TimeInterval?) {
        windowStart = timestamp
        windowAccepted = 0
        windowSkips = [:]
        windowBlurRejects = 0
        windowExposureRejects = 0
    }

    /// Totals for the log: written, skipped, mean and slowest io job in milliseconds.
    private func summaryLine() -> String {
        locked { () -> String in
            let mean = jobCount > 0 ? Double(jobNanos) / Double(jobCount) / 1_000_000 : 0
            let slowest = Double(slowestJobNanos) / 1_000_000
            return "written \(writtenCount), skipped \(skippedCount), jobs \(jobCount), "
                + "mean \(Int(mean.rounded())) ms, slowest \(Int(slowest.rounded())) ms"
        }
    }

    /// Runs `body` while holding `lock`.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
