# Mapper module breakdown (MODULES.md)

This is the work breakdown for builds 4 to 8. Every implementation agent receives section 0, section 3.1 (the file contract) and exactly one module section from section 3 as its only brief, so each module section is self-contained; the summaries of merged modules (3.2 to 3.9) are the reference for the symbols a section lists under "Uses" and may be attached as needed. The design decisions it implements are in `docs/design/synthesis-decisions.md` (D1 to D27), with one override: the lead decision on the build plan (section 2) replaces D25. Where this file names an Apple API, the declaration is copied from `docs/RESEARCH.md` (APIs RESEARCH does not list are marked "(not in RESEARCH)", see rule 0.2.12); where it names a Mapper type, the name and signature are the real ones on the `integration` branch. `docs/ARCHITECTURE.md` explains the design behind these contracts; the two files use the same names and the same build plan, and where they differ this file's Swift signatures win.

Sources read for this file: `docs/SPEC.txt`, `docs/design/synthesis-decisions.md`, `docs/design/proposal-ship-first.md` (the base), `docs/design/judgements.md`, `docs/design/research-digest.md`, `docs/RESEARCH.md`, `docs/UX_COPY.md`, `docs/TEST_PLAN.md`, and on `integration`: `ios/Sources/Core`, `Geometry`, `Export`, `Units`, `Support`, `Coverage`, `MeshProcessing` and `Texturing` (all merged and compiled green).

---

## 0. How to use this file (rules every agent follows)

Read this section, then your module section, then the "Uses" symbols in the real source files. When anything here disagrees with the real code of a merged module, the code wins; report the difference to the lead in your final message.

### 0.1 Ownership

1. You own exactly one folder, `ios/Sources/<Module>/`, plus one strings file `ios/Sources/Support/Copy+<Module>.swift`. You create and edit nothing else.
2. Never edit: `ios/Sources/Core/` (the shared contract), `ios/project.yml`, `ios/Sources/MapperApp.swift`, `ios/Sources/ContentView.swift`, `ios/Sources/Support/Copy.swift`, `ios/Sources/Support/SettingsKey.swift`, or any file of another module. AppShell (wave 4d) is the only module that edits `ContentView.swift` and `MapperApp.swift`. The lead edits `project.yml` and wires every `<Module>SelfTest.run` into the Diagnostics suite list.
3. If you need a change in Core or in another module, do not work around it by redefining types. Write it as a "Core change request" or "module change request" in your final message with the exact Swift you need. Section 3.0 lists the change requests already known.
4. You compile only against modules of earlier waves (section 2). If your section lists a dependency, it is already merged into `integration` when you start.

### 0.2 Swift rules (D26 plus research facts)

1. Swift 5.9 language mode, iOS 18.0 deployment target, Xcode 26.6 / iOS 26 SDK on CI. No Swift packages, no macros (no `@Observable`, no `#Preview`), no `.metal` files, no SceneKit, no `ARSCNView`.
2. UI models are `@MainActor final class X: ObservableObject` with `@Published` properties. SwiftUI views are structs.
3. ARKit, RoomPlan and Object Capture delegates are plain `NSObject` subclasses, never `@MainActor`. Hop to main with `DispatchQueue.main.async` carrying only value types. Never retain an `ARFrame`, `capturedImage`, `sceneDepth` buffer or `ARMeshGeometry` buffer beyond the callback; copy what you need inside it.
4. Actor isolation violations are hard errors even in Swift 5 mode (RESEARCH 3.9 gotcha 1). Do not call a `@MainActor` member synchronously from a nonisolated context. `UIDevice.current`, `UIApplication.shared`, `ObjectCaptureSession`, `RoomCaptureView`, `ARView` and `LowLevelMesh` are main-actor only.
5. Every `switch` over an Apple enum has `@unknown default` (RoomPlan, ARKit, Object Capture enums are not frozen).
6. No force unwraps and no `try!` except on literals. No `fatalError` in shipping paths.
7. Doc comments (`///`) on every type, property group and function. Plain English comments, no em-dashes, no emojis.
8. Files under about 450 lines. Split by responsibility, not by line count alone.
9. File names must be unique across the whole target: two files named `Pipeline.swift` in different folders fail the build ("filename used twice"). Prefix new file names with your module name when in doubt. Names already used: every file under `ios/Sources/Core`, `Geometry`, `Export`, `Units`, `Support`, `Coverage`, `MeshProcessing`, `Texturing` (for example `Pipeline.swift`, `Crop.swift`, `Mesh.swift`, `Plane.swift`, `Exposure.swift`, `Charts.swift`).
10. Exact Apple API names and argument labels come from `docs/RESEARCH.md`. A delegate method with a near-miss label compiles silently as a plain method and is never called; copy delegate signatures verbatim.
11. Deprecated or unavailable APIs to avoid (RESEARCH section 5): `ARView(frame:cameraMode:)` (2 arguments), `UnlitMaterial.baseColor`/`tintColor`, `MeshResource.generateAsync`, `TextureResource.generate`, `MagnificationGesture`, `RotationGesture`, `UIImpactFeedbackGenerator(style:)` (use `Haptics` from Support or `.sensoryFeedback`), any `viewRotationAngle` API, `LowLevelMesh.Descriptor.allowsPrimitiveRestart`, `PhotogrammetrySession.Request.Detail` other than `.reduced`, `BGContinuedProcessingTask*` and `captureHighResolutionFrame(using:)` without `if #available(iOS 26.0, *)`.
12. An Apple API that `docs/RESEARCH.md` does not list (for example `FileHandle`, `CVPixelBufferCreate`, ImageIO `CGImageSource`/`CGImageDestination`, `AVCaptureDevice.requestAccess(for:)`, SwiftUI `.presentationDetents`) may be used only when it was introduced in iOS 17.0 or earlier and is not deprecated in the iOS 26 SDK. Module sections mark such APIs "(not in RESEARCH)"; the pre-CI reviewer checks those spellings first. Nothing introduced after iOS 18.0 is used without `if #available`, and no iOS 27 symbol is ever named.

### 0.3 Names you must not declare at top level (D10 plus names taken in the target)

- Forbidden generic names: Measurement, Transform, Entity, Scene, Material, Object, Surface, Section, BoundingBox, CapturedRoom, Picker, Label, Image, Text, Color, Path, Shape, Plane, Range, Model, View, Anchor, Frame, Camera, Mesh, Project, Room, Wall, Door, Window. Nested types must not shadow Swift or SwiftUI names either (no nested `Range`, `Type`, `Text`).
- Taken by Core: ElementID, UUIDBytes, FrameLink, Vec2, Vec3, Transform4, OrientedBoxRecord, Intrinsics, MapperError, CoreError, ProjectManifest, ScanMode, ProjectStatus, CaptureSessionRef, RoomRecord, RoomStatus, ObjectRecord, ObjectSize, FloorRecord, QualitySummary, QualityVerdict, ScanSettings, DetailLevel, ScanDistance, ProjectPackage, RawScanFolder, ProjectStore, KeyframeRecord, PhotoPin, CaptureEvent, CaptureEventKind, CaptureSessionRecord, RoomCaptureLog, DegradedMode, SealEntry, SealFile, PoseSample, TrackingSummary, ThermalLevel, MinimapCell, MinimapSnapshot, LiveScanSnapshot, ScanEngineState, ScanEngineEvent, ScanEngine, SnapshotRecording, FakeScanEngine, Provenance, CleanModel, CleanRoom, CleanWall, WallArc, CleanOpening, OpeningKind, DoorSwing, CleanFloor, CleanCeiling, DetectionConfidence, DetectedObject, ObjectCategory, RoomMetrics, PlanAxes, PlanModel, PlanLevel, PlanRoom, PlanWall, PlanOpening, PlanFixture, AnnotationKind, PlanAnnotation, PlanDimension, EditOperation, RoomAlignmentRecord, EditLog, EditApplicable, PipelineStepID, DerivedStamp, DerivedIndex, InputHasher, StepContext, ProcessingStep, MeasurementKind, SnapKind, MeasurementSource, MeasuredValue, MeasurementRecord, MeshChunk, CoreByteReader, MeshChunkFile, DepthMap, DepthFile, PoseTrackFile, CoreSelfTest.
- Taken by Geometry: TriangleMesh, AABB3, OrientedBox, Rectangle2D, Plane, Polygon2D, Segment2D, Ray, TriangleQuery, MeshBVH, MeshBVHBuilder, SnapTarget, SnapResult, Snap, SymmetricEigen3, GeometrySelfTest.
- Taken by Export: ExportMaterial, ExportMesh, ExportScene, ExportError, ExportText, Plan2D, ByteWriter, CRC32, ZipWriter, OBJWriter, PLYWriter, STLWriter, GLBWriter, USDZWriter, DXFWriter, SVGWriter, PDFPlanWriter, ExportSelfTest.
- Taken by Units: UnitSystem, FractionDenominator, UnitPreferences, LengthFormat, AreaFormat, VolumeFormat, AngleFormat, Tolerance, LengthParser, UnitsSelfTest.
- Taken by Support: Copy, GuidanceKind, GuidanceMessage, GuidancePolicy, LogStore, DebugServer, Haptics, DeviceState, SettingsKey. ContentView.swift: ContentView, SelfTestSuite, SelfTestResult.
- Taken by Coverage: SurfaceClass, CoverageFace, CoverageObservation, CoverageState, CoverageWall, CoverageRoomBoundary, CoverageStats, CoverageIntegrateResult, CoverageGrid, MissingArea, ExpectedSample, ExpectedSurfacesResult, ExpectedSurfaces, ScanQualityReport, ScanQuality, GuidanceTracking, GuidanceInput, GuidanceOutput, GuidanceEngine, MeasurementSnapKind, MeasurementEvidence, MeasurementConfidence, CoverageSelfTest.
- Taken by MeshProcessing: MergeChunk (renamed from MeshChunk), ChunkMerge, MeshWithAttributes, MeshTopology, EdgeTable, UnionFind, CropRegion, MeshCrop, HoleFill, MeshSimplify, SimplifyQuadric, SimplifyHeapEntry, SimplifyWorkspace, MeshSmooth, MeshCleanup, ObjectIsolation, MeshProcessingRandom, MeshProcessingSelfTest.
- Taken by Texturing: every name starting with `TX` (for example TXMesh, TXKeyframe, TXOptions, TXResult, TXError, TXExposure, TXCamera, TXAtlasPacker, TXAtlasBaker, TXImageCache), TextureBaker, KeyframeSelector, TexturingSelfTest.
- Taken by the modules in this file: every public type named in a module section below. Check section 3 before inventing a name.

### 0.4 Strings

1. All user-facing text comes from `Copy`. Never hardcode a string a user can see (VoiceOver labels included).
2. New strings go in `ios/Sources/Support/Copy+<Module>.swift` as `extension Copy { enum <Module> { static let ... } }`, in the style of `Copy.swift` and `docs/UX_COPY.md` (voice rules at the top of UX_COPY.md: plain American English, Title Case buttons, guidance sentences without a final period, never say mesh, polygon, LiDAR data, anchor, point cloud, photogrammetry).
3. If `Copy.<Module>` already exists (Home, Modes, Onboarding, Scanning, Guidance, House, Quality, Processing, Viewer, Measure, ObjectMenu, WallMenu, FloorPlan, Project, Export, Settings, Permissions, Errors, Empty, A11y), do not redeclare it: write `extension Copy.<Name> { ... }` in your own file and pick member names that do not exist yet.
4. Reuse existing constants wherever UX_COPY.md already has the text. Each module section lists the existing constants to use and the new ones to add, with their text.
5. All length, area, volume and tolerance text goes through `ios/Sources/Units/` (`LengthFormat`, `AreaFormat`, `VolumeFormat`, `AngleFormat`, `Tolerance`). Never format lengths with `String(format:)` or `Measurement.FormatStyle`.

### 0.5 Self-tests

1. Every module with testable logic ships `enum <Module>SelfTest { static func run() -> [String] }` in `<Module>SelfTest.swift`, returning one line per failing check ("name: detail") and an empty array when all pass, in the style of `UnitsSelfTest`. Each section gives the minimum number of checks and the checks that must exist.
2. Self-tests are plain Swift (no XCTest), deterministic (no `Date()`, no randomness without a fixed seed), run in under 2 seconds on the phone, never run an ARSession, RoomPlan or Object Capture session, the camera or the network (creating a plain configuration or value object is fine), and write files only under `FileManager.default.temporaryDirectory`, cleaning up after themselves.
3. The lead adds `SelfTestSuite(name: "<Module>", run: <Module>SelfTest.run)` to the Diagnostics list. You do not.

### 0.6 Build and review loop

1. Branch `impl/<module>` from `integration`. Compile with `gh workflow run ios-build --ref impl/<module>` and read the "Compiler errors" step. Before each CI run, re-read your diff for type mismatches, wrong labels, missing imports, missing `@unknown default`, isolation mistakes and duplicate file names.
2. Commit author identity stays the default. No session links or personal details in commit messages. Never push to main.
3. Your final message: branch, green run id, files with line counts, the self-test check count, and any change requests.

---

## 1. Module index

Status: "merged" is on `integration` and compiled green (wave 0 is complete: Core, Coverage, MeshProcessing and Texturing were merged with their self-tests in the Diagnostics suite list); "to build" is new; "planned" is specified in full when its build starts. Frameworks are Apple frameworks beyond Foundation and simd.

| Module | Folder | Build | Wave | Depends on (modules; frameworks) | Status |
|---|---|---|---|---|---|
| Support | Support | 1 | - | none; UIKit, Network | merged |
| Units | Units | 1 | - | none | merged |
| Geometry | Geometry | 3 | - | none | merged |
| Export | Export | 3 | - | none; UIKit, CoreGraphics | merged |
| Core | Core | 4 | 0 | Geometry, Export (ByteWriter), Support (LogStore, GuidanceKind); RoomPlan (one file) | merged |
| Coverage | Coverage | 4 | 0 | Support (GuidanceKind, GuidancePolicy) | merged |
| MeshProcessing | MeshProcessing | 4 | 0 | Geometry | merged |
| Texturing | Texturing | 4 | 0 | none; CoreGraphics | merged |
| Store | Store | 4 | 4a | Core, Support | to build |
| CaptureCore | CaptureCore | 4 | 4a | Core, Support; ARKit | to build |
| RoomModel | RoomModel | 4 | 4a | Core, Geometry, MeshProcessing, Support; RoomPlan | to build |
| MeshModel | MeshModel | 4 | 4a | Core, Geometry, MeshProcessing, Export, Support | to build |
| Pipeline | Pipeline | 4 | 4a | Core, Support; UIKit | to build |
| MeasureCore | MeasureCore | 4 | 4a | Core, Geometry, Coverage, Units, Support | to build |
| FloorPlan | FloorPlan | 4 | 4a | Core, Geometry, Export, Units, Support; SwiftUI, CoreGraphics, UIKit, ImageIO | to build |
| Viewer3D | Viewer3D | 4 | 4a | Core, Geometry, MeshProcessing, Support; RealityKit, SwiftUI, UIKit, ImageIO | to build |
| GuidanceUI | GuidanceUI | 4 | 4a | Core, Coverage, Support; SwiftUI, ARKit, RoomPlan, RealityKit | to build |
| MeshRecord | MeshRecord | 4 | 4b | Core, Geometry, CaptureCore, Store, Support; ARKit | to build |
| Keyframes | Keyframes | 4 | 4b | Core, CaptureCore, Store, Texturing, Export (ByteWriter), Support; ARKit, CoreImage, CoreVideo | to build |
| RoomCapture | RoomCapture | 4 | 4b | Core, CaptureCore, Store, RoomModel, GuidanceUI, Coverage, Support; ARKit, RoomPlan, SwiftUI | to build |
| Quality | Quality | 4 | 4b | Core, Coverage, RoomModel, MeshModel, MeasureCore, Store, MeshProcessing, Support | to build |
| TextureJob | TextureJob | 4 | 4b | Core, Texturing, MeshModel, MeshProcessing, Store, Export (ByteWriter), Support; ImageIO, CoreGraphics | to build |
| ScanUI | ScanUI | 4 | 4c | Core, CaptureCore, Store, RoomCapture, MeshRecord, Keyframes, Quality, GuidanceUI, RoomModel, MeshModel, FloorPlan, Units, Support; SwiftUI, AVFoundation, ARKit, RoomPlan | to build |
| QualityUI | QualityUI | 4 | 4c | Core, Quality, Support; SwiftUI | to build |
| Results | Results | 4 | 4c | Core, Store, Pipeline, RoomModel, MeshModel, FloorPlan, MeasureCore, Viewer3D, Quality, TextureJob, Units, Support; SwiftUI, RoomPlan, QuickLook | to build |
| ExportUI | ExportUI | 4 | 4c | Core, Export, Store, RoomModel, MeshModel, FloorPlan, MeasureCore, Quality, TextureJob, Units, Support; SwiftUI, UIKit, RoomPlan | to build |
| HomeUI | HomeUI | 4 | 4c | Core, Store, Pipeline, Units, Support; SwiftUI | to build |
| AppShell | AppShell | 4 | 4d | every build 4 module; SwiftUI, ARKit, RoomPlan, RealityKit | to build |
| Structure | Structure | 5 | 5a | Core, Geometry, RoomModel, Store, Support; RoomPlan | to build |
| CoverageLive | CoverageLive | 5 | 5a | Core, Coverage, CaptureCore, MeshRecord, RoomModel, Support; ARKit | to build |
| LiveMeshView | LiveMeshView | 5 | 5a | Core, CaptureCore, Store, MeshRecord, Keyframes, GuidanceUI, Coverage, Support; ARKit, RealityKit, SwiftUI | to build |
| ObjectCapture | ObjectCapture | 5 | 5a | Core, Store, GuidanceUI, Support; RealityKit, SwiftUI | to build |
| ObjectModel | ObjectModel | 5 | 5a | Core, Geometry, MeshProcessing, Export, Store, Support; ModelIO | to build |
| MeasureTool | MeasureTool | 5 | 5a | Core, Geometry, Viewer3D, MeasureCore, Store, Units, Support; SwiftUI | to build |
| LiveMeasure | LiveMeasure | 5 | 5a | Core, CaptureCore, MeasureCore, Store, GuidanceUI, Units, Support; ARKit, RealityKit, SwiftUI | to build |
| PlanEditor | PlanEditor | 5 | 5a | Core, FloorPlan, Store, Units, Support; SwiftUI | to build |
| CoverageOverlay | CoverageOverlay | 5 | 5b | Core, CoverageLive, LiveMeshView, Coverage, Support; RealityKit, SwiftUI | to build |
| LargeObject | LargeObject | 5 | 5b | Core, CaptureCore, CoverageLive, LiveMeshView, ObjectModel, MeshProcessing, Geometry, Store, Support | to build |
| MissingAreas | MissingAreas | 5 | 5b | Core, CoverageLive, LiveMeshView, Quality, Units, Support; SwiftUI | to build |
| HouseUI | HouseUI | 5 | 5b | Core, Store, Structure, RoomCapture, ScanUI, QualityUI, FloorPlan, Support; SwiftUI | to build |
| ObjectUI | ObjectUI | 5 | 5b | Core, ObjectCapture, ObjectModel, Viewer3D, Store, Units, Support; SwiftUI | to build |
| Viewer3D (build 5) | Viewer3D | 5 | 5a | as in build 4; RealityKit `Entity(contentsOf:)` | to build |
| Build 5 revisions | ScanUI, Results, HomeUI, ExportUI | 5 | 5c | the 5a and 5b modules they wire | to build |
| AppShell (build 5) | AppShell | 5 | 5d | everything | to build |
| ProjectOps | ProjectOps | 6 | 6a | Core, Store, Export (CRC32), Support; SwiftUI, UniformTypeIdentifiers | to build |
| ObjectCrop | ObjectCrop | 6 | 6a | Core, ObjectModel, ObjectCapture, MeshProcessing, Viewer3D, Store, Support; RealityKit | to build |
| AdvancedScan | AdvancedScan | 6 | 6a | Core, Support; SwiftUI | to build |
| ReferenceLength | ReferenceLength | 6 | 6a | Core, Store, MeasureCore, RoomModel, Units, Support; SwiftUI | to build |
| TextureJob (build 6) | TextureJob | 6 | 6a | as in build 4 | to build |
| ExportUI (build 6) | ExportUI | 6 | 6a | as in build 4 plus ObjectModel | to build |
| BackgroundWork | BackgroundWork | 6 | 6a | Core, Pipeline, Support; BackgroundTasks | to build |
| Build 6 revisions | HomeUI, Results, ScanUI | 6 | 6b | the 6a modules they wire | to build |
| AppShell (build 6) | AppShell | 6 | 6c | everything | to build |
| EditMenus | EditMenus | 7 | 7a | Core, Viewer3D, RoomModel, Store, MeasureTool, Support | planned |
| PhotoBrowser | PhotoBrowser | 7 | 7a | Core, Store, Viewer3D, Support | planned |
| SurfaceEvidence | SurfaceEvidence | 7 | 7a | Core, Geometry, MeshModel, RoomModel, Store | planned |
| SpaceScan | SpaceScan | 7 | 7a | Core, LiveMeshView, CoverageLive, MeshModel, Store | planned |
| HeadlessRoom | HeadlessRoom | 7 | 7a | Core, CaptureCore, RoomModel, CoverageLive, CoverageOverlay, GuidanceUI, Store; RoomPlan, RealityKit | planned |
| MeshRefine | MeshRefine | 8 | 8a | Core, Geometry, MeshModel, RoomModel, SurfaceEvidence | planned |
| LevelsAndStairs | LevelsAndStairs | 8 | 8a | Core, Structure, FloorPlan | planned |

---

## 2. Dependency graphs and the build plan

Lead decision (overrides D25): main already shipped build 3 (0.3) with the capability probe and the Units, Geometry and Export self-tests. Build 4 is the room MVP. Coverage, MeshProcessing and Texturing are merged on `integration` as pure-logic modules and Core is the shared contract ("wave 0"). Each build is split into waves; a module compiles on its own branch against wave 0 and earlier waves only. A module never imports a module of the same or a later wave. This section and `docs/ARCHITECTURE.md` section 13 state the same plan.

Membership follows the real dependencies in the module index (section 1), which differ from the example lists in the lead decision in three places: AppShell is the composition root that imports every build 4 screen, so it cannot sit in the same wave as the screens it composes and gets its own final wave 4d; the screens it composes (ScanUI, QualityUI, Results, ExportUI, HomeUI) are wave 4c and talk to each other only through closures that AppShell wires; and GuidanceUI and FloorPlan depend on no other new build 4 module, so they are 4a, not 4b.

### 2.1 Build 4 (0.4), room MVP

```
wave 0 (merged or merging): Support Units Geometry Export Core Coverage MeshProcessing Texturing

wave 4a (imports wave 0 only)                                             est. lines
  Store        ios/Sources/Store        <- Core Support                         900
  CaptureCore  ios/Sources/CaptureCore  <- Core Support              [ARKit]   1400
  RoomModel    ios/Sources/RoomModel    <- Core Geometry MeshProcessing Support  [RoomPlan]   1400
  MeshModel    ios/Sources/MeshModel    <- Core Geometry MeshProcessing Export Support        800
  Pipeline     ios/Sources/Pipeline     <- Core Support                         600
  MeasureCore  ios/Sources/MeasureCore  <- Core Geometry Coverage Units Support              700
  FloorPlan    ios/Sources/FloorPlan    <- Core Geometry Export Units Support               1400
  Viewer3D     ios/Sources/Viewer3D     <- Core Geometry MeshProcessing Support  [RealityKit] 1200
  GuidanceUI   ios/Sources/GuidanceUI   <- Core Coverage Support   [ARKit RoomPlan RealityKit enums]  450

wave 4b (imports wave 0 and 4a)
  MeshRecord   ios/Sources/MeshRecord   <- CaptureCore Store  (+ Core Geometry Support)       500
  Keyframes    ios/Sources/Keyframes    <- CaptureCore Store Texturing  (+ Core Export Support)  900
  RoomCapture  ios/Sources/RoomCapture  <- CaptureCore Store RoomModel GuidanceUI Coverage  (+ Core Support)  1200
  Quality      ios/Sources/Quality      <- RoomModel MeshModel MeasureCore Store Coverage MeshProcessing  (+ Core Support)  800
  TextureJob   ios/Sources/TextureJob   <- MeshModel Store Texturing MeshProcessing  (+ Core Export Support)  700

wave 4c (imports wave 0, 4a, 4b; never another 4c module)
  ScanUI       ios/Sources/ScanUI       <- RoomCapture MeshRecord Keyframes Quality CaptureCore GuidanceUI Store RoomModel MeshModel FloorPlan  1300
  QualityUI    ios/Sources/QualityUI    <- Quality                              400
  Results      ios/Sources/Results      <- Viewer3D FloorPlan MeasureCore RoomModel MeshModel Store Pipeline Quality TextureJob  1300
  ExportUI     ios/Sources/ExportUI     <- MeshModel RoomModel FloorPlan MeasureCore Store Quality TextureJob Export  1100
  HomeUI       ios/Sources/HomeUI       <- Store Pipeline                       500

wave 4d
  AppShell     ios/Sources/AppShell     <- all of the above; edits ContentView.swift, MapperApp.swift  1300
```

Line counts are estimates of Swift excluding the self-test; a module that grows past about 1500 lines is split into two files groups on the same branch, never into a same-wave dependency.

Why no module depends on its own wave: in 4a every dependency is a wave 0 module (checked per row). In 4b, recorders (MeshRecord, Keyframes) plug into RoomCapture only through the `ScanRecorder` protocol of CaptureCore (4a), so RoomCapture never imports them; ScanUI (4c) creates them and hands them to the engine. Quality and TextureJob read the consolidated mesh through MeshModel (4a) and never call RoomCapture. In 4c, the quality sheet (QualityUI) is presented over the scan screen (ScanUI) by AppShell, and the export sheet (ExportUI) is presented from the result screen (Results) by AppShell through an `onExport` closure. Pipeline steps of 4a modules that need another 4a module's output (CleanModelStep needs the consolidated mesh) receive it through an injected closure; AppShell's `ProcessingPlans` wires it.

What an amateur can do after build 4: create a project and scan one room with Apple's RoomCaptureView (live outlines, coaching, wall, door, window and object detection) on an app-owned ARSession that also records the LiDAR mesh, texture keyframes and a pose track; see the scan quality sheet (Shape, Walls, Floor, Ceiling, Color and texture, Missing areas) over the live camera and Finish or Finish Anyway; open the result screen with Realistic, 3D Clean, Floor Plan and Raw Scan (Realistic is the textured mesh when TextureJob finishes, otherwise RoomPlan's own model in Quick Look, otherwise an honest "Color is still being added"); read room length, width, floor area, perimeter, ceiling height, wall, door and window sizes with plus or minus confidence in feet and inches and metric; find the project on Home, delete it; export USDZ, OBJ, PLY, STL, GLB, PDF, SVG, DXF, PNG and JSON; run Settings > Diagnostics (capability probe, all self-tests) and Demo Mode (FakeScanEngine) with no ARKit.

If TextureJob slips, build 4 ships without it (Realistic falls back as above) and TextureJob moves to build 5 wave 5a unchanged.

Wave gates: every module of a wave branches `impl/<module>` from the `integration` head on which the previous wave is merged and green, compiles on its branch through `workflow_dispatch` until green (with its self-test), and merges one at a time with `integration` compiled green after each merge. The lead then adds the module's `SelfTestSuite` line. After wave 4d the lead bumps `MARKETING_VERSION` to 0.4 and `CURRENT_PROJECT_VERSION` in `ios/project.yml`.

Build 4 acceptance on the phone (`docs/TEST_PLAN.md`): MODE-01, MODE-02 and MODE-03 (Room only; other modes show "Coming in a later version"), MODE-04, MODE-05, ROOM-01 to ROOM-05, ROOM-11, TEX-01 and TEX-02 (when TextureJob landed), TEX-06, QUAL-01, QUAL-02, QUAL-04, REC-01, REC-03, REC-05, FURN-01, FURN-02, FURN-04, MEAS-02 to MEAS-06, MEAS-09, MEAS-11, CONF-01 to CONF-04, PLAN-01 to PLAN-04, PLAN-06, EDIT3D-01 (read-only object card), EDIT3D-06, PROJ-01, PROJ-05, PROJ-07, PROJ-09, OFF-01 to OFF-04, EXP-01, EXP-02 (untextured unless TextureJob landed), EXP-03 to EXP-07, EXP-09, EXP-10, the performance checks of TEST_PLAN sections 4.2 to 4.9, and the section 5 smoke list.

### 2.2 Build 5 (0.5)

```
wave 5a (imports build 4)
  Structure      <- RoomModel Store                    [RoomPlan StructureBuilder]
  CoverageLive   <- CaptureCore MeshRecord RoomModel Coverage
  LiveMeshView   <- CaptureCore Store MeshRecord Keyframes GuidanceUI Coverage   [RealityKit ARView .ar]
  ObjectCapture  <- Store GuidanceUI                   [RealityKit Object Capture]
  ObjectModel    <- MeshProcessing Export Store Geometry  [ModelIO]
  MeasureTool    <- Viewer3D MeasureCore Store
  LiveMeasure    <- CaptureCore MeasureCore Store GuidanceUI  [ARView .ar]
  PlanEditor     <- FloorPlan Store
  Viewer3D rev.  <- as build 4 (adds loadModel(_:) for Object Capture USDZ)
  (TextureJob, if it slipped from build 4)
wave 5b (imports build 4 and 5a)
  CoverageOverlay <- CoverageLive LiveMeshView
  LargeObject     <- CoverageLive LiveMeshView ObjectModel CaptureCore
  MissingAreas    <- CoverageLive LiveMeshView Quality
  HouseUI         <- Structure RoomCapture ScanUI QualityUI FloorPlan
  ObjectUI        <- ObjectCapture ObjectModel Viewer3D
wave 5c (revisions of build 4 screens, one agent each)
  ScanUI   (+ CoverageLive hooks, minimap, CoverageOverlay, MissingAreas entry)
  Results  (+ MeasureTool, PlanEditor, object results)
  HomeUI   (+ House, Object, Quick Measure enabled in the mode picker)
  ExportUI (+ house USDZ via CapturedStructure, multi-level plan, object USDZ as produced)
wave 5d
  AppShell (routes for House, Object, Quick Measure, missing areas, editors)
```

After build 5: House mode room by room with progress, merge and alignment (D9), manual alignment, floors; Object mode small and medium (Object Capture) and large (LiDAR mesh driver, side guidance "Capture the left side"); Quick Measure; measuring inside the model with snapping and confidence; floor plan editing through the EditLog with undo; live green, yellow, red and gray coverage; Show Missing Areas.

### 2.3 Build 6 (0.6)

```
wave 6a (imports builds 4 and 5 only)
  ProjectOps       <- Store Export(CRC32)
  ObjectCrop       <- ObjectModel ObjectCapture MeshProcessing Viewer3D Store
  AdvancedScan     <- Core (produces ScanSettings; no driver imports)
  ReferenceLength  <- Store MeasureCore RoomModel
  BackgroundWork   <- Pipeline                       [BackgroundTasks, iOS 26 only behind #available]
  TextureJob rev.  <- as build 4 (adds TextureHighStep)
  ExportUI rev.    <- as build 4 plus ObjectModel
wave 6b (imports 6a)
  HomeUI, Results, ScanUI revisions (project menu, Photo Realistic, crop, reference length, Advanced flow)
wave 6c
  AppShell revision (routes, background processing wiring)
```

After build 6: rename, duplicate, archive, back up and restore (StreamingZip with validation), Free up space; Photo Realistic; object crop; Advanced Scan options including space scans without RoomPlan; reference length correction (D21); background processing on iOS 26 behind `#available`.

### 2.4 Build 7 (0.7) and build 8 (0.8)

Build 7, wave 7a: EditMenus (3D editing: object and wall menus, move, rotate, relabel, recategorize, show raw geometry, inspect geometry), PhotoBrowser (photos associated with scan locations, fly to a photo's pose), SurfaceEvidence (honest measured, occluded, unscanned map for Hide Furniture), SpaceScan (commercial spaces, warehouses and outdoor structures larger than RoomPlan's limits, as multi-pass mesh scans), HeadlessRoom (D15 experiment behind a Diagnostics flag: `RoomCaptureSession(arSession:)` with Mapper's own `ARView` and the live green, yellow, red and gray overlay in Room mode, shipped only if device logs show depth and mesh survive on that path). Wave 7b revises Results, ScanUI and AppShell to wire them.

Build 8, wave 8a: MeshRefine (mesh-refined wall planes and jambs, counters, cabinets, columns and structural features with acceptance tests, keeping both RoomPlan and refined values), LevelsAndStairs (stair links between floors, UP and DN on both levels, level alignment by stairs). Wave 8b revises Results, FloorPlan and AppShell.

Later, not scheduled (none is required by SPEC.txt): per-vertex color display (`ShaderGraphMaterial` spike, RESEARCH 3.5), a Metal visibility pass for texturing if CPU timing is too slow, high-resolution texture stills if the build 6 experiment proves their intrinsics and depth alignment, point cloud (E57, LAS) export, export of Object Capture images for Mac reconstruction, seam-based gain solve improvements, landscape viewer and iPad layout, localization of `Copy`.

Section 4 maps every SPEC item to a module and build.

---

## 3. Module sections

Each module to build has: Purpose; Build and wave; Files; Public Swift API (real declarations, with the queue or actor each member runs on); Uses (exact symbols of other modules); Apple APIs (declarations copied from `docs/RESEARCH.md`); Must NOT do; Copy strings; Self-test; Acceptance checks for the reviewer; SPEC requirements owned. Declarations are the contract other agents code against: keep every name, label and type exactly. You may add private helpers and extra public members, never remove or rename listed ones.

### 3.0 Known change requests (lead decides; agents do not apply them)

Build 4 needs no Core change: every build 4 contract below compiles against Core as merged on `integration`.

- CR-1 (Core, needed before wave 5a, PlanEditor): `EditOperation` cannot express move door, resize door or window, merge rooms or split room. Proposed cases: `moveOpening(opening: ElementID, offset: Float)`, `resizeOpening(opening: ElementID, width: Float, sillHeight: Float, headHeight: Float)`, `mergeRooms(rooms: [ElementID], into: ElementID)`, `splitRoom(room: ElementID, line: [Vec2], newRoom: ElementID)`, each with `targets` entries. Until then PlanEditor implements move and resize as `deleteElement` plus `addOpening`, and merge and split wait for the CR.
- CR-2 (Core, optional): `MeasuredValue.isLowConfidence` uses a fixed 4 cm limit on 2 sigma, while Coverage's `MeasurementConfidence` flags sigma above `max(5 cm, 3 percent of length)` plus tracking and depth criteria. MeasureCore's `MeasureDisplay.isLowConfidence(_:length:)` is the one rule every screen uses (section 3.14); no UI reads `MeasuredValue.isLowConfidence`. The lead may align Core later.
- CR-3 (MeshProcessing): done. `MeshChunk` was renamed `MergeChunk`, and `Cleanup.swift` (`MeshCleanup`) and `ObjectIsolation.swift` (`ObjectIsolation`) are merged. Code against the names in 3.8.
- CR-4 (Core, Phase 4 hardening, not needed for build 4): `RawScanFolder.resolve(_:)` rejects absolute paths and `..` components (Store validates record paths before calling it until then, section 3.10); `ProjectStore.readJSON(_:from:maxBytes:)` with a size cap; `ProjectStore.listProjects()` skips packages whose folder name is not the manifest id; `ProjectStore.writeData(_:to:protection:)` with a file protection option (`docs/ARCHITECTURE.md` section 11).
- CR-5 (Core, documentation only): the `ProjectPackage` doc comment still shows the Object Capture `Checkpoint/` under `raw/objects/<id>/`; it lives at `derived/objects/<id>/checkpoint/` (section 3.33), and the per-module derived files of section 3.1 should be listed there.

### 3.1 Derived and raw file contract (all modules)

Paths below are relative to the project package (`ProjectPackage.root`). Core names the top-level ones; the producing module owns the others and exposes a loader. A consumer in a later wave calls the loader; a consumer in the same wave gets the data through an injected closure.

| Path | Producer | Loader for consumers |
|---|---|---|
| `raw/sessions/<s>/rooms/<r>/` (sealed, `RawScanFolder` names, plus `scan.json`) | RoomCapture via Store | Store `RawScanReader` |
| `raw/sessions/<s>/rooms/<r>/mesh/<anchor>.mchk` | MeshRecord | Store `RawScanReader.meshChunks()`, or Core `MeshChunkFile.decode` |
| `raw/sessions/<s>/rooms/<r>/keyframes.jsonl`, `keyframes/NNNNN.jpg`, `depth/NNNNN.dpth`, `poses.ptrk`, `photos.jsonl`, `photos/<id>.jpg` | Keyframes | Store `RawScanReader` |
| `raw/sessions/<s>/rooms/<r>/capturedroomdata.json`, `capturedroom.json`, `roomlog.json`, `events.jsonl`; `raw/sessions/<s>/session.json` | RoomCapture | RoomModel `CapturedRoomStore`, Store `RawScanReader` |
| `derived/index.json` | Pipeline | Core `DerivedIndex` via `ProjectStore.readJSON` |
| `derived/rooms/<r>/capturedroom.json` (only when raw lacks it) | RoomModel `BuildRoomStep` | RoomModel `CapturedRoomStore` |
| `derived/rooms/<r>/mesh.mchk`, `mesh_inferred.mchk`, `mesh_view.mchk`, `mesh_stats.json` | MeshModel | MeshModel `MeshModelStore` |
| `derived/clean.json` | RoomModel `CleanModelStep` | RoomModel `CleanModelStore` |
| `derived/plan.json`, `thumbnail.jpg` (package root) | FloorPlan | FloorPlan `PlanModelStore`; `ProjectPackage.thumbnailURL` |
| `derived/rooms/<r>/quality.json` | Quality | Quality `QualityStore` |
| `derived/rooms/<r>/texture/textured.mchk`, `textured.tuv`, `page_<n>.jpg` | TextureJob | TextureJob `TextureStore` |
| `edits/editlog.json`, `edits/measurements.json` | Store `EditStore` | Store `EditStore` |
| `exports/<yyyyMMdd-HHmmss>/...` | ExportUI (also Results' Quick Look copy) | none (shared out) |
| `Library/Application Support/InProgress/<scanID>/` (RawScanFolder layout plus `scan.json`, D5) | Store `InProgressScans` (RoomCapture, ObjectCapture, LiveMeshView write through `RawScanWriter`) | Store `InProgressScans.list()`, AppShell `RecoveryService` |
| `raw/sessions/<s>/mesh-pass/<p>/` (build 5 patch and mesh-only passes) | LiveMeshView `MeshScanEngine` via Store | MeshModel `MeshConsolidator.latestChunks(in:)`, Store `RawScanReader` |
| `raw/objects/<o>/` (`Images/`, `objectlog.json`, `SEAL.json`; RawScanFolder layout for large objects) | ObjectCapture, LargeObject (build 5) | ObjectCapture `PhotogrammetryStep`, ObjectModel |
| `derived/objects/<o>/checkpoint/`, `model.usdz`, `dims.json` (build 5) | ObjectCapture (checkpoint, model), ObjectModel (`dims.json`) | ObjectModel, ObjectUI |
| `derived/structure/structure.json`, `alignment.json`, `attempt.json` (build 5) | Structure | Structure |

JSON in the package is written with `ProjectStore.encoder` and read with `ProjectStore.decoder` (ISO 8601 dates, sorted keys). The one exception is RoomPlan's own types (`CapturedRoomData`, `CapturedRoom`, `CapturedStructure`): encode with a plain `JSONEncoder()` and decode with a plain `JSONDecoder()`.

### 3.2 Support (merged, build 1)

Public API used by other modules (`ios/Sources/Support`):
- `enum Copy` with nested enums Home, Modes (Modes.Advanced), Onboarding, Scanning, Guidance, House, Quality, Processing, Viewer, Measure, ObjectMenu, WallMenu, FloorPlan, Project, Export, Settings, Permissions, Errors, Empty, A11y. Examples: `Copy.Viewer.realistic`, `Copy.Measure.accuracy(_ value: String) -> String` (prepends the plus-minus sign itself), `Copy.Quality.percent(_ value: Int) -> String`, `Copy.Errors.tooHot` (a `(title:, body:)` tuple), `Copy.Home.defaultRoomName(_ date: String) -> String`.
- `enum GuidanceKind: String, CaseIterable, Codable` (29 cases, tiers in `Copy.Guidance.all`), `var message: GuidanceMessage`; `struct GuidanceMessage { let text: String; let tier: Int; let minimumSeconds: Double; let haptic: Bool }`; `enum GuidancePolicy` (display rule constants, `canInterrupt(incomingTier:currentTier:currentShownSeconds:)`).
- `final class LogStore { static let shared; func write(_ message: String, category: String = "app"); func files() -> [URL] }`.
- `enum Haptics { static func tap(), firm(), selection(), success(), warning(), error() }`, `enum DeviceState { static var summary: String; static var thermal: String }`.
- `final class DebugServer { static let shared; func start(); func stop(); var token: String }`; `enum SettingsKey { static let wirelessDebug, debugToken, units }`. Modules add keys with `extension SettingsKey { static let <name> = "<name>" }` in their own files.

### 3.3 Units (merged, build 1)

- `enum UnitSystem: String, Codable, CaseIterable { case imperial, metric }`, `enum FractionDenominator: Int { case eighth = 8, sixteenth = 16 }`.
- `struct UnitPreferences: Codable, Equatable { var system: UnitSystem; var fraction: FractionDenominator; var showBoth: Bool; static let standard; static let defaultsKey = "units"; static func load(from: UserDefaults = .standard) -> UnitPreferences; func save(to: UserDefaults = .standard) }`.
- `enum LengthFormat { static func feetInches(_ meters: Double, denominator: FractionDenominator) -> String; static func metric(_ meters: Double) -> String; static func primary(_ meters: Double, prefs: UnitPreferences) -> String; static func both(...) -> String; static func display(_ meters: Double, prefs: UnitPreferences) -> String; static let invalid = "--" }`.
- `enum AreaFormat`, `enum VolumeFormat` with `imperial`, `metric`, `primary`, `both`, `display` (AreaFormat) taking square or cubic meters; `enum AngleFormat { static func degrees(_:) -> String; static func radians(_:) -> String }`.
- `enum Tolerance { static func plusMinus(_ meters: Double, prefs: UnitPreferences) -> String }`: returns the text WITH a leading plus-minus sign ("±0.6\"").
- `enum LengthParser { static func meters(from text: String, prefs: UnitPreferences) -> Double? }`.

### 3.4 Geometry (merged, build 3)

- `struct TriangleMesh: Equatable { var positions: [SIMD3<Float>]; var indices: [UInt32]; init(positions:indices:); var triangleCount: Int; func triangle(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?; var surfaceArea: Float; var boundingBox: AABB3; var signedVolume: Float; var isWatertight: Bool; var boundaryEdges: [(UInt32, UInt32)]; var vertexNormals: [SIMD3<Float>]; func transformed(by: simd_float4x4) -> TriangleMesh; func merged(with: TriangleMesh) -> TriangleMesh; func welded(tolerance: Float = 1e-4) -> TriangleMesh }`.
- `struct AABB3 { var min, max: SIMD3<Float>; static let empty; init(min:max:); init<S: Sequence>(points: S); var isEmpty, center, size; func union(_:); mutating func expand(_:); func expanded(by:); func contains(_:) }`.
- `struct OrientedBox { var center: SIMD3<Float>; var axes: simd_float3x3; var halfExtents: SIMD3<Float>; var volume: Float; var corners: [SIMD3<Float>]; func contains(_:tolerance:); static func enclosing(_:axes:) -> OrientedBox?; static func fit(_ points: [SIMD3<Float>], gravityAligned: Bool) -> OrientedBox? }`.
- `struct Rectangle2D { var center, axis, halfExtents: SIMD2<Float>; var area: Float; static func minimumArea(enclosing points: [SIMD2<Float>]) -> Rectangle2D? }`.
- `struct Polygon2D { var points: [SIMD2<Float>]; var signedArea, area, perimeter: Float; var centroid: SIMD2<Float>; var isClockwise: Bool; func contains(point:) -> Bool; var boundingBox; func simplified(tolerance:); static func convexHull(_:); func offset(by:miterLimit:) }`. There is no triangulation in Geometry.
- `struct Segment2D { var a, b; var length; var direction; func closestPoint(to:); func distance(to:); func intersection(with:) -> SIMD2<Float>?; func angle(between:) }`.
- `struct Plane { var normal: SIMD3<Float>; var d: Float; init(normal:d:); init(point:normal:); init?(_:_:_:); func signedDistance(to:); func project(_:); func intersection(with: Ray) -> SIMD3<Float>?; static func intersection(_:_:_:); static func fit(_:) -> (plane: Plane, rms: Float)? }`.
- `struct Ray { var origin, direction; init(origin:direction:); func point(at:) }`, `final class MeshBVH { init(mesh: TriangleMesh); func raycast(_ ray: Ray, maxDistance: Float) -> (distance: Float, triangle: Int, point: SIMD3<Float>, normal: SIMD3<Float>)?; func nearestPoint(to: SIMD3<Float>, maxDistance: Float) -> (point:, triangle:, distance:)? }`.
- `enum Snap { static func toCorner(_:corners:radius:) -> SnapResult; static func toEdge(_:edges:radius:); static func toPlane(_:planes:radius:); static func best(_:corners:edges:planes:cornerRadius:edgeRadius:planeRadius:) -> SnapResult }`, `enum SnapTarget { case corner(Int), edge(Int), plane(Int), none }`, `struct SnapResult { var point; var target; var distance }`.

### 3.5 Export (merged, build 3)

Texture coordinates in `ExportMesh` are bottom-left origin (OBJ and USD); `GLBWriter` flips V itself. Nothing else flips.
- `struct ExportMaterial { init(name: String, baseColor: SIMD4<Float> = [1,1,1,1], textureJPEG: Data? = nil, textureName: String = "") }`.
- `struct ExportMesh { init(name: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>]? = nil, texcoords: [SIMD2<Float>]? = nil, colors: [SIMD4<UInt8>]? = nil, indices: [UInt32], materialIndex: Int? = nil); func validate() throws }`.
- `struct ExportScene { init(meshes: [ExportMesh], materials: [ExportMaterial] = [], metadata: [String: String] = [:]) }`.
- Writers: `OBJWriter.write(_ scene: ExportScene, to folder: URL, baseName: String = "model") throws -> [URL]`, `OBJWriter.zipBundle(for:baseName:) throws -> Data`; `PLYWriter.data(for: ExportScene, encoding: .binaryLittleEndian) throws -> Data`; `STLWriter.binary(for: ExportScene, options: .printing) throws -> Data` (Z up, millimeters); `GLBWriter.data(for: ExportScene, generator: String = "Mapper") throws -> Data`; `USDZWriter.data(for: ExportScene, layerName: String = "model.usda", modified: Date = Date()) throws -> Data` (in memory: keep scenes under about 600k triangles); `ZipWriter.archive(_ entries: [(name: String, data: Data)], alignment: Int = 1, modified: Date = Date()) throws -> Data` (in memory, small files only); `CRC32.checksum(_ data: Data, previous: UInt32 = 0) -> UInt32`.
- `struct Plan2D { struct Layer { init(name: String, color: SIMD3<Float>) }; enum Geometry { case line(from:to:), polyline(points:closed:), arc(center:radius:startAngle:endAngle:), circle(center:radius:), text(position:height:string:rotation:), dimension(from:to:offset:label:) } (SIMD2<Double> meters, +Y up); struct Entity { init(layer: String, geometry: Geometry) }; init(name: String, layers: [Layer], entities: [Entity], dimensionTextHeight: Double = 0.12); func dimensionLayout(from:to:offset:) -> DimensionLayout?; func bounds() -> (min: SIMD2<Double>, max: SIMD2<Double>)? }`. Labels arrive already formatted.
- `DXFWriter.data(for: Plan2D) throws -> Data` (R12, millimeters, units TEXT note; no `$INSUNITS`, D23); `SVGWriter.data(for: Plan2D, options: SVGWriter.Options = .init()) throws -> Data`; `PDFPlanWriter.data(for: Plan2D, options: PDFPlanWriter.Options = .init()) throws -> Data` with `Options(paper: .usLetter or .a4, date:, northAngle:, lineWidth:, scaleCaption:)`; scale chosen automatically from `quarterInch`, `eighthInch`, `oneToFifty`, `oneToHundred`.
- `enum ExportError: Error, LocalizedError` (validation and write failures).

### 3.6 Core (merged, build 4 wave 0)

Imports Foundation and simd only (RoomPlan in `ObjectCategory+RoomPlan.swift`). Everything Codable is also Sendable and Equatable unless noted.
- Identity: `struct ElementID: Codable, Hashable { var uuid: UUID; var roomPlanID: UUID?; init(uuid: UUID = UUID(), roomPlanID: UUID? = nil); static func derived(fromRoomPlan id: UUID) -> ElementID }` (equality by `uuid`); `enum FrameLink { case projectFrame(sessionID: UUID), relocalized(sessionID: UUID, from: UUID), manual, unaligned; var sessionID: UUID?; var mayShareFrame: Bool }`.
- Codable math: `Vec2 { x, y; init(_ v: SIMD2<Float>); var simd }`, `Vec3 { x, y, z; init(_ v: SIMD3<Float>); var simd }`, `Transform4 { init(_ t: simd_float4x4); init?(elements: [Float]); var simd: simd_float4x4; var translation: SIMD3<Float>; static let identity }`, `OrientedBoxRecord { init(_ box: OrientedBox); var orientedBox }`, `Intrinsics { fx, fy, cx, cy: Float; width, height: Int; init(fx:fy:cx:cy:width:height:); init(matrix: simd_float3x3, width: Int, height: Int); var matrix; func scaled(toWidth:height:); func project(cameraPoint:) -> SIMD2<Float>?; func project(worldPoint:cameraToWorld:) -> SIMD2<Float>?; func unproject(pixel:depth:) -> SIMD3<Float>; func contains(pixel:) -> Bool }` (camera looks down -Z, v grows downward).
- Errors: `enum MapperError: Error { case lowStorage(freeBytes: Int64), unsupportedDevice, cameraDenied, trackingFailed, deviceTooHot, sceneTooLarge, roomPlanFailed(String), objectCaptureFailed(String), processingFailed(step: PipelineStepID, reason: String), outOfMemory(step: PipelineStepID), corruptProject(String), ioFailed(String), cancelled; var copyKey: String }`; `enum CoreError: Error { case corruptFile(String), missingFile(String), unsupportedSchema(Int) }`.
- Project: `struct ProjectManifest { static let currentSchema = 1, currentPipelineVersion = 1; var schemaVersion, id, name, kind: ScanMode, createdAt, modifiedAt, isArchived, pipelineVersion, sessions: [CaptureSessionRef], rooms: [RoomRecord], objects: [ObjectRecord], floors: [FloorRecord], status: ProjectStatus, reconstructionPending: Bool, settings: ScanSettings; static func new(kind:name:now:) -> ProjectManifest }`; `enum ScanMode { room, house, object, quickMeasure, advancedSpace, advancedObject }`; `enum ProjectStatus { capturing, needsProcessing, processing, ready, needsAttention }`; `struct CaptureSessionRef { id, startedAt, frameLink, worldMapFile: String? }`; `struct RoomRecord { id, name, sessionID, floorIndex, status: RoomStatus, capturedRoomID: UUID?, quality: QualitySummary?, hasMeshPass, keyframeCount, capturedAt, frameLink }`; `enum RoomStatus { capturing, captured, needsRescan, processed, failed }`; `struct ObjectRecord { id, name, size: ObjectSize, status, imageCount, modelFile: String? }`; `enum ObjectSize { smallMedium, large }`; `struct FloorRecord { id: Int, name, elevation }`; `struct QualitySummary { shape, walls, floor, ceiling, texture: Double (0...1); missingAreas: Int; verdict: QualityVerdict; init(shape:walls:floor:ceiling:texture:missingAreas:) }`; `enum QualityVerdict { good, okay, poor; static func from(...) }`; `struct ScanSettings { detail: DetailLevel, keepAllPhotos, findRooms, findFurniture, distance: ScanDistance; static let room; static func defaults(for: ScanMode); var keyframeGate: (meters: Float, degrees: Float); var depthWindow: ClosedRange<Float> }`.
- Package: `struct ProjectPackage { static let fileExtension = "mapperproj"; let root; init(root:); manifestURL, thumbnailURL, rawURL, sessionURL(_:), sessionRecordURL(_:), worldMapURL(session:), rawRoomURL(session:room:), rawMeshPassURL(session:pass:), rawObjectURL(_:), quickMeasureURL, derivedURL, derivedIndexURL, derivedRoomURL(_:), derivedObjectURL(_:), cleanModelURL, planModelURL, structureURL, capturedStructureURL, alignmentURL, editsURL, editLogURL, measurementsURL, exportsURL, sealURL(in:) }`; `struct RawScanFolder { let url; init(url:); sealURL, capturedRoomDataURL, capturedRoomURL, roomLogURL, poseTrackURL, keyframesLogURL, eventsLogURL, photosLogURL, meshURL; func meshChunkURL(anchor:) -> URL; static func keyframeImagePath(_ index: Int) -> String; static func depthPath(_:) -> String; static func photoPath(_ id: UUID) -> String; func resolve(_ relativePath: String) -> URL }`.
- `enum ProjectStore` (thread-safe, all static): thresholds `refuseScanBelowBytes` (1.5 GB), `warnScanBelowBytes` (3 GB), `stopKeyframesBelowBytes` (1 GB), `pauseCaptureBelowBytes` (300 MB), `objectCapturePreflightBytes` (3 GB); `encoder`, `decoder`; `projectsRoot() throws -> URL`; `inProgressRoot() throws -> URL`; `ensureDirectory(_:)`; `package(for id: UUID) throws -> ProjectPackage`; `create(kind:name:now:) throws -> (ProjectPackage, ProjectManifest)`; `readManifest(_:)`, `writeManifest(_:to:)`, `listProjects() -> [ProjectManifest]`; `writeJSON(_:to:)`, `readJSON(_:from:)`, `writeData(_:to:)` (atomic); `freeBytes() -> Int64`; `excludeFromBackup(_:)`; `sealRawFolder(_:now:) -> SealFile`; `verifyRawFolder(_:) -> [String]`.
- Raw records: `KeyframeRecord { index, timestamp, transform: Transform4, intrinsics, imageFile, depthFile: String?, exposureDuration: Double, exposureOffset: Float, ambientIntensity: Float, angularSpeed: Float, trackingNormal: Bool }`; `PhotoPin { id, timestamp, transform, intrinsics, imageFile, note }`; `CaptureEvent { t: Double, kind: CaptureEventKind, detail }`; `enum CaptureEventKind { tracking, thermal, instruction, error, config, memory, degraded, relocalization, note }`; `CaptureSessionRecord { id, osVersion, deviceClass, configLog: [String] }`; `RoomCaptureLog { seconds, instructionSeconds: [String: Double], error: String?, relocalizations, limitedTrackingFraction, degraded: DegradedMode }`; `enum DegradedMode { allGood, depthStripped, meshStripped, roomPlanFailed }`; `SealFile { static let fileName = "SEAL.json"; sealedAt; files: [SealEntry]; static func make(folder:now:); func verify(folder:) -> [String] }`; `struct PoseSample { timestamp: Double; transform: simd_float4x4; tracking: UInt8 (0 n/a, 1 limited, 2 normal); thermal: UInt8; exposureDuration: Float }` (not Codable).
- Binary: `struct MeshChunk { anchorID: UUID; transform: simd_float4x4; updateCount: UInt32; positions, normals: [SIMD3<Float>]; indices: [UInt32]; classes: [UInt8]; init(anchorID:transform:updateCount:positions:normals:indices:classes:); var faceCount; var worldPositions; func toTriangleMesh(world: Bool) -> TriangleMesh }` (anchor-local; no explicit `Sendable`, which Swift 5 mode does not require for the queue hops in this file); `enum MeshChunkFile { static func encode(_:) -> Data; static func decode(_:) throws -> MeshChunk }`; `struct DepthMap { width, height, depth: [Float], confidence: [UInt8]; func depthAt(x:y:) -> Float? }`; `enum DepthFile { static func encode(width:height:depth:confidence:) -> Data; static func decode(_:) throws -> DepthMap }`; `enum PoseTrackFile { static let recordSize = 78; static func appendHeader(to: inout ByteWriter); static func append(_: PoseSample, to: inout ByteWriter); static func decode(_:) throws -> [PoseSample] }`; `struct CoreByteReader`.
- Live scan: `enum TrackingSummary { normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, limited, notAvailable }`; `enum ThermalLevel { nominal, fair, serious, critical; init(_ state: ProcessInfo.ThermalState) }`; `enum MinimapCell: UInt8`; `struct MinimapSnapshot`; `struct LiveScanSnapshot { timestamp, elapsed, tracking, degraded, guidanceRawValue: String?, wallCount, doorCount, windowCount, openingCount, objectCount, meshFaceCount, keyframeCount, photoCount, coverageFraction: Float, thermal, freeBytes: Int64, availableMemory: UInt64, minimap: MinimapSnapshot?; var guidance: GuidanceKind? }` (all fields have defaults); `enum ScanEngineState { idle, starting, scanning, paused, stopping, finished, failed }`; `enum ScanEngineEvent { case snapshot(LiveScanSnapshot), roomFinished(roomID: UUID), failed(MapperError), stateChanged(ScanEngineState) }`; `protocol ScanEngine: AnyObject { var state: ScanEngineState { get }; var onEvent: ((ScanEngineEvent) -> Void)? { get set }; func start() throws; func pause(); func resume(); func finish(); func cancel() }` (call from main; events on main); `struct SnapshotRecording { snapshots; static func decodeJSONLines(_:) throws; func encodeJSONLines() throws -> Data; static func synthetic(count: Int = 120, interval: Double = 0.25) }`; `final class FakeScanEngine: ScanEngine { init(recording: SnapshotRecording = .synthetic(), interval: TimeInterval = 0.25, loops: Bool = false, roomID: UUID = UUID()) }`.
- Models: `enum Provenance { measured, estimated, inferred, user }`; `CleanModel { rooms: [CleanRoom]; sourceIsStructure; stamp: DerivedStamp?; static let empty }`; `CleanRoom { id: ElementID; recordID: UUID; name; sectionLabel: String?; floorIndex; walls: [CleanWall]; openings: [CleanOpening]; floor: CleanFloor; ceiling: CleanCeiling; objects: [DetectedObject]; metrics: RoomMetrics }`; `CleanWall { id, start: Vec3, end: Vec3, height, normal: Vec3 (into the room), thickness, thicknessSource, arc: WallArc?, confidence: DetectionConfidence, completedEdges: Int, occludedSpans: [ClosedRange<Float>], provenance; var length: Float }`; `WallArc { center: Vec3, radius, startAngle, endAngle }`; `CleanOpening { id, wallID: ElementID?, kind: OpeningKind, offsetAlongWall, width, sillHeight, headHeight, swing: DoorSwing?, provenance }`; `enum OpeningKind { door, openDoor, window, opening }`; `DoorSwing { hingeAtStart, opensToNormalSide, source }`; `CleanFloor { outline: [Vec2] (CCW plan), elevation, occludedArea, provenance }`; `CleanCeiling { height, provenance }`; `enum DetectionConfidence { low, medium, high }`; `DetectedObject { id, category: ObjectCategory, label, transform: Transform4, dimensions: Vec3, confidence, isHidden, provenance; var isMovable: Bool; var orientedBox: OrientedBox }`; `enum ObjectCategory` (16 RoomPlan categories plus desk, cabinet, shelf, lamp, plant, appliance, vehicle, other; `isMovable`, `copyKey`; `init(_ category: CapturedRoom.Object.Category)`); `RoomMetrics { floorArea, perimeter, ceilingHeight, ceilingProvenance, wallArea, length, width, volume, volumeProvenance; static let zero }`; `enum PlanAxes { static func toPlan(_ p: SIMD3<Float>) -> SIMD2<Float> (x, -z); static func toWorld(_ p: SIMD2<Float>, y: Float) -> SIMD3<Float>; static func toPlan(_ p: Vec3) -> Vec2 }`; `DetectionConfidence.init(_: CapturedRoom.Confidence)`, `OpeningKind.init?(_: CapturedRoom.Surface.Category)`.
- Plan: `PlanModel { levels: [PlanLevel]; northAngle; stamp; static let empty }`; `PlanLevel { id: Int, name, elevation, rooms: [PlanRoom], walls: [PlanWall], openings: [PlanOpening], fixtures: [PlanFixture], annotations: [PlanAnnotation], dimensions: [PlanDimension] }`; `PlanRoom { id: ElementID, name, outline: [Vec2], labelAt: Vec2, area }`; `PlanWall { id, a: Vec2, b: Vec2, thickness, thicknessSource, arc: WallArc?, provenance, occludedSpans }`; `PlanOpening { id, wallID: ElementID, kind, offset, width, swing }`; `PlanFixture { id, category, center: Vec2, size: Vec2, yaw, isMovable, isHidden }`; `enum AnnotationKind { text, symbol, note }`; `PlanAnnotation { id, kind, at: Vec2, text, symbol: String? }`; `PlanDimension { id, a, b, offset, isUser; var length }`.
- Edits: `enum EditOperation { renameRoom(room:name:), relabelObject(object:label:), recategorizeObject(object:category:), setHidden(element:hidden:), deleteElement(element:), moveObject(object:transform:), moveWallEndpoint(wall:atStart:to: Vec2), addWall(wall: PlanWall, level: Int), addOpening(opening: PlanOpening, level: Int), setDoorSwing(door:swing:), setWallThickness(wall:thickness:), addAnnotation(annotation:level:), addDimension(dimension:level:), setScaleCorrection(room:factor:), setRoomAlignment(RoomAlignmentRecord), cropObject(object:box: OrientedBoxRecord); var targets: [ElementID] }`; `RoomAlignmentRecord { roomID, yaw, translation: Vec3, source }`; `struct EditLog { private(set) operations, cursor, revision; init(); var active; canUndo; canRedo; mutating func append(_:); undo() -> Bool; redo() -> Bool; func applied<T: EditApplicable>(to base: T) -> (T, orphaned: [EditOperation]) }`; `protocol EditApplicable { mutating func apply(_ op: EditOperation) -> Bool }` (false only when a target is missing; operations for other models return true unchanged).
- Pipeline: `enum PipelineStepID { buildRoom, consolidateMesh, cleanModel, floorPlan, quality, mergeStructure, alignRooms, textureLow, textureHigh, reconstructObject, objectMetrics, thumbnail }`; `DerivedStamp { step, subject: UUID?, pipelineVersion, inputHash, createdAt; init(step:subject:pipelineVersion:inputHash:createdAt:) }`; `DerivedIndex { stamps; func stamp(step:subject:); func isFresh(step:subject:version:inputHash:) -> Bool; mutating func record(_:); mutating func invalidate(step:) }`; `enum InputHasher { static func hash(seals: [SealFile], editRevision: Int?, extra: [String] = []) -> String }`; `struct StepContext { package, manifest, availableMemory: UInt64, isCancelled: () -> Bool, progress: (Double) -> Void; func checkCancelled() throws }` (not Sendable); `protocol ProcessingStep: AnyObject { var id: PipelineStepID { get }; var memoryBudgetBytes: UInt64 { get }; var reducedMemoryBudgetBytes: UInt64? { get } (default nil); func inputHash(_ ctx: StepContext) throws -> String; func run(_ ctx: StepContext) async throws }`.
- Measurements: `enum MeasurementKind { distance, wallLength, height, area, perimeter, angle, volume }`; `enum SnapKind { corner, edge, plane, meshVertex, meshSurface, none }`; `enum MeasurementSource { live, viewer, plan, automatic }`; `struct MeasuredValue { static let lowConfidenceLimit = 0.04; var value: Double; var sigma: Double? (1 sigma); var provenance }` (do not use its `isLowConfidence`, CR-2); `struct MeasurementRecord { id, kind, points: [Vec3], snaps: [SnapKind], result: MeasuredValue, source, name, roomID: ElementID?, createdAt }`.
- `enum CoreSelfTest { static func run() -> [String] }`.

### 3.7 Coverage (merged, build 4 wave 0)

Pure Foundation and simd, value types, deterministic; confine each `CoverageGrid` and `GuidanceEngine` value to one queue.
- `enum SurfaceClass: UInt8 { none = 0, wall, floor, ceiling, table, seat, window, door }` (same raw values as `ARMeshClassification`).
- `struct CoverageFace { var centroid: SIMD3<Float>; var normal: SIMD3<Float>; var area: Float; var surface: SurfaceClass }`; `struct CoverageObservation { var cameraToWorld: simd_float4x4; var intrinsics: simd_float3x3; var imageResolution: SIMD2<Float>; var trackingNormal: Bool; var depthConfidenceMean: Float?; var timestamp: Double }`; `enum CoverageState: UInt8 { gray = 0, red, yellow, green }`; `struct CoverageWall { start, end: SIMD2<Float> (world x, z); baseY, height: Float }`; `struct CoverageRoomBoundary { walls: [CoverageWall]; floorPolygon: [SIMD2<Float>] (x, z); floorY: Float; ceilingPolygon: [SIMD2<Float>]; ceilingY: Float }`. Note: Coverage uses world (x, z), not `PlanAxes` (x, -z).
- `struct CoverageGrid { static let defaultVoxelSize: Float = 0.10, maxRange = 5.0, goodQuality = 0.5, maxFacesPerIntegrate = 60_000; init(voxelSize: Float = 0.10); @discardableResult mutating func integrate(observation: CoverageObservation, faces: [CoverageFace]) -> CoverageIntegrateResult; func key(for:) -> SIMD3<Int32>; func voxelStats(_:) -> CoverageStats?; func faceStats(_:) -> CoverageStats?; func state(ofFace:) -> CoverageState; func state(atVoxel:) -> CoverageState; func isObserved(near:radius:) -> Bool; mutating func markExpected(_:); mutating func clearExpected(); func goodFaceAreaFraction(faces:) -> Float; func observedAreaFraction(faces:surface:) -> Float; func stateCounts() -> [CoverageState: Int]; mutating func reset() }`; `struct CoverageStats { observationCount, goodObservationCount: UInt16; bestViewCosine, bestDistance, bestQuality: Float }`. Faces are kept by index across calls, so pass faces in a stable order within one evaluation.
- `struct MissingArea { centroid, normal: SIMD3<Float>; area: Float; surface: SurfaceClass; suggestedViewpoint: SIMD3<Float> }` (not Codable); `struct ExpectedSample { position, normal, surface, element: Int (wall index, -1 floor, -2 ceiling), cell: SIMD2<Int32>, area }`; `struct ExpectedSurfacesResult { samples, observed: [Bool], missing: [MissingArea], expectedArea, observedArea: [SurfaceClass: Float] }`; `enum ExpectedSurfaces { static let sampleSpacing: Float = 0.20; static func samples(for:spacing:) -> [ExpectedSample]; static func evaluate(room: CoverageRoomBoundary, grid: CoverageGrid, spacing: Float = 0.20) -> ExpectedSurfacesResult; static func suggestedViewpoint(centroid:normal:room:) -> SIMD3<Float>; static func pointInPolygon(_:_:) -> Bool }`.
- `struct ScanQualityReport { geometry, walls, floor, ceiling, textures: Float (0...100); missingAreas: [MissingArea]; var missingAreaCount; func meetsAll(threshold:) -> Bool; static let empty }`; `enum ScanQuality { static func evaluate(grid: CoverageGrid, faces: [CoverageFace], room: CoverageRoomBoundary?) -> ScanQualityReport; static func report(from: ExpectedSurfacesResult, textures: Float) -> ScanQualityReport }`.
- `enum GuidanceTracking: UInt8 { normal, excessiveMotion, insufficientFeatures, initializing, relocalizing }`; `struct GuidanceInput { var time: Double; tracking = .normal; angularSpeed: Float = 0; linearSpeed: Float = 0; centerDistance: Float?; depthConfidenceMean: Float?; ambientIntensity: Float?; viewCoverage: Float?; nearbyMissing: [MissingArea] = []; newDoors, newWindows, newWalls: Int = 0; deviceHot = false; overallComplete = false; init(time: Double) }`; `struct GuidanceOutput: Equatable { var message: GuidanceKind?; var fireHaptic: Bool }`; `struct GuidanceEngine { init(); mutating func update(_ input: GuidanceInput) -> GuidanceOutput; mutating func reset(); func conditions(for:) -> Set<GuidanceKind> }` (implements every `GuidancePolicy` rule).
- `enum MeasurementSnapKind: UInt8 { none, vertex, edge, plane, roomSurface }`; `struct MeasurementEvidence { distance: Float; depthConfidence: Float?; observations: Int; trackingNormalFraction: Float; snap: MeasurementSnapKind }`; `struct MeasurementConfidence { var accuracy: Float (about 1 sigma, meters); var isLowConfidence: Bool; static func pointAccuracy(_:) -> Float; static func estimate(start:end:length:) -> MeasurementConfidence; static func estimate(point:) -> MeasurementConfidence }` (RoomPlan-snapped lengths floor at 0.0125 m).

### 3.8 MeshProcessing (merged, build 4 wave 0)

Pure functions, never mutate inputs, Foundation and simd.
- `struct MergeChunk { var localMesh: TriangleMesh; var anchorTransform: simd_float4x4; var faceClass: [UInt8]?; var vertexColor: [SIMD4<UInt8>]?; init(localMesh:anchorTransform:faceClass:vertexColor:) }` (CR-3 rename).
- `struct MeshWithAttributes: Equatable { var mesh: TriangleMesh; var faceClass: [UInt8]?; var vertexColor: [SIMD4<UInt8>]?; var isInferred: [Bool]?; static let unclassified: UInt8 = 0; init(mesh:faceClass:vertexColor:isInferred:); var triangleCount: Int; var isConsistent: Bool; var inferredCount: Int; func keepingFaces(_ keep: [Bool]) -> MeshWithAttributes; func appending(_ other: MeshWithAttributes) -> MeshWithAttributes }`.
- `enum ChunkMerge { static let defaultWeldTolerance: Float = 0.005; static func merge(_ chunks: [MergeChunk], weldTolerance: Float = 0.005) -> MeshWithAttributes; static func removingDegenerateAndDuplicateFaces(_:minimumArea:) -> MeshWithAttributes }`.
- `enum MeshCleanup { static let defaultMinimumArea: Float = 0.02; static let defaultMinimumTriangles = 20; struct Components: Equatable { var faceComponent: [Int32]; var count: Int; var triangleCounts: [Int]; var areas: [Float]; var largest: Int? }; static func connectedComponents(_ mesh: TriangleMesh) -> Components; static func removingFloaters(_ input: MeshWithAttributes, minimumArea: Float = 0.02, minimumTriangles: Int = 20) -> MeshWithAttributes (the largest component is always kept); static func largestComponent(_:) -> MeshWithAttributes; static func removingNonManifoldEdges(_:) -> MeshWithAttributes; static func fixingWinding(_:) -> MeshWithAttributes; static func normals(_ mesh: TriangleMesh) -> [SIMD3<Float>]; static func faceNormals(_ mesh: TriangleMesh) -> [SIMD3<Float>]; static func cleaned(_ input: MeshWithAttributes, minimumArea: Float = 0.02, minimumTriangles: Int = 20) -> MeshWithAttributes }`.
- `enum HoleFill { static let defaultMaxPerimeter: Float = 0.5; struct BoundaryLoop: Equatable { var vertices: [UInt32]; var perimeter: Float }; struct FillResult { var mesh: MeshWithAttributes (new faces appended, isInferred true); var filledLoops: Int; var skippedLoops: Int; var addedTriangles: Int }; static func boundaryLoops(_ mesh: TriangleMesh) -> [BoundaryLoop]; static func fillSmallHoles(_ input: MeshWithAttributes, maxPerimeter: Float = 0.5) -> FillResult }`.
- `enum MeshSimplify { struct Options { init(targetTriangleCount: Int? = nil, maxError: Float? = nil, boundaryWeight: Float = 1000, preserveClassBoundaries: Bool = true, classBoundaryWeight: Float = 100, minimumNormalDot: Float = 0.2) }; struct SimplifyResult { var mesh: MeshWithAttributes; var collapses: Int; var maxError: Float }; static func simplify(_ input: MeshWithAttributes, options: Options) -> SimplifyResult }` (faceClass and isInferred follow their faces).
- `enum MeshSmooth { static func taubin(_:iterations:lambda:mu:) -> MeshWithAttributes }`.
- `enum CropRegion { case orientedBox(OrientedBox), box(AABB3), halfSpace(Plane) }`; `enum MeshCrop { enum Mode { keepInside, removeInside }; enum FaceTest { centroid, allCorners, anyCorner }; static func contains(_:_:) -> Bool; static func insideMask(_:region:test:) -> [Bool]; static func crop(_ input: MeshWithAttributes, region: CropRegion, mode: Mode, test: FaceTest = .centroid) -> MeshWithAttributes }`.
- `enum ObjectIsolation { struct PlaneOptions { init(inlierDistance: Float = 0.01, maxTiltDegrees: Float = 10, normalToleranceDegrees: Float = 25, ...) }; struct Options { init(plane: PlaneOptions = PlaneOptions(), faceTest: MeshCrop.FaceTest = .centroid, ...) }; enum VolumeUnavailableReason: Equatable { case notWatertight, degenerate }; struct IsolatedObject { var mesh: MeshWithAttributes; var box: OrientedBox (axis 0 width, axis 1 world up, axis 2 depth); var width, height, depth: Float; var heightAboveSupport: Float?; var surfaceArea: Float; var volume: Float?; var volumeUnavailableReason: VolumeUnavailableReason?; var supportPlane: Plane? }; static func isolate(_ input: MeshWithAttributes, selection: CropRegion, options: Options = Options()) -> IsolatedObject?; static func isolate(_ input: MeshWithAttributes, box: OrientedBox, options: Options = Options()) -> IsolatedObject?; static func isolate(_ input: MeshWithAttributes, box: AABB3, options: Options = Options()) -> IsolatedObject?; static func measure(_ object: MeshWithAttributes, support: Plane?) -> IsolatedObject?; static func gravityAlignedBox(_ points: [SIMD3<Float>]) -> OrientedBox?; static func findSupportPlane(_ mesh: TriangleMesh, maxHeight: Float? = nil, options: PlaneOptions = PlaneOptions()) -> Plane? }` (read the elided option fields in `ObjectIsolation.swift`).
- Also `enum MeshTopology`, `struct EdgeTable`, `struct UnionFind`, `struct MeshProcessingRandom` (seeded generator), `extension TriangleMesh { func weldMap(tolerance: Float) -> (positions: [SIMD3<Float>], remap: [UInt32]) }`.

### 3.9 Texturing (merged, build 4 wave 0)

CPU only (Foundation, simd, CoreGraphics; no other Mapper module). Texcoords are bottom-left origin, which matches RealityKit, OBJ, USD and `ExportMesh`, so no consumer flips V.
- `struct TXMesh { var positions: [SIMD3<Float>]; var indices: [UInt32]; var faceCount: Int }` (world space).
- `struct TXKeyframe { var image: CGImage; var intrinsics: simd_float3x3; var imageResolution: SIMD2<Float>; var cameraToWorld: simd_float4x4; var timestamp: Double; var exposureOffset: Float? }` (image may be any size with the same aspect as `imageResolution`; keep it lazily decoded).
- `struct TXOptions { var atlasSize = 4096; var texelsPerMeter: Float = 400; var maxAtlases = 8; var minViewCosine: Float = 0.25; var occlusionTolerance: Float = 0.03; var blendSeams = true; var normalizeExposure = true; init() }`.
- `struct TXResult { var texcoords: [SIMD2<Float>] (3 per face, face f owns 3f...3f+2); var faceAtlas: [UInt16]; var atlases: [CGImage]; var faceSource: [Int32] (-1 untextured); var coverage: Float }`; `enum TXError: Error { invalidMesh(String), noKeyframes, cancelled, imageFailed(String) }`.
- `final class TextureBaker { init(options: TXOptions = TXOptions()); func cancel(); var isCancelled: Bool; func bake(mesh: TXMesh, keyframes: [TXKeyframe], progress: ((Float) -> Void)?) throws -> TXResult }` (call off main; one bake per instance; about 830 MB peak at 1M triangles, 300 keyframes, 8 atlases of 4096).
- `struct KeyframeSelector { struct Config { maxTranslation: Float = 0.15; maxRotationDegrees: Float = 12; maxAngularVelocity: Float = 1.0; minExposureOffset: Float = -2; maxExposureOffset: Float = 2; maxKeyframes = 300; minInterval: Double = 0.1; init() }; enum Decision { accept, rejectTooClose, rejectBlur, rejectExposure, rejectTooSoon }; init(config: Config = Config()); mutating func consider(cameraToWorld: simd_float4x4, timestamp: Double, exposureOffset: Float?) -> Decision; mutating func reset(); var count: Int }`.
- `enum TXExposure` (gain solve), `struct TXCamera`, `struct TXRGBImage`, `struct TXLumaImage`, and the other `TX` types are internal building blocks.

---

## Build 4, wave 4a

### 3.10 Store

**Purpose.** Everything that reads or writes a project package beyond Core's `ProjectStore` helpers: the observable project library, serialized manifest updates from any thread, the crash-safe in-progress raw writer (D5), sealing and moving scans into packages, reading raw scans back, the edit log and measurement files (D3), and storage accounting.

**Build and wave.** Build 4, wave 4a. Depends on Core and Support only.

**Files.** `ios/Sources/Store/StoreProjectLibrary.swift`, `StoreManifestWriter.swift`, `StoreRawScanWriter.swift`, `StoreInProgress.swift`, `StoreRawScanReader.swift`, `StorePackageCheck.swift`, `StoreEdits.swift`, `StoreUsage.swift`, `StoreSelfTest.swift`.

**Public Swift API.**
```swift
extension Notification.Name {
    /// Posted on the main queue after a manifest was written; `object` is the project UUID.
    static let mapperManifestDidChange: Notification.Name   // "mapper.manifestDidChange"
    /// Posted on the main queue after edits/editlog.json or edits/measurements.json changed; `object` is the project UUID.
    static let mapperEditsDidChange: Notification.Name      // "mapper.editsDidChange"
}

/// Serialized read-modify-write of project.json from any thread (one process-wide NSLock).
enum ManifestWriter {
    /// Reads the manifest (Core `ProjectStore.readManifest`).
    static func read(_ package: ProjectPackage) throws -> ProjectManifest
    /// Applies `mutate` under the lock, sets `modifiedAt = now`, writes atomically, posts
    /// `.mapperManifestDidChange` on main, returns the written manifest.
    @discardableResult
    static func update(_ package: ProjectPackage, now: Date = Date(),
                       _ mutate: (inout ProjectManifest) throws -> Void) throws -> ProjectManifest
}

/// The project list shown on Home. Main actor.
@MainActor final class ProjectLibrary: ObservableObject {
    static let shared: ProjectLibrary
    /// All readable projects, newest `modifiedAt` first, archived ones included.
    @Published private(set) var projects: [ProjectManifest]
    init()
    /// Lists `Documents/Projects` on a background queue and publishes on main. Also called on
    /// every `.mapperManifestDidChange`.
    func reload()
    /// Creates the package with `ProjectStore.create(kind:name:now:)` and inserts it.
    func create(kind: ScanMode, name: String) throws -> (ProjectPackage, ProjectManifest)
    /// `ManifestWriter.update` plus an immediate local refresh of that entry.
    @discardableResult
    func update(_ id: UUID, _ mutate: (inout ProjectManifest) throws -> Void) throws -> ProjectManifest
    /// Removes the whole package folder (raw included) after the caller confirmed.
    func delete(_ id: UUID) throws
    /// Renames (used by ProjectOps in build 6).
    func rename(_ id: UUID, to name: String) throws
    func manifest(for id: UUID) -> ProjectManifest?
    func package(for id: UUID) throws -> ProjectPackage
}

/// Kind of a raw scan folder.
enum RawScanKind: String, Codable, CaseIterable, Sendable { case room, meshPass, object }

/// `scan.json` inside every raw scan folder, written at creation and sealed with the folder.
struct InProgressScanInfo: Codable, Equatable, Sendable {
    static let fileName = "scan.json"
    var scanID: UUID
    var projectID: UUID
    var sessionID: UUID?
    var roomID: UUID?
    var kind: RawScanKind
    var mode: ScanMode
    var startedAt: Date
    init(scanID: UUID, projectID: UUID, sessionID: UUID?, roomID: UUID?, kind: RawScanKind, mode: ScanMode, startedAt: Date)
}

/// In-progress scans under Library/Application Support/InProgress/<scanID>/ (D5). Thread-safe.
/// Every function below also takes a trailing `root: URL? = nil` (nil means
/// `ProjectStore.inProgressRoot()`), so the self-test works in a temporary folder.
enum InProgressScans {
    /// Creates the folder with subfolders mesh/, keyframes/, depth/, photos/ and writes scan.json.
    static func create(_ info: InProgressScanInfo) throws -> RawScanFolder
    static func folder(for scanID: UUID) throws -> RawScanFolder
    /// Every InProgress folder with a readable scan.json, sealed or not. At launch AppShell's
    /// RecoveryService finishes sealed ones silently (a crash hit between seal and move) and
    /// offers "Recover unfinished scan" for unsealed ones (D5).
    static func list() -> [InProgressScanInfo]
    /// True when the folder already holds SEAL.json.
    static func isSealed(scanID: UUID) -> Bool
    /// Writes SEAL.json (`ProjectStore.sealRawFolder`) unless one exists already (then only the
    /// move is repeated), moves the folder to `destination` (creating parents; fails if it
    /// exists), re-applies `excludeFromBackup` on the package raw/.
    @discardableResult
    static func seal(_ folder: RawScanFolder, into destination: URL, package: ProjectPackage) throws -> SealFile
    static func discard(scanID: UUID) throws
}

/// Integrity check run when a project opens (Results) and after a restore (build 6). Any thread.
enum PackageCheck {
    /// `ProjectStore.verifyRawFolder` on every sealed room, mesh-pass and object folder of the
    /// manifest, plus the record path rule below; returns problem lines (also logged, category
    /// "store"). The caller marks the project `.needsAttention` through `ManifestWriter` when
    /// the list is not empty.
    static func verify(_ package: ProjectPackage, manifest: ProjectManifest) -> [String]
    /// A path stored in a record (`KeyframeRecord.imageFile`, `depthFile`, `PhotoPin.imageFile`)
    /// is safe when it is relative, non-empty and has no `..` component (records read from disk
    /// are untrusted; Core change request CR-4 moves this into `RawScanFolder.resolve`).
    static func isSafeRecordPath(_ path: String) -> Bool
}

/// Serial IO for one raw scan folder. Every method returns at once; work runs in order on
/// `ioQueue`. Only this type writes raw files, and only before sealing (D5).
final class RawScanWriter {
    /// Shared serial queue "mapper.io" (QoS utility).
    static let ioQueue: DispatchQueue
    let folder: RawScanFolder
    init(folder: RawScanFolder)
    /// Encodes with `ProjectStore.encoder`, appends one line plus "\n" (FileHandle, seekToEnd).
    func appendJSONLine<T: Encodable>(_ value: T, to url: URL)
    /// Appends raw bytes (pose track).
    func appendBytes(_ data: Data, to url: URL)
    /// Writes a whole file atomically (temporary file, then rename).
    func writeFile(_ data: Data, to url: URL)
    /// Runs arbitrary work on the io queue (JPEG encode then write); errors are counted and logged.
    func perform(_ work: @escaping () throws -> Void)
    /// Calls `completion` on the io queue after all work queued before it.
    func flush(completion: @escaping () -> Void)
    /// Failed writes so far (thread-safe).
    var failureCount: Int { get }
    /// Bytes written so far (thread-safe).
    var bytesWritten: Int64 { get }
}

/// Read-only access to a sealed or in-progress raw scan folder. Safe on any thread.
struct RawScanReader {
    let folder: RawScanFolder
    init(folder: RawScanFolder)
    func info() -> InProgressScanInfo?
    /// JSON Lines readers ignore a trailing partial line (crash while appending). Records whose
    /// file paths fail `PackageCheck.isSafeRecordPath` are dropped and logged.
    func keyframes() throws -> [KeyframeRecord]
    func photos() throws -> [PhotoPin]
    func events() throws -> [CaptureEvent]
    func poseSamples() throws -> [PoseSample]
    func roomLog() -> RoomCaptureLog?
    func meshChunkURLs() -> [URL]
    /// Decodes every mesh/*.mchk; corrupt files are skipped and logged when `skipCorrupt`.
    func meshChunks(skipCorrupt: Bool = true) -> [MeshChunk]
    var hasCapturedRoom: Bool { get }
    var hasCapturedRoomData: Bool { get }
    static func jsonLines<T: Decodable>(_ type: T.Type, at url: URL) throws -> [T]
}

/// edits/editlog.json and edits/measurements.json with a process-wide lock. Posts
/// `.mapperEditsDidChange` on main after every write.
enum EditStore {
    static func load(_ package: ProjectPackage) -> EditLog            // empty when absent or unreadable (logged)
    @discardableResult static func append(_ op: EditOperation, to package: ProjectPackage) throws -> EditLog
    @discardableResult static func undo(_ package: ProjectPackage) throws -> EditLog
    @discardableResult static func redo(_ package: ProjectPackage) throws -> EditLog
    static func loadMeasurements(_ package: ProjectPackage) -> [MeasurementRecord]
    static func saveMeasurements(_ records: [MeasurementRecord], to package: ProjectPackage) throws
}

/// Bytes used per package part.
struct PackageUsage: Equatable, Sendable { var raw: Int64; var derived: Int64; var edits: Int64; var exports: Int64; var total: Int64 }
enum StorageUsage {
    static func usage(of package: ProjectPackage) -> PackageUsage    // walks the folder, any thread
    static func projectsTotal() -> Int64
    static func inProgressTotal() -> Int64
}
```

**Uses.** Core: `ProjectStore` (every helper), `ProjectPackage`, `RawScanFolder`, `ProjectManifest`, `ScanMode`, `SealFile`, `KeyframeRecord`, `PhotoPin`, `CaptureEvent`, `RoomCaptureLog`, `PoseSample`, `PoseTrackFile.decode`, `MeshChunk`, `MeshChunkFile.decode`, `EditLog`, `EditOperation`, `MeasurementRecord`, `CoreError`. Support: `LogStore.shared.write(_:category:)` with category "store".

**Apple APIs.** Foundation only (not in RESEARCH except the backup and free-space keys; all long-standing): `FileManager` (`createDirectory`, `moveItem(at:to:)`, `removeItem(at:)`, `subpathsOfDirectory(atPath:)`, `attributesOfItem(atPath:)`), `FileHandle(forWritingTo:)`, `seekToEnd()`, `write(contentsOf:)`, `close()`, `Data.write(to:options: [.atomic])`, `NSLock`, `NotificationCenter.default.post(name:object:)`, `URLResourceValues.isExcludedFromBackup` (through `ProjectStore.excludeFromBackup`; RESEARCH 3.9: re-apply after every write batch).

**Must NOT do.** Never write inside a sealed folder or modify raw after sealing. Never use POSIX permissions to lock raw (judgements, D5). Never delete raw data except through `delete(_:)` of a whole project (Free up space is build 6 ProjectOps). Never block the main thread with folder walks (`reload` and `usage` run off main). Never hold `ProjectManifest` writes outside `ManifestWriter`. No UI, no Copy strings.

**Copy strings.** None.

**Self-test.** `StoreSelfTest.run()`, at least 25 checks, all in a temporary folder: InProgressScans create makes the four subfolders and scan.json; `RawScanWriter.appendJSONLine` then `flush` then `RawScanReader.keyframes()` round trip of 3 records; a trailing partial line is ignored; `appendBytes` of a pose track header plus 2 records decodes to 2 samples; `writeFile` is atomic (target never half-written, content equal); `seal` writes SEAL.json listing every file with sizes and moves the folder; sealing into an existing destination throws; a folder that already has SEAL.json is moved with its original seal (`isSealed` true before, seal date unchanged after); `ProjectStore.verifyRawFolder` on the moved folder is empty; `PackageCheck.verify` reports a deleted keyframe JPEG; `isSafeRecordPath` rejects "/etc/x", "../x", "keyframes/../../x" and "" and accepts "keyframes/00001.jpg"; a keyframes.jsonl line with an unsafe path is dropped by `RawScanReader.keyframes()`; `discard` removes the folder; `list` returns sealed and unsealed folders and skips unreadable ones; `ManifestWriter.update` from 4 concurrent queues applying 25 increments each to `rooms` count ends with 100 rooms; `update` bumps `modifiedAt`; `EditStore.append` twice, `undo`, `redo` produce the expected cursor and revision; `loadMeasurements` of a missing file is empty; measurements round trip; `StorageUsage.usage` sums raw and derived correctly for known file sizes.

**Acceptance checks.** Every write path goes through `RawScanWriter`, `ManifestWriter`, `EditStore` or `ProjectStore.writeData`; `ProjectLibrary` is `@MainActor` and never touches disk synchronously on main except `create` and `update` (small JSON); notifications are posted on main; `RawScanWriter` never throws to its caller (it counts and logs failures); all folder walks tolerate missing folders.

**SPEC owned.** "PROJECT SYSTEM" (stored locally, each project contains its original scan data and derived models, delete); "CORE DESIGN PRINCIPLE" ("Never destroy the original raw scan when the user edits the project"); "FLOOR PLAN EDITING" ("Manual edits must not overwrite raw scan data") at the storage level.

### 3.11 CaptureCore

**Purpose.** The one app-owned `ARSession` per capture session and everything around it: configuration (D14), the serial delegate queue and fan-out to recorders (D7, D8), re-applying the configuration when RoomPlan replaces it, watchdogs (depth, mesh, delegate identity, storage D18, memory D17), tracking and thermal monitoring, frame and mesh copying helpers, and first-run diagnostics (D22). It knows nothing about RoomPlan, files or UI.

**Build and wave.** Build 4, wave 4a. Depends on Core, Support; ARKit.

**Files.** `ios/Sources/CaptureCore/CaptureSessionHub.swift`, `CaptureRecorder.swift`, `CaptureConfiguration.swift`, `CaptureTracking.swift`, `CaptureThermal.swift`, `CaptureWatchdogs.swift`, `CaptureDelegateRelay.swift`, `CaptureFrameReading.swift`, `CaptureMeshCopy.swift`, `CaptureDiagnostics.swift`, `CaptureCoreSelfTest.swift`.

**Public Swift API.**
```swift
/// What decides the ARKit configuration of one capture.
struct ScanProfile: Equatable, Sendable {
    var mode: ScanMode
    var settings: ScanSettings
    init(mode: ScanMode, settings: ScanSettings)
    /// Plane detection only for Quick Measure (D14); planes flatten the raw mesh.
    var wantsPlaneDetection: Bool { get }
}

enum ScanConfigurationFactory {
    /// sceneReconstruction .meshWithClassification (else .mesh) when supported; frameSemantics
    /// [.sceneDepth] when supported; planeDetection [] unless `wantsPlaneDetection` then
    /// [.horizontal, .vertical]; environmentTexturing .none; isLightEstimationEnabled true;
    /// default video format (never 4K or HDR).
    static func make(_ profile: ScanProfile) -> ARWorldTrackingConfiguration
    static var supportsMesh: Bool { get }
    static var supportsDepth: Bool { get }
    /// Human-readable lines for CaptureSessionRecord.configLog.
    static func describe(_ configuration: ARConfiguration?) -> [String]
}

/// Live counters a recorder reports for LiveScanSnapshot.
struct RecorderStats: Equatable, Sendable {
    var meshAnchors = 0, meshFaces = 0, keyframes = 0, skippedKeyframes = 0
    var photos = 0, poseSamples = 0, writeFailures = 0
    init()
    /// Field-wise sum.
    static func + (lhs: RecorderStats, rhs: RecorderStats) -> RecorderStats
}

/// A raw-data recorder fed by ARSessionHub. Every method is called on `hub.queue`.
/// Implementations copy what they need inside the call and return quickly (target under 2 ms).
protocol ScanRecorder: AnyObject {
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor])
    /// Stops recording, finishes all pending writes, then calls `completion` (any queue).
    func finishRecording(completion: @escaping () -> Void)
    var stats: RecorderStats { get }
}
extension ScanRecorder {
    // Default empty implementations of the four hub(_:...) callbacks.
}

/// Summary the hub publishes at most 4 times a second on its queue.
struct HubStatus: Equatable, Sendable {
    var tracking: TrackingSummary = .initializing
    var degraded: DegradedMode = .allGood
    var thermal: ThermalLevel = .nominal
    var storage: StorageState = .ok
    var freeBytes: Int64 = 0
    var availableMemory: UInt64 = 0
    var depthPresent = false
    var meshAnchorCount = 0
    var interrupted = false
    var ambientIntensity: Float? = nil
    var angularSpeed: Float = 0          // rad/s
    var linearSpeed: Float = 0           // m/s
    var centerDistance: Float? = nil     // m, median of the 5x5 center depth pixels
    var depthConfidenceMean: Float? = nil // 0...1 (ARConfidenceLevel / 2)
    var elapsed: Double = 0              // seconds since markScanStart
    init()
}

/// Owns one ARSession and its serial delegate queue.
final class ARSessionHub: NSObject, ARSessionDelegate {
    let session: ARSession
    /// Serial queue "mapper.ar.delegate", QoS userInitiated; also the queue of every recorder call.
    let queue: DispatchQueue
    let tracking: TrackingMonitor          // hub queue only
    let thermal: ThermalGovernor            // thread-safe
    let storage: StorageWatchdog            // thread-safe
    let diagnostics: CaptureDiagnostics     // hub queue only
    /// Hub queue. Timeline events for events.jsonl.
    var onCaptureEvent: ((CaptureEvent) -> Void)?
    /// Hub queue, at most 4 Hz.
    var onStatus: ((HubStatus) -> Void)?
    /// Hub queue. Called for every frame after recorders (engines read counters here).
    var onFrame: ((ARFrame) -> Void)?
    /// Main actor (reads `UIDevice.current.model` for diagnostics).
    @MainActor init(profile: ScanProfile)
    /// Call on the main thread (not actor-isolated, so nonisolated engine methods may call it).
    /// Sets `session.delegate = self` and `session.delegateQueue = queue`. Call before any
    /// RoomPlan object is created (RESEARCH 3.2 recommended step 2).
    func install()
    /// Call on the main thread. `session.run(ScanConfigurationFactory.make(profile), options: options)`.
    func run(options: ARSession.RunOptions = [])
    /// Call on the main thread. `session.pause()`.
    func pause()
    /// Any thread. Re-runs the configuration with options [] (never reset options). Logs the
    /// reason and the configuration before and after (D22). Called by the watchdog when depth
    /// or mesh is missing, never unconditionally: on the RoomCaptureView path RoomPlan
    /// preserves the session's settings, so Mapper reconfigures only when the watchdog sees
    /// depth or mesh missing (RESEARCH ruling 1).
    func reapplyConfiguration(reason: String)
    /// Any thread (hops to queue).
    func attach(_ recorder: ScanRecorder)
    func detach(_ recorder: ScanRecorder)
    func updateProfile(_ profile: ScanProfile)
    /// Hub queue. Resets elapsed time and the watchdogs for a new room or pass.
    func markScanStart(timestamp: TimeInterval)
    /// Hub queue.
    private(set) var profile: ScanProfile
    private(set) var degraded: DegradedMode
    private(set) var status: HubStatus
    /// ARSessionDelegate / ARSessionObserver (exact signatures, hub queue):
    func session(_ session: ARSession, didUpdate frame: ARFrame)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor])
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor])
    func session(_ session: ARSession, didRemove anchors: [ARAnchor])
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera)
    func sessionWasInterrupted(_ session: ARSession)
    func sessionInterruptionEnded(_ session: ARSession)
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool   // returns true
    func session(_ session: ARSession, didFailWithError error: any Error)
}

/// Tracking history. Hub queue only.
final class TrackingMonitor {
    private(set) var summary: TrackingSummary
    private(set) var relocalizations: Int
    var limitedFraction: Double { get }     // 0...1 of time not .normal since reset
    func update(_ state: ARCamera.TrackingState, timestamp: TimeInterval)
    func reset()
    static func summary(_ state: ARCamera.TrackingState) -> TrackingSummary
    /// PoseSample code: 0 not available, 1 limited, 2 normal.
    static func poseCode(_ state: ARCamera.TrackingState) -> UInt8
}

/// Thermal ladder (ship-first 3.1, RESEARCH 3.8).
struct ThermalPolicy: Equatable, Sendable {
    var keyframeIntervalScale: Double   // 1 nominal and fair, 2 serious
    var coverageHz: Double              // 3, 3, 1, 0
    var overlayEnabled: Bool            // false from serious
    var mustStop: Bool                  // true at critical
    static func forLevel(_ level: ThermalLevel) -> ThermalPolicy
}
final class ThermalGovernor {           // thread-safe
    init(notificationCenter: NotificationCenter = .default)
    var level: ThermalLevel { get }
    var policy: ThermalPolicy { get }
    /// Called on `queue` after every change.
    func start(on queue: DispatchQueue, onChange: @escaping (ThermalLevel) -> Void)
    func stop()
}

enum StorageState: String, Equatable, Sendable { case ok, stopKeyframes, pause }
/// 10 s free-space watchdog (D18).
final class StorageWatchdog {           // thread-safe
    init(interval: TimeInterval = 10, freeBytes: @escaping () -> Int64 = { ProjectStore.freeBytes() })
    var state: StorageState { get }
    var freeBytes: Int64 { get }
    func start(on queue: DispatchQueue, onChange: @escaping (StorageState) -> Void)
    func stop()
    /// Below `ProjectStore.pauseCaptureBelowBytes` pause, below `stopKeyframesBelowBytes` stop keyframes.
    static func state(forFreeBytes bytes: Int64) -> StorageState
}
enum MemoryProbe {
    /// `os_proc_available_memory()` as UInt64 (import os).
    static func availableBytes() -> UInt64
}

/// Depth and mesh arrival watchdog (ship-first 3.1 step 6), pure logic for testing.
enum WatchdogAction: Equatable, Sendable { case none, reapply(reason: String), degrade(DegradedMode) }
struct CaptureWatchdogLogic: Equatable, Sendable {
    static let depthMissingSeconds: Double = 2
    static let meshMissingSeconds: Double = 8
    init()
    /// Feed once per frame. Re-apply once when depth is missing for 2 s or no mesh anchor
    /// after 8 s of normal tracking; degrade (.depthStripped or .meshStripped) if still
    /// missing 2 s after that re-apply.
    mutating func observe(timestamp: Double, depthPresent: Bool, meshAnchorCount: Int, trackingNormal: Bool) -> WatchdogAction
    mutating func reset()
}

/// Forwards every delegate call to the hub and to the delegate it replaced. Installed only
/// when the once-per-second identity check finds `session.delegate !== hub`.
final class ARDelegateRelay: NSObject, ARSessionDelegate {
    init(hub: ARSessionHub, previous: (any ARSessionDelegate)?)
}

/// Frame readers. Call only inside the ARFrame callback (hub queue).
enum ARFrameReading {
    static func intrinsics(of camera: ARCamera) -> Intrinsics
    /// Copies depthMap (Float32) and confidenceMap (UInt8) into Core's DepthMap, honoring
    /// bytesPerRow; nil when sceneDepth is nil or the pixel format is unexpected (logged once).
    static func depthMap(of frame: ARFrame) -> DepthMap?
    static func centerDepth(of frame: ARFrame) -> (distance: Float, confidence: Float)?
    static func meanConfidence(of frame: ARFrame, stride: Int = 8) -> Float?
    static func ambientIntensity(of frame: ARFrame) -> Float?
    static func angularSpeed(from previous: simd_float4x4, to current: simd_float4x4, seconds: Double) -> Float
    static func linearSpeed(from previous: simd_float4x4, to current: simd_float4x4, seconds: Double) -> Float
}

/// Copies an ARMeshAnchor into Core's anchor-local MeshChunk (D8). Hub queue.
enum MeshAnchorCopier {
    static func copy(_ anchor: ARMeshAnchor, updateCount: UInt32) -> MeshChunk
    /// Unpacks `count` float3 values at `offset` with `stride` bytes (testable without ARKit).
    static func unpackFloat3(_ base: UnsafeRawPointer, count: Int, offset: Int, stride: Int) -> [SIMD3<Float>]
    static func unpackUInt32(_ base: UnsafeRawPointer, count: Int, offset: Int, stride: Int) -> [UInt32]
}

/// First-run and per-second diagnostics (D22), logged with category "capture". Hub queue.
final class CaptureDiagnostics {
    private(set) var configLog: [String]
    @MainActor init()
    func logConfiguration(_ configuration: ARConfiguration?, label: String)
    func logFirstFrame(_ frame: ARFrame)                 // image and depth sizes and pixel formats, fps
    func tick(frame: ARFrame, meshAnchors: Int, delegateIsHub: Bool, availableMemory: UInt64)
    /// Unprojects the center depth pixel and projects it back; error in pixels (target < 0.5).
    func projectionRoundTrip(_ frame: ARFrame) -> Float?
    func sessionRecord(id: UUID) -> CaptureSessionRecord  // osVersion, deviceClass, configLog
}
```

**Uses.** Core: `ScanMode`, `ScanSettings`, `DegradedMode`, `TrackingSummary`, `ThermalLevel` (`init(_ state: ProcessInfo.ThermalState)`), `CaptureEvent`, `CaptureEventKind`, `CaptureSessionRecord`, `Intrinsics(matrix:width:height:)`, `DepthMap`, `MeshChunk`, `RawScanFolder`, `ProjectStore.freeBytes()`, `ProjectStore.stopKeyframesBelowBytes`, `ProjectStore.pauseCaptureBelowBytes`. Support: `LogStore`.

**Apple APIs** (RESEARCH 3.1, 3.8, 3.9):
```swift
class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool  // ARWorldTrackingConfiguration
var sceneReconstruction: ARConfiguration.SceneReconstruction { get set }   // .meshWithClassification, .mesh
class func supportsFrameSemantics(_ frameSemantics: ARConfiguration.FrameSemantics) -> Bool                // call on ARWorldTrackingConfiguration
var frameSemantics: ARConfiguration.FrameSemantics { get set }             // .sceneDepth
var planeDetection: ARWorldTrackingConfiguration.PlaneDetection { get set }
var environmentTexturing: ARWorldTrackingConfiguration.EnvironmentTexturing { get set }
var isLightEstimationEnabled: Bool { get set }
func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])
func pause()
weak var delegate: (any ARSessionDelegate)? { get set }
var delegateQueue: dispatch_queue_t? { get set }
@NSCopying var configuration: ARConfiguration? { get }
var sceneDepth: ARDepthData? { get }                                   // ARFrame
unowned(unsafe) var depthMap: CVPixelBuffer { get }                    // ARDepthData, Float32 meters
unowned(unsafe) var confidenceMap: CVPixelBuffer? { get }              // UInt8, 0 low, 1 medium, 2 high
var transform: simd_float4x4 { get }; var intrinsics: simd_float3x3 { get }; var imageResolution: CGSize { get }  // ARCamera
var trackingState: ARCamera.TrackingState { get }                      // .notAvailable, .limited(Reason), .normal
var exposureDuration: TimeInterval { get }                             // ARCamera
var lightEstimate: ARLightEstimate? { get }; var ambientIntensity: CGFloat { get }
class ARMeshGeometry { var vertices: ARGeometrySource; var normals: ARGeometrySource; var faces: ARGeometryElement; var classification: ARGeometrySource? }
class ARGeometrySource { var buffer: any MTLBuffer; var count: Int; var format: MTLVertexFormat; var componentsPerVector: Int; var offset: Int; var stride: Int }
class ARGeometryElement { var buffer: any MTLBuffer; var count: Int; var bytesPerIndex: Int; var indexCountPerPrimitive: Int; var primitiveType: ARGeometryPrimitiveType }
var thermalState: ProcessInfo.ThermalState { get }; class let thermalStateDidChangeNotification: NSNotification.Name
extern size_t os_proc_available_memory();                             // import os
```
Buffers: `buffer.contents()` plus `offset` and `stride` (never assume 12 or 16), normals are per vertex, classification is one UInt8 per face, faces are UInt32 triples (RESEARCH 3.1 gotchas 2 to 4, 3.9 gotcha 4). Depth and confidence sizes and pixel formats are read at runtime with `CVPixelBufferGetWidth`, `CVPixelBufferGetHeight` (RESEARCH 3.1), `CVPixelBufferGetPixelFormatType`, `CVPixelBufferGetBytesPerRow`, inside `CVPixelBufferLockBaseAddress(_, .readOnly)` and `CVPixelBufferUnlockBaseAddress` (not in RESEARCH, CoreVideo, iOS 4).

**Must NOT do.** Never pass `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction` when re-applying during RoomPlan. Never enable plane detection except for Quick Measure (D14). Never change `videoFormat` (RESEARCH 3.8 disputed 10). Never retain an ARFrame, its pixel buffers or an `ARMeshGeometry` buffer. Never mark the hub `@MainActor`. Never call ARKit on main except `install`, `run`, `pause` and init. No file IO (recorders use Store), no RoomPlan import, no UI.

**Copy strings.** None (diagnostics are logs).

**Self-test.** `CaptureCoreSelfTest.run()`, at least 25 checks: `ScanProfile.wantsPlaneDetection` true only for quickMeasure; `ScanConfigurationFactory.make` sets planeDetection [] for room, house, advancedSpace, object (inspect the returned configuration's `planeDetection`, `environmentTexturing`, `isLightEstimationEnabled`; no session is run); `CaptureWatchdogLogic` sequences: depth present all along gives none; depth absent 2.1 s gives one reapply then degrade(.depthStripped) after 2 more seconds; mesh absent 8 s with normal tracking gives reapply; limited tracking does not count toward the mesh timer; reset clears; `StorageWatchdog.state(forFreeBytes:)` at 5 GB, 900 MB, 200 MB; `ThermalPolicy.forLevel` for all four levels; `ThermalLevel(.critical)`; `TrackingMonitor` with synthetic timestamps gives the right limited fraction (use a pure helper that takes summaries); `MeshAnchorCopier.unpackFloat3` with stride 12 and stride 16 buffers and an offset of 8; `unpackUInt32`; `ARFrameReading.angularSpeed` of a 90 degree yaw over 1 s is pi/2 within 1e-4; `linearSpeed` of 0.5 m over 0.25 s is 2; `RecorderStats +` sums fields.

**Acceptance checks.** `install()` is called before `RoomCaptureView` is created (documented in the doc comment); every delegate method matches the RESEARCH signature exactly; recorders receive calls only on `queue`; `onStatus` is throttled to 4 Hz; the delegate identity check runs once per second and logs; watchdog actions are logged as `CaptureEvent(kind: .degraded / .config)`; no `@MainActor` on the class; `os` imported only in `CaptureWatchdogs.swift`.

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation A (LiDAR mesh, ARKit anchors, camera poses, depth information, confidence information, world transforms, timestamps, device orientation, calibration information), capture side; "ROOM SCANNING" ("Use ARKit LiDAR mesh data in parallel"; "Do not rely exclusively on RoomPlan"); "LIVE SCANNING EXPERIENCE" signals (tracking quality, lighting, speed).

### 3.12 RoomModel

**Purpose.** Turns RoomPlan output into Mapper's own clean architectural model (Representation C): a testable mirror of `CapturedRoom` (`RoomInput`), the closed wall loop that is the primary room outline (D12), walls with corners closed, openings projected onto their walls, default door swing, floor and ceiling from mesh faces (D13), object boxes, occlusion honesty heuristics, room metrics, EditLog application to `CleanModel` (D3), triangle meshes of the clean model for the viewer and exports, and the `buildRoom` and `cleanModel` pipeline steps.

**Build and wave.** Build 4, wave 4a. Core, Geometry, MeshProcessing (types only), Support; RoomPlan (only in `RoomInput+RoomPlan.swift` and `RoomModelStores.swift`, `RoomModelSteps.swift`).

**Files.** `ios/Sources/RoomModel/RoomInput.swift`, `RoomInput+RoomPlan.swift`, `RoomOutline.swift`, `CleanModelBuilder.swift`, `RoomMetricsCalculator.swift`, `CleanModel+Edits.swift`, `CleanMeshBuilder.swift`, `PolygonTriangulator.swift`, `RoomModelStores.swift`, `RoomModelSteps.swift`, `RoomModelSelfTest.swift`, `RoomModelSelfTestFixtures.swift`.

**Public Swift API.** All pure functions are nonisolated and safe on any queue.
```swift
enum SurfaceKind: String, Codable, CaseIterable, Sendable { case wall, door, openDoor, window, opening, floor }
struct WallArcInput: Codable, Equatable, Sendable { var center: Vec2; var radius: Float; var startAngle: Float; var endAngle: Float }  // local xz, radians
struct SurfaceInput: Codable, Equatable, Sendable {
    var identifier: UUID; var parentIdentifier: UUID?; var kind: SurfaceKind
    var transform: Transform4; var dimensions: Vec3; var confidence: DetectionConfidence
    var completedEdges: Int; var curve: WallArcInput?; var polygonCorners: [Vec3]; var story: Int
}
struct ObjectInput: Codable, Equatable, Sendable {
    var identifier: UUID; var parentIdentifier: UUID?; var category: ObjectCategory
    var transform: Transform4; var dimensions: Vec3; var confidence: DetectionConfidence; var story: Int
}
struct SectionInput: Codable, Equatable, Sendable { var label: String; var center: Vec3; var story: Int }
/// Everything Mapper uses from one CapturedRoom, constructible in tests.
struct RoomInput: Codable, Equatable, Sendable {
    var identifier: UUID
    var walls: [SurfaceInput]; var openings: [SurfaceInput]; var floors: [SurfaceInput]
    var objects: [ObjectInput]; var sections: [SectionInput]; var story: Int
}
extension RoomInput { init(_ room: CapturedRoom) }             // RoomInput+RoomPlan.swift
extension SurfaceInput { init(_ surface: CapturedRoom.Surface) } // angles via .converted(to: .radians).value

struct WallSegment: Equatable, Sendable {
    var id: ElementID; var start: SIMD2<Float>; var end: SIMD2<Float>   // PlanAxes plan meters
    var baseY: Float; var height: Float; var confidence: DetectionConfidence; var completedEdges: Int; var arc: WallArc?
}
struct OutlineResult: Equatable, Sendable {
    var polygon: [SIMD2<Float>]      // counter-clockwise, plan meters
    var walls: [WallSegment]         // loop order, a to b counter-clockwise (room on the left), corners intersected
    var strayWalls: [WallSegment]    // stubs and partitions not in the loop
    var isClosed: Bool
    var floorPolygonMismatch: Float? // |loop area - floor polygon area| / loop area (cross-check only)
}
enum RoomOutline {
    static let joinTolerance: Float = 0.15
    static let parallelLimitDegrees: Float = 10
    /// Endpoints transform * (+-dimensions.x / 2, 0, 0, 1); horizontal projection of columns.0
    /// when abs(columns.1.y) < 0.99 (logged).
    static func wallSegments(_ input: RoomInput) -> [WallSegment]
    static func build(_ input: RoomInput) -> OutlineResult
    /// floors[0].polygonCorners through the floor transform, plan meters; nil when absent.
    static func floorPolygon(_ input: RoomInput) -> [SIMD2<Float>]?
}

struct CleanBuildOptions: Equatable, Sendable {
    var interiorThickness: Float = 0.115; var exteriorThickness: Float = 0.15
    var findFurniture = true; var ceilingCoverageGate: Float = 0.25; var occlusionDistance: Float = 0.3
    init()
}
enum CleanModelBuilder {
    /// One room. `mesh` is the world-space consolidated mesh with faceClass (nil: no mesh terms).
    static func buildRoom(_ input: RoomInput, recordID: UUID, name: String, floorIndex: Int,
                          mesh: MeshWithAttributes?, options: CleanBuildOptions = CleanBuildOptions()) -> CleanRoom
    static func buildModel(_ rooms: [(input: RoomInput, record: RoomRecord)], meshes: [UUID: MeshWithAttributes],
                           options: CleanBuildOptions = CleanBuildOptions()) -> CleanModel
    /// Hinge at the end nearer a wall corner; opens toward the room normal; source .estimated.
    static func defaultSwing(opening: CleanOpening, wall: CleanWall, outline: [SIMD2<Float>]) -> DoorSwing
}
enum RoomMetricsCalculator {
    static func metrics(for room: CleanRoom) -> RoomMetrics
    /// D13: median Y of ceiling faces (class 3) inside the outline minus floor Y, when they cover
    /// at least `gate` of the outline area.
    static func ceilingFromMesh(_ mesh: MeshWithAttributes, outline: [SIMD2<Float>], floorY: Float, gate: Float) -> (height: Float, coverage: Float)?
    static func floorFromMesh(_ mesh: MeshWithAttributes, outline: [SIMD2<Float>], gate: Float) -> (elevation: Float, coverage: Float)?
    /// Movable objects within `distance` of a wall add occluded spans; their footprints add occluded floor area.
    static func applyOcclusion(_ room: inout CleanRoom, distance: Float)
}
extension CleanModel: EditApplicable { mutating func apply(_ op: EditOperation) -> Bool }

enum CleanPartKind: Hashable, Sendable { case wall, floor, ceiling, door, window, opening, object(ObjectCategory) }
struct CleanMeshPart: Equatable {
    var element: ElementID; var kind: CleanPartKind; var mesh: TriangleMesh
    var isMovable: Bool; var isHidden: Bool; var provenance: Provenance
}
enum CleanMeshBuilder {
    static func parts(for model: CleanModel, includeCeiling: Bool, includeHidden: Bool) -> [CleanMeshPart]
    /// Wall rectangle minus opening rectangles as strips of quads (no general triangulation).
    static func wallMesh(_ wall: CleanWall, openings: [CleanOpening]) -> TriangleMesh
}
enum PolygonTriangulator {
    /// Ear clipping of a simple polygon (either winding); triangle indices into `polygon`, empty on failure.
    static func triangulate(_ polygon: [SIMD2<Float>]) -> [UInt32]
}

enum CleanModelStore {
    static func loadBase(_ package: ProjectPackage) throws -> CleanModel                 // derived/clean.json
    /// Applies `EditLog` from `package.editLogURL` (missing file = empty log), recomputes metrics.
    static func loadEdited(_ package: ProjectPackage) throws -> (model: CleanModel, orphaned: [EditOperation])
    static func save(_ model: CleanModel, to package: ProjectPackage) throws
}
enum CapturedRoomStore {
    static func rawFolder(_ package: ProjectPackage, room: RoomRecord) -> RawScanFolder
    static func rebuiltURL(_ package: ProjectPackage, roomID: UUID) -> URL              // derived/rooms/<id>/capturedroom.json
    static func loadCapturedRoom(_ package: ProjectPackage, room: RoomRecord) throws -> CapturedRoom  // raw first, then rebuilt
    static func loadInput(_ package: ProjectPackage, room: RoomRecord) throws -> RoomInput
}
/// Rebuilds capturedroom.json from capturedroomdata.json when raw lacks it (crash during capture).
final class BuildRoomStep: ProcessingStep { init(room: RoomRecord) }        // id .buildRoom, budget 150 MB
/// Builds derived/clean.json for every room with status captured or processed. A room with no
/// loadable CapturedRoom (RoomPlan failed) is left out of the model and logged; an empty model is
/// still written so FloorPlanStep and Results can report "no walls".
final class CleanModelStep: ProcessingStep {                                  // id .cleanModel, budget 200 MB
    init(meshProvider: @escaping (UUID) -> MeshWithAttributes?)              // room id -> consolidated mesh
}
```

Rules the builder follows: walls come from the loop (D12) with `ElementID.derived(fromRoomPlan:)` ids and `normal` pointing into the room; openings attach by `parentIdentifier` (fallback nearest parallel wall within 0.3 m), endpoints are projected onto the wall and clamped, `sillHeight`/`headHeight` are relative to the floor elevation; `OpeningKind(_:)` mapping lives in Core; `thickness` defaults to 0.115 m for every wall of a single room (Structure sets 0.15 m for exterior walls, or a measured value from wall pairs, in build 5), `thicknessSource` `.estimated`; floor outline is the loop polygon, `floor.elevation` from mesh floor faces when `floorFromMesh` passes the gate (`.measured`), else the floors[0] Y or the lowest wall base (`.estimated`); ceiling per D13, else max wall height with confidence high (`.estimated`); objects are skipped when `findFurniture` is false (they stay in raw); `CleanRoom.id = ElementID(uuid: recordID)`; `sectionLabel` is the label of the section whose center lies inside the outline; a floor polygon mismatch over 5 percent is logged (category "roommodel"). Metrics: area and perimeter from the loop (shoelace), length and width from `Rectangle2D.minimumArea(enclosing:)`, wall area = sum of length x height minus openings, volume = area x ceiling height with the ceiling's provenance. Edit application (`apply`): renameRoom, relabelObject, recategorizeObject, setHidden, deleteElement (walls, openings, objects), moveObject, moveWallEndpoint (plan point to world via `PlanAxes.toWorld(_:y:)` at the floor elevation), addWall (height = room ceiling), addOpening, setDoorSwing, setWallThickness and setScaleCorrection (multiplies the room's metrics) change the model; setRoomAlignment, cropObject, addAnnotation and addDimension return true unchanged; an operation whose target is missing returns false and changes nothing.

**Uses.** Core: `CleanModel`, `CleanRoom`, `CleanWall`, `CleanOpening`, `CleanFloor`, `CleanCeiling`, `DetectedObject`, `DoorSwing`, `WallArc`, `RoomMetrics`, `Provenance`, `ElementID.derived(fromRoomPlan:)`, `PlanAxes`, `ObjectCategory.init(_:)`, `DetectionConfidence.init(_:)`, `OpeningKind.init?(_:)`, `EditOperation`, `EditLog.applied(to:)`, `EditApplicable`, `ProcessingStep`, `StepContext`, `InputHasher`, `SealFile`, `ProjectStore`, `ProjectPackage`, `RawScanFolder`, `RoomRecord`, `MapperError`. Geometry: `Polygon2D`, `Rectangle2D.minimumArea(enclosing:)`, `Segment2D.intersection(with:)`, `TriangleMesh`, `OrientedBox`. MeshProcessing: `MeshWithAttributes`. Support: `LogStore`.

**Apple APIs** (RESEARCH 3.2 and 3.6): `CapturedRoom` (`identifier`, `walls`, `doors`, `windows`, `openings`, `floors`, `objects`, `sections`, `story`), `CapturedRoom.Surface` (`identifier`, `parentIdentifier`, `category`, `confidence`, `transform`, `dimensions`, `completedEdges: Set<CapturedRoom.Surface.Edge>`, `curve`, `polygonCorners`, `story`), `CapturedRoom.Surface.Category { floor, door(isOpen: Bool), opening, wall, window }` (not CaseIterable), `CapturedRoom.Surface.Curve` (`startAngle`/`endAngle: Measurement<UnitAngle>`, `radius: Float`, `center: simd_float2`), `CapturedRoom.Object` (`identifier`, `parentIdentifier`, `category`, `transform`, `dimensions`, `confidence`), `CapturedRoom.Section` (`label`, `center`, `story`), `class RoomBuilder { init(options: RoomBuilder.ConfigurationOptions); func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom }` with `[.beautifyObjects]`, `struct CapturedRoomData` (Codable).

**Must NOT do.** Never use `floors[].polygonCorners` as the room outline or area source (cross-check only). Never trust `columns.0` sign for winding; derive it from the loop. Never draw curved walls as straight segments (keep `arc`). Never construct or mutate `CapturedRoom`. Never write into raw. Never bake a label or category guess into anything but the derived model (labels are edits).

**Copy strings.** None (names are resolved by FloorPlan's `RoomTitles`).

**Self-test.** `RoomModelSelfTest.run()`, at least 45 checks, with hand-made `RoomInput` fixtures in `RoomModelSelfTestFixtures.swift`: a 4 x 5 m rectangle, an L-shaped room (6 walls, area 20.0 where the bounding rectangle is 24.0), a room with a 0.3 m stub wall, a room with one wall whose `columns.0` is flipped, a room with a curved wall. Checks: outline closed and counter-clockwise; L-shape area within 1e-3 of 20 and perimeter exact; floor polygon mismatch reported for the L-shape with a rectangle floor; stub goes to `strayWalls`; flipped wall still in loop order; wall normals point inside; corner intersection moves endpoints that overshoot by 5 cm; door projected onto its parent with correct offset, width, sill 0 and head height; window sill relative to floor elevation; opening with nil parent attaches to the nearest wall; default swing hinge at the nearer corner; ceiling from a synthetic mesh at 2.60 m with 80 percent coverage is measured 2.60; with 10 percent coverage it falls back to wall height, estimated; length and width of the 4 x 5 room are 5 and 4; wall area subtracts one door; volume provenance follows the ceiling; findFurniture false drops objects; occlusion span for a sofa 0.1 m from a wall; each EditOperation case applied once (rename, relabel, recategorize, hide, delete wall, move object, move wall endpoint, add wall, add opening, door swing, thickness, scale 1.1 on area) plus an orphaned target returning false; `PolygonTriangulator` on a square (2 triangles), an L (4 triangles), a clockwise input, and a degenerate input (empty); `CleanMeshBuilder.wallMesh` of a 4 x 2.5 m wall with a 0.9 x 2.0 m door has area 10 - 1.8 within 1e-4; `parts` excludes hidden objects unless asked; `RoomInput` Codable round trip.

**Acceptance checks.** RoomPlan types appear only in the three named files; the builder never reads `floors` for area; every public function is pure; `CleanModel.apply` returns true for operations meant for other models; metrics are recomputed after edits in `loadEdited`; `CleanModelStep.inputHash` includes the room seals and `EditLog.revision` is NOT included (the base model ignores edits).

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation C (walls, floors, ceilings, doors, windows, openings, stairs where detectable, furniture, appliances, other recognized objects); "ROOM SCANNING" (walls, floor, ceiling, doors, windows, openings, structural boundaries, furniture, permanent fixtures); "MEASUREMENT SYSTEM" automatic values (wall length and height, ceiling height, door and window sizes, room length, width, area, floor area, wall area, perimeter, estimated volume); "FURNITURE REMOVAL" (occluded spans and areas marked, not fabricated; estimated geometry distinguished by provenance); "AUTOMATIC OBJECT RECOGNITION" ("Never permanently bake AI/object-recognition guesses into the raw scan").

### 3.13 MeshModel

**Purpose.** Turns the raw anchor-local mesh chunks of a room into derived world-space meshes: consolidated measured mesh (weld, cleanup), small holes filled and flagged inferred, a simplified viewer and texturing mesh, statistics, the classification color palette, the export adapter, and the `consolidateMesh` step. Also a fast unwelded path for the quality check at Done.

**Build and wave.** Build 4, wave 4a. Core, Geometry, MeshProcessing, Export, Support.

**Files.** `ios/Sources/MeshModel/MeshConsolidator.swift`, `MeshModelStore.swift`, `MeshClassPalette.swift`, `MeshExportAdapter.swift`, `MeshModelStep.swift`, `MeshModelSelfTest.swift`.

**Public Swift API.** Pure and nonisolated unless noted.
```swift
struct ConsolidationOptions: Equatable, Sendable {
    var weldTolerance: Float = 0.005; var minIslandTriangles = 50; var minIslandArea: Float = 0.01
    var holeMaxPerimeter: Float = 0.5; var viewTriangleBudget = 300_000
    var depthWindow: ClosedRange<Float>? = nil          // Advanced distance crop (build 6)
    init()
}
struct MeshStats: Codable, Equatable, Sendable {
    var chunkCount: Int; var triangleCount: Int; var viewTriangleCount: Int; var inferredTriangleCount: Int
    var classTriangleCounts: [String: Int]              // ARMeshClassification raw value (0...7) as text
    var boundsMin: Vec3; var boundsMax: Vec3
}
struct ConsolidationResult { var measured: MeshWithAttributes; var inferred: MeshWithAttributes; var view: MeshWithAttributes; var stats: MeshStats }
enum MeshConsolidator {
    /// Later folders win for the same anchorID; within a folder the highest updateCount wins.
    static func latestChunks(in folders: [RawScanFolder]) -> [MeshChunk]
    static func mergeChunks(_ chunks: [MeshChunk]) -> [MergeChunk]
    /// ChunkMerge.merge, removingDegenerateAndDuplicateFaces, MeshCleanup.removingFloaters,
    /// HoleFill.fillSmallHoles (inferred faces split out), MeshSimplify to viewTriangleBudget.
    static func consolidate(_ chunks: [MeshChunk], options: ConsolidationOptions, isCancelled: () -> Bool) -> ConsolidationResult?
    /// World transform only, no weld; for the quality check at Done (under 1 s for 500k faces).
    static func fastWorldMesh(_ chunks: [MeshChunk]) -> MeshWithAttributes
}
enum MeshModelStore {
    static func measuredURL(_ package: ProjectPackage, room: UUID) -> URL   // derived/rooms/<r>/mesh.mchk
    static func inferredURL(_ package: ProjectPackage, room: UUID) -> URL   // mesh_inferred.mchk
    static func viewURL(_ package: ProjectPackage, room: UUID) -> URL       // mesh_view.mchk
    static func statsURL(_ package: ProjectPackage, room: UUID) -> URL      // mesh_stats.json
    static func save(_ result: ConsolidationResult, package: ProjectPackage, room: UUID) throws
    static func loadMeasured(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    static func loadInferred(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    static func loadView(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    static func loadStats(_ package: ProjectPackage, room: UUID) -> MeshStats?
    /// World mesh <-> Core MeshChunk (identity transform, anchorID = room id, classes, normals).
    static func chunk(from mesh: MeshWithAttributes, id: UUID) -> MeshChunk
    static func mesh(from chunk: MeshChunk) -> MeshWithAttributes
}
enum MeshClassPalette {
    /// RGBA 0...1 per ARMeshClassification raw value 0...7, plus `inferred`.
    static func color(for classValue: UInt8) -> SIMD4<Float>
    static func bytes(for classValue: UInt8) -> SIMD4<UInt8>
    static let inferred: SIMD4<Float>
    static let all: [UInt8: SIMD4<Float>]
}
enum MeshExportAdapter {
    static func exportMesh(_ mesh: MeshWithAttributes, name: String, colorByClass: Bool) -> ExportMesh
    static func scene(measured: MeshWithAttributes, inferred: MeshWithAttributes?, colorByClass: Bool) -> ExportScene
}
final class ConsolidateMeshStep: ProcessingStep {    // id .consolidateMesh; budget 700 MB, reduced 350 MB
    init(roomID: UUID, folders: [RawScanFolder])     // folders: the room folder plus its mesh passes
}                                                    // no chunks (meshStripped): completes, writes nothing, logs
```
Palette (RGB, alpha 1): none 0.62 0.62 0.62; wall 0.45 0.62 0.85; floor 0.55 0.75 0.45; ceiling 0.90 0.85 0.55; table 0.85 0.55 0.35; seat 0.75 0.45 0.75; window 0.40 0.85 0.90; door 0.85 0.40 0.40; inferred 1.00 0.60 0.00. The reduced variant (available memory below the full budget) simplifies each chunk to half its faces before merging and uses a 150k view budget.

**Uses.** Core: `MeshChunk`, `MeshChunkFile`, `RawScanFolder`, `ProjectPackage`, `ProjectStore`, `ProcessingStep`, `StepContext`, `InputHasher`, `SealFile`, `MapperError`, `Vec3`. MeshProcessing: `MergeChunk`, `ChunkMerge.merge`, `ChunkMerge.removingDegenerateAndDuplicateFaces`, `MeshCleanup.removingFloaters`, `MeshCleanup.normals`, `HoleFill.fillSmallHoles`, `MeshSimplify.simplify`, `MeshWithAttributes.keepingFaces`. Geometry: `TriangleMesh`, `AABB3`. Export: `ExportMesh`, `ExportScene`, `ExportMaterial`. Support: `LogStore`.

**Apple APIs.** None beyond Foundation and simd.

**Must NOT do.** Never modify or delete raw chunks; never drop a chunk because its anchor was removed during capture (RESEARCH 3.1 gotcha 15); never simplify the measured mesh (only the view copy); never mix inferred faces into `mesh.mchk`; never hold more than one room's full mesh in memory in the step.

**Copy strings.** None.

**Self-test.** `MeshModelSelfTest.run()`, at least 25 checks: `latestChunks` picks the highest updateCount and the later folder; two overlapping anchor-local cube halves with different transforms consolidate into one watertight cube (volume 1 within 1e-3); classes survive consolidation; a 10 cm hole is filled and appears only in `inferred`; a 30-triangle floater is removed; view budget respected on a 20k triangle sphere with budget 5k; `fastWorldMesh` transforms positions by the anchor transform; chunk/mesh round trip through `MeshChunkFile`; `save` then `loadMeasured`/`loadView`/`loadStats` round trip in a temp package; palette has 8 distinct colors and `bytes` matches `color`; export adapter produces per-vertex colors when asked and none otherwise, and `ExportScene.validate()` passes; cancellation closure returning true yields nil.

**Acceptance checks.** The step decodes chunks one folder at a time and releases them before simplification; `inputHash` uses the seals of all given folders; outputs are written with `ProjectStore.writeData` (atomic); the palette is the only source of classification colors in the app.

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation A (LiDAR mesh preserved) and Representation B (mesh cleanup, hole filling where mathematically reasonable, mesh simplification for performance); deliverable 2 "A high-detail LiDAR mesh"; "FURNITURE REMOVAL" ("If geometry is estimated, clearly distinguish estimated geometry from measured geometry": filled holes flagged inferred).

### 3.14 MeasureCore

**Purpose.** One place that turns geometry plus capture evidence into honest measured values and the text shown for them: the confidence adapter over Coverage's `MeasurementConfidence` with the RoomPlan cap, the single low-confidence rule (CR-2), display text in both unit systems, the room dimension list (length, width, floor area, perimeter, ceiling height, wall, door and window sizes, wall area, estimated volume), and the snap candidate set from the clean model used by the measuring tools of build 5.

**Build and wave.** Build 4, wave 4a. Core, Geometry, Coverage, Units, Support.

**Files.** `ios/Sources/MeasureCore/MeasureEvidence.swift`, `MeasureConfidenceAdapter.swift`, `MeasureDisplay.swift`, `MeasureRoomDimensions.swift`, `MeasureSnapSet.swift`, `MeasureCoreSelfTest.swift`, `ios/Sources/Support/Copy+MeasureCore.swift`.

**Public Swift API.** Pure, nonisolated.
```swift
/// Capture evidence for one wall (filled by Quality from the coverage grid).
struct WallEvidence: Codable, Equatable, Sendable { var wallID: ElementID; var medianDistance: Float; var observations: Int }
/// Capture evidence for one room.
struct RoomEvidence: Codable, Equatable, Sendable {
    var trackingNormalFraction: Float; var relocalizations: Int; var walls: [WallEvidence]
    static let unknown: RoomEvidence          // fraction 1, 0 relocalizations, no walls
    func wall(_ id: ElementID) -> WallEvidence?
}
enum ConfidenceAdapter {
    /// RESEARCH ruling 4: RoomPlan-derived lengths never better than +-3 cm displayed (2 sigma).
    static let roomPlanMinimumSigma: Float = 0.015
    static let defaultDistance: Float = 2.0
    static let defaultObservations = 3
    /// A RoomPlan-derived length (wall, opening, room side, height): evidence of both ends is the
    /// wall's (or defaults), snap .roomSurface; sigma = max(Coverage accuracy, 0.015); when Coverage
    /// flags low confidence the sigma is raised to `lowConfidenceSigma(length:)` so the flag survives.
    static func roomPlanLength(_ length: Float, wall: WallEvidence?, room: RoomEvidence, provenance: Provenance) -> MeasuredValue
    /// Free point-to-point distance (build 5 tools).
    static func distance(start: MeasurementEvidence, end: MeasurementEvidence, length: Float) -> MeasuredValue
    /// Rectangle-like area from its two sides: sigma = sqrt((b sa)^2 + (a sb)^2).
    static func area(_ area: Float, sideA: MeasuredValue, sideB: MeasuredValue) -> MeasuredValue
    /// Sum of lengths: sigma = sqrt(sum of sigma^2).
    static func sum(_ values: [MeasuredValue]) -> MeasuredValue
    static func lowConfidenceSigma(length: Float) -> Double    // 0.505 * max(0.04, 0.03 * length)
}
enum MeasureDisplay {
    /// The one rule every screen uses: 2 sigma > max(0.04 m, 3 percent of `length`) for lengths;
    /// for areas and volumes the relative part only (2 sigma > 3 percent of the value). False without sigma.
    static func isLowConfidence(_ value: MeasuredValue, length: Double?) -> Bool
    /// Value text in the user's units: LengthFormat.display / AreaFormat.display / VolumeFormat / AngleFormat.
    static func valueText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String
    /// "Estimated accuracy ±0.6\"" (Copy.Measure.accuracy with Tolerance.plusMinus minus its leading
    /// "±", because Copy adds the sign), Copy.Measure.lowConfidence, Copy.Measure.notMeasured for
    /// inferred values, or nil when there is no sigma.
    static func accuracyText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String?
    static func accessibilityText(label: String, value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String
}
enum DimensionGroup: String, CaseIterable, Sendable { case room, walls, doors, windows }
struct DimensionRow: Identifiable, Equatable, Sendable {
    var id: String; var group: DimensionGroup; var title: String; var label: String
    var kind: MeasurementKind; var value: MeasuredValue; var element: ElementID?; var isLowConfidence: Bool
}
enum RoomDimensions {
    /// Room: length, width, floor area, perimeter, ceiling height, wall area, estimated volume; then
    /// per wall (length, height), per door (width, height), per window (width, height).
    static func rows(for room: CleanRoom, evidence: RoomEvidence) -> [DimensionRow]
}
/// Snap candidates from the clean model (world meters), in priority order corner, edge, plane.
struct SnapSet: Equatable {
    var corners: [SIMD3<Float>]; var cornerElements: [ElementID?]
    var edges: [(SIMD3<Float>, SIMD3<Float>)]; var planes: [Plane]
    static func build(from room: CleanRoom, includeObjects: Bool) -> SnapSet
    /// Geometry `Snap.best` with radii 0.10 corner, 0.05 edge, 0.05 plane; maps the target to Core SnapKind.
    func snap(_ point: SIMD3<Float>) -> (point: SIMD3<Float>, kind: SnapKind)
    static func == (lhs: SnapSet, rhs: SnapSet) -> Bool
}
```
Provenance rules: `.measured` and `.estimated` values show value plus accuracy text; `.inferred` values (volume from an inferred ceiling, occluded spans) show value plus `Copy.Measure.notMeasured` and no plus-minus; `.user` values show no plus-minus. Ceiling height with `.measured` provenance uses the depth model at the median camera distance; with `.estimated` it uses `roomPlanLength`.

**Uses.** Core: `MeasuredValue`, `MeasurementKind`, `SnapKind`, `Provenance`, `CleanRoom`, `CleanWall`, `CleanOpening`, `RoomMetrics`, `ElementID`. Coverage: `MeasurementEvidence`, `MeasurementSnapKind`, `MeasurementConfidence.estimate(start:end:length:)`, `MeasurementConfidence.estimate(point:)`. Geometry: `Snap.best`, `SnapResult`, `SnapTarget`, `Plane`, `Rectangle2D`. Units: `LengthFormat.display`, `AreaFormat.display`, `VolumeFormat.primary`, `VolumeFormat.both`, `AngleFormat.degrees`, `Tolerance.plusMinus`, `UnitPreferences`. Support: `Copy.Measure.*`.

**Apple APIs.** None.

**Must NOT do.** Never use `MeasuredValue.isLowConfidence` (CR-2). Never show a plus-minus better than 3 cm for a RoomPlan-derived length. Never call `CapturedRoom.Confidence` accuracy. Never format numbers without Units. Never produce a plus-minus for inferred or user values.

**Copy strings.** Existing: `Copy.Measure.roomLength`, `roomWidth`, `floorArea`, `perimeter`, `ceilingHeight`, `wallArea`, `volume`, `wallLength`, `wallHeight`, `doorWidth`, `doorHeight`, `windowSize`, `accuracy(_:)`, `accuracySpoken(_:)`, `lowConfidence`, `notMeasured`, `A11y.measurement(_:value:)`. New in `Copy+MeasureCore.swift` (`extension Copy { enum MeasureCore }`): `roomGroup = "Room"`, `wallsGroup = "Walls"`, `doorsGroup = "Doors"`, `windowsGroup = "Windows"`, `static func wallTitle(_ n: Int) -> String { "Wall \(n)" }`, `doorTitle(_:)` "Door \(n)", `windowTitle(_:)` "Window \(n)", `windowWidth = "Window width"`, `windowHeight = "Window height"`.

**Self-test.** `MeasureCoreSelfTest.run()`, at least 30 checks: a 5.66 m wall with defaults displays at least plus or minus 3 cm (sigma >= 0.015); sigma grows with length (2 m < 8 m); tracking fraction 0.5 marks low confidence and the flag survives through `MeasureDisplay.isLowConfidence`; a 10 m wall with good evidence is not low confidence (relative rule) while a 0.5 m distance with sigma 0.025 is; area sigma formula on a 4 x 5 room; sum of 4 walls; `accuracyText` contains exactly one plus-minus sign; imperial and metric texts for 3.845 m match `LengthFormat.display`; inferred volume text uses `notMeasured` and no sign; `RoomDimensions.rows` for a 4 x 5 room with one door and one window returns 7 room rows plus 8 wall rows plus 2 door rows plus 2 window rows in order; length >= width; `SnapSet` of a 4 x 5 x 2.5 room has 8 corners, the snap of a point 3 cm from a floor corner returns `.corner`, 3 cm from the middle of a wall's top edge returns `.edge`, a point 2 cm from a wall plane and at least 1 m from its edges returns `.plane`, a point 1 m inside the room returns `.none`.

**Acceptance checks.** All constants in one place with doc comments citing RESEARCH ruling 4 and the Coverage formula; no Units bypass; `RoomDimensions` is deterministic and ordered; row ids are stable strings ("room.length", "wall.<uuid>.length").

**SPEC owned.** "MEASUREMENT SYSTEM" (both feet and inches and metric, preference switching, the automatic measurements), "MEASUREMENT CONFIDENCE" (all of it: confidence shown, "Low confidence, rescan this section", no survey-grade claims), snapping order for "corner, wall, edge, floor, ceiling, door, window, object edge" (logic; the tools are build 5).

### 3.15 Pipeline

**Purpose.** Runs processing steps (Core `ProcessingStep`) one at a time per project, one project at a time: freshness by derived stamps (D11), memory gates and reduced variants (D17), thermal pause, idle timer, cancellation, progress, and a published per-project state that screens use for progressive results (D20).

**Build and wave.** Build 4, wave 4a. Core, Support; UIKit.

**Files.** `ios/Sources/Pipeline/ProcessingRunner.swift`, `ProcessingTypes.swift`, `ProcessingGuards.swift`, `PipelineSelfTest.swift`.

**Public Swift API.**
```swift
struct ScheduledStep {
    let step: ProcessingStep; let subject: UUID?; let isOptional: Bool
    init(_ step: ProcessingStep, subject: UUID? = nil, isOptional: Bool = false)
}
struct ProcessingJob {
    let projectID: UUID; let package: ProjectPackage; let steps: [ScheduledStep]
    init(projectID: UUID, package: ProjectPackage, steps: [ScheduledStep])
}
enum ProcessingOutcome: Equatable { case completed(skippedOptional: [PipelineStepID]), failed(step: PipelineStepID, error: MapperError), cancelled }
struct ProjectProcessingState: Equatable, Sendable {
    var isQueued = false; var isRunning = false; var isPausedForHeat = false
    var currentStep: PipelineStepID? = nil; var fraction: Double = 0
    var completed: Set<PipelineStepID> = []; var failed: [PipelineStepID: String] = [:]
    init()
}
@MainActor final class ProcessingRunner: ObservableObject {
    static let shared: ProcessingRunner
    @Published private(set) var states: [UUID: ProjectProcessingState]
    /// Queues a job; `onFinish` is called on main once. A job for a project already queued replaces it.
    func enqueue(_ job: ProcessingJob, onFinish: @escaping (ProcessingOutcome) -> Void)
    func cancel(projectID: UUID)
    func state(for projectID: UUID) -> ProjectProcessingState
    var isBusy: Bool { get }
}
enum ProcessingGuards {
    static func availableMemory() -> UInt64                       // os_proc_available_memory
    /// .full when available >= budget + headroom, .reduced when a reduced budget exists and
    /// available >= reduced + headroom, else .refuse (D17).
    static let headroomBytes: UInt64 = 300_000_000
    static func variant(available: UInt64, budget: UInt64, reduced: UInt64?) -> StepVariant
    static func waitWhileCritical(isCancelled: () -> Bool) async  // polls every 5 s at .critical
    /// True when the index holds a stamp with the current pipeline version and this hash.
    static func shouldSkip(index: DerivedIndex, step: PipelineStepID, subject: UUID?, inputHash: String) -> Bool
    /// Pure state reducer used by the runner (and the self-test).
    static func reduce(_ state: ProjectProcessingState, _ event: ProcessingEvent) -> ProjectProcessingState
    /// True when a progress update at `now` should be published after one at `last` (0.1 s throttle).
    static func shouldPublish(now: Double, last: Double?) -> Bool
}
enum StepVariant: Equatable, Sendable { case full, reduced, refuse }
enum ProcessingEvent: Equatable, Sendable {
    case queued, started(PipelineStepID), progress(Double), stepCompleted(PipelineStepID),
         stepSkipped(PipelineStepID), stepFailed(PipelineStepID, reason: String, optional: Bool),
         pausedForHeat(Bool), finished
}
```
Runner algorithm per step: build `StepContext` (manifest via `ProjectStore.readManifest`, `availableMemory`, `isCancelled` reading a per-job lock-protected flag, `progress` that hops to main at most 10 times a second); compute `inputHash` off main in `Task.detached(priority: .userInitiated)`; skip when `DerivedIndex.isFresh(step:subject:version: ProjectManifest.currentPipelineVersion, inputHash:)`; refuse with `MapperError.outOfMemory(step:)` when `variant` is `.refuse` (the step itself picks full or reduced from `ctx.availableMemory`); await `waitWhileCritical`; run `step.run(ctx)` in `Task.detached`; on success record `DerivedStamp` in `derived/index.json` (the runner is the only writer of the index); on failure of an optional step record it in `failed` and continue, of a required step stop with `.failed`. `UIApplication.shared.isIdleTimerDisabled` is true while any job runs. Every step start, end, skip and failure is logged (category "pipeline") with duration and available memory.

**Uses.** Core: `ProcessingStep`, `StepContext`, `PipelineStepID`, `DerivedIndex`, `DerivedStamp`, `ProjectManifest.currentPipelineVersion`, `ProjectStore.readManifest`, `ProjectStore.readJSON`, `ProjectStore.writeJSON`, `ProjectPackage.derivedIndexURL`, `MapperError`. Support: `LogStore`.

**Apple APIs.** `var isIdleTimerDisabled: Bool { get set }` (UIApplication, main only); `var thermalState: ProcessInfo.ThermalState { get }`; `os_proc_available_memory()` (import os); `Task.detached(priority:operation:)`.

**Must NOT do.** Never run two steps at once; never run processing while a capture is active (AppShell only enqueues after Finish); never write the manifest (callers do it in `onFinish` through Store); never use `BGProcessingTask` (RESEARCH 3.9); never block main.

**Copy strings.** None (screens map `PipelineStepID` to `Copy.Processing`).

**Self-test.** `PipelineSelfTest.run()`, at least 15 checks on the pure parts (the runner itself is async and main-actor, so it is covered by the device smoke test): `ProcessingGuards.variant` at the full, reduced and refuse boundaries and with no reduced budget; `shouldSkip` true only for equal version and hash and the same subject; `reduce` for queued, started, progress, stepCompleted, stepSkipped, stepFailed optional (job continues), stepFailed required, pausedForHeat, finished; `shouldPublish` drops an update 0.05 s after the last and passes one after 0.2 s; `DerivedIndex.record` replaces the same step and subject.

**Acceptance checks.** Every `@Published` mutation on main; no `ProcessingStep` touched on main except creation; failures of optional steps never fail the job; the index is read and written only by the runner; cancellation observed between steps and through `ctx.isCancelled`.

**SPEC owned.** "LOCAL-FIRST ARCHITECTURE" ("Prefer on-device processing"); "SCAN QUALITY SYSTEM" and "ROOM SCANNING" indirectly (results appear progressively, D20).

### 3.16 FloorPlan

**Purpose.** Representation D: derives the `PlanModel` from the clean model, applies edits to it (D3), converts a level into Export's `Plan2D` with layers, symbols, dimension strings and hit-test metadata, draws `Plan2D` with Core Graphics for the screen, PNG and the thumbnail (the same drawing that the PDF, SVG and DXF writers consume), provides the SwiftUI plan canvas with pan, zoom and tap, owns room titles, and runs the `floorPlan` and `thumbnail` steps.

**Build and wave.** Build 4, wave 4a. Core, Geometry, Export, Units, Support; SwiftUI, CoreGraphics, UIKit, ImageIO.

**Files.** `ios/Sources/FloorPlan/PlanBuilder.swift`, `PlanModel+Edits.swift`, `PlanDrawing.swift`, `PlanSymbols.swift`, `PlanRenderer.swift`, `PlanCanvasView.swift`, `FloorPlanSteps.swift`, `FloorPlanSelfTest.swift`, `ios/Sources/Support/Copy+FloorPlan.swift`.

**Public Swift API.**
```swift
enum PlanBuilder {
    /// One level per floor index. Walls a->b counter-clockwise around their room (room on the left,
    /// body drawn to the right by thickness); one interior dimension per wall (offset 0.3 m into the
    /// room); two overall dimensions per room from Rectangle2D.minimumArea; fixtures from objects.
    static func build(from model: CleanModel, floors: [FloorRecord]) -> PlanModel
}
extension PlanModel: EditApplicable { mutating func apply(_ op: EditOperation) -> Bool }
enum PlanModelStore {
    static func loadBase(_ package: ProjectPackage) throws -> PlanModel
    static func loadEdited(_ package: ProjectPackage) throws -> (plan: PlanModel, orphaned: [EditOperation])
    static func save(_ plan: PlanModel, to package: ProjectPackage) throws
}
/// Layer toggles (SPEC "Provide toggles"). Persisted per viewer session only.
struct PlanToggles: Codable, Equatable, Sendable {
    var furniture = true, measurements = true, roomNames = true, doorsWindows = true
    var fixtures = true, grid = false, scale = true
    static let standard: PlanToggles
}
enum PlanLayers {   // names and colors used by every writer
    static let walls = "A-WALL", doors = "A-DOOR", windows = "A-GLAZ", roomNames = "A-FLOR-IDEN"
    static let dimensions = "A-ANNO-DIMS", furniture = "A-FURN", fixtures = "A-FIXT", notes = "A-ANNO-NOTE", grid = "A-GRID"
    static let occluded = "A-WALL-OCCL"
    static func all() -> [Plan2D.Layer]
}
enum PlanHitKind: Equatable, Sendable { case wall, opening, fixture, room, dimension, annotation }
struct PlanHit: Equatable, Sendable {
    var element: ElementID; var kind: PlanHitKind
    var segment: (SIMD2<Float>, SIMD2<Float>)?; var polygon: [SIMD2<Float>]
    func distance(to point: SIMD2<Float>) -> Float
    static func == (lhs: PlanHit, rhs: PlanHit) -> Bool
}
struct PlanDrawingResult { var plan: Plan2D; var hits: [PlanHit] }
enum PlanDrawing {
    /// Labels are formatted here with Units; hidden fixtures are skipped; occluded wall spans go to
    /// `PlanLayers.occluded` as dashed segments; door = gap + leaf line + quarter arc from the hinge;
    /// window = three parallel lines; opening = gap with a thin line; stairs = treads at 0.28 m.
    static func make(level: PlanLevel, toggles: PlanToggles, prefs: UnitPreferences,
                     roomTitles: [ElementID: String], name: String) -> PlanDrawingResult
    static func hitTest(_ hits: [PlanHit], at point: SIMD2<Float>, tolerance: Float) -> PlanHit?
}
enum RoomTitles {
    /// User name, else the RoomPlan section label name, else "Room n".
    static func title(name: String, sectionLabel: String?, index: Int) -> String
    static func titles(for model: CleanModel) -> [ElementID: String]
}
/// Screen and image mapping: plan meters (+Y up) to points (+Y down).
struct PlanViewport: Equatable, Sendable {
    var pointsPerMeter: CGFloat; var origin: CGPoint      // screen point of plan (0, 0)
    func toScreen(_ p: SIMD2<Double>) -> CGPoint
    func toPlan(_ p: CGPoint) -> SIMD2<Double>
    static func fitting(min: SIMD2<Double>, max: SIMD2<Double>, in size: CGSize, margin: CGFloat) -> PlanViewport
}
enum PlanRenderer {
    /// Draws every entity; text drawn in screen space so it does not scale with zoom beyond clamping.
    static func draw(_ plan: Plan2D, in ctx: CGContext, viewport: PlanViewport, lineWidth: CGFloat, dark: Bool)
    static func pngData(_ plan: Plan2D, pixelWidth: Int) -> Data?
    static func jpegThumbnail(_ plan: Plan2D, pixelSize: Int) -> Data?
}
/// SwiftUI Canvas via GraphicsContext.withCGContext; DragGesture pans, MagnifyGesture zooms
/// about its anchor, SpatialTapGesture hit-tests in model space (12 pt tolerance).
struct PlanCanvasView: View {
    init(drawing: PlanDrawingResult, selection: Binding<ElementID?>, onTap: ((PlanHit?) -> Void)? = nil)
}
final class FloorPlanStep: ProcessingStep { init(floors: [FloorRecord]) }   // id .floorPlan; reads clean.json, writes plan.json; 50 MB
final class ThumbnailStep: ProcessingStep { init() }                        // id .thumbnail; edited plan level 0 -> thumbnail.jpg 512 px; 50 MB
```
`PlanModel.apply` changes the plan for renameRoom, setHidden (fixtures), deleteElement, moveWallEndpoint, addWall, addOpening, setDoorSwing, setWallThickness, addAnnotation, addDimension, recategorizeObject (fixture category), moveObject (fixture center and yaw from the transform); other operations return true unchanged; a missing target returns false. After an edit that moves walls, the dimension strings of those walls follow their endpoints.

**Uses.** Core: `PlanModel`, `PlanLevel`, `PlanRoom`, `PlanWall`, `PlanOpening`, `PlanFixture`, `PlanAnnotation`, `PlanDimension`, `PlanAxes`, `CleanModel`, `CleanRoom`, `FloorRecord`, `DoorSwing`, `ObjectCategory`, `EditOperation`, `EditLog`, `EditApplicable`, `ProcessingStep`, `StepContext`, `InputHasher`, `ProjectStore`, `ProjectPackage` (`cleanModelURL`, `planModelURL`, `editLogURL`, `thumbnailURL`). Geometry: `Rectangle2D`, `Polygon2D`, `Segment2D`. Export: `Plan2D` and its `Layer`, `Geometry`, `Entity`, `dimensionLayout(from:to:offset:)`, `bounds()`. Units: `LengthFormat.primary`, `AreaFormat.primary`, `UnitPreferences`. Support: `Copy.FloorPlan.*`, `Copy.A11y.floorPlan`, `Copy.A11y.floorPlanHint`.

**Apple APIs** (RESEARCH 3.6): `struct Canvas<Symbols>`, `func withCGContext(content: (CGContext) throws -> Void) rethrows`; `DragGesture(minimumDistance: 10, coordinateSpace: .local)`; `MagnifyGesture(minimumScaleDelta: 0.01)`; `SpatialTapGesture(count: 1, coordinateSpace: .local)`; `UIGraphicsImageRenderer(size:format:)` with `pngData(actions:)`, `jpegData(withCompressionQuality:actions:)` (not in RESEARCH, iOS 10); `UIGraphicsPushContext(_:)`/`UIGraphicsPopContext()` for text with `NSAttributedString.draw(at:)` (not in RESEARCH, long-standing; Export's `PDFPlanWriter` already draws its text this way inside a UIKit renderer context).

**Must NOT do.** Never use `MagnificationGesture` or the `CoordinateSpace`-typed initializers; never use `ImageRenderer` for plans; never format a length without Units; never add `$INSUNITS` or DXF DIMENSION entities (Export owns DXF); never flip y twice (screen is y-down, plan is y-up, `PlanViewport` is the only flip); never bake Copy defaults into `PlanRoom.name` (empty means default).

**Copy strings.** Existing: `Copy.FloorPlan.toggleFurniture`, `toggleMeasurements`, `toggleRoomNames`, `toggleDoorsWindows`, `toggleFixtures`, `toggleGrid`, `toggleScale`, `Copy.House.roomSuggestions`. New (`extension Copy.FloorPlan` in `Copy+FloorPlan.swift`): `static func defaultRoomTitle(_ n: Int) -> String { "Room \(n)" }`, `sectionLivingRoom = "Living Room"`, `sectionKitchen = "Kitchen"`, `sectionDiningRoom = "Dining Room"`, `sectionBedroom = "Bedroom"`, `sectionBathroom = "Bathroom"`, `stairsUp = "UP"`, `stairsDown = "DN"`, `static func roomTag(name: String, area: String) -> String { "\(name)\n\(area)" }`.

**Self-test.** `FloorPlanSelfTest.run()`, at least 35 checks: build from a 4 x 5 clean room gives one level, one room with area 20, 4 walls counter-clockwise, 4 wall dimensions and 2 overall dimensions labeled with `LengthFormat.primary`; door becomes an opening with the right offset and a swing; `PlanAxes` sign (world z = -3 maps to plan y = 3); every EditOperation that concerns the plan applies (rename, hide fixture, delete wall, move endpoint moves the dimension, add wall, add opening, swing, thickness, annotation, dimension, recategorize, move fixture) and an orphan returns false; `PlanDrawing` with toggles off removes the matching layers' entities; hidden fixture skipped; door arc entity present with radius = width; occluded span produces a dashed layer entity; `hitTest` finds a wall 5 cm from the click and not at 1 m; `PlanViewport.fitting` maps bounds inside the margins and `toPlan(toScreen(p)) == p`; `pngData` returns PNG bytes starting with the PNG signature; `jpegThumbnail` returns JPEG bytes; `RoomTitles` for empty name with a kitchen label, empty name without label, and a user name.

**Acceptance checks.** The canvas, PNG and thumbnail all call `PlanRenderer.draw` on the same `Plan2D` the exporters get; text size is constant on screen; layer names are the constants above; the step writes `plan.json` from the base clean model (edits are applied at load).

**SPEC owned.** "2D FLOOR PLAN" (walls, wall thickness where determinable as estimated or measured, doors, door swing direction when known (estimated default), windows, openings, room names, room dimensions, overall dimensions, fixtures, stairs, bathroom fixtures, kitchen equipment, all seven toggles); "CORE DESIGN PRINCIPLE", Representation D.

### 3.17 Viewer3D

**Purpose.** Mapper's own RealityKit viewer engine (no SceneKit, no Metal, no custom shader): an `ARView` in `.nonAR` mode with an orbit, pan and pinch camera, geometry uploaded as `LowLevelMesh` parts, the display styles (Textured, Solid Color, Wireframe, Raw Scan classification colors, Photo Realistic later) by material, layer visibility (Hide Furniture), CPU picking with `MeshBVH`, screen projection for SwiftUI labels, snapshots, and the UV checkerboard diagnostic (D22). It renders generic parts; callers convert their models into parts.

**Build and wave.** Build 4, wave 4a. Core, Geometry, MeshProcessing, Support; RealityKit, SwiftUI, UIKit, ImageIO.

**Files.** `ios/Sources/Viewer3D/ViewerTypes.swift`, `ViewerContentBuilder.swift`, `ViewerRenderMesh.swift`, `ViewerModel.swift`, `ViewerContainer.swift`, `ViewerOrbitCamera.swift`, `ViewerPicking.swift`, `ViewerDiagnostics.swift`, `Viewer3DSelfTest.swift`.

**Public Swift API.**
```swift
enum ViewerDisplayStyle: String, CaseIterable, Sendable { case photoRealistic, textured, solidColor, wireframe, rawScan }
enum ViewerMaterial: Equatable, Sendable {
    case unlit(SIMD4<Float>)          // UnlitMaterial(color:), faceCulling .none
    case lit(SIMD4<Float>)            // SimpleMaterial(color:roughness:isMetallic:), faceCulling .none
    case wireframe(SIMD4<Float>)      // UnlitMaterial, triangleFillMode .lines
    case translucent(SIMD4<Float>)    // UnlitMaterial, blending .transparent(opacity:)
    case texture(URL)                 // UnlitMaterial(texture:) from a JPEG page
}
enum ViewerLayer: String, CaseIterable, Hashable, Sendable {
    case realistic, raw, rawInferred, cleanStructure, cleanOpenings, cleanFurniture, cleanFixtures, overlay
}
enum ViewerPickTag: Hashable, Sendable { case element(ElementID), rawMesh }
/// One drawable part: world-space triangles, per-vertex normals and uvs optional (empty or one per vertex).
struct ViewerPart: Sendable {
    var id: String; var positions: [SIMD3<Float>]; var normals: [SIMD3<Float>]; var uvs: [SIMD2<Float>]
    var indices: [UInt32]; var material: ViewerMaterial; var layer: ViewerLayer; var pickTag: ViewerPickTag?
    init(id: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [],
         indices: [UInt32], material: ViewerMaterial, layer: ViewerLayer, pickTag: ViewerPickTag? = nil)
}
struct ViewerContent: Sendable { var parts: [ViewerPart]; var bounds: AABB3; static let empty: ViewerContent; init(parts: [ViewerPart]) }
struct ViewerHit: Equatable, Sendable { var position: SIMD3<Float>; var normal: SIMD3<Float>; var partID: String; var triangle: Int; var pickTag: ViewerPickTag? }

/// Pure builders, any queue.
enum ViewerContentBuilder {
    static let tileSize: Float = 2
    /// Face indices grouped by 2 m tile of their centroid.
    static func tiles(_ mesh: TriangleMesh, tileSize: Float) -> [[Int]]
    /// Raw Scan style: one part per (tile, class) with the palette color; Solid and Wireframe styles
    /// ignore classes. Faces with isInferred go to layer .rawInferred with the `inferredColor`.
    static func meshParts(_ mesh: MeshWithAttributes, style: ViewerDisplayStyle, palette: [UInt8: SIMD4<Float>],
                          inferredColor: SIMD4<Float>, layer: ViewerLayer, idPrefix: String) -> [ViewerPart]
    /// Box of a detected object (12 triangles, translucent fill plus a wireframe copy).
    static func boxParts(_ box: OrientedBox, color: SIMD4<Float>, layer: ViewerLayer, pickTag: ViewerPickTag?, id: String) -> [ViewerPart]
    /// Un-indexes a part when uvs are per corner (texture atlases).
    static func expandCorners(positions: [SIMD3<Float>], indices: [UInt32], cornerUVs: [SIMD2<Float>]) -> (positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])
}

/// Main actor. Owns the ARView scene, camera and picking structures.
@MainActor final class ViewerModel: ObservableObject {
    @Published private(set) var isLoading: Bool
    @Published private(set) var cameraRevision: Int     // bumps on every camera change (for label overlays)
    init()
    /// Replaces the scene. Uploads parts in batches of 16 with `await Task.yield()` between batches;
    /// builds a MeshBVH per pickable part off main.
    func load(_ content: ViewerContent) async
    func setVisible(_ layer: ViewerLayer, _ visible: Bool)
    func frameAll()
    func resetView()
    func hitTest(_ point: CGPoint) -> ViewerHit?
    func project(_ world: SIMD3<Float>) -> CGPoint?
    func snapshotJPEG(maxPixel: Int) async -> Data?
}
/// UIViewRepresentable around ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false).
/// One-finger drag orbits (yaw, pitch clamped to 5...85 degrees), two-finger drag pans, pinch dollies,
/// double tap frames all, single tap calls `onTap` with `model.hitTest`.
struct ViewerContainer: UIViewRepresentable {
    init(model: ViewerModel, background: UIColor, onTap: ((ViewerHit?) -> Void)? = nil)
}
enum ViewerDiagnostics {
    /// Numbered 8 x 8 checkerboard quad (texture written to a temporary JPEG) to confirm the UV V origin on device.
    static func uvCheckerContent() throws -> ViewerContent
}
/// Pure orbit camera math (ViewerOrbitCamera.swift), any queue.
enum ViewerOrbitMath {
    /// Camera-to-world matrix at `eye` looking at `target` with world +Y up (camera looks down -Z).
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4
    /// Eye position for yaw and pitch (radians, pitch clamped to 5...85 degrees) at `distance` from `target`.
    static func eye(target: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float) -> SIMD3<Float>
    /// Target and distance that frame `bounds` for a vertical field of view in degrees.
    static func framing(_ bounds: AABB3, fieldOfViewDegrees: Float) -> (target: SIMD3<Float>, distance: Float)
}
```
Rendering rules: one `ModelEntity` per `ViewerPart`, each with its own `LowLevelMesh` and exactly one `LowLevelMesh.Part` (indexOffset 0), so no multi-part offsets are needed; interleaved vertex layout position `.float3` offset 0, normal `.float3` offset 12, uv0 `.float2` offset 24, stride 32 (normals computed with `TriangleMesh.vertexNormals` when absent, uv zero when absent); `UInt32` indices; every material has `faceCulling = .none` (LiDAR winding is inconsistent); entities of one layer share a parent entity whose `isEnabled` toggles the layer; camera is a `PerspectiveCamera` under `AnchorEntity(world: .zero)` whose pose is set by assigning `camera.transform = Transform(matrix: ViewerOrbitMath.lookAt(eye:target:))` (entity `transform`, iOS 13, not in RESEARCH; `look(at:from:relativeTo:)` is not used); textures are loaded with ImageIO (`CGImageSourceCreateWithURL`, `CGImageSourceCreateImageAtIndex`) and `TextureResource(image:withName:options:)` with semantic `.color`; picking uses `arView.ray(through:)` then `MeshBVH.raycast` over pickable parts (nearest hit); `Scene.raycast` with static-mesh `CollisionComponent`s (RESEARCH 3.5 recommended 6) is not used because the CPU BVH gives the triangle directly without async shape generation. Performance target: 300k triangles in about 150 parts at 30 fps or better on the A15; parts are built off main, only the memory copy into the `LowLevelMesh` runs on main.

**Uses.** Core: `ElementID`. Geometry: `TriangleMesh` (`vertexNormals`, `boundingBox`), `AABB3`, `OrientedBox` (`corners`), `MeshBVH`, `Ray`. MeshProcessing: `MeshWithAttributes`. Support: `Copy.A11y.modelViewer`, `Copy.A11y.modelViewerHint`, `LogStore`.

**Apple APIs** (RESEARCH 3.5):
```swift
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)
var environment: ARView.Environment; static func color(_ color: ARView.Environment.Color) -> ARView.Environment.Background
@MainActor @preconcurrency func project(_ point: SIMD3<Float>) -> CGPoint?
@MainActor @preconcurrency func ray(through screenPoint: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?
@MainActor @preconcurrency func snapshot(saveToHDR: Bool, completion: @escaping (ARView.Image?) -> Void)
@MainActor init(descriptor: LowLevelMesh.Descriptor) throws
// Descriptor(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType: .uint32)
// Attribute(semantic: .position/.normal/.uv0, format: .float3/.float2, layoutIndex: 0, offset:)
// Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: 32)
// Part(indexOffset: 0, indexCount:, topology: .triangle, materialIndex: 0, bounds: BoundingBox)
var parts: LowLevelMesh.PartsCollection { get set }                         // replaceAll(_:)
@MainActor func withUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)
@MainActor func withUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)
@MainActor @preconcurrency convenience init(from mesh: LowLevelMesh) async throws   // MeshResource: always `try await`
var triangleFillMode: UnlitMaterial.TriangleFillMode { get set }             // .lines, iOS 18.0
var faceCulling: UnlitMaterial.FaceCulling { get set }                       // .none, iOS 18.0
init(texture: TextureResource)                                               // UnlitMaterial, iOS 18.0
var blending: UnlitMaterial.Blending                                         // .transparent(opacity:)
@MainActor @preconcurrency convenience init(image cgImage: CGImage, withName resourceName: String? = nil, options: TextureResource.CreateOptions) async throws
init(semantic: TextureResource.Semantic?, mipmapsMode: TextureResource.MipmapsMode = .allocateAndGenerateAll)   // CreateOptions, use .color
@MainActor @preconcurrency var isEnabled: Bool { get set }                   // Entity
```

**Must NOT do.** No `ARView(frame:cameraMode:)` 2-argument init; no `Descriptor.allowsPrimitiveRestart`, `instanceCapacity` or the 6-argument Descriptor init (iOS 27); no `MeshResource.generateAsync`; no `UnlitMaterial.baseColor`; no CustomMaterial, ShaderGraphMaterial or `.metal` files in build 4; no `realityViewCameraControls`; no SceneKit; no per-frame mesh regeneration; never flip UVs (bottom-left everywhere); never run ARKit sessions (nonAR only).

**Copy strings.** Existing only: `Copy.A11y.modelViewer`, `modelViewerHint`, `Copy.Viewer.resetView`.

**Self-test.** `Viewer3DSelfTest.run()`, at least 20 checks on the pure builders (no ARView): tiles of a 6 x 1 x 1 m strip give 3 tiles; `meshParts` in Raw Scan style for a mesh with 3 classes in one tile gives 3 parts whose colors match the palette and whose index counts sum to the input; Solid style gives one part per tile; inferred faces go to `.rawInferred`; `boxParts` gives 12 triangles plus a wireframe part; `expandCorners` of 2 faces gives 6 vertices and indices 0...5 with uvs in order; `ViewerContent(parts:)` bounds equal the union of positions; the interleaved packer (`static func pack(_ part: ViewerPart) -> Data` in ViewerRenderMesh.swift, internal but testable) writes 32 bytes per vertex with normal at offset 12 and uv at offset 24; zero normals are replaced by computed normals; empty parts are skipped; `ViewerOrbitMath.lookAt` maps the camera's -Z axis onto the direction to the target and keeps +Y up within 1e-5; `eye` clamps pitch to 85 degrees; `framing` of a 4 x 2.5 x 5 m box puts the whole box inside a 60 degree view.

**Acceptance checks.** Every RealityKit call is on the main actor; `MeshResource(from:)` is awaited; all materials set `faceCulling = .none`; picking never needs collision components; `load` cancels an in-flight load when called again; label overlays use `project` and `cameraRevision`.

**SPEC owned.** "IMAGE / TEXTURE CAPTURE" display modes (TEXTURED, SOLID COLOR, WIREFRAME, RAW MESH; PHOTO REALISTIC in build 6); "ROOM SCANNING" (switching views, rendering side); "FURNITURE REMOVAL" (Hide Furniture as layer visibility); "3D EDITING" ("Allow users to tap objects", picking side).

### 3.18 GuidanceUI

**Purpose.** The live guidance banner and the adapters that feed Coverage's `GuidanceEngine` from Apple signals: tracking mapping, RoomPlan coaching suppression (D15, RESEARCH ruling 1, 3.10 gotcha 6 and 3.8 gotcha 23), Object Capture feedback mapping (used in build 5), VoiceOver announcements and tier 1 haptics with cooldown and the user's Haptics setting.

**Build and wave.** Build 4, wave 4a. Core, Coverage, Support; SwiftUI, ARKit, RoomPlan, RealityKit (enum mapping only).

**Files.** `ios/Sources/GuidanceUI/GuidanceSignals.swift`, `GuidanceFilter.swift`, `GuidanceBanner.swift`, `GuidanceAnnouncer.swift`, `GuidanceUISelfTest.swift`.

**Public Swift API.**
```swift
extension SettingsKey { static let guidanceHaptics = "guidanceHaptics" }   // Bool, absent means on

enum GuidanceSignals {
    static func tracking(_ summary: TrackingSummary) -> GuidanceTracking
    static func tracking(_ state: ARCamera.TrackingState) -> GuidanceTracking
    /// True for every Instruction except .normal (RoomPlan is coaching).
    static func isCoaching(_ instruction: RoomCaptureSession.Instruction) -> Bool
    /// Stable log names ("normal", "moveCloseToWall", ...) for RoomCaptureLog.instructionSeconds.
    static func name(of instruction: RoomCaptureSession.Instruction) -> String
    /// movingTooFast -> moveSlower, objectTooClose -> tooClose, objectTooFar -> tooFar,
    /// environmentTooDark and environmentLowLight -> lightingPoor, outOfFieldOfView -> objectKeepInView;
    /// others nil. Highest-priority mapped case wins.
    static func guidance(for feedback: Set<ObjectCaptureSession.Feedback>) -> GuidanceKind?
}
/// Room mode with RoomCaptureView: while RoomPlan coaches, only deviceHot and trackingLost pass
/// (RoomPlan cannot say those); otherwise everything passes.
struct GuidanceFilter: Equatable, Sendable {
    static let alwaysAllowed: Set<GuidanceKind> = [.deviceHot, .trackingLost]
    var roomPlanCoaching: Bool
    init(roomPlanCoaching: Bool = false)
    func filter(_ output: GuidanceOutput) -> GuidanceOutput
}
/// Pill banner, top center: bold white text on a translucent dark capsule; animates in and out;
/// shows `kind.message.text`; hidden when nil. Clamped to .xxxLarge Dynamic Type.
struct GuidanceBanner: View { init(kind: GuidanceKind?) }
/// Main actor. Announces each newly shown message (tier 1 with high priority) and fires
/// `Haptics.warning()` for newly shown tier 1 messages at most every GuidancePolicy.hapticCooldownSeconds,
/// only when the setting is on.
@MainActor final class GuidanceAnnouncer: ObservableObject {
    init(defaults: UserDefaults = .standard)
    func present(_ kind: GuidanceKind?, now: Double)
    /// Pure decision used by `present` and the self-test.
    static func shouldFireHaptic(kind: GuidanceKind, now: Double, lastHaptic: Double?, enabled: Bool) -> Bool
}
```

**Uses.** Core: `TrackingSummary`. Coverage: `GuidanceTracking`, `GuidanceOutput`. Support: `GuidanceKind` (`message`), `GuidancePolicy.hapticCooldownSeconds`, `Haptics.warning()`, `SettingsKey`.

**Apple APIs.** `ARCamera.TrackingState { case notAvailable; case limited(ARCamera.TrackingState.Reason); case normal }` with Reason `initializing, relocalizing, excessiveMotion, insufficientFeatures`; `RoomCaptureSession.Instruction` cases `normal, moveCloseToWall, moveAwayFromWall, turnOnLight, slowDown, lowTexture` (not CaseIterable); `ObjectCaptureSession.Feedback` cases `environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected, objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing` (no `outOfRange`); `UIAccessibility.post(notification: .announcement, argument:)` with `NSAttributedString` key `.accessibilitySpeechAnnouncementPriority` (`.high` for tier 1) (not in RESEARCH; iOS 3 and iOS 11). Every switch has `@unknown default`.

**Must NOT do.** Never duplicate RoomPlan's coaching text (RESEARCH 3.10 gotcha 6); never show more than one message; never hardcode text; never use `UIImpactFeedbackGenerator(style:)` directly (use `Haptics`); no timing logic of its own beyond the haptic cooldown (the engine owns display rules).

**Copy strings.** Existing only: `Copy.Guidance.all` through `GuidanceKind.message`.

**Self-test.** `GuidanceUISelfTest.run()`, at least 15 checks: tracking mappings for all `TrackingSummary` cases; `GuidanceFilter` passes `.deviceHot` and `.trackingLost` while coaching and drops `.moveSlower`, `.doorDetected`, `.scanCeiling`; passes all when not coaching; `shouldFireHaptic` false for tier 2, false within 5 s of the last, false when disabled, true otherwise; feedback mapping for a set containing movingTooFast and objectTooFar returns moveSlower (higher priority); empty set returns nil; `name(of:)` distinct for all six instructions.

**Acceptance checks.** The banner reads only `Copy`; the announcer is the only place that posts announcements and guidance haptics; mapping functions are total with `@unknown default`.

**SPEC owned.** "LIVE SCANNING EXPERIENCE" (messages "Move slower", "Tracking quality is low", "Lighting is poor", "Too close", "Too far", detection messages, "Do not overwhelm the user. Only show important instructions.").

---

## Build 4, wave 4b

### 3.19 MeshRecord

**Purpose.** Records the raw LiDAR mesh (Representation A) during ARKit captures: the latest anchor-local copy of every `ARMeshAnchor` (D8), dirty anchors flushed to `mesh/<anchor>.mchk` every 3 s and once at the end, removed anchors kept (marked stale), memory eviction after a room's final flush (D17), and live counters.

**Build and wave.** Build 4, wave 4b. Core, Geometry, CaptureCore, Store, Support; ARKit.

**Files.** `ios/Sources/MeshRecord/MeshStore.swift`, `MeshRecordFlush.swift`, `MeshRecordSelfTest.swift`.

**Public Swift API.** Everything runs on the hub queue unless noted.
```swift
struct MeshChunkIndexEntry: Equatable, Sendable {
    var anchorID: UUID; var updateCount: UInt32; var faceCount: Int; var vertexCount: Int
    var boundsMin: SIMD3<Float>; var boundsMax: SIMD3<Float>   // world space
    var isStale: Bool; var isDirty: Bool; var isEvicted: Bool
}
final class MeshStore: ScanRecorder {
    static let flushInterval: TimeInterval = 3
    init()
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)           // checks the flush timer
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor])          // ARMeshAnchor only
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor])       // marks stale, keeps data and file
    func finishRecording(completion: @escaping () -> Void)             // final flush of every dirty anchor
    var stats: RecorderStats { get }                                   // meshAnchors, meshFaces, writeFailures
    private(set) var index: [UUID: MeshChunkIndexEntry]
    /// Copies of the live chunks (build 5 CoverageLive); empty after eviction.
    func currentChunks() -> [MeshChunk]
    /// D17: after finish, drop geometry from RAM; keep the index.
    func evict()
    /// Resident geometry bytes (logged per room).
    var residentBytes: Int { get }
}
```
Flush writes each dirty chunk with `RawScanWriter.writeFile(MeshChunkFile.encode(chunk), to: folder.meshChunkURL(anchor:))` (atomic replace, latest version per anchor). Encoding happens inside `RawScanWriter.perform` on the io queue, not on the hub queue.

**Uses.** CaptureCore: `ScanRecorder`, `ARSessionHub`, `ScanProfile`, `RecorderStats`, `MeshAnchorCopier.copy(_:updateCount:)`. Store: `RawScanWriter` (`perform`, `writeFile`, `flush`, `failureCount`). Core: `MeshChunk`, `MeshChunkFile.encode`, `RawScanFolder.meshChunkURL(anchor:)`. Geometry: `AABB3`. Support: `LogStore`.

**Apple APIs.** `class ARMeshAnchor : ARAnchor { var geometry: ARMeshGeometry { get } }`, `identifier: UUID`, `transform: simd_float4x4` (RESEARCH 3.1). Anchors arrive through `ARSessionHub`.

**Must NOT do.** Never keep an `ARMeshAnchor` or its buffers past the call; never delete a chunk or its file on `didRemove` (RESEARCH 3.1 gotcha 15); never write world-space positions to raw (D8); never write after `finishRecording` completed.

**Copy strings.** None.

**Self-test.** `MeshRecordSelfTest.run()`, at least 12 checks with a fake folder and synthetic `MeshChunk` values fed through an internal `ingest(_ chunk: MeshChunk)` entry point (the ARKit path is covered on device): ingest marks dirty and counts faces; a second ingest of the same anchor replaces it and bumps updateCount; `flushDue(now:)` true after 3 s; flush writes one `.mchk` per dirty anchor and clears dirty; a stale anchor keeps its file; finish flushes remaining dirty chunks; `evict` empties `currentChunks` and keeps index entries; bounds are world space (transform applied).

**Acceptance checks.** No ARKit object escapes the call; flush work is on the io queue; the final flush completes before `completion`; memory log line per room with `residentBytes` and `MemoryProbe.availableBytes()`.

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation A ("LiDAR mesh", "ARKit anchors", "world transforms"); "ROOM SCANNING" ("Use ARKit LiDAR mesh data in parallel").

### 3.20 Keyframes

**Purpose.** Records the camera side of Representation A during ARKit captures: motion-gated texture keyframes (JPEG plus Float16 depth plus confidence plus pose and intrinsics, D6, D7) through a pooled frame copier so no encoding happens on the delegate queue, the 10 Hz binary pose track (D8), and user "Take Photo" pins.

**Build and wave.** Build 4, wave 4b. Core, CaptureCore, Store, Texturing (`KeyframeSelector`), Export (`ByteWriter`), Support; ARKit, CoreImage, CoreVideo.

**Files.** `ios/Sources/Keyframes/KeyframeRecorder.swift`, `KeyframeFrameCopier.swift`, `KeyframeEncoding.swift`, `PoseTrackRecorder.swift`, `PhotoRecorder.swift`, `KeyframesSelfTest.swift`.

**Public Swift API.** Recorder callbacks run on the hub queue.
```swift
/// 4 preallocated bi-planar buffers the size and pixel format of the first capturedImage (D7),
/// created once with CVPixelBufferCreate and handed out from a lock-protected free list.
/// Thread-safe: `copy` runs on the hub queue, `release` on the io queue.
final class FrameCopier {
    init(width: Int, height: Int, pixelFormat: OSType, count: Int = 4)
    /// Copies both planes row by row (honoring each plane's bytes per row); nil when all buffers
    /// are in use (the keyframe is skipped and counted).
    func copy(_ image: CVPixelBuffer) -> CVPixelBuffer?
    /// Returns a buffer to the free list after its JPEG is written.
    func release(_ buffer: CVPixelBuffer)
    /// Buffers currently handed out (0...count).
    var inUse: Int { get }
}
final class KeyframeRecorder: ScanRecorder {
    init(jpegQuality: Double = 0.85)
    /// Gate: KeyframeSelector with Config.maxTranslation = settings.keyframeGate.meters,
    /// maxRotationDegrees = settings.keyframeGate.degrees, maxAngularVelocity 1.0, maxKeyframes Int.max
    /// (never thin afterwards, D6); frames only when tracking is .normal, storage state is .ok and
    /// the thermal policy's keyframeIntervalScale allows it.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    func finishRecording(completion: @escaping () -> Void)
    var stats: RecorderStats { get }                 // keyframes, skippedKeyframes, writeFailures
}
final class PoseTrackRecorder: ScanRecorder {
    static let sampleInterval: TimeInterval = 0.1    // 10 Hz
    init()
    // writes the PTRK header at begin, buffers records, appends every 1 s and at finish
}
final class PhotoRecorder: ScanRecorder {
    init()
    /// Any thread. The next frame with normal tracking is saved as photos/<id>.jpg plus a photos.jsonl line.
    func requestPhoto(note: String = "")
    /// Called on main after the photo file is written.
    var onPhotoSaved: ((UUID) -> Void)?
}
```
Per accepted keyframe inside the callback: `FrameCopier.copy(frame.capturedImage)`, `ARFrameReading.depthMap(of:)`, `ARFrameReading.intrinsics(of:)`, `frame.camera.transform`, `exposureDuration`, `exposureOffset`, `ambientIntensity`, angular speed; then on the io queue (`RawScanWriter.perform`): `CIImage(cvPixelBuffer:)` into one shared `CIContext`'s `writeJPEGRepresentation(of:to:colorSpace:options:)` (iOS 10, RESEARCH 3.9) at `keyframes/NNNNN.jpg` with the option `CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)` 0.85, then `FrameCopier.release`, `DepthFile.encode(width:height:depth:confidence:)` at `depth/NNNNN.dpth`, and only after both succeed one `KeyframeRecord` line in keyframes.jsonl (so the log never points to a missing file). Pose samples use `TrackingMonitor.poseCode`, `ThermalLevel` index as the thermal code and `exposureDuration`.

**Uses.** CaptureCore: `ScanRecorder`, `ARSessionHub` (`status`, `thermal.policy`, `storage.state`, `tracking`), `ARFrameReading`, `TrackingMonitor.poseCode`, `RecorderStats`, `ScanProfile`. Store: `RawScanWriter`. Core: `KeyframeRecord`, `PhotoPin`, `PoseSample`, `PoseTrackFile.appendHeader`, `PoseTrackFile.append`, `DepthFile.encode`, `RawScanFolder.keyframeImagePath`, `depthPath`, `photoPath`, `keyframesLogURL`, `photosLogURL`, `poseTrackURL`, `Transform4`, `Intrinsics`, `ScanSettings.keyframeGate`. Export: `ByteWriter` (pose records). Texturing: `KeyframeSelector`, `KeyframeSelector.Config`, `KeyframeSelector.Decision`. Support: `LogStore`.

**Apple APIs.** `var capturedImage: CVPixelBuffer { get }` ('420f' bi-planar YCbCr, landscape), `var timestamp: TimeInterval`, `var camera: ARCamera` (`transform`, `intrinsics`, `imageResolution`, `trackingState`, `exposureDuration`, `exposureOffset`), `var lightEstimate: ARLightEstimate?` (RESEARCH 3.1, 3.8); CoreVideo (not in RESEARCH, all iOS 4) `CVPixelBufferCreate`, `CVPixelBufferGetPixelFormatType`, `CVPixelBufferLockBaseAddress`, `CVPixelBufferUnlockBaseAddress`, `CVPixelBufferGetBaseAddressOfPlane`, `CVPixelBufferGetBytesPerRowOfPlane`, `CVPixelBufferGetHeightOfPlane`, `CVPixelBufferGetWidthOfPlane`; CoreImage `CIImage(cvPixelBuffer:)`, `CIContext.writeJPEGRepresentation(of:to:colorSpace:options:)` (iOS 10, RESEARCH 3.9).

**Must NOT do.** Never encode JPEG or write files on the hub queue; never queue unbounded work (skip when the pool is exhausted, RESEARCH 3.4); never retain the ARFrame or `capturedImage`; never use `captureHighResolutionFrame` in build 4 (RESEARCH ruling 5); never delete or thin keyframes after capture (D6); never write a keyframes.jsonl line before its files exist.

**Copy strings.** None (the Take Photo button and "Photo saved to this spot" live in ScanUI).

**Self-test.** `KeyframesSelfTest.run()`, at least 15 checks: `FrameCopier` with count 2 returns 2 buffers then nil, and a buffer again after one is released; copied planes equal the source bytes for a synthetic 64 x 48 420f buffer (created with `CVPixelBufferCreate`); the gate configured from Standard settings accepts a 0.35 m move and rejects 0.1 m; Keep all photos off scales the gate by 1.5; pose track bytes for 3 samples decode with `PoseTrackFile.decode` to the same samples; the JSONL line for a keyframe decodes to the same `KeyframeRecord`; the photo request flag is consumed exactly once; JPEG encode of a synthetic buffer produces data starting with FF D8.

**Acceptance checks.** Pool size 4; skipped keyframes counted and logged per minute; the io queue is the Store queue; all three recorders tolerate `finishRecording` before any frame.

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation A ("camera poses", "camera frames where permitted", "depth information", "confidence information", "timestamps", "device orientation", "calibration information"); "IMAGE / TEXTURE CAPTURE" ("Capture camera imagery and associate images with camera poses", "Preserve original image quality where practical"); deliverable 12 "Images/photos associated with scanned locations" (capture side).

### 3.21 RoomCapture

**Purpose.** The Room scan engine (D1, D15): `RoomCaptureView(frame:arSession:)` with Apple's coaching, outlines and detection on the app-owned `ARSession` of CaptureCore, recorders plugged in through `ScanRecorder`, the exact order of operations that keeps mesh and depth alive, per-room persistence of RoomPlan data, sealing the room folder, live snapshots with filtered guidance, error mapping, and hooks for build 5 (live room, guidance and snapshot augmenters; next room on the same session).

**Build and wave.** Build 4, wave 4b. Core, CaptureCore, Store, RoomModel (RoomInput for the live hook), GuidanceUI, Coverage (GuidanceEngine), Support; ARKit, RoomPlan, SwiftUI.

**Files.** `ios/Sources/RoomCapture/RoomScanEngine.swift`, `RoomScanEngine+Lifecycle.swift`, `RoomCaptureController.swift`, `RoomCaptureContainer.swift`, `RoomScanPersistence.swift`, `RoomScanStats.swift`, `RoomCaptureSelfTest.swift`, `ios/Sources/Support/Copy+RoomCapture.swift`.

**Public Swift API.**
```swift
struct RoomScanTarget: Equatable, Sendable {
    var projectID: UUID; var package: ProjectPackage; var sessionID: UUID; var roomID: UUID
    var mode: ScanMode; var settings: ScanSettings
}
struct RoomScanResult: Equatable, Sendable {
    var roomID: UUID; var sealedFolder: RawScanFolder; var capturedRoomID: UUID?
    var log: RoomCaptureLog; var keyframeCount: Int; var photoCount: Int; var frameLink: FrameLink; var capturedAt: Date
}
/// Room engine. Call ScanEngine methods on main; work runs on hub.queue; events arrive on main.
final class RoomScanEngine: NSObject, ScanEngine {
    private(set) var state: ScanEngineState
    var onEvent: ((ScanEngineEvent) -> Void)?
    let hub: ARSessionHub
    @MainActor init(target: RoomScanTarget, recorders: [ScanRecorder])
    /// Main. Creates the view once (later calls return the same instance): hub.install(), hub.run(),
    /// RoomCaptureView(frame: .zero, arSession: hub.session), captureSession.delegate = controller,
    /// delegate = controller, and stores `view.captureSession` in a private `RoomCaptureSession`
    /// property. The ScanEngine methods below are nonisolated, so they use that stored session and
    /// never touch the main-actor `RoomCaptureView`. Starts capture if start() was already called.
    @MainActor func makeCaptureView() -> RoomCaptureView
    /// Main. Checks RoomCaptureSession.isSupported (else .unsupportedDevice) and free space (else
    /// .lowStorage); creates the InProgress folder (kind .room); attaches and begins recorders; when the view already exists, runs
    /// captureSession.run(configuration:) with isCoachingEnabled true.
    func start() throws
    /// Main. Marks paused (RoomPlan has no pause; the room keeps scanning after resume). Used for interruptions.
    func pause()
    func resume()
    /// Main. captureSession.stop(pauseARSession: false); persistence and sealing follow; then
    /// .roomFinished(roomID:) with `lastResult` set. The ARSession keeps running (D19).
    func finish()
    /// Main. Stops RoomPlan and pauses the session; raw data stays in InProgress for recovery.
    func cancel()
    /// Main. After the quality sheet: pauses the ARSession, detaches recorders, releases the view.
    func close()
    /// Main. Stops RoomPlan (`stop(pauseARSession: true)`) and recorders without sealing when a
    /// capture is still running; does nothing otherwise. Raw data stays in InProgress.
    func stopIfRunning()
    /// Main (build 5 House): same view and session, new InProgress folder, recorders begin again.
    func startNextRoom(roomID: UUID) throws
    /// Main. Valid after .roomFinished.
    private(set) var lastResult: RoomScanResult?
    /// Hub queue hooks for build 5 (CoverageLive, House). All optional.
    var liveRoomHandler: ((RoomInput) -> Void)?                     // at most 1 Hz
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)?
    var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)?
}
/// Delegates of RoomCaptureSession and RoomCaptureView (NSCoding stubs required).
final class RoomCaptureController: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate {
    override init()
    required init?(coder: NSCoder)
    func encode(with coder: NSCoder)
    // RoomCaptureSessionDelegate and RoomCaptureViewDelegate methods, verbatim below; each forwards
    // value copies to the engine on hub.queue.
}
/// SwiftUI host. makeUIView calls engine.makeCaptureView(); updateUIView does nothing;
/// dismantleUIView calls engine.stopIfRunning() (RESEARCH 3.10 gotcha 4); normal flows have
/// already called finish(), cancel() or close().
struct RoomCaptureContainer: UIViewRepresentable { init(engine: RoomScanEngine) }
/// Pure helpers (tested).
enum RoomScanStats {
    static func mapError(_ error: any Error) -> MapperError
    static func counts(_ input: RoomInput) -> (walls: Int, doors: Int, windows: Int, openings: Int, objects: Int)
    /// Adds elapsed time to the current instruction bucket.
    static func accumulate(_ seconds: inout [String: Double], instruction: String, delta: Double)
    /// Room mode input: tracking, deviceHot (thermal serious or worse) and the new detection
    /// counts only. angularSpeed stays 0 and centerDistance, ambientIntensity and
    /// depthConfidenceMean stay nil, so moveSlower, tooClose, tooFar, moveCloser and
    /// lightingPoor never fire over RoomPlan's own coaching (RESEARCH 3.10 gotcha 6, 3.8 gotcha 23).
    static func guidanceInput(time: Double, status: HubStatus, newDoors: Int, newWindows: Int, newWalls: Int) -> GuidanceInput
    static func next(_ state: ScanEngineState, on signal: RoomEngineSignal) -> ScanEngineState
}
enum RoomEngineSignal: Equatable, Sendable { case start, didStart, pause, resume, finish, sealed, failure, cancel }
```
If CI reports an actor-isolation error on the `RoomCaptureViewDelegate` conformance, move that conformance (with the NSCoding stubs) to a separate `@MainActor final class RoomCaptureViewDelegateBridge: NSObject, RoomCaptureViewDelegate` and keep `RoomCaptureSessionDelegate` on the nonisolated controller. Order of operations (RESEARCH 3.1 recommended 3, 3.2 recommended 2 to 5, ship-first 3.1): hub.install (delegate and delegateQueue first), hub.run, create RoomCaptureView with the same session, set both delegates, `run(configuration:)`; in `captureSession(_:didStartWith:)` hop to `hub.queue`, call `hub.markScanStart`, log the effective configuration (`hub.diagnostics.logConfiguration(hub.session.configuration, label:)`) now and again 1 s and 5 s later, and log whether `session.delegate === hub`. There is no unconditional re-apply here: on the `RoomCaptureView(frame:arSession:)` path RoomPlan preserves the session's settings, so only the hub watchdog re-applies the configuration, and only when depth or mesh is missing (RESEARCH ruling 1, D22). Each tick (4 Hz, hub queue) builds a `LiveScanSnapshot` from `hub.status`, recorder stats and live counts, runs `GuidanceEngine.update` on `RoomScanStats.guidanceInput(...)` plus `guidanceAugmenter`, filters through `GuidanceFilter(roomPlanCoaching:)`, applies `snapshotAugmenter`, and posts `.snapshot` on main. Interruptions: `sessionWasInterrupted` (through `hub.onCaptureEvent`) sets state `.paused` and emits `.stateChanged(.paused)`; `sessionInterruptionEnded` returns to `.scanning`. On `didEndWith`: write `capturedroomdata.json` (plain `JSONEncoder`) through the writer; when `error` is nil or `CaptureError.exceedSceneSizeLimit` (keep the partial room, maps to `.sceneTooLarge`), run `RoomBuilder(options: [.beautifyObjects]).capturedRoom(from:)` in a `Task` and write `capturedroom.json`; any other error sets the log's degraded mode to `.roomPlanFailed` and is reported through `RoomScanStats.mapError`; write `roomlog.json`, `events.jsonl` lines (instructions, errors, tracking, thermal, degraded changes from `hub.onCaptureEvent`) and `raw/sessions/<s>/session.json` (first room of the session, from `hub.diagnostics.sessionRecord(id:)`); call `finishRecording` on every recorder; `RawScanWriter.flush`; `InProgressScans.seal(_:into: package.rawRoomURL(session:room:), package:)`; set `lastResult`; emit `.roomFinished`. A `RoomBuilder` failure still seals the room with `capturedroomdata.json` and no `capturedroom.json`; the error is logged and the pipeline's `BuildRoomStep` retries later. At thermal `.critical` or storage state `.pause` the engine calls `finish()` itself and, after `.roomFinished`, emits `.failed(.deviceTooHot)` or `.failed(.lowStorage(freeBytes:))`. Build 4 saves no `ARWorldMap` (HouseUI adds it in build 5).

**Uses.** CaptureCore: `ARSessionHub`, `ScanRecorder`, `ScanProfile`, `HubStatus`, `CaptureDiagnostics`, `ThermalLevel` policy. Store: `InProgressScans`, `InProgressScanInfo`, `RawScanWriter`. RoomModel: `RoomInput.init(_ room: CapturedRoom)`. GuidanceUI: `GuidanceSignals.isCoaching`, `GuidanceSignals.name(of:)`, `GuidanceSignals.tracking(_:)`, `GuidanceFilter`. Coverage: `GuidanceEngine`, `GuidanceInput`, `GuidanceOutput`. Core: `ScanEngine`, `ScanEngineState`, `ScanEngineEvent`, `LiveScanSnapshot`, `MapperError`, `RoomCaptureLog`, `DegradedMode`, `CaptureEvent`, `FrameLink`, `ProjectPackage`, `RawScanFolder`, `ProjectStore.freeBytes`, `ProjectStore.refuseScanBelowBytes`. Support: `LogStore`.

**Apple APIs** (RESEARCH 3.2 and 3.10, copy verbatim):
```swift
@MainActor @preconcurrency init(frame: CGRect, arSession: ARSession)                // RoomCaptureView, iOS 17.0
@MainActor @preconcurrency var captureSession: RoomCaptureSession! { get }         // never assign
@MainActor @preconcurrency weak var delegate: (any RoomCaptureViewDelegate)?
protocol RoomCaptureViewDelegate : NSCoding
func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool   // return false
func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?)
static var isSupported: Bool { get }                                                 // RoomCaptureSession
func run(configuration: RoomCaptureSession.Configuration)
func stop(pauseARSession: Bool = true)                                               // always pass false explicitly on Done
weak var delegate: (any RoomCaptureSessionDelegate)?
struct RoomCaptureSession.Configuration { init(); var isCoachingEnabled: Bool }       // keep true
func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration)
func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?)
enum RoomCaptureSession.CaptureError { deviceNotSupported, deviceTooHot, exceedSceneSizeLimit, invalidARConfiguration, worldTrackingFailure, internalError }
class RoomBuilder { init(options: RoomBuilder.ConfigurationOptions); func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom }
```

**Must NOT do.** Never use the headless `RoomCaptureSession` in build 4 (D15); never set `isCoachingEnabled = false`; never create a second `RoomCaptureView` on the same session (tracking loss, RESEARCH 3.2 disputed 3) and never recreate it in `updateUIView`; never return true from `shouldPresent`; never call `stop()` without `pauseARSession: false` on Done; never pass reset run options on re-apply and never re-apply in `didStartWith` unless the watchdog asks for it; never write `beautifyObjects` on the capture configuration; never use the last `didUpdate` room as final (use RoomBuilder output); never show a banner that duplicates RoomPlan's coaching; never mark the engine or controller `@MainActor` (only the listed members).

**Copy strings.** Existing: `Copy.Errors.tooHot`, `trackingFailed`, `interrupted`, `generic`. New (`extension Copy { enum RoomCapture }`): `sceneTooLarge = (title: "This room is too big for one scan", body: "Your scan so far is saved. Finish here and scan the rest as another room.")`, `roomPlanFailed = (title: "Walls couldn't be found", body: "Your scan is saved. The 3D scan and measurements still work, but there is no floor plan.")`.

**Self-test.** `RoomCaptureSelfTest.run()`, at least 15 checks on the pure parts: `mapError` for every `CaptureError` case and an unknown error; `counts` of a fixture RoomInput (2 doors, 1 window, 1 opening in `openings`); `accumulate` sums per instruction; `guidanceInput` copies tracking, deviceHot and detection counts from a `HubStatus` and leaves angularSpeed 0 and centerDistance, ambientIntensity and depthConfidenceMean nil even when the status has them; a snapshot built from fixed inputs has the expected counts, degraded mode and guidance raw value; `RoomScanStats.next` for start, didStart, pause, resume, finish, sealed, failure and cancel from each relevant state.

**Acceptance checks.** Delegate signatures match RESEARCH character for character; `hub.install()` precedes view creation; `stop(pauseARSession: false)` on Done; RoomPlan objects are touched only on main; every file write goes through `RawScanWriter`; the room folder is sealed before `.roomFinished`; `close()` pauses the ARSession; memory and thermal state logged at start and finish.

**SPEC owned.** "ROOM SCANNING" (all: RoomPlan where appropriate, ARKit mesh in parallel, not exclusively RoomPlan); "LIVE SCANNING EXPERIENCE" ("The user should see the model forming while walking" through RoomCaptureView outlines and mini model; "Window detected", "Door detected", "Wall detected", "Tracking quality is low", "Lighting is poor", "Move slower"); "SCANNING MODES" ROOM.

### 3.22 Quality

**Purpose.** The scan quality evaluation (SCAN QUALITY SYSTEM) for a finished room, computed from recorded data with Coverage's math: expected surfaces from the clean room outline, coverage integrated from the pose track (geometry) and keyframes (color and texture), wall scores weighted by RoomPlan confidence and completed edges, openings excluded from missing areas (D19), per-wall capture evidence for measurement confidence, persistence, and the `quality` step. Build 4 computes this at Done from the sealed folder; build 5 adds the live path.

**Build and wave.** Build 4, wave 4b. Core, Coverage, RoomModel, MeshModel, MeasureCore, Store, MeshProcessing, Support.

**Files.** `ios/Sources/Quality/QualityTypes.swift`, `QualityInputs.swift`, `QualityEvaluator.swift`, `QualityStore.swift`, `QualitySelfTest.swift`.

**Public Swift API.** Pure and nonisolated; `evaluateSealedRoom` does IO and must run off main (budget under 5 s for a 5-minute room on the A15).
```swift
struct MissingAreaRecord: Codable, Equatable, Identifiable, Sendable {
    var id: Int; var centroid: Vec3; var normal: Vec3; var area: Float
    var surface: UInt8                 // SurfaceClass raw value
    var suggestedViewpoint: Vec3
}
struct QualityEvaluation: Codable, Equatable, Sendable {
    var roomID: UUID
    var summary: QualitySummary        // 0...1 values and verdict (Core)
    var missingAreas: [MissingAreaRecord]
    var degraded: DegradedMode
    var evidence: RoomEvidence         // MeasureCore
    var inputHash: String              // InputHasher over the room seal
    var evaluatedAt: Date
}
enum QualityInputs {
    /// Plan outline (x, -z) back to Coverage's world (x, z); walls with base and height.
    static func boundary(for room: CleanRoom) -> CoverageRoomBoundary
    static func faces(_ mesh: MeshWithAttributes) -> [CoverageFace]
    /// Pose samples decimated to `hz` (default 2), trackingNormal = code 2; intrinsics from the
    /// nearest keyframe record (fallback: the first keyframe).
    static func observations(poses: [PoseSample], keyframes: [KeyframeRecord], hz: Double) -> [CoverageObservation]
    static func observations(keyframes: [KeyframeRecord]) -> [CoverageObservation]
}
enum QualityEvaluator {
    /// Tunables in one place (RESEARCH 3.8 disputed 13).
    static let edgeMissingFactor = 0.85, mediumConfidenceFactor = 0.7, lowConfidenceFactor = 0.5
    static func evaluate(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes,
                         geometryObservations: [CoverageObservation], textureObservations: [CoverageObservation],
                         log: RoomCaptureLog?, inputHash: String, now: Date) -> QualityEvaluation
    /// Reads the sealed folder (RawScanReader), builds the clean room with RoomModel (mesh nil) and
    /// MeshConsolidator.fastWorldMesh, then `evaluate`.
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation
}
enum QualityStore {
    static func url(_ package: ProjectPackage, room: UUID) -> URL          // derived/rooms/<r>/quality.json
    static func load(_ package: ProjectPackage, room: UUID) -> QualityEvaluation?
    /// Writes quality.json and sets RoomRecord.quality through ManifestWriter.
    static func save(_ evaluation: QualityEvaluation, package: ProjectPackage) throws
}
/// Re-evaluates with the consolidated mesh when quality.json is missing or its inputHash differs.
final class QualityStep: ProcessingStep { init(room: RoomRecord) }         // id .quality; budget 300 MB
```
Scores: walls = per-wall observed fraction of expected samples (Coverage `ExpectedSurfaces.evaluate`) after dropping samples inside that wall's doors, windows and openings, times 1.0 (4 completed edges and high confidence), `edgeMissingFactor`, `mediumConfidenceFactor` or `lowConfidenceFactor`, area-weighted; floor and ceiling from `ExpectedSurfacesResult.observedArea / expectedArea`; shape = area-weighted mean of the three; texture = `textureGrid.goodFaceAreaFraction(faces:)` where `textureGrid` integrates only keyframe observations; missing areas = Coverage clusters minus those whose centroid lies inside a window, door or opening; without a room (RoomPlan failed) Coverage's no-room path gives shape and texture and walls, floor and ceiling are reported as 0 with degraded `.roomPlanFailed`. Evidence per wall: median `bestDistance` and median `goodObservationCount` of the voxels at that wall's samples; tracking fraction = 1 - `RoomCaptureLog.limitedTrackingFraction`; relocalizations from the log. Percent values from Coverage (0...100) are divided by 100 for `QualitySummary`.

**Uses.** Coverage: `CoverageGrid`, `CoverageFace`, `CoverageObservation`, `CoverageRoomBoundary`, `CoverageWall`, `ExpectedSurfaces.evaluate`, `ExpectedSurfacesResult`, `ScanQuality.evaluate`, `SurfaceClass`, `MissingArea`. RoomModel: `CleanModelBuilder.buildRoom`, `CapturedRoomStore.loadInput`, `RoomInput`. MeshModel: `MeshConsolidator.fastWorldMesh`, `MeshModelStore.loadMeasured`. MeasureCore: `RoomEvidence`, `WallEvidence`. Store: `RawScanReader`, `ManifestWriter`. Core: `QualitySummary`, `QualityVerdict`, `CleanRoom`, `RoomRecord`, `RoomCaptureLog`, `DegradedMode`, `PoseSample`, `KeyframeRecord`, `InputHasher`, `SealFile`, `ProcessingStep`, `PlanAxes`, `Vec3`. MeshProcessing: `MeshWithAttributes`.

**Apple APIs.** None.

**Must NOT do.** Never treat `completedEdges` as a finish gate (soft factor only, RESEARCH 3.8 gotcha 3); never count windows and mirrors as missing (D19); never key coverage by face index across mesh versions (one evaluation uses one fixed face list); never block main; never write raw.

**Copy strings.** None (QualityUI owns the text).

**Self-test.** `QualitySelfTest.run()`, at least 20 checks using the Coverage prototype recipe (a 4 x 5 x 2.5 m room mesh at 0.2 m cells, camera circuit of 16 poses at 1.4 m height looking outward): all walls, floor and ceiling observed gives walls, floor and ceiling at least 0.9 and verdict good; removing the observations that see wall 2 lowers walls and adds a missing area on wall 2; a window rectangle on wall 2 removes that missing area; low confidence wall factor lowers the walls score by the expected ratio; texture score uses keyframes only (poses without keyframes give texture 0); boundary conversion flips z correctly (plan y 3 -> world z -3); evidence has one entry per wall with medianDistance about the circuit radius; decimation to 2 Hz of 10 Hz poses keeps one in five; no-room path sets degraded `.roomPlanFailed`; `QualityEvaluation` Codable round trip.

**Acceptance checks.** `evaluateSealedRoom` never runs RoomBuilder (reads capturedroom.json only); percent to fraction conversion in one place; the manifest update goes through `ManifestWriter`; timings logged.

**SPEC owned.** "SCAN QUALITY SYSTEM" ("Track coverage for surfaces and geometry"; Geometry, Walls, Floor, Ceiling, Textures, Missing areas values); "MEASUREMENT CONFIDENCE" (evidence input).

### 3.23 TextureJob

**Purpose.** Representation B in build 4: textures the room's viewer mesh with the recorded keyframes using Texturing's `TextureBaker` at the Textured density, persists atlas pages and per-corner UVs, and loads them for the viewer and exports. Photo Realistic density and exposure normalization are build 6 (same module, second revision).

**Build and wave.** Build 4, wave 4b (moves to 5a unchanged if it slips). Core, Texturing, MeshModel, MeshProcessing, Store, Export (`ByteWriter`), Support; ImageIO, CoreGraphics.

**Files.** `ios/Sources/TextureJob/TextureJobTypes.swift`, `TextureJobInputs.swift`, `TextureStore.swift`, `TextureLowStep.swift`, `TextureJobSelfTest.swift`.

**Public Swift API.**
```swift
enum TextureDensity: String, Codable, CaseIterable, Sendable {
    case textured, photoRealistic
    var options: TXOptions      // textured: atlasSize 2048, texelsPerMeter 100, maxAtlases 4, normalizeExposure false
}                               // photoRealistic (build 6): 4096, 250 to 500 by DetailLevel, 8, normalizeExposure true
struct TexturedMesh {
    var positions: [SIMD3<Float>]; var indices: [UInt32]
    var texcoords: [SIMD2<Float>]      // 3 per face, bottom-left origin
    var faceAtlas: [UInt16]; var pageURLs: [URL]; var coverage: Float
}
struct TexturedPagePart { var page: Int; var positions: [SIMD3<Float>]; var texcoords: [SIMD2<Float>]; var indices: [UInt32] }
extension TexturedMesh {
    /// Un-indexed per-page arrays (3 vertices per face) for Viewer3D and ExportMesh; untextured faces skipped.
    func pageParts() -> [TexturedPagePart]
}
enum KeyframeLoader {
    /// Lazily decoded CGImages (CGImageSourceCreateImageAtIndex, no cache) for keyframes with
    /// trackingNormal, evenly subsampled to at most `maxCount`.
    static func keyframes(in folder: RawScanFolder, maxCount: Int) throws -> [TXKeyframe]
}
enum TextureStore {
    static func folder(_ package: ProjectPackage, room: UUID) -> URL      // derived/rooms/<r>/texture/
    /// textured.mchk (the exact mesh baked), textured.tuv, page_<n>.jpg (JPEG q 0.85 via CGImageDestination)
    static func save(mesh: MeshWithAttributes, result: TXResult, package: ProjectPackage, room: UUID) throws
    static func load(_ package: ProjectPackage, room: UUID) throws -> TexturedMesh?
    static func exists(_ package: ProjectPackage, room: UUID) -> Bool
    /// "TUV1" format: magic, version UInt16 1, faceCount UInt32, pageCount UInt16, then per face
    /// atlas UInt16 and 3 x (Float32, Float32); little endian.
    static func encodeUV(texcoords: [SIMD2<Float>], faceAtlas: [UInt16], pageCount: Int) -> Data
    static func decodeUV(_ data: Data) throws -> (texcoords: [SIMD2<Float>], faceAtlas: [UInt16], pageCount: Int)
}
/// id .textureLow; optional; budget 600 MB, reduced 350 MB (150k-triangle mesh, 1024 atlases).
final class TextureLowStep: ProcessingStep { init(room: RoomRecord, folders: [RawScanFolder]) }
```
Step: load `MeshModelStore.loadView` (fallback: simplify measured to 200k), build `TXMesh(positions:indices:)`, load up to 150 keyframes, run `TextureBaker(options:).bake(mesh:keyframes:progress:)` forwarding progress to `ctx.progress`, check `ctx.isCancelled` through `baker.cancel()` from a watcher, write pages immediately as JPEG, save UVs and the mesh. `TXError.noKeyframes` completes with no files (Realistic shows the fallback).

**Uses.** Texturing: `TextureBaker`, `TXOptions`, `TXMesh`, `TXKeyframe`, `TXResult`, `TXError`. MeshModel: `MeshModelStore.loadView`, `loadMeasured`, `chunk(from:id:)`, `mesh(from:)`. MeshProcessing: `MeshSimplify`, `MeshWithAttributes`. Store: `RawScanReader.keyframes()`. Core: `KeyframeRecord`, `RawScanFolder.resolve`, `MeshChunkFile`, `ProcessingStep`, `StepContext`, `InputHasher`, `ProjectStore`, `CoreByteReader`. Export: `ByteWriter`. Support: `LogStore`.

**Apple APIs.** ImageIO (not in RESEARCH, iOS 4 or earlier) `CGImageSourceCreateWithURL`, `CGImageSourceCreateImageAtIndex` (options `kCGImageSourceShouldCache: false`), `CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)`, `CGImageDestinationAddImage` with `kCGImageDestinationLossyCompressionQuality`, `CGImageDestinationFinalize`.

**Must NOT do.** No Metal; no hi-res stills; never decode all keyframes up front; never flip UVs; never texture the full-resolution measured mesh in build 4 (viewer mesh only); never hold finished atlas CGImages after writing them.

**Copy strings.** None (Results shows `Copy.Processing.stepTextures` and `Copy.Errors.textureFailed`).

**Self-test.** `TextureJobSelfTest.run()`, at least 12 checks: `encodeUV`/`decodeUV` round trip; corrupt UV data throws; `pageParts` of 3 faces on 2 pages returns 2 parts with 6 and 3 vertices and texcoords in corner order; untextured faces (source -1) are skipped; `TextureDensity.textured.options` values; `KeyframeLoader` subsampling picks evenly spaced indices (pure helper `static func subsample(count:max:) -> [Int]`); save then load round trip with a tiny synthetic TXResult (2 x 2 atlas CGImage) in a temp package.

**Acceptance checks.** Peak memory logged; pages written one at a time; the step is marked optional by AppShell; outputs only under `derived/rooms/<r>/texture/`.

**SPEC owned.** "IMAGE / TEXTURE CAPTURE" ("Use those images to texture the reconstructed mesh", "overlapping images", "perspective differences", "texture seams", "If a perfect texture reconstruction is not possible, produce the best available result while preserving geometry", TEXTURED mode); deliverable 1 "A realistic textured 3D model" (build 4 level); "CORE DESIGN PRINCIPLE", Representation B (texture projection, texture blending).

---

## Build 4, wave 4c (screens; none imports another 4c module)

### 3.24 ScanUI

**Purpose.** The room scan flow for an amateur: preflight (camera permission, LiDAR, free space D18, battery, heat), tips once per mode, project creation, the full-screen scan screen (RoomCaptureView plus Mapper chrome: Cancel, Done, timer, counts, Take Photo, guidance banner), the `@MainActor` `ScanFlowModel` facade over any `ScanEngine` (D1), the quality check at Done, Finish, Cancel with confirmation, time hints, interruption handling, Demo Mode with `FakeScanEngine` and a synthetic demo project, and the optional snapshot recorder for real device recordings.

**Build and wave.** Build 4, wave 4c. Core, CaptureCore, Store, RoomCapture, MeshRecord, Keyframes, Quality, GuidanceUI, RoomModel, MeshModel, FloorPlan, Units, Support; SwiftUI, AVFoundation, ARKit, RoomPlan.

**Files.** `ios/Sources/ScanUI/ScanFlowModel.swift`, `ScanFlowModel+Room.swift`, `RoomScanScreen.swift`, `ScanChrome.swift`, `ScanPreflight.swift`, `ScanTipsSheet.swift`, `DemoProjectFactory.swift`, `SnapshotRecorder.swift`, `ScanUISelfTest.swift`, `ios/Sources/Support/Copy+ScanUI.swift`.

**Public Swift API.**
```swift
extension SettingsKey {
    static let demoMode = "demoMode"                 // Bool
    static let keepScanPhotos = "keepScanPhotos"     // Bool, absent means on (ScanSettings.keepAllPhotos)
    static let recordSnapshots = "recordSnapshots"   // Bool (Diagnostics)
    static func tipsSeen(_ mode: ScanMode) -> String // "tipsSeen.<mode>"
}
enum ScanFlowPhase: Equatable { case preflight, tips, capturing, stopping, checking, quality, finishing, done(UUID), failed(String), cancelled }
enum PreflightIssue: Equatable, Sendable { case cameraDenied, noLidar, lowStorage(free: Int64), storageWarning(free: Int64), lowBattery(Float), deviceHot }
struct PreflightReport: Equatable, Sendable { var blocking: PreflightIssue?; var warnings: [PreflightIssue] }
enum ScanPreflight {
    /// Pure decision (tested): blocking = camera denied, no LiDAR, free < ProjectStore.refuseScanBelowBytes;
    /// warnings = free < warnScanBelowBytes, battery < 0.2, thermal serious or worse.
    static func evaluate(cameraAuthorized: Bool, lidarSupported: Bool, freeBytes: Int64, batteryLevel: Float?, thermal: ThermalLevel) -> PreflightReport
    /// Reads the real values; asks for camera access when undetermined. Main actor.
    @MainActor static func run(mode: ScanMode) async -> PreflightReport
}
struct ScanAlert: Identifiable, Equatable { var id: String; var title: String; var body: String }
@MainActor final class ScanFlowModel: ObservableObject {
    @Published private(set) var phase: ScanFlowPhase
    @Published private(set) var snapshot: LiveScanSnapshot
    @Published private(set) var evaluation: QualityEvaluation?
    @Published private(set) var preflight: PreflightReport?
    @Published var alert: ScanAlert?
    @Published var showsCancelConfirmation: Bool
    @Published var showsTimeLimitSheet: Bool
    let mode: ScanMode; let isDemo: Bool
    private(set) var projectID: UUID?
    /// The live room engine (nil in Demo Mode); RoomScanScreen hosts its view.
    private(set) var roomEngine: RoomScanEngine?
    /// Called once after Finish with the project id (AppShell enqueues processing and opens Results).
    var onComplete: ((UUID) -> Void)?
    /// Called when the flow ends without a project (cancel, blocking preflight).
    var onDismiss: (() -> Void)?
    init(mode: ScanMode, isDemo: Bool)
    func begin()                                     // preflight, then tips or capture
    func tipsFinished(dontShowAgain: Bool)
    func done()                                      // Done button: finish, then quality check
    func finish()                                    // Finish or Finish Anyway on the quality sheet
    func requestCancel(); func confirmCancel(); func keepScanning()
    func takePhoto()
}
enum ScanFlowSignal: Equatable, Sendable {
    case preflightPassed, preflightBlocked, tipsDone, engineStarted, doneTapped, roomFinished(UUID), evaluated, finishTapped, cancelConfirmed, failed(String)
}
extension ScanFlowModel {
    /// Pure phase reducer used by the model and the self-test.
    nonisolated static func nextPhase(_ phase: ScanFlowPhase, on signal: ScanFlowSignal) -> ScanFlowPhase
}
struct RoomScanScreen: View { init(model: ScanFlowModel) }   // camera (RoomCaptureContainer or demo placeholder) + ScanChrome; forced dark
struct ScanTipsSheet: View { init(mode: ScanMode, onStart: @escaping (_ dontShowAgain: Bool) -> Void) }
enum DemoProjectFactory {
    /// Writes a synthetic 4 x 5 m room with a door, a window, a table and a sofa: a sealed raw
    /// folder (`ProjectStore.sealRawFolder`) with one synthetic mesh chunk and no RoomPlan or
    /// keyframe files, derived clean.json, plan.json, mesh files and quality.json; returns the
    /// record (status `.processed`). The caller sets the project status `.ready`, so the demo
    /// project is never enqueued for processing.
    static func makeDemoRoom(package: ProjectPackage, sessionID: UUID, roomID: UUID, now: Date) throws -> (RoomRecord, QualityEvaluation)
}
/// Appends every snapshot as JSON Lines to Documents/Diagnostics/recording-<timestamp>.jsonl when enabled.
final class SnapshotRecorder { init?(enabled: Bool); func record(_ snapshot: LiveScanSnapshot); func close() }
```
Flow: `begin` runs preflight (blocking issue: alert with the matching Copy error then `onDismiss`); tips when `tipsSeen` is false; create the project (`ProjectLibrary.shared.create(kind: .room, name: Copy.Home.defaultRoomName(date))`, settings `ScanSettings.defaults(for: .room)` with `keepAllPhotos` from the setting, append `CaptureSessionRef(id:startedAt:frameLink: .projectFrame(sessionID:), worldMapFile: nil)`); create recorders (`MeshStore()`, `KeyframeRecorder()`, `PoseTrackRecorder()`, `PhotoRecorder()`) and `RoomScanEngine(target:recorders:)`, or `FakeScanEngine()` in Demo Mode; `engine.start()`; mirror `.snapshot` events; `done` calls `engine.finish()` (phase stopping); on `.roomFinished` append the `RoomRecord` (status `.captured`, `capturedRoomID`, `keyframeCount`, `capturedAt`, `frameLink`) with `ProjectLibrary.update`, set phase checking and run `QualityEvaluator.evaluateSealedRoom` in `Task.detached`, then `QualityStore.save` and phase quality; `finish` sets the project status `.needsProcessing` (`.ready` in Demo Mode), calls `roomEngine.close()`, phase done, `onComplete(projectID)`; `confirmCancel` while capturing cancels the engine, discards the InProgress folder and deletes the project when it has no rooms; `confirmCancel` in the quality phase (the Discard button, same confirmation) closes the engine and deletes the project, because a Room project holds exactly this one sealed room (a build 5 house removes only the room through Store). A `.failed` event that arrives after `.roomFinished` (heat, storage) shows its alert and keeps the finished room; the quality sheet still opens. The idle timer is disabled while the scan screen is visible. After 4 minutes a tier 3 style hint (`Copy.ScanUI.timeHint`) shows once; after 5 minutes the time limit sheet. On `.stateChanged(.paused)` the chrome shows `Copy.Scanning.paused`; after 30 s paused, the alert offers Finish.

**Uses.** RoomCapture: `RoomScanEngine`, `RoomScanTarget`, `RoomScanResult`, `RoomCaptureContainer`. MeshRecord: `MeshStore`. Keyframes: `KeyframeRecorder`, `PoseTrackRecorder`, `PhotoRecorder`. CaptureCore: `ScanRecorder`, `ScanConfigurationFactory.supportsMesh`. Quality: `QualityEvaluator.evaluateSealedRoom`, `QualityStore.save`, `QualityEvaluation`. GuidanceUI: `GuidanceBanner`, `GuidanceAnnouncer`. Store: `ProjectLibrary`, `InProgressScans.discard`. RoomModel: `RoomInput`, `CleanModelBuilder`, `CleanModelStore.save` (demo). MeshModel: `MeshModelStore`, `ConsolidationResult` (demo). FloorPlan: `PlanBuilder`, `PlanModelStore.save` (demo). Core: `ScanEngine`, `ScanEngineEvent`, `FakeScanEngine`, `SnapshotRecording.synthetic`, `LiveScanSnapshot`, `ScanMode`, `ScanSettings`, `CaptureSessionRef`, `RoomRecord`, `FrameLink`, `ProjectStore`, `MapperError.copyKey`, `ThermalLevel`. Support: `Copy.Scanning`, `Copy.Onboarding`, `Copy.Permissions`, `Copy.Errors`, `Copy.A11y`, `Haptics.success()`.

**Apple APIs.** `AVCaptureDevice.authorizationStatus(for: .video)`, `AVCaptureDevice.requestAccess(for: .video)` (async form) (not in RESEARCH, iOS 7; async import iOS 15); `RoomCaptureSession.isSupported`; `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`; `UIDevice.current.isBatteryMonitoringEnabled = true` then `batteryLevel` (main); `UIApplication.shared.isIdleTimerDisabled` (main); SwiftUI `.fullScreenCover` is presented by AppShell, this module provides the content; `.persistentSystemOverlays(.hidden)`, `.environment(\.colorScheme, .dark)`, `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on the HUD; `.sensoryFeedback(.success, trigger:)` on finish.

**Must NOT do.** Never show the quality sheet itself (AppShell composes QualityUI); never enqueue processing (AppShell does in `onComplete`); never import QualityUI, Results, ExportUI or HomeUI; never touch ARKit in Demo Mode; never delete raw data without the user's confirmation; never hardcode text.

**Copy strings.** Existing: `Copy.Scanning.done`, `cancel`, `cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`, `paused`, `startingUp`, `addPhoto`, `photoSaved`; `Copy.Onboarding.room`, `start`, `dontShowAgain`, `skip`; `Copy.Permissions.*`; `Copy.Errors.noLidar`, `storageFullTitle`, `storageFullBody(_:)`, `lowBattery`, `tooHot`, `interrupted`; `Copy.A11y.scanView`, `doneScanning`, `doneScanningHint`. New (`enum ScanUI`): `static func elapsed(minutes: Int, seconds: Int) -> String` ("\(minutes):\(two-digit seconds)"), `timeHint = "Almost done? Tap Done when the room looks complete"`, `timeLimitTitle = "Time to finish this room"`, `timeLimitBody = "Long scans make your iPhone hot. Tap Done now. You can scan more later."`, `storageWarningTitle = "Storage is getting low"`, `static func storageWarningBody(_ size: String) -> String { "About \(size) free. A room scan can use a few hundred MB." }`, `warmTitle = "Your iPhone is warm"`, `warmBody = "Scanning makes it warmer. Take a break if it gets hot."`, `demoBanner = "Demo Mode: no camera is used"`, `static func counts(walls: Int, doors: Int, windows: Int) -> String { "\(walls) walls, \(doors) doors, \(windows) windows" }`, `pausedFinishPrompt = "Still paused. Finish with what you have?"`, `finishNow = "Finish Now"`.

**Self-test.** `ScanUISelfTest.run()`, at least 15 checks: `ScanPreflight.evaluate` blocking for denied camera, no LiDAR, 1 GB free; warning only for 2 GB free, 15 percent battery, serious heat; clean report otherwise; `ScanFlowModel.nextPhase` for the main path and both cancel paths; `Copy.ScanUI.elapsed(minutes: 4, seconds: 5)` is "4:05"; `DemoProjectFactory.makeDemoRoom` in a temp package writes clean.json and plan.json that load with `CleanModelStore.loadBase` and `PlanModelStore.loadBase`, with floor area 20 within 1e-3; `SnapshotRecorder` disabled returns nil.

**Acceptance checks.** The model is the only owner of the engine and recorders; engine events are handled on main; no quality or processing UI in this module; Demo Mode never imports ARKit code paths at runtime (no `RoomScanEngine` created).

**SPEC owned.** "SCANNING MODES" ("The application should choose sensible defaults automatically"; "The user should not need to understand LiDAR, meshes..."); "ROOM SCANNING" flow; "LIVE SCANNING EXPERIENCE" (chrome, "Do not overwhelm the user"); "SCAN QUALITY SYSTEM" ("Before allowing the user to finish, show: SCAN QUALITY", data side).

### 3.25 QualityUI

**Purpose.** The scan quality sheet (SPEC SCAN QUALITY) shown as a medium-detent sheet over the live camera (D19): Shape, Walls, Floor, Ceiling, Color and texture as percentages with bars, the missing area count, the verdict summary, the degraded-mode note (D16), Finish or Finish Anyway, Discard, and a Show Missing Areas button slot that build 5 fills.

**Build and wave.** Build 4, wave 4c. Core, Quality, Support; SwiftUI.

**Files.** `ios/Sources/QualityUI/QualitySheet.swift`, `QualityPresentation.swift`, `QualityUISelfTest.swift`, `ios/Sources/Support/Copy+QualityUI.swift`.

**Public Swift API.**
```swift
enum QualityTint: Equatable, Sendable { case good, okay, poor }        // >= 0.9, >= 0.7, below
struct QualityRowModel: Identifiable, Equatable, Sendable { var id: String; var title: String; var percentText: String; var fraction: Double; var tint: QualityTint; var accessibility: String }
enum QualityPresentation {
    static func rows(for evaluation: QualityEvaluation) -> [QualityRowModel]   // Shape, Walls, Floor, Ceiling, Color and texture
    static func summaryText(_ verdict: QualityVerdict) -> String
    static func finishTitle(missingAreas: Int) -> String                        // Finish when 0, else Finish Anyway
    static func degradedNote(_ mode: DegradedMode) -> String?                  // nil for .allGood
    static func missingText(count: Int) -> String
}
/// nil evaluation shows the "Checking your scan..." state. `onShowMissingAreas` nil hides the button (build 4).
struct QualitySheet: View {
    init(evaluation: QualityEvaluation?, onFinish: @escaping () -> Void, onDiscard: @escaping () -> Void,
         onShowMissingAreas: (() -> Void)? = nil)
}
```

**Uses.** Quality: `QualityEvaluation`, `MissingAreaRecord`. Core: `QualitySummary`, `QualityVerdict`, `DegradedMode`. Support: `Copy.Quality.*`, `Copy.A11y.metric(_:percent:)`, `Copy.Scanning.cancelConfirmDiscard`.

**Apple APIs.** SwiftUI `.presentationDetents([.medium, .large])` (iOS 16) and `.interactiveDismissDisabled()` (iOS 15) are applied by AppShell (not in RESEARCH); this view uses `ProgressView(value:)`, `Gauge` or plain bars, `.accessibilityElement(children: .combine)`.

**Must NOT do.** No computation beyond presentation; never present itself; never hide the Finish Anyway path.

**Copy strings.** Existing: `Copy.Quality.title`, `geometry`, `walls`, `floor`, `ceiling`, `textures`, `missingAreas`, `summaryGood`, `summaryOkay`, `summaryPoor`, `finishAnyway`, `finish`, `showMissingAreas`, `percent(_:)`. New (`extension Copy.Quality` in `Copy+QualityUI.swift`): `checking = "Checking your scan..."`, `noteDepthStripped = "Some depth data was missing, so these numbers are rough."`, `noteMeshStripped = "The detailed 3D scan didn't record. Walls and the floor plan are fine."`, `noteRoomPlanFailed = "Walls couldn't be found, so there is no floor plan for this scan."`. The Discard button reuses `Copy.Scanning.cancelConfirmDiscard`.

**Self-test.** `QualityUISelfTest.run()`, at least 10 checks: rows order and titles; 0.943 shows "94%"; tints at 0.95, 0.8, 0.5; finish title for 0 and 3 missing areas; degraded notes nil for allGood and non-nil for the others; summary text per verdict.

**Acceptance checks.** All text from Copy; VoiceOver reads each row as "Walls, 100 percent".

**SPEC owned.** "SCAN QUALITY SYSTEM" (the SCAN QUALITY screen, FINISH ANYWAY; SHOW MISSING AREAS entry point in build 5).

### 3.26 Results

**Purpose.** The result screen: segmented Realistic, 3D Clean, Floor Plan, Raw Scan switcher, available from the moment the floor plan step is done with per-tab status chips while later steps run (D20); display style menu; Hide Furniture; floor plan toggles; the room dimensions panel with plus or minus confidence; a read-only object card when tapping an object box (category guess and width, height, depth); the RoomPlan model in Quick Look as the Realistic fallback; an Export button that calls back to AppShell.

**Build and wave.** Build 4, wave 4c. Core, Store, Pipeline, RoomModel, MeshModel, FloorPlan, MeasureCore, Viewer3D, Quality, TextureJob, Units, Support; SwiftUI, RoomPlan, QuickLook.

**Files.** `ios/Sources/Results/ResultScreen.swift`, `ResultModel.swift`, `ResultModel+Loading.swift`, `ResultTabs.swift`, `ResultDimensionsPanel.swift`, `ResultObjectCard.swift`, `ResultAvailability.swift`, `ResultsSelfTest.swift`, `ios/Sources/Support/Copy+Results.swift`.

**Public Swift API.**
```swift
enum ResultTab: String, CaseIterable, Identifiable, Sendable { case realistic, clean, floorPlan, raw; var id: String { rawValue } }
enum TabAvailability: Equatable, Sendable { case ready, preparing(text: String, percent: Int?), unavailable(reason: String), failed(reason: String) }
/// What exists on disk for the project. `isDemo`: the room's raw folder has neither keyframes
/// nor RoomPlan data (Demo Mode rooms), so Realistic is unavailable rather than "preparing".
struct ResultFiles: Equatable, Sendable { var hasClean = false, hasPlan = false, hasMeshView = false, hasTexture = false, hasCapturedRoom = false, isDemo = false; init() }
enum ResultAvailability {
    /// Pure. Realistic: texture ready, else preparing while textureLow runs, else failed text, else
    /// "fallback available" when a CapturedRoom exists. Clean and Floor Plan need clean/plan files;
    /// Raw needs the view mesh; RoomPlan failure makes Clean and Floor Plan unavailable with the reason.
    static func compute(_ tab: ResultTab, files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability
}
@MainActor final class ResultModel: ObservableObject {
    @Published var tab: ResultTab
    @Published var displayStyle: ViewerDisplayStyle          // realistic and raw tabs
    @Published var hideFurniture: Bool
    @Published var planToggles: PlanToggles
    @Published private(set) var availability: [ResultTab: TabAvailability]
    @Published private(set) var dimensionRows: [DimensionRow]
    @Published private(set) var planDrawing: PlanDrawingResult?
    @Published private(set) var selectedObject: DetectedObject?
    @Published var quickLookURL: URL?
    @Published private(set) var title: String
    let viewer: ViewerModel
    init(projectID: UUID)
    func load() async                        // manifest, PackageCheck.verify (off main; problems mark the
                                             // project .needsAttention via ManifestWriter), edited clean
                                             // model and plan, quality evidence, files
    func show(_ tab: ResultTab) async        // builds the tab's ViewerContent off main, then viewer.load
    func handleTap(_ hit: ViewerHit?)        // object boxes: selectedObject
    func openSimpleModel() async             // CapturedRoom.export(to:metadataURL:modelProvider:exportOptions: [.mesh]) into exports/, sets quickLookURL
}
struct ResultScreen: View { init(projectID: UUID, onExport: @escaping () -> Void) }
```
Content per tab: Realistic = `TextureStore.load` pages via `pageParts()` into `ViewerPart`s with `.texture(url)`; Solid Color and Wireframe styles re-use the view mesh. 3D Clean = `CleanMeshBuilder.parts` (walls light gray `.lit`, floor, openings translucent, objects translucent boxes plus wireframe with `pickTag .element(id)`, furniture in `.cleanFurniture` so Hide Furniture toggles that layer), ceiling hidden. Floor Plan = `PlanCanvasView` of `PlanDrawing.make(level:toggles:prefs:roomTitles:name:)` with `RoomTitles.titles(for:)`. Raw Scan = `MeshModelStore.loadView` plus `loadInferred` through `ViewerContentBuilder.meshParts` with `MeshClassPalette.all`. The dimensions panel lists `RoomDimensions.rows(for:evidence:)` (evidence from `QualityStore.load`, else `RoomEvidence.unknown`) with `MeasureDisplay.valueText` and `accuracyText`, grouped, plus `Copy.Measure.disclaimer`. The model observes `ProcessingRunner.shared.states[projectID]` and `.mapperManifestDidChange` and reloads what changed. Units come from `UnitPreferences.load()` on appear.

**Uses.** Viewer3D: `ViewerModel`, `ViewerContainer`, `ViewerContent`, `ViewerPart`, `ViewerMaterial`, `ViewerLayer`, `ViewerPickTag`, `ViewerHit`, `ViewerContentBuilder`, `ViewerDisplayStyle`. FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing`, `PlanDrawingResult`, `PlanToggles`, `PlanCanvasView`, `RoomTitles`. MeasureCore: `RoomDimensions`, `DimensionRow`, `MeasureDisplay`, `RoomEvidence`. RoomModel: `CleanModelStore.loadEdited`, `CleanMeshBuilder`, `CapturedRoomStore.loadCapturedRoom`. MeshModel: `MeshModelStore`, `MeshClassPalette`. TextureJob: `TextureStore`, `TexturedMesh`. Quality: `QualityStore.load`. Pipeline: `ProcessingRunner.shared`, `ProjectProcessingState`. Store: `ProjectLibrary`, `PackageCheck`, `ManifestWriter`. Core: `ProjectManifest`, `DetectedObject`, `DegradedMode`, `PipelineStepID`. Units: `UnitPreferences`, `LengthFormat`. Support: `Copy.Viewer`, `Copy.Processing`, `Copy.Measure`, `Copy.Errors.textureFailed`, `Copy.Empty.noFloorPlan`, `Copy.ObjectMenu.guessedLabel(_:)`, `Copy.A11y.viewSwitcher`, `viewSwitcherHint`.

**Apple APIs.** `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (file name starts with a letter); `nonisolated func quickLookPreview(_ item: Binding<URL?>) -> some View`; SwiftUI `Picker` with `.pickerStyle(.segmented)` for the switcher, `Menu` for display styles and toggles.

**Must NOT do.** Never block main while loading meshes (build parts in `Task.detached`); never embed `QLPreviewController` in a representable (RESEARCH 3.7 gotcha 19); never show a number without its confidence text; never present ExportUI directly; no editing in build 4 (read-only object card).

**Copy strings.** Existing: `Copy.Viewer.realistic`, `clean`, `floorPlan`, `raw`, `displayTitle`, `photoRealistic`, `textured`, `solidColor`, `wireframe`, `hideFurniture`, `showFurniture`, `export`, `width`, `height`, `depth`, `resetView`; `Copy.Processing.stepShape`, `stepClean`, `stepFloorPlan`, `stepTextures`, `done`; `Copy.Measure.disclaimer`, `legendTitle`, `measured`, `estimated`, `inferred`. New (`enum Results`): `static func stepProgress(_ step: String, percent: Int) -> String { "\(step) \(percent)%" }`, `colorPreparing = "Color is still being added"`, `simpleModel = "View Simple Model"`, `simpleModelNote = "A simple model from the room scan, without color."`, `noWalls = "Floor plans need walls. This scan has none."`, `dimensionsTitle = "Measurements"`, `photoRealisticLater = "Photo Realistic comes in a later version"`.

**Self-test.** `ResultsSelfTest.run()`, at least 15 checks on `ResultAvailability.compute`: realistic ready with texture; preparing with percent while textureLow runs; failed text when textureLow failed; fallback when only a CapturedRoom exists; clean unavailable when `.roomPlanFailed`; floor plan preparing while floorPlan runs; raw ready with the view mesh; demo files make every tab but realistic ready; plus the step-to-text mapping (`static func stepText(_ step: PipelineStepID) -> String`).

**Acceptance checks.** Tab switching never reloads unchanged content; Hide Furniture toggles a layer, it does not rebuild; dimension rows use MeasureDisplay only; the Quick Look file lives in `exports/`.

**SPEC owned.** "ROOM SCANNING" ("After scanning, allow the user to switch between: REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH"); "FURNITURE REMOVAL" (HIDE FURNITURE); "MEASUREMENT SYSTEM" and "MEASUREMENT CONFIDENCE" (display); "AUTOMATIC OBJECT RECOGNITION" (labels shown as guesses); "IMAGE / TEXTURE CAPTURE" display modes selection; deliverables 1 to 7.

### 3.27 ExportUI

**Purpose.** The export sheet and export jobs (deliverable 14 "Exportable professional files"): formats grouped by representation with plain explanations, availability with reasons, options, running writers off main, staging files in `exports/`, and sharing through a `UIActivityViewController` wrapper.

**Build and wave.** Build 4, wave 4c. Core, Export, Store, RoomModel, MeshModel, FloorPlan, MeasureCore, Quality, TextureJob, Units, Support; SwiftUI, UIKit, RoomPlan.

**Files.** `ios/Sources/ExportUI/ExportSheet.swift`, `ExportCatalog.swift`, `ExportRunner.swift`, `ExportAdapters.swift`, `ExportSummaryJSON.swift`, `ExportShare.swift`, `ExportUISelfTest.swift`, `ios/Sources/Support/Copy+ExportUI.swift`.

**Public Swift API.**
```swift
enum ExportRepresentation: String, CaseIterable, Identifiable, Sendable { case realistic, clean, raw, floorPlan, data; var id: String { rawValue } }
enum ExportFileFormat: String, CaseIterable, Identifiable, Sendable { case usdz, obj, ply, stl, glb, pdf, svg, dxf, png, json; var id: String { rawValue } }
struct ExportInputs: Equatable, Sendable { var hasTexture = false, hasClean = false, hasPlan = false, hasMesh = false, hasCapturedRoom = false, hasEdits = false, meshTriangles = 0; init() }
struct ExportOption: Identifiable, Equatable, Sendable {
    var representation: ExportRepresentation; var format: ExportFileFormat
    var isAvailable: Bool; var reason: String?; var id: String { get }
}
enum ExportCatalog {
    /// realistic: usdz, obj (zip), glb; clean: usdz, obj, glb; raw: usdz, obj, ply, stl, glb;
    /// floorPlan: pdf, svg, dxf, png; data: json. Unavailable ones carry Copy.Export.noColor / noFloorPlan.
    static func options(for inputs: ExportInputs) -> [ExportOption]
    static func fileName(project: String, option: ExportOption, date: Date) -> String   // starts with a letter; DXF gets "_mm"
}
struct ExportSettings: Equatable, Sendable { var includeTextures = true; var includeHidden = false; var includeMeasurements = true; var paper: PDFPlanWriter.Paper = .usLetter; init() }
enum ExportRunner {
    /// Off main. Writes into exports/<yyyyMMdd-HHmmss>/ and returns the file (or zip) URL.
    static func run(_ option: ExportOption, settings: ExportSettings, projectID: UUID, package: ProjectPackage, prefs: UnitPreferences) async throws -> URL
}
enum ExportAdapters {
    static func cleanScene(_ model: CleanModel, includeHidden: Bool) -> ExportScene     // CleanMeshBuilder parts, one material per kind
    static func rawScene(_ package: ProjectPackage, room: UUID, maxTextTriangles: Int) throws -> ExportScene
    static func texturedScene(_ mesh: TexturedMesh) throws -> ExportScene              // pageParts, ExportMaterial(textureJPEG:) per page
    static func planDrawing(_ package: ProjectPackage, prefs: UnitPreferences) throws -> Plan2D
}
/// Summary JSON: rooms with metrics (meters, square meters, provenance, sigma), openings, objects
/// (category, label, box), quality summary; plus capturedroom.json when present (both zipped).
enum ExportSummaryJSON { static func data(model: CleanModel, evidence: [UUID: RoomEvidence], manifest: ProjectManifest) throws -> Data }
struct ExportSheet: View { init(projectID: UUID) }
struct ActivityShareSheet: UIViewControllerRepresentable { init(items: [Any]) }
```
Rules: clean USDZ uses RoomPlan's own `export(to:metadataURL:modelProvider:exportOptions: [.mesh])` with a `.plist` metadata URL next to it (RESEARCH 3.2 recommended 9; walls with door and window cutouts; only the `.usdz` is shared) when the project has one room, a CapturedRoom and no active edits, else `USDZWriter` from `cleanScene`; raw OBJ and USDZ (text formats) use the full mesh up to 600k triangles, else the view mesh with the note `Copy.ExportUI.simplifiedNote`; PLY, STL and GLB always use the full measured mesh; STL uses `STLWriter.Options.printing` (millimeters, Z up); DXF comes from `DXFWriter.data(for:)` unchanged (D23: no `$INSUNITS` added here) with "_mm" in the file name; PDF uses `PDFPlanWriter.data(for:options:)` with `scaleCaption: Copy.ExportUI.scaleCaption`; PNG uses `PlanRenderer.pngData(_:pixelWidth: 3000)`; multi-file results are zipped with `ZipWriter.archive` (small) before sharing; share folders never, only files.

**Uses.** Export: `ExportScene`, `ExportMesh`, `ExportMaterial`, `OBJWriter.zipBundle`, `OBJWriter.write`, `PLYWriter.data`, `STLWriter.binary`, `GLBWriter.data`, `USDZWriter.data`, `DXFWriter.data`, `SVGWriter.data`, `PDFPlanWriter.data`, `PDFPlanWriter.Options`, `PDFPlanWriter.Paper`, `ZipWriter.archive`, `ExportError`. RoomModel: `CleanModelStore.loadEdited`, `CleanMeshBuilder.parts`, `CapturedRoomStore.loadCapturedRoom`. MeshModel: `MeshModelStore`, `MeshExportAdapter.scene`. FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing.make`, `PlanToggles.standard`, `RoomTitles`, `PlanRenderer.pngData`. TextureJob: `TextureStore.load`, `TexturedMesh.pageParts`. Quality: `QualityStore.load`. MeasureCore: `RoomEvidence`. Store: `ProjectLibrary`, `EditStore.load`. Core: `ProjectPackage.exportsURL`, `ProjectStore.writeData`. Units: `UnitPreferences`. Support: `Copy.Export.*`, `Copy.Errors.exportFailed`.

**Apple APIs.** `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` with `[.mesh]` and a `.plist` metadata URL (iOS 17.0; `USDExportOptions` is an OptionSet of `.parametric`, `.mesh`, `.model`); `init(activityItems: [Any], applicationActivities: [UIActivity]?)` (UIActivityViewController, iOS 6; RESEARCH 3.7 names the wrapper, not the initializer); `.quickLookPreview` for USDZ and PDF preview (optional).

**Must NOT do.** Never write outside `exports/`; never read outside the package; never add `$INSUNITS`; never use `MDLAsset.export` or SceneKit for USD; never share a folder URL (zip first); never block main.

**Copy strings.** Existing: `Copy.Export.title`, `subtitle`, `button`, `preparing`, `ready`, `includeTextures`, `includeHidden`, `includeMeasurements`, `units`, `noFloorPlan`, `noColor`, `formats`. New (`enum ExportUI`): `realisticSection = "3D Model with Color"`, `cleanSection = "3D Clean Model"`, `rawSection = "Raw Scan"`, `planSection = "Floor Plan"`, `dataSection = "Data"`, `simplifiedNote = "Simplified to keep the file a manageable size."`, `scaleCaption = "Scale"`, `paper = "Paper Size"`, `letter = "US Letter"`, `a4 = "A4"`.

**Self-test.** `ExportUISelfTest.run()`, at least 15 checks: catalog availability for no texture, no plan, demo inputs; DXF file name ends in "_mm.dxf"; file names start with a letter even for a project named "3rd floor"; `cleanScene` of a demo clean model validates (`ExportScene.validate()`); `texturedScene` of a 2-face textured mesh has one material with JPEG data and bottom-left texcoords unchanged; summary JSON parses with `JSONSerialization` and has rooms[0].metrics.floorArea; raw scene threshold picks the view mesh above 600k.

**Acceptance checks.** Each format uses the listed writer; zips only in memory for small outputs; errors map to `Copy.Errors.exportFailed`; the share sheet receives file URLs that survive until dismissal.

**SPEC owned.** Deliverable 14 "Exportable professional files"; "PROJECT SYSTEM" (export); "2D FLOOR PLAN" output files.

### 3.28 HomeUI

**Purpose.** Home: the projects list with thumbnails, subtitles by mode, processing and needs-work badges, search, empty state and privacy footer, delete with confirmation, the big New Scan button and the mode picker (Room enabled in build 4, the other modes shown disabled with "Coming in a later version").

**Build and wave.** Build 4, wave 4c. Core, Store, Pipeline, Units, Support; SwiftUI.

**Files.** `ios/Sources/HomeUI/HomeScreen.swift`, `HomeProjectRow.swift`, `HomeModePicker.swift`, `HomePresentation.swift`, `HomeUISelfTest.swift`, `ios/Sources/Support/Copy+HomeUI.swift`.

**Public Swift API.**
```swift
enum HomeBadge: Equatable, Sendable { case processing, needsWork }
enum HomePresentation {
    static func subtitle(for manifest: ProjectManifest, dateText: String) -> String
    static func badge(for manifest: ProjectManifest, processing: ProjectProcessingState?) -> HomeBadge?
    static func filtered(_ projects: [ProjectManifest], query: String, showArchived: Bool) -> [ProjectManifest]
}
struct HomeScreen: View {
    init(library: ProjectLibrary, runner: ProcessingRunner, availableModes: Set<ScanMode>,
         onNewScan: @escaping (ScanMode) -> Void, onOpen: @escaping (UUID) -> Void, onSettings: @escaping () -> Void)
}
struct ModePickerSheet: View { init(availableModes: Set<ScanMode>, onPick: @escaping (ScanMode) -> Void, onCancel: @escaping () -> Void) }
```

**Uses.** Store: `ProjectLibrary` (`projects`, `delete`). Pipeline: `ProcessingRunner`, `ProjectProcessingState`. Core: `ProjectManifest`, `ScanMode`, `RoomStatus`, `ProjectPackage.thumbnailURL`. Support: `Copy.Home.*`, `Copy.Modes.*`, `Copy.Project.deleteTitle(_:)`, `deleteBody`, `deleteConfirm`, `Copy.Empty.noProjects`, `noSearchResults`, `Copy.A11y.newScanHint`, `openProjectHint`, `projectRow(name:type:date:)`, `projectNeedsWork(_:)`.

**Apple APIs.** SwiftUI `List`, `.searchable(text:prompt:)`, `.swipeActions`, `.confirmationDialog` (not in RESEARCH, all iOS 15), `AsyncImage` is not used for files (load the thumbnail with `UIImage(contentsOfFile:)` off main).

**Must NOT do.** No rename, duplicate, archive, backup (build 6 ProjectOps); never start a scan itself (callback only); never block main on disk.

**Copy strings.** Existing as listed. New (`enum HomeUI`): `comingLater = "Coming in a later version"`.

**Self-test.** `HomeUISelfTest.run()`, at least 8 checks: subtitles for room, house (room count), object, quick measure; processing badge when running; needs-work badge when a room is `.needsRescan`; search is case-insensitive and hides archived unless asked.

**Acceptance checks.** Rows are accessible elements with `Copy.A11y.projectRow`; New Scan is reachable with one hand at the bottom.

**SPEC owned.** "SCANNING MODES" ("The home screen should contain a large button: NEW SCAN", mode options); "PROJECT SYSTEM" (project list, delete, "No required account").

---

## Build 4, wave 4d

### 3.29 AppShell

**Purpose.** The composition root that replaces the capability probe as the app's first screen: navigation, Home, the scan cover (ScanUI plus the QualityUI sheet over it), processing plans and resume on launch, Results plus the ExportUI sheet, Settings, Diagnostics (capability probe kept, all self-tests, Demo Mode, UV checker, device facts), and unfinished scan recovery (D5).

**Build and wave.** Build 4, wave 4d. Every build 4 module; SwiftUI, ARKit, RoomPlan, RealityKit. Owns `ContentView.swift` and `MapperApp.swift` (edits allowed); the lead edits `project.yml` and the suite list.

**Files.** `ios/Sources/AppShell/AppRootView.swift`, `AppRouter.swift`, `AppScanCoordinator.swift`, `AppResultsCoordinator.swift`, `AppProcessingPlans.swift`, `AppSettingsScreen.swift`, `AppDiagnosticsScreen.swift` (moves `SelfTestSuite`, `SelfTestResult` and the probe rows here, names unchanged), `AppRecovery.swift`, `AppShellSelfTest.swift`, `ios/Sources/Support/Copy+AppShell.swift`; edits `ios/Sources/ContentView.swift` (body becomes `AppRootView()`) and keeps `MapperApp.swift` launching it.

**Public Swift API.**
```swift
enum AppRoute: Hashable { case result(UUID), settings, diagnostics }
struct ScanRequest: Identifiable, Equatable { var id: UUID; var mode: ScanMode; var isDemo: Bool }
@MainActor final class AppRouter: ObservableObject {
    @Published var path: [AppRoute]
    @Published var scanRequest: ScanRequest?          // drives .fullScreenCover
    @Published var exportProjectID: UUID?             // drives the export sheet
    func startScan(_ mode: ScanMode)
    func openResult(_ id: UUID)
}
struct AppRootView: View { init() }                  // NavigationStack(path:) over HomeScreen
struct AppScanCoordinator: View { init(request: ScanRequest, onFinished: @escaping (UUID?) -> Void) }
struct AppResultsCoordinator: View { init(projectID: UUID) }
enum ProcessingPlans {
    /// Room projects, in this order: per room BuildRoomStep (required; only when raw lacks
    /// capturedroom.json and has capturedroomdata.json), per room ConsolidateMeshStep (optional:
    /// a failure leaves Raw Scan unavailable and heights from RoomPlan), CleanModelStep(meshProvider:
    /// MeshModelStore.loadMeasured) (required), FloorPlanStep (required; Results opens once it is
    /// stamped, D20), per room QualityStep (optional), ThumbnailStep (optional), per room
    /// TextureLowStep (optional).
    static func roomSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// Enqueues projects whose status is .needsProcessing or .processing (never Demo Mode projects,
    /// which are .ready) and, on completion, sets rooms .processed and project .ready (or
    /// .needsAttention when a required step failed).
    @MainActor static func enqueue(projectID: UUID)
    /// On launch: projects in .needsProcessing or .processing.
    @MainActor static func resumePending()
}
struct SettingsScreen: View { init() }
struct DiagnosticsScreen: View { init() }            // probe rows, self-test suites, Demo Mode, snapshot recording, UV checker, log share
enum RecoveryService {
    /// Unsealed InProgress folders to offer to the user. Before returning, sealed ones (a crash hit
    /// between seal and move) are finished silently: moved, RoomRecord added or updated, enqueued.
    /// Main actor (called once at launch; the moves are renames on one volume).
    @MainActor static func pending() -> [InProgressScanInfo]
    /// Seals into the project's room folder (JSON Lines tolerate a torn last line; no roomlog.json
    /// is written), adds the RoomRecord (.captured), enqueues processing. A missing project (it was
    /// deleted) makes recover create a new Room project for the scan.
    @MainActor static func recover(_ info: InProgressScanInfo) throws
    static func discard(_ info: InProgressScanInfo) throws
}
```
Composition: the scan cover shows `RoomScanScreen(model:)` and attaches `.sheet` with `QualitySheet(evaluation:onFinish:onDiscard:)` when `model.phase` is checking or quality, with `.presentationDetents([.medium, .large])` and `.interactiveDismissDisabled()`; `model.onComplete` calls `ProcessingPlans.enqueue` and routes to the result. The result route shows `ResultScreen(projectID:onExport:)`; `onExport` sets `exportProjectID`, which presents `ExportSheet(projectID:)`. Settings: units (`UnitPreferences`), inch fractions, show both, vibrate for warnings (`SettingsKey.guidanceHaptics`), keep scan photos (`SettingsKey.keepScanPhotos`), show tips again (clears `tipsSeen`), storage used (`StorageUsage.projectsTotal`), wireless debug log (`DebugServer`), Diagnostics link, version. Diagnostics: the five capability rows from the old ContentView (`supportsSceneReconstruction(.meshWithClassification)`, `supportsFrameSemantics(.sceneDepth)`, `RoomCaptureSession.isSupported`, `ObjectCaptureSession.isSupported`, `PhotogrammetrySession.isSupported`), `os_proc_available_memory`, `ProcessInfo.physicalMemory`, the suite list (lead-owned lines, one per module self-test) run off main with results logged exactly as ContentView does today, Demo Mode toggle (`SettingsKey.demoMode`), record snapshots toggle, UV checker (`ViewerDiagnostics.uvCheckerContent()` in a `ViewerContainer`), Share Log. On launch: `ProjectLibrary.shared.reload()`, `ProcessingPlans.resumePending()`, recovery sheet when `RecoveryService.pending()` is not empty. Unsupported device (no LiDAR): Home stays usable for existing projects and New Scan shows `Copy.Errors.noLidar`.

**Uses.** Every build 4 module's screen types and `ProcessingPlans` step types: `BuildRoomStep`, `CleanModelStep`, `ConsolidateMeshStep`, `FloorPlanStep`, `ThumbnailStep`, `QualityStep`, `TextureLowStep`, `ScheduledStep`, `ProcessingJob`, `ProcessingRunner`, `ProcessingOutcome`; Store `ProjectLibrary`, `InProgressScans`, `RawScanReader`, `StorageUsage`; RoomModel `CapturedRoomStore.rawFolder`; Viewer3D `ViewerDiagnostics`, `ViewerContainer`, `ViewerModel`; Support `Copy.Settings.*`, `Copy.Home.settings`, `LogStore`, `DebugServer`, `DeviceState`.

**Apple APIs.** `NavigationStack(path:root:)` (RESEARCH 3.10), `.navigationDestination(for:destination:)`, `.fullScreenCover(item:)`, `.sheet(item:)` (not in RESEARCH, iOS 14 to 16), `.presentationDetents`, `ShareLink(item:preview:)` for log files; the probe APIs above (RESEARCH 3.9 "Runtime capability gates").

**Must NOT do.** No business logic that belongs to a feature module; never run processing during a scan; never remove the probe rows or the self-test logging format (the maintainer reads them with `tools/phone_log.py`); never add suite lines (the lead does).

**Copy strings.** Existing: `Copy.Settings.*`, `Copy.Home.title`, `Copy.Errors.*`. New (`enum AppShell`): `recoverTitle = "Recover unfinished scan?"`, `recoverBody = "Mapper closed before a scan was finished. You can keep what was scanned."`, `recoverKeep = "Keep Scan"`, `recoverDiscard = "Discard"`, `diagnosticsTitle = "Diagnostics"`, `demoMode = "Demo Mode"`, `demoModeFooter = "Try every screen with a sample room. The camera is not used."`, `recordSnapshots = "Record Scan Snapshots"`, `uvCheck = "Texture Orientation Check"`, `selfTests = "Self-Tests"`, `runSelfTests = "Run Again"`, `showBoth = "Show both units"`.

**Self-test.** `AppShellSelfTest.run()`, at least 8 checks: `roomSteps` for a manifest with one captured room lists the steps in order with subjects and the optional flags on consolidateMesh, quality, thumbnail and textureLow; BuildRoomStep omitted when raw capturedroom.json exists and when capturedroomdata.json is missing (temp package); a `.ready` project is not enqueued; two rooms produce per-room steps; an object-only manifest produces no room steps.

**Acceptance checks.** App launches to Home; the capability probe and self-test log lines are unchanged in format; the scan cover dismisses on cancel and on finish; the quality sheet appears over the live camera; Results opens immediately after Finish with chips; Export works from Results; Demo Mode runs the whole flow without camera permission.

**SPEC owned.** "SCANNING MODES" (entry flow); "PROJECT SYSTEM" (projects stored locally, restore on relaunch of unfinished work); "LOCAL-FIRST ARCHITECTURE" ("must work offline", no account); TEST_PLAN MODE-01 to MODE-05, ROOM-01, ROOM-02, ROOM-11, QUAL-01, QUAL-04, PROJ-01, PROJ-05, OFF-01 to OFF-04 end to end.

---

## Build 5 (0.5)

Same rules as build 4; sections are shorter because the build 4 contracts already fix the shared types. Every build 5 and 6 module receives its section plus section 0. For these sections: the wave is in the heading; dependencies are the module index row (section 1) and the named symbols follow the build 4 sections; new strings follow rule 0.4 with existing Copy constants reused where UX_COPY.md has them; acceptance checks are that the listed API exists exactly, the self-test count is met, every "Must NOT do" holds, and each SPEC item owned is handled on device per the matching TEST_PLAN.md cases (HOUSE, OBJ, MEAS, CONF, PEDIT, LIVE, QUAL, PROJ, EXP).

### 3.30 Structure (wave 5a)

**Purpose.** House merge and alignment (D9): merge rooms whose frames are confirmed shared with `StructureBuilder`, recover each room's rigid transform into the structure frame from kept wall, door and window identifiers (least squares on matched wall endpoints), detect stacked rooms, group floors by elevation, build the clean model from the structure, and store `derived/structure/structure.json` and `alignment.json`; manual alignment records (source `.user`) come from edits.
**Files.** `ios/Sources/Structure/StructureMerger.swift`, `StructureAlignment.swift`, `StructureFloors.swift`, `StructureSteps.swift`, `StructureSelfTest.swift`.
**API.**
```swift
enum StructureEligibility { static func mergeable(_ rooms: [RoomRecord], sessions: [CaptureSessionRef]) -> (merge: [RoomRecord], separate: [RoomRecord]) }
enum StructureAlignment {
    /// Yaw about +Y plus translation minimizing matched endpoint distances; nil with fewer than 2 matches.
    static func solve(before: [UUID: (SIMD2<Float>, SIMD2<Float>)], after: [UUID: (SIMD2<Float>, SIMD2<Float>)]) -> (yaw: Float, translation: SIMD2<Float>, rms: Float)?
    static func overlapRatio(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Float     // stacked-room check (> 0.3 of the smaller room sends it to manual alignment)
    static func apply(_ record: RoomAlignmentRecord, to model: inout CleanModel)
}
enum StructureFloors { static func group(elevations: [UUID: Float], gap: Float = 1.2) -> [UUID: Int] }
final class MergeStructureStep: ProcessingStep { init(rooms: [RoomRecord]) }   // id .mergeStructure
final class AlignRoomsStep: ProcessingStep { init(rooms: [RoomRecord]) }       // id .alignRooms
```
**Apple APIs.** `class StructureBuilder { init(options: StructureBuilder.ConfigurationOptions); func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure }` with `[.beautifyObjects]` (never `option:`); `StructureBuilder.BuildError { deviceNotSupported, exceedSceneSizeLimit, insufficientInput, internalError, invalidInput, invalidRoomLocation }`; `CapturedStructure` (Codable; rooms, walls, doors, windows, openings, floors, objects, sections; room and floor identifiers are regenerated, surface and object identifiers kept).
**Must NOT do.** Never pass rooms with `.unaligned` or `.manual` frame links to StructureBuilder; never rely on it to throw for unrelated frames; never overwrite per-room captures; never move raw data (alignment is applied at derivation time to mesh, keyframes and textures); never call StructureBuilder without first writing `derived/structure/attempt.json` (a crash cannot be caught, so after one crashed attempt the step is not retried automatically and HouseUI offers "Join rooms again" or manual alignment; RESEARCH 3.10 gotcha 9).
**Self-test.** At least 15 checks: solve recovers yaw 30 degrees and translation (1, 2) from 4 matched walls within 1e-3; fewer than 2 matches gives nil; overlap of identical squares is 1; floor grouping with elevations 0, 0.05, 2.8 gives 2 floors; eligibility splits projectFrame, relocalized and unaligned rooms; apply moves walls, openings and objects.
**SPEC owned.** "HOUSE / BUILDING MODE" (preserve room relationships, recognize shared walls, maintain coordinate alignment, detect doorways connecting rooms (shared door identifiers), combine rooms into one building model, support multiple floors); "2D FLOOR PLAN" (wall thickness where determinable: antiparallel wall pairs 0.05 to 0.5 m apart become `.measured`).

### 3.31 CoverageLive (wave 5a)

**Purpose.** Live coverage during ARKit captures: a `ScanRecorder` that integrates Coverage's `CoverageGrid` at up to 3 Hz on the hub queue from the latest mesh faces (MeshRecord `currentChunks`) and the frame pose, keeps expected surfaces from the live room (`RoomScanEngine.liveRoomHandler`), produces the top-down `MinimapSnapshot`, and fills `GuidanceInput.viewCoverage` and `nearbyMissing` through the engine's augmenter hooks.
**Files.** `ios/Sources/CoverageLive/CoverageLiveRecorder.swift`, `CoverageLiveMinimap.swift`, `CoverageLiveHooks.swift`, `CoverageLiveSelfTest.swift`.
**API.**
```swift
final class CoverageLiveRecorder: ScanRecorder {
    init(meshSource: MeshStore, hz: Double = 3)
    func setExpectedRoom(_ room: RoomInput)                   // hub queue, from liveRoomHandler
    func augment(_ input: inout GuidanceInput)                // hub queue
    func augment(_ snapshot: inout LiveScanSnapshot)          // coverageFraction and minimap
    func faceStates() -> [UUID: [CoverageState]]              // per anchor, for CoverageOverlay
    func currentMissingAreas() -> [MissingArea]
}
enum CoverageLiveMinimap { static func make(grid: CoverageGrid, boundary: CoverageRoomBoundary?, cellSize: Float) -> MinimapSnapshot }
```
**Rules.** Rate follows `ThermalPolicy.coverageHz` (0 at critical); only frames with normal tracking; depth confidence mean from `ARFrameReading.meanConfidence`; faces keyed per anchor and rebuilt when an anchor's updateCount changes (coverage is position keyed in the grid).
**Self-test.** At least 12 checks: minimap cells for a synthetic grid; augment sets viewCoverage between 0 and 1; missing areas empty when everything is observed; the 3 Hz throttle; thermal critical stops integration.
**SPEC owned.** "LIVE SCANNING EXPERIENCE" (GREEN, YELLOW, RED, GRAY; "Scan this corner", "Point toward the floor", "Scan the ceiling", "This area needs another pass"); "SCAN QUALITY SYSTEM" ("Track coverage for surfaces and geometry", live).

### 3.32 LiveMeshView (wave 5a)

**Purpose.** The mesh-only scan driver: `MeshScanEngine` (ScanEngine without RoomPlan, used for Advanced space scans, Show Missing Areas patch passes, the two-pass fallback when RoomPlan strips the mesh (D16), and large objects) plus `LiveMeshScreen`, an `ARView` in `.ar` mode bound to the hub session with `ARCoachingOverlayView` (goal `.tracking`) and a slot for the coverage overlay.
**Files.** `ios/Sources/LiveMeshView/MeshScanEngine.swift`, `LiveMeshContainer.swift`, `LiveMeshScreen.swift`, `LiveMeshViewSelfTest.swift`.
**API.**
```swift
struct MeshScanTarget: Equatable, Sendable { var projectID: UUID; var package: ProjectPackage; var sessionID: UUID; var passID: UUID; var kind: RawScanKind; var destination: URL; var settings: ScanSettings }
final class MeshScanEngine: NSObject, ScanEngine {
    @MainActor init(target: MeshScanTarget, recorders: [ScanRecorder], hub: ARSessionHub? = nil)  // reuse a running hub for patch passes
    let hub: ARSessionHub
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)?; var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)?
}
struct LiveMeshContainer: UIViewRepresentable { init(engine: MeshScanEngine, overlay: (@MainActor (ARView) -> Void)?) }
```
**Apple APIs.** `ARView(frame:cameraMode: .ar, automaticallyConfigureSession: false)`, then `arView.session = hub.session` and immediately re-assert `hub.install()` and log `session.delegate === hub` (whoever assigns last wins); `ARCoachingOverlayView` (`goal`, `session`, `activatesAutomatically`); `debugOptions.insert(.showSceneUnderstanding)` only behind the Diagnostics toggle.
**Must NOT do.** Plane detection stays off (D14); never create a second ARSession for a patch pass (same session keeps the frame).
**Self-test.** At least 8 checks on the pure state reducer and target validation.
**SPEC owned.** "ADVANCED SCAN" space scanning driver; "LIVE SCANNING EXPERIENCE" ("The user should see the model forming while walking").

### 3.33 ObjectCapture (wave 5a)

**Purpose.** Small and medium objects (D4): a port of Apple's GuidedCapture flow: `ObjectScanModel` owning `ObjectCaptureSession?`, fresh, empty `Images/` and `Checkpoint/` folders per scan inside the scan's InProgress folder (D5; RESEARCH 3.3 gotcha 2: a non-empty checkpoint folder fails the session), sealed and moved on `.completed` (the checkpoint is moved out first, then the folder is sealed) so that `Images/` and `objectlog.json` land in `raw/objects/<id>/` while the checkpoint moves to `derived/objects/<id>/checkpoint/` (it is a cache that `PhotogrammetrySession` keeps writing, not raw; CR-5), the onboarding state machine (three passes, flip or not), `ObjectScanScreen` with `ObjectCaptureView` and Mapper overlay, Object Capture preflight (3 GB free, D18), and `PhotogrammetryStep` (`reconstructObject`) with `reconstructionPending` resume (D17).
**Files.** `ios/Sources/ObjectCapture/ObjectScanModel.swift`, `ObjectScanFolders.swift`, `ObjectOnboarding.swift`, `ObjectScanScreen.swift`, `PhotogrammetryStep.swift`, `ObjectCaptureSelfTest.swift`, `Copy+ObjectCapture.swift`.
**API.**
```swift
struct ObjectScanTarget: Equatable, Sendable { var projectID: UUID; var package: ProjectPackage; var objectID: UUID }
@MainActor final class ObjectScanModel: ObservableObject {
    @Published private(set) var captureState: ObjectCaptureSession.CaptureState?
    @Published private(set) var shotCount: Int; @Published private(set) var shotLimit: Int
    @Published private(set) var guidance: GuidanceKind?; @Published private(set) var onboarding: ObjectOnboardingState
    init(target: ObjectScanTarget)
    func start() throws; func continueTapped(); func startCapture(); func nextPass(flipped: Bool); func finish(); func cancel()
    var onComplete: ((UUID) -> Void)?
}
enum ObjectOnboardingState: Equatable, Sendable { case firstSegment, secondSegment, thirdSegment, flipObject, captureFromLowerAngle, captureFromHigherAngle, done }
final class PhotogrammetryStep: ProcessingStep { init(object: ObjectRecord) }  // id .reconstructObject; Apple-managed memory; nothing else runs
```
**Apple APIs** (RESEARCH 3.3): `@MainActor class ObjectCaptureSession`, `static var isSupported`, `start(imagesDirectory:configuration:)` with `Configuration.checkpointDirectory` and `isOverCaptureEnabled = false`, `startDetecting() -> Bool`, `startCapturing()`, `beginNewScanPass()`, `beginNewScanPassAfterFlip()`, `finish()`, `cancel()`, `pause()`, `resume()`, `stateUpdates`, `feedbackUpdates`, `userCompletedScanPassUpdates`, `numberOfShotsTakenUpdates`, `maximumNumberOfInputImages`; `ObjectCaptureView(session:cameraFeedOverlay:)`; `PhotogrammetrySession(input:configuration:)`, `process(requests: [.modelFile(url: modelURL), .bounds])` (default detail `.reduced`), `outputs` iterated until `.processingComplete` or `.processingCancelled` with `@unknown default`.
**Must NOT do.** Never name a Detail other than `.reduced`; never request `.modelEntity`; release the capture session before creating the PhotogrammetrySession; never reuse a session after `.completed` or `.failed`; never tear down `ObjectCaptureView` repeatedly (pause instead); never add our haptics during capture.
**Self-test.** At least 12 checks: onboarding transitions for flippable and non-flippable objects; feedback mapping through `GuidanceSignals.guidance(for:)`; folder creation empties; preflight threshold.
**SPEC owned.** "OBJECT SCANNING" ("Guide the user around the object", "Move around the object slowly", "Capture the top", "Attempt to separate the target object from its background" (object masking), "Use camera images for textures", textured mesh); "SCANNING MODES" OBJECT.

### 3.34 ObjectModel (wave 5a)

**Purpose.** Object results: load the photogrammetry USDZ with `MDLAsset` into `TriangleMesh`, width, height and depth from the bounds, surface area, volume only when watertight (reason otherwise), untextured variant, the `ExportScene` adapter, the `objectMetrics` step; for large objects, `ObjectIsolation.isolate` on the room mesh cropped to the user box.
**Files.** `ios/Sources/ObjectModel/ObjectModelLoader.swift`, `ObjectDimensions.swift`, `ObjectModelStore.swift`, `ObjectMetricsStep.swift`, `ObjectModelSelfTest.swift`.
**API.**
```swift
struct ObjectDimensionsRecord: Codable, Equatable, Sendable { var width, height, depth: Float; var surfaceArea: Float; var volume: Float?; var volumeUnavailableReason: String?; var box: OrientedBoxRecord }
enum ObjectModelLoader { static func mesh(fromUSDZ url: URL) throws -> MeshWithAttributes }   // MDLAsset childObjects(of: MDLMesh.self)
enum ObjectDimensions { static func measure(_ mesh: MeshWithAttributes) -> ObjectDimensionsRecord; static func isolate(_ roomMesh: MeshWithAttributes, box: OrientedBox) -> ObjectDimensionsRecord? }
final class ObjectMetricsStep: ProcessingStep { init(object: ObjectRecord) }   // id .objectMetrics
```
**Apple APIs.** `MDLAsset(url:)`, `boundingBox`, `childObjects(of:)`, `MDLMesh` vertex and submesh buffers (RESEARCH 3.3 "Reading the finished model").
**Must NOT do.** Never report volume for a non-watertight mesh; never use SceneKit loaders; never use `MDLAsset.export` for USD.
**Self-test.** At least 10 checks with synthetic meshes (box volume, open box reason, gravity-aligned dimensions, isolation of a box on a floor).
**SPEC owned.** "OBJECT SCANNING" (untextured mesh, bounding box, width, height, depth, "estimated volume where mathematically valid"); "MEASUREMENT SYSTEM" (object width, height, depth, surface area, estimated volume).

### 3.35 MeasureTool (wave 5a)

**Purpose.** In-viewer measuring on the finished model: point-to-point, wall length, height, area polygon, angle; snapping through `SnapSet` then the raw mesh hit (`ViewerModel.hitTest`), selection haptic on snap, live labels via `ViewerModel.project`, confidence via `ConfidenceAdapter.distance` with evidence from the quality grid, the measurement list, save and delete through `EditStore.saveMeasurements`.
**Files.** `ios/Sources/MeasureTool/MeasureToolModel.swift`, `MeasureToolOverlay.swift`, `MeasureToolList.swift`, `MeasureToolSelfTest.swift`, `Copy+MeasureTool.swift`.
**API.** `@MainActor final class MeasureToolModel: ObservableObject { init(projectID: UUID, viewer: ViewerModel, snaps: SnapSet, evidence: RoomEvidence); @Published var kind: MeasurementKind; func tap(_ hit: ViewerHit?); func undoPoint(); func clear(); func save(name: String) throws; @Published private(set) var records: [MeasurementRecord] }`, `struct MeasureToolOverlay: View`, `struct MeasureToolList: View`, pure `enum MeasureMath { static func angle(_:_:_:) -> Float; static func polygonArea(_ points: [SIMD3<Float>]) -> Float }`.
**Must NOT do.** Never write measurements into raw; never skip the confidence text.
**Self-test.** At least 10 checks on `MeasureMath` and the snap-to-SnapKind mapping.
**SPEC owned.** "MEASUREMENT SYSTEM" (point-to-point distance, angle, surface area, "Users must be able to manually place measurement points", snapping to corner, wall, edge, floor, ceiling, door, window, object edge); "MEASUREMENT CONFIDENCE" in the tool.

### 3.36 LiveMeasure (wave 5a)

**Purpose.** Quick Measure: `ARView` `.ar` on its own hub with `ScanProfile(mode: .quickMeasure, settings: ScanSettings.defaults(for: .quickMeasure))` (planes on, D14), center reticle, Add Point, raycast snapping (existing points and plane corners within 10 cm or 24 pt, then `.existingPlaneGeometry`, then `.estimatedPlane`), live label, plus or minus from `ConfidenceAdapter.distance` with the center depth sample, and Save that creates a `quickMeasure` project with `raw/measure/quick.json`.
**Files.** `ios/Sources/LiveMeasure/LiveMeasureModel.swift`, `LiveMeasureScreen.swift`, `LiveMeasureSnapping.swift`, `LiveMeasureSelfTest.swift`, `Copy+LiveMeasure.swift`.
**Apple APIs.** `@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]` (ARView, view points); `ARPlaneAnchor` `planeExtent` and `geometry.boundaryVertices`.
**Self-test.** At least 8 checks on snapping order and the saved record.
**SPEC owned.** "SCANNING MODES" QUICK MEASURE; "MEASUREMENT SYSTEM" (point-to-point in the live camera).

### 3.37 PlanEditor (wave 5a)

**Purpose.** Floor plan editing through the EditLog (D3): selection on `PlanCanvasView` hits, move wall (two `moveWallEndpoint`), adjust wall length by typing (`LengthParser`), wall thickness, add and delete wall, add, move and resize doors and windows (CR-1, or delete plus add until then), add opening, flip door swing, rename room, merge and split rooms (CR-1), add and delete measurement and dimension, text annotation, symbol, note, undo and redo (`EditStore.undo`/`redo`), Reset to Scan (appends nothing; clears the log after confirmation), snapping of endpoints to endpoints (50 mm), 0, 45, 90 degrees and a 100 mm or 1 in grid.
**Files.** `ios/Sources/PlanEditor/PlanEditorModel.swift`, `PlanEditorOps.swift`, `PlanEditorToolbar.swift`, `PlanEditorSnapping.swift`, `PlanEditorSelfTest.swift`, `Copy+PlanEditor.swift`.
**API.** `@MainActor final class PlanEditorModel: ObservableObject { init(projectID: UUID); @Published private(set) var plan: PlanModel; @Published var selection: ElementID?; func perform(_ action: PlanEditAction) throws; func undo() throws; func redo() throws; var canUndo: Bool; var canRedo: Bool }`, `enum PlanEditAction` (one case per SPEC edit), pure `enum PlanEditorOps { static func operations(for action: PlanEditAction, in level: PlanLevel) -> [EditOperation] }`.
**Must NOT do.** Never write plan.json (the base stays derived); never touch raw.
**Self-test.** At least 15 checks: every action maps to the expected operations and applies cleanly to a fixture plan through `PlanModel.apply` and `CleanModel.apply`.
**SPEC owned.** "FLOOR PLAN EDITING" (all listed operations; "Manual edits must not overwrite raw scan data"); "2D FLOOR PLAN" ("Allow manual editing").

### 3.38 CoverageOverlay (wave 5b)

**Purpose.** The live colored mesh: one `LowLevelMesh` per anchor with four parts (green, yellow, red, gray `UnlitMaterial`, `blending = .transparent(opacity: 0.45)`), rebuilt from a dirty set at most every 0.33 s on main, skipped outside the frustum, paused at thermal serious; plus the SwiftUI minimap view for room mode (Canvas of `MinimapSnapshot`) and the coverage legend.
**Files.** `ios/Sources/CoverageOverlay/CoverageOverlayRenderer.swift`, `CoverageMinimapView.swift`, `CoverageLegendView.swift`, `CoverageOverlaySelfTest.swift`.
**Apple APIs.** As Viewer3D's LowLevelMesh set (Descriptor capacity 1.5 x faces; recreate only when exceeded).
**Must NOT do.** No `.showSceneUnderstanding` as the user-facing view; no CustomMaterial in the `.ar` view.
**Self-test.** At least 8 checks on face sorting into state parts and capacity growth.
**SPEC owned.** "LIVE SCANNING EXPERIENCE" (GREEN = scanned well, YELLOW = partially scanned, RED = missing information, GRAY = not scanned).

### 3.39 LargeObject (wave 5b)

**Purpose.** Large objects (appliances, vehicles, equipment, D4): the mesh driver with a user-tapped seed, a gravity-aligned `OrientedBox.fit(_:gravityAligned: true)` grown from mesh vertices near the seed above the floor-classified faces, `SectorCoverage` (8 azimuth sectors plus top) raising `objectCaptureLeft`, `objectCaptureRight`, `objectCaptureBack`, `objectCaptureTop`, `objectMoveCloserToArea`, `objectNeedsDetail`, and the crop stored as a `cropObject` edit.
**Files.** `ios/Sources/LargeObject/LargeObjectModel.swift`, `SectorCoverage.swift`, `LargeObjectSeed.swift`, `LargeObjectSelfTest.swift`.
**Self-test.** At least 10 checks on sector assignment, least-covered sector to guidance kind, and box growth.
**SPEC owned.** "OBJECT SCANNING" ("Capture the left side", "Capture the back", "Move closer to this area", "This section needs more detail"; vehicles, appliances, equipment); "SCANNING MODES" OBJECT (large).

### 3.40 MissingAreas (wave 5b)

**Purpose.** Show Missing Areas (D19): from the quality sheet, continue on the same running session in a `MeshScanEngine` patch pass (new mesh-pass folder), tour the missing areas sorted by walking distance with an arrow HUD toward the suggested viewpoint, mark an area filled when coverage reaches it, Next Area, and return to the quality sheet with re-evaluated numbers; windows and mirrors excluded.
**Files.** `ios/Sources/MissingAreas/MissingAreasModel.swift`, `MissingAreasHUD.swift`, `MissingAreasSelfTest.swift`, `Copy+MissingAreas.swift` (uses `Copy.Quality.missingAreaHint`, `missingAreaDone`, `nextMissingArea`, `allAreasDone`, `missingAreaStep(_:of:)`).
**Self-test.** At least 8 checks on ordering, arrow angle and the filled rule.
**SPEC owned.** "SCAN QUALITY SYSTEM" ("Selecting SHOW MISSING AREAS should guide the user directly to locations requiring additional scanning").

### 3.41 HouseUI (wave 5b)

**Purpose.** House and building flow: room list with status ("Kitchen done", "Hallway needs additional scan"), Scan Next Room on the same RoomCaptureView and session (`RoomScanEngine.startNextRoom`), name each room, Rescan, Add Floor, Finish Building (merge through Structure with the "Joining rooms together..." state), `AlignRoomsScreen` for manual alignment (drag, rotate, parallel-wall and doorway snapping) stored as `setRoomAlignment` edits, returning later with world map relocalization (`initialWorldMap`, "Start fresh here" after 30 s), memory eviction per room and the "Finish this floor" suggestion under 800 MB (D17).
**Files.** `ios/Sources/HouseUI/HouseModel.swift`, `HouseScreen.swift`, `AlignRoomsScreen.swift`, `HouseRelocalization.swift`, `HouseUISelfTest.swift`, `Copy+HouseUI.swift` (uses `Copy.House.*`).
**Apple APIs.** `getCurrentWorldMap(completionHandler:)` when `worldMappingStatus` is `.extending` or `.mapped`; `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)`; `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)`; `initialWorldMap`; run with `[.resetTracking, .removeExistingAnchors]` only for a relocalizing new session.
**Self-test.** At least 10 checks on room status text, the memory rule and the relocalization timeout.
**SPEC owned.** "HOUSE / BUILDING MODE" (all, including progress, return to incomplete sections, manual correction); "SCANNING MODES" HOUSE / BUILDING.

### 3.42 ObjectUI (wave 5b)

**Purpose.** The object flow and result: size chooser (small or medium, large), ObjectCapture or LargeObject capture, processing screen with stage and remaining time from `PhotogrammetrySession` outputs, object result in Viewer3D (textured, untextured, box toggle) with width, height, depth, volume or `Copy.Viewer.volumeUnavailable`.
**Files.** `ios/Sources/ObjectUI/ObjectSizeChooser.swift`, `ObjectProcessingScreen.swift`, `ObjectResultScreen.swift`, `ObjectUISelfTest.swift`, `Copy+ObjectUI.swift`.
**SPEC owned.** "OBJECT SCANNING" (outputs and "Object scanning must behave differently from architectural scanning"); "CORE DESIGN PRINCIPLE", Representation E.

### 3.43 Build 5 revisions (waves 5c and 5d)

- Viewer3D (5a): `func loadModel(_ url: URL) async throws` on `ViewerModel` that adds an Object Capture USDZ with `try await Entity(contentsOf: url)` (RESEARCH 3.3, iOS 18.0) under the scene root, frames it and makes it pickable through `MeshBVH` of its loaded mesh; used by ObjectUI (5b).
- ScanUI (5c): wires `CoverageLiveRecorder` into room scans (liveRoomHandler, augmenters), shows the minimap and legend, enables Show Missing Areas; adds the two-pass fallback when `degraded == .meshStripped` (RoomPlan pass, then a same-session mesh and photo pass in LiveMeshView).
- ExportUI (5c): house USDZ through `CapturedStructure.export(to:metadataURL:modelProvider:exportOptions:)` (4-argument form only, RESEARCH 3.2) or `USDZWriter`, one plan PDF page per level, object USDZ as produced by Object Capture; object OBJ, STL, PLY and GLB follow in build 6.
- Results (5c): Measure button (MeasureTool), Edit on the Floor Plan tab (PlanEditor), measurements list, orphaned edits listed (D3).
- HomeUI (5c): House, Object and Quick Measure enabled; house subtitle with room count; needs-work badge.
- AppShell (5d): routes and covers for House, Object, Quick Measure, the missing areas tour and the editors; processing plans for houses (mergeStructure, alignRooms) and objects (reconstructObject, objectMetrics).

---

## Build 6 (0.6)

### 3.44 ProjectOps (wave 6a)

**Purpose.** The full project system: rename, duplicate (new id, raw copied), archive and unarchive, back up and restore with a FileHandle `StreamingZip` (STORE, CRC32 in 1 MB blocks with `CRC32.checksum(_:previous:)`, ZIP64 over 4 GB, D2), restore into a staging folder with validation (path traversal and zip slip rejected, size limits, manifest schema version, SEAL verification) then a move into Projects, and Free up space (confirmed removal of superseded scans or original photos with the warning that Realistic cannot be rebuilt, D6), plus the `.mapperproj` document type declaration (the lead adds the Info.plist keys from RESEARCH 3.9).
**Files.** `ios/Sources/ProjectOps/StreamingZipWriter.swift`, `StreamingZipReader.swift`, `ProjectBackup.swift`, `ProjectRestore.swift`, `ProjectDuplicate.swift`, `ProjectFreeSpace.swift`, `ProjectOpsSelfTest.swift`, `Copy+ProjectOps.swift` (uses `Copy.Project.*`).
**API.** `final class StreamingZipWriter { init(url: URL) throws; func addFile(at: URL, name: String) throws; func finish() throws }`, `final class StreamingZipReader { init(url: URL) throws; var entries: [StreamingZipEntry]; func extract(_ entry: StreamingZipEntry, to: URL) throws }`, `enum ProjectBackup { static func backup(_ id: UUID, to folder: URL) async throws -> URL }`, `enum ProjectRestore { static func restore(from url: URL, asCopy: Bool) async throws -> UUID }`.
**Must NOT do.** Never build a backup in memory (no `ZipWriter` for backups); never write outside the staging folder before validation passes; never follow symlinks in archives.
**Self-test.** At least 20 checks: round trip of a temp package; CRC matches `CRC32`; a `../evil` entry is rejected; a truncated archive fails cleanly; duplicate gets a new id and name `Copy.Project.duplicateName`.
**SPEC owned.** "PROJECT SYSTEM" (rename, duplicate, archive, backup, restore).

### 3.45 ObjectCrop (wave 6a)

**Purpose.** "Allow the user to manually crop unwanted geometry": a draggable box in the viewer; small and medium objects re-run photogrammetry from the kept checkpoint with `PhotogrammetrySession.Request.Geometry(bounds:transform:)` (old model kept until the new one succeeds); large objects apply `MeshCrop.crop` through a `cropObject` edit.
**Files.** `ios/Sources/ObjectCrop/ObjectCropModel.swift`, `ObjectCropBox.swift`, `ObjectCropSelfTest.swift`.
**SPEC owned.** "OBJECT SCANNING" (manual crop).

### 3.46 AdvancedScan (wave 6a)

**Purpose.** The Advanced Scan options screen (what: a space or an object; detail Standard, High, Maximum; keep all photos; find walls, doors and windows; find furniture; scanning distance) producing a `ScanSettings` and the driver choice: space with rooms uses RoomCapture, space without rooms uses LiveMeshView (warehouses, outdoor structures), object uses the object flow.
**Files.** `ios/Sources/AdvancedScan/AdvancedScanModel.swift`, `AdvancedScanScreen.swift`, `AdvancedScanSelfTest.swift` (uses `Copy.Modes.Advanced.*`).
**SPEC owned.** "SCANNING MODES" ADVANCED SCAN; outdoor structures "when technically possible".

### 3.47 ReferenceLength (wave 6a)

**Purpose.** D21: the user enters one tape-measured length for a measured segment (`LengthParser`), the app stores a reversible `setScaleCorrection` edit (factor = tape / measured, allowed 0.9 to 1.1), metrics and plan labels scale, raw never changes; Reset removes it.
**Files.** `ios/Sources/ReferenceLength/ReferenceLengthModel.swift`, `ReferenceLengthSheet.swift`, `ReferenceLengthSelfTest.swift`, `Copy+ReferenceLength.swift`.
**SPEC owned.** "MEASUREMENT CONFIDENCE" (calibration against a known length; never implies survey grade).

### 3.48 BackgroundWork (wave 6a)

**Purpose.** iOS 26 extras behind `if #available(iOS 26.0, *)`: submit a `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` from the user's Finish action for CPU-only steps (never the GPU resource) and report progress from the runner; an experiment flag for `captureHighResolutionFrame(using:)` stills logged against the stream frame (off by default).
**Files.** `ios/Sources/BackgroundWork/BackgroundProcessing.swift`, `HighResolutionStills.swift`, `BackgroundWorkSelfTest.swift`.
**Must NOT do.** Never register the same BGTask identifier twice; never reference iOS 26 symbols outside `#available`.
**SPEC owned.** "LOCAL-FIRST ARCHITECTURE" (on-device processing continues while the app is backgrounded on iOS 26).

### 3.49 Build 6 revisions

- TextureJob (6a): `TextureHighStep` (id `.textureHigh`, budget 1 GB, reduced 500 MB) at `TextureDensity.photoRealistic` with `normalizeExposure = true` (Texturing `TXExposure`), density by `DetailLevel`, reduced variant at 2048 atlases, baking `mesh.mchk` up to 1M faces into `derived/rooms/<r>/texture-high/` (same file names as `texture/`); an atlas streaming callback in Texturing is proposed to the lead first.
- ExportUI (6a): object formats (USDZ as is, OBJ, STL, PLY, GLB from ObjectModel), measurements CSV and a PDF room schedule page, textured OBJ, GLB and USDZ at Photo Realistic, PNG images of the model (`ViewerModel.snapshotJPEG`).
- HomeUI, Results, ScanUI (6b) and AppShell (6c): project menu (rename, duplicate, archive, back up, restore from backup, Free up space), Photo Realistic style, crop, reference length entry, Advanced flow, background processing toggle.

---

## Build 7 (0.7) and build 8 (0.8)

Planned modules, specified in full when their build starts:
- EditMenus (7a): tap an object in 3D Clean: Hide, Delete from Clean Model, Move, Rotate, Measure, Rename, Change Category, Show Raw Geometry; tap a wall: Measure, Adjust, Add Opening, Add Door, Add Window, Hide, Inspect Scan; all through `EditOperation` (`relabelObject`, `recategorizeObject`, `setHidden`, `deleteElement`, `moveObject`, `addOpening`) and `Copy.ObjectMenu`, `Copy.WallMenu`.
- PhotoBrowser (7a): photos and keyframes associated with scan locations; tap a photo to fly the camera to its pose.
- SurfaceEvidence (7a): 5 cm evidence map by BVH ray tests toward keyframe positions (measured, occluded, unscanned, inferred) that drives Hide Furniture honesty and measurement grading.
- SpaceScan (7a): commercial spaces, restaurants, offices and warehouses larger than RoomPlan's limits as several mesh passes in one session with relocalization, merged in MeshModel.
- HeadlessRoom (7a): the D15 experiment behind a Diagnostics flag: `RoomCaptureSession(arSession:)` (iOS 17.0) driven directly with Mapper's own `ARView` in `.ar` mode, the live green, yellow, red and gray `CoverageOverlay` in Room mode and our own coaching banner (RoomPlan `Instruction` mapped through GuidanceUI), re-applying the configuration in `didStartWith` for every room (RESEARCH 3.2 recommended 4). It ships only if device logs from builds 4 to 6 show depth and mesh survive on that path; otherwise Room mode stays on `RoomCaptureView`.
- MeshRefine (8a): mesh-refined wall planes and jambs, counters, cabinets and columns from mesh heuristics with strict acceptance tests, keeping both RoomPlan and refined values.
- LevelsAndStairs (8a): stair links between floors, UP and DN on both levels, level alignment by stairs and exterior walls.

---

## 4. SPEC coverage matrix

Every section and requirement of `docs/SPEC.txt`, the module that owns it and the build it lands in. "b4 (logic), b5 (UI)" means the logic ships first and the user-facing part later. Nothing is deferred silently: items after build 6 name their planned module.

### 4.1 Scope and deliverables (SPEC opening)

| Requirement | Owner | Build |
|---|---|---|
| Scan a single room | RoomCapture, ScanUI | 4 |
| Multiple connected rooms; entire houses and buildings | Structure, HouseUI | 5 |
| Commercial spaces, restaurants, offices | HouseUI (room by room) | 5; very large open areas SpaceScan 7 |
| Warehouses; outdoor structures when technically possible | AdvancedScan (space without rooms, LiveMeshView driver) | 6; SpaceScan 7 |
| Furniture, appliances, equipment, boxes, small and medium objects, arbitrary objects | ObjectCapture, ObjectUI | 5 |
| Vehicles, large appliances and equipment | LargeObject | 5 |
| Use both LiDAR geometry and camera imagery whenever possible | CaptureCore, MeshRecord, Keyframes | 4 |
| Usable by an amateur, advanced functionality available | Copy voice rules everywhere; AdvancedScan | 4; 6 |
| 1 Realistic textured 3D model | TextureJob (Textured), Results | 4; Photo Realistic 6; objects 5 |
| 2 High-detail LiDAR mesh | MeshRecord, MeshModel, Results (Raw Scan) | 4 |
| 3 Clean architectural 3D model | RoomModel, Viewer3D, Results | 4 |
| 4 2D floor plan | FloorPlan, Results | 4 |
| 5 Measurements | MeasureCore, Results; MeasureTool, LiveMeasure | 4; 5 |
| 6 Object dimensions | Results object card (room objects); ObjectModel (scanned objects) | 4; 5 |
| 7 Room dimensions; 9 floor area; 10 ceiling height | RoomModel, MeasureCore, Results | 4 |
| 8 Surface area | wall area in MeasureCore (b4); MeasureTool area, ObjectModel surface area | 4; 5 |
| 11 Distance measurements | MeasureTool, LiveMeasure | 5 |
| 12 Images and photos associated with scanned locations | Keyframes (capture, poses), ScanUI Take Photo; PhotoBrowser (browse) | 4; 7 |
| 13 Editable detected objects | Hide Furniture (b4); fixture move and delete in PlanEditor (b5); EditMenus rename, recategorize, move, rotate, delete | 4; 5; 7 |
| 14 Exportable professional files | ExportUI | 4; remaining formats 6 |

### 4.2 CORE DESIGN PRINCIPLE

| Requirement | Owner | Build |
|---|---|---|
| Multiple representations of the same scan | Store package layout (raw, derived, edits) | 4 |
| A: LiDAR mesh; ARKit anchors; world transforms | MeshRecord (anchor-local chunks with transforms, D8) | 4 |
| A: camera poses; timestamps; device orientation | Keyframes (10 Hz pose track, keyframe poses) | 4 |
| A: camera frames where permitted; depth; confidence; calibration | Keyframes (JPEG, Float16 depth plus confidence, intrinsics per keyframe) | 4 |
| A: feature points; detected planes | Not recorded per frame by design: raw feature points are unstable (RESEARCH 3.8 gotcha 21) and plane detection flattens the raw mesh (D14). The per-session ARWorldMap (feature points and plane anchors) is saved by HouseUI | 5 |
| A: never destroy the original raw scan | Store (sealed folders D5, no thinning D6), every module's "Must NOT do" | 4 |
| B: LiDAR geometry plus RGB imagery, texture projection, texture blending | TextureJob with Texturing | 4 |
| B: photogrammetry where appropriate | ObjectCapture | 5 |
| B: mesh cleanup; hole filling where reasonable (flagged inferred); simplification | MeshModel with MeshProcessing | 4 |
| C: walls, floors, ceilings, doors, windows, openings, stairs where detectable, furniture, appliances, other recognized objects | RoomModel (RoomPlan categories, D12, D13) | 4 |
| C: counters, cabinets (beyond RoomPlan storage), columns, structural features | MeshRefine | 8 |
| D: 2D floor plan from the reconstructed geometry | FloorPlan | 4 |
| E: isolated object model | ObjectCapture, ObjectModel, LargeObject | 5 |

### 4.3 SCANNING MODES

| Requirement | Owner | Build |
|---|---|---|
| Large NEW SCAN button on the home screen | HomeUI | 4 |
| ROOM | ScanUI, RoomCapture | 4 |
| HOUSE / BUILDING | HouseUI | 5 |
| OBJECT | ObjectUI, ObjectCapture, LargeObject | 5 |
| QUICK MEASURE | LiveMeasure | 5 |
| ADVANCED SCAN | AdvancedScan | 6 |
| Sensible defaults chosen automatically | Core `ScanSettings.defaults(for:)`, ScanUI | 4 |
| No need to understand LiDAR, meshes, polygons, SLAM, anchors, point clouds, photogrammetry | Copy (UX_COPY.md voice rules) | 4 onward |

### 4.4 ROOM SCANNING

| Requirement | Owner | Build |
|---|---|---|
| Prioritize walls, floor, ceiling, doors, windows, openings, structural boundaries, furniture, permanent fixtures | RoomCapture, RoomModel | 4 |
| Use RoomPlan where appropriate | RoomCapture (RoomCaptureView, D15) | 4 |
| Use ARKit LiDAR mesh in parallel; do not rely exclusively on RoomPlan | CaptureCore, MeshRecord, Keyframes (same ARSession) | 4 |
| Switch between REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH | Results | 4 |

### 4.5 HOUSE / BUILDING MODE

| Requirement | Owner | Build |
|---|---|---|
| Scan rooms separately and combine into one structure | HouseUI, Structure | 5 |
| Preserve room relationships; maintain coordinate alignment | Structure (FrameLink, alignment D9) | 5 |
| Recognize shared walls | Structure (StructureBuilder, measured thickness from wall pairs) | 5 |
| Detect doorways connecting rooms | Structure (kept door identifiers) | 5 |
| Combine rooms into one building model | Structure, RoomModel | 5 |
| Multiple floors when technically possible | Structure `StructureFloors`, HouseUI Add Floor; stair links LevelsAndStairs | 5; 8 |
| Manual correction when automatic alignment fails | HouseUI `AlignRoomsScreen` | 5 |
| Progress such as "Kitchen done", "Hallway needs additional scan" | HouseUI | 5 |
| Return to incomplete sections | HouseUI (relocalization, Rescan) | 5 |

### 4.6 OBJECT SCANNING

| Requirement | Owner | Build |
|---|---|---|
| Behave differently from architectural scanning | ObjectUI size chooser (D4) | 5 |
| Guide the user around the object; "Move around the object slowly"; "Capture the top" | ObjectCapture (Apple guidance), GuidanceUI | 5 |
| "Capture the left side", "Capture the back", "Move closer to this area", "This section needs more detail" | LargeObject `SectorCoverage` | 5 |
| Separate the target object from its background | ObjectCapture (object masking), ObjectModel `ObjectIsolation` | 5 |
| Camera images for textures | ObjectCapture | 5 |
| Textured mesh, untextured mesh, bounding box, width, height, depth, estimated volume where valid | ObjectModel, ObjectUI | 5 |
| Manually crop unwanted geometry | ObjectCrop | 6 |

### 4.7 IMAGE / TEXTURE CAPTURE

| Requirement | Owner | Build |
|---|---|---|
| Realistic textures from the camera; not a gray mesh | TextureJob | 4 |
| Capture imagery associated with camera poses | Keyframes | 4 |
| Texture the reconstructed mesh | TextureJob, Viewer3D, ExportUI | 4 |
| Overlapping images, perspective differences, texture seams | Texturing (view selection, charts, seam blending) via TextureJob | 4 |
| Exposure differences, lighting changes | TextureJob Photo Realistic with `normalizeExposure` (TXExposure) | 6 |
| Preserve original image quality where practical | Keyframes (full stream resolution, JPEG 0.85, never thinned); high-resolution stills experiment in BackgroundWork | 4; 6 |
| Best available result while preserving geometry | Results fallbacks (RoomPlan model, Solid Color), `Copy.Errors.textureFailed` | 4 |
| PHOTO REALISTIC | TextureJob high density, Viewer3D | 6 |
| TEXTURED, SOLID COLOR, WIREFRAME, RAW MESH | Viewer3D, Results | 4 |

### 4.8 LIVE SCANNING EXPERIENCE

| Requirement | Owner | Build |
|---|---|---|
| Real-time visual guidance | RoomCaptureView coaching (RoomCapture), GuidanceUI banner | 4 |
| See the model forming while walking | RoomCaptureView outlines and mini model (RoomCapture); live colored mesh (CoverageOverlay) | 4; 5 |
| GREEN, YELLOW, RED, GRAY | CoverageLive, CoverageOverlay (colored mesh in mesh-only scans and patch passes, minimap in Room mode); HeadlessRoom (colored 3D overlay in Room mode) | 5; 7 |
| "Move slower", "Move closer", "Too close", "Too far", "Tracking quality is low", "Lighting is poor" | Coverage `GuidanceEngine` fed by RoomCapture | 4 |
| "Window detected", "Door detected", "Wall detected" | RoomCapture detection counts | 4 |
| "Scan this corner", "Point toward the floor", "Scan the ceiling", "This area needs another pass" | CoverageLive (needs live coverage) | 5 |
| Do not overwhelm; only important instructions | GuidancePolicy in `GuidanceEngine`, `GuidanceFilter` | 4 |

### 4.9 SCAN QUALITY SYSTEM

| Requirement | Owner | Build |
|---|---|---|
| Scan-completeness system tracking coverage | Quality (from recorded data); CoverageLive (live) | 4; 5 |
| SCAN QUALITY before finishing: Geometry (Shape), Walls, Floor, Ceiling, Textures, Missing areas | Quality, QualityUI | 4 |
| FINISH ANYWAY | QualityUI | 4 |
| SHOW MISSING AREAS guiding the user to them | MissingAreas | 5 |

### 4.10 AUTOMATIC OBJECT RECOGNITION

| Requirement | Owner | Build |
|---|---|---|
| Detect table, chair, sink, toilet, refrigerator, oven, bed, sofa, TV, stairs, appliance (dishwasher, washer, stove) | RoomModel from RoomPlan categories (`ObjectCategory`) | 4 |
| Detect door, window, wall, floor, ceiling | RoomModel (surfaces; ceiling from mesh class, D13) | 4 |
| Detect cabinet, counter, desk, column | RoomPlan storage and table cover part of it (4); MeshRefine heuristics | 4; 8 |
| Allow the user to correct object labels | EditMenus (relabel, recategorize through EditLog) | 7 |
| Never bake recognition guesses into the raw scan | RoomModel (derived only), EditLog overlays | 4 |

### 4.11 FURNITURE REMOVAL

| Requirement | Owner | Build |
|---|---|---|
| HIDE FURNITURE hides movable objects in the clean model | Results (layer), FloorPlan (furniture toggle) | 4 |
| Mark blocked regions as INFERRED, OCCLUDED or UNSCANNED; do not fabricate | RoomModel occlusion heuristic drawn dashed (4); SurfaceEvidence evidence map | 4; 7 |
| Distinguish estimated from measured geometry | `Provenance` on every value, MeasureDisplay texts, inferred hole faces in MeshModel | 4 |

### 4.12 MEASUREMENT SYSTEM

| Requirement | Owner | Build |
|---|---|---|
| Wall length, wall height, ceiling height, door width and height, window dimensions, room length, width, area, floor area, wall area, perimeter, estimated volume (room) | RoomModel, MeasureCore, Results | 4 |
| Object width, height, depth | Results object card (room objects); ObjectModel | 4; 5 |
| Point-to-point distance, angle, surface area | MeasureTool, LiveMeasure | 5 |
| Estimated volume (objects) | ObjectModel | 5 |
| Feet and inches and metric; preference switching | Units, MeasureDisplay, AppShell Settings | 4 |
| Manually placed measurement points | MeasureTool, LiveMeasure | 5 |
| Snapping to corner, wall, edge, floor, ceiling, door, window, object edge | MeasureCore `SnapSet` (logic 4); MeasureTool, LiveMeasure (UI 5) | 4; 5 |

### 4.13 MEASUREMENT CONFIDENCE

| Requirement | Owner | Build |
|---|---|---|
| Show measurement confidence ("Estimated accuracy ±0.6\"") | MeasureCore, Results | 4 |
| "Low confidence, rescan this section" | MeasureCore `MeasureDisplay.isLowConfidence` | 4 |
| Never imply survey-grade accuracy | MeasureCore (3 cm RoomPlan floor), `Copy.Measure.disclaimer` | 4 |
| Calibrate with one known length | ReferenceLength (D21) | 6 |

### 4.14 2D FLOOR PLAN

| Requirement | Owner | Build |
|---|---|---|
| Automatic clean plan with walls, doors, windows, openings, room names, room dimensions, overall dimensions, fixtures, stairs, bathroom fixtures, kitchen equipment | FloorPlan | 4 |
| Wall thickness where determinable | FloorPlan (estimated, 4); Structure measured wall pairs | 4; 5 |
| Door swing direction when known | RoomModel default (estimated, 4); PlanEditor Flip Door Swing | 4; 5 |
| Counters | MeshRefine | 8 |
| Toggles: Furniture, Measurements, Room names, Doors/windows, Fixtures, Grid, Scale | FloorPlan `PlanToggles`, Results | 4 |
| Allow manual editing | PlanEditor | 5 |

### 4.15 FLOOR PLAN EDITING

| Requirement | Owner | Build |
|---|---|---|
| Move wall, adjust wall length, change wall thickness, add wall, delete wall | PlanEditor | 5 |
| Add, move, resize door; add, move, resize window; add opening | PlanEditor (move and resize via CR-1) | 5 |
| Rename room | PlanEditor | 5 |
| Merge rooms, split room | PlanEditor (needs CR-1) | 5 |
| Add and delete measurement; add text annotation, symbol, notes | PlanEditor | 5 |
| Manual edits must not overwrite raw scan data | EditLog overlays (Store, RoomModel, FloorPlan) | 4 |

### 4.16 3D EDITING

| Requirement | Owner | Build |
|---|---|---|
| Tap objects | Results (read-only card with category guess and size) | 4 |
| Object: Hide, Delete from clean model, Move, Rotate, Rename, Change category, Show raw geometry | EditMenus | 7 |
| Object: Measure | MeasureTool (5); from the object menu in EditMenus (7) | 5; 7 |
| Wall: Measure | MeasureTool | 5 |
| Wall: Adjust, Add opening, Add door, Add window | PlanEditor (plan, 5); EditMenus wall menu (3D, 7) | 5; 7 |
| Wall: Hide, Inspect geometry | EditMenus | 7 |

### 4.17 PROJECT SYSTEM

| Requirement | Owner | Build |
|---|---|---|
| Stored locally by default; no account, subscription or cloud | Store, AppShell | 4 |
| Projects list | HomeUI | 4 |
| Each project contains its original scan data and derived models | Store (package layout) | 4 |
| Delete; export | HomeUI; ExportUI | 4 |
| Rename, duplicate, archive, backup, restore | ProjectOps (rename API in Store from 4) | 6 |

### 4.18 LOCAL-FIRST ARCHITECTURE

| Requirement | Owner | Build |
|---|---|---|
| Works offline after installation | all modules (no network code; only the opt-in token-protected DebugServer) | 4 |
| Prefer on-device processing | Pipeline, MeshModel, TextureJob, ObjectCapture (on-device photogrammetry) | 4; 5 |
| No AWS, Azure, Firebase, Supabase, subscription APIs or paid AI services | enforced by rule 0.2 (native frameworks only, no packages) | 4 |
