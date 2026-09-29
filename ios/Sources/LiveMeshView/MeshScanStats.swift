import Foundation

// Pure rules of the mesh-only scan driver (docs/MODULES.md 3.32). Nothing here touches a
// session, a file or a clock, so LiveMeshViewSelfTest checks every rule without ARKit. The
// finish order is the data in `finishSteps`, which the engine iterates, so the order cannot
// drift from the tested list.

/// Lifecycle signals the engine feeds to `MeshScanStats.next(_:on:)`.
enum MeshEngineSignal: Equatable, Sendable {
    /// `start()` made the pass folder; `firstFrame` the first frame after it; `pause` a pause or
    /// an interruption; `interruptionEnded` its end (the engine stays paused until `resume`);
    /// `finish` Done or a system stop; `sealed` the seal; `failure` a failure before the seal;
    /// `cancel` the end of `cancel()` or `discard()`.
    case start, firstFrame, pause, interruptionEnded, resume, finish, sealed, failure, cancel
}

/// One step of the finish sequence, in the order `MeshScanStats.finishSteps` lists them.
enum MeshFinishStep: String, CaseIterable, Sendable {
    /// The 9 steps of docs/MODULES.md 3.32, "Finish sequence", in that order.
    case detachRecorders, finishRecorders, writeAttachments, writeLogs, flushWriter, closeWriter, seal,
         pauseIfSystemStop, emitRoomFinished
}

/// Pure rules (tested).
enum MeshScanStats {
    /// Most bytes of one attachment file name (UTF-8).
    static let maxAttachmentNameBytes = 128

    /// Names the engine, the recorders or the folder layout own, so an attachment never
    /// replaces them (compared without regard to case).
    static let reservedFileNames: [String] = [
        SealFile.fileName, InProgressScanInfo.fileName, "roomlog.json", "events.jsonl", "keyframes.jsonl",
        "photos.jsonl", "poses.ptrk", "mesh", "keyframes", "depth", "photos",
    ]

    /// True while a pass is live: starting, scanning, paused.
    static func isCapturing(_ state: ScanEngineState) -> Bool {
        state == .starting || state == .scanning || state == .paused
    }

    /// Engine state machine. Signals that do not apply to a state leave it unchanged; a failure
    /// after the seal leaves `.finished` (the pass is sealed and `lastResult` stays valid; the
    /// `.failed` event is then a notice about how the pass ended).
    static func next(_ state: ScanEngineState, on signal: MeshEngineSignal) -> ScanEngineState {
        switch signal {
        case .start:
            return state == .idle ? .starting : state
        case .firstFrame:
            return state == .starting ? .scanning : state
        case .pause:
            return state == .starting || state == .scanning ? .paused : state
        case .interruptionEnded:
            return state
        case .resume:
            return state == .paused ? .scanning : state
        case .finish:
            return isCapturing(state) ? .stopping : state
        case .sealed:
            return isCapturing(state) || state == .stopping ? .finished : state
        case .failure:
            return isCapturing(state) || state == .stopping ? .failed : state
        case .cancel:
            return .idle
        }
    }

    /// The finish sequence in order (tested as data).
    static let finishSteps: [MeshFinishStep] = [
        .detachRecorders, .finishRecorders, .writeAttachments, .writeLogs, .flushWriter, .closeWriter, .seal,
        .pauseIfSystemStop, .emitRoomFinished,
    ]

    /// Mesh-mode input: tracking (`GuidanceSignals.tracking(status.tracking)`), angularSpeed, linearSpeed,
    /// centerDistance, depthConfidenceMean, ambientIntensity from the status, deviceHot at thermal
    /// serious or worse. Everything RoomScanStats leaves out in Room mode is set here (no RoomPlan coaching).
    static func guidanceInput(time: Double, status: HubStatus) -> GuidanceInput {
        var input = GuidanceInput(time: time)
        input.tracking = GuidanceSignals.tracking(status.tracking)
        input.angularSpeed = status.angularSpeed
        input.linearSpeed = status.linearSpeed
        input.centerDistance = status.centerDistance
        input.depthConfidenceMean = status.depthConfidenceMean
        input.ambientIntensity = status.ambientIntensity
        input.deviceHot = status.thermal == .serious || status.thermal == .critical
        return input
    }

    /// The live snapshot for one status tick: streams and device state from the hub, recorder
    /// counters and the guidance to show. Element counts stay 0 (no RoomPlan in a mesh pass).
    static func snapshot(timestamp: Double, status: HubStatus, recorders: RecorderStats,
                         guidance: GuidanceKind?) -> LiveScanSnapshot {
        var snapshot = LiveScanSnapshot()
        snapshot.timestamp = timestamp
        snapshot.elapsed = status.elapsed
        snapshot.tracking = status.tracking
        snapshot.degraded = status.degraded
        snapshot.guidanceRawValue = guidance?.rawValue
        snapshot.meshFaceCount = recorders.meshFaces
        snapshot.keyframeCount = recorders.keyframes
        snapshot.photoCount = recorders.photos
        snapshot.thermal = status.thermal
        snapshot.freeBytes = status.freeBytes
        snapshot.availableMemory = status.availableMemory
        return snapshot
    }

    /// thermal .critical -> .deviceTooHot, storage .pause -> .lowStorage(freeBytes: 0) (the caller
    /// fills the bytes), memory .critical -> .lowMemory, else nil.
    static func systemStopReason(thermal: ThermalLevel, storage: StorageState, memory: MemoryState) -> MapperError? {
        if thermal == .critical { return .deviceTooHot }
        if storage == .pause { return .lowStorage(freeBytes: 0) }
        if memory == .critical { return .lowMemory }
        return nil
    }

    /// Nil when valid: kind and mode agree (meshPass with room, house or advancedSpace; object with
    /// object or advancedObject), `destination` equals the package URL for the kind, session and passID.
    static func validationProblem(_ target: MeshScanTarget) -> String? {
        switch target.kind {
        case .meshPass:
            let modes: [ScanMode] = [.room, .house, .advancedSpace]
            guard modes.contains(target.mode) else { return "mode \(target.mode.rawValue) cannot record a mesh pass" }
        case .object:
            let modes: [ScanMode] = [.object, .advancedObject]
            guard modes.contains(target.mode) else { return "mode \(target.mode.rawValue) cannot record an object" }
        case .room:
            return "kind room is recorded by the room engine"
        }
        guard let expected = target.expectedDestination else { return "no destination for kind \(target.kind.rawValue)" }
        guard sameLocation(target.destination, expected) else {
            return "destination is not the package folder of this \(target.kind.rawValue)"
        }
        return nil
    }

    /// The start checks as one pure rule: `.ioFailed(problem)` for an invalid target, then
    /// `.unsupportedDevice` without mesh support, then `.lowStorage(freeBytes:)` under
    /// `ProjectStore.refuseScanBelowBytes`; nil when capture may start.
    static func startProblem(_ target: MeshScanTarget, supportsMesh: Bool, freeBytes: Int64) -> MapperError? {
        if let problem = validationProblem(target) { return .ioFailed(problem) }
        guard supportsMesh else { return .unsupportedDevice }
        guard freeBytes >= ProjectStore.refuseScanBelowBytes else { return .lowStorage(freeBytes: freeBytes) }
        return nil
    }

    /// True only for an owned hub (teardown pauses it); a borrowed hub keeps running.
    static func pausesHubOnTeardown(ownsHub: Bool) -> Bool {
        ownsHub
    }

    /// True once per gap: scanning, a previous frame known, and more than `frameGapSeconds` since it.
    static func shouldReapplyForFrameGap(now: Double, lastFrame: Double?, triedForThisGap: Bool, isScanning: Bool) -> Bool {
        guard isScanning, !triedForThisGap, let lastFrame, now.isFinite, lastFrame.isFinite else { return false }
        return now - lastFrame > MeshScanEngine.frameGapSeconds
    }

    /// A single safe file name (RawScanFolder.isSafeRelativePath, no "/") that is not a name the
    /// engine or a recorder writes: SEAL.json, scan.json, roomlog.json, events.jsonl, keyframes.jsonl,
    /// photos.jsonl, poses.ptrk (nor a subfolder of the layout). Hidden names (a leading ".") and
    /// names over `maxAttachmentNameBytes` are refused too.
    static func isSafeAttachmentName(_ name: String) -> Bool {
        guard RawScanFolder.isSafeRelativePath(name), !name.contains("/"), !name.hasPrefix("."),
              name.utf8.count <= maxAttachmentNameBytes else { return false }
        let lowered = name.lowercased()
        return !reservedFileNames.contains { $0.lowercased() == lowered }
    }

    /// roomlog.json of a pass: no RoomPlan instructions; counts and fractions clamped.
    static func log(seconds: Double, relocalizations: Int, limitedFraction: Double, degraded: DegradedMode,
                    error: String?) -> RoomCaptureLog {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let safeFraction = limitedFraction.isFinite ? min(1, max(0, limitedFraction)) : 0
        return RoomCaptureLog(seconds: safeSeconds, instructionSeconds: [:], error: error,
                              relocalizations: max(0, relocalizations), limitedTrackingFraction: safeFraction,
                              degraded: degraded)
    }

    /// The `.failed` notice sent after `.roomFinished`: the system stop first, then an earlier
    /// session failure (`.trackingFailed`); nil for a plain Done.
    static func notice(systemStop: MapperError?, pending: MapperError?) -> MapperError? {
        systemStop ?? pending
    }

    /// Seconds of capture from the scan start and the latest frame (0 when either is unknown).
    static func elapsed(start: Double?, latest: Double?) -> Double {
        guard let start, let latest, latest.isFinite, start.isFinite else { return 0 }
        return max(0, latest - start)
    }

    /// True when at least `interval` seconds passed since `last` (the 10 Hz camera transform).
    /// Time running backwards counts as due, so a new timeline is picked up at once.
    static func isDue(now: Double, last: Double?, interval: Double) -> Bool {
        guard let last else { return true }
        let delta = now - last
        return delta >= interval || delta < 0
    }

    /// Diagnostic text of an error for logs (never shown in the UI). Swift enum errors give their
    /// case; anything else only its domain and code, because Foundation errors carry full file
    /// paths (ARCHITECTURE 11.4).
    static func describe(_ error: any Error) -> String {
        if error is MapperError || error is CoreError { return "\(error)" }
        let nsError = error as NSError
        if Mirror(reflecting: error).displayStyle == .enum { return "\(nsError.domain).\(error)" }
        return "\(nsError.domain) \(nsError.code)"
    }

    /// True when two file URLs name the same location (standardized paths, trailing slash ignored).
    static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
