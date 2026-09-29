import Foundation
import UIKit

// Engine events of the house flow (docs/MODULES.md 3.41, ARCHITECTURE 4.2 and 4.3): snapshots,
// state changes, failures before and after a room was saved (including the lost relocalization
// of RESEARCH 3.2 disputed 7), capture start failures, and Cancel during a room with its ordered
// discard. Main actor (extension of the model); events of a replaced engine are ignored.

extension HouseFlowModel {
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
}
