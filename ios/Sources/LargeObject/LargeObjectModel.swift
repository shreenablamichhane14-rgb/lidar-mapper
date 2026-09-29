import ARKit
import Combine
import Foundation
import RealityKit
import UIKit
import simd

// The large-object flow on the main actor (docs/MODULES.md 3.39, D4, ARCHITECTURE 4.5): a
// mesh-only pass (LiveMeshView's MeshScanEngine with an owned hub, mode .object, no planes)
// with live coverage and the LargeObjectTracker as extra recorders; the tap that picks the
// object (ray pick off main, `.estimatedPlane` fallback on main); the 2 Hz copy of the tracker's
// box and sides into published values; Done, cancel and alerts. The save after the seal (crop
// edit, ObjectRecord, thumbnail) is in LargeObjectModel+Finish.swift.
//
// Queue rules: nothing heavy runs here. The ray pick, growth and sector pass run in detached
// tasks or on the tracker's queue; hub-queue closures are formed by the tracker and CoverageLive,
// never in this class.

/// What to do once the alert on screen is dismissed.
enum LargeObjectAfterAlert: Equatable {
    /// The capture was saved: call `onComplete` with the project id.
    case complete(UUID)
    /// Leave the flow: tear down, delete the project when `deleteIfEmpty` and it holds nothing, `onDismiss`.
    case dismiss(deleteIfEmpty: Bool)
}

/// The `@MainActor` flow of a large-object capture.
@MainActor final class LargeObjectModel: ObservableObject {
    /// Where the flow is.
    @Published private(set) var phase: LargeObjectPhase = .starting
    /// The chosen object's box (nil before the tap).
    @Published private(set) var box: OrientedBox?
    /// Regions covered and required (0 of 0 until the first pass).
    @Published private(set) var sidesCovered: Int = 0
    @Published private(set) var sidesRequired: Int = 0
    /// Seed hints (Copy.LargeObject), nil while capturing.
    @Published private(set) var hint: String?
    /// "About w by d by h" of the box through Units (an addition to the 3.39 API; nil without a box).
    @Published private(set) var boxSizeText: String?
    /// The Cancel confirmation is shown.
    @Published var showsCancelConfirmation = false
    /// The alert on screen (start failures, a failed save, a notice after the save).
    @Published var alert: ScanAlert?
    /// True while `alert` is presented (the screen's alert binding; an addition to the 3.39 API).
    @Published var isAlertPresented = false

    /// The object being captured.
    let target: LargeObjectTarget
    /// The mesh-only pass.
    let scan: MeshScanModel
    /// For AppShell's CoverageOverlay: `CoverageOverlayRenderer(source: model.coverage, thermal: model.scan.engine.hub.thermal)`.
    let coverage: CoverageLiveRecorder
    /// Box, sectors and the object message.
    let tracker: LargeObjectTracker
    /// Project id after the seal, the ObjectRecord and the crop edit.
    var onComplete: ((UUID) -> Void)?
    /// After a confirmed cancel (the project is deleted when it holds nothing).
    var onDismiss: (() -> Void)?

    // MARK: Main-actor state (internal for LargeObjectModel+Finish.swift)

    /// The live view (weak: SwiftUI owns it).
    weak var arView: ARView?
    /// The wireframe outline on `arView`.
    let boxEntity: LargeObjectBoxEntity
    /// Unit preferences for the size line.
    let unitPreferences: UnitPreferences
    /// The 2 Hz refresh loop.
    var refreshTask: Task<Void, Never>?
    /// Increases with every tap, so an older tap's result is dropped.
    var tapSerial = 0
    /// Done was tapped (a pass that finishes without it was stopped by the engine).
    var userFinished = false
    /// The box captured at Done (the crop edit).
    var boxAtDone: OrientedBox?
    /// The save after the seal started (runs once).
    var completionStarted = false
    /// The user confirmed Cancel; `dismissed` once `onDismiss` fired.
    var cancelConfirmed = false
    var dismissed = false
    /// `teardown()` ran.
    var tornDown = false
    /// What the dismissal of the current alert leads to.
    var afterAlert: LargeObjectAfterAlert?

    /// Seconds between two refreshes of the published values (2 Hz).
    static let refreshSeconds: Double = 0.5
    /// Seconds a confirmed cancel waits for the engine's idle event before leaving anyway.
    static let cancelFallbackSeconds: Double = 10

    /// Builds the pass: `MeshStore`, `CoverageLiveRecorder(meshSource:)`, the tracker, the recorder set
    /// without photos, `MeshScanEngine(target: .largeObject(...), recorders:)` (owned hub, mode `.object`,
    /// no planes, D14), the guidance and snapshot hooks, then the `MeshScanModel` facade. Nothing runs
    /// until `start()`.
    init(target: LargeObjectTarget) {
        self.target = target
        let mesh = MeshStore()
        let liveCoverage = CoverageLiveRecorder(meshSource: mesh)
        let objectTracker = LargeObjectTracker(coverage: liveCoverage)
        let recorders = MeshScanRecorderSet(photos: false, mesh: mesh, extra: [liveCoverage, objectTracker]).all
        let engine = MeshScanEngine(target: target.meshTarget, recorders: recorders)
        engine.guidanceAugmenter = objectTracker.guidanceHook(after: liveCoverage)
        engine.snapshotAugmenter = liveCoverage.snapshotHook
        coverage = liveCoverage
        tracker = objectTracker
        scan = MeshScanModel(engine: engine)
        boxEntity = LargeObjectBoxEntity()
        unitPreferences = UnitPreferences.load(from: UserDefaults.standard)
        scan.onFinished = { [weak self] result in
            self?.passFinished(result)
        }
        scan.onIdle = { [weak self] in
            self?.passIdle()
        }
        LargeObjectLog.write("large object model for object \(target.objectID), project \(target.projectID)")
    }

    // MARK: - Start and view

    /// `scan.start()`; phase `.aiming`, hint `Copy.LargeObject.tapToSelect`, the refresh loop. A start
    /// failure shows `ScanErrorCopy.alert(for:)` and leaves the flow after the alert (the new project is
    /// deleted when it holds nothing).
    func start() {
        guard phase == .starting, !tornDown else {
            LargeObjectLog.write("start ignored in phase \(phase)")
            return
        }
        do {
            try scan.start()
        } catch {
            let mapped = (error as? MapperError) ?? MapperError.ioFailed(String(describing: error))
            LargeObjectLog.write("start failed: \(mapped.copyKey)")
            phase = .failed(mapped.copyKey)
            showAlert(ScanErrorCopy.alert(for: mapped), then: .dismiss(deleteIfEmpty: true))
            return
        }
        phase = .aiming
        hint = Copy.LargeObject.tapToSelect
        startRefreshLoop()
    }

    /// From LiveMeshScreen's onViewReady: keeps the view weakly and attaches the box entity.
    func attach(_ arView: ARView) {
        self.arView = arView
        boxEntity.attach(to: arView)
        boxEntity.update(box)
    }

    // MARK: - Choosing the object

    /// Seed from a tap: `arView.ray(through:)`; phase `.locating`; off main the ray pick against the live
    /// faces within 6 m; when nothing is hit, `arView.raycast(from:allowing: .estimatedPlane, alignment: .any)`
    /// on main; then off main the floor, growth and box. A box starts capturing; none gives a hint.
    func handleTap(_ point: CGPoint, in arView: ARView) {
        guard phase == .aiming, !tornDown else { return }
        self.arView = arView
        guard let cast = arView.ray(through: point) else {
            LargeObjectLog.write("tap: no ray through the point")
            hint = Copy.LargeObject.noObjectFound
            return
        }
        let ray = Ray(origin: cast.origin, direction: cast.direction)
        let camera = scan.engine.latestCameraTransform.map { LargeObjectModel.translation($0) } ?? cast.origin
        tapSerial += 1
        let serial = tapSerial
        phase = .locating
        hint = Copy.LargeObject.locating
        let source = coverage
        Task { [weak self] in
            let hit = await Task.detached(priority: .userInitiated) { () -> SIMD3<Float>? in
                LargeObjectLocator.pick(ray, anchors: source.anchorFaces(changedSince: 0).anchors)
            }.value
            await self?.continueLocating(hit: hit, point: point, serial: serial, camera: camera)
        }
    }

    /// Second half of a tap: the plane fallback on main, then the first box off main.
    private func continueLocating(hit: SIMD3<Float>?, point: CGPoint, serial: Int, camera: SIMD3<Float>) async {
        guard serial == tapSerial, phase == .locating else { return }
        var seed = hit
        var source = "live faces"
        if seed == nil, let view = arView,
           let result = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            seed = LargeObjectModel.translation(result.worldTransform)
            source = "estimated plane"
        }
        guard let seedPoint = seed, LargeObjectSeed.isFinite(seedPoint) else {
            LargeObjectLog.write("tap: nothing hit")
            backToAiming(Copy.LargeObject.noObjectFound)
            return
        }
        let faces = coverage
        let location = await Task.detached(priority: .userInitiated) { () -> LargeObjectLocation in
            LargeObjectLocator.locate(seed: seedPoint, anchors: faces.anchorFaces(changedSince: 0).anchors)
        }.value
        guard serial == tapSerial, phase == .locating else { return }
        let seedText = LargeObjectTracker.text(seedPoint)
        guard let found = location.box else {
            LargeObjectLog.write("tap at \(seedText) (\(source)): no box, \(location.sampleCount) samples, "
                                 + "\(location.grownPoints) grown, wall \(location.seedInWallColumn)")
            backToAiming(location.seedInWallColumn ? Copy.LargeObject.tappedWall : Copy.LargeObject.noObjectFound)
            return
        }
        tracker.setSeed(seedPoint, floorY: location.floorY, front: camera)
        LargeObjectLog.write("seed at \(seedText) (\(source)), box \(LargeObjectTracker.sizeText(found)), "
                             + "\(location.grownPoints) points, floor \(LargeObjectTracker.floorText(location.floorY))")
        setBox(found)
        sidesCovered = 0
        sidesRequired = 0
        hint = nil
        phase = .capturing
        Haptics.selection()
    }

    /// Drops the chosen object and asks for a new tap.
    func chooseAgain() {
        switch phase {
        case .capturing, .locating, .aiming:
            break
        case .starting, .finishing, .done, .cancelled, .failed:
            return
        }
        tapSerial += 1
        tracker.setSeed(nil, floorY: nil, front: nil)
        setBox(nil)
        sidesCovered = 0
        sidesRequired = 0
        phase = .aiming
        hint = Copy.LargeObject.tapToSelect
        LargeObjectLog.write("choose again")
    }

    /// Phase `.aiming` with a hint.
    private func backToAiming(_ text: String) {
        setPhase(.aiming, hint: text)
    }

    /// Sets the phase and the hint together (how LargeObjectModel+Finish.swift changes them).
    func setPhase(_ newPhase: LargeObjectPhase, hint newHint: String? = nil) {
        phase = newPhase
        hint = newHint
    }

    // MARK: - Done

    /// Done is possible: capturing with a box while the pass runs or is paused.
    var canFinish: Bool {
        guard phase == .capturing, box != nil else { return false }
        let state = scan.state
        return state == .scanning || state == .paused
    }

    /// Done (enabled once a box exists): the tracker's log as the `largeobject.json` attachment, the
    /// box kept for the crop edit, `scan.finish(attachments:)`.
    func finish() {
        guard canFinish, !completionStarted else { return }
        let current = tracker.current().box ?? box
        boxAtDone = current
        userFinished = true
        var attachments: [String: Data] = [:]
        if let data = tracker.log().encoded() { attachments[LargeObjectLog.fileName] = data }
        phase = .finishing
        hint = nil
        LargeObjectLog.write("Done: box \(current.map(LargeObjectTracker.sizeText) ?? "none"), "
                             + "\(sidesCovered) of \(sidesRequired) covered, \(attachments.count) attachments")
        scan.finish(attachments: attachments)
    }

    // MARK: - Refresh (2 Hz)

    /// Starts the loop that copies the tracker's values into the published ones.
    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LargeObjectModel.refreshSeconds * 1_000_000_000))
                guard let self else { return }
                self.refresh()
            }
        }
    }

    /// One refresh: engine failures, then (while capturing) the box, the outline and the sides.
    func refresh() {
        checkEngineFailure()
        guard phase == .capturing else { return }
        let state = tracker.current()
        if let latest = state.box, latest != box { setBox(latest) }
        if sidesCovered != state.covered { sidesCovered = state.covered }
        if sidesRequired != state.required { sidesRequired = state.required }
    }

    /// Publishes the box, updates the outline (at most twice a second) and the size line.
    func setBox(_ newBox: OrientedBox?) {
        box = newBox
        boxEntity.update(newBox)
        boxSizeText = newBox.map { LargeObjectModel.sizeText($0, prefs: unitPreferences) }
    }

    /// A pass that failed without being sealed (seal or folder failure): the alert, then the flow
    /// ends; the raw stays in InProgress for recovery, so the project is kept.
    private func checkEngineFailure() {
        guard scan.state == .failed, !completionStarted, !cancelConfirmed else { return }
        switch phase {
        case .aiming, .locating, .capturing, .finishing:
            break
        case .starting, .done, .cancelled, .failed:
            return
        }
        let error = scan.failure ?? MapperError.ioFailed("mesh pass failed")
        LargeObjectLog.write("pass failed without a seal: \(error.copyKey)")
        phase = .failed(error.copyKey)
        hint = nil
        showAlert(ScanErrorCopy.alert(for: error), then: .dismiss(deleteIfEmpty: false))
    }

    // MARK: - Alerts

    /// Shows `alert`; `next` runs once it is dismissed.
    func showAlert(_ newAlert: ScanAlert, then next: LargeObjectAfterAlert?) {
        afterAlert = next
        alert = newAlert
        isAlertPresented = true
    }

    /// A button of the alert: resume, finish, Settings or OK, then what the alert was waiting for.
    func alertAction(_ action: ScanAlertAction) {
        alert = nil
        isAlertPresented = false
        switch action {
        case .ok:
            break
        case .resume:
            scan.resume()
        case .finishNow:
            finish()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        runAfterAlert()
    }

    /// The alert went away without a button: same as OK (nothing when a button already handled it).
    func alertDismissed() {
        guard alert != nil else { return }
        alertAction(.ok)
    }

    /// Runs what the dismissed alert was waiting for, once.
    private func runAfterAlert() {
        guard alert == nil, let next = afterAlert else { return }
        afterAlert = nil
        switch next {
        case .complete(let projectID):
            fireComplete(projectID)
        case .dismiss(let deleteIfEmpty):
            teardown()
            if deleteIfEmpty { deleteProjectIfEmpty() }
            fireDismiss()
        }
    }

    // MARK: - Helpers

    /// The translation column of a transform.
    nonisolated static func translation(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// `Copy.LargeObject.boxSize` of a box: the longer horizontal side as the width, the shorter as the
    /// depth, the vertical side as the height, each through `LengthFormat.display`.
    nonisolated static func sizeText(_ box: OrientedBox, prefs: UnitPreferences) -> String {
        let size = box.halfExtents * 2
        let width = Double(max(size.x, size.z))
        let depth = Double(min(size.x, size.z))
        let height = Double(size.y)
        return Copy.LargeObject.boxSize(width: LengthFormat.display(width, prefs: prefs),
                                        depth: LengthFormat.display(depth, prefs: prefs),
                                        height: LengthFormat.display(height, prefs: prefs))
    }
}
