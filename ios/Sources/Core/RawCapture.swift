import Foundation
import simd

/// One accepted keyframe (one line of `keyframes.jsonl`).
struct KeyframeRecord: Codable, Equatable, Sendable {
    /// Sequential index within the scan, also the file stem of image and depth.
    var index: Int
    /// `ARFrame.timestamp`, seconds.
    var timestamp: Double
    /// Camera to world (`ARCamera.transform`) in the capture frame.
    var transform: Transform4
    /// Intrinsics of the stored image (`ARCamera.intrinsics`, per frame).
    var intrinsics: Intrinsics
    /// Image file name relative to the scan folder.
    var imageFile: String
    /// Depth file name relative to the scan folder, when depth was present.
    var depthFile: String?
    /// `ARCamera.exposureDuration`, seconds.
    var exposureDuration: Double
    /// `ARCamera.exposureOffset`.
    var exposureOffset: Float
    /// `ARLightEstimate.ambientIntensity`, lumens.
    var ambientIntensity: Float
    /// Camera angular speed when captured, radians per second (blur indicator).
    var angularSpeed: Float
    /// True when tracking was `.normal`.
    var trackingNormal: Bool
}

/// A full-frame photo the user took during a scan (one line of `photos.jsonl`).
struct PhotoPin: Codable, Equatable, Identifiable, Sendable {
    /// Photo identifier.
    var id: UUID
    /// `ARFrame.timestamp`, seconds.
    var timestamp: Double
    /// Camera to world when taken.
    var transform: Transform4
    /// Intrinsics of the stored image.
    var intrinsics: Intrinsics
    /// Image file name relative to the scan folder.
    var imageFile: String
    /// User note (user text, may be empty).
    var note: String
}

/// A timeline event during capture (one line of `events.jsonl`).
struct CaptureEvent: Codable, Equatable, Sendable {
    /// Seconds since the scan started.
    var t: Double
    /// Event kind.
    var kind: CaptureEventKind
    /// Free-form diagnostic detail (for logs, never shown as UI text).
    var detail: String
}

/// Kinds of capture events. Raw values are persisted.
enum CaptureEventKind: String, Codable, CaseIterable, Sendable {
    case tracking, thermal, instruction, error, config, memory, degraded, relocalization, note
}

/// Contents of `session.json`: facts about one ARKit session.
struct CaptureSessionRecord: Codable, Equatable, Identifiable, Sendable {
    /// Session identifier.
    var id: UUID
    /// iOS version string, for example "18.3.2".
    var osVersion: String
    /// Generic device class (`UIDevice.current.model`, for example "iPhone"). Never a
    /// hardware identifier, name or serial.
    var deviceClass: String
    /// Effective ARKit configuration lines logged after the session started (D22).
    var configLog: [String]
}

/// Contents of `roomlog.json`: RoomPlan capture diagnostics for one room.
struct RoomCaptureLog: Codable, Equatable, Sendable {
    /// Capture duration, seconds.
    var seconds: Double
    /// Seconds spent in each RoomPlan instruction, keyed by instruction name.
    var instructionSeconds: [String: Double]
    /// Final error description, if the capture ended with one.
    var error: String?
    /// Number of relocalizations during the room.
    var relocalizations: Int
    /// Fraction of the capture time with limited tracking, 0...1.
    var limitedTrackingFraction: Double
    /// Which data streams survived (D16).
    var degraded: DegradedMode
}

/// Which capture streams worked (D16). Raw values are persisted.
enum DegradedMode: String, Codable, CaseIterable, Sendable {
    /// Depth, mesh and RoomPlan all delivered.
    case allGood
    /// No scene depth: coverage falls back to mesh-face sampling.
    case depthStripped
    /// No mesh anchors: the room switches to the two-pass fallback.
    case meshStripped
    /// RoomPlan failed: space scan outputs only.
    case roomPlanFailed
}

/// One file listed in a seal.
struct SealEntry: Codable, Equatable, Sendable {
    /// Path relative to the sealed folder, "/" separated.
    var path: String
    /// Size in bytes when sealed.
    var size: Int64
}

/// Contents of `SEAL.json`, written when a raw scan folder is finished (D5). Opening a
/// project verifies sizes against it and logs mismatches.
struct SealFile: Codable, Equatable, Sendable {
    /// File name of the seal inside a sealed folder.
    static let fileName = "SEAL.json"

    /// When the folder was sealed.
    var sealedAt: Date
    /// Every regular file in the folder except the seal itself, sorted by path.
    var files: [SealEntry]

    /// Total size of all sealed files, bytes.
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Lists every regular file under `folder` (recursively, excluding `SEAL.json`).
    static func make(folder: URL, now: Date = Date()) throws -> SealFile {
        let fm = FileManager.default
        var entries: [SealEntry] = []
        for relative in try fm.subpathsOfDirectory(atPath: folder.path) where relative != fileName {
            let attributes = try fm.attributesOfItem(atPath: folder.appendingPathComponent(relative).path)
            guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(SealEntry(path: relative, size: size))
        }
        entries.sort { $0.path < $1.path }
        return SealFile(sealedAt: now, files: entries)
    }

    /// Compares the folder with the seal. Returns one diagnostic line per missing file,
    /// size mismatch or unexpected new file; empty when everything matches.
    func verify(folder: URL) -> [String] {
        var problems: [String] = []
        let current: SealFile
        do {
            current = try SealFile.make(folder: folder)
        } catch {
            return ["cannot list \(folder.lastPathComponent): \(error.localizedDescription)"]
        }
        var actual: [String: Int64] = [:]
        for entry in current.files { actual[entry.path] = entry.size }
        var expected = Set<String>()
        for entry in files {
            expected.insert(entry.path)
            guard let size = actual[entry.path] else {
                problems.append("missing \(entry.path)")
                continue
            }
            if size != entry.size {
                problems.append("size mismatch \(entry.path): sealed \(entry.size), found \(size)")
            }
        }
        for entry in current.files where !expected.contains(entry.path) {
            problems.append("unexpected \(entry.path)")
        }
        return problems
    }
}

/// One 10 Hz pose sample of the binary pose track `poses.ptrk` (D8). Binary only, never
/// JSON; see `PoseTrackFile`.
struct PoseSample: Equatable {
    /// `ARFrame.timestamp`, seconds.
    var timestamp: Double
    /// Camera to world.
    var transform: simd_float4x4
    /// Tracking state code: 0 not available, 1 limited, 2 normal.
    var tracking: UInt8
    /// Thermal state code: `ProcessInfo.ThermalState.rawValue` clamped to 0...255.
    var thermal: UInt8
    /// `ARCamera.exposureDuration`, seconds.
    var exposureDuration: Float

    /// Creates a sample.
    init(timestamp: Double, transform: simd_float4x4, tracking: UInt8, thermal: UInt8, exposureDuration: Float) {
        self.timestamp = timestamp
        self.transform = transform
        self.tracking = tracking
        self.thermal = thermal
        self.exposureDuration = exposureDuration
    }

    /// Field-wise equality (the transform compared element by element).
    static func == (lhs: PoseSample, rhs: PoseSample) -> Bool {
        lhs.timestamp == rhs.timestamp && Transform4(lhs.transform) == Transform4(rhs.transform)
            && lhs.tracking == rhs.tracking && lhs.thermal == rhs.thermal
            && lhs.exposureDuration == rhs.exposureDuration
    }
}
