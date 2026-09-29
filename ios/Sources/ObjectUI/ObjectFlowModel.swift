import Foundation
import Combine
import UIKit
import AVFoundation

/// The Object flow (docs/MODULES.md 3.42, D4): the size chooser, preflight (ScanUI's camera,
/// LiDAR, storage, battery and heat checks, then ObjectCapture's support and 3 GB gate), the
/// pre-permission screen, the tips, project creation, the capture (ObjectCapture's
/// `ObjectScanModel`, started and torn down here), the manifest update when the photos are
/// sealed, and Demo Mode.
///
/// Rules: Large ends the flow with `onLargeObject` and makes no project. No project exists
/// before both preflights passed. The flow never enqueues processing (AppShell does in
/// `onComplete`) and never writes `isIdleTimerDisabled` (ObjectFlowScreen holds an
/// `IdleTimerGuard` token). Every phase change goes through the pure `nextPhase(_:on:)`.
@MainActor final class ObjectFlowModel: ObservableObject {
    /// Where the flow is (only `apply(_:)` changes it).
    @Published private(set) var phase: ObjectFlowPhase = .chooser
    /// The alert to show; its buttons call `respond(to:)`.
    @Published var alert: ObjectAlert?
    /// True while the iOS camera prompt is up (Continue disabled).
    @Published private(set) var isRequestingPermission = false

    /// Demo Mode: no camera, a synthetic object.
    let isDemo: Bool
    /// The project made for this object, once created.
    private(set) var projectID: UUID?
    /// The capture model while capturing (ObjectFlowScreen shows its ObjectScanScreen).
    private(set) var scanModel: ObjectScanModel?
    /// Main. Called once after the photos were sealed and the manifest updated (AppShell
    /// enqueues the object plan and opens the object result).
    var onComplete: ((UUID) -> Void)?
    /// Main. The user chose Large (AppShell presents LargeObject's flow).
    var onLargeObject: (() -> Void)?
    /// Main. The flow ended without an object (any project made for it was deleted).
    var onDismiss: (() -> Void)?

    /// Seconds a closed alert needs to animate out before the next step (alert, capture or
    /// the cover's dismissal).
    nonisolated static let presentationGapSeconds: Double = 0.35

    /// What closing the current alert does next.
    private enum FollowUp: Sendable {
        /// Nothing (the flow continues by itself).
        case stay
        /// End the flow with `onDismiss`.
        case endFlow
        /// Show the next warning or apply the signal.
        case advance(ObjectFlowSignal)
    }

    /// `begin()` ran; the flow ended (a callback fired).
    private var hasBegun = false, hasEnded = false
    /// Preflight warnings still to show before the tips or the capture.
    private var pendingWarnings: [ObjectAlert] = []
    /// What closing the current alert does.
    private var followUp: FollowUp = .stay
    /// True once the ObjectRecord is in the manifest (the project is then never deleted here).
    private var recordSaved = false

    /// A flow; nothing runs until `begin()` and a choice.
    init(isDemo: Bool) {
        self.isDemo = isDemo
    }

    // MARK: - User actions

    /// Shows the chooser (the initial phase). Idempotent; ObjectFlowScreen calls it on appear.
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        log("object flow begin, demo \(isDemo)")
    }

    /// Small or medium: the checks, then permission, tips and the capture. Large: `onLargeObject`
    /// (no project, no Object Capture).
    func choose(_ size: ObjectSize) {
        guard phase == .chooser, !hasEnded else { return }
        switch size {
        case .large:
            apply(.choseLarge)
            hasEnded = true
            log("large object chosen")
            let callback = onLargeObject
            onLargeObject = nil
            callback?()
        case .smallMedium:
            apply(.choseSmallMedium)
            Task { [weak self] in
                await self?.runPreflight()
            }
        }
    }

    /// Continue on the pre-permission screen: asks iOS for the camera
    /// (`AVCaptureDevice.requestAccess(for: .video)`, not in RESEARCH, iOS 7), then continues or
    /// shows the denied alert with Open Settings and ends.
    func permissionContinue() async {
        guard phase == .permission, !isRequestingPermission, !hasEnded else { return }
        isRequestingPermission = true
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        isRequestingPermission = false
        guard phase == .permission, !hasEnded else { return }
        if granted {
            log("camera permission granted")
            advance(.permissionGranted(showTips: !ScanUISettings.tipsSeen(.object)))
        } else {
            log("camera permission denied")
            apply(.permissionDenied)
            let denied = ObjectAlert.from(ScanErrorCopy.alert(for: MapperError.cameraDenied))
            present(denied, then: .endFlow)
        }
    }

    /// Start Scan or Skip on the tips page; `dontShowAgain` marks the object tips as seen.
    func tipsFinished(dontShowAgain: Bool) {
        guard phase == .tips, !hasEnded else { return }
        if dontShowAgain { ScanUISettings.markTipsSeen(.object) }
        apply(.tipsDone)
        startCapture()
    }

    /// Opens Mapper's page in Settings (`UIApplication.openSettingsURLString`, not in RESEARCH, iOS 8).
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        log("opening Settings")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Cancel on the chooser, the checks, the permission screen or the tips (the capture has
    /// its own Cancel in ObjectScanScreen). Ends the flow with `onDismiss`.
    func cancel() {
        switch phase {
        case .chooser, .preflight, .permission, .tips:
            apply(.cancelled)
            endFlow()
        case .capturing, .saving, .done, .largeChosen, .failed, .cancelled:
            log("cancel ignored in phase \(phase)")
        }
    }

    /// An alert button: Open Settings opens Settings; then, after the alert has animated out,
    /// the follow-up of the alert runs (end the flow, the next warning, or the next phase).
    func respond(to action: ObjectAlertAction) {
        let next = followUp
        followUp = .stay
        alert = nil
        if action == .openSettings { openSettings() }
        let nanoseconds = UInt64(ObjectFlowModel.presentationGapSeconds * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.run(next)
        }
    }

    /// The screen went away: releases a capture session still held (its InProgress folder
    /// stays for recovery when nothing was sealed). Idempotent.
    func viewDisappeared() {
        guard let scan = scanModel else { return }
        scan.teardown()
        if !phase.isTerminal {
            log("flow screen closed in phase \(phase); capture session released")
        }
    }

    // MARK: - Pure reducer

    /// Pure phase reducer (tested). Terminal phases ignore every signal; a signal that does not
    /// apply to the phase leaves it unchanged.
    nonisolated static func nextPhase(_ phase: ObjectFlowPhase, on signal: ObjectFlowSignal) -> ObjectFlowPhase {
        if phase.isTerminal { return phase }
        if case .failed(let reason) = signal { return .failed(reason) }
        switch (phase, signal) {
        case (.chooser, .choseSmallMedium): return .preflight
        case (.chooser, .choseLarge): return .largeChosen
        case (.preflight, .preflightPassed(let showTips)): return showTips ? .tips : .capturing
        case (.preflight, .preflightBlocked): return .cancelled
        case (.preflight, .permissionNeeded): return .permission
        case (.preflight, .permissionDenied): return .cancelled
        case (.permission, .permissionGranted(let showTips)): return showTips ? .tips : .capturing
        case (.permission, .permissionDenied): return .cancelled
        case (.tips, .tipsDone): return .capturing
        case (.capturing, .captureSealed): return .saving
        case (.capturing, .captureEnded): return .cancelled
        case (.saving, .saved(let projectID)): return .done(projectID)
        case (.chooser, .cancelled), (.preflight, .cancelled), (.permission, .cancelled), (.tips, .cancelled):
            return .cancelled
        default:
            return phase
        }
    }

    // MARK: - Preflight

    /// ScanUI's checks (async), then ObjectCapture's; Demo Mode skips both. A blocking issue
    /// shows its alert and ends the flow; a never-asked camera goes to the permission phase;
    /// warnings show before the tips or the capture.
    private func runPreflight() async {
        guard phase == .preflight, !hasEnded else { return }
        let showTips = !ScanUISettings.tipsSeen(.object)
        if isDemo {
            advance(.preflightPassed(showTips: showTips))
            return
        }
        let report = await ScanPreflight.run(mode: .object, isDemo: false)
        guard phase == .preflight, !hasEnded else { return }
        if let blocking = report.blocking, let blockingAlert = ObjectAlert.scanPreflight(blocking) {
            log("preflight blocked: \(ScanPreflight.describe(blocking))")
            apply(blocking == .cameraDenied ? .permissionDenied : .preflightBlocked)
            present(blockingAlert, then: .endFlow)
            return
        }
        let objectReport = ObjectCapturePreflight.run()
        if let issue = objectReport.blocking {
            log("object capture preflight blocked: \(issue)")
            apply(.preflightBlocked)
            present(ObjectAlert.preflight(issue), then: .endFlow)
            return
        }
        var warnings: [ObjectAlert] = report.warnings.compactMap { ObjectAlert.scanWarning($0) }
        warnings.append(contentsOf: objectReport.warnings.map { ObjectAlert.preflight($0) })
        pendingWarnings = ObjectAlert.uniqueWarnings(warnings)
        if report.blocking == .cameraUndetermined {
            apply(.permissionNeeded)
        } else {
            advance(.preflightPassed(showTips: showTips))
        }
    }

    /// Shows the next pending warning (closing it comes back here), then applies `signal` and
    /// starts the capture when the new phase is `.capturing`.
    private func advance(_ signal: ObjectFlowSignal) {
        guard !hasEnded else { return }
        if !pendingWarnings.isEmpty {
            let warning = pendingWarnings.removeFirst()
            present(warning, then: .advance(signal))
            return
        }
        apply(signal)
        if phase == .capturing { startCapture() }
    }

    // MARK: - Capture

    /// Creates the project and starts the capture (Demo Mode writes the synthetic object).
    /// A failure deletes the new project and shows its alert.
    private func startCapture() {
        guard phase == .capturing, projectID == nil, !hasEnded else { return }
        let name = ScanFlowModel.defaultProjectName(mode: .object, now: Date())
        let created: (ProjectPackage, ProjectManifest)
        do {
            created = try ProjectLibrary.shared.create(kind: .object, name: name)
        } catch {
            failFlow(error, reason: "project not created")
            return
        }
        let project = created.1.id
        projectID = project
        let target = ObjectScanTarget(projectID: project, package: created.0, objectID: UUID())
        log("project \(project) created for object \(target.objectID)")
        if isDemo {
            startDemo(target)
            return
        }
        let scan = ObjectScanModel(target: target)
        scan.onComplete = { [weak self] result in
            self?.captureSealed(result)
        }
        scan.onEnded = { [weak self] in
            self?.captureEnded()
        }
        scanModel = scan
        do {
            try scan.start()
        } catch {
            scan.teardown()
            scanModel = nil
            failFlow(error, reason: "capture did not start")
        }
    }

    /// The photos are sealed: one manifest update appends the ObjectRecord, sets the project
    /// `.needsProcessing` and `reconstructionPending`, then `.done` and `onComplete`.
    private func captureSealed(_ result: ObjectScanResult) {
        guard phase == .capturing, let project = projectID, !hasEnded else { return }
        apply(.captureSealed)
        scanModel?.teardown()
        let record = ObjectRecord(id: result.objectID, name: "", size: .smallMedium, status: .captured,
                                  imageCount: result.imageCount, modelFile: nil)
        do {
            try ProjectLibrary.shared.update(project) { manifest in
                manifest.objects.removeAll { $0.id == record.id }
                manifest.objects.append(record)
                manifest.status = .needsProcessing
                manifest.reconstructionPending = true
            }
        } catch {
            // The sealed photos stay in raw/objects/<id>/; the project is kept so nothing the
            // user captured is deleted (logged; the Home list shows the project).
            log("object \(result.objectID) sealed but the manifest update failed: \(StoreFiles.describe(error))")
            scanModel = nil
            apply(.failed("manifest update failed"))
            present(ObjectAlert(id: "object.saveFailed", title: Copy.Errors.saveFailed.title,
                                body: Copy.Errors.saveFailed.body, actions: [.ok]), then: .endFlow)
            return
        }
        recordSaved = true
        scanModel = nil
        log("object \(result.objectID) saved: \(result.imageCount) photos, project needs processing")
        complete(project)
    }

    /// The capture was cancelled or discarded (its InProgress folder is gone): the project made
    /// for it is deleted and the flow ends with `onDismiss`.
    private func captureEnded() {
        guard !hasEnded else { return }
        scanModel?.teardown()
        scanModel = nil
        deleteProjectIfUnused()
        apply(.captureEnded)
        endFlow()
    }

    /// Demo Mode: `ObjectDemo.makeDemoObject` off main, then the record, status `.ready`, `.done`.
    private func startDemo(_ target: ObjectScanTarget) {
        apply(.captureSealed)
        let now = Date()
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ObjectRecord, Error> in
                do {
                    let record = try ObjectDemo.makeDemoObject(package: target.package, objectID: target.objectID, now: now)
                    return .success(record)
                } catch {
                    return .failure(error)
                }
            }.value
            self?.demoFinished(outcome, project: target.projectID)
        }
    }

    /// Records the demo object and completes, or deletes the project and shows the failure.
    private func demoFinished(_ outcome: Result<ObjectRecord, Error>, project: UUID) {
        guard phase == .saving, !hasEnded else { return }
        do {
            let record = try outcome.get()
            try ProjectLibrary.shared.update(project) { manifest in
                manifest.objects = [record]
                manifest.status = .ready
                manifest.reconstructionPending = false
            }
            recordSaved = true
            log("demo object \(record.id) saved in project \(project)")
            complete(project)
        } catch {
            failFlow(error, reason: "demo object not written")
        }
    }

    // MARK: - Endings

    /// `.saved(project)` then `onComplete` once.
    private func complete(_ project: UUID) {
        apply(.saved(project))
        hasEnded = true
        let callback = onComplete
        onComplete = nil
        callback?(project)
    }

    /// Deletes the new project (when no record was saved), moves to `.failed` and shows the
    /// alert for `error`; closing it ends the flow.
    private func failFlow(_ error: Error, reason: String) {
        log("\(reason): \(StoreFiles.describe(error))")
        deleteProjectIfUnused()
        apply(.failed(reason))
        present(ObjectAlert.startFailure(error), then: .endFlow)
    }

    /// Deletes the project made for this flow unless its object was saved.
    private func deleteProjectIfUnused() {
        guard let project = projectID, !recordSaved else { return }
        do {
            try ProjectLibrary.shared.delete(project)
            log("project \(project) deleted (no object saved)")
        } catch {
            log("project \(project) could not be deleted: \(StoreFiles.describe(error))")
        }
        projectID = nil
    }

    /// Releases the capture and calls `onDismiss` once.
    private func endFlow() {
        guard !hasEnded else { return }
        hasEnded = true
        scanModel?.teardown()
        scanModel = nil
        log("object flow ended in phase \(phase)")
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    // MARK: - Helpers

    /// Shows `newAlert`; closing it runs `next`.
    private func present(_ newAlert: ObjectAlert, then next: FollowUp) {
        followUp = next
        alert = newAlert
        log("alert \(newAlert.id)")
    }

    /// Runs an alert's follow-up.
    private func run(_ next: FollowUp) {
        switch next {
        case .stay:
            break
        case .endFlow:
            endFlow()
        case .advance(let signal):
            advance(signal)
        }
    }

    /// Moves the phase through the pure reducer and logs real changes.
    private func apply(_ signal: ObjectFlowSignal) {
        let next = ObjectFlowModel.nextPhase(phase, on: signal)
        guard next != phase else { return }
        log("phase \(phase) -> \(next)")
        phase = next
    }

    /// Writes one line to the app log (category "objectui").
    private func log(_ message: String) {
        ObjectPresentation.log(message)
    }
}
