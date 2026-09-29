import Foundation

// The pure phase reducer of the house flow (docs/MODULES.md 3.41) and the sheet each phase shows.
//
// | From | Signal | To |
// |---|---|---|
// | preflight | preflightPassed(showTips, relocalize) | tips, else relocalizing or capturing |
// | preflight | preflightBlocked | cancelled |
// | preflight | permissionNeeded | permission |
// | permission | permissionGranted(showTips, relocalize) | as preflightPassed |
// | preflight, permission | permissionDenied | cancelled |
// | tips | tipsDone(relocalize) | relocalizing or capturing |
// | relocalizing | relocalized | capturing |
// | relocalizing, checking, quality, roomList | startedFresh | capturing (lost relocalization) |
// | capturing | doneTapped, engineStopping | stopping |
// | capturing, stopping | roomFinished | checking |
// | checking | evaluated | quality |
// | checking, quality | finishTapped | naming |
// | checking, quality | roomDiscarded(hasRooms) | roomList, else cancelled |
// | naming | named | roomList |
// | roomList | nextRoom(relocalize) | relocalizing or capturing |
// | roomList | finishBuilding | finishing |
// | finishing | finished(id) | done(id) |
// | preflight ... stopping | cancelConfirmed(hasRooms) | roomList, else cancelled |
// | preflight ... stopping | failed(reason) | failed(reason) |
// Terminal phases (done, failed, cancelled) never change; any other pair leaves the phase as it is.

/// The sheet the house screen presents over the camera.
enum HouseSheetKind: String, Identifiable, Sendable {
    /// QualityUI's quality sheet (checking and quality).
    case quality
    /// The naming prompt.
    case naming
    /// The room list.
    case rooms

    /// Identity for `.sheet(item:)`.
    var id: String { rawValue }
}

extension HouseFlowModel {
    /// Pure phase reducer used by the model and the self-test (table above).
    nonisolated static func nextPhase(_ phase: HouseFlowPhase, on signal: HouseFlowSignal) -> HouseFlowPhase {
        if isTerminal(phase) { return phase }
        switch signal {
        case .preflightPassed(let showTips, let relocalize):
            return phase == .preflight ? entry(showTips: showTips, relocalize: relocalize) : phase
        case .preflightBlocked:
            return phase == .preflight ? .cancelled : phase
        case .permissionNeeded:
            return phase == .preflight ? .permission : phase
        case .permissionGranted(let showTips, let relocalize):
            return phase == .permission ? entry(showTips: showTips, relocalize: relocalize) : phase
        case .permissionDenied:
            return phase == .preflight || phase == .permission ? .cancelled : phase
        case .tipsDone(let relocalize):
            guard phase == .tips else { return phase }
            return relocalize ? .relocalizing : .capturing
        case .relocalized:
            return phase == .relocalizing ? .capturing : phase
        case .startedFresh:
            switch phase {
            case .relocalizing, .checking, .quality, .roomList: return .capturing
            default: return phase
            }
        case .doneTapped, .engineStopping:
            return phase == .capturing ? .stopping : phase
        case .roomFinished:
            return phase == .capturing || phase == .stopping ? .checking : phase
        case .evaluated:
            return phase == .checking ? .quality : phase
        case .finishTapped:
            return phase == .quality || phase == .checking ? .naming : phase
        case .roomDiscarded(let hasRooms):
            guard phase == .quality || phase == .checking else { return phase }
            return hasRooms ? .roomList : .cancelled
        case .named:
            return phase == .naming ? .roomList : phase
        case .nextRoom(let relocalize):
            guard phase == .roomList else { return phase }
            return relocalize ? .relocalizing : .capturing
        case .finishBuilding:
            return phase == .roomList ? .finishing : phase
        case .finished(let projectID):
            return phase == .finishing ? .done(projectID) : phase
        case .cancelConfirmed(let hasRooms):
            guard isBeforeRoomSaved(phase) else { return phase }
            return hasRooms ? .roomList : .cancelled
        case .failed(let reason):
            return isBeforeRoomSaved(phase) ? .failed(reason) : phase
        }
    }

    /// Tips first when they were not seen, else the relocalization or the capture.
    nonisolated static func entry(showTips: Bool, relocalize: Bool) -> HouseFlowPhase {
        if showTips { return .tips }
        return relocalize ? .relocalizing : .capturing
    }

    /// True for done, failed and cancelled.
    nonisolated static func isTerminal(_ phase: HouseFlowPhase) -> Bool {
        switch phase {
        case .done, .failed, .cancelled: return true
        case .preflight, .permission, .tips, .relocalizing, .capturing, .stopping, .checking, .quality, .naming,
             .roomList, .finishing:
            return false
        }
    }

    /// True for the phases before the current capture was saved: preflight, permission, tips,
    /// relocalizing, capturing and stopping.
    nonisolated static func isBeforeRoomSaved(_ phase: HouseFlowPhase) -> Bool {
        switch phase {
        case .preflight, .permission, .tips, .relocalizing, .capturing, .stopping: return true
        case .checking, .quality, .naming, .roomList, .finishing, .done, .failed, .cancelled: return false
        }
    }

    /// The sheet of the current phase: quality while checking or showing the quality (not while
    /// AppShell's missing-areas tour runs), naming, or the room list.
    var presentedSheet: HouseSheetKind? {
        switch phase {
        case .checking, .quality: return isTourActive ? nil : .quality
        case .naming: return .naming
        case .roomList: return .rooms
        case .preflight, .permission, .tips, .relocalizing, .capturing, .stopping, .finishing, .done, .failed,
             .cancelled:
            return nil
        }
    }

    /// True while RoomPlan's view, the relocalization camera or the demo backdrop should show.
    var showsCamera: Bool {
        switch phase {
        case .relocalizing, .capturing, .stopping, .checking, .quality, .naming, .roomList, .finishing: return true
        case .preflight, .permission, .tips, .done, .failed, .cancelled: return isDiscarding
        }
    }
}
