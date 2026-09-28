import ARKit
import UIKit

/// First-run and per-second diagnostics (D22), logged with category "capture". Hub queue
/// (except `init`). Answers the open device questions of ARCHITECTURE 15: effective
/// configuration, first-frame sizes and formats, depth share, mesh anchors, delegate
/// identity, memory, confidence histogram and the projection round trip.
final class CaptureDiagnostics {
    /// Effective ARKit configuration lines (and the first-frame line) for session.json.
    private(set) var configLog: [String] = []
    /// iOS version string, for example "18.3.2".
    private let osVersion: String
    /// Generic device class (`UIDevice.current.model`), never a name or identifier.
    private let deviceClass: String
    /// True once the first frame was described.
    private var firstFrameLogged = false
    /// Start of the current one-second window (frame timebase).
    private var windowStart: TimeInterval?
    /// Frames in the current window.
    private var windowFrames = 0
    /// Frames with scene depth in the current window.
    private var windowDepthFrames = 0
    /// Per-second lines written so far.
    private var ticks = 0

    /// Most lines kept in `configLog` (the file stays small even after many re-applies).
    static let maxConfigLines = 400
    /// Every tick is logged for this many seconds, then one in `laterTickEvery`.
    static let verboseTicks = 30
    /// Logging interval in ticks after the verbose period.
    static let laterTickEvery = 5

    /// Main actor (reads `UIDevice.current.model` and `systemVersion`).
    @MainActor init() {
        let device = UIDevice.current
        osVersion = device.systemVersion
        deviceClass = device.model
    }

    /// Logs the configuration line by line under `label` and appends the lines to `configLog`.
    func logConfiguration(_ configuration: ARConfiguration?, label: String) {
        let lines = ScanConfigurationFactory.describe(configuration)
        appendConfigLines(lines.map { "\(label): \($0)" })
        CaptureCoreLog.write("config [\(label)] " + lines.joined(separator: "; "))
    }

    /// Image and depth sizes and pixel formats, camera resolution and intrinsics of the first
    /// frame (fps is measured by `tick`). Later calls do nothing.
    func logFirstFrame(_ frame: ARFrame) {
        guard !firstFrameLogged else { return }
        firstFrameLogged = true
        let image = frame.capturedImage
        var parts: [String] = []
        parts.append("image \(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) "
                     + "\(CaptureDiagnostics.fourCC(CVPixelBufferGetPixelFormatType(image))) "
                     + "planes \(CVPixelBufferGetPlaneCount(image))")
        let k = ARFrameReading.intrinsics(of: frame.camera)
        parts.append("camera \(k.width)x\(k.height) fx \(k.fx) fy \(k.fy) cx \(k.cx) cy \(k.cy)")
        if let depth = frame.sceneDepth {
            let map = depth.depthMap
            parts.append("depth \(CVPixelBufferGetWidth(map))x\(CVPixelBufferGetHeight(map)) "
                         + CaptureDiagnostics.fourCC(CVPixelBufferGetPixelFormatType(map)))
            if let confidence = depth.confidenceMap {
                parts.append("confidence \(CVPixelBufferGetWidth(confidence))x\(CVPixelBufferGetHeight(confidence)) "
                             + CaptureDiagnostics.fourCC(CVPixelBufferGetPixelFormatType(confidence)))
            } else {
                parts.append("confidence none")
            }
        } else {
            parts.append("depth none")
        }
        parts.append("lightEstimate \(frame.lightEstimate != nil)")
        let line = "first frame: " + parts.joined(separator: ", ")
        appendConfigLines([line])
        CaptureCoreLog.write(line)
    }

    /// Call once per frame. Counts frames and depth frames and, once a second, logs fps, the
    /// share of frames with depth, the mesh anchor count, delegate identity, available memory,
    /// the confidence histogram and the projection round trip.
    func tick(frame: ARFrame, meshAnchors: Int, delegateIsHub: Bool, availableMemory: UInt64) {
        let now = frame.timestamp
        guard let start = windowStart else {
            windowStart = now
            windowFrames = 1
            windowDepthFrames = frame.sceneDepth == nil ? 0 : 1
            return
        }
        windowFrames += 1
        if frame.sceneDepth != nil { windowDepthFrames += 1 }
        let seconds = now - start
        guard seconds >= 1 else { return }
        ticks += 1
        let verbose = ticks <= CaptureDiagnostics.verboseTicks || ticks % CaptureDiagnostics.laterTickEvery == 0
        if verbose {
            let fps = Double(windowFrames) / seconds
            let depthPercent = windowDepthFrames * 100 / max(1, windowFrames)
            var parts = ["fps \(String(format: "%.1f", fps))", "depth \(depthPercent)%",
                         "anchors \(meshAnchors)", "delegateIsHub \(delegateIsHub)",
                         "memory \(availableMemory / 1_000_000) MB"]
            if let histogram = ARFrameReading.confidenceHistogram(of: frame) {
                parts.append("confidence low \(histogram.low) medium \(histogram.medium) high \(histogram.high)")
            }
            if let error = projectionRoundTrip(frame) {
                parts.append("roundTrip \(String(format: "%.4f", Double(error))) px")
            }
            CaptureCoreLog.write("tick " + parts.joined(separator: ", "))
        }
        windowStart = now
        windowFrames = 0
        windowDepthFrames = 0
    }

    /// Unprojects the center depth pixel and projects it back; error in pixels (target < 0.5).
    /// The depth pixel is unprojected with the image intrinsics scaled to the depth map, moved
    /// to world space with the camera pose, projected with the full-image intrinsics and scaled
    /// back to depth pixels, so it checks the Intrinsics scaling and axis conventions (D22).
    func projectionRoundTrip(_ frame: ARFrame) -> Float? {
        guard let sceneDepth = frame.sceneDepth, let center = ARFrameReading.centerDepth(of: frame) else { return nil }
        let depthWidth = CVPixelBufferGetWidth(sceneDepth.depthMap)
        let depthHeight = CVPixelBufferGetHeight(sceneDepth.depthMap)
        let full = ARFrameReading.intrinsics(of: frame.camera)
        guard depthWidth > 0, depthHeight > 0, full.width > 0, full.height > 0 else { return nil }
        let scaled = full.scaled(toWidth: depthWidth, height: depthHeight)
        let pixel = SIMD2<Float>(Float(depthWidth / 2) + 0.5, Float(depthHeight / 2) + 0.5)
        let cameraPoint = scaled.unproject(pixel: pixel, depth: center.distance)
        let cameraToWorld = frame.camera.transform
        let world4 = simd_mul(cameraToWorld, SIMD4<Float>(cameraPoint, 1))
        let world = SIMD3<Float>(world4.x, world4.y, world4.z)
        guard let imagePixel = full.project(worldPoint: world, cameraToWorld: cameraToWorld) else { return nil }
        let sx = Float(depthWidth) / Float(full.width)
        let sy = Float(depthHeight) / Float(full.height)
        let back = SIMD2<Float>(imagePixel.x * sx, imagePixel.y * sy)
        let error = simd_length(back - pixel)
        return error.isFinite ? error : nil
    }

    /// Facts for session.json: osVersion, deviceClass, configLog.
    func sessionRecord(id: UUID) -> CaptureSessionRecord {
        CaptureSessionRecord(id: id, osVersion: osVersion, deviceClass: deviceClass, configLog: configLog)
    }

    /// Appends lines, keeping at most `maxConfigLines` (the oldest first lines are kept, the
    /// newest dropped, so the configuration at start always survives).
    private func appendConfigLines(_ lines: [String]) {
        let room = CaptureDiagnostics.maxConfigLines - configLog.count
        guard room > 0 else { return }
        configLog.append(contentsOf: lines.prefix(room))
    }

    /// A pixel format code as its four characters ("fdep", "L008", "420f"), or the number
    /// when a byte is not printable.
    static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(code)" }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Capture log helpers: every line goes to `LogStore` with category "capture"; `once` writes
/// a given key only the first time (thread-safe), for per-frame problems.
enum CaptureCoreLog {
    /// Guards `loggedKeys`.
    private static let lock = NSLock()
    /// Keys already written by `once`.
    private static var loggedKeys = Set<String>()

    /// Writes one line with category "capture".
    static func write(_ message: String) {
        LogStore.shared.write(message, category: "capture")
    }

    /// Writes `message` the first time `key` is seen in this app run.
    static func once(_ key: String, _ message: String) {
        lock.lock()
        let isNew = loggedKeys.insert(key).inserted
        lock.unlock()
        if isNew { write(message) }
    }
}
