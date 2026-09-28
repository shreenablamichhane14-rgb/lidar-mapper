import ARKit
import Foundation
import simd

/// One anchor's entry in `MeshStore.index`: identity, sizes, world-space bounds and state of
/// the latest version. A value copy, safe to read on any queue.
struct MeshChunkIndexEntry: Equatable, Sendable {
    /// `ARMeshAnchor.identifier`.
    var anchorID: UUID
    /// Versions recorded for this anchor in the current recording (1 after the first).
    var updateCount: UInt32
    /// Whole faces of the latest version.
    var faceCount: Int
    /// Vertices of the latest version.
    var vertexCount: Int
    /// World-space bounds of the latest version (anchor transform applied).
    var boundsMin: SIMD3<Float>
    /// World-space bounds of the latest version (anchor transform applied).
    var boundsMax: SIMD3<Float>
    /// ARKit removed the anchor; its data and file are kept because it may come back.
    var isStale: Bool
    /// The latest version is not on disk yet.
    var isDirty: Bool
    /// The geometry was dropped from RAM after the room's final flush (D17).
    var isEvicted: Bool
}

/// Records the raw LiDAR mesh (Representation A, D8) during ARKit captures.
///
/// Keeps the latest anchor-local copy of every `ARMeshAnchor` (copied inside the callback by
/// `MeshAnchorCopier`, so no ARKit object or buffer outlives the call), flushes dirty anchors to
/// `mesh/<anchor>.mchk` every 3 s and once at the end (latest version per anchor, file replaced
/// atomically by `RawScanWriter`, encoding on the io queue), keeps removed anchors marked stale
/// (RESEARCH 3.1 gotcha 15), drops geometry from RAM after the final flush on `evict()` (D17) and
/// reports live counters.
///
/// Every `ScanRecorder` call arrives on the hub queue. The state is lock-protected, so the
/// read-only members (`index`, `stats`, `currentChunks()`, `residentBytes`) and `evict()` are
/// safe from any queue as well. Flush machinery lives in MeshRecordFlush.swift.
final class MeshStore: ScanRecorder {
    /// Seconds between two timed flushes of dirty anchors (D8).
    static let flushInterval: TimeInterval = 3
    /// Timed flush batches allowed to wait on the io queue; the timer skips a turn beyond this.
    static let maxTimedFlushesInFlight = 1
    /// Failed writes of one anchor retried by marking it dirty again, before it waits for its
    /// next update (a successful write resets the count).
    static let maxWriteRetries = 3
    /// Anchor callbacks slower than this are logged, once per recording, nanoseconds.
    static let slowCallbackNanos: UInt64 = 4_000_000

    /// Counters for the per-room log line. Lock-protected.
    struct Counters {
        /// Flush batches submitted and anchor files written.
        var flushes = 0, filesWritten = 0
        /// Bytes of chunk files written.
        var bytesWritten: Int64 = 0
        /// Anchors marked dirty again after a failed write; batches whose folder was missing.
        var writeRetries = 0, missingFolderBatches = 0
        /// Copies without faces (skipped) and chunks offered while not recording (ignored).
        var emptyUpdates = 0, ignoredWhileIdle = 0
        /// Removal callbacks that marked an anchor stale.
        var staleMarks = 0
        /// Slowest anchor callback, nanoseconds, and whether a slow one was logged.
        var slowestCallbackNanos: UInt64 = 0
        /// True once a slow callback was logged in this recording.
        var loggedSlowCallback = false
    }

    // MARK: State (lock-protected; only MeshStore's own files touch it)

    /// Guards every stored property below.
    let lock = NSLock()
    /// Folder, writer and write ledger of the current (or last) recording.
    var folderValue: RawScanFolder?
    /// Writer of the current (or last) recording; closed at finish.
    var writerValue: RawScanWriter?
    /// Versions already on disk (io queue only), one ledger per recording.
    var ledgerValue: FlushLedger?
    /// True between `beginRecording` and `finishRecording`.
    var recording = false
    /// Incremented by every `beginRecording`, so late io completions of an earlier recording
    /// never touch the state of the next one.
    var generation = 0
    /// Latest anchor-local copy per anchor (empty after `evict()`).
    var chunkStore: [UUID: MeshChunk] = [:]
    /// Anchor identifiers in first-seen order (deterministic flush and `currentChunks` order).
    var anchorOrder: [UUID] = []
    /// Backing store of `index`.
    var indexValue: [UUID: MeshChunkIndexEntry] = [:]
    /// Anchors whose latest version is not on disk and not yet handed to the writer.
    var dirtyIDs = Set<UUID>()
    /// Sum of `faceCount` over the index.
    var faceTotal = 0
    /// Sum of `residentBytes(of:)` over `chunkStore`.
    var residentTotal = 0
    /// Frame time of the last timed flush (or of the scan start); nil until the first frame.
    var lastFlushTime: TimeInterval?
    /// Timed flush batches submitted and not completed yet.
    var timedFlushesInFlight = 0
    /// Consecutive failed writes per anchor.
    var retryCounts: [UUID: Int] = [:]
    /// Log counters of the current recording.
    var counters = Counters()

    /// An idle store; `beginRecording` starts a recording.
    init() {}

    // MARK: - ScanRecorder

    /// Hub queue. Starts recording into `folder` (its `mesh/` subfolder is made on the first
    /// flush while the folder exists). A recording still running is flushed and closed first.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        let previous = locked { () -> (batch: FlushBatch?, writer: RawScanWriter?) in
            let leftover = recording ? takeBatchLocked(reason: .restart) : nil
            let oldWriter = recording ? writerValue : nil
            generation += 1
            folderValue = folder
            writerValue = RawScanWriter(folder: folder)
            ledgerValue = FlushLedger()
            recording = true
            chunkStore = [:]
            anchorOrder = []
            indexValue = [:]
            dirtyIDs = []
            faceTotal = 0
            residentTotal = 0
            lastFlushTime = startTimestamp > 0 ? startTimestamp : nil
            timedFlushesInFlight = 0
            retryCounts = [:]
            counters = Counters()
            return (leftover, oldWriter)
        }
        if let oldWriter = previous.writer {
            MeshStore.log("begin while recording; the previous recording was flushed and closed")
            if let batch = previous.batch { submit(batch) }
            oldWriter.close()
        }
        MeshStore.log("recording began in \(folder.url.lastPathComponent), mode \(profile.mode.rawValue), "
                      + "available \(MemoryProbe.availableBytes() / 1_000_000) MB")
    }

    /// Hub queue. Reads only `frame.timestamp` and runs the flush timer.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        tick(now: frame.timestamp)
    }

    /// Hub queue. Copies every `ARMeshAnchor` (other anchors are ignored).
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor]) {
        record(anchors)
    }

    /// Hub queue. Copies every updated `ARMeshAnchor`, replacing the stored version.
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor]) {
        record(anchors)
    }

    /// Hub queue. Marks removed mesh anchors stale; their data and files are kept.
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        markStale(ids)
    }

    /// Hub queue. Stops recording, writes every dirty anchor, closes the writer, logs the room's
    /// memory line, then calls `completion` on the io queue. Later callbacks are ignored.
    func finishRecording(completion: @escaping () -> Void) {
        let plan = locked { () -> (batch: FlushBatch?, writer: RawScanWriter?, wasRecording: Bool) in
            guard recording else { return (nil, writerValue, false) }
            let batch = takeBatchLocked(reason: .finish)
            recording = false
            return (batch, writerValue, true)
        }
        guard let writer = plan.writer else {
            completion()
            return
        }
        guard plan.wasRecording else {
            // Already finished: complete after whatever that finish queued.
            writer.flush(completion: completion)
            return
        }
        if let batch = plan.batch { submit(batch) }
        writer.close()
        writer.flush { [weak self] in
            self?.logRoomSummary()
            completion()
        }
    }

    /// Hub queue. Flushes every dirty anchor now (memory pressure, 3.21), without finishing.
    func flushNow() {
        let batch = locked { () -> FlushBatch? in
            guard recording else { return nil }
            return takeBatchLocked(reason: .now)
        }
        guard let batch else { return }
        submit(batch)
        MeshStore.log("flushNow: \(batch.chunks.count) dirty anchors queued")
    }

    /// Mesh anchors held (stale ones included), their face count and failed writes.
    var stats: RecorderStats {
        let snapshot = locked { (anchors: indexValue.count, faces: faceTotal, writer: writerValue) }
        var result = RecorderStats()
        result.meshAnchors = snapshot.anchors
        result.meshFaces = snapshot.faces
        result.writeFailures = snapshot.writer?.failureCount ?? 0
        return result
    }

    // MARK: - Index, chunks, memory

    /// One entry per anchor of the current (or last) recording; kept after `evict()`.
    var index: [UUID: MeshChunkIndexEntry] {
        locked { indexValue }
    }

    /// Copies of the live chunks in first-seen order (build 5 CoverageLive); empty after eviction.
    func currentChunks() -> [MeshChunk] {
        locked { anchorOrder.compactMap { chunkStore[$0] } }
    }

    /// D17: after finish, drop geometry from RAM; keep the index. Ignored (and logged) while
    /// recording, because unwritten versions would be lost.
    func evict() {
        let result = locked { () -> (anchors: Int, bytes: Int)? in
            guard !recording else { return nil }
            let freed = (anchors: chunkStore.count, bytes: residentTotal)
            chunkStore = [:]
            residentTotal = 0
            dirtyIDs = []
            for id in anchorOrder {
                indexValue[id]?.isEvicted = true
            }
            return freed
        }
        guard let result else {
            MeshStore.log("evict ignored while recording")
            return
        }
        MeshStore.log("evicted \(result.anchors) anchors, freed \(result.bytes / 1_000_000) MB, "
                      + "available \(MemoryProbe.availableBytes() / 1_000_000) MB")
    }

    /// Resident geometry bytes (logged per room).
    var residentBytes: Int {
        locked { residentTotal }
    }

    // MARK: - Ingest (internal entry point, also used by the self-test)

    /// True between `beginRecording` and `finishRecording` (any queue).
    var isRecording: Bool {
        locked { recording }
    }

    /// Stores a copied chunk as the latest version of its anchor and marks it dirty. The store
    /// assigns the update count (previous plus 1), computes world-space bounds, and clears the
    /// stale flag of an anchor that came back. Chunks without faces are skipped (an empty copy
    /// never replaces good data), and nothing is stored while not recording.
    func ingest(_ chunk: MeshChunk) {
        guard chunk.faceCount > 0, !chunk.positions.isEmpty else {
            locked { counters.emptyUpdates += 1 }
            return
        }
        let bounds = MeshStore.worldBounds(of: chunk)
        let bytes = MeshStore.residentBytes(of: chunk)
        let low = bounds.isEmpty ? SIMD3<Float>.zero : bounds.min
        let high = bounds.isEmpty ? SIMD3<Float>.zero : bounds.max
        locked { () -> Void in
            guard recording else {
                counters.ignoredWhileIdle += 1
                return
            }
            let id = chunk.anchorID
            let previous = indexValue[id]
            var stored = chunk
            stored.updateCount = MeshStore.nextUpdateCount(after: previous?.updateCount ?? 0)
            if let old = chunkStore[id] {
                residentTotal -= MeshStore.residentBytes(of: old)
            }
            if previous == nil {
                anchorOrder.append(id)
            }
            faceTotal += stored.faceCount - (previous?.faceCount ?? 0)
            residentTotal += bytes
            chunkStore[id] = stored
            indexValue[id] = MeshChunkIndexEntry(anchorID: id, updateCount: stored.updateCount,
                                                 faceCount: stored.faceCount, vertexCount: stored.positions.count,
                                                 boundsMin: low, boundsMax: high,
                                                 isStale: false, isDirty: true, isEvicted: false)
            dirtyIDs.insert(id)
        }
    }

    /// Marks known anchors stale (ARKit removed them). Data, index entry and file stay.
    func markStale(_ ids: [UUID]) {
        locked { () -> Void in
            guard recording else { return }
            for id in ids where indexValue[id] != nil {
                indexValue[id]?.isStale = true
                counters.staleMarks += 1
            }
        }
    }

    // MARK: - Helpers

    /// Hub queue. Copies each mesh anchor inside the call and ingests the copy; times the call.
    private func record(_ anchors: [ARAnchor]) {
        guard isRecording else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        var copied = 0
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let next = nextUpdateCount(for: meshAnchor.identifier)
            ingest(MeshAnchorCopier.copy(meshAnchor, updateCount: next))
            copied += 1
        }
        guard copied > 0 else { return }
        noteCallbackTime(DispatchTime.now().uptimeNanoseconds &- started, anchors: copied)
    }

    /// The update count the next version of `id` gets.
    private func nextUpdateCount(for id: UUID) -> UInt32 {
        locked { MeshStore.nextUpdateCount(after: indexValue[id]?.updateCount ?? 0) }
    }

    /// Tracks the slowest anchor callback and logs the first slow one of a recording.
    private func noteCallbackTime(_ nanos: UInt64, anchors: Int) {
        let logNow = locked { () -> Bool in
            if nanos > counters.slowestCallbackNanos { counters.slowestCallbackNanos = nanos }
            guard nanos > MeshStore.slowCallbackNanos, !counters.loggedSlowCallback else { return false }
            counters.loggedSlowCallback = true
            return true
        }
        if logNow {
            MeshStore.log("slow anchor callback: \(nanos / 1_000_000) ms for \(anchors) anchors")
        }
    }

    /// Runs `body` while holding `lock`.
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// `value + 1`, saturating at `UInt32.max`.
    static func nextUpdateCount(after value: UInt32) -> UInt32 {
        value == UInt32.max ? value : value + 1
    }

    /// World-space bounds of a chunk (its transform applied); non-finite points are skipped, so
    /// a chunk without finite points gives `AABB3.empty`.
    static func worldBounds(of chunk: MeshChunk) -> AABB3 {
        var box = AABB3.empty
        let transform = chunk.transform
        for point in chunk.positions {
            let moved = simd_mul(transform, SIMD4<Float>(point, 1))
            let world = SIMD3<Float>(moved.x, moved.y, moved.z)
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }
            box.expand(world)
        }
        return box
    }

    /// Bytes a chunk's arrays occupy in RAM (SIMD3 elements use their 16-byte stride).
    static func residentBytes(of chunk: MeshChunk) -> Int {
        let vectorStride = MemoryLayout<SIMD3<Float>>.stride
        let vertexBytes = (chunk.positions.count + chunk.normals.count) * vectorStride
        let indexBytes = chunk.indices.count * MemoryLayout<UInt32>.stride
        return vertexBytes + indexBytes + chunk.classes.count
    }

    /// Writes one line with category "capture" and the "mesh: " prefix.
    static func log(_ message: String) {
        LogStore.shared.write("mesh: " + message, category: "capture")
    }
}
