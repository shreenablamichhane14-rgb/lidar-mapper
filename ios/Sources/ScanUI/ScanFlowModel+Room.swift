import Foundation

// The capture side of ScanFlowModel (docs/MODULES.md 3.24, ARCHITECTURE 3.4 and 4.2): the
// project and engine of one capture, engine events, the saved room and its quality check,
// Demo Mode, and the cleanup of discard and failure paths. Main actor (extension of the model);
// `ScanQualityCheck` holds the parts that run off the main thread.

/// Keyframes pause with the room engine: `RoomScanEngine` pauses every recorder that conforms
/// to `PausableScanRecorder` (RoomCapture never names a Keyframes type), and
/// `KeyframeRecorder` already has the matching lock-protected `isPaused`.
extension KeyframeRecorder: PausableScanRecorder {}

/// The engine and recorders of one capture, made before `start()`.
struct ScanEngineParts {
    /// The engine the flow drives.
    var engine: ScanEngine
    /// The same engine when it is the room engine (nil in Demo Mode).
    var roomEngine: RoomScanEngine?
    /// The Take Photo recorder (nil in Demo Mode).
    var photoRecorder: PhotoRecorder?
}

/// The project, session and room made for one capture.
struct ScanCaptureProject: Equatable, Sendable {
    /// Project identifier.
    var id: UUID
    /// Its package.
    var package: ProjectPackage
    /// The ARKit session of the capture.
    var sessionID: UUID
    /// The room being scanned.
    var roomID: UUID
    /// Capture options written into the manifest.
    var settings: ScanSettings
}

extension ScanFlowModel {
    // MARK: - Capture start

    /// Creates the project (name, settings, capture session), the recorders and the engine
    /// (`RoomScanEngine`, or `FakeScanEngine` in Demo Mode) and starts it. When the start
    /// throws, the project just created is deleted, the alert shows and the flow ends.
    func startCapture() {
        guard phase == .tips, !hasEnded, engine == nil else { return }
        let project: ScanCaptureProject
        do {
            project = try makeProject(now: Date())
        } catch {
            log("project could not be created: \(StoreFiles.describe(error))")
            apply(.failed("project"))
            present(ScanErrorCopy.alert(for: MapperError.ioFailed("project")), followUp: .endFlow)
            return
        }
        let parts = makeEngine(for: project)
        adopt(projectID: project.id, package: project.package, sessionID: project.sessionID, roomID: project.roomID,
              parts: parts)
        snapshotRecorder = SnapshotRecorder(enabled: ScanUISettings.recordsSnapshots())
        parts.engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        do {
            try parts.engine.start()
        } catch {
            let mapped = (error as? MapperError) ?? MapperError.ioFailed(StoreFiles.describe(error))
            log("engine start failed: \(mapped.copyKey)")
            parts.engine.onEvent = nil
            teardownEngine()
            deleteProject(reason: "the engine did not start")
            apply(.failed(mapped.copyKey))
            present(ScanErrorCopy.notice(for: mapped), followUp: .endFlow)
            return
        }
        apply(.tipsDone)
        startTicker()
        log("capture started: project \(project.id), room \(project.roomID), keep photos \(project.settings.keepAllPhotos)")
    }

    /// `ProjectLibrary.create` with the default name of the mode, then one update with the
    /// capture settings (Keep all photos from Settings) and the `CaptureSessionRef`.
    func makeProject(now: Date) throws -> ScanCaptureProject {
        let name = ScanFlowModel.defaultProjectName(mode: mode, now: now)
        let created = try ProjectLibrary.shared.create(kind: mode, name: name)
        let id = created.1.id
        let session = UUID()
        let room = UUID()
        let settings = ScanUISettings.scanSettings(for: mode)
        let reference = CaptureSessionRef(id: session, startedAt: now, frameLink: .projectFrame(sessionID: session),
                                          worldMapFile: nil)
        do {
            try ProjectLibrary.shared.update(id) { manifest in
                manifest.settings = settings
                manifest.sessions.append(reference)
            }
        } catch {
            try? ProjectLibrary.shared.delete(id)
            throw error
        }
        return ScanCaptureProject(id: id, package: created.0, sessionID: session, roomID: room, settings: settings)
    }

    /// The engine and recorders: `FakeScanEngine` over `SnapshotRecording.synthetic()` in Demo
    /// Mode (no ARKit), else `MeshStore`, `KeyframeRecorder`, `PoseTrackRecorder` and
    /// `PhotoRecorder` handed to `RoomScanEngine(target:recorders:)`.
    func makeEngine(for project: ScanCaptureProject) -> ScanEngineParts {
        if isDemo {
            let fake = FakeScanEngine(recording: .synthetic(), interval: 0.25, loops: false, roomID: project.roomID)
            return ScanEngineParts(engine: fake, roomEngine: nil, photoRecorder: nil)
        }
        let photos = PhotoRecorder()
        photos.onPhotoSaved = { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.photoSaved() }
        }
        let recorders: [ScanRecorder] = [MeshStore(), KeyframeRecorder(), PoseTrackRecorder(), photos]
        let target = RoomScanTarget(projectID: project.id, package: project.package, sessionID: project.sessionID,
                                    roomID: project.roomID, mode: mode, settings: project.settings)
        let room = RoomScanEngine(target: target, recorders: recorders)
        return ScanEngineParts(engine: room, roomEngine: room, photoRecorder: photos)
    }

    // MARK: - Engine events (always on main)

    /// Routes one engine event.
    func handle(_ event: ScanEngineEvent) {
        guard !hasEnded else { return }
        switch event {
        case .snapshot(let value):
            received(snapshot: value)
        case .stateChanged(let state):
            engineStateChanged(state)
        case .roomFinished(let id):
            roomFinished(id)
        case .failed(let error):
            engineFailed(error)
        }
    }

    /// The room was sealed: the RoomRecord goes into the manifest at once (so a kill while the
    /// sheet is up still leaves a project that launch processing resumes), then the quality
    /// check starts. When an alert or dialog just closed, the check (and so the sheet) waits a
    /// moment so two presentations never overlap.
    func roomFinished(_ id: UUID) {
        guard finishedRoomID == nil else {
            log("room \(id) finished again; ignored")
            return
        }
        finishedRoomID = id
        guard phase == .capturing || phase == .stopping else {
            log("room \(id) saved after the scan was discarded; it goes with the project")
            return
        }
        roomSaved = true
        if showsCancelConfirmation || alert != nil {
            showsCancelConfirmation = false
            alert = nil
            alertFollowUp = .none
            markPresentationClosed()
        }
        showsTimeLimitSheet = false
        stopTimers()
        announcer.reset()
        Haptics.success()
        recordFinishedRoom(id)
        let wait = presentationGapRemaining()
        guard wait > 0 else {
            enterChecking(id)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.enterChecking(id)
        }
    }

    /// Phase checking (the sheet shows "Checking your scan...") and the quality check.
    func enterChecking(_ id: UUID) {
        guard finishedRoomID == id, !hasEnded, phase == .capturing || phase == .stopping else { return }
        apply(.roomFinished(id))
        beginQualityCheck(roomID: id)
    }

    /// Appends the room's RoomRecord (`.captured`, from the engine's `lastResult`) and sets the
    /// project `.needsProcessing` in one update. Demo Mode records its room after
    /// `DemoProjectFactory` wrote the files.
    func recordFinishedRoom(_ id: UUID) {
        guard !isDemo, let project = projectID, let session = sessionID else { return }
        let result = roomEngine?.lastResult
        let record = RoomRecord(id: id, name: "", sessionID: session, floorIndex: 0, status: .captured,
                                capturedRoomID: result?.capturedRoomID, quality: nil, hasMeshPass: false,
                                keyframeCount: result?.keyframeCount ?? snapshot.keyframeCount,
                                capturedAt: result?.capturedAt ?? Date(),
                                frameLink: result?.frameLink ?? .projectFrame(sessionID: session))
        savedRecord = record
        do {
            try ProjectLibrary.shared.update(project) { manifest in
                manifest.rooms.removeAll { $0.id == id }
                manifest.rooms.append(record)
                manifest.status = .needsProcessing
            }
            roomRecorded = true
            log("room \(id) added to project \(project): \(record.keyframeCount) keyframes, needs processing")
        } catch {
            log("room \(id) could not be added to project \(project): \(StoreFiles.describe(error))")
        }
    }

    /// Runs the quality check off the main thread: `QualityEvaluator.evaluateSealedRoom` plus
    /// `QualityStore.save`, or `DemoProjectFactory.makeDemoRoom` in Demo Mode.
    func beginQualityCheck(roomID id: UUID) {
        let now = Date()
        guard let package = projectPackage, let session = sessionID else {
            evaluationReady(ScanQualityCheck.fallback(roomID: id, now: now))
            return
        }
        if isDemo {
            Task.detached(priority: .userInitiated) { [weak self] in
                let outcome = ScanQualityCheck.demo(package: package, sessionID: session, roomID: id, now: now)
                await self?.demoRoomFinished(outcome)
            }
            return
        }
        guard let record = savedRecord else {
            evaluationReady(ScanQualityCheck.fallback(roomID: id, now: now))
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ScanQualityCheck.evaluate(package: package, record: record, now: now)
            await self?.qualityCheckFinished(outcome, roomID: id)
        }
    }

    /// The real quality check ended; a failure shows an honest all-zero evaluation.
    func qualityCheckFinished(_ outcome: ScanQualityCheck.Outcome, roomID id: UUID) {
        switch outcome {
        case .evaluated(let result):
            evaluationReady(result)
        case .failed(let reason):
            log("quality check of room \(id) failed: \(reason)")
            evaluationReady(ScanQualityCheck.fallback(roomID: id, now: Date()))
        }
    }

    /// The demo room was written: records it with status `.ready` (never enqueued), then shows
    /// its evaluation. A failure removes the demo project and ends the flow after the alert.
    func demoRoomFinished(_ outcome: ScanQualityCheck.DemoOutcome) {
        switch outcome {
        case .made(let record, let result):
            if let project = projectID {
                do {
                    try ProjectLibrary.shared.update(project) { manifest in
                        manifest.rooms.removeAll { $0.id == record.id }
                        manifest.rooms.append(record)
                        manifest.status = .ready
                    }
                    roomRecorded = true
                    savedRecord = record
                    log("demo room \(record.id) written; project \(project) ready")
                } catch {
                    log("demo room could not be recorded: \(StoreFiles.describe(error))")
                }
            }
            evaluationReady(result)
        case .failed(let reason):
            log("demo room failed: \(reason)")
            guard phase == .checking || phase == .quality else { return }
            apply(.discarded)
            teardownEngine()
            deleteProject(reason: "the demo room could not be written")
            present(ScanErrorCopy.alert(for: MapperError.ioFailed("demo")), followUp: .endFlow)
        }
    }

    /// `.failed`: after the room was saved it is a notice (the sheet still opens); before, the
    /// flow fails, the engine is released (raw stays in InProgress for recovery) and the empty
    /// project is removed.
    func engineFailed(_ error: MapperError) {
        log("engine reported \(error.copyKey)")
        Haptics.warning()
        if finishedRoomID != nil {
            present(ScanErrorCopy.notice(for: error), followUp: .none)
            return
        }
        guard !awaitingDiscardIdle, ScanFlowModel.isBeforeRoomSaved(phase) else { return }
        apply(.failed(error.copyKey))
        stopTimers()
        announcer.reset()
        teardownEngine()
        cleanUpAfterFailure()
        present(ScanErrorCopy.notice(for: error), followUp: .endFlow)
    }

    // MARK: - Discard and cleanup

    /// Confirmed Cancel while scanning or saving: `engine.discard()`, then `completeDiscard`
    /// on `.stateChanged(.idle)` (or after a timeout, logged).
    func beginDiscard() {
        stopTimers()
        announcer.reset()
        showsTimeLimitSheet = false
        alert = nil
        alertFollowUp = .none
        log("cancel confirmed: discarding the scan")
        guard let current = engine else {
            completeDiscard()
            return
        }
        isDiscarding = true
        awaitingDiscardIdle = true
        let timeout = UInt64(ScanFlowTiming.discardTimeoutSeconds * 1_000_000_000)
        discardTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            self?.discardTimedOut()
        }
        current.discard()
    }

    /// The engine stopped and deleted the scan: removes the project when it has no rooms,
    /// releases the engine and ends the flow.
    func completeDiscard() {
        awaitingDiscardIdle = false
        discardTimeout?.cancel()
        discardTimeout = nil
        deleteProjectIfEmpty()
        teardownEngine()
        isDiscarding = false
        endFlow()
    }

    /// No `.idle` arrived in time: finish the discard anyway (the engine keeps stopping).
    func discardTimedOut() {
        guard awaitingDiscardIdle else { return }
        log("discard: no idle event after \(Int(ScanFlowTiming.discardTimeoutSeconds)) s; ending the flow")
        completeDiscard()
    }

    /// Removes the scan just saved after the user confirmed Discard (only that room; the
    /// project goes when no room is left), releases the engine and ends the flow.
    func discardSavedRoom() {
        alert = nil
        alertFollowUp = .none
        stopTimers()
        announcer.reset()
        teardownEngine()
        if let project = projectID {
            if let room = finishedRoomID {
                do {
                    let deleted = try ProjectLibrary.shared.discardRoom(room, in: project)
                    log("discarded room \(room)\(deleted ? " and its project" : "")")
                } catch {
                    log("discard of room \(room) failed: \(StoreFiles.describe(error))")
                }
            } else {
                deleteProject(reason: "discarded before the room was saved")
            }
        }
        endFlow()
    }

    /// After a failure before the room was saved. Raw data stays in InProgress, where launch
    /// recovery offers it. A room folder already moved into the package is never deleted
    /// without the user: the project keeps it and is marked for processing; otherwise the
    /// empty project is removed so it never stays `.capturing`.
    func cleanUpAfterFailure() {
        guard let package = projectPackage else { return }
        if let room = roomID, let session = sessionID,
           StoreFiles.isDirectory(package.rawRoomURL(session: session, room: room)) {
            log("room \(room) is already in the package; the project keeps it")
            recordFinishedRoom(room)
            return
        }
        deleteProject(reason: "the capture failed before the room was saved; raw stays in InProgress")
    }

    /// Deletes the project when its manifest lists no room (an unreadable manifest counts as none).
    func deleteProjectIfEmpty() {
        guard let package = projectPackage else { return }
        let rooms = (try? ProjectStore.readManifest(package))?.rooms.count ?? 0
        if rooms == 0 {
            deleteProject(reason: "discarded while scanning")
        } else {
            log("project kept: it has \(rooms) rooms")
        }
    }

    /// Deletes the project of this flow (logged; a failure is logged, never thrown).
    func deleteProject(reason: String) {
        guard let project = projectID else { return }
        do {
            try ProjectLibrary.shared.delete(project)
            log("deleted project \(project): \(reason)")
        } catch {
            log("could not delete project \(project) (\(reason)): \(StoreFiles.describe(error))")
        }
    }

    /// Releases the engine (idempotent): the room engine's `teardown()`, or `cancel()` of a fake
    /// engine that is still replaying.
    func teardownEngine() {
        if let room = roomEngine {
            room.teardown()
        } else if let current = engine {
            let state = current.state
            if state == .starting || state == .scanning || state == .paused { current.cancel() }
        }
    }

    /// Ends the flow without a project for AppShell (cancel, discard, failure, blocking preflight).
    func endFlow() {
        guard !hasEnded else { return }
        hasEnded = true
        stopTimers()
        showsTimeLimitSheet = false
        showsCancelConfirmation = false
        teardownEngine()
        snapshotRecorder?.close()
        releaseIdleToken()
        announcer.reset()
        log("scan flow ended in phase \(phase)")
        onDismiss?()
    }
}

/// The off-main parts of the quality check at Done. Stateless, any thread.
enum ScanQualityCheck {
    /// Result of the real check.
    enum Outcome: Sendable {
        /// The evaluation (also saved as quality.json).
        case evaluated(QualityEvaluation)
        /// The check could not run; diagnostic text.
        case failed(String)
    }

    /// Result of the demo room.
    enum DemoOutcome: Sendable {
        /// The demo room's record and evaluation.
        case made(RoomRecord, QualityEvaluation)
        /// The demo room could not be written; diagnostic text.
        case failed(String)
    }

    /// `QualityEvaluator.evaluateSealedRoom`, then `QualityStore.save` (a failed save is logged;
    /// the pipeline's QualityStep writes the file again).
    static func evaluate(package: ProjectPackage, record: RoomRecord, now: Date) -> Outcome {
        do {
            let result = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, now: now)
            do {
                try QualityStore.save(result, package: package)
            } catch {
                LogStore.shared.write("quality.json of room \(record.id) not saved: \(StoreFiles.describe(error))",
                                      category: ScanPreflight.logCategory)
            }
            return .evaluated(result)
        } catch {
            return .failed(StoreFiles.describe(error))
        }
    }

    /// `DemoProjectFactory.makeDemoRoom`.
    static func demo(package: ProjectPackage, sessionID: UUID, roomID: UUID, now: Date) -> DemoOutcome {
        do {
            let made = try DemoProjectFactory.makeDemoRoom(package: package, sessionID: sessionID, roomID: roomID, now: now)
            return .made(made.0, made.1)
        } catch {
            return .failed(StoreFiles.describe(error))
        }
    }

    /// An honest evaluation when the check could not run: every score 0, nothing missing
    /// listed, so the sheet says the scan has gaps and offers Finish Anyway.
    static func fallback(roomID: UUID, now: Date) -> QualityEvaluation {
        let summary = QualitySummary(shape: 0, walls: 0, floor: 0, ceiling: 0, texture: 0, missingAreas: 0)
        return QualityEvaluation(roomID: roomID, summary: summary, missingAreas: [], degraded: .allGood,
                                 evidence: RoomEvidence.unknown, darkKeyframeFraction: 0, inputHash: "-",
                                 evaluatedAt: now)
    }
}
