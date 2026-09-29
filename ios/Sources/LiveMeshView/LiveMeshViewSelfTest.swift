import Foundation

// Self-test of the LiveMeshView module (docs/MODULES.md 3.32, section 0.5): the engine's pure
// rules, the target factories, the recorder set, the sealed mesh-pass lookup (in a temporary
// package, LiveMeshViewSelfTest+Files.swift) and the copy strings. Deterministic, no ARKit
// session, camera or network; the recorders are created but never fed; files only under the
// temporary directory, removed afterwards. Returns one line per failing check.

/// `LiveMeshViewSelfTest.run()`: empty when every check passes.
enum LiveMeshViewSelfTest {
    /// Runs every check (nonisolated; the Diagnostics suite calls it off the main actor).
    static func run() -> [String] {
        var f: [String] = []
        checkStateMachine(&f)
        checkFinishSteps(&f)
        checkGuidanceAndSnapshot(&f)
        checkSystemStops(&f)
        checkTargets(&f)
        checkStartProblems(&f)
        checkSmallRules(&f)
        checkRecorderSet(&f)
        checkFolders(&f)
        checkCopy(&f)
        return f
    }

    /// Appends "name: detail" when `ok` is false.
    static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    /// A fixed UUID whose last byte is `n` (deterministic ids without force unwraps).
    static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x4C, 0x4D, 0x56, 0x53, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    /// A package helper under a fixed path (no IO).
    static let samplePackage = ProjectPackage(root: URL(fileURLWithPath: "/tmp/LiveMeshViewSample.mapperproj", isDirectory: true))

    // MARK: - Checks 1 and 2: state machine

    /// `next` for the start, pause and resume path, the finish path and the notices.
    private static func checkStateMachine(_ f: inout [String]) {
        let n = MeshScanStats.next
        check(&f, "next.start", n(.idle, .start) == .starting, "\(n(.idle, .start))")
        check(&f, "next.firstFrame", n(.starting, .firstFrame) == .scanning, "\(n(.starting, .firstFrame))")
        check(&f, "next.pause", n(.scanning, .pause) == .paused, "\(n(.scanning, .pause))")
        check(&f, "next.interruptionEnded", n(.paused, .interruptionEnded) == .paused, "\(n(.paused, .interruptionEnded))")
        check(&f, "next.resume", n(.paused, .resume) == .scanning, "\(n(.paused, .resume))")
        check(&f, "next.finish", n(.scanning, .finish) == .stopping, "\(n(.scanning, .finish))")
        check(&f, "next.sealed", n(.stopping, .sealed) == .finished, "\(n(.stopping, .sealed))")
        check(&f, "next.failure", n(.scanning, .failure) == .failed, "\(n(.scanning, .failure))")
        check(&f, "next.cancel", n(.scanning, .cancel) == .idle, "\(n(.scanning, .cancel))")
        check(&f, "next.noticeAfterSeal", n(.finished, .failure) == .finished, "\(n(.finished, .failure))")
        check(&f, "next.firstFrameWhilePaused", n(.paused, .firstFrame) == .paused, "\(n(.paused, .firstFrame))")
    }

    // MARK: - Check 3: finish steps

    /// The 9 steps in order, the seal after the writer's close, `emitRoomFinished` last.
    private static func checkFinishSteps(_ f: inout [String]) {
        let steps = MeshScanStats.finishSteps
        let expected: [MeshFinishStep] = [.detachRecorders, .finishRecorders, .writeAttachments, .writeLogs,
                                          .flushWriter, .closeWriter, .seal, .pauseIfSystemStop, .emitRoomFinished]
        check(&f, "finishSteps.order", steps == expected, "\(steps.map { $0.rawValue })")
        check(&f, "finishSteps.all", Set(steps) == Set(MeshFinishStep.allCases) && steps.count == 9, "\(steps.count)")
        let close = steps.firstIndex(of: .closeWriter) ?? -1
        let seal = steps.firstIndex(of: .seal) ?? -1
        let finishRecorders = steps.firstIndex(of: .finishRecorders) ?? -1
        check(&f, "finishSteps.sealAfterClose", close >= 0 && seal == close + 1, "close \(close), seal \(seal)")
        check(&f, "finishSteps.recordersBeforeSeal", finishRecorders >= 0 && finishRecorders < seal, "\(finishRecorders)")
        check(&f, "finishSteps.emitLast", steps.last == .emitRoomFinished, "\(String(describing: steps.last))")
    }

    // MARK: - Checks 4 and 5: guidance input and snapshot

    /// A status with every guidance field set.
    static func sampleStatus(thermal: ThermalLevel) -> HubStatus {
        var status = HubStatus()
        status.tracking = .excessiveMotion
        status.degraded = .depthStripped
        status.thermal = thermal
        status.freeBytes = 7_000_000_000
        status.availableMemory = 900_000_000
        status.angularSpeed = 1.75
        status.linearSpeed = 0.5
        status.centerDistance = 2.25
        status.depthConfidenceMean = 0.4
        status.ambientIntensity = 250
        status.elapsed = 42.5
        return status
    }

    /// `guidanceInput` copies every mesh-mode signal; deviceHot only at serious and critical;
    /// `snapshot` takes counters, device state and the guidance raw value.
    private static func checkGuidanceAndSnapshot(_ f: inout [String]) {
        let input = MeshScanStats.guidanceInput(time: 12, status: sampleStatus(thermal: .fair))
        let trackingOK: Bool = input.tracking == GuidanceTracking.excessiveMotion
        let speedsOK: Bool = input.angularSpeed == Float(1.75) && input.linearSpeed == Float(0.5)
        let copied: Bool = input.time == Double(12) && trackingOK && speedsOK
        let distanceOK: Bool = input.centerDistance == Float(2.25) && input.depthConfidenceMean == Float(0.4)
        let depth: Bool = distanceOK && input.ambientIntensity == Float(250)
        check(&f, "guidanceInput.copies", copied && depth && !input.deviceHot,
              "tracking \(input.tracking), speeds \(input.angularSpeed) \(input.linearSpeed)")
        let hot: [Bool] = ThermalLevel.allCases.map {
            MeshScanStats.guidanceInput(time: 0, status: sampleStatus(thermal: $0)).deviceHot
        }
        let expectedHot: [Bool] = ThermalLevel.allCases.map { $0 == .serious || $0 == .critical }
        check(&f, "guidanceInput.deviceHot", hot == expectedHot, "\(hot)")

        var stats = RecorderStats()
        stats.meshFaces = 12_345
        stats.keyframes = 17
        stats.photos = 3
        let snap = MeshScanStats.snapshot(timestamp: 99.5, status: sampleStatus(thermal: .serious), recorders: stats,
                                          guidance: .moveSlower)
        let counters: Bool = snap.meshFaceCount == 12_345 && snap.keyframeCount == 17 && snap.photoCount == 3
        let thermalOK: Bool = snap.thermal == ThermalLevel.serious && snap.degraded == DegradedMode.depthStripped
        let device: Bool = thermalOK && snap.tracking == TrackingSummary.excessiveMotion
        let times: Bool = snap.elapsed == Double(42.5) && snap.timestamp == Double(99.5)
        let memory: Bool = snap.freeBytes == Int64(7_000_000_000) && snap.availableMemory == UInt64(900_000_000)
        let guidanceOK: Bool = snap.guidance == GuidanceKind.moveSlower
        check(&f, "snapshot.fields", counters && device && times && memory && guidanceOK,
              "faces \(snap.meshFaceCount), keyframes \(snap.keyframeCount), guidance \(String(describing: snap.guidanceRawValue))")
        let quiet = MeshScanStats.snapshot(timestamp: 0, status: HubStatus(), recorders: RecorderStats(), guidance: nil)
        check(&f, "snapshot.noGuidance", quiet.guidanceRawValue == nil && quiet.wallCount == 0, "\(quiet)")
    }

    // MARK: - Check 6: system stops

    /// Heat, storage, memory and all good.
    private static func checkSystemStops(_ f: inout [String]) {
        let heat = MeshScanStats.systemStopReason(thermal: .critical, storage: .ok, memory: .ok)
        check(&f, "systemStop.thermal", heat == .deviceTooHot, "\(String(describing: heat))")
        let storage = MeshScanStats.systemStopReason(thermal: .serious, storage: .pause, memory: .ok)
        check(&f, "systemStop.storage", storage == .lowStorage(freeBytes: 0), "\(String(describing: storage))")
        let memory = MeshScanStats.systemStopReason(thermal: .fair, storage: .stopKeyframes, memory: .critical)
        check(&f, "systemStop.memory", memory == .lowMemory, "\(String(describing: memory))")
        let none = MeshScanStats.systemStopReason(thermal: .serious, storage: .stopKeyframes, memory: .low)
        check(&f, "systemStop.none", none == nil, "\(String(describing: none))")
        let notice = MeshScanStats.notice(systemStop: nil, pending: .trackingFailed)
        check(&f, "notice.pending", notice == .trackingFailed, "\(String(describing: notice))")
        let stopFirst = MeshScanStats.notice(systemStop: .lowMemory, pending: .trackingFailed)
        check(&f, "notice.systemStopFirst", stopFirst == .lowMemory, "\(String(describing: stopFirst))")
    }

    // MARK: - Checks 7 and 8: targets and validation

    /// Factories and `validationProblem`.
    private static func checkTargets(_ f: inout [String]) {
        let package = samplePackage
        let session = fixedID(1), room = fixedID(2), pass = fixedID(3), object = fixedID(4)
        let patch = MeshScanTarget.patchPass(projectID: fixedID(9), package: package, sessionID: session, roomID: room,
                                             mode: .house, settings: .room, passID: pass)
        let patchIDs: Bool = patch.roomID == room && patch.passID == pass
        let patchOK: Bool = patchIDs && patch.kind == RawScanKind.meshPass && patch.mode == ScanMode.house
        let patchURL = MeshScanStats.sameLocation(patch.destination, package.rawMeshPassURL(session: session, pass: pass))
        check(&f, "patchPass.fields", patchOK && patchURL, "\(patch.kind) \(patch.destination.path)")
        let large = MeshScanTarget.largeObject(projectID: fixedID(9), package: package, sessionID: session, objectID: object,
                                               settings: ScanSettings.defaults(for: .object))
        let largeIDs: Bool = large.passID == object && large.roomID == nil
        let largeOK: Bool = largeIDs && large.kind == RawScanKind.object && large.mode == ScanMode.object
        let largeURL = MeshScanStats.sameLocation(large.destination, package.rawObjectURL(object))
        check(&f, "largeObject.fields", largeOK && largeURL && large.scanInfoRoomID == object, "\(large.destination.path)")
        let space = MeshScanTarget.spaceScan(projectID: fixedID(9), package: package, sessionID: session,
                                             settings: ScanSettings.defaults(for: .advancedSpace), passID: pass)
        let spaceOK: Bool = space.kind == RawScanKind.meshPass && space.mode == ScanMode.advancedSpace
        check(&f, "spaceScan.fields", spaceOK && space.roomID == nil, "\(space.mode)")

        check(&f, "validation.patchPass", MeshScanStats.validationProblem(patch) == nil,
              MeshScanStats.validationProblem(patch) ?? "")
        check(&f, "validation.largeObject", MeshScanStats.validationProblem(large) == nil,
              MeshScanStats.validationProblem(large) ?? "")
        check(&f, "validation.spaceScan", MeshScanStats.validationProblem(space) == nil,
              MeshScanStats.validationProblem(space) ?? "")
        var objectInPassFolder = large
        objectInPassFolder.destination = package.rawMeshPassURL(session: session, pass: object)
        check(&f, "validation.objectDestination", MeshScanStats.validationProblem(objectInPassFolder) != nil, "accepted")
        var outside = patch
        outside.destination = URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true)
            .appendingPathComponent(pass.uuidString, isDirectory: true)
        check(&f, "validation.outsidePackage", MeshScanStats.validationProblem(outside) != nil, "accepted")
        var quick = patch
        quick.mode = .quickMeasure
        check(&f, "validation.quickMeasure", MeshScanStats.validationProblem(quick) != nil, "accepted")
        var passAsObject = patch
        passAsObject.mode = .object
        check(&f, "validation.meshPassObjectMode", MeshScanStats.validationProblem(passAsObject) != nil, "accepted")
        var roomKind = patch
        roomKind.kind = .room
        check(&f, "validation.roomKind", MeshScanStats.validationProblem(roomKind) != nil, "accepted")
    }

    // MARK: - Check 18: start problems

    /// `startProblem` in its order: invalid target, no mesh, low storage, fine.
    private static func checkStartProblems(_ f: inout [String]) {
        let valid = MeshScanTarget.patchPass(projectID: fixedID(9), package: samplePackage, sessionID: fixedID(1),
                                             roomID: fixedID(2), mode: .room, settings: .room, passID: fixedID(3))
        var invalid = valid
        invalid.mode = .quickMeasure
        let gb: Int64 = 1_000_000_000
        let bad = MeshScanStats.startProblem(invalid, supportsMesh: true, freeBytes: 5 * gb)
        var badIsIO = false
        if case .ioFailed? = bad { badIsIO = true }
        check(&f, "startProblem.invalidTarget", badIsIO, "\(String(describing: bad))")
        let noMesh = MeshScanStats.startProblem(valid, supportsMesh: false, freeBytes: 5 * gb)
        check(&f, "startProblem.noMesh", noMesh == .unsupportedDevice, "\(String(describing: noMesh))")
        let low = MeshScanStats.startProblem(valid, supportsMesh: true, freeBytes: gb)
        check(&f, "startProblem.lowStorage", low == .lowStorage(freeBytes: gb), "\(String(describing: low))")
        let fine = MeshScanStats.startProblem(valid, supportsMesh: true, freeBytes: 5 * gb)
        check(&f, "startProblem.fine", fine == nil, "\(String(describing: fine))")
    }

    // MARK: - Checks 9, 10, 11, 17: small rules

    /// Frame gaps, attachment names, the log, the teardown pause rule and the timer parts.
    private static func checkSmallRules(_ f: inout [String]) {
        let gap = MeshScanStats.shouldReapplyForFrameGap
        check(&f, "frameGap.due", gap(101.6, 100, false, true), "not due")
        check(&f, "frameGap.tried", !gap(101.6, 100, true, true), "due again")
        check(&f, "frameGap.paused", !gap(101.6, 100, false, false), "due while paused")
        check(&f, "frameGap.noFrame", !gap(101.6, nil, false, true), "due without a frame")
        check(&f, "frameGap.short", !gap(101.0, 100, false, true), "due after 1 s")

        let safe = MeshScanStats.isSafeAttachmentName
        check(&f, "attachment.safe", safe("largeobject.json"), "refused")
        let refusedNames = ["../x", "a/b.json", "", "SEAL.json", "roomlog.json", "scan.json", "events.jsonl",
                      "keyframes.jsonl", "photos.jsonl", "poses.ptrk", "seal.json", ".hidden"]
        let accepted = refusedNames.filter { safe($0) }
        check(&f, "attachment.unsafe", accepted.isEmpty, "\(accepted)")

        let log = MeshScanStats.log(seconds: 83.5, relocalizations: 2, limitedFraction: 0.25, degraded: .depthStripped,
                                    error: "error.deviceTooHot")
        let logCounts: Bool = log.seconds == Double(83.5) && log.instructionSeconds.isEmpty && log.relocalizations == 2
        let logRest: Bool = log.limitedTrackingFraction == Double(0.25) && log.degraded == DegradedMode.depthStripped
        check(&f, "log.fields", logCounts && logRest && log.error == "error.deviceTooHot", "\(log)")
        let clamped = MeshScanStats.log(seconds: -1, relocalizations: -3, limitedFraction: 4, degraded: .allGood, error: nil)
        let clampedCounts: Bool = clamped.seconds == Double(0) && clamped.relocalizations == 0
        let clampedRest: Bool = clamped.limitedTrackingFraction == Double(1) && clamped.error == nil
        check(&f, "log.clamped", clampedCounts && clampedRest, "\(clamped)")

        check(&f, "teardown.owned", MeshScanStats.pausesHubOnTeardown(ownsHub: true), "not paused")
        check(&f, "teardown.borrowed", !MeshScanStats.pausesHubOnTeardown(ownsHub: false), "paused")

        let parts = MeshScanModel.elapsedParts(245.7)
        check(&f, "elapsed.parts", parts.minutes == 4 && parts.seconds == 5, "\(parts)")
        let negative = MeshScanModel.elapsedParts(-3)
        check(&f, "elapsed.negative", negative.minutes == 0 && negative.seconds == 0, "\(negative)")
        let due: Bool = MeshScanStats.isDue(now: 10.1, last: 10.0, interval: 0.099)
        let early: Bool = MeshScanStats.isDue(now: 10.05, last: 10.0, interval: 0.1)
        let backwards: Bool = MeshScanStats.isDue(now: 9.0, last: 10.0, interval: 0.1)
        check(&f, "camera.due", due && !early && backwards, "due \(due), early \(early), backwards \(backwards)")
    }

    // MARK: - Check 12: recorder set

    /// Order and identity of `MeshScanRecorderSet.all`.
    private static func checkRecorderSet(_ f: inout [String]) {
        let extra = LiveMeshSelfTestRecorder()
        let mesh = MeshStore()
        let withPhotos = MeshScanRecorderSet(photos: true, mesh: mesh, extra: [extra])
        let all = withPhotos.all
        var order = false
        if all.count == 5 {
            let standard: Bool = all[0] === mesh && all[1] === withPhotos.keyframes && all[2] === withPhotos.poses
            let rest: Bool = all[3] is PhotoRecorder && all[4] === extra
            order = standard && rest
        }
        check(&f, "recorderSet.withPhotos", order && withPhotos.photos != nil, "\(all.count) recorders")
        let plain = MeshScanRecorderSet(photos: false)
        let plainAll = plain.all
        let hasPhoto: Bool = plainAll.contains { $0 is PhotoRecorder }
        let noPhoto: Bool = plainAll.count == 4 && !hasPhoto && plain.photos == nil
        let meshFirst: Bool = plainAll.first === plain.mesh
        check(&f, "recorderSet.withoutPhotos", noPhoto && meshFirst, "\(plainAll.count) recorders")
    }

    // MARK: - Check 16: copy

    /// Every string of the screens and the Diagnostics toggle is non-empty.
    private static func checkCopy(_ f: inout [String]) {
        let strings = [Copy.LiveMeshView.saving, Copy.LiveMeshView.debugViewToggle, Copy.LiveMeshView.debugViewFooter,
                       Copy.LiveMeshView.elapsedLabel, Copy.Scanning.paused, Copy.Scanning.resume,
                       Copy.Scanning.startingUp, Copy.Scanning.done, Copy.Scanning.cancel, Copy.Scanning.photoSaved,
                       Copy.A11y.scanView, Copy.A11y.doneScanning, Copy.ScanUI.elapsed(minutes: 1, seconds: 5)]
        let empty = strings.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        check(&f, "copy.nonEmpty", empty.isEmpty, "\(empty.count) empty")
        check(&f, "copy.settingsKey", SettingsKey.liveMeshDebugView == "liveMeshDebugView", SettingsKey.liveMeshDebugView)
    }
}

/// A recorder that records nothing (the self-test's extra recorder).
final class LiveMeshSelfTestRecorder: ScanRecorder {
    /// Nothing to begin.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {}
    /// Completes at once.
    func finishRecording(completion: @escaping () -> Void) { completion() }
    /// No counters.
    var stats: RecorderStats { RecorderStats() }
}
