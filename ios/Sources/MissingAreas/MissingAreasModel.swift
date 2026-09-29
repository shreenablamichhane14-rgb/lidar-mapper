import Foundation
import Combine
import simd
import UIKit

// Show Missing Areas (docs/MODULES.md 3.40, D19, lead decision 4): a patch pass on the finished
// room's still-running session. The model builds a `MeshScanEngine` on the room engine's hub
// (new mesh-pass folder, new recorders, coverage watching every missing area), runs the tour at
// `refreshHz` on main, and after Done records the pass, evaluates the room again off main and
// hands the new evaluation back. It never creates a session, never pauses the room's session
// (only LiveMeshView does, for a system stop) and never writes into the room's sealed folder.
// Pass events and the evaluation are handled in MissingAreasModel+Pass.swift.

/// Everything the tour needs; built by ScanUI from the finished room.
struct MissingAreasTarget {
    /// The project of the room.
    var projectID: UUID
    /// Its package.
    var package: ProjectPackage
    /// The finished room (its sealed folder is read, never written).
    var room: RoomRecord
    /// The room's evaluation at Done; its missing areas are the tour.
    var evaluation: QualityEvaluation
    /// The room's mode and settings (the borrowed hub keeps its profile).
    var mode: ScanMode
    var settings: ScanSettings
    /// `RoomScanEngine.hub` of the finished room, still running.
    var hub: ARSessionHub
}

/// Where the tour is.
enum MissingAreasPhase: Equatable {
    case preparing, touring, allDone, finishing, rechecking, done, cancelled, failed(String)

    /// Preparing, touring or all done: Done, Next Area and Cancel still apply.
    var isActive: Bool {
        switch self {
        case .preparing, .touring, .allDone: return true
        case .finishing, .rechecking, .done, .cancelled, .failed: return false
        }
    }

    /// Done, cancelled or failed: `onFinished` is due (once any alert is dismissed).
    var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .failed: return true
        case .preparing, .touring, .allDone, .finishing, .rechecking: return false
        }
    }
}

/// Main-actor model of the tour (see the file header).
@MainActor final class MissingAreasModel: ObservableObject {
    /// Tour refresh rate, Hz.
    static let refreshHz: Double = 10
    /// Seconds a notice stays on screen.
    static let noticeSeconds: Double = 2
    /// Seconds `start()` waits for a camera pose before ordering the tour from the first viewpoint.
    static let startWaitSeconds: Double = 2
    /// Work-queue seconds the coverage seed may use.
    static let seedDeadlineSeconds: Double = 2
    /// Seconds between two progress log lines (QUAL-03 "Log").
    static let logIntervalSeconds: Double = 10

    /// Where the tour is.
    @Published private(set) var phase: MissingAreasPhase = .preparing
    /// The tour state (stops, current stop, fractions).
    @Published private(set) var tour: MissingAreaTour
    /// Where to point the user, nil without a current stop or a camera pose.
    @Published private(set) var arrow: MissingAreaArrow? = nil
    /// A short line after an event ("That area is filled in"), cleared after 2 s.
    @Published private(set) var notice: String? = nil
    /// The cancel confirmation is shown.
    @Published var showsCancelConfirmation = false
    /// The alert shown over the tour; setting it to nil (the alert's OK) lets a due `onFinished` run.
    @Published var alert: ScanAlert? = nil {
        didSet {
            if alert == nil { scheduleDeliveryCheck() }
        }
    }
    /// True after the cancel was confirmed, until the pass stopped.
    @Published private(set) var isCancelling = false

    /// What the tour runs on.
    let target: MissingAreasTarget
    /// The patch pass.
    let scan: MeshScanModel
    /// For ScanUI's CoverageOverlay: `CoverageOverlayRenderer(source: model.coverage, thermal: target.hub.thermal)`.
    let coverage: CoverageLiveRecorder
    /// Units for the distance line, read once.
    let units: UnitPreferences
    /// The evaluation after the tour (nil until then).
    private(set) var newEvaluation: QualityEvaluation?
    /// True when a system stop ended the pass (the session is paused; ScanUI hides Show Missing Areas).
    /// Also set when the pass ended with a session failure notice.
    private(set) var stoppedBySystem = false
    /// Called once: the new evaluation after Done, or nil after Cancel. After a failure or a
    /// failed re-evaluation, the room's evaluation at Done. Runs after any alert is dismissed.
    var onFinished: ((QualityEvaluation?) -> Void)?

    // MARK: Private state (main)

    /// `start()` ran; `teardown()` ran.
    var started = false, tornDown = false
    /// The sealed pass, after `.roomFinished`.
    var passResult: MeshScanResult?
    /// True once `onFinished` is due; what it receives; true once it ran.
    var deliveryDue = false
    var deliveryValue: QualityEvaluation?
    var delivered = false
    /// The refresh loop.
    private var refreshTask: Task<Void, Never>?
    /// Uptimes: start, previous tick, last progress log line.
    private var startedAt: Double = 0, lastTick: Double?, lastLogTime: Double = 0
    /// Slowest tick since the last progress line, milliseconds.
    private var slowestTickMilliseconds: Double = 0
    /// Increases for every notice, so an older notice's timer does not hide a newer one.
    private var noticeSerial = 0
    /// VoiceOver direction throttle.
    private var announcer = MissingAreasAnnouncer()
    /// Combine subscriptions (the pass's failures).
    var cancellables: Set<AnyCancellable> = []

    /// Main. Builds the pass (no hardware runs until `start()`): its own `MeshStore`, a coverage
    /// recorder reading that store, the standard recorders without photos, and a `MeshScanEngine`
    /// on `target.hub` with the tour's guidance and coverage snapshot hooks.
    init(target: MissingAreasTarget) {
        self.target = target
        let mesh = MeshStore()
        let recorder = CoverageLiveRecorder(meshSource: mesh)
        let recorders = MeshScanRecorderSet(photos: false, mesh: mesh, extra: [recorder]).all
        let passTarget = MeshScanTarget.patchPass(projectID: target.projectID, package: target.package,
                                                  sessionID: target.room.sessionID, roomID: target.room.id,
                                                  mode: target.mode, settings: target.settings)
        let engine = MeshScanEngine(target: passTarget, recorders: recorders, hub: target.hub)
        engine.guidanceAugmenter = MissingAreasModel.tourGuidanceHook(coverage: recorder)
        engine.snapshotAugmenter = recorder.snapshotHook
        coverage = recorder
        scan = MeshScanModel(engine: engine)
        units = UnitPreferences.load(from: .standard)
        let first = target.evaluation.missingAreas.first?.suggestedViewpoint.simd ?? SIMD3<Float>(0, 0, 0)
        tour = MissingAreaTour(records: target.evaluation.missingAreas, start: first)
        connectPass()
        MissingAreasLog.write("tour model for room \(target.room.id): \(target.evaluation.missingAreas.count) missing areas, "
                              + "\(tour.stops.count) to visit, pass \(passTarget.passID)")
    }

    // MARK: - Guidance hooks (nonisolated)

    /// The tour's guidance rule: keep tracking, speed, distance, light and heat inputs; clear
    /// `viewCoverage` and `nearbyMissing` (the arrow is the guide). `overallComplete` is cleared too.
    nonisolated static func tourGuidance(_ input: inout GuidanceInput) {
        input.viewCoverage = nil
        input.nearbyMissing = []
        input.overallComplete = false
    }

    /// The engine's guidance hook: `coverage.guidanceHook` then `tourGuidance`. Nonisolated, so the
    /// closure is formed outside the main actor (it runs on the hub queue).
    nonisolated static func tourGuidanceHook(coverage: CoverageLiveRecorder) -> (inout GuidanceInput) -> Void {
        let augment = coverage.guidanceHook
        return { (input: inout GuidanceInput) -> Void in
            augment(&input)
            MissingAreasModel.tourGuidance(&input)
        }
    }

    /// True when ScanUI may offer Show Missing Areas: the room was not stopped by the system and
    /// the evaluation lists at least one area the tour would visit (not a window or a door).
    nonisolated static func isOffered(evaluation: QualityEvaluation?, stoppedBySystem: Bool) -> Bool {
        guard !stoppedBySystem, let evaluation else { return false }
        return evaluation.missingAreas.contains { record in
            let surface = record.surfaceClass
            return surface != .window && surface != .door
        }
    }

    // MARK: - Actions (main)

    /// Watches every stop's sample points (they read red), starts the pass, seeds coverage off
    /// main (best effort, logged) and starts the refresh loop. The tour is ordered from the first
    /// camera pose (else the first viewpoint) and the phase becomes `.touring`.
    func start() {
        guard !started, !tornDown else {
            MissingAreasLog.write("start ignored: already started or torn down")
            return
        }
        started = true
        var areas: [Int: [SIMD3<Float>]] = [:]
        for stop in tour.stops { areas[stop.id] = stop.samplePoints }
        coverage.setWatchedAreas(areas)
        do {
            try scan.start()
        } catch {
            let mapped = (error as? MapperError) ?? MapperError.ioFailed("mesh pass start")
            fail(mapped, reason: "the pass did not start")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        startedAt = now
        lastLogTime = now
        lastTick = nil
        MissingAreasLog.write("tour started: \(areas.count) watched areas on the room's session, "
                              + "\(areas.values.reduce(0) { $0 + $1.count }) sample points")
        seedCoverage()
        startRefreshLoop()
    }

    /// Next Area: the current area is passed and the nearest pending one is shown.
    func nextArea() {
        guard phase == .touring, !isCancelling else { return }
        var next = tour
        let events = next.next()
        tour = next
        Haptics.selection()
        MissingAreasLog.write("Next Area: \(tour.remainingCount) of \(tour.stops.count) left")
        handle(events)
        announcer.reset()
    }

    /// Done: finish the pass, record it, evaluate again (MissingAreasModel+Pass.swift).
    func finishTour() {
        guard phase.isActive, !isCancelling else { return }
        showsCancelConfirmation = false
        stopRefresh()
        arrow = nil
        phase = .finishing
        MissingAreasLog.write("Done: \(tour.remainingCount) of \(tour.stops.count) missing areas left, "
                              + "\(tour.stops.filter { $0.status == .filled }.count) filled")
        scan.finish()
    }

    /// Cancel: asks first.
    func requestCancel() {
        guard phase.isActive, !isCancelling else { return }
        showsCancelConfirmation = true
    }

    /// Cancel confirmed: the pass is discarded; on idle the tour ends with `onFinished(nil)`.
    func confirmCancel() {
        showsCancelConfirmation = false
        guard phase.isActive, !isCancelling else { return }
        isCancelling = true
        stopRefresh()
        arrow = nil
        MissingAreasLog.write("cancel confirmed: discarding the pass (\(tour.remainingCount) areas left)")
        scan.discard()
    }

    /// Keep Scanning: closes the confirmation.
    func keepScanning() {
        showsCancelConfirmation = false
    }

    /// Idempotent: stops the refresh loop and notices and tears the pass down (a pass still
    /// running gets LiveMeshView's ordered cancel; the borrowed hub gets its closures back and
    /// keeps running). `onFinished` is not called after this.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stopRefresh()
        noticeSerial += 1
        cancellables.removeAll()
        scan.teardown()
        MissingAreasLog.write("tour model torn down in phase \(MissingAreasModel.phaseName(phase))")
    }

    // MARK: - Refresh loop

    /// Runs `tick()` `refreshHz` times a second until it returns false or the loop is stopped.
    private func startRefreshLoop() {
        refreshTask?.cancel()
        let interval = UInt64(1_000_000_000 / MissingAreasModel.refreshHz)
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let model = self else { return }
                if !model.tick() { return }
            }
        }
    }

    /// Cancels the refresh loop.
    func stopRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// One refresh: orders the tour once a camera pose exists, then updates it with the watched
    /// fractions, handles its events, recomputes the arrow, announces a new direction and logs
    /// progress. Returns false once the tour is no longer active.
    private func tick() -> Bool {
        guard !tornDown, phase.isActive, !isCancelling else { return false }
        let began = ProcessInfo.processInfo.systemUptime
        let seconds = lastTick.map { began - $0 } ?? 0
        lastTick = began
        let camera = scan.engine.latestCameraTransform
        if phase == .preparing {
            guard camera != nil || began - startedAt >= MissingAreasModel.startWaitSeconds else { return true }
            beginTour(camera: camera)
        }
        if let camera {
            var next = tour
            let tracking = scan.snapshot.tracking == .normal && scan.state == .scanning
            let events = next.update(fractions: coverage.watchedFractions(), cameraToWorld: camera, seconds: seconds,
                                     trackingNormal: tracking)
            if next != tour { tour = next }
            handle(events)
            let pointer = tour.currentStop.map { MissingAreaTour.arrow(cameraToWorld: camera, record: $0.record) }
            if pointer != arrow { arrow = pointer }
        } else if arrow != nil {
            arrow = nil
        }
        announceDirectionIfDue(now: began)
        logProgressIfDue(now: began)
        let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
        slowestTickMilliseconds = Swift.max(slowestTickMilliseconds, milliseconds)
        return true
    }

    /// Orders the tour from the camera position (else the first viewpoint); `.allDone` when no
    /// area is left to visit.
    private func beginTour(camera: simd_float4x4?) {
        let fromCamera = camera.map { MissingAreaTour.position($0) }
        let first = target.evaluation.missingAreas.first?.suggestedViewpoint.simd ?? SIMD3<Float>(0, 0, 0)
        tour = MissingAreaTour(records: target.evaluation.missingAreas, start: fromCamera ?? first)
        let origin = fromCamera == nil ? "the first viewpoint" : "the camera"
        MissingAreasLog.write("tour ordered from \(origin): \(tour.stops.count) areas, "
                              + "\(target.evaluation.missingAreas.count - tour.stops.count) windows or doors skipped")
        if tour.isFinished {
            phase = .allDone
            show(notice: Copy.Quality.allAreasDone)
        } else {
            phase = .touring
        }
    }

    /// Haptics, notices, phase and log lines for tour events.
    private func handle(_ events: [MissingAreaTourEvent]) {
        for event in events {
            switch event {
            case .filled(let id):
                Haptics.success()
                show(notice: Copy.Quality.missingAreaDone)
                MissingAreasLog.write("area \(id) filled; \(tour.remainingCount) of \(tour.stops.count) left")
            case .unscannable(let id):
                show(notice: Copy.MissingAreas.cantScan)
                MissingAreasLog.write("area \(id) unscannable (faced \(MissingAreaTour.unscannableSeconds) s without "
                                      + "progress); \(tour.remainingCount) of \(tour.stops.count) left")
            case .advanced(let id):
                announcer.reset()
                MissingAreasLog.write("now showing area \(id)")
            case .finished:
                phase = .allDone
                arrow = nil
                show(notice: Copy.Quality.allAreasDone)
                MissingAreasLog.write("tour finished: no pending area left")
            }
        }
    }

    // MARK: - Notices and VoiceOver

    /// Shows `text` for `noticeSeconds` and speaks it with VoiceOver.
    func show(notice text: String) {
        noticeSerial += 1
        let serial = noticeSerial
        notice = text
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            announcer.noteSpoken(now: ProcessInfo.processInfo.systemUptime)
        }
        let delay = UInt64(MissingAreasModel.noticeSeconds * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let model = self, model.noticeSerial == serial else { return }
            model.notice = nil
        }
    }

    /// Speaks the arrow's direction when it changed, at most every 3 s, while VoiceOver runs.
    private func announceDirectionIfDue(now: Double) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let direction = arrow.map { MissingAreaTour.direction($0) }
        guard announcer.shouldAnnounce(direction, now: now), let direction else { return }
        UIAccessibility.post(notification: .announcement, argument: MissingAreasPresentation.spokenText(direction))
    }

    /// One progress line every `logIntervalSeconds`: areas left, the current fraction and the slowest tick.
    private func logProgressIfDue(now: Double) {
        guard now - lastLogTime >= MissingAreasModel.logIntervalSeconds else { return }
        lastLogTime = now
        let current = tour.currentStop
        let fraction = current.map { String(format: "%.2f", Double($0.fraction)) } ?? "-"
        let slowest = String(format: "%.2f", slowestTickMilliseconds)
        MissingAreasLog.write("tour at \(Int(now - startedAt)) s: \(tour.remainingCount) of \(tour.stops.count) missing "
                              + "areas left, current \(current.map { String($0.id) } ?? "none") at \(fraction), "
                              + "tracking \(scan.snapshot.tracking.rawValue), slowest tick \(slowest) ms")
        slowestTickMilliseconds = 0
    }

    /// Short phase name for logs.
    nonisolated static func phaseName(_ phase: MissingAreasPhase) -> String {
        switch phase {
        case .preparing: return "preparing"
        case .touring: return "touring"
        case .allDone: return "allDone"
        case .finishing: return "finishing"
        case .rechecking: return "rechecking"
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}
