import Foundation
import simd

// Scan quality summary for the SCAN QUALITY screen (docs/SPEC.txt, SCAN QUALITY SYSTEM):
//
//   Geometry: 94%   Walls: 100%   Floor: 98%   Ceiling: 82%   Textures: 91%   Missing areas: 3
//
// This file only computes numbers. The UI formats them (percent text comes from Copy.swift)
// and uses `missingAreas` for SHOW MISSING AREAS.
//
// Rules (all percentages are clamped to 0...100; NaN or infinite values become 0):
// 1. With a room boundary, walls / floor / ceiling are 100 * observedArea / expectedArea from
//    `ExpectedSurfaces.evaluate(room:grid:)`. A class with no expected area reports 100, because
//    nothing is missing there (for example a room without a ceiling polygon and zero height).
// 2. With a room boundary, geometry is the area-weighted mean over walls, floor and ceiling:
//    100 * (sum of observed area) / (sum of expected area), 100 if nothing is expected at all.
//    This weights a 20 m^2 floor more than a 2 m^2 wall strip, which matches how much of the
//    model is actually missing.
// 3. Without a room boundary (object scans, or before RoomPlan has produced walls), walls / floor /
//    ceiling come from `grid.observedAreaFraction(faces:surface:)` for that class, and geometry
//    from the same call over all faces (surface nil). Only captured faces exist in that case, so
//    the numbers describe how well the captured mesh has been seen, not completeness.
// 4. Textures is always 100 * `grid.goodFaceAreaFraction(faces:)`: the area-weighted share of mesh
//    faces with at least one good observation (quality >= CoverageGrid.goodQuality), which is
//    what a keyframe needs to give a sharp texture. It does not depend on the room.
// 5. Missing areas come from `ExpectedSurfaces.evaluate` (already sorted by area, largest first)
//    and are empty without a room boundary.

/// Summary of scan completeness shown before the user finishes a scan.
/// All percentages are 0...100. `missingAreas` is sorted by area, largest first.
struct ScanQualityReport {
    /// Area-weighted share of all expected surfaces observed (percent).
    var geometry: Float
    /// Share of expected wall area observed (percent).
    var walls: Float
    /// Share of expected floor area observed (percent).
    var floor: Float
    /// Share of expected ceiling area observed (percent).
    var ceiling: Float
    /// Area-weighted share of mesh faces with at least one good observation (percent).
    var textures: Float
    /// Unobserved regions of the expected room shell, largest first.
    var missingAreas: [MissingArea]
}

extension ScanQualityReport {
    /// Number of missing areas, for the "Missing areas: N" line.
    var missingAreaCount: Int { missingAreas.count }

    /// True when every percentage is at least `threshold` and there are no missing areas.
    /// The caller decides the threshold; the engine does not gate finishing.
    func meetsAll(threshold: Float) -> Bool {
        return geometry >= threshold && walls >= threshold && floor >= threshold
            && ceiling >= threshold && textures >= threshold && missingAreas.isEmpty
    }

    /// An empty report: nothing scanned, no missing areas known.
    static let empty = ScanQualityReport(geometry: 0, walls: 0, floor: 0, ceiling: 0,
                                         textures: 0, missingAreas: [])
}

/// Computes `ScanQualityReport` from the coverage grid, the current mesh faces and an
/// optional room boundary. Stateless and deterministic.
enum ScanQuality {
    /// Percent reported for a class with no expected area (nothing can be missing).
    static let nothingExpectedPercent: Float = 100

    /// Expected areas at or below this (m^2) count as "nothing expected" to avoid dividing by
    /// a rounding residue.
    static let minExpectedArea: Float = 1e-6

    /// Builds the report. See the file header for every rule.
    static func evaluate(grid: CoverageGrid, faces: [CoverageFace],
                         room: CoverageRoomBoundary?) -> ScanQualityReport {
        let textures = sqPercent(fraction: grid.goodFaceAreaFraction(faces: faces))

        guard let room = room else {
            return ScanQualityReport(
                geometry: sqPercent(fraction: grid.observedAreaFraction(faces: faces, surface: nil)),
                walls: sqPercent(fraction: grid.observedAreaFraction(faces: faces, surface: .wall)),
                floor: sqPercent(fraction: grid.observedAreaFraction(faces: faces, surface: .floor)),
                ceiling: sqPercent(fraction: grid.observedAreaFraction(faces: faces, surface: .ceiling)),
                textures: textures,
                missingAreas: [])
        }

        let result = ExpectedSurfaces.evaluate(room: room, grid: grid)
        return report(from: result, textures: textures)
    }

    /// Builds the room-based part of the report from an already computed
    /// `ExpectedSurfacesResult` (so callers that also draw red samples need not evaluate twice).
    /// `textures` is a percentage 0...100 and is clamped.
    static func report(from result: ExpectedSurfacesResult, textures: Float) -> ScanQualityReport {
        let classes: [SurfaceClass] = [.wall, .floor, .ceiling]
        var expectedTotal: Float = 0
        var observedTotal: Float = 0
        for surface in classes {
            let expected = sqSanitize(result.expectedArea[surface] ?? 0)
            // Observed can never exceed expected for the same class.
            let observed = min(sqSanitize(result.observedArea[surface] ?? 0), expected)
            expectedTotal += expected
            observedTotal += observed
        }
        return ScanQualityReport(
            geometry: ratioPercent(observed: observedTotal, expected: expectedTotal),
            walls: classPercent(result, .wall),
            floor: classPercent(result, .floor),
            ceiling: classPercent(result, .ceiling),
            textures: sqClamp(textures),
            missingAreas: result.missing)
    }

    /// Percent of one class: observed / expected, 100 when nothing is expected.
    static func classPercent(_ result: ExpectedSurfacesResult, _ surface: SurfaceClass) -> Float {
        let expected = sqSanitize(result.expectedArea[surface] ?? 0)
        let observed = sqSanitize(result.observedArea[surface] ?? 0)
        return ratioPercent(observed: observed, expected: expected)
    }

    /// 100 * observed / expected clamped to 0...100; `nothingExpectedPercent` when expected
    /// is at or below `minExpectedArea` (division guard).
    static func ratioPercent(observed: Float, expected: Float) -> Float {
        let e = sqSanitize(expected)
        guard e > minExpectedArea else { return nothingExpectedPercent }
        return sqClamp(100 * sqSanitize(observed) / e)
    }
}

/// Converts a 0...1 fraction to a clamped 0...100 percentage.
private func sqPercent(fraction: Float) -> Float {
    return sqClamp(100 * fraction)
}

/// Clamps a percentage to 0...100, mapping NaN and infinities to 0.
private func sqClamp(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 100)
}

/// Replaces NaN, infinite or negative areas with 0.
private func sqSanitize(_ value: Float) -> Float {
    guard value.isFinite, value > 0 else { return 0 }
    return value
}
