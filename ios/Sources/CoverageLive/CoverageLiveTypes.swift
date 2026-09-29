import Foundation
import simd

// Public value types of CoverageLive (docs/MODULES.md 3.31): the tunables, one anchor's faces
// with their live states (what CoverageOverlay and LargeObject draw and pick), and the summary
// for diagnostics and simple UI values.

/// Tunables in one place (RESEARCH 3.8 disputed 13: engineering choices, tuned on device).
struct CoverageLiveOptions: Equatable, Sendable {
    /// Integration rate cap, Hz. The rate used is min(maxHz, ThermalPolicy.coverageHz), that is 3, 3, 1, 0.
    var maxHz: Double = 3
    /// Voxel edge, meters (Coverage default).
    var voxelSize: Float = 0.10
    /// Least seconds between two anchor refreshes from MeshStore.
    var anchorRefreshSeconds: Double = 1
    /// Least seconds between two expected-surface evaluations (missing areas, fraction, minimap).
    var evaluationSeconds: Double = 1
    /// Minimap cell edge, meters; doubled until the map fits `maxMinimapCells` on each side.
    var minimapCellSize: Float = 0.25
    /// Most minimap cells on each side.
    var maxMinimapCells: Int = 96
    /// Faces tracked at most; anchors past the cap are left out (logged once per recording).
    var maxTrackedFaces: Int = 500_000
    /// With an expected room but no mesh face after this many seconds of scanning, the expected
    /// shell samples stand in for faces (meshStripped, D16).
    var shellFallbackSeconds: Double = 8
    /// Live-room mode only: missing areas reach guidance after this much scan time, once each has
    /// been missing this long, within this horizontal distance of the camera, at most 3.
    var nearbyAfterSeconds: Double = 30
    /// Least age of a missing area before it reaches guidance, seconds (see `nearbyAfterSeconds`).
    var nearbyMinAgeSeconds: Double = 15
    /// Largest horizontal camera distance of a missing area that reaches guidance, meters.
    var nearbyRadius: Float = 3
    /// Growth of the live room's window, door and opening boxes on every side before they
    /// exclude expected samples and missing areas, meters (D19; an addition to the 3.31 list).
    var exclusionMargin: Float = 0.1
    /// Radius of the well-observed test of watched points, meters (3.31 pass step 7).
    var watchedRadius: Float = 0.15

    /// The defaults above.
    init() {}
}

/// One anchor's triangles with their live coverage states. A value copy: the arrays share
/// storage with MeshStore's chunk of the same version (copy on write, nothing is duplicated).
struct CoverageAnchorFaces {
    /// `ARMeshAnchor.identifier`.
    var anchorID: UUID
    /// `MeshChunkIndexEntry.updateCount` of the version these faces came from.
    var updateCount: UInt32
    /// Anchor to world.
    var transform: simd_float4x4
    /// `MeshChunk.positions`, `normals` (per vertex) and `indices`, anchor-local.
    var localPositions: [SIMD3<Float>]
    var localNormals: [SIMD3<Float>]
    var indices: [UInt32]
    /// One per triangle (indices.count / 3): world centroid, unit normal oriented like the ARKit
    /// vertex normals, area (0 for a degenerate or out-of-range triangle) and class.
    var faces: [CoverageFace]
    /// One per triangle: `CoverageGrid.state(atVoxel:)` of the centroid's voxel; gray for area 0.
    var states: [CoverageState]
    /// World bounds of the positions.
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    /// From one recorder-wide counter; set anew whenever the geometry or any state changed.
    var revision: UInt64
}

/// Diagnostics and simple UI values.
struct CoverageLiveSummary: Equatable {
    /// Live passes that integrated an observation, and due frames skipped because a pass was in flight.
    var integrations: Int
    var skippedBusy: Int
    /// Anchors tracked and their faces.
    var anchors: Int
    var trackedFaces: Int
    /// With an expected room: observed / expected area; otherwise the green share of the tracked face area. 0...1.
    var coverageFraction: Float
    /// Green share of the in-view face area at the last pass; nil when under 0.05 m^2 is in view.
    var viewCoverage: Float?
    /// Missing areas after the D19 filter, and whether an expected room (or boundary) is set.
    var missingCount: Int
    var hasExpectedRoom: Bool
    /// The expected shell stands in for mesh faces (D16 meshStripped).
    var usesShellFallback: Bool
    /// Integration rate in use, Hz, and the duration of the last pass, milliseconds.
    var effectiveHz: Double
    var lastPassMilliseconds: Double

    /// Every counter zero, no view coverage.
    static let zero = CoverageLiveSummary(integrations: 0, skippedBusy: 0, anchors: 0, trackedFaces: 0,
                                          coverageFraction: 0, viewCoverage: nil, missingCount: 0,
                                          hasExpectedRoom: false, usesShellFallback: false, effectiveHz: 0,
                                          lastPassMilliseconds: 0)
}
