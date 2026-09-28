# Mapper architecture proposal: fidelity-first

Lens: maximize the geometry, texture and measurement quality that an iPhone 13 Pro Max (A15, 6 GB, LiDAR) can reach on device, without giving up the amateur UX in `docs/SPEC.txt`. Every heavy component below names the researched approach it rests on and a fallback that still ships a result when it fails.

Sources: `docs/SPEC.txt`, `docs/research/raw/*.json` (first research pass and its verdicts; `docs/research/verify/` and `docs/RESEARCH.md` are not on main yet, so where a claim was refuted or left unverified this proposal says so and builds a device check into the plan), `CLAUDE.md`, `ios/project.yml`, `ios/Sources/**`, `docs/UX_COPY.md`, `docs/TEST_PLAN.md`, and the task briefs `docs/tasks/geometry.md` and `docs/tasks/exporters.md`. The branches `feat/geometry` and `feat/export` do not exist on the remote yet; this design reuses the public types those briefs fix (`Polygon2D`, `Segment2D`, `Plane`, `SymmetricEigen3`, `OrientedBox`, `AABB3`, `TriangleMesh`, `Ray`, `MeshBVH`, `Snap`, `ExportMesh`, `ExportScene`, `ExportMaterial`, `Plan2D` and the writers) and never redefines them.

## 0. The fidelity thesis in eight decisions

1. **Capture everything once, process as often as needed.** A scan records the raw LiDAR mesh (anchor-local, lossless), a 10 Hz pose track, motion-gated keyframes with per-frame intrinsics and exposure, the matching LiDAR depth and confidence maps, RoomPlan's `CapturedRoomData`, and a session quality log. Nothing in `raw/` is written after the scan ends. Every model is derived and can be rebuilt by a newer pipeline, so a room scanned with build 3 gets textures in build 4 and better textures in build 6.
2. **One ARSession owned by the app** carries ARKit mesh, depth, keyframes and RoomPlan together, so every representation lives in one world frame. The research verdicts say RoomPlan re-runs the shared session and can drop `.sceneDepth`; the design re-applies the configuration in `captureSession(_:didStartWith:)`, runs a watchdog, and falls back to a second mesh pass on the same session (still one world frame) if RoomPlan blocks meshing.
3. **Plane detection stays off while recording the raw mesh.** ARKit flattens the mesh where it detects planes (arkit-mesh-depth F0). Fidelity wants trim, outlets and slight wall bows kept; planes are fitted later, by us, with residuals we can report.
4. **Textures come from our own view-selection atlas**, not from per-vertex colour: GPU depth-pass occlusion, per-face best view scored by projected area, angle, sharpness and exposure, neighbour smoothing, chart packing into 4096 px pages, a global seam gain solve, then (build 6) local seam levelling and photo-consistency outlier rejection. Per-vertex colour is computed first as a fast preview and as the fallback.
5. **The clean model is RoomPlan refined by the mesh.** RoomPlan gives topology (which surfaces are walls, doors, windows, which door belongs to which wall). The mesh gives geometry: every wall plane is refitted to classified mesh faces with a robust fit, corners are re-intersected, ceiling height is measured from ceiling-classified faces (RoomPlan has no ceiling surface), object boxes are refitted to the mesh inside them.
6. **Every surface cell carries evidence**: measured, estimated (hole-filled), inferred, occluded or unscanned, computed by ray casting from the recorded camera poses. This is what makes HIDE FURNITURE honest.
7. **Every measurement carries a sigma** built from a depth-noise model, the local fit residual, observation count, pose drift between the two endpoints' observation times, and the snap type. The model is calibrated against `docs/TEST_PLAN.md` section 3 before any number is trusted.
8. **Multi-room alignment is two-stage**: shared ARSession plus `StructureBuilder` first; a gravity-constrained 4-DOF point-to-plane ICP on doorway overlap second, used both when `StructureBuilder` throws and to refine rooms joined by hand or by world-map relocalization.

## 1. Module map

Directory per module under `ios/Sources/`. "Owner size" is the expected code volume for one agent in one sitting (about 400 to 1200 lines of Swift). Arrows in "Depends on" point at modules this one imports types from; nothing depends on UI.

| Module | Responsibility | Files | Depends on | Build | Owner size |
|---|---|---|---|---|---|
| Support (exists) | Log, debug server, haptics, device state, settings keys, all UI strings | `Support/*.swift` | none | 1 | exists |
| Units (exists) | Length, area, volume, angle, tolerance formatting and parsing | `Units/*.swift` | none | 2 | exists |
| Geometry (feat/geometry) | Pure simd geometry: polygons, planes, PCA, OBB, triangle mesh, BVH, snapping | `Geometry/*.swift` | none | 3 | brief exists |
| Export (feat/export) | OBJ, PLY, STL, GLB, USDZ, DXF, SVG, PDF, ZIP writers over plain input types | `Export/*.swift` | none | 3 | brief exists |
| Core | Shared model types, Codable simd wrappers, binary record formats, project package paths, error enums, pipeline stage protocol | `Core/Model/*.swift`, `Core/Package/*.swift` | Geometry | 3 | 1200 |
| MeshOps | Mesh algorithms beyond the Geometry brief: robust plane fit, vertex weld across anchors, overlap removal, connected components, small-hole fill, quadric decimation, 4-DOF ICP | `MeshOps/*.swift` | Geometry | 3 (fit, weld), 4 (decimate), 5 (ICP) | 1100 |
| Project | Project store and package I/O: create, list, rename, duplicate, archive, delete, backup and restore (zip), atomic writes, backup exclusion, free-space checks, crash recovery | `Project/*.swift` | Core, Export (ZipWriter) | 3 | 700 |
| Capture | The one ARSession: configuration, delegate hub and multiplexer, RoomPlan bridge, config watchdog, keyframe gate, frame copier, raw writers, mesh chunk store, pose track, thermal governor, world map save and load, session probe | `Capture/*.swift` | Core, Project, Support | 3 | 1400 (two agents: Session+RoomPlan, Keyframes+Writers) |
| ObjectScan | Object Capture flow (ObjectCaptureSession, PhotogrammetrySession), folder manager, orbit state machine, model inspection (ModelIO), large-object mesh path | `ObjectScan/*.swift` | Core, Project, Support | 5 | 800 |
| Coverage | Live 10 cm coverage voxel hash, per-wall expected vs observed area, hole finder, texture coverage, quality report, missing-area clusters and the guide-to-area target | `Coverage/*.swift` | Core, Geometry | 4 | 900 |
| Processing | Job graph and scheduler, mesh consolidation, per-vertex colour preview, clean-model builder and refinement, surface evidence classifier, room merge and alignment, LOD, derived-product cache keys | `Processing/*.swift` | Core, Geometry, MeshOps, Project | 3 (consolidate), 4 (clean refine, evidence), 5 (merge) | 1500 (two agents) |
| Texture | Keyframe loading, Metal depth pass, view selection, smoothing, charts, packing, bake, dilation, seam gains, seam levelling, UV split, CPU fallback bake | `Texture/*.swift`, `Texture/Texture.metal` | Core, Geometry, MeshOps | 4 (v1), 6 (levelling, hi-res) | 1500 (two agents: GPU side, chart side) |
| Render | Post-scan viewer (ARView non-AR), chunk entities over LowLevelMesh, display modes, orbit camera, picking via our BVH, live scan overlay entities | `Render/*.swift`, `Render/Render.metal` | Core, Geometry | 3 (raw, solid), 4 (textured, live overlay) | 1100 |
| Measure | Measurement engine, snapping candidates from the clean model and mesh, endpoint refinement, confidence model, room metrics | `Measure/*.swift` | Core, Geometry, Units | 3 (basic), 4 (refine, confidence) | 800 |
| Plan | Floor plan model derived from the clean model, edit operations as overlays, plan renderer (Core Graphics), hit testing, Plan2D adapter | `Plan/*.swift` | Core, Geometry, Units, Export (Plan2D) | 3 (read-only), 5 (editing) | 1200 |
| ExportAdapters | Project to `ExportScene` and `Plan2D`, RoomPlan USDZ export, per-format options, share packaging | `ExportAdapters/*.swift` | Core, Export, Plan, Project | 3 (plan, raw mesh), 4 (textured) | 600 |
| Diagnostics | Self-test screen: session probe log, projection dot overlay, UV checkerboard, reprojection round-trip, exporter and geometry self-tests | `Diagnostics/*.swift` | Capture, Render, Export, Geometry | 3 | 500 |
| UI | SwiftUI screens and view models; the state machines in section 8 | `UI/<Screen>/*.swift` | everything above | 3 onward | several agents |

Rules that keep parallel work compiling:

- Only Core defines shared types. A module may add internal types but never a public type another module needs.
- Geometry, MeshOps, Core, Units and Export import only `Foundation` and `simd` (Export adds UIKit for the PDF writer, as its brief says). They must compile without ARKit, RoomPlan, RealityKit or Metal, so their self-tests run anywhere.
- ARKit and RoomPlan types appear only in Capture, ObjectScan and the RoomPlan adapter inside Processing (`Processing/RoomPlanAdapter.swift`). Everything downstream sees Core types.
- RealityKit appears only in Render. Metal appears only in Texture and Render (and the optional TSDF stage in Processing, section 4.8).
- Names that collide with Apple types are forbidden in our code: `Measurement` (Foundation), `Surface`, `Object`, `Section` (RoomPlan nested types, risky in files that import RoomPlan), `Transform`, `BoundingBox`, `Entity`, `Scene`, `Material` (RealityKit), `CapturedRoom`, `CapturedStructure`. Core uses `MeasurementRecord`, `CleanWall`, `DetectedObject` and so on.

## 2. Data model

### 2.1 Project package on disk

One folder per project: `Documents/Projects/<uuid>.mapperproj/`, declared as a package UTI (`com.shreehub.mapper.project`, conforming to `com.apple.package` and `public.content`, storage-deploy F10) so Files shows it as one item. In-progress captures are written under `Library/Application Support/Captures/<captureId>/` and moved into the package when the scan ends, so Files never shows half-written data (storage-deploy gotcha). `raw/` and `derived/` are marked `isExcludedFromBackup` after every write batch (the flag resets on some operations, so it is re-applied and verified in the log); `project.json` and `edits/` stay in the iCloud/iTunes device backup because they are small and irreplaceable.

```
<uuid>.mapperproj/
  project.json                 ProjectManifest (Codable, schemaVersion)
  thumbnail.jpg
  raw/                         written once per capture, never modified afterwards
    captures/<captureId>/
      capture.json             CaptureRecord: settings, device, video format, OS, start/end, outcome
      session_log.json         SessionQualityLog: tracking timeline, relocalizations, RoomPlan
                               instructions with durations, thermal and battery timeline, light stats,
                               config-probe results, errors
      mesh/<anchorUUID>.mchk   final geometry of each ARMeshAnchor, anchor-local, plus its transform
      mesh/index.json          anchor list: id, update count, first/last update time, stale flag
      poses.ptrk               10 Hz pose track (binary PoseSample records)
      keyframes/index.json     [KeyframeRecord]
      keyframes/kf_000123.jpg  1920x1440 landscape sensor orientation, JPEG q 0.9
      keyframes/kf_000123.d16  depth, Float16 metres, 256x192 (size read at runtime)
      keyframes/kf_000123.cf8  confidence, UInt8 raw ARConfidenceLevel values
      depthstream/ds_004512.d16/.cf8 + depthstream/index.json   (Maximum detail only, 5 Hz)
      stills/st_000004.heic + stills/index.json   hi-res stills and user "Take Photo" shots
      roomplan/capturedRoomData.json   CapturedRoomData (Codable), the re-processable RoomPlan raw
      roomplan/capturedRoom.json       CapturedRoom from RoomBuilder at scan end (Codable)
      worldmap.arworldmap              NSKeyedArchiver, mesh anchors stripped from map.anchors
      object/Images/ object/Checkpoint/   Object Capture input (object captures only)
  derived/                     regenerable; each product has a cache key (section 4.1)
    products.json              DerivedIndex: product -> {pipelineVersion, inputHash, files, status}
    mesh/consolidated.tmsh     ConsolidatedMesh (world space, welded, provenance per face)
    mesh/lod_view.tmsh         decimated copy for the viewer (about 300k faces)
    mesh/vertex_colors.bin     preview colours per consolidated vertex
    texture/textured.tmsh      UV-split mesh with submesh per page
    texture/atlas_0.jpg ...    atlas pages, 4096 x 4096
    texture/texture_report.json   per-face chosen keyframe, texel density stats, gains
    clean/clean_model.json     CleanModel (walls, openings, rooms, objects, levels, evidence)
    clean/evidence_<planeId>.sev   SurfaceEvidenceMap per wall/floor/ceiling plane
    structure/capturedStructure.json   StructureBuilder result for houses
    structure/alignment.json   per-room rigid transforms from StructureBuilder or ICP
    plan/plan_base.json        PlanModel derived from the clean model
    quality/coverage.cvx       final coverage voxels
    quality/quality.json       ScanQualityReport
    object/model.usdz          Object Capture output
    object/object_metrics.json dimensions, surface area, volume validity
  edits/                       user overlays, append-only operation logs; never touch raw/
    clean_edits.json           label corrections, hidden, deleted-from-clean, moved, rotated
    plan_edits.json            PlanEdit operations with undo pointer
    measurements.json          [MeasurementRecord]
    annotations.json           notes, text labels, symbols
    alignment_edits.json       manual room placement
    crop.json                  object crop box
  exports/<timestamp>-<format>/   files handed to the share sheet (kept until the user clears them)
```

Binary record formats (all little endian, written through the `ByteWriter` helper from the Export brief, read with `loadUnaligned` so header offsets need not be 16-byte aligned, storage-deploy F20):

| File | Header (32 bytes) | Payload |
|---|---|---|
| `.mchk` | magic `MCHK`, version UInt16, flags UInt16 (bit0 has classification), vertexCount UInt32, faceCount UInt32, updateCount UInt32, reserved to 32 | anchor transform 16 x Float32 column-major; positions packed 3 x Float32 per vertex (stride 12, not `SIMD3<Float>`'s 16); normals packed 3 x Float32; indices 3 x UInt32 per face; classification 1 x UInt8 per face |
| `.ptrk` | magic `PTRK`, version, recordSize UInt32, count UInt32 | per record: timestamp Float64, transform 16 x Float32, trackingState UInt8, trackingReason UInt8, mappingStatus UInt8, thermal UInt8, ambientIntensity Float32, exposureDuration Float32 (84 bytes) |
| `.d16` / `.cf8` | magic `DPTH` / `CONF`, version, width UInt32, height UInt32 | row-major Float16 metres / UInt8 levels in sensor orientation |
| `.tmsh` | magic `TMSH`, version, vertexCount, faceCount, attribute flags | positions, normals, optional uv (Float32 x 2), optional colour (UInt8 x 4), indices, face class, face provenance, face observation count, optional submesh table |
| `.sev` | magic `SEVM`, version, width, height, cellSize Float32, plane frame 16 x Float32 | UInt8 SurfaceEvidence per cell |
| `.cvx` | magic `CVOX`, version, count, cellSize | per cell: packed key UInt64, observations UInt8, bestAngle UInt8, bestTexel UInt8, flags UInt8 |

Why anchor-local plus transform for the raw mesh: it is exactly what ARKit delivered (arkit-mesh-depth F9), so no floating point is lost and a later pipeline that wants to re-pose anchors (for example after ICP) can do so. World space is a derived product.

Storage per room at High detail (storage-deploy F23, texturing F9): keyframes 150 to 250 MB, depth plus confidence 40 to 60 MB, mesh 15 to 40 MB, world map 5 to 30 MB, derived 60 to 120 MB. Total 270 to 500 MB. Maximum detail adds the depth stream (about 150 MB per 5 minutes) and stills. The scan start refuses below 1.5 GB free (`volumeAvailableCapacityForImportantUsage`) and warns below 3 GB. Settings offers "Remove original photos" per project once textures exist; that is the one explicit, user-confirmed exception to "raw is never deleted", and it keeps the mesh, poses and RoomPlan data.

### 2.2 In-memory Swift types (Core)

Exact names. All are value types unless noted; all Codable ones use the simd wrappers because `simd_float4x4` is not Codable (storage-deploy F4).

**Codable wrappers and IDs**

| Type | Shape |
|---|---|
| `CodableMatrix4` | `var m: [Float]` (16, column-major); `init(_ m: simd_float4x4)`, `var simd: simd_float4x4` |
| `CodableMatrix3` | same for `simd_float3x3` (9) |
| `CodableVector3`, `CodableVector2` | `x, y, z` / `x, y` Floats with `simd` accessors |
| `ProjectID`, `CaptureID`, `KeyframeID` | `typealias` to `UUID` / `UUID` / `Int` |

**Project**

| Type | Fields |
|---|---|
| `ProjectManifest` | `schemaVersion: Int`, `id: ProjectID`, `name: String`, `kind: ScanKind`, `createdAt: Date`, `modifiedAt: Date`, `isArchived: Bool`, `captures: [CaptureRecord]`, `rooms: [RoomRecord]`, `levels: [LevelRecord]`, `settings: CaptureSettings`, `derived: DerivedIndex` |
| `ScanKind` | enum `room, house, object, quickMeasure, advancedSpace, advancedObject` |
| `CaptureRecord` | `id: CaptureID`, `kind: CaptureKind`, `roomID: UUID?`, `startedAt: Date`, `endedAt: Date?`, `outcome: CaptureOutcome`, `folder: String`, `deviceModel: String`, `osVersion: String`, `videoFormat: String`, `probe: SessionProbeResult` |
| `CaptureKind` | enum `roomPlanWithMesh, meshOnly, meshPassAfterRoomPlan, objectCapture, largeObjectMesh, quickMeasure` |
| `CaptureOutcome` | enum `inProgress, completed, cancelled, interrupted, recovered, failed(String)` (Codable via a manual key) |
| `CaptureSettings` | `detail: DetailLevel`, `keepPhotos: Bool`, `detectRooms: Bool`, `detectObjects: Bool`, `range: ScanRange`, `hiResStills: Bool`, `depthStreamHz: Int` |
| `DetailLevel` | enum `standard, high, maximum` (UX copy: Standard, High, Maximum) |
| `ScanRange` | enum `near, normal, far` with `depthWindow: ClosedRange<Float>` 0.25...2.0, 0.3...4.0, 0.3...5.0 m |
| `RoomRecord` | `id: UUID`, `name: String`, `levelID: UUID?`, `captureIDs: [CaptureID]`, `status: RoomStatus`, `alignment: CodableMatrix4?`, `alignmentSource: AlignmentSource` |
| `RoomStatus` | enum `notScanned, scanned, needsMore, rescanning` |
| `AlignmentSource` | enum `sharedSession, structureBuilder, worldMapRelocalized, icpRefined, manual` |
| `LevelRecord` | `id`, `name`, `index: Int`, `floorHeight: Float` |

**Raw scan records**

| Type | Fields |
|---|---|
| `KeyframeRecord` | `id: KeyframeID`, `captureID`, `timestamp: Double`, `source: KeyframeSource` (`video, hiResStill, userPhoto`), `imageFile: String`, `depthFile: String?`, `confidenceFile: String?`, `imageWidth: Int`, `imageHeight: Int`, `intrinsics: CodableMatrix3` (per frame, never global; texturing F1), `cameraTransform: CodableMatrix4`, `exposureDuration: Double`, `exposureOffset: Float`, `iso: Float?`, `ambientIntensity: Float?`, `colorTemperature: Float?`, `sharpness: Float`, `angularSpeed: Float`, `trackingNormal: Bool`, `depthAligned: Bool` (false for hi-res stills) |
| `PoseSample` | binary: see `.ptrk` |
| `MeshChunk` | `anchorID: UUID`, `transform: simd_float4x4`, `positions: [SIMD3<Float>]`, `normals: [SIMD3<Float>]`, `indices: [UInt32]`, `faceClasses: [UInt8]`, `updateCount: Int`, `lastUpdate: Double`, `isStale: Bool`; `func worldPositions() -> [SIMD3<Float>]` |
| `SurfaceClass` | `UInt8` enum mirroring ARMeshClassification raw values `none 0, wall 1, floor 2, ceiling 3, table 4, seat 5, window 6, door 7` (arkit-mesh-depth gotcha: use rawValue, never alphabetical order) |
| `SessionQualityLog` | tracking fractions, `relocalizations: Int`, `instructionSeconds: [String: Double]`, `thermal: [ThermalEvent]`, `battery: [BatterySample]`, `ambientMin/median: Float`, `depthConfidenceHistogram: [Int]`, `roomPlanError: String?`, `configReapplies: Int` |
| `SessionProbeResult` | `configBeforeRoomPlan: String`, `configAfterRoomPlan: String`, `sceneDepthPresent: Bool`, `meshAnchorsReceived: Int`, `delegateStillOurs: Bool`, `framesViaDelegate: Int`, `framesViaPolling: Int`, `depthSize: String`, `videoFormats: [String]` |

**Derived geometry**

| Type | Fields |
|---|---|
| `ConsolidatedMesh` | `mesh: TriangleMesh` (Geometry), `normals: [SIMD3<Float>]`, `faceClass: [UInt8]`, `faceProvenance: [UInt8]` (`FaceProvenance`), `faceObservations: [UInt8]`, `sourceAnchor: [UInt16]` (index into an anchor table) |
| `FaceProvenance` | `UInt8` enum `measured 0, holeFilled 1, fused 2` |
| `TexturedMesh` | `positions`, `normals`, `uvs: [SIMD2<Float>]` (top-left origin internally), `indices`, `submeshes: [TexturedSubmesh]`, `pages: [String]` |
| `TexturedSubmesh` | `page: Int`, `indexStart: Int`, `indexCount: Int` |
| `TextureReport` | `texelSizeMeters: Float`, `pageCount: Int`, `facesTextured: Int`, `facesUntextured: Int`, `meanViewAngle: Float`, `gains: [KeyframeID: SIMD3<Float>]`, `stage timings` |

**Clean model** (all in world metres, Y up)

| Type | Fields |
|---|---|
| `CleanModel` | `rooms: [CleanRoom]`, `walls: [CleanWall]`, `openings: [CleanOpening]`, `objects: [DetectedObject]`, `floors: [CleanSlab]`, `ceilings: [CleanSlab]`, `levels: [LevelRecord]` |
| `ElementEvidence` | `source: ElementSource` (`roomPlan, meshRefined, meshOnly, user`), `roomPlanConfidence: ConfidenceLevel?`, `fitRMS: Float?`, `inliers: Int`, `coverage: Float` (0...1 of the element's area with measured evidence), `completedEdges: Int?` |
| `CleanWall` | `id: UUID` (RoomPlan identifier when it came from RoomPlan), `roomIDs: [UUID]`, `baseLine: Segment3` (two floor-level endpoints), `height: Float`, `plane: Plane` (Geometry), `thickness: Float`, `thicknessSource: ThicknessSource` (`defaultEstimate, measuredPair, user`), `curve: WallCurve?`, `polygon: [SIMD3<Float>]?`, `evidence: ElementEvidence` |
| `CleanOpening` | `id`, `wallID`, `kind: OpeningKind` (`door(isOpen: Bool)`, `window`, `opening`), `offsetAlongWall: Float`, `width: Float`, `sillHeight: Float`, `headHeight: Float`, `evidence` |
| `CleanSlab` | `id`, `roomID`, `outline: Polygon2D` (plan XZ), `height: Float` (world Y), `evidence` |
| `CleanRoom` | `id`, `name: String`, `label: RoomLabel?`, `levelID`, `outline: Polygon2D`, `floorHeight: Float`, `ceilingHeight: Float?`, `ceilingSource: ElementSource` |
| `DetectedObject` | `id`, `category: ObjectCategory`, `categorySource: LabelSource` (`recognizer, user`), `box: OrientedBox` (Geometry), `boxSource: ElementSource`, `recognizerConfidence: ConfidenceLevel?`, `attributes: [String: String]`, `isMovable: Bool`, `evidence` |
| `ObjectCategory` | enum: RoomPlan's 16 (`bathtub, bed, chair, dishwasher, fireplace, oven, refrigerator, sink, sofa, stairs, storage, stove, table, television, toilet, washerDryer`) plus spec extras `cabinet, counter, desk, appliance, column, other` |
| `SurfaceEvidence` | `UInt8` enum `measured 0, estimated 1, inferred 2, occluded 3, unscanned 4` (SPEC "Furniture removal") |
| `SurfaceEvidenceMap` | `planeID: UUID`, `frame: CodableMatrix4`, `cellSize: Float` (0.05), `width: Int`, `height: Int`, `cells: [UInt8]`; `func fraction(_:) -> Float` |

**Floor plan** (plan metres, plan X = world x, plan Y = world z, one mirror fixed in the renderer and verified on device with an L-shaped room, floorplan-cad gotcha)

| Type | Fields |
|---|---|
| `PlanModel` | `levels: [PlanLevel]`, `rooms: [PlanRoom]`, `walls: [PlanWall]`, `openings: [PlanOpening]`, `fixtures: [PlanFixture]`, `annotations: [PlanAnnotation]`, `dimensions: [PlanDimension]` |
| `PlanWall` | `id`, `a, b: SIMD2<Float>`, `thickness`, `thicknessSource`, `curve: WallCurve?`, `levelID`, `isHidden: Bool` |
| `PlanOpening` | `id`, `wallID`, `kind: PlanOpeningKind` (`door(hinge: HingeSide, swing: SwingSide)`, `window`, `opening`), `offset`, `width` |
| `PlanRoom` | `id`, `name`, `polygon: Polygon2D`, `levelID` |
| `PlanFixture` | `id`, `objectID: UUID?`, `category: ObjectCategory`, `center: SIMD2<Float>`, `size: SIMD2<Float>`, `yaw: Float`, `isFurniture: Bool` |
| `PlanEdit` | `id`, `timestamp`, `op: PlanEditOp` |
| `PlanEditOp` | enum: `moveWall, setWallLength, setWallThickness, addWall, deleteWall, addOpening, moveOpening, resizeOpening, flipSwing, renameRoom, mergeRooms, splitRoom, addDimension, deleteDimension, addText, addSymbol, addNote` with associated values |

**Measurements and quality**

| Type | Fields |
|---|---|
| `MeasurementRecord` | `id`, `kind: MeasureKind`, `points: [MeasurePoint]`, `value: Double` (metres, square metres, cubic metres or radians by kind), `confidence: MeasureConfidence`, `label: String?`, `createdAt`, `source: MeasureSource` (`user, automatic, manualEntry`) |
| `MeasureKind` | enum matching SPEC: `pointToPoint, wallLength, wallHeight, ceilingHeight, doorWidth, doorHeight, windowWidth, windowHeight, objectWidth, objectHeight, objectDepth, roomLength, roomWidth, roomArea, floorArea, wallArea, surfaceArea, perimeter, angle, volume` |
| `MeasurePoint` | `position: CodableVector3`, `snap: SnapKind` (`none, corner, wallEdge, edge, floor, ceiling, door, window, objectEdge, plane`), `refinement: PointRefinement` (`raw, planeFit, lineFit, cornerFit`), `sigma: Float`, `observedAt: Double?` (timestamp of best observation) |
| `MeasureConfidence` | `sigma: Float` (metres, 1 sigma), `plusMinus: Float` (2 sigma, floored and rounded), `grade: ConfidenceGrade` (`good, fair, low, estimated, manual`), `terms: [String: Float]` for the log |
| `ScanQualityReport` | `geometry: Float`, `walls: Float?`, `floor: Float?`, `ceiling: Float?`, `textures: Float?`, `objectSides: Float?`, `missingAreas: [MissingArea]`, `summary: QualitySummary` (`good, okay, poor`) |
| `MissingArea` | `id`, `center: CodableVector3`, `normal: CodableVector3`, `extent: Float`, `reason: MissingReason` (`hole, unscanned, lowTexture, lowConfidence, wallEndOpen`), `priority: Int` |

**Pipeline contract**

```swift
/// One derived product. Stages are pure functions of their inputs plus a pipeline version,
/// so the scheduler can skip a stage whose cache key is unchanged.
protocol PipelineStage {
    associatedtype Input
    associatedtype Output
    static var product: DerivedProduct { get }
    static var version: Int { get }
    func cacheKey(for input: Input) -> String
    func run(_ input: Input, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> Output
}
```

`DerivedProduct` is an enum: `consolidatedMesh, vertexColors, viewLOD, cleanModel, surfaceEvidence, structure, floorPlan, texture, quality, objectModel, objectMetrics`.

## 3. Capture pipelines

### 3.1 The shared session (Room, House, Advanced space, Quick Measure)

`CaptureSession` (final class, Capture module) owns one `ARSession`. Construction order matters because the research is split on who owns `arSession.delegate` while RoomPlan runs (arkit verdicts say poll `currentFrame`; the roomplan verdict cites Apple's multi-room article and shipping code that set the delegate on a session passed to `RoomCaptureSession(arSession:)`). The design supports both and logs which one happened.

1. Check gates: `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`, `supportsFrameSemantics(.sceneDepth)`, `RoomCaptureSession.isSupported`, free space, battery, thermal.
2. Build `ARWorldTrackingConfiguration`:
   - `sceneReconstruction = .meshWithClassification`
   - `frameSemantics = [.sceneDepth]` (not smoothed: raw per-frame depth for geometry, arkit recs)
   - `planeDetection = []` for Room, House and Advanced space (no mesh flattening); `[.horizontal, .vertical]` for Quick Measure only
   - `environmentTexturing = .none`, `isLightEstimationEnabled = true`, `videoHDRAllowed = false`
   - `videoFormat = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing ?? ARWorldTrackingConfiguration.supportedVideoFormats[0]` (1920x1440 at 60 on this phone per research; logged)
3. `session.delegate = hub; session.delegateQueue = captureQueue` where `hub` is `CaptureDelegateHub: NSObject, ARSessionDelegate` (nonisolated, no `@MainActor`, storage-deploy F17).
4. `session.run(config)`. After `run`, lock exposure behaviour through `ARConfiguration.configurableCaptureDeviceForPrimaryCamera`: `lockForConfiguration()`, `activeMaxExposureDuration` capped at 1/120 s, auto exposure kept (texturing F11), `unlockForConfiguration()`. Skipped if nil.
5. If the mode uses RoomPlan: `roomSession = RoomCaptureSession(arSession: session)`, `roomSession.delegate = roomBridge` (strong reference kept, the delegate is weak), `roomSession.run(configuration: RoomCaptureSession.Configuration())`.
6. In `captureSession(_:didStartWith:)`: record `session.configuration` into the probe; if `session.delegate !== hub`, wrap the current delegate in `DelegateMultiplexer` (forwards every callback to RoomPlan's delegate first, then to `hub`) and install it; re-apply our configuration with `session.run(ourConfig, options: [])` (never `.resetTracking` or `.removeExistingAnchors`, arkit verdict). Log the configuration again.
7. Watchdog on `captureQueue` every 1 s: if no frame arrived through the delegate for 1 s, start `FramePoller` (a `DispatchSourceTimer` at 30 Hz reading `session.currentFrame`, copying what it needs and dropping the reference); if `frame.sceneDepth == nil` for 2 s or no `ARMeshAnchor` appeared in `frame.anchors` within 5 s of tracking `.normal`, re-apply the configuration once more; after two failed re-applies, mark the capture `meshBlockedByRoomPlan`.
8. `meshBlockedByRoomPlan` fallback: RoomPlan still finishes its pass. When the user taps Done, `roomSession.stop(pauseARSession: false)` keeps the world frame, the app runs our configuration with `options: []` and asks for a 60 to 90 second "detail pass" (`CaptureKind.meshPassAfterRoomPlan`) with the coverage overlay. Mesh, keyframes and RoomPlan data share one world frame either way.

`RoomPlanBridge: NSObject, RoomCaptureSessionDelegate` implements the seven methods with the exact signatures from roomplan F4 (copied verbatim, since a near miss silently becomes a non-conforming method). `didUpdate` feeds the live CapturedRoom snapshot to Coverage (expected wall areas) and to the guidance engine (wall, door, window detected); `didProvide` maps the six `RoomCaptureSession.Instruction` cases to `GuidanceKind`; `didEndWith` stores `CapturedRoomData` JSON at once, then runs `RoomBuilder(options: [.beautifyObjects]).capturedRoom(from:)` and stores `capturedRoom.json`. The final `CapturedRoom`, not the last `didUpdate`, is the truth (roomplan F18).

Build 3 hosts the live view with `RoomCaptureView(frame:arSession:)` (Apple says it preserves the session's settings; it draws the live outlines amateurs expect). Build 4 replaces it with our own `ARView` in `.ar` mode (`automaticallyConfigureSession = false`, `session = ourSession`) so we can draw the coverage overlay. If the probe shows `ARView` taking the delegate or breaking RoomPlan, the fallback keeps `RoomCaptureView` and shows coverage as a top-down mini map (SwiftUI `Canvas`) in the corner instead of on the geometry.

### 3.2 What the capture queue does per frame

All of this runs on `captureQueue` (serial, `.userInitiated`). No `ARFrame` is retained past the callback (arkit gotcha: more than about 10 retained frames starves the camera).

| Step | Rate | Work | Budget |
|---|---|---|---|
| Pose track | every 6th frame (10 Hz) | append `PoseSample` to an in-memory ring, flushed every 2 s by the IO queue | under 0.05 ms |
| Tracking and light | every frame | update tracking fractions, ambient intensity, guidance conditions | under 0.05 ms |
| Keyframe gate | every frame | `KeyframeGate.evaluate` (below); on accept, copy | under 0.1 ms reject, about 1.5 ms accept |
| Mesh anchors | on `didAdd`/`didUpdate` | `MeshChunkStore.ingest`: memcpy vertices, normals, faces, classification respecting `offset` and `stride` (arkit F9), keep latest per anchor id, mark dirty | about 0.2 ms per anchor |
| Mesh removal | on `didRemove` | mark stale, keep data (anchors can come back with the same id, arkit gotcha) | trivial |
| Coverage sample | 3 Hz | hand the latest camera pose, intrinsics and a 64x48 decimated confidence map to Coverage | about 0.3 ms copy |

**KeyframeGate** (texturing F14, storage-deploy recs). Accept a frame when all of: `trackingState == .normal`; translation since last keyframe above `dMin` or rotation above `aMin`; `camera.exposureDuration < 1/60 s`; angular speed from the pose ring below 0.8 rad/s; and at least 0.25 s since the last keyframe. Thresholds by detail level:

| Detail | dMin | aMin | Typical rate | Keyframes per 5 min |
|---|---|---|---|---|
| Standard | 0.20 m | 15 deg | 0.7 per s | about 200 |
| High (default for Room and House) | 0.12 m | 10 deg | 1.2 per s | about 350 |
| Maximum | 0.08 m | 8 deg | 1.8 per s | about 500 |

**FrameCopier.** On accept, the Y and CbCr planes of `capturedImage` are memcpy'd into a buffer from our own `CVPixelBufferPool` of 4 buffers (4.1 MB each) and the depth and confidence maps into two small pooled buffers, then the `ARFrame` is dropped. If all 4 pool buffers are busy (the IO queue is behind) the keyframe is skipped and counted, never queued. The IO queue then converts with `CIImage(cvPixelBuffer:)` and `CIContext.jpegRepresentation` (q 0.9, one shared `CIContext`), converts depth Float32 to Float16, computes sharpness (luma downscaled to 480x360, `MPSImageLaplacian` then `MPSImageStatisticsMeanAndVariance`, about 1 ms; fallback: gradient energy on the CPU at 240x180), writes files through temp-and-rename, and appends the `KeyframeRecord`. Peak extra memory: 4 x 4.1 MB plus depth copies, about 20 MB.

**Hi-res stills** (Maximum detail and "Take Photo"). `session.captureHighResolutionFrame()` (iOS 16 async form), one in flight, never within 2 s of a `run`. Stored as HEIC in `stills/` with the frame's own intrinsics and `imageResolution`, `depthAligned = false` (depth on these frames is reported misaligned, texturing F2). Maximum takes one every 1 m of travel. They are only used by texturing after build 6's intrinsics check (section 4.3) passes on device; until then they are location photos (SPEC item 12).

**Depth stream** (Maximum only). 5 Hz depth plus confidence plus pose, Float16, feeding measurement refinement and the optional TSDF stage. About 150 KB per sample.

**Mesh flush.** `MeshChunkStore` writes a dirty anchor at most every 3 s and always at Done, through the IO queue, into the in-progress capture folder. A force quit loses at most about 3 s of mesh (TEST_PLAN PERF-26 asks for 30 s).

**ThermalGovernor** (quality-coverage F13, recs). Reads `ProcessInfo.processInfo.thermalState` once, then observes `thermalStateDidChangeNotification`:

| State | Action |
|---|---|
| nominal, fair | full rates |
| serious | keyframe gate one level coarser, stop hi-res stills and depth stream, coverage 1 Hz, live overlay refresh 1 Hz, stop hole detection, show `deviceHot` |
| critical | save everything, pause session, show `Copy.Errors.tooHot` |

Plus: idle timer disabled while scanning and processing, battery monitoring on and logged every 30 s, 4-minute warning and suggestion to split the room (RoomPlan's under-5-minutes guidance), memory warning handler that drops the keyframe rate to Standard and flushes the chunk store.

### 3.3 Room

Shared session with RoomPlan, High detail. Done -> RoomPlan `stop(pauseARSession: false)` -> world map saved if `worldMappingStatus` is `.extending` or `.mapped` (mesh anchors stripped from `map.anchors` before archiving) -> quality screen (section 4.7) -> SHOW MISSING AREAS loops back into the same live session (still running, same frame) -> Finish -> `session.pause()`, move capture into the package, start processing.

### 3.4 House / Building

One `CaptureSession` for the whole visit. Room N ends with `roomSession.stop(pauseARSession: false)`; the room list sheet is shown over the still-running camera; "Scan Next Room" calls `run(configuration:)` again on the same `RoomCaptureSession` (roomplan F16). Each room gets its own capture folder, mesh anchors and keyframes are routed to the active room's capture, and the world map is saved after every room so a crash or a break loses at most one room.

Returning later ("Continue Scanning" on an incomplete room, or the next day): new `ARSession` with `initialWorldMap` from the last room saved, run with `[.resetTracking, .removeExistingAnchors]`, relocalization UI until `trackingState` is `.normal`, a "Start fresh here" escape after 30 s. A relocalized capture is flagged `worldMapRelocalized`; its alignment is refined by ICP in processing (section 4.6). The `exceedSceneSizeLimit` error reported right after relocalization (roomplan F16) ends that RoomPlan session and restarts a fresh one with manual placement.

Multi-floor: rooms carry a level; a new level starts with "Add Floor". If the user walks the stairs with the session running, one frame covers both levels; otherwise levels are placed by the stair footprint plus ICP, with manual correction.

### 3.5 Object

Two paths, chosen by size:

- **Object Capture** (default, objects about 8 cm to 1.8 m). Copy of Apple's sample flow (object-capture F16): `ObjectCaptureSession` with a fresh empty `Images/` and `Checkpoint/`, `isOverCaptureEnabled = false`, three orbits with flip logic, `ObjectCaptureView` plus our overlay. Our `ARSession` is not running (Object Capture owns the camera, quality F9). On finish: nil the capture session, then `PhotogrammetrySession(input: imagesURL, configuration:)` with `checkpointDirectory` reused and `.modelFile(url: models/model.usdz)` (detail defaults to `.reduced`, the only iOS level; writing `.medium` does not compile, object-capture F10). Outputs are iterated with an until-complete filter and `@unknown default`.
- **Large object** (vehicles, machines, appliances taller than about 1.8 m, or when detection reports an oversize box; also Advanced "An object"): our shared session without RoomPlan (`CaptureKind.largeObjectMesh`), Maximum-style keyframe gate, a user-placed crop box drawn on the floor. Output goes through the room pipeline (consolidate, crop, texture at 1 to 2 mm texels). This exceeds Object Capture's 2048 px texture cap for big objects, where WWDC24 says area quality drops above 6 feet (object-capture F18).

### 3.6 Quick Measure

Shared session without RoomPlan, `planeDetection = [.horizontal, .vertical]`, mesh on, keyframes off except one still per placed point. Raycast order: our BVH over the current chunk snapshot (rebuilt from `MeshChunkStore` at 2 Hz for chunks within 3 m), then `ARRaycastQuery` `.existingPlaneGeometry`, then `.estimatedPlane` with `.any` (quality F11). Saved as a `quickMeasure` project with its measurements, poses and stills.

### 3.7 Advanced

Same capture code, all switches exposed through `CaptureSettings`: space or object; detail (Standard, High, Maximum); keep all photos; "Find walls, doors and windows" (RoomPlan on or off; off gives `meshOnly` for warehouses, outdoor structures and anything past RoomPlan's 9 x 9 m single-room limit, roomplan F17); "Find furniture and appliances" (clean-model object extraction on or off); scanning distance (`ScanRange` depth window used by coverage, depth fusion and keyframe distance checks).

## 4. Processing pipelines

### 4.1 Scheduler, queues and memory

`ProcessingScheduler` runs stages in a fixed graph on one serial `OperationQueue` (`.userInitiated`, `maxConcurrentOperationCount = 1` for heavy stages) plus one Metal command queue. Each stage writes its product atomically and records `{pipelineVersion, inputHash}` in `derived/products.json`, so a crash or force quit resumes at the first missing product (PERF-27) and a newer pipeline version only reruns what changed. Processing runs in the foreground with the idle timer disabled; iOS 18 has no usable background continuation (storage-deploy F5). On the iOS 26 phone a later build can wrap the job in `BGContinuedProcessingTaskRequest` behind `#available(iOS 26, *)` without the GPU entitlement.

The app checks `os_proc_available_memory()` before each stage and picks the stage's reduced variant when the headroom is below its budget. Working-set target for the whole app: 1.5 GB (storage-deploy F22 estimates a 3 GB ceiling on this phone; build 3 logs the real value).

```
raw captures
  -> [A] RoomPlan adapter (CapturedRoom -> Core types)          CPU, ~0.2 s
  -> [B] mesh consolidation                                       CPU, 3-6 s
  -> [C] vertex colour preview                                    CPU, 2-4 s     (viewer usable here)
  -> [D] clean model refinement                                   CPU, 1-3 s
  -> [E] surface evidence (measured/occluded/unscanned)           CPU BVH, 2-5 s
  -> [F] floor plan base                                          CPU, <0.5 s
  -> [G] view LOD                                                 CPU, 3-6 s
  -> [H] texture atlas                                            GPU + CPU, 15-40 s
  -> [I] quality report (final)                                   CPU, <1 s
house only: [M] StructureBuilder + ICP alignment after all rooms, then [B..I] on the merged set
object: [O1] photogrammetry (Object Capture) or the room path with a crop
```

| Stage | Queue | Peak memory (1 room, 500k faces, 350 keyframes) | Reduced variant when memory is short |
|---|---|---|---|
| B consolidation | processing (CPU, `concurrentPerform` over anchors) | 250 MB | weld per 2 m tile |
| C vertex colours | processing | 120 MB | every 2nd keyframe |
| D clean model | processing | 80 MB | RoomPlan geometry only |
| E evidence | processing | 150 MB (BVH of 500k faces is about 60 MB) | 10 cm cells |
| G LOD | processing | 200 MB | target 200k faces |
| H texture | processing + Metal | 500 MB (4 pages x 64 MB, 2 decoded frames, depth targets, mesh) | 2048 px pages or 4 mm texels, then CPU bake |
| O1 photogrammetry | PhotogrammetrySession (its own threads) | Apple managed; everything else released first | none (Apple's `.automaticDownsampling`) |

### 4.2 Mesh consolidation [B]

Input: final `.mchk` chunks of one or more captures (plus a per-capture rigid transform from alignment). Output: `ConsolidatedMesh`.

1. Transform each chunk to world space (positions with the full 4x4, normals with the rotation part; anchor transforms are rigid, texturing F3).
2. **Overlap removal.** Anchors overlap at their borders (arkit F8). A 2 cm voxel hash records, per voxel, which anchor owns it: the anchor with the most faces whose centroid falls there, ties to the anchor updated last. A face is dropped when its centroid voxel is owned by another anchor and an owner face lies within 1 cm along the normal. This keeps one surface layer instead of z-fighting doubles.
3. **Weld** vertices with a spatial hash at 3 mm (`TriangleMesh.welded(tolerance:)` from Geometry) so anchor seams become shared edges; recompute area-weighted normals.
4. **Clean up**: drop degenerate faces, drop connected components under 50 faces or 0.02 m^2 unless classified (keeps small real objects), drop faces farther than the capture's depth window from every pose that could have seen them (range outliers).
5. **Hole fill, conservative** (SPEC "hole filling where mathematically reasonable"): boundary loops with perimeter under 0.4 m whose vertices fit a plane with RMS under 1 cm are filled by ear clipping on that plane. Filled faces get `FaceProvenance.holeFilled` and render and export with an "estimated" flag; measurements on them are graded `estimated`. Larger holes stay open and become missing areas.
6. Per-face observation count: from the coverage voxels (section 4.7) looked up by centroid.

Fidelity justification: ARKit already fuses depth into the mesh; the losses are at anchor borders (doubles and cracks) and in small holes. Fixing only those keeps every measured vertex where ARKit put it. Fallback: skip steps 2 and 5 (concatenate plus weld), which is what most apps export.

### 4.3 Texturing [H]

The texturing research is the backbone (texturing recs). Conventions fixed once, in Core, with self-tests in build 3 (section 9):

- Projection: `c = inverse(cameraTransform) * (p, 1)`, `z = -c.z > 0`, `u = fx * c.x / z + ox`, `v = -fy * c.y / z + oy`, pixels from the top-left of the landscape sensor image (texturing F0). Depth lookup at `(u * dW / W, v * dH / H)` with sizes read from the files.
- UVs are top-left inside the app; flipped once at the boundary for RealityKit and OBJ (`v' = 1 - v`), confirmed by the numbered checkerboard test.

Stages:

| Step | Where | What | Justification | Fallback |
|---|---|---|---|---|
| H1 input mesh | CPU | the consolidated mesh decimated to the detail target (Standard 300k, High 500k, Maximum 800k faces) with a quadric decimator that preserves boundaries and class borders | A15 time budget scales with faces x keyframes | take the view LOD |
| H2 keyframe pre-selection | CPU | drop keyframes with sharpness below the capture's 20th percentile, tracking not normal, or exposure outliers; cap at 400 | fewer, sharper views beat more views | none needed |
| H3 depth pass per keyframe | Metal render, 960x720 `.depth32Float` (private) plus `.r32Float` linear depth colour target, off-axis projection from K (texturing F8 option B) | exact visibility of every face from every keyframe | option A only: compare with the keyframe's LiDAR depth (min of 2x2, tolerance 3 cm + 3 % of depth) |
| H4 view selection | Metal compute, one dispatch per keyframe over all faces | reject out-of-image (8 px margin), back-facing (`dot(n, toCam) < 0.2`), outside the depth window, occluded (rendered depth vs `-c.z`, epsilon 1.5 cm + 1 %); secondary reject when LiDAR depth is high confidence and disagrees by more than 5 cm (people, moved chairs); score = projected area x cos^2 x sharpness weight x exposure weight; keep best 3 (score, keyframe) per face | 150M face-view tests in under 1 s on the GPU | CPU `concurrentPerform` over faces with the same maths (about 5 to 10 s), depth-map occlusion only |
| H5 photo-consistency (build 6) | CPU | for faces with 3 candidates, compare mean colours; drop a candidate more than 3 sigma from the median (photo-consistency outlier rejection from the multi-view texturing literature, for moving objects) | removes ghosts of people walking through | skip |
| H6 smoothing | CPU | 3 passes: a face switches to a neighbour's keyframe when that candidate keeps at least 70 % of its best score, bonus per agreeing neighbour (ScanSpace's scheme) | fewer, larger charts mean fewer seams | 1 pass |
| H7 charts | CPU | connected components per keyframe, recursive split along the longer axis until fill at least 0.35 and at most 1024 px | proven in ScanSpace | same |
| H8 packing | CPU | global scale to reach the texel target (Standard 4 mm, High 3 mm, Maximum 2 mm) within the page budget (High: 3 pages of 4096^2), shelf packing, 4 px padding | a furnished room is 100 to 200 m^2 of surface (texturing F15) | coarser texel until it fits |
| H9 gain solve | CPU | per keyframe per channel log-gain by weighted least squares on samples along chart seams, Huber reweighting, Jacobi iterations, mean gain 1, clamp [0.5, 2] (texturing F11) | exposure differs frame to frame even with the 1/120 s cap | exposure-metadata normalisation (ISO x exposure time ratio) |
| H10 bake | Metal compute per keyframe: decode JPEG with ImageIO into an `MTLTexture` via `MTKTextureLoader` (no origin option, texturing F9), copy each chart's source rect with bilinear resample and the gain applied into its page | keyframe-by-keyframe keeps peak memory at pages plus 2 decoded frames | CPU bake with Core Graphics (`CGContext.draw` of cropped `CGImage`s), 3 to 5x slower |
| H11 seam levelling (build 6) | CPU + Metal | per chart-boundary vertex colour offsets solved by Jacobi so both sides agree, interpolated over each chart's interior and added during the bake (local seam levelling) | removes the visible tiling a global gain cannot | global gains only |
| H12 dilation | Metal compute (CPU loop fallback) | 4 px push-pull of chart edges into padding | hides bilinear bleeding at chart borders | CPU |
| H13 encode and UV split | CPU | JPEG q 0.9 pages, duplicate vertices shared by charts, one submesh per page | Export and Render need per-vertex UVs | same |

Untextured faces (never seen, all views rejected) get the per-vertex preview colour and count against the Textures quality score.

Time budget (texturing recs): 15 to 40 s on the A15 for 500k faces and 350 keyframes, dominated by JPEG decode (run 2 decode threads ahead of the GPU). PERF-04 asks for under 2 minutes per room end to end.

**Hi-res stills in texturing (build 6).** A still is admitted only after an on-device check: project 20 LiDAR depth samples from the nearest regular keyframe (within 50 ms) into the still using the still's own `intrinsics` and `imageResolution`; mean reprojection error must be under 1.5 px after scaling. If the check fails on this phone the stills stay location photos. Where admitted they compete in H4 with a resolution bonus, giving close-up detail at about 3x the texel density.

**Every Metal component and its fallback.** All shaders live in one `Texture.metal` (plus `Render.metal` for the viewer's optional vertex-colour material), use Metal 2 level features only, and are exercised by a synthetic self-test in the Diagnostics screen before a real scan relies on them.

| Metal component | Why Metal | Fallback that ships |
|---|---|---|
| depth pass (H3) | 350 renders of 500k faces, 1 to 3 ms each | LiDAR depth-map occlusion test on the CPU |
| view selection (H4) | 150M projections | same maths on CPU across 6 cores |
| bake (H10) | resampling 30 to 50 Mtexels | Core Graphics bake |
| dilation (H12) | 3 pages x 16.8 Mtexels, several passes | CPU loop |
| vertex-colour material (viewer) | no built-in RealityKit material reads vertex colours (rendering verdicts) | `ShaderGraphMaterial(materialXLabel:data:)` with a Geometry Color node, or per-face coloured parts |
| TSDF fusion (4.8, optional) | integrating 1500 depth maps into a sparse voxel grid | ARKit mesh (default) |

Sharpness uses MPS kernels (no custom shader). Colour conversion uses Core Image (no custom shader).

### 4.4 Clean model [A, D]

**A. RoomPlan adapter.** `CapturedRoom` or `CapturedStructure` becomes Core types. Walls: endpoints from `transform * (±dimensions.x / 2, 0, 0, 1)` (floorplan F3, marked likely; verified on device in build 3 by logging one wall's columns), plan points from world (x, z); `polygonCorners` go through the full 4x4 and world Y is dropped (floorplan F2: which local axes carry the polygon is undocumented). Curved walls from `curve`. Doors, windows and openings attach to walls by `parentIdentifier`, endpoints projected onto the parent segment and clamped. Floors from `floors[].polygonCorners`, falling back to intersected wall lines. Objects from `transform` and `dimensions`. Room names from `sections` (five real labels, user editable). `confidence` is kept as the recognizer's category confidence, never as dimensional accuracy (quality F2).

**D. Mesh refinement** (the fidelity step; each element keeps its RoomPlan value and the refined value, and uses the refined one only when the acceptance test passes).

| Element | Method | Accept when | Result |
|---|---|---|---|
| Wall plane | faces classified `wall` with centroid within 10 cm of the RoomPlan plane and inside its rectangle (in the wall's local frame, expanded 5 cm); area-weighted IRLS plane fit with PCA (`Plane.fit`) and Huber weights; normal constrained within 2 deg of horizontal | at least 200 faces, coverage at least 30 %, RMS under 1.2 cm, shift under 6 cm, tilt under 2 deg | plane replaced, `source = .meshRefined`, `fitRMS` stored |
| Wall ends and corners | re-intersect adjacent refined planes with each other and with the floor plane (`Plane` three-plane intersection); replace RoomPlan endpoints when the corner moves under 15 cm | adjacent walls within 15 cm and angle between 30 and 150 deg | corner points; wall length becomes corner-to-corner |
| Floor height | median Y of `floor` faces within the room outline | at least 500 faces | slab height |
| Ceiling height | median Y of `ceiling` faces within the outline; per-room histogram detects sloped or stepped ceilings (two modes more than 10 cm apart become two slabs) | coverage at least 25 % of the floor area | `ceilingHeight`, `ceilingSource = .meshRefined`; else max wall height with `.roomPlan` and graded estimated |
| Door and window width | boundary edges of the wall mesh inside the opening rectangle projected on the wall plane; opening jambs = 10th and 90th percentile of boundary points along the wall axis | both jambs found, width within 10 % of RoomPlan | refined width and offset |
| Wall thickness | antiparallel wall pairs across rooms (dot of normals < -0.95, overlap in plan, 5 to 50 cm apart): thickness = plane distance (floorplan F5); exterior walls default 150 mm, interior 115 mm, flagged estimate | pair found | `thicknessSource = .measuredPair` |
| Object boxes | faces inside the RoomPlan box expanded 5 cm, minus faces within 2 cm of wall and floor planes; gravity-aligned `OrientedBox.fit` | at least 100 faces and volume within 50 % of RoomPlan's | refined box, `boxSource = .meshRefined` |
| Mesh-only elements (Advanced "Find walls" off, or regions RoomPlan missed) | region growing over `wall`, `floor`, `ceiling` classified faces into planar segments (normal within 8 deg, 3 cm plane distance), RANSAC-free because the classification seeds regions | segment over 0.5 m^2 | walls and slabs with `source = .meshOnly` |

Counters and cabinets: RoomPlan reports `storage`; objects of category `storage` taller than 0.8 m against a wall become `cabinet`, a horizontal `table`-classified face region at 0.85 to 1.0 m attached to storage becomes `counter`. Columns: vertical mesh-only segments forming a closed loop under 1 m across. These are guesses, stored with `categorySource = .recognizer`, correctable by the user, and never written to `raw/` (SPEC "Automatic object recognition").

### 4.5 Surface evidence and HIDE FURNITURE [E]

For every clean wall, floor and ceiling a 5 cm grid on its plane gets one `SurfaceEvidence` value:

1. **measured**: a consolidated mesh face with provenance `measured` lies within 3 cm of the cell centre along the plane normal.
2. **estimated**: covered only by hole-filled faces.
3. **occluded**: no measured face, and a ray from the cell centre towards at least 80 % of the keyframe camera positions whose frustum contained the cell hits another surface first (our `MeshBVH.raycast` over the consolidated mesh, at most 16 keyframes sampled per cell). This is "blocked by furniture, nothing was seen here".
4. **unscanned**: no keyframe frustum within the depth window ever contained the cell.
5. **inferred**: the clean model draws the surface there anyway (walls are planes behind the sofa), so occluded and unscanned cells on a drawn surface are shown as inferred geometry.

HIDE FURNITURE hides `DetectedObject`s with `isMovable` in the clean view and the floor plan and paints the evidence map behind them (hatched for inferred, grey for unscanned), using the UX copy legend (Measured, Estimated, Inferred, Occluded, Unscanned). No geometry is synthesised beyond the fitted planes; measurements across inferred cells are graded `estimated`.

### 4.6 Rooms, structure and alignment [M]

1. Rooms captured in one session: `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from:)` (floorplan F8). The result is stored; every room keeps its own `CapturedRoom` so a failure still leaves usable rooms.
2. **4-DOF ICP refinement** (MeshOps, build 5). For each pair of rooms that share a doorway (door centres within 0.5 m after the current alignment), sample up to 20k points from `wall`, `door` and `floor` classified faces within 1.5 m of the doorway on both sides; point-to-plane ICP solving yaw plus translation only (ARKit gravity is reliable, so roll and pitch stay fixed), Huber weights, trimmed to the best 80 % of pairs, at most 30 iterations. Accept when the RMS drops and the correction is under 0.3 m and 5 deg; otherwise keep the previous alignment and flag the doorway for "Scan Doorway Again". A final global pass distributes residuals over the room graph (each room's pose is the average of pairwise suggestions, weighted by overlap, 3 iterations).
3. Rooms captured in separate sessions without a successful relocalization: the user drags and rotates the room in "Line Up by Hand" (floor plan view, snapping parallel walls and door centres, floorplan recs), then ICP refines from that start.
4. Continuing a room later (a second capture of the same room): the new capture is aligned to the first by the same ICP over the whole overlap; both captures feed consolidation, each keeps its raw data.
5. Merged house geometry reruns B to I over all rooms with their alignment transforms. Rooms are also kept separately for per-room views.

Levels: rooms are grouped by floor height (1.2 m gap) and RoomPlan's `story` as a hint; one plan page per level.

### 4.7 Coverage and quality [live, I]

**Live** (Coverage module, `coverageQueue`, 3 Hz; quality recs, first algorithm, extended):

- `CoverageGrid`: `[UInt64: CoverageCell]` keyed by packed 10 cm integer coordinates, so it survives ARKit re-meshing. Each 3 Hz tick takes the latest pose and the decimated confidence map, iterates every 4th face of anchors whose bounds intersect the frustum, and for faces 0.3 m to the range limit away, inside the image, within 60 deg of facing and with confidence at least medium, increments the cell's observation count and records the best viewing angle and best texel size seen (`distance / fx`). Colour rule per face: 0 observations gray, 1 to 2 yellow, at least 3 from at least 2 distinct viewpoints green; red for cells flagged as holes (boundary loops inside an anchor, computed on anchor update, skipped at `.serious`) or cells seen only at grazing angles.
- Expected areas from the live `CapturedRoom`: per wall `polygon area - child openings`, observed = area of `wall` faces within 10 cm of the plane inside the rectangle (quality recs, second algorithm).
- Guidance conditions: "Scan the ceiling" when ceiling coverage is under 30 % after 60 s; "Point toward the floor" likewise; "Scan this corner" when a wall lacks `.left` or `.right` in `completedEdges` (a heuristic, verified on device); "Move closer" when the best texel size of the cells in view is worse than the detail target; "This area needs another pass" for red cells in view.

**Quality screen** before Finish (UX copy section 6):

| Row | Computation |
|---|---|
| Shape (geometry) | area-weighted fraction of green cells over all cells with any observation plus unscanned cells inside the room outline |
| Walls | area-weighted mean of per-wall observed/expected, times the RoomPlan factor (1.0 all edges and high confidence, 0.85 missing edge, 0.7 medium, 0.5 low) |
| Floor | floor-classified observed area / floor polygon area |
| Ceiling | ceiling-classified observed area / floor polygon area (RoomPlan has no ceiling) |
| Color and texture | fraction of surface cells whose best texel size meets the detail target from a view within 60 deg |
| Missing areas | clusters of red or unscanned cells over 0.25 m^2 (union-find on adjacent cells), sorted by area |

SHOW MISSING AREAS: the session is still running, so the app shows an arrow (a RealityKit entity pointing from the camera towards the cluster centre) and the hint text, re-evaluates the cluster at 3 Hz, and says "That area is filled in" when its green fraction passes 70 %.

The final report [I] is recomputed from the consolidated mesh and the texture report (the Textures row uses the real atlas result).

### 4.8 Optional depth refusion (Maximum detail, build 6+, experimental)

ARKit's mesh has 3 to 8 cm triangles (texturing F3). With the 5 Hz depth stream stored, a sparse TSDF (8x8x8 voxel blocks at 1.5 cm in a spatial hash, only near surfaces, confidence-medium-and-up depth only, per-voxel weights) can be integrated on the GPU and meshed with marching cubes into a finer surface for trim, outlets and furniture edges. Memory: about 150 m^2 of surface at 1.5 cm with a 6-voxel band is about 4M voxels, 16 MB as half-float TSDF plus weight. It becomes the texturing and measurement mesh only if, on the same scan, its median distance to the ARKit mesh is under 1 cm and its hole area is not larger; otherwise the ARKit mesh stays. This is deliberately last in the plan: no research source measured it on an A15, so it is gated by a device benchmark and never blocks a build.

### 4.9 Floor plan base [F]

`PlanBuilder` converts the clean model into `PlanModel` (plan XY = world x, z). Walls from refined corners, openings from refined jambs, door swing default heuristic (hinge at the end nearer a wall corner, swing into the room whose polygon contains the door centre plus 0.3 m along the normal, floorplan recs), fixtures from objects with plan symbols, room polygons from floor slabs, overall and per-room dimension strings. `plan_base.json` is regenerable; user edits live in `edits/plan_edits.json` and are applied on top at load (section 8.6).

### 4.10 Object model [O1]

- Object Capture output: `model.usdz` (under 50k faces, 2048 px maps, object-capture F10). Dimensions from `MDLAsset(url:).boundingBox` (metric, because the HEICs carry depth). Surface area and volume from `childObjects(of: MDLMesh.self)` buffers; volume shown only when `TriangleMesh.isWatertight` is true (SPEC "estimated volume where mathematically valid"), else the UX copy "Volume unavailable".
- Crop: a user box stored in `edits/crop.json`; the exported and displayed mesh is clipped by it (faces with any vertex outside are dropped), raw stays whole.
- Large-object path: the room pipeline with a crop, textured at 1 to 2 mm, then the same metrics on our own mesh.
- OBJ from Object Capture: request a directory URL once on device (community-confirmed only, object-capture F12); the dependable path is loading the USDZ with ModelIO into `ExportMesh` and using our OBJ writer.

## 5. Rendering and viewer

Stack: RealityKit `ARView(frame:cameraMode: .nonAR, automaticallyConfigureSession: false)` in a `UIViewRepresentable` (not deprecated on the iOS 26 SDK; SceneKit and ARSCNView are deprecated and not used, rendering F0, F1). A `PerspectiveCamera` under `AnchorEntity(world: .zero)` driven by our own orbit, pan and pinch recognisers (RealityView's camera controls take one mode at a time, rendering F2). RealityView stays a later option since it does have projection helpers on iOS 18 (rendering verdict).

**Chunk entities.** The view mesh is split into spatial tiles of about 20k faces (`ChunkEntityFactory`), each a `ModelEntity` whose `MeshResource` comes from a `LowLevelMesh` with the interleaved vertex `position float3, normal float3, uv0 float2, color uchar4Normalized_bgra` and `uint32` indices (rendering recs). Capacities are fixed at creation. `MeshResource(from:)` is awaited (`try await`, the async overload). Materials have `faceCulling = .none` (LiDAR winding is inconsistent). Tiles outside the frustum are `isEnabled = false`.

Display modes (UX copy "Display style"):

| Mode | Material |
|---|---|
| Photo Realistic | `UnlitMaterial(texture:)` per atlas page (`TextureResource(image:withName:options:)`, `semantic: .color`); one part per page |
| Textured | preview vertex colours: `CustomMaterial` unlit surface shader reading `params.geometry().color()` (fallback: `ShaderGraphMaterial` from inline MaterialX, then per-face coloured parts); shown while the atlas is still baking |
| Solid Color | `SimpleMaterial` lit, light grey, for reading shape |
| Wireframe | same mesh, `triangleFillMode = .lines` |
| Raw Scan | the raw ARKit chunks as captured (not consolidated), coloured by `SurfaceClass`, one part per class |

Views (UX copy "View switcher"): Realistic (textured mesh), 3D Clean (walls as extruded slabs with openings cut, floors, ceilings hidden from above, objects as boxes, evidence overlay optional, HIDE FURNITURE), Floor Plan (SwiftUI `Canvas` with the Core Graphics renderer, section 8.6), Raw Scan.

**Textures in memory.** A 4096^2 page with mipmaps is about 85 MB of GPU memory. High detail (3 pages) is 255 MB; the viewer loads pages at 2048 when `os_proc_available_memory()` is under 1 GB and swaps to full resolution on zoom. Maximum detail may need this always.

**Picking and measuring.** Our own `MeshBVH` over the full-resolution consolidated mesh (not the view LOD, not collision shapes), queried with `arView.ray(through:)`. This gives the exact face, normal, classification and provenance at the hit, which the measurement engine needs, and avoids building RealityKit collision shapes (async and slow, rendering F4). `pixelCast` is kept as an instant fallback while the BVH builds.

**Labels.** SwiftUI overlays positioned with `arView.project(_:)` each frame (measurement values, object labels, missing-area arrows).

**Live scan overlay** (build 4): `ARView` in `.ar` mode on our session. One `LowLevelMesh` entity per `ARMeshAnchor`, rebuilt from `MeshChunkStore` copies on the main actor at most every 0.4 s for dirty anchors in the frustum, indices sorted into 4 parts (gray, yellow, red, green) with 4 semi-transparent `UnlitMaterial`s; occlusion from `sceneUnderstanding` is off to avoid z-fighting with our own overlay (rendering F15).

## 6. Measurements and confidence

### 6.1 Placing a point

Snap candidates are built once per project from the clean model and mesh (Measure module, using `Snap` from Geometry), in priority order (quality recs):

1. Refined corners (three-plane intersections of walls and floor or ceiling), opening corners, object box corners.
2. Edges: plane-plane intersection lines of adjacent refined walls, wall-floor and wall-ceiling lines, opening jambs, object box edges.
3. Planes: refined walls, floors, ceilings (point projected onto the plane).
4. Mesh surface via BVH.

Snap radius: the smaller of 24 pt on screen and 10 cm in the world. Every snap is announced with the UX copy (`Snapped to corner`) and a selection haptic.

### 6.2 Refining a point (fidelity step)

A raw BVH hit sits on a 3 to 8 cm triangle. Refinement replaces it with a local fit:

- **planeFit**: gather consolidated-mesh vertices within 4 cm of the hit plus, when the depth stream or keyframe depth exists, depth samples back-projected from the up to 5 best keyframes seeing the point (high confidence only, within 3 m). IRLS plane fit; the point is projected onto the plane. Local sigma = fit RMS / sqrt(n_effective).
- **lineFit** (edges): two plane fits on each side of the edge (faces split by normal clustering), intersection line; the point is projected onto the line.
- **cornerFit**: three planes (or the snapped clean-model corner, which already came from refined planes).

### 6.3 Confidence model

Per endpoint (metres, 1 sigma):

```
sigma_depth(d, c) = (0.005 + 0.004 * d) * k_c          k_high 1.0, k_medium 1.5, k_low 3.0
                    d = distance from the best observing camera, c = its depth confidence
sigma_obs         = sigma_depth / sqrt(min(n, 9)), floored at 0.003     n = coverage observations
sigma_fit         = local fit RMS / sqrt(n_effective) for planeFit, lineFit, cornerFit
sigma_pick        = 0.003 snapped refined corner, 0.006 edge, 0.010 plane, 0.020 raw mesh hit
sigma_point       = sqrt(sigma_obs^2 + sigma_fit^2 + sigma_pick^2)
```

Per measurement between A and B with length L:

```
sigma_pose = L * r + 0.01 * s
    r = 0.005 when tracking was .normal throughout, 0.015 if any limited period, 0.03 after a relocalization
    s = camera path length in metres travelled between the best observations of A and B, capped at 30,
        in units of 10 m (drift grows with the path, not with L alone; the pose track provides it)
sigma_total = sqrt(sigma_A^2 + sigma_B^2 + sigma_pose^2)
plusMinus   = 2 * sigma_total * k_cal, floored at 0.010 m, rounded up to 0.5 cm or 1/8 in (Units.Tolerance)
```

Grades: `good` when plusMinus is at most 2 cm, `fair` up to 5 cm, `low` above 5 cm or when either endpoint had fewer than 2 observations (shows "Low confidence, rescan this section"), `estimated` when an endpoint lies on hole-filled, inferred or occluded surface, `manual` for typed values. RoomPlan-only lengths are never shown better than ±2.5 cm (quality F16). Derived quantities: areas from polygon sigma propagation (each vertex's sigma perpendicular to its edges), volumes only for watertight meshes.

`k_cal` starts at 1.0 and is set once from the TEST_PLAN section 3 table: the smallest value for which at least 8 of 10 reference distances fall inside the shown range (CONF-02). It ships as a constant with the build number that measured it, and the terms of every measurement are logged so the calibration can be redone from logs without rescanning.

Display follows TEST_PLAN 3.8 and `Copy.Measure`: value in the preferred system with the other in parentheses, `Estimated accuracy ±...`, no more decimals than the accuracy supports.

### 6.4 Automatic room metrics

Computed on the clean model after refinement: wall length (corner to corner) and height, ceiling height (mesh-measured when available, per slab for stepped ceilings), door and window width and height, room length and width (the minimum-area rectangle of the floor polygon via `OrientedBox.fit` in 2D), floor area and perimeter (shoelace over the refined outline), wall area (net of openings), surface area (sum over consolidated mesh faces with measured provenance), object width, height and depth from refined boxes. Each gets a `MeasurementRecord` with `source = .automatic` and its own confidence.

## 7. Exports

Writers come from `feat/export` unchanged; `ExportAdapters` converts project data into their input types.

| Output | Source data | Writer | Notes |
|---|---|---|---|
| USDZ realistic | textured mesh, one `ExportMesh` per atlas page with `materialIndex`, `ExportMaterial.textureJPEG` = page bytes | `USDZWriter` | Y up, metres; alternative for comparison on device: write USDA then `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18, verified in doc JSON, untested on device) |
| USDZ clean (RoomPlan) | stored `CapturedRoom` / `CapturedStructure` | `export(to:metadataURL:modelProvider:exportOptions:)` with `.parametric` or `.mesh` | Apple-native, walls without UVs (roomplan F13); refined values are not in it, so our own clean USDZ below is the default |
| USDZ / GLB / OBJ clean (ours) | `CleanModel` extruded to meshes (walls as slabs with opening cuts, objects as boxes, hidden objects optional) | `USDZWriter`, `GLBWriter`, `OBJWriter` | reflects user edits |
| OBJ, GLB textured | textured mesh, v flipped for OBJ | `OBJWriter`, `GLBWriter` | multi-page atlas = multiple materials |
| PLY raw | consolidated mesh with preview vertex colours, or the raw chunks untouched ("original scan") | `PLYWriter` | binary little endian |
| STL | consolidated or object mesh, in millimetres | `STLWriter` | CAD convention |
| PDF, SVG, DXF plan | `PlanModel` with edits applied -> `Plan2D` (layers A-WALL, A-DOOR, A-GLAZ, A-FLOR-IDEN, A-ANNO-DIMS) with dimension labels pre-formatted by Units | `PDFPlanWriter`, `SVGWriter`, `DXFWriter` | DXF in millimetres with the unit in a TEXT note and the file name (floorplan F17) |
| JSON | measurements, room schedule, quality report, object metrics | `JSONEncoder` | for developers |
| Images | PNG snapshots of the viewer and plan | `ARView.snapshot`, `UIGraphicsImageRenderer` | |
| Backup | the whole package | `ZipWriter` (STORE) | Restore unzips into a new package id when the name exists |

Export files are written to `exports/<timestamp>-<format>/` and shared with `ShareLink` (URL is Transferable) or a zipped folder when a format has several files (OBJ plus MTL plus textures).

## 8. UX flow and state machines

View models are `@MainActor` `ObservableObject` classes (Swift 5 mode, no macros needed beyond what SwiftUI already uses) that receive `Sendable` value snapshots from the capture and processing queues through `Task { @MainActor in }`.

### 8.1 App

```
Launch -> CapabilityGate
  noLiDAR            -> UnsupportedScreen (Copy.Errors.noLidar)
  ok                 -> Home (project list, New Scan)
  pendingRecovery    -> Home with "Recover scan?" (captures found in Application Support)
Home -> ModePicker -> [Onboarding tips once per mode] -> ScanFlow(mode)
Home -> ProjectDetail -> Viewer | Rooms (house) | Export | Rename/Duplicate/Archive/Delete/Backup
```

### 8.2 ScanFlow (Room, Advanced space)

```
idle
 -> preparing        (gates, free space, session start, probe)
 -> scanning         (live view, guidance, coverage; Pause/Cancel/Done/Take Photo)
      pause          -> paused (session paused; Resume relocalizes to the same map)
      interrupted    -> relocalizing (sessionShouldAttemptRelocalization true; 30 s -> offer Start Fresh)
      thermalCritical-> savedAndPaused
      cancel         -> confirmCancel -> discarded | scanning
      done           -> finishingRoomPlan (stop(pauseARSession: false), RoomBuilder)
 -> meshPass         (only if meshBlockedByRoomPlan)
 -> reviewQuality    (quality screen)
      showMissing    -> guiding(area i of n) -> reviewQuality
      finish / finishAnyway -> committing (world map, move capture into package)
 -> processing       (stage list with progress; viewer opens as soon as [C] is ready)
 -> viewer
```

### 8.3 HouseFlow

```
roomList (Rooms: done / needs additional scan / not scanned, Add Floor, Finish Building)
 -> nameRoom -> ScanFlow(room, sharedSession: true) -> roomList
 -> continueRoom(id) -> relocalizing -> ScanFlow(room, append capture) -> roomList
 -> finishBuilding -> merging (StructureBuilder) 
      success -> aligningICP -> processing(house) -> viewer
      failure -> alignByHand (drag, rotate, snap) -> aligningICP -> processing(house)
```

A room is "needs additional scan" when its quality summary is poor, a doorway ICP was rejected, or its RoomPlan capture ended with an error.

### 8.4 ObjectFlow

Apple's GuidedCapture state machine (ui-ux F11): `ready -> detecting -> capturing(orbit 1) -> review -> [flip | lower angle] -> capturing(orbit 2) -> ... -> finishing -> reconstructing -> viewer`, with `.failed(cancelled)` treated as restart. Large-object branch: `sizeCheck -> ScanFlow(largeObject) -> cropBox -> processing`.

### 8.5 Viewer

```
viewer(view: realistic | clean | plan | raw, display: photo | textured | solid | wireframe)
  tapObject  -> objectMenu (Hide, Delete from Clean Model, Move, Rotate, Measure, Rename,
                            Change Category, Show Raw Geometry)
  tapWall    -> wallMenu (Measure, Adjust, Add Opening, Add Door, Add Window, Hide, Inspect Scan)
  measure    -> measuring(points 0..n, snapping) -> saved
  crop       -> cropping (object) -> saved
```

"Show Raw Geometry" and "Inspect Scan" highlight the consolidated faces inside the element's box or within 10 cm of its plane, coloured by evidence. All edits append to `edits/`; "Reset to Scan" clears the overlay.

### 8.6 Floor plan editor

`PlanEditor` holds `base: PlanModel`, `ops: [PlanEdit]`, `cursor: Int`; the displayed model is `ops[0..<cursor].reduce(base, apply)`. Undo and redo move the cursor; a new op truncates the redo tail. Hit testing is in model space (segment distance under 12 pt / scale). Wall drag moves along the normal keeping neighbours joined; endpoints snap to other endpoints (5 cm), 0/45/90 deg and a 10 cm or 1 in grid (floorplan recs). The renderer is one `PlanRenderer.draw(model, in: CGContext, scale:, style:)` used by the SwiftUI `Canvas` (through `withCGContext`) and by the PDF export, so the screen and the print match. Toggles: Furniture, Measurements, Room Names, Doors and Windows, Fixtures, Grid, Scale.

## 9. Build plan

Each build is one CI-green IPA installed on the test phone. Raw capture comes first on purpose: scans made with an early build are reprocessed by later builds.

### Build 3: capture everything, see and measure it

Modules: Geometry and Export merged; Core; Project; Capture (shared session, RoomPlan bridge with multiplexer and watchdog, keyframes, depth, mesh store, pose track, thermal governor, world map); Processing A, B, C, F; Render (raw and solid, vertex-colour preview); Measure (snapping to RoomPlan corners and mesh, basic confidence without refinement); Plan read-only; ExportAdapters for PLY, OBJ (untextured), USDZ (RoomPlan parametric), PDF, SVG, DXF plan; Diagnostics; UI: Home, ModePicker (Room live, others "coming soon"), Onboarding, ScanFlow with `RoomCaptureView(frame:arSession:)`, a simple quality screen (RoomPlan walls and completed edges only), Viewer (Raw Scan, 3D Clean boxes, Floor Plan), Projects (rename, delete).

Diagnostics in this build settle the risky facts in one round trip: session probe (configuration before and after RoomPlan, delegate identity, frames via delegate vs polling, `sceneDepth` presence, mesh anchor count, depth size, video formats), projection dots (project mesh vertices into the live image, landscape), depth reprojection round trip (must be under 0.5 px), UV checkerboard (numbered test atlas on a quad in RealityKit), memory ceiling (`os_proc_available_memory()`), exporter and geometry self-tests, `completedEdges` log on a half-scanned wall, wall transform columns log.

User can: scan a room, see the raw LiDAR scan and a coloured preview, see RoomPlan's clean boxes and a floor plan, measure point to point with a ± value, see room dimensions, export plan PDF/SVG/DXF and raw mesh OBJ/PLY and RoomPlan USDZ, keep and rename projects. Photos and depth are already recorded for later texturing.

### Build 4: realistic textures, honest quality

Modules: Texture v1 (H1 to H4, H6 to H10, H12, H13; CPU fallbacks included); Processing D (mesh-refined clean model), E (surface evidence), G (LOD), I; Coverage (live grid, expected areas, holes, quality screen, SHOW MISSING AREAS); Render: Photo Realistic, Wireframe, live coverage overlay on our own `ARView` (or the mini-map fallback); Measure: refinement (planeFit, lineFit, cornerFit) and the full confidence model; ExportAdapters: textured USDZ, OBJ, GLB; Quick Measure mode; Advanced (space) with detail levels.

User can: get a photo-textured room, see green/yellow/red/gray coverage while scanning, get the SCAN QUALITY screen with missing areas and be guided to them, measure with refined points and calibrated ±, use Quick Measure, export textured models.

Calibration task in this build: run TEST_PLAN section 3 and set `k_cal`.

### Build 5: houses, objects, editing

Modules: House flow (shared session across rooms, world map resume, StructureBuilder, 4-DOF ICP, manual alignment, levels); ObjectScan (Object Capture, photogrammetry, metrics, crop, large-object path); Plan editing (all SPEC floor plan edits as overlays, door swing, thickness); viewer object and wall menus, HIDE FURNITURE with evidence legend, label correction; project duplicate, archive, backup and restore.

User can: scan a whole house room by room with a progress list, return to incomplete rooms, fix alignment by hand, scan objects with dimensions and volume, edit the floor plan, hide furniture and see what is measured versus inferred, back up and restore projects.

### Build 6: fidelity upgrades

Modules: Texture H5 (photo-consistency), H11 (seam levelling), hi-res stills after the on-device intrinsics check; Maximum detail depth stream; experimental TSDF refusion behind the benchmark gate; counters, cabinets and columns in the clean model; multi-floor plans; iOS 26 background continuation for processing on the second phone.

User can: pick Maximum detail for sharper textures and finer geometry, get fewer visible seams, see counters and cabinets drawn in the plan, handle multi-storey houses.

## 10. Risks and mitigations

| # | Risk | Evidence | Mitigation | Fallback |
|---|---|---|---|---|
| 1 | RoomPlan re-runs the shared session and drops `.sceneDepth` or mesh, or takes the delegate | arkit verdicts (refuted "config stays in effect"), roomplan F6 (unsure), forum 808834 | re-apply in `didStartWith` with `options: []`, watchdog, delegate multiplexer, `currentFrame` polling; build 3 probe logs everything | sequential mesh pass on the same running session after RoomPlan stops (one world frame kept) |
| 2 | Coordinate-convention errors ruin textures (projection sign, depth pass, UV flips) | texturing gotchas: one sign error makes every texture garbage; no local compiler | conventions in one Core file; build 3 Diagnostics: projection dots, depth reprojection round trip, UV checkerboard | per-vertex colour display remains correct and ships |
| 3 | Memory: 350 keyframes, 500k faces, 3 atlas pages and a viewer on a 6 GB phone without the increased-memory entitlement | storage-deploy F22 (about 3 GB ceiling, unmeasured) | stream everything to disk, bake keyframe by keyframe, stage budgets with `os_proc_available_memory()` checks and reduced variants, viewer page downsampling | coarser texels, 2048 pages, lower face targets |
| 4 | Thermal: LiDAR plus 60 fps plus JPEG encode plus overlay reaches `.serious` within minutes, silently degrading tracking | quality F13 | governor ladder, 4-minute warning, split rooms, log thermal timeline | pause and save at `.critical` |
| 5 | Seams and exposure tiling | texturing gotchas | exposure cap at 1/120 s, sharpness-weighted selection, smoothing, gain solve (build 4), seam levelling and outlier rejection (build 6) | global gains only |
| 6 | Mesh-refined walls worse than RoomPlan in cluttered rooms | none measured | strict acceptance tests per element; both values kept; the log records every rejection | RoomPlan geometry |
| 7 | Confidence overclaims | TEST_PLAN CONF-02 | explicit error model, `k_cal` from the section 3 protocol, grade floor ±1 cm, RoomPlan cap ±2.5 cm, terms logged | show only grades, no number |
| 8 | ICP locks onto the wrong wall (symmetric doorways, corridors) | none measured | 4-DOF only, doorway-local sampling, correction limits 0.3 m and 5 deg, residual check, user confirmation in house view | keep StructureBuilder or manual alignment |
| 9 | `ARView` in `.ar` mode on the shared session conflicts with RoomPlan | not researched directly | build 3 uses `RoomCaptureView(frame:arSession:)`; build 4 tests `ARView` behind a flag | coverage mini map over `RoomCaptureView` |
| 10 | Processing time exceeds PERF-04 (2 min per room) | texturing estimate 15 to 40 s, unmeasured | stage timings in the log, face and keyframe caps per detail level, viewer usable after stage C | Standard detail default |
| 11 | Storage: 300 to 500 MB per room; a house is several GB | storage-deploy F23 | free-space gate, per-project size in the list, "Remove original photos" after texturing, backup exclusion of raw and derived | Standard detail |
| 12 | Hi-res stills: intrinsics scaling undocumented, depth misaligned | texturing F10, arkit F17 | off until the build 6 reprojection check passes on device | 1920x1440 keyframes |
| 13 | CustomMaterial vertex colour not wired to `LowLevelMesh` `.color` on iOS | rendering verdicts (unconfirmed on iOS) | build 3 self-test | ShaderGraphMaterial, then per-face parts |
| 14 | Object Capture stays at `.reduced` (50k faces, 2048 px) | object-capture F10 | large-object path with our pipeline for big items | Object Capture result as is |
| 15 | Many parallel agents, CI-only compiler | CLAUDE.md | Core owns every shared type; Geometry, MeshOps, Core, Export free of Apple AR frameworks; exact delegate signatures copied from research; names that collide with Apple types forbidden; each module ships a self-test | CI error listing per file |

## Appendix A: API facts this design depends on, with status

| Fact | Status in research | Where it is used |
|---|---|---|
| `RoomCaptureSession(arSession:)`, `stop(pauseARSession: false)` (iOS 17) | verified | 3.1, 3.4 |
| Custom configuration survives `RoomCaptureSession.run` | refuted as stated; re-apply pattern from shipping code | 3.1 steps 6 to 8 |
| Setting `arSession.delegate` before `RoomCaptureSession(arSession:)` keeps our callbacks | roomplan verdict: supported by Apple's article and shipping code, not documented | 3.1 step 3, probe |
| ARMeshAnchor buffers anchor-local, UInt32 faces, per-face UInt8 class, reused on update | verified | 3.2, 2.1 |
| ARWorldMap excludes mesh anchors | verified | 2.1, 3.4 |
| Depth 256x192 Float32, confidence 0/1/2 | verified formats, size from samples; read at runtime | 3.2, 4.3 |
| Projection formula with `-fy` and `z = -c.z` | verified from Apple sample and shipping code | 4.3 |
| Per-frame intrinsics vary | verified (forum reports) | 2.2 `KeyframeRecord` |
| `captureHighResolutionFrame` 12 MP, one in flight, depth misaligned | verified API, misalignment community | 3.2, 4.3 |
| SceneKit deprecated in the iOS 26 SDK | verified | 5 (not used) |
| `ARView` not deprecated; `LowLevelMesh`, `triangleFillMode`, `UnlitMaterial(texture:)` iOS 18 | verified | 5 |
| No built-in vertex-colour material; CustomMaterial or ShaderGraphMaterial | verified with correction | 5 |
| `PhotogrammetrySession` iOS: `.reduced` only | verified | 3.5, 4.10 |
| `MDLUtility.convert(toUSDZ:writeTo:)` iOS 18 | verified in doc JSON, untested on device | 7 |
| `polygonCorners` local axes, wall transform column meaning | unverified (floorplan) | 4.4 A, build 3 log |
| `completedEdges` meaning "observed" | community only | 4.7 guidance, build 3 log |
| BGContinuedProcessingTask iOS 26 only | verified | 4.1 |
