import Foundation
import Combine
import UIKit
import AVFoundation

/// How a house flow starts (AppShell 5d presents the flow as a full-screen cover).
enum HouseScanStart: Equatable, Sendable {
    /// New Scan > House / Building: creates the project; the first session is the project frame.
    case newProject
    /// Continue Scanning on an existing house: a new session that relocalizes first.
    case continueProject(UUID)
    /// Rescan one room of an existing house: a new session that relocalizes (preferring that
    /// room's own map); the new capture supersedes the room when the user keeps it.
    case rescan(project: UUID, room: UUID)
}

/// One house cover request (AppShell's `AppCover.house`).
struct HouseScanRequest: Identifiable, Equatable, Sendable {
    /// Identity of the cover.
    var id: UUID
    /// How the flow starts.
    var start: HouseScanStart
    /// Demo Mode: `FakeScanEngine`, no camera, no ARKit.
    var isDemo: Bool
}

/// Where the house flow is (only `HouseFlowModel.apply(_:)` changes it, through `nextPhase`).
enum HouseFlowPhase: Equatable {
    case preflight, permission, tips, relocalizing, capturing, stopping, checking, quality, naming, roomList, finishing
    case done(UUID), failed(String), cancelled
}

/// Inputs of the pure phase reducer (`HouseFlowModel.nextPhase(_:on:)`).
enum HouseFlowSignal: Equatable, Sendable {
    case preflightPassed(showTips: Bool, relocalize: Bool), preflightBlocked, permissionNeeded
    case permissionGranted(showTips: Bool, relocalize: Bool), permissionDenied, tipsDone(relocalize: Bool)
    case relocalized, startedFresh, doneTapped, engineStopping, roomFinished, evaluated, finishTapped
    case roomDiscarded(hasRooms: Bool), named, nextRoom(relocalize: Bool), finishBuilding, finished(UUID)
    case cancelConfirmed(hasRooms: Bool), failed(String)
}

/// What closing the current alert does next.
enum HouseAlertFollowUp: Equatable, Sendable {
    /// Nothing more.
    case stay
    /// Show the next preflight warning, then the tips, the capture or the relocalization.
    case continueChecks
    /// End the flow (`onDismiss`).
    case endFlow
}

/// The House / Building flow for an amateur, room by room (docs/MODULES.md 3.41, ARCHITECTURE
/// 4.3, D9, D17): preflight, permission and tips; one `RoomScanEngine` (one `RoomCaptureView`,
/// one `ARSession`) per visit with `startNextRoom(roomID:)` between rooms; the quality sheet
/// after each room; naming; the room list; Scan Next Room, Rescan, Add Floor, Finish Building;
/// relocalization on later visits with Start Fresh Here; Demo Mode.
///
/// Files: this file holds the state, the state writers and the checks before the capture;
/// `HouseFlowReducer.swift` the pure reducer; `HouseFlowModel+Actions.swift` the capture
/// controls, Cancel, the missing-areas hand-off and alerts; `HouseFlowModel+Session.swift`
/// engines, sessions, relocalization and teardown; `HouseFlowModel+Events.swift` engine events,
/// failures and the discard; `HouseFlowModel+Rooms.swift` the room finish, quality, naming, room
/// list actions and floors; `HouseFlowModel+Support.swift` Demo Mode rooms, timers, screen
/// lifecycle and small helpers.
@MainActor final class HouseFlowModel: ObservableObject {
    // MARK: Published state (contract, docs/MODULES.md 3.41)

    /// Where the flow is.
    @Published private(set) var phase: HouseFlowPhase = .preflight
    /// The latest live snapshot of the engine.
    @Published private(set) var snapshot = LiveScanSnapshot()
    /// The quality evaluation of the room just saved (nil while checking).
    @Published private(set) var evaluation: QualityEvaluation?
    /// Room list rows (active rooms, floor then capture order).
    @Published private(set) var rows: [HouseRoomRow] = []
    /// `Copy.House.progressSummary(done:total:)` of `rows`.
    @Published private(set) var progressText = ""
    /// Floor index new rooms go on.
    @Published private(set) var currentFloor = 0
    /// Seconds since the relocalization (or Keep Looking) started, for the Start Fresh Here offer.
    @Published private(set) var relocalizationElapsed: Double = 0
    /// True after `HouseRelocalization.timeoutSeconds`, or at once when there is no map.
    @Published private(set) var showsStartFresh = false
    /// Under 800 MB available after a room (D17): the room list suggests finishing.
    @Published private(set) var lowMemory = false
    /// Engine `.paused`: the chrome shows Resume and Finish Now.
    @Published private(set) var isPaused = false
    /// True from the Show Missing Areas tap until `refreshEvaluation(_:stoppedBySystem:)`: the quality
    /// sheet is not presented while AppShell's missing-areas tour runs over this screen (3.43e).
    @Published private(set) var isTourActive = false
    /// The alert to show (a system alert, or a notice card while a sheet is up).
    @Published var alert: HouseAlert?
    /// The Cancel confirmation ("Stop this scan?") is showing.
    @Published var showsCancelConfirmation = false
    /// The naming prompt after a room is kept.
    @Published var naming: HouseNamingRequest?

    // MARK: Published extras for the screens (written by the model only)

    /// The engine's lifecycle state (the chrome shows "Getting ready" while `.starting`).
    @Published var engineState: ScanEngineState = .idle
    /// True once RoomPlan's view may be mounted for `roomEngine` (false while relocalizing).
    @Published var isCaptureViewMounted = false
    /// True once `roomEngine` was torn down: its camera view is removed (dismantling is idempotent).
    @Published var cameraReleased = false
    /// The house has no usable room map: the relocalization screen offers Start Fresh Here at once.
    @Published var noMapAvailable = false
    /// "Room 3, Floor 1" on the scan screen (`Copy.HouseUI.roomChip`).
    @Published var roomChipText = ""
    /// The tips page is showing.
    @Published var showsTips = false
    /// The camera prompt is up (Continue disabled).
    @Published var isRequestingPermission = false
    /// "Photo saved to this spot" is showing.
    @Published var showsPhotoNote = false
    /// "Start at the doorway you walked in through" is showing.
    @Published var showsNextRoomHint = false
    /// The 4 minute hint is showing.
    @Published var showsTimeHint = false
    /// The 5 minute time limit card is showing.
    @Published var showsTimeLimitCard = false
    /// A confirmed Cancel is waiting for the engine to stop and delete the capture.
    @Published var isDiscarding = false
    /// The record of the room just saved (AppShell's missing-areas tour target).
    @Published var finishedRecord: RoomRecord?

    // MARK: Configuration and results

    /// The cover request.
    let request: HouseScanRequest
    /// Live guidance: banner kind, VoiceOver announcements and warning haptics.
    let announcer: GuidanceAnnouncer
    /// The project of this visit, once known.
    private(set) var projectID: UUID?
    /// The visit's engine (nil in Demo Mode); HouseScanScreen hosts its view. AppShell's
    /// missing-areas tour (5d) uses it and `lastResult`.
    private(set) var roomEngine: RoomScanEngine?
    /// The result of the room just saved.
    private(set) var lastResult: RoomScanResult?
    /// Main. Called once when the visit ends with at least one room (Finish Building, or the
    /// flow closing after a system stop); AppShell enqueues the House plan and opens Results.
    var onComplete: ((UUID) -> Void)?
    /// Main. Called when the flow ends without a room (the new project was deleted).
    var onDismiss: (() -> Void)?
    /// AppShell (5d) wires MissingAreas here. The quality sheet offers Show Missing Areas only when
    /// this is set and `canShowMissingAreas`; the tap sets `isTourActive`, then calls it.
    var onShowMissingAreas: (() -> Void)?
    /// Optional capture add-ons, called once per engine with its MeshStore before the engine
    /// exists: extra recorders plus a hook installer (AppShell 5d wires CoverageLive here the
    /// same way the ScanUI 5c revision does for rooms). Nil in build 5b.
    var captureExtras: ((MeshStore) -> (recorders: [ScanRecorder], install: (RoomScanEngine) -> Void))?

    // MARK: Internal state (used by the extensions in the other HouseFlowModel files)

    /// The engine being driven (the room engine, or a fake engine in Demo Mode), its serial
    /// (events of a replaced engine are ignored), its Take Photo recorder and mesh store.
    var engine: ScanEngine?, engineSerial = 0, photoRecorder: PhotoRecorder?, meshStore: MeshStore?
    /// The project's package and capture settings; true when this visit created the project.
    var package: ProjectPackage?, projectSettings = ScanSettings.room, createdProject = false
    /// The current ARKit session and the frame link recorded for it (nil until decided).
    var sessionID: UUID?, sessionLink: FrameLink?
    /// The room being captured, the room the engine saved, and the room a Rescan replaces.
    var currentRoomID: UUID?, finishedRoomID: UUID?, pendingRescan: UUID?
    /// The room a relocalizing engine will capture once the session is decided.
    var pendingRoomID: UUID?
    /// The next room needs a new session (system stop, failure, discard) or a fresh unaligned one.
    var needsNewSession = false, freshSessionRequired = false
    /// The map the current session relocalizes against, the poll and the map load.
    var relocalizationSource: (session: UUID, room: UUID)?
    /// The relocalization poll and the world map load tasks.
    var relocalizationTask: Task<Void, Never>?, relocalizationLoad: Task<Void, Never>?
    /// Uptime when the relocalization (or Keep Looking) started; relocalization time of `.normal`.
    var relocalizationStartedAt: TimeInterval = 0, normalSince: Double?, timeoutLogged = false
    /// Uptime when a room of a relocalized session started, and when the current room ended.
    var relocalizedRoomStartedAt: TimeInterval?, roomEndedAt: TimeInterval?
    /// System stops of the room and of a tour of it (Show Missing Areas is then hidden).
    var roomStoppedBySystem = false, tourStoppedBySystem = false
    /// Rooms that stay `.needsRescan` whatever their evaluation says (lost relocalization).
    var forcedNeedsRescan: Set<UUID> = []
    /// The room whose quality check is running.
    var checkingRoomID: UUID?
    /// Demo Mode: the placed demo rooms of the house and the chained write of the demo model.
    var demoRooms: [CleanRoom] = [], demoWrite: Task<Void, Never>?
    /// `begin()` ran; the flow ended through `endFlow` or `finishBuilding`.
    var hasBegun = false, hasEnded = false
    /// Preflight warnings still to show, and what closing the current alert does next.
    var pendingWarnings: [PreflightIssue] = [], alertFollowUp: HouseAlertFollowUp = .stay
    /// Uptime when the last alert or dialog closed.
    var lastPresentationClosed: TimeInterval = -1_000
    /// Idle timer hold while the screen is visible.
    var idleToken: UUID?
    /// The 1 Hz ticker and other short tasks.
    var ticker: Task<Void, Never>?, photoNoteTask: Task<Void, Never>?, discardTimeout: Task<Void, Never>?
    /// Uptime when the engine paused, and whether this pause already prompted.
    var pausedSince: TimeInterval?, pausedPrompted = false
    /// Timed cues of the current room, and when the hints hide.
    var timeHintShown = false, timeLimitShown = false, timeHintHideAt: TimeInterval?, nextHintHideAt: TimeInterval?
    /// First `.scanning` of the room (start haptic), and a discard waiting for `.idle`.
    var hasStartedScanning = false, awaitingDiscardIdle = false
    /// Mapper went to the background while scanning (the interrupted alert shows on return).
    var leftScreenWhileScanning = false
    /// Increases for every rows request, so an older listing is not published.
    var rowsRequest = 0

    /// Creates a flow for `request`; nothing runs until `begin()`.
    init(request: HouseScanRequest) {
        self.request = request
        announcer = GuidanceAnnouncer()
        switch request.start {
        case .newProject:
            break
        case .continueProject(let id):
            projectID = id
        case .rescan(let project, let room):
            projectID = project
            pendingRescan = room
        }
    }

    /// True in Demo Mode.
    var isDemo: Bool { request.isDemo }

    /// `HousePresentation.canOfferMissingAreas` for the room on the quality sheet (not Demo Mode, the
    /// engine `.finished`, no system stop of the room or of an earlier tour of it, at least one
    /// missing area).
    var canShowMissingAreas: Bool {
        let count = evaluation.map { QualityPresentation.missingCount($0) } ?? 0
        return HousePresentation.canOfferMissingAreas(isDemo: isDemo, engineState: roomEngine?.state,
                                                      stoppedBySystem: roomStoppedBySystem || tourStoppedBySystem,
                                                      missingAreas: count)
    }

    // MARK: - State writers (the only places that change the contract's read-only state)

    /// Moves the phase through the pure reducer and logs real changes.
    func apply(_ signal: HouseFlowSignal) {
        let next = HouseFlowModel.nextPhase(phase, on: signal)
        guard next != phase else { return }
        log("phase \(phase) -> \(next)")
        phase = next
    }

    /// Stores the project of this visit.
    func setProject(_ id: UUID, package newPackage: ProjectPackage) {
        projectID = id
        package = newPackage
    }

    /// Replaces the engine (the old one's events are dropped from now on).
    func adopt(engine newEngine: ScanEngine?, roomEngine newRoom: RoomScanEngine?, photos: PhotoRecorder?,
               meshes: MeshStore?) {
        engine?.onEvent = nil
        engineSerial += 1
        let serial = engineSerial
        engine = newEngine
        roomEngine = newRoom
        photoRecorder = photos
        meshStore = meshes
        cameraReleased = false
        engineState = .idle
        newEngine?.onEvent = { [weak self] event in
            self?.handle(event, serial: serial)
        }
    }

    /// Stores the result of the room just saved.
    func setLastResult(_ result: RoomScanResult?) { lastResult = result }
    /// Publishes a live snapshot.
    func setSnapshot(_ value: LiveScanSnapshot) { snapshot = value }
    /// Publishes the evaluation shown on the quality sheet.
    func setEvaluation(_ value: QualityEvaluation?) { evaluation = value }
    /// Publishes the room list rows and their progress text.
    func setRows(_ value: [HouseRoomRow]) {
        rows = value
        progressText = HousePresentation.progressText(value)
    }
    /// Sets the floor new rooms go on.
    func setCurrentFloor(_ value: Int) { currentFloor = Swift.max(0, value) }
    /// Publishes the relocalization clock and the Start Fresh Here offer.
    func setRelocalization(elapsed: Double, startFresh: Bool) {
        relocalizationElapsed = elapsed.isFinite ? Swift.max(0, elapsed) : 0
        if showsStartFresh != startFresh { showsStartFresh = startFresh }
    }
    /// Publishes the low memory suggestion.
    func setLowMemory(_ value: Bool) { lowMemory = value }
    /// Publishes the paused state.
    func setPaused(_ value: Bool) { isPaused = value }
    /// Publishes whether the missing-areas tour runs.
    func setTourActive(_ value: Bool) { isTourActive = value }

    // MARK: - Flow start

    /// Preflight, then permission, tips, then capture or relocalization. Idempotent (the screen
    /// also calls it when it appears).
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        log("house flow begin: \(HouseFlowModel.describe(request.start)), demo \(isDemo)")
        if let id = projectID, !loadExistingProject(id) {
            apply(.preflightBlocked)
            present(HouseAlert.from(ScanErrorCopy.alert(for: MapperError.corruptProject("house manifest"))), followUp: .endFlow)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let report = await ScanPreflight.run(mode: .house, isDemo: self.isDemo)
            self.preflightFinished(report)
        }
    }

    /// Applies the preflight result: a blocking issue ends the flow after its alert, an
    /// undetermined camera goes to the permission screen, otherwise the warnings and tips.
    func preflightFinished(_ report: PreflightReport) {
        guard phase == .preflight, !hasEnded else { return }
        pendingWarnings = report.warnings
        guard let blocking = report.blocking else {
            continueChecks()
            return
        }
        switch blocking {
        case .cameraUndetermined:
            apply(.permissionNeeded)
        case .cameraDenied:
            apply(.permissionDenied)
            present(HouseAlert.from(ScanErrorCopy.alert(for: MapperError.cameraDenied)), followUp: .endFlow)
        case .noLidar, .lowStorage, .storageWarning, .lowBattery, .deviceHot:
            apply(.preflightBlocked)
            let error = HousePresentation.preflightError(blocking) ?? MapperError.unsupportedDevice
            present(HouseAlert.from(ScanErrorCopy.alert(for: error)), followUp: .endFlow)
        }
    }

    /// Shows the next preflight warning (closing it comes back here), then applies the passed
    /// signal of the current phase and shows the tips or starts the capture or relocalization.
    func continueChecks() {
        guard !hasEnded, phase == .preflight || phase == .permission else { return }
        if !pendingWarnings.isEmpty {
            let warning = pendingWarnings.removeFirst()
            present(HouseAlert.from(ScanErrorCopy.preflightAlert(for: warning)), followUp: .continueChecks)
            return
        }
        let showTips = !ScanUISettings.tipsSeen(.house)
        let relocalize = firstCaptureRelocalizes
        if phase == .permission {
            apply(.permissionGranted(showTips: showTips, relocalize: relocalize))
        } else {
            apply(.preflightPassed(showTips: showTips, relocalize: relocalize))
        }
        if showTips {
            showsTips = true
        } else {
            enterCapture()
        }
    }

    /// True when the first capture of this visit relocalizes (Continue Scanning and Rescan
    /// outside Demo Mode).
    var firstCaptureRelocalizes: Bool {
        !isDemo && request.start != .newProject
    }

    /// Continue on the pre-permission screen: asks iOS for the camera
    /// (`AVCaptureDevice.requestAccess(for: .video)`, not in RESEARCH), then continues or shows
    /// the denied alert with Open Settings.
    func permissionContinue() async {
        guard phase == .permission, !isRequestingPermission else { return }
        isRequestingPermission = true
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        isRequestingPermission = false
        guard phase == .permission, !hasEnded else { return }
        if granted {
            log("camera permission granted")
            continueChecks()
        } else {
            log("camera permission denied")
            apply(.permissionDenied)
            present(HouseAlert.from(ScanErrorCopy.alert(for: MapperError.cameraDenied)), followUp: .endFlow)
        }
    }

    /// Start Scan or Skip on the tips page; `dontShowAgain` marks the House tips as seen.
    func tipsFinished(dontShowAgain: Bool) {
        guard phase == .tips, !hasEnded else { return }
        if dontShowAgain { ScanUISettings.markTipsSeen(.house) }
        showsTips = false
        apply(.tipsDone(relocalize: firstCaptureRelocalizes))
        enterCapture()
    }
}
