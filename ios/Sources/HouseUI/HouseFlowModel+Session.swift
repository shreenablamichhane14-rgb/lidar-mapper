import Foundation
import ARKit
import UIKit

// Sessions of the house flow (docs/MODULES.md 3.41, ARCHITECTURE 4.3, D9): the engines and their
// recorders, the first capture of a new house, relocalization against a saved room map with the
// 30 s Start Fresh Here offer, fresh unaligned sessions, engine events, failures, Cancel during a
// room, and teardown. One ARSession per visit: rooms of one session follow each other with
// `startNextRoom(roomID:)`; a new engine (and so a new `RoomCaptureContainer` identity) comes only
// with a new session. Main actor (extension of the model).

extension HouseFlowModel {
    // MARK: - Engines

    /// The engine and recorders of the current session: `MeshStore`, `KeyframeRecorder`,
    /// `PoseTrackRecorder`, `PhotoRecorder` plus `captureExtras`, handed to
    /// `RoomScanEngine(target:recorders:)` with `RoomScanTarget(mode: .house)`. Nothing runs yet.
    @discardableResult
    func makeRoomEngine(roomID: UUID) -> RoomScanEngine? {
        guard let project = projectID, let package, let session = sessionID else { return nil }
        let meshes = MeshStore()
        let photos = PhotoRecorder()
        photos.onPhotoSaved = { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.photoSaved() }
        }
        var recorders: [ScanRecorder] = [meshes, KeyframeRecorder(), PoseTrackRecorder(), photos]
        var installer: ((RoomScanEngine) -> Void)?
        if let extras = captureExtras?(meshes) {
            recorders.append(contentsOf: extras.recorders)
            installer = extras.install
        }
        let target = RoomScanTarget(projectID: project, package: package, sessionID: session, roomID: roomID,
                                    mode: .house, settings: projectSettings)
        let room = RoomScanEngine(target: target, recorders: recorders)
        installer?(room)
        adopt(engine: room, roomEngine: room, photos: photos, meshes: meshes)
        log("engine for session \(session), room \(roomID), \(recorders.count) recorders")
        return room
    }

    /// Demo Mode: a `FakeScanEngine` replaying the synthetic scan for `roomID`.
    func makeDemoEngine(roomID: UUID) {
        let fake = FakeScanEngine(recording: .synthetic(), interval: 0.25, loops: false, roomID: roomID)
        adopt(engine: fake, roomEngine: nil, photos: nil, meshes: nil)
    }

    /// Starts the room `roomID` on the current engine (`start()`, or `startNextRoom(roomID:)` on
    /// the same session); a failure goes to the room list with the alert, or ends the flow.
    @discardableResult
    func startEngine(roomID: UUID, isNext: Bool) -> Bool {
        prepareRoomState(roomID)
        do {
            if isNext, let room = roomEngine {
                try room.startNextRoom(roomID: roomID)
            } else if let current = engine {
                try current.start()
            } else {
                throw MapperError.ioFailed("no engine")
            }
        } catch {
            captureStartFailed(error)
            return false
        }
        startTicker()
        log("room \(roomID) started\(isNext ? " on the same session" : ""), floor \(currentFloor)")
        return true
    }

    /// Mounts RoomPlan's view for the current engine and starts its first room.
    func mountAndStart(roomID: UUID) {
        isCaptureViewMounted = true
        if case .relocalized? = sessionLink {
            relocalizedRoomStartedAt = ProcessInfo.processInfo.systemUptime
        } else {
            relocalizedRoomStartedAt = nil
        }
        startEngine(roomID: roomID, isNext: false)
    }

    /// Resets the per-room state before a room starts.
    func prepareRoomState(_ roomID: UUID) {
        currentRoomID = roomID
        finishedRoomID = nil
        finishedRecord = nil
        checkingRoomID = nil
        roomStoppedBySystem = false
        tourStoppedBySystem = false
        roomEndedAt = nil
        hasStartedScanning = false
        timeHintShown = false
        timeLimitShown = false
        showsTimeHint = false
        showsTimeLimitCard = false
        pausedSince = nil
        pausedPrompted = false
        setPaused(false)
        setEvaluation(nil)
        setLastResult(nil)
        setSnapshot(LiveScanSnapshot())
        announcer.reset()
        updateRoomChip()
    }

    // MARK: - First capture

    /// Called when the checks and tips are done: the first room of a new house, the
    /// relocalization of a later visit, or a Demo Mode room.
    func enterCapture() {
        switch phase {
        case .capturing:
            startFirstRoom()
        case .relocalizing:
            beginRelocalization(preferRoom: pendingRescan)
        default:
            break
        }
    }

    /// The first room of this visit without relocalization: a new house (the project and its first
    /// session, `.projectFrame`, before the engine starts), or a Demo Mode visit.
    func startFirstRoom() {
        if projectID == nil {
            do {
                try makeProject(now: Date())
            } catch {
                log("project could not be created: \(StoreFiles.describe(error))")
                apply(.failed("project"))
                present(HouseAlert.from(ScanErrorCopy.alert(for: MapperError.ioFailed("project"))), followUp: .endFlow)
                return
            }
        } else {
            // A later Demo Mode visit (a real later visit relocalizes instead): a new session with
            // no known relation to the earlier ones.
            let session = UUID()
            sessionID = session
            let link: FrameLink = isDemo ? .unaligned : .projectFrame(sessionID: session)
            guard recordSession(link: link) else { return }
        }
        let room = UUID()
        if isDemo {
            makeDemoEngine(roomID: room)
        } else {
            guard makeRoomEngine(roomID: room) != nil else {
                captureStartFailed(MapperError.ioFailed("engine"))
                return
            }
        }
        mountAndStart(roomID: room)
    }

    /// `ProjectLibrary.create(kind: .house, name:)` with the default House name, then one update
    /// with the capture settings (Keep all photos from Settings) and the first `CaptureSessionRef`
    /// (`.projectFrame`). A failed update deletes the new project again.
    func makeProject(now: Date) throws {
        let name = ScanFlowModel.defaultProjectName(mode: .house, now: now)
        let created = try ProjectLibrary.shared.create(kind: .house, name: name)
        let id = created.1.id
        let session = UUID()
        let settings = ScanUISettings.scanSettings(for: .house)
        let reference = HouseManifestRules.session(id: session, startedAt: now, link: .projectFrame(sessionID: session))
        do {
            try ProjectLibrary.shared.update(id) { manifest in
                manifest.settings = settings
                manifest.sessions.append(reference)
            }
        } catch {
            try? ProjectLibrary.shared.delete(id)
            throw error
        }
        setProject(id, package: created.0)
        createdProject = true
        projectSettings = settings
        sessionID = session
        sessionLink = .projectFrame(sessionID: session)
        log("house project \(id) created, session \(session), keep photos \(settings.keepAllPhotos)")
    }

    /// Appends the current session's `CaptureSessionRef` with `link` (replacing an earlier entry
    /// of the same id) and remembers the link. A failed write ends the capture with its alert.
    @discardableResult
    func recordSession(link: FrameLink) -> Bool {
        guard let session = sessionID else { return false }
        let reference = HouseManifestRules.session(id: session, startedAt: Date(), link: link)
        do {
            try updateManifest { manifest in
                manifest.sessions.removeAll { $0.id == session }
                manifest.sessions.append(reference)
            }
        } catch {
            log("session \(session) not recorded: \(StoreFiles.describe(error))")
            captureStartFailed(MapperError.ioFailed("session"))
            return false
        }
        sessionLink = link
        log("session \(session) recorded as \(StructureEligibility.linkKey(link))")
        return true
    }

    // MARK: - Relocalization

    /// A new engine for a new session that relocalizes against the saved room map
    /// (`HouseRelocalization.sourceMap`): the map is read off main, unarchived on main, then
    /// `hub.install()` and `hub.run(options: [.resetTracking, .removeExistingAnchors], initialWorldMap:)`
    /// (3.30b) before any RoomPlan object exists, and the tracking poll. Without a map the camera
    /// runs plainly and Start Fresh Here is offered at once (`noMapAvailable`).
    func beginRelocalization(preferRoom: UUID?) {
        stopRelocalizationPoll()
        guard let package, let manifest = readManifest() else {
            captureStartFailed(MapperError.corruptProject("manifest"))
            return
        }
        sessionID = UUID()
        sessionLink = nil
        relocalizationSource = nil
        noMapAvailable = false
        timeoutLogged = false
        setRelocalization(elapsed: 0, startFresh: false)
        let room = UUID()
        pendingRoomID = room
        guard let engine = makeRoomEngine(roomID: room) else {
            captureStartFailed(MapperError.ioFailed("engine"))
            return
        }
        isCaptureViewMounted = false
        let hub = engine.hub
        guard let source = HouseRelocalization.sourceMap(manifest: manifest, package: package, preferRoom: preferRoom) else {
            showNoMap(hub: hub)
            return
        }
        log("relocalizing against room \(source.room) of session \(source.session)")
        relocalizationLoad = Task { [weak self] in
            let map = await HouseRelocalization.loadWorldMap(from: source.url)
            guard let self, self.phase == .relocalizing, !self.isCaptureViewMounted, self.roomEngine?.hub === hub else { return }
            guard let map else {
                self.showNoMap(hub: hub)
                return
            }
            hub.install()
            hub.run(options: [.resetTracking, .removeExistingAnchors], initialWorldMap: map)
            self.relocalizationSource = (session: source.session, room: source.room)
            self.startRelocalizationPoll(hub: hub)
        }
    }

    /// No usable map: the camera runs without one and Start Fresh Here shows at once.
    func showNoMap(hub: ARSessionHub) {
        hub.install()
        if !hub.isRunning { hub.run() }
        noMapAvailable = true
        setRelocalization(elapsed: 0, startFresh: true)
        log("relocalization: no usable room map; Start Fresh Here offered")
    }

    /// Polls the hub's tracking every 0.5 s and feeds `HouseRelocalization.decide`.
    func startRelocalizationPoll(hub: ARSessionHub) {
        relocalizationStartedAt = ProcessInfo.processInfo.systemUptime
        normalSince = nil
        relocalizationTask?.cancel()
        let interval = UInt64(HouseRelocalization.pollSeconds * 1_000_000_000)
        relocalizationTask = Task { [weak self, weak hub] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let hub else { return }
                let tracking = await HouseRelocalization.trackingSummary(of: hub)
                guard !Task.isCancelled, let model = self else { return }
                if model.relocalizationTick(tracking: tracking) { return }
            }
        }
    }

    /// One poll result. Returns true when the poll should stop.
    func relocalizationTick(tracking: TrackingSummary) -> Bool {
        guard phase == .relocalizing, !isCaptureViewMounted else { return true }
        let elapsed = ProcessInfo.processInfo.systemUptime - relocalizationStartedAt
        if tracking == .normal {
            if normalSince == nil { normalSince = elapsed }
        } else {
            normalSince = nil
        }
        let decision = HouseRelocalization.decide(elapsed: elapsed, tracking: tracking, normalSince: normalSince)
        setRelocalization(elapsed: elapsed, startFresh: showsStartFresh || decision == .timedOut)
        switch decision {
        case .relocalized:
            relocalizationSucceeded(seconds: elapsed)
            return true
        case .timedOut:
            if !timeoutLogged {
                timeoutLogged = true
                Haptics.warning()
                log("relocalization: no match after \(Int(elapsed)) s, tracking \(tracking.rawValue); Start Fresh Here offered")
            }
            return false
        case .keepWaiting:
            return false
        }
    }

    /// Tracking held `.normal` against the map (D9): the session is recorded `.relocalized`,
    /// RoomPlan's view replaces the relocalization view and the room starts.
    func relocalizationSucceeded(seconds: Double) {
        stopRelocalizationPoll()
        guard let session = sessionID, let source = relocalizationSource, let room = pendingRoomID else { return }
        guard recordSession(link: .relocalized(sessionID: session, from: source.session)) else { return }
        log("relocalized in \(String(format: "%.1f", seconds)) s against room \(source.room)")
        Haptics.success()
        apply(.relocalized)
        mountAndStart(roomID: room)
    }

    /// Keep Looking: restarts the 30 s timer (the poll keeps running).
    func keepLooking() {
        guard phase == .relocalizing, !noMapAvailable, relocalizationSource != nil else { return }
        relocalizationStartedAt = ProcessInfo.processInfo.systemUptime
        normalSince = nil
        timeoutLogged = false
        setRelocalization(elapsed: 0, startFresh: false)
        log("keep looking tapped")
    }

    /// Start Fresh Here. While relocalizing: re-runs the hub with `[.resetTracking,
    /// .removeExistingAnchors]` (RoomPlan has not started on it), records the session
    /// `.unaligned` and starts the room (these rooms are parked until lined up). After a lost
    /// relocalization (`sceneTooLarge` right after it): a new engine on a new unaligned session.
    func startFresh() {
        switch phase {
        case .relocalizing:
            guard let engine = roomEngine, !isCaptureViewMounted, let room = pendingRoomID else { return }
            stopRelocalizationPoll()
            if relocalizationSource != nil {
                engine.hub.run(options: [.resetTracking, .removeExistingAnchors])
            }
            relocalizationSource = nil
            guard recordSession(link: .unaligned) else { return }
            log("start fresh here: unaligned session")
            apply(.startedFresh)
            mountAndStart(roomID: room)
        case .checking, .quality, .roomList:
            guard freshSessionRequired else { return }
            startFreshSession(signal: .startedFresh)
        default:
            break
        }
    }

    /// A new engine on a new `.unaligned` session (never reset options on a session RoomPlan ran
    /// on), then `signal` and the room.
    func startFreshSession(signal: HouseFlowSignal) {
        teardownEngine()
        sessionID = UUID()
        let room = UUID()
        guard makeRoomEngine(roomID: room) != nil else {
            captureStartFailed(MapperError.ioFailed("engine"))
            return
        }
        guard recordSession(link: .unaligned) else { return }
        freshSessionRequired = false
        needsNewSession = false
        apply(signal)
        log("fresh unaligned session \(sessionID?.uuidString ?? "-")")
        mountAndStart(roomID: room)
    }

    /// Cancel while relocalizing: the new session is dropped (nothing was recorded for it).
    func cancelRelocalization() {
        stopRelocalizationPoll()
        teardownEngine()
        needsNewSession = true
        let rooms = hasActiveRooms()
        log("relocalization cancelled")
        apply(.cancelConfirmed(hasRooms: rooms))
        if rooms { enterRoomList() } else { endFlow() }
    }

    /// Stops the poll and the map load.
    func stopRelocalizationPoll() {
        relocalizationTask?.cancel()
        relocalizationTask = nil
        relocalizationLoad?.cancel()
        relocalizationLoad = nil
    }

    // MARK: - Engine events (always on main)

    /// Routes one engine event; events of a replaced engine are ignored.
    func handle(_ event: ScanEngineEvent, serial: Int) {
        guard !hasEnded, serial == engineSerial else { return }
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

    /// A live snapshot: published while scanning or saving, fed to the guidance announcer
    /// (nothing while paused) and checked for the timed cues.
    func received(snapshot value: LiveScanSnapshot) {
        guard phase == .capturing || phase == .stopping else { return }
        setSnapshot(value)
        let guidance: GuidanceKind? = phase == .capturing && !isPaused ? value.guidance : nil
        announcer.present(guidance, now: value.timestamp)
        checkTimeCues(elapsed: value.elapsed)
    }

    /// The engine's lifecycle state changed.
    func engineStateChanged(_ state: ScanEngineState) {
        engineState = state
        switch state {
        case .scanning:
            if isPaused {
                setPaused(false)
                pausedSince = nil
                log("scanning again after a pause")
            }
            leftScreenWhileScanning = false
            if HouseFlowModel.isPauseAlert(alert) { alert = nil }
            if !hasStartedScanning {
                hasStartedScanning = true
                Haptics.selection()
            }
        case .paused:
            guard !isPaused else { return }
            setPaused(true)
            pausedSince = ProcessInfo.processInfo.systemUptime
            pausedPrompted = false
            announcer.present(nil, now: snapshot.timestamp)
            log("engine paused")
            if leftScreenWhileScanning && UIApplication.shared.applicationState == .active { appDidBecomeActive() }
        case .stopping:
            setPaused(false)
            if roomEndedAt == nil { roomEndedAt = ProcessInfo.processInfo.systemUptime }
            if phase == .capturing {
                log("the engine is finishing the room by itself")
                showsTimeLimitCard = false
                showsTimeHint = false
                apply(.engineStopping)
            }
        case .idle:
            if awaitingDiscardIdle { completeDiscard() }
        case .starting, .finished, .failed:
            break
        }
    }

    /// `.failed`: after the room was saved it is a notice (the lost relocalization case offers
    /// Start Fresh Here); before, the capture ends: the room list with the alert when the house
    /// has rooms, else the flow fails and the new empty project is removed (raw stays in
    /// InProgress for recovery).
    func engineFailed(_ error: MapperError) {
        log("engine reported \(error.copyKey)")
        Haptics.warning()
        if finishedRoomID != nil {
            if error == .sceneTooLarge && relocalizationLost() {
                handleLostRelocalization()
            } else {
                present(HouseAlert.from(ScanErrorCopy.notice(for: error)), followUp: .stay)
            }
            return
        }
        guard !awaitingDiscardIdle, phase == .capturing || phase == .stopping else { return }
        stopTimers()
        announcer.reset()
        teardownEngine()
        needsNewSession = true
        if hasActiveRooms() {
            apply(.cancelConfirmed(hasRooms: true))
            enterRoomList()
            present(HouseAlert.from(ScanErrorCopy.notice(for: error)), followUp: .stay)
        } else {
            removeEmptyProject(reason: "the capture failed before the first room was saved; raw stays in InProgress")
            apply(.failed(error.copyKey))
            present(HouseAlert.from(ScanErrorCopy.notice(for: error)), followUp: .endFlow)
        }
    }

    /// True when the room of a relocalized session ended within `lostWindowSeconds` of its start
    /// (RESEARCH 3.2 disputed 7: RoomPlan cannot work in this session).
    func relocalizationLost() -> Bool {
        guard case .relocalized? = sessionLink, let started = relocalizedRoomStartedAt else { return false }
        let ended = roomEndedAt ?? ProcessInfo.processInfo.systemUptime
        return ended - started <= HouseRelocalization.lostWindowSeconds
    }

    /// The tiny room stays `.needsRescan`; the next room needs a fresh unaligned session; the
    /// alert offers Start Fresh Here.
    func handleLostRelocalization() {
        guard let room = finishedRoomID else { return }
        forcedNeedsRescan.insert(room)
        do {
            try updateManifest { manifest in HouseManifestRules.setStatus(.needsRescan, room: room, in: &manifest) }
        } catch {
            log("room \(room) status not updated: \(StoreFiles.describe(error))")
        }
        freshSessionRequired = true
        needsNewSession = true
        log("relocalization lost: scene too large right after relocalizing; room \(room) needs a rescan")
        present(HouseAlert.relocalizationLost(), followUp: .stay)
    }

    /// Error that `startEngine` or a session write reported: back to the room list with the alert
    /// when the house has rooms, else the flow ends (the new empty project is removed).
    func captureStartFailed(_ error: Error) {
        let mapped = (error as? MapperError) ?? MapperError.ioFailed(StoreFiles.describe(error))
        log("capture could not start: \(mapped.copyKey)")
        stopTimers()
        teardownEngine()
        needsNewSession = true
        if hasActiveRooms() {
            apply(.cancelConfirmed(hasRooms: true))
            enterRoomList()
            present(HouseAlert.from(ScanErrorCopy.notice(for: mapped)), followUp: .stay)
        } else {
            removeEmptyProject(reason: "the capture did not start")
            apply(.failed(mapped.copyKey))
            present(HouseAlert.from(ScanErrorCopy.notice(for: mapped)), followUp: .endFlow)
        }
    }

    // MARK: - Cancel during a room

    /// Confirmed Cancel while scanning or saving: `engine.discard()`, then `completeDiscard` on
    /// `.stateChanged(.idle)` (or after a timeout, logged).
    func beginDiscard() {
        stopTimers()
        announcer.reset()
        showsTimeLimitCard = false
        alert = nil
        alertFollowUp = .stay
        log("cancel confirmed: discarding room \(currentRoomID?.uuidString ?? "-")")
        guard let current = engine else {
            completeDiscard()
            return
        }
        isDiscarding = true
        awaitingDiscardIdle = true
        let timeout = UInt64(ScanFlowTiming.discardTimeoutSeconds * 1_000_000_000)
        discardTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, let model = self, model.awaitingDiscardIdle else { return }
            model.log("discard: no idle event in time; continuing")
            model.completeDiscard()
        }
        current.discard()
    }

    /// The engine stopped and deleted the room's InProgress data: the room list when the house
    /// has rooms (the camera stays live behind it), else the empty project is removed and the
    /// flow ends. The idle engine cannot start a next room, so the next one gets a new session.
    func completeDiscard() {
        awaitingDiscardIdle = false
        discardTimeout?.cancel()
        discardTimeout = nil
        isDiscarding = false
        needsNewSession = true
        if hasActiveRooms() {
            apply(.cancelConfirmed(hasRooms: true))
            enterRoomList()
        } else {
            teardownEngine()
            removeEmptyProject(reason: "discarded while scanning the first room")
            apply(.cancelConfirmed(hasRooms: false))
            endFlow()
        }
    }

    // MARK: - Teardown and end

    /// Releases the engine (idempotent): the room engine's `teardown()` (session paused, recorders
    /// detached, hub closures cleared), or `cancel()` of a fake engine still replaying.
    func teardownEngine() {
        stopRelocalizationPoll()
        if let room = roomEngine {
            room.teardown()
        } else if let current = engine {
            let state = current.state
            if state == .starting || state == .scanning || state == .paused { current.cancel() }
        }
    }

    /// Ends the flow without a completed visit (cancel, discard of the only room, failure,
    /// blocking preflight): teardown, then `onDismiss`.
    func endFlow() {
        guard !hasEnded else { return }
        hasEnded = true
        stopTimers()
        showsCancelConfirmation = false
        teardownEngine()
        releaseIdleToken()
        announcer.reset()
        log("house flow ended in phase \(phase)")
        onDismiss?()
    }

    /// Deletes the project when this visit created it and it lists no active room.
    func removeEmptyProject(reason: String) {
        guard createdProject, let id = projectID, !hasActiveRooms() else { return }
        do {
            try ProjectLibrary.shared.delete(id)
            log("deleted project \(id): \(reason)")
        } catch {
            log("could not delete project \(id) (\(reason)): \(StoreFiles.describe(error))")
        }
    }
}
