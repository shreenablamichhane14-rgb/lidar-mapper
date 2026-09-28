import Foundation
import ARKit
import RoomPlan

/// Plain-Swift checks of RoomCapture's pure parts (docs/MODULES.md 3.21): error mapping, counts,
/// instruction seconds, the Room mode guidance input, the snapshot, the state machine, the
/// finish order, system stops, detections and the world map rule. Deterministic, no ARKit or
/// RoomPlan session, no camera, no files, well under 2 s. `run()` returns one line per failing
/// check ("name: detail"); empty means all passed.
enum RoomCaptureSelfTest {
    /// Runs every check.
    static func run() -> [String] {
        var failures: [String] = []
        checkErrors(&failures)
        checkCountsAndDetections(&failures)
        checkAccumulate(&failures)
        checkGuidance(&failures)
        checkSnapshot(&failures)
        checkStateMachine(&failures)
        checkFinishSteps(&failures)
        checkSystemStops(&failures)
        checkRoomOutcome(&failures)
        checkSmallHelpers(&failures)
        return failures
    }

    /// Records a failure when `ok` is false.
    private static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    // MARK: - Fixtures

    /// Deterministic UUID from a small number.
    static func uuid(_ n: Int) -> UUID {
        let lo = UInt8(n & 0xff)
        let hi = UInt8((n >> 8) & 0xff)
        return UUID(uuid: (0x52, 0x43, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    /// A surface of `kind` with identifier `n` (geometry is irrelevant to these checks).
    static func surface(_ n: Int, _ kind: SurfaceKind) -> SurfaceInput {
        SurfaceInput(identifier: uuid(n), parentIdentifier: nil, kind: kind, transform: Transform4.identity,
                     dimensions: Vec3(x: 1, y: 2, z: 0), confidence: .high, completedEdges: 4, curve: nil,
                     polygonCorners: [], story: 0)
    }

    /// An object with identifier `n`.
    static func object(_ n: Int, _ category: ObjectCategory) -> ObjectInput {
        ObjectInput(identifier: uuid(n), parentIdentifier: nil, category: category, transform: Transform4.identity,
                    dimensions: Vec3(x: 1, y: 1, z: 1), confidence: .medium, story: 0)
    }

    /// 3 walls, 2 doors (one open), 1 window, 1 opening, 1 floor, 2 objects.
    static func fixtureRoom(extraDoor: Bool = false) -> RoomInput {
        var openings = [surface(11, .door), surface(12, .openDoor), surface(13, .window), surface(14, .opening)]
        if extraDoor { openings.append(surface(15, .door)) }
        return RoomInput(identifier: uuid(1), walls: [surface(2, .wall), surface(3, .wall), surface(4, .wall)],
                         openings: openings, floors: [surface(20, .floor)],
                         objects: [object(30, .sofa), object(31, .table)], sections: [], story: 0)
    }

    // MARK: - Checks

    /// `mapError` for every CaptureError case, a Mapper error, cancellation and an unknown error;
    /// `describe` never prints a file path.
    private static func checkErrors(_ failures: inout [String]) {
        let expected: [(RoomCaptureSession.CaptureError, MapperError)] = [
            (.deviceNotSupported, .roomPlanFailed("deviceNotSupported")),
            (.deviceTooHot, .deviceTooHot),
            (.exceedSceneSizeLimit, .sceneTooLarge),
            (.invalidARConfiguration, .roomPlanFailed("invalidARConfiguration")),
            (.worldTrackingFailure, .trackingFailed),
            (.internalError, .roomPlanFailed("internalError")),
        ]
        for (error, mapped) in expected {
            let got = RoomScanStats.mapError(error)
            check(&failures, "mapError.\(RoomScanStats.captureErrorName(error))", got == mapped, "got \(got)")
        }
        let unknown = RoomScanStats.mapError(NSError(domain: "MapperSelfTest", code: 7))
        var isRoomPlanFailed = false
        if case .roomPlanFailed = unknown { isRoomPlanFailed = true }
        check(&failures, "mapError.unknown", isRoomPlanFailed, "got \(unknown)")
        check(&failures, "mapError.mapper", RoomScanStats.mapError(MapperError.lowMemory) == .lowMemory, "not passed through")
        check(&failures, "mapError.cancelled", RoomScanStats.mapError(CancellationError()) == .cancelled, "not cancelled")
        let pathError = NSError(domain: NSCocoaErrorDomain, code: 4,
                                userInfo: [NSFilePathErrorKey: "/private/var/secret/room.json"])
        let text = RoomScanStats.describe(pathError)
        check(&failures, "describe.noPath", !text.contains("/private") && !text.contains("secret"), text)
        check(&failures, "describe.capture", RoomScanStats.describe(RoomCaptureSession.CaptureError.deviceTooHot)
              == "CaptureError.deviceTooHot", RoomScanStats.describe(RoomCaptureSession.CaptureError.deviceTooHot))
        check(&failures, "isDeviceTooHot", RoomScanStats.isDeviceTooHot(RoomCaptureSession.CaptureError.deviceTooHot)
              && !RoomScanStats.isDeviceTooHot(RoomCaptureSession.CaptureError.internalError)
              && !RoomScanStats.isDeviceTooHot(nil), "wrong")
    }

    /// `counts` of the fixture and the detection tracker's once-per-element rule.
    private static func checkCountsAndDetections(_ failures: inout [String]) {
        let room = fixtureRoom()
        let c = RoomScanStats.counts(room)
        check(&failures, "counts.walls", c.walls == 3, "\(c.walls)")
        check(&failures, "counts.doors", c.doors == 2, "\(c.doors)")
        check(&failures, "counts.windows", c.windows == 1, "\(c.windows)")
        check(&failures, "counts.openings", c.openings == 1, "\(c.openings)")
        check(&failures, "counts.objects", c.objects == 2, "\(c.objects)")
        let live = RoomLiveCounts(c)
        var expectedLive = RoomLiveCounts()
        expectedLive.walls = 3
        expectedLive.doors = 2
        expectedLive.windows = 1
        expectedLive.openings = 1
        expectedLive.objects = 2
        check(&failures, "counts.live", live == expectedLive, "\(live)")

        var tracker = RoomDetectionTracker()
        tracker.observe(room)
        let first = tracker.take()
        check(&failures, "detections.first", first.walls == 3 && first.doors == 2 && first.windows == 1, "\(first)")
        tracker.observe(room)
        let again = tracker.take()
        check(&failures, "detections.repeat", again.walls == 0 && again.doors == 0 && again.windows == 0, "\(again)")
        tracker.observe(fixtureRoom(extraDoor: true))
        let extra = tracker.take()
        check(&failures, "detections.newDoor", extra.walls == 0 && extra.doors == 1 && extra.windows == 0, "\(extra)")
    }

    /// `accumulate` sums per instruction and ignores bad deltas.
    private static func checkAccumulate(_ failures: inout [String]) {
        var seconds: [String: Double] = [:]
        RoomScanStats.accumulate(&seconds, instruction: "slowDown", delta: 1.5)
        RoomScanStats.accumulate(&seconds, instruction: "normal", delta: 4)
        RoomScanStats.accumulate(&seconds, instruction: "slowDown", delta: 2)
        RoomScanStats.accumulate(&seconds, instruction: "slowDown", delta: -3)
        RoomScanStats.accumulate(&seconds, instruction: "turnOnLight", delta: .nan)
        check(&failures, "accumulate.sum", seconds["slowDown"] == 3.5, "\(seconds)")
        check(&failures, "accumulate.other", seconds["normal"] == 4, "\(seconds)")
        check(&failures, "accumulate.ignored", seconds["turnOnLight"] == nil && seconds.count == 2, "\(seconds)")
    }

    /// A status with every live signal set to an extreme value.
    static func extremeStatus(tracking: TrackingSummary, thermal: ThermalLevel) -> HubStatus {
        var status = HubStatus()
        status.tracking = tracking
        status.thermal = thermal
        status.angularSpeed = 5
        status.linearSpeed = 3
        status.centerDistance = 0.1
        status.ambientIntensity = 10
        status.depthConfidenceMean = 0
        return status
    }

    /// `guidanceInput` copies only tracking, heat and detections; the engine and filter then
    /// never raise the messages RoomPlan's coaching owns, while heat and detections work.
    private static func checkGuidance(_ failures: inout [String]) {
        let input = RoomScanStats.guidanceInput(time: 3, status: extremeStatus(tracking: .excessiveMotion, thermal: .serious),
                                                newDoors: 2, newWindows: 1, newWalls: 3)
        check(&failures, "guidanceInput.tracking", input.tracking == .excessiveMotion, "\(input.tracking)")
        check(&failures, "guidanceInput.hot", input.deviceHot, "deviceHot false at serious")
        check(&failures, "guidanceInput.counts", input.newDoors == 2 && input.newWindows == 1 && input.newWalls == 3,
              "\(input.newDoors) \(input.newWindows) \(input.newWalls)")
        check(&failures, "guidanceInput.speeds", input.angularSpeed == 0 && input.linearSpeed == 0,
              "\(input.angularSpeed) \(input.linearSpeed)")
        check(&failures, "guidanceInput.nils", input.centerDistance == nil && input.ambientIntensity == nil
              && input.depthConfidenceMean == nil, "a live signal was copied")
        check(&failures, "guidanceInput.time", input.time == 3, "\(input.time)")
        let fair = RoomScanStats.guidanceInput(time: 0, status: extremeStatus(tracking: .normal, thermal: .fair),
                                               newDoors: -1, newWindows: 0, newWalls: 0)
        check(&failures, "guidanceInput.fair", !fair.deviceHot && fair.newDoors == 0, "fair counted as hot")

        let owned: Set<GuidanceKind> = [.moveSlower, .tooClose, .tooFar, .moveCloser, .lightingPoor]
        var engine = GuidanceEngine()
        var seen = Set<GuidanceKind>()
        for tick in 0..<80 {
            let t = Double(tick) * 0.25
            let step = RoomScanStats.guidanceInput(time: t, status: extremeStatus(tracking: .normal, thermal: .nominal),
                                                   newDoors: 0, newWindows: 0, newWalls: 0)
            if let kind = engine.update(step).message { seen.insert(kind) }
        }
        check(&failures, "guidance.roomPlanOwned", seen.isDisjoint(with: owned), "shown \(seen)")

        var hotEngine = GuidanceEngine()
        var hotShown = false
        for tick in 0..<40 {
            let t = Double(tick) * 0.25
            let step = RoomScanStats.guidanceInput(time: t, status: extremeStatus(tracking: .normal, thermal: .serious),
                                                   newDoors: 0, newWindows: 0, newWalls: 0)
            let output = GuidanceFilter(roomPlanCoaching: true).filter(hotEngine.update(step))
            if output.message == .deviceHot { hotShown = true }
        }
        check(&failures, "guidance.hotWhileCoaching", hotShown, "deviceHot never passed the coaching filter")

        let door = RoomScanStats.guidanceInput(time: 1, status: extremeStatus(tracking: .normal, thermal: .nominal),
                                               newDoors: 1, newWindows: 0, newWalls: 0)
        var coachingEngine = GuidanceEngine()
        let coached = GuidanceFilter(roomPlanCoaching: true).filter(coachingEngine.update(door))
        var quietEngine = GuidanceEngine()
        let quiet = GuidanceFilter(roomPlanCoaching: false).filter(quietEngine.update(door))
        check(&failures, "guidance.doorSuppressed", coached.message == nil, "\(String(describing: coached.message))")
        check(&failures, "guidance.doorShown", quiet.message == .doorDetected, "\(String(describing: quiet.message))")
    }

    /// A snapshot built from fixed inputs.
    private static func checkSnapshot(_ failures: inout [String]) {
        var status = HubStatus()
        status.tracking = .normal
        status.degraded = .depthStripped
        status.thermal = .fair
        status.elapsed = 12
        status.freeBytes = 5_000_000_000
        status.availableMemory = 1_000_000_000
        var counts = RoomLiveCounts()
        counts.walls = 4
        counts.doors = 2
        counts.windows = 1
        counts.openings = 1
        counts.objects = 3
        var stats = RecorderStats()
        stats.meshFaces = 1000
        stats.keyframes = 7
        stats.photos = 2
        let s = RoomScanStats.snapshot(timestamp: 42, status: status, counts: counts, recorders: stats, guidance: .doorDetected)
        let wallsAndDoors: Bool = s.wallCount == 4 && s.doorCount == 2
        let windowsAndRest: Bool = s.windowCount == 1 && s.openingCount == 1 && s.objectCount == 3
        check(&failures, "snapshot.counts", wallsAndDoors && windowsAndRest, "\(s)")
        check(&failures, "snapshot.degraded", s.degraded == .depthStripped, "\(s.degraded)")
        check(&failures, "snapshot.guidance", s.guidanceRawValue == "doorDetected" && s.guidance == .doorDetected,
              "\(String(describing: s.guidanceRawValue))")
        check(&failures, "snapshot.recorders", s.meshFaceCount == 1000 && s.keyframeCount == 7 && s.photoCount == 2, "\(s)")
        let expectedFree: Int64 = 5_000_000_000
        let expectedMemory: UInt64 = 1_000_000_000
        let storageOK: Bool = s.freeBytes == expectedFree && s.availableMemory == expectedMemory
        let timesOK: Bool = s.elapsed == 12 && s.timestamp == 42
        check(&failures, "snapshot.device", s.thermal == .fair && storageOK && timesOK, "\(s)")
        let none = RoomScanStats.snapshot(timestamp: 0, status: status, counts: counts, recorders: stats, guidance: nil)
        check(&failures, "snapshot.noGuidance", none.guidanceRawValue == nil, "\(String(describing: none.guidanceRawValue))")
    }

    /// `next` for every signal from the states it applies to (and some it does not).
    private static func checkStateMachine(_ failures: inout [String]) {
        let cases: [(ScanEngineState, RoomEngineSignal, ScanEngineState)] = [
            (.idle, .start, .starting), (.finished, .start, .starting), (.scanning, .start, .scanning),
            (.starting, .didStart, .scanning), (.paused, .didStart, .paused), (.idle, .didStart, .idle),
            (.scanning, .pause, .paused), (.starting, .pause, .paused), (.idle, .pause, .idle), (.stopping, .pause, .stopping),
            (.paused, .interruptionEnded, .paused), (.scanning, .interruptionEnded, .scanning),
            (.paused, .resume, .scanning), (.scanning, .resume, .scanning), (.stopping, .resume, .stopping),
            (.scanning, .finish, .stopping), (.paused, .finish, .stopping), (.starting, .finish, .stopping),
            (.idle, .finish, .idle), (.finished, .finish, .finished),
            (.stopping, .sealed, .finished), (.scanning, .sealed, .finished), (.idle, .sealed, .idle),
            (.stopping, .failure, .failed), (.scanning, .failure, .failed), (.finished, .failure, .finished),
            (.idle, .failure, .idle),
            (.stopping, .cancel, .idle), (.scanning, .cancel, .idle), (.failed, .cancel, .idle),
        ]
        for (from, signal, to) in cases {
            let got = RoomScanStats.next(from, on: signal)
            check(&failures, "next.\(from.rawValue).\(signal)", got == to, "expected \(to.rawValue), got \(got.rawValue)")
        }
        check(&failures, "isCapturing", RoomScanStats.isCapturing(.paused) && !RoomScanStats.isCapturing(.stopping)
              && !RoomScanStats.isCapturing(.idle), "wrong")
    }

    /// `finishSteps` is exactly the 11 steps in order, seal after closeWriter, emit last.
    private static func checkFinishSteps(_ failures: inout [String]) {
        let steps = RoomScanStats.finishSteps
        let expected: [RoomFinishStep] = [.writeRoomData, .buildRoom, .saveWorldMap, .detachRecorders, .finishRecorders,
                                          .writeLogs, .flushWriter, .closeWriter, .seal, .pauseIfSystemStop,
                                          .emitRoomFinished]
        check(&failures, "finishSteps.order", steps == expected, "\(steps.map { $0.rawValue })")
        check(&failures, "finishSteps.all", steps.count == 11 && Set(steps) == Set(RoomFinishStep.allCases), "\(steps.count)")
        let seal = steps.firstIndex(of: .seal) ?? -1
        let close = steps.firstIndex(of: .closeWriter) ?? Int.max
        let flush = steps.firstIndex(of: .flushWriter) ?? Int.max
        let finishRecorders = steps.firstIndex(of: .finishRecorders) ?? Int.max
        check(&failures, "finishSteps.sealAfterClose", seal > close && close > flush && flush > finishRecorders, "\(seal) \(close)")
        check(&failures, "finishSteps.dataFirst", steps.first == .writeRoomData, "\(String(describing: steps.first))")
        check(&failures, "finishSteps.emitLast", steps.last == .emitRoomFinished, "\(String(describing: steps.last))")
    }

    /// `systemStopReason` for heat, storage, memory and all good.
    private static func checkSystemStops(_ failures: inout [String]) {
        check(&failures, "stop.thermal", RoomScanStats.systemStopReason(thermal: .critical, storage: .ok, memory: .ok)
              == .deviceTooHot, "not deviceTooHot")
        check(&failures, "stop.storage", RoomScanStats.systemStopReason(thermal: .nominal, storage: .pause, memory: .ok)
              == .lowStorage(freeBytes: 0), "not lowStorage")
        check(&failures, "stop.memory", RoomScanStats.systemStopReason(thermal: .nominal, storage: .ok, memory: .critical)
              == .lowMemory, "not lowMemory")
        check(&failures, "stop.none", RoomScanStats.systemStopReason(thermal: .nominal, storage: .ok, memory: .ok) == nil,
              "stopped while all good")
        check(&failures, "stop.warningsOnly",
              RoomScanStats.systemStopReason(thermal: .serious, storage: .stopKeyframes, memory: .low) == nil,
              "stopped on warnings")
    }

    /// Which errors build the room, the degraded mode and the notice after the seal.
    private static func checkRoomOutcome(_ failures: inout [String]) {
        let tooLarge = RoomCaptureSession.CaptureError.exceedSceneSizeLimit
        let internalError = RoomCaptureSession.CaptureError.internalError
        check(&failures, "build.none", RoomScanStats.shouldBuildRoom(after: nil), "false")
        check(&failures, "build.sceneTooLarge", RoomScanStats.shouldBuildRoom(after: tooLarge), "false")
        check(&failures, "build.hot", RoomScanStats.shouldBuildRoom(after: RoomCaptureSession.CaptureError.deviceTooHot), "false")
        check(&failures, "build.internal", !RoomScanStats.shouldBuildRoom(after: internalError), "true")
        check(&failures, "build.unsupported",
              !RoomScanStats.shouldBuildRoom(after: RoomCaptureSession.CaptureError.deviceNotSupported), "true")
        check(&failures, "build.foreign", !RoomScanStats.shouldBuildRoom(after: NSError(domain: "x", code: 1)), "true")
        check(&failures, "degraded.keep", RoomScanStats.degradedMode(hub: .depthStripped, hasRoomData: true, error: nil)
              == .depthStripped, "changed")
        check(&failures, "degraded.noData", RoomScanStats.degradedMode(hub: .allGood, hasRoomData: false, error: nil)
              == .roomPlanFailed, "not roomPlanFailed")
        check(&failures, "degraded.internal", RoomScanStats.degradedMode(hub: .allGood, hasRoomData: true, error: internalError)
              == .roomPlanFailed, "not roomPlanFailed")
        check(&failures, "degraded.sceneTooLarge", RoomScanStats.degradedMode(hub: .meshStripped, hasRoomData: true,
                                                                               error: tooLarge) == .meshStripped, "changed")
        check(&failures, "notice.systemStop", RoomScanStats.notice(systemStop: .lowMemory, error: tooLarge,
                                                                   pending: nil, hasRoomData: true) == .lowMemory, "wrong")
        check(&failures, "notice.error", RoomScanStats.notice(systemStop: nil, error: tooLarge, pending: .trackingFailed,
                                                              hasRoomData: true) == .sceneTooLarge, "wrong")
        check(&failures, "notice.pending", RoomScanStats.notice(systemStop: nil, error: nil, pending: .trackingFailed,
                                                                hasRoomData: true) == .trackingFailed, "wrong")
        check(&failures, "notice.none", RoomScanStats.notice(systemStop: nil, error: nil, pending: nil,
                                                             hasRoomData: true) == nil, "not nil")
        let noData = RoomScanStats.notice(systemStop: nil, error: nil, pending: nil, hasRoomData: false)
        var noDataIsRoomPlan = false
        if case .roomPlanFailed? = noData { noDataIsRoomPlan = true }
        check(&failures, "notice.noData", noDataIsRoomPlan, "\(String(describing: noData))")
        let configNotice = RoomScanStats.mapError(RoomCaptureSession.CaptureError.invalidARConfiguration)
        check(&failures, "notice.droppedWhenBuilt", RoomScanStats.finalNotice(configNotice, roomBuilt: true) == nil,
              "roomPlanFailed sent although the room was built")
        check(&failures, "notice.keptWhenNotBuilt", RoomScanStats.finalNotice(configNotice, roomBuilt: false) == configNotice,
              "roomPlanFailed dropped without a room")
        check(&failures, "notice.otherKept", RoomScanStats.finalNotice(.sceneTooLarge, roomBuilt: true) == .sceneTooLarge,
              "sceneTooLarge dropped")
    }

    /// World map rule, throttles and elapsed time.
    private static func checkSmallHelpers(_ failures: inout [String]) {
        check(&failures, "worldMap.mapped", RoomScanStats.shouldSaveWorldMap(.mapped), "false")
        check(&failures, "worldMap.extending", RoomScanStats.shouldSaveWorldMap(.extending), "false")
        check(&failures, "worldMap.limited", !RoomScanStats.shouldSaveWorldMap(.limited), "true")
        check(&failures, "worldMap.notAvailable", !RoomScanStats.shouldSaveWorldMap(.notAvailable), "true")
        let names: [ARFrame.WorldMappingStatus] = [.notAvailable, .limited, .extending, .mapped]
        check(&failures, "worldMap.names", Set(names.map { RoomScanStats.worldMappingName($0) }).count == 4, "not distinct")
        check(&failures, "isDue.first", RoomScanStats.isDue(now: 0, last: nil, interval: 10), "false")
        check(&failures, "isDue.early", !RoomScanStats.isDue(now: 19.9, last: 10, interval: 10), "true")
        check(&failures, "isDue.onTime", RoomScanStats.isDue(now: 20, last: 10, interval: 10), "false")
        check(&failures, "elapsed.unknown", RoomScanStats.elapsed(start: nil, latest: 5) == 0, "not 0")
        check(&failures, "elapsed.value", RoomScanStats.elapsed(start: 2, latest: 7.5) == 5.5, "not 5.5")
        check(&failures, "elapsed.backwards", RoomScanStats.elapsed(start: 5, latest: 3) == 0, "not 0")
        check(&failures, "copy.nonEmpty", !Copy.RoomCapture.sceneTooLarge.title.isEmpty
              && !Copy.RoomCapture.roomPlanFailed.body.isEmpty && !Copy.RoomCapture.tooHotFinished.title.isEmpty
              && !Copy.RoomCapture.lowMemory.body.isEmpty, "an empty string")
    }
}
