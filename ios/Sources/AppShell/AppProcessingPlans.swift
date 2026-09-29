import Foundation

/// Builds and enqueues the processing job of a project (ARCHITECTURE 5.3, D20) and maps its
/// outcome to the project status. The plan builders are pure or read only a few small files, so
/// they are nonisolated and self-tested; the enqueue family runs on the main actor with
/// `ProcessingRunner.shared` and `ProjectLibrary.shared`.
enum ProcessingPlans {
    /// Log category.
    static let logCategory = "appshell"

    // MARK: - Plans

    /// Room projects, in this order, with `dependsOn` so a failure stops only its dependents:
    /// per room BuildRoomStep (optional; only when raw lacks capturedroom.json, has
    /// capturedroomdata.json and roomlog.json's `degraded` is not `.roomPlanFailed`; a RoomBuilder
    /// error completes without output), per room ConsolidateMeshStep (optional: a failure leaves Raw
    /// Scan unavailable and heights from RoomPlan), CleanModelStep (required; depends on the rooms'
    /// buildRoom steps; built as `CleanModelStep(meshProvider: { package, room in try? MeshModelStore.loadMeasured(package, room: room) })`,
    /// where `try?` flattens the optional in Swift 5), FloorPlanStep (required; depends on
    /// cleanModel; Results shows the tabs once plan.json exists, D20), per room QualityStep
    /// (optional; independent), ThumbnailStep (optional; depends on floorPlan), per room
    /// TextureLowStep (optional; independent; left out when it slipped, section 2.1). A
    /// `roomPlanFailed` room therefore still gets consolidateMesh, quality and textureLow.
    ///
    /// Rooms are those `CleanModelStep` includes (status captured or processed), in manifest
    /// order. Object and Quick Measure projects, and projects without such a room, get no steps.
    /// Reads, per room, only whether raw capturedroom.json and capturedroomdata.json exist and
    /// roomlog.json (at most 1 MB). Any thread.
    static func roomSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep] {
        var rebuild: Set<UUID> = []
        for room in CleanModelStep.eligibleRooms(manifest) {
            let folder = CapturedRoomStore.rawFolder(package, room: room)
            if needsBuildRoom(folder) { rebuild.insert(room.id) }
        }
        return roomSteps(manifest: manifest, package: package, rebuildRooms: rebuild)
    }

    /// The plan of `roomSteps(manifest:package:)` with the rooms that get a BuildRoomStep given
    /// (pure; the self-test checks the order and dependencies with it).
    static func roomSteps(manifest: ProjectManifest, package: ProjectPackage, rebuildRooms: Set<UUID>) -> [ScheduledStep] {
        guard isRoomKind(manifest.kind) else { return [] }
        let rooms = CleanModelStep.eligibleRooms(manifest)
        guard !rooms.isEmpty else { return [] }
        var steps: [ScheduledStep] = []
        var buildKeys: Set<ScheduledStepKey> = []
        for room in rooms where rebuildRooms.contains(room.id) {
            let step = ScheduledStep(BuildRoomStep(room: room), subject: room.id, isOptional: true)
            buildKeys.insert(step.key)
            steps.append(step)
        }
        for room in rooms {
            let folders = [CapturedRoomStore.rawFolder(package, room: room)]
            steps.append(ScheduledStep(ConsolidateMeshStep(roomID: room.id, folders: folders), subject: room.id,
                                       isOptional: true))
        }
        let cleanStep = CleanModelStep(meshProvider: { stepPackage, roomID in
            try? MeshModelStore.loadMeasured(stepPackage, room: roomID)
        })
        let clean = ScheduledStep(cleanStep, isOptional: false, dependsOn: buildKeys)
        steps.append(clean)
        let plan = ScheduledStep(FloorPlanStep(floors: manifest.floors), isOptional: false, dependsOn: [clean.key])
        steps.append(plan)
        for room in rooms {
            steps.append(ScheduledStep(QualityStep(room: room), subject: room.id, isOptional: true))
        }
        steps.append(ScheduledStep(ThumbnailStep(), isOptional: true, dependsOn: [plan.key]))
        for room in rooms {
            let folders = [CapturedRoomStore.rawFolder(package, room: room)]
            steps.append(ScheduledStep(TextureLowStep(room: room, folders: folders), subject: room.id, isOptional: true))
        }
        return steps
    }

    /// True for the modes whose projects are made of rooms (Room, House, Advanced space).
    static func isRoomKind(_ kind: ScanMode) -> Bool {
        switch kind {
        case .room, .house, .advancedSpace: return true
        case .object, .advancedObject, .quickMeasure: return false
        }
    }

    /// True when a room needs BuildRoomStep: raw has no capturedroom.json, has
    /// capturedroomdata.json, and roomlog.json does not say `.roomPlanFailed` (a missing or
    /// unreadable roomlog.json, as after a recovered scan, does not block it).
    static func needsBuildRoom(_ folder: RawScanFolder) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.capturedRoomURL.path) { return false }
        guard fm.fileExists(atPath: folder.capturedRoomDataURL.path) else { return false }
        return RawScanReader(folder: folder).roomLog()?.degraded != .roomPlanFailed
    }

    /// Pure: whether `enqueue` builds a job for a project in `status`. Demo Mode projects are
    /// written `.ready` and never processed; a `.capturing` project is reconciled by
    /// `RecoveryService` at launch first.
    static func shouldEnqueue(status: ProjectStatus) -> Bool {
        switch status {
        case .needsProcessing, .processing, .needsAttention: return true
        case .ready, .capturing: return false
        }
    }

    /// Pure: whether `resumePending` picks a project in `status` at launch.
    static func shouldResume(status: ProjectStatus) -> Bool {
        status == .needsProcessing || status == .processing
    }

    /// Pure: the status a finished job leaves (nil keeps the current one). `.cancelled` keeps
    /// `.processing`, so the next launch or Retry resumes the project.
    static func statusAfter(_ outcome: ProcessingOutcome) -> ProjectStatus? {
        switch outcome {
        case .completed: return .ready
        case .failed: return .needsAttention
        case .cancelled: return nil
        }
    }

    // MARK: - Enqueue (main actor)

    /// Enqueues a project (atFront when the user just finished it). On `.completed` sets rooms
    /// .processed and project .ready; on `.failed` sets .needsAttention; on `.cancelled` leaves
    /// `.processing` (never `.ready`), so the next launch or Retry resumes it.
    ///
    /// Reads the manifest and the few small files of `roomSteps` on main (small JSON, as Store's
    /// own `update`). A `.ready` or `.capturing` project is not enqueued; a project without steps
    /// is marked `.needsAttention` so it never shows "Building model..." forever.
    @MainActor static func enqueue(projectID: UUID, atFront: Bool) {
        let id = projectID
        let package: ProjectPackage
        let manifest: ProjectManifest
        do {
            package = try ProjectStore.package(for: id)
            manifest = try ProjectStore.readManifest(package)
        } catch {
            log("not enqueued \(short(id)): manifest unreadable (\(StoreFiles.describe(error)))")
            return
        }
        guard shouldEnqueue(status: manifest.status) else {
            log("not enqueued \(short(id)): status \(manifest.status.rawValue)")
            return
        }
        let steps = roomSteps(manifest: manifest, package: package)
        guard !steps.isEmpty else {
            log("not enqueued \(short(id)): nothing to process (kind \(manifest.kind.rawValue), \(manifest.rooms.count) rooms)")
            setStatus(.needsAttention, of: id)
            return
        }
        if manifest.status != .processing {
            setStatus(.processing, of: id)
        }
        let names = steps.map { $0.key.logName }.joined(separator: " ")
        log("enqueue \(short(id))\(atFront ? " at front" : ""): \(names)")
        let job = ProcessingJob(projectID: id, package: package, steps: steps)
        ProcessingRunner.shared.enqueue(job, atFront: atFront) { outcome in
            ProcessingPlans.jobFinished(projectID: id, outcome: outcome)
        }
    }

    /// After Home appears (never while the scan cover is up): projects in .needsProcessing or
    /// .processing, never Demo Mode projects (.ready). The folder walk runs off main; projects
    /// the runner already holds are skipped.
    @MainActor static func resumePending() {
        Task.detached(priority: .utility) {
            let ids = ProjectStore.listProjects()
                .filter { ProcessingPlans.shouldResume(status: $0.status) }
                .map { $0.id }
            await ProcessingPlans.enqueueResumed(ids)
        }
    }

    /// Results' Retry: sets .needsProcessing and enqueues.
    @MainActor static func retry(projectID: UUID) {
        log("retry \(short(projectID))")
        setStatus(.needsProcessing, of: projectID)
        enqueue(projectID: projectID, atFront: true)
    }

    /// Enqueues the projects found by `resumePending` that the runner does not hold yet.
    @MainActor static func enqueueResumed(_ ids: [UUID]) {
        if !ids.isEmpty { log("resume at launch: \(ids.count) projects") }
        let runner = ProcessingRunner.shared
        for id in ids {
            let state = runner.state(for: id)
            if state.isQueued || state.isRunning { continue }
            enqueue(projectID: id, atFront: false)
        }
    }

    /// Maps a job's outcome to the project: rooms `.processed` and `.ready` on completion,
    /// `.needsAttention` on failure, unchanged on cancel.
    @MainActor static func jobFinished(projectID: UUID, outcome: ProcessingOutcome) {
        switch outcome {
        case .completed(let skipped):
            let names = skipped.map { $0.rawValue }.joined(separator: " ")
            log("job completed \(short(projectID))\(skipped.isEmpty ? "" : ", no output from: " + names)")
        case .failed(let step, let error):
            log("job failed \(short(projectID)) at \(step.rawValue): \(error.copyKey)")
        case .cancelled:
            log("job cancelled \(short(projectID)); status kept for the next launch or Retry")
        }
        guard let status = statusAfter(outcome) else { return }
        do {
            try ProjectLibrary.shared.update(projectID) { manifest in
                if status == .ready {
                    for index in manifest.rooms.indices where manifest.rooms[index].status == .captured {
                        manifest.rooms[index].status = .processed
                    }
                }
                manifest.status = status
            }
        } catch {
            log("status \(status.rawValue) not saved for \(short(projectID)): \(StoreFiles.describe(error))")
        }
    }

    /// Writes a project status (logged on failure, for example after a delete).
    @MainActor static func setStatus(_ status: ProjectStatus, of projectID: UUID) {
        do {
            try ProjectLibrary.shared.update(projectID) { manifest in
                manifest.status = status
            }
        } catch {
            log("status \(status.rawValue) not saved for \(short(projectID)): \(StoreFiles.describe(error))")
        }
    }

    // MARK: - Log

    /// Writes one line to the app log.
    static func log(_ message: String) {
        LogStore.shared.write("plans: " + message, category: logCategory)
    }

    /// First 8 characters of an id for the log.
    static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
