import Foundation

// The finish and abandon sequences of MeshScanEngine (docs/MODULES.md 3.32): one ordered task
// over `MeshScanStats.finishSteps` inside a background task, and the ordered stop of cancel and
// discard. Every raw write goes through the pass's `RawScanWriter` (createParents false); the
// recorders flush and close their own writers in `finishRecording`, which is awaited before the
// seal; nothing is written into the folder after the writer is closed, and the seal comes after
// the close, so no file follows SEAL.json and `.roomFinished` never precedes the seal.

/// Values the finish sequence needs, copied on the hub queue when the finish started.
struct MeshFinishContext {
    /// The pass and its project.
    var target: MeshScanTarget
    /// The InProgress folder.
    var folder: RawScanFolder
    /// The pass's writer.
    var writer: RawScanWriter
    /// Extra files for the folder root (names already checked).
    var attachments: [String: Data]
    /// Why the engine finished the pass itself (heat, storage, memory), if it did.
    var systemStop: MapperError?
    /// The `.failed` event sent after `.roomFinished`, if any.
    var notice: MapperError?
    /// Contents of roomlog.json.
    var log: RoomCaptureLog
    /// Contents of session.json (written only when the session has none yet).
    var sessionRecord: CaptureSessionRecord
    /// The last events.jsonl lines.
    var finalEvents: [CaptureEvent]
}

extension MeshScanEngine {
    // MARK: - Finish sequence

    /// The finish sequence, in the order of `MeshScanStats.finishSteps`, inside a background task.
    /// A cancel or discard that arrives before the seal abandons the pass instead; one that arrives
    /// after the seal reports `.stateChanged(.idle)` instead of `.roomFinished`.
    func runFinishSequence(_ context: MeshFinishContext) async {
        let background = await MeshScanBackgroundTask.begin(name: "mapper.meshpass.finish")
        MeshScanLog.write("finish sequence for pass \(context.target.passID): " + MeshScanLog.deviceLine())
        var stats = RecorderStats()
        for step in MeshScanStats.finishSteps {
            switch step {
            case .detachRecorders:
                await detachRecorders()
            case .finishRecorders:
                stats = await finishRecorders()
            case .writeAttachments:
                writeAttachments(context)
            case .writeLogs:
                writeLogs(context)
            case .flushWriter:
                await context.writer.flush()
            case .closeWriter:
                await closeWriter(context.writer)
            case .seal:
                if let kind = await onHubQueue({ self.q.abandon }) {
                    await completeAbandon(kind)
                    await background.end()
                    return
                }
                if let failure = await seal(context) {
                    await failSeal(context, reason: failure)
                    await background.end()
                    return
                }
            case .pauseIfSystemStop:
                if context.systemStop != nil {
                    await onMain { self.hub.pause() }
                    MeshScanLog.write("session paused after a system stop (owned hub \(self.ownsHub))")
                }
            case .emitRoomFinished:
                await emitRoomFinished(context, stats: stats)
            }
        }
        await background.end()
    }

    /// Step 1: detaches every recorder on the hub queue, so no callback arrives after this.
    func detachRecorders() async {
        await onHubQueue {
            for recorder in self.recorders { self.hub.detach(recorder) }
        }
    }

    /// Step 2: `finishRecording(completion:)` on the hub queue for each recorder, awaited in turn
    /// (at most `recorderFinishTimeout` each; every recorder flushes and closes its own writer),
    /// then `releaseMemory()` (D17); returns the final counters.
    func finishRecorders() async -> RecorderStats {
        let hub = self.hub
        for recorder in recorders {
            let name = String(describing: type(of: recorder))
            let finished = await MeshScanAsync.withTimeout(seconds: MeshScanEngine.recorderFinishTimeout,
                                                           fallback: false) { finish in
                hub.queue.async {
                    recorder.finishRecording { finish(true) }
                }
            }
            if !finished {
                MeshScanLog.write("recorder \(name) did not finish within \(Int(MeshScanEngine.recorderFinishTimeout)) s")
            }
        }
        return await onHubQueue {
            for recorder in self.recorders { recorder.releaseMemory() }
            return self.recorders.reduce(RecorderStats()) { $0 + $1.stats }
        }
    }

    /// Step 3: each attachment written at the folder root (names were checked in `finish`; the
    /// path is resolved inside the folder once more).
    func writeAttachments(_ context: MeshFinishContext) {
        for name in context.attachments.keys.sorted() {
            guard let data = context.attachments[name] else { continue }
            guard MeshScanStats.isSafeAttachmentName(name), let url = context.folder.resolve(name) else {
                MeshScanLog.write("attachment skipped: unsafe name")
                continue
            }
            context.writer.writeFile(data, to: url)
        }
        if !context.attachments.isEmpty {
            MeshScanLog.write("\(context.attachments.count) attachments queued")
        }
    }

    /// Step 4: roomlog.json, the last events.jsonl lines and raw/sessions/<s>/session.json when the
    /// session has none yet (its folder exists since `start()`; made again if needed, only inside
    /// an existing package).
    func writeLogs(_ context: MeshFinishContext) {
        let writer = context.writer
        do {
            writer.writeFile(try ProjectStore.encoder.encode(context.log), to: context.folder.roomLogURL)
        } catch {
            MeshScanLog.write("roomlog.json not encoded: \(MeshScanStats.describe(error))")
        }
        for event in context.finalEvents {
            writer.appendJSONLine(event, to: context.folder.eventsLogURL)
        }
        let package = context.target.package
        let sessionID = context.target.sessionID
        guard !StoreFiles.exists(package.sessionRecordURL(sessionID)) else { return }
        do {
            try ProjectStore.ensureDirectory(package.sessionURL(sessionID), inside: package.root)
            writer.writeFile(try ProjectStore.encoder.encode(context.sessionRecord), to: package.sessionRecordURL(sessionID))
        } catch {
            MeshScanLog.write("session.json not written: \(MeshScanStats.describe(error))")
        }
    }

    /// Step 6: no write is queued after this; returns once the close ran on the io queue.
    func closeWriter(_ writer: RawScanWriter) async {
        await onHubQueue { self.q.writerCloseRequested = true }
        writer.close()
        await writer.flush()
        MeshScanLog.write("writer closed: \(writer.bytesWritten) bytes, \(writer.failureCount) failures, "
                          + "\(writer.droppedAfterClose) dropped")
    }

    /// Step 7: seals and moves the folder into the package on the io queue. Returns nil on
    /// success, else the failure text (the folder then stays in InProgress for recovery).
    func seal(_ context: MeshFinishContext) async -> String? {
        let package = context.target.package
        let folder = context.folder
        let destination = context.target.destination
        let failure: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            RawScanWriter.ioQueue.async {
                do {
                    try InProgressScans.seal(folder, into: destination, package: package)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: StoreFiles.describe(error))
                }
            }
        }
        if let failure {
            MeshScanLog.write("seal of pass \(context.target.passID) failed: \(failure)")
            return failure
        }
        await onHubQueue { self.q.sealed = true }
        return nil
    }

    /// A failed seal: pauses the session after a system stop, then `.failed(.ioFailed)` (raw
    /// stays in InProgress for recovery; `.roomFinished` is never sent without a seal).
    func failSeal(_ context: MeshFinishContext, reason: String) async {
        if context.systemStop != nil { await onMain { self.hub.pause() } }
        await onHubQueue { self.q.phase = MeshScanStats.next(self.q.phase, on: .failure) }
        publish(state: .failed, events: [.failed(.ioFailed("seal: \(reason)"))])
    }

    /// Step 9: `lastResult`, `.finished` and `.roomFinished(roomID: passID)`, then the notice
    /// (heat, storage, memory, tracking) as `.failed`; the state stays `.finished`. A cancel or
    /// discard that arrived during the seal gets `.stateChanged(.idle)` instead (the sealed
    /// folder stays in the package).
    func emitRoomFinished(_ context: MeshFinishContext, stats: RecorderStats) async {
        let abandoned = await onHubQueue { () -> MeshAbandonKind? in
            let kind = self.q.abandon
            self.q.abandon = nil
            self.q.phase = MeshScanStats.next(self.q.phase, on: kind == nil ? .sealed : .cancel)
            return kind
        }
        if let kind = abandoned {
            MeshScanLog.write("\(kind.rawValue) arrived during the seal; pass \(context.target.passID) stays sealed")
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        }
        let target = context.target
        let result = MeshScanResult(passID: target.passID, kind: target.kind, roomID: target.roomID,
                                    sealedFolder: RawScanFolder(url: target.destination), log: context.log,
                                    keyframeCount: stats.keyframes, photoCount: stats.photos,
                                    meshFaceCount: stats.meshFaces, frameLink: .projectFrame(sessionID: target.sessionID),
                                    capturedAt: Date(), stoppedBySystem: context.systemStop != nil)
        // As specified (and as RoomCapture): `.roomFinished` then the notice; the state becomes
        // `.finished` in the same main hop, without a separate `.stateChanged` event.
        var events: [ScanEngineEvent] = [.roomFinished(roomID: target.passID)]
        if let notice = context.notice { events.append(.failed(notice)) }
        let counts = "\(stats.meshFaces) faces, \(stats.keyframes) keyframes, \(stats.photos) photos"
        let ending = "degraded \(context.log.degraded.rawValue), system stop \(context.systemStop?.copyKey ?? "none")"
        MeshScanLog.write("pass \(target.passID) finished: \(counts), \(ending); " + MeshScanLog.deviceLine())
        publish(state: .finished, events: events, result: result)
    }

    // MARK: - Abandon sequence (cancel and discard)

    /// Ordered stop without sealing: recorders detached and finished, writer flushed and closed;
    /// then discard (if asked) and `.stateChanged(.idle)`.
    func runAbandonSequence(writer: RawScanWriter) async {
        await detachRecorders()
        _ = await finishRecorders()
        await writer.flush()
        await closeWriter(writer)
        let kind = await onHubQueue { self.q.abandon ?? .cancel }
        await completeAbandon(kind)
    }

    /// After the writer closed: deletes the InProgress folder for a discard (kept for a cancel),
    /// then `.stateChanged(.idle)`.
    func completeAbandon(_ kind: MeshAbandonKind) async {
        let scanID = target.passID
        if kind == .discard {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                RawScanWriter.ioQueue.async {
                    MeshScanEngine.discardInProgress(scanID)
                    continuation.resume()
                }
            }
        }
        await onHubQueue {
            self.q.abandon = nil
            self.q.phase = MeshScanStats.next(self.q.phase, on: .cancel)
            if kind == .discard { self.q.discarded = true }
        }
        MeshScanLog.write(kind == .discard ? "pass \(scanID) discarded" : "pass \(scanID) cancelled; raw kept in InProgress")
        publish(state: .idle, events: [.stateChanged(.idle)])
    }

    // MARK: - Queue hops for the async sequences

    /// Runs `body` on the hub queue and returns its result.
    func onHubQueue<T: Sendable>(_ body: @escaping () -> T) async -> T {
        let queue = hub.queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Runs `body` on the main queue (for the nonisolated main-thread call `hub.pause()`) and
    /// returns when it ran.
    func onMain(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                body()
                continuation.resume()
            }
        }
    }
}
