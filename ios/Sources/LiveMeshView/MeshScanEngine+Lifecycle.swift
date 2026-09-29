import Foundation
import ARKit

// Hub-queue side of MeshScanEngine (docs/MODULES.md 3.32): recording start, frames (scan start,
// camera transform, frame gaps), the 4 Hz status tick with guidance and snapshot, capture events
// and interruptions, memory warnings, pause and resume, engine-initiated finishes (heat, storage,
// memory, session failure) and the start of the finish and abandon sequences. Every method here
// runs on `hub.queue` unless its comment says otherwise; `q` is touched only here and in the
// finish sequence's hub-queue hops.

extension MeshScanEngine {
    // MARK: - Recording start

    /// Main (hops to the hub queue). Stores the folder and writer, writes the events that arrived
    /// before them, begins every recorder and attaches it, in that order, so no hub callback
    /// reaches a recorder before `beginRecording`. State `.starting`.
    func beginRecordingOnQueue(folder: RawScanFolder, writer: RawScanWriter) {
        hub.queue.async { [weak self] in
            guard let self else { return }
            self.q.folder = folder
            self.q.writer = writer
            self.q.phase = MeshScanStats.next(self.q.phase, on: .start)
            for event in self.q.pendingEvents { writer.appendJSONLine(event, to: folder.eventsLogURL) }
            self.q.pendingEvents = []
            let profile = self.target.profile
            let startTimestamp = self.q.latestFrameTimestamp ?? 0
            for recorder in self.recorders {
                recorder.beginRecording(into: folder, profile: profile, startTimestamp: startTimestamp)
                self.hub.attach(recorder)
            }
            self.setKeyframesPaused(false)
            let owner = self.ownsHub ? "owned" : "borrowed"
            self.appendEngineEvent(.note, "mesh pass \(self.target.passID) recording started, kind "
                                   + "\(self.target.kind.rawValue), mode \(self.target.mode.rawValue), \(owner) hub")
        }
    }

    // MARK: - Hub closures

    /// Every frame: latest timestamp and arrival time (a frame ends a gap), the camera transform at
    /// most 10 times a second, and the scan start at the first frame of the pass. Reads only
    /// value facts; the frame is never kept.
    func handleFrame(_ frame: ARFrame) {
        let timestamp = frame.timestamp
        q.latestFrameTimestamp = timestamp
        q.lastFrameUptime = ProcessInfo.processInfo.systemUptime
        if q.gapReapplyTried {
            q.gapReapplyTried = false
            MeshScanLog.write("frames arrive again after the gap")
        }
        if MeshScanStats.isDue(now: timestamp, last: q.lastCameraTimestamp, interval: MeshScanEngine.cameraUpdateInterval) {
            q.lastCameraTimestamp = timestamp
            storeCameraTransform(frame.camera.transform)
        }
        if q.scanStartTimestamp == nil && MeshScanStats.isCapturing(q.phase) {
            markScanStart(timestamp)
        }
    }

    /// One status tick (4 Hz; about 1 Hz while frames are missing): system stops, the memory low
    /// note, the frame gap rule, guidance (mesh-mode input, augmenter, engine), and the snapshot
    /// (augmenter) to main.
    func handleStatus(_ status: HubStatus) {
        guard MeshScanStats.isCapturing(q.phase) else { return }
        if !q.finishStarted, var reason = MeshScanStats.systemStopReason(thermal: status.thermal,
                                                                             storage: status.storage,
                                                                             memory: status.memory) {
            if case .lowStorage = reason { reason = .lowStorage(freeBytes: status.freeBytes) }
            beginFinish(systemStop: reason, reason: "system stop \(reason.copyKey)", attachments: [:])
            return
        }
        if status.memory == .low && !q.memoryLowLogged {
            q.memoryLowLogged = true
            appendEngineEvent(.memory, "memory low, available \(status.availableMemory / 1_000_000) MB; keyframes stop")
        } else if status.memory == .ok {
            q.memoryLowLogged = false
        }
        let now = ProcessInfo.processInfo.systemUptime
        checkFrameGap(now: now)
        var input = MeshScanStats.guidanceInput(time: now, status: status)
        if let augment = guidanceAugmenter { augment(&input) }
        let output = q.guidance.update(input)
        let stats = recorders.reduce(RecorderStats()) { $0 + $1.stats }
        var snapshot = MeshScanStats.snapshot(timestamp: q.latestFrameTimestamp ?? 0, status: status,
                                              recorders: stats, guidance: output.message)
        if let augment = snapshotAugmenter { augment(&snapshot) }
        publish(state: nil, events: [.snapshot(snapshot)])
    }

    /// Hub events: written to events.jsonl; interruptions pause the engine (it stays paused after
    /// the interruption ends, until `resume()`); a session failure finishes the pass with what
    /// exists and reports `.trackingFailed` after `.roomFinished`.
    func handleCaptureEvent(_ event: CaptureEvent) {
        recordEvent(event)
        if event.kind == .tracking && event.detail == ARSessionHub.interruptedDetail {
            if MeshScanStats.isCapturing(q.phase) { applyPause(reason: "session interrupted") }
        } else if event.kind == .tracking && event.detail == ARSessionHub.interruptionEndedDetail {
            let next = MeshScanStats.next(q.phase, on: .interruptionEnded)
            MeshScanLog.write("interruption ended; engine stays \(next.rawValue) until Resume")
        } else if event.kind == .error && event.detail.hasPrefix(ARSessionHub.sessionFailedPrefix) {
            guard MeshScanStats.isCapturing(q.phase), !q.finishStarted else { return }
            q.pendingNotice = .trackingFailed
            beginFinish(systemStop: nil, reason: "ARSession failed", attachments: [:])
        }
    }

    /// iOS memory warning (forwarded by the hub): every recorder flushes and the pass finishes as
    /// a system stop with `.lowMemory` (D17).
    func handleMemoryPressure() {
        guard MeshScanStats.isCapturing(q.phase), !q.finishStarted else { return }
        beginFinish(systemStop: .lowMemory, reason: "memory warning", attachments: [:])
    }

    // MARK: - Pause, resume, finish, abandon

    /// Pauses (state and keyframes; the session keeps running).
    func applyPause(reason: String) {
        let next = MeshScanStats.next(q.phase, on: .pause)
        guard next != q.phase else { return }
        q.phase = next
        setKeyframesPaused(true)
        appendEngineEvent(.note, "paused: \(reason)")
        publish(state: next, events: [.stateChanged(next)])
    }

    /// Back to scanning after `pause()` or an interruption.
    func applyResume() {
        let next = MeshScanStats.next(q.phase, on: .resume)
        guard next != q.phase else { return }
        q.phase = next
        setKeyframesPaused(false)
        appendEngineEvent(.note, "resumed")
        publish(state: next, events: [.stateChanged(next)])
    }

    /// Starts a finish: Done (`systemStop` nil) or the engine itself (heat, storage, memory, a
    /// session failure). A memory stop first calls `flushNow()` on every recorder. Emits
    /// `.stateChanged(.stopping)` and launches the finish sequence.
    func beginFinish(systemStop: MapperError?, reason: String, attachments: [String: Data]) {
        guard MeshScanStats.isCapturing(q.phase), !q.finishStarted, q.abandon == nil else {
            MeshScanLog.write("finish (\(reason)) ignored in state \(q.phase.rawValue)")
            return
        }
        guard let folder = q.folder, let writer = q.writer else {
            MeshScanLog.write("finish (\(reason)) without a pass folder; nothing to seal")
            q.phase = MeshScanStats.next(q.phase, on: .failure)
            publish(state: .failed, events: [.stateChanged(.failed), .failed(.ioFailed("mesh pass folder missing at finish"))])
            return
        }
        q.phase = MeshScanStats.next(q.phase, on: .finish)
        q.systemStop = systemStop
        if systemStop == .lowMemory {
            for recorder in recorders { recorder.flushNow() }
        }
        appendEngineEvent(.note, "finish requested: \(reason)")
        MeshScanLog.write("finish requested (\(reason)), \(attachments.count) attachments: "
                          + MeshScanLog.deviceLine(storage: false))
        publish(state: .stopping, events: [.stateChanged(.stopping)])
        let context = makeFinishContext(folder: folder, writer: writer, attachments: attachments)
        q.finishStarted = true
        Task { [self] in await self.runFinishSequence(context) }
    }

    /// Starts a cancel or discard. While capturing: the ordered stop in a task. While a finish
    /// runs: the finish sequence abandons before sealing. Otherwise: `.stateChanged(.idle)` (a
    /// discard also removes an unsealed InProgress folder, for example after a failed seal).
    func beginAbandon(_ kind: MeshAbandonKind) {
        if let existing = q.abandon {
            if kind == .discard && existing == .cancel { q.abandon = .discard }
            return
        }
        switch q.phase {
        case .idle, .finished, .failed:
            if kind == .discard, !q.sealed, !q.discarded, q.folder != nil {
                q.discarded = true
                let scanID = target.passID
                RawScanWriter.ioQueue.async { MeshScanEngine.discardInProgress(scanID) }
            }
            q.phase = MeshScanStats.next(q.phase, on: .cancel)
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        case .stopping where q.finishStarted:
            q.abandon = kind
            MeshScanLog.write("\(kind.rawValue) requested during the finish sequence; it stops before the seal")
            return
        case .starting, .scanning, .paused, .stopping:
            q.abandon = kind
            q.phase = .stopping
        }
        guard let writer = q.writer else {
            q.phase = MeshScanStats.next(q.phase, on: .cancel)
            q.abandon = nil
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        }
        q.finishStarted = true
        appendEngineEvent(.note, "capture \(kind == .discard ? "discarded" : "cancelled")")
        Task { [self] in await self.runAbandonSequence(writer: writer) }
    }

    // MARK: - Small helpers (hub queue)

    /// The first frame of the pass: phase `.scanning` (unless paused), guidance reset, and the
    /// hub's scan start (watchdogs, elapsed time, tracking history).
    func markScanStart(_ timestamp: TimeInterval) {
        q.scanStartTimestamp = timestamp
        q.guidance.reset()
        let next = MeshScanStats.next(q.phase, on: .firstFrame)
        let changed = next != q.phase
        q.phase = next
        if changed { publish(state: next, events: [.stateChanged(next)]) }
        MeshScanLog.write("first frame of pass \(target.passID); scan start")
        hub.markScanStart(timestamp: timestamp)
    }

    /// The frame gap rule: while scanning, more than `frameGapSeconds` without a frame re-applies
    /// the configuration once per gap (for example after RoomPlan objects of a borrowed session
    /// were released) and logs it.
    func checkFrameGap(now: TimeInterval) {
        guard MeshScanStats.shouldReapplyForFrameGap(now: now, lastFrame: q.lastFrameUptime,
                                                     triedForThisGap: q.gapReapplyTried,
                                                     isScanning: q.phase == .scanning) else { return }
        q.gapReapplyTried = true
        let gap = now - (q.lastFrameUptime ?? now)
        let text = "no frame for \(String(format: "%.1f", gap)) s; re-applying the configuration"
        appendEngineEvent(.config, text)
        MeshScanLog.write(text)
        hub.reapplyConfiguration(reason: "mesh pass frame gap")
    }

    /// Pauses or resumes every `KeyframeRecorder` among the recorders.
    func setKeyframesPaused(_ paused: Bool) {
        for recorder in recorders {
            if let keyframes = recorder as? KeyframeRecorder { keyframes.isPaused = paused }
        }
    }

    /// Writes an event to events.jsonl (buffered before the writer exists, dropped after its
    /// close was requested).
    func recordEvent(_ event: CaptureEvent) {
        if let writer = q.writer, let folder = q.folder {
            guard !q.writerCloseRequested else { return }
            writer.appendJSONLine(event, to: folder.eventsLogURL)
        } else if q.pendingEvents.count < MeshScanEngine.maxPendingEvents {
            q.pendingEvents.append(event)
        }
    }

    /// An engine event with `t` seconds since the scan start.
    func appendEngineEvent(_ kind: CaptureEventKind, _ detail: String) {
        let t = MeshScanStats.elapsed(start: q.scanStartTimestamp, latest: q.latestFrameTimestamp)
        recordEvent(CaptureEvent(t: t, kind: kind, detail: detail))
    }

    /// Copies everything the finish sequence needs (hub-queue values: tracking history, degraded
    /// mode, diagnostics).
    func makeFinishContext(folder: RawScanFolder, writer: RawScanWriter, attachments: [String: Data]) -> MeshFinishContext {
        let seconds = MeshScanStats.elapsed(start: q.scanStartTimestamp, latest: q.latestFrameTimestamp)
        let degraded = hub.degraded
        let log = MeshScanStats.log(seconds: seconds, relocalizations: hub.tracking.relocalizations,
                                    limitedFraction: hub.tracking.limitedFraction, degraded: degraded,
                                    error: q.systemStop?.copyKey)
        let stopName = q.systemStop?.copyKey ?? "none"
        let noticeName = q.pendingNotice?.copyKey ?? "none"
        let finalEvents = [CaptureEvent(t: seconds, kind: .note,
                                        detail: "mesh pass ended, system stop \(stopName), notice \(noticeName), "
                                            + "degraded \(degraded.rawValue)")]
        return MeshFinishContext(target: target, folder: folder, writer: writer, attachments: attachments,
                                 systemStop: q.systemStop,
                                 notice: MeshScanStats.notice(systemStop: q.systemStop, pending: q.pendingNotice),
                                 log: log, sessionRecord: hub.diagnostics.sessionRecord(id: target.sessionID),
                                 finalEvents: finalEvents)
    }

    /// Deletes an InProgress folder (the caller closed the writer first). Logged, never thrown.
    static func discardInProgress(_ scanID: UUID) {
        do {
            try InProgressScans.discard(scanID: scanID)
        } catch {
            MeshScanLog.write("discard of scan \(scanID) failed: \(MeshScanStats.describe(error))")
        }
    }
}
