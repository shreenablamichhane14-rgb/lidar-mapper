import ARKit
import Foundation

/// Saves the user's "Take Photo" pictures during an ARKit capture (SPEC deliverable 12, capture
/// side): the next frame with normal tracking after `requestPhoto(note:)` is copied, encoded
/// as JPEG (quality 0.9) at `photos/<id>.jpg` on the io queue, and one `PhotoPin` line (pose,
/// intrinsics, note) is appended to photos.jsonl after the file exists.
///
/// Threading: `requestPhoto` and `onPhotoSaved` may be used from any thread (lock-protected);
/// every `ScanRecorder` call runs on the hub queue; encoding and writes run on Store's io queue
/// through the recorder's own `RawScanWriter`. One copier buffer is made at the first request,
/// so a photo is never queued behind another one: the request waits for the buffer instead.
/// No ARFrame or ARKit buffer is retained.
final class PhotoRecorder: ScanRecorder {
    /// JPEG quality of photos.
    static let jpegQuality: Double = KeyframeEncoding.photoQuality
    /// Frame buffers for photos (one photo in flight at a time).
    static let bufferCount = 1

    // MARK: Lock-protected state

    /// Guards the lock-protected group.
    private let lock = NSLock()
    /// Note of the pending request, nil when no photo is requested.
    private var pendingNote: String?
    /// Backing store of `onPhotoSaved`.
    private var savedHandler: ((UUID) -> Void)?
    /// Photos whose line was written since begin.
    private var savedCount = 0

    // MARK: Hub queue state

    /// Lifecycle phase.
    private var phase: KeyframesRecorderPhase = .idle
    /// Folder and writer of the current (or last) recording.
    private var folder: RawScanFolder?, writer: RawScanWriter?
    /// The photo copier, made at the first frame that serves a request.
    private var copier: FrameCopier?

    /// Creates an idle recorder.
    init() {}

    /// Any thread. The next frame with normal tracking is saved as photos/<id>.jpg plus a
    /// photos.jsonl line. A request made while another is still pending is merged into it
    /// (one photo, the first note).
    func requestPhoto(note: String = "") {
        let accepted = locked { () -> Bool in
            guard pendingNote == nil else { return false }
            pendingNote = note
            return true
        }
        KeyframesLog.write(accepted ? "photo: requested" : "photo: request merged with the pending one")
    }

    /// Called on main after the photo file is written.
    var onPhotoSaved: ((UUID) -> Void)? {
        get { locked { savedHandler } }
        set { locked { savedHandler = newValue } }
    }

    /// Any thread. True while a request waits for a frame.
    var hasPendingRequest: Bool { locked { pendingNote != nil } }

    /// Any thread. Takes the pending request (its note) and clears it, so each request is
    /// served exactly once; nil when none is pending.
    func takePendingRequest() -> String? {
        locked { () -> String? in
            let note = pendingNote
            pendingNote = nil
            return note
        }
    }

    /// Any thread. Photos whose line was written since begin.
    var savedPhotos: Int { locked { savedCount } }

    /// Hub queue. Photos written and failed writes.
    var stats: RecorderStats {
        var result = RecorderStats()
        result.photos = savedPhotos
        result.writeFailures = writer?.failureCount ?? 0
        return result
    }

    // MARK: - ScanRecorder

    /// Hub queue. Starts saving photos into `folder` (with its photos/ subfolder). A request
    /// left from before is dropped; a recording still open is closed first.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {
        if phase == .recording, let previous = writer {
            KeyframesLog.write("photo: begin while recording; closing the previous recording")
            KeyframeEncoding.finish(previous) {}
        }
        if takePendingRequest() != nil { KeyframesLog.write("photo: stale request dropped at begin") }
        self.folder = folder
        writer = RawScanWriter(folder: folder)
        copier = nil
        locked { savedCount = 0 }
        phase = .recording
        KeyframesLog.write("photo: begin \(folder.url.lastPathComponent), mode \(profile.mode.rawValue)")
    }

    /// Hub queue. Serves a pending request with this frame when tracking is normal and the
    /// photo buffer is free; otherwise the request waits for a later frame.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame) {
        guard phase == .recording, let folder, let writer, hasPendingRequest else { return }
        let camera = frame.camera
        guard TrackingMonitor.summary(camera.trackingState) == .normal else { return }
        let image = frame.capturedImage
        guard let activeCopier = preparedCopier(for: image), activeCopier.available > 0 else { return }
        guard let note = takePendingRequest() else { return }
        guard let buffer = activeCopier.copy(image) else {
            restoreRequest(note)
            return
        }
        let id = UUID()
        let pin = PhotoPin(id: id, timestamp: frame.timestamp, transform: Transform4(camera.transform),
                           intrinsics: ARFrameReading.intrinsics(of: camera),
                           imageFile: RawScanFolder.photoPath(id), note: note)
        submit(PhotoJob(buffer: buffer, pin: pin), folder: folder, writer: writer, copier: activeCopier)
    }

    /// Hub queue. Drops a request that is still pending, waits for a photo being written,
    /// closes the writer and calls `completion` (on the io queue). Without an open recording
    /// `completion` runs at once. Later hub callbacks are ignored.
    func finishRecording(completion: @escaping () -> Void) {
        if takePendingRequest() != nil { KeyframesLog.write("photo: pending request dropped at finish") }
        guard phase == .recording, let writer else {
            if phase == .recording { phase = .finished }
            completion()
            return
        }
        phase = .finished
        copier = nil
        let name = folder?.url.lastPathComponent ?? "-"
        KeyframeEncoding.finish(writer) { [weak self] in
            let saved = self?.savedPhotos ?? 0
            KeyframesLog.write("photo: finished \(name): \(saved) photos, \(writer.failureCount) write failures")
            completion()
        }
    }

    // MARK: - Helpers

    /// Puts a request back when its frame could not be copied (unless a new one arrived).
    private func restoreRequest(_ note: String) {
        locked { () -> Void in
            if pendingNote == nil { pendingNote = note }
        }
    }

    /// The photo copier for this image size and format, made (or remade when nothing is in
    /// flight) as needed; nil while a copier of another format still has a photo in flight.
    private func preparedCopier(for image: CVPixelBuffer) -> FrameCopier? {
        if let existing = copier {
            if existing.matches(image) { return existing }
            if existing.inUse > 0 { return nil }
        }
        let made = FrameCopier(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                               pixelFormat: CVPixelBufferGetPixelFormatType(image), count: PhotoRecorder.bufferCount)
        copier = made
        return made
    }

    /// Queues the photo on the io queue; after its line is written counts it and calls
    /// `onPhotoSaved` on main.
    private func submit(_ job: PhotoJob, folder: RawScanFolder, writer: RawScanWriter, copier: FrameCopier) {
        let id = job.pin.id
        writer.perform { [weak self] in
            let written = try KeyframeEncoding.writePhoto(job, folder: folder, writer: writer, copier: copier,
                                                          quality: PhotoRecorder.jpegQuality)
            guard written, let self else { return }
            let handler = self.locked { () -> ((UUID) -> Void)? in
                self.savedCount += 1
                return self.savedHandler
            }
            KeyframesLog.write("photo: saved \(id.uuidString)")
            DispatchQueue.main.async {
                handler?(id)
            }
        }
    }

    /// Runs `body` while holding `lock`.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
