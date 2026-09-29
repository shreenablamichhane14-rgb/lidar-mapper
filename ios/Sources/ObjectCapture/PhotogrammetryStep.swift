import Foundation
import RealityKit
// Photogrammetry types are imported with SwiftUI as well as RealityKit (docs/MODULES.md rule 0.2.13).
import SwiftUI

/// id .reconstructObject, subject = object id; required in the object plan. Budget 1 GB,
/// reduced 500 MB: both variants make the same request (Apple manages photogrammetry memory
/// and downsamples by itself); the reduced one only lets a relaunch after a jetsam kill run
/// once more on the kept checkpoint before the runner gives up (3.15).
///
/// Run (docs/MODULES.md 3.33 "Reconstruction"; RESEARCH 3.3 gotchas 7 to 12): waits until no
/// `ObjectCaptureSession` is counted, then one `PhotogrammetrySession` on
/// `raw/objects/<id>/Images/` with the derived checkpoint and object masking, requests
/// `[.modelFile(url: model-partial.usdz), .bounds]` at the default detail, iterates the outputs
/// until `.processingComplete` or `.processingCancelled`, renames the partial model over
/// `model.usdz`, writes `reconstruction.json` and clears `reconstructionPending`. The checkpoint
/// is kept (build 6 ObjectCrop re-runs from it).
final class PhotogrammetryStep: ProcessingStep {
    /// Hashed with the raw seal, so a rule change rebuilds the model.
    static let rulesVersion = "reconstruct-rules=1"
    /// Peak memory of the full variant, bytes (1 GB).
    static let fullBudgetBytes: UInt64 = 1024 * 1024 * 1024
    /// Peak memory of the reduced variant, bytes (500 MB).
    static let reducedBudgetBytes: UInt64 = 500 * 1024 * 1024
    /// Longest wait for a capture session to be released, seconds.
    static let captureWaitSeconds: Double = 60
    /// Poll interval while waiting for the capture, seconds.
    static let pollSeconds: Double = 0.25
    /// Minimum interval between two progress posts, seconds (4 per second).
    static let progressInterval: Double = 0.25
    /// Share of the step's progress the session's fraction fills (the rest is the install).
    static let progressShare = 0.95

    /// Always `.reconstructObject`.
    let id: PipelineStepID = .reconstructObject
    /// The object this step reconstructs (the stamp subject).
    let object: ObjectRecord

    /// Full budget, 1 GB.
    var memoryBudgetBytes: UInt64 { PhotogrammetryStep.fullBudgetBytes }
    /// Reduced budget, 500 MB (the same request; see the type comment).
    var reducedMemoryBudgetBytes: UInt64? { PhotogrammetryStep.reducedBudgetBytes }

    /// A step for one small or medium object.
    init(object: ObjectRecord) {
        self.object = object
    }

    // MARK: Hash

    /// The seal of `raw/objects/<id>/` and `rulesVersion`.
    func inputHash(_ ctx: StepContext) throws -> String {
        let sealURL = ctx.package.sealURL(in: ctx.package.rawObjectURL(object.id))
        return PhotogrammetryStep.inputHash(seal: try? ProjectStore.readJSON(SealFile.self, from: sealURL))
    }

    /// The step hash for a seal (nil hashes no files).
    static func inputHash(seal: SealFile?) -> String {
        InputHasher.hash(seals: seal.map { [$0] } ?? [], editRevision: nil, extra: [rulesVersion])
    }

    // MARK: Run

    /// Reconstructs the model. Throws `MapperError.objectCaptureFailed` when photogrammetry is
    /// unsupported, the images are missing or the model request fails (after the checkpoint
    /// retry), `MapperError.cancelled` when cancelled or when a capture session stayed alive
    /// for 60 s (the job stays queued), and `MapperError.ioFailed` when the outputs cannot be
    /// installed.
    func run(_ ctx: StepContext) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let package = ctx.package
        let objectID = object.id
        defer { PhotogrammetryMonitor.postClear(objectID) }
        try ctx.checkCancelled()
        guard PhotogrammetrySession.isSupported else {
            ObjectCaptureSignals.log("reconstruct \(objectID): photogrammetry unsupported")
            throw MapperError.objectCaptureFailed("photogrammetry unsupported")
        }
        let images = PhotogrammetryStore.imagesURL(package, object: objectID)
        let imageCount = ObjectScanFolders.imageCount(in: images)
        guard imageCount >= ObjectScanFolders.minimumImages else {
            ObjectCaptureSignals.log("reconstruct \(objectID): only \(imageCount) images")
            throw MapperError.objectCaptureFailed("only \(imageCount) images")
        }
        try await waitForCaptureRelease(ctx)

        try ProjectStore.ensureDirectory(PhotogrammetryStore.folder(package, object: objectID), inside: package.root)
        let checkpoint = PhotogrammetryStore.checkpointURL(package, object: objectID)
        let reused = StoreFiles.isDirectory(checkpoint) && !ObjectScanFolders.isEmptyDirectory(checkpoint)
        try ProjectStore.ensureDirectory(checkpoint, inside: package.root)
        let partial = PhotogrammetryStore.partialModelURL(package, object: objectID)
        removeIfPresent(partial)

        let limits = PhotogrammetryStore.deviceLimits()
        let thermalStart = ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue
        let variant = ctx.availableMemory < memoryBudgetBytes ? "reduced" : "full"
        let checkpointText = reused ? "reused" : "new"
        let limitsText = "limits \(limits.images) images / \(limits.dimension) px"
        let memoryText = "memory \(ProcessingGuards.availableMemory()) bytes"
        ObjectCaptureSignals.log("reconstruct \(objectID): \(imageCount) images, \(limitsText), variant \(variant), "
                                 + "\(memoryText), thermal \(thermalStart), checkpoint \(checkpointText)")

        let outcome: ReconstructionOutcome
        do {
            outcome = try await reconstructOnce(ctx, images: images, checkpoint: checkpoint, output: partial)
        } catch let failure as PhotogrammetryAttemptFailure {
            guard reused, !ctx.isCancelled() else { throw failure.mapperError }
            ObjectCaptureSignals.log("reconstruct \(objectID): checkpoint retry after \(failure.detail)")
            do {
                try ObjectScanFolders.emptyDirectory(checkpoint)
            } catch {
                throw MapperError.ioFailed("checkpoint reset: \(StoreFiles.describe(error))")
            }
            removeIfPresent(partial)
            do {
                outcome = try await reconstructOnce(ctx, images: images, checkpoint: checkpoint, output: partial)
            } catch let second as PhotogrammetryAttemptFailure {
                throw second.mapperError
            }
        }

        try installModel(partial, package: package, objectID: objectID)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let thermalEnd = ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue
        let progress = outcome.progress
        let hash = try inputHash(ctx)
        let info = PhotogrammetryInfo(objectID: objectID, imageCount: imageCount,
                                      boundsMin: outcome.boundsMin, boundsMax: outcome.boundsMax,
                                      seconds: seconds, invalidSamples: progress.invalidSamples,
                                      skippedSamples: progress.skippedSamples, downsampled: progress.downsampled,
                                      stitchingIncomplete: progress.stitchingIncomplete,
                                      maximumNumberOfInputImages: limits.images,
                                      maximumInputImageDimension: limits.dimension,
                                      thermalAtStart: thermalStart, thermalAtEnd: thermalEnd,
                                      inputHash: hash, finishedAt: Date())
        do {
            try ProjectStore.writeJSON(info, to: PhotogrammetryStore.infoURL(package, object: objectID), createParents: false)
            try ManifestWriter.update(package) { manifest in
                if let index = manifest.objects.firstIndex(where: { $0.id == objectID }) {
                    manifest.objects[index].modelFile = PhotogrammetryStore.modelFileName
                }
                manifest.reconstructionPending = false
            }
        } catch {
            throw MapperError.ioFailed("reconstruction outputs: \(StoreFiles.describe(error))")
        }
        ctx.progress(1)
        let secondsText = String(format: "%.1f", seconds)
        let hasBounds = outcome.boundsMin != nil
        let samplesText = "invalid \(progress.invalidSamples), skipped \(progress.skippedSamples)"
        let flagsText = "downsampled \(progress.downsampled), stitching incomplete \(progress.stitchingIncomplete)"
        let endMemory = "memory \(ProcessingGuards.availableMemory()) bytes"
        ObjectCaptureSignals.log("reconstruct \(objectID): done in \(secondsText) s, thermal \(thermalStart) -> \(thermalEnd), "
                                 + "\(endMemory), \(samplesText), \(flagsText), bounds \(hasBounds)")
    }

    // MARK: Private

    /// Waits while `ObjectCaptureActivity.captureSessions > 0` (poll 0.25 s, cancellation checked
    /// each time, at most 60 s, then `MapperError.cancelled` so the job stays queued; logged),
    /// because a capture and a photogrammetry session must never overlap (gotcha 10).
    private func waitForCaptureRelease(_ ctx: StepContext) async throws {
        guard ObjectCaptureActivity.captureSessions > 0 else { return }
        let start = ProcessInfo.processInfo.systemUptime
        ObjectCaptureSignals.log("reconstruct \(object.id): waiting for the capture session to be released")
        let nanoseconds = UInt64(PhotogrammetryStep.pollSeconds * 1_000_000_000)
        while ObjectCaptureActivity.captureSessions > 0 {
            try ctx.checkCancelled()
            let waited = ProcessInfo.processInfo.systemUptime - start
            if waited >= PhotogrammetryStep.captureWaitSeconds {
                ObjectCaptureSignals.log("reconstruct \(object.id): capture session still alive after \(Int(waited)) s; left queued")
                throw MapperError.cancelled
            }
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
        let waited = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start)
        ObjectCaptureSignals.log("reconstruct \(object.id): waited \(waited) s for the capture session")
    }

    /// One counted session: `reconstructionStarted()` right before the session is created and
    /// `reconstructionEnded()` after `runSession` returned or threw (its session reference and
    /// the cancel watcher are gone by then).
    private func reconstructOnce(_ ctx: StepContext, images: URL, checkpoint: URL,
                                 output: URL) async throws -> ReconstructionOutcome {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = checkpoint
        configuration.isObjectMaskingEnabled = true
        ObjectCaptureActivity.reconstructionStarted()
        let result: Result<ReconstructionOutcome, Error>
        do {
            let outcome = try await runSession(ctx, images: images, configuration: configuration, output: output)
            result = .success(outcome)
        } catch {
            result = .failure(error)
        }
        ObjectCaptureActivity.reconstructionEnded()
        return try result.get()
    }

    /// Creates the session, starts the requests and iterates the outputs until
    /// `.processingComplete` or `.processingCancelled` (the sequence never ends by itself,
    /// gotcha 8). Cancellation is checked on every output and by a 1 s watcher; a cancel calls
    /// `session.cancel()` and waits for `.processingCancelled` (gotcha 9). Throws
    /// `PhotogrammetryAttemptFailure` for a failure the checkpoint retry may fix and
    /// `MapperError.cancelled` for a cancel.
    private func runSession(_ ctx: StepContext, images: URL, configuration: PhotogrammetrySession.Configuration,
                            output: URL) async throws -> ReconstructionOutcome {
        let session: PhotogrammetrySession
        do {
            session = try PhotogrammetrySession(input: images, configuration: configuration)
        } catch {
            throw PhotogrammetryAttemptFailure(detail: "session: \(StoreFiles.describe(error))")
        }
        do {
            try session.process(requests: [.modelFile(url: output), .bounds])
        } catch {
            throw PhotogrammetryAttemptFailure(detail: "process: \(StoreFiles.describe(error))")
        }
        let canceller = PhotogrammetryCanceller(session: session, isCancelled: ctx.isCancelled)
        let watcher = Task.detached { await canceller.watch() }
        var loop = OutputLoopState(objectID: object.id)
        do {
            for try await item in session.outputs {
                _ = canceller.cancelIfNeeded()
                if handle(item, loop: &loop, ctx: ctx) { break }
            }
        } catch {
            watcher.cancel()
            _ = await watcher.value
            if canceller.wasRequested || ctx.isCancelled() { throw MapperError.cancelled }
            throw PhotogrammetryAttemptFailure(detail: "outputs: \(StoreFiles.describe(error))")
        }
        watcher.cancel()
        _ = await watcher.value
        ctx.progress(loop.progress.fraction * PhotogrammetryStep.progressShare)
        PhotogrammetryMonitor.post(loop.progress)
        return try finish(loop, canceller: canceller, output: output)
    }

    /// Applies one output to the loop state (bounds, model errors, progress, throttled posts);
    /// true when the loop must end (`.processingComplete` or `.processingCancelled`).
    private func handle(_ item: PhotogrammetrySession.Output, loop: inout OutputLoopState, ctx: StepContext) -> Bool {
        if case .requestComplete(_, .bounds(let box)) = item {
            loop.boundsMin = Vec3(box.min)
            loop.boundsMax = Vec3(box.max)
        }
        if case .requestError(let request, let error) = item {
            let detail = StoreFiles.describe(error)
            if PhotogrammetryOutputs.isModelRequest(request) {
                loop.modelError = detail
                ObjectCaptureSignals.log("reconstruct \(object.id): model request failed (\(detail))")
            } else {
                ObjectCaptureSignals.log("reconstruct \(object.id): bounds request failed (\(detail)), ignored")
            }
        }
        guard let event = PhotogrammetryOutputs.event(item) else { return false }
        loop.progress = PhotogrammetryOutputs.reduce(loop.progress, event)
        switch event {
        case .completed, .cancelled:
            loop.ended = event
            return true
        case .modelWritten:
            loop.modelWritten = true
        case .inputComplete, .progress, .stage, .invalidSample, .skippedSample, .downsampled,
             .stitchingIncomplete, .boundsReceived, .requestFailed:
            break
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - loop.lastPost >= PhotogrammetryStep.progressInterval {
            loop.lastPost = now
            ctx.progress(loop.progress.fraction * PhotogrammetryStep.progressShare)
            PhotogrammetryMonitor.post(loop.progress)
        }
        return false
    }

    /// Decides the attempt's result after the loop: cancelled, failed (retryable) or a model.
    /// A cancel that arrived after the model was complete keeps the model.
    private func finish(_ loop: OutputLoopState, canceller: PhotogrammetryCanceller,
                        output: URL) throws -> ReconstructionOutcome {
        guard let ended = loop.ended else {
            if canceller.wasRequested { throw MapperError.cancelled }
            throw PhotogrammetryAttemptFailure(detail: "outputs ended before processing completed")
        }
        let hasModel = loop.modelWritten && loop.modelError == nil && FileManager.default.fileExists(atPath: output.path)
        if ended == .cancelled || (canceller.wasRequested && !hasModel) {
            ObjectCaptureSignals.log("reconstruct \(object.id): cancelled at \(Int(loop.progress.fraction * 100)) percent")
            throw MapperError.cancelled
        }
        if let error = loop.modelError {
            throw PhotogrammetryAttemptFailure(detail: "model request: \(error)")
        }
        guard hasModel else {
            throw PhotogrammetryAttemptFailure(detail: "processing completed without a model file")
        }
        return ReconstructionOutcome(progress: loop.progress, boundsMin: loop.boundsMin, boundsMax: loop.boundsMax)
    }

    /// `model-partial.usdz` replaces `model.usdz` (`FileManager.replaceItemAt`), or is renamed to
    /// it when there is no older model.
    private func installModel(_ partial: URL, package: ProjectPackage, objectID: UUID) throws {
        let target = PhotogrammetryStore.modelURL(package, object: objectID)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: partial, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: partial, to: target)
            }
        } catch {
            throw MapperError.ioFailed("model install: \(StoreFiles.describe(error))")
        }
    }

    /// Deletes a leftover file; failures are logged.
    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            ObjectCaptureSignals.log("reconstruct \(object.id): remove \(url.lastPathComponent) failed (\(StoreFiles.describe(error)))")
        }
    }
}

/// What one successful session produced.
private struct ReconstructionOutcome {
    /// Final progress (counters and flags for the info file).
    var progress: PhotogrammetryProgress
    /// The `.bounds` result, when it arrived.
    var boundsMin: Vec3?
    var boundsMax: Vec3?
}

/// Mutable state of one output loop.
private struct OutputLoopState {
    /// Progress so far.
    var progress: PhotogrammetryProgress
    /// The `.bounds` result, when it arrived.
    var boundsMin: Vec3?
    var boundsMax: Vec3?
    /// Error of the model request, log text.
    var modelError: String?
    /// True after the model request completed.
    var modelWritten = false
    /// `.completed` or `.cancelled` once processing ended.
    var ended: PhotogrammetryEvent?
    /// Uptime of the last progress post.
    var lastPost = -Double.infinity

    /// Empty state for an object.
    init(objectID: UUID) {
        progress = PhotogrammetryProgress(objectID: objectID)
    }
}

/// A failed attempt that the checkpoint retry may fix; turned into
/// `MapperError.objectCaptureFailed` when it leaves the step.
private struct PhotogrammetryAttemptFailure: Error {
    /// Log text.
    var detail: String
    /// The error the step throws.
    var mapperError: MapperError { .objectCaptureFailed(detail) }
}

/// Sends `cancel()` to a running session once the job is cancelled: checked on every output by
/// the loop and every second by `watch()`. Thread-safe.
private final class PhotogrammetryCanceller: @unchecked Sendable {
    /// The running session.
    private let session: PhotogrammetrySession
    /// The step context's cancellation flag (thread-safe per `StepContext`).
    private let isCancelled: () -> Bool
    /// Protects `requested`.
    private let lock = NSLock()
    /// True once `cancel()` was sent.
    private var requested = false

    /// Watches `session` for the job flag `isCancelled`.
    init(session: PhotogrammetrySession, isCancelled: @escaping () -> Bool) {
        self.session = session
        self.isCancelled = isCancelled
    }

    /// True once `cancel()` was sent.
    var wasRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    /// Sends `cancel()` once when the job is cancelled; true when a cancel was sent (now or before).
    func cancelIfNeeded() -> Bool {
        guard isCancelled() else { return wasRequested }
        lock.lock()
        let first = !requested
        requested = true
        lock.unlock()
        if first {
            session.cancel()
            ObjectCaptureSignals.log("photogrammetry: cancel requested")
        }
        return true
    }

    /// Checks once a second until a cancel was sent or the watcher task is cancelled.
    func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            if cancelIfNeeded() { return }
        }
    }
}
