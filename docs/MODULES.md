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
2. UI models are `@MainActor final class X: ObservableObject` with `@Published` properties. SwiftUI views are structs. `ObservableObject` and `@Published` come from Combine: write `import Combine` (or `import SwiftUI`) in every file that declares one; Foundation and UIKit do not re-export them.
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
| Store | Store | 4 | 4a | Core, Support; Combine | to build |
| CaptureCore | CaptureCore | 4 | 4a | Core, Support; ARKit, UIKit | to build |
| RoomModel | RoomModel | 4 | 4a | Core, Geometry, MeshProcessing, Support; RoomPlan | to build |
| MeshModel | MeshModel | 4 | 4a | Core, Geometry, MeshProcessing, Export, Support | to build |
| Pipeline | Pipeline | 4 | 4a | Core, Support; UIKit, Combine | to build |
| MeasureCore | MeasureCore | 4 | 4a | Core, Geometry, Coverage, Units, Support | to build |
| FloorPlan | FloorPlan | 4 | 4a | Core, Geometry, Export, Units, Support; SwiftUI, CoreGraphics, UIKit, ImageIO | to build |
| Viewer3D | Viewer3D | 4 | 4a | Core, Geometry, MeshProcessing, Support; RealityKit, SwiftUI, UIKit, ImageIO | to build |
| GuidanceUI | GuidanceUI | 4 | 4a | Core, Coverage, Support; SwiftUI, ARKit, RoomPlan, RealityKit | to build |
| Export revision (3.18a) | Export | 4 | 4a | none; UIKit, CoreGraphics | to build |
| MeshRecord | MeshRecord | 4 | 4b | Core, Geometry, CaptureCore, Store, Support; ARKit | to build |
| Keyframes | Keyframes | 4 | 4b | Core, CaptureCore, Store, Texturing, Export (ByteWriter), Support; ARKit, CoreImage, CoreVideo | to build |
| RoomCapture | RoomCapture | 4 | 4b | Core, CaptureCore, Store, RoomModel, GuidanceUI, Coverage, Support; ARKit, RoomPlan, SwiftUI | to build |
| Quality | Quality | 4 | 4b | Core, Coverage, RoomModel, MeshModel, MeasureCore, Store, MeshProcessing, Support | to build |
| TextureJob | TextureJob | 4 | 4b | Core, Texturing, MeshModel, MeshProcessing, Store, Export (ByteWriter), Support; ImageIO, CoreGraphics | to build (types and store never slip; only the step may) |
| HomeUI | HomeUI | 4 | 4b | Core, Store, Pipeline, Units, Support; SwiftUI | to build |
| ScanUI | ScanUI | 4 | 4c | Core, CaptureCore, Store, Pipeline (IdleTimerGuard), RoomCapture, MeshRecord, Keyframes, Quality, GuidanceUI, RoomModel, MeshModel, FloorPlan, Units, Support; SwiftUI, AVFoundation, ARKit, RoomPlan | to build |
| QualityUI | QualityUI | 4 | 4c | Core, Quality, Support; SwiftUI | to build |
| Results | Results | 4 | 4c | Core, Store, Pipeline, RoomModel, MeshModel, FloorPlan, MeasureCore, Viewer3D, Quality, TextureJob, Units, Support; SwiftUI, RoomPlan, QuickLook | to build |
| ExportUI | ExportUI | 4 | 4c | Core, Export, Store, RoomModel, MeshModel, FloorPlan, MeasureCore, Quality, TextureJob, Units, Support; SwiftUI, UIKit, RoomPlan | to build |
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
| Texturing revision | Texturing | 6 | 6a | none; CoreGraphics (atlas streaming callback, accepted by the lead) | to build |
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

Membership follows the real dependencies in the module index (section 1), which differ from the example lists in the lead decision in four places: AppShell is the composition root that imports every build 4 screen, so it cannot sit in the same wave as the screens it composes and gets its own final wave 4d; the screens it composes (ScanUI, QualityUI, Results, ExportUI) are wave 4c and talk to each other only through closures that AppShell wires; HomeUI needs only Store and Pipeline (4a), so it moved to 4b (lead decision 7, dependencies verified); and GuidanceUI and FloorPlan depend on no other new build 4 module, so they are 4a, not 4b.

### 2.1 Build 4 (0.4), room MVP

```
wave 0 (merged on integration): Support Units Geometry Export Core Coverage MeshProcessing Texturing

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
  Export rev.  ios/Sources/Export       <- (none)   DXF in millimeters with a units note (3.18a)   60

wave 4b (imports wave 0 and 4a)
  MeshRecord   ios/Sources/MeshRecord   <- CaptureCore Store  (+ Core Geometry Support)       500
  Keyframes    ios/Sources/Keyframes    <- CaptureCore Store Texturing  (+ Core Export Support)  900
  RoomCapture  ios/Sources/RoomCapture  <- CaptureCore Store RoomModel GuidanceUI Coverage  (+ Core Support)  1200
  Quality      ios/Sources/Quality      <- RoomModel MeshModel MeasureCore Store Coverage MeshProcessing  (+ Core Support)  800
  TextureJob   ios/Sources/TextureJob   <- MeshModel Store Texturing MeshProcessing  (+ Core Export Support)  700
  HomeUI       ios/Sources/HomeUI       <- Store Pipeline                       500

wave 4c (imports wave 0, 4a, 4b; never another 4c module)
  ScanUI       ios/Sources/ScanUI       <- RoomCapture MeshRecord Keyframes Quality CaptureCore GuidanceUI Store Pipeline RoomModel MeshModel FloorPlan  1300
  QualityUI    ios/Sources/QualityUI    <- Quality                              400
  Results      ios/Sources/Results      <- Viewer3D FloorPlan MeasureCore RoomModel MeshModel Store Pipeline Quality TextureJob  1300
  ExportUI     ios/Sources/ExportUI     <- MeshModel RoomModel FloorPlan MeasureCore Store Quality TextureJob Export  1100

wave 4d
  AppShell     ios/Sources/AppShell     <- all of the above; edits ContentView.swift, MapperApp.swift  1300
```

Line counts are estimates of Swift excluding the self-test; a module that grows past about 1500 lines is split into two files groups on the same branch, never into a same-wave dependency.

Why no module depends on its own wave: in 4a every dependency is a wave 0 module (checked per row; the Export revision changes only Export's own files). In 4b, HomeUI needs only Store and Pipeline, and recorders (MeshRecord, Keyframes) plug into RoomCapture only through the `ScanRecorder` protocol of CaptureCore (4a), so RoomCapture never imports them; ScanUI (4c) creates them and hands them to the engine. Quality and TextureJob read the consolidated mesh through MeshModel (4a) and never call RoomCapture. In 4c, the quality sheet (QualityUI) is presented over the scan screen (ScanUI) by AppShell, and the export sheet (ExportUI) is presented from the result screen (Results) by AppShell through an `onExport` closure that carries an `ExportViewState` (declared in FloorPlan, 4a, so neither screen imports the other). Pipeline steps of 4a modules that need another 4a module's output (CleanModelStep needs the consolidated mesh) receive it through an injected closure; AppShell's `ProcessingPlans` wires it.

What an amateur can do after build 4: create a project and scan one room with Apple's RoomCaptureView (live outlines, coaching, wall, door, window and object detection) on an app-owned ARSession that also records the LiDAR mesh, texture keyframes and a pose track; see the scan quality sheet (Shape, Walls, Floor, Ceiling, Color and texture, Missing areas) over the live camera and Finish or Finish Anyway; open the result screen with Realistic, 3D Clean, Floor Plan and Raw Scan (Realistic is the textured mesh when TextureJob finishes, otherwise RoomPlan's own model in Quick Look, otherwise an honest "Color is still being added"); read room length, width, floor area, perimeter, ceiling height, wall, door and window sizes with plus or minus confidence in feet and inches and metric; find the project on Home, rename or delete it; export USDZ, OBJ, PLY, STL, GLB, PDF, SVG, DXF, PNG and JSON; run Settings > Diagnostics (capability probe, all self-tests) and Demo Mode (FakeScanEngine) with no ARKit.

TextureJob is split so a slip cannot break wave 4c: `TextureJobTypes.swift` and `TextureStore.swift` (`TextureDensity`, `TexturedMesh`, `TexturedPagePart`, `pageParts()`, `TextureStore` with `encodeUV`, `decodeUV`, `load`, `exists`) never slip and must merge in 4b, because Results and ExportUI (4c) import them. Only `TextureLowStep` and `KeyframeLoader` may slip. On a slip AppShell leaves `TextureLowStep` out of `ProcessingPlans`, Results and ExportUI see `TextureStore.exists == false` and show the fallback, and the step lands in build 5 wave 5a.

Wave gates: every module of a wave branches `impl/<module>` from the `integration` head on which the previous wave is merged and green, compiles on its branch through `workflow_dispatch` until green (with its self-test), and merges one at a time with `integration` compiled green after each merge. The lead then adds the module's `SelfTestSuite` line. After wave 4d the lead bumps `MARKETING_VERSION` to 0.4 and `CURRENT_PROJECT_VERSION` in `ios/project.yml`.

Build 4 acceptance on the phone (`docs/TEST_PLAN.md`), with the build 4 variant stated where the test names a later feature:
- As written: MODE-01, MODE-02 and MODE-03 (Room only; other modes show "Coming in a later version"), MODE-04, MODE-05, ROOM-01 to ROOM-05, TEX-01 (when TextureLowStep landed), TEX-06, QUAL-04, REC-01, REC-05, FURN-01, FURN-02, FURN-04, MEAS-02 to MEAS-06, MEAS-09, MEAS-11, CONF-01 to CONF-04, PLAN-01 to PLAN-04, PLAN-06, EDIT3D-01 (read-only object card), EDIT3D-06, PROJ-01, PROJ-05, PROJ-07, PROJ-09, OFF-02 to OFF-04, EXP-01, EXP-02 (untextured unless TextureLowStep landed), EXP-03, EXP-04, EXP-06, EXP-07, EXP-10, LIVE-01, LIVE-06, LIVE-07, LIVE-08, LIVE-10.
- Build 4 variants: QUAL-01 without the Show Missing Areas button; QUAL-02 as two separate scans (walls only, then a full scan); ROOM-11 with Keep Scanning continuing the scan and Done saving the partial room (Discard leaves no project); TEX-02 with four modes (Photo Realistic shows `Copy.Results.photoRealisticLater`); OFF-01 without plan editing and in-model measuring; EXP-05 without annotations.
- Performance: TEST_PLAN sections 4.2 to 4.9 except PERF-03, PERF-10, PERF-25 (House mode) and PERF-28 (plan edits).
- Smoke list (section 5): all checks except the Show Missing Areas button in #4, #6 (Quick Measure), #8 (plan edit) and #9 (object scan).
- N/A in build 4: REC-03 (label correction, build 7), EXP-09 (House mode), PERF-03, PERF-10, PERF-25, PERF-28.
The same notes belong in TEST_PLAN.md 0.3 so the tester marks these N/A rather than S1 or S2 failures (the lead updates TEST_PLAN.md).

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
  (TextureJob's TextureLowStep and KeyframeLoader, only if they slipped from build 4)
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
  Texturing rev.   <- (none)  atlas streaming callback so finished atlases go to disk (accepted by the lead)
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

Core changes for build 4 (CR-2, CR-4, CR-5 and CR-6 below) were applied on `integration` by the design review before wave 4a; every build 4 contract in this file compiles against Core as it is now. No further Core change is needed for build 4.

- CR-1 (Core, approved for build 5; the lead applies it before wave 5a, PlanEditor): `EditOperation` gains `moveOpening(opening: ElementID, offset: Float)`, `resizeOpening(opening: ElementID, width: Float, sillHeight: Float, headHeight: Float)`, `mergeRooms(rooms: [ElementID], into: ElementID)`, `splitRoom(room: ElementID, line: [Vec2], newRoom: ElementID)`, each with `targets` entries, and RoomModel and FloorPlan revisions apply them in 5a. Build 4 writes no edits, so nothing waits on it.
- CR-2 (Core, applied): one low-confidence rule everywhere. `MeasuredValue.isLowConfidence(length:)` implements "2 sigma above max(4 cm, 3 percent of the length)" for lengths and "2 sigma above 3 percent of the value" for areas and volumes (`length: nil`); `isLowConfidence(kind:)` picks the variant from a `MeasurementKind`, and the `isLowConfidence` property treats the value as a length. MeasureCore's `MeasureDisplay.isLowConfidence(_:length:)` delegates to it, and every screen goes through MeasureDisplay.
- CR-3 (MeshProcessing): done. `MeshChunk` was renamed `MergeChunk`, and `Cleanup.swift` (`MeshCleanup`) and `ObjectIsolation.swift` (`ObjectIsolation`) are merged. Code against the names in 3.8.
- CR-4 (Core, applied): `RawScanFolder.resolve(_:) -> URL?` returns nil for absolute paths, `..`, `.` or empty components, backslashes, NUL bytes and anything outside the folder (`RawScanFolder.isSafeRelativePath(_:)` is the pure rule); `ProjectStore.readJSON(_:from:maxBytes:)` throws `CoreError.fileTooLarge(name:bytes:)` above `maxBytes` (default `ProjectStore.defaultMaxJSONBytes`, 32 MB; `readManifest` uses `maxManifestBytes`, 1 MB); `listProjects()` lists only folders named exactly `<UUID>.mapperproj` (`ProjectStore.projectID(fromPackageName:)`) whose manifest id matches; `ProjectStore.writeData(_:to:protection:createParents:)` keeps `.atomic` and adds `ProjectStore.defaultProtection(for:)` when `protection` is nil: `.completeFileProtectionUnlessOpen` under a package's `edits/` and `exports/` and for `thumbnail.jpg`, the system default for raw and derived. `ProjectStore.inProgressRoot()` re-applies backup exclusion on every call.
- CR-5 (Core, documentation, applied): the `ProjectPackage` doc comment places the Object Capture checkpoint at `derived/objects/<id>/checkpoint/` (section 3.33) and lists the per-module derived files of section 3.1.
- CR-6 (Core, applied by the design review): `writeData(... createParents: false)` refuses to recreate a missing parent folder and `ProjectStore.ensureDirectory(_:inside:)` creates a derived folder only while the package root exists (late writes after a discard or delete, 3.10); `ProjectPackage.pipelineAttemptURL` (`derived/pipeline_attempt.json`, 3.15); `RawScanFolder.liveCapturedRoomURL` (`capturedroom-live.json`) and `RawScanFolder.worldMapURL` (`worldmap.arworldmap`) (3.21); `MapperError.lowMemory` (3.21); `CoreError.fileTooLarge`; `ScanEngine.discard()` (3.21, 3.24; `FakeScanEngine.discard()` equals `cancel()`); doc comments on `ProjectStatus.capturing`, `PlanModel.northAngle` (counter-clockwise from plan +y) and `ObjectCategory` display names.

### 3.1 Derived and raw file contract (all modules)

Paths below are relative to the project package (`ProjectPackage.root`). Core names the top-level ones; the producing module owns the others and exposes a loader. A consumer in a later wave calls the loader; a consumer in the same wave gets the data through an injected closure.

| Path | Producer | Loader for consumers |
|---|---|---|
| `raw/sessions/<s>/rooms/<r>/` (sealed, `RawScanFolder` names, plus `scan.json`) | RoomCapture via Store | Store `RawScanReader` |
| `raw/sessions/<s>/rooms/<r>/mesh/<anchor>.mchk` | MeshRecord | Store `RawScanReader.meshChunks()`, or Core `MeshChunkFile.decode` |
| `raw/sessions/<s>/rooms/<r>/keyframes.jsonl`, `keyframes/NNNNN.jpg`, `depth/NNNNN.dpth`, `poses.ptrk`, `photos.jsonl`, `photos/<id>.jpg` | Keyframes | Store `RawScanReader` |
| `raw/sessions/<s>/rooms/<r>/capturedroomdata.json`, `capturedroom.json`, `capturedroom-live.json` (provisional, rewritten during capture), `worldmap.arworldmap` (best effort), `roomlog.json`, `events.jsonl`; `raw/sessions/<s>/session.json` | RoomCapture | RoomModel `CapturedRoomStore`, Store `RawScanReader` |
| `derived/index.json`, `derived/pipeline_attempt.json` | Pipeline | Core `DerivedIndex` via `ProjectStore.readJSON`; the attempt marker is Pipeline-private |
| `derived/rooms/<r>/capturedroom.json` (only when raw lacks it) | RoomModel `BuildRoomStep` | RoomModel `CapturedRoomStore` |
| `derived/rooms/<r>/mesh.mchk`, `mesh_inferred.mchk`, `mesh_view.mchk`, `mesh_floaters.mchk`, `mesh_stats.json` | MeshModel | MeshModel `MeshModelStore` |
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

Input hashes (D11): a step hashes the `SealFile`s of the raw folders it reads with `InputHasher.hash(seals:editRevision:extra:)`; a step that reads another step's output also adds that step's current stamp `inputHash` (read from `derived/index.json` with `ProjectStore.readJSON(DerivedIndex.self, from:)`, `"-"` when there is none) to `extra`, so it reruns when its input was rebuilt (for example `CleanModelStep` adds the room's `consolidateMesh` stamps, `FloorPlanStep` the `cleanModel` stamp, `TextureLowStep` the room's `consolidateMesh` stamp, `QualityStep` the room's `buildRoom` and `consolidateMesh` stamps). Only steps that read edits pass `EditLog.revision` (build 4: `ThumbnailStep`).

Writes: raw files go through Store's `RawScanWriter` with `createParents: false`; derived writers create their folder with `ProjectStore.ensureDirectory(_:inside: package.root)` and write with `ProjectStore.writeData(_:to:protection:createParents: false)`, so a step or recorder that finishes after its project or scan was deleted fails instead of recreating the folder (CR-6). `edits/`, `exports/` and `thumbnail.jpg` get `.completeFileProtectionUnlessOpen` automatically (CR-4).

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
- `DXFWriter.data(for: Plan2D) throws -> Data` (R12, no `$INSUNITS`, D23). As merged it writes 1 drawing unit = 1 meter and no units note; the wave 4a Export revision (3.18a) adds `DXFWriter.data(for:millimeters:unitsNote:)` (millimeters by default plus one TEXT note), which is what ExportUI calls. `SVGWriter.data(for: Plan2D, options: SVGWriter.Options = .init()) throws -> Data`; `PDFPlanWriter.data(for: Plan2D, options: PDFPlanWriter.Options = .init()) throws -> Data` with `Options(paper: .usLetter or .a4, date:, northAngle:, lineWidth:, scaleCaption:)`, where `northAngle` is measured counter-clockwise from plan +x and defaults to `Double.pi / 2` (plan up is north); scale chosen automatically from `quarterInch`, `eighthInch`, `oneToFifty`, `oneToHundred`.
- `enum ExportError: Error, LocalizedError` (validation and write failures).

### 3.6 Core (merged, build 4 wave 0)

Imports Foundation and simd only (RoomPlan in `ObjectCategory+RoomPlan.swift`). Everything Codable is also Sendable and Equatable unless noted.
- Identity: `struct ElementID: Codable, Hashable { var uuid: UUID; var roomPlanID: UUID?; init(uuid: UUID = UUID(), roomPlanID: UUID? = nil); static func derived(fromRoomPlan id: UUID) -> ElementID }` (equality by `uuid`); `enum FrameLink { case projectFrame(sessionID: UUID), relocalized(sessionID: UUID, from: UUID), manual, unaligned; var sessionID: UUID?; var mayShareFrame: Bool }`.
- Codable math: `Vec2 { x, y; init(_ v: SIMD2<Float>); var simd }`, `Vec3 { x, y, z; init(_ v: SIMD3<Float>); var simd }`, `Transform4 { init(_ t: simd_float4x4); init?(elements: [Float]); var simd: simd_float4x4; var translation: SIMD3<Float>; static let identity }`, `OrientedBoxRecord { init(_ box: OrientedBox); var orientedBox }`, `Intrinsics { fx, fy, cx, cy: Float; width, height: Int; init(fx:fy:cx:cy:width:height:); init(matrix: simd_float3x3, width: Int, height: Int); var matrix; func scaled(toWidth:height:); func project(cameraPoint:) -> SIMD2<Float>?; func project(worldPoint:cameraToWorld:) -> SIMD2<Float>?; func unproject(pixel:depth:) -> SIMD3<Float>; func contains(pixel:) -> Bool }` (camera looks down -Z, v grows downward).
- Errors: `enum MapperError: Error { case lowStorage(freeBytes: Int64), unsupportedDevice, cameraDenied, trackingFailed, deviceTooHot, lowMemory, sceneTooLarge, roomPlanFailed(String), objectCaptureFailed(String), processingFailed(step: PipelineStepID, reason: String), outOfMemory(step: PipelineStepID), corruptProject(String), ioFailed(String), cancelled; var copyKey: String }` (`copyKey` is for logs; screens map cases to Copy with an exhaustive switch, 3.24 `ScanErrorCopy`); `enum CoreError: Error { case corruptFile(String), missingFile(String), unsupportedSchema(Int), fileTooLarge(name: String, bytes: Int64) }`.
- Project: `struct ProjectManifest { static let currentSchema = 1, currentPipelineVersion = 1; var schemaVersion, id, name, kind: ScanMode, createdAt, modifiedAt, isArchived, pipelineVersion, sessions: [CaptureSessionRef], rooms: [RoomRecord], objects: [ObjectRecord], floors: [FloorRecord], status: ProjectStatus, reconstructionPending: Bool, settings: ScanSettings; static func new(kind:name:now:) -> ProjectManifest }`; `enum ScanMode { room, house, object, quickMeasure, advancedSpace, advancedObject }`; `enum ProjectStatus { capturing, needsProcessing, processing, ready, needsAttention }`; `struct CaptureSessionRef { id, startedAt, frameLink, worldMapFile: String? }`; `struct RoomRecord { id, name, sessionID, floorIndex, status: RoomStatus, capturedRoomID: UUID?, quality: QualitySummary?, hasMeshPass, keyframeCount, capturedAt, frameLink }`; `enum RoomStatus { capturing, captured, needsRescan, processed, failed }`; `struct ObjectRecord { id, name, size: ObjectSize, status, imageCount, modelFile: String? }`; `enum ObjectSize { smallMedium, large }`; `struct FloorRecord { id: Int, name, elevation }`; `struct QualitySummary { shape, walls, floor, ceiling, texture: Double (0...1); missingAreas: Int; verdict: QualityVerdict; init(shape:walls:floor:ceiling:texture:missingAreas:) }`; `enum QualityVerdict { good, okay, poor; static func from(...) }`; `struct ScanSettings { detail: DetailLevel, keepAllPhotos, findRooms, findFurniture, distance: ScanDistance; static let room; static func defaults(for: ScanMode); var keyframeGate: (meters: Float, degrees: Float); var depthWindow: ClosedRange<Float> }`.
- Package: `struct ProjectPackage { static let fileExtension = "mapperproj"; let root; init(root:); manifestURL, thumbnailURL, rawURL, sessionURL(_:), sessionRecordURL(_:), worldMapURL(session:), rawRoomURL(session:room:), rawMeshPassURL(session:pass:), rawObjectURL(_:), quickMeasureURL, derivedURL, derivedIndexURL, pipelineAttemptURL, derivedRoomURL(_:), derivedObjectURL(_:), cleanModelURL, planModelURL, structureURL, capturedStructureURL, alignmentURL, editsURL, editLogURL, measurementsURL, exportsURL, sealURL(in:) }`; `struct RawScanFolder { let url; init(url:); sealURL, capturedRoomDataURL, capturedRoomURL, liveCapturedRoomURL, worldMapURL, roomLogURL, poseTrackURL, keyframesLogURL, eventsLogURL, photosLogURL, meshURL; func meshChunkURL(anchor:) -> URL; static func keyframeImagePath(_ index: Int) -> String; static func depthPath(_:) -> String; static func photoPath(_ id: UUID) -> String; func resolve(_ relativePath: String) -> URL? (nil when unsafe, CR-4); static func isSafeRelativePath(_ path: String) -> Bool }`.
- `enum ProjectStore` (thread-safe, all static): thresholds `refuseScanBelowBytes` (1.5 GB), `warnScanBelowBytes` (3 GB), `stopKeyframesBelowBytes` (1 GB), `pauseCaptureBelowBytes` (300 MB), `objectCapturePreflightBytes` (3 GB), `defaultMaxJSONBytes` (32 MB), `maxManifestBytes` (1 MB); `encoder`, `decoder`; `projectsRoot() throws -> URL`; `inProgressRoot() throws -> URL` (backup exclusion re-applied); `ensureDirectory(_:)`; `ensureDirectory(_:inside root: URL)` (only while `root` exists); `package(for id: UUID) throws -> ProjectPackage`; `projectID(fromPackageName:) -> UUID?`; `create(kind:name:now:) throws -> (ProjectPackage, ProjectManifest)`; `readManifest(_:)`, `writeManifest(_:to:)`, `listProjects() -> [ProjectManifest]` (well-formed names, manifest id must match); `writeJSON(_:to:protection: Data.WritingOptions? = nil, createParents: Bool = true)`, `readJSON(_:from:maxBytes: Int64 = defaultMaxJSONBytes)`, `writeData(_:to:protection: Data.WritingOptions? = nil, createParents: Bool = true)` (atomic; nil protection means `defaultProtection(for:)`); `defaultProtection(for: URL) -> Data.WritingOptions`; `freeBytes() -> Int64`; `excludeFromBackup(_:)`; `sealRawFolder(_:now:) -> SealFile` (never recreates the folder); `verifyRawFolder(_:) -> [String]`.
- Raw records: `KeyframeRecord { index, timestamp, transform: Transform4, intrinsics, imageFile, depthFile: String?, exposureDuration: Double, exposureOffset: Float, ambientIntensity: Float, angularSpeed: Float, trackingNormal: Bool }`; `PhotoPin { id, timestamp, transform, intrinsics, imageFile, note }`; `CaptureEvent { t: Double, kind: CaptureEventKind, detail }`; `enum CaptureEventKind { tracking, thermal, instruction, error, config, memory, degraded, relocalization, note }`; `CaptureSessionRecord { id, osVersion, deviceClass, configLog: [String] }`; `RoomCaptureLog { seconds, instructionSeconds: [String: Double], error: String?, relocalizations, limitedTrackingFraction, degraded: DegradedMode }`; `enum DegradedMode { allGood, depthStripped, meshStripped, roomPlanFailed }`; `SealFile { static let fileName = "SEAL.json"; sealedAt; files: [SealEntry]; static func make(folder:now:); func verify(folder:) -> [String] }`; `struct PoseSample { timestamp: Double; transform: simd_float4x4; tracking: UInt8 (0 n/a, 1 limited, 2 normal); thermal: UInt8; exposureDuration: Float }` (not Codable).
- Binary: `struct MeshChunk { anchorID: UUID; transform: simd_float4x4; updateCount: UInt32; positions, normals: [SIMD3<Float>]; indices: [UInt32]; classes: [UInt8]; init(anchorID:transform:updateCount:positions:normals:indices:classes:); var faceCount; var worldPositions; func toTriangleMesh(world: Bool) -> TriangleMesh }` (anchor-local; no explicit `Sendable`, which Swift 5 mode does not require for the queue hops in this file); `enum MeshChunkFile { static func encode(_:) -> Data; static func decode(_:) throws -> MeshChunk }`; `struct DepthMap { width, height, depth: [Float], confidence: [UInt8]; func depthAt(x:y:) -> Float? }`; `enum DepthFile { static func encode(width:height:depth:confidence:) -> Data; static func decode(_:) throws -> DepthMap }`; `enum PoseTrackFile { static let recordSize = 78; static func appendHeader(to: inout ByteWriter); static func append(_: PoseSample, to: inout ByteWriter); static func decode(_:) throws -> [PoseSample] }`; `struct CoreByteReader`.
- Live scan: `enum TrackingSummary { normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, limited, notAvailable }`; `enum ThermalLevel { nominal, fair, serious, critical; init(_ state: ProcessInfo.ThermalState) }`; `enum MinimapCell: UInt8`; `struct MinimapSnapshot`; `struct LiveScanSnapshot { timestamp, elapsed, tracking, degraded, guidanceRawValue: String?, wallCount, doorCount, windowCount, openingCount, objectCount, meshFaceCount, keyframeCount, photoCount, coverageFraction: Float, thermal, freeBytes: Int64, availableMemory: UInt64, minimap: MinimapSnapshot?; var guidance: GuidanceKind? }` (all fields have defaults); `enum ScanEngineState { idle, starting, scanning, paused, stopping, finished, failed }`; `enum ScanEngineEvent { case snapshot(LiveScanSnapshot), roomFinished(roomID: UUID), failed(MapperError), stateChanged(ScanEngineState) }`; `protocol ScanEngine: AnyObject { var state: ScanEngineState { get }; var onEvent: ((ScanEngineEvent) -> Void)? { get set }; func start() throws; func pause(); func resume(); func finish(); func cancel(); func discard() }` (call from main; events on main; `state` written on main only; `cancel` keeps InProgress for recovery after an ordered stop, `discard` then deletes it and reports `.stateChanged(.idle)` last); `struct SnapshotRecording { snapshots; static func decodeJSONLines(_:) throws; func encodeJSONLines() throws -> Data; static func synthetic(count: Int = 120, interval: Double = 0.25) }`; `final class FakeScanEngine: ScanEngine { init(recording: SnapshotRecording = .synthetic(), interval: TimeInterval = 0.25, loops: Bool = false, roomID: UUID = UUID()) }`.
- Models: `enum Provenance { measured, estimated, inferred, user }`; `CleanModel { rooms: [CleanRoom]; sourceIsStructure; stamp: DerivedStamp?; static let empty }`; `CleanRoom { id: ElementID; recordID: UUID; name; sectionLabel: String?; floorIndex; walls: [CleanWall]; openings: [CleanOpening]; floor: CleanFloor; ceiling: CleanCeiling; objects: [DetectedObject]; metrics: RoomMetrics }`; `CleanWall { id, start: Vec3, end: Vec3, height, normal: Vec3 (into the room), thickness, thicknessSource, arc: WallArc?, confidence: DetectionConfidence, completedEdges: Int, occludedSpans: [ClosedRange<Float>], provenance; var length: Float }`; `WallArc { center: Vec3, radius, startAngle, endAngle }`; `CleanOpening { id, wallID: ElementID?, kind: OpeningKind, offsetAlongWall, width, sillHeight, headHeight, swing: DoorSwing?, provenance }`; `enum OpeningKind { door, openDoor, window, opening }`; `DoorSwing { hingeAtStart, opensToNormalSide, source }`; `CleanFloor { outline: [Vec2] (CCW plan), elevation, occludedArea, provenance }`; `CleanCeiling { height, provenance }`; `enum DetectionConfidence { low, medium, high }`; `DetectedObject { id, category: ObjectCategory, label, transform: Transform4, dimensions: Vec3, confidence, isHidden, provenance; var isMovable: Bool; var orientedBox: OrientedBox }`; `enum ObjectCategory` (16 RoomPlan categories plus desk, cabinet, shelf, lamp, plant, appliance, vehicle, other; `isMovable`, `copyKey`; `init(_ category: CapturedRoom.Object.Category)`); `RoomMetrics { floorArea, perimeter, ceilingHeight, ceilingProvenance, wallArea, length, width, volume, volumeProvenance; static let zero }`; `enum PlanAxes { static func toPlan(_ p: SIMD3<Float>) -> SIMD2<Float> (x, -z); static func toWorld(_ p: SIMD2<Float>, y: Float) -> SIMD3<Float>; static func toPlan(_ p: Vec3) -> Vec2 }`; `DetectionConfidence.init(_: CapturedRoom.Confidence)`, `OpeningKind.init?(_: CapturedRoom.Surface.Category)`.
- Plan: `PlanModel { levels: [PlanLevel]; northAngle (radians, counter-clockwise from plan +y, 0 unknown); stamp; static let empty }`; `PlanLevel { id: Int, name, elevation, rooms: [PlanRoom], walls: [PlanWall], openings: [PlanOpening], fixtures: [PlanFixture], annotations: [PlanAnnotation], dimensions: [PlanDimension] }`; `PlanRoom { id: ElementID, name, outline: [Vec2], labelAt: Vec2, area }`; `PlanWall { id, a: Vec2, b: Vec2, thickness, thicknessSource, arc: WallArc?, provenance, occludedSpans }`; `PlanOpening { id, wallID: ElementID, kind, offset, width, swing }`; `PlanFixture { id, category, center: Vec2, size: Vec2, yaw, isMovable, isHidden }`; `enum AnnotationKind { text, symbol, note }`; `PlanAnnotation { id, kind, at: Vec2, text, symbol: String? }`; `PlanDimension { id, a, b, offset, isUser; var length }`.
- Edits: `enum EditOperation { renameRoom(room:name:), relabelObject(object:label:), recategorizeObject(object:category:), setHidden(element:hidden:), deleteElement(element:), moveObject(object:transform:), moveWallEndpoint(wall:atStart:to: Vec2), addWall(wall: PlanWall, level: Int), addOpening(opening: PlanOpening, level: Int), setDoorSwing(door:swing:), setWallThickness(wall:thickness:), addAnnotation(annotation:level:), addDimension(dimension:level:), setScaleCorrection(room:factor:), setRoomAlignment(RoomAlignmentRecord), cropObject(object:box: OrientedBoxRecord); var targets: [ElementID] }`; `RoomAlignmentRecord { roomID, yaw, translation: Vec3, source }`; `struct EditLog { private(set) operations, cursor, revision; init(); var active; canUndo; canRedo; mutating func append(_:); undo() -> Bool; redo() -> Bool; func applied<T: EditApplicable>(to base: T) -> (T, orphaned: [EditOperation]) }`; `protocol EditApplicable { mutating func apply(_ op: EditOperation) -> Bool }` (false only when a target is missing; operations for other models return true unchanged).
- Pipeline: `enum PipelineStepID { buildRoom, consolidateMesh, cleanModel, floorPlan, quality, mergeStructure, alignRooms, textureLow, textureHigh, reconstructObject, objectMetrics, thumbnail }`; `DerivedStamp { step, subject: UUID?, pipelineVersion, inputHash, createdAt; init(step:subject:pipelineVersion:inputHash:createdAt:) }`; `DerivedIndex { stamps; func stamp(step:subject:); func isFresh(step:subject:version:inputHash:) -> Bool; mutating func record(_:); mutating func invalidate(step:) }`; `enum InputHasher { static func hash(seals: [SealFile], editRevision: Int?, extra: [String] = []) -> String }`; `struct StepContext { package, manifest, availableMemory: UInt64, isCancelled: () -> Bool, progress: (Double) -> Void; func checkCancelled() throws }` (not Sendable); `protocol ProcessingStep: AnyObject { var id: PipelineStepID { get }; var memoryBudgetBytes: UInt64 { get }; var reducedMemoryBudgetBytes: UInt64? { get } (default nil); func inputHash(_ ctx: StepContext) throws -> String; func run(_ ctx: StepContext) async throws }`.
- Measurements: `enum MeasurementKind { distance, wallLength, height, area, perimeter, angle, volume }`; `enum SnapKind { corner, edge, plane, meshVertex, meshSurface, none }`; `enum MeasurementSource { live, viewer, plan, automatic }`; `struct MeasuredValue { static let lowConfidenceLimit = 0.04, lowConfidenceRelative = 0.03; var value: Double; var sigma: Double? (1 sigma); var provenance; func isLowConfidence(length: Double?) -> Bool; func isLowConfidence(kind: MeasurementKind) -> Bool; var isLowConfidence: Bool }` (CR-2, the one rule; screens reach it through `MeasureDisplay`); `struct MeasurementRecord { id, kind, points: [Vec3], snaps: [SnapKind], result: MeasuredValue, source, name, roomID: ElementID?, createdAt }`.
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

**Build and wave.** Build 4, wave 4a. Depends on Core and Support only; Combine for `ProjectLibrary` (`import Combine` in `StoreProjectLibrary.swift`).

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
    /// Removes the whole package folder (raw included) after the caller confirmed. Callers
    /// cancel the project's processing job first (HomeUI, 3.28).
    func delete(_ id: UUID) throws
    /// The user discarded the scan just captured (quality sheet Discard, lead decision 4):
    /// removes that RoomRecord, its sealed raw room folder and `derived/rooms/<room>/`, and
    /// deletes the whole project when no room is left. Returns true when the project was
    /// deleted. The only raw removal besides `delete` and build 6 Free up space.
    @discardableResult
    func discardRoom(_ roomID: UUID, in projectID: UUID) throws -> Bool
    /// Renames (HomeUI and Results from build 4; ProjectOps in build 6).
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
    /// Creates the folder with subfolders mesh/, keyframes/, depth/, photos/, writes scan.json
    /// and excludes the new folder from backup (the root is excluded by Core's inProgressRoot()).
    static func create(_ info: InProgressScanInfo) throws -> RawScanFolder
    static func folder(for scanID: UUID) throws -> RawScanFolder
    /// Every InProgress folder with a readable scan.json, sealed or not. At launch AppShell's
    /// RecoveryService finishes sealed ones silently (a crash hit between seal and move) and
    /// offers "Recover unfinished scan" for unsealed ones (D5).
    static func list() -> [InProgressScanInfo]
    /// True when the folder already holds SEAL.json.
    static func isSealed(scanID: UUID) -> Bool
    /// Writes SEAL.json (`ProjectStore.sealRawFolder`) unless one exists already (then only the
    /// move is repeated), moves the folder to `destination` (creating its parents with
    /// `ProjectStore.ensureDirectory(_:inside: package.root)`, so a deleted package is never
    /// recreated; fails if the destination exists), re-applies `excludeFromBackup` on the package raw/.
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
    /// is safe when Core's `RawScanFolder.isSafeRelativePath` accepts it (CR-4); readers then
    /// open files only through `RawScanFolder.resolve`, which returns nil for anything else.
    static func isSafeRecordPath(_ path: String) -> Bool
}

/// Serial IO for one raw scan folder. Every method returns at once; work runs in order on
/// `ioQueue`. Only this type writes raw files, and only before sealing (D5). Every write
/// uses `createParents: false` (CR-6), so nothing recreates a discarded folder.
final class RawScanWriter {
    /// Shared serial queue "mapper.io" (QoS utility).
    static let ioQueue: DispatchQueue
    let folder: RawScanFolder
    init(folder: RawScanFolder)
    /// Encodes with `ProjectStore.encoder`, appends one line plus "\n" (FileHandle, seekToEnd).
    /// On a failed or short write it truncates the file back to the offset before the append
    /// (`truncate(atOffset:)`) and increments `failureCount`, so a torn line never glues onto
    /// the next one.
    func appendJSONLine<T: Encodable>(_ value: T, to url: URL)
    /// Appends raw bytes (pose track).
    func appendBytes(_ data: Data, to url: URL)
    /// Writes a whole file atomically (temporary file, then rename).
    func writeFile(_ data: Data, to url: URL)
    /// Runs arbitrary work on the io queue (JPEG encode then write); errors are counted and logged.
    func perform(_ work: @escaping () throws -> Void)
    /// Calls `completion` on the io queue after all work queued before it.
    func flush(completion: @escaping () -> Void)
    /// Queued after all earlier work: from then on every write call is dropped and counted in
    /// `droppedAfterClose` (logged once). The engine closes the writer before sealing or
    /// discarding the folder.
    func close()
    /// Writes dropped because they arrived after `close()` (thread-safe).
    var droppedAfterClose: Int { get }
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
    /// JSON Lines readers skip every line that does not decode (a torn last line after a crash,
    /// or a middle line after a failed append), count the skipped lines and log the count once.
    /// Records whose file paths fail `PackageCheck.isSafeRecordPath` are dropped and logged.
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
    var hasLiveCapturedRoom: Bool { get }
    /// Lines skipped by the last JSON Lines read.
    static func jsonLines<T: Decodable>(_ type: T.Type, at url: URL) throws -> (records: [T], skipped: Int)
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

**Must NOT do.** Never write inside a sealed folder or modify raw after sealing. Never use POSIX permissions to lock raw (judgements, D5). Never delete raw data except through `delete(_:)` of a whole project, `discardRoom(_:in:)` of the scan the user just discarded, or `InProgressScans.discard` (Free up space is build 6 ProjectOps). Never create a raw or derived folder as a side effect of a write (`createParents: false`, CR-6). Never block the main thread with folder walks (`reload` and `usage` run off main). Never hold `ProjectManifest` writes outside `ManifestWriter`. No UI, no Copy strings.

**Copy strings.** None.

**Self-test.** `StoreSelfTest.run()`, at least 25 checks, all in a temporary folder: InProgressScans create makes the four subfolders and scan.json; `RawScanWriter.appendJSONLine` then `flush` then `RawScanReader.keyframes()` round trip of 3 records; a trailing partial line is ignored; a corrupt middle line is skipped and counted while the lines around it decode; after `close()` a queued `appendJSONLine` writes nothing and increments `droppedAfterClose`; `appendBytes` of a pose track header plus 2 records decodes to 2 samples; `writeFile` is atomic (target never half-written, content equal); `seal` writes SEAL.json listing every file with sizes and moves the folder; sealing into an existing destination throws; a folder that already has SEAL.json is moved with its original seal (`isSealed` true before, seal date unchanged after); `ProjectStore.verifyRawFolder` on the moved folder is empty; `PackageCheck.verify` reports a deleted keyframe JPEG; `isSafeRecordPath` rejects "/etc/x", "../x", "keyframes/../../x" and "" and accepts "keyframes/00001.jpg"; a keyframes.jsonl line with an unsafe path is dropped by `RawScanReader.keyframes()`; `discard` removes the folder; `discardRoom` of the only room deletes the project and of one of two rooms removes that record and folder only; `create` sets `isExcludedFromBackup` on the new folder; `list` returns sealed and unsealed folders and skips unreadable ones; `ManifestWriter.update` from 4 concurrent queues applying 25 increments each to `rooms` count ends with 100 rooms; `update` bumps `modifiedAt`; `EditStore.append` twice, `undo`, `redo` produce the expected cursor and revision; `loadMeasurements` of a missing file is empty; measurements round trip; `StorageUsage.usage` sums raw and derived correctly for known file sizes.

**Acceptance checks.** Every write path goes through `RawScanWriter`, `ManifestWriter`, `EditStore` or `ProjectStore.writeData`; `ProjectLibrary` is `@MainActor` and never touches disk synchronously on main except `create` and `update` (small JSON); notifications are posted on main; `RawScanWriter` never throws to its caller (it counts and logs failures); all folder walks tolerate missing folders.

**SPEC owned.** "PROJECT SYSTEM" (stored locally, each project contains its original scan data and derived models, delete); "CORE DESIGN PRINCIPLE" ("Never destroy the original raw scan when the user edits the project"); "FLOOR PLAN EDITING" ("Manual edits must not overwrite raw scan data") at the storage level.

### 3.11 CaptureCore

**Purpose.** The one app-owned `ARSession` per capture session and everything around it: configuration (D14), the serial delegate queue and fan-out to recorders (D7, D8), re-applying the configuration when RoomPlan replaces it, watchdogs (depth, mesh, delegate identity, storage D18, memory D17), tracking and thermal monitoring, frame and mesh copying helpers, and first-run diagnostics (D22). It knows nothing about RoomPlan, files or UI.

**Build and wave.** Build 4, wave 4a. Depends on Core, Support; ARKit, UIKit (memory warning notification).

`docs/REUSE.md` 4.4 is a sketch written before this contract and is superseded by it: do not copy its `override init()` shape or its re-apply in `didStartWith` (3.21 Must NOT do).

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
    /// Stops recording, finishes all pending writes, then calls `completion` (any queue). Hub
    /// callbacks that still arrive after this call are ignored (engines detach recorders first).
    func finishRecording(completion: @escaping () -> Void)
    /// Writes buffered data now without finishing (memory pressure). Hub queue.
    func flushNow()
    var stats: RecorderStats { get }
}
extension ScanRecorder {
    // Default empty implementations of the four hub(_:...) callbacks and of flushNow().
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
    var memory: MemoryState = .ok        // from MemoryProbe, two consecutive ticks (see MemoryPolicy)
    init()
}
enum MemoryState: String, Equatable, Sendable { case ok, low, critical }
/// Capture memory floor (D17, RESEARCH 3.9 "pause capture on memory warnings"). Starting values,
/// tuned from open device question 6.
enum MemoryPolicy {
    static let stopKeyframesBelowBytes: UInt64 = 600_000_000   // .low: keyframes stop, tier 1 note logged
    static let finishBelowBytes: UInt64 = 400_000_000          // .critical: the engine flushes and finishes
    /// Pure: .critical below 400 MB or after a memory warning, .low below 600 MB, each only when
    /// the previous sample agreed (two consecutive status ticks), else .ok.
    static func state(available: UInt64, previous: UInt64?, warning: Bool) -> MemoryState
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
    /// Hub queue. `UIApplication.didReceiveMemoryWarningNotification` (observed from init until
    /// `pause()`), forwarded once per warning.
    var onMemoryPressure: (() -> Void)?
    // Owners set these three closures with `[weak self]` captures and nil them in teardown;
    // the hub never keeps its owner alive. The hub logs a "hub deinit" line.
    /// Main actor (reads `UIDevice.current.model` for diagnostics).
    @MainActor init(profile: ScanProfile)
    /// Call on the main thread (not actor-isolated, so nonisolated engine methods may call it).
    /// Sets `session.delegate = self` and `session.delegateQueue = queue`. Call before any
    /// RoomPlan object is created (RESEARCH 3.2 recommended step 2).
    func install()
    /// Call on the main thread. `session.run(ScanConfigurationFactory.make(profile), options: options)`.
    func run(options: ARSession.RunOptions = [])
    /// Call on the main thread. `session.pause()`; also stops the memory warning observer.
    /// Idempotent.
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

/// Forwards every delegate call first to the delegate it replaced (synchronously, on the queue
/// the call arrived on) and then to the hub; it never changes `session.delegateQueue`.
/// Installed only when the once-per-second identity check finds `session.delegate !== hub`
/// and `SettingsKey.captureRelay` is on (absent means on; Diagnostics can turn it off if the
/// camera view goes black, the one reported failure of a late delegate swap, RESEARCH 3.2
/// disputed 1). The check logs both `session.delegate === hub` and
/// `session.delegateQueue === queue`, and re-asserts only the queue.
final class ARDelegateRelay: NSObject, ARSessionDelegate {
    init(hub: ARSessionHub, previous: (any ARSessionDelegate)?)
}
extension SettingsKey { static let captureRelay = "captureRelay" }   // Bool, absent means on

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

Queue guard: the hub marks `queue` with `DispatchQueue.setSpecific(key:value:)`; every delegate callback checks `DispatchQueue.getSpecific(key:)` and, when it runs on a foreign queue (RoomPlan or a relay changed the delegate queue), copies the values it needs inside the call and `queue.async`s the copies (never the `ARFrame`), logging the first occurrence.

**Must NOT do.** Never pass `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction` when re-applying during RoomPlan. Never enable plane detection except for Quick Measure (D14). Never change `videoFormat` (RESEARCH 3.8 disputed 10). Never retain an ARFrame, its pixel buffers or an `ARMeshGeometry` buffer. Never mark the hub `@MainActor`. Never call ARKit on main except `install`, `run`, `pause` and init. No file IO (recorders use Store), no RoomPlan import, no UI.

**Copy strings.** None (diagnostics are logs).

**Self-test.** `CaptureCoreSelfTest.run()`, at least 25 checks: `ScanProfile.wantsPlaneDetection` true only for quickMeasure; `ScanConfigurationFactory.make` sets planeDetection [] for room, house, advancedSpace, object (inspect the returned configuration's `planeDetection`, `environmentTexturing`, `isLightEstimationEnabled`; no session is run); `CaptureWatchdogLogic` sequences: depth present all along gives none; depth absent 2.1 s gives one reapply then degrade(.depthStripped) after 2 more seconds; mesh absent 8 s with normal tracking gives reapply; limited tracking does not count toward the mesh timer; reset clears; `StorageWatchdog.state(forFreeBytes:)` at 5 GB, 900 MB, 200 MB; `ThermalPolicy.forLevel` for all four levels; `ThermalLevel(.critical)`; `TrackingMonitor` with synthetic timestamps gives the right limited fraction (use a pure helper that takes summaries); `MeshAnchorCopier.unpackFloat3` with stride 12 and stride 16 buffers and an offset of 8; `unpackUInt32`; `ARFrameReading.angularSpeed` of a 90 degree yaw over 1 s is pi/2 within 1e-4; `linearSpeed` of 0.5 m over 0.25 s is 2; `RecorderStats +` sums fields; `MemoryPolicy.state` gives .ok at 1 GB, .low only on the second consecutive 550 MB sample, .critical on the second 350 MB sample and at once with `warning: true`.

**Acceptance checks.** `install()` is called before `RoomCaptureView` is created (documented in the doc comment); every delegate method matches the RESEARCH signature exactly; recorders receive calls only on `queue`; `onStatus` is throttled to 4 Hz; the delegate and delegate-queue identity check runs once per second and logs; watchdog actions are logged as `CaptureEvent(kind: .degraded / .config)`; memory states and warnings are logged as `CaptureEvent(kind: .memory)`; no `@MainActor` on the class; `os` imported only in `CaptureWatchdogs.swift`; `deinit` logs one line.

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
    /// True when loaded from `capturedroom-live.json` (a killed capture): not final, so the
    /// builder gives every wall, opening, floor and object provenance `.estimated`.
    var isProvisional: Bool = false
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

enum CleanPartKind: Hashable, Sendable { case wall, floor, ceiling, door, window, opening, object(ObjectCategory), occluded }
struct CleanMeshPart: Equatable {
    var element: ElementID; var kind: CleanPartKind; var mesh: TriangleMesh
    var isMovable: Bool; var isHidden: Bool; var provenance: Provenance
}
enum CleanMeshBuilder {
    /// Also emits `.occluded` parts (provenance `.inferred`, `element` = the wall or the object):
    /// for every `CleanWall.occludedSpans` range a wall-plane quad of the span's length and
    /// height min(wall height, top of the blocking movable object + 0.1 m), and for every movable
    /// `DetectedObject` its footprint quad from `orientedBox`, 5 mm above the floor. Viewers show
    /// them only while Hide Furniture is on (SPEC FURNITURE REMOVAL: blocked regions are marked,
    /// never shown as measured).
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
    /// Raw capturedroom.json first, then the rebuilt derived one, then raw capturedroom-live.json.
    static func loadCapturedRoom(_ package: ProjectPackage, room: RoomRecord) throws -> CapturedRoom
    /// As `loadCapturedRoom`; `isProvisional` is true when the live file was used.
    static func loadInput(_ package: ProjectPackage, room: RoomRecord) throws -> RoomInput
}
/// Rebuilds capturedroom.json from capturedroomdata.json when raw lacks it (RoomBuilder threw or
/// the app was killed after didEndWith). Catches `RoomBuilder` errors, logs them and completes
/// without output, so CleanModelStep and FloorPlanStep leave the room out (never fails the job).
final class BuildRoomStep: ProcessingStep { init(room: RoomRecord) }        // id .buildRoom, budget 150 MB
/// Builds derived/clean.json for every room with status captured or processed. A room with no
/// loadable CapturedRoom (RoomPlan failed) is left out of the model and logged; an empty model is
/// still written so FloorPlanStep and Results can report "no walls".
final class CleanModelStep: ProcessingStep {                                  // id .cleanModel, budget 200 MB
    /// (package, room id) -> consolidated measured mesh, nil when absent. The step passes `ctx.package`.
    init(meshProvider: @escaping (ProjectPackage, UUID) -> MeshWithAttributes?)
}
```

Rules the builder follows: walls come from the loop (D12) with `ElementID.derived(fromRoomPlan:)` ids and `normal` pointing into the room; openings attach by `parentIdentifier` (fallback nearest parallel wall within 0.3 m), endpoints are projected onto the wall and clamped, `sillHeight`/`headHeight` are relative to the floor elevation; `OpeningKind(_:)` mapping lives in Core; `thickness` defaults to 0.115 m for every wall of a single room (Structure sets 0.15 m for exterior walls, or a measured value from wall pairs, in build 5), `thicknessSource` `.estimated`; a provisional input (`isProvisional`) gives provenance `.estimated` to every wall, opening, floor and object; floor outline is the loop polygon, `floor.elevation` from mesh floor faces when `floorFromMesh` passes the gate (`.measured`), else the floors[0] Y or the lowest wall base (`.estimated`); ceiling per D13, else max wall height with confidence high (`.estimated`); objects are skipped when `findFurniture` is false (they stay in raw); `CleanRoom.id = ElementID(uuid: recordID)`; `sectionLabel` is the label of the section whose center lies inside the outline; a floor polygon mismatch over 5 percent is logged (category "roommodel"). Metrics: area and perimeter from the loop (shoelace), length and width from `Rectangle2D.minimumArea(enclosing:)`, wall area = sum of length x height minus openings, volume = area x ceiling height with the ceiling's provenance. Edit application (`apply`): renameRoom, relabelObject, recategorizeObject, setHidden, deleteElement (walls, openings, objects), moveObject, moveWallEndpoint (plan point to world via `PlanAxes.toWorld(_:y:)` at the floor elevation), addWall (height = room ceiling), addOpening, setDoorSwing, setWallThickness and setScaleCorrection (multiplies the room's metrics) change the model; setRoomAlignment, cropObject, addAnnotation and addDimension return true unchanged; an operation whose target is missing returns false and changes nothing.

**Uses.** Core: `CleanModel`, `CleanRoom`, `CleanWall`, `CleanOpening`, `CleanFloor`, `CleanCeiling`, `DetectedObject`, `DoorSwing`, `WallArc`, `RoomMetrics`, `Provenance`, `ElementID.derived(fromRoomPlan:)`, `PlanAxes`, `ObjectCategory.init(_:)`, `DetectionConfidence.init(_:)`, `OpeningKind.init?(_:)`, `EditOperation`, `EditLog.applied(to:)`, `EditApplicable`, `ProcessingStep`, `StepContext`, `InputHasher`, `SealFile`, `ProjectStore`, `ProjectPackage`, `RawScanFolder`, `RoomRecord`, `MapperError`. Geometry: `Polygon2D`, `Rectangle2D.minimumArea(enclosing:)`, `Segment2D.intersection(with:)`, `TriangleMesh`, `OrientedBox`. MeshProcessing: `MeshWithAttributes`. Support: `LogStore`.

**Apple APIs** (RESEARCH 3.2 and 3.6): `CapturedRoom` (`identifier`, `walls`, `doors`, `windows`, `openings`, `floors`, `objects`, `sections`, `story`), `CapturedRoom.Surface` (`identifier`, `parentIdentifier`, `category`, `confidence`, `transform`, `dimensions`, `completedEdges: Set<CapturedRoom.Surface.Edge>`, `curve`, `polygonCorners`, `story`), `CapturedRoom.Surface.Category { floor, door(isOpen: Bool), opening, wall, window }` (not CaseIterable), `CapturedRoom.Surface.Curve` (`startAngle`/`endAngle: Measurement<UnitAngle>`, `radius: Float`, `center: simd_float2`), `CapturedRoom.Object` (`identifier`, `parentIdentifier`, `category`, `transform`, `dimensions`, `confidence`), `CapturedRoom.Section` (`label`, `center`, `story`), `class RoomBuilder { init(options: RoomBuilder.ConfigurationOptions); func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom }` with `[.beautifyObjects]`, `struct CapturedRoomData` (Codable).

**Must NOT do.** Never use `floors[].polygonCorners` as the room outline or area source (cross-check only). Never trust `columns.0` sign for winding; derive it from the loop. Never draw curved walls as straight segments (keep `arc`). Never construct or mutate `CapturedRoom`. Never write into raw. Never bake a label or category guess into anything but the derived model (labels are edits).

**Copy strings.** None (names are resolved by FloorPlan's `RoomTitles`).

**Self-test.** `RoomModelSelfTest.run()`, at least 45 checks, with hand-made `RoomInput` fixtures in `RoomModelSelfTestFixtures.swift`: a 4 x 5 m rectangle, an L-shaped room (6 walls, area 20.0 where the bounding rectangle is 24.0), a room with a 0.3 m stub wall, a room with one wall whose `columns.0` is flipped, a room with a curved wall. Checks: outline closed and counter-clockwise; L-shape area within 1e-3 of 20 and perimeter exact; floor polygon mismatch reported for the L-shape with a rectangle floor; stub goes to `strayWalls`; flipped wall still in loop order; wall normals point inside; corner intersection moves endpoints that overshoot by 5 cm; door projected onto its parent with correct offset, width, sill 0 and head height; window sill relative to floor elevation; opening with nil parent attaches to the nearest wall; default swing hinge at the nearer corner; ceiling from a synthetic mesh at 2.60 m with 80 percent coverage is measured 2.60; with 10 percent coverage it falls back to wall height, estimated; length and width of the 4 x 5 room are 5 and 4; wall area subtracts one door; volume provenance follows the ceiling; findFurniture false drops objects; occlusion span for a sofa 0.1 m from a wall; each EditOperation case applied once (rename, relabel, recategorize, hide, delete wall, move object, move wall endpoint, add wall, add opening, door swing, thickness, scale 1.1 on area) plus an orphaned target returning false; `PolygonTriangulator` on a square (2 triangles), an L (4 triangles), a clockwise input, and a degenerate input (empty); `CleanMeshBuilder.wallMesh` of a 4 x 2.5 m wall with a 0.9 x 2.0 m door has area 10 - 1.8 within 1e-4; `parts` excludes hidden objects unless asked; a sofa 0.1 m from a wall yields one occluded wall quad and one occluded floor quad, both `.inferred`; a provisional input gives `.estimated` walls; `RoomInput` Codable round trip with `isProvisional` true.

**Acceptance checks.** RoomPlan types appear only in the three named files; the builder never reads `floors` for area; every public function is pure; `CleanModel.apply` returns true for operations meant for other models; metrics are recomputed after edits in `loadEdited`; `CleanModelStep.inputHash` includes the room seals and `EditLog.revision` is NOT included (the base model ignores edits); `BuildRoomStep` never throws for a `RoomBuilder` error; derived files are written with `createParents: false` after `ensureDirectory(_:inside:)` (CR-6).

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation C (walls, floors, ceilings, doors, windows, openings, stairs where detectable, furniture, appliances, other recognized objects); "ROOM SCANNING" (walls, floor, ceiling, doors, windows, openings, structural boundaries, furniture, permanent fixtures); "MEASUREMENT SYSTEM" automatic values (wall length and height, ceiling height, door and window sizes, room length, width, area, floor area, wall area, perimeter, estimated volume); "FURNITURE REMOVAL" (occluded spans and areas marked, not fabricated; estimated geometry distinguished by provenance); "AUTOMATIC OBJECT RECOGNITION" ("Never permanently bake AI/object-recognition guesses into the raw scan").

### 3.13 MeshModel

**Purpose.** Turns the raw anchor-local mesh chunks of a room into derived world-space meshes: consolidated measured mesh (weld, cleanup), small holes filled and flagged inferred, the removed floating fragments kept for the Raw Scan view, a simplified viewer and texturing mesh of the measured faces, statistics, the classification color palette, the export adapter, and the `consolidateMesh` step. Also a fast unwelded path for the quality check at Done.

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
/// `view` is simplified from `measured` only; `inferred` (small hole fills) stays at full
/// resolution in its own file; `floaters` are the islands `removingFloaters` dropped, kept so
/// Raw Scan shows the scan with its noise (simplified with the same budget share).
struct ConsolidationResult { var measured: MeshWithAttributes; var inferred: MeshWithAttributes; var view: MeshWithAttributes; var floaters: MeshWithAttributes; var stats: MeshStats }
enum MeshConsolidator {
    /// Later folders win for the same anchorID; within a folder the highest updateCount wins.
    static func latestChunks(in folders: [RawScanFolder]) -> [MeshChunk]
    static func mergeChunks(_ chunks: [MeshChunk]) -> [MergeChunk]
    /// ChunkMerge.merge, removingDegenerateAndDuplicateFaces, MeshCleanup.removingFloaters (the
    /// removed faces become `floaters`), HoleFill.fillSmallHoles (inferred faces split out),
    /// MeshSimplify of the measured faces only to viewTriangleBudget.
    static func consolidate(_ chunks: [MeshChunk], options: ConsolidationOptions, isCancelled: () -> Bool) -> ConsolidationResult?
    /// World transform only, no weld; for the quality check at Done (under 1 s for 500k faces).
    static func fastWorldMesh(_ chunks: [MeshChunk]) -> MeshWithAttributes
}
enum MeshModelStore {
    static func measuredURL(_ package: ProjectPackage, room: UUID) -> URL   // derived/rooms/<r>/mesh.mchk
    static func inferredURL(_ package: ProjectPackage, room: UUID) -> URL   // mesh_inferred.mchk
    static func viewURL(_ package: ProjectPackage, room: UUID) -> URL       // mesh_view.mchk
    static func floatersURL(_ package: ProjectPackage, room: UUID) -> URL   // mesh_floaters.mchk
    static func statsURL(_ package: ProjectPackage, room: UUID) -> URL      // mesh_stats.json
    static func save(_ result: ConsolidationResult, package: ProjectPackage, room: UUID) throws
    static func loadMeasured(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    static func loadInferred(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    /// Measured faces only: the result has `isInferred == nil` (the chunk format has no inferred
    /// flag); draw `loadInferred` next to it for the Inferred color.
    static func loadView(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
    static func loadFloaters(_ package: ProjectPackage, room: UUID) throws -> MeshWithAttributes?
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

**Must NOT do.** Never modify or delete raw chunks; never drop a chunk because its anchor was removed during capture (RESEARCH 3.1 gotcha 15); never simplify the measured mesh (only the view copy); never mix inferred faces into `mesh.mchk` or `mesh_view.mchk`; never hold more than one room's full mesh in memory in the step.

**Copy strings.** None.

**Self-test.** `MeshModelSelfTest.run()`, at least 25 checks: `latestChunks` picks the highest updateCount and the later folder; two overlapping anchor-local cube halves with different transforms consolidate into one watertight cube (volume 1 within 1e-3); classes survive consolidation; a 10 cm hole is filled and appears only in `inferred`, and `view` contains no inferred face; a 30-triangle floater is removed from `measured` and appears in `floaters`; view budget respected on a 20k triangle sphere with budget 5k; `fastWorldMesh` transforms positions by the anchor transform; chunk/mesh round trip through `MeshChunkFile`; `save` then `loadMeasured`/`loadView`/`loadFloaters`/`loadStats` round trip in a temp package (`loadView` returns `isInferred == nil`); palette has 8 distinct colors and `bytes` matches `color`; export adapter produces per-vertex colors when asked and none otherwise, and `ExportScene.validate()` passes; cancellation closure returning true yields nil.

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
    /// The one rule every screen uses (CR-2): returns `value.isLowConfidence(length: length)` from
    /// Core, that is 2 sigma > max(0.04 m, 3 percent of `length`) for lengths and 2 sigma > 3 percent
    /// of the value for areas and volumes (`length` nil). False without sigma.
    static func isLowConfidence(_ value: MeasuredValue, length: Double?) -> Bool
    /// Value text in the user's units: LengthFormat.display / AreaFormat.display / VolumeFormat / AngleFormat.
    static func valueText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String
    /// "Estimated accuracy ±0.6\"" (Copy.Measure.accuracy with Tolerance.plusMinus minus its leading
    /// "±", because Copy adds the sign), Copy.Measure.lowConfidence, Copy.Measure.notMeasured for
    /// inferred values, or nil when there is no sigma.
    static func accuracyText(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String?
    static func accessibilityText(label: String, value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> String
}
enum DimensionGroup: String, CaseIterable, Sendable { case room, walls, doors, windows, objects }
struct DimensionRow: Identifiable, Equatable, Sendable {
    var id: String; var group: DimensionGroup; var title: String; var label: String
    var kind: MeasurementKind; var value: MeasuredValue; var element: ElementID?; var isLowConfidence: Bool
}
enum RoomDimensions {
    /// Room: length, width, floor area, perimeter, ceiling height, wall area, estimated volume; then
    /// per wall (length, height, area), per door (width, height), per window (width, height).
    /// Wall area row: id "wall.<uuid>.area", kind .area, value length x height minus that wall's
    /// openings, sigma from `ConfidenceAdapter.area(_:sideA:sideB:)` of the wall's length and height
    /// rows; the Walls group carries `Copy.MeasureCore.wallAreaNote`. Every row has `element` set
    /// (walls, doors and windows to their ElementID) so Results can filter by selection.
    static func rows(for room: CleanRoom, evidence: RoomEvidence) -> [DimensionRow]
    /// Width, height and depth of a detected object's box (ids "object.<uuid>.width" and so on,
    /// titles `Copy.Viewer.width`, `height`, `depth`, group .objects), each from
    /// `ConfidenceAdapter.roomPlanLength(_, wall: nil, room: evidence, provenance: object.provenance)`.
    static func objectRows(for object: DetectedObject, evidence: RoomEvidence) -> [DimensionRow]
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

**Uses.** Core: `MeasuredValue` (`isLowConfidence(length:)`, CR-2), `MeasurementKind`, `SnapKind`, `Provenance`, `CleanRoom`, `CleanWall`, `CleanOpening`, `DetectedObject`, `RoomMetrics`, `ElementID`. Coverage: `MeasurementEvidence`, `MeasurementSnapKind`, `MeasurementConfidence.estimate(start:end:length:)`, `MeasurementConfidence.estimate(point:)`. Geometry: `Snap.best`, `SnapResult`, `SnapTarget`, `Plane`, `Rectangle2D`. Units: `LengthFormat.display`, `AreaFormat.display`, `VolumeFormat.primary`, `VolumeFormat.both`, `AngleFormat.degrees`, `Tolerance.plusMinus`, `UnitPreferences`. Support: `Copy.Measure.*`.

**Apple APIs.** None.

**Must NOT do.** Never implement a second low-confidence rule (delegate to Core's `MeasuredValue.isLowConfidence(length:)`, CR-2). Never show a plus-minus better than 3 cm for a RoomPlan-derived length. Never call `CapturedRoom.Confidence` accuracy. Never format numbers without Units. Never produce a plus-minus for inferred or user values.

**Copy strings.** Existing: `Copy.Measure.roomLength`, `roomWidth`, `floorArea`, `perimeter`, `ceilingHeight`, `wallArea`, `volume`, `wallLength`, `wallHeight`, `doorWidth`, `doorHeight`, `windowSize`, `accuracy(_:)`, `accuracySpoken(_:)`, `lowConfidence`, `notMeasured`, `A11y.measurement(_:value:)`. New in `Copy+MeasureCore.swift` (`extension Copy { enum MeasureCore }`): `roomGroup = "Room"`, `wallsGroup = "Walls"`, `doorsGroup = "Doors"`, `windowsGroup = "Windows"`, `static func wallTitle(_ n: Int) -> String { "Wall \(n)" }`, `doorTitle(_:)` "Door \(n)", `windowTitle(_:)` "Window \(n)", `windowWidth = "Window width"`, `windowHeight = "Window height"`, `objectsGroup = "Objects"`, `wallAreaNote = "Doors and windows are not counted in wall area."`.

**Self-test.** `MeasureCoreSelfTest.run()`, at least 30 checks: a 5.66 m wall with defaults displays at least plus or minus 3 cm (sigma >= 0.015); sigma grows with length (2 m < 8 m); tracking fraction 0.5 marks low confidence and the flag survives through `MeasureDisplay.isLowConfidence`; a 10 m wall with good evidence is not low confidence (relative rule) while a 0.5 m distance with sigma 0.025 is; area sigma formula on a 4 x 5 room; sum of 4 walls; `accuracyText` contains exactly one plus-minus sign; imperial and metric texts for 3.845 m match `LengthFormat.display`; inferred volume text uses `notMeasured` and no sign; `RoomDimensions.rows` for a 4 x 5 room with one door and one window returns 7 room rows plus 12 wall rows plus 2 door rows plus 2 window rows in order, and the door wall's area row equals its length x 2.5 minus the door area; filtering rows by one wall's `element` gives 3 rows; `objectRows` of a 1 m table with `RoomEvidence.unknown` gives 3 rows, each sigma >= 0.015 and none low confidence; `MeasureDisplay.isLowConfidence` agrees with Core's rule on 0.5 m and 10 m cases; length >= width; `SnapSet` of a 4 x 5 x 2.5 room has 8 corners, the snap of a point 3 cm from a floor corner returns `.corner`, 3 cm from the middle of a wall's top edge returns `.edge`, a point 2 cm from a wall plane and at least 1 m from its edges returns `.plane`, a point 1 m inside the room returns `.none`.

**Acceptance checks.** All constants in one place with doc comments citing RESEARCH ruling 4 and the Coverage formula; no Units bypass; `RoomDimensions` is deterministic and ordered; row ids are stable strings ("room.length", "wall.<uuid>.length").

**SPEC owned.** "MEASUREMENT SYSTEM" (both feet and inches and metric, preference switching, the automatic measurements), "MEASUREMENT CONFIDENCE" (all of it: confidence shown, "Low confidence, rescan this section", no survey-grade claims), snapping order for "corner, wall, edge, floor, ceiling, door, window, object edge" (logic; the tools are build 5).

### 3.15 Pipeline

**Purpose.** Runs processing steps (Core `ProcessingStep`) one at a time per project, one project at a time: freshness by derived stamps (D11), step dependencies so one failure stops only what needs it, memory gates and reduced variants (D17), thermal pause and heat-reduced variants, a crash-loop guard, suspension while a capture runs, the app's single idle-timer owner (`IdleTimerGuard`), cancellation, progress, and a published per-project state that screens use for progressive results (D20).

**Build and wave.** Build 4, wave 4a. Core, Support; UIKit, Combine (`import Combine` in `ProcessingRunner.swift`).

**Files.** `ios/Sources/Pipeline/ProcessingRunner.swift`, `ProcessingTypes.swift`, `ProcessingGuards.swift`, `PipelineAttempt.swift`, `PipelineIdleTimer.swift`, `PipelineSelfTest.swift`.

**Public Swift API.**
```swift
/// Identifies one scheduled step within a job (step plus subject).
struct ScheduledStepKey: Hashable, Sendable { var step: PipelineStepID; var subject: UUID? }
struct ScheduledStep {
    let step: ProcessingStep; let subject: UUID?; let isOptional: Bool
    /// Steps of the same job whose output this one reads. When one of them failed or was skipped
    /// for failure, this step is not run and is recorded as failed ("dependency failed");
    /// independent steps still run.
    let dependsOn: Set<ScheduledStepKey>
    var key: ScheduledStepKey { get }
    init(_ step: ProcessingStep, subject: UUID? = nil, isOptional: Bool = false, dependsOn: Set<ScheduledStepKey> = [])
}
struct ProcessingJob {
    let projectID: UUID; let package: ProjectPackage; let steps: [ScheduledStep]
    init(projectID: UUID, package: ProjectPackage, steps: [ScheduledStep])
}
/// `.failed` names the first required step that failed; it is reported after every step that
/// did not depend on it has run. `.cancelled` covers user cancel and `suspendAll` is never
/// reported (a suspended job keeps its place and reruns later).
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
    /// True between `suspendAll` and `resumeAll`.
    @Published private(set) var isSuspended: Bool
    /// Queues a job; `onFinish` is called on main once. A job for a project already queued replaces
    /// it. `atFront` puts it before the waiting jobs (a scan the user just finished).
    func enqueue(_ job: ProcessingJob, atFront: Bool = false, onFinish: @escaping (ProcessingOutcome) -> Void)
    func cancel(projectID: UUID)
    /// Before a capture starts: sets the running job's cancel flag, keeps every job queued (the
    /// interrupted step reruns later; stamped steps skip), does not call `onFinish`, publishes
    /// `isSuspended`. Nothing starts until `resumeAll`.
    func suspendAll(reason: String)
    /// After the capture cover closes: restarts the queue.
    func resumeAll()
    func state(for projectID: UUID) -> ProjectProcessingState
    var isBusy: Bool { get }
}
/// The only writer of `UIApplication.shared.isIdleTimerDisabled` in the app: the idle timer is
/// disabled while at least one holder exists (a visible scan screen, a running job). Main actor.
@MainActor enum IdleTimerGuard {
    static func acquire(_ reason: String) -> UUID
    static func release(_ token: UUID)
    /// Pure rule used by the self-test: disabled when the holder set is not empty.
    nonisolated static func shouldDisable(holders: Int) -> Bool
}
/// Crash-loop guard (`derived/pipeline_attempt.json`, `ProjectPackage.pipelineAttemptURL`),
/// written atomically before `step.run` and deleted after its stamp or failure is recorded.
struct PipelineAttempt: Codable, Equatable, Sendable {
    var step: PipelineStepID; var subject: UUID?; var variant: String; var count: Int; var startedAt: Date
    /// Pure: what to do when a job starts and a marker for this step exists (the app died in it).
    /// count 0 (no marker): run normally; count 1: run forcing the reduced variant (refuse when there
    /// is none); count 2 or more: do not run, record `MapperError.outOfMemory(step:)`.
    static func decision(previous: PipelineAttempt?, hasReducedVariant: Bool) -> AttemptDecision
}
enum AttemptDecision: Equatable, Sendable { case run, runReduced, giveUp }
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
Runner algorithm per step: skip it as failed ("dependency failed") when a step in its `dependsOn` failed; build `StepContext` (manifest via `ProjectStore.readManifest`, `availableMemory`, `isCancelled` reading a per-job lock-protected flag, `progress` that hops to main at most 10 times a second); compute `inputHash` off main in `Task.detached(priority: .userInitiated)`; skip when `DerivedIndex.isFresh(step:subject:version: ProjectManifest.currentPipelineVersion, inputHash:)`; read the attempt marker and apply `PipelineAttempt.decision` (give up: record the failure without running; run reduced: pass an `availableMemory` capped just under the full budget plus headroom); at thermal `.serious` also cap `availableMemory` so steps pick their reduced variant, and wait 30 s before any step whose budget is over 300 MB (`isPausedForHeat` shows); refuse with `MapperError.outOfMemory(step:)` when `variant` is `.refuse` (the step itself picks full or reduced from `ctx.availableMemory`); await `waitWhileCritical`; write the attempt marker (count + 1); run `step.run(ctx)` in `Task.detached`; on success record `DerivedStamp` in `derived/index.json` (the runner is the only writer of the index) and delete the marker; on failure delete the marker, record it in `failed`, and continue with every step that does not depend on it (optional or required); the job reports `.failed(step:error:)` for the first failed required step once nothing runnable is left. While any job runs the runner holds an `IdleTimerGuard` token. Every step start, end, skip, give-up and failure is logged (category "pipeline") with duration and available memory.

**Uses.** Core: `ProcessingStep`, `StepContext`, `PipelineStepID`, `DerivedIndex`, `DerivedStamp`, `ProjectManifest.currentPipelineVersion`, `ProjectStore.readManifest`, `ProjectStore.readJSON`, `ProjectStore.writeJSON`, `ProjectPackage.derivedIndexURL`, `MapperError`. Support: `LogStore`.

**Apple APIs.** `var isIdleTimerDisabled: Bool { get set }` (UIApplication, main only); `var thermalState: ProcessInfo.ThermalState { get }`; `os_proc_available_memory()` (import os); `Task.detached(priority:operation:)`.

**Must NOT do.** Never run two steps at once; never run processing while a capture is active (AppShell calls `suspendAll` before a scan starts and enqueues after Finish); never write the manifest (callers do it in `onFinish` through Store); never write `isIdleTimerDisabled` except inside `IdleTimerGuard`; never use `BGProcessingTask` (RESEARCH 3.9); never block main.

**Copy strings.** None (screens map `PipelineStepID` to `Copy.Processing`).

**Self-test.** `PipelineSelfTest.run()`, at least 15 checks on the pure parts (the runner itself is async and main-actor, so it is covered by the device smoke test): `ProcessingGuards.variant` at the full, reduced and refuse boundaries and with no reduced budget; `shouldSkip` true only for equal version and hash and the same subject; `reduce` for queued, started, progress, stepCompleted, stepSkipped, stepFailed optional (job continues), stepFailed required, pausedForHeat, finished; `shouldPublish` drops an update 0.05 s after the last and passes one after 0.2 s; `DerivedIndex.record` replaces the same step and subject; a pure planner (`static func runnable(_ steps: [ScheduledStep], failed: Set<ScheduledStepKey>) -> [ScheduledStepKey]`) keeps an independent step 2 runnable after a required failure of step 1 and drops a step that depends on step 1 (transitively); `PipelineAttempt.decision` for no marker, count 1 with and without a reduced variant, and count 2; `IdleTimerGuard.shouldDisable` for 0 and 2 holders; suspend then resume keeps the job queued and its stamped steps skip (pure queue helper).

**Acceptance checks.** Every `@Published` mutation on main; no `ProcessingStep` touched on main except creation; failures of optional steps never fail the job; a required failure stops only its dependents; the index and the attempt marker are read and written only by the runner; cancellation observed between steps and through `ctx.isCancelled`; `isIdleTimerDisabled` appears only in `PipelineIdleTimer.swift`.

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
/// What the user set on the result screen that exports must respect (SPEC HIDE FURNITURE,
/// TEST_PLAN EXP-05). Declared here so Results and ExportUI (both 4c) share it without
/// importing each other.
struct ExportViewState: Equatable, Sendable {
    var planToggles: PlanToggles; var hideFurniture: Bool
    static let standard: ExportViewState      // PlanToggles.standard, hideFurniture false
}
enum PlanLayers {   // names and colors used by every writer
    static let walls = "A-WALL", doors = "A-DOOR", windows = "A-GLAZ", roomNames = "A-FLOR-IDEN"
    static let dimensions = "A-ANNO-DIMS", furniture = "A-FURN", fixtures = "A-FIXT", notes = "A-ANNO-NOTE", grid = "A-GRID"
    static let occluded = "A-WALL-OCCL"
    /// Door leaf and swing arc whose `swing?.source` is `.estimated` or `.inferred`, drawn dashed.
    static let doorSwingEstimated = "A-DOOR-EST"
    /// Outer face of walls whose `thicknessSource` is `.estimated`, drawn dashed.
    static let wallsEstimated = "A-WALL-EST"
    /// Scale bar below the plan (`toggles.scale`).
    static let scaleBar = "A-ANNO-SCAL"
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
    /// Honest estimates (SPEC "clearly distinguish estimated geometry", RESEARCH 3.6: RoomPlan has
    /// no hinge side and no thickness): the leaf and arc of a door whose swing is `.estimated` or
    /// `.inferred` are drawn dashed (short `.line` and `.arc` pieces) on `doorSwingEstimated`, a
    /// `.user` swing solid on `doors`; the inner face of a wall is solid on `walls`, its outer face
    /// dashed on `wallsEstimated` when `thicknessSource` is `.estimated`. `doorsWindows` toggles both
    /// door layers. `toggles.grid` draws 1 m lines (metric) or 1 ft lines (imperial) over the plan
    /// bounds on `grid`; `toggles.scale` draws a 4-segment scale bar with a Units-formatted end
    /// label below the plan on `scaleBar`. Every toggle removes only its own layers.
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
    /// Internal parameter names `lower` and `upper` keep `Swift.min` and `Swift.max` usable in the body.
    static func fitting(min lower: SIMD2<Double>, max upper: SIMD2<Double>, in size: CGSize, margin: CGFloat) -> PlanViewport
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

**Copy strings.** Existing: `Copy.FloorPlan.toggleFurniture`, `toggleMeasurements`, `toggleRoomNames`, `toggleDoorsWindows`, `toggleFixtures`, `toggleGrid`, `toggleScale`, `Copy.House.roomSuggestions`. New (`extension Copy.FloorPlan` in `Copy+FloorPlan.swift`): `static func defaultRoomTitle(_ n: Int) -> String { "Room \(n)" }`, `sectionLivingRoom = "Living Room"`, `sectionKitchen = "Kitchen"`, `sectionDiningRoom = "Dining Room"`, `sectionBedroom = "Bedroom"`, `sectionBathroom = "Bathroom"`, `stairsUp = "UP"`, `stairsDown = "DN"`, `static func roomTag(name: String, area: String) -> String { "\(name)\n\(area)" }`, and `static func categoryName(_ category: ObjectCategory) -> String`, an exhaustive switch (no default) giving the display name of every `ObjectCategory` for fixture labels, the Results object card and exports: bathtub "Bathtub", bed "Bed", chair "Chair", dishwasher "Dishwasher", fireplace "Fireplace", oven "Oven", refrigerator "Refrigerator", sink "Sink", sofa "Sofa", stairs "Stairs", storage "Storage", stove "Stove", table "Table", television "TV", toilet "Toilet", washerDryer "Washer or Dryer", desk "Desk", cabinet "Cabinet", shelf "Shelf", lamp "Lamp", plant "Plant", appliance "Appliance", vehicle "Vehicle", other "Object".

**Self-test.** `FloorPlanSelfTest.run()`, at least 35 checks: build from a 4 x 5 clean room gives one level, one room with area 20, 4 walls counter-clockwise, 4 wall dimensions and 2 overall dimensions labeled with `LengthFormat.primary`; door becomes an opening with the right offset and a swing; `PlanAxes` sign (world z = -3 maps to plan y = 3); every EditOperation that concerns the plan applies (rename, hide fixture, delete wall, move endpoint moves the dimension, add wall, add opening, swing, thickness, annotation, dimension, recategorize, move fixture) and an orphan returns false; `PlanDrawing` with toggles off removes the matching layers' entities and no others (all seven toggles); grid off has no A-GRID entities and on has some; scale on has at least 5 A-ANNO-SCAL entities; hidden fixture skipped; a `.user` door swing gives an arc entity with radius = width on A-DOOR; an `.estimated` swing gives entities only on A-DOOR-EST, with more than one arc piece; an estimated-thickness wall has its outer face on A-WALL-EST; occluded span produces a dashed layer entity; `Copy.FloorPlan.categoryName` is non-empty and distinct for every `ObjectCategory.allCases`; `hitTest` finds a wall 5 cm from the click and not at 1 m; `PlanViewport.fitting` maps bounds inside the margins and `toPlan(toScreen(p)) == p`; `pngData` returns PNG bytes starting with the PNG signature; `jpegThumbnail` returns JPEG bytes; `RoomTitles` for empty name with a kitchen label, empty name without label, and a user name.

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
    case realistic, raw, rawInferred, cleanStructure, cleanOpenings, cleanFurniture, cleanFixtures, cleanOccluded, overlay
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
/// Room mode with RoomCaptureView: while RoomPlan coaches, only deviceHot, trackingLost and
/// trackingLow pass (RoomPlan has no instruction for heat or tracking); otherwise everything passes.
struct GuidanceFilter: Equatable, Sendable {
    static let alwaysAllowed: Set<GuidanceKind> = [.deviceHot, .trackingLost, .trackingLow]
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

**Apple APIs.** `ARCamera.TrackingState { case notAvailable; case limited(ARCamera.TrackingState.Reason); case normal }` with Reason `initializing, relocalizing, excessiveMotion, insufficientFeatures`; `RoomCaptureSession.Instruction` cases `normal, moveCloseToWall, moveAwayFromWall, turnOnLight, slowDown, lowTexture` (not CaseIterable); `ObjectCaptureSession.Feedback` cases `environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected, objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing` (no `outOfRange`); `UIAccessibility.post(notification: .announcement, argument:)` with `NSAttributedString` key `.accessibilitySpeechAnnouncementPriority` (`.high` for tier 1) (not in RESEARCH; `UIAccessibility.post` iOS 3, announcement priority iOS 17.0, inside the rule 0.2.12 limit). Every switch has `@unknown default`.

**Must NOT do.** Never duplicate RoomPlan's coaching text (RESEARCH 3.10 gotcha 6); never show more than one message; never hardcode text; never use `UIImpactFeedbackGenerator(style:)` directly (use `Haptics`); no timing logic of its own beyond the haptic cooldown (the engine owns display rules).

**Copy strings.** Existing only: `Copy.Guidance.all` through `GuidanceKind.message`.

**Self-test.** `GuidanceUISelfTest.run()`, at least 15 checks: tracking mappings for all `TrackingSummary` cases; `GuidanceFilter` passes `.deviceHot`, `.trackingLost` and `.trackingLow` while coaching and drops `.moveSlower`, `.doorDetected`, `.scanCeiling`; passes all when not coaching; `shouldFireHaptic` false for tier 2, false within 5 s of the last, false when disabled, true otherwise; feedback mapping for a set containing movingTooFast and objectTooFar returns moveSlower (higher priority); empty set returns nil; `name(of:)` distinct for all six instructions.

**Acceptance checks.** The banner reads only `Copy`; the announcer is the only place that posts announcements and guidance haptics; mapping functions are total with `@unknown default`.

**SPEC owned.** "LIVE SCANNING EXPERIENCE" (messages "Move slower", "Tracking quality is low", "Lighting is poor", "Too close", "Too far", detection messages, "Do not overwhelm the user. Only show important instructions.").

### 3.18a Export revision (DXF units)

**Purpose.** Make the DXF floor plan match D23, RESEARCH 3.6 recommended 10 and TEST_PLAN EXP-07: coordinates in millimeters with a units note. The merged `DXFWriter` writes 1 drawing unit = 1 meter with no note, and ExportUI may not edit Export, so this small revision lands in wave 4a (one agent, branch `impl/export-dxf`).

**Build and wave.** Build 4, wave 4a. Export only (no new dependency).

**Files.** `ios/Sources/Export/DXFWriter.swift`, `ExportSelfTest.swift` (edits only).

**Public Swift API.**
```swift
extension DXFWriter {
    /// Multiplies every coordinate, radius, text height and dimension offset by 1000 when
    /// `millimeters` is true (so 1 drawing unit = 1 mm) and, when `unitsNote` is not nil, appends
    /// one TEXT entity with that string on the notes layer ("A-ANNO-NOTE" when present, else "0")
    /// at the lower-left of `plan.bounds()`, below the drawing. Still R12, still no `$INSUNITS`.
    static func text(for plan: Plan2D, millimeters: Bool, unitsNote: String?) throws -> String
    static func data(for plan: Plan2D, millimeters: Bool, unitsNote: String?) throws -> Data
}
```
The existing `text(for:)` and `data(for:)` stay and keep their current meaning (meters, no note), so nothing else changes. Export has no Copy dependency: the caller passes the note text (ExportUI passes `Copy.ExportUI.dxfUnitsNote`).

**Must NOT do.** No `$INSUNITS`, no DIMENSION entities, no new layers besides using an existing notes layer; no Copy import.

**Self-test.** Extend `ExportSelfTest` by at least 3 checks: a 4 m line becomes 4000 in the millimeter output (group codes 10 and 11); the note string appears once as a TEXT entity; `data(for:)` output is unchanged (meters).

**Acceptance checks.** `$EXTMIN` and `$EXTMAX` are scaled too; text heights scale with the coordinates.

**SPEC owned.** "2D FLOOR PLAN" output files (DXF in real units).

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
    /// Hub queue. Flushes every dirty anchor now (memory pressure, 3.21), without finishing.
    func flushNow()
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

**Must NOT do.** Never keep an `ARMeshAnchor` or its buffers past the call; never delete a chunk or its file on `didRemove` (RESEARCH 3.1 gotcha 15); never write world-space positions to raw (D8); never write after `finishRecording` was called (hub callbacks that still arrive are ignored, the ScanRecorder contract).

**Copy strings.** None.

**Self-test.** `MeshRecordSelfTest.run()`, at least 12 checks with a fake folder and synthetic `MeshChunk` values fed through an internal `ingest(_ chunk: MeshChunk)` entry point (the ARKit path is covered on device): ingest marks dirty and counts faces; a second ingest of the same anchor replaces it and bumps updateCount; `flushDue(now:)` true after 3 s; flush writes one `.mchk` per dirty anchor and clears dirty; a stale anchor keeps its file; finish flushes remaining dirty chunks and an ingest after finish writes nothing; `flushNow` writes dirty chunks without finishing; `evict` empties `currentChunks` and keeps index entries; bounds are world space (transform applied).

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
    /// (never thin afterwards, D6). `selector.consider` is called only when a FrameCopier buffer is
    /// free (`copier.inUse < count`), tracking is .normal, storage state is .ok, memory state is .ok,
    /// the engine is not paused (`isPaused`) and the thermal policy's keyframeIntervalScale allows
    /// it; otherwise the frame counts as skipped without touching the selector, so a skipped
    /// viewpoint is not rejected later as too close.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    func finishRecording(completion: @escaping () -> Void)
    var stats: RecorderStats { get }                 // keyframes, skippedKeyframes, writeFailures
    /// Any thread. While true no keyframe is taken (the engine sets it while paused, 3.21).
    var isPaused: Bool { get set }
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

**Self-test.** `KeyframesSelfTest.run()`, at least 15 checks: `FrameCopier` with count 2 returns 2 buffers then nil, and a buffer again after one is released; copied planes equal the source bytes for a synthetic 64 x 48 420f buffer (created with `CVPixelBufferCreate`); the gate configured from Standard settings accepts a 0.35 m move and rejects 0.1 m; a pool-exhausted frame followed by the same pose once a buffer is free is accepted (pure gate helper `static func shouldConsider(buffersFree:tracking:storage:memory:paused:) -> Bool`); Keep all photos off scales the gate by 1.5; pose track bytes for 3 samples decode with `PoseTrackFile.decode` to the same samples; the JSONL line for a keyframe decodes to the same `KeyframeRecord`; the photo request flag is consumed exactly once; JPEG encode of a synthetic buffer produces data starting with FF D8.

**Acceptance checks.** Pool size 4; skipped keyframes counted and logged per minute; the io queue is the Store queue; all three recorders tolerate `finishRecording` before any frame and ignore hub callbacks after it.

**SPEC owned.** "CORE DESIGN PRINCIPLE", Representation A ("camera poses", "camera frames where permitted", "depth information", "confidence information", "timestamps", "device orientation", "calibration information"); "IMAGE / TEXTURE CAPTURE" ("Capture camera imagery and associate images with camera poses", "Preserve original image quality where practical"); deliverable 12 "Images/photos associated with scanned locations" (capture side).

### 3.21 RoomCapture

**Purpose.** The Room scan engine (D1, D15): `RoomCaptureView(frame:arSession:)` with Apple's coaching, outlines and detection on the app-owned `ARSession` of CaptureCore, recorders plugged in through `ScanRecorder`, the exact order of operations that keeps mesh and depth alive, per-room persistence of RoomPlan data, sealing the room folder, live snapshots with filtered guidance, error mapping, and hooks for build 5 (live room, guidance and snapshot augmenters; next room on the same session).

**Build and wave.** Build 4, wave 4b. Core, CaptureCore, Store, RoomModel (RoomInput for the live hook), GuidanceUI, Coverage (GuidanceEngine), Support; ARKit, RoomPlan, SwiftUI, UIKit (background task).

`docs/REUSE.md` 4.4 is superseded by this section and 3.11: never re-apply the configuration in `didStartWith` (only the watchdog does), and use the API below, not the REUSE skeleton.

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
    /// True when the engine finished the room itself (heat, storage, memory): the ARSession was
    /// paused before `.roomFinished`, so build 5 hides Show Missing Areas for this room.
    var stoppedBySystem: Bool
}
/// Room engine. Call ScanEngine methods on main; work runs on hub.queue; events arrive on main.
/// `state` and `lastResult` are written only on main, inside the same `DispatchQueue.main.async`
/// that emits the matching event; hub.queue keeps a private phase copy for its own decisions.
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
    /// .lowStorage); creates the InProgress folder (kind .room) and the package's session folder
    /// (`package.sessionURL(_:)` through `ProjectStore.ensureDirectory(_:inside: package.root)`, where
    /// session.json goes); attaches and begins recorders; when the view already exists, runs
    /// captureSession.run(configuration:) with isCoachingEnabled true. Throws before creating
    /// anything on disk when a check fails.
    func start() throws
    /// Main. Marks paused (state only: RoomPlan has no pause and keeps scanning; KeyframeRecorder
    /// takes no keyframes while paused). Used for interruptions.
    func pause()
    /// Main. The user tapped Resume (Copy.Scanning.resume): back to `.scanning`. After
    /// `sessionInterruptionEnded` the engine stays `.paused` until this call, so the user can walk
    /// back to where they stopped, as `Copy.Scanning.paused` says.
    func resume()
    /// Main. captureSession.stop(pauseARSession: false); the finish sequence below runs; then
    /// .roomFinished(roomID:) with `lastResult` set. The ARSession keeps running (D19) unless the
    /// engine finished the room itself.
    func finish()
    /// Main. Ordered stop without sealing (Core ScanEngine.cancel): stop RoomPlan, detach the
    /// recorders on hub.queue, `finishRecording` on each, `writer.flush`, `writer.close()`; raw data
    /// stays in InProgress for recovery; then `.stateChanged(.idle)`.
    func cancel()
    /// Main. The user confirmed Discard Scan while capturing: `cancel()`'s ordered stop, then
    /// `InProgressScans.discard(scanID:)` once the writer is closed, then `.stateChanged(.idle)`.
    /// ScanFlowModel deletes the project only after that event.
    func discard()
    /// Main, idempotent, safe in any state: if a capture is still running it does `cancel()`'s
    /// ordered stop (raw stays in InProgress), then `hub.pause()`, detaches the recorders, nils the
    /// hub's onCaptureEvent, onStatus, onFrame and onMemoryPressure closures, and releases the view
    /// and the stored captureSession. ScanFlowModel calls it on every terminal phase (done, failed,
    /// cancelled) and `dismantleUIView` calls it too. Replaces the earlier `close()` and
    /// `stopIfRunning()`. Logs "room engine deinit" when released.
    func teardown()
    /// Main (build 5 House): same view and session, new InProgress folder, recorders begin again.
    func startNextRoom(roomID: UUID) throws
    /// Main. Valid after .roomFinished.
    private(set) var lastResult: RoomScanResult?
    /// Hub queue hooks for build 5 (CoverageLive, House). All optional.
    var liveRoomHandler: ((RoomInput) -> Void)?                     // at most 1 Hz
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)?
    var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)?
}
/// Delegates of RoomCaptureSession and RoomCaptureView (NSCoding stubs required). Holds the
/// engine weakly (`weak var engine: RoomScanEngine?`), so engine, hub and controller form no cycle.
final class RoomCaptureController: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate {
    override init()
    required init?(coder: NSCoder)
    func encode(with coder: NSCoder)
    // RoomCaptureSessionDelegate and RoomCaptureViewDelegate methods, verbatim below; each forwards
    // value copies to the engine on hub.queue.
}
/// SwiftUI host. makeUIView calls engine.makeCaptureView(); updateUIView does nothing. The
/// coordinator is the engine, because `dismantleUIView` is static and cannot read `self.engine`
/// (RESEARCH 3.10: `static func dismantleUIView(_ uiView: Self.UIViewType, coordinator: Self.Coordinator)`).
struct RoomCaptureContainer: UIViewRepresentable {
    init(engine: RoomScanEngine)
    func makeCoordinator() -> RoomScanEngine          // returns engine
    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: RoomScanEngine)   // coordinator.teardown()
}
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
    /// The finish sequence in order (tested as data, so the order cannot drift).
    static let finishSteps: [RoomFinishStep]
    /// Why the engine ends a room by itself, or nil: thermal .critical, storage .pause, memory .critical.
    static func systemStopReason(thermal: ThermalLevel, storage: StorageState, memory: MemoryState) -> MapperError?
}
enum RoomEngineSignal: Equatable, Sendable { case start, didStart, pause, interruptionEnded, resume, finish, sealed, failure, cancel }
enum RoomFinishStep: String, CaseIterable, Sendable {
    case writeRoomData, buildRoom, saveWorldMap, detachRecorders, finishRecorders, writeLogs,
         flushWriter, closeWriter, seal, pauseIfSystemStop, emitRoomFinished
}
```
If CI reports an actor-isolation error on the `RoomCaptureViewDelegate` conformance, move that conformance (with the NSCoding stubs) to a separate `@MainActor final class RoomCaptureViewDelegateBridge: NSObject, RoomCaptureViewDelegate` and keep `RoomCaptureSessionDelegate` on the nonisolated controller.

Order of operations at start (RESEARCH 3.1 recommended 3, 3.2 recommended 2 to 5, ship-first 3.1): hub.install (delegate and delegateQueue first), hub.run, create RoomCaptureView with the same session, set both delegates, `run(configuration:)`; in `captureSession(_:didStartWith:)` hop to `hub.queue`, call `hub.markScanStart`, log the effective configuration (`hub.diagnostics.logConfiguration(hub.session.configuration, label:)`) now and again 1 s and 5 s later, and log whether `session.delegate === hub` and `session.delegateQueue === hub.queue`. There is no unconditional re-apply here: on the `RoomCaptureView(frame:arSession:)` path RoomPlan preserves the session's settings, so only the hub watchdog re-applies the configuration, and only when depth or mesh is missing (RESEARCH ruling 1, D22). Hub closures capture the engine `[weak self]`.

Each tick (4 Hz, hub queue) builds a `LiveScanSnapshot` from `hub.status`, recorder stats and live counts, runs `GuidanceEngine.update` on `RoomScanStats.guidanceInput(...)` plus `guidanceAugmenter`, filters through `GuidanceFilter(roomPlanCoaching:)`, applies `snapshotAugmenter`, and posts `.snapshot` on main.

Live room safety net: `didUpdate` keeps the latest `CapturedRoom` value; at most every 10 s, and at once on `sessionWasInterrupted`, the engine encodes it with a plain `JSONEncoder()` inside `RawScanWriter.perform` and writes it atomically to `folder.liveCapturedRoomURL` (`capturedroom-live.json`). It stops at `didEndWith`. A scan killed by iOS or a force quit then still has a provisional room for recovery (RoomModel reads it with every value `.estimated`, RESEARCH 3.2 gotchas 6 and 11).

Interruptions: `sessionWasInterrupted` (through `hub.onCaptureEvent`) sets state `.paused` and emits `.stateChanged(.paused)`; `sessionInterruptionEnded` is logged and keeps `.paused` until the user taps Resume (`resume()`) or Finish Now.

Memory (D17, RESEARCH 3.9): `HubStatus.memory` `.low` (under 600 MB for two ticks) stops keyframes and logs `CaptureEvent(kind: .memory)`; `.critical` (under 400 MB for two ticks) or `hub.onMemoryPressure` makes the engine call `flushNow()` on every recorder (MeshStore flushes its dirty chunks) and then finish the room itself exactly as for heat, emitting `.failed(.lowMemory)` after `.roomFinished`.

Finish sequence (`finish()`, or the engine itself at thermal `.critical`, `CaptureError.deviceTooHot`, storage `.pause` or memory `.critical`). `captureSession(_:didEndWith:error:)` arrives synchronously on an undocumented thread; the controller copies the values and hands them to one `Task` that runs the whole sequence in this order (`RoomScanStats.finishSteps`), wrapped in `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` (ended at the last step or on expiry, not in RESEARCH, iOS 4, main):
1. `writeRoomData`: queue `capturedroomdata.json` (plain `JSONEncoder`) on the writer first, so a crash still leaves rebuildable data.
2. `buildRoom`: when `error` is nil or `CaptureError.exceedSceneSizeLimit` (keep the partial room, maps to `.sceneTooLarge`): `do { let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data); queue the capturedroom.json write } catch { log }`. Any other error sets the log's degraded mode to `.roomPlanFailed` and is reported through `RoomScanStats.mapError`. A RoomBuilder failure seals the room with `capturedroomdata.json` and no `capturedroom.json`; the pipeline's `BuildRoomStep` retries once and then leaves the room out.
3. `saveWorldMap`: when `hub.session.currentFrame?.worldMappingStatus` is `.mapped` or `.extending`, `getCurrentWorldMap(completionHandler:)` (wait at most 3 s), drop the `ARMeshAnchor`s from `anchors`, archive with `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` and write `folder.worldMapURL`; otherwise skip silently and log (feature points for SPEC Representation A; RESEARCH 3.1 world map block).
4. `detachRecorders`: detach every recorder from the hub on hub.queue, so no callback arrives after this point.
5. `finishRecorders`: on hub.queue call each recorder's `finishRecording(completion:)`, awaited with `withCheckedContinuation`.
6. `writeLogs`: `roomlog.json`, the remaining `events.jsonl` lines, and `raw/sessions/<s>/session.json` for the first room of the session (from `hub.diagnostics.sessionRecord(id:)`).
7. `flushWriter`: await `RawScanWriter.flush`.
8. `closeWriter`: `RawScanWriter.close()`; nothing can be written into the folder after this.
9. `seal`: `InProgressScans.seal(_:into: package.rawRoomURL(session:room:), package:)`.
10. `pauseIfSystemStop`: when the engine finished the room itself, `hub.pause()` now (RESEARCH 3.1 recommended 10: pause at critical), so the quality sheet shows over a stopped camera; `stoppedBySystem` is true.
11. `emitRoomFinished`: `DispatchQueue.main.async` sets `lastResult` and `state`, emits `.roomFinished`, and for a system stop then emits `.failed(.deviceTooHot)`, `.failed(.lowStorage(freeBytes:))` or `.failed(.lowMemory)`.
No file is written into the scan folder after `SEAL.json`.

**Uses.** CaptureCore: `ARSessionHub`, `ScanRecorder` (including `flushNow()`, so MeshRecord is never imported), `ScanProfile`, `HubStatus`, `MemoryState`, `CaptureDiagnostics`, `ThermalLevel` policy, `StorageState`. Store: `InProgressScans`, `InProgressScanInfo`, `RawScanWriter`. RoomModel: `RoomInput.init(_ room: CapturedRoom)`. GuidanceUI: `GuidanceSignals.isCoaching`, `GuidanceSignals.name(of:)`, `GuidanceSignals.tracking(_:)`, `GuidanceFilter`. Coverage: `GuidanceEngine`, `GuidanceInput`, `GuidanceOutput`. Core: `ScanEngine`, `ScanEngineState`, `ScanEngineEvent`, `LiveScanSnapshot`, `MapperError` (including `.lowMemory`), `RoomCaptureLog`, `DegradedMode`, `CaptureEvent`, `FrameLink`, `ProjectPackage`, `RawScanFolder` (`liveCapturedRoomURL`, `worldMapURL`), `ProjectStore.freeBytes`, `ProjectStore.refuseScanBelowBytes`. Support: `LogStore`.

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
func getCurrentWorldMap(completionHandler: @escaping (ARWorldMap?, (any Error)?) -> Void)   // ARSession (RESEARCH 3.1 world map)
var worldMappingStatus: ARFrame.WorldMappingStatus { get }                                   // .notAvailable, .limited, .extending, .mapped
```
Not in RESEARCH (all long-standing): `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` and `endBackgroundTask(_:)` (iOS 4, main), `ARWorldMap.anchors` (settable, iOS 12), `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:)` (iOS 11).

**Must NOT do.** Never write into the scan folder after `SEAL.json`; never emit `.roomFinished` before the seal; never leave the hub callbacks set after `teardown()`; never use the headless `RoomCaptureSession` in build 4 (D15); never set `isCoachingEnabled = false`; never create a second `RoomCaptureView` on the same session (tracking loss, RESEARCH 3.2 disputed 3) and never recreate it in `updateUIView`; never return true from `shouldPresent`; never call `stop()` without `pauseARSession: false` on Done; never pass reset run options on re-apply and never re-apply in `didStartWith` unless the watchdog asks for it; never write `beautifyObjects` on the capture configuration; never use the last `didUpdate` room as final (use RoomBuilder output); never show a banner that duplicates RoomPlan's coaching; never mark the engine or controller `@MainActor` (only the listed members).

**Copy strings.** Existing: `Copy.Errors.trackingFailed`, `interrupted`, `generic`. New (`extension Copy { enum RoomCapture }`): `sceneTooLarge = (title: "This room is too big for one scan", body: "Your scan so far is saved. Finish here and scan the rest as a new project.")`, `roomPlanFailed = (title: "Walls couldn't be found", body: "Your scan is saved. The 3D scan still works, but there is no floor plan or room measurements.")`, `tooHotFinished = (title: "Your iPhone is too hot", body: "Scanning stopped to let it cool down. Your scan is saved.")` (used instead of `Copy.Errors.tooHot`, whose body says "paused"), `lowMemory = (title: "Mapper needed to stop the scan", body: "Your iPhone was running low on memory. Your scan is saved.")`.

**Self-test.** `RoomCaptureSelfTest.run()`, at least 15 checks on the pure parts: `mapError` for every `CaptureError` case and an unknown error; `counts` of a fixture RoomInput (2 doors, 1 window, 1 opening in `openings`); `accumulate` sums per instruction; `guidanceInput` copies tracking, deviceHot and detection counts from a `HubStatus` and leaves angularSpeed 0 and centerDistance, ambientIntensity and depthConfidenceMean nil even when the status has them; a snapshot built from fixed inputs has the expected counts, degraded mode and guidance raw value; `RoomScanStats.next` for start, didStart, pause, interruptionEnded (stays paused), resume, finish, sealed, failure and cancel from each relevant state; `finishSteps` is exactly the 11 steps in the order above, with `seal` after `closeWriter` and `emitRoomFinished` last; `systemStopReason` for thermal critical, storage pause, memory critical and all-good.

**Acceptance checks.** Delegate signatures match RESEARCH character for character; `hub.install()` precedes view creation; `stop(pauseARSession: false)` on Done; `RoomCaptureView` is touched only on main and RoomPlan values cross queues only as value copies; every file write goes through `RawScanWriter`; the room folder is sealed before `.roomFinished` and nothing is written after `SEAL.json`; `teardown()` pauses the ARSession, clears the hub closures and is idempotent; two scans in a row log two "hub deinit" lines (no retain cycle); memory and thermal state logged at start and finish.

**SPEC owned.** "ROOM SCANNING" (all: RoomPlan where appropriate, ARKit mesh in parallel, not exclusively RoomPlan); "LIVE SCANNING EXPERIENCE" ("The user should see the model forming while walking" through RoomCaptureView outlines and mini model; "Window detected", "Door detected", "Wall detected" and "Tracking quality is low" from Mapper; speed, distance and lighting through RoomPlan's own coaching `slowDown`, `moveCloseToWall`, `moveAwayFromWall` and `turnOnLight` in Room mode, Mapper's own texts for those in mesh-only scans from build 5); "SCANNING MODES" ROOM; Representation A feature points (per-room world map).

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
    /// Share of keyframes taken in the dark or with a long exposure (excluded from the texture grid).
    var darkKeyframeFraction: Float
    /// `QualityStep.inputHash`: InputHasher over the room seal plus the room's buildRoom and
    /// consolidateMesh stamp hashes ("-" when absent). The quick evaluation at Done stores
    /// extra ["done"] instead, so the pipeline step always supersedes it.
    var inputHash: String
    var evaluatedAt: Date
}
enum QualityInputs {
    /// Plan outline (x, -z) back to Coverage's world (x, z); walls with base and height.
    static func boundary(for room: CleanRoom) -> CoverageRoomBoundary
    static func faces(_ mesh: MeshWithAttributes) -> [CoverageFace]
    /// Pose samples decimated to `hz`, trackingNormal = code 2; intrinsics from the nearest
    /// keyframe record (fallback: the first keyframe).
    static func observations(poses: [PoseSample], keyframes: [KeyframeRecord], hz: Double = 2) -> [CoverageObservation]
    /// Texture observations: a keyframe counts only when tracking was normal, `ambientIntensity`
    /// >= `QualityEvaluator.darkAmbientIntensity` and `exposureDuration` <=
    /// `QualityEvaluator.longExposureSeconds` (dark or blurred frames do not color a surface well).
    static func observations(keyframes: [KeyframeRecord]) -> [CoverageObservation]
    /// Fraction of keyframes failing the light test above.
    static func darkFraction(_ keyframes: [KeyframeRecord]) -> Float
}
enum QualityEvaluator {
    /// Tunables in one place (RESEARCH 3.8 disputed 13).
    static let edgeMissingFactor = 0.85, mediumConfidenceFactor = 0.7, lowConfidenceFactor = 0.5
    /// Light tunables (ARKit ambient intensity: 1000 is neutral; SPEC "lighting changes", TEST_PLAN TEX-06).
    static let darkAmbientIntensity: Float = 250
    static let longExposureSeconds: Double = 1.0 / 30
    static func evaluate(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes,
                         geometryObservations: [CoverageObservation], textureObservations: [CoverageObservation],
                         log: RoomCaptureLog?, inputHash: String, now: Date) -> QualityEvaluation
    /// Reads the sealed folder (RawScanReader), builds the clean room with RoomModel (mesh nil) and
    /// MeshConsolidator.fastWorldMesh, then `evaluate` with inputHash extra ["done"].
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation
}
enum QualityStore {
    static func url(_ package: ProjectPackage, room: UUID) -> URL          // derived/rooms/<r>/quality.json
    static func load(_ package: ProjectPackage, room: UUID) -> QualityEvaluation?
    /// Writes quality.json and sets RoomRecord.quality through ManifestWriter.
    static func save(_ evaluation: QualityEvaluation, package: ProjectPackage) throws
}
/// Re-evaluates with the consolidated mesh (falls back to the fast mesh when there is none) and
/// the rebuilt room. `inputHash` = InputHasher.hash(seals: [room seal], editRevision: nil,
/// extra: [buildRoom stamp hash or "-", consolidateMesh stamp hash or "-"]), so it runs after
/// the Done evaluation (extra ["done"]) and again whenever the room or mesh is rebuilt.
final class QualityStep: ProcessingStep { init(room: RoomRecord) }         // id .quality; budget 300 MB
```
Scores: walls = per-wall observed fraction of expected samples (Coverage `ExpectedSurfaces.evaluate`) after dropping samples inside that wall's doors, windows and openings, times 1.0 (4 completed edges and high confidence), `edgeMissingFactor`, `mediumConfidenceFactor` or `lowConfidenceFactor`, area-weighted; floor and ceiling from `ExpectedSurfacesResult.observedArea / expectedArea`; shape = area-weighted mean of the three; texture = `textureGrid.goodFaceAreaFraction(faces:)` where `textureGrid` integrates only keyframe observations that pass the light test (so a dark but well-tracked scan scores low); missing areas = Coverage clusters minus those whose centroid lies inside a window, door or opening; without a room (RoomPlan failed) Coverage's no-room path gives shape and texture and walls, floor and ceiling are reported as 0 with degraded `.roomPlanFailed`. Evidence per wall: median `bestDistance` and median `goodObservationCount` of the voxels at that wall's samples; tracking fraction = 1 - `RoomCaptureLog.limitedTrackingFraction`; relocalizations from the log. Percent values from Coverage (0...100) are divided by 100 for `QualitySummary`.

**Uses.** Coverage: `CoverageGrid`, `CoverageFace`, `CoverageObservation`, `CoverageRoomBoundary`, `CoverageWall`, `ExpectedSurfaces.evaluate`, `ExpectedSurfacesResult`, `ScanQuality.evaluate`, `SurfaceClass`, `MissingArea`. RoomModel: `CleanModelBuilder.buildRoom`, `CapturedRoomStore.loadInput`, `RoomInput`. MeshModel: `MeshConsolidator.fastWorldMesh`, `MeshModelStore.loadMeasured`. MeasureCore: `RoomEvidence`, `WallEvidence`. Store: `RawScanReader`, `ManifestWriter`. Core: `QualitySummary`, `QualityVerdict`, `CleanRoom`, `RoomRecord`, `RoomCaptureLog`, `DegradedMode`, `PoseSample`, `KeyframeRecord`, `InputHasher`, `SealFile`, `ProcessingStep`, `PlanAxes`, `Vec3`. MeshProcessing: `MeshWithAttributes`.

**Apple APIs.** None.

**Must NOT do.** Never treat `completedEdges` as a finish gate (soft factor only, RESEARCH 3.8 gotcha 3); never count windows and mirrors as missing (D19); never key coverage by face index across mesh versions (one evaluation uses one fixed face list); never block main; never write raw.

**Copy strings.** None (QualityUI owns the text).

**Self-test.** `QualitySelfTest.run()`, at least 20 checks using the Coverage prototype recipe (a 4 x 5 x 2.5 m room mesh at 0.2 m cells, camera circuit of 16 poses at 1.4 m height looking outward): all walls, floor and ceiling observed gives walls, floor and ceiling at least 0.9 and verdict good; removing the observations that see wall 2 lowers walls and adds a missing area on wall 2; a window rectangle on wall 2 removes that missing area; low confidence wall factor lowers the walls score by the expected ratio; texture score uses keyframes only (poses without keyframes give texture 0); boundary conversion flips z correctly (plan y 3 -> world z -3); evidence has one entry per wall with medianDistance about the circuit radius; decimation to 2 Hz of 10 Hz poses keeps one in five (and the default `hz` is 2); no-room path sets degraded `.roomPlanFailed`; 16 keyframes at ambientIntensity 100 give texture below 0.2 while the same poses at 1000 give at least 0.9, and `darkKeyframeFraction` is 1 and 0; the Done evaluation hash differs from the step hash for the same seal; `QualityEvaluation` Codable round trip.

**Acceptance checks.** `evaluateSealedRoom` never runs RoomBuilder (reads capturedroom.json only); percent to fraction conversion in one place; the manifest update goes through `ManifestWriter`; timings logged.

**SPEC owned.** "SCAN QUALITY SYSTEM" ("Track coverage for surfaces and geometry"; Geometry, Walls, Floor, Ceiling, Textures, Missing areas values); "MEASUREMENT CONFIDENCE" (evidence input).

### 3.23 TextureJob

**Purpose.** Representation B in build 4: textures the room's viewer mesh with the recorded keyframes using Texturing's `TextureBaker` at the Textured density, persists atlas pages and per-corner UVs, and loads them for the viewer and exports. Photo Realistic density and exposure normalization are build 6 (same module, second revision).

**Build and wave.** Build 4, wave 4b. Core, Texturing, MeshModel, MeshProcessing, Store, Export (`ByteWriter`), Support; ImageIO, CoreGraphics. Two parts with different slip rules (section 2.1): `TextureJobTypes.swift` and `TextureStore.swift` (`TextureDensity`, `TexturedMesh`, `TexturedPagePart`, `pageParts()`, `TextureStore`) never slip and merge in 4b first, because Results and ExportUI (4c) import them; `TextureJobInputs.swift` (`KeyframeLoader`) and `TextureLowStep.swift` may slip to 5a, and then AppShell leaves the step out of `ProcessingPlans`.

**Files.** `ios/Sources/TextureJob/TextureJobTypes.swift`, `TextureStore.swift` (non-slippable), `TextureJobInputs.swift`, `TextureLowStep.swift` (slippable), `TextureJobSelfTest.swift`.

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

**Apple APIs.** ImageIO (not in RESEARCH, iOS 4 or earlier) `CGImageSourceCreateWithURL`, `CGImageSourceCreateImageAtIndex` (options `kCGImageSourceShouldCache: false`), `CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)` (the UTI string literal, so no UniformTypeIdentifiers import is needed), `CGImageDestinationAddImage` with `kCGImageDestinationLossyCompressionQuality`, `CGImageDestinationFinalize`.

**Must NOT do.** No Metal; no hi-res stills; never decode all keyframes up front; never flip UVs; never texture the full-resolution measured mesh in build 4 (viewer mesh only); never hold finished atlas CGImages after writing them.

**Copy strings.** None (Results shows `Copy.Processing.stepTextures` and `Copy.Errors.textureFailed`).

**Self-test.** `TextureJobSelfTest.run()`, at least 12 checks: `encodeUV`/`decodeUV` round trip; corrupt UV data throws; `pageParts` of 3 faces on 2 pages returns 2 parts with 6 and 3 vertices and texcoords in corner order; untextured faces (source -1) are skipped; `TextureDensity.textured.options` values; `KeyframeLoader` subsampling picks evenly spaced indices (pure helper `static func subsample(count:max:) -> [Int]`); save then load round trip with a tiny synthetic TXResult (2 x 2 atlas CGImage) in a temp package.

**Acceptance checks.** Peak memory logged; pages written one at a time; the step is marked optional by AppShell; outputs only under `derived/rooms/<r>/texture/`, created with `ensureDirectory(_:inside:)` and written with `createParents: false` (CR-6); the non-slippable files compile without the slippable ones.

**SPEC owned.** "IMAGE / TEXTURE CAPTURE" ("Use those images to texture the reconstructed mesh", "overlapping images", "perspective differences", "texture seams", "If a perfect texture reconstruction is not possible, produce the best available result while preserving geometry", TEXTURED mode); deliverable 1 "A realistic textured 3D model" (build 4 level); "CORE DESIGN PRINCIPLE", Representation B (texture projection, texture blending).

---

## Build 4, wave 4c (screens; none imports another 4c module)

### 3.24 ScanUI

**Purpose.** The room scan flow for an amateur: preflight (camera permission with a pre-permission screen and an Open Settings path, LiDAR, free space D18, battery, heat; Demo Mode skips camera and LiDAR), tips once per mode, project creation, the full-screen scan screen (RoomCaptureView plus Mapper chrome: Cancel, Done, timer, counts, Take Photo, guidance banner), the `@MainActor` `ScanFlowModel` facade over any `ScanEngine` (D1), the quality check at Done, Finish, Cancel with confirmation, time hints, interruption handling, Demo Mode with `FakeScanEngine` and a synthetic demo project, and the optional snapshot recorder for real device recordings.

**Build and wave.** Build 4, wave 4c. Core, CaptureCore, Store, Pipeline (`IdleTimerGuard`), RoomCapture, MeshRecord, Keyframes, Quality, GuidanceUI, RoomModel, MeshModel, FloorPlan, Units, Support; SwiftUI, AVFoundation, ARKit, RoomPlan.

**Files.** `ios/Sources/ScanUI/ScanFlowModel.swift`, `ScanFlowModel+Room.swift`, `RoomScanScreen.swift`, `ScanChrome.swift`, `ScanPreflight.swift`, `ScanPermissionScreen.swift`, `ScanErrorCopy.swift`, `ScanTipsSheet.swift`, `DemoProjectFactory.swift`, `SnapshotRecorder.swift`, `ScanUISelfTest.swift`, `ios/Sources/Support/Copy+ScanUI.swift`.

**Public Swift API.**
```swift
extension SettingsKey {
    static let demoMode = "demoMode"                 // Bool
    static let keepScanPhotos = "keepScanPhotos"     // Bool, absent means on (ScanSettings.keepAllPhotos)
    static let recordSnapshots = "recordSnapshots"   // Bool (Diagnostics)
    static func tipsSeen(_ mode: ScanMode) -> String // "tipsSeen.<mode>"
}
enum ScanFlowPhase: Equatable { case preflight, permission, tips, capturing, stopping, checking, quality, finishing, done(UUID), failed(String), cancelled }
enum PreflightIssue: Equatable, Sendable { case cameraDenied, cameraUndetermined, noLidar, lowStorage(free: Int64), storageWarning(free: Int64), lowBattery(Float), deviceHot }
struct PreflightReport: Equatable, Sendable { var blocking: PreflightIssue?; var warnings: [PreflightIssue] }
enum ScanPreflight {
    /// Demo Mode needs only this much free space, bytes.
    static let demoMinimumFreeBytes: Int64 = 50_000_000
    /// Pure decision (tested): blocking = camera denied, camera undetermined (answered by the
    /// permission phase, not an alert), no LiDAR, free < ProjectStore.refuseScanBelowBytes;
    /// warnings = free < warnScanBelowBytes, battery < 0.2, thermal serious or worse. With
    /// `isDemo` the camera and LiDAR are ignored and the storage floor is `demoMinimumFreeBytes`.
    static func evaluate(cameraStatus: CameraPermission, lidarSupported: Bool, freeBytes: Int64, batteryLevel: Float?,
                         thermal: ThermalLevel, isDemo: Bool) -> PreflightReport
    /// Reads the real values without asking for camera access (the permission phase asks). In
    /// Demo Mode it never touches AVCaptureDevice or ARKit. Main actor.
    @MainActor static func run(mode: ScanMode, isDemo: Bool) async -> PreflightReport
}
enum CameraPermission: Equatable, Sendable { case authorized, denied, undetermined }
/// Buttons an alert offers; the view maps them to Copy and actions.
enum ScanAlertAction: Equatable, Sendable { case ok, openSettings, finishNow, resume }
struct ScanAlert: Identifiable, Equatable { var id: String; var title: String; var body: String; var actions: [ScanAlertAction] }
/// Exhaustive MapperError to alert mapping (no default, so a new Core case fails to compile
/// until it has text): lowStorage -> Copy.Errors.storageFullTitle and storageFullBody; unsupportedDevice
/// -> noLidar; cameraDenied -> Copy.Permissions.cameraDeniedTitle and cameraDeniedBody with
/// [.openSettings, .ok]; trackingFailed -> Copy.Errors.trackingFailed with [.resume, .finishNow] while
/// capturing; deviceTooHot -> Copy.RoomCapture.tooHotFinished; lowMemory -> Copy.RoomCapture.lowMemory;
/// sceneTooLarge -> Copy.RoomCapture.sceneTooLarge; roomPlanFailed -> Copy.RoomCapture.roomPlanFailed;
/// every other case -> Copy.Errors.generic.
enum ScanErrorCopy { static func alert(for error: MapperError) -> ScanAlert }
@MainActor final class ScanFlowModel: ObservableObject {
    @Published private(set) var phase: ScanFlowPhase
    @Published private(set) var snapshot: LiveScanSnapshot
    @Published private(set) var evaluation: QualityEvaluation?
    @Published private(set) var preflight: PreflightReport?
    @Published private(set) var isPaused: Bool          // engine .paused: chrome shows Resume and Finish Now
    @Published var alert: ScanAlert?
    @Published var showsCancelConfirmation: Bool
    @Published var showsTimeLimitSheet: Bool
    let mode: ScanMode; let isDemo: Bool
    private(set) var projectID: UUID?
    /// The live room engine (nil in Demo Mode); RoomScanScreen hosts its view.
    private(set) var roomEngine: RoomScanEngine?
    /// Called once after Finish with the project id (AppShell enqueues processing and opens Results).
    var onComplete: ((UUID) -> Void)?
    /// Called when the flow ends without a project (cancel, discard, blocking preflight).
    var onDismiss: (() -> Void)?
    init(mode: ScanMode, isDemo: Bool)
    func begin()                                     // preflight, then permission, tips or capture
    func permissionContinue() async                  // Continue on the pre-permission screen: requestAccess
    func tipsFinished(dontShowAgain: Bool)
    func done()                                      // Done button: finish, then quality check
    func resume()                                    // Resume while paused: roomEngine?.resume()
    func finishNow()                                 // Finish Now while paused or from an alert: same as done()
    func finish()                                    // Finish or Finish Anyway on the quality sheet
    func discardScan()                               // Discard on the quality sheet, after confirmation
    func requestCancel(); func confirmCancel(); func keepScanning()
    func openSettings()                              // UIApplication.openSettingsURLString
    func takePhoto()
}
enum ScanFlowSignal: Equatable, Sendable {
    case preflightPassed, preflightBlocked, permissionNeeded, permissionGranted, permissionDenied, tipsDone,
         engineStarted, doneTapped, engineStopping, roomFinished(UUID), evaluated, finishTapped, cancelConfirmed,
         discarded, failed(String)
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
Flow: `begin` runs `ScanPreflight.run(mode:isDemo:)`. A blocking issue shows `ScanErrorCopy`'s alert and then `onDismiss` (camera denied offers Open Settings, which calls `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString))`); camera undetermined goes to phase `permission`, a screen with `Copy.Permissions.cameraTitle`, `cameraBody` and `cameraContinue`, whose Continue calls `AVCaptureDevice.requestAccess(for: .video)` and then continues or shows the denied alert. Tips when `tipsSeen` is false. Then: create the project (`ProjectLibrary.shared.create(kind: .room, name: Copy.Home.defaultRoomName(date))`, settings `ScanSettings.defaults(for: .room)` with `keepAllPhotos` from the setting, append `CaptureSessionRef(id:startedAt:frameLink: .projectFrame(sessionID:), worldMapFile: nil)`); create recorders (`MeshStore()`, `KeyframeRecorder()`, `PoseTrackRecorder()`, `PhotoRecorder()`) and `RoomScanEngine(target:recorders:)`, or `FakeScanEngine()` in Demo Mode; `engine.start()` (when it throws, delete the project just created, show the alert and end with `onDismiss`); acquire an `IdleTimerGuard` token while the scan screen is visible (released in `onDisappear`; never write `isIdleTimerDisabled` directly); mirror `.snapshot` events.

Stopping: `done` (and `finishNow`) calls `engine.finish()` (phase stopping). `.stateChanged(.stopping)` also arrives when the engine finishes by itself (heat, storage, memory) and maps to `engineStopping`, `capturing -> stopping`; a `.roomFinished` that arrives in `capturing` goes straight to `checking`. On `.roomFinished` one `ProjectLibrary.update` appends the `RoomRecord` (status `.captured`, `capturedRoomID`, `keyframeCount`, `capturedAt`, `frameLink`) and sets the project status `.needsProcessing` (`.ready` in Demo Mode, whose files `DemoProjectFactory` writes complete), so a kill while the sheet is up still leaves a project that launch processing resumes. Then phase checking runs `QualityEvaluator.evaluateSealedRoom` in `Task.detached`, `QualityStore.save`, phase quality. A `.failed` event that arrives after `.roomFinished` (heat, storage, memory) shows its alert and keeps the finished room; the quality sheet still opens.

Ending: `finish` calls `roomEngine.teardown()`, phase done, `onComplete(projectID)`. `discardScan` (quality sheet Discard, same confirmation text as Cancel; lead decision 4) calls `roomEngine.teardown()` and `ProjectLibrary.discardRoom(roomID, in: projectID)`, which removes only the scan just captured and deletes the project when no room is left (always, for a build 4 Room project), then `onDismiss`. `confirmCancel` while capturing calls `engine.discard()` and, after its `.stateChanged(.idle)`, deletes the project when it has no rooms, then `teardown()` and `onDismiss`. A `.failed` before `.roomFinished` calls `teardown()` (raw stays in InProgress for recovery). Every terminal phase calls `teardown()`, which is idempotent.

Interruptions and time: on `.stateChanged(.paused)` the chrome shows `Copy.Scanning.paused` with Resume (`Copy.Scanning.resume`) and Finish Now (`Copy.ScanUI.finishNow`); `sessionInterruptionEnded` keeps the pause until the user taps Resume; after 30 s paused the alert `Copy.ScanUI.pausedFinishPrompt` offers [.finishNow, .resume]. The interrupted and trackingFailed alerts use [.resume, .finishNow]. After 4 minutes a tier 3 style hint (`Copy.ScanUI.timeHint`) shows once; after 5 minutes the time limit sheet (no automatic stop for time; the memory floor in 3.21 is the safety stop).

**Uses.** RoomCapture: `RoomScanEngine` (`teardown`, `discard`, `resume`), `RoomScanTarget`, `RoomScanResult`, `RoomCaptureContainer`. Pipeline: `IdleTimerGuard`. MeshRecord: `MeshStore`. Keyframes: `KeyframeRecorder`, `PoseTrackRecorder`, `PhotoRecorder`. CaptureCore: `ScanRecorder`, `ScanConfigurationFactory.supportsMesh`. Quality: `QualityEvaluator.evaluateSealedRoom`, `QualityStore.save`, `QualityEvaluation`. GuidanceUI: `GuidanceBanner`, `GuidanceAnnouncer`. Store: `ProjectLibrary` (`create`, `update`, `delete`, `discardRoom`). RoomModel: `RoomInput`, `CleanModelBuilder`, `CleanModelStore.save` (demo). MeshModel: `MeshModelStore`, `ConsolidationResult` (demo). FloorPlan: `PlanBuilder`, `PlanModelStore.save` (demo). Core: `ScanEngine` (`discard`), `ScanEngineEvent`, `FakeScanEngine`, `SnapshotRecording.synthetic`, `LiveScanSnapshot`, `ScanMode`, `ScanSettings`, `CaptureSessionRef`, `RoomRecord`, `FrameLink`, `ProjectStore`, `MapperError` (exhaustive switch in `ScanErrorCopy`), `ThermalLevel`. Support: `Copy.Scanning`, `Copy.Onboarding`, `Copy.Permissions`, `Copy.Errors`, `Copy.A11y`, `Haptics.success()`.

**Apple APIs.** `AVCaptureDevice.authorizationStatus(for: .video)`, `AVCaptureDevice.requestAccess(for: .video)` (async form) (not in RESEARCH, iOS 7; async import iOS 15); `UIApplication.openSettingsURLString` and `UIApplication.shared.open(_:options:completionHandler:)` (not in RESEARCH, iOS 8 and 10, main); `RoomCaptureSession.isSupported`; `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`; `UIDevice.current.isBatteryMonitoringEnabled = true` then `batteryLevel` (main); the idle timer only through Pipeline's `IdleTimerGuard`; SwiftUI `.fullScreenCover` is presented by AppShell, this module provides the content; `.persistentSystemOverlays(.hidden)`, `.environment(\.colorScheme, .dark)`, `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on the HUD; `.sensoryFeedback(.success, trigger:)` on finish.

**Must NOT do.** Never show the quality sheet itself (AppShell composes QualityUI); never enqueue processing (AppShell does in `onComplete`); never import QualityUI, Results, ExportUI or HomeUI; never touch ARKit, AVCaptureDevice or the LiDAR checks in Demo Mode; never delete raw data without the user's confirmation; never leave a project in `.capturing` after the flow ends; never write `isIdleTimerDisabled`; never hardcode text.

**Copy strings.** Existing: `Copy.Scanning.done`, `cancel`, `cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`, `paused`, `resume`, `startingUp`, `addPhoto`, `photoSaved`; `Copy.Onboarding.room`, `start`, `dontShowAgain`, `skip`; `Copy.Permissions.cameraTitle`, `cameraBody`, `cameraContinue`, `cameraDeniedTitle`, `cameraDeniedBody`, `openSettings`; `Copy.Errors.ok`, `noLidar`, `storageFullTitle`, `storageFullBody(_:)`, `lowBattery`, `interrupted`, `trackingFailed`, `generic`; `Copy.RoomCapture.*` (3.21); `Copy.A11y.scanView`, `doneScanning`, `doneScanningHint`. New (`enum ScanUI`): `static func elapsed(minutes: Int, seconds: Int) -> String` ("\(minutes):\(two-digit seconds)"), `timeHint = "Almost done? Tap Done when the room looks complete"`, `timeLimitTitle = "Time to finish this room"`, `timeLimitBody = "Long scans make your iPhone hot. Tap Done now. You can scan more later."`, `storageWarningTitle = "Storage is getting low"`, `static func storageWarningBody(_ size: String) -> String { "About \(size) free. A room scan can use a few hundred MB." }`, `warmTitle = "Your iPhone is warm"`, `warmBody = "Scanning makes it warmer. Take a break if it gets hot."`, `demoBanner = "Demo Mode: no camera is used"`, `static func counts(walls: Int, doors: Int, windows: Int) -> String { "\(walls) walls, \(doors) doors, \(windows) windows" }`, `pausedFinishPrompt = "Still paused. Finish with what you have?"`, `finishNow = "Finish Now"`.

**Self-test.** `ScanUISelfTest.run()`, at least 22 checks: `ScanPreflight.evaluate` blocking for denied camera, no LiDAR, 1 GB free; undetermined camera leads to the permission phase (preflight -> permission -> tips); warning only for 2 GB free, 15 percent battery, serious heat; clean report otherwise; with `isDemo` a denied camera and no LiDAR give no blocking issue and 30 MB free blocks; `ScanFlowModel.nextPhase` for the main path, both cancel paths, discard, `engineStopping` (capturing -> stopping), `roomFinished` while capturing (-> checking), and `.failed` after `roomFinished` staying on the quality path; `ScanErrorCopy.alert` returns a non-empty title for every `MapperError` case and [.openSettings, .ok] for cameraDenied; `Copy.ScanUI.elapsed(minutes: 4, seconds: 5)` is "4:05"; `DemoProjectFactory.makeDemoRoom` in a temp package writes clean.json and plan.json that load with `CleanModelStore.loadBase` and `PlanModelStore.loadBase`, with floor area 20 within 1e-3; `SnapshotRecorder` disabled returns nil.

**Acceptance checks.** The model is the only owner of the engine and recorders; engine events are handled on main; no quality or processing UI in this module; Demo Mode never imports ARKit code paths at runtime (no `RoomScanEngine` created) and never asks for the camera; every terminal phase calls `teardown()`; MODE-04 path: the denied alert's Open Settings opens Mapper's page in Settings.

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
    /// `Copy.Quality.noteDark` when more than 30 percent of keyframes were dark, else nil.
    static func lightNote(darkKeyframeFraction: Float) -> String?
    static func missingText(count: Int) -> String
}
/// nil evaluation shows the "Checking your scan..." state. `onShowMissingAreas` nil hides the button
/// (build 4; build 5 passes it only while the room's session is still running, D19). `onDiscard`
/// removes only the scan just captured (lead decision 4; ScanFlowModel.discardScan).
struct QualitySheet: View {
    init(evaluation: QualityEvaluation?, onFinish: @escaping () -> Void, onDiscard: @escaping () -> Void,
         onShowMissingAreas: (() -> Void)? = nil)
}
```

**Uses.** Quality: `QualityEvaluation`, `MissingAreaRecord`. Core: `QualitySummary`, `QualityVerdict`, `DegradedMode`. Support: `Copy.Quality.*`, `Copy.A11y.metric(_:percent:)`, `Copy.Scanning.cancelConfirmDiscard`.

**Apple APIs.** SwiftUI `.presentationDetents([.medium, .large])` (iOS 16) and `.interactiveDismissDisabled()` (iOS 15) are applied by AppShell (not in RESEARCH); this view uses `ProgressView(value:)`, `Gauge` or plain bars, `.accessibilityElement(children: .combine)`.

**Must NOT do.** No computation beyond presentation; never present itself; never hide the Finish Anyway path.

**Copy strings.** Existing: `Copy.Quality.title`, `geometry`, `walls`, `floor`, `ceiling`, `textures`, `missingAreas`, `summaryGood`, `summaryOkay`, `summaryPoor`, `finishAnyway`, `finish`, `showMissingAreas`, `percent(_:)`. New (`extension Copy.Quality` in `Copy+QualityUI.swift`): `checking = "Checking your scan..."`, `noteDepthStripped = "Some depth data was missing, so these numbers are rough."`, `noteMeshStripped = "The detailed 3D scan didn't record. Walls and the floor plan are fine."`, `noteRoomPlanFailed = "Walls couldn't be found, so there is no floor plan for this scan."`, `noteDark = "It was dark, so the color in your model may look poor."`. The Discard button reuses `Copy.Scanning.cancelConfirmDiscard`.

**Self-test.** `QualityUISelfTest.run()`, at least 10 checks: rows order and titles; 0.943 shows "94%"; tints at 0.95, 0.8, 0.5; finish title for 0 and 3 missing areas; degraded notes nil for allGood and non-nil for the others; `lightNote` nil at 0.3 and non-nil at 0.31; summary text per verdict.

**Acceptance checks.** All text from Copy; VoiceOver reads each row as "Walls, 100 percent".

**SPEC owned.** "SCAN QUALITY SYSTEM" (the SCAN QUALITY screen, FINISH ANYWAY; SHOW MISSING AREAS entry point in build 5).

### 3.26 Results

**Purpose.** The result screen: segmented Realistic, 3D Clean, Floor Plan, Raw Scan switcher, available from the moment the floor plan exists with per-tab status chips while later steps run (D20); display style menu; Hide Furniture with occluded regions marked and a legend; missing areas marked as unscanned; floor plan toggles; wall, door and window selection (3D Clean and Floor Plan) that filters the dimensions panel; the room dimensions panel with plus or minus confidence; a read-only object card when tapping an object box (category guess and width, height, depth with confidence); project rename; a retry for failed processing; the RoomPlan model in Quick Look as the Realistic fallback; an Export button that calls back to AppShell with the current view state.

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
    /// Pure. Decides from the files on disk plus the in-memory processing state, never from stamps
    /// (stamps are the runner's business; a demo or relaunched project has an empty state).
    /// Realistic: texture ready, else preparing while textureLow runs, else failed text, else
    /// "fallback available" when a CapturedRoom exists. Clean and Floor Plan need clean/plan files;
    /// Raw needs the view mesh; RoomPlan failure makes Clean and Floor Plan unavailable with the reason.
    /// `degraded` comes from `RawScanReader.roomLog()?.degraded` (raw truth), overridden to
    /// `.roomPlanFailed` only when `CapturedRoomStore.loadInput` fails after the job finished; never
    /// from `QualityEvaluation.degraded`.
    static func compute(_ tab: ResultTab, files: ResultFiles, processing: ProjectProcessingState, degraded: DegradedMode) -> TabAvailability
    /// Pure. The processing view shows only while `(processing.isQueued || processing.isRunning) && !files.hasPlan`.
    static func showsProcessingView(files: ResultFiles, processing: ProjectProcessingState) -> Bool
    /// Pure. Retry shows when `status == .needsAttention` or `processing.failed` is not empty.
    static func showsRetry(status: ProjectStatus, processing: ProjectProcessingState) -> Bool
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
    /// Selected wall, door, window or opening (3D Clean tap or Floor Plan tap); nil shows all rows.
    @Published private(set) var selectedElement: ElementID?
    @Published private(set) var objectRows: [DimensionRow]   // MeasureCore objectRows of selectedObject
    @Published private(set) var missingAreaCount: Int
    @Published var showsLegend: Bool
    @Published var quickLookURL: URL?
    @Published private(set) var title: String
    let viewer: ViewerModel
    init(projectID: UUID)
    func load() async                        // manifest, PackageCheck.verify (off main; problems mark the
                                             // project .needsAttention via ManifestWriter), edited clean
                                             // model and plan, quality evidence and missing areas, files
    func show(_ tab: ResultTab) async        // builds the tab's ViewerContent off main, then viewer.load
    /// `.element(id)` of a wall or opening part: selectedElement (plus a highlight copy of the part
    /// on `.overlay`); of an object box: selectedObject and objectRows; nil or raw mesh: clears both.
    func handleTap(_ hit: ViewerHit?)
    func selectPlanHit(_ hit: PlanHit?)      // Floor Plan tab: walls and openings drive selectedElement
    func clearSelection()                    // "Show all" in the dimensions panel
    /// Visible rows: all rows, or only rows whose `element == selectedElement`.
    var visibleRows: [DimensionRow] { get }
    func rename(to name: String) throws      // ProjectLibrary.rename; title updates
    /// Current view state for exports (plan toggles and Hide Furniture).
    var exportViewState: ExportViewState { get }
    func openSimpleModel() async             // CapturedRoom.export(to:metadataURL:modelProvider:exportOptions: [.mesh]) into exports/simple/ (fixed name, replaced each time), sets quickLookURL
}
/// While `ResultAvailability.showsProcessingView` is true the screen shows the processing view
/// instead of the tabs (D20): `Copy.Processing.title`, the current step's text (`stepText`), a
/// progress bar and `Copy.Processing.keepOpen`; then the tabs appear with chips for the steps still
/// running. A demo project, or a relaunched project whose job is not queued, shows the tabs at once,
/// each tab deciding from its files. `onRetry` shows as `Copy.Errors.tryAgain` when
/// `ResultAvailability.showsRetry` is true; tapping the title offers Rename (`Copy.Project.rename`,
/// `renameTitle`).
struct ResultScreen: View { init(projectID: UUID, onExport: @escaping (ExportViewState) -> Void, onRetry: @escaping () -> Void) }
```
Content per tab: Realistic = `TextureStore.load` pages via `pageParts()` into `ViewerPart`s with `.texture(url)`; Solid Color and Wireframe styles re-use the view mesh. 3D Clean = `CleanMeshBuilder.parts`: walls light gray `.lit`, floor, openings translucent, every wall, door, window and opening part with `pickTag: .element(part.element)`, objects translucent boxes plus wireframe with `pickTag .element(id)`, furniture in `.cleanFurniture` so Hide Furniture toggles that layer, and the `.occluded` parts as a translucent gray (`.translucent([0.5, 0.5, 0.5, 0.45])` plus a `.wireframe` copy so they read as hatched) on `ViewerLayer.cleanOccluded`, visible only while Hide Furniture is on; ceiling hidden. Missing areas (3D Clean and Raw Scan): one `ViewerPart` per `MissingAreaRecord` of `QualityStore.load` on `.overlay`, a square of side sqrt(area) centered at `centroid`, facing `normal`, offset 2 cm along it, material `.translucent([1, 0.2, 0.2, 0.5])`, with a toolbar count (`Copy.Quality.missingAreas`) and the Unscanned legend entry; they are never filled with geometry. Floor Plan = `PlanCanvasView` of `PlanDrawing.make(level:toggles:prefs:roomTitles:name:)` with `RoomTitles.titles(for:)`; its `onTap` calls `selectPlanHit`. Raw Scan = `MeshModelStore.loadView` (measured) plus `loadInferred` (`.rawInferred`, Inferred color) plus `loadFloaters` (`.raw`, the noise that cleanup removed, so the tab shows the scan as captured) through `ViewerContentBuilder.meshParts` with `MeshClassPalette.all`. The dimensions panel lists `visibleRows` of `RoomDimensions.rows(for:evidence:)` (evidence from `QualityStore.load`, else `RoomEvidence.unknown`) with `MeasureDisplay.valueText` and `accuracyText`, grouped, the Walls group with `Copy.MeasureCore.wallAreaNote`, a Show All control while something is selected, plus `Copy.Measure.disclaimer`. The object card shows `Copy.Results.objectGuess(Copy.FloorPlan.categoryName(object.category))` and the three `objectRows` with `MeasureDisplay.valueText` and `accuracyText`. The legend sheet (a Legend button on 3D Clean and Floor Plan, `Copy.Measure.legendTitle`) lists Measured, Estimated, Inferred, Occluded and Unscanned with their detail lines and a swatch matching the viewer and plan styles (solid, dashed, Inferred color, gray hatch, red square). The model observes `ProcessingRunner.shared.states[projectID]` and `.mapperManifestDidChange` and reloads what changed. Units come from `UnitPreferences.load()` on appear.

**Uses.** Viewer3D: `ViewerModel`, `ViewerContainer`, `ViewerContent`, `ViewerPart`, `ViewerMaterial`, `ViewerLayer`, `ViewerPickTag`, `ViewerHit`, `ViewerContentBuilder`, `ViewerDisplayStyle`. FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing`, `PlanDrawingResult`, `PlanHit`, `PlanToggles`, `ExportViewState`, `PlanCanvasView`, `RoomTitles`, `Copy.FloorPlan.categoryName(_:)`. MeasureCore: `RoomDimensions` (`rows`, `objectRows`), `DimensionRow`, `MeasureDisplay`, `RoomEvidence`. RoomModel: `CleanModelStore.loadEdited`, `CleanMeshBuilder` (including `.occluded` parts), `CapturedRoomStore.loadCapturedRoom`, `CapturedRoomStore.loadInput`. MeshModel: `MeshModelStore` (`loadView`, `loadInferred`, `loadFloaters`), `MeshClassPalette`. TextureJob: `TextureStore`, `TexturedMesh`. Quality: `QualityStore.load`, `MissingAreaRecord`. Pipeline: `ProcessingRunner.shared`, `ProjectProcessingState`. Store: `ProjectLibrary` (`rename`), `PackageCheck`, `ManifestWriter`, `RawScanReader.roomLog()`. Core: `ProjectManifest`, `ProjectStatus`, `DetectedObject`, `DegradedMode`, `PipelineStepID`. Units: `UnitPreferences`, `LengthFormat`. Support: `Copy.Viewer`, `Copy.Processing`, `Copy.Measure`, `Copy.Quality.missingAreas`, `Copy.Errors.textureFailed`, `Copy.Errors.tryAgain`, `Copy.Project.rename`, `renameTitle`, `Copy.Empty.noFloorPlan`, `Copy.A11y.viewSwitcher`, `viewSwitcherHint` (not `Copy.ObjectMenu.guessedLabel`, whose "Tap to correct it" is build 7).

**Apple APIs.** `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (file name starts with a letter); `nonisolated func quickLookPreview(_ item: Binding<URL?>) -> some View`; SwiftUI `Picker` with `.pickerStyle(.segmented)` for the switcher, `Menu` for display styles and toggles.

**Must NOT do.** Never block main while loading meshes (build parts in `Task.detached`); never embed `QLPreviewController` in a representable (RESEARCH 3.7 gotcha 19); never show a number without its confidence text; never present ExportUI directly; never gate the tabs on stamps; never draw occluded or missing regions as measured surfaces; no geometry editing in build 4 (read-only object card; rename is the only change).

**Copy strings.** Existing: `Copy.Viewer.realistic`, `clean`, `floorPlan`, `raw`, `displayTitle`, `photoRealistic`, `textured`, `solidColor`, `wireframe`, `hideFurniture`, `showFurniture`, `export`, `width`, `height`, `depth`, `resetView`; `Copy.Processing.stepShape`, `stepClean`, `stepFloorPlan`, `stepTextures`, `done`; `Copy.Measure.disclaimer`, `legendTitle`, `measured`, `measuredDetail`, `estimated`, `estimatedDetail`, `inferred`, `inferredDetail`, `occluded`, `occludedDetail`, `unscanned`, `unscannedDetail`. New (`enum Results`): `static func objectGuess(_ category: String) -> String { "Mapper thinks this is a \(category)." }`, `legend = "Legend"`, `showAll = "Show All"`, `static func stepProgress(_ step: String, percent: Int) -> String { "\(step) \(percent)%" }`, `colorPreparing = "Color is still being added"`, `simpleModel = "View Simple Model"`, `simpleModelNote = "A simple model from the room scan, without color."`, `noWalls = "Floor plans need walls. This scan has none."`, `dimensionsTitle = "Measurements"`, `photoRealisticLater = "Photo Realistic comes in a later version"`.

**Self-test.** `ResultsSelfTest.run()`, at least 22 checks on the pure parts: `ResultAvailability.compute` realistic ready with texture; preparing with percent while textureLow runs; failed text when textureLow failed; fallback when only a CapturedRoom exists; clean unavailable when `.roomPlanFailed`; floor plan preparing while floorPlan runs; raw ready with the view mesh; demo files with an empty processing state show the tabs (`showsProcessingView` false) with every tab but realistic ready; an empty state with status `.ready` and no plan shows the tabs with Floor Plan unavailable; a queued job without a plan shows the processing view; `showsRetry` for `.needsAttention` and for a failed step; row filtering by one wall's element returns its 3 rows; 3 missing area records give 3 overlay parts of 2 triangles each (pure builder `static func missingAreaParts(_:) -> [ViewerPart]`); occluded parts go to `.cleanOccluded`; the step-to-text mapping (`static func stepText(_ step: PipelineStepID) -> String`).

**Acceptance checks.** Tab switching never reloads unchanged content; Hide Furniture toggles the furniture and occluded layers, it does not rebuild; dimension rows use MeasureDisplay only; tapping a wall in 3D Clean or on the plan highlights it and filters the panel to its length, height and area (MEAS-02, MEAS-06, CONF-01, smoke #7); the legend explains every marking (FURN-02); missing areas are visible after Finish Anyway (QUAL-04); the Quick Look file lives in `exports/simple/`.

**SPEC owned.** "ROOM SCANNING" ("After scanning, allow the user to switch between: REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH"); "FURNITURE REMOVAL" (HIDE FURNITURE, blocked regions marked OCCLUDED and missing ones UNSCANNED with a legend); "PROJECT SYSTEM" (rename); "MEASUREMENT SYSTEM" and "MEASUREMENT CONFIDENCE" (display); "AUTOMATIC OBJECT RECOGNITION" (labels shown as guesses); "IMAGE / TEXTURE CAPTURE" display modes selection; deliverables 1 to 7.

### 3.27 ExportUI

**Purpose.** The export sheet and export jobs (deliverable 14 "Exportable professional files"): formats grouped by representation with plain explanations, availability with reasons, options, the result screen's view state (Hide Furniture, plan toggles) applied to the files, running writers off main, staging files in `exports/` and cleaning them up, and sharing through a `UIActivityViewController` wrapper.

**Build and wave.** Build 4, wave 4c. Core, Export, Store, RoomModel, MeshModel, FloorPlan, MeasureCore, Quality, TextureJob, Units, Support; SwiftUI, UIKit, RoomPlan.

**Files.** `ios/Sources/ExportUI/ExportSheet.swift`, `ExportCatalog.swift`, `ExportRunner.swift`, `ExportAdapters.swift`, `ExportSummaryJSON.swift`, `ExportShare.swift`, `ExportUISelfTest.swift`, `ios/Sources/Support/Copy+ExportUI.swift`.

**Public Swift API.**
```swift
enum ExportRepresentation: String, CaseIterable, Identifiable, Sendable { case realistic, clean, raw, floorPlan, data; var id: String { rawValue } }
enum ExportFileFormat: String, CaseIterable, Identifiable, Sendable { case usdz, obj, ply, stl, glb, pdf, svg, dxf, png, json; var id: String { rawValue } }
struct ExportInputs: Equatable, Sendable { var hasTexture = false, hasKeyframes = false, hasClean = false, hasPlan = false, hasMesh = false, hasCapturedRoom = false, hasEdits = false, meshTriangles = 0; init() }
struct ExportOption: Identifiable, Equatable, Sendable {
    var representation: ExportRepresentation; var format: ExportFileFormat
    var isAvailable: Bool; var reason: String?; var id: String { get }
}
enum ExportCatalog {
    /// realistic: usdz, obj (zip), glb; clean: usdz, obj, glb; raw: usdz, obj, ply, stl, glb;
    /// floorPlan: pdf, svg, dxf, png; data: json. Unavailable ones carry a reason: Copy.Export.noColor
    /// when no keyframes were captured, Copy.ExportUI.colorNotReady when keyframes exist but
    /// `TextureStore.exists` is false (still running, failed or slipped), Copy.Export.noFloorPlan.
    static func options(for inputs: ExportInputs) -> [ExportOption]
    static func fileName(project: String, option: ExportOption, date: Date) -> String   // starts with a letter; DXF gets "_mm"
    /// Explicit switch over ExportFileFormat to its (label, detail) (never an index into
    /// Copy.Export.formats): usdz, obj, stl, glb, pdf, svg, dxf, json, png ("Images") from
    /// Copy.Export.formats by label; ply uses Copy.ExportUI.plyDetail in build 4 (class colors, not photo color).
    static func label(for format: ExportFileFormat) -> (label: String, detail: String)
}
/// `unitsOverride` nil uses the app's UnitPreferences for PDF, SVG and PNG labels (Copy.Export.units).
struct ExportSettings: Equatable, Sendable { var includeTextures = true; var includeHidden = false; var includeMeasurements = true; var paper: PDFPlanWriter.Paper = .usLetter; var unitsOverride: UnitSystem? = nil; init() }
enum ExportRunner {
    /// Off main. Writes into exports/<yyyyMMdd-HHmmss>/ and returns the file (or zip) URL.
    static func run(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                    package: ProjectPackage, prefs: UnitPreferences) async throws -> URL
    /// At launch (AppShell): deletes `exports/<stamp>/` staging folders older than 24 hours in
    /// every package. Any thread.
    static func removeStaleStaging(olderThan seconds: TimeInterval = 86_400, now: Date = Date())
}
enum ExportAdapters {
    /// CleanMeshBuilder parts, one material per kind. `includeMovable` false (Hide Furniture on
    /// the result screen) drops movable objects unless `includeHidden` asks for hidden ones;
    /// occluded parts are never exported as surfaces.
    static func cleanScene(_ model: CleanModel, includeHidden: Bool, includeMovable: Bool) -> ExportScene
    static func rawScene(_ package: ProjectPackage, room: UUID, maxTextTriangles: Int) throws -> ExportScene
    static func texturedScene(_ mesh: TexturedMesh) throws -> ExportScene              // pageParts, ExportMaterial(textureJPEG:) per page
    /// `PlanDrawing.make` with the result screen's toggles (TEST_PLAN EXP-05: every visible layer, no hidden one).
    static func planDrawing(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles) throws -> Plan2D
}
/// Summary JSON: rooms with metrics (meters, square meters, provenance, sigma), openings, objects
/// (category, label, box), quality summary; plus capturedroom.json when present (both zipped).
enum ExportSummaryJSON { static func data(model: CleanModel, evidence: [UUID: RoomEvidence], manifest: ProjectManifest) throws -> Data }
struct ExportSheet: View { init(projectID: UUID, viewState: ExportViewState) }
/// `completionWithItemsHandler` deletes that export's staging folder once the share finishes.
struct ActivityShareSheet: UIViewControllerRepresentable { init(items: [Any], stagingFolder: URL?) }
```
Rules: clean USDZ uses RoomPlan's own `export(to:metadataURL:modelProvider:exportOptions: [.mesh])` with a `.plist` metadata URL next to it (RESEARCH 3.2 recommended 9; walls with door and window cutouts; only the `.usdz` is shared) when the project has one room, a CapturedRoom and no active edits, else `USDZWriter` from `cleanScene`; raw OBJ and USDZ (text formats) use the full mesh up to 600k triangles, else the view mesh plus the inferred mesh as a separate object (the Inferred distinction survives) with the note `Copy.ExportUI.simplifiedNote`; PLY, STL and GLB always use the full measured mesh; STL uses `STLWriter.Options.printing` (millimeters, Z up); DXF comes from `DXFWriter.data(for: plan, millimeters: true, unitsNote: Copy.ExportUI.dxfUnitsNote)` (the wave 4a Export revision, 3.18a; D23: no `$INSUNITS`) with "_mm" in the file name; PDF uses `PDFPlanWriter.data(for:options:)` with `scaleCaption: Copy.ExportUI.scaleCaption` and `northAngle: Double.pi / 2 + Double(plan.northAngle)` (PlanModel measures counter-clockwise from +y, the writer from +x; the default while `northAngle == 0`); every plan format uses `ExportAdapters.planDrawing(_:prefs:toggles:)` with `viewState.planToggles`, and clean 3D formats pass `includeMovable: !viewState.hideFurniture`; PNG uses `PlanRenderer.pngData(_:pixelWidth: 3000)`; multi-file results are zipped with `ZipWriter.archive` (small) before sharing; share folders never, only files.

**Uses.** Export: `ExportScene`, `ExportMesh`, `ExportMaterial`, `OBJWriter.zipBundle`, `OBJWriter.write`, `PLYWriter.data`, `STLWriter.binary`, `GLBWriter.data`, `USDZWriter.data`, `DXFWriter.data(for:millimeters:unitsNote:)`, `SVGWriter.data`, `PDFPlanWriter.data`, `PDFPlanWriter.Options`, `PDFPlanWriter.Paper`, `ZipWriter.archive`, `ExportError`. RoomModel: `CleanModelStore.loadEdited`, `CleanMeshBuilder.parts`, `CapturedRoomStore.loadCapturedRoom`. MeshModel: `MeshModelStore`, `MeshExportAdapter.scene`. FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing.make`, `PlanToggles`, `ExportViewState`, `RoomTitles`, `PlanRenderer.pngData`, `Copy.FloorPlan.categoryName(_:)` (summary JSON and labels). TextureJob: `TextureStore.load`, `TexturedMesh.pageParts`. Quality: `QualityStore.load`. MeasureCore: `RoomEvidence`. Store: `ProjectLibrary`, `EditStore.load`. Core: `ProjectPackage.exportsURL`, `ProjectStore.writeData`. Units: `UnitPreferences`. Support: `Copy.Export.*`, `Copy.Errors.exportFailed`.

**Apple APIs.** `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` with `[.mesh]` and a `.plist` metadata URL (iOS 17.0; `USDExportOptions` is an OptionSet of `.parametric`, `.mesh`, `.model`); `init(activityItems: [Any], applicationActivities: [UIActivity]?)` (UIActivityViewController, iOS 6; RESEARCH 3.7 names the wrapper, not the initializer); `.quickLookPreview` for USDZ and PDF preview (optional).

**Must NOT do.** Never write outside `exports/`; never read outside the package; never add `$INSUNITS`; never use `MDLAsset.export` or SceneKit for USD; never share a folder URL (zip first); never ignore the result screen's view state; never index `Copy.Export.formats` by position; never block main.

**Copy strings.** Existing: `Copy.Export.title`, `subtitle`, `button`, `preparing`, `ready`, `includeTextures`, `includeHidden`, `includeMeasurements`, `units`, `noFloorPlan`, `noColor`, `formats`. New (`enum ExportUI`): `realisticSection = "3D Model with Color"`, `cleanSection = "3D Clean Model"`, `rawSection = "Raw Scan"`, `planSection = "Floor Plan"`, `dataSection = "Data"`, `simplifiedNote = "Simplified to keep the file a manageable size."`, `scaleCaption = "Scale"`, `paper = "Paper Size"`, `letter = "US Letter"`, `a4 = "A4"`, `dxfUnitsNote = "Units: millimeters"`, `plyDetail = "The raw scan shape for 3D and research software."`, `colorNotReady = "Not available yet: color is still being added"`, `unitsApp = "Same as the app"`.

**Self-test.** `ExportUISelfTest.run()`, at least 20 checks: catalog availability for no texture, no plan, demo inputs, and the colorNotReady reason when keyframes exist without a texture; `label(for:)` gives each format its own entry (png is "Images", json is "JSON"); DXF file name ends in "_mm.dxf"; `planDrawing` with the furniture toggle off has no A-FURN entities; `cleanScene` with `includeMovable: false` has no movable object meshes; file names start with a letter even for a project named "3rd floor"; `cleanScene` of a demo clean model validates (`ExportScene.validate()`); `texturedScene` of a 2-face textured mesh has one material with JPEG data and bottom-left texcoords unchanged; summary JSON parses with `JSONSerialization` and has rooms[0].metrics.floorArea; raw scene threshold picks the view mesh above 600k.

**Acceptance checks.** Each format uses the listed writer; zips only in memory for small outputs; errors map to `Copy.Errors.exportFailed`; the share sheet receives file URLs that survive until dismissal.

**SPEC owned.** Deliverable 14 "Exportable professional files"; "PROJECT SYSTEM" (export); "2D FLOOR PLAN" output files.

### 3.28 HomeUI (wave 4b; listed here with the other screens)

**Purpose.** Home: the projects list with thumbnails, subtitles by mode, processing and needs-work badges, search, empty state and privacy footer, rename, delete with confirmation, the big New Scan button and the mode picker (Room enabled in build 4, the other modes shown disabled with "Coming in a later version").

**Build and wave.** Build 4, wave 4b (lead decision 7: it needs only Store and Pipeline from 4a, so it no longer waits for 4c). Core, Store, Pipeline, Units, Support; SwiftUI.

**Files.** `ios/Sources/HomeUI/HomeScreen.swift`, `HomeProjectRow.swift`, `HomeModePicker.swift`, `HomePresentation.swift`, `HomeUISelfTest.swift`, `ios/Sources/Support/Copy+HomeUI.swift`.

**Public Swift API.**
```swift
enum HomeBadge: Equatable, Sendable { case processing, needsWork }
enum HomePresentation {
    static func subtitle(for manifest: ProjectManifest, dateText: String) -> String
    static func badge(for manifest: ProjectManifest, processing: ProjectProcessingState?) -> HomeBadge?
    /// Drops `.capturing` projects (a scan in progress or awaiting launch recovery; they never open
    /// Results) and archived ones unless `showArchived`; case-insensitive name search.
    static func filtered(_ projects: [ProjectManifest], query: String, showArchived: Bool) -> [ProjectManifest]
}
struct HomeScreen: View {
    init(library: ProjectLibrary, runner: ProcessingRunner, availableModes: Set<ScanMode>,
         onNewScan: @escaping (ScanMode) -> Void, onOpen: @escaping (UUID) -> Void, onSettings: @escaping () -> Void)
}
struct ModePickerSheet: View { init(availableModes: Set<ScanMode>, onPick: @escaping (ScanMode) -> Void, onCancel: @escaping () -> Void) }
```

Rename: a swipe action and a context menu item (`Copy.Project.rename`) open an alert with a text field (`Copy.Project.renameTitle`, `Copy.Errors.ok`, cancel) that calls `ProjectLibrary.rename` (default names repeat, for example two "Room Sep 28" on one day, UX_COPY section 1). Delete: calls `runner.cancel(projectID:)` first and deletes in the job's end, or refuses with the row disabled while `state.isRunning`, so no step writes into a deleted package.

**Uses.** Store: `ProjectLibrary` (`projects`, `delete`, `rename`). Pipeline: `ProcessingRunner` (`cancel`), `ProjectProcessingState`. Core: `ProjectManifest`, `ScanMode`, `RoomStatus`, `ProjectPackage.thumbnailURL`. Support: `Copy.Home.*`, `Copy.Modes.*`, `Copy.Project.rename`, `renameTitle`, `deleteTitle(_:)`, `deleteBody`, `deleteConfirm`, `Copy.Empty.noProjects`, `noSearchResults`, `Copy.A11y.newScanHint`, `openProjectHint`, `projectRow(name:type:date:)`, `projectNeedsWork(_:)`.

**Apple APIs.** SwiftUI `List`, `.searchable(text:prompt:)`, `.swipeActions`, `.confirmationDialog` (not in RESEARCH, all iOS 15), `AsyncImage` is not used for files (load the thumbnail with `UIImage(contentsOfFile:)` off main).

**Must NOT do.** No duplicate, archive, backup (build 6 ProjectOps); never open Results for a `.capturing` project; never start a scan itself (callback only); never block main on disk.

**Copy strings.** Existing as listed. New (`enum HomeUI`): `comingLater = "Coming in a later version"`.

**Self-test.** `HomeUISelfTest.run()`, at least 10 checks: subtitles for room, house (room count), object, quick measure; processing badge when running; needs-work badge when a room is `.needsRescan`; search is case-insensitive and hides archived unless asked; `.capturing` projects are filtered out; a renamed project sorts and searches by its new name.

**Acceptance checks.** Rows are accessible elements with `Copy.A11y.projectRow`; New Scan is reachable with one hand at the bottom.

**SPEC owned.** "SCANNING MODES" ("The home screen should contain a large button: NEW SCAN", mode options); "PROJECT SYSTEM" (project list, rename, delete, "No required account").

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
/// Drives the export sheet. `UUID` itself is not `Identifiable`, so `.sheet(item:)` needs this
/// wrapper (never add a retroactive `extension UUID: Identifiable`).
struct ExportRequest: Identifiable, Equatable { let id: UUID; var projectID: UUID; var viewState: ExportViewState }
@MainActor final class AppRouter: ObservableObject {
    @Published var path: [AppRoute]
    @Published var scanRequest: ScanRequest?          // drives .fullScreenCover
    @Published var exportRequest: ExportRequest?      // drives .sheet(item: $router.exportRequest) { ExportSheet(projectID: $0.projectID, viewState: $0.viewState) }
    func startScan(_ mode: ScanMode)
    func openResult(_ id: UUID)
}
struct AppRootView: View { init() }                  // NavigationStack(path:) over HomeScreen
struct AppScanCoordinator: View { init(request: ScanRequest, onFinished: @escaping (UUID?) -> Void) }
struct AppResultsCoordinator: View { init(projectID: UUID) }
enum ProcessingPlans {
    /// Room projects, in this order, with `dependsOn` so a failure stops only its dependents:
    /// per room BuildRoomStep (optional; only when raw lacks capturedroom.json, has
    /// capturedroomdata.json and roomlog.json's `degraded` is not `.roomPlanFailed`; a RoomBuilder
    /// error completes without output), per room ConsolidateMeshStep (optional: a failure leaves Raw
    /// Scan unavailable and heights from RoomPlan), CleanModelStep (required; depends on the rooms'
    /// buildRoom steps; built as `CleanModelStep(meshProvider: { package, room in try? MeshModelStore.loadMeasured(package, room: room) })`,
    /// where `try?` flattens the optional in Swift 5), FloorPlanStep (required; depends on
    /// cleanModel; Results shows the tabs once plan.json exists, D20), per room QualityStep
    /// (optional; independent), ThumbnailStep (optional; depends on floorPlan), per room
    /// TextureLowStep (optional; independent; left out when it slipped, section 2.1). A
    /// `roomPlanFailed` room therefore still gets consolidateMesh, quality and textureLow.
    static func roomSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// Enqueues a project (atFront when the user just finished it). On `.completed` sets rooms
    /// .processed and project .ready; on `.failed` sets .needsAttention; on `.cancelled` leaves
    /// `.processing` (never `.ready`), so the next launch or Retry resumes it.
    @MainActor static func enqueue(projectID: UUID, atFront: Bool)
    /// After Home appears (never while the scan cover is up): projects in .needsProcessing or
    /// .processing, never Demo Mode projects (.ready).
    @MainActor static func resumePending()
    /// Results' Retry: sets .needsProcessing and enqueues.
    @MainActor static func retry(projectID: UUID)
}
struct SettingsScreen: View { init() }
struct DiagnosticsScreen: View { init() }            // probe rows, self-test suites, Demo Mode, snapshot recording, UV checker, log share
enum RecoveryService {
    /// Unsealed InProgress folders to offer to the user. Before returning, sealed ones (a crash hit
    /// between seal and move) are finished silently: moved, RoomRecord added or updated, enqueued.
    /// It also reconciles every project still in `.capturing` (a kill during the quality sheet, an
    /// engine start that threw, a crash between the seal move and the manifest update): it adds a
    /// RoomRecord for each sealed `raw/sessions/*/rooms/*` folder missing from `manifest.rooms`
    /// (from scan.json and RawScanReader), sets `.needsProcessing` when the project has rooms, and
    /// deletes it when it has no rooms and no InProgress scan.json names its projectID.
    /// Main actor (called once at launch; the moves are renames on one volume).
    @MainActor static func pending() -> [InProgressScanInfo]
    /// Seals into the project's room folder (JSON Lines tolerate a torn last line; no roomlog.json
    /// is written), adds the RoomRecord (.captured), enqueues processing. A missing project (it was
    /// deleted) makes recover create a new Room project for the scan.
    @MainActor static func recover(_ info: InProgressScanInfo) throws
    /// Removes the InProgress folder, then deletes its project when that leaves it with no rooms.
    static func discard(_ info: InProgressScanInfo) throws
    /// Pure decision behind `pending()` for one `.capturing` project (tested).
    static func reconcile(roomsInManifest: Int, sealedRoomFolders: Int, hasInProgressScan: Bool) -> CapturingFix
}
enum CapturingFix: Equatable, Sendable { case addRoomsAndProcess, process, keepForRecovery, delete }
```
Composition: when `scanRequest` becomes non-nil AppShell calls `ProcessingRunner.shared.suspendAll(reason: "capture")` before preflight, and `resumeAll()` when the cover dismisses (no processing next to RoomPlan and ARKit, ARCHITECTURE 12.1). The scan cover shows `RoomScanScreen(model:)` and attaches `.sheet` with `QualitySheet(evaluation:onFinish:onDiscard:)` (onDiscard asks for the Discard confirmation, then `model.discardScan()`) when `model.phase` is checking or quality, with `.presentationDetents([.medium, .large])` and `.interactiveDismissDisabled()`; `model.onComplete` calls `ProcessingPlans.enqueue(projectID:atFront: true)` and routes to the result. The result route shows `ResultScreen(projectID:onExport:onRetry:)`; `onExport` sets `exportRequest` with the view state, which presents `ExportSheet(projectID:viewState:)`; `onRetry` calls `ProcessingPlans.retry`. Settings: units (`UnitPreferences`), inch fractions, show both, vibrate for warnings (`SettingsKey.guidanceHaptics`), keep scan photos (`SettingsKey.keepScanPhotos`), show tips again (clears `tipsSeen`), storage used (`StorageUsage.projectsTotal`), wireless debug log (`DebugServer`: the setting is session-only, so AppShell's `MapperApp` sets `SettingsKey.wirelessDebug` to false at launch and no longer auto-starts the server; turning the toggle on removes `SettingsKey.debugToken` first so a new token is generated, and the listener stops when `scenePhase` becomes `.background`), Diagnostics link, version. Diagnostics: the five capability rows from the old ContentView (`supportsSceneReconstruction(.meshWithClassification)`, `supportsFrameSemantics(.sceneDepth)`, `RoomCaptureSession.isSupported`, `ObjectCaptureSession.isSupported`, `PhotogrammetrySession.isSupported`), `os_proc_available_memory`, `ProcessInfo.physicalMemory`, the suite list (lead-owned lines, one per module self-test) run off main with results logged exactly as ContentView does today, Demo Mode toggle (`SettingsKey.demoMode`), record snapshots toggle, capture delegate relay toggle (`SettingsKey.captureRelay`, 3.11), UV checker (`ViewerDiagnostics.uvCheckerContent()` in a `ViewerContainer`), Share Log. On launch: `ProjectLibrary.shared.reload()`, `RecoveryService.pending()` (recovery sheet when not empty), `ExportRunner.removeStaleStaging()` off main, then `ProcessingPlans.resumePending()` once Home has appeared. Unsupported device (no LiDAR): Home stays usable for existing projects and New Scan shows `Copy.Errors.noLidar`, except in Demo Mode (`SettingsKey.demoMode` on), where New Scan proceeds with `FakeScanEngine`.

**Uses.** Every build 4 module's screen types and `ProcessingPlans` step types: `BuildRoomStep`, `CleanModelStep`, `ConsolidateMeshStep`, `FloorPlanStep`, `ThumbnailStep`, `QualityStep`, `TextureLowStep`, `ScheduledStep`, `ScheduledStepKey`, `ProcessingJob`, `ProcessingRunner` (`suspendAll`, `resumeAll`), `ProcessingOutcome`; FloorPlan `ExportViewState`; ExportUI `ExportRunner.removeStaleStaging`; Store `ProjectLibrary`, `InProgressScans`, `RawScanReader`, `StorageUsage`; RoomModel `CapturedRoomStore.rawFolder`; Viewer3D `ViewerDiagnostics`, `ViewerContainer`, `ViewerModel`; Support `Copy.Settings.*`, `Copy.Home.settings`, `LogStore`, `DebugServer`, `DeviceState`.

**Apple APIs.** `NavigationStack(path:root:)` (RESEARCH 3.10), `.navigationDestination(for:destination:)`, `.fullScreenCover(item:)`, `.sheet(item:)` (not in RESEARCH, iOS 14 to 16), `.presentationDetents`, `ShareLink(item:preview:)` for log files; the probe APIs above (RESEARCH 3.9 "Runtime capability gates").

**Must NOT do.** No business logic that belongs to a feature module; never run processing during a scan (suspend before preflight); never write `isIdleTimerDisabled` (Pipeline's `IdleTimerGuard`); never remove the probe rows or the self-test logging format (the maintainer reads them with `tools/phone_log.py`); never add suite lines (the lead does).

**Copy strings.** Existing: `Copy.Settings.*`, `Copy.Home.title`, `Copy.Errors.*`. New (`enum AppShell`): `recoverTitle = "Recover unfinished scan?"`, `recoverBody = "Mapper closed before a scan was finished. You can keep what was scanned."`, `recoverKeep = "Keep Scan"`, `recoverDiscard = "Discard"`, `diagnosticsTitle = "Diagnostics"`, `demoMode = "Demo Mode"`, `demoModeFooter = "Try every screen with a sample room. The camera is not used."`, `recordSnapshots = "Record Scan Snapshots"`, `uvCheck = "Texture Orientation Check"`, `selfTests = "Self-Tests"`, `runSelfTests = "Run Again"`, `showBoth = "Show both units"`, `captureRelay = "Capture Delegate Relay"`, `captureRelayFooter = "Turn off only if the camera view goes black during a room scan."`.

**Self-test.** `AppShellSelfTest.run()`, at least 14 checks: `roomSteps` for a manifest with one captured room lists the steps in order with subjects, the optional flags on buildRoom, consolidateMesh, quality, thumbnail and textureLow, and the `dependsOn` sets above; BuildRoomStep omitted when raw capturedroom.json exists, when capturedroomdata.json is missing and when roomlog.json says `.roomPlanFailed` (temp package), and such a room still yields consolidateMesh, quality and textureLow; a `.ready` project is not enqueued; two rooms produce per-room steps; an object-only manifest produces no room steps; `RecoveryService.reconcile` for a `.capturing` project with a sealed room missing from the manifest (addRoomsAndProcess), with its room already listed (process), with no rooms but an InProgress scan (keepForRecovery) and with nothing (delete).

**Acceptance checks.** App launches to Home; the capability probe and self-test log lines are unchanged in format; the scan cover dismisses on cancel and on finish; the quality sheet appears over the live camera; Results opens right after Finish with the processing view, then shows the tabs once the floor plan is ready, with chips for later steps; Export works from Results and respects Hide Furniture and the plan toggles; Demo Mode runs the whole flow without camera permission and on a device without LiDAR; no job runs while the scan cover is up; after a force quit during processing the project reprocesses at the next launch (PERF-27) and a force quit during capture offers recovery (PERF-26).

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
**Apple APIs.** `@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]` (ARView, view points); `ARPlaneAnchor` `planeExtent`; `ARPlaneGeometry.boundaryVertices` via `geometry` (not in RESEARCH, iOS 11.3).
**Self-test.** At least 8 checks on snapping order and the saved record.
**SPEC owned.** "SCANNING MODES" QUICK MEASURE; "MEASUREMENT SYSTEM" (point-to-point in the live camera).

### 3.37 PlanEditor (wave 5a)

**Purpose.** Floor plan editing through the EditLog (D3): selection on `PlanCanvasView` hits, move wall (two `moveWallEndpoint`), adjust wall length by typing (`LengthParser`), wall thickness, add and delete wall, add, move and resize doors and windows (CR-1, approved; the lead applies it to Core before wave 5a), add opening, flip door swing (a `.user` swing is drawn solid), rename room, merge and split rooms (CR-1), move, delete and recategorize fixtures and furniture (`moveObject`, `deleteElement`, `recategorizeObject`, SPEC "Editable detected objects"), add and delete measurement and dimension, text annotation, symbol, note, undo and redo (`EditStore.undo`/`redo`), Reset to Scan (appends nothing; clears the log after confirmation), snapping of endpoints to endpoints (50 mm), 0, 45, 90 degrees and a 100 mm or 1 in grid.
**Files.** `ios/Sources/PlanEditor/PlanEditorModel.swift`, `PlanEditorOps.swift`, `PlanEditorToolbar.swift`, `PlanEditorSnapping.swift`, `PlanEditorSelfTest.swift`, `Copy+PlanEditor.swift`.
**API.** `@MainActor final class PlanEditorModel: ObservableObject { init(projectID: UUID); @Published private(set) var plan: PlanModel; @Published var selection: ElementID?; func perform(_ action: PlanEditAction) throws; func undo() throws; func redo() throws; var canUndo: Bool; var canRedo: Bool }`, `enum PlanEditAction` (one case per SPEC edit, including `moveFixture(ElementID, center: Vec2, yaw: Float)`, `deleteFixture(ElementID)` and `recategorizeFixture(ElementID, ObjectCategory)`, mapped to `moveObject` (world transform from the plan center and yaw at the object's height), `deleteElement` and `recategorizeObject`), pure `enum PlanEditorOps { static func operations(for action: PlanEditAction, in level: PlanLevel) -> [EditOperation] }`.
**Must NOT do.** Never write plan.json (the base stays derived); never touch raw.
**Self-test.** At least 18 checks: every action maps to the expected operations and applies cleanly to a fixture plan through `PlanModel.apply` and `CleanModel.apply`, including the three fixture actions.
**SPEC owned.** "FLOOR PLAN EDITING" (all listed operations; "Manual edits must not overwrite raw scan data"); "2D FLOOR PLAN" ("Allow manual editing"); deliverable 13 "Editable detected objects" (move, delete, change category on the plan).

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

**Purpose.** Show Missing Areas (D19, kept by lead decision 4): from the quality sheet, continue on the same running `ARSession` (the room's `RoomScanEngine` has not been torn down; the sheet stays over the live camera) in a `MeshScanEngine(target:recorders:hub:)` patch pass with the room engine's hub (new mesh-pass folder, new recorders), tour the missing areas sorted by walking distance with an arrow HUD toward the suggested viewpoint, mark an area filled when coverage reaches it, Next Area, and return to the quality sheet with re-evaluated numbers; windows and mirrors excluded. The button is offered only when `RoomScanResult.stoppedBySystem` is false (a heat, storage or memory stop already paused the session). Finish or Discard after the tour tears down both engines.
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
- Results (5c): Measure button (MeasureTool), Edit on the Floor Plan tab (PlanEditor), measurements list, orphaned edits listed (D3), Change Category on the object card (`Copy.ObjectMenu.changeCategory`, names from `Copy.FloorPlan.categoryName`, a `recategorizeObject` edit through `EditStore`).
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
**Setup.** `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)` returns false unless the identifier is in the Info.plist `BGTaskSchedulerPermittedIdentifiers` array, and registering one identifier twice kills the app. So: the lead adds `BGTaskSchedulerPermittedIdentifiers` to `ios/project.yml` before wave 6a with the constant `BackgroundProcessing.taskIdentifier`; AppShell (6c) makes exactly one guarded `register` call at launch inside `if #available(iOS 26.0, *)`; the self-test checks that the constant equals the plist value read from `Bundle.main`. Whether iOS 26 requires the bundle identifier as a prefix (Sideloadly rewrites the bundle id) is checked on the phone: a false return is logged and the feature stays off.
**Files.** `ios/Sources/BackgroundWork/BackgroundProcessing.swift`, `HighResolutionStills.swift`, `BackgroundWorkSelfTest.swift`.
**Must NOT do.** Never register the same BGTask identifier twice; never reference iOS 26 symbols outside `#available`.
**SPEC owned.** "LOCAL-FIRST ARCHITECTURE" (on-device processing continues while the app is backgrounded on iOS 26).

### 3.49 Build 6 revisions

- Texturing (6a, lead decision 6: accepted): an atlas streaming callback on `TextureBaker` so each finished atlas page is handed to the caller and released instead of held until the end (lower peak than the about 830 MB at 1M faces).
- TextureJob (6a, after the Texturing revision): `TextureHighStep` (id `.textureHigh`, budget 1 GB, reduced 500 MB) at `TextureDensity.photoRealistic` with `normalizeExposure = true` (Texturing `TXExposure`), density by `DetailLevel`, reduced variant at 2048 atlases, baking `mesh.mchk` up to 1M faces into `derived/rooms/<r>/texture-high/` (same file names as `texture/`), writing each page from the atlas callback.
- ExportUI (6a): object formats (USDZ as is, OBJ, STL, PLY, GLB from ObjectModel), measurements CSV and a PDF room schedule page, textured OBJ, GLB and USDZ at Photo Realistic, PNG images of the model (`ViewerModel.snapshotJPEG`).
- HomeUI, Results, ScanUI (6b) and AppShell (6c): project menu (rename, duplicate, archive, back up, restore from backup, Free up space), Photo Realistic style, crop, reference length entry, Advanced flow, background processing toggle.

---

## Build 7 (0.7) and build 8 (0.8)

Planned modules, specified in full when their build starts:
- EditMenus (7a): tap an object in 3D Clean: Hide, Delete from Clean Model, Move, Rotate, Measure, Rename, Change Category, Show Raw Geometry; tap a wall: Measure, Adjust, Add Opening, Add Door, Add Window, Hide, Inspect Scan; all through `EditOperation` (`relabelObject`, `recategorizeObject`, `setHidden`, `deleteElement`, `moveObject`, `addOpening`) and `Copy.ObjectMenu`, `Copy.WallMenu`.
- PhotoBrowser (7a): photos and keyframes associated with scan locations; tap a photo to fly the camera to its pose.
- SurfaceEvidence (7a): 5 cm evidence map by BVH ray tests toward keyframe positions (measured, occluded, unscanned, inferred) that drives Hide Furniture honesty and measurement grading.
- SpaceScan (7a): commercial spaces, restaurants, offices and warehouses larger than RoomPlan's limits as several mesh passes in one session with relocalization, merged in MeshModel.
- HeadlessRoom (7a, scheduled by lead decision 5): the D15 experiment behind a Diagnostics flag: `RoomCaptureSession(arSession:)` (iOS 17.0) driven directly with Mapper's own `ARView` in `.ar` mode, the live green, yellow, red and gray `CoverageOverlay` in Room mode and our own coaching banner (RoomPlan `Instruction` mapped through GuidanceUI), re-applying the configuration in `didStartWith` for every room (RESEARCH 3.2 recommended 4). It ships only if device logs from builds 4 to 6 show depth and mesh survive on that path; otherwise Room mode stays on `RoomCaptureView`.
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
| 6 Object dimensions | Results object card with MeasureCore `objectRows` (room objects, with confidence); ObjectModel (scanned objects) | 4; 5 |
| 7 Room dimensions; 9 floor area; 10 ceiling height | RoomModel, MeasureCore, Results | 4 |
| 8 Surface area | room and per-wall area in MeasureCore (b4, openings not counted, stated in the panel); MeasureTool area, ObjectModel surface area | 4; 5 |
| 11 Distance measurements | MeasureTool, LiveMeasure | 5 |
| 12 Images and photos associated with scanned locations | Keyframes (capture, poses), ScanUI Take Photo; PhotoBrowser (browse) | 4; 7 |
| 13 Editable detected objects | Hide Furniture (b4); fixture move, delete and recategorize in PlanEditor and Change Category on the Results card (b5); EditMenus rename, rotate, show raw (b7) | 4; 5; 7 |
| 14 Exportable professional files | ExportUI | 4; remaining formats 6 |

### 4.2 CORE DESIGN PRINCIPLE

| Requirement | Owner | Build |
|---|---|---|
| Multiple representations of the same scan | Store package layout (raw, derived, edits) | 4 |
| A: LiDAR mesh; ARKit anchors; world transforms | MeshRecord (anchor-local chunks with transforms, D8) | 4 |
| A: camera poses; timestamps; device orientation | Keyframes (10 Hz pose track, keyframe poses) | 4 |
| A: camera frames where permitted; depth; confidence; calibration | Keyframes (JPEG, Float16 depth plus confidence, intrinsics per keyframe) | 4 |
| A: feature points; detected planes | Feature points: the ARWorldMap at Done (mesh anchors stripped) in every room folder (RoomCapture, 4) and per session for relocalization (HouseUI, 5); not recorded per frame (unstable, RESEARCH 3.8 gotcha 21). Planes: RoomPlan's surfaces in `capturedroomdata.json` (4); ARKit plane anchors are not recorded because plane detection flattens the raw mesh (D14) | 4; 5 |
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
| "Move slower", "Move closer", "Too close", "Too far", "Tracking quality is low", "Lighting is poor" | Room mode: RoomPlan's own coaching (`slowDown`, `moveCloseToWall`, `moveAwayFromWall`, `turnOnLight`) plus Mapper's `trackingLow`, `trackingLost` and `deviceHot` through `GuidanceFilter` (4); Mapper's texts from `GuidanceEngine` in mesh-only scans (LiveMeshView, 5) | 4; 5 |
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
| Allow the user to correct object labels | Change Category on the Results card and in PlanEditor (recategorize, 5); EditMenus relabel and the full object menu (7) | 5; 7 |
| Never bake recognition guesses into the raw scan | RoomModel (derived only), EditLog overlays | 4 |

### 4.11 FURNITURE REMOVAL

| Requirement | Owner | Build |
|---|---|---|
| HIDE FURNITURE hides movable objects in the clean model | Results (layer), FloorPlan (furniture toggle), ExportUI (exports follow the result screen) | 4 |
| Mark blocked regions as INFERRED, OCCLUDED or UNSCANNED; do not fabricate | RoomModel occlusion heuristic and occluded parts, Results (gray hatched regions in 3D Clean while Hide Furniture is on, missing areas as unscanned, legend), FloorPlan (dashed) (4); SurfaceEvidence evidence map (7) | 4; 7 |
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
| Wall thickness where determinable | FloorPlan (estimated, outer face dashed on A-WALL-EST, 4); Structure measured wall pairs | 4; 5 |
| Door swing direction when known | RoomModel default drawn dashed as estimated on A-DOOR-EST (4); confirmed by PlanEditor Flip Door Swing, then solid (5) | 4; 5 |
| Counters | MeshRefine | 8 |
| Toggles: Furniture, Measurements, Room names, Doors/windows, Fixtures, Grid, Scale | FloorPlan `PlanToggles` (grid lines on A-GRID, scale bar on A-ANNO-SCAL), Results; exports use the same toggles (`ExportViewState`) | 4 |
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
| Tap objects | Results (read-only card with category guess and size with confidence; walls, doors and windows selectable to filter measurements) | 4 |
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
| Rename | HomeUI and Results (Store `rename`) | 4 |
| Duplicate, archive, backup, restore | ProjectOps | 6 |

### 4.18 LOCAL-FIRST ARCHITECTURE

| Requirement | Owner | Build |
|---|---|---|
| Works offline after installation | all modules (no network code; only the opt-in token-protected DebugServer) | 4 |
| Prefer on-device processing | Pipeline, MeshModel, TextureJob, ObjectCapture (on-device photogrammetry) | 4; 5 |
| No AWS, Azure, Firebase, Supabase, subscription APIs or paid AI services | enforced by rule 0.2 (native frameworks only, no packages) | 4 |
