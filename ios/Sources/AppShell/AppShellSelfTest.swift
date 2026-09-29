import Foundation

/// Plain-Swift checks for AppShell (no XCTest), run from the Diagnostics suite list off the main
/// actor. Deterministic: fixed ids and dates; files only in one folder under
/// `FileManager.default.temporaryDirectory`, removed before and after; no ARKit, camera or
/// network. Covers `ProcessingPlans.roomSteps` (order, subjects, optional flags, dependencies,
/// when BuildRoomStep is scheduled, several rooms, object projects), the enqueue, resume and
/// outcome status rules, `RecoveryService.reconcile` and the recovery file helpers.
enum AppShellSelfTest {
    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AppShellSelfTest", isDirectory: true)
        try? fm.removeItem(at: root)
        defer { try? fm.removeItem(at: root) }
        do {
            let package = ProjectPackage(root: root.appendingPathComponent("P." + ProjectPackage.fileExtension, isDirectory: true))
            try makeFixture(package)
            planChecks(package, &failures)
            buildRoomChecks(package, &failures)
            recoveryFileChecks(package, &failures)
        } catch {
            failures.append("fixture: \(error)")
        }
        statusChecks(&failures)
        reconcileChecks(&failures)
        return failures
    }

    // MARK: - Fixtures

    /// 2026-09-28 12:00 UTC.
    private static let sep28 = Date(timeIntervalSince1970: 1_790_596_800)
    /// The capture session of every fixture room.
    private static let session = uuid(0xA0)
    /// Room with capturedroomdata.json only: gets BuildRoomStep.
    private static let roomNeedsBuild = uuid(1)
    /// Room whose raw capturedroom.json exists.
    private static let roomHasRoom = uuid(2)
    /// Room without capturedroomdata.json.
    private static let roomNoData = uuid(3)
    /// Room whose roomlog.json says `.roomPlanFailed`.
    private static let roomPlanFailed = uuid(4)
    /// Room whose roomlog.json is unreadable (data present): BuildRoomStep still runs.
    private static let roomBadLog = uuid(5)

    /// Records a failure when `ok` is false.
    private static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    /// A fixed UUID ending in `low`.
    private static func uuid(_ low: UInt8) -> UUID {
        UUID(uuid: (0x5A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, low))
    }

    /// A room record of the fixture session.
    private static func room(_ id: UUID, _ status: RoomStatus = .captured) -> RoomRecord {
        RoomRecord(id: id, name: "", sessionID: session, floorIndex: 0, status: status, capturedRoomID: nil,
                   quality: nil, hasMeshPass: false, keyframeCount: 0, capturedAt: sep28,
                   frameLink: .projectFrame(sessionID: session))
    }

    /// A manifest of `kind` with `rooms`.
    private static func manifest(_ rooms: [RoomRecord], kind: ScanMode = .room) -> ProjectManifest {
        var value = ProjectManifest.new(kind: kind, name: "Test", now: sep28)
        value.rooms = rooms
        value.status = .needsProcessing
        return value
    }

    /// Writes the raw room folders of the five fixture rooms.
    private static func makeFixture(_ package: ProjectPackage) throws {
        let data = Data("{}".utf8)
        let good = RoomCaptureLog(seconds: 30, instructionSeconds: [:], error: nil, relocalizations: 0,
                                  limitedTrackingFraction: 0, degraded: .allGood)
        var failed = good
        failed.degraded = .roomPlanFailed
        for id in [roomNeedsBuild, roomHasRoom, roomNoData, roomPlanFailed, roomBadLog] {
            let folder = RawScanFolder(url: package.rawRoomURL(session: session, room: id))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            if id != roomNoData {
                try data.write(to: folder.capturedRoomDataURL)
            }
            if id == roomHasRoom {
                try data.write(to: folder.capturedRoomURL)
            }
            if id == roomBadLog {
                try Data("not json".utf8).write(to: folder.roomLogURL)
            } else {
                try ProjectStore.writeJSON(id == roomPlanFailed ? failed : good, to: folder.roomLogURL)
            }
        }
    }

    // MARK: - Plans

    /// Step ids of a plan, in order.
    private static func ids(_ steps: [ScheduledStep]) -> [PipelineStepID] {
        steps.map { $0.stepID }
    }

    /// The step with `id` and `subject`, if any.
    private static func find(_ steps: [ScheduledStep], _ id: PipelineStepID, _ subject: UUID? = nil) -> ScheduledStep? {
        steps.first { $0.stepID == id && $0.subject == subject }
    }

    /// One captured room that needs BuildRoomStep: order, subjects, optional flags, dependencies.
    private static func planChecks(_ package: ProjectPackage, _ failures: inout [String]) {
        let room = roomNeedsBuild
        let steps = ProcessingPlans.roomSteps(manifest: manifest([self.room(room)]), package: package)
        let expected: [PipelineStepID] = [.buildRoom, .consolidateMesh, .cleanModel, .floorPlan, .quality, .thumbnail, .textureLow]
        check(&failures, "plan.order", ids(steps) == expected, "\(ids(steps).map { $0.rawValue })")

        let roomSubjects: [PipelineStepID] = [.buildRoom, .consolidateMesh, .quality, .textureLow]
        let projectSteps: [PipelineStepID] = [.cleanModel, .floorPlan, .thumbnail]
        let subjectsOK = steps.allSatisfy { step in
            roomSubjects.contains(step.stepID) ? step.subject == room : step.subject == nil
        }
        check(&failures, "plan.subjects", subjectsOK, steps.map { $0.key.logName }.joined(separator: " "))

        let optional: Set<PipelineStepID> = [.buildRoom, .consolidateMesh, .quality, .thumbnail, .textureLow]
        let flagsOK = steps.allSatisfy { $0.isOptional == optional.contains($0.stepID) }
        check(&failures, "plan.optional", flagsOK, steps.map { "\($0.stepID.rawValue)=\($0.isOptional)" }.joined(separator: " "))
        check(&failures, "plan.required", projectSteps.dropLast().allSatisfy { id in
            find(steps, id)?.isOptional == false
        }, "cleanModel and floorPlan must be required")

        let build = ScheduledStepKey(step: .buildRoom, subject: room)
        let clean = ScheduledStepKey(step: .cleanModel)
        let plan = ScheduledStepKey(step: .floorPlan)
        check(&failures, "plan.cleanDependsOnBuildRoom", find(steps, .cleanModel)?.dependsOn == [build],
              "\(find(steps, .cleanModel)?.dependsOn.map { $0.logName } ?? [])")
        check(&failures, "plan.floorPlanDependsOnClean", find(steps, .floorPlan)?.dependsOn == [clean], "floorPlan deps")
        check(&failures, "plan.thumbnailDependsOnPlan", find(steps, .thumbnail)?.dependsOn == [plan], "thumbnail deps")
        let independent: [PipelineStepID] = [.buildRoom, .consolidateMesh, .quality, .textureLow]
        let independentOK = independent.allSatisfy { find(steps, $0, room)?.dependsOn.isEmpty == true }
        check(&failures, "plan.independentSteps", independentOK, "buildRoom, consolidateMesh, quality, textureLow depend on nothing")

        // Two rooms: per-room steps for each, in manifest order; BuildRoomStep only where needed.
        let two = ProcessingPlans.roomSteps(manifest: manifest([self.room(roomNeedsBuild), self.room(roomNoData)]),
                                            package: package)
        let consolidated = two.filter { $0.stepID == .consolidateMesh }.map { $0.subject }
        let qualities = two.filter { $0.stepID == .quality }.map { $0.subject }
        let textures = two.filter { $0.stepID == .textureLow }.map { $0.subject }
        let perRoom: [UUID?] = [roomNeedsBuild, roomNoData]
        let consolidatedOK: Bool = consolidated == perRoom
        let qualitiesOK: Bool = qualities == perRoom
        let texturesOK: Bool = textures == perRoom
        check(&failures, "plan.twoRooms", consolidatedOK && qualitiesOK && texturesOK,
              two.map { $0.key.logName }.joined(separator: " "))
        check(&failures, "plan.twoRooms.buildRoom", two.filter { $0.stepID == .buildRoom }.map { $0.subject } == [roomNeedsBuild],
              "only the room with capturedroomdata.json is rebuilt")
        check(&failures, "plan.twoRooms.projectSteps", two.filter { $0.subject == nil }.count == 3, "one cleanModel, floorPlan, thumbnail")

        // Projects without room steps.
        var objects = manifest([], kind: .object)
        objects.objects = [ObjectRecord(id: uuid(9), name: "", size: .smallMedium, status: .captured, imageCount: 40, modelFile: nil)]
        check(&failures, "plan.objectOnly", ProcessingPlans.roomSteps(manifest: objects, package: package).isEmpty,
              "an object project gets no room steps")
        let capturing = manifest([self.room(roomNeedsBuild, .capturing)])
        check(&failures, "plan.noEligibleRoom", ProcessingPlans.roomSteps(manifest: capturing, package: package).isEmpty,
              "a room still capturing is not processed")
        let processed = ProcessingPlans.roomSteps(manifest: manifest([self.room(roomNeedsBuild, .processed)]), package: package)
        check(&failures, "plan.processedRoomReruns", processed.contains { $0.stepID == .cleanModel }, "Retry of a processed room")
    }

    /// When BuildRoomStep is left out, and what such a room still gets.
    private static func buildRoomChecks(_ package: ProjectPackage, _ failures: inout [String]) {
        for (name, id) in [("hasCapturedRoom", roomHasRoom), ("noRoomData", roomNoData), ("roomPlanFailed", roomPlanFailed)] {
            let steps = ProcessingPlans.roomSteps(manifest: manifest([room(id)]), package: package)
            check(&failures, "buildRoom.omitted.\(name)", !steps.contains { $0.stepID == .buildRoom }, ids(steps).map { $0.rawValue }.joined(separator: " "))
            check(&failures, "buildRoom.cleanHasNoDeps.\(name)", find(steps, .cleanModel)?.dependsOn.isEmpty == true, "cleanModel deps")
        }
        let failed = ProcessingPlans.roomSteps(manifest: manifest([room(roomPlanFailed)]), package: package)
        let kept = [PipelineStepID.consolidateMesh, .quality, .textureLow].allSatisfy { find(failed, $0, roomPlanFailed) != nil }
        check(&failures, "buildRoom.roomPlanFailedKeepsRoomSteps", kept, ids(failed).map { $0.rawValue }.joined(separator: " "))
        let badLog = RawScanFolder(url: package.rawRoomURL(session: session, room: roomBadLog))
        check(&failures, "buildRoom.unreadableLogStillBuilds", ProcessingPlans.needsBuildRoom(badLog), "a missing or unreadable roomlog does not block")
    }

    // MARK: - Status rules

    /// Enqueue, resume and outcome rules, and the room-kind rule.
    private static func statusChecks(_ failures: inout [String]) {
        check(&failures, "enqueue.readyNotEnqueued", !ProcessingPlans.shouldEnqueue(status: .ready), "Demo Mode projects stay ready")
        check(&failures, "enqueue.capturingNotEnqueued", !ProcessingPlans.shouldEnqueue(status: .capturing), "capturing waits for recovery")
        check(&failures, "enqueue.needsProcessing", ProcessingPlans.shouldEnqueue(status: .needsProcessing)
              && ProcessingPlans.shouldEnqueue(status: .processing), "needsProcessing and processing are enqueued")
        let resumed = ProjectStatus.allCases.filter { ProcessingPlans.shouldResume(status: $0) }
        check(&failures, "resume.statuses", Set(resumed) == [.needsProcessing, .processing], "\(resumed.map { $0.rawValue })")
        check(&failures, "outcome.completed", ProcessingPlans.statusAfter(.completed(skippedOptional: [.textureLow])) == .ready, "ready")
        let error = MapperError.processingFailed(step: .cleanModel, reason: "test")
        check(&failures, "outcome.failed", ProcessingPlans.statusAfter(.failed(step: .cleanModel, error: error)) == .needsAttention,
              "needsAttention")
        check(&failures, "outcome.cancelledKeepsStatus", ProcessingPlans.statusAfter(.cancelled) == nil, "cancel never sets ready")
        let roomKinds: [ScanMode] = ScanMode.allCases.filter { ProcessingPlans.isRoomKind($0) }
        check(&failures, "kind.rooms", Set(roomKinds) == [.room, .house, .advancedSpace], "\(roomKinds.map { $0.rawValue })")
        check(&failures, "selfTests.launchRunDue", AppSelfTestRunner.launchRunDue(recorded: nil, current: "0.4 (1)")
              && !AppSelfTestRunner.launchRunDue(recorded: "0.4 (1)", current: "0.4 (1)"), "once per build")
    }

    // MARK: - Recovery

    /// `RecoveryService.reconcile` for the four cases and their precedence.
    private static func reconcileChecks(_ failures: inout [String]) {
        let add = RecoveryService.reconcile(roomsInManifest: 0, sealedRoomFolders: 1, hasInProgressScan: false)
        check(&failures, "reconcile.addRoomsAndProcess", add == .addRoomsAndProcess, "\(add)")
        let process = RecoveryService.reconcile(roomsInManifest: 1, sealedRoomFolders: 0, hasInProgressScan: false)
        check(&failures, "reconcile.process", process == .process, "\(process)")
        let keep = RecoveryService.reconcile(roomsInManifest: 0, sealedRoomFolders: 0, hasInProgressScan: true)
        check(&failures, "reconcile.keepForRecovery", keep == .keepForRecovery, "\(keep)")
        let delete = RecoveryService.reconcile(roomsInManifest: 0, sealedRoomFolders: 0, hasInProgressScan: false)
        check(&failures, "reconcile.delete", delete == .delete, "\(delete)")
        let both = RecoveryService.reconcile(roomsInManifest: 2, sealedRoomFolders: 1, hasInProgressScan: true)
        check(&failures, "reconcile.missingRoomsWin", both == .addRoomsAndProcess, "\(both)")
        let listedAndWaiting = RecoveryService.reconcile(roomsInManifest: 1, sealedRoomFolders: 0, hasInProgressScan: true)
        check(&failures, "reconcile.roomsBeforeWaiting", listedAndWaiting == .process, "\(listedAndWaiting)")
    }

    /// Sealed room folder listing, the scanned-data rule and the recovered RoomRecord.
    private static func recoveryFileChecks(_ package: ProjectPackage, _ failures: inout [String]) {
        do {
            let sealedRoom = uuid(0x10)
            let unsealedRoom = uuid(0x11)
            let noInfoRoom = uuid(0x12)
            for id in [sealedRoom, unsealedRoom, noInfoRoom] {
                let folder = RawScanFolder(url: package.rawRoomURL(session: session, room: id))
                try FileManager.default.createDirectory(at: folder.meshURL, withIntermediateDirectories: true)
                if id != noInfoRoom {
                    let info = InProgressScanInfo(scanID: uuid(0x20), projectID: uuid(0x30), sessionID: session, roomID: id,
                                                  kind: .room, mode: .room, startedAt: sep28)
                    try ProjectStore.writeJSON(info, to: folder.url.appendingPathComponent(InProgressScanInfo.fileName))
                }
                if id != unsealedRoom {
                    try ProjectStore.sealRawFolder(folder.url, now: sep28)
                }
            }
            let sealed = RecoveryService.sealedRoomFolders(in: package).map { $0.roomID }
            check(&failures, "recovery.sealedRoomFolders", sealed == [sealedRoom], "\(sealed)")

            let sealedFolder = RawScanFolder(url: package.rawRoomURL(session: session, room: sealedRoom))
            let record = RecoveryService.roomRecord(roomID: sealedRoom, sessionID: session, folder: sealedFolder,
                                                    fallbackDate: Date(timeIntervalSince1970: 0))
            let statusOK: Bool = record.status == .captured && record.keyframeCount == 0
            let timeOK: Bool = record.capturedAt == sep28
            let frameOK: Bool = record.frameLink == .projectFrame(sessionID: session) && record.sessionID == session
            let recordOK = statusOK && timeOK && frameOK
            check(&failures, "recovery.roomRecord", recordOK, "\(record.status.rawValue) \(record.capturedAt)")

            let empty = RawScanFolder(url: package.rawRoomURL(session: session, room: unsealedRoom))
            check(&failures, "recovery.emptyScanHasNoData", !RecoveryService.hasScannedData(empty), "mesh/ is empty")
            try Data([1, 2, 3]).write(to: empty.meshChunkURL(anchor: uuid(0x40)))
            check(&failures, "recovery.meshChunkIsData", RecoveryService.hasScannedData(empty), "a mesh chunk counts")
            let dataOnly = RawScanFolder(url: package.rawRoomURL(session: session, room: roomNeedsBuild))
            check(&failures, "recovery.roomDataIsData", RecoveryService.hasScannedData(dataOnly), "capturedroomdata.json counts")
        } catch {
            failures.append("recovery.fixture: \(error)")
        }
    }
}
