import Foundation
import ARKit
import RoomPlan

// Hub-queue side of RoomScanEngine (docs/MODULES.md 3.21): room start, RoomPlan callbacks (hopped
// here by RoomCaptureController), hub status ticks with snapshot and guidance, capture events and
// interruptions, pause and resume, engine-initiated finishes (heat, storage, memory) and the
// start of the finish and abandon sequences. Every method here runs on `hub.queue` unless its
// comment says otherwise; `q` is touched only here.

extension RoomScanEngine {
    // MARK: - Room start

    /// Main (hops to the hub queue). Stores the new room's folder and writer, writes the events
    /// that arrived before it, begins every recorder and attaches it, in that order, so no hub
    /// callback reaches a recorder before `beginRecording`.
    func beginRoomOnQueue(_ prepared: PreparedRoom, target: RoomScanTarget) {
        hub.queue.async { [weak self] in
            guard let self else { return }
            let serial = self.q.roomSerial + 1
            let roomsFinished = self.q.roomsFinished
            let latestFrame = self.q.latestFrameTimestamp
            var fresh = RoomEngineQueueState(target: target)
            fresh.roomSerial = serial
            fresh.roomsFinished = roomsFinished
            fresh.latestFrameTimestamp = latestFrame
            fresh.pendingEvents = self.q.pendingEvents
            fresh.scanID = prepared.scanID
            fresh.folder = prepared.folder
            fresh.writer = prepared.writer
            fresh.phase = RoomScanStats.next(self.q.phase, on: .start)
            self.q = fresh
            for event in self.q.pendingEvents { prepared.writer.appendJSONLine(event, to: prepared.folder.eventsLogURL) }
            self.q.pendingEvents = []
            let profile = ScanProfile(mode: target.mode, settings: target.settings)
            let startTimestamp = latestFrame ?? ProcessInfo.processInfo.systemUptime
            for recorder in self.recorders {
                recorder.beginRecording(into: prepared.folder, profile: profile, startTimestamp: startTimestamp)
                self.hub.attach(recorder)
            }
            self.setRecordersPaused(false)
            self.appendEngineEvent(.note, "room \(target.roomID) recording started, scan \(prepared.scanID)")
        }
    }

    // MARK: - Frames, status, events, memory (hub closures)

    /// Latest frame time; marks the scan start when RoomPlan started before the first frame.
    func handleFrameTimestamp(_ timestamp: TimeInterval) {
        q.latestFrameTimestamp = timestamp
        if q.pendingScanStart { markScanStart(timestamp) }
    }

    /// One status tick (4 Hz): engine-initiated finish checks, the memory low note, guidance
    /// (Room mode input, augmenter, engine, coaching filter), the snapshot (augmenter) to main.
    func handleStatus(_ status: HubStatus) {
        guard RoomScanStats.isCapturing(q.phase) else { return }
        if !q.finishStarted, var reason = RoomScanStats.systemStopReason(thermal: status.thermal,
                                                                             storage: status.storage,
                                                                             memory: status.memory) {
            if case .lowStorage = reason { reason = .lowStorage(freeBytes: status.freeBytes) }
            beginFinish(systemStop: reason, reason: "system stop \(reason.copyKey)")
            return
        }
        if status.memory == .low && !q.memoryLowLogged {
            q.memoryLowLogged = true
            appendEngineEvent(.memory, "memory low, available \(status.availableMemory / 1_000_000) MB; keyframes stop")
        } else if status.memory == .ok {
            q.memoryLowLogged = false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let detected = q.detections.take()
        var input = RoomScanStats.guidanceInput(time: now, status: status, newDoors: detected.doors,
                                                newWindows: detected.windows, newWalls: detected.walls)
        if let augment = guidanceAugmenter { augment(&input) }
        let raw = q.guidance.update(input)
        let output = GuidanceFilter(roomPlanCoaching: q.coaching).filter(raw)
        let stats = recorders.reduce(RecorderStats()) { $0 + $1.stats }
        var snapshot = RoomScanStats.snapshot(timestamp: q.latestFrameTimestamp ?? 0, status: status,
                                              counts: q.counts, recorders: stats, guidance: output.message)
        if let augment = snapshotAugmenter { augment(&snapshot) }
        logRoomPlanRates(now: now)
        publish(state: nil, events: [.snapshot(snapshot)])
    }

    /// Hub events: written to events.jsonl; interruptions pause the engine (and write the live
    /// room file at once); a session failure finishes the room with what exists.
    func handleCaptureEvent(_ event: CaptureEvent) {
        recordEvent(event)
        if event.kind == .tracking && event.detail == ARSessionHub.interruptedDetail {
            writeLiveRoom(reason: "interruption")
            if RoomScanStats.isCapturing(q.phase) { applyPause(reason: "session interrupted") }
        } else if event.kind == .tracking && event.detail == ARSessionHub.interruptionEndedDetail {
            let next = RoomScanStats.next(q.phase, on: .interruptionEnded)
            RoomScanLog.write("interruption ended; engine stays \(next.rawValue) until Resume")
        } else if event.kind == .error && event.detail.hasPrefix(ARSessionHub.sessionFailedPrefix) {
            guard RoomScanStats.isCapturing(q.phase), !q.finishStarted else { return }
            q.pendingNotice = .trackingFailed
            beginFinish(systemStop: nil, reason: "ARSession failed")
        }
    }

    /// iOS memory warning (forwarded by the hub): flush and finish the room, as for heat (D17).
    func handleMemoryPressure() {
        guard RoomScanStats.isCapturing(q.phase), !q.finishStarted else { return }
        beginFinish(systemStop: .lowMemory, reason: "memory warning")
    }

    // MARK: - RoomPlan callbacks (hopped here by RoomCaptureController)

    /// `didStartWith`: marks the scan start (hub watchdogs and elapsed time begin), logs the
    /// effective configuration now, after 1 s and after 5 s, and the delegate identity. Never
    /// re-applies the configuration (only the hub watchdog does, RESEARCH ruling 1).
    func roomPlanDidStart(coachingEnabled: Bool, callbackOnMain: Bool) {
        RoomScanLog.write("RoomPlan didStartWith: coaching \(coachingEnabled), callback on main \(callbackOnMain)")
        if let latest = q.latestFrameTimestamp {
            markScanStart(latest)
        } else {
            q.pendingScanStart = true
        }
        logConfiguration(label: "RoomPlan didStartWith")
        let delegateIsHub = hub.session.delegate === hub
        let queueIsHub = hub.session.delegateQueue === hub.queue
        let relay = hub.currentRelay != nil
        RoomScanLog.write("identity after didStartWith: delegate === hub \(delegateIsHub), "
                          + "delegateQueue === hub.queue \(queueIsHub), relay \(relay)")
        appendEngineEvent(.config, "RoomPlan started; delegate === hub \(delegateIsHub), queue \(queueIsHub)")
        for delay in [1.0, 5.0] {
            hub.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logConfiguration(label: "\(Int(delay)) s after RoomPlan start")
            }
        }
        let next = RoomScanStats.next(q.phase, on: .didStart)
        guard next != q.phase else { return }
        q.phase = next
        publish(state: next, events: [.stateChanged(next)])
    }

    /// `didUpdate`: live counts, new detections, the live room safety net (every 10 s) and the
    /// build 5 live room hook (at most 1 Hz).
    func roomPlanDidUpdate(_ room: CapturedRoom) {
        guard RoomScanStats.isCapturing(q.phase) else { return }
        q.updateCount += 1
        let input = RoomInput(room)
        q.counts = RoomLiveCounts(RoomScanStats.counts(input))
        q.detections.observe(input)
        q.latestRoom = room
        let now = ProcessInfo.processInfo.systemUptime
        if RoomScanStats.isDue(now: now, last: q.lastLiveWrite, interval: RoomScanEngine.liveRoomInterval) {
            writeLiveRoom(reason: "periodic")
        }
        if let handler = liveRoomHandler,
           RoomScanStats.isDue(now: now, last: q.lastLiveHandler, interval: RoomScanEngine.liveHandlerInterval) {
            q.lastLiveHandler = now
            handler(input)
        }
    }

    /// `didProvide`: coaching flag for the guidance filter, seconds per instruction, and one
    /// `.instruction` event per change (`.normal` arrives constantly, RESEARCH 3.2 gotcha 7).
    func roomPlanDidProvide(instructionName: String, coaching: Bool) {
        q.instructionCount += 1
        q.coaching = coaching
        guard instructionName != q.instructionName else { return }
        closeInstructionBucket(now: ProcessInfo.processInfo.systemUptime)
        q.instructionName = instructionName
        appendEngineEvent(.instruction, instructionName)
    }

    /// `didEndWith` (values copied by the controller).
    func roomPlanDidEnd(data: CapturedRoomData, error: (any Error)?) {
        let text = error.map { RoomScanStats.describe($0) } ?? "none"
        RoomScanLog.write("RoomPlan didEndWith, error \(text)")
        handleRoomEnded(data: data, error: error, source: "didEndWith")
    }

    /// The RoomPlan pass ended (didEndWith, the 15 s watchdog, or a finish with no pass): starts
    /// the finish sequence once per room. During a cancel the room data is still written (best
    /// effort, for recovery) while the writer is open; during a discard it is dropped.
    func handleRoomEnded(data: CapturedRoomData?, error: (any Error)?, source: String) {
        q.liveWritesStopped = true
        if let abandon = q.abandon {
            if abandon == .cancel, let data, !q.writerCloseRequested, let writer = q.writer, let folder = q.folder {
                RoomScanPersistence.queueRoomData(data, writer: writer, folder: folder)
            }
            return
        }
        guard !q.finishStarted else {
            RoomScanLog.write("room end from \(source) ignored: the finish sequence already runs")
            return
        }
        switch q.phase {
        case .starting, .scanning, .paused:
            if RoomScanStats.isDeviceTooHot(error) { q.systemStop = .deviceTooHot }
            q.phase = RoomScanStats.next(q.phase, on: .finish)
            publish(state: .stopping, events: [.stateChanged(.stopping)])
            DispatchQueue.main.async { [weak self] in self?.markRoomPlanEnded() }
            RoomScanLog.write("RoomPlan ended the room by itself (\(source))")
        case .stopping:
            break
        case .idle, .finished, .failed:
            RoomScanLog.write("room end from \(source) ignored in state \(q.phase.rawValue)")
            return
        }
        guard let context = makeFinishContext(data: data, error: error) else {
            RoomScanLog.write("room end without a room folder; nothing to seal")
            q.phase = RoomScanStats.next(q.phase, on: .failure)
            publish(state: .failed, events: [.failed(.ioFailed("room folder missing at finish"))])
            return
        }
        q.finishStarted = true
        Task { [self] in await self.runFinishSequence(context) }
    }

    /// The `didEndWith` watchdog: finishes without room data when RoomPlan never answered.
    func handleEndTimeout(serial: Int) {
        guard serial == q.roomSerial, q.phase == .stopping, !q.finishStarted, q.abandon == nil else { return }
        RoomScanLog.write("didEndWith did not arrive within \(Int(RoomScanEngine.endTimeoutSeconds)) s")
        handleRoomEnded(data: nil, error: nil, source: "timeout")
    }

    // MARK: - Pause, resume, finish, abandon

    /// Pauses (state only; RoomPlan keeps scanning) and stops keyframes.
    func applyPause(reason: String) {
        let next = RoomScanStats.next(q.phase, on: .pause)
        guard next != q.phase else { return }
        q.phase = next
        setRecordersPaused(true)
        appendEngineEvent(.note, "paused: \(reason)")
        publish(state: next, events: [.stateChanged(next)])
    }

    /// Back to scanning after `pause()` or an interruption.
    func applyResume() {
        let next = RoomScanStats.next(q.phase, on: .resume)
        guard next != q.phase else { return }
        q.phase = next
        setRecordersPaused(false)
        appendEngineEvent(.note, "resumed")
        publish(state: next, events: [.stateChanged(next)])
    }

    /// Starts a finish: Done (`systemStop` nil) or the engine itself (heat, storage, memory; a
    /// memory stop first calls `flushNow()` on every recorder). Emits `.stateChanged(.stopping)`
    /// and stops the RoomPlan pass on main.
    func beginFinish(systemStop: MapperError?, reason: String) {
        guard RoomScanStats.isCapturing(q.phase), !q.finishStarted, q.abandon == nil else {
            RoomScanLog.write("finish (\(reason)) ignored in state \(q.phase.rawValue)")
            return
        }
        q.phase = RoomScanStats.next(q.phase, on: .finish)
        q.systemStop = systemStop
        if systemStop == .lowMemory {
            for recorder in recorders { recorder.flushNow() }
        }
        appendEngineEvent(.note, "finish requested: \(reason)")
        RoomScanLog.write("finish requested (\(reason)): " + RoomScanLog.deviceLine())
        publish(state: .stopping, events: [.stateChanged(.stopping)])
        let serial = q.roomSerial
        DispatchQueue.main.async { [weak self] in self?.stopRoomPlanForFinish(serial: serial) }
    }

    /// Starts a cancel or discard. While capturing: ordered stop in a task. While a finish runs:
    /// the finish sequence abandons before sealing. Otherwise: `.stateChanged(.idle)` (a discard
    /// also removes an unsealed InProgress folder, for example after a failed seal).
    func beginAbandon(_ kind: RoomAbandonKind) {
        if let existing = q.abandon {
            if kind == .discard && existing == .cancel { q.abandon = .discard }
            return
        }
        switch q.phase {
        case .idle, .finished, .failed:
            if kind == .discard, !q.sealed, let scanID = q.scanID {
                q.scanID = nil
                RawScanWriter.ioQueue.async { RoomScanPersistence.discardInProgress(scanID) }
            }
            q.phase = RoomScanStats.next(q.phase, on: .cancel)
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        case .stopping where q.finishStarted:
            q.abandon = kind
            RoomScanLog.write("\(kind) requested during the finish sequence; it stops before the seal")
            return
        case .starting, .scanning, .paused, .stopping:
            q.abandon = kind
            q.phase = .stopping
        }
        guard let writer = q.writer, let scanID = q.scanID else {
            q.phase = RoomScanStats.next(q.phase, on: .cancel)
            q.abandon = nil
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        }
        q.finishStarted = true
        appendEngineEvent(.note, "capture \(kind == .discard ? "discarded" : "cancelled")")
        Task { [self] in await self.runAbandonSequence(writer: writer, scanID: scanID) }
    }

    // MARK: - Small helpers (hub queue)

    /// Marks the scan start on the hub (watchdogs, elapsed time, tracking history) and resets
    /// the guidance engine.
    func markScanStart(_ timestamp: TimeInterval) {
        q.pendingScanStart = false
        q.scanStartTimestamp = timestamp
        q.guidance.reset()
        hub.markScanStart(timestamp: timestamp)
    }

    /// Adds the time since the current instruction started to its bucket.
    func closeInstructionBucket(now: TimeInterval) {
        if let name = q.instructionName {
            RoomScanStats.accumulate(&q.instructionSeconds, instruction: name, delta: now - q.instructionSince)
        }
        q.instructionSince = now
    }

    /// Pauses or resumes every recorder that supports it (`PausableScanRecorder`).
    func setRecordersPaused(_ paused: Bool) {
        for recorder in recorders {
            if let pausable = recorder as? PausableScanRecorder { pausable.isPaused = paused }
        }
    }

    /// Writes an event to events.jsonl (buffered before the writer exists, dropped after its
    /// close was requested).
    func recordEvent(_ event: CaptureEvent) {
        if let writer = q.writer, let folder = q.folder {
            guard !q.writerCloseRequested else { return }
            writer.appendJSONLine(event, to: folder.eventsLogURL)
        } else if q.pendingEvents.count < RoomScanEngine.maxPendingEvents {
            q.pendingEvents.append(event)
        }
    }

    /// An engine event (instruction, notes) with `t` seconds since the scan start.
    func appendEngineEvent(_ kind: CaptureEventKind, _ detail: String) {
        let t = RoomScanStats.elapsed(start: q.scanStartTimestamp, latest: q.latestFrameTimestamp)
        recordEvent(CaptureEvent(t: t, kind: kind, detail: detail))
    }

    /// Writes the latest live room to capturedroom-live.json (plain JSONEncoder inside the
    /// writer's io queue block, atomic), unless live writes stopped at `didEndWith`.
    func writeLiveRoom(reason: String) {
        guard !q.liveWritesStopped, !q.writerCloseRequested, let room = q.latestRoom,
              let writer = q.writer, let folder = q.folder else { return }
        q.lastLiveWrite = ProcessInfo.processInfo.systemUptime
        RoomScanPersistence.queueLiveRoom(room, writer: writer, folder: folder)
        RoomScanLog.once("live.first.\(q.roomSerial)", "live room file written (\(reason))")
    }

    /// Logs the effective ARKit configuration through the hub diagnostics (D22).
    func logConfiguration(label: String) {
        hub.diagnostics.logConfiguration(hub.session.configuration, label: label)
    }

    /// RoomPlan callback rates once a second for 30 s, then every 10 s (RESEARCH 3.2 step 12).
    func logRoomPlanRates(now: TimeInterval) {
        guard let last = q.lastRateLog else {
            q.lastRateLog = now
            return
        }
        let interval: TimeInterval = q.rateLogs < 30 ? 1 : 10
        guard now - last >= interval else { return }
        let seconds = max(0.001, now - last)
        let updates = Double(q.updateCount) / seconds
        let coaching = q.coaching ? "coaching \(q.instructionName ?? "?")" : "not coaching"
        RoomScanLog.write("roomplan: didUpdate \(String(format: "%.1f", updates))/s, "
                          + "instructions \(q.instructionCount), \(coaching), walls \(q.counts.walls)")
        q.updateCount = 0
        q.instructionCount = 0
        q.lastRateLog = now
        q.rateLogs += 1
    }

    /// Seconds between two live room files (docs/MODULES.md 3.21).
    static let liveRoomInterval: TimeInterval = 10
    /// Seconds between two live room hook calls (1 Hz).
    static let liveHandlerInterval: TimeInterval = 1
    /// Most hub events kept before the writer exists.
    static let maxPendingEvents = 500
}
