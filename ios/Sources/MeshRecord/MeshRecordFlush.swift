import Foundation

/// Flush machinery of `MeshStore` (D8): the 3 s timer, dirty batches taken on the hub queue as
/// values, encoding and atomic writes inside `RawScanWriter.perform` on the io queue, a per
/// recording ledger so an older version never overwrites a newer file, and bounded retries of
/// failed writes.
extension MeshStore {
    /// Why a batch was taken.
    enum FlushReason: String {
        /// The 3 s timer (`tick(now:)`).
        case timer
        /// `flushNow()` (memory pressure).
        case now
        /// `finishRecording(completion:)`, the final flush.
        case finish
        /// `beginRecording` while a recording was still running.
        case restart
    }

    /// Dirty chunks handed to the io queue as values, with the writer, folder and ledger of the
    /// recording they belong to.
    struct FlushBatch {
        /// Latest versions of the dirty anchors, anchor-local (D8), in first-seen order.
        var chunks: [MeshChunk]
        /// Scan folder of the recording.
        var folder: RawScanFolder
        /// Writer of the recording.
        var writer: RawScanWriter
        /// Versions already on disk for the recording.
        var ledger: FlushLedger
        /// `MeshStore.generation` when the batch was taken.
        var generation: Int
        /// Why the batch was taken.
        var reason: FlushReason
    }

    /// One failed chunk write.
    struct FailedWrite {
        /// Anchor of the chunk.
        var anchorID: UUID
        /// Version that failed.
        var updateCount: UInt32
    }

    /// What a batch did on the io queue.
    struct FlushOutcome {
        /// Recording and reason of the batch.
        var generation: Int, reason: FlushReason
        /// Anchors written.
        var written: [UUID] = []
        /// Writes that failed (counted by the writer too).
        var failed: [FailedWrite] = []
        /// Bytes written.
        var bytes = 0
        /// Chunks skipped because the same or a newer version was already on disk.
        var skipped = 0
        /// True when the scan folder no longer existed (discarded or deleted), so nothing was written.
        var folderMissing = false

        /// An empty outcome for a batch.
        init(generation: Int, reason: FlushReason) {
            self.generation = generation
            self.reason = reason
        }
    }

    /// Highest update count on disk per anchor for one recording. Touched only on the io queue
    /// (inside `RawScanWriter.perform`), which is serial.
    final class FlushLedger {
        /// Highest version written per anchor.
        private var written: [UUID: UInt32] = [:]

        /// True when this version or a newer one of the anchor is already on disk.
        func isWritten(_ chunk: MeshChunk) -> Bool {
            guard let last = written[chunk.anchorID] else { return false }
            return last >= chunk.updateCount
        }

        /// Records a successful write.
        func markWritten(_ chunk: MeshChunk) {
            written[chunk.anchorID] = chunk.updateCount
        }
    }

    // MARK: - Timer

    /// True when a timed flush should run at frame time `now`: recording, something dirty, no
    /// timed batch still waiting on the io queue, and at least `flushInterval` seconds since the
    /// last timed flush (or the scan start).
    func flushDue(now: TimeInterval) -> Bool {
        locked { flushDueLocked(now: now) }
    }

    /// Hub queue (every frame). Starts the timer on the first frame (or when frame time goes
    /// backwards) and submits a timed batch when `flushDue(now:)`.
    func tick(now: TimeInterval) {
        let batch = locked { () -> FlushBatch? in
            guard recording else { return nil }
            guard let last = lastFlushTime, now >= last else {
                lastFlushTime = now
                return nil
            }
            guard flushDueLocked(now: now) else { return nil }
            lastFlushTime = now
            return takeBatchLocked(reason: .timer)
        }
        if let batch { submit(batch) }
    }

    /// `flushDue(now:)` while holding the lock.
    func flushDueLocked(now: TimeInterval) -> Bool {
        guard recording, !dirtyIDs.isEmpty, timedFlushesInFlight < MeshStore.maxTimedFlushesInFlight else {
            return false
        }
        guard let last = lastFlushTime else { return false }
        return now - last >= MeshStore.flushInterval
    }

    // MARK: - Batches

    /// Holding the lock: takes every dirty anchor as a value batch and clears the dirty flags.
    /// Nil when nothing is dirty or no recording was begun.
    func takeBatchLocked(reason: FlushReason) -> FlushBatch? {
        guard !dirtyIDs.isEmpty, let folder = folderValue, let writer = writerValue, let ledger = ledgerValue else {
            return nil
        }
        var chunks: [MeshChunk] = []
        chunks.reserveCapacity(dirtyIDs.count)
        for id in anchorOrder where dirtyIDs.contains(id) {
            if let chunk = chunkStore[id] { chunks.append(chunk) }
            indexValue[id]?.isDirty = false
        }
        dirtyIDs = []
        if reason == .timer { timedFlushesInFlight += 1 }
        counters.flushes += 1
        return FlushBatch(chunks: chunks, folder: folder, writer: writer, ledger: ledger,
                          generation: generation, reason: reason)
    }

    /// Any queue, never holding the lock. Queues the batch on the writer: inside `perform` (io
    /// queue) the `mesh/` folder is ensured while the scan folder exists, then each chunk is
    /// encoded and written atomically, then the outcome is recorded.
    func submit(_ batch: FlushBatch) {
        batch.writer.perform { [weak self] in
            do {
                try ProjectStore.ensureDirectory(batch.folder.meshURL, inside: batch.folder.url)
            } catch {
                var outcome = FlushOutcome(generation: batch.generation, reason: batch.reason)
                outcome.folderMissing = true
                self?.batchCompleted(outcome)
                throw error
            }
            let outcome = MeshStore.writeChunks(batch)
            self?.batchCompleted(outcome)
        }
    }

    /// Io queue (inside `perform`, so each `writeFile` runs at once). Encodes and writes each
    /// chunk not already on disk; a write counts as failed when the writer's failure count grew.
    static func writeChunks(_ batch: FlushBatch) -> FlushOutcome {
        var outcome = FlushOutcome(generation: batch.generation, reason: batch.reason)
        for chunk in batch.chunks {
            if batch.ledger.isWritten(chunk) {
                outcome.skipped += 1
                continue
            }
            let data = MeshChunkFile.encode(chunk)
            let failuresBefore = batch.writer.failureCount
            batch.writer.writeFile(data, to: batch.folder.meshChunkURL(anchor: chunk.anchorID))
            if batch.writer.failureCount == failuresBefore {
                batch.ledger.markWritten(chunk)
                outcome.written.append(chunk.anchorID)
                outcome.bytes += data.count
            } else {
                outcome.failed.append(FailedWrite(anchorID: chunk.anchorID, updateCount: chunk.updateCount))
            }
        }
        return outcome
    }

    /// Io queue. Updates the counters of the batch's recording; while it is still recording,
    /// an anchor whose write failed is marked dirty again (up to `maxWriteRetries` in a row)
    /// unless a newer version arrived meanwhile; after finish its index entry is only flagged
    /// dirty. Outcomes of an earlier recording are ignored.
    func batchCompleted(_ outcome: FlushOutcome) {
        let logMissing = locked { () -> Bool in
            guard outcome.generation == generation else { return false }
            if outcome.reason == .timer, timedFlushesInFlight > 0 { timedFlushesInFlight -= 1 }
            counters.filesWritten += outcome.written.count
            counters.bytesWritten += Int64(outcome.bytes)
            for id in outcome.written { retryCounts[id] = nil }
            if outcome.folderMissing {
                counters.missingFolderBatches += 1
                return counters.missingFolderBatches == 1
            }
            for failure in outcome.failed {
                if recording {
                    retryIfCurrentLocked(failure)
                } else if indexValue[failure.anchorID]?.updateCount == failure.updateCount {
                    // Finished: no more writes, but the index stays honest about what is on disk.
                    indexValue[failure.anchorID]?.isDirty = true
                }
            }
            return false
        }
        if logMissing {
            MeshStore.log("scan folder missing (discarded or deleted); mesh chunks not written")
        }
    }

    /// Holding the lock: marks the anchor dirty again when the failed version is still its
    /// latest, it is in RAM and it has not failed `maxWriteRetries` times in a row.
    private func retryIfCurrentLocked(_ failure: FailedWrite) {
        let id = failure.anchorID
        let tries = (retryCounts[id] ?? 0) + 1
        retryCounts[id] = tries
        guard tries <= MeshStore.maxWriteRetries, chunkStore[id] != nil,
              let entry = indexValue[id], entry.updateCount == failure.updateCount else { return }
        indexValue[id]?.isDirty = true
        dirtyIDs.insert(id)
        counters.writeRetries += 1
    }

    /// Any queue. Calls `completion` on the io queue after every write queued so far (at once
    /// when no recording was ever begun).
    func flushWrites(completion: @escaping () -> Void) {
        guard let writer = locked({ writerValue }) else {
            completion()
            return
        }
        writer.flush(completion: completion)
    }

    // MARK: - Logs

    /// Io queue, after the final flush. The per-room memory line (D17): anchors, faces, files,
    /// bytes, failures, `residentBytes` and `MemoryProbe.availableBytes()`.
    func logRoomSummary() {
        let summary = locked { () -> String in
            let stale = indexValue.values.filter { $0.isStale }.count
            let folderName = folderValue?.url.lastPathComponent ?? "-"
            let written = counters.bytesWritten / 1_000_000
            let slowest = counters.slowestCallbackNanos / 1_000_000
            let part1 = "room finished in \(folderName): \(indexValue.count) anchors (\(stale) stale), \(faceTotal) faces, "
            let part2 = "\(counters.filesWritten) files, \(written) MB written in \(counters.flushes) flushes, "
            let part3 = "\(counters.writeRetries) retries, \(counters.emptyUpdates) empty copies, "
            let part4 = "\(counters.ignoredWhileIdle) ignored while idle, slowest callback \(slowest) ms, "
            let part5 = "resident \(residentTotal / 1_000_000) MB"
            return part1 + part2 + part3 + part4 + part5
        }
        let failures = locked({ writerValue })?.failureCount ?? 0
        let available = MemoryProbe.availableBytes() / 1_000_000
        MeshStore.log(summary + ", \(failures) write failures, available \(available) MB")
    }
}
