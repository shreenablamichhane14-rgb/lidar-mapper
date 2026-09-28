import Foundation
import simd

// Value types of the Quality module (docs/MODULES.md 3.22): the stored evaluation of one room
// (`derived/rooms/<r>/quality.json`), its missing areas, the Coverage boundary of a clean room
// with the wall mapping the scorer needs, and the diagnostics one evaluation reports for logs
// and the self-test. Pure values, safe on any queue.

/// One unobserved region of the expected room shell (Coverage `MissingArea` after windows,
/// doors and openings were taken out, D19), in its Codable form for `quality.json`. Results
/// draws one red square per record (3D Clean, Raw Scan) and build 5's Show Missing Areas tour
/// walks the user to `suggestedViewpoint`.
struct MissingAreaRecord: Codable, Equatable, Identifiable, Sendable {
    /// Position in the evaluation's list (0 is the largest area).
    var id: Int
    /// Area-weighted centroid, world meters.
    var centroid: Vec3
    /// Unit normal of the surface, pointing into the room.
    var normal: Vec3
    /// Area in square meters.
    var area: Float
    /// `SurfaceClass` raw value (1 wall, 2 floor, 3 ceiling).
    var surface: UInt8
    /// Where to stand to see the area: eye height, inside the floor polygon, world meters.
    var suggestedViewpoint: Vec3
}

extension MissingAreaRecord {
    /// A record from a Coverage missing area.
    init(id: Int, _ area: MissingArea) {
        self.init(id: id, centroid: Vec3(area.centroid), normal: Vec3(area.normal), area: area.area,
                  surface: area.surface.rawValue, suggestedViewpoint: Vec3(area.suggestedViewpoint))
    }

    /// The Coverage surface class (`.none` for an unknown raw value).
    var surfaceClass: SurfaceClass {
        SurfaceClass(rawValue: surface) ?? SurfaceClass.none
    }
}

/// The scan quality evaluation of one room (SCAN QUALITY SYSTEM), stored as
/// `derived/rooms/<r>/quality.json` by `QualityStore`. `summary` holds the 0...1 scores and the
/// verdict shown on the quality sheet; `evidence` feeds MeasureCore's measurement confidence.
struct QualityEvaluation: Codable, Equatable, Sendable {
    /// `RoomRecord.id` of the evaluated room.
    var roomID: UUID
    /// 0...1 values and verdict (Core).
    var summary: QualitySummary
    /// Missing areas, largest first (windows, doors and openings excluded).
    var missingAreas: [MissingAreaRecord]
    /// Which capture streams worked; `.roomPlanFailed` whenever no usable room was available.
    var degraded: DegradedMode
    /// Per-wall capture evidence for MeasureCore.
    var evidence: RoomEvidence
    /// Share of keyframes taken in the dark or with a long exposure (excluded from the texture grid).
    var darkKeyframeFraction: Float
    /// `QualityStep.inputHash`: InputHasher over the room seal plus the room's buildRoom and
    /// consolidateMesh stamp hashes ("-" when absent). The quick evaluation at Done stores
    /// extra ["done"] instead, so the pipeline step always supersedes it.
    var inputHash: String
    /// When the evaluation ran.
    var evaluatedAt: Date
}

extension QualityEvaluation {
    /// The same evaluation with every non-finite float replaced (NaN and infinities become 0,
    /// wall distances fall back to `ConfidenceAdapter.defaultDistance`), because JSON cannot
    /// carry them. The evaluator never produces such values; this is the storage guard.
    func sanitizedForStorage() -> QualityEvaluation {
        var copy = self
        copy.summary = QualitySummary(shape: QualityMath.finite(summary.shape),
                                      walls: QualityMath.finite(summary.walls),
                                      floor: QualityMath.finite(summary.floor),
                                      ceiling: QualityMath.finite(summary.ceiling),
                                      texture: QualityMath.finite(summary.texture),
                                      missingAreas: Swift.max(0, summary.missingAreas))
        copy.missingAreas = missingAreas.map { record in
            var r = record
            r.centroid = QualityMath.finite(r.centroid)
            r.normal = QualityMath.finite(r.normal)
            r.area = QualityMath.finite(r.area)
            r.suggestedViewpoint = QualityMath.finite(r.suggestedViewpoint)
            return r
        }
        copy.evidence.trackingNormalFraction = QualityMath.unit(evidence.trackingNormalFraction)
        copy.evidence.walls = evidence.walls.map { wall in
            var w = wall
            if !(w.medianDistance.isFinite && w.medianDistance > 0) { w.medianDistance = ConfidenceAdapter.defaultDistance }
            w.observations = Swift.max(0, w.observations)
            return w
        }
        copy.darkKeyframeFraction = QualityMath.unit(darkKeyframeFraction)
        return copy
    }
}

/// A clean room's expected shell in Coverage's world (x, z) convention, plus what the scorer
/// needs to map Coverage walls back to clean walls: a curved wall becomes several straight
/// Coverage walls, all pointing at the same clean wall.
struct QualityBoundary {
    /// Walls, floor and ceiling for `ExpectedSurfaces`.
    var boundary: CoverageRoomBoundary
    /// Index into `CleanRoom.walls` of each Coverage wall (same count as `boundary.walls`).
    var wallIndex: [Int]
    /// Floor elevation (world y) that opening sill and head heights are measured from.
    var floorY: Float
}

/// What one evaluation did, for the log line of `evaluateSealedRoom` and `QualityStep` and for
/// the self-test. Not stored.
struct QualityScoreDetail {
    /// Observed fraction of each clean wall (samples inside openings dropped); nil for a wall
    /// with no expected samples.
    var wallFractions: [Float?] = []
    /// Soft factor applied to each clean wall (confidence and completed edges).
    var wallFactors: [Float] = []
    /// Expected area of each clean wall after openings were dropped, square meters.
    var wallExpectedAreas: [Float] = []
    /// Wall samples dropped because they lie inside a door, window or opening.
    var excludedSampleCount = 0
    /// Faces the grids were fed.
    var faceCount = 0
    /// Mesh faces whose cross-product normal pointed away from the nearest camera and was flipped.
    var flippedFaceCount = 0
    /// Every n-th mesh face was used (1 = all); above the face limit the mesh is thinned evenly.
    var faceStride = 1
    /// True when the mesh had no usable faces and the expected shell stood in for it.
    var usedShellFaces = false
    /// Geometry observations integrated.
    var geometryObservationCount = 0
    /// Texture observations integrated.
    var textureObservationCount = 0
    /// Integrate calls that stopped at Coverage's per-call face cap.
    var truncatedIntegrations = 0
    /// Coverage's own missing clusters before openings were taken out (self-test comparison).
    var coverageMissing: [MissingArea] = []
    /// True when the room was missing or unusable and the no-room path ran.
    var usedNoRoomPath = false
}

/// Small numeric helpers shared by the Quality files.
enum QualityMath {
    /// `value` when finite, else 0.
    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// `value` when finite, else 0.
    static func finite(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    /// Every component finite (non-finite ones become 0).
    static func finite(_ v: Vec3) -> Vec3 {
        Vec3(x: finite(v.x), y: finite(v.y), z: finite(v.z))
    }

    /// Clamped to 0...1; NaN becomes 0.
    static func unit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    /// Clamped to 0...1; NaN becomes 0.
    static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    /// Median of finite values (mean of the two middle values for an even count); nil when empty.
    static func median(_ values: [Float]) -> Float? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    /// Lower median of counts (the lower middle value for an even count, the conservative side,
    /// as `RoomEvidence.typicalWall` does); nil when empty.
    static func lowerMedian(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// True when every element of the matrix is finite.
    static func isFinite(_ m: simd_float4x4) -> Bool {
        let c = m.columns
        let a = c.0.x.isFinite && c.0.y.isFinite && c.0.z.isFinite && c.0.w.isFinite
        let b = c.1.x.isFinite && c.1.y.isFinite && c.1.z.isFinite && c.1.w.isFinite
        let d = c.2.x.isFinite && c.2.y.isFinite && c.2.z.isFinite && c.2.w.isFinite
        let e = c.3.x.isFinite && c.3.y.isFinite && c.3.z.isFinite && c.3.w.isFinite
        return a && b && d && e
    }

    /// Translation column of a transform.
    static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}
