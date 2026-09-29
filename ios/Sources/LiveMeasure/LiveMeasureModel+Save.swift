import Foundation
import RealityKit
import UIKit

// Save of Quick Measure (MODULES 3.36): the project is created only now, named at creation as
// ScanUI names rooms ("Measurement Sep 28"); quick.json is written and sealed off main; the
// project becomes `.ready` as soon as the seal is on disk (a Quick Measure project has nothing
// to process); the thumbnail is the live camera snapshot with the distances drawn on it (best
// effort). A failure deletes the new project and leaves the distances on screen.

extension LiveMeasureModel {
    /// Longest wait for `ARView.snapshot`, seconds.
    static let snapshotTimeout: Double = 2

    /// Main (file work detached). Snapshot, `ProjectLibrary.shared.create(kind: .quickMeasure, name:)`,
    /// `QuickMeasureStore.save`, status `.ready`, one log line per measurement, thumbnail. Returns
    /// `.failed` after deleting the project when any required step fails.
    func performSave() async -> LiveMeasureSaveOutcome {
        let lines = thumbnailLines()
        let viewSize = arView?.bounds.size ?? .zero
        let image = await captureSnapshot(timeout: LiveMeasureModel.snapshotTimeout)
        let records = segments.map { $0.record() }
        let now = Date()
        let name = ScanFlowModel.defaultProjectName(mode: .quickMeasure, now: now)
        let created: (ProjectPackage, ProjectManifest)
        do {
            created = try ProjectLibrary.shared.create(kind: .quickMeasure, name: name)
        } catch {
            LiveMeasureLog.write("save failed: create project: \(error)")
            return .failed
        }
        let package = created.0
        let id = created.1.id
        let writeError = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try QuickMeasureStore.save(records, to: package, now: now)
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        if let writeError {
            LiveMeasureLog.write("save failed: quick.json: \(writeError)")
            deleteUnsavedProject(id)
            return .failed
        }
        do {
            try ProjectLibrary.shared.update(id) { manifest in
                manifest.status = .ready
            }
        } catch {
            LiveMeasureLog.write("save failed: status update: \(error)")
            deleteUnsavedProject(id)
            return .failed
        }
        for (index, record) in records.enumerated() {
            LiveMeasureLog.write("saved measurement \(index + 1) of \(records.count) in \(id): "
                                 + LiveMeasureLog.describe(record))
        }
        if let image {
            await writeThumbnail(image, lines: lines, viewSize: viewSize, to: package)
        } else {
            LiveMeasureLog.write("thumbnail skipped: no snapshot")
        }
        return .saved(id)
    }

    /// Removes a project created by a failed save (logged when that fails too).
    private func deleteUnsavedProject(_ id: UUID) {
        do {
            try ProjectLibrary.shared.delete(id)
        } catch {
            LiveMeasureLog.write("could not delete the unsaved project \(id): \(error)")
        }
    }

    /// The on-screen lines of every distance whose two ends are projected (view points).
    private func thumbnailLines() -> [LiveMeasureThumbnail.Line] {
        var lines: [LiveMeasureThumbnail.Line] = []
        for segment in segments {
            guard let points = screenPoints[segment.id], let start = points.start, let end = points.end else { continue }
            lines.append(LiveMeasureThumbnail.Line(start: start, end: end))
        }
        return lines
    }

    /// `arView.snapshot(saveToHDR: false)`, or nil without a view, on failure or after `timeout`.
    private func captureSnapshot(timeout: Double) async -> UIImage? {
        guard let view = arView, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let gate = LiveMeasureOnceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            view.snapshot(saveToHDR: false) { snapshot in
                if gate.claim() { continuation.resume(returning: snapshot) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Encodes the thumbnail off main and writes it with `ProjectStore.writeData(_:to:)` into
    /// `package.thumbnailURL` (best effort, logged).
    private func writeThumbnail(_ image: UIImage, lines: [LiveMeasureThumbnail.Line], viewSize: CGSize,
                                to package: ProjectPackage) async {
        let box = LiveMeasureImageBox(image: image)
        let url = package.thumbnailURL
        let result = await Task.detached(priority: .utility) { () -> String in
            guard let data = LiveMeasureThumbnail.jpeg(box.image, lines: lines, viewSize: viewSize) else {
                return "encoding failed"
            }
            do {
                try ProjectStore.writeData(data, to: url, createParents: false)
                return "written, \(data.count) bytes"
            } catch {
                return "write failed: \(error)"
            }
        }.value
        LiveMeasureLog.write("thumbnail \(result)")
    }
}

/// Resumes a continuation at most once (snapshot completion against its timeout). Thread-safe.
final class LiveMeasureOnceGate: @unchecked Sendable {
    /// Guards `used`.
    private let lock = NSLock()
    /// True after the first claim.
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

/// Carries a snapshot into the detached encoding task (the image is never mutated).
struct LiveMeasureImageBox: @unchecked Sendable {
    /// The snapshot.
    let image: UIImage
}

/// The Quick Measure thumbnail: the camera snapshot scaled down, with each distance drawn as a
/// white line with a dark outline and end dots. Pure drawing, safe off main.
enum LiveMeasureThumbnail {
    /// One distance in view points.
    struct Line: Sendable {
        /// Projected ends.
        var start: CGPoint
        var end: CGPoint
    }

    /// Longest side of the thumbnail, pixels.
    static let maxPixel: CGFloat = 1024
    /// JPEG quality.
    static let quality: CGFloat = 0.7

    /// JPEG of `image` (a snapshot of a view of `viewSize` points) with `lines` drawn on it; nil
    /// for an empty image.
    static func jpeg(_ image: UIImage, lines: [Line], viewSize: CGSize) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth >= 1, pixelHeight >= 1 else { return nil }
        let factor = min(1, maxPixel / max(pixelWidth, pixelHeight))
        let size = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            guard viewSize.width > 0, viewSize.height > 0, !lines.isEmpty else { return }
            let scaleX = size.width / viewSize.width
            let scaleY = size.height / viewSize.height
            let weight = max(2, size.width / 250)
            let cg = context.cgContext
            cg.setLineCap(.round)
            for line in lines {
                let a = CGPoint(x: line.start.x * scaleX, y: line.start.y * scaleY)
                let b = CGPoint(x: line.end.x * scaleX, y: line.end.y * scaleY)
                LiveMeasureThumbnail.stroke(cg, from: a, to: b, color: UIColor.black.withAlphaComponent(0.55), width: weight * 2.2)
                LiveMeasureThumbnail.stroke(cg, from: a, to: b, color: UIColor.white, width: weight)
                for end in [a, b] {
                    let radius = weight * 1.6
                    cg.setFillColor(UIColor.white.cgColor)
                    cg.fillEllipse(in: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }

    /// One straight stroke.
    private static func stroke(_ cg: CGContext, from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.move(to: a)
        cg.addLine(to: b)
        cg.strokePath()
    }
}
