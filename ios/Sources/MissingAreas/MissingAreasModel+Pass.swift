import Foundation
import Combine

// The pass side of MissingAreasModel (docs/MODULES.md 3.40, flow steps 3 to 5): the coverage
// seed, the pass's finish, idle and failure events, recording the pass in the manifest, the
// evaluation after the tour and the one-time `onFinished` delivery. Main actor throughout;
// the seed and the evaluation run in detached tasks and hop back with value types only.

extension MissingAreasModel {
    // MARK: - Pass wiring

    /// Main (from `init`). Routes the pass's finish, idle and failure to this model.
    func connectPass() {
        scan.onFinished = { [weak self] result in
            self?.passFinished(result)
        }
        scan.onIdle = { [weak self] in
            self?.passIdle()
        }
        scan.$failure
            .compactMap { $0 }
            .sink { [weak self] error in
                MainActor.assumeIsolated {
                    self?.scanFailed(error)
                }
            }
            .store(in: &cancellables)
    }

    /// Off main: `MissingAreasReevaluation.seedInputs`; back on main, `coverage.seed(... deadlineSeconds: 2)`
    /// (it only queues work on the coverage queue), so the parts the room pass saw read green or
    /// yellow. Best effort; the lines are logged. Only value types cross the hop.
    func seedCoverage() {
        let package = target.package
        let record = target.room
        Task.detached(priority: .utility) { [weak self] in
            let inputs = MissingAreasReevaluation.seedInputs(package: package, record: record)
            await self?.seedReady(observations: inputs.observations, faces: inputs.faces)
        }
    }

    /// Main. Hands the seed to the coverage recorder (a seed that arrives before the recording
    /// began waits for it inside the recorder).
    func seedReady(observations: [CoverageObservation], faces: [CoverageFace]) {
        guard !tornDown else { return }
        guard !observations.isEmpty else {
            MissingAreasLog.write("coverage seed skipped: no observations of the room")
            return
        }
        let deadline = MissingAreasModel.seedDeadlineSeconds
        coverage.seed(observations: observations, faces: faces, deadlineSeconds: deadline)
        MissingAreasLog.write("coverage seed queued: \(observations.count) observations, \(faces.count) faces, "
                              + "deadline \(deadline) s")
    }

    // MARK: - Pass events (main)

    /// `.roomFinished`: the pass is sealed. Records it, then (unless a cancel is under way)
    /// evaluates the room again. A system stop that ended the pass during the tour lands here too.
    func passFinished(_ result: MeshScanResult) {
        guard passResult == nil else { return }
        passResult = result
        if result.stoppedBySystem { noteSystemStop() }
        MissingAreasLog.write("pass \(result.passID) sealed: \(result.meshFaceCount) faces, \(result.keyframeCount) "
                              + "keyframes, system stop \(result.stoppedBySystem), degraded \(result.log.degraded.rawValue)")
        let record = recordPass()
        if isCancelling {
            MissingAreasLog.write("cancel arrived after the seal; the sealed pass stays in the project")
            return
        }
        guard !phase.isTerminal, !tornDown else { return }
        leaveTour(for: .rechecking)
        reevaluate(record)
    }

    /// `.stateChanged(.idle)`: after a confirmed cancel the pass is gone; the tour ends with nil.
    func passIdle() {
        guard isCancelling, !phase.isTerminal else {
            MissingAreasLog.write("pass idle in phase \(MissingAreasModel.phaseName(phase)); nothing to do")
            return
        }
        scan.teardown()
        setCancelling(false)
        leaveTour(for: .cancelled)
        MissingAreasLog.write("tour cancelled; the room's session keeps running")
        scheduleDelivery(nil)
    }

    /// `.failed`: after the seal it is a notice (heat, storage, memory, tracking) shown as an
    /// alert, and the session stopped (`stoppedBySystem`); before the seal the pass failed.
    func scanFailed(_ error: MapperError) {
        MissingAreasLog.write("pass reported \(error.copyKey) in phase \(MissingAreasModel.phaseName(phase))")
        if passResult != nil {
            noteSystemStop()
            alert = ScanErrorCopy.notice(for: error)
            return
        }
        guard !isCancelling, !phase.isTerminal, !tornDown else { return }
        guard scan.engine.state == .failed else {
            alert = ScanErrorCopy.notice(for: error)
            return
        }
        fail(error, reason: "the pass failed before it was saved")
    }

    /// Ends the tour after a failure: alert, pass torn down (raw stays in InProgress for
    /// recovery), phase `.failed`, and the room's evaluation at Done once the alert is dismissed.
    func fail(_ error: MapperError, reason: String) {
        MissingAreasLog.write("tour failed: \(reason) (\(error.copyKey))")
        setCancelling(false)
        let shown = ScanErrorCopy.notice(for: error)
        leaveTour(for: .failed(shown.body))
        scan.teardown()
        alert = shown
        scheduleDelivery(target.evaluation)
    }

    // MARK: - Recording and evaluation

    /// Sets the room's `hasMeshPass` in the manifest (after the seal, before the evaluation).
    /// Returns the stored record, or the target's record with the flag set when the update failed.
    func recordPass() -> RoomRecord {
        var fallback = target.room
        fallback.hasMeshPass = true
        let roomID = target.room.id
        do {
            let written = try ProjectLibrary.shared.update(target.projectID) { (manifest: inout ProjectManifest) throws -> Void in
                guard let index = manifest.rooms.firstIndex(where: { $0.id == roomID }) else { return }
                manifest.rooms[index].hasMeshPass = true
            }
            if let stored = written.rooms.first(where: { $0.id == roomID }) {
                MissingAreasLog.write("room \(roomID) marked with a mesh pass")
                return stored
            }
            MissingAreasLog.write("room \(roomID) is not in the manifest; mesh pass not recorded")
        } catch {
            MissingAreasLog.write("mesh pass not recorded for room \(roomID): \(StoreFiles.describe(error))")
        }
        return fallback
    }

    /// Off main: `MissingAreasReevaluation.run`; back on main, `reevaluationFinished` (the
    /// evaluation or the failure text; only value types cross the hop).
    func reevaluate(_ record: RoomRecord) {
        let package = target.package
        let now = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            var evaluation: QualityEvaluation?
            var failure: String?
            do {
                evaluation = try MissingAreasReevaluation.run(package: package, record: record, now: now)
            } catch {
                failure = StoreFiles.describe(error)
            }
            let result = evaluation
            let problem = failure
            await self?.reevaluationFinished(result, failure: problem)
        }
    }

    /// The evaluation ended: keeps the new one (a failure logs and keeps the room's evaluation at
    /// Done; the pass stays sealed and the pipeline scores it later), hands the hub back
    /// (`scan.teardown()`), phase `.done`, then `onFinished`.
    func reevaluationFinished(_ evaluation: QualityEvaluation?, failure: String?) {
        if let evaluation {
            keep(newEvaluation: evaluation)
            MissingAreasLog.write("evaluation after the tour: \(target.evaluation.missingAreas.count) -> "
                                  + "\(evaluation.missingAreas.count) missing areas")
        } else {
            MissingAreasLog.write("evaluation after the tour failed (\(failure ?? "unknown")); keeping the room's evaluation")
        }
        scan.teardown()
        guard phase == .rechecking, !tornDown else { return }
        leaveTour(for: .done)
        scheduleDelivery(newEvaluation ?? target.evaluation)
    }

    // MARK: - Delivery

    /// Makes `onFinished(value)` due; it runs once any alert is dismissed.
    func scheduleDelivery(_ value: QualityEvaluation?) {
        guard !deliveryDue else { return }
        deliveryDue = true
        deliveryValue = value
        scheduleDeliveryCheck()
    }

    /// Checks the delivery on the next main turn (never inside a view update).
    func scheduleDeliveryCheck() {
        guard deliveryDue, !delivered else { return }
        Task { @MainActor [weak self] in
            self?.deliverIfReady()
        }
    }

    /// Calls `onFinished` once, when due, with no alert up and before `teardown()`.
    func deliverIfReady() {
        guard deliveryDue, !delivered, alert == nil, !tornDown else { return }
        delivered = true
        let callback = onFinished
        onFinished = nil
        let label = deliveryValue.map { "\($0.missingAreas.count) missing areas" } ?? "nothing (cancelled)"
        MissingAreasLog.write("tour ended in phase \(MissingAreasModel.phaseName(phase)); returning \(label)")
        callback?(deliveryValue)
    }
}
