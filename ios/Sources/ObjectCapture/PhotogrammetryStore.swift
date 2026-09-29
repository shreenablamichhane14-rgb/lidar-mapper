import Foundation
import Combine
import RealityKit
// Photogrammetry and Object Capture types are imported with SwiftUI as well as RealityKit
// (docs/MODULES.md rule 0.2.13).
import SwiftUI

// Reconstruction paths, info, progress and the progress monitor (docs/MODULES.md 3.33, 3.1;
// ARCHITECTURE 5.10; RESEARCH 3.3 recommended 6).

/// Mapper's copy of `PhotogrammetrySession.Output.ProcessingStage`.
enum PhotogrammetryStage: String, Codable, CaseIterable, Sendable {
    case preProcessing, imageAlignment, pointCloudGeneration, meshGeneration, textureMapping, optimization
}

/// Live reconstruction progress for ObjectUI (Mapper values only).
struct PhotogrammetryProgress: Equatable, Sendable {
    /// The object being reconstructed.
    var objectID: UUID
    /// Fraction of the model request, 0...1.
    var fraction: Double = 0
    /// Current stage, when the session reported one.
    var stage: PhotogrammetryStage? = nil
    /// Estimated seconds left, when the session reported an estimate.
    var remainingSeconds: Double? = nil
    /// True once all images were ingested (`.inputComplete`).
    var inputComplete = false
    /// True after `.automaticDownsampling` (images shrunk to fit memory).
    var downsampled = false
    /// True after `.stitchingIncomplete` (a flipped side did not join).
    var stitchingIncomplete = false
    /// Count of `.invalidSample` outputs.
    var invalidSamples = 0
    /// Count of `.skippedSample` outputs.
    var skippedSamples = 0

    /// Empty progress for an object.
    init(objectID: UUID) {
        self.objectID = objectID
    }
}

/// Mapper's copy of the outputs that change progress (pure reducer input).
enum PhotogrammetryEvent: Equatable, Sendable {
    case inputComplete, progress(Double), stage(PhotogrammetryStage?, remaining: Double?)
    case invalidSample, skippedSample, downsampled, stitchingIncomplete
    case modelWritten, boundsReceived, requestFailed(String), completed, cancelled
}

/// Pure mappings from `PhotogrammetrySession.Output` to Mapper events and progress.
enum PhotogrammetryOutputs {
    /// Maps a processing stage; a stage added by a future SDK gives nil.
    static func stage(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> PhotogrammetryStage? {
        switch stage {
        case .preProcessing: return .preProcessing
        case .imageAlignment: return .imageAlignment
        case .pointCloudGeneration: return .pointCloudGeneration
        case .meshGeneration: return .meshGeneration
        case .textureMapping: return .textureMapping
        case .optimization: return .optimization
        @unknown default: return nil
        }
    }

    /// Every `Output` case mapped, `@unknown default` gives nil (logged). Progress and progress
    /// info count only for the model request (the `.bounds` request finishes long before the
    /// model and would make the bar jump), so those outputs of other requests give nil.
    static func event(_ output: PhotogrammetrySession.Output) -> PhotogrammetryEvent? {
        switch output {
        case .inputComplete:
            return .inputComplete
        case .requestProgress(let request, let fractionComplete):
            return isModelRequest(request) ? .progress(fractionComplete) : nil
        case .requestProgressInfo(let request, let info):
            guard isModelRequest(request) else { return nil }
            let mapped = info.processingStage.flatMap { PhotogrammetryOutputs.stage($0) }
            return .stage(mapped, remaining: info.estimatedRemainingTime)
        case .requestComplete(let request, _):
            if isModelRequest(request) { return .modelWritten }
            if case .bounds = request { return .boundsReceived }
            return nil
        case .requestError(_, let error):
            return .requestFailed(StoreFiles.describe(error))
        case .processingComplete:
            return .completed
        case .processingCancelled:
            return .cancelled
        case .invalidSample:
            return .invalidSample
        case .skippedSample:
            return .skippedSample
        case .automaticDownsampling:
            return .downsampled
        case .stitchingIncomplete:
            return .stitchingIncomplete
        @unknown default:
            ObjectCaptureSignals.log("photogrammetry: unknown output ignored")
            return nil
        }
    }

    /// Applies one event. Progress is clamped to 0...1 and never goes backwards; a stage event
    /// keeps the previous stage or estimate when the new one is nil; `.completed` sets 1.
    static func reduce(_ progress: PhotogrammetryProgress, _ event: PhotogrammetryEvent) -> PhotogrammetryProgress {
        var next = progress
        switch event {
        case .inputComplete:
            next.inputComplete = true
        case .progress(let fraction):
            let clamped = fraction.isFinite ? Swift.min(1, Swift.max(0, fraction)) : 0
            next.fraction = Swift.max(next.fraction, clamped)
        case .stage(let stage, let remaining):
            if let stage { next.stage = stage }
            if let remaining, remaining.isFinite, remaining >= 0 { next.remainingSeconds = remaining }
        case .invalidSample:
            next.invalidSamples += 1
        case .skippedSample:
            next.skippedSamples += 1
        case .downsampled:
            next.downsampled = true
        case .stitchingIncomplete:
            next.stitchingIncomplete = true
        case .completed:
            next.fraction = 1
            next.remainingSeconds = 0
        case .modelWritten, .boundsReceived, .requestFailed, .cancelled:
            break
        }
        return next
    }

    /// True for a `.modelFile` request.
    static func isModelRequest(_ request: PhotogrammetrySession.Request) -> Bool {
        if case .modelFile = request { return true }
        return false
    }
}

/// `derived/objects/<id>/reconstruction.json`.
struct PhotogrammetryInfo: Codable, Equatable, Sendable {
    /// The reconstructed object.
    var objectID: UUID
    /// Images in `raw/objects/<id>/Images/`.
    var imageCount: Int
    /// The `.bounds` result, meters, when it arrived.
    var boundsMin: Vec3?
    var boundsMax: Vec3?
    /// Wall time of the step, seconds.
    var seconds: Double
    /// Counts of `.invalidSample` and `.skippedSample` outputs.
    var invalidSamples: Int
    var skippedSamples: Int
    /// `.automaticDownsampling` and `.stitchingIncomplete` were reported.
    var downsampled: Bool
    var stitchingIncomplete: Bool
    /// `PhotogrammetrySession.limits` on this device.
    var maximumNumberOfInputImages: Int
    var maximumInputImageDimension: Int
    /// `ThermalLevel` raw values at start and end.
    var thermalAtStart: String
    var thermalAtEnd: String
    /// The step's input hash.
    var inputHash: String
    /// When the model was installed.
    var finishedAt: Date

    /// boundsMax - boundsMin, nil without bounds.
    var boundsExtents: SIMD3<Float>? {
        guard let low = boundsMin, let high = boundsMax else { return nil }
        return high.simd - low.simd
    }
}

/// Paths and loaders of the reconstruction outputs (section 3.1). Any thread, no IO except the
/// two loaders.
enum PhotogrammetryStore {
    /// The finished model.
    static let modelFileName = "model.usdz"
    /// The model while it is written (renamed over `model.usdz` on success).
    static let partialModelFileName = "model-partial.usdz"
    /// `PhotogrammetryInfo`.
    static let infoFileName = "reconstruction.json"
    /// The derived checkpoint folder (moved from the capture at sealing, kept for build 6).
    static let checkpointFolderName = "checkpoint"
    /// Read cap of `reconstruction.json`, bytes.
    static let maxInfoBytes: Int64 = 256 * 1024

    /// `derived/objects/<id>/`.
    static func folder(_ package: ProjectPackage, object: UUID) -> URL {
        package.derivedObjectURL(object)
    }

    /// `derived/objects/<id>/model.usdz`.
    static func modelURL(_ package: ProjectPackage, object: UUID) -> URL {
        folder(package, object: object).appendingPathComponent(modelFileName, isDirectory: false)
    }

    /// `derived/objects/<id>/model-partial.usdz`.
    static func partialModelURL(_ package: ProjectPackage, object: UUID) -> URL {
        folder(package, object: object).appendingPathComponent(partialModelFileName, isDirectory: false)
    }

    /// `derived/objects/<id>/checkpoint/`.
    static func checkpointURL(_ package: ProjectPackage, object: UUID) -> URL {
        folder(package, object: object).appendingPathComponent(checkpointFolderName, isDirectory: true)
    }

    /// `derived/objects/<id>/reconstruction.json`.
    static func infoURL(_ package: ProjectPackage, object: UUID) -> URL {
        folder(package, object: object).appendingPathComponent(infoFileName, isDirectory: false)
    }

    /// `raw/objects/<id>/Images/`.
    static func imagesURL(_ package: ProjectPackage, object: UUID) -> URL {
        package.rawObjectURL(object).appendingPathComponent(ObjectScanFolders.imagesFolderName, isDirectory: true)
    }

    /// The model URL when the file exists, else nil.
    static func modelURLIfPresent(_ package: ProjectPackage, object: UUID) -> URL? {
        let url = modelURL(package, object: object)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `reconstruction.json`, or nil when absent or unreadable (logged when unreadable).
    static func loadInfo(_ package: ProjectPackage, object: UUID) -> PhotogrammetryInfo? {
        let url = infoURL(package, object: object)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try ProjectStore.readJSON(PhotogrammetryInfo.self, from: url, maxBytes: maxInfoBytes)
        } catch {
            ObjectCaptureSignals.log("object \(object): unreadable \(infoFileName) (\(StoreFiles.describe(error)))")
            return nil
        }
    }

    /// `PhotogrammetrySession.limits` on this device (RESEARCH 3.3 recommended 1: read at
    /// runtime, never hard-coded).
    static func deviceLimits() -> (images: Int, dimension: Int) {
        let limits = PhotogrammetrySession.limits
        return (images: limits.maximumNumberOfInputImages, dimension: limits.maximumInputImageDimension)
    }
}

/// Main actor, observed by ObjectUI's processing view.
@MainActor final class PhotogrammetryMonitor: ObservableObject {
    /// The one monitor PhotogrammetryStep posts to.
    static let shared = PhotogrammetryMonitor()
    /// Latest progress per object being reconstructed.
    @Published private(set) var progress: [UUID: PhotogrammetryProgress] = [:]

    /// Creates an empty monitor (the app uses `shared`).
    init() {}

    /// Stores the latest progress of an object (published only when it changed).
    func update(_ value: PhotogrammetryProgress) {
        guard progress[value.objectID] != value else { return }
        progress[value.objectID] = value
    }

    /// Forgets an object's progress (the reconstruction ended).
    func clear(_ objectID: UUID) {
        guard progress[objectID] != nil else { return }
        progress[objectID] = nil
    }

    /// Any thread: `DispatchQueue.main.async { MainActor.assumeIsolated { shared.update(value) } }`,
    /// throttled by the caller to 4 per second.
    nonisolated static func post(_ value: PhotogrammetryProgress) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PhotogrammetryMonitor.shared.update(value)
            }
        }
    }

    /// Any thread: clears an object's progress on main.
    nonisolated static func postClear(_ objectID: UUID) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PhotogrammetryMonitor.shared.clear(objectID)
            }
        }
    }
}
