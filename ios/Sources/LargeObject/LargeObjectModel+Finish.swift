import Foundation
import RealityKit
import UIKit

// After the seal, cancel and teardown of the large-object flow (docs/MODULES.md 3.39, flow
// steps 4 and 5). The ObjectRecord and the crop edit are written only after `.roomFinished`
// (the pass is sealed). A pass the engine stopped by itself (heat, storage, memory, a session
// failure) finishes without attachments, so its folder has no largeobject.json; the crop edit is
// still written from the tracker's latest box, which is what ObjectModel's ObjectMetricsStep uses.

/// Resumes a continuation at most once (snapshot completion against its timeout). Thread-safe.
final class LargeObjectOnceGate: @unchecked Sendable {
    /// Guards `used`.
    private let lock = NSLock()
    /// True once claimed.
    private var used = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Carries a snapshot image into the detached encoding task.
final class LargeObjectImageBox: @unchecked Sendable {
    /// The snapshot (read only).
    let image: UIImage

    /// Wraps `image`.
    init(image: UIImage) {
        self.image = image
    }
}

extension LargeObjectModel {
    /// Seconds to wait for the view snapshot before saving without a thumbnail.
    static let snapshotTimeout: Double = 2
    /// JPEG quality of the thumbnail.
    static let thumbnailQuality: CGFloat = 0.7

    // MARK: - After the seal

    /// `.roomFinished` (the pass is sealed): the crop edit, the ObjectRecord and the thumbnail, then
    /// teardown, phase `.done` and `onComplete` (after the notice alert when the engine reported one).
    func passFinished(_ result: MeshScanResult) {
        guard !completionStarted else { return }
        completionStarted = true
        refreshTask?.cancel()
        refreshTask = nil
        let finalBox = boxAtDone ?? tracker.current().box ?? box
        if !userFinished {
            LargeObjectLog.write("pass sealed without Done (stopped by the engine, system stop \(result.stoppedBySystem)); "
                                 + "largeobject.json not attached, crop from the latest box")
        }
        setPhase(.finishing)
        Task {
            await self.saveCapture(result, box: finalBox)
            self.completeAfterSave()
        }
    }

    /// Writes the crop edit (when a box exists), then the ObjectRecord with status `.needsProcessing`,
    /// then the thumbnail (best effort). Every step is logged; a failure does not stop the others.
    func saveCapture(_ result: MeshScanResult, box finalBox: OrientedBox?) async {
        let package = target.package
        let objectID = target.objectID
        if let cropBox = finalBox {
            let operation = EditOperation.cropObject(object: ElementID(uuid: objectID), box: OrientedBoxRecord(cropBox))
            let outcome = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    try EditStore.append(operation, to: package)
                    return "crop edit written"
                } catch {
                    return "crop edit not written: \(error)"
                }
            }.value
            LargeObjectLog.write("\(outcome), box \(LargeObjectTracker.sizeText(cropBox))")
        } else {
            LargeObjectLog.write("no box at the seal; no crop edit (the object needs a crop before processing)")
        }
        let record = LargeObjectModel.objectRecord(id: objectID, keyframes: result.keyframeCount)
        do {
            try ProjectLibrary.shared.update(target.projectID) { manifest in
                LargeObjectModel.add(record, to: &manifest)
            }
            LargeObjectLog.write("object \(objectID) added: \(result.keyframeCount) keyframes, "
                                 + "\(result.meshFaceCount) faces, degraded \(result.log.degraded.rawValue)")
        } catch {
            LargeObjectLog.write("object record not written: \(error)")
        }
        await writeThumbnail()
    }

    /// The ObjectRecord of a sealed large object.
    nonisolated static func objectRecord(id: UUID, keyframes: Int) -> ObjectRecord {
        ObjectRecord(id: id, name: "", size: .large, status: .captured, imageCount: keyframes, modelFile: nil)
    }

    /// Adds (or replaces, for the same id) `record` and sets the status `.needsProcessing`. Pure.
    nonisolated static func add(_ record: ObjectRecord, to manifest: inout ProjectManifest) {
        if let index = manifest.objects.firstIndex(where: { $0.id == record.id }) {
            manifest.objects[index] = record
        } else {
            manifest.objects.append(record)
        }
        manifest.status = .needsProcessing
    }

    /// Teardown, phase `.done`, then `onComplete` now or after the notice alert (heat, storage,
    /// memory or tracking, reported after `.roomFinished`).
    func completeAfterSave() {
        let projectID = target.projectID
        boxEntity.detach()
        scan.teardown()
        setPhase(.done(projectID))
        if let notice = scan.failure {
            LargeObjectLog.write("saved with a notice: \(notice.copyKey)")
            showAlert(ScanErrorCopy.notice(for: notice), then: .complete(projectID))
        } else {
            fireComplete(projectID)
        }
    }

    /// `onComplete` once.
    func fireComplete(_ projectID: UUID) {
        let callback = onComplete
        onComplete = nil
        onDismiss = nil
        LargeObjectLog.write("large object capture complete for project \(projectID)")
        callback?(projectID)
    }

    // MARK: - Thumbnail

    /// `thumbnail.jpg` from `arView.snapshot(saveToHDR: false)` of the attached view (outline removed
    /// first), `jpegData(compressionQuality: 0.7)` off main, `ProjectStore.writeData(_:to: package.thumbnailURL)`.
    /// Best effort, logged: FloorPlan's ThumbnailStep never makes one for a large object.
    func writeThumbnail() async {
        boxEntity.detach()
        guard let image = await captureSnapshot() else {
            LargeObjectLog.write("thumbnail skipped: no snapshot")
            return
        }
        let carrier = LargeObjectImageBox(image: image)
        let url = target.package.thumbnailURL
        let quality = LargeObjectModel.thumbnailQuality
        let outcome = await Task.detached(priority: .utility) { () -> String in
            guard let data = carrier.image.jpegData(compressionQuality: quality) else { return "encoding failed" }
            do {
                try ProjectStore.writeData(data, to: url, createParents: false)
                return "written, \(data.count) bytes"
            } catch {
                return "write failed: \(error)"
            }
        }.value
        LargeObjectLog.write("thumbnail \(outcome)")
    }

    /// The attached view's snapshot, or nil without a view, on failure or after `snapshotTimeout`.
    private func captureSnapshot() async -> UIImage? {
        guard let view = arView, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let gate = LargeObjectOnceGate()
        let timeout = LargeObjectModel.snapshotTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            view.snapshot(saveToHDR: false) { snapshot in
                if gate.claim() { continuation.resume(returning: snapshot) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: - Cancel

    /// Cancel was tapped: asks first (not while saving or after the end).
    func requestCancel() {
        guard canCancel else { return }
        showsCancelConfirmation = true
    }

    /// Keep Scanning in the confirmation.
    func keepScanning() {
        showsCancelConfirmation = false
    }

    /// Discard Scan in the confirmation: `scan.discard()`; on idle (or after a fallback wait) the
    /// project is deleted when it holds nothing, then `onDismiss`.
    func confirmCancel() {
        showsCancelConfirmation = false
        guard canCancel, !cancelConfirmed else { return }
        cancelConfirmed = true
        tapSerial += 1
        refreshTask?.cancel()
        refreshTask = nil
        tracker.setSeed(nil, floorY: nil, front: nil)
        setBox(nil)
        setPhase(.cancelled)
        LargeObjectLog.write("cancel confirmed; discarding the pass")
        scan.discard()
        let wait = LargeObjectModel.cancelFallbackSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.finishCancel(reason: "no idle event after \(Int(wait)) s")
        }
    }

    /// True while a cancel can still discard the capture.
    var canCancel: Bool {
        guard !completionStarted, !cancelConfirmed else { return false }
        switch phase {
        case .starting, .aiming, .locating, .capturing, .failed:
            return true
        case .finishing, .done, .cancelled:
            return false
        }
    }

    /// The engine went idle (cancel or discard finished). Only a confirmed cancel acts on it; the
    /// idle that follows a plain teardown is ignored.
    func passIdle() {
        guard cancelConfirmed else { return }
        finishCancel(reason: "pass discarded")
    }

    /// After a confirmed cancel, once: teardown, delete the project when it holds nothing, `onDismiss`.
    func finishCancel(reason: String) {
        guard cancelConfirmed, !dismissed else { return }
        LargeObjectLog.write("cancel finished: \(reason)")
        teardown()
        deleteProjectIfEmpty()
        fireDismiss()
    }

    /// Deletes the project when its manifest (read from disk, else the library's copy) has no object and no room.
    func deleteProjectIfEmpty() {
        let projectID = target.projectID
        let manifest = (try? ProjectStore.readManifest(target.package)) ?? ProjectLibrary.shared.manifest(for: projectID)
        guard let manifest else {
            LargeObjectLog.write("project \(projectID) already gone")
            return
        }
        guard manifest.objects.isEmpty && manifest.rooms.isEmpty else {
            LargeObjectLog.write("project \(projectID) kept: \(manifest.objects.count) objects, \(manifest.rooms.count) rooms")
            return
        }
        do {
            try ProjectLibrary.shared.delete(projectID)
            LargeObjectLog.write("empty project \(projectID) deleted")
        } catch {
            LargeObjectLog.write("empty project \(projectID) not deleted: \(error)")
        }
    }

    /// `onDismiss` once.
    func fireDismiss() {
        guard !dismissed else { return }
        dismissed = true
        let callback = onDismiss
        onDismiss = nil
        onComplete = nil
        callback?()
    }

    // MARK: - Teardown

    /// Idempotent: stops the refresh loop, removes the outline and tears the pass down (a capture
    /// still running is cancelled by the engine and its raw kept in InProgress for recovery).
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        tapSerial += 1
        refreshTask?.cancel()
        refreshTask = nil
        boxEntity.detach()
        scan.teardown()
        LargeObjectLog.write("large object model torn down in phase \(phase)")
    }
}
