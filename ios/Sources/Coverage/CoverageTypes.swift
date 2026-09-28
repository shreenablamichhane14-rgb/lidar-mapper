import Foundation
import simd

// Shared plain input and output types for the coverage and scan quality engine.
// No ARKit or RoomPlan imports: a thin adapter converts ARFrame / ARMeshAnchor /
// CapturedRoom data into these types, so the engine can be unit-tested in isolation.
//
// World convention: ARKit world space, meters, +Y up, gravity along -Y.
// Room plan coordinates (`SIMD2<Float>`) are (x, z) on the horizontal plane.

/// Semantic class of a mesh face. Raw values match `ARMeshClassification`
/// (none = 0, wall = 1, floor = 2, ceiling = 3, table = 4, seat = 5, window = 6,
/// door = 7), as declared in the ARKit Objective-C header and recorded in
/// docs/research/raw/arkit-mesh-depth.json and docs/RESEARCH.md (declaration order, not the
/// alphabetical order of Apple's documentation topics). The adapter can therefore map the
/// per-face `UInt8` of `ARMeshGeometry.classification` with `SurfaceClass(rawValue:)`.
enum SurfaceClass: UInt8, CaseIterable {
    case none = 0, wall = 1, floor = 2, ceiling = 3, table = 4, seat = 5, window = 6, door = 7
}

/// One mesh triangle as seen by the coverage engine: world-space centroid,
/// unit normal (pointing out of the surface, toward where a viewer stands),
/// area in square meters and semantic class.
struct CoverageFace {
    var centroid: SIMD3<Float>
    var normal: SIMD3<Float>
    var area: Float
    var surface: SurfaceClass
}

/// One camera observation (one processed ARFrame).
/// - `cameraToWorld`: `ARCamera.transform` (camera looks down its local -Z, +X right and +Y up
///   in the landscape-right sensor frame). A camera-space point p projects to pixel
///   u = fx * p.x / -p.z + cx, v = fy * -p.y / -p.z + cy (image v grows downward).
/// - `intrinsics`: `ARCamera.intrinsics` in pixels for `imageResolution`.
/// - `trackingNormal`: `trackingState == .normal`; non-normal observations are ignored by the grid.
/// - `depthConfidenceMean`: mean of `ARDepthData.confidenceMap` normalized to 0...1
///   (raw `ARConfidenceLevel` low = 0, medium = 1, high = 2, divided by 2); nil when no depth.
/// - `timestamp`: `ARFrame.timestamp` in seconds.
struct CoverageObservation {
    var cameraToWorld: simd_float4x4
    var intrinsics: simd_float3x3
    var imageResolution: SIMD2<Float>
    var trackingNormal: Bool
    var depthConfidenceMean: Float?
    var timestamp: Double
}

/// Display state of a voxel or face on the coverage overlay.
/// gray = not scanned / unknown, red = expected surface never observed,
/// yellow = partial (1 to 2 good observations), green = well scanned.
enum CoverageState: UInt8, CaseIterable {
    case gray = 0, red = 1, yellow = 2, green = 3
}

/// One straight wall of a room boundary, as RoomPlan reports it: a segment on the
/// floor plan from `start` to `end` in (x, z), rising from `baseY` for `height` meters.
struct CoverageWall {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var baseY: Float
    var height: Float
}

/// The expected shell of a room: walls plus floor and ceiling polygons in (x, z).
/// Polygons may be given in either winding; `ceilingPolygon` may be empty, in which
/// case the floor polygon is reused at `ceilingY`.
struct CoverageRoomBoundary {
    var walls: [CoverageWall]
    var floorPolygon: [SIMD2<Float>]
    var floorY: Float
    var ceilingPolygon: [SIMD2<Float>]
    var ceilingY: Float
}
