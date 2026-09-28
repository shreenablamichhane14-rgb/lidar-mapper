# Coverage module API contract (ios/Sources/Coverage/)

Shared types already exist in ios/Sources/Coverage/CoverageTypes.swift (read it): SurfaceClass, CoverageFace,
CoverageObservation, CoverageState, CoverageWall, CoverageRoomBoundary. Do not redeclare them.
Names already taken elsewhere in the app target (DO NOT declare these at top level): Plane, Ray, Snap, SnapResult,
SnapTarget, Polygon2D, Segment2D, Rectangle2D, AABB3, OrientedBox, SelfTestResult, SelfTestSuite, TriangleMesh,
TriangleQuery, Tolerance, Copy, GuidanceKind, GuidanceMessage, GuidancePolicy, Haptics, DeviceState.
Private file-scope helpers must be `private`/`fileprivate` and prefixed to avoid clashes (e.g. `private func cgCross`).

Language: Swift 5.9 mode, iOS 18, `import Foundation` + `import simd` only. No force unwraps (except literals),
doc comment (///) on every type, property group and function, file under ~450 lines. No Date() anywhere.
Plain English comments, no em-dashes, no emojis. All types are value types (struct/enum) unless stated.

## CoverageGrid.swift
```swift
/// Per-voxel / per-face accumulated evidence.
struct CoverageStats: Equatable {
    var observationCount: UInt16      // observations with quality > 0 (saturating)
    var goodObservationCount: UInt16  // observations with quality >= CoverageGrid.goodQuality (saturating)
    var bestViewCosine: Float         // max over obs of dot(normal, dirToCamera), 0 if none
    var bestDistance: Float           // distance of the best-quality observation, .infinity if none
    var bestQuality: Float            // max quality 0...1
    static let empty: CoverageStats
}
struct CoverageIntegrateResult { var facesTested: Int; var facesUpdated: Int; var truncated: Bool }

struct CoverageGrid {
    static let defaultVoxelSize: Float = 0.10
    static let maxRange: Float = 5.0
    static let goodQuality: Float = 0.5        // an observation is "good" at or above this
    static let excellentQuality: Float = 0.85  // one excellent observation => green
    static let greenGoodCount = 3              // >= 3 good observations => green
    static let maxFacesPerIntegrate = 60_000   // cap on faces scored per call (round-robin cursor over the rest)
    let voxelSize: Float
    init(voxelSize: Float = CoverageGrid.defaultVoxelSize)

    /// Quality of one observation of a surface point, 0...1 = distance term * incidence term * confidence term.
    /// distance term: 0 below 0.2 m, ramps to 1 at 0.5 m, 1 on 0.5...2.5 m, falls linearly to 0 at 5.0 m.
    /// incidence term: clamp((viewCosine - 0.17) / (0.7 - 0.17), 0, 1) roughly (0 at grazing > ~80 deg, 1 within ~45 deg).
    /// confidence term: nil -> 0.8, else 0.4 + 0.6 * clamp(conf, 0, 1).
    static func observationQuality(distance: Float, viewCosine: Float, depthConfidence: Float?) -> Float

    /// Integrates one observation. Ignores it when !trackingNormal. Tests faces against the frustum built from
    /// intrinsics + imageResolution (with small margin), range (0.2...maxRange) and facing (viewCosine > 0).
    /// Faces array may grow between calls (mesh updates): per-face stats are kept by index and extended.
    /// Also updates the voxel containing each updated face centroid.
    @discardableResult
    mutating func integrate(observation: CoverageObservation, faces: [CoverageFace]) -> CoverageIntegrateResult

    func key(for point: SIMD3<Float>) -> SIMD3<Int32>          // floor(point / voxelSize)
    func center(of key: SIMD3<Int32>) -> SIMD3<Float>
    func voxelStats(_ key: SIMD3<Int32>) -> CoverageStats?
    func faceStats(_ index: Int) -> CoverageStats?              // nil if index never seen
    func state(ofFace index: Int) -> CoverageState               // gray if unknown
    func state(atVoxel key: SIMD3<Int32>) -> CoverageState       // red if marked expected and unobserved
    static func state(for stats: CoverageStats) -> CoverageState // green: good>=3 or best>=excellent; yellow: good 1-2 or obs>=1; else gray
    /// True if any voxel whose center is within `radius` of `point` has observationCount > 0.
    func isObserved(near point: SIMD3<Float>, radius: Float) -> Bool
    /// Marks voxels containing these points as expected surface (used for red state).
    mutating func markExpected(_ points: [SIMD3<Float>])
    mutating func clearExpected()
    var voxelCount: Int { get }
    var faceCount: Int { get }                                   // number of per-face stat slots
    /// Area-weighted fraction (0...1) of faces with at least one good observation; faces from the last integrate call.
    func goodFaceAreaFraction(faces: [CoverageFace]) -> Float
    /// Area-weighted fraction of faces of a class whose state is yellow or green.
    func observedAreaFraction(faces: [CoverageFace], surface: SurfaceClass?) -> Float
    func stateCounts() -> [CoverageState: Int]                   // over voxels
    mutating func reset()
}
```
Performance: keep per-face stats in a contiguous array; per-call cost estimate documented (200k faces x ~25 flops
frustum test ~ 3-5 ms on A15 at 2-3 Hz). The cap bounds scored faces; the frustum test itself may cover all faces
or a round-robin slice, document which.

## ExpectedSurfaces.swift
```swift
struct MissingArea { var centroid: SIMD3<Float>; var normal: SIMD3<Float>; var area: Float; var surface: SurfaceClass; var suggestedViewpoint: SIMD3<Float> }
struct ExpectedSample { var position: SIMD3<Float>; var normal: SIMD3<Float>; var surface: SurfaceClass
                        var element: Int   // wall index >= 0, -1 floor, -2 ceiling
                        var cell: SIMD2<Int32> } // grid coords within the element for adjacency
struct ExpectedSurfacesResult {
    var samples: [ExpectedSample]; var observed: [Bool]; var missing: [MissingArea]
    var expectedArea: [SurfaceClass: Float]   // keys .wall .floor .ceiling
    var observedArea: [SurfaceClass: Float]
}
enum ExpectedSurfaces {
    static let sampleSpacing: Float = 0.20
    static let observedRadius: Float = 0.15     // sample counts as observed if grid.isObserved(near:radius:)
    static let minMissingArea: Float = 0.08     // clusters smaller than this (2 samples) are ignored
    static let eyeHeight: Float = 1.4, viewDistance: Float = 1.5
    /// Wall samples at cell centers ((i+0.5)*s along length, (j+0.5)*s up), normal horizontal pointing INTO the room
    /// (toward the floor polygon interior). Floor normal +Y at floorY, ceiling normal -Y at ceilingY, cells on the
    /// s-grid in (x,z) whose center is inside the polygon (even-odd). Each sample represents s*s m^2
    /// (partial last row/column may be weighted by its true fraction; document choice).
    static func samples(for room: CoverageRoomBoundary, spacing: Float = sampleSpacing) -> [ExpectedSample]
    /// Samples, marks observed, union-find clusters of unobserved samples (same element, 4-neighbor cells),
    /// one MissingArea per cluster >= minMissingArea, sorted by area descending.
    static func evaluate(room: CoverageRoomBoundary, grid: CoverageGrid, spacing: Float = sampleSpacing) -> ExpectedSurfacesResult
    /// centroid + normal * viewDistance horizontally, y = floorY + eyeHeight; floor/ceiling: above centroid at eye height;
    /// then clamped inside the floor polygon (inset 0.3 m where possible).
    static func suggestedViewpoint(centroid: SIMD3<Float>, normal: SIMD3<Float>, room: CoverageRoomBoundary) -> SIMD3<Float>
    static func pointInPolygon(_ p: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool
}
```

## ScanQuality.swift
```swift
/// Percentages 0...100.
struct ScanQualityReport { var geometry: Float; var walls: Float; var floor: Float; var ceiling: Float; var textures: Float; var missingAreas: [MissingArea] }
enum ScanQuality {
    /// With a room: walls/floor/ceiling = 100 * observedArea / expectedArea of ExpectedSurfaces.evaluate (100 if nothing expected);
    /// geometry = area-weighted over all three. Without a room: from grid.observedAreaFraction(faces:surface:) per class
    /// and over all faces. textures = 100 * grid.goodFaceAreaFraction(faces:). missingAreas from evaluate (empty without room).
    static func evaluate(grid: CoverageGrid, faces: [CoverageFace], room: CoverageRoomBoundary?) -> ScanQualityReport
}
```

## GuidanceEngine.swift
```swift
enum GuidanceTracking: UInt8 { case normal, excessiveMotion, insufficientFeatures, initializing, relocalizing }
struct GuidanceInput {
    var time: Double                    // seconds, monotonic, supplied by caller
    var tracking: GuidanceTracking = .normal
    var angularSpeed: Float = 0         // rad/s
    var linearSpeed: Float = 0          // m/s
    var centerDistance: Float? = nil    // m, depth at view center
    var depthConfidenceMean: Float? = nil  // 0...1
    var ambientIntensity: Float? = nil  // ARLightEstimate lumens-scale, 1000 = neutral
    var viewCoverage: Float? = nil      // 0...1 fraction of in-view surface that is green
    var nearbyMissing: [MissingArea] = []
    var newDoors: Int = 0; var newWindows: Int = 0; var newWalls: Int = 0
    var deviceHot: Bool = false
    var overallComplete: Bool = false   // caller: scan quality says done
    init(time: Double)  // memberwise with defaults also fine
}
struct GuidanceOutput: Equatable { var message: GuidanceKind?; var fireHaptic: Bool }
struct GuidanceEngine {
    init()
    mutating func update(_ input: GuidanceInput) -> GuidanceOutput
    mutating func reset()
    // Documented thresholds as static lets, e.g. tooCloseDistance 0.3, tooFarDistance 5.0, moveCloserDistance 3.0,
    // lightingPoorIntensity 300, fastAngularSpeed 1.5 rad/s, fastLinearSpeed 1.0 m/s, lowViewCoverage 0.3, etc.
}
```
Rules from GuidancePolicy (Copy.swift): one message at a time; condition must hold conditionHoldSeconds before showing
(detection events bypass hold); shown at least its minimumSeconds; minimumGapSeconds of quiet after hide except tier 1;
same message not re-shown within repeatCooldownSeconds; tier 3 dropped for tier3QuietAfterTier1Seconds after any tier 1;
max 4 tier-3 per rolling minute; haptic only when a haptic message newly appears and hapticCooldownSeconds elapsed;
canInterrupt(incomingTier:currentTier:currentShownSeconds:) decides preemption. Message hides once its minimum time has
passed and its condition no longer holds (events hide after their minimum time). Deterministic.

Completion notes (impl/coverage):
- When the message on screen reaches its minimum time and the best waiting candidate may interrupt it
  (GuidancePolicy.canInterrupt), the candidate replaces it directly instead of hide plus gap. Without this the
  "tier 2 interrupts tier 3 after its minimum time" rule could never fire, because tier 3 always hides at exactly
  its minimum time and the gap then delayed the tier 2 message by 3 s.
- Tier 3 conditions (roomLooksComplete) show once per run of being true, not again after every 10 s cooldown.
- depthConfidenceMean is used: below 0.3 with the view center beyond 1.5 m (or unknown) it raises moveCloser.
- dryrun/ holds a plain Python port of the module and of every self-test check (`python3 run.py`, optional
  args: frustum margin in px, `f64`). It reproduces all 160 checks with float32 rounding emulated; rerun it
  after changing thresholds, since there is no Swift compiler outside CI.

## MeasurementConfidence.swift
```swift
enum MeasurementSnapKind: UInt8 { case none, vertex, edge, plane, roomSurface }
/// Evidence for one measured endpoint.
struct MeasurementEvidence {
    var distance: Float              // camera to point at capture, m
    var depthConfidence: Float?      // 0...1
    var observations: Int            // number of depth observations supporting the point
    var trackingNormalFraction: Float // 0...1 fraction of frames with normal tracking during capture
    var snap: MeasurementSnapKind
}
struct MeasurementConfidence: Equatable {
    var accuracy: Float              // +/- meters (about 1 sigma..95%; document)
    var isLowConfidence: Bool
    static func pointAccuracy(_ e: MeasurementEvidence) -> Float
    /// Length measurement between two endpoints: root-sum-square of endpoint accuracies plus drift proportional to length.
    static func estimate(start: MeasurementEvidence, end: MeasurementEvidence, length: Float) -> MeasurementConfidence
    static func estimate(point: MeasurementEvidence) -> MeasurementConfidence
}
```
Monotonic: accuracy non-decreasing in distance, non-increasing in observations and depthConfidence and trackingNormalFraction.

## CoverageSelfTest.swift
`enum CoverageSelfTest { static func run() -> [String] }` returns failures only (empty = pass), style like
ios/Sources/Units/UnitsSelfTest.swift. >= 45 checks.
