# Mapper architecture proposal: ship-first

Lens: minimize novel code and compile risk. Apple's frameworks (RoomPlan, Object Capture, ARKit scene reconstruction, RealityKit) do the hard work; custom geometry and imaging code exists only where SPEC.txt cannot be met otherwise. Build 3 scans a room and shows a floor plan, a 3D model and measurements. Every module fits one agent in one sitting (target under about 600 lines of Swift, hard ceiling 900).

Inputs read for this proposal: docs/SPEC.txt, docs/research/raw/*.json (all ten topics, including every refuted or corrected verdict), CLAUDE.md, ios/project.yml, all of ios/Sources/, docs/UX_COPY.md, docs/TEST_PLAN.md, and the briefs docs/tasks/geometry.md and docs/tasks/exporters.md. At the time of writing there is no docs/research/verify/ folder, no docs/RESEARCH.md and no feat/geometry or feat/export branch on the remote (only main and an old dev). This design therefore reuses the Geometry and Export modules through the interfaces fixed in their briefs; if those branches land with different names, only the adapter files named below change.

Research facts this design depends on most (from docs/research/raw, with corrections applied):

| Fact | Consequence here |
|---|---|
| RoomCaptureSession(arSession:) and RoomCaptureView(frame:arSession:) accept an app-owned ARSession (iOS 17). Corrected verdict: the app may set arSession.delegate itself (Apple's multi-room article requires it); set it before creating the RoomPlan objects. | One ARSession per capture session, owned by `ARSessionHub`, shared by RoomPlan, mesh recording, keyframes and coverage. |
| Corrected verdict: RoomPlan re-runs the shared session with its own configuration and can drop `.sceneDepth` (forum 763400); community fix is to re-run our configuration with options [] in captureSession(_:didStartWith:). | `ARSessionHub.reapplyConfiguration()` in didStartWith plus a watchdog; build 3 logs the effective configuration. Fallback is a same-session mesh pass after RoomPlan stops (section 3.2). |
| ARMeshAnchor geometry is anchor-local, buffers are reused on update, classification is per face, normals per vertex, not in ARWorldMap. | Copy on the delegate queue, transform to world, persist ourselves. |
| Never retain ARFrames (more than about 10 stalls the camera). | Every frame consumer copies what it needs inside the callback. |
| PhotogrammetrySession on iOS supports only `.reduced` (under 50k triangles, 2048 textures). | Object model quality is capped; no other detail case may appear in code. |
| SceneKit and ARSCNView are deprecated in the iOS 26 SDK; ARView is not; LowLevelMesh, UnlitMaterial(texture:), TextureResource(image:withName:options:) are iOS 18. | Viewer is RealityKit ARView(.nonAR). No SceneKit anywhere. |
| No built-in RealityKit material reads vertex colors on iOS without a shader (CustomMaterial or ShaderGraphMaterial). | Ship-first avoids both: per-face colors use LowLevelMesh parts with one UnlitMaterial per color; photo color goes through a texture. Zero .metal files. |
| CapturedRoom and friends are Codable but read-only with no initializer. | Raw truth is the encoded CapturedRoomData and CapturedRoom JSON; everything editable lives in our own value types. |
| RoomPlan gives no wall thickness, no door swing, no ceiling, only boxes for objects, 5 room labels. | These are our plan-model attributes with provenance flags (measured, estimated, inferred, user). |
| iOS 18 has no background continuation for long processing (BGContinuedProcessingTask is iOS 26). | All processing runs in the foreground with the idle timer disabled and resumable steps. |
| simd matrices are not Codable; SIMD3<Float> has stride 16 while ARKit vertex buffers are packed at stride 12. | `Transform4`/`Intrinsics` wrappers for JSON; binary chunk files are packed explicitly. |
| Swift 5 language mode, XcodeGen, no macros required. | Use ObservableObject and @Published (property wrappers), never @Observable or #Preview (macros). |

---

## 1. Module map

Folders are under `ios/Sources/`. "B" is the build where the module first lands (section 9). Dependencies point downward only: UI depends on processing and capture, which depend on Store, Geometry, Export, Units and Support. No module imports a sibling at its own layer except where listed.

### 1.1 Layers

| Layer | Modules | May import |
|---|---|---|
| L0 Foundation | Support, Units, Geometry, Export, Store | Foundation, simd, UIKit (Support, Export PDF), CoreImage/ImageIO (Store) |
| L1 Capture | CaptureCore, MeshRecord, Keyframes, Coverage, Guidance, RoomCapture, ObjectCapture, LiveMeasure, LiveMeshView | L0, ARKit, RoomPlan, RealityKit |
| L2 Processing | Pipeline, MeshModel, RoomModel, FloorPlan, Quality, Texture, ObjectModel, Structure | L0, RoomPlan (RoomModel, Structure), ModelIO (ObjectModel), RealityKit (ObjectModel photogrammetry only) |
| L3 Presentation | AppShell, Viewer3D, MeasureTool, PlanEditor, Results, QualityUI, HouseUI, ExportUI, ProjectOps | everything below |

### 1.2 Modules

| ID | Module (folder) | Responsibility | Files | Depends on | B |
|---|---|---|---|---|---|
| M00 | Support (existing) | LogStore, DebugServer, Haptics, DeviceState, SettingsKey, Copy. New strings go in `Copy+<Module>.swift` extensions of `enum Copy` so parallel agents never edit the same file. | existing + `Copy+Capture.swift`, `Copy+Results.swift` etc. | none | 1 |
| M01 | Units (existing) | All length, area, volume, angle and tolerance text; parsing. | existing | none | 1 |
| M02 | Geometry (brief: docs/tasks/geometry.md) | Polygon2D, Segment2D, Plane, SymmetricEigen3, OrientedBox, AABB3, TriangleMesh, Ray, MeshBVH, Snap. Pure simd. | per brief | none | 3 |
| M03 | Export (brief: docs/tasks/exporters.md) | ExportMesh/ExportScene/ExportMaterial/Plan2D input types; OBJ, PLY, STL, GLB, USDZ, ZIP, DXF (R12), SVG, PDF writers. | per brief | none | 3 |
| M04 | Store | Project package layout, manifest, Codable wrappers, binary chunk and depth formats, atomic writes, backup exclusion, free-space check, project library. | `ProjectManifest.swift`, `ProjectPackage.swift`, `ProjectLibrary.swift`, `CodableSIMD.swift`, `BinaryFormats.swift`, `FileIO.swift` | M00 | 3 |
| M10 | CaptureCore | `ARSessionHub` (owns ARSession, delegate queue, fan-out to consumers), `ScanConfiguration`, `TrackingMonitor`, `ThermalGovernor`, `CaptureDiagnostics` (logs effective config, anchor counts, depth presence, memory). | `ARSessionHub.swift`, `ScanConfiguration.swift`, `TrackingMonitor.swift`, `ThermalGovernor.swift`, `CaptureDiagnostics.swift` | M00, M04 | 3 |
| M11 | MeshRecord | `MeshStore`: latest world-space copy per ARMeshAnchor, stale handling, periodic checkpoint and final snapshot to `raw/.../mesh/*.mchk`. | `MeshStore.swift`, `MeshChunk.swift` | M04, M10 | 3 |
| M12 | Keyframes | `KeyframeGate`, `KeyframeRecorder` (JPEG plus Float16 depth plus confidence plus pose), user "Take Photo" pins. | `KeyframeGate.swift`, `KeyframeRecorder.swift`, `PhotoPins.swift` | M04, M10 | 3 |
| M13 | Coverage | `VoxelCoverage` (10 cm hash, observation counts, photo bit), sampling from scene depth (mesh-face fallback), `CoverageMinimap` SwiftUI Canvas. | `VoxelCoverage.swift`, `CoverageSampler.swift`, `CoverageMinimap.swift` | M02, M10 | 3 |
| M14 | Guidance | `GuidanceEngine` implementing `GuidancePolicy` from Copy.swift over a set of `GuidanceKind` conditions; `GuidanceBanner` view; mappers from RoomPlan Instruction, ObjectCapture Feedback, tracking, light, thermal. | `GuidanceEngine.swift`, `GuidanceSignals.swift`, `GuidanceBanner.swift` | M00 | 3 |
| M15 | RoomCapture | `RoomCaptureController` (RoomCaptureSessionDelegate + RoomCaptureViewDelegate with NSCoding stubs), `RoomCaptureContainer` (UIViewRepresentable around one RoomCaptureView), per-room run/stop, RoomBuilder, persistence of CapturedRoomData and CapturedRoom JSON, live room stats. | `RoomCaptureController.swift`, `RoomCaptureContainer.swift`, `RoomScanScreen.swift` | M04, M10-M14 | 3 |
| M16 | ObjectCapture | Port of Apple's GuidedCapture sample: `ObjectScanModel`, capture folder manager, overlay views, onboarding state machine, `PhotogrammetryJob`. | `ObjectScanModel.swift`, `ObjectCaptureFolders.swift`, `ObjectScanScreen.swift`, `ObjectOnboarding.swift`, `PhotogrammetryJob.swift` | M04, M14 | 4 |
| M17 | LiveMeasure | Quick Measure: ARView(.ar) on its own session, center reticle, "+" button, raycast, plane-corner snapping, live label, confidence. | `LiveMeasureScreen.swift`, `LiveMeasureModel.swift` | M02, M10, M20 (confidence) | 4 |
| M18 | LiveMeshView | ARView(.ar) bound to the hub's session for mesh-only scanning (Advanced "space", patch pass, Show Missing Areas). B4: Apple `.showSceneUnderstanding` wireframe plus minimap. B5: `CoverageOverlay` with one LowLevelMesh per anchor and four colored parts. | `LiveMeshScreen.swift`, `CoverageOverlay.swift`, `MissingAreaArrow.swift` | M10-M14 | 4 |
| M20 | MeasureCore | `MeasurementRecord`, `ConfidenceModel` (research formula), `SnapCandidates` builder from CleanModel and mesh. | `MeasurementRecord.swift`, `ConfidenceModel.swift`, `SnapCandidates.swift` | M02 | 3 |
| M21 | Pipeline | `ProcessingRunner` actor: ordered, idempotent, resumable steps with progress, memory and thermal checks, idle timer. | `ProcessingRunner.swift`, `PipelineStep.swift`, `ProcessingScreen.swift` | M04 | 3 |
| M22 | MeshModel | Consolidate mesh chunks: load, weld seams, drop tiny islands, classification stats, merged `TriangleMesh`, per-chunk BVH index, export adapter. | `MeshConsolidator.swift`, `RawMeshIndex.swift`, `MeshExportAdapter.swift` | M02, M03, M04 | 4 |
| M23 | RoomModel | `CleanModel` from CapturedRoom/CapturedStructure: walls with cut openings, floor polygons, inferred ceiling, object boxes, provenance, room metrics. Overrides applied on top. | `CleanModel.swift`, `CleanModelBuilder.swift`, `RoomMetrics.swift`, `Overrides.swift` | M02, M04, RoomPlan | 3 |
| M24 | FloorPlan | `PlanModel` from CleanModel (door swing heuristic, thickness), `PlanDrawing` (PlanModel to Plan2D plus hit-test metadata), dimension strings via Units. | `PlanModel.swift`, `PlanBuilder.swift`, `PlanDrawing.swift` | M01, M02, M03, M23 | 3 |
| M25 | Quality | `QualityReport` (Shape, Walls, Floor, Ceiling, Color and texture, missing areas) from VoxelCoverage plus RoomPlan completedEdges/confidence; `MissingArea` clustering. | `QualityReport.swift`, `QualityEvaluator.swift`, `MissingAreaFinder.swift` | M02, M13, M23 | 3 |
| M26 | Texture | B5: `CellTextureBaker` (one color cell per triangle). B6: `ChartAtlasBaker` (per-face best view, charts, shelf packing, CoreGraphics bake). CPU only, no Metal. | `KeyframeIndex.swift`, `ViewScoring.swift`, `CellTextureBaker.swift`, `ChartAtlasBaker.swift`, `ShelfPacker.swift` | M02, M04, M22 | 5 |
| M27 | ObjectModel | Load the photogrammetry USDZ with MDLAsset, dimensions from boundingBox, volume and area from mesh buffers (M02), ExportMesh adapter, crop by re-processing with `Request.Geometry`. | `ObjectModelLoader.swift`, `ObjectDimensions.swift`, `ObjectCrop.swift` | M02, M03, M16 | 4 |
| M28 | Structure | StructureBuilder merge, per-room alignment transforms (manual fallback), floor grouping by floor elevation. | `StructureMerger.swift`, `RoomAlignment.swift`, `FloorGrouping.swift` | M02, M23, RoomPlan | 5 |
| M30 | AppShell | App entry, NavigationStack routes, Home (project list), New Scan mode sheet, tips sheets, Settings, unsupported-device screen, permissions. Replaces ContentView (the capability probe moves to Settings > Diagnostics). | `AppRouter.swift`, `HomeScreen.swift`, `ModePickerSheet.swift`, `TipsSheet.swift`, `SettingsScreen.swift`, `DiagnosticsScreen.swift` | all L1, L2 | 3 |
| M31 | Viewer3D | ARView(.nonAR) host, orbit/pan/pinch camera, `RenderMeshBuilder` (LowLevelMesh), scene builders for raw, clean, textured, object; display styles; CPU picking with MeshBVH. | `ViewerContainer.swift`, `OrbitCamera.swift`, `RenderMeshBuilder.swift`, `ViewerScene.swift`, `ViewerPicking.swift` | M02, M22, M23, M26, M27 | 4 |
| M32 | MeasureTool | In-viewer measuring: two-point, wall, area, angle; snapping; confidence badge; measurement list. | `MeasureToolModel.swift`, `MeasureOverlay.swift`, `MeasurementList.swift` | M20, M31 | 4 |
| M33 | PlanEditor | Canvas view of PlanDrawing, toggles, selection, editing ops, undo stack, save to edits. | `PlanCanvas.swift`, `PlanEditorModel.swift`, `PlanEditOps.swift`, `PlanToolbar.swift` | M24 | 3 (view only), 5 (editing) |
| M34 | Results | Result screen: REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH switcher, display style menu, object and wall menus, Hide Furniture, photos. B3 uses QuickLook for 3D. | `ResultScreen.swift`, `ObjectMenu.swift`, `WallMenu.swift`, `PhotoBrowser.swift` | M31-M33 | 3 |
| M35 | QualityUI | Scan quality screen, Finish Anyway, Show Missing Areas flow. | `QualityScreen.swift`, `MissingAreasFlow.swift` | M18, M25 | 3 (screen), 4 (missing areas) |
| M36 | HouseUI | Room list with status, Scan Next Room, Rescan, Finish Building, manual alignment editor, floors. | `HouseScreen.swift`, `AlignRoomsScreen.swift` | M15, M28 | 5 |
| M37 | ExportUI | Export sheet per representation, adapters to M03 types, ShareLink, measurement CSV. | `ExportSheet.swift`, `ExportJobs.swift` | M03, M22-M27 | 3 (USDZ, JSON, PDF), 4 (all) |
| M38 | ProjectOps | Rename, duplicate, archive, delete, backup (ZIP via M03), restore (STORE-only `ZipReader`). | `ProjectOps.swift`, `ZipReader.swift` | M03, M04 | 6 |

### 1.3 Parallel-work rules

- Every public type named in section 2 is created by its owning module exactly as spelled; other modules code against those names from day one, so interfaces are fixed before implementation starts.
- One agent per module per build. An agent edits only its own folder plus its own `Copy+X.swift`. The only shared files are `project.yml` (owned by M30) and `MapperApp.swift` (owned by M30).
- Each module ships `XSelfTest.run() -> [String]` for its pure logic (same pattern as UnitsSelfTest) and M30's Diagnostics screen runs all of them at launch and logs the result, so on-device verification needs no Xcode.
- Swift rules: Swift 5 mode; no macros (no @Observable, no #Preview); UI models are `@MainActor final class ...: ObservableObject`; ARKit and RoomPlan delegates are plain `NSObject` subclasses, never @MainActor; hop to main with `DispatchQueue.main.async` carrying only value types; every switch over an Apple enum has `@unknown default`; delegate signatures are copied verbatim from the research.

---

## 2. Data model

### 2.1 Project package on disk

A project is a directory package in the app's Documents so it shows up in Files (UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace are already on). UTI registration of `.mapperproj` as a package is deferred to build 6 (it only affects icons).

```
Documents/Projects/<projectUUID>.mapperproj/
  project.json                 ProjectManifest (small, backed up)
  thumbnail.jpg                512 px, derived
  raw/                         write-once; isExcludedFromBackup re-applied after every write batch
    sessions/<sessionUUID>/
      session.json             CaptureSessionRecord: device, iOS, ARKit config log, thermal/tracking timeline
      worldmap.arworldmap      NSKeyedArchiver ARWorldMap (mesh anchors stripped), one per completed room
      rooms/<roomUUID>/
        capturedroomdata.json  JSONEncoder(CapturedRoomData)   (RoomPlan raw, re-buildable)
        capturedroom.json      JSONEncoder(CapturedRoom)       (RoomBuilder output at capture time)
        roomlog.json           RoomCaptureLog: instruction durations, errors, timer
        mesh/<anchorUUID>.mchk MeshChunkFile, world space, final snapshot of this room's pass
        keyframes/<i>.jpg      1920x1440 JPEG q0.85, sensor (landscape) orientation
        depth/<i>.dpth         DepthFile: Float16 depth + UInt8 confidence, 256x192
        keyframes.json         [KeyframeRecord]
        photos/<photoUUID>.jpg user "Take Photo" (full frame) + photos.json [PhotoPin]
      mesh-pass/               same layout as rooms/<id> minus RoomPlan files (Advanced space scan, patch passes)
    objects/<objectUUID>/
      Images/                  ObjectCaptureSession HEICs (Apple format, includes depth)
      Checkpoint/              deleted after a successful model
      objectlog.json
    measure/quick.json         [MeasurementRecord] saved from Quick Measure
  derived/                     regenerable; every file stamped with pipelineVersion; safe to delete
    rooms/<roomUUID>/
      mesh.mchk                consolidated welded mesh of all passes for the room
      cells.jpg + cells.uv     B5 cell texture page and per-corner UVs (UVFile)
      atlas_<n>.jpg + atlas.uv B6 chart atlas pages and UVs
      coverage.vox             VoxelCoverage snapshot (VoxelFile)
      quality.json             QualityReport
    structure.json             JSONEncoder(CapturedStructure) when merged
    clean.json                 CleanModel (all rooms, before overrides)
    plan.json                  PlanModel (before user edits)
    objects/<objectUUID>/model.usdz, dims.json
  edits/                       user work; backed up; never touches raw/
    overrides.json             Overrides: labels, categories, hidden, deleted, object transforms, room names, door swings, thickness
    plan.edited.json           PlanModel after floor plan edits (absent until the first edit)
    measurements.json          [MeasurementRecord] placed in the viewer
    annotations.json           [PlanAnnotation] text, symbols, notes
    alignment.json             [RoomAlignmentRecord] manual room placement
  exports/                     files produced for sharing; cleared on demand
```

Rules:
- `raw/` is written only by capture modules while a capture session is open. After a room or object is finished, nothing writes into its raw folder again. Store exposes read-only accessors for raw after finish (`ProjectPackage.rawRoom(_:)` returns URLs, there is no raw writer outside `CaptureWriter`).
- In-progress capture writes straight into the package (crash keeps everything captured so far); the manifest marks the room `capturing` so the app can offer "Keep what was scanned" on next launch.
- All writes go through `FileIO.writeAtomically(_:to:)` (temp file in the same directory, then `replaceItemAt`).
- Before a scan starts, `FileIO.freeBytes()` (volumeAvailableCapacityForImportantUsage) must exceed 1 GB, else the scan refuses with Copy.Errors storage text.

Binary formats (little endian, packed, all counts explicit; readers use `loadUnaligned`):

| File | Header | Body |
|---|---|---|
| `.mchk` MeshChunkFile | magic "MCHK" (4), version UInt16 = 1, flags UInt16 (bit0 normals, bit1 classes), vertexCount UInt32, faceCount UInt32, anchorID 16 bytes, reserved 4 (total 36) | positions Float32 x3 packed, normals Float32 x3 packed, indices UInt32 x3, classes UInt8 per face |
| `.dpth` DepthFile | magic "DPTH", version UInt16, width UInt16, height UInt16, reserved UInt16 (12) | depth Float16 row-major meters, then confidence UInt8 row-major |
| `.uv` UVFile | magic "UVS1", version, faceCount UInt32, pageCount UInt16 | per face: page UInt16, 3 corners x Float32 x2 (top-left image convention) |
| `.vox` VoxelFile | magic "VOX1", version, cellSize Float32, count UInt32 | per cell: key Int64 (packed 21-bit x,y,z), count UInt8, flags UInt8 |

### 2.2 In-memory types (exact names)

Store (M04):

```swift
struct ProjectManifest: Codable {
    var schemaVersion: Int              // 1
    var id: UUID
    var name: String
    var kind: ProjectKind
    var createdAt: Date
    var modifiedAt: Date
    var isArchived: Bool
    var pipelineVersion: Int            // bumps invalidate derived/
    var sessions: [CaptureSessionRef]
    var rooms: [RoomRecord]
    var objects: [ObjectRecord]
    var floors: [FloorRecord]
    var status: ProjectStatus
}
enum ProjectKind: String, Codable { case room, house, object, quickMeasure, advancedSpace, advancedObject }
enum ProjectStatus: String, Codable { case capturing, needsProcessing, processing, ready, needsAttention }
struct CaptureSessionRef: Codable, Identifiable { var id: UUID; var startedAt: Date; var alignment: Transform4; var relocalizedFrom: UUID? }
struct RoomRecord: Codable, Identifiable {
    var id: UUID; var name: String; var sessionID: UUID; var floorIndex: Int
    var status: RoomStatus; var capturedRoomID: UUID?; var quality: QualitySummary?
    var hasMeshPass: Bool; var keyframeCount: Int; var capturedAt: Date
}
enum RoomStatus: String, Codable { case capturing, captured, needsRescan, processed, failed }
struct ObjectRecord: Codable, Identifiable { var id: UUID; var name: String; var status: RoomStatus; var imageCount: Int; var modelFile: String? }
struct FloorRecord: Codable, Identifiable { var id: Int; var name: String; var elevation: Float }
struct QualitySummary: Codable { var shape: Double; var walls: Double; var floor: Double; var ceiling: Double; var texture: Double; var missingAreas: Int }

struct Transform4: Codable, Equatable { var m: [Float]  /* 16, column-major */ ; init(_ t: simd_float4x4); var simd: simd_float4x4 }
struct Intrinsics: Codable, Equatable { var fx: Float; var fy: Float; var cx: Float; var cy: Float; var width: Int; var height: Int }
struct Vec3: Codable, Equatable { var x: Float; var y: Float; var z: Float; init(_ v: SIMD3<Float>); var simd: SIMD3<Float> }

struct ProjectPackage {                  // pure path helper, no IO state
    let root: URL
    var manifestURL: URL
    func rawRoom(session: UUID, room: UUID) -> URL
    func rawMeshPass(session: UUID) -> URL
    func rawObject(_ id: UUID) -> URL
    func derivedRoom(_ id: UUID) -> URL
    var editsURL: URL; var exportsURL: URL
}
@MainActor final class ProjectLibrary: ObservableObject {
    @Published private(set) var projects: [ProjectManifest]
    func create(kind: ProjectKind, name: String) throws -> ProjectPackage
    func save(_ manifest: ProjectManifest) throws
    func delete(_ id: UUID) throws; func rename(_ id: UUID, to: String) throws
    func package(for id: UUID) -> ProjectPackage
}
```

Capture records (M10 to M15):

```swift
struct MeshChunk { var id: UUID; var positions: [SIMD3<Float>]; var normals: [SIMD3<Float>]; var indices: [UInt32]; var classes: [UInt8]; var isStale: Bool }
struct KeyframeRecord: Codable { var index: Int; var timestamp: Double; var transform: Transform4; var intrinsics: Intrinsics
    var exposureDuration: Double; var exposureOffset: Float; var ambientIntensity: Float; var angularSpeed: Float; var hasDepth: Bool }
struct PhotoPin: Codable, Identifiable { var id: UUID; var timestamp: Double; var transform: Transform4; var intrinsics: Intrinsics; var note: String }
struct CaptureSessionRecord: Codable { var id: UUID; var device: String; var osVersion: String; var configLog: [String]; var events: [CaptureEvent] }
struct CaptureEvent: Codable { var t: Double; var kind: String; var detail: String }   // tracking, thermal, instruction, error
struct RoomCaptureLog: Codable { var seconds: Double; var instructionSeconds: [String: Double]; var error: String?; var relocalizations: Int; var limitedTrackingFraction: Double }
```

Models (M20, M23 to M25, M28):

```swift
enum Provenance: String, Codable { case measured, estimated, inferred, user }   // shown as Measured / Estimated / Inferred / Edited
struct CleanModel: Codable { var rooms: [CleanRoom]; var sourceIsStructure: Bool }
struct CleanRoom: Codable, Identifiable {
    var id: UUID                         // our RoomRecord id
    var capturedRoomID: UUID
    var name: String; var sectionLabel: String?; var floorIndex: Int
    var walls: [CleanWall]; var openings: [CleanOpening]; var floor: CleanFloor; var ceiling: CleanCeiling
    var objects: [CleanObject]; var metrics: RoomMetrics
}
struct CleanWall: Codable, Identifiable { var id: UUID; var start: Vec3; var end: Vec3; var height: Float; var normal: Vec3
    var thickness: Float; var thicknessSource: Provenance; var curve: WallArc?; var confidence: String; var completedEdges: [String]
    var occludedSpans: [ClosedRange<Float>]; var provenance: Provenance }
struct WallArc: Codable { var center: Vec3; var radius: Float; var startAngle: Float; var endAngle: Float }
struct CleanOpening: Codable, Identifiable { var id: UUID; var wallID: UUID?; var kind: OpeningKind; var offsetAlongWall: Float
    var width: Float; var sillHeight: Float; var headHeight: Float; var swing: DoorSwing?; var provenance: Provenance }
enum OpeningKind: String, Codable { case door, openDoor, window, opening }
struct DoorSwing: Codable { var hingeAtStart: Bool; var opensToNormalSide: Bool; var source: Provenance }
struct CleanFloor: Codable { var polygon: [Vec3]; var elevation: Float; var occludedArea: Float; var provenance: Provenance }
struct CleanCeiling: Codable { var height: Float; var provenance: Provenance }   // inferred unless mesh ceiling coverage >= 60 %
struct CleanObject: Codable, Identifiable { var id: UUID; var category: String; var label: String; var isMovable: Bool
    var transform: Transform4; var dimensions: Vec3; var confidence: String; var provenance: Provenance }
struct RoomMetrics: Codable { var floorArea: Float; var perimeter: Float; var ceilingHeight: Float; var wallArea: Float
    var length: Float; var width: Float; var volume: Float }

struct Overrides: Codable {             // keyed by RoomPlan identifiers or our ids; survives re-derivation
    var roomNames: [UUID: String]; var objectLabels: [UUID: String]; var objectCategories: [UUID: String]
    var hidden: Set<UUID>; var deletedFromClean: Set<UUID>; var objectTransforms: [UUID: Transform4]
    var doorSwings: [UUID: DoorSwing]; var wallThickness: [UUID: Float]
}

struct PlanModel: Codable { var levels: [PlanLevel]; var northAngle: Float; var unitsHint: String }
struct PlanLevel: Codable, Identifiable { var id: Int; var name: String; var rooms: [PlanRoom]; var walls: [PlanWall]
    var openings: [PlanOpening]; var fixtures: [PlanFixture]; var annotations: [PlanAnnotation]; var dimensions: [PlanDimension] }
struct PlanRoom: Codable, Identifiable { var id: UUID; var name: String; var outline: [SIMD2Codable]; var labelAt: SIMD2Codable }
struct PlanWall: Codable, Identifiable { var id: UUID; var a: SIMD2Codable; var b: SIMD2Codable; var thickness: Float
    var thicknessSource: Provenance; var arc: WallArc?; var provenance: Provenance }
struct PlanOpening: Codable, Identifiable { var id: UUID; var wallID: UUID; var kind: OpeningKind; var offset: Float; var width: Float; var swing: DoorSwing? }
struct PlanFixture: Codable, Identifiable { var id: UUID; var category: String; var center: SIMD2Codable; var size: SIMD2Codable; var yaw: Float; var isMovable: Bool }
struct PlanAnnotation: Codable, Identifiable { var id: UUID; var kind: String /* text, symbol, note */; var at: SIMD2Codable; var text: String }
struct PlanDimension: Codable, Identifiable { var id: UUID; var a: SIMD2Codable; var b: SIMD2Codable; var offset: Float; var isUser: Bool }
struct SIMD2Codable: Codable, Equatable { var x: Float; var y: Float }    // plan meters: plan x = world x, plan y = world -z (checked on device)

struct MeasurementRecord: Codable, Identifiable {
    var id: UUID; var kind: MeasurementKind; var points: [Vec3]; var value: Double /* meters, m2, m3 or radians */
    var sigma: Double; var snaps: [String]; var source: String /* live, viewer, plan */; var name: String; var createdAt: Date }
enum MeasurementKind: String, Codable { case distance, wallLength, height, area, perimeter, angle, volume }

struct QualityReport: Codable { var summary: QualitySummary; var perWall: [WallQuality]; var missing: [MissingArea]; var verdict: QualityVerdict }
struct WallQuality: Codable { var wallID: UUID; var coverage: Double; var completedEdges: Int; var confidence: String }
struct MissingArea: Codable, Identifiable { var id: UUID; var kind: MissingKind; var center: Vec3; var normal: Vec3; var area: Float; var roomID: UUID }
enum MissingKind: String, Codable { case wall, floor, ceiling, texture, hole }
enum QualityVerdict: String, Codable { case good, okay, poor }
struct RoomAlignmentRecord: Codable { var roomID: UUID; var yaw: Float; var translation: SIMD2Codable; var source: Provenance }
```

Rendering (M31):

```swift
struct RenderVertex { var position: SIMD3<Float>; var normal: SIMD3<Float>; var uv: SIMD2<Float> }   // one LowLevelMesh layout for everything
struct RenderMesh { var vertices: [RenderVertex]; var indices: [UInt32]; var parts: [RenderPart] }
struct RenderPart { var indexOffset: Int; var indexCount: Int; var materialIndex: Int }
enum DisplayStyle: String, CaseIterable { case photoRealistic, textured, solidColor, wireframe, rawMesh }
enum ResultView: String, CaseIterable { case realistic, clean, floorPlan, raw }
```

---

## 3. Capture pipelines

### 3.1 The shared session (all ARKit-based modes)

`ARSessionHub` (M10) owns one `ARSession` per capture session. It is created by the scan screen, lives until the user leaves the scan flow (Room: until Finish; House: until Finish Building or the user leaves), and is the only object that sets `session.delegate`.

```
ARSession  --delegate (queue "ar.delegate", serial)-->  ARSessionHub
   ARSessionHub fans out, on that queue, to:
     MeshStore            session(_:didAdd/didUpdate/didRemove anchors:) -> copy ARMeshAnchor to world space
     KeyframeRecorder     session(_:didUpdate frame:) -> gate, encode JPEG, copy depth, write
     CoverageSampler      session(_:didUpdate frame:) at 3 Hz -> depth samples -> VoxelCoverage
     TrackingMonitor      cameraDidChangeTrackingState, light, worldMappingStatus -> GuidanceSignals
   and posts value-type summaries to main (LiveScanStats) at most 4 times a second.
```

Configuration (`ScanConfiguration.make(_ profile: ScanProfile) -> ARWorldTrackingConfiguration`):
- `sceneReconstruction = .meshWithClassification` if `supportsSceneReconstruction(.meshWithClassification)`.
- `frameSemantics = [.sceneDepth]` if supported (no smoothed depth).
- `planeDetection = []` for Room and House (RoomPlan does its own; planes would flatten the raw mesh); `[.horizontal, .vertical]` for Quick Measure (corner snapping).
- `environmentTexturing = .none`, `isLightEstimationEnabled = true`, default video format (1920x1440 at 60). No hi-res still capture in v1 (research: optional, depth misaligned, one in flight).

Order of operations for RoomPlan modes (fixes from the corrected verdicts):
1. `hub.session.delegate = hub`; `hub.session.delegateQueue = hub.queue`.
2. `hub.session.run(config)`.
3. `RoomCaptureView(frame: .zero, arSession: hub.session)`; set `captureSession.delegate` and `delegate` to `RoomCaptureController`.
4. `captureSession.run(configuration: RoomCaptureSession.Configuration())` (coaching on).
5. In `captureSession(_:didStartWith:)`: `CaptureDiagnostics.logConfiguration(hub.session.configuration)`, then `hub.reapplyConfiguration()` which runs our config with options `[]` (never reset options, which would break the shared world frame).
6. Watchdog in the hub: if no `sceneDepth` for 2 s or no mesh anchor after 8 s of normal tracking, re-apply once more and log; if still missing, set `hub.degraded = .noDepth` or `.noMesh`. Coverage then falls back to mesh-face sampling (noDepth) or the room switches to the two-pass fallback (noMesh, 3.2).
7. After each ARSession callback, the hub checks `session.delegate === self` once per second; if RoomPlan replaced it, the hub logs it and installs `ARDelegateRelay` (forwards every call to the previous delegate, then to the hub). This is the cheap defensive multiplexer the research suggests; it is not expected to trigger.

Threading: everything ARKit touches runs on "ar.delegate". JPEG encoding runs synchronously on that queue (10 to 30 ms, at most 2 accepted keyframes per second) so no ARFrame or pixel buffer ever leaves the callback. File writes go to a separate serial "io" queue as `Data`.

Memory during capture (target working set under 1 GB): MeshStore up to about 120 MB (500k vertices world space plus normals at 16-byte SIMD stride), VoxelCoverage under 10 MB, zero retained frames, JPEG in flight under 2 MB.

Thermal (`ThermalGovernor`): `.fair` logs; `.serious` shows tier 1 `deviceHot`, drops coverage to 1 Hz and keyframes to 1 per second, B5 overlay stops re-meshing; `.critical` stops the RoomPlan run (the room keeps what it has), pauses the session and shows the break message. RoomPlan `CaptureError.deviceTooHot` is handled the same way.

### 3.2 Room

UI: `RoomScanScreen` is a ZStack of `RoomCaptureContainer` (RoomCaptureView: camera, Apple outlines, coaching text, mini model) and our chrome: Cancel, Done, elapsed timer, `GuidanceBanner`, `CoverageMinimap` (bottom-left, top-down: floor cells colored by observation count, walls from the live CapturedRoom colored by per-wall coverage), and a Take Photo button.

One message at a time: RoomCaptureView draws RoomPlan's coaching itself. `RoomCaptureController` records the latest `Instruction`; while it is anything but `.normal`, `GuidanceEngine` suppresses tiers 2 and 3 of our own banner (tier 1 safety messages still show; they are rare). When RoomPlan is quiet, our banner shows coverage hints (`scanCeiling`, `pointAtFloor`, `scanCorner`, `needsAnotherPass`) derived from VoxelCoverage and detection messages (`doorDetected`, `windowDetected`, `wallDetected`, `openingDetected`, `stairsDetected`) from counts in `captureSession(_:didAdd:)`.

Room state machine (`RoomScanPhase`): `preflight -> starting -> scanning -> stopping -> building -> quality -> (patching -> quality)* -> finishing -> done`, with `failed(RoomScanFailure)` reachable from starting, scanning and building, and `cancelled` from any state before finishing.
- Done: `captureSession.stop(pauseARSession: false)` so the ARSession keeps running for the quality screen and any patch pass. `captureView(shouldPresent:error:)` returns false (we show our own result). `captureSession(_:didEndWith:error:)` encodes `CapturedRoomData` to disk first, then `RoomBuilder(options: [.beautifyObjects]).capturedRoom(from:)` in a Task, and encodes the `CapturedRoom`. The final CapturedRoom (not the last didUpdate) is the truth.
- MeshStore writes its final snapshot for the room when stopping starts; KeyframeRecorder closes keyframes.json.
- Quality: section 4.6. Finish Anyway or Finish moves to finishing: save the world map (`getCurrentWorldMap` if `worldMappingStatus` is `.mapped` or `.extending`, anchors filtered to non-mesh), pause the session, update the manifest, enqueue processing.
- Timer: tier 3 hint at 4 minutes and a "tap Done soon" sheet at 5 minutes (Apple guidance), never an automatic stop.
- Errors: `exceedSceneSizeLimit` keeps the partial room and suggests splitting via House mode; `worldTrackingFailure` offers Rescan; `deviceTooHot` as above.

Two-pass fallback (only if build 3 diagnostics show RoomPlan strips mesh or depth on iOS 18.3): the room scan runs RoomPlan as above (RoomPlan data only), then after `stop(pauseARSession: false)` the hub re-runs our configuration without reset options and the user does a guided 60 to 90 second "color and detail pass" in `LiveMeshScreen` on the same session, so mesh and keyframes share RoomPlan's world frame. The same screen is the Show Missing Areas patch pass, so this fallback costs no extra module.

### 3.3 House / Building

One `RoomCaptureView` instance and one ARSession for the whole house visit. Per room: `captureSession.run(configuration:)`, Done calls `stop(pauseARSession: false)`, RoomBuilder, quality, then the House screen shows the room list (`Dining Room done`, `Hallway needs additional scan`) with Scan Next Room. Keeping the same RoomCaptureView avoids the reported tracking loss when a new view is created on a running session (StackOverflow 79208951). Every CapturedRoom is written to disk as soon as it is built so a crash loses at most one room. A world map is saved after each room.

Returning later (new app launch): the new session loads the last `worldmap.arworldmap` as `initialWorldMap`, runs with `[.resetTracking, .removeExistingAnchors]`, shows ARCoachingOverlayView (goal `.tracking`) until `trackingState == .normal`, then starts RoomPlan. If it does not relocalize within 30 s, or RoomPlan throws `exceedSceneSizeLimit` right after relocalizing (known report), the user can "Start fresh here": a new `CaptureSessionRef` with its own frame, joined later by manual alignment.

Finish Building: `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)` over rooms of the same session (and relocalized sessions). Success stores `derived/structure.json` and the CleanModel is built from it (shared walls deduplicated by Apple, thickness measured from antiparallel wall pairs). Failure (`invalidRoomLocation`, `exceedSceneSizeLimit`, any error) keeps per-room models and opens `AlignRoomsScreen`: drag and two-finger rotate each room on the plan, with snapping of parallel walls and coinciding doorways (M28 `RoomAlignment`). The result is a `RoomAlignmentRecord` per room; raw data is untouched.

Floors: rooms are grouped by floor elevation (cluster gap 1.2 m, `story` as a hint); Add Floor starts rooms with a new floorIndex. Stairs come from `Object.Category.stairs`; direction is a user attribute.

### 3.4 Object

A straight port of Apple's GuidedCapture sample (the research calls it the only object path Apple guarantees compiles on the iOS 18 SDK). The shared ARSession must be paused and released first: ObjectCaptureSession owns the camera.
- `ObjectScanModel` (@MainActor ObservableObject) owns `ObjectCaptureSession?` and observes `stateUpdates`, `feedbackUpdates`, `userCompletedScanPassUpdates`, `numberOfShotsTakenUpdates` in stored Tasks.
- Folders from `ObjectCaptureFolders`: `raw/objects/<id>/Images/` and `Checkpoint/`, fresh and empty per capture. `Configuration.checkpointDirectory` set, `isOverCaptureEnabled = false` (no Mac path).
- `ObjectScanScreen`: `ObjectCaptureView(session:)` with our overlay (Cancel, shot counter `%d/%d` from `maximumNumberOfInputImages`, Continue / Start Capture / Next buttons per state, GuidanceBanner fed by `Feedback` mapped to Copy guidance kinds: movingTooFast to moveSlower, objectTooClose to tooClose, objectTooFar to tooFar, environmentTooDark and environmentLowLight to lightingPoor, outOfFieldOfView to objectKeepInView).
- `ObjectOnboarding`: Apple's orbit and flip state machine (firstSegment to thirdSegmentComplete, flipObject, captureFromLowerAngle, captureFromHigherAngle), mapped onto our Copy guidance ("Capture the top" for the high orbit, "Capture the back" for the flip passes). Continue calls `beginNewScanPassAfterFlip()` for flippable objects else `beginNewScanPass()`. Finish calls `finish()`.
- After `.completed`: set the session to nil, then `PhotogrammetryJob` creates `PhotogrammetrySession(input: imagesURL, configuration:)` with `checkpointDirectory` reused and runs `process(requests: [.modelFile(url: model.usdz)])` (default detail, which is `.reduced`). Outputs are consumed until `.processingComplete` or `.processingCancelled` with `@unknown default`. Progress feeds ProcessingScreen.
- The object quality screen reports "Sides captured" from completed scan passes and shot count; Show Missing Areas for objects means "do another orbit" (`beginNewScanPass`).

### 3.5 Quick Measure

`LiveMeasureScreen`: ARView(frame:cameraMode: .ar, automaticallyConfigureSession: false) with its own ARSession (planes on, mesh on, no RoomPlan). Center reticle; the "+" button drops a point at `arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first`. Snapping (research order): existing points and ARPlaneAnchor boundary-vertex corners and plane-plane-floor intersections within 10 cm world or 24 pt screen, then `.existingPlaneGeometry`, then `.estimatedPlane`. Haptic selection on snap. Live label at the midpoint via `arView.project`. Confidence from `ConfidenceModel` using the depth at each endpoint (sceneDepth sample) and tracking history. Nothing is saved unless the user taps Save, which creates a `quickMeasure` project with `raw/measure/quick.json`.

### 3.6 Advanced

Advanced is not a new pipeline, it is a set of switches over the two drivers:

| Option | Effect |
|---|---|
| What: A space, "Find walls, doors and windows" on | Room driver (3.2) with the options below |
| What: A space, "Find walls..." off (outdoors, warehouses, vehicles, structures) | `LiveMeshScreen` driver: mesh plus keyframes plus coverage overlay, no RoomPlan; outputs Raw Mesh, Textured, Photo Realistic, measurements; no floor plan |
| What: An object | Object driver (3.4); "Find furniture" hidden |
| Detail: Standard / High / Maximum | Keyframe gate 0.30 m or 15 degrees / 0.20 m or 10 degrees / 0.12 m or 7 degrees; texture density 4 / 3 / 2 mm per texel; mesh kept unwelded at Maximum |
| Keep all photos | Off: keyframes deleted after texturing succeeds. On: kept in raw/ (default on for Room) |
| Find furniture | Off: CleanModel drops objects (RoomPlan still detects; they stay in raw) |
| Scanning distance | Close up / Normal / Far: coverage and keyframe depth window 0.3-2 m / 0.3-4 m / 0.3-5 m; mesh faces beyond the window are cropped at consolidation (raw untouched) |

---

## 4. Processing pipelines

`ProcessingRunner` (M21) is an actor. A project's work is a list of `PipelineStep` values executed one at a time; each step reads raw and derived files, writes derived files atomically, and stamps `pipelineVersion`. A step whose outputs exist with the current version is skipped, so a jetsam kill or a relaunch resumes where it stopped. Heavy work runs in `Task.detached(priority: .userInitiated)`; `DispatchQueue.concurrentPerform` is used inside a step for data-parallel loops. The runner sets `isIdleTimerDisabled = true` while running, checks `os_proc_available_memory()` before each step (skips optional steps under 600 MB and says so), and pauses between steps at thermal `.critical`.

```swift
enum PipelineStep: String, Codable, CaseIterable {
    case buildRoom, consolidateMesh, cleanModel, floorPlan, quality, mergeStructure,
         cellTexture, atlasTexture, reconstructObject, objectMetrics, thumbnail
}
```

| Step | Module | Input | Output | Queue / actor | Memory budget | Time on A15 (estimate) |
|---|---|---|---|---|---|---|
| buildRoom | M15 | capturedroomdata.json | capturedroom.json (only if missing, e.g. crash during capture) | detached task, RoomBuilder async | under 100 MB | seconds |
| consolidateMesh | M22 | raw mesh chunks of all passes of a room | derived mesh.mchk, classification stats | detached, concurrentPerform per chunk | under 400 MB for 1M triangles | 2 to 6 s |
| cleanModel | M23 | capturedroom.json or structure.json, overrides.json, coverage | clean.json | detached | under 50 MB | under 1 s |
| floorPlan | M24 | clean.json | plan.json | detached | under 20 MB | under 1 s |
| quality | M25 | coverage.vox, clean.json, keyframes.json | quality.json | detached | under 50 MB | under 1 s |
| mergeStructure | M28 | all capturedroom.json | structure.json or alignment request | StructureBuilder async | under 200 MB | seconds |
| cellTexture (B5) | M26 | mesh.mchk, keyframes, depth | cells.jpg, cells.uv | detached, one keyframe decoded at a time | under 450 MB | 10 to 40 s |
| atlasTexture (B6) | M26 | same | atlas pages, atlas.uv | detached | under 600 MB | 20 to 90 s |
| reconstructObject | M16 | Images/, Checkpoint/ | model.usdz | PhotogrammetrySession (Apple-managed); nothing else runs | Apple-managed; app releases all other large state | minutes |
| objectMetrics | M27 | model.usdz | dims.json | detached | under 100 MB | under 1 s |
| thumbnail | M31 | best available model | thumbnail.jpg | main (ARView snapshot) | small | under 1 s |

Order after a room: buildRoom, consolidateMesh, cleanModel, floorPlan, quality, thumbnail, then (B5+) cellTexture, (B6+) atlasTexture. The result screen opens as soon as floorPlan is done; textures appear when ready ("Adding color and texture" shows in the result screen, not as a blocking wait).

### 4.1 Raw mesh consolidation (M22)

1. Load all `.mchk` of the room's passes (RoomPlan pass plus patch passes). Chunks are already world space; patch-pass chunks with the same anchor id replace older ones.
2. Weld within each chunk and across chunk borders with `TriangleMesh.welded(tolerance: 0.002)` (spatial hash, M02).
3. Remove islands under 50 triangles and faces outside the Advanced distance window.
4. Keep per-face classification. Output one merged mesh plus a chunk table (face ranges per spatial tile of about 2 m) used for rendering, picking and frustum culling.
5. No decimation in v1 (budget is 1M triangles; if the log shows more, a vertex-clustering decimator at 1 cm is the planned addition, about 150 lines in M22).

### 4.2 Texturing (M26), CPU only

Stage 1, build 5, "Textured" (`CellTextureBaker`): each face gets one texture cell (4x4 texels, 2 triangles per 4x8 block pair) on 4096 px pages (1M faces fit in one page). For each keyframe (decoded one at a time with ImageIO, never more than two in memory), project face centroids with the intrinsics formula verified in the research (`z = -c.z; u = fx*c.x/z + cx; v = -fy*c.y/z + cy`), reject if behind, outside a 16 px margin, facing away (dot less than 0.2), or occluded (stored LiDAR depth at `(u*W_d/W, v*H_d/H)` smaller than z minus (0.03 + 0.03 z)). Score `cos(angle) / (1 + d^2) * sharpness` where sharpness comes from the keyframe's angular speed. Keep the best keyframe per face, then sample three points per face (the corners pulled 20 percent toward the centroid) and paint a small gradient into the cell. Output is a normal texture, so display needs only `UnlitMaterial(texture:)` and every exporter already handles it. It looks like a colored mesh at 3 to 8 cm resolution: a big step up from gray, cheap, and it validates every coordinate convention before the full atlas.

Stage 2, build 6, "Photo Realistic" (`ChartAtlasBaker`): the same view selection, plus two passes of neighbor smoothing (a neighbor's keyframe wins if its score is at least 70 percent of the best), charts = connected faces sharing a keyframe, split until at most 1024 px and fill ratio at least 0.35, a global scale to fit 2 to 3 pages at the Advanced detail density, shelf packing (`ShelfPacker`), and a CoreGraphics bake per keyframe (crop source rect with 4 px padding, draw into the page context, which mirrors the ScanSpace approach reported at 10 to 60 s). Seam dilation 4 px. Exposure differences: v1 applies a per-keyframe gain from `exposureDuration` and `exposureOffset` normalization; the seam-based least-squares gain solve is a later addition in the same module. Pages are written as JPEG q0.85.

Conventions fixed in one place: `TextureConvention.imageOrigin = .topLeft`; RealityKit and OBJ get `v' = 1 - v` at the boundary (M31 and the export adapter), confirmed by the UV test pattern in Diagnostics (build 4).

Fallbacks: if a keyframe set is empty or texture steps fail, the viewer shows Solid Color and the Realistic tab says the color layer is missing. Metal is not used in any build of this plan; if CPU baking proves too slow on device (over 3 minutes), the only permitted Metal addition is a compute kernel for the chart copy inside M26, with the CoreGraphics path kept as fallback.

### 4.3 Clean model (M23)

From `CapturedRoom` (single room) or `CapturedStructure` (house), never by re-importing USDZ:
- Walls: endpoints `transform * (+-dimensions.x/2, 0, 0, 1)`, height `dimensions.y`, normal from `columns.2`, curved walls from `curve`. Adjacent wall lines are intersected when their ends are within 15 cm and the angle is not near 0 or 180 degrees, so corners close.
- Openings: doors, windows, openings attached by `parentIdentifier`, endpoints projected onto the parent wall and clamped. `door(isOpen:)` maps to door or openDoor.
- Floor: `floors[0].polygonCorners` transformed by the floor transform, world Y dropped for the plan; fallback to the closed wall polygon.
- Ceiling: height = median wall height over walls with confidence high (else all walls). Provenance `measured` if at least 60 percent of ceiling cells in VoxelCoverage were observed, otherwise `inferred`.
- Thickness: 0.115 m interior, 0.15 m exterior, provenance `estimated`; in a structure, antiparallel overlapping wall pairs 0.05 to 0.5 m apart give `measured` thickness.
- Objects: boxes from `transform` and `dimensions`, category name from `Object.Category`, `isMovable` true for bed, chair, sofa, table, television.
- Furniture honesty: when Hide Furniture is on, the floor area under movable object footprints and wall spans behind movable objects closer than 0.3 m to a wall are recorded as `occludedSpans` / `occludedArea`; a span is upgraded to measured only if VoxelCoverage observed the wall cells there. Occluded spans render hatched in 3D Clean and dashed on the plan and are labeled "Inferred" in menus and exports. Nothing is fabricated as measured.
- Metrics (`RoomMetrics`): floor area by shoelace, perimeter, ceiling height, wall area minus child openings, length and width from the floor polygon's minimum-area rectangle (M02 OrientedBox on the polygon), volume = area times ceiling height (flagged inferred when the ceiling is inferred).
- Overrides from `edits/overrides.json` are applied last (labels, categories, hidden, deleted, moved objects, swings, thickness), so AI labels are never baked in and re-derivation keeps user corrections.

### 4.4 Floor plan (M24)

`PlanBuilder` maps CleanModel to `PlanModel` (plan x = world x, plan y = world -z; the sign is verified on device with an L-shaped room and centralized in `PlanBuilder.planPoint(_:)`). Door swing default: hinge at the door end nearer a wall corner, opening into the room whose floor polygon contains `doorCenter + normal * 0.3`; source `estimated` until the user changes it. Dimensions: one interior string per wall, overall bounding dimensions per room, room tag = name plus area. If `edits/plan.edited.json` exists, the editor and exports use it instead of `plan.json`; re-derivation after a rescan asks whether to keep the edited plan.

`PlanDrawing.make(level:toggles:prefs:) -> (Plan2D, [PlanHit])` converts a level into the Export module's `Plan2D` (layers A-WALL, A-DOOR, A-GLAZ, A-FLOR-IDEN, A-ANNO-DIMS, A-FURN, A-FIXT, A-ANNO-NOTE, A-GRID) plus hit-test metadata. The screen Canvas, PDF, SVG and DXF writers all draw the same Plan2D, so what the user sees is what they export. Dimension labels are formatted by `LengthFormat` before they enter Plan2D.

### 4.5 Object model (M27)

`MDLAsset(url: model.usdz)`: `boundingBox` gives width, height, depth in meters (Object Capture HEICs carry depth, so scale is metric). Meshes from `childObjects(of: MDLMesh.self)` are converted to `TriangleMesh` to compute surface area and, only when `isWatertight` is true, volume (otherwise the UI shows volume as unavailable with the reason). Untextured mesh = same geometry with Solid Color display; exports go through `ExportMesh` built from the MDLMesh buffers. Crop: the user drags a box in the viewer, then `PhotogrammetrySession` is re-run from the kept Checkpoint with `.modelFile(url:, geometry: PhotogrammetrySession.Request.Geometry(bounds:transform:))`; the previous model is kept until the new one succeeds. Checkpoint is deleted only after the user leaves the crop step (build 6).

### 4.6 Coverage and quality (M13, M25)

Live (`CoverageSampler`, 3 Hz on "ar.delegate"): take the current frame's depth and confidence, sample a 64x48 grid, keep samples with confidence at least medium and depth inside the distance window, unproject with scaled intrinsics to world (research formula), and increment the 10 cm voxel (`[Int64: UInt8]`, saturating). Only counts while `trackingState == .normal`. When a keyframe is accepted, the same samples set the voxel's photo bit. Fallback when depth is missing: sample every fourth face centroid of anchors in the frustum (research algorithm). Colors: green at 3 or more observations, yellow at 1 or 2, red for expected cells with 0 observations, gray for cells never observed and not expected.

Expected surfaces come from the live CapturedRoom (`didUpdate`) or, after the scan, the final one: wall rectangles minus openings, floor polygon, ceiling plane at wall height, each sampled on a 20 cm grid.

`QualityEvaluator` (after Done, under 1 s):
- Walls = observed wall samples / expected wall samples, each wall multiplied by 1.0 (4 completedEdges, high confidence), 0.85 (an edge missing), 0.7 (medium), 0.5 (low).
- Floor and Ceiling = observed fraction of their samples.
- Shape (Copy "Shape", the spec's Geometry) = area-weighted mean of walls, floor, ceiling.
- Color and texture = fraction of observed cells with the photo bit.
- Missing areas = connected clusters (flood fill on each surface grid) of unobserved samples with area at least 0.25 m2, plus clusters without the photo bit (kind texture). Each `MissingArea` has center and normal for guidance.
- Verdict: good if all at least 90 percent, okay if all at least 70 percent, else poor (Copy.Quality summaries).

Show Missing Areas (M35 with M18): the session is still running, so `LiveMeshScreen` opens on it with the missing areas sorted by walking distance. An arrow (SwiftUI, rotated by the target's direction in camera space, pinned to the screen edge when off screen) and the tier 2 text "Walk toward the arrow and scan the red area" guide the user; the area is marked filled when its samples reach at least 1 observation, then Next Area. The patch pass records mesh and keyframes into `raw/sessions/<s>/mesh-pass/` and returns to the quality screen with updated numbers. RoomPlan data does not change in a patch pass (wall detection gaps need Rescan Room, which is offered when a wall has fewer than 2 completedEdges).

---

## 5. Rendering and viewer

Build 3 uses no custom 3D renderer: 3D Clean opens `CapturedRoom.export(to:exportOptions: .parametric)` (and `.mesh` for the model with cut openings) in QuickLook via `.quickLookPreview($url)`, which includes object and AR viewing for free. Raw Mesh in build 3 is exported to USDZ with the M03 writer and opened the same way.

Build 4 introduces `Viewer3D` (M31), hosted as `ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)` in a UIViewRepresentable (ARView is not deprecated; RealityView's single camera-control mode does not fit an orbit, pan and zoom viewer):
- Camera: `PerspectiveCamera` under `AnchorEntity(world: .zero)`; `OrbitCamera` turns one-finger drag into yaw and pitch, two-finger drag into pan, pinch into distance, double tap into "frame selection". Background `.color(.black)` for scans, system background for the plan.
- Meshes: every mesh goes through `RenderMeshBuilder` into `LowLevelMesh` (verified iOS 18 API: `LowLevelMesh.Descriptor(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType:)`, attributes position, normal, uv0; `withUnsafeMutableBytes(bufferIndex:)`, `withUnsafeMutableIndices`, `parts.replaceAll`), then `try MeshResource(from: lowLevelMesh)` on the main actor. One entity per 2 m tile so tiles can be hidden with `isEnabled`. The array building happens off main; only the memcpy into the LowLevelMesh runs on main.
- Materials, all with `faceCulling = .none` (LiDAR winding is inconsistent):

| Display style | Material |
|---|---|
| Photo Realistic | `UnlitMaterial(texture:)` with atlas pages, one part per page |
| Textured | `UnlitMaterial(texture:)` with the cell page |
| Solid Color | `SimpleMaterial(color:roughness:isMetallic:)` light gray, lit |
| Wireframe | `UnlitMaterial(color:)` with `triangleFillMode = .lines` |
| Raw Mesh | per-face classification colors: faces sorted into parts by class, one `UnlitMaterial(color:)` per class |

  No CustomMaterial, no ShaderGraphMaterial, no .metal file. Per-face colors (classification, coverage, occluded hatching) are always parts plus materials.
- 3D Clean: walls as quads with openings cut (M02 polygon triangulation of the wall rectangle minus opening rectangles), floor polygon, ceiling (hidden by default, shown translucent when inferred), object boxes (`MeshResource.generateBox(size:cornerRadius: 0)` with a translucent category color, `triangleFillMode = .lines` outline). Hide Furniture toggles the `isEnabled` of the movable-objects parent. Occluded spans use a striped texture made once in code.
- Object results: `Entity(contentsOf:)` (async, iOS 18) for the photogrammetry USDZ.
- Picking: `arView.ray(through:)` then CPU `MeshBVH.raycast` (M02) over the raw mesh, and a ray-box test over clean-model objects and wall quads. This avoids async collision-shape generation and gives triangle, normal and classification directly. Tap on an object opens ObjectMenu (Hide, Delete from clean model, Move, Rotate, Measure, Rename, Change category, Show raw geometry); tap on a wall opens WallMenu (Measure, Adjust, Add opening, Add door, Add window, Hide, Inspect geometry). Move and Rotate write `Overrides.objectTransforms`; wall edits go to the plan editor.
- Labels: SwiftUI overlays positioned with `arView.project(_:)` each frame change (measurement values, room names), not 3D text.
- Performance: target 1M triangles in about 100 to 400 tile entities; if frame rate drops under 30, tiles farther than 12 m or outside the frustum are disabled, and Wireframe draws only visible tiles.

Live views: RoomPlan scanning uses RoomCaptureView's own renderer (nothing to build). `LiveMeshScreen` uses `ARView(.ar)` on the hub session with `debugOptions.insert(.showSceneUnderstanding)` in build 4, replaced in build 5 by `CoverageOverlay`: one entity per ARMeshAnchor with a LowLevelMesh at 1.5x capacity and four parts (green, yellow, red, gray `UnlitMaterial` with `.transparent(opacity: 0.45)`), rebuilt from a dirty set at most every 0.33 s, skipped for anchors out of the frustum, paused at thermal `.serious`.

Floor plan screen: SwiftUI `Canvas` drawing `Plan2D` entities through `withCGContext` with the same stroke styles the PDF writer uses; pan and zoom via `DragGesture` and `MagnifyGesture`; selection by model-space hit tests from `PlanHit`.

---

## 6. Measurements and confidence

Sources of measurements, in order of how they are produced:

| Measurement | Source | Pick sigma |
|---|---|---|
| Room length, width, area, perimeter, floor area, ceiling height, wall length, wall height, wall area, door and window width and height | RoomMetrics and CleanWall/CleanOpening (automatic, listed on the result screen) | RoomPlan cap below |
| Point-to-point, angle, area polygon, height | MeasureTool in the viewer (points on raw mesh via BVH, snapped) | 0.003 corner, 0.01 plane, 0.02 raw vertex |
| Live distance | Quick Measure (ARKit raycast) | as above |
| Object width, height, depth, volume, surface area | ObjectModel (MDLAsset bounds, watertight volume) or CleanObject box for room objects | box: max(0.02, 3 percent of size) |

Snapping (`SnapCandidates` + `Snap` from M02), within 10 cm world or 24 pt screen, whichever is smaller: clean-model corners (wall-wall-floor and wall-wall-ceiling intersections), opening corners, object box corners, then wall and object edges, then floor and ceiling planes, then the raw mesh hit. The snapped target is recorded in `MeasurementRecord.snaps` and drives the sigma.

`ConfidenceModel` (research formula, meters):
- `sigmaDepth(d, c) = (0.005 + 0.004 d) * k_c`, `k` = 1 / 1.5 / 3 for high / medium / low confidence, divided by `sqrt(min(n, 9))` with n the voxel observation count, floored at 0.004.
- `sigmaPose(L) = 0.005 L` if tracking stayed normal, `0.015 L` if limited tracking occurred, `0.03 L` after a relocalization (from RoomCaptureLog and CaptureSessionRecord).
- `sigmaTotal = sqrt(sA^2 + sB^2 + sigmaPose^2 + pickA^2 + pickB^2)`; displayed as `Tolerance.plusMinus(2 * sigmaTotal)`, floored at 1 cm, rounded up to 0.5 cm or 0.1 in.
- RoomPlan-derived lengths never show better than `max(0.025, 0.0083 L)` (about 1 in per 10 ft), matching reported drift.
- Over 4 cm: show "Low confidence, rescan this section" (Copy.Measure) instead of a number. Inferred values (ceiling without ceiling coverage, volume from an inferred ceiling, occluded spans) show "Estimated" and no plus-minus.
- Every measurement is shown in both systems via `LengthFormat.both` according to UnitPreferences.

The accuracy protocol in TEST_PLAN.md (tape-measured references) is what calibrates the constants; they live in one `ConfidenceModel.Constants` struct so a single edit retunes them.

---

## 7. Exports (reuse feat/export)

M37 only adapts our models to the Export module's input types and calls its writers. Units: meters, Y up for 3D formats; millimeters for STL and DXF (DXF R12 per the research, $INSUNITS written and the unit stated in the file name and a TEXT note).

| Representation | Formats | Path |
|---|---|---|
| Raw LiDAR mesh | OBJ (per-vertex classification color extension), PLY (binary, colors), STL (mm), GLB, USDZ | MeshExportAdapter: `mesh.mchk` to `ExportMesh`, then OBJWriter, PLYWriter, STLWriter, GLBWriter, USDZWriter |
| Realistic (B5/B6) | USDZ, GLB, OBJ+MTL+JPEG in a ZIP | ExportMesh with texcoords (v flipped for OBJ) and ExportMaterial per page |
| 3D Clean | USDZ (RoomPlan native `.parametric` when there are no overrides; otherwise USDZWriter from the CleanModel mesh), GLB, OBJ, JSON (CapturedRoom / CapturedStructure) | RoomPlan `export(to:metadataURL:modelProvider:exportOptions:)` or CleanModel mesh adapter |
| Floor plan | PDF (vector, auto scale 1/4 in = 1 ft, 1/8 in = 1 ft, 1:50, 1:100, title block, north arrow, scale bar), SVG, DXF, PNG | PlanDrawing to Plan2D, then PDFPlanWriter, SVGWriter, DXFWriter; PNG through UIGraphicsImageRenderer drawing the same Canvas routine |
| Object | USDZ (photogrammetry output as is), OBJ, STL, PLY, GLB | ObjectModel MDLMesh to ExportMesh |
| Measurements | CSV and a room schedule inside the PDF | M37 writes CSV text (name, kind, value in both systems, plus-minus, provenance) |
| Project backup | `.zip` of the package (STORE) | ZipWriter; restore via M38 `ZipReader` |

Sharing: files are staged in `exports/` and shared with `ShareLink(item:preview:)`; multi-file formats are zipped first. QuickLook preview is offered for USDZ, PDF and PNG. Export never reads anything outside the package and never writes into raw/ or edits/.

---

## 8. UX flow and state machines

### 8.1 Screens

```
Home (Projects list, New Scan)
 +-- ModePickerSheet: Room | House / Building | Object | Quick Measure | Advanced Scan
 |     +-- TipsSheet (once per mode, Don't show again)
 |     +-- Room ------> RoomScanScreen -> QualityScreen <-> MissingAreasFlow (LiveMeshScreen)
 |     |                                   -> ProcessingScreen (short) -> ResultScreen
 |     +-- House -----> HouseScreen (room list) <-> RoomScanScreen (per room) -> Finish Building
 |     |                                   -> [AlignRoomsScreen] -> ProcessingScreen -> ResultScreen
 |     +-- Object ----> ObjectScanScreen -> review (point cloud, orbits) -> ProcessingScreen -> ResultScreen (object)
 |     +-- Quick Measure -> LiveMeasureScreen (Save creates a project)
 |     +-- Advanced ---> AdvancedOptions -> Room driver | LiveMeshScreen | Object driver
 +-- Project (tap) -> ResultScreen: [Realistic | 3D Clean | Floor Plan | Raw Scan] + Display, Measure, Hide Furniture, Photos, Edit, Export
 |     +-- House projects: HouseScreen to continue incomplete rooms
 +-- Settings (units, fraction, haptics, wireless debug, Diagnostics)
```

Navigation: one `NavigationStack(path:)` with `enum AppRoute: Hashable { case project(UUID), house(UUID), result(UUID), settings, diagnostics }`; capture screens are `fullScreenCover`s (they own the camera and must fully appear and disappear). Portrait only (current Info.plist); the scanning HUD forces dark color scheme.

### 8.2 State machines (all plain enums driven by @MainActor ObservableObject models)

`ScanFlowModel.phase: ScanFlowPhase`

```swift
enum ScanFlowPhase: Equatable {
    case preflight          // permissions, LiDAR support, free space, thermal, battery warning under 20 %
    case tips
    case capturing          // mode-specific sub-state below
    case quality
    case patching(UUID)     // missing area id being filled
    case finishing
    case processing
    case done(UUID)         // project id
    case failed(String)     // Copy.Errors key
    case cancelled
}
```

Transitions: preflight to tips (first time) or capturing; capturing to quality on Done; quality to patching on Show Missing Areas, patching to quality when filled or on Back; quality to finishing on Finish or Finish Anyway; finishing to processing to done. Cancel from capturing asks for confirmation (Copy.Scanning.cancelConfirm*) and deletes the room's raw folder only after confirmation. Backgrounding during capturing: the session is interrupted; on return the hub shows "Paused. Go back to where you stopped, then tap Resume." and relocalization runs (`sessionShouldAttemptRelocalization` returns true); after 30 s without relocalizing, offer Finish With What You Have.

Room sub-state `RoomScanPhase` (section 3.2). House adds `HousePhase { roomList, scanningRoom(UUID), relocalizing, merging, aligning, finished }`. Object mirrors Apple's `CaptureState` plus `ObjectOnboardingState` from the sample. Quick Measure: `MeasurePhase { searching, placingFirst, placingSecond, showing }`.

Guidance: `GuidanceEngine` takes a `Set<GuidanceKind>` of currently true conditions every 0.25 s and applies the existing `GuidancePolicy` rules (hold 0.75 s, minimum times per tier, gap, interrupts, repeat cooldown, tier 3 quiet period and cap, tier 1 haptic cooldown, VoiceOver announcement). It is pure logic with a SelfTest, so the display rules in UX_COPY.md are enforced in one place for every mode.

Post-scan mode switching: the result screen's segmented control switches between Realistic, 3D Clean, Floor Plan and Raw Scan at any time, for any finished room or house, because all four come from the same raw data. Unavailable ones show why ("Color is still being added", "Floor plans need walls; this was scanned as a space").

Project system: list sorted by recent, search, archive filter; per project Rename, Duplicate (copies package, new id), Archive, Delete (confirm), Export, Back Up (zip), Restore (from Files). Needs-another-scan badge when any room is `needsRescan`.

---

## 9. Build plan

Each build is one batch of modules implemented in parallel on feature branches, each compiled through `workflow_dispatch`, then merged. The version in project.yml goes up by one per build.

| Build | Modules landing | What the user can do afterwards |
|---|---|---|
| 3 (0.3) | M02 Geometry, M03 Export (already briefed), M04 Store, M10 CaptureCore, M11 MeshRecord, M12 Keyframes, M13 Coverage, M14 Guidance, M15 RoomCapture, M20 MeasureCore, M21 Pipeline, M23 RoomModel, M24 FloorPlan, M25 Quality, M30 AppShell, M33 PlanEditor (view only), M34 Results (QuickLook 3D), M35 QualityUI (screen only), M37 ExportUI (USDZ, JSON, PDF, SVG, DXF) | Create a project, scan a room with RoomPlan's live outlines and our guidance banner, see a scan quality screen, then a floor plan with dimensions, room area, perimeter, ceiling height, wall and door sizes in ft-in and metric, view the clean 3D model and the raw mesh in QuickLook (and AR), take photos during the scan, export USDZ, JSON, PDF, SVG and DXF. Raw mesh, keyframes and depth are recorded from day one, so later builds can reprocess build 3 scans. Diagnostics answers every open device question (section 10). |
| 4 (0.4) | M16 ObjectCapture, M17 LiveMeasure, M18 LiveMeshView (wireframe plus minimap), M22 MeshModel, M27 ObjectModel, M31 Viewer3D, M32 MeasureTool, M34 Results (own viewer, object and wall menus, Hide Furniture), M35 Show Missing Areas, M37 all mesh formats | Scan objects with Apple's guided capture and get a textured USDZ with width, height, depth, volume when valid; Quick Measure with snapping and plus-minus; the in-app 3D viewer with Raw Mesh (classification colors), Solid, Wireframe and 3D Clean; tap objects to rename, recategorize, hide; measure inside the model with snapping and confidence; Show Missing Areas to fill gaps; Advanced "space" scans without RoomPlan; export OBJ, PLY, STL, GLB. |
| 5 (0.5) | M26 Texture (cells), M28 Structure, M36 HouseUI, M18 CoverageOverlay (LowLevelMesh colors), M33 PlanEditor (editing), M31 Textured style | House mode room by room with progress list, merge into one plan and model, return to incomplete rooms, manual alignment when merging fails, multiple floors; Textured display (photo-colored mesh); live green, yellow, red, gray overlay in space scans and patch passes; floor plan editing (walls, doors, windows, openings, rooms, measurements, text, symbols, notes) with undo. |
| 6 (0.6) | M26 Texture (chart atlas, exposure gain), M27 ObjectCrop, M38 ProjectOps, Advanced options complete, M31 object move and rotate, BGContinuedProcessingTask behind `#available(iOS 26, *)` on the second phone, `.mapperproj` UTI | Photo Realistic rooms and houses, object crop, full project system (duplicate, archive, backup, restore), all Advanced options, 3D move and rotate of objects, processing that continues in the background on iOS 26. |

Build 3 critical path (the first device test gates the rest): M04, M10, M15 and M30 can start together because their interfaces are fixed here; M23 and M24 can be built and self-tested against a CapturedRoom JSON fixture encoded on the device by build 3's Diagnostics "Save fixture" button (and against a hand-made fixture before that). If M02 or M03 slips, build 3 ships with the floor plan drawn directly from PlanModel in Canvas and only USDZ and JSON exports; nothing else in build 3 needs them.

---

## 10. Risks and mitigations

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | RoomPlan re-runs the shared ARSession and drops scene depth or mesh, or conflicts over the delegate, on iOS 18.3 (research: conflicting community reports, one unanswered Dec 2025 thread). | Medium / high: raw mesh, textures and coverage all depend on it. | Build 3 logs effective configuration after didStartWith, anchor counts and depth presence; re-apply configuration with options [] plus watchdog; defensive delegate relay; if still missing, the two-pass fallback (RoomPlan pass then a same-session mesh and photo pass after `stop(pauseARSession: false)`) uses modules that exist anyway (LiveMeshScreen). Raw capture never depends on RoomPlan. |
| 2 | Texture quality and time on an A15 without Metal, plus coordinate convention mistakes (projection sign, UV flip) that make textures garbage with no local compiler. | Medium / medium: Realistic view is a headline output. | Two stages (cells in build 5 validate conventions cheaply; charts in build 6); one conventions file; Diagnostics UV test pattern and a reprojection check (unproject a depth pixel, reproject, must round-trip under 0.5 px) logged on device; CPU CoreGraphics bake mirrors a shipping open-source app; Metal allowed only for the chart copy if timing demands it. |
| 3 | Multi-room merging fails (StructureBuilder `invalidRoomLocation` or `exceedSceneSizeLimit`, relocalization failures across launches, tracking loss when views are recreated). | Medium / high for House mode. | Keep one RoomCaptureView and ARSession per visit; save a world map per room; every room is usable alone; manual alignment screen with wall and doorway snapping; "Start fresh here" when relocalization fails; alignment stored as overrides, never in raw. |
| 4 | Memory and jetsam (about 3 GB ceiling, no increased-memory entitlement on a free Apple ID). | Low to medium / high. | No retained frames; mesh store only latest per anchor; keyframes on disk, decoded one at a time; photogrammetry runs alone after releasing ObjectCaptureSession; runner checks `os_proc_available_memory()` before each step; build 3 logs the real ceiling. |
| 5 | Thermal throttling during 5-minute scans (silent frame drops, drift). | High / medium. | ThermalGovernor ladder, 4 and 5 minute hints, deviceTooHot handling, thermal timeline in session.json feeding sigmaPose. |
| 6 | CI compile round trips across many parallel agents (wrong API spellings, merge conflicts). | High / medium. | Exact type names fixed in this document; verbatim delegate signatures from research; no macros, no Metal, no SceneKit, no packages; per-module Copy extensions; one owner for project.yml; SelfTests in every pure module. |
| 7 | RealityKit performance at around 1M triangles on the A15. | Medium / medium. | 2 m tiles with isEnabled culling; unlit materials; decimation step reserved in M22; MeshBVH picking off main. |
| 8 | Measurement over-confidence. | Medium / high for trust. | Research-based ConfidenceModel with RoomPlan caps, "Estimated" and "Inferred" labels, low-confidence rescan message, calibration against TEST_PLAN.md tape references. |
| 9 | Storage growth (200 to 350 MB per room). | High / low. | 1 GB free-space gate, raw excluded from backup, Keep all photos option, Checkpoint deletion, per-project size shown. |
| 10 | Object Capture limits (`.reduced` only, shiny or thin objects, undocumented image cap). | Certain / low. | Apple's own flow and copy; log `maximumNumberOfInputImages`; honest volume only when watertight; crop by re-processing. |

Device questions that build 3's Diagnostics must answer (logged through LogStore, readable with tools/phone_log.py): effective ARConfiguration after RoomPlan starts; mesh anchor count and faces per anchor; depth map size and pixel formats; `os_proc_available_memory()` at launch and during a scan; `ObjectCaptureSession.maximumNumberOfInputImages` and `PhotogrammetrySession.limits`; `completedEdges` behavior on a half-scanned wall; floor `polygonCorners` axes; plan handedness on an L-shaped room; thermal timeline and battery percent per minute.
