import Foundation
import Combine
import ARKit
import RealityKit
import UIKit
import simd

// Quick Measure's model (MODULES 3.36, ARCHITECTURE 4.6): owns its own `ARSessionHub` (plane
// detection on, the only mode where it is, D14), the probe recorder, the 15 Hz reticle loop
// on main (raycasts and projections run on main only), the points and segments, guidance and
// the idle timer token. Saving lives in LiveMeasureModel+Save.swift; the value, accuracy and
// VoiceOver texts (through MeasureDisplay) are in LiveMeasureScreenParts.swift.
//
// Members beyond MODULES 3.36 (additive): `pendingScreen`, `hasFoundSurfaces`, `alertMessage`,
// `isAlertShown` (alert binding), `viewDismantled(_:)`, `removeSegments(at:)`, `dismissAlert()`,
// `accessibilityText(label:value:)`, `isLowConfidence(_:)`, `performSave()` (+Save) and the
// probe's `onSessionFailed`.

/// The Quick Measure model. Main actor.
@MainActor final class LiveMeasureModel: ObservableObject {
    /// Reticle refresh rate, Hz.
    static let reticleHz: Double = 15
    /// Corner candidates are recomputed every this many ticks.
    static let cornerRefreshTicks = 5
    /// Shortest distance kept, meters (a second tap on the same spot does nothing).
    static let minimumSegmentLength: Float = 0.005
    /// A snapped point that moved farther than this counts as a new snap (haptic), meters.
    static let snapChangeDistance: Float = 0.01

    /// Screen state.
    @Published private(set) var phase: LiveMeasurePhase = .starting
    /// Closed distances, oldest first.
    @Published private(set) var segments: [LiveMeasureSegment] = []
    /// The start of the distance being measured.
    @Published private(set) var pending: LiveMeasurePoint?
    /// Where Add Point would place a point now (nil without a surface under the reticle).
    @Published private(set) var reticle: LiveMeasureResolution?
    /// Pending point to reticle, while a point is pending.
    @Published private(set) var liveValue: MeasuredValue?
    /// Screen points of segment midpoints and endpoints for labels and lines (refreshed with the reticle).
    @Published private(set) var screenPoints: [UUID: (start: CGPoint?, end: CGPoint?, middle: CGPoint?)] = [:]
    /// Screen point of the pending point (refreshed with the reticle).
    @Published private(set) var pendingScreen: CGPoint?
    /// True once a plane or a surface under the reticle was found (hint wording).
    @Published private(set) var hasFoundSurfaces = false
    /// Tier 1 guidance message on screen, nil when all is well.
    @Published private(set) var guidance: GuidanceKind?
    /// "Snap to corners and edges": off leaves only the two raycast hits.
    @Published var snappingEnabled = true
    /// The discard confirmation is showing.
    @Published var showsDiscardConfirmation = false
    /// Alert title; setting it shows the alert, nil hides it.
    @Published var alert: String? {
        didSet {
            let shown = alert != nil
            if isAlertShown != shown { isAlertShown = shown }
        }
    }
    /// Alert body (nil for a title-only alert).
    @Published private(set) var alertMessage: String?
    /// Binding for the alert; false clears `alert` and `alertMessage`.
    @Published var isAlertShown = false {
        didSet {
            guard !isAlertShown else { return }
            if alert != nil { alert = nil }
            if alertMessage != nil { alertMessage = nil }
        }
    }

    /// The model's own session hub (the model is its only owner).
    let hub: ARSessionHub
    /// Unit preferences read at init.
    let prefs: UnitPreferences
    /// Called with the new project id after Save.
    var onComplete: ((UUID) -> Void)?
    /// Called when the screen closes without saving.
    var onDismiss: (() -> Void)?

    /// The live view, kept weakly (the container owns it).
    weak var arView: ARView?
    /// Hub recorder: planes and center samples.
    private let probe = LiveMeasureProbe()
    /// VoiceOver announcements and warning haptics of guidance.
    private let announcer: GuidanceAnnouncer
    /// The reticle loop.
    private var loopTask: Task<Void, Never>?
    /// Ticks run, and the tick of the last corner refresh.
    private var tickCount = 0
    private var cornerTick: Int?
    /// Corner candidates of the last refresh.
    private var cachedCorners: [SIMD3<Float>] = []
    /// IdleTimerGuard token while measuring.
    private var idleToken: UUID?
    /// Lifecycle flags.
    private var started = false
    private var tornDown = false

    /// Main. Creates the hub with the Quick Measure profile (plane detection on) and reads the units.
    init() {
        let profile = ScanProfile(mode: .quickMeasure, settings: ScanSettings.defaults(for: .quickMeasure))
        hub = ARSessionHub(profile: profile)
        prefs = UnitPreferences.load()
        announcer = GuidanceAnnouncer()
        LiveMeasureLog.write("model init, plane detection \(profile.wantsPlaneDetection)")
    }

    // MARK: - Lifecycle

    /// Main. The container's view (kept weakly); starts the reticle loop.
    func attach(_ arView: ARView) {
        self.arView = arView
        LiveMeasureLog.write("view attached, delegate === hub \(hub.session.delegate === hub)")
        startLoop()
    }

    /// Main. `hub.install()`, `hub.attach(probe)`, `probe.install(on: hub)`, `hub.run()`, an IdleTimerGuard token.
    func start() {
        guard !started, !tornDown else { return }
        started = true
        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .failed(Copy.Errors.noLidar.body)
            LiveMeasureLog.write("start refused: world tracking is not supported")
            return
        }
        probe.onGuidance = { [weak self] kind in self?.receiveGuidance(kind) }
        probe.onRelocalization = { [weak self] in self?.receiveRelocalization() }
        probe.onSessionFailed = { [weak self] in self?.receiveSessionFailure() }
        hub.install()
        hub.attach(probe)
        probe.install(on: hub)
        hub.run()
        idleToken = IdleTimerGuard.acquire("quick measure")
        announcer.reset()
        phase = .measuring
        LiveMeasureLog.write("started")
        startLoop()
    }

    /// Main, idempotent: loop stopped, `hub.pause()`, probe detached, hub closures nil, token released.
    func teardown() {
        loopTask?.cancel()
        loopTask = nil
        guard !tornDown else { return }
        tornDown = true
        hub.pause()
        hub.detach(probe)
        probe.uninstall(from: hub)
        probe.onGuidance = nil
        probe.onRelocalization = nil
        probe.onSessionFailed = nil
        if let token = idleToken {
            IdleTimerGuard.release(token)
            idleToken = nil
        }
        announcer.reset()
        if guidance != nil { guidance = nil }
        LiveMeasureLog.write("teardown: hub running \(hub.isRunning), segments \(segments.count)")
    }

    /// Main. The container was dismantled: forget the view and tear down (the hub is paused on every exit).
    func viewDismantled(_ view: ARView) {
        if arView === view { arView = nil }
        teardown()
    }

    // MARK: - Actions

    /// Commits the reticle (nothing without one): the first point starts a distance, the second
    /// closes it (non-chained: the next point starts a new distance; snapping to an existing
    /// point chains them by hand).
    func addPoint() {
        guard phase == .measuring else { return }
        guard let target = reticle else {
            LiveMeasureLog.write("add point ignored: no surface under the reticle")
            return
        }
        let point = makePoint(from: target)
        if let start = pending {
            let length = simd_distance(start.position, point.position)
            guard length.isFinite, length >= LiveMeasureModel.minimumSegmentLength else {
                LiveMeasureLog.write("add point ignored: end is on the start point")
                return
            }
            Haptics.tap()
            let segment = LiveMeasureSegment.make(start: start, end: point, id: UUID(), createdAt: Date())
            segments.append(segment)
            pending = nil
            liveValue = nil
            LiveMeasureLog.write("distance \(segments.count) closed: " + LiveMeasureLog.describe(segment.record()))
        } else {
            Haptics.tap()
            pending = point
        }
        if let view = arView { updateScreenPoints(in: view) }
    }

    /// Removes the pending point, else reopens the last segment's end.
    func undo() {
        guard phase == .measuring else { return }
        if pending != nil {
            pending = nil
            liveValue = nil
        } else if let last = segments.popLast() {
            screenPoints[last.id] = nil
            pending = last.start
        }
        if let view = arView { updateScreenPoints(in: view) }
    }

    /// Removes every distance and the pending point.
    func clearAll() {
        guard phase == .measuring else { return }
        segments = []
        pending = nil
        liveValue = nil
        screenPoints = [:]
        pendingScreen = nil
    }

    /// Removes the segments at `offsets` of `segments` (the measurement list's swipe to delete).
    func removeSegments(at offsets: IndexSet) {
        guard phase == .measuring else { return }
        for index in offsets.sorted(by: >) where index < segments.count {
            let removed = segments.remove(at: index)
            screenPoints[removed.id] = nil
        }
    }

    /// Creates the project and files (LiveMeasureModel+Save.swift); phase `.saved(id)` then `onComplete`.
    func save() {
        guard phase == .measuring, !segments.isEmpty else { return }
        phase = .saving
        LiveMeasureLog.write("save: \(segments.count) measurements")
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performSave()
            self.finishSave(outcome)
        }
    }

    /// Asks to discard unsaved segments, else closes.
    func close() {
        if phase == .saving { return }
        if !segments.isEmpty && phase == .measuring {
            showsDiscardConfirmation = true
            return
        }
        teardown()
        onDismiss?()
    }

    /// Discards the unsaved distances and closes.
    func confirmDiscard() {
        showsDiscardConfirmation = false
        LiveMeasureLog.write("discarded \(segments.count) unsaved measurements")
        teardown()
        onDismiss?()
    }

    /// Hides the alert.
    func dismissAlert() {
        isAlertShown = false
    }

    // MARK: - Save outcome

    /// Applies the result of `performSave()`: saved -> teardown, `.saved(id)`, `onComplete`;
    /// failed -> back to measuring with `Copy.Errors.saveFailed`, the segments kept on screen.
    private func finishSave(_ outcome: LiveMeasureSaveOutcome) {
        switch outcome {
        case .saved(let id):
            teardown()
            phase = .saved(id)
            onComplete?(id)
        case .failed:
            phase = tornDown ? .failed(Copy.Errors.saveFailed.body) : .measuring
            alertMessage = Copy.Errors.saveFailed.body
            alert = Copy.Errors.saveFailed.title
        }
    }

    // MARK: - Hub callbacks (main)

    /// A new guidance message (tier 1 only) from the probe.
    private func receiveGuidance(_ kind: GuidanceKind?) {
        guard !tornDown else { return }
        if guidance != kind { guidance = kind }
        announcer.present(kind, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Tracking relocalized: points placed before may have moved.
    private func receiveRelocalization() {
        guard !tornDown, phase == .measuring else { return }
        guard !segments.isEmpty || pending != nil else { return }
        alertMessage = nil
        alert = Copy.LiveMeasure.relocalized
    }

    /// The session failed: with measurements on screen they stay savable, else the screen fails.
    private func receiveSessionFailure() {
        guard !tornDown, phase == .measuring else { return }
        if segments.isEmpty {
            phase = .failed(Copy.Errors.generic.body)
        } else {
            alertMessage = Copy.Errors.generic.body
            alert = Copy.Errors.generic.title
        }
    }

    // MARK: - Reticle loop (main)

    /// Starts the loop once (it idles until a view is attached and the phase is `.measuring`).
    private func startLoop() {
        guard loopTask == nil, !tornDown else { return }
        let interval = UInt64(1_000_000_000.0 / LiveMeasureModel.reticleHz)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                guard let model = self else { return }
                model.tick()
            }
        }
    }

    /// One reticle tick: raycasts from the view center, snap candidates, resolution, haptic on
    /// a new snap, live value and screen points.
    private func tick() {
        guard phase == .measuring, let view = arView else { return }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        tickCount &+= 1
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let camera = LiveMeasureMatrix.translation(view.cameraTransform.matrix)
        let planes = probe.planes()
        let rawHit = planeHit(in: view, at: center, planes: planes)
        let fallback = estimatedHit(in: view, at: center)
        let hit = LiveMeasureSnapping.unoccludedHit(rawHit, fallback: fallback, camera: camera)
        if !hasFoundSurfaces && (!planes.isEmpty || fallback != nil) { hasFoundSurfaces = true }
        var candidates: [LiveMeasureCandidate] = []
        if snappingEnabled {
            candidates = snapCandidates(in: view, planes: planes, camera: camera)
        }
        let resolution = LiveMeasureSnapping.resolve(hit: hit, fallback: fallback, candidates: candidates, reticle: center)
        updateReticle(resolution)
        updateLiveValue()
        updateScreenPoints(in: view)
    }

    /// The `.existingPlaneGeometry` hit at `center`, tagged by the plane it hit.
    private func planeHit(in view: ARView, at center: CGPoint, planes: [LiveMeasurePlane]) -> LiveMeasureCandidate? {
        guard let result = view.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any).first else {
            return nil
        }
        let point = LiveMeasureMatrix.translation(result.worldTransform)
        guard LiveMeasureSnapping.isFinite(point) else { return nil }
        var tag: LiveMeasureSnapTag?
        if let identifier = result.anchor?.identifier, let plane = planes.first(where: { $0.id == identifier }) {
            tag = LiveMeasureSnapping.tag(for: plane.kind)
        }
        return LiveMeasureCandidate(point: point, screen: view.project(point), source: .planeGeometry, snap: .plane, tag: tag)
    }

    /// The `.estimatedPlane` hit at `center`.
    private func estimatedHit(in view: ARView, at center: CGPoint) -> LiveMeasureCandidate? {
        guard let result = view.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first else {
            return nil
        }
        let point = LiveMeasureMatrix.translation(result.worldTransform)
        guard LiveMeasureSnapping.isFinite(point) else { return nil }
        return LiveMeasureCandidate(point: point, screen: view.project(point), source: .estimatedPlane,
                                    snap: SnapKind.none, tag: nil)
    }

    /// Committed points (the pending start is left out: a distance never ends on its own start)
    /// and plane corners, refreshed every `cornerRefreshTicks` ticks, each projected on screen.
    private func snapCandidates(in view: ARView, planes: [LiveMeasurePlane], camera: SIMD3<Float>) -> [LiveMeasureCandidate] {
        var list: [LiveMeasureCandidate] = []
        for segment in segments {
            for point in [segment.start, segment.end] {
                list.append(LiveMeasureCandidate(point: point.position, screen: view.project(point.position),
                                                 source: .existingPoint, snap: point.snap, tag: point.tag))
            }
        }
        let due = cornerTick.map { tickCount - $0 >= LiveMeasureModel.cornerRefreshTicks } ?? true
        if due {
            cachedCorners = LiveMeasureSnapping.cornerPoints(planes, camera: camera)
            cornerTick = tickCount
        }
        for corner in cachedCorners {
            list.append(LiveMeasureCandidate(point: corner, screen: view.project(corner), source: .planeCorner,
                                             snap: .corner, tag: .corner))
        }
        return list
    }

    /// Publishes the resolution; a newly snapped candidate fires `Haptics.selection()`.
    private func updateReticle(_ resolution: LiveMeasureResolution?) {
        if let resolution, resolution.isSnapped {
            var isNew = true
            if let previous = reticle, previous.isSnapped {
                isNew = simd_distance(previous.point, resolution.point) > LiveMeasureModel.snapChangeDistance
            }
            if isNew { Haptics.selection() }
        }
        if reticle != resolution { reticle = resolution }
    }

    /// The pending point to the reticle, with the reticle's evidence.
    private func updateLiveValue() {
        guard let start = pending, let target = reticle else {
            if liveValue != nil { liveValue = nil }
            return
        }
        liveValue = LiveMeasureSegment.value(from: start, to: makePoint(from: target))
    }

    /// Projects every segment's ends and midpoint and the pending point.
    private func updateScreenPoints(in view: ARView) {
        var map: [UUID: (start: CGPoint?, end: CGPoint?, middle: CGPoint?)] = [:]
        for segment in segments {
            let middle = (segment.start.position + segment.end.position) * 0.5
            map[segment.id] = (start: view.project(segment.start.position), end: view.project(segment.end.position),
                               middle: view.project(middle))
        }
        screenPoints = map
        let projected = pending.flatMap { view.project($0.position) }
        if pendingScreen != projected { pendingScreen = projected }
    }

    /// A point at the resolution with evidence from the probe's recent samples.
    private func makePoint(from resolution: LiveMeasureResolution) -> LiveMeasurePoint {
        let samples = probe.recentSamples()
        let now = samples.map { $0.timestamp }.max() ?? 0
        let evidence = LiveMeasureSnapping.evidence(point: resolution.point, samples: samples,
                                                    snap: resolution.measurementSnap, now: now)
        return LiveMeasurePoint(position: resolution.point, snap: resolution.snap, evidence: evidence, tag: resolution.tag)
    }
}
