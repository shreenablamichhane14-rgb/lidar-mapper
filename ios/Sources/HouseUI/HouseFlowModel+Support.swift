import Foundation
import UIKit

// Supporting parts of HouseFlowModel (docs/MODULES.md 3.41): the project and manifest helpers,
// Demo Mode rooms (ScanUI's synthetic room placed into the house by HouseDemo), the 1 Hz ticker
// with the paused prompt and the 4 and 5 minute cues, photo and next-room hints, the idle timer
// hold, backgrounding, alert presentation helpers and the log. Main actor (extension of the
// model) unless marked nonisolated.

/// Result of writing one Demo Mode room off the main thread.
enum HouseDemoRoomOutcome: Sendable {
    /// The room's record, its evaluation and the room placed into the house.
    case made(RoomRecord, QualityEvaluation, CleanRoom)
    /// The demo room could not be written; diagnostic text.
    case failed(String)
}

extension HouseFlowModel {
    // MARK: - Project and manifest

    /// Continue Scanning and Rescan: the package, capture settings and floor of the existing
    /// house (the rescanned room's floor, else the latest room's). Demo Mode also reads the
    /// placed demo rooms. False (logged) when the manifest cannot be read.
    func loadExistingProject(_ id: UUID) -> Bool {
        do {
            let found = try ProjectStore.package(for: id)
            let manifest = try ProjectStore.readManifest(found)
            setProject(id, package: found)
            projectSettings = manifest.settings
            let active = StructureEligibility.activeRooms(manifest)
            if let rescan = pendingRescan, let room = manifest.rooms.first(where: { $0.id == rescan }) {
                setCurrentFloor(room.floorIndex)
            } else if let latest = active.max(by: { $0.capturedAt < $1.capturedAt }) {
                setCurrentFloor(latest.floorIndex)
            }
            if isDemo {
                demoRooms = (try? CleanModelStore.loadBase(found).rooms) ?? []
            }
            log("house \(id) opened: \(active.count) active rooms, \(manifest.sessions.count) sessions, floor \(currentFloor)")
            refreshRows()
            return true
        } catch {
            log("house \(id) could not be opened: \(StoreFiles.describe(error))")
            return false
        }
    }

    /// The project's manifest, or nil when it cannot be read (small JSON, main is fine).
    func readManifest() -> ProjectManifest? {
        guard let package = projectPackage else { return nil }
        return try? ProjectStore.readManifest(package)
    }

    /// True when the project lists at least one active room (`StructureEligibility.activeRooms`).
    func hasActiveRooms() -> Bool {
        guard let manifest = readManifest() else { return false }
        return !StructureEligibility.activeRooms(manifest).isEmpty
    }

    /// `ProjectLibrary.update` of this visit's project.
    @discardableResult
    func updateManifest(_ mutate: (inout ProjectManifest) throws -> Void) throws -> ProjectManifest {
        guard let id = projectID else { throw MapperError.ioFailed("no project") }
        return try ProjectLibrary.shared.update(id, mutate)
    }

    // MARK: - Demo Mode rooms

    /// Writes the demo room off main (`DemoProjectFactory.makeDemoRoom`), reads its clean room
    /// back with `CleanModelStore.loadBase` and places it with `HouseDemo.placed`.
    func beginDemoRoom(_ id: UUID) {
        guard let package = projectPackage, let session = sessionID else {
            demoRoomFinished(.failed("no package"), roomID: id)
            return
        }
        let floor = currentFloor
        let placed = demoRooms
        let link = sessionLink ?? .unaligned
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = HouseFlowModel.makeDemoRoom(package: package, sessionID: session, roomID: id, floor: floor,
                                                      link: link, placed: placed, now: now)
            await self?.demoRoomFinished(outcome, roomID: id)
        }
    }

    /// The off-main part of a demo room. The record gets the visit's floor and session link.
    nonisolated static func makeDemoRoom(package: ProjectPackage, sessionID: UUID, roomID: UUID, floor: Int,
                                         link: FrameLink, placed: [CleanRoom], now: Date) -> HouseDemoRoomOutcome {
        do {
            let made = try DemoProjectFactory.makeDemoRoom(package: package, sessionID: sessionID, roomID: roomID, now: now)
            var record = made.0
            record.floorIndex = floor
            record.frameLink = link
            let base = try CleanModelStore.loadBase(package)
            guard let built = base.rooms.first(where: { $0.recordID == roomID }) else {
                return .failed("demo room missing from clean.json")
            }
            let room = HouseDemo.placed(built, name: "", floorIndex: floor, after: placed)
            return .made(record, made.1, room)
        } catch {
            return .failed(StoreFiles.describe(error))
        }
    }

    /// The demo room was written: recorded with the project `.ready` (never enqueued), the demo
    /// house rewritten, then its evaluation on the sheet. A failure leaves the room out.
    func demoRoomFinished(_ outcome: HouseDemoRoomOutcome, roomID: UUID) {
        switch outcome {
        case .made(let record, let result, let room):
            demoRooms.removeAll { $0.recordID == room.recordID }
            demoRooms.append(room)
            do {
                try updateManifest { manifest in
                    HouseManifestRules.append(record, to: &manifest)
                    manifest.status = .ready
                }
            } catch {
                log("demo room \(roomID) not recorded: \(StoreFiles.describe(error))")
            }
            finishedRecord = record
            writeDemoHouse()
            refreshRows()
            guard finishedRoomID == roomID, phase == .checking, !hasEnded else { return }
            setEvaluation(result)
            apply(.evaluated)
        case .failed(let reason):
            log("demo room \(roomID) failed: \(reason)")
            guard phase == .checking || phase == .quality else { return }
            let rooms = hasActiveRooms()
            let notice = HouseAlert.from(ScanErrorCopy.notice(for: MapperError.ioFailed("demo")))
            apply(.roomDiscarded(hasRooms: rooms))
            if rooms {
                enterRoomList()
                present(notice, followUp: .stay)
            } else {
                removeEmptyProject(reason: "the demo room could not be written")
                present(notice, followUp: .endFlow)
            }
        }
    }

    /// Rewrites the demo house (active rooms only) off main; writes run one after another.
    func writeDemoHouse() {
        guard let package = projectPackage, let manifest = readManifest() else { return }
        let activeIDs = Set(StructureEligibility.activeRooms(manifest).map { $0.id })
        let rooms = demoRooms.filter { activeIDs.contains($0.recordID) }
        guard !rooms.isEmpty else { return }
        let previous = demoWrite
        demoWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try HouseDemo.write(rooms, manifest: manifest, package: package)
            } catch {
                LogStore.shared.write("demo house not written: \(StoreFiles.describe(error))",
                                      category: HouseRelocalization.logCategory)
            }
        }
    }

    /// Drops a discarded or superseded demo room and rewrites the house.
    func removeDemoRoom(_ id: UUID) {
        demoRooms.removeAll { $0.recordID == id }
        writeDemoHouse()
    }

    /// Names a demo room in the demo clean model too (plan titles use it).
    func renameDemoRoom(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = demoRooms.firstIndex(where: { $0.recordID == id }) else { return }
        demoRooms[index].name = String(trimmed.prefix(HousePresentation.maxRoomNameLength))
        writeDemoHouse()
    }

    // MARK: - Timed cues

    /// Starts the 1 Hz ticker of the capture.
    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let model = self else { return }
                model.tick()
            }
        }
    }

    /// Stops the ticker and hides the time hint.
    func stopTimers() {
        ticker?.cancel()
        ticker = nil
        showsTimeHint = false
        timeHintHideAt = nil
    }

    /// One tick: hides the hints after their time; after 30 seconds paused (with nothing else on
    /// screen) shows the Finish Now or Resume prompt once per pause.
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let hideAt = timeHintHideAt, now >= hideAt {
            showsTimeHint = false
            timeHintHideAt = nil
        }
        if let hideAt = nextHintHideAt, now >= hideAt {
            showsNextRoomHint = false
            nextHintHideAt = nil
        }
        guard phase == .capturing, isPaused, let since = pausedSince else { return }
        guard alert == nil, !showsCancelConfirmation, !showsTimeLimitCard else { return }
        guard ScanFlowModel.pausedPromptDue(pausedSeconds: now - since, alreadyPrompted: pausedPrompted) else { return }
        pausedPrompted = true
        Haptics.warning()
        present(HouseAlert.from(ScanErrorCopy.pausedPrompt()), followUp: .stay)
    }

    /// Checks the 4 minute hint and the 5 minute limit against the scan time of a snapshot.
    func checkTimeCues(elapsed: Double) {
        guard phase == .capturing else { return }
        switch ScanFlowModel.timeCue(elapsed: elapsed, hintShown: timeHintShown, limitShown: timeLimitShown) {
        case .hint:
            timeHintShown = true
            showsTimeHint = true
            timeHintHideAt = ProcessInfo.processInfo.systemUptime + ScanFlowTiming.timeHintVisibleSeconds
            log("time hint at \(Int(elapsed)) s")
        case .limit:
            timeLimitShown = true
            timeHintShown = true
            showsTimeHint = false
            timeHintHideAt = nil
            showsTimeLimitCard = true
            Haptics.warning()
            log("time limit card at \(Int(elapsed)) s")
        case nil:
            break
        }
    }

    /// Keep Scanning on the time limit card.
    func dismissTimeLimit() {
        showsTimeLimitCard = false
    }

    /// "Start at the doorway you walked in through" for a few seconds at the start of a room.
    func showNextRoomHint() {
        showsNextRoomHint = true
        nextHintHideAt = ProcessInfo.processInfo.systemUptime + ScanFlowTiming.timeHintVisibleSeconds
    }

    /// The photo recorder saved a photo (main).
    func photoSaved() {
        guard phase == .capturing || phase == .stopping else { return }
        showPhotoNote()
    }

    /// Shows "Photo saved to this spot" for a moment.
    func showPhotoNote() {
        showsPhotoNote = true
        photoNoteTask?.cancel()
        let delay = UInt64(ScanFlowTiming.photoNoteSeconds * 1_000_000_000)
        photoNoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.showsPhotoNote = false
        }
    }

    // MARK: - Screen lifecycle

    /// The screen appeared: hold the idle timer (Pipeline's `IdleTimerGuard`; this module never
    /// writes `isIdleTimerDisabled`).
    func screenAppeared() {
        guard idleToken == nil, !hasEnded else { return }
        idleToken = IdleTimerGuard.acquire("house scan screen")
    }

    /// The screen disappeared: give the idle timer hold back.
    func screenDisappeared() {
        releaseIdleToken()
    }

    /// Releases the idle timer hold, when held.
    func releaseIdleToken() {
        guard let token = idleToken else { return }
        idleToken = nil
        IdleTimerGuard.release(token)
    }

    /// The app went to the background. The room engine pauses itself on the ARSession
    /// interruption; the Demo Mode engine is paused here so the paused chrome can be tried.
    func appDidEnterBackground() {
        guard phase == .capturing else { return }
        leftScreenWhileScanning = true
        guard isDemo, !isPaused, let current = engine else { return }
        log("demo engine paused for the background")
        current.pause()
    }

    /// The app is in front again: when the scan paused while Mapper was away, the interrupted
    /// alert (`Copy.Errors.interrupted`) offers Resume and Finish Now.
    func appDidBecomeActive() {
        guard leftScreenWhileScanning else { return }
        guard phase == .capturing else {
            leftScreenWhileScanning = false
            return
        }
        guard isPaused else { return }
        leftScreenWhileScanning = false
        guard alert == nil, !showsCancelConfirmation, !showsTimeLimitCard else { return }
        pausedPrompted = true
        Haptics.warning()
        present(HouseAlert.from(ScanErrorCopy.interruptedAlert()), followUp: .stay)
    }

    // MARK: - Alert presentation helpers

    /// True when alerts show as a notice card over a sheet instead of a system alert.
    var showsAlertAsNotice: Bool {
        presentedSheet != nil
    }

    /// Binding target of the system alert: reads "an alert and no sheet"; writes are ignored,
    /// because every alert closes through its buttons (`alertAction`), which clear `alert`.
    var systemAlertPresented: Bool {
        get { alert != nil && !showsAlertAsNotice }
        set { _ = newValue }
    }

    /// Remembers when an alert or dialog closed.
    func markPresentationClosed() {
        lastPresentationClosed = ProcessInfo.processInfo.systemUptime
    }

    /// Seconds still to wait before the next presentation after the last alert or dialog closed.
    func presentationGapRemaining() -> Double {
        let since = ProcessInfo.processInfo.systemUptime - lastPresentationClosed
        return Swift.max(0, ScanFlowTiming.presentationGapSeconds - since)
    }

    // MARK: - Log

    /// Writes one line to the app log (category "house").
    func log(_ message: String) {
        LogStore.shared.write(message, category: HouseRelocalization.logCategory)
    }

    /// Log text of a start request (ids only, never names).
    nonisolated static func describe(_ start: HouseScanStart) -> String {
        switch start {
        case .newProject: return "new house"
        case .continueProject(let id): return "continue \(id)"
        case .rescan(let project, let room): return "rescan \(room) of \(project)"
        }
    }
}
