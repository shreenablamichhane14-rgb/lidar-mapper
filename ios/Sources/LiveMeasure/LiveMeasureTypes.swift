import Foundation
import simd

// Value types of Quick Measure (MODULES 3.36): placed points, measured segments, the screen
// phase, the save outcome and the diagnostics log lines. Plain values, usable on any queue.

/// One placed point.
struct LiveMeasurePoint {
    /// World position, meters.
    var position: SIMD3<Float>
    /// What it snapped to (stored in `MeasurementRecord.snaps`).
    var snap: SnapKind
    /// Capture evidence at the moment it was placed.
    var evidence: MeasurementEvidence
    /// The "Snapped to" tag it was placed with; later points snapping to it show the same tag.
    var tag: LiveMeasureSnapTag? = nil
}

/// One measured distance.
struct LiveMeasureSegment: Identifiable {
    /// Record identifier.
    let id: UUID
    /// The two ends.
    var start: LiveMeasurePoint
    var end: LiveMeasurePoint
    /// `ConfidenceAdapter.distance(start:end:length:)`.
    var value: MeasuredValue
    /// When the segment was closed.
    var createdAt: Date

    /// kind .distance, the two points and snaps, source .live, name "", roomID nil.
    func record() -> MeasurementRecord {
        MeasurementRecord(id: id, kind: .distance, points: [Vec3(start.position), Vec3(end.position)],
                          snaps: [start.snap, end.snap], result: value, source: .live, name: "",
                          roomID: nil, createdAt: createdAt)
    }

    /// The distance between two points with its confidence (`ConfidenceAdapter.distance`).
    static func value(from start: LiveMeasurePoint, to end: LiveMeasurePoint) -> MeasuredValue {
        let length = simd_distance(start.position, end.position)
        return ConfidenceAdapter.distance(start: start.evidence, end: end.evidence, length: length)
    }

    /// A segment between two points, its value through `value(from:to:)`.
    static func make(start: LiveMeasurePoint, end: LiveMeasurePoint, id: UUID, createdAt: Date) -> LiveMeasureSegment {
        LiveMeasureSegment(id: id, start: start, end: end, value: value(from: start, to: end), createdAt: createdAt)
    }
}

/// Screen state of Quick Measure.
enum LiveMeasurePhase: Equatable {
    /// Before `start()`; measuring; creating the project; saved as project `id`; cannot measure (message).
    case starting, measuring, saving, saved(UUID), failed(String)
}

/// Result of `LiveMeasureModel.performSave()`.
enum LiveMeasureSaveOutcome: Equatable {
    /// The project exists, quick.json is sealed and the project is `.ready`.
    case saved(UUID)
    /// Nothing was kept (a created project was deleted again).
    case failed
}

/// Diagnostics log lines of Quick Measure (category "livemeasure"). Any thread; never UI text.
enum LiveMeasureLog {
    /// One line in the app log.
    static func write(_ message: String) {
        LogStore.shared.write(message, category: "livemeasure")
    }

    /// "start (x, y, z) corner, end (x, y, z) plane, value 1.2345 m, sigma 0.0061 m".
    static func describe(_ record: MeasurementRecord) -> String {
        let points = record.points.map { point -> String in
            String(format: "(%.4f, %.4f, %.4f)", Double(point.x), Double(point.y), Double(point.z))
        }
        let snaps = record.snaps.map { $0.rawValue }
        let start = points.first ?? "-"
        let end = points.count > 1 ? points[1] : "-"
        let startSnap = snaps.first ?? "-"
        let endSnap = snaps.count > 1 ? snaps[1] : "-"
        let value = String(format: "%.4f", record.result.value)
        let sigma = record.result.sigma.map { String(format: "%.4f", $0) } ?? "none"
        return "start \(start) \(startSnap), end \(end) \(endSnap), value \(value) m, sigma \(sigma) m"
    }
}
