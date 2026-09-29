import Foundation

// Rooms of the house flow (docs/MODULES.md 3.41, D17, D19, CR-7): the room just saved (record,
// world map path, memory eviction and the "finish this floor" check), its quality check and
// status, Finish (a pending Rescan now supersedes the old room) and naming, Discard, the room
// list (rows, Scan Next Room, Rescan, Add Floor, Finish Building). Main actor (extension of the
// model); file reads that can grow run in detached tasks.

extension HouseFlowModel {
    // MARK: - Room saved

    /// The engine sealed the room: its `RoomRecord` goes into the manifest at once (with the
    /// project `.needsProcessing` and the session's world map path), the mesh store is evicted and
    /// memory logged (D17), then the quality check starts. Demo Mode writes the demo room instead.
    func roomFinished(_ id: UUID) {
        guard id == currentRoomID, finishedRoomID == nil else {
            log("room \(id) finished again or unknown; ignored")
            return
        }
        finishedRoomID = id
        guard phase == .capturing || phase == .stopping else {
            log("room \(id) was saved while the capture was being cancelled; it stays in the project")
            if !isDemo { _ = saveRoomRecord(id, result: roomEngine?.lastResult) }
            return
        }
        if showsCancelConfirmation {
            showsCancelConfirmation = false
            markPresentationClosed()
        }
        if HouseFlowModel.isPauseAlert(alert) {
            alert = nil
            alertFollowUp = .stay
        }
        showsTimeLimitCard = false
        showsNextRoomHint = false
        stopTimers()
        announcer.reset()
        Haptics.success()
        if isDemo {
            apply(.roomFinished)
            beginDemoRoom(id)
            return
        }
        let result = roomEngine?.lastResult
        setLastResult(result)
        roomStoppedBySystem = result?.stoppedBySystem ?? false
        if roomStoppedBySystem {
            needsNewSession = true
            log("room \(id) was finished by the system; the next room gets a new session")
        }
        let record = saveRoomRecord(id, result: result)
        apply(.roomFinished)
        beginQualityCheck(record)
    }

    /// Appends the room's record (`HouseManifestRules.roomRecord` with the session's link and the
    /// current floor) and, when the sealed folder holds `worldmap.arworldmap`, the session's map
    /// path, in one update; evicts the mesh store and logs the available memory.
    func saveRoomRecord(_ id: UUID, result: RoomScanResult?) -> RoomRecord {
        let link = sessionLink ?? .unaligned
        let record: RoomRecord
        if let result, result.roomID == id {
            record = HouseManifestRules.roomRecord(result, sessionLink: link, floorIndex: currentFloor)
        } else {
            record = RoomRecord(id: id, name: "", sessionID: sessionID ?? id, floorIndex: currentFloor, status: .captured,
                                capturedRoomID: nil, quality: nil, hasMeshPass: false,
                                keyframeCount: snapshot.keyframeCount, capturedAt: Date(), frameLink: link)
        }
        let hasMap = result.map { FileManager.default.fileExists(atPath: $0.sealedFolder.worldMapURL.path) } ?? false
        do {
            try updateManifest { manifest in
                HouseManifestRules.append(record, to: &manifest)
                if hasMap { HouseManifestRules.setWorldMap(session: record.sessionID, room: record.id, in: &manifest) }
            }
        } catch {
            log("room \(id) could not be added to the project: \(StoreFiles.describe(error))")
        }
        finishedRecord = record
        meshStore?.evict()
        let available = MemoryProbe.availableBytes()
        log("room \(id) saved on floor \(record.floorIndex), link \(StructureEligibility.linkKey(link)), "
            + "\(record.keyframeCount) keyframes, world map \(hasMap); available memory \(available / 1_000_000) MB after eviction")
        setLowMemory(HousePresentation.suggestsFinishFloor(availableMemory: available))
        if result?.log.degraded == .meshStripped {
            log("room \(id): mesh stripped; no House detail pass in build 5 (3.49), Raw Scan and Realistic show their fallback")
        }
        return record
    }

    // MARK: - Quality check

    /// Runs `QualityEvaluator.evaluateSealedRoom` and `QualityStore.save` (ScanUI's
    /// `ScanQualityCheck.evaluate`) off the main thread.
    func beginQualityCheck(_ record: RoomRecord) {
        let now = Date()
        checkingRoomID = record.id
        guard let package = projectPackage else {
            qualityCheckFinished(.failed("no package"), roomID: record.id)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = ScanQualityCheck.evaluate(package: package, record: record, now: now)
            await self?.qualityCheckFinished(outcome, roomID: record.id)
        }
    }

    /// The check ended (a failure shows the honest all-zero evaluation): the room's status from
    /// `HouseManifestRules.status(after:)`, then the quality sheet when the room is still on it.
    func qualityCheckFinished(_ outcome: ScanQualityCheck.Outcome, roomID: UUID) {
        let result: QualityEvaluation
        switch outcome {
        case .evaluated(let value):
            result = value
        case .failed(let reason):
            log("quality check of room \(roomID) failed: \(reason)")
            result = ScanQualityCheck.fallback(roomID: roomID, now: Date())
        }
        applyStatus(after: result, room: roomID)
        guard checkingRoomID == roomID, phase == .checking, !hasEnded else { return }
        setEvaluation(result)
        apply(.evaluated)
        log("room \(roomID) quality \(result.summary.verdict.rawValue), \(result.summary.missingAreas) missing areas")
    }

    /// `.needsRescan` for a poor evaluation (or a lost relocalization), else `.captured`.
    func applyStatus(after result: QualityEvaluation, room: UUID) {
        let status: RoomStatus = forcedNeedsRescan.contains(room) ? .needsRescan : HouseManifestRules.status(after: result)
        do {
            try updateManifest { manifest in
                guard let current = manifest.rooms.first(where: { $0.id == room })?.status,
                      current == .captured || current == .needsRescan else { return }
                HouseManifestRules.setStatus(status, room: room, in: &manifest)
            }
        } catch {
            log("room \(room) status not updated: \(StoreFiles.describe(error))")
        }
        refreshRows()
    }

    // MARK: - Quality sheet actions

    /// Finish or Finish Anyway: keeps the room (a pending Rescan now supersedes the old room,
    /// CR-7, nothing is deleted), then naming.
    func finishRoom() {
        guard phase == .quality || phase == .checking, let room = finishedRoomID else { return }
        if let old = pendingRescan, old != room {
            do {
                try updateManifest { manifest in HouseManifestRules.supersede(old, by: room, in: &manifest) }
                log("room \(room) supersedes room \(old)")
            } catch {
                log("supersede of room \(old) failed: \(StoreFiles.describe(error))")
            }
            if isDemo { removeDemoRoom(old) }
            pendingRescan = nil
        }
        // The lost relocalization offer belongs to the quality sheet; the next room starts fresh anyway.
        if alert?.id == HouseAlert.relocalizationLost().id { alert = nil }
        apply(.finishTapped)
        prepareNaming(room)
    }

    /// Discard on the quality sheet, after its confirmation: `ProjectLibrary.discardRoom` removes
    /// only the room just saved (the project too when no room is left, which ends the flow).
    func discardRoom() {
        guard phase == .quality || phase == .checking, let project = projectID, let room = finishedRoomID else { return }
        alert = nil
        alertFollowUp = .stay
        var deletedProject = false
        do {
            deletedProject = try ProjectLibrary.shared.discardRoom(room, in: project)
            log("discarded room \(room)\(deletedProject ? " and its project" : "")")
        } catch {
            log("discard of room \(room) failed: \(StoreFiles.describe(error))")
        }
        finishedRecord = nil
        checkingRoomID = nil
        setEvaluation(nil)
        if isDemo && !deletedProject { removeDemoRoom(room) }
        if deletedProject {
            apply(.roomDiscarded(hasRooms: false))
            endFlow()
        } else {
            apply(.roomDiscarded(hasRooms: true))
            enterRoomList()
        }
    }

    // MARK: - Naming

    /// The naming prompt: the room's current name, `Copy.House.roomSuggestions` at once, then the
    /// detected section name first once `CapturedRoomStore.loadInput` and
    /// `CleanModelBuilder.sectionLabel(_:polygon:)` ran off main.
    func prepareNaming(_ room: UUID) {
        let current = readManifest()?.rooms.first(where: { $0.id == room })?.name ?? ""
        naming = HouseNamingRequest(id: room, suggestions: HousePresentation.suggestedNames(sectionLabel: nil), current: current)
        if isDemo {
            let label = demoRooms.first(where: { $0.recordID == room })?.sectionLabel
            namingLabelLoaded(label, room: room)
            return
        }
        guard let package = projectPackage, let record = finishedRecord, record.id == room else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let label = HouseFlowModel.sectionLabel(package: package, record: record)
            await self?.namingLabelLoaded(label, room: room)
        }
    }

    /// The RoomPlan section label of a saved room (nil when its CapturedRoom cannot be read).
    nonisolated static func sectionLabel(package: ProjectPackage, record: RoomRecord) -> String? {
        guard let input = try? CapturedRoomStore.loadInput(package, room: record) else { return nil }
        let polygon = RoomOutline.build(input).polygon
        return CleanModelBuilder.sectionLabel(input, polygon: polygon)
    }

    /// Puts the detected section name first in the open naming prompt.
    func namingLabelLoaded(_ label: String?, room: UUID) {
        guard let label, var request = naming, request.id == room else { return }
        request.suggestions = HousePresentation.suggestedNames(sectionLabel: label)
        naming = request
    }

    /// Save on the naming prompt: writes `RoomRecord.name` (empty keeps the default title).
    func name(_ text: String) {
        guard phase == .naming, let request = naming else { return }
        do {
            try updateManifest { manifest in HouseManifestRules.setName(text, room: request.id, in: &manifest) }
        } catch {
            log("room \(request.id) name not saved: \(StoreFiles.describe(error))")
        }
        if isDemo { renameDemoRoom(request.id, to: text) }
        naming = nil
        apply(.named)
        enterRoomList()
    }

    /// Skip on the naming prompt: the room keeps its default title.
    func skipNaming() {
        guard phase == .naming else { return }
        naming = nil
        apply(.named)
        enterRoomList()
    }

    // MARK: - Room list

    /// The room list is showing: fresh rows, no timers.
    func enterRoomList() {
        stopTimers()
        showsNextRoomHint = false
        refreshRows()
    }

    /// Reloads the rows off main from the manifest, the Structure report and the edit log.
    func refreshRows() {
        guard let package = projectPackage else { return }
        rowsRequest += 1
        let token = rowsRequest
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = HouseFlowModel.loadRows(package: package)
            await self?.rowsLoaded(loaded, token: token)
        }
    }

    /// Rows of a package: `HousePresentation.rows` over the manifest, `StructureStore.loadReport`
    /// and the user alignments of `EditStore.load`. Nil when the manifest cannot be read.
    nonisolated static func loadRows(package: ProjectPackage) -> [HouseRoomRow]? {
        guard let manifest = try? ProjectStore.readManifest(package) else { return nil }
        let report = StructureStore.loadReport(package)
        let aligned = Set(StructureStore.userAlignments(EditStore.load(package)).keys)
        return HousePresentation.rows(manifest: manifest, report: report, userAligned: aligned)
    }

    /// Publishes a listing unless a newer one was requested.
    func rowsLoaded(_ loaded: [HouseRoomRow]?, token: Int) {
        guard token == rowsRequest, let loaded else { return }
        setRows(loaded)
    }

    /// Scan Next Room: `startNextRoom(roomID:)` on the same engine and session; after a system
    /// stop, a failure or a Cancel the engine is torn down and a new session relocalizes (the
    /// paused session's frame is not trusted); after a lost relocalization a fresh unaligned
    /// session starts. Demo Mode starts a new fake engine.
    func scanNextRoom() {
        guard phase == .roomList, !hasEnded, projectID != nil else { return }
        let room = UUID()
        if isDemo {
            makeDemoEngine(roomID: room)
            apply(.nextRoom(relocalize: false))
            if startEngine(roomID: room, isNext: false) { showNextRoomHint() }
            return
        }
        if freshSessionRequired {
            startFreshSession(signal: .nextRoom(relocalize: false))
            showNextRoomHint()
            return
        }
        guard !needsNewSession, let current = roomEngine, current.state == .finished, current.lastResult != nil else {
            log("next room needs a new session; relocalizing")
            teardownEngine()
            apply(.nextRoom(relocalize: true))
            beginRelocalization(preferRoom: pendingRescan)
            return
        }
        apply(.nextRoom(relocalize: false))
        if case .relocalized? = sessionLink {
            relocalizedRoomStartedAt = ProcessInfo.processInfo.systemUptime
        } else {
            relocalizedRoomStartedAt = nil
        }
        if startEngine(roomID: room, isNext: true) { showNextRoomHint() }
    }

    /// Rescan from the room list: the next capture supersedes `roomID` when kept (on its floor).
    func rescan(_ roomID: UUID) {
        guard phase == .roomList else { return }
        pendingRescan = roomID
        if let floor = readManifest()?.rooms.first(where: { $0.id == roomID })?.floorIndex {
            setCurrentFloor(floor)
        }
        log("rescan of room \(roomID)")
        scanNextRoom()
    }

    /// Add Floor: appends a `FloorRecord` and switches `currentFloor` to it.
    func addFloor() {
        guard phase == .roomList else { return }
        var added: Int?
        do {
            try updateManifest { manifest in added = HouseManifestRules.addFloor(to: &manifest) }
        } catch {
            log("floor not added: \(StoreFiles.describe(error))")
            return
        }
        guard let floor = added else { return }
        setCurrentFloor(floor)
        Haptics.selection()
        log("floor \(floor) added; new rooms go on it")
        refreshRows()
    }

    /// Finish Building: tears the engine down, sets `.finishing`, and calls `onComplete(projectID)`
    /// (AppShell enqueues merge, alignment and the House clean model; Demo Mode stays `.ready`).
    func finishBuilding() {
        guard phase == .roomList, let id = projectID, !hasEnded else { return }
        teardownEngine()
        apply(.finishBuilding)
        stopTimers()
        announcer.reset()
        releaseIdleToken()
        if isDemo {
            do {
                try updateManifest { manifest in manifest.status = .ready }
            } catch {
                log("demo project status not set: \(StoreFiles.describe(error))")
            }
        }
        hasEnded = true
        log("finish building: project \(id) handed over")
        onComplete?(id)
        apply(.finished(id))
    }

    /// "Room 3, Floor 1" for the room about to start (a Rescan shows the old room's title).
    func updateRoomChip() {
        let manifest = readManifest()
        let active = manifest.map { StructureEligibility.activeRooms($0) } ?? []
        var title = Copy.FloorPlan.defaultRoomTitle(active.count + 1)
        if let old = pendingRescan, let index = active.firstIndex(where: { $0.id == old }) {
            title = HousePresentation.roomTitle(active[index], index: index)
        }
        let floor = HousePresentation.floorTitle(currentFloor, floors: manifest?.floors ?? [])
        roomChipText = Copy.HouseUI.roomChip(title, floor: floor)
    }
}
