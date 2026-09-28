import Foundation
import ARKit
import RoomPlan

// Per-room persistence of RoomScanEngine (docs/MODULES.md 3.21, ARCHITECTURE 3.4 and 4.2): the
// finish sequence as one ordered task over `RoomScanStats.finishSteps`, the abandon sequence of
// cancel and discard, and the RoomPlan and world map files. Every raw write goes through the
// room's `RawScanWriter` (createParents false); nothing is written into the folder after the
// writer is closed, and the seal comes after the close, so no file follows SEAL.json.

/// Values the finish sequence needs, copied on the hub queue when the RoomPlan pass ended.
struct RoomFinishContext {
    /// The room and its project.
    var target: RoomScanTarget
    /// InProgress scan identifier, its folder and writer.
    var scanID: UUID
    /// The InProgress folder.
    var folder: RawScanFolder
    /// The room's writer.
    var writer: RawScanWriter
    /// RoomPlan's raw room data (nil when RoomPlan never ran or never answered).
    var data: CapturedRoomData?
    /// RoomPlan's end error.
    var error: (any Error)?
    /// Why the engine finished the room itself (heat, storage, memory), if it did.
    var systemStop: MapperError?
    /// The `.failed` event sent after `.roomFinished`, if any.
    var notice: MapperError?
    /// Contents of roomlog.json.
    var log: RoomCaptureLog
    /// True for the first room of this engine's ARSession (session.json is written with it).
    var firstRoomOfSession: Bool
    /// Contents of session.json.
    var sessionRecord: CaptureSessionRecord
    /// The last events.jsonl lines.
    var finalEvents: [CaptureEvent]
}

/// Result of the RoomBuilder run (Sendable, so it crosses the timeout helper).
enum RoomBuildOutcome: Sendable {
    /// The final room.
    case built(CapturedRoom)
    /// RoomBuilder threw; diagnostic text.
    case failed(String)
    /// RoomBuilder did not answer in time.
    case timedOut
}

/// Result of the world map request.
enum RoomWorldMapOutcome: Sendable {
    /// Archived map bytes, anchors kept and mesh anchors dropped.
    case archived(Data, kept: Int, dropped: Int)
    /// No map or an archive failure; diagnostic text.
    case failed(String)
    /// ARKit did not answer in time.
    case timedOut
}

/// File helpers of the room engine. Thread-safe (stateless).
enum RoomScanPersistence {
    /// Longest wait for RoomBuilder before sealing without capturedroom.json (BuildRoomStep retries).
    static let roomBuilderTimeout: TimeInterval = 60
    /// Longest wait for `getCurrentWorldMap` (docs/MODULES.md 3.21: at most 3 s).
    static let worldMapTimeout: TimeInterval = 3
    /// Longest wait for one recorder's `finishRecording`.
    static let recorderFinishTimeout: TimeInterval = 20

    /// Queues capturedroomdata.json: plain `JSONEncoder` (RoomPlan's own type, 3.1) on the io
    /// queue, atomic write, parent must exist.
    static func queueRoomData(_ data: CapturedRoomData, writer: RawScanWriter, folder: RawScanFolder) {
        let url = folder.capturedRoomDataURL
        writer.perform {
            let encoded = try JSONEncoder().encode(data)
            try ProjectStore.writeData(encoded, to: url, createParents: false)
        }
    }

    /// Queues capturedroom-live.json (the provisional room of a killed scan), same rules.
    static func queueLiveRoom(_ room: CapturedRoom, writer: RawScanWriter, folder: RawScanFolder) {
        let url = folder.liveCapturedRoomURL
        writer.perform {
            let encoded = try JSONEncoder().encode(room)
            try ProjectStore.writeData(encoded, to: url, createParents: false)
        }
    }

    /// Deletes an InProgress folder (the caller closed the writer first). Logged, never thrown.
    static func discardInProgress(_ scanID: UUID) {
        do {
            try InProgressScans.discard(scanID: scanID)
        } catch {
            RoomScanLog.write("discard of scan \(scanID) failed: \(RoomScanStats.describe(error))")
        }
    }

    /// Drops the mesh anchors (Mapper keeps its own mesh) and archives the map with secure
    /// coding (feature points for Representation A).
    static func archiveWorldMap(_ map: ARWorldMap?, error: (any Error)?) -> RoomWorldMapOutcome {
        guard let map else {
            return .failed(error.map { RoomScanStats.describe($0) } ?? "no world map")
        }
        let before = map.anchors.count
        map.anchors = map.anchors.filter { !($0 is ARMeshAnchor) }
        let kept = map.anchors.count
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            return .archived(data, kept: kept, dropped: before - kept)
        } catch {
            return .failed("archive: \(RoomScanStats.describe(error))")
        }
    }
}

extension RoomScanEngine {
    // MARK: - Finish sequence

    /// Hub queue. Copies everything the finish sequence needs; nil without a room folder.
    func makeFinishContext(data: CapturedRoomData?, error: (any Error)?) -> RoomFinishContext? {
        guard let folder = q.folder, let writer = q.writer, let scanID = q.scanID else { return nil }
        closeInstructionBucket(now: ProcessInfo.processInfo.systemUptime)
        let hasData = data != nil
        let degraded = RoomScanStats.degradedMode(hub: hub.degraded, hasRoomData: hasData, error: error)
        let seconds = RoomScanStats.elapsed(start: q.scanStartTimestamp, latest: q.latestFrameTimestamp)
        let errorText = error.map { RoomScanStats.describe($0) }
        let log = RoomCaptureLog(seconds: seconds, instructionSeconds: q.instructionSeconds, error: errorText,
                                 relocalizations: hub.tracking.relocalizations,
                                 limitedTrackingFraction: hub.tracking.limitedFraction, degraded: degraded)
        let notice = RoomScanStats.notice(systemStop: q.systemStop, error: error, pending: q.pendingNotice,
                                          hasRoomData: hasData)
        var finalEvents = [CaptureEvent(t: seconds, kind: error == nil ? .note : .error,
                                        detail: "room ended, error \(errorText ?? "none"), room data \(hasData)")]
        if degraded != hub.degraded {
            finalEvents.append(CaptureEvent(t: seconds, kind: .degraded, detail: degraded.rawValue))
        }
        return RoomFinishContext(target: q.target, scanID: scanID, folder: folder, writer: writer, data: data,
                                 error: error, systemStop: q.systemStop, notice: notice, log: log,
                                 firstRoomOfSession: q.roomsFinished == 0,
                                 sessionRecord: hub.diagnostics.sessionRecord(id: q.target.sessionID),
                                 finalEvents: finalEvents)
    }

    /// The finish sequence, in the order of `RoomScanStats.finishSteps`, inside a background
    /// task. A cancel or discard that arrives before the seal abandons the room instead; one
    /// that arrives after the seal reports `.stateChanged(.idle)` instead of `.roomFinished`.
    func runFinishSequence(_ context: RoomFinishContext) async {
        let background = await RoomBackgroundTask.begin(name: "mapper.room.finish")
        RoomScanLog.write("finish sequence for room \(context.target.roomID): " + RoomScanLog.deviceLine())
        var capturedRoomID: UUID?
        var stats = RecorderStats()
        for step in RoomScanStats.finishSteps {
            switch step {
            case .writeRoomData:
                if let data = context.data {
                    RoomScanPersistence.queueRoomData(data, writer: context.writer, folder: context.folder)
                }
            case .buildRoom:
                capturedRoomID = await buildRoom(context)
            case .saveWorldMap:
                await saveWorldMap(context)
            case .detachRecorders:
                await detachRecorders()
            case .finishRecorders:
                stats = await finishRecorders()
            case .writeLogs:
                writeLogs(context)
            case .flushWriter:
                await context.writer.flush()
            case .closeWriter:
                await closeWriter(context.writer)
            case .seal:
                if let kind = await onHubQueue({ self.q.abandon }) {
                    await completeAbandon(kind, scanID: context.scanID)
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
                    RoomScanLog.write("session paused after a system stop")
                }
            case .emitRoomFinished:
                await emitRoomFinished(context, capturedRoomID: capturedRoomID, stats: stats)
            }
        }
        await background.end()
    }

    /// Step 2: RoomBuilder on the room data (never the last `didUpdate`), then capturedroom.json.
    /// Failures and timeouts are logged; the room is then sealed without capturedroom.json.
    func buildRoom(_ context: RoomFinishContext) async -> UUID? {
        guard let data = context.data else {
            RoomScanLog.write("no room data; RoomBuilder not run")
            return nil
        }
        guard RoomScanStats.shouldBuildRoom(after: context.error) else {
            RoomScanLog.write("RoomBuilder not run after a RoomPlan failure")
            return nil
        }
        let started = ProcessInfo.processInfo.systemUptime
        let outcome = await RoomAsync.withTimeout(seconds: RoomScanPersistence.roomBuilderTimeout,
                                                  fallback: RoomBuildOutcome.timedOut) { finish in
            Task {
                do {
                    let builder = RoomBuilder(options: [.beautifyObjects])
                    let room = try await builder.capturedRoom(from: data)
                    finish(.built(room))
                } catch {
                    finish(.failed(RoomScanStats.describe(error)))
                }
            }
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        switch outcome {
        case .built(let room):
            do {
                context.writer.writeFile(try JSONEncoder().encode(room), to: context.folder.capturedRoomURL)
            } catch {
                RoomScanLog.write("CapturedRoom could not be encoded: \(RoomScanStats.describe(error))")
                return nil
            }
            RoomScanLog.write("RoomBuilder done in \(milliseconds) ms: \(room.walls.count) walls, "
                              + "\(room.doors.count) doors, \(room.windows.count) windows, \(room.objects.count) objects")
            return room.identifier
        case .failed(let reason):
            RoomScanLog.write("RoomBuilder failed after \(milliseconds) ms: \(reason)")
            return nil
        case .timedOut:
            RoomScanLog.write("RoomBuilder did not finish within \(Int(RoomScanPersistence.roomBuilderTimeout)) s")
            return nil
        }
    }

    /// Step 3: the world map without mesh anchors, best effort, at most 3 s, only when mapping
    /// is `.mapped` or `.extending`.
    func saveWorldMap(_ context: RoomFinishContext) async {
        let session = hub.session
        guard let status = session.currentFrame?.worldMappingStatus else {
            RoomScanLog.write("world map skipped: no current frame")
            return
        }
        guard RoomScanStats.shouldSaveWorldMap(status) else {
            RoomScanLog.write("world map skipped: mapping \(RoomScanStats.worldMappingName(status))")
            return
        }
        let outcome = await RoomAsync.withTimeout(seconds: RoomScanPersistence.worldMapTimeout,
                                                  fallback: RoomWorldMapOutcome.timedOut) { finish in
            session.getCurrentWorldMap { map, error in
                finish(RoomScanPersistence.archiveWorldMap(map, error: error))
            }
        }
        switch outcome {
        case .archived(let data, let kept, let dropped):
            context.writer.writeFile(data, to: context.folder.worldMapURL)
            RoomScanLog.write("world map saved: \(data.count) bytes, \(kept) anchors, \(dropped) mesh anchors dropped")
        case .failed(let reason):
            RoomScanLog.write("world map not saved: \(reason)")
        case .timedOut:
            RoomScanLog.write("world map not saved: no answer within \(Int(RoomScanPersistence.worldMapTimeout)) s")
        }
    }

    /// Step 4: detaches every recorder on the hub queue, so no callback arrives after this.
    func detachRecorders() async {
        await onHubQueue {
            for recorder in self.recorders { self.hub.detach(recorder) }
        }
    }

    /// Step 5: `finishRecording(completion:)` on the hub queue for each recorder, awaited in turn
    /// (with a timeout per recorder); returns the recorders' final counters.
    func finishRecorders() async -> RecorderStats {
        let hub = self.hub
        for recorder in recorders {
            let name = String(describing: type(of: recorder))
            let finished = await RoomAsync.withTimeout(seconds: RoomScanPersistence.recorderFinishTimeout,
                                                       fallback: false) { finish in
                hub.queue.async {
                    recorder.finishRecording { finish(true) }
                }
            }
            if !finished {
                RoomScanLog.write("recorder \(name) did not finish within \(Int(RoomScanPersistence.recorderFinishTimeout)) s")
            }
        }
        return await onHubQueue { self.recorders.reduce(RecorderStats()) { $0 + $1.stats } }
    }

    /// Step 6: roomlog.json, the last events.jsonl lines and, for the first room of the session,
    /// raw/sessions/<s>/session.json (its folder exists since `start()`; made again if needed,
    /// only inside an existing package).
    func writeLogs(_ context: RoomFinishContext) {
        let writer = context.writer
        do {
            writer.writeFile(try ProjectStore.encoder.encode(context.log), to: context.folder.roomLogURL)
        } catch {
            RoomScanLog.write("roomlog.json not encoded: \(RoomScanStats.describe(error))")
        }
        for event in context.finalEvents {
            writer.appendJSONLine(event, to: context.folder.eventsLogURL)
        }
        guard context.firstRoomOfSession else { return }
        let package = context.target.package
        let sessionID = context.target.sessionID
        do {
            try ProjectStore.ensureDirectory(package.sessionURL(sessionID), inside: package.root)
            writer.writeFile(try ProjectStore.encoder.encode(context.sessionRecord), to: package.sessionRecordURL(sessionID))
        } catch {
            RoomScanLog.write("session.json not written: \(RoomScanStats.describe(error))")
        }
    }

    /// Step 8: no write is queued after this; returns once the close ran on the io queue.
    func closeWriter(_ writer: RawScanWriter) async {
        await onHubQueue { self.q.writerCloseRequested = true }
        writer.close()
        await writer.flush()
        RoomScanLog.write("writer closed: \(writer.bytesWritten) bytes, \(writer.failureCount) failures, "
                          + "\(writer.droppedAfterClose) dropped")
    }

    /// Step 9: seals and moves the folder into the package on the io queue. Returns nil on
    /// success, else the failure text (the folder then stays in InProgress for recovery).
    func seal(_ context: RoomFinishContext) async -> String? {
        let package = context.target.package
        let folder = context.folder
        let destination = package.rawRoomURL(session: context.target.sessionID, room: context.target.roomID)
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
            RoomScanLog.write("seal of room \(context.target.roomID) failed: \(failure)")
            return failure
        }
        await onHubQueue {
            self.q.sealed = true
            self.q.roomsFinished += 1
        }
        return nil
    }

    /// A failed seal: pauses the session after a system stop, then `.failed(.ioFailed)` (raw
    /// stays in InProgress for recovery; `.roomFinished` is never sent without a seal).
    func failSeal(_ context: RoomFinishContext, reason: String) async {
        if context.systemStop != nil { await onMain { self.hub.pause() } }
        await onHubQueue { self.q.phase = RoomScanStats.next(self.q.phase, on: .failure) }
        publish(state: .failed, events: [.failed(.ioFailed("seal: \(reason)"))])
    }

    /// Step 11: `lastResult`, `.finished` and `.roomFinished`, then the notice (heat, storage,
    /// memory, scene size, tracking, RoomPlan failure) as `.failed`. A cancel or discard that
    /// arrived during the seal gets `.stateChanged(.idle)` instead (the sealed folder is in the
    /// package; ScanUI deletes the project, or launch recovery adds the room).
    func emitRoomFinished(_ context: RoomFinishContext, capturedRoomID: UUID?, stats: RecorderStats) async {
        let abandoned = await onHubQueue { () -> RoomAbandonKind? in
            let kind = self.q.abandon
            self.q.abandon = nil
            self.q.phase = RoomScanStats.next(self.q.phase, on: kind == nil ? .sealed : .cancel)
            return kind
        }
        if let kind = abandoned {
            RoomScanLog.write("\(kind) arrived during the seal; room \(context.target.roomID) stays sealed")
            publish(state: .idle, events: [.stateChanged(.idle)])
            return
        }
        let destination = context.target.package.rawRoomURL(session: context.target.sessionID, room: context.target.roomID)
        let result = RoomScanResult(roomID: context.target.roomID, sealedFolder: RawScanFolder(url: destination),
                                    capturedRoomID: capturedRoomID, log: context.log, keyframeCount: stats.keyframes,
                                    photoCount: stats.photos, frameLink: .projectFrame(sessionID: context.target.sessionID),
                                    capturedAt: Date(), stoppedBySystem: context.systemStop != nil)
        var events: [ScanEngineEvent] = [.roomFinished(roomID: context.target.roomID)]
        if let notice = context.notice { events.append(.failed(notice)) }
        RoomScanLog.write("room \(context.target.roomID) finished: \(stats.keyframes) keyframes, \(stats.photos) photos, "
                          + "degraded \(context.log.degraded.rawValue), system stop \(context.systemStop?.copyKey ?? "none"); "
                          + RoomScanLog.deviceLine())
        publish(state: .finished, events: events, result: result)
    }

    // MARK: - Abandon sequence (cancel and discard)

    /// Ordered stop without sealing: RoomPlan stop on main, recorders detached and finished,
    /// writer flushed and closed; then discard (if asked) and `.stateChanged(.idle)`.
    func runAbandonSequence(writer: RawScanWriter, scanID: UUID) async {
        await onMain { self.stopRoomPlanForAbandon() }
        await detachRecorders()
        _ = await finishRecorders()
        await writer.flush()
        await closeWriter(writer)
        let kind = await onHubQueue { self.q.abandon ?? .cancel }
        await completeAbandon(kind, scanID: scanID)
    }

    /// After the writer closed: deletes the InProgress folder for a discard (kept for a cancel),
    /// then `.stateChanged(.idle)`.
    func completeAbandon(_ kind: RoomAbandonKind, scanID: UUID) async {
        if kind == .discard {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                RawScanWriter.ioQueue.async {
                    RoomScanPersistence.discardInProgress(scanID)
                    continuation.resume()
                }
            }
        }
        await onHubQueue {
            self.q.abandon = nil
            self.q.phase = RoomScanStats.next(self.q.phase, on: .cancel)
            if kind == .discard { self.q.scanID = nil }
        }
        RoomScanLog.write(kind == .discard ? "scan \(scanID) discarded" : "scan \(scanID) cancelled; raw kept in InProgress")
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

    /// Runs `body` on the main queue (for the nonisolated main-thread calls `hub.pause()` and
    /// the RoomPlan stop) and returns when it ran.
    func onMain(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                body()
                continuation.resume()
            }
        }
    }
}
