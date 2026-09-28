# Mapper architecture proposal: UX-first

Lens: the scanning experience drives the architecture. This document first fixes the screens, state machines, view models and the data they consume, then attaches capture and processing pipelines behind stable interfaces. Everything below is written against the verified research in `docs/research/raw/*.json` (including the refutations), the product brief `docs/SPEC.txt`, the copy catalog `docs/UX_COPY.md` / `ios/Sources/Support/Copy.swift`, and the existing app code under `ios/Sources/`.

Branch status at the time of writing: `origin/main` and `origin/dev` only. `feat/geometry` and `feat/export` are briefed (`docs/tasks/geometry.md`, `docs/tasks/exporters.md`) but not pushed yet. This design consumes their briefed public types by name (`Polygon2D`, `Segment2D`, `Plane`, `OrientedBox`, `AABB3`, `TriangleMesh`, `MeshBVH`, `Ray`, `Snap`, `SnapTarget`, `ExportScene`, `ExportMesh`, `ExportMaterial`, `Plan2D`, the `*Writer` enums, `ZipWriter`) and never redefines them.

## 0. Principles that follow from the lens

1. **The user never waits on a blank screen.** Every long operation has a visible, honest state. Results appear progressively: the clean model and floor plan (seconds) before the raw mesh (tens of seconds) before the photo-realistic model (a minute or more). The viewer opens as soon as the first representation is ready.
2. **One live camera, many states.** Scan, quality check, Show Missing Areas and (in House mode) the room list all happen over the same running AR session. The quality screen is a sheet over the live camera, not a new screen, because Show Missing Areas needs tracking to still be alive. This single decision shapes the capture layer more than any other.
3. **Views never touch ARKit, RoomPlan or Object Capture types.** Views read plain value snapshots published by a `ScanEngine`. That gives the UI agents a fixed contract, a fake engine to build against, and a demo mode on the phone that replays a recorded scan without scanning.
4. **One message at a time.** Guidance arbitration (`UX_COPY.md` section 4 display rules, already encoded in `GuidancePolicy`) is a pure, testable engine. Detectors only raise conditions; the engine decides what the user sees.
5. **Honesty is a data-model property, not a UI afterthought.** Every surface, measurement and element carries a `Provenance` (measured, estimated, inferred, occluded, unscanned) and measurements carry a confidence. The UI renders what the data says.
6. **Raw is sealed.** A scan's raw folder becomes read-only the moment the user taps Finish. Every edit is an overlay; every derived file can be deleted and rebuilt.
7. **Compile-safety over cleverness.** Swift 5 mode, no macros (so no `@Observable`: view models are `ObservableObject` with `@Published`), no Swift packages, delegate signatures copied verbatim from the research, Metal nowhere in the first three builds.

## 1. Module map

Each module is a folder under `ios/Sources/`. Arrows mean "depends on". Nothing depends on `UI`. Only `Capture`, `Engines` and `Render/Live` import ARKit or RoomPlan; only `Engines/ObjectCaptureEngine.swift` and `Processing/ObjectModelBuilder.swift` import Object Capture types.

| Module | Responsibility | Key files | Depends on |
|---|---|---|---|
| `Support` (exists) | Log, debug server, haptics, device state, settings keys, `Copy` | `LogStore.swift`, `DebugServer.swift`, `DeviceFeatures.swift`, `SettingsKey.swift`, `Copy.swift` | Foundation, UIKit |
| `Units` (exists) | Length, area, volume, angle, tolerance formatting and parsing | `Units.swift`, `LengthFormatter.swift`, `LengthParser.swift` | Foundation |
| `Geometry` (feat/geometry) | Pure simd geometry: polygons, planes, PCA, OBB, meshes, BVH, snapping | as briefed | Foundation, simd |
| `Export` (feat/export) | OBJ, PLY, STL, GLB, USDZ, DXF, SVG, PDF, ZIP writers over plain input types | as briefed | Foundation, simd, UIKit (PDF) |
| `Core` | Shared value types and protocols only: ids, project model, scan records, clean model, floor plan, measurements, quality, provenance, live snapshot, engine protocol, Codable simd wrappers, errors | `Ids.swift`, `ProjectModel.swift`, `ScanModel.swift`, `CleanModel.swift`, `FloorPlanModel.swift`, `MeasureModel.swift`, `QualityModel.swift`, `LiveScan.swift`, `ScanEngine.swift`, `EditModel.swift`, `CodableSimd.swift`, `MapperError.swift` | Foundation, simd, Geometry, Units |
| `Store` | Project package on disk: layout, manifest IO, raw writer with sealing, raw reader, derived cache, edit log, project list index, backup and restore, storage accounting | `PackageLayout.swift`, `ProjectStore.swift`, `RawScanWriter.swift`, `RawScanReader.swift`, `MeshChunkFile.swift`, `DerivedStore.swift`, `EditStore.swift`, `BackupService.swift`, `StreamingZip.swift` | Core, Export (CRC only), Support |
| `Capture` | ARKit session ownership and recording: configuration, shared-session protocol with RoomPlan, mesh anchor copying, keyframe gate and encoding, depth copies, photo pins, diagnostics, thermal governor | `ARSessionHost.swift`, `CaptureConfig.swift`, `MeshRecorder.swift`, `KeyframeRecorder.swift`, `PhotoPinRecorder.swift`, `SessionDiagnostics.swift`, `ThermalGovernor.swift`, `FrameMath.swift` | Core, Store, Geometry, Support, ARKit, CoreImage |
| `Coverage` | Voxel coverage grid, live coverage tracking, expected surfaces from RoomPlan, quality report, missing-area clustering, object sector coverage | `CoverageGrid.swift`, `CoverageTracker.swift`, `ExpectedSurfaces.swift`, `QualityAnalyzer.swift`, `MissingAreaFinder.swift`, `SectorCoverage.swift` | Core, Geometry |
| `Guidance` | Pure message arbitration and the detectors that turn signals into `GuidanceKind` conditions | `GuidanceEngine.swift`, `GuidanceDetectors.swift`, `GuidanceSelfTest.swift` | Core, Support (Copy, GuidancePolicy) |
| `Engines` | The `ScanEngine` implementations the scan screen drives | `RoomScanEngine.swift`, `RoomPlanBridge.swift`, `MeshScanEngine.swift`, `ObjectCaptureEngine.swift`, `MeasureEngine.swift`, `FakeScanEngine.swift`, `SnapshotRecorder.swift` | Core, Capture, Coverage, Guidance, Store, RoomPlan, RealityKit |
| `Processing` | Post-scan stage runner and stages: mesh consolidation, clean model, floor plan, object model, structure merge, thumbnails, auto measurements | `ProcessingQueue.swift`, `MeshConsolidator.swift`, `CleanModelBuilder.swift`, `FloorPlanBuilder.swift`, `StructureMerger.swift`, `ObjectModelBuilder.swift`, `LargeObjectBuilder.swift`, `ThumbnailRenderer.swift` | Core, Store, Geometry, Coverage, Measure, RoomPlan, RealityKit (object only) |
| `Texturing` | CPU view selection, charts, atlas bake (CoreGraphics), vertex colors for PLY | `KeyframeIndex.swift`, `ViewSelector.swift`, `ChartBuilder.swift`, `AtlasPacker.swift`, `AtlasBaker.swift`, `TexturedMeshBuilder.swift` | Core, Store, Geometry, CoreGraphics, ImageIO |
| `Measure` | Confidence model, auto measurements from the clean model, snap candidate provider, measurement session logic shared by live and viewer tools | `ConfidenceModel.swift`, `AutoMeasurements.swift`, `SnapCandidates.swift`, `MeasureToolModel.swift` | Core, Geometry, Units |
| `Render` | RealityKit scene building: live overlays (coverage, RoomPlan outlines, target ring) and the post-scan viewer (chunks, materials, orbit camera, picking) | `Live/CoverageOverlay.swift`, `Live/RoomOutlineOverlay.swift`, `Live/TourMarker.swift`, `Viewer/ModelViewerView.swift`, `Viewer/OrbitCamera.swift`, `Viewer/SceneAssembler.swift`, `Viewer/ScanMaterials.swift`, `Viewer/Picker.swift`, `ARViewContainer.swift` | Core, Geometry, RealityKit, ARKit (live only) |
| `Plan` | Floor plan drawing (Core Graphics), hit testing, edit operations, plan-to-`Plan2D` adapter | `PlanRenderer.swift`, `PlanHitTest.swift`, `PlanEditor.swift`, `PlanLayout.swift` | Core, Geometry, Units, CoreGraphics |
| `ExportAdapters` | Maps project representations to `ExportScene` / `Plan2D`, runs writers, stages share files, JSON summary export, RoomPlan native USDZ | `ExportCoordinator.swift`, `SceneAdapter.swift`, `PlanAdapter.swift`, `MeasurementsJSON.swift` | Core, Store, Export, Plan, RoomPlan |
| `UI` | App shell, every screen, every view model | see section 8 | everything above except Capture internals |

Rules that keep parallel work compiling:

- Shared types live only in `Core`. A module may add private helper types but must not add public types another module needs.
- `Core` imports only Foundation, simd, Geometry and Units. It never imports ARKit, RoomPlan or RealityKit, so every agent can use it freely.
- ARKit and RoomPlan values are converted into `Core` values at the boundary (`Capture`, `Engines/RoomPlanBridge.swift`, `Processing/CleanModelBuilder.swift`).
- Every module ships a `<Module>SelfTest.run() -> [String]` for its pure logic, wired into a Diagnostics screen (the capability probe screen grows into it), because CI cannot run tests on a device.

## 2. Data model

### 2.1 Project package on disk

Projects live in `Documents/Projects/<projectID>.mapperproj/` (a folder; `UIFileSharingEnabled` already exposes Documents, so the user can also see and copy packages in Files). Scans in progress live in `Library/Application Support/InProgress/<scanID>/` and are moved into the package on seal, so Files never shows half-written chunks (storage research gotcha).

```
<projectID>.mapperproj/
  project.json                     ProjectManifest (schema version, name, mode, rooms, status)
  thumbnail.jpg                    list thumbnail (derived, regenerable)
  scans/
    <scanID>/
      raw/                         SEALED, read-only after Finish
        SEAL.json                  RawSeal: file list, byte sizes, sealedAt, app version
        session.json               ScanSessionInfo: mode, settings, device, video format, config log
        timeline.jsonl             one JSON object per line: tracking, thermal, battery, RoomPlan
                                   instructions, relocalizations, interruptions (append-only)
        mesh/
          index.json               [MeshChunkRecord]: anchor id, file, counts, transform, updatedAt
          <anchorID>.mchk          binary chunk (see 2.2), world space, last version of each anchor
        keyframes/
          keyframes.jsonl          KeyframeRecord per line (append-only during capture)
          <index>.jpg              1920x1440 capturedImage as JPEG, sensor (landscape) orientation
          <index>.dep              Float16 depth 256x192 with header
          <index>.cnf              UInt8 confidence 256x192 with header
        photos/
          photos.json              [PhotoPin]
          <photoID>.jpg            user "Take Photo" images with pose
        planes.json                ARPlaneAnchor snapshot at Finish (alignment, classification,
                                   transform, extent, boundary)
        worldmap.arworldmap        ARWorldMap at Finish (only when mapping status allows)
        roomplan/
          capturedroomdata.json    CapturedRoomData (opaque, Codable), re-buildable by RoomBuilder
          liveroom.json            last live CapturedRoom from didUpdate (for diagnostics only)
        objectcapture/
          Images/                  HEIC shots written by ObjectCaptureSession (object mode)
        measure/
          points.json              Quick Measure points with raycast source and pose
          snapshot.jpg             ARView snapshot of the measured scene
  derived/                         REGENERABLE. Deleting it loses nothing.
    state.json                     DerivedState: per representation status, input fingerprint
    <scanID>/
      roomplan/capturedroom.json   RoomBuilder output (CapturedRoom JSON)
      mesh/consolidated.mchk       welded, cleaned world mesh (raw mesh view and texturing input)
      mesh/bvh.bin                 optional cached BVH
      coverage/grid.bin            final CoverageGrid
      coverage/quality.json        QualityReport at Finish (what the user saw)
      textured/texmesh.mchk        split-vertex mesh with UVs
      textured/atlas_<n>.jpg       atlas pages (4096 max)
      object/model.usdz            PhotogrammetrySession output (object mode)
      object/mesh.mchk             that model converted to our mesh for measuring
    structure/capturedstructure.json   StructureBuilder output (house mode)
    clean/cleanmodel.json          CleanModel (all rooms of the project, one coordinate frame)
    plan/floorplan.json            FloorPlan as generated (before edits)
    measure/auto.json              [SavedMeasurement] generated from the clean model
  edits/
    edits.json                     EditLog: ordered EditOperation list with undo cursor
    measurements.json              user-placed SavedMeasurement list
    annotations.json               text, symbols, notes on plan and in 3D
    alignment.json                 manual room placements (house mode), per room transform
  exports/                         temporary staging, cleared on launch
```

Rules:

- `raw/` is written only by `RawScanWriter` while a scan is live. `RawScanWriter.seal()` writes `SEAL.json`, moves the folder into the package and sets POSIX permissions to read-only (0o444 files, 0o555 folders). `RawScanReader` is the only reader API. A rescan never overwrites: it creates a new `scanID` and the `RoomRecord` points at the new one; superseded scans are listed in the manifest and can be removed only through an explicit "Free up space" action.
- `derived/state.json` records, per representation, the stage status and a fingerprint of its inputs (raw scan ids plus algorithm version). The app rebuilds anything missing, failed or stale, which is also how a new build with a better texturer upgrades old projects.
- `edits/` is small JSON. It references elements by stable ids (section 2.3). The displayed clean model and floor plan are always `derived + edits`, computed by pure functions.
- File formats: JSON via `Codable` for everything structured; append-only JSON Lines where a crash mid-scan must not lose earlier records; small binary files with a 16-byte header for mesh, depth and confidence (storage research). JPEG for keyframes (hardware encoder via `CIContext.jpegRepresentation`, top-left row order matches the pixel buffer). HEIC only where Object Capture writes it.
- Backup is one STORE-mode zip of the whole package with extension `.mapperbackup`, written by `StreamingZip` (file handle based, because a package can be several hundred MB and the briefed `ZipWriter` builds `Data` in memory). Restore unzips into `InProgress/restore-<uuid>/`, validates `project.json` and the seals, then moves it into `Projects/`.

### 2.2 Binary chunk format (`.mchk`)

| Offset | Type | Meaning |
|---|---|---|
| 0 | 4 bytes | magic `MCHK` |
| 4 | UInt16 | version (1) |
| 6 | UInt16 | flags: bit0 normals, bit1 classification, bit2 uv, bit3 colors |
| 8 | UInt32 | vertex count |
| 12 | UInt32 | triangle count |
| 16 | Float32 x 3 x V | positions (world space, meters, Y up) |
| | Float32 x 3 x V | normals (if flag) |
| | Float32 x 2 x V | uv (if flag, top-left origin) |
| | UInt8 x 4 x V | colors RGBA (if flag) |
| | UInt32 x 3 x T | indices |
| | UInt8 x T | per-face ARMeshClassification raw value (if flag) |

Depth (`.dep`) and confidence (`.cnf`) files use the same 16-byte header shape (`MDEP` / `MCNF`, width, height, format) followed by the raw plane. Little-endian throughout. `MeshChunkFile` reads into `TriangleMesh` (positions, indices) plus side arrays, so Geometry and Export consume it directly.

### 2.3 In-memory model (Core)

All types are value types, `Codable` and `Equatable` unless noted. simd values are stored through `CodableSimd.swift` wrappers (`CodableVector3`, `CodableMatrix4` as 16 floats column-major) so `JSONEncoder` output is stable and readable.

Names avoid clashes with Apple types: no `Measurement` (Foundation), no `Project` collisions, no `Transform` (RealityKit), no `Room` bare name.

```swift
// Ids.swift
struct ProjectID: Hashable, Codable { var raw: UUID }
struct ScanID: Hashable, Codable { var raw: UUID }
struct RoomID: Hashable, Codable { var raw: UUID }
struct ElementID: Hashable, Codable { var raw: UUID }   // walls, openings, objects, plan items

// ProjectModel.swift
enum ScanMode: String, Codable, CaseIterable { case room, house, object, quickMeasure, advanced }
enum ProjectStatus: String, Codable { case scanning, processing, ready, needsWork, failed }
struct ProjectManifest: Codable, Equatable {
    var schemaVersion: Int
    var id: ProjectID
    var name: String
    var mode: ScanMode
    var createdAt: Date
    var modifiedAt: Date
    var isArchived: Bool
    var status: ProjectStatus
    var rooms: [RoomRecord]            // room and house mode; one entry for a single room
    var scans: [ScanRecord]            // every scan ever made, including superseded ones
    var floors: [FloorRecord]          // house mode; one default floor otherwise
    var objectScan: ScanID?            // object mode
    var settings: ScanSettings         // what the user picked (Advanced) or mode defaults
}
struct ProjectSummary: Identifiable, Equatable { /* id, name, mode, dates, status, roomCount, thumbnailURL */ }
struct RoomRecord: Codable, Equatable, Identifiable {
    var id: RoomID
    var name: String
    var floorIndex: Int
    var activeScan: ScanID?
    var status: RoomStatus
    var qualityScore: Double?          // 0...1, from the QualityReport at Finish
}
enum RoomStatus: String, Codable { case notScanned, scanning, done, needsScan }
struct FloorRecord: Codable, Equatable { var index: Int; var name: String; var roomIDs: [RoomID] }
struct ScanRecord: Codable, Equatable, Identifiable {
    var id: ScanID
    var roomID: RoomID?
    var mode: ScanMode
    var startedAt: Date
    var sealedAt: Date?
    var supersededBy: ScanID?
    var coordinateFrame: FrameLink     // how this scan relates to the project frame
}
enum FrameLink: Codable, Equatable {
    case projectFrame                  // same ARSession or relocalized world map
    case manual(CodableMatrix4)        // placed by hand (Line Up by Hand)
    case unaligned                     // separate frame, not yet placed
}
struct ScanSettings: Codable, Equatable {
    enum Detail: String, Codable { case standard, high, maximum }
    enum Range: String, Codable { case near, normal, far }
    enum Subject: String, Codable { case space, smallObject, largeObject }
    var subject: Subject
    var detail: Detail
    var keepAllPhotos: Bool
    var findRoomLayout: Bool           // RoomPlan on or off
    var findObjects: Bool
    var range: Range
    static func defaults(for mode: ScanMode) -> ScanSettings
}

// ScanModel.swift (raw records, written once)
struct ScanSessionInfo: Codable { /* mode, settings, app version, device model string (no identifiers),
                                     os version, videoFormat, frameSemantics, sceneReconstruction,
                                     configBeforeRoomPlan, configAfterRoomPlan, meshAnchorCount */ }
struct MeshChunkRecord: Codable { var anchorID: UUID; var file: String; var vertexCount: Int;
                                  var triangleCount: Int; var bounds: CodableAABB; var updatedAt: TimeInterval }
struct KeyframeRecord: Codable {
    var index: Int
    var timestamp: TimeInterval
    var cameraToWorld: CodableMatrix4          // ARCamera.transform
    var intrinsics: CodableIntrinsics          // fx, fy, cx, cy for imageWidth x imageHeight
    var imageWidth: Int; var imageHeight: Int  // sensor orientation (landscape)
    var exposureDuration: Double; var exposureOffset: Float
    var ambientIntensity: Double?
    var sharpness: Float                       // 0...1 from angular speed
    var hasDepth: Bool
}
struct PhotoPin: Codable, Identifiable { var id: UUID; var keyframeLike: KeyframeRecord; var note: String? }
enum TimelineEvent: Codable { /* tracking(TrackingQuality), thermal(ThermalLevel), battery(Float),
                                 instruction(String), relocalized, interrupted, resumed, roomPlanError(String) */ }

// CleanModel.swift
enum Provenance: String, Codable { case measured, estimated, inferred, occluded, unscanned }
enum ElementCategory: String, Codable, CaseIterable {
    case wall, floor, ceiling, door, window, opening, stairs
    case table, chair, sofa, bed, storage, cabinet, counter, sink, toilet, bathtub
    case refrigerator, oven, stove, dishwasher, washerDryer, fireplace, television
    case desk, column, appliance, other
    var isMovable: Bool                        // drives Hide Furniture
    var isFixture: Bool                        // drives the Fixtures plan toggle
}
struct CleanWall: Codable, Identifiable {
    var id: ElementID; var sourceID: UUID?     // RoomPlan surface identifier when it came from RoomPlan
    var roomID: RoomID
    var start: CodableVector3; var end: CodableVector3   // interior face line at floor height
    var height: Float; var thickness: Float
    var thicknessProvenance: Provenance
    var curve: WallCurve?
    var confidence: DetectionConfidence
    var coverage: Float                        // 0...1 observed fraction
    var segments: [SurfacePatch]               // provenance patches along the wall (occluded behind sofa, etc.)
}
struct CleanOpening: Codable, Identifiable { var id: ElementID; var sourceID: UUID?; var wallID: ElementID
    var kind: OpeningKind; var offsetAlongWall: Float; var width: Float; var sillHeight: Float
    var height: Float; var swing: DoorSwing?; var confidence: DetectionConfidence }
enum OpeningKind: String, Codable { case door, window, opening }
struct DoorSwing: Codable { var hingeAtStart: Bool; var opensToInterior: Bool; var isUserSet: Bool }
struct CleanObject: Codable, Identifiable { var id: ElementID; var sourceID: UUID?; var roomID: RoomID?
    var category: ElementCategory; var guessedCategory: ElementCategory?
    var box: CodableOrientedBox; var confidence: DetectionConfidence; var attributes: [String] }
struct CleanFloor: Codable { var roomID: RoomID; var outline: [CodableVector2]; var elevation: Float;
    var ceilingHeight: Float?; var ceilingProvenance: Provenance }
struct CleanRoom: Codable, Identifiable { var id: RoomID; var name: String; var sectionLabel: String?
    var floor: CleanFloor; var wallIDs: [ElementID] }
struct CleanModel: Codable { var rooms: [CleanRoom]; var walls: [CleanWall]; var openings: [CleanOpening]
    var objects: [CleanObject]; var floors: [Int: [RoomID]] }
enum DetectionConfidence: String, Codable { case high, medium, low, userSet }

// FloorPlanModel.swift  (plan coordinates: meters, x = world x, y = -world z, one plan per floor)
struct FloorPlan: Codable { var floors: [PlanFloor] }
struct PlanFloor: Codable { var index: Int; var rooms: [PlanRoom]; var walls: [PlanWall];
    var openings: [PlanOpening]; var fixtures: [PlanFixture]; var dimensions: [PlanDimension];
    var annotations: [PlanAnnotation] }
struct PlanRoom: Codable, Identifiable { var id: ElementID; var roomID: RoomID; var name: String;
    var outline: [CodableVector2]; var areaSquareMeters: Double }
struct PlanWall: Codable, Identifiable { var id: ElementID; var a: CodableVector2; var b: CodableVector2;
    var thickness: Float; var provenance: Provenance; var isUserAdded: Bool }
struct PlanOpening: Codable, Identifiable { var id: ElementID; var wallID: ElementID; var kind: OpeningKind;
    var offset: Float; var width: Float; var swing: DoorSwing? }
struct PlanFixture: Codable, Identifiable { var id: ElementID; var category: ElementCategory;
    var center: CodableVector2; var size: CodableVector2; var rotation: Float; var isFurniture: Bool }
struct PlanDimension: Codable, Identifiable { var id: ElementID; var a: CodableVector2; var b: CodableVector2;
    var offset: Float; var kind: DimensionKind; var measurementID: UUID? }
struct PlanAnnotation: Codable, Identifiable { var id: ElementID; var kind: AnnotationKind; var position: CodableVector2;
    var text: String; var symbol: String? }
struct PlanLayerToggles: Codable, Equatable { var furniture, measurements, roomNames, doorsWindows,
    fixtures, grid, scale: Bool }

// MeasureModel.swift
enum MeasureKind: String, Codable { case distance, wallLength, wallHeight, ceilingHeight, doorWidth,
    doorHeight, windowSize, roomLength, roomWidth, roomArea, floorArea, wallArea, surfaceArea,
    perimeter, angle, objectWidth, objectHeight, objectDepth, volume }
struct MeasurePoint: Codable { var position: CodableVector3; var source: SnapSource; var depthAtPick: Float?;
    var confidenceAtPick: UInt8?; var observations: Int }
enum SnapSource: String, Codable { case roomPlanCorner, planeCorner, edge, plane, mesh, raycastPlane, raycastEstimated, manual }
struct MeasurementConfidence: Codable { var sigmaMeters: Double; var isLow: Bool }
struct SavedMeasurement: Codable, Identifiable {
    var id: UUID; var kind: MeasureKind; var label: String?
    var points: [MeasurePoint]; var valueSI: Double          // meters, square meters or cubic meters
    var confidence: MeasurementConfidence?; var provenance: Provenance
    var elementID: ElementID?; var isAutomatic: Bool
}

// QualityModel.swift
enum CoverageState: UInt8, Codable { case gray = 0, red, yellow, green }
struct QualityMetric: Codable, Identifiable { var id: QualityMetricKind; var fraction: Double?; var isApplicable: Bool }
enum QualityMetricKind: String, Codable { case shape, walls, floor, ceiling, textures, objectSides }
struct MissingArea: Codable, Identifiable {
    var id: UUID; var center: CodableVector3; var normal: CodableVector3; var areaSquareMeters: Float
    var surface: ElementCategory; var reason: MissingReason; var suggestedViewpoint: CodableVector3
}
enum MissingReason: String, Codable { case unscanned, thin, hole, lowConfidence }
enum QualityVerdict: String, Codable { case good, okay, poor }
struct QualityReport: Codable { var metrics: [QualityMetric]; var missingAreas: [MissingArea];
    var verdict: QualityVerdict; var computedAt: Date; var usedRoomPlan: Bool }
```

`LiveScan.swift`, `ScanEngine.swift` and `EditModel.swift` are defined in sections 3 and 8, next to the flows that need them.

Category mapping (RoomPlan to `ElementCategory`), done once in `CleanModelBuilder`: `storage` to `cabinet` (or `storage` when the `StorageType` attribute is `.shelf`), `washerDryer` to `washerDryer`, `television` to `television`, `stairs` to `stairs`, every other of the 16 cases to its same-named case; surfaces map to wall, door, window, opening, floor. `counter`, `desk`, `column` and `appliance` exist because the spec lists them; they appear only from user correction (Change Category) or ARKit mesh classification hints (`table`, `seat`), never invented.

## 3. Capture pipelines

### 3.1 The scan engine contract (what the UI sees)

```swift
// Core/ScanEngine.swift
@MainActor protocol ScanEngine: AnyObject {
    var mode: ScanMode { get }
    var snapshot: LiveScanSnapshot { get }                       // latest, main actor
    var onSnapshot: ((LiveScanSnapshot) -> Void)? { get set }    // called on main, at most 5 Hz
    func start(settings: ScanSettings, context: ScanContext) throws
    func pause()
    func resume()
    func requestQualityCheck() -> QualityReport                 // Done tapped: soft stop, session keeps running
    func beginMissingAreaTour(_ areas: [MissingArea])
    func endMissingAreaTour()
    func takePhoto()
    func finish() async throws -> ScanResultRef                 // hard stop, seal raw, return ids
    func cancel()                                               // discard raw
}
struct ScanContext { var projectID: ProjectID; var roomID: RoomID?; var worldMapURL: URL?; var isHouseRoom: Bool }
struct ScanResultRef { var scanID: ScanID; var roomData: Bool; var meshChunks: Int; var keyframes: Int }

// Core/LiveScan.swift
enum LiveScanPhase: Equatable { case starting, running, paused(PauseReason), relocalizing,
    qualityCheck, touring(index: Int, total: Int), finishing, failed(MapperError) }
enum PauseReason: String { case user, interrupted, thermal, lowStorage }
enum TrackingQuality: Equatable { case normal, limited(String), notAvailable }
enum ThermalLevel: Int { case nominal, fair, serious, critical }
struct LiveScanSnapshot: Equatable {
    var phase: LiveScanPhase
    var elapsed: TimeInterval
    var tracking: TrackingQuality
    var thermal: ThermalLevel
    var conditions: Set<GuidanceKind>          // raised this tick by detectors; the GuidanceEngine arbitrates
    var events: [LiveEvent]                    // one-shot: doorFound, windowFound, wallFound, stairsFound, photoSaved
    var coverage: LiveCoverage                 // per metric fraction, overall estimate
    var detected: DetectedCounts               // walls, doors, windows, openings, objects so far
    var miniMap: MiniMapModel                  // 2D wall segments, user position and heading, missing markers
    var tour: TourState?                       // target screen position or edge direction, distance, filled
    var object: ObjectCaptureStatus?           // object mode: state, shots, max, orbit, passComplete
    var roomLimitWarning: Bool                 // 4 minute RoomPlan limit reached
    var storageLow: Bool
}
```

The scan screen view model (`ScanViewModel`, section 8) owns one `ScanEngine` and a `GuidanceEngine`. It never sees ARKit types. `FakeScanEngine` replays a `SnapshotRecorder` file (JSON Lines of snapshots captured on device) or a synthetic script, so every scan-flow screen can be built, compiled and exercised on the phone in demo mode before the capture code is finished.

The live camera view itself is the only exception: the scan screen embeds `ARViewContainer`, which receives an opaque `LiveViewProvider` from the engine (`func makeLiveView() -> UIView`). Room, mesh and measure engines return an `ARView`; the object engine returns nothing and the screen embeds `ObjectCaptureView` instead through `ObjectCaptureEngine.hostView() -> AnyView`.

### 3.2 One ARSession shared with RoomPlan (Room, House, Advanced with room layout)

The research refuted the naive claim that a custom configuration survives `RoomCaptureSession.run`. The verified working pattern, and the one this design encodes in `ARSessionHost` plus `RoomPlanBridge`:

1. `ARSessionHost` creates `ARSession()`, sets `delegateQueue` to the serial `capture.queue` and `delegate = ARSessionHost` itself, **before** creating the `RoomCaptureSession` (assigning the delegate after RoomPlan starts is the only reported blackout scenario).
2. Build `ARWorldTrackingConfiguration` (`CaptureConfig.makeWorldTracking(settings:)`): `sceneReconstruction = .meshWithClassification` (guarded by `supportsSceneReconstruction`), `frameSemantics = [.sceneDepth]` (guarded by `supportsFrameSemantics`), `planeDetection = [.horizontal, .vertical]`, `environmentTexturing = .none`, `isLightEstimationEnabled = true`, `videoFormat` = default 1920x1440 at 60 fps (no 4K, no high-resolution stills in v1). Run it.
3. The `ARView` for the camera feed is created with `ARView(frame:cameraMode: .ar, automaticallyConfigureSession: false)` and its `session` is set to our session. Our delegate is re-asserted after that assignment and logged.
4. `RoomCaptureSession(arSession: session)`, `delegate = RoomPlanBridge`, `run(configuration:)` with `isCoachingEnabled = false` (our guidance replaces RoomPlan's coaching text; we still consume `didProvide instruction`).
5. In `captureSession(_:didStartWith:)`, re-run our configuration on the same session with `options: []` (never `.resetTracking` or `.removeExistingAnchors`, which would break the shared world origin), then log `session.configuration` (video format, frame semantics, scene reconstruction, plane detection) as `configAfterRoomPlan` in `session.json`.
6. `SessionDiagnostics` watchdog, every 2 s on `capture.queue`: if `currentFrame?.sceneDepth == nil` or zero mesh anchors 5 s after start, re-apply the configuration once more; if still missing, switch the engine into **layout-only degraded mode** (below) and log it. Separately, a `CADisplayLink`-free fallback polls `session.currentFrame` from the coverage timer, so frames keep flowing even if RoomPlan swallows `session(_:didUpdate:)` delivery.

Degraded modes are designed into the UX rather than discovered later:

| Condition detected on device | Engine behavior | What the user sees |
|---|---|---|
| Everything works (expected) | RoomPlan + mesh + depth + keyframes | Coverage colors on the mesh, RoomPlan outlines, full quality screen |
| RoomPlan strips depth but mesh anchors arrive | Coverage still from mesh; confidence filter skipped (weight all observations as medium); keyframes still captured (color only) | Same UI; confidence of measurements widened |
| RoomPlan strips mesh and depth | Layout-only: coverage colors painted on RoomPlan wall, floor and object boxes from `completedEdges` and confidence; raw mesh comes from a short follow-up mesh pass offered after Finish ("Add detail: walk the room once more") on a plain ARKit session using the saved world map | Walls turn green/yellow/red as boxes instead of mesh; one extra optional pass |
| RoomPlan fails to start or errors (`exceedSceneSizeLimit`, `worldTrackingFailure`) | Mesh engine continues alone; clean model later extracted from mesh planes (reduced: walls and floor only) | "Scan stopped" alert only if tracking failed; otherwise scanning continues silently in mesh mode |

The first build that contains `RoomScanEngine` exists to settle these device facts (research open questions) and log them; the UI is already correct for all four rows.

### 3.3 Room mode

- Engine: `RoomScanEngine` (ARSessionHost + RoomPlanBridge + MeshRecorder + KeyframeRecorder + CoverageTracker + detectors).
- `capture.queue` work per ARKit callback:
  - `session(_:didAdd:)` / `didUpdate anchors`: for each `ARMeshAnchor`, copy vertices (respecting `offset` and `stride`), normals, faces and per-face classification out of the MTLBuffers synchronously, transform to world space with `anchor.transform`, store in `MeshRecorder` keyed by `anchor.identifier` (replace wholesale). `didRemove` marks stale, never deletes (anchors can come back). Mark the chunk dirty for the overlay and for the 30 s disk checkpoint.
  - `session(_:didUpdate frame:)`: never retain the frame. Read pose, tracking state, light estimate; feed `KeyframeGate` (tracking normal, moved more than 0.5 m or 20 degrees since last keyframe at Standard detail, angular speed low); for an accepted frame, synchronously create the JPEG with a shared `CIContext` and copy depth and confidence planes into `Data`, then hand the three `Data` blobs and the `KeyframeRecord` to `io.queue`. If `io.queue` has 2 pending keyframes, drop the new one and log (never block the delegate).
  - Every 333 ms (coverage tick, research algorithm): take the latest frame values already copied, update the `CoverageGrid` from faces in view (stride 4), 10 cm cells keyed by packed world position so re-meshing does not reset coverage.
- RoomPlan callbacks (thread undocumented, treated as any thread): `didUpdate room` stores the latest `CapturedRoom` in `RoomPlanBridge`, extracts `ExpectedSurfaces` (walls with `polygonCorners`, openings subtracted, floors) for the coverage tracker, emits `LiveEvent`s for new doors, windows, openings, walls and stairs, and updates mini map segments. `didProvide instruction` feeds `GuidanceDetectors`. `didEndWith data, error` delivers `CapturedRoomData` to the writer.
- Snapshot publishing: `RoomScanEngine` builds a `LiveScanSnapshot` on `capture.queue` at 4 Hz and posts it to main with `DispatchQueue.main.async`.
- Done (soft stop): `requestQualityCheck()` runs `QualityAnalyzer` on the current grid and the latest `CapturedRoom` (about 20 ms) while the session keeps running. The quality sheet appears over the camera.
- Finish (hard stop): `RoomCaptureSession.stop(pauseARSession: false)` (so house mode can continue; room mode pauses the ARSession afterwards), await `didEndWith`, save `CapturedRoomData`, flush the latest mesh chunks, write `planes.json`, request `currentWorldMap()` if `worldMappingStatus` is `.extending` or `.mapped`, write the timeline, seal. Only then does processing start.
- Limits: warning event at 4 minutes of RoomPlan scanning, per Apple's 5 minute guidance ("This room is big. Tap Done and scan the rest as another room"); `exceedSceneSizeLimit` routes the user to House mode for the rest.

### 3.4 House / Building mode

House mode is Room mode repeated on one living ARSession, with the room list as a sheet over the camera.

- One `ARSessionHost` and one `RoomCaptureSession` for the whole visit. After each room: `stop(pauseARSession: false)`, seal that room's scan, keep the session running, show the Rooms sheet (`HouseProgressSheet`) over the dimmed live camera with the hint "Keep the camera pointed at the walls while you walk to the next room". Tapping Scan Next Room calls `run(configuration:)` again on the same `RoomCaptureSession` (research: keeps every `CapturedRoom` in one world frame).
- Every room end also saves an `ARWorldMap` into that room's raw folder. If the app is backgrounded or the user comes back another day, `RoomScanEngine` starts with `initialWorldMap` and phase `.relocalizing` ("Go back to where you stopped", ARKit coaching overlay with goal `.tracking`). Success within 30 s marks the new scan `FrameLink.projectFrame`; otherwise the scan proceeds unaligned and is placed by hand afterwards (Line Up by Hand).
- Multiple floors: Add Floor increments `floorIndex`; the ARSession continues if the user walks the stairs while scanning; rooms are merged per floor.
- Merge: `StructureMerger` calls `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from:)` over the rooms of one floor whose frame is `projectFrame`. On `invalidRoomLocation` or `exceedSceneSizeLimit`, every room stays usable on its own and the alignment screen opens with the failing room highlighted ("These rooms didn't line up").
- Shared walls and doorways: from `CapturedStructure` when merging works; otherwise `CleanModelBuilder` pairs antiparallel wall faces 5 to 50 cm apart (measured wall thickness) and doors whose centers coincide within 30 cm (connection). Both are recorded in `CleanModel` so the plan draws one thick wall and a connected door.

### 3.5 Object mode

Object mode opens with a two-card choice (UX-first addition, one tap, pictures): **Small or medium object** (fits on a table or the floor, you can walk all around it) and **Large object** (furniture against a wall, appliance, vehicle). Default selection is small. The two use different engines because Apple's Object Capture gives the best texture for small things but caps output at `.reduced` detail and needs the object to be movable and textured, while large or fixed objects need the LiDAR mesh.

**Small or medium: `ObjectCaptureEngine`** (mirrors Apple's GuidedCapture sample, the only object path Apple guarantees):

| Engine state | ObjectCaptureSession | Primary button | Our overlay |
|---|---|---|---|
| `preparing` | `init()`, `start(imagesDirectory:configuration:)` with a fresh empty `raw/objectcapture/Images/` and `Checkpoint/` under `InProgress` | none | "Getting ready" |
| `ready` | `.ready` | Continue: `startDetecting()`; a `false` return shows "Can't find your object. It should be larger than 3 in (8 cm)" | tips link |
| `detecting` | `.detecting` | Start Capture: `startCapturing()`; Reset Box: `resetDetection()` | "Move around the object slowly" |
| `capturing(orbit)` | `.capturing` | shutter when `canRequestImageCapture` | shot counter `numberOfShotsTaken / maximumNumberOfInputImages`, guidance from `feedback` |
| `passReview(orbit)` | `userCompletedScanPass == true`; our sheet pauses the session (`pause()`, because a covering sheet does not auto-pause) | Finish, Show Missing Areas (next orbit), Flip | `ObjectCapturePointCloudView(session:).showShotLocations(true)` as the object quality screen, "Sides captured: N of 3" |
| `finishing` | `finish()`, wait for `.completed` | none | "Saving" |
| `reconstructing` | ObjectCaptureSession set to nil first, then `PhotogrammetrySession(input: imagesURL, configuration:)` with `.modelFile(url:)` (default `.reduced`) | Cancel | processing screen with `ProcessingStage` names and `estimatedRemainingTime` |

Guidance mapping from `ObjectCaptureSession.Feedback` (all switches carry `@unknown default`): `objectTooFar` to `.moveCloser`, `objectTooClose` to `.tooClose`, `environmentTooDark` and `environmentLowLight` to `.lightingPoor`, `movingTooFast` to `.moveSlower`, `outOfFieldOfView` to `.objectKeepInView`, `objectNotDetected` to `.objectKeepInView`, `overCapturing` ignored (counter turns red). Orbit guidance: orbit 1 done raises `.objectCaptureTop` (capture from higher), orbit 2 done raises "capture from lower" mapped to `.objectNeedsDetail`; flippable objects get the flip prompt through `beginNewScanPassAfterFlip()`. "Capture the left side / back" messages are not available on this path because Object Capture does not expose camera pose; Apple's capture dial shows the same information visually.

**Large object: `MeshScanEngine` in object focus.** Same `ARSessionHost` as rooms, no RoomPlan. The user taps the object once (raycast `.estimatedPlane`, `.any`); the engine seeds a target point and grows a gravity-aligned `OrientedBox` (Geometry `OrientedBox.fit(_:gravityAligned: true)`) from mesh vertices within 2 m of the target and above the floor plane (lowest large horizontal `ARPlaneAnchor`). `SectorCoverage` divides the space around the box into 8 azimuth sectors plus top; the detector compares the camera azimuth to the least-covered sector and raises `.objectCaptureLeft`, `.objectCaptureRight`, `.objectCaptureBack` or `.objectCaptureTop`; persistent red cells on the box surface raise `.objectMoveCloserToArea` / `.objectNeedsDetail`. Result: raw mesh cropped to the box (crop is an edit, raw keeps everything), textured by the same texturer as rooms.

### 3.6 Quick Measure

- Engine: `MeasureEngine` (ARSessionHost with mesh and plane detection, no RoomPlan, no keyframes, no coverage).
- Center reticle model (Apple Measure app convention): each frame the reticle ray from screen center is resolved by `SnapCandidates` in priority order: plane-plane-floor corners from `ARPlaneAnchor`s, edges where two classified planes meet, a CPU ray-triangle hit on the live `MeshRecorder` chunks (per-chunk `MeshBVH`, rebuilt lazily on chunk update), `ARRaycastQuery` `.existingPlaneGeometry`, then `.estimatedPlane`. Snapping radius is the smaller of 10 cm in world space or 24 pt on screen; a snap plays `Haptics.selection()` and shows "Snapped to corner".
- Add Point, Undo, Clear All, Save. Each committed point records depth and confidence at pick time, so `ConfidenceModel` produces the ± value live.
- Save creates a `quickMeasure` project containing `measure/points.json`, the measurements and `ARView.snapshot` as the associated photo. Nothing else is recorded.

### 3.7 Advanced Scan

Advanced is not a separate engine; it is the options screen producing `ScanSettings`, then one of the engines above.

| Option | Effect |
|---|---|
| What are you scanning: A space | `RoomScanEngine` if "Find walls, doors and windows" is on, else `MeshScanEngine` (outdoor structures, warehouses beyond RoomPlan limits) |
| What are you scanning: An object | Object size choice, then the matching object engine |
| Detail Standard / High / Maximum | keyframe gate 0.5 m or 20 deg / 0.3 m or 15 deg / 0.2 m or 10 deg; coverage "green" at 3 / 4 / 5 observations; atlas texel 4 / 3 / 2 mm |
| Keep all photos | on: every gated keyframe kept; off: gate doubled (half the photos). Raw is never thinned afterwards |
| Find furniture and appliances | RoomPlan objects kept in the clean model or dropped at build time (raw keeps them) |
| Scanning distance Close up / Normal / Far | coverage and mesh observation window 0.3 to 1.5 m / 0.3 to 3.5 m / 0.3 to 5.0 m; also sets tooFar thresholds |

### 3.8 Photos during a scan

Take Photo copies the current `capturedImage` (1920x1440) as JPEG plus the full `KeyframeRecord` into `photos/`. High-resolution stills (`captureHighResolutionFrame`) are deferred (research: one in flight, fails right after run, depth misaligned). In the viewer, Photos shows pins in 3D at the camera pose; tapping a pin flies the orbit camera to the photo viewpoint and shows the photo. Keyframes are also browsable there, which covers "images associated with scanned locations".

### 3.9 Interruptions, thermal and storage during capture

| Event | Source | Engine reaction | UI |
|---|---|---|---|
| App leaves foreground | `sessionWasInterrupted`, scene phase | phase `.paused(.interrupted)`, flush checkpoint, save world map | "Scan paused" alert on return, then relocalizing |
| Tracking limited | `cameraDidChangeTrackingState` | condition `.trackingLow` or `.trackingLost` | tier 1 message; ARCoachingOverlayView for relocalizing |
| Relocalization fails 60 s | timer | offer Finish with what was scanned | "Scan stopped. Mapper lost track of where you are. Your scan up to this point was saved." |
| Thermal `.serious` | `ProcessInfo.thermalStateDidChangeNotification` | coverage tick 1 Hz, overlay frozen (still collecting), keyframe gate doubled, hole detection off | tier 1 `.deviceHot` once |
| Thermal `.critical` or `deviceTooHot` | same, RoomPlan error | pause, checkpoint, seal on request | "Your iPhone is too hot" alert |
| Free space under 1 GB | `volumeAvailableCapacityForImportantUsage` every 10 s | stop keyframes; under 300 MB pause | "Not enough storage" with estimate |
| Battery under 20 percent, unplugged | UIDevice battery | log; one alert | "Battery is low" |
| Memory warning | `didReceiveMemoryWarningNotification` | drop overlay meshes of far chunks, flush recorder | none |

`UIApplication.shared.isIdleTimerDisabled` is true on scan and processing screens only.

## 4. Processing pipelines

### 4.1 Progressive processing, driven by what the user wants to see first

`ProcessingQueue` (in `Processing`) is a persistent job runner. Jobs are per project, per representation. It writes status to `derived/state.json` after every stage, so a jetsam kill or a relaunch resumes where it stopped, and the project list can show "Building model..." from the manifest alone.

```swift
enum Representation: String, Codable, CaseIterable { case clean, floorPlan, rawMesh, textured, objectModel, measurements, thumbnail }
enum RepresentationStatus: Codable, Equatable { case notApplicable, queued, building(stage: ProcessingStep, fraction: Double?), ready, failed(String), stale }
enum ProcessingStep: String, Codable { case shape, textures, clean, floorPlan, saving }   // maps 1:1 to Copy.Processing steps
@MainActor final class ProcessingQueue: ObservableObject {
    @Published private(set) var status: [ProjectID: [Representation: RepresentationStatus]]
    func enqueue(project: ProjectID, reason: ProcessingReason)
    func cancel(project: ProjectID)
}
```

Order per mode is chosen so that the first thing the user can look at arrives fastest:

| Mode | Stage order (each runs after the previous) | Viewer opens after | Typical time on A15 (estimate, to be logged) |
|---|---|---|---|
| Room | RoomBuilder to CapturedRoom, clean model, floor plan, auto measurements (stepClean, stepFloorPlan); then mesh consolidation (stepShape); then texturing (stepTextures); thumbnail | clean model and floor plan | 3 to 8 s to first view; 20 to 40 s raw mesh; 30 to 120 s textured |
| House (per room at room end) | RoomBuilder only; at Finish Building: StructureBuilder merge, clean model, plan, measurements; then per-room mesh and texture jobs | merged plan | 5 to 15 s to first view |
| Object small | PhotogrammetrySession (the only stage that blocks the UI, with live stage names and ETA); then convert to our mesh, box, dimensions, volume | object model | a few minutes |
| Object large | mesh consolidation, crop box, dimensions; then texturing | raw mesh | 10 to 30 s |
| Advanced space without layout | mesh consolidation, plane-based clean model (walls and floor only, marked estimated), floor plan from wall planes; texturing | raw mesh | 10 to 30 s |
| Quick Measure | thumbnail only | immediately | under 1 s |

The processing screen (`ProcessingView`) is shown only until the "viewer opens after" representation is ready; the remaining stages continue while the user is in the viewer, shown as per-tab progress chips ("Adding color and texture 40%"). If the user leaves the app, work pauses with the app (no background execution on iOS 18; `BGContinuedProcessingTask` behind `#available(iOS 26, *)` in a later build) and resumes on return. The texturer checkpoints after view selection and after each atlas page so a restart does not start from zero.

### 4.2 Stages, queues and memory budgets

Memory ceiling: the per-app limit on a 6 GB iPhone 13 Pro Max is unmeasured (community about 3 GB). Build 3 logs `os_proc_available_memory()` at launch, scan end and each stage. Budgets below keep every stage under 700 MB peak and run only one heavy stage at a time.

| Stage | Input | Output | Runs on | Peak memory budget | Notes |
|---|---|---|---|---|---|
| `RoomBuild` | `capturedroomdata.json` | `capturedroom.json` | Swift `Task` (RoomBuilder is async) | 100 MB | `RoomBuilder(options: [.beautifyObjects])`; failure keeps raw, marks clean `failed` with Try Again |
| `StructureMerger` | CapturedRooms of one floor | `capturedstructure.json` | `Task` | 200 MB | failure path in 3.4 |
| `CleanModelBuilder` | CapturedRoom or CapturedStructure, coverage grids, consolidated mesh (optional, for thickness and occlusion) | `cleanmodel.json` | `processing.queue` (serial, utility) | 50 MB | wall lines from `transform` times (plus or minus width / 2, 0, 0); room outline from `floors[0].polygonCorners` through the full transform, fallback to intersecting consecutive wall lines; openings projected onto the parent wall via `parentIdentifier` and clamped; curved walls from `curve`; ceiling height = median of high-confidence wall heights; wall provenance patches from coverage (observed = measured, cells behind a `CleanObject` box with no observation = occluded, never seen = unscanned) |
| `FloorPlanBuilder` | `CleanModel` | `floorplan.json` | `processing.queue` | 20 MB | plan x = world x, plan y = -world z; walls drawn from interior faces offset outward by thickness (room areas unchanged); door swing heuristic (hinge near the closer corner, opens into the room containing center + 0.3 m normal), all flagged not user-set; dimension strings per wall and overall |
| `AutoMeasurements` | `CleanModel` | `measure/auto.json` | `processing.queue` | 5 MB | section 6 |
| `MeshConsolidator` | `raw/mesh/*.mchk` | `consolidated.mchk` (+ optional `bvh.bin`) | `processing.queue` | 400 MB | merge chunks, weld at 1 mm with the Geometry spatial hash (`welded(tolerance:)`), drop components under 200 triangles, keep per-face classification; if over 800k triangles, vertex-clustering decimation to 800k (own code, 1 cm grid) and keep the full one too |
| `Texturing` | consolidated mesh, keyframes | `texmesh.mchk`, `atlas_n.jpg` | `texturing.queue` plus `DispatchQueue.concurrentPerform` with 3 workers | 700 MB | 4.3 |
| `ObjectModelBuilder` | `objectcapture/Images` | `model.usdz`, `mesh.mchk` | `Task` iterating `PhotogrammetrySession.outputs` (wrapped so it ends at `processingComplete`) | whatever Photogrammetry needs; everything else idle, ObjectCaptureSession released first | `MDLAsset(url:)` then `childObjects(of: MDLMesh.self)` buffers to our `TriangleMesh` for box, volume and picking; bounding box and extents in meters |
| `LargeObjectBuilder` | consolidated mesh, crop box edit | cropped mesh, OBB | `processing.queue` | 200 MB | volume only when `isWatertight` after crop, else "Volume unavailable" |
| `ThumbnailRenderer` | first ready representation | `thumbnail.jpg` | main (RealityKit offscreen `ARView.snapshot` of a hidden view is fragile, so plan-based thumbnails use `PlanRenderer` into `UIGraphicsImageRenderer`; object thumbnails use the first Object Capture image) | 30 MB | |
| `CoverageFinalizer` | live grid | `grid.bin`, `quality.json` | at Finish on `capture.queue` | 10 MB | |

### 4.3 Texturing (CPU first, Metal only if the device says so)

The texturing research recommends a GPU pipeline but also documents a shipping iOS app (ScanSpace) doing per-face best view, charts and a Core Graphics bake on the CPU in 10 to 60 s. The UX-first choice is the CPU path for the first textured build, because it can be written and reviewed without Metal shader compile risk, and it yields a correct atlas that the UI can show. A Metal view-selection kernel is the documented upgrade if logs show the CPU path exceeding 120 s for a typical room.

1. `KeyframeIndex`: load all `KeyframeRecord`s; per keyframe precompute world-to-camera and the scaled intrinsics for the 256x192 depth (scale 256/imageWidth).
2. `ViewSelector`: for each face and each keyframe whose frustum contains the face bounds: project the three vertices with the verified convention (`c = inverse(cameraToWorld) * p; z = -c.z; u = fx * c.x / z + cx; v = -fy * c.y / z + cy`), reject if outside a 16 px margin, back-facing (cos under 0.2), nearer than 0.2 m or farther than the range limit, or occluded by the LiDAR depth test (project, sample the 2x2 minimum of the keyframe depth, accept if `z <= depth + 0.03 + 0.03 * depth`, skip low confidence). Score = projected area x cos x sharpness. Keep best and second best per face. Then 3 passes of neighbour smoothing (candidate must keep 30 percent of the best score) to reduce chart count. Parallelized over face ranges.
3. `ChartBuilder`: connected faces with the same keyframe form charts; split recursively until each chart's source rectangle is at most 1024 px and fill ratio at least 0.35; 4 px padding.
4. `AtlasPacker`: shelf packing into 4096x4096 pages at a global scale that fits Detail's texel size, at most 4 pages.
5. `AtlasBaker`: keyframe by keyframe: decode JPEG with ImageIO (never more than two decoded at once), draw each chart's source rectangle into its page `CGContext`; flood fill untextured texels from neighbours; dilate 4 px; encode each page as JPEG (quality 0.85).
6. `TexturedMeshBuilder`: split vertices per chart, write UVs with top-left origin into `texmesh.mchk`. The viewer flips v once when building the RealityKit mesh; OBJ export flips v once; GLB and USDZ keep what their writers expect (the flip lives in `SceneAdapter`, one place).
7. Display styles from one atlas: Photo Realistic = full-resolution atlas with a per-keyframe gain correction (build 7, seam gain solve); Textured = the same atlas without gain correction in build 5, so both styles exist from the first textured build and differ once gain correction lands. No vertex-color shader is needed anywhere (the research shows vertex colors need a CustomMaterial or ShaderGraphMaterial that is unverified on iOS). PLY export gets per-vertex colors by sampling the atlas at each vertex UV.

A texture failure never fails the project: the raw mesh and clean model stay ready and the user sees "Color couldn't be added. Your model is saved without color."

### 4.4 Coverage and quality (live and at Finish)

- `CoverageGrid`: `[UInt64: CoverageCell]` where the key packs integer (x, y, z) of 10 cm cells and `CoverageCell` holds `observations: UInt8` (saturating), `bestConfidence: UInt8`, `classMask: UInt8` (wall, floor, ceiling, object from mesh classification), `seenByKeyframe: Bool`, `isHoleEdge: Bool`. A 9 x 9 x 3 m room is at most about 240k cells, typically 20k to 40k (about 1 MB).
- `CoverageTracker` (3 Hz, `coverage.queue`): the research algorithm (faces in view, stride 4, 0.3 to 4 m, facing within 60 degrees, depth confidence at least medium, increment). Cell state: 0 observations = gray (not scanned), observed but under threshold = yellow, threshold reached = green, expected but inside a detected hole or persistently low-confidence = red. "Expected" comes from `ExpectedSurfaces` (RoomPlan walls minus openings, floor polygon, ceiling = floor polygon at ceiling height); without RoomPlan, expected = cells adjacent to observed cells on the same plane (holes).
- `QualityAnalyzer` produces the Scan Quality numbers exactly as shown on the quality screen:

| Row (Copy.Quality) | Formula |
|---|---|
| Shape | area-weighted green-or-yellow fraction of all expected cells, multiplied by the RoomPlan quality factor (1.0 all edges complete and high confidence, 0.85 missing edge, 0.7 medium, 0.5 low) |
| Walls | observed wall area / expected wall area (research formula: faces classified wall within 10 cm of the wall plane and inside its rectangle) |
| Floor | same for the floor polygon |
| Ceiling | same for the ceiling; "not applicable" when Range is Close up or in object modes |
| Color and texture | expected cells that were seen by at least one keyframe at a good angle / expected cells |
| Sides captured (objects) | covered sectors out of 9 (large) or completed orbits out of 3 (small) |
| Missing areas | clusters (flood fill over red and gray expected cells) larger than 0.25 square meters; windows, mirrors and persistently low-confidence regions near a RoomPlan window are excluded and never nagged about |

Verdict: good when every applicable metric is at least 0.9 and there are no missing areas (button reads Finish), okay at 0.7, otherwise poor (button reads Finish Anyway).

- `MissingAreaFinder` returns up to 8 `MissingArea`s sorted by area, each with a suggested viewpoint 1.5 m from the area center along its normal (clamped inside the room outline) so the tour can point the user somewhere standable.

## 5. Rendering and viewer

### 5.1 Live scan rendering

- Host: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)` in `ARViewContainer: UIViewRepresentable`, created once in `makeUIView` and never recreated in `updateUIView`.
- `CoverageOverlay`: one `ModelEntity` per mesh anchor under an `AnchorEntity(world: .zero)` (chunks are already world space). Each entity owns a `LowLevelMesh` (interleaved position float3 + normal float3, `uint32` indices, capacity 1.5x, recreated only when exceeded) with 4 parts, one per `CoverageState`, each part using one of 4 `UnlitMaterial(color:)` with `blending = .transparent(opacity:)` 0.45 and `faceCulling = .none`. Face indices are written sorted by state, so coloring needs no shader. Updates are coalesced in a dirty set flushed at most every 0.5 s, only for chunks in the view frustum; CPU buffers are built on `coverage.queue`, copied into the `LowLevelMesh` on main (`withUnsafeMutableBytes`, `withUnsafeMutableIndices` are main actor). Scene understanding occlusion is off while scanning (z-fighting with the overlay).
- `RoomOutlineOverlay`: RoomPlan walls, doors, windows and objects as thin line boxes (`MeshResource.generateBox(size:)` with `triangleFillMode = .lines`), rebuilt from `didUpdate room` at most 2 Hz. In layout-only degraded mode, wall boxes get coverage-state colors instead.
- `TourMarker`: a pulsing ring at the target area and a screen-edge arrow drawn in SwiftUI from `ARView.project(_:)` of the target (nil or off screen means edge arrow toward the target direction computed from the camera transform).
- Mini map (SwiftUI `Canvas`): top-down wall segments from RoomPlan, the user's position and heading, missing-area dots, room names in House mode. Always small in the bottom corner; tap to enlarge. It is the same drawing code (`PlanRenderer`) as the floor plan, at a different scale and style.
- Thermal ladder: at `.serious` overlays stop updating (last colors stay) and the ARView `preferredFramesPerSecond` drops to 30.

### 5.2 Post-scan viewer

- Host: `ARView(frame:cameraMode: .nonAR, automaticallyConfigureSession: false)` in `ModelViewerView: UIViewRepresentable` (non-deprecated, has `project`, `ray(through:)`, `hitTest`, `snapshot`). Camera: a `PerspectiveCamera` driven by `OrbitCamera` (yaw, pitch, distance, target) from UIKit gesture recognizers on the ARView: one-finger drag orbits, pinch zooms, two-finger drag pans, double tap focuses. RealityView is not used because its camera controls take one mode at a time.
- `SceneAssembler` builds one parent entity per representation from plain Core data: raw mesh chunks (`LowLevelMesh` per 64k-vertex block, classification colors as parts), textured mesh (per atlas page a part with `UnlitMaterial(texture:)`, `TextureResource(image:withName:options:)` with semantic `.color`), clean model (walls as boxes with thickness, openings as cut boxes drawn as frames, objects as boxes, floor as extruded polygon; provenance styles below), object model (Photogrammetry USDZ loaded with `Entity(contentsOf:)`, iOS 18). Switching views toggles `isEnabled` on parents; nothing is rebuilt.
- Display styles (Copy.Viewer): Photo Realistic and Textured use the textured parent; Solid Color swaps materials to a lit `SimpleMaterial` gray; Wireframe sets `triangleFillMode = .lines` on the current materials; Raw Scan shows the raw mesh with classification colors. Styles unavailable for a representation are disabled with the reason ("Not available: color wasn't captured").
- Provenance styles in 3D Clean: measured = solid; estimated and inferred = 50 percent transparent with a hatched texture; occluded = dark hatched; unscanned = outline only. The legend sheet (Copy.Measure legend strings) explains them. Hide Furniture disables every entity whose category `isMovable` and reveals the occluded patches behind it; it never shows invented geometry as measured.
- Picking: elements (walls, openings, objects) get simple box `CollisionComponent`s from `ShapeResource.generateBox(size:)`, so `ARView.hitTest` returns the element entity reliably. Surface points for measuring use `ARView.ray(through:)` plus the Geometry `MeshBVH.raycast` on the consolidated (or object) mesh, not collision meshes: exact triangle, normal and distance, no dependency on `generateStaticMesh` behavior. BVH build for 800k triangles runs once per viewer session on `processing.queue`, with a small spinner on the Measure button until ready.
- Labels: measurement values and element names are SwiftUI views positioned with `ARView.project(_:)` each frame from a `CADisplayLink`-driven layout pass in the view model, hidden when behind the camera.
- Floor Plan view: SwiftUI `Canvas` calling `PlanRenderer.draw(floor:into:transform:style:)` through `context.withCGContext`. Pan and zoom with `DragGesture` and `MagnifyGesture` (iOS 17). Labels drawn in screen space so text does not scale. The same renderer draws PDF pages and PNG exports.

## 6. Measurements and confidence

### 6.1 Where measurements come from

| Measurement | Source | Provenance | Tool |
|---|---|---|---|
| Point-to-point distance | two `MeasurePoint`s (live reticle or viewer tap) | measured | Measure tool |
| Wall length, height, area | `CleanWall` interior face; area minus openings | measured if wall coverage at least 0.7 and both ends have completed edges, else estimated | automatic, tap wall then Measure |
| Ceiling height | median high-confidence wall height, cross-checked with ceiling plane from mesh if present | measured or estimated | automatic |
| Door width and height, window size | `CleanOpening` | measured (RoomPlan) | automatic, tap door or window |
| Room length and width | minimum-area rectangle of the room outline (Geometry OBB 2D via rotating calipers) | derived from measured | automatic |
| Room area, floor area, perimeter | `Polygon2D.area`, `perimeter` of the room outline | derived | automatic |
| Surface area | sum of triangle areas of the selected mesh region or element | measured | viewer, lasso on object or wall |
| Angle | three points or two walls | measured | Measure tool, angle mode |
| Object width, height, depth | gravity-aligned `OrientedBox` of the object mesh (large, small) or RoomPlan box (room objects) | measured | object summary, tap object |
| Estimated volume | `TriangleMesh.signedVolume` only when `isWatertight`; otherwise shown as "Volume unavailable: part of the object wasn't scanned"; for RoomPlan boxes never shown (a box is not the object) | estimated | object summary |

Automatic measurements are generated once per clean model build and stored in `derived/measure/auto.json`; user measurements live in `edits/measurements.json`. Both display through the same `SavedMeasurement` list.

### 6.2 Confidence model (`ConfidenceModel`)

Straight from the verified quality research, in meters:

- depth term per endpoint: `sigmaDepth = (0.005 + 0.004 * d) * k`, k = 1 / 1.5 / 3 for high / medium / low depth confidence at pick time; divided by `sqrt(min(n, 9))` for n observations of that point's coverage cell, floored at 0.004.
- pose term: `0.005 * L` if tracking was normal for the whole scan, `0.015 * L` if any limited tracking occurred, `0.03 * L` after a relocalization (from `timeline.jsonl`).
- pick term per endpoint: 0.003 snapped RoomPlan corner (high confidence), 0.01 plane raycast, 0.02 raw mesh hit, 0.03 estimated plane raycast.
- `sigma = sqrt(sum of squares)`; displayed value is plus or minus 2 sigma, floored at 1 cm (0.4 in), rounded up to 0.5 cm or 1/8 in via `Tolerance.plusMinus`. RoomPlan-derived wall lengths are never shown better than plus or minus 2.5 cm.
- When sigma exceeds 4 cm the value is shown with "Low confidence, rescan this section" and a Rescan This Section button (which opens the scan in Continue Scanning with that wall as a tour target).
- Areas and volumes propagate first order (relative sigma of each dimension added in quadrature).
- Every measurement screen carries the disclaimer string once; nothing says "survey grade".

### 6.3 Snapping

`SnapCandidates` builds, per view, candidate sets for `Snap` (Geometry): corners (RoomPlan wall polygon corners, wall-wall-floor intersections computed from the clean model, opening corners, object box corners), edges (wall lines at floor and ceiling, opening edges, object box edges), planes (walls, floor, ceiling). Priority corner, then edge, then plane, then raw mesh. The UI names the target with `Copy.Measure.snapped(to:)` using the existing `snapTargets` words. Snap can be turned off with the existing toggle.

## 7. Exports (reusing feat/export)

`ExportCoordinator` builds plain inputs and calls the briefed writers; it never writes bytes itself except the JSON summary. Files are staged in `exports/<timestamp>/` and shared with `ShareLink` (single file) or a STORE zip (folders such as OBJ with textures).

| Export (Copy.Export label) | Source representation | Adapter to | Writer | Notes |
|---|---|---|---|---|
| USDZ | textured mesh (or solid if no color); object model file as is for small objects | `ExportScene` | `USDZWriter`; fallback `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18) on a written usda if the self-test flags a problem | Quick Look preview via `.quickLookPreview` |
| USDZ (architectural, clean) | CapturedRoom or CapturedStructure | none | `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions: .parametric)` | offered under USDZ as "Clean model" option; file name never starts with a digit |
| OBJ | textured or raw mesh, clean model as boxes | `ExportScene` | `OBJWriter` (+ MTL + atlas JPEGs, v flipped) | zipped folder |
| PLY | raw consolidated mesh with vertex colors sampled from the atlas | `ExportScene` | `PLYWriter` binary | "The raw scan with color" |
| STL | object mesh or raw mesh | `ExportScene` | `STLWriter` binary | shape only |
| glTF | textured mesh | `ExportScene` | `GLBWriter` | |
| PDF Floor Plan | `FloorPlan` + edits + toggles | `Plan2D` via `PlanAdapter` | `PDFPlanWriter` | one page per floor; scale picked by the writer |
| SVG | same | `Plan2D` | `SVGWriter` | |
| DXF | same | `Plan2D` (layers A-WALL, A-DOOR, A-GLAZ, A-ANNO-DIMS, A-FLOR-IDEN, A-FURN) | `DXFWriter` | dimension text pre-formatted by `Units` |
| JSON | rooms, walls, openings, objects, measurements with confidence and provenance | `MeasurementsJSON` (own `Codable` DTOs, versioned) | JSONEncoder | for developers |
| Images | current 3D view snapshot (`ARView.snapshot`) and plan PNG (`PlanRenderer` into `UIGraphicsImageRenderer`) | none | ImageIO | also "Save to Photos" (existing usage string) |
| Back Up | whole package | none | `StreamingZip` | `.mapperbackup` |

Export options (Copy.Export): Include textures, Include hidden objects (edits applied or not), Include measurements (plan dimensions, JSON), Units (from `UnitPreferences`). Unavailable formats are listed with the reason instead of hidden.

`SceneAdapter` is the single place that knows axis and UV conventions: world meters, Y up, right handed for every writer; top-left UV internally, flipped where a writer expects bottom-left.

## 8. UX flow and state machines

This is the part the rest of the design serves. Every screen below names its SwiftUI view, its view model and the state it renders. View models are `@MainActor final class ...: ObservableObject` with `@Published` properties (no `@Observable` macro). All text comes from `Copy`; all lengths, areas and volumes from `Units`.

### 8.1 Screen map

```
MapperApp
 └ AppRootView (AppRouter: NavigationStack path)
    ├ ProjectListView ............ ProjectListViewModel     (Home: New Scan, search, sort, archived)
    │   └ ProjectDetailView ....... ProjectViewModel         (house: room list; others: open viewer)
    │       └ ViewerScreen ........ ViewerViewModel          (Realistic | 3D Clean | Floor Plan | Raw Scan)
    │            ├ MeasureOverlay ... MeasureToolModel
    │            ├ ElementMenuSheet . ElementMenuModel        (object menu, wall menu)
    │            ├ FloorPlanEditorView PlanEditorModel
    │            ├ PhotosSheet
    │            ├ CropOverlay ...... CropModel               (objects)
    │            └ ExportSheet ...... ExportViewModel
    ├ SettingsView ............... SettingsViewModel         (units, tips, haptics, storage, debug, demo mode)
    └ ScanFlowCover (fullScreenCover) ScanFlowModel
        ├ ModePickerView            (Room, House / Building, Object, Quick Measure, Advanced Scan)
        ├ ObjectSizePickerView      (small or medium, large)
        ├ AdvancedOptionsView
        ├ TipsView                  (once per mode, Don't show again)
        ├ CameraPermissionView
        ├ ScanScreen .............. ScanViewModel + GuidanceEngine
        │   ├ ARViewContainer / ObjectCaptureView
        │   ├ GuidanceBanner, CoverageLegend, MiniMapView, TopBar (Cancel, timer, Pause), BottomBar (Take Photo, Done)
        │   ├ QualitySheet ......... QualityViewModel          (over the live camera)
        │   ├ TourHUD                                          (Show Missing Areas)
        │   ├ HouseProgressSheet ... HouseViewModel            (over the live camera)
        │   ├ NameRoomSheet
        │   └ ObjectPassReviewSheet                            (ObjectCapturePointCloudView)
        ├ MeasureScreen ........... MeasureToolModel (live)
        └ ProcessingView .......... ProcessingViewModel        (until first representation is ready)
```

Navigation rules: scanning is always a `fullScreenCover` (no back swipe mid-scan, portrait only, dark HUD, `persistentSystemOverlays(.hidden)`); results and editing are pushed on the `NavigationStack`; destructive actions use `confirmationDialog`; errors use `alert` with the `Copy.Errors` title and body.

### 8.2 Scan flow state machine (`ScanFlowModel`)

```swift
enum ScanFlowState: Equatable {
    case pickMode
    case pickObjectSize
    case advancedOptions
    case tips(ScanMode)
    case permission(PermissionState)
    case scanning(ScanMode)                 // ScanScreen or MeasureScreen; the engine owns the sub-phases
    case houseBetweenRooms                  // ScanScreen with HouseProgressSheet, session alive
    case sealing
    case processing(ProjectID)
    case finished(ProjectID)                // cover dismisses, router pushes ViewerScreen
    case cancelled
}
```

| From | Event | To | Side effects |
|---|---|---|---|
| pickMode | Room / House / Quick Measure | tips(mode) or permission | create draft `ProjectManifest` in memory (not on disk yet) |
| pickMode | Object | pickObjectSize | |
| pickMode | Advanced Scan | advancedOptions | |
| pickObjectSize, advancedOptions | Start | tips or permission | `ScanSettings` fixed |
| tips | Start Scan / Skip | permission | Don't show again stores `SettingsKey` per mode |
| permission | authorized | scanning | engine created and started; project folder created in `InProgress` |
| permission | denied | stays, shows Open Settings | |
| scanning | Cancel, confirm Discard Scan | cancelled | `engine.cancel()`, delete InProgress |
| scanning | Finish (from QualitySheet) in room, object, advanced | sealing | `engine.finish()` |
| scanning | Finish in house | houseBetweenRooms | room sealed, RoomBuilder queued, NameRoomSheet first |
| houseBetweenRooms | Scan Next Room / Rescan / Continue Scanning | scanning(.house) | `run(configuration:)` on the same RoomCaptureSession |
| houseBetweenRooms | Finish Building | sealing | stop session, merge queued |
| sealing | sealed | processing | package moved to Documents, `ProcessingQueue.enqueue` |
| processing | first representation ready | finished | haptic success, cover dismisses to ViewerScreen |
| processing | failure with raw safe | finished | viewer opens with failed tab and Try Again |
| scanning (Quick Measure) | Save | finished | tiny project written directly |

### 8.3 Live scan phases and the scan screen

`ScanViewModel` renders `LiveScanSnapshot.phase`:

| Phase | Top bar | Center | Bottom bar | Transitions |
|---|---|---|---|---|
| starting | Cancel | "Getting ready. Move your phone slowly." | disabled | first normal tracking frame to running |
| running | Cancel, timer, Pause | guidance banner, coverage colors, outlines, legend chip | Take Photo, Done | Pause to paused(.user); tracking loss to relocalizing; Done to qualityCheck |
| paused(reason) | Cancel | "Paused. Go back to where you stopped, then tap Resume." | Resume | Resume to relocalizing (if interrupted) or running |
| relocalizing | Cancel | ARCoachingOverlayView + tier 1 "Tracking lost..." | none | tracking normal to running; 60 s to failed offer |
| qualityCheck | none (sheet) | QualitySheet over live camera; coverage keeps updating underneath | sheet buttons | Show Missing Areas to touring; Keep Scanning to running; Finish to finishing |
| touring(i, n) | "Missing area i of n", End Tour | TourHUD arrow, ring, distance, guidance | Next Area | area filled: "That area is filled in", auto advance after 1.5 s; last: "No more missing areas" and back to qualityCheck with fresh numbers |
| finishing | none | "Saving" | none | sealed |
| failed(error) | Close | alert from `Copy.Errors` | | raw saved when possible |

The quality sheet (`QualitySheet`) shows the Copy.Quality rows as bars with percent, the verdict summary line, Missing areas count, and buttons: Show Missing Areas (only when count > 0), Finish or Finish Anyway, and Keep Scanning. It is a medium-detent sheet so the camera, colors and mini map stay visible above it, which makes "the red area" in the copy something the user can actually see.

### 8.4 Guidance arbitration (`GuidanceEngine`)

Pure logic, no UIKit, injected clock, self-tested. It implements the 11 display rules of `UX_COPY.md` section 4 using the constants already in `GuidancePolicy`.

```swift
struct GuidanceDisplay: Equatable { var kind: GuidanceKind?; var shownSince: TimeInterval; var playHaptic: Bool; var announce: Bool }
final class GuidanceEngine {
    init(clock: @escaping () -> TimeInterval, hapticsEnabled: Bool)
    func update(conditions: Set<GuidanceKind>, events: [LiveEvent], mode: ScanMode) -> GuidanceDisplay
    func reset()
}
```

Internal state: first-true time per condition (0.75 s hold), last-shown time per kind (10 s no-repeat), time of last tier 1 (5 s tier 3 quiet), rolling tier 3 timestamps (4 per minute), last haptic time (5 s), current message and its start, last hide time (3 s gap, tier 1 exempt). Priority: lowest tier, then the table order of `GuidanceKind.allCases`. Tier 1 stays while its condition holds. Events (door found and so on) become tier 3 conditions true for 2 s.

Detectors (`GuidanceDetectors`, run on `capture.queue` each snapshot) raise conditions:

| Condition | Rule |
|---|---|
| trackingLost | `trackingState == .notAvailable` or limited(.relocalizing) |
| trackingLow | limited(.excessiveMotion) or limited(.insufficientFeatures) for 1 s |
| lightingPoor | `ambientIntensity < 250` for 2 s, or RoomPlan `turnOnLight`, or Object Capture low light |
| moveSlower | angular speed above 90 deg/s or linear above 0.8 m/s for 0.5 s, or RoomPlan `slowDown` |
| tooClose | median depth of the center 32x24 depth patch under 0.25 m, or RoomPlan `moveAwayFromWall` |
| tooFar | more than 70 percent of depth pixels invalid or beyond the Range limit for 1.5 s |
| deviceHot | thermal `.serious` (once per scan) |
| objectMoved | large object: OBB center drift above 5 cm between coverage ticks |
| moveCloser | RoomPlan `moveCloseToWall`, or view median depth above 3.5 m while cells in view stay yellow |
| scanCorner | a RoomPlan wall within 3 m in view lacks `.left` or `.right` in `completedEdges` near the user after 20 s |
| pointAtFloor | floor metric under 0.3 after 30 s and camera pitch above minus 15 deg for 10 s |
| scanCeiling | ceiling metric under 0.2 after 45 s and pitch below 15 deg for 10 s |
| scanDoorwayBothSides | house mode: a door of this room within 1.5 m and the door's other side not covered |
| needsAnotherPass | more than 30 percent of expected cells in view are red |
| object sector kinds | 3.5 |
| windowDetected, doorDetected, wallDetected, openingDetected, stairsDetected | RoomPlan new element events (walls only for the first 3) |
| roomLooksComplete, objectLooksComplete | QualityAnalyzer quick estimate reaches the good verdict |

RoomPlan `lowTexture` raises `trackingLow` only if ARKit tracking is also limited; otherwise it is logged and ignored (a plain wall is not the user's fault).

### 8.5 House progress (`HouseViewModel`)

Rows: rooms in scan order with status (done with checkmark, needs additional scan with warning, not scanned) using `Copy.House.roomDone`, `roomNeedsScan`, `roomNotScanned`; progress summary; per-floor sections with Add Floor; buttons Scan Next Room and Finish Building. A room's status is `needsScan` when its QualityReport verdict was poor or the user chose Finish Anyway with missing areas. Tapping a row offers Rescan or Continue Scanning (new scan, same `RoomID`, tour preloaded with that room's missing areas). The same view (`RoomListView`) appears in `ProjectDetailView` for returning later; from there, Continue Scanning starts a relocalizing session from the latest world map.

Alignment (`AlignmentView`, `AlignmentViewModel`): shown after a failed merge or for unaligned rooms. Top-down plan of aligned rooms plus the loose room; one-finger drag moves, two-finger rotate rotates; snapping aligns parallel walls (touching faces with gap equal to thickness) and coincident doors; Done stores `FrameLink.manual(transform)` in `edits/alignment.json`. Scan Doorway Again starts a short scan of the doorway on a new session.

### 8.6 Viewer (`ViewerViewModel`)

```swift
enum ViewerTab: String, CaseIterable { case realistic, clean, floorPlan, raw }
enum DisplayStyle: String, CaseIterable { case photoRealistic, textured, solidColor, wireframe, rawScan }
enum ViewerTool: Equatable { case none, measure, crop, editPlan, photos, inspect(ElementID) }
```

| Tab | Shows | Available when | Placeholder while building |
|---|---|---|---|
| Realistic | textured mesh (room) or object model | textured or objectModel ready | chip "Adding color and texture N%" over the raw mesh in solid color |
| 3D Clean | clean model with provenance styles | clean ready (not for objects: tab hidden) | "Finding walls, doors and furniture" |
| Floor Plan | `FloorPlanView` read mode | floorPlan ready (objects: empty state `Copy.Empty.noFloorPlan`) | "Drawing the floor plan" |
| Raw Scan | consolidated mesh, classification colors | rawMesh ready | "Building the shape" |

Toolbar per tab: Measure, Hide Furniture (clean and plan), Photos, Export, Edit (plan: opens the editor; clean: enables element selection), Crop (object tabs), Display (realistic and raw). The object summary card (Width, Height, Depth, Estimated volume, Show Box) sits under the 3D view in object projects.

Element selection: tap in 3D Clean hits the element entity; the sheet shows the Copy.ObjectMenu or Copy.WallMenu actions, the element's measurements with confidence, and for guessed labels "Mapper thinks this is a table. Tap to correct it." Move and Rotate enter a gizmo mode (drag on the floor plane, two-finger rotate), each commit is one edit.

### 8.7 Edits (overlay model, undoable)

```swift
// Core/EditModel.swift
enum EditOperation: Codable, Equatable {
    case renameElement(ElementID, String)
    case setCategory(ElementID, ElementCategory)
    case setHidden(ElementID, Bool)
    case deleteFromClean(ElementID)
    case moveElement(ElementID, CodableMatrix4)          // new pose
    case setWallLine(ElementID, CodableVector2, CodableVector2)
    case setWallThickness(ElementID, Float)
    case addWall(PlanWall)
    case deleteWall(ElementID)
    case addOpening(PlanOpening)
    case updateOpening(PlanOpening)
    case deleteOpening(ElementID)
    case renameRoom(RoomID, String)
    case mergeRooms([RoomID], into: RoomID)
    case splitRoom(RoomID, lineA: CodableVector2, lineB: CodableVector2, newRoom: RoomID)
    case addAnnotation(PlanAnnotation)
    case deleteAnnotation(ElementID)
    case setCropBox(CodableOrientedBox?)
    case setDoorSwing(ElementID, DoorSwing)
}
struct EditLog: Codable { var operations: [EditOperation]; var cursor: Int }   // cursor < count means redo available
enum EditApplier {
    static func apply(_ log: EditLog, to model: CleanModel) -> CleanModel
    static func apply(_ log: EditLog, to plan: FloorPlan) -> FloorPlan
}
```

Undo and redo move the cursor; a new operation after an undo truncates the redo tail; Reset to Scan empties the log (with confirmation). Edits are saved after each operation (small file, atomic write). Because both 3D Clean and Floor Plan read `EditApplier` output, a wall moved in the plan moves in 3D and the other way round. Raw scan data and derived files are never modified by edits; measurements referencing an edited element are recomputed from the edited model and flagged "Estimated, not measured" when the edit changed their geometry.

### 8.8 Floor plan editor (`PlanEditorModel`)

```swift
enum PlanEditMode: Equatable { case select, addWall, addDoor, addWindow, addOpening, split, merge, measure, addText, addSymbol, addNote }
enum PlanSelection: Equatable { case none, wall(ElementID), opening(ElementID), room(ElementID), dimension(ElementID), annotation(ElementID) }
```

- Select: tap hit-tests in plan space (segment distance under 12 pt converted by zoom). A selected wall shows handles: drag body moves along its normal keeping neighbours joined; drag an end handle changes length with snapping (endpoints 5 cm, angles 0/45/90 deg, grid 10 cm or 1 in); the inspector offers Wall Length (typed value parsed by `LengthParser`), Wall Thickness, Delete Wall, Add Door / Window / Opening at the tapped position.
- Openings: drag along the wall, handles resize, Flip Door Swing.
- Add Wall: tap start, tap end, snapping as above. Split: draw a line across a room (Copy.FloorPlan.splitHint). Merge: tap rooms (mergeHint), Done.
- Measurement, text, symbol, note tools place annotations; symbols come from a small fixed set (outlet, switch, light, vent, drain, north arrow).
- Toggles bar: Furniture, Measurements, Room Names, Doors and Windows, Fixtures, Grid, Scale, stored per project.
- Undo, Redo, Done Editing, Reset to Scan; the footer always reads "Edits never change your original scan."

### 8.9 Project list and actions

`ProjectListViewModel` loads `ProjectSummary`s from a small index (`Documents/Projects/index.json`, rebuilt from manifests if missing). Rows show thumbnail, name, subtitle by mode (Copy.Home subtitles), and badges: processing ("Building model...") from `ProcessingQueue`, needs work ("Needs another scan") from room statuses. Swipe and context menu actions: Rename, Duplicate (copies the package; raw copied read-only, new project id), Archive / Unarchive, Delete (confirmation with Copy.Project.deleteBody), Export, Back Up. Restore from Backup lives in the list's menu and uses a document picker for `.mapperbackup` files. Settings shows storage used per project with a "Free up space" action that deletes `derived/` of archived projects and superseded scans (never active raw).

### 8.10 Errors and edge states map

| Situation | Screen | Copy |
|---|---|---|
| No LiDAR (`supportsSceneReconstruction` false) | Mode picker disables scan modes, Quick Measure stays with plane raycasts | `Copy.Errors.noLidar` |
| Object Capture unsupported | small-object card disabled, large enabled | `Copy.Errors.objectUnsupported` |
| RoomPlan unsupported but LiDAR present | Room mode runs mesh engine | none |
| Processing failed | viewer tab error card with Try Again and "Try with less detail" | `Copy.Errors.processingFailed` |
| Texture failed | Realistic tab shows solid mesh and the notice | `Copy.Errors.textureFailed` |
| Export failed | export sheet inline error | `Copy.Errors.exportFailed` |
| Save failed | alert, raw stays in InProgress and is offered on next launch ("Recover unfinished scan") | `Copy.Errors.saveFailed` |

Crash recovery: at launch `ProjectStore` looks in `InProgress/`; a scan with mesh chunks or keyframes is offered as "Recover unfinished scan" and is sealed as is.

### 8.11 Copy additions this design needs

To be added to `docs/UX_COPY.md` and `Copy.swift` together (proposed keys): object size choice (`Modes.objectSmall`, `objectSmallDetail`, `objectLarge`, `objectLargeDetail`, `objectTapToSelect`), scanning (`Scanning.relocalizing`, `Scanning.keepCameraUp`, `Scanning.roomTooBig`, `Scanning.miniMap`, `Scanning.endTour`), house (`House.walkToNextRoomHint`), processing chips (`Processing.stepPercent(step:percent:)`), recovery (`Home.recoverScanTitle`, `recoverScanBody`), object capture states (`ObjectScan.continue`, `startCapture`, `resetBox`, `cantFindObject`, `flip`, `skipFlip`, `orbitProgress(n:of:)`), settings (`Settings.demoMode`, `Settings.freeUpSpace`), and the plan symbols list.

## 9. Build plan

Principle: every build ends with something a user can do start to finish, and the first build of each area also logs the device facts the research could not verify. Modules are sized for one agent each; the parallel column lists what can be written at the same time against `Core`.

### Build 3 (0.3): scan a room, get a plan

| Module work (parallel agents) | Notes |
|---|---|
| Core (all types in 2.3, 3.1, 8.7), CodableSimd, MapperError | lands first, same day; everyone else codes against it |
| Store: PackageLayout, ProjectStore, RawScanWriter/Reader with seal, MeshChunkFile, EditStore | |
| UI shell: AppRouter, ProjectListView, ModePickerView, TipsView, CameraPermissionView, SettingsView (units, tips, haptics), ScanScreen chrome, QualitySheet (walls and floor rows only), ProcessingView, ViewerScreen with Floor Plan and 3D Clean tabs | built against FakeScanEngine, demo mode in Settings |
| Guidance: GuidanceEngine + self-test; detectors for tracking, RoomPlan instructions, tier 3 events | |
| Capture: ARSessionHost, CaptureConfig, MeshRecorder, KeyframeRecorder, SessionDiagnostics (logs every open device question), ThermalGovernor | |
| Engines: RoomScanEngine with RoomPlanBridge (shared session protocol from 3.2), FakeScanEngine, SnapshotRecorder | |
| Processing: ProcessingQueue, RoomBuild, CleanModelBuilder, FloorPlanBuilder, AutoMeasurements | |
| Plan: PlanRenderer (read-only), Render/Viewer: ModelViewerView with OrbitCamera and clean model boxes | |
| Geometry and Export branches merged if green | |

User can: tap New Scan, Room; see tips; scan with live RoomPlan outlines, the mini map and one-at-a-time guidance; tap Done and see wall and floor percentages; Finish; within seconds see the 3D Clean model and a dimensioned floor plan with room area, wall lengths and ceiling height (both unit systems); rename, archive, delete projects. Raw mesh and keyframes are already recorded and sealed for later builds. The log answers: does RoomPlan keep our configuration, do mesh anchors and depth arrive, frame delivery, memory ceiling, mesh size per room.

### Build 4 (0.4): coverage, quality and measuring

- Coverage: CoverageGrid, CoverageTracker, ExpectedSurfaces, QualityAnalyzer (all rows), MissingAreaFinder.
- Render/Live: CoverageOverlay (4-part LowLevelMesh), TourMarker; mini map missing dots.
- Show Missing Areas tour end to end; layout-only degraded coverage if build 3 logs showed mesh loss.
- Processing: MeshConsolidator; Raw Scan tab.
- Measure: ConfidenceModel, SnapCandidates, MeasureToolModel; Quick Measure mode (MeasureEngine, MeasureScreen); viewer Measure tool with BVH picking; confidence and Low confidence labels.
- Photos: Take Photo, PhotosSheet with pins.
- Advanced Scan options and MeshScanEngine (space without layout).

User can: watch walls turn gray, yellow, green while scanning; see the full Scan Quality screen and be walked to each missing area; measure anything in the live camera or in the saved model with ± accuracy; take photos pinned to places; view the raw LiDAR mesh.

### Build 5 (0.5): realistic color and objects

- Texturing (CPU pipeline 4.3), Realistic tab, Display styles (Photo Realistic and Textured from the atlas, Solid, Wireframe, Raw).
- Object mode: ObjectSizePickerView, ObjectCaptureEngine (GuidedCapture machine), ObjectPassReviewSheet, ObjectModelBuilder; large object path (MeshScanEngine object focus, SectorCoverage, LargeObjectBuilder); object summary card, Crop.
- ExportAdapters and ExportSheet: all formats in section 7; Back Up and Restore (StreamingZip).

User can: see a photo-textured room; scan a chair or an appliance and get a textured model with width, height, depth and volume when valid; crop it; export USDZ, OBJ, PLY, STL, glTF, PDF, SVG, DXF, JSON and images; back up and restore projects.

### Build 6 (0.6): whole house and editing

- House mode: HouseProgressSheet over the live session, NameRoomSheet, per-room sealing, world map per room, relocalizing resume, StructureMerger, shared walls and doorway connections, floors, AlignmentView (Line Up by Hand), Continue Scanning and Rescan from the project.
- Editing: EditApplier, FloorPlanEditorView (all Copy.FloorPlan actions), element menus in 3D Clean (hide, delete from clean, move, rotate, rename, change category, show raw geometry, wall actions), Hide Furniture with provenance patches, label correction.

User can: scan a whole floor room by room with a live checklist, come back later to fix a room, join rooms by hand when automatic alignment fails, edit the plan (walls, doors, windows, rooms, notes) and the 3D model, correct labels, hide furniture and see what is measured versus inferred.

### Build 7 (0.7): polish and quality

Seam gain correction (Photo Realistic differs from Textured), optional Metal view selection if build 5 logs show slow texturing, multi-floor plan pages in PDF, `BGContinuedProcessingTask` on iOS 26, VoiceOver and Dynamic Type pass (HUD clamped at xxxLarge), storage cleanup, measurement calibration against the TEST_PLAN tape protocol (tighten or widen the confidence constants from real data).

## 10. Risks and mitigations

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | RoomPlan re-runs the shared ARSession and strips mesh or depth, or takes the delegate, so the live coverage view has no data | medium / high | Delegate set before RoomPlan init, configuration re-applied in `didStartWith` with `options: []`, watchdog re-apply, `currentFrame` polling fallback, and the designed degraded modes (3.2): layout-only coverage on RoomPlan boxes plus an optional follow-up mesh pass on the saved world map. Build 3 logs settle it before build 4 builds on it. |
| 2 | Thermal and frame budget: RoomPlan + mesh + depth + JPEG keyframes + RealityKit overlay on an A15 for 5 minutes | high / medium | Keyframes gated by motion (1 to 2 per second), JPEG on a bounded io queue with drop policy, overlay updates at most 2 Hz and only in the frustum, coverage stride 4 at 3 Hz, thermal ladder (freeze overlay, 30 fps, halve keyframes, pause at critical), 4 minute warning. Diagnostics log thermal and fps timelines. |
| 3 | Keeping the session alive through the quality sheet and the tour conflicts with RoomPlan's 5 minute guidance and makes Finish slower | medium / medium | The quality sheet is quick; the tour is capped at 8 areas; the timer keeps running and the 4 minute warning still fires; if RoomPlan ends the session (`deviceTooHot`, limit) the raw collected so far is sealed and the tour continues on the mesh engine for coverage only. |
| 4 | Texture coordinate conventions (projection sign, UV flip, landscape sensor image) produce garbage textures with no local compiler | medium / high | Verified projection formula from research, one flip location (`SceneAdapter` and the viewer mesh builder), Diagnostics screen with the two research self-tests (project mesh vertices onto the live image as dots; numbered checkerboard atlas on a quad) shipped in build 4 before texturing lands. |
| 5 | Memory: 800k-triangle meshes, BVH, atlas pages and Photogrammetry on a device with an unknown jetsam limit | medium / high | One heavy stage at a time, budgets in 4.2, decimation cap 800k for processing (full mesh kept), atlas pages streamed, ObjectCaptureSession released before PhotogrammetrySession, `os_proc_available_memory` logged per stage. |
| 6 | Multi-room alignment fails (`invalidRoomLocation`, relocalization fails on another day) | high / medium | Per-room world maps, rooms always usable alone, FrameLink model, Line Up by Hand with wall and door snapping, "Scan Doorway Again". |
| 7 | Object Capture limits: `.reduced` only on iOS, textureless or shiny objects fail, no camera pose for side guidance | high / medium | Two object paths with a clear chooser; Apple's dial and orbit prompts on the small path; LiDAR path with sector guidance for large objects; honest "Volume unavailable" rule. |
| 8 | CI round trips on exact signatures (RoomPlan delegate, ObjectCaptureSession, LowLevelMesh, TextureResource async inits) | high / low | Signatures copied from research into Core-adjacent files by the agent owning each boundary; one boundary file per framework (`RoomPlanBridge.swift`, `ObjectCaptureEngine.swift`, `CoverageOverlay.swift`) so failures stay local; no macros; Swift 5 mode; `@unknown default` on every Apple enum switch. |
| 9 | UI built against a fake engine drifts from real engine behavior | medium / medium | `LiveScanSnapshot` is the only contract; `SnapshotRecorder` records real scans on device into files that `FakeScanEngine` replays, so demo mode uses real data from build 3 on. |
| 10 | Raw immutability erodes (a later module writes into raw) | low / high | Only `RawScanWriter` can write, only before seal; sealed files are read-only on disk; `SEAL.json` sizes checked on project open and logged if changed. |
| 11 | Package size fills the phone (keyframes, depth, Object Capture HEICs) | medium / medium | Storage estimate shown before Advanced Maximum scans, live free-space watchdog, Free up space action for derived and superseded data, Keep all photos setting controls capture density. |
| 12 | Measurement accuracy perceived as better than it is | medium / high | Confidence model from published data, 1 cm floor, RoomPlan cap 2.5 cm, low-confidence badge above 4 cm, provenance on every value, disclaimer string, calibration pass in build 7 against the TEST_PLAN protocol. |

## 11. Device facts to log in build 3 (answers change behavior, not structure)

`session.configuration` before and after RoomPlan starts; whether `session(_:didUpdate frame:)` keeps firing under RoomPlan; mesh anchor count and triangles per anchor for a typical room; `sceneDepth` presence and depth buffer size; `supportedVideoFormats`; `os_proc_available_memory()` at launch, scan end and each stage; thermal timeline and battery percent per minute of scanning; RoomPlan `completedEdges` behavior when half a wall is scanned; `ObjectCaptureSession.maximumNumberOfInputImages` and `PhotogrammetrySession.limits`; JPEG encode time for one keyframe; world map size per room.
