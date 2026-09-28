import ARKit
import Foundation
import simd

/// Records the 10 Hz binary pose track `poses.ptrk` of an ARKit capture (D8): one `PoseSample`
/// every 0.1 s by frame timestamp with the camera transform, the tracking code
/// (`TrackingMonitor.poseCode`), the thermal level index and the exposure duration.
///
/// Writes the PTRK header at begin, buffers records in a `ByteWriter`, appends the batch
/// through its own `RawScanWriter` about once a second, and appends the rest at `flushNow` and
/// at finish. Every `ScanRecorder` call runs on the hub queue and all state is confined to it;
/// the append itself runs on the io queue. No ARFrame is retained.
final class PoseTrackRecorder: ScanRecorder {
    /// Pose sampling interval by frame timestamp.
    static let sampleInterval: TimeInterval = 0.1    // 10 Hz
    /// Seconds of samples buffered before a batch is appended.
    static let flushInterval: TimeInterval = 1
    /// Early tolerance of the sampling interval, seconds (half a 60 fps frame), so frame
    /// timing jitter does not push samples one frame late.
    static let dueTolerance: TimeInterval = 0.008

    // MARK: Hub queue state

    /// Lifecycle phase.
    private var phase: KeyframesRecorderPhase = .idle
    /// Folder and writer of the current (or last) recording.
    private var folder: RawScanFolder?, writer: RawScanWriter?
    /// Frames older than this (the scan start, frame timebase) are ignored.
    private var startTimestamp: TimeInterval = 0
    /// Timestamp of the last recorded sample and of the last batch append.
    private var lastSampleTimestamp: TimeInterval?, lastFlushTimestamp: TimeInterval?
    /// Records not yet handed to the writer.
    private var pending = ByteWriter()
    /// Number of records in `pending`, and samples recorded since begin.
    private var pendingCount = 0, recordedCount = 0

    /// Creates an idle recorder.
    init() {}

    /// Hub queue. Pose samples recorded and failed writes.
    var stats: RecorderStats {
        var result = RecorderStats()
        result.poseSamples = recordedCount
        result.writeFailures = writer?.failureCount ?? 0
        return result
    }

    /// Hub queue. Starts a track in `folder`: a new writer and the PTRK header appended to
    /// `poses.ptrk`. A recording still open is flushed and closed first.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        if phase == .recording, let previous = writer {
            KeyframesLog.write("pose track: begin while recording; closing the previous track")
            appendPending()
            KeyframeEncoding.finish(previous) {}
        }
        let newWriter = RawScanWriter(folder: folder)
        self.folder = folder
        writer = newWriter
        self.startTimestamp = startTimestamp
        lastSampleTimestamp = nil
        lastFlushTimestamp = nil
        pending = ByteWriter(capacity: PoseTrackRecorder.batchCapacity)
        pendingCount = 0
        recordedCount = 0
        phase = .recording
        newWriter.appendBytes(KeyframeEncoding.poseTrackHeader(), to: folder.poseTrackURL)
        KeyframesLog.write("pose track: begin \(folder.url.lastPathComponent), mode \(profile.mode.rawValue)")
    }

    /// Hub queue. Records a sample when 0.1 s passed since the last one.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        guard phase == .recording else { return }
        let timestamp = frame.timestamp
        guard timestamp + 0.001 >= startTimestamp,
              PoseTrackRecorder.isDue(timestamp: timestamp, last: lastSampleTimestamp) else { return }
        let camera = frame.camera
        let sample = PoseSample(timestamp: timestamp, transform: camera.transform,
                                tracking: TrackingMonitor.poseCode(camera.trackingState),
                                thermal: KeyframeEncoding.thermalCode(hub.thermal.level),
                                exposureDuration: Float(camera.exposureDuration))
        ingest(sample)
    }

    /// Hub queue. Buffers one sample (when due and recording) and appends the batch once a
    /// second passed since the last append. The ARKit-free entry point of the recorder, used
    /// by `hub(_:didUpdate:)` and the self-test.
    func ingest(_ sample: PoseSample) {
        guard phase == .recording,
              PoseTrackRecorder.isDue(timestamp: sample.timestamp, last: lastSampleTimestamp) else { return }
        lastSampleTimestamp = sample.timestamp
        PoseTrackFile.append(sample, to: &pending)
        pendingCount += 1
        recordedCount += 1
        guard let lastFlush = lastFlushTimestamp else {
            lastFlushTimestamp = sample.timestamp
            return
        }
        let sinceFlush = sample.timestamp - lastFlush
        if sinceFlush >= PoseTrackRecorder.flushInterval || sinceFlush < 0 {
            appendPending()
            lastFlushTimestamp = sample.timestamp
        }
    }

    /// Hub queue. Memory pressure: appends the buffered samples now, without finishing.
    func flushNow() {
        guard phase == .recording else { return }
        appendPending()
    }

    /// Hub queue. Appends the buffered samples, waits for every queued write, closes the
    /// writer and calls `completion` (on the io queue). Without an open recording `completion`
    /// runs at once. Later hub callbacks are ignored.
    func finishRecording(completion: @escaping () -> Void) {
        guard phase == .recording, let writer else {
            if phase == .recording { phase = .finished }
            completion()
            return
        }
        appendPending()
        phase = .finished
        let name = folder?.url.lastPathComponent ?? "-"
        let samples = recordedCount
        KeyframeEncoding.finish(writer) {
            KeyframesLog.write("pose track: finished \(name): \(samples) samples, \(writer.failureCount) write failures")
            completion()
        }
    }

    // MARK: - Helpers

    /// Bytes reserved for one batch (a second at 10 Hz plus slack).
    static let batchCapacity = PoseTrackFile.recordSize * 16

    /// True when a sample at `timestamp` is due: the first sample, a timebase that went
    /// backwards, or at least `sampleInterval - dueTolerance` after the last sample. Pure.
    static func isDue(timestamp: TimeInterval, last: TimeInterval?) -> Bool {
        guard timestamp.isFinite else { return false }
        guard let last else { return true }
        let delta = timestamp - last
        return delta < 0 || delta >= sampleInterval - dueTolerance
    }

    /// Hands the buffered records to the writer (queued append on the io queue).
    private func appendPending() {
        guard pendingCount > 0, let writer, let folder else { return }
        writer.appendBytes(pending.data, to: folder.poseTrackURL)
        pending = ByteWriter(capacity: PoseTrackRecorder.batchCapacity)
        pendingCount = 0
    }
}
