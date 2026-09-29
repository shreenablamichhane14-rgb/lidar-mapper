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

13. CI lessons (confirmed by real builds): `ObjectCaptureSession` and its nested types (`Feedback`, `CaptureState`) live in the RealityKit plus SwiftUI cross-import overlay, so a file that uses them must `import SwiftUI` as well as `import RealityKit`; `import RealityKit` alone fails with "cannot find type 'ObjectCaptureSession' in scope". A `static func` on a `@MainActor` class is main-actor isolated too; mark pure helpers `nonisolated` when the self-test (run off main) calls them. Local names `unsafe`, `consume`, `borrowing` and `sending` are contextual keywords in the Swift 6.2 compiler; avoid them.

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
| Core changes CR-1, CR-7, CR-8 (3.37a, 3.30a, 3.31c) | Core, Geometry (`Polygon2D.clipped`), Store (`EditStore.reset`); stub cases in RoomModel and FloorPlan | 5 | pre-5a (lead) | no new dependency | to build |
| RoomModel revision (3.37b) | RoomModel | 5 | 5a0 | as build 4 (with CR-1) | to build |
| FloorPlan revision (3.37c) | FloorPlan | 5 | 5a0 | as build 4 (with CR-1) | to build |
| CaptureCore revision (3.30b) | CaptureCore | 5 | 5a0 | as build 4; ARKit | to build |
| RoomCapture revision (3.30c) | RoomCapture | 5 | 5a0 | as build 4 | to build |
| Viewer3D revision (3.34a) | Viewer3D | 5 | 5a0 | as build 4; RealityKit `Entity(contentsOf:)` | to build |
| Coverage revision CR-9 (3.31a) | Coverage | 5 | 5a0 | as build 4 (Support) | to build |
| Quality revision CR-10 (3.31b) | Quality | 5 | 5a0 | as build 4 | to build |
| Structure | Structure | 5 | 5a | Core, Geometry, RoomModel, MeshProcessing, Store, Support; RoomPlan | to build |
| CoverageLive | CoverageLive | 5 | 5a | Core, Coverage, CaptureCore, MeshRecord, RoomModel, Geometry, Support; ARKit | to build |
| LiveMeshView | LiveMeshView | 5 | 5a | Core, CaptureCore, Store, MeshRecord, Keyframes, GuidanceUI, Coverage, Pipeline, ScanUI (`Copy.ScanUI.elapsed` only), Support; ARKit, RealityKit, SwiftUI, UIKit | to build |
| ObjectCapture | ObjectCapture | 5 | 5a | Core, Store, GuidanceUI, Pipeline, Support; RealityKit, SwiftUI, Combine | to build |
| ObjectModel | ObjectModel | 5 | 5a | Core, Geometry, MeshProcessing, MeshModel, Export, Store, Support; ModelIO, RealityKit (fallback loader) | to build |
| MeasureTool | MeasureTool | 5 | 5a | Core, Geometry, Coverage, MeasureCore, Viewer3D, RoomModel, Quality, Store, Units, Support; SwiftUI, Combine | to build |
| LiveMeasure | LiveMeasure | 5 | 5a | Core, CaptureCore, MeasureCore, Store, GuidanceUI, Coverage, Geometry, Pipeline, ScanUI (`ScanFlowModel.defaultProjectName` only), Units, Support; ARKit, RealityKit, SwiftUI, UIKit | to build |
| PlanEditor | PlanEditor | 5 | 5a | Core, Geometry, FloorPlan, RoomModel, Store, Units, Support; SwiftUI, CoreGraphics, Combine | to build |
| CoverageOverlay | CoverageOverlay | 5 | 5b | Core, CoverageLive, CaptureCore, Coverage, Support; RealityKit, SwiftUI | to build |
| LargeObject | LargeObject | 5 | 5b | Core, CoverageLive, LiveMeshView, CaptureCore, MeshRecord, Store, Coverage (CR-9), Geometry, ScanUI, Units, Support; ARKit, RealityKit, SwiftUI | to build |
| MissingAreas | MissingAreas | 5 | 5b | Core, CoverageLive, LiveMeshView, Quality (CR-10), MeshModel, RoomModel, CaptureCore, Store, ScanUI, Units, Support; RealityKit, SwiftUI | to build |
| HouseUI | HouseUI | 5 | 5b | Core, Store, Structure, RoomCapture, CaptureCore, MeshRecord, Keyframes, Quality, QualityUI, ScanUI, GuidanceUI, RoomModel, FloorPlan, Pipeline, Support; SwiftUI, AVFoundation, ARKit, RealityKit | to build |
| ObjectUI | ObjectUI | 5 | 5b | Core, Store, ObjectCapture, ObjectModel, Viewer3D, MeasureCore, ScanUI, Pipeline, TextureJob, Export, Geometry, MeshProcessing, Units, Support; SwiftUI, AVFoundation | to build |
| ScanUI revision (3.43a) | ScanUI | 5 | 5c | as build 4 plus CoverageLive, LiveMeshView, Quality (CR-10), CoverageOverlay, MissingAreas; RealityKit | to build |
| Results revision (3.43b) | Results | 5 | 5c | as build 4 plus MeasureTool, PlanEditor, Structure, LiveMeasure, HouseUI | to build |
| HomeUI revision (3.43c) | HomeUI | 5 | 5c | as build 4 (Core CR-7) | to build |
| ExportUI revision (3.43d) | ExportUI | 5 | 5c | as build 4 plus Structure, ObjectCapture, ObjectModel, LiveMeasure; PDFKit | to build |
| AppShell revision (3.43e) | AppShell | 5 | 5d | every build 4 and build 5 module | to build |
| ProjectOps | ProjectOps | 6 | 6a | Core, Store, Export (CRC32), Support; SwiftUI, UniformTypeIdentifiers | to build |
| ObjectCrop | ObjectCrop | 6 | 6a | Core, ObjectModel, ObjectCapture, MeshProcessing, Viewer3D, Store, Support; RealityKit | to build |
| AdvancedScan | AdvancedScan | 6 | 6a | Core, Support; SwiftUI | to build |
| ReferenceLength | ReferenceLength | 6 | 6a | Core, Store, MeasureCore, RoomModel, Units, Support; SwiftUI | to build |
| TextureJob (build 6) | TextureJob | 6 | 6a | as in build 4 | to build |
| ExportUI (build 6) | ExportUI | 6 | 6a | as in build 4 plus ObjectModel | to build |
| BackgroundWork | BackgroundWork | 6 | 6a | Core, Pipeline, Support; BackgroundTasks | to build |
| Texturing revision | Texturing | 6 | 6a | none; CoreGraphics (atlas streaming callback, accepted by the lead) | to build |
| HouseUI revision (D16 detail pass hook, 3.49) | HouseUI | 6 | 6a | as build 5 | to build |
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
before wave 5a (the lead, one commit, compiled green)
  Core CR-1 (3.37a)  EditOperation moveOpening, resizeOpening, mergeRooms, splitRoom, batch; EditLog flattenedActive,
                     reset(keeping:); mergedOutlines on CleanFloor and PlanRoom; wall orientation and WallArc docs;
                     Geometry Polygon2D.clipped(leftOf:_:); Store EditStore.reset(_:keeping:); stub cases in
                     RoomModel and FloorPlan
  Core CR-7 (3.30a)  RoomRecord.supersededBy
  Core CR-8 (3.31c)  MinimapSnapshot.camera, heading

wave 5a0 (revisions of build 4 modules; each edits only its own folder; imports build 4 and the pre-5a Core)   est. lines
  RoomModel rev.   (3.37b) <- as build 4   orientation invariant, CR-1 operations, merged outlines          350
  FloorPlan rev.   (3.37c) <- as build 4   no reversed walls, CR-1 operations, merged rooms                 300
  CaptureCore rev. (3.30b) <- as build 4   run(options:initialWorldMap:)                                      40
  RoomCapture rev. (3.30c) <- as build 4   makeCaptureView keeps a running session                            15
  Viewer3D rev.    (3.34a) <- as build 4   loadModel(_:layer:transform:pickMesh:pickTag:)                   180
  Coverage rev.    (3.31a) <- (none)       GuidanceInput.extraConditions (CR-9)                               20
  Quality rev.     (3.31b) <- as build 4   mesh-pass folders in the Done evaluation and QualityStep (CR-10)  120

wave 5a (imports build 4, pre-5a and 5a0)
  Structure     (3.30) <- RoomModel Store MeshProcessing (+ Core Geometry Support)   [RoomPlan StructureBuilder]  1450
  CoverageLive  (3.31) <- CaptureCore MeshRecord RoomModel Coverage (+ Core Geometry Support)                     1200
  LiveMeshView  (3.32) <- CaptureCore Store MeshRecord Keyframes GuidanceUI Coverage Pipeline ScanUI(copy)
                          (+ Core Support)   [RealityKit ARView .ar]                                              1450
  ObjectCapture (3.33) <- Store GuidanceUI Pipeline (+ Core Support)   [RealityKit + SwiftUI Object Capture]      1450
  ObjectModel   (3.34) <- MeshProcessing MeshModel Export Store (+ Core Geometry Support)   [ModelIO, RealityKit]  900
  MeasureTool   (3.35) <- Viewer3D MeasureCore RoomModel Quality Store Coverage (+ Core Geometry Units Support)   1350
  LiveMeasure   (3.36) <- CaptureCore MeasureCore Store GuidanceUI Coverage Geometry Pipeline ScanUI(name)
                          (+ Core Units Support)   [ARView .ar, planes]                                           1300
  PlanEditor    (3.37) <- FloorPlan RoomModel Store (+ Core Geometry Units Support)                               1500

wave 5b (imports build 4, pre-5a, 5a0 and 5a)
  CoverageOverlay (3.38) <- CoverageLive CaptureCore Coverage (+ Core Support)   [RealityKit LowLevelMesh]         900
  LargeObject     (3.39) <- CoverageLive LiveMeshView CaptureCore MeshRecord Store Coverage(CR-9) Geometry ScanUI
                            Units (+ Core Support)                                                                1400
  MissingAreas    (3.40) <- CoverageLive LiveMeshView Quality(CR-10) MeshModel RoomModel CaptureCore Store ScanUI
                            Units (+ Core Support)                                                                1000
  HouseUI         (3.41) <- Structure RoomCapture(3.30c) CaptureCore(3.30b) MeshRecord Keyframes Quality QualityUI
                            ScanUI GuidanceUI RoomModel FloorPlan Pipeline Store (+ Core Support)                 1450
  ObjectUI        (3.42) <- ObjectCapture ObjectModel Viewer3D(3.34a) MeasureCore ScanUI Pipeline TextureJob Export
                            Geometry MeshProcessing Units Store (+ Core Support)                                  1400

wave 5c (revisions of build 4 screens, one agent each; imports everything above; no 5c revision imports another)
  ScanUI rev.   (3.43a) <- CoverageLive LiveMeshView Quality(CR-10) CoverageOverlay MissingAreas   [RealityKit]   400
  Results rev.  (3.43b) <- MeasureTool PlanEditor Structure LiveMeasure HouseUI                                   650
  HomeUI rev.   (3.43c) <- (Core CR-7)                                                                             60
  ExportUI rev. (3.43d) <- Structure ObjectCapture ObjectModel LiveMeasure   [PDFKit]                              450

wave 5d
  AppShell rev. (3.43e) <- everything; edits ContentView.swift and MapperApp.swift                                700
```

Why wave 5a0: PlanEditor's and MeasureTool's self-tests apply the CR-1 operations through `PlanModel.apply` and `CleanModel.applyingEdits`, Structure builds rooms with `CleanModelBuilder`, and MeasureTool picks on the revised viewer; revising a build 4 module inside wave 5a would let 5a modules compile against one behavior and merge into another. So every revision of a build 4 module that a later build 5 module needs is its own small agent in wave 5a0, on its own branch, touching only its own folder and using only build 4 and pre-5a symbols (the FloorPlan revision relies on the RoomModel revision's orientation invariant as data in clean.json, never as an import, so the two run in parallel). All seven merge, with `integration` green after each, before any 5a module starts.

Why no module depends on its own wave. In 5a: ObjectModel receives ObjectCapture's model file and bounds through `ObjectMetricsStep`'s two closures, which AppShell wires, and ObjectCapture never reads dims.json; LiveMeshView never references CoverageLive (coverage plugs in as an extra `ScanRecorder` plus the two augmenter closures); LiveMeasure has its own container and never uses LiveMeshView; MeasureTool and PlanEditor never import each other (Results composes them in 5c); HouseUI (5b) is the only user of Structure's snapping math. In 5b: CoverageOverlay attaches to any `ARView`, so LargeObject and MissingAreas never import it (the overlay is attached through their `onViewReady` closures by ScanUI 5c and AppShell 5d: `CoverageOverlayRenderer(source: model.coverage, thermal: hub.thermal)`, `attach(to:)` in the closure, `detach()` when the screen goes away); HouseUI reaches MissingAreas and CoverageLive only through `onShowMissingAreas` and `captureExtras`, set by AppShell; ObjectUI hands a Large choice to AppShell (`onLargeObject`) and never imports LargeObject. In 5c: see 3.43. Every dependency of a 5a module on a 4c module (LiveMeshView, LiveMeasure on ScanUI) is on merged code.

Wave gates as in build 4 (2.1): each module branches `impl/<module>` from the `integration` head on which the previous wave is merged and green, compiles on its branch until green with its self-test, and merges one at a time; the lead adds each `SelfTestSuite` line. After wave 5d the lead bumps `MARKETING_VERSION` to 0.5 and `CURRENT_PROJECT_VERSION` in `ios/project.yml`.

After build 5: House mode room by room with progress, relocalization for later visits, merge and alignment (D9), manual alignment, floors, Rescan that supersedes a room; Object mode small and medium (Object Capture, on-device photogrammetry) and large (LiDAR mesh driver with a tapped seed, gravity-aligned box and side guidance "Capture the left side"), with dimensions, surface area and volume only when watertight; Quick Measure with plane-corner snapping and confidence; measuring inside the model with snapping and confidence; floor plan editing through the EditLog with undo, redo and Reset to Scan; live green, yellow, red and gray coverage (colored mesh in mesh-only views and the tour, minimap and legend in Room mode); Show Missing Areas on the still-running session with re-evaluated quality (Room and House rooms); the D16 detail pass when RoomPlan strips the mesh in Room mode (House rooms in build 6, 3.49); House, Object and Quick Measure exports.

Build 5 acceptance on the phone (`docs/TEST_PLAN.md`):
- As written: HOUSE-01 to HOUSE-09, OBJ-01 to OBJ-06, OBJ-09, MEAS-01 to MEAS-11, CONF-01 to CONF-04, PEDIT-01 to PEDIT-09, PLAN-05, QUAL-01 (with Show Missing Areas), QUAL-02, QUAL-03, REC-02, LIVE-01 to LIVE-10, MODE-02, MODE-03, MODE-06, EXP-05 (with annotations), EXP-09, OFF-01 (full workflow), PERF-03, PERF-10, PERF-13, PERF-25, PERF-28, and the smoke list #3, #4, #6, #7, #8, #9 as written.
- Build 5 variants: OBJ-07 without step 4 (crop is build 6); EXP-08 with the JSON export only (CSV and the report page come in build 6); EDIT3D-01 shows Change Category on the card (the full object menu is build 7).
- N/A in build 5: OBJ-08 (ObjectCrop, build 6), MODE-07 (Advanced Scan, build 6).
The build 4 variants of QUAL-01, QUAL-02, OFF-01 and EXP-05 and the build 4 N/A of EXP-09, PERF-03, PERF-10, PERF-25 and PERF-28 are removed from TEST_PLAN 0.3 (the lead updates TEST_PLAN.md).

Device questions the build 5 logs answer on the first run: StructureBuilder's output frame (per room: placement method, matches, rms); whether ModelIO reads Object Capture's USDZ on iOS 18.3.2 (`ObjectModelLoader.canReadUSDZ`, triangles, bounds against `.bounds`, and which loader path produced each object's mesh); whether `PhotogrammetrySession` accepts the capture checkpoint after it moved to `derived/objects/<id>/checkpoint/` (the "checkpoint retry" line); whether `ObjectCaptureActivity` ever made a capture or a reconstruction wait, and for how long; whether dismantling the relocalization and live mesh `ARView`s leaves the hub's session running (`hub.isRunning` and delegate identity after dismantle; both containers hand the view a fresh idle `ARSession()` first); relocalization time and success rate (seconds to `.normal`, Start Fresh Here taps); Object Capture limits on the A15 (`maximumNumberOfInputImages`, `PhotogrammetrySession.limits`), reconstruction time and downsampling; CoverageLive pass time (median under 60 ms for 50k visible faces) and CoverageOverlay main-thread time per tick (under 8 ms).

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
  HouseUI rev.     <- as build 5 (hook for the D16 detail pass of House rooms, composed by AppShell 6c)
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

Core changes for build 4 (CR-2, CR-4, CR-5 and CR-6 below) were applied on `integration` by the design review before wave 4a; every build 4 contract in this file compiles against Core as it is now. No further Core change is needed for build 4. Build 5 needs three Core changes before wave 5a (CR-1, CR-7, CR-8, applied by the lead in one commit) and revisions of seven build 4 modules in wave 5a0, two of them numbered (CR-9, CR-10); section 2.2 has the order.

- CR-1 (Core, Geometry and Store; approved; specified in 3.37a; the lead applies it before wave 5a with stub cases): `EditOperation` gains `moveOpening(opening:offset:)`, `resizeOpening(opening:width:sillHeight:headHeight:)`, `mergeRooms(rooms:into:)`, `splitRoom(room:line:newRoom:)` and `batch(operations:)` (one user action is one undo step), with `targets` and `flattened`; `EditLog` gains `flattenedActive` and `reset(keeping:)`; `CleanFloor` and `PlanRoom` gain optional `mergedOutlines`; the `WallArc` angle convention and the wall orientation invariant (room on the left of start -> end, normal the left perpendicular) are documented in Core; Geometry gains `Polygon2D.clipped(leftOf:_:)`; Store gains `EditStore.reset(_:keeping:)`. RoomModel (3.37b) and FloorPlan (3.37c) implement the operations in wave 5a0; the FloorPlan change request of build 4 (RoomModel reverses walls outside the loop instead of flipping their normal; FloorPlan stops reversing walls) lands in the same two revisions. Readers of one operation kind (scale corrections, room alignments, crops, recategorizations) read `EditLog.flattenedActive`, never `active`, because a batch can hold any operation.
- CR-2 (Core, applied): one low-confidence rule everywhere. `MeasuredValue.isLowConfidence(length:)` implements "2 sigma above max(4 cm, 3 percent of the length)" for lengths and "2 sigma above 3 percent of the value" for areas and volumes (`length: nil`); `isLowConfidence(kind:)` picks the variant from a `MeasurementKind`, and the `isLowConfidence` property treats the value as a length. MeasureCore's `MeasureDisplay.isLowConfidence(_:length:)` delegates to it, and every screen goes through MeasureDisplay.
- CR-3 (MeshProcessing): done. `MeshChunk` was renamed `MergeChunk`, and `Cleanup.swift` (`MeshCleanup`) and `ObjectIsolation.swift` (`ObjectIsolation`) are merged. Code against the names in 3.8.
- CR-4 (Core, applied): `RawScanFolder.resolve(_:) -> URL?` returns nil for absolute paths, `..`, `.` or empty components, backslashes, NUL bytes and anything outside the folder (`RawScanFolder.isSafeRelativePath(_:)` is the pure rule); `ProjectStore.readJSON(_:from:maxBytes:)` throws `CoreError.fileTooLarge(name:bytes:)` above `maxBytes` (default `ProjectStore.defaultMaxJSONBytes`, 32 MB; `readManifest` uses `maxManifestBytes`, 1 MB); `listProjects()` lists only folders named exactly `<UUID>.mapperproj` (`ProjectStore.projectID(fromPackageName:)`) whose manifest id matches; `ProjectStore.writeData(_:to:protection:createParents:)` keeps `.atomic` and adds `ProjectStore.defaultProtection(for:)` when `protection` is nil: `.completeFileProtectionUnlessOpen` under a package's `edits/` and `exports/` and for `thumbnail.jpg`, the system default for raw and derived. `ProjectStore.inProgressRoot()` re-applies backup exclusion on every call.
- CR-5 (Core, documentation, applied): the `ProjectPackage` doc comment places the Object Capture checkpoint at `derived/objects/<id>/checkpoint/` (section 3.33) and lists the per-module derived files of section 3.1.
- CR-6 (Core, applied by the design review): `writeData(... createParents: false)` refuses to recreate a missing parent folder and `ProjectStore.ensureDirectory(_:inside:)` creates a derived folder only while the package root exists (late writes after a discard or delete, 3.10); `ProjectPackage.pipelineAttemptURL` (`derived/pipeline_attempt.json`, 3.15); `RawScanFolder.liveCapturedRoomURL` (`capturedroom-live.json`) and `RawScanFolder.worldMapURL` (`worldmap.arworldmap`) (3.21); `MapperError.lowMemory` (3.21); `CoreError.fileTooLarge`; `ScanEngine.discard()` (3.21, 3.24; `FakeScanEngine.discard()` equals `cancel()`); doc comments on `ProjectStatus.capturing`, `PlanModel.northAngle` (counter-clockwise from plan +y) and `ObjectCategory` display names.
- CR-7 (Core, build 5; specified in 3.30a; the lead applies it with CR-1 before wave 5a): `RoomRecord.supersededBy: UUID? = nil` for HouseUI's Rescan. Backward compatible (build 4 manifests decode with nil); CoreSelfTest gains 2 checks. Rooms that count are `supersededBy == nil` (Structure `StructureEligibility.activeRooms`).
- CR-8 (Core, build 5; specified in 3.31c; the lead applies it with CR-1 before wave 5a): `MinimapSnapshot` gains `camera: Vec2? = nil` and `heading: Float? = nil` (the "you are here" marker of the minimap). Backward compatible; CoreSelfTest gains 2 checks.
- CR-9 (Coverage revision, wave 5a0; specified in 3.31a): `GuidanceInput.extraConditions: Set<GuidanceKind> = []`, tier 2 and 3 conditions decided outside the engine (LargeObject's sector guidance), with no change to thresholds or display rules.
- CR-10 (Quality revision, wave 5a0; specified in 3.31b): `QualityEvaluator.evaluateSealedRoom(package:record:passes:now:)`, `QualityEvaluator.doneInputHash(seals:)` and `QualityStep(room:passes:)` (default `[]`), so a room's sealed mesh-pass folders count in its quality.
- Other revisions of build 4 modules in wave 5a0 (no change request number, each specified in its own section): RoomModel (3.37b), FloorPlan (3.37c), CaptureCore `run(options:initialWorldMap:)` and `ScanConfigurationFactory.make(_:initialWorldMap:)` (3.30b), RoomCapture `makeCaptureView` keeps a running session (3.30c), Viewer3D `loadModel` (3.34a). The build 4 screens are revised in wave 5c (3.43a to 3.43d) and AppShell in 5d (3.43e).

Lead decision after the build 4 end-to-end review (E3): the CR-2 low-confidence rule (2 sigma above max(4 cm, 3 percent of the length)) applies to lengths; an area or volume takes its low-confidence flag from its sides (wall area from length and height, floor area from length and width, total wall area from the wall areas, volume from floor area and ceiling height). `MeasureDisplay` has row overloads that use the row's own flag.

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
| `edits/editlog.json` (build 5: CR-1 operations and `batch` entries; PlanEditor writes one entry per user action) | Store `EditStore` (PlanEditor, Results, HouseUI and LargeObject append) | Store `EditStore`; replayed by RoomModel `CleanModelStore.loadEdited` and FloorPlan `PlanModelStore.loadEdited` |
| `edits/measurements.json` | Store `EditStore`, written by MeasureTool (viewer measurements) and Results (renames and deletions of Quick Measure records; once written it supersedes `raw/measure/quick.json` for display, and the raw file stays sealed) | Store `EditStore.loadMeasurements`; Results `QuickMeasureRecords.effective` |
| `exports/<yyyyMMdd-HHmmss>/...` | ExportUI (also Results' Quick Look copy) | none (shared out) |
| `Library/Application Support/InProgress/<scanID>/` (RawScanFolder layout plus `scan.json`, D5) | Store `InProgressScans` (RoomCapture, ObjectCapture, LiveMeshView write through `RawScanWriter`) | Store `InProgressScans.list()`, AppShell `RecoveryService` |
| `raw/sessions/<s>/mesh-pass/<p>/` (RawScanFolder layout plus `scan.json` with kind `.meshPass` and the room id; Show Missing Areas and the D16 detail pass in build 5, space scans in build 6) | LiveMeshView `MeshScanEngine` via Store | LiveMeshView `MeshPassFolders` (`forRoom(_:in:)`, `spacePasses(in:)`); MeshModel `ConsolidateMeshStep(roomID:folders:)`; Quality `evaluateSealedRoom(package:record:passes:now:)` (CR-10); Store `RawScanReader` |
| `raw/measure/quick.json` and its `SEAL.json` (Quick Measure projects) | LiveMeasure `QuickMeasureStore.save` | LiveMeasure `QuickMeasureStore.load`; Results `QuickMeasureRecords.effective`; ExportUI |
| `raw/objects/<o>/` (`Images/`, `objectlog.json`, `SEAL.json`; small and medium) | ObjectCapture `ObjectScanFolders.seal` | ObjectCapture `PhotogrammetryStore.imagesURL`; FloorPlan `ThumbnailStep` (first image) |
| `raw/objects/<o>/` (RawScanFolder layout plus `largeobject.json`; large) | LargeObject through LiveMeshView `MeshScanEngine` | MeshModel `ConsolidateMeshStep` (subject = object id) |
| `derived/objects/<o>/checkpoint/` (moved from the capture at sealing, kept for build 6 ObjectCrop), `model.usdz`, `model-partial.usdz` (only while reconstructing), `reconstruction.json` | ObjectCapture (`ObjectScanFolders.seal`, `PhotogrammetryStep`) | ObjectCapture `PhotogrammetryStore`; ObjectModel through `ObjectMetricsStep`'s closures |
| `derived/objects/<o>/dims.json`, `mesh.mchk` | ObjectModel `ObjectMetricsStep` | ObjectModel `ObjectModelStore` |
| `derived/structure/structure.json` (only after a successful merge), `attempt.json` (only while the builder runs), `merge.json` | Structure `MergeStructureStep` | Structure `StructureStore` |
| `derived/structure/alignment.json` ([RoomAlignmentRecord], measured and parked), `placements.json` | Structure `AlignRoomsStep` | Structure `StructureStore` (`effectiveAlignments` adds the user edits) |
| `derived/structure/connections.json`; `derived/clean.json` of House projects | Structure `HouseCleanModelStep` | Structure `StructureStore`; RoomModel `CleanModelStore` |
| `raw/sessions/<s>/` of House sessions: `CaptureSessionRef.worldMapFile` = `rooms/<r>/worldmap.arworldmap` (the room's own map, no new file) | HouseUI (manifest field only) | HouseUI `HouseRelocalization.sourceMap` (resolved with `RawScanFolder.resolve`) |

Input hashes (D11): a step hashes the `SealFile`s of the raw folders it reads with `InputHasher.hash(seals:editRevision:extra:)`; a step that reads another step's output also adds that step's current stamp `inputHash` (read from `derived/index.json` with `ProjectStore.readJSON(DerivedIndex.self, from:)`, `"-"` when there is none) to `extra`, so it reruns when its input was rebuilt (for example `CleanModelStep` adds the room's `consolidateMesh` stamps, `FloorPlanStep` the `cleanModel` stamp, `TextureLowStep` the room's `consolidateMesh` stamp, `QualityStep` the room's `buildRoom` and `consolidateMesh` stamps). Only steps that read edits pass `EditLog.revision` (build 4: `ThumbnailStep`).

Build 5 additions to the input hashes: `HouseCleanModelStep` adds `StructureStore.alignmentEditDigest` (the active alignment edits only) instead of `EditLog.revision`; `ObjectMetricsStep` adds `ObjectModelStore.cropDigest` for large objects; `QualityStep` adds the seals of the room's mesh-pass folders (CR-10); `CleanModelStep` hashes `CleanModelStep.rulesVersion` ("cleanModel-rules=2" from build 5) and `FloorPlanStep` hashes `FloorPlanStep.rulesVersion` ("planBuilder-rules=2"); AppShell's `ProcessingPlans.upgradeIfNeeded()` enqueues every ready, non-demo room and house project once per `ProcessingPlans.rulesVersion`, so derived files made under older rules are rebuilt.

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

**Must NOT do.** Never use `floors[].polygonCorners` as the room outline or area source while the wall loop closes (cross-check only); only when the loop does not close is the floor polygon (else the hull of the wall ends) the outline, with floor provenance `.estimated` (ARCHITECTURE RoomOutline, risk 5; lead ruling after build 4 wave 4a). Never trust `columns.0` sign for winding; derive it from the loop. Never draw curved walls as straight segments (keep `arc`). Never construct or mutate `CapturedRoom`. Never write into raw. Never bake a label or category guess into anything but the derived model (labels are edits).

**Copy strings.** None (names are resolved by FloorPlan's `RoomTitles`).

**Self-test.** `RoomModelSelfTest.run()`, at least 45 checks, with hand-made `RoomInput` fixtures in `RoomModelSelfTestFixtures.swift`: a 4 x 5 m rectangle, an L-shaped room (6 walls, area 20.0 where the bounding rectangle is 24.0), a room with a 0.3 m stub wall, a room with one wall whose `columns.0` is flipped, a room with a curved wall. Checks: outline closed and counter-clockwise; L-shape area within 1e-3 of 20 and perimeter exact; floor polygon mismatch reported for the L-shape with a rectangle floor; stub goes to `strayWalls`; flipped wall still in loop order; wall normals point inside; corner intersection moves endpoints that overshoot by 5 cm; door projected onto its parent with correct offset, width, sill 0 and head height; window sill relative to floor elevation; opening with nil parent attaches to the nearest wall; default swing hinge at the nearer corner; ceiling from a synthetic mesh at 2.60 m with 80 percent coverage is measured 2.60; with 10 percent coverage it falls back to wall height, estimated; length and width of the 4 x 5 room are 5 and 4; wall area subtracts one door; volume provenance follows the ceiling; findFurniture false drops objects; occlusion span for a sofa 0.1 m from a wall; each EditOperation case applied once (rename, relabel, recategorize, hide, delete wall, move object, move wall endpoint, add wall, add opening, door swing, thickness, scale 1.1 on area) plus an orphaned target returning false; `PolygonTriangulator` on a square (2 triangles), an L (4 triangles), a clockwise input, and a degenerate input (empty); `CleanMeshBuilder.wallMesh` of a 4 x 2.5 m wall with a 0.9 x 2.0 m door has area 10 - 1.8 within 1e-4; `parts` excludes hidden objects unless asked; a sofa 0.1 m from a wall yields one occluded wall quad and one occluded floor quad, both `.inferred`; a provisional input gives `.estimated` walls; `RoomInput` Codable round trip with `isProvisional` true.

**Acceptance checks.** RoomPlan types appear only in the three named files; the builder never reads `floors` for area while the wall loop closes (fallback is `.estimated`); every public function is pure; `CleanModel.apply` returns true for operations meant for other models; metrics are recomputed after edits in `loadEdited`; `CleanModelStep.inputHash` includes the room seals and `EditLog.revision` is NOT included (the base model ignores edits); `BuildRoomStep` never throws for a `RoomBuilder` error; derived files are written with `createParents: false` after `ensureDirectory(_:inside:)` (CR-6).

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

Same rules and format as build 4 (Purpose; Build and wave; Files; Public Swift API; Uses; Apple APIs; Must NOT do; Copy strings; Self-test; Acceptance checks; SPEC owned; TEST_PLAN ids). Every build 5 agent receives section 0, section 3.1 and its own section. Symbols of merged modules are the real ones on `integration` (build 4, all waves); a symbol of another build 5 module is the declaration in that module's section below, with the same spelling. Waves are in section 2.2: the Core changes before wave 5a (applied by the lead), wave 5a0 (revisions of build 4 modules that later build 5 modules compile against), 5a, 5b, 5c (revisions of the build 4 screens) and 5d (AppShell). The module sections keep their numbers; a lettered section is a Core change or a revision of a build 4 module, placed next to the module that needs it first.

| Section | Module or change | Wave | Folder |
|---|---|---|---|
| 3.37a | Core change CR-1: plan editing operations (with Geometry `Polygon2D.clipped` and Store `EditStore.reset`) | pre-5a (lead) | Core, Geometry, Store |
| 3.30a | Core change CR-7: superseded rooms | pre-5a (lead) | Core |
| 3.31c | Core change CR-8: minimap camera | pre-5a (lead) | Core |
| 3.37b | RoomModel revision: wall orientation, CR-1 operations | 5a0 | RoomModel |
| 3.37c | FloorPlan revision: CR-1 operations, merged rooms | 5a0 | FloorPlan |
| 3.30b | CaptureCore revision: relocalization run | 5a0 | CaptureCore |
| 3.30c | RoomCapture revision: keep a running session | 5a0 | RoomCapture |
| 3.34a | Viewer3D revision: loadModel | 5a0 | Viewer3D |
| 3.31a | Coverage revision CR-9: extra guidance conditions | 5a0 | Coverage |
| 3.31b | Quality revision CR-10: mesh-pass folders | 5a0 | Quality |
| 3.30 | Structure | 5a | Structure |
| 3.31 | CoverageLive | 5a | CoverageLive |
| 3.32 | LiveMeshView | 5a | LiveMeshView |
| 3.33 | ObjectCapture | 5a | ObjectCapture |
| 3.34 | ObjectModel | 5a | ObjectModel |
| 3.35 | MeasureTool | 5a | MeasureTool |
| 3.36 | LiveMeasure | 5a | LiveMeasure |
| 3.37 | PlanEditor | 5a | PlanEditor |
| 3.38 | CoverageOverlay | 5b | CoverageOverlay |
| 3.39 | LargeObject | 5b | LargeObject |
| 3.40 | MissingAreas | 5b | MissingAreas |
| 3.41 | HouseUI | 5b | HouseUI |
| 3.42 | ObjectUI | 5b | ObjectUI |
| 3.43a | ScanUI revision | 5c | ScanUI |
| 3.43b | Results revision | 5c | Results |
| 3.43c | HomeUI revision | 5c | HomeUI |
| 3.43d | ExportUI revision | 5c | ExportUI |
| 3.43e | AppShell revision | 5d | AppShell |

### 3.30 Structure (wave 5a)

**Purpose.** House merge and alignment (D9) as pure logic plus three processing steps: which rooms share an ARKit world frame (frame groups from `RoomRecord.frameLink` and `CaptureSessionRef.frameLink`), `StructureBuilder(options: [.beautifyObjects])` on the confirmed shared-frame rooms only, each room's rigid transform (yaw about +Y plus translation) into the structure frame recovered by least squares on the wall, door, window and opening identifiers the merge keeps, fallback placements (shared frame, group median, parked beside the building for rooms from unaligned sessions), stacked-room detection, floor levels by elevation, shared walls with measured thickness, each connecting doorway kept once, the House clean model in the structure frame with the user's alignment edits applied, the snapping math of manual alignment (used by HouseUI's `AlignRoomsScreen`), and every file under `derived/structure/`. Raw data is never moved: transforms are applied at derivation time, to the clean model here and to meshes, keyframes and textures by their consumers through `StructureStore.effectiveAlignments`.

**Build and wave.** Build 5, wave 5a. Core (with CR-1 and CR-7, 3.37a and 3.30a), Geometry, RoomModel (as revised in wave 5a0, 3.37b), MeshProcessing (the `MeshWithAttributes` type only), Store (`EditStore`), Support; RoomPlan only in `StructureStore.swift` and `StructureSteps.swift`. About 1450 lines excluding the self-test. No UI, no Copy.

**Files.** `ios/Sources/Structure/StructureEligibility.swift`, `StructureAlignment.swift`, `StructureFloors.swift`, `StructureWalls.swift`, `StructureLayout.swift`, `StructureSnapping.swift`, `StructureStore.swift`, `StructureSteps.swift` (MergeStructureStep, AlignRoomsStep), `StructureCleanStep.swift` (HouseCleanModelStep), `StructureSelfTest.swift`, `StructureSelfTestFixtures.swift`.

**Public Swift API.** Everything except the steps and the store's file IO is pure, nonisolated and safe on any queue. Plan coordinates are `PlanAxes` (plan x = world x, plan y = -world z); a yaw is a rotation about world +Y, which is counter-clockwise both seen from above and in plan coordinates.
```swift
// MARK: Frames (StructureEligibility.swift)

/// Rooms captured in one ARKit world frame (D9): sessions joined by
/// `.relocalized(sessionID:from:)` links, plus the active rooms captured in them.
struct StructureFrameGroup: Equatable, Sendable {
    /// Session identifiers, in `ProjectManifest.sessions` order.
    var sessions: [UUID]
    /// Active room identifiers, in `ProjectManifest.rooms` order.
    var rooms: [UUID]
}

enum StructureEligibility {
    /// Rooms that belong in house models: `supersededBy == nil` (CR-7) and status `.captured`,
    /// `.processed` or `.needsRescan` (a poor room is still real data). Manifest order.
    static func activeRooms(_ manifest: ProjectManifest) -> [RoomRecord]
    /// Groups sessions by relocalization links (undirected, transitive), each group with the
    /// active rooms of its sessions. A session whose `CaptureSessionRef.frameLink` is `.unaligned`
    /// or `.manual` never joins another session but keeps all its rooms in one group: Start Fresh
    /// Here continues one ARKit session with `startNextRoom`, so those rooms share a frame with
    /// each other (their own `frameLink` is `.unaligned` too, which must not split them). Only a
    /// room whose own `frameLink` is `.manual` is a group of its own (one room).
    static func frameGroups(rooms: [RoomRecord], sessions: [CaptureSessionRef]) -> [StructureFrameGroup]
    /// The structure frame: the group with the most rooms; ties go to the group that holds the
    /// earliest session in `sessions` order. Nil when there are no rooms.
    static func anchorGroup(_ groups: [StructureFrameGroup], sessions: [CaptureSessionRef]) -> StructureFrameGroup?
    /// Rooms passed to StructureBuilder: active rooms of the anchor group for which `isFinal` is
    /// true (a raw or rebuilt capturedroom.json, never the provisional live file). Everything
    /// else is `separate`. Both keep the order of `rooms`.
    static func mergeable(_ rooms: [RoomRecord], sessions: [CaptureSessionRef],
                          isFinal: (RoomRecord) -> Bool) -> (merge: [RoomRecord], separate: [RoomRecord])
    /// Stable text of a frame link for input hashes ("project:<id>", "reloc:<id>:<from>",
    /// "manual", "unaligned").
    static func linkKey(_ link: FrameLink) -> String
}

// MARK: Rigid placement (StructureAlignment.swift)

/// One surface (wall, door, window or opening) found both in a room's own capture and in the
/// merged structure: plan segment endpoints and the surface center height (world y).
struct AlignmentSegmentPair: Equatable, Sendable {
    var beforeStart: SIMD2<Float>
    var beforeEnd: SIMD2<Float>
    var beforeY: Float
    var afterStart: SIMD2<Float>
    var afterEnd: SIMD2<Float>
    var afterY: Float
    init(beforeStart: SIMD2<Float>, beforeEnd: SIMD2<Float>, beforeY: Float,
         afterStart: SIMD2<Float>, afterEnd: SIMD2<Float>, afterY: Float)
    /// Weight in the solve: the length of the before segment, meters.
    var weight: Float { get }
}

/// A rigid placement solved from segment pairs.
struct AlignmentSolution: Equatable, Sendable {
    /// Rotation about world +Y, radians.
    var yaw: Float
    /// World translation, meters (y is the weighted median height change).
    var translation: SIMD3<Float>
    /// Root mean square plan distance of the matched endpoints after the transform, meters.
    var rms: Float
    /// Segment pairs used.
    var matches: Int
    /// The Core record for a room (Core `RoomAlignmentRecord`, translation as `Vec3`).
    func record(roomID: UUID, source: Provenance) -> RoomAlignmentRecord
}

enum StructureAlignment {
    /// A solve is trusted only with at least `minimumMatches` pairs and rms at most this, meters.
    static let maxTrustedRMS: Float = 0.05
    static let minimumMatches = 2
    /// Weighted 2D Procrustes (D9). Pass 1 solves yaw and translation from segment midpoints;
    /// pass 2 orders each pair's after endpoints to agree with the pass 1 rotation (RoomPlan's
    /// `columns.0` sign is arbitrary) and solves again on all endpoints. Nil with fewer than 2
    /// pairs or when the midpoints are all within 1 cm of each other.
    static func solve(_ pairs: [AlignmentSegmentPair]) -> AlignmentSolution?
    /// Pairs for one room: every wall, door, window and opening of `room` (its own capture,
    /// RoomModel `RoomInput`) whose identifier appears in `structure` (see
    /// `StructureSurfaces.index`), with endpoints from RoomModel `RoomOutline.surfaceEndpoints`
    /// and heights from the surface transforms. Surfaces without endpoints are skipped.
    static func pairs(room: RoomInput, structure: [UUID: SurfaceInput]) -> [AlignmentSegmentPair]
    /// Rotation about +Y by `record.yaw` (column-major: column 0 = (cos, 0, -sin, 0), column 2 =
    /// (sin, 0, cos, 0)), then translation by `record.translation`.
    static func matrix(_ record: RoomAlignmentRecord) -> simd_float4x4
    static func transform(_ point: SIMD3<Float>, by record: RoomAlignmentRecord) -> SIMD3<Float>
    /// The same placement in plan coordinates: counter-clockwise rotation by yaw, then
    /// (translation.x, -translation.z).
    static func planTransform(_ point: SIMD2<Float>, by record: RoomAlignmentRecord) -> SIMD2<Float>
    static func identity(roomID: UUID, source: Provenance) -> RoomAlignmentRecord
    static func inverse(_ record: RoomAlignmentRecord) -> RoomAlignmentRecord
    /// `inner` first, then `outer`; the result keeps `inner.roomID`.
    static func compose(_ outer: RoomAlignmentRecord, after inner: RoomAlignmentRecord, source: Provenance) -> RoomAlignmentRecord
    /// A plan rotation about `pivot` expressed as a record (manual alignment turns rooms about
    /// their own centroid).
    static func rotation(by angle: Float, about pivot: SIMD2<Float>, roomID: UUID) -> RoomAlignmentRecord
    /// A plan move expressed as a record (world y unchanged).
    static func translation(by delta: SIMD2<Float>, roomID: UUID) -> RoomAlignmentRecord
    /// Component-wise median of yaw and translation over trusted solutions; nil when empty.
    static func median(_ solutions: [AlignmentSolution]) -> AlignmentSolution?
    /// The room moved: wall start, end and normal, wall arc center (angles plus yaw), floor
    /// outline and elevation (plus translation.y), object transforms. Openings, spans,
    /// metrics, names and ids are unchanged (rigid move).
    static func apply(_ record: RoomAlignmentRecord, to room: CleanRoom) -> CleanRoom
    /// Moves the room whose `recordID == record.roomID`; false when there is none.
    @discardableResult
    static func apply(_ record: RoomAlignmentRecord, to model: inout CleanModel) -> Bool
    /// Stacked-room check: cells of a `cell` grid (plan meters) inside both polygons divided by
    /// the cells inside the smaller one (`Polygon2D.contains(point:)` at cell centers over the
    /// intersection of the bounding boxes). 1 for identical squares, 0 when disjoint.
    static func overlapRatio(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>], cell: Float = 0.05) -> Float
}

// MARK: Floors (StructureFloors.swift)

struct FloorAssignmentInput: Equatable, Sendable {
    var roomID: UUID
    /// `RoomRecord.floorIndex` (Add Floor in HouseUI).
    var userFloor: Int
    /// Floor elevation in the structure frame; nil for parked or unplaced rooms.
    var elevation: Float?
}

enum StructureFloors {
    static let defaultGap: Float = 1.2
    /// Cluster rank per room, 0 for the lowest cluster: elevations sorted, a new cluster starts
    /// where two neighbors differ by more than `gap`.
    static func group(elevations: [UUID: Float], gap: Float = 1.2) -> [UUID: Int]
    /// The derived floor index of every room (ARCHITECTURE 4.3: "story as a hint only").
    /// Rooms with an elevation are clustered with `group`; each cluster, lowest first, takes the
    /// user floor most of its rooms carry (ties: the smaller index), unless a lower cluster
    /// already took that index, in which case it takes one more than the largest index used so
    /// far. Rooms without an elevation keep their user floor.
    static func assign(_ rooms: [FloorAssignmentInput], gap: Float = 1.2) -> [UUID: Int]
}

// MARK: Shared walls and doorways (StructureWalls.swift)

/// Two walls of different rooms that are the two faces of one wall.
struct SharedWallPair: Codable, Equatable, Sendable {
    var roomA: UUID
    var wallA: ElementID
    var roomB: UUID
    var wallB: ElementID
    /// Distance between the two inner faces, meters: the measured wall thickness.
    var gap: Float
    /// Length along which the two faces overlap, meters.
    var overlap: Float
}

/// One doorway seen from both rooms; the kept opening stays a door, the other becomes a plain
/// opening so the plan and 3D Clean draw the door once (TEST_PLAN HOUSE-04).
struct DoorwayLink: Codable, Equatable, Sendable {
    var keptRoom: UUID
    var kept: ElementID
    var mergedRoom: UUID
    var merged: ElementID
    /// Distance between the two opening centers, plan meters.
    var distance: Float
}

enum StructureWalls {
    static let minimumGap: Float = 0.05
    static let maximumGap: Float = 0.5
    static let parallelToleranceDegrees: Float = 10
    /// Required face overlap: min(0.5 m, half the shorter wall).
    static let minimumOverlap: Float = 0.5
    static let doorwayDistance: Float = 0.4
    static let doorwayWidthTolerance: Float = 0.25
    /// Probe distance behind a wall for the exterior test, meters.
    static let exteriorProbe: Float = 0.3
    /// Mutual-best pairs of straight walls (arc nil) of different rooms on the same floor:
    /// antiparallel normals within 10 degrees, room B's wall behind room A's wall (on the side
    /// opposite A's normal), gap 0.05 to 0.5 m, overlap at least `minimumOverlap`. Each wall is
    /// in at most one pair; smaller gap, then larger overlap wins. Deterministic order.
    static func sharedWalls(in model: CleanModel) -> [SharedWallPair]
    /// Paired walls get `thickness = gap`, `thicknessSource = .measured`. An unpaired straight
    /// wall on a floor with at least 2 rooms whose probe point (midpoint moved `exteriorProbe`
    /// against its normal) lies inside no other room outline of that floor gets
    /// `exteriorThickness` with `.estimated`; every other wall keeps RoomModel's value.
    static func applyThickness(_ pairs: [SharedWallPair], exteriorThickness: Float, to model: inout CleanModel)
    /// Openings of kind door, openDoor or opening on the two walls of a pair whose centers are
    /// within `doorwayDistance` and whose widths differ by at most `doorwayWidthTolerance`.
    /// Kept: the door when only one is a door, else the opening of the room that comes first
    /// in `model.rooms`.
    static func doorwayLinks(in model: CleanModel, pairs: [SharedWallPair]) -> [DoorwayLink]
    /// The merged opening of each link becomes kind `.opening` with `swing = nil`; ids,
    /// offsets and sizes are kept, so its wall still has the gap.
    static func applyDoorways(_ links: [DoorwayLink], to model: inout CleanModel)
}

// MARK: Placement plan (StructureLayout.swift)

/// A room's outline in its own capture frame, from RoomModel `RoomOutline.build(_:).polygon`,
/// and its floor height (the lowest `WallSegment.baseY`).
struct RoomFootprint: Equatable, Sendable {
    var roomID: UUID
    var outline: [SIMD2<Float>]
    var floorElevation: Float
    /// Nil when the loop has fewer than 3 points.
    static func from(_ input: RoomInput, roomID: UUID) -> RoomFootprint?
}

/// How a room got its placement. Raw values are persisted in placements.json.
enum AlignmentMethod: String, Codable, CaseIterable, Sendable {
    /// Same ARKit frame as the structure, no trusted merge solve: identity.
    case sharedFrame
    /// Solved from the StructureBuilder merge (trusted).
    case structureMerge
    /// Anchor-group room without a trusted solve while others have one: their median.
    case groupMedian
    /// Room from another frame: laid out beside the building until the user lines it up.
    case parked
    /// A `setRoomAlignment` edit (source `.user`) overrides the derived placement.
    case user
}

struct RoomPlacementReport: Codable, Equatable, Sendable {
    var roomID: UUID
    var method: AlignmentMethod
    var matches: Int
    var rms: Float?
    /// The earlier room this one overlaps by more than 30 percent on the same floor.
    var stackedWith: UUID?
    /// True for parked and stacked rooms (HouseUI shows "needs lining up" until a user edit).
    var needsManualAlignment: Bool
}

struct StructurePlacementPlan: Equatable, Sendable {
    /// One record per placed or parked room (source `.measured` for sharedFrame,
    /// structureMerge and groupMedian, `.estimated` for parked).
    var records: [RoomAlignmentRecord]
    var reports: [RoomPlacementReport]
    /// Active rooms that got no record (another frame and no loadable outline).
    var unplaced: [UUID]
}

enum StructureLayout {
    static let parkingGap: Float = 1.0
    static let stackedOverlap: Float = 0.3
    /// Rooms whose floors are closer than this in height are on the same floor for the
    /// stacked check, meters.
    static let sameFloorHeight: Float = 1.2
    /// The whole placement plan (used by AlignRoomsStep, and by HouseCleanModelStep when
    /// alignment.json is missing): anchor-group rooms take their trusted solve
    /// (structureMerge), else the median of the trusted solves (groupMedian), else identity
    /// (sharedFrame); rooms of other groups are parked with `parking`; then `stacked` flags.
    static func plan(rooms: [RoomRecord], sessions: [CaptureSessionRef], footprints: [UUID: RoomFootprint],
                     solutions: [UUID: AlignmentSolution]) -> StructurePlacementPlan
    /// Parked placements, one translation per frame group so the rooms of a group keep their
    /// relative layout (they share an ARKit frame): each group's union bounds in a row to the +x
    /// side of the placed footprints' plan bounds, 1 m apart, bottom edges aligned, never
    /// overlapping, in `groups` order. Without placed footprints the first group stays where it
    /// is and the rest follow to its right.
    static func parking(_ groups: [[RoomFootprint]], placed: [RoomFootprint]) -> [UUID: RoomAlignmentRecord]
    /// Later room to earlier room for placed pairs on the same floor whose placed outlines
    /// overlap by more than `stackedOverlap` (`StructureAlignment.overlapRatio`).
    static func stacked(_ footprints: [RoomFootprint], records: [UUID: RoomAlignmentRecord], order: [UUID]) -> [UUID: UUID]
}

// MARK: Manual alignment math (StructureSnapping.swift), used by HouseUI

struct AlignWall: Equatable, Sendable {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    /// Unit plan normal pointing into the room.
    var inward: SIMD2<Float>
}

/// A room as the alignment screen draws and snaps it, plan meters, structure frame.
struct AlignShape: Equatable, Sendable {
    var roomID: UUID
    var outline: [SIMD2<Float>]
    var walls: [AlignWall]
    /// Centers of doors and openings.
    var doors: [SIMD2<Float>]
    /// From a clean room (edited model, already in the structure frame).
    static func from(_ room: CleanRoom) -> AlignShape
    func moved(by record: RoomAlignmentRecord) -> AlignShape
    var centroid: SIMD2<Float> { get }
}

enum AlignSnapKind: String, CaseIterable, Sendable { case none, parallel, wallGap, doorway }

struct AlignPlacement: Equatable, Sendable {
    /// Delta to compose after the room's current effective alignment.
    var delta: RoomAlignmentRecord
    var snap: AlignSnapKind
}

enum StructureSnapping {
    static let angleSnapDegrees: Float = 5
    static let wallSnapDistance: Float = 0.3
    static let doorSnapDistance: Float = 0.4
    static let assumedWallThickness: Float = 0.12
    /// The user's raw gesture (rotation about the moving shape's centroid, then translation)
    /// snapped in this order: yaw to the nearest wall direction of `others` within 5 degrees
    /// (parallel, modulo 90 degrees); then door centers within 0.4 m made to coincide
    /// (doorway); else the nearest antiparallel wall within 0.3 m moved to a 0.12 m gap
    /// (wallGap). Pure; the returned delta applies to `moving` as given.
    static func snap(_ moving: AlignShape, rotation: Float, translation: SIMD2<Float>, others: [AlignShape]) -> AlignPlacement
}

// MARK: Files (StructureStore.swift, imports RoomPlan)

/// `derived/structure/attempt.json`: written right before StructureBuilder runs, removed right
/// after it returns or throws. Present at the next run: the app died inside the builder.
struct StructureAttempt: Codable, Equatable, Sendable {
    var startedAt: Date
    var roomIDs: [UUID]
    var inputHash: String
}

enum StructureMergeOutcome: String, Codable, CaseIterable, Sendable {
    case merged, tooFewRooms, builderFailed, crashedBefore, skippedReducedMemory, unsupported
}

/// `derived/structure/merge.json` (MergeStructureStep).
struct StructureMergeResult: Codable, Equatable, Sendable {
    var outcome: StructureMergeOutcome
    var mergedRooms: [UUID]
    var separateRooms: [UUID]
    /// Anchor-group rooms left out because only the provisional live room exists.
    var provisionalRooms: [UUID]
    /// Builder error description (logs only, never shown).
    var detail: String?
    var seconds: Double
    var inputHash: String
    var finishedAt: Date
}

/// `derived/structure/placements.json` (AlignRoomsStep).
struct StructurePlacements: Codable, Equatable, Sendable {
    var rooms: [RoomPlacementReport]
    var unplaced: [UUID]
    var inputHash: String
    var finishedAt: Date
}

struct FloorAssignmentEntry: Codable, Equatable, Sendable { var roomID: UUID; var floorIndex: Int }

/// `derived/structure/connections.json` (HouseCleanModelStep).
struct StructureConnections: Codable, Equatable, Sendable {
    var sharedWalls: [SharedWallPair]
    var doorways: [DoorwayLink]
    var floors: [FloorAssignmentEntry]
    var inputHash: String
}

/// Everything HouseUI and Results read about a house's structure, in one value.
struct StructureReport: Equatable, Sendable {
    var merge: StructureMergeResult?
    var placements: StructurePlacements?
    var connections: StructureConnections?
    var hasCrashedAttempt: Bool
    static let empty: StructureReport
    func placement(for roomID: UUID) -> RoomPlacementReport?
}

enum StructureStore {
    static let maxStructureBytes: Int64 = 128 * 1024 * 1024
    static func attemptURL(_ package: ProjectPackage) -> URL        // derived/structure/attempt.json
    static func mergeURL(_ package: ProjectPackage) -> URL          // merge.json
    static func placementsURL(_ package: ProjectPackage) -> URL     // placements.json
    static func connectionsURL(_ package: ProjectPackage) -> URL    // connections.json
    /// `ProjectStore.ensureDirectory(package.structureURL, inside: package.root)` (CR-6).
    @discardableResult static func ensureFolder(_ package: ProjectPackage) throws -> URL
    /// `package.capturedStructureURL` with a plain `JSONDecoder()` through RoomModel's
    /// `CapturedRoomStore.decodeRoomPlanJSON(_:from:maxBytes:)`; nil when absent.
    static func loadStructure(_ package: ProjectPackage) throws -> CapturedStructure?
    /// Plain `JSONEncoder()`, `ProjectStore.writeData(_:to:createParents: false)`.
    static func saveStructure(_ structure: CapturedStructure, to package: ProjectPackage) throws
    static func removeStructure(_ package: ProjectPackage)
    /// `package.alignmentURL` ([RoomAlignmentRecord], Core doc); empty when absent or unreadable.
    static func loadAlignments(_ package: ProjectPackage) -> [RoomAlignmentRecord]
    static func saveAlignments(_ records: [RoomAlignmentRecord], to package: ProjectPackage) throws
    static func loadReport(_ package: ProjectPackage) -> StructureReport
    /// The last `setRoomAlignment` per room in `log.flattenedActive` (CR-1: a batch may hold one),
    /// source forced to `.user`.
    static func userAlignments(_ log: EditLog) -> [UUID: RoomAlignmentRecord]
    /// Derived records overridden by user edits (pure).
    static func effectiveAlignments(measured: [RoomAlignmentRecord], log: EditLog) -> [UUID: RoomAlignmentRecord]
    /// `loadAlignments` plus `EditStore.load(package)` (any thread). Results, ExportUI and the
    /// build 5 viewers place each room's mesh, keyframes and textures with
    /// `StructureAlignment.matrix` of this record.
    static func effectiveAlignments(_ package: ProjectPackage) -> [UUID: RoomAlignmentRecord]
    /// Pure. Where Results and ExportUI draw each active room (`StructureEligibility.activeRooms`):
    /// `StructureAlignment.matrix` of its record in `alignments`; without a record, identity for a
    /// room of the anchor frame group (it shares the structure frame, exactly as
    /// HouseCleanModelStep's fallback plan places it while alignment.json is missing) and no entry
    /// for a room of another group (it waits for AlignRoomsStep to park it). Every active room of a
    /// non-House project gets identity. Rooms without an entry are skipped by the caller.
    static func placementMatrices(manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord]) -> [UUID: simd_float4x4]
    /// Stable text of the user alignments for input hashes ("-" when none).
    static func alignmentEditDigest(_ log: EditLog) -> String
    static func hasCrashedAttempt(_ package: ProjectPackage) -> Bool
    /// HouseUI "Join Rooms Again": removes attempt.json so the next job calls the builder again.
    static func clearCrashedAttempt(_ package: ProjectPackage) throws
}

// MARK: Steps (StructureSteps.swift and StructureCleanStep.swift)

/// RoomPlan surfaces of a merged structure by identifier: walls, doors, windows and openings
/// of `structure.rooms` first, then the structure-level lists for identifiers not seen yet,
/// each converted with RoomModel's `SurfaceInput.init(_:)` (StructureSteps.swift, RoomPlan).
enum StructureSurfaces {
    static func index(_ structure: CapturedStructure) -> [UUID: SurfaceInput]
}

/// id .mergeStructure; optional in the House plan; budget 400 MB, reduced 60 MB (the reduced
/// variant never calls StructureBuilder). Reads `ctx.manifest`, so it takes no arguments (rooms
/// can change between enqueue and run).
final class MergeStructureStep: ProcessingStep { init() }
/// id .alignRooms; optional; budget 150 MB.
final class AlignRoomsStep: ProcessingStep { init() }
/// id .cleanModel for House projects (AppShell schedules it instead of RoomModel's
/// CleanModelStep); required; budget 250 MB. Same provider shape as CleanModelStep.
final class HouseCleanModelStep: ProcessingStep {
    static let rulesVersion = "houseClean-rules=1"
    init(meshProvider: @escaping (ProjectPackage, UUID) -> MeshWithAttributes?)
}
```

**Rules.**

*Frames.* A room shares the structure frame only when its session is in the anchor group: the first session of a new house is `.projectFrame(sessionID:)`, and HouseUI writes `.relocalized(sessionID:from:)` only after tracking returned to `.normal` against a saved world map (so the D9 "tracking normal" condition is in the link itself), else `.unaligned`. Rooms of the anchor group always get a placement, even when StructureBuilder is skipped, fails or crashes, because they share ARKit's frame. Rooms of other groups are never merged and never stacked silently: they are parked beside the building and flagged until the user lines them up (HouseUI `AlignRoomsScreen`); a user edit on one room of a group is written for every room of that group, because they share a frame.

*MergeStructureStep.* Input hash: `InputHasher.hash(seals:editRevision: nil, extra:)` over the seals of the `mergeable` rooms, their `buildRoom` stamp hashes ("-" when absent), every session's `linkKey`, "attempt=present" or "attempt=absent", and `"mergeStructure-rules=1"`. Order: (1) outcome `unsupported` when `RoomCaptureSession.isSupported` is false; (2) `skippedReducedMemory` when `ctx.availableMemory < memoryBudgetBytes` (Core rule: the reduced variant; also what the runner forces after one crash, 3.15 `PipelineAttempt`); (3) `crashedBefore` when attempt.json exists, whatever input hash it records (the builder died last time; a crash cannot be caught, RESEARCH 3.10 gotcha 9; matching the stored hash would never succeed, because the current hash carries "attempt=present" while the stored one was computed with "attempt=absent", so the builder would be called again after every crash; only `clearCrashedAttempt` removes the file, and its absence changes the hash so the step reruns); (4) `tooFewRooms` with fewer than 2 mergeable rooms; (5) otherwise write attempt.json, load each room with `CapturedRoomStore.loadCapturedRoom`, `ctx.checkCancelled()`, then `try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)`, catching every error (`StructureBuilder.BuildError` and others) as `builderFailed` with `detail`; remove attempt.json after the call returns or throws. Only `merged` writes `structure.json`; every other outcome removes a stale one. merge.json is written in every case, and the step never fails the job (only cancellation and a failed derived write throw). Logged (category "structure"): outcome, room count, seconds, surface counts, available memory before and after.

*AlignRoomsStep.* Input hash: seals of the active rooms, their `buildRoom` stamps, the `mergeStructure` stamp, session `linkKey`s, `"alignRooms-rules=1"`. It loads each active room's `RoomInput` (`CapturedRoomStore.loadInput`; a failure leaves the room without a footprint) and, when merge.json says `merged`, the structure (`StructureStore.loadStructure`) indexed with `StructureSurfaces.index`. For each merged room `StructureAlignment.solve(pairs(room:structure:))` is trusted at `minimumMatches` or more and rms at most `maxTrustedRMS`; untrusted solves are logged with their rms. `StructureLayout.plan` then gives every record and report; alignment.json and placements.json are written. The step never fails for a room it cannot place.

*HouseCleanModelStep.* Input hash: seals of the active rooms; per room id, floor, name, `supersededBy`, `buildRoom` and `consolidateMesh` stamp hashes; the `alignRooms` stamp; `StructureStore.alignmentEditDigest(EditStore.load(package))` (only the alignment edits, not `EditLog.revision`, so unrelated edits do not rebuild the model); `findFurniture`; `rulesVersion`. Per active room, one at a time: `CapturedRoomStore.loadInput` (failure: the room is left out and logged, as CleanModelStep does), `CleanModelBuilder.buildRoom(_:recordID:name:floorIndex:mesh:options:)` in the room's capture frame with the provider's mesh, then `StructureAlignment.apply` of its effective record (`effectiveAlignments(measured: loadAlignments, log:)`; without alignment.json, `StructureLayout.plan` with no solutions). Then `StructureFloors.assign` sets each room's `floorIndex` (placed rooms by their structure-frame floor elevation, parked rooms keep the user floor), `StructureWalls.sharedWalls`, `applyThickness(_:exteriorThickness: CleanBuildOptions().exteriorThickness, to:)`, `doorwayLinks` and `applyDoorways`. It writes clean.json through `CleanModelStore.save` with `sourceIsStructure` true when any room's method is `structureMerge` or `groupMedian`, and its stamp, then connections.json. Edits that store absolute positions (`moveObject`, `moveWallEndpoint`, `addWall`, `addOpening`, annotations, dimensions) are in the structure frame and are not moved when that room's alignment later changes; the step logs one line per room whose effective alignment changed since the previous build.

*Consumers.* FloorPlanStep reads clean.json unchanged (its levels are the union of the manifest floors and the rooms' derived floor indices). Results, ExportUI and viewers that draw per-room meshes, keyframes or textures of a house use `StructureStore.placementMatrices(manifest:alignments: StructureStore.effectiveAlignments(package))` and skip rooms without an entry, so the meshes stand where the House clean model puts the rooms even before AlignRoomsStep has run (a plain "skip rooms with no record" would leave Realistic and Raw Scan empty until then, and "identity for every room" would drop rooms of other frames on top of the building).

**Uses.** Core: `ProjectManifest`, `RoomRecord` (with CR-7 `supersededBy`), `RoomStatus`, `CaptureSessionRef`, `FrameLink` (`mayShareFrame`, `sessionID`), `RoomAlignmentRecord`, `EditOperation.setRoomAlignment`, `EditLog.flattenedActive` (CR-1), `CleanModel`, `CleanRoom`, `CleanWall`, `CleanOpening`, `OpeningKind`, `WallArc`, `DetectedObject`, `Transform4`, `Vec2`, `Vec3`, `Provenance`, `ElementID`, `PlanAxes`, `ProjectPackage` (`structureURL`, `capturedStructureURL`, `alignmentURL`, `derivedIndexURL`, `root`), `ProjectStore` (`ensureDirectory(_:inside:)`, `writeJSON`, `writeData`, `readJSON`, `encoder`), `DerivedIndex`, `DerivedStamp`, `InputHasher`, `SealFile`, `ProcessingStep`, `StepContext`, `MapperError`. Geometry: `Polygon2D` (`contains(point:)`, `area`, `boundingBox`), `Segment2D`. RoomModel: `RoomInput`, `SurfaceInput` (`init(_ surface: CapturedRoom.Surface)`), `RoomOutline` (`build(_:)`, `surfaceEndpoints(_:)`, `wallSegments(_:)`), `WallSegment.baseY`, `CleanModelBuilder.buildRoom(_:recordID:name:floorIndex:mesh:options:)`, `CleanBuildOptions` (`findFurniture`, `exteriorThickness`), `CapturedRoomStore` (`loadInput`, `loadCapturedRoom`, `loadWithSource`, `hasFinalRoom`, `rawFolder`, `decodeRoomPlanJSON`), `CleanModelStore.save`. MeshProcessing: `MeshWithAttributes`. Store: `EditStore.load(_:)`. Support: `LogStore` (category "structure").

**Apple APIs** (RESEARCH 3.2, 3.10):
```swift
class StructureBuilder                                                     // iOS 17.0
init(options: StructureBuilder.ConfigurationOptions)                       // typealias of RoomBuilder.ConfigurationOptions
func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure
struct RoomBuilder.ConfigurationOptions   // OptionSet, init(rawValue: Int); only option: static let beautifyObjects
enum StructureBuilder.BuildError          // iOS 17.0: deviceNotSupported, exceedSceneSizeLimit, insufficientInput,
                                          // internalError, invalidInput, invalidRoomLocation
// CapturedStructure: struct, Codable, Sendable: identifier, version, rooms: [CapturedRoom], walls, doors,
// windows, openings, floors, objects, sections (Surface/Object/Section are typealiases of the CapturedRoom types)
static var isSupported: Bool { get }      // RoomCaptureSession, iOS 16.0
```
`JSONEncoder()` and `JSONDecoder()` (plain, section 3.1 rule for RoomPlan types). Nothing else outside Foundation and simd.

**Must NOT do.** Never pass a room outside the anchor group, a `.manual` or `.unaligned` room, or a provisional (live) room to StructureBuilder; never rely on StructureBuilder to throw for unrelated frames (D9); never write `StructureBuilder(option:)` (RESEARCH 3.10 gotcha 10); never call the builder without writing attempt.json first, and never call it again automatically after a crash (only `clearCrashedAttempt` re-enables it); never trust a solve with fewer than 2 matches or rms above 5 cm; never place a room from another frame at its capture coordinates (park it); never move, rewrite or delete raw data or rewrite a `RoomRecord` (steps never write the manifest); never keep a structure.json that does not match the current merge; never write a user alignment anywhere but the EditLog (HouseUI) and never bake it into alignment.json; never parse USDZ node names; never import RoomPlan outside `StructureStore.swift` and `StructureSteps.swift`; never pass `EditLog.revision` into the step hashes (only the alignment digest).

**Copy strings.** None (HouseUI owns all house text).

**Self-test.** `StructureSelfTest.run()`, at least 35 checks, fixtures in `StructureSelfTestFixtures.swift` (hand-made `RoomInput` rectangles and `CleanRoom`s; no RoomPlan objects are created): `solve` recovers yaw 30 degrees and translation (1, 0.2, 2) from the 4 walls of a 4 x 5 m room within 1e-3, also when two pairs have their after endpoints swapped; 1 pair gives nil; coincident midpoints give nil; a solve with noise 0.1 m reports rms above `maxTrustedRMS`; `matrix` of yaw 90 degrees maps world (1, 0, 0) to (0, 0, -1) and `planTransform` maps plan (1, 0) to (0, 1); `inverse` then `compose` gives identity within 1e-5; `rotation(by:about:)` keeps the pivot fixed; `median` of three solutions; `apply` moves walls, normals, the arc center and angles, floor outline, floor elevation and object transforms, and leaves openings and metrics equal; `apply(to: inout CleanModel)` returns false for an unknown room; `overlapRatio` gives 1 for identical squares, 0 for disjoint ones, 0.5 within 0.02 for half-overlapping squares, and works for an L-shape; `frameGroups`: projectFrame session A plus a session B relocalized from A form one group, an unaligned session C is separate and its two rooms (both with frameLink `.unaligned`) form one group, a room with frameLink `.manual` in session A is its own group; `anchorGroup` picks the largest group and breaks a tie by session order; `mergeable` leaves a provisional room and an unaligned room out; `activeRooms` drops a superseded room and a `.capturing` room and keeps `.needsRescan`; `group` of elevations 0, 0.05 and 2.8 gives two clusters; `assign` puts an upstairs room on a new floor when every user floor is 0, keeps user floors 0, 0, 1 for elevations 0, 0, 2.8, and keeps the user floor of a room without elevation; `plan` gives sharedFrame identity to anchor rooms without a merge, groupMedian to an anchor room without a solve when others have one, parked records (source `.estimated`) 1 m to the right of the building for another session's rooms, and a stacked flag for a second copy of the same room; `parking` never overlaps two parked groups and keeps the relative layout of two rooms of one group; two rooms whose shared wall faces are 0.12 m apart give one `SharedWallPair` with gap 0.12 within 1e-4, and both walls get thickness 0.12 `.measured`; faces 0.8 m apart give no pair; an outside wall of a two-room floor gets `exteriorThickness` `.estimated` and a single-room floor keeps 0.115; a door on both sides of a shared wall gives one `DoorwayLink`, the later room's door becomes `.opening` with no swing and keeps its offset; a door facing an opening keeps the door; `StructureSnapping.snap` turns a room rotated 3 degrees parallel to its neighbor, moves a door 0.3 m away onto the neighbor's door, and moves an antiparallel wall 0.25 m away to a 0.12 m gap; `userAlignments` keeps the last active edit per room, finds one inside a `batch` and ignores an undone one; `effectiveAlignments` prefers the user record; `alignmentEditDigest` changes when an alignment edit is appended and not when a rename is; a temp package round trip of merge.json, placements.json, connections.json and alignment.json through `StructureStore`; `hasCrashedAttempt` true after writing attempt.json and false after `clearCrashedAttempt`; the merge decision (a pure helper of the step) gives `crashedBefore` for a leftover attempt.json whose stored input hash differs from the current one; `placementMatrices` gives the record's matrix, identity for an anchor-group room without a record, no entry for another group's room without a record, and identity for every room of a Room project.

**Acceptance checks.** RoomPlan is imported only in the two named files; every pure function is nonisolated and deterministic (no `Date()` except `finishedAt` stamps, no randomness); derived writes use `ensureFolder` and `createParents: false`; MergeStructureStep writes attempt.json before and removes it after the builder call in every code path; no step throws for a merge, solve or placement failure; `HouseCleanModelStep` holds at most one room's consolidated mesh at a time; logs name each room's method, matches and rms; section 3.1's `structure.json` is written only by MergeStructureStep.

**SPEC owned.** "HOUSE / BUILDING MODE": preserve room relationships (frame groups, D9), recognize shared walls (`StructureWalls.sharedWalls`), maintain coordinate alignment (solve, fallbacks, effective alignments), detect doorways connecting rooms (`DoorwayLink`), combine rooms into one building model (`HouseCleanModelStep`), support multiple floors (`StructureFloors.assign`), manual correction (snapping math and user records; the screen is HouseUI). "2D FLOOR PLAN": wall thickness where determinable (measured from wall pairs, estimated exterior). "CORE DESIGN PRINCIPLE": raw never moved (alignment at derivation time).

**TEST_PLAN ids.** HOUSE-02 (rooms combined, shared walls within 10 cm), HOUSE-03 (one wall, thickness within 3 cm or estimated), HOUSE-04 (each connecting door once), HOUSE-06 (relocalized room placed in the same frame), HOUSE-07 (user alignment applied, raw unchanged), HOUSE-08 (upstairs rooms on their own level), HOUSE-09, PLAN-05, PERF-10; EXP-09 through ExportUI's use of structure.json (5c).

### 3.30a Core change CR-7: superseded rooms (applied by the lead before wave 5a)

HouseUI's Rescan (TEST_PLAN HOUSE-05, HOUSE-06) captures a room again and must replace the old capture in every model without deleting its raw data (D5, D6). Core has no way to say "this capture was replaced". One optional field, backward compatible with build 4 manifests (synthesized `Decodable` uses `decodeIfPresent` for optionals; the memberwise initializer gains a trailing defaulted parameter, so no call site changes):
```swift
struct RoomRecord {
    // ...existing fields unchanged...
    /// The room that replaced this capture after a Rescan (HouseUI, build 5); nil while this
    /// capture is current. A superseded room keeps its sealed raw folder and its record; house
    /// models, processing plans, the room list, Results and exports leave it out. Build 6 Free up
    /// space may offer to remove it (D6).
    var supersededBy: UUID? = nil
}
```
CoreSelfTest adds 2 checks: a build 4 manifest JSON without the key decodes with `supersededBy == nil`, and a round trip keeps a set value. Consumers that list rooms filter with `StructureEligibility.activeRooms` (3.30) or `supersededBy == nil`. CR-1 (3.37a) and CR-8 (3.31c) are applied in the same pre-5a Core commit.

### 3.30b CaptureCore revision: relocalization run (wave 5a0)

**Purpose.** HouseUI's Continue Scanning and Rescan (ARCHITECTURE 4.3, RESEARCH 3.2 recommended 7) start a new session that relocalizes against a saved `ARWorldMap` before RoomPlan starts. The merged hub can only run `ScanConfigurationFactory.make(profile)`, which has no world map.

**Build and wave.** Build 5, wave 5a0 (one agent, branch `impl/capturecore-reloc`). CaptureCore only; merges before wave 5a starts. Its only caller is HouseUI (5b).

**Files.** Edits `ios/Sources/CaptureCore/CaptureConfiguration.swift`, `CaptureSessionHub+Lifecycle.swift`, `CaptureCoreSelfTest.swift`.

**Public Swift API.**
```swift
extension ScanConfigurationFactory {
    /// `make(profile)` with `initialWorldMap` set (nil gives exactly `make(profile)`).
    static func make(_ profile: ScanProfile, initialWorldMap: ARWorldMap?) -> ARWorldTrackingConfiguration
}
extension ARSessionHub {
    /// Call on the main thread, before any RoomPlan object exists. Same as `run(options:)`
    /// (monitors, identity check, logging) with the configuration from
    /// `make(profile, initialWorldMap: map)`. HouseUI passes [.resetTracking, .removeExistingAnchors]
    /// (allowed here because RoomPlan has not started). The map is used for this run only:
    /// `reapplyConfiguration` keeps building `make(profile)` without it, which is safe because the
    /// watchdog runs only after `markScanStart`, when relocalization is over.
    func run(options: ARSession.RunOptions, initialWorldMap: ARWorldMap)
}
```
No default arguments on the new `run`, so `run()` and `run(options:)` stay unambiguous.

**Apple APIs** (RESEARCH 3.1, 3.2): `var initialWorldMap: ARWorldMap? { get set }` (ARWorldTrackingConfiguration, iOS 12.0); `func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])`; RunOptions `.resetTracking`, `.removeExistingAnchors`.

**Must NOT do.** Never set a world map in `reapplyConfiguration`; never pass reset options anywhere else; no RoomPlan import.

**Self-test.** At least 3 new checks in `CaptureCoreSelfTest`: `make(profile, initialWorldMap: nil)` has a nil `initialWorldMap` and the same reconstruction, semantics and plane detection as `make(profile)`; `describe` of it contains "initialWorldMap: false".

**Acceptance checks.** The log line of the new run names the options and "initialWorldMap: true"; Room mode (ScanUI) behaves exactly as before.

**SPEC owned.** "HOUSE / BUILDING MODE" ("Allow the user to return to incomplete sections", capture side). **TEST_PLAN ids.** HOUSE-06.

### 3.30c RoomCapture revision: keep a running session (wave 5a0)

**Purpose.** `RoomScanEngine.makeCaptureView()` calls `hub.install()` and `hub.run()` unconditionally, so after HouseUI relocalized the engine's hub with a world map, creating the view would re-run the plain configuration. It must re-assert the delegate but keep a running session, as `startNextRoom` already does.

**Build and wave.** Build 5, wave 5a0 (branch `impl/roomcapture-reloc`). RoomCapture only; merges before wave 5a starts. Its only caller is HouseUI (5b).

**Files.** Edits `ios/Sources/RoomCapture/RoomScanEngine.swift`, `RoomScanStats.swift`, `RoomCaptureSelfTest.swift`.

**Public Swift API.**
```swift
extension RoomScanStats {
    /// Pure: `makeCaptureView` runs the hub only when it is not running yet.
    static func shouldRunHub(isRunning: Bool) -> Bool
}
// makeCaptureView(): hub.install(); if RoomScanStats.shouldRunHub(isRunning: hub.isRunning) { hub.run() }
// else log "session already running (relocalized), not run again".
```

**Must NOT do.** No other behavior change; the order install, (run), view, delegates stays as in 3.21.

**Self-test.** 2 new checks (`shouldRunHub` true for false, false for true). **Acceptance checks.** In Room mode the hub is never running before `makeCaptureView`, so ScanUI's path is unchanged; the log shows which branch ran. **TEST_PLAN ids.** HOUSE-06 (capture side).

### 3.31 CoverageLive (wave 5a)

**Purpose.** Live coverage for every ARKit capture from build 5 on (Room and House rooms on `RoomCaptureView`, Show Missing Areas patch passes, the two-pass fallback, mesh-only space scans, large objects): a `ScanRecorder` that keeps one Coverage `CoverageGrid` (10 cm voxels) current at up to 3 Hz from the latest camera pose and the live LiDAR faces (MeshRecord `MeshStore`), marks expected surfaces (the live RoomPlan room, a finished room, or watched point sets such as missing areas) so unscanned parts read red, finds missing areas with windows, doors and openings excluded (D19), and publishes what the other build 5 modules draw and say: per-anchor face states (CoverageOverlay, LargeObject), the top-down `MinimapSnapshot` and `coverageFraction` (through the engines' snapshot augmenter), `viewCoverage`, `nearbyMissing` and `overallComplete` (through the guidance augmenter, so Coverage's `GuidanceEngine` says "Scan this corner", "Point toward the floor", "Scan the ceiling" and "This area needs another pass"), and the observed fraction of each watched point set (MissingAreas). It writes no file: live coverage is display state; the sealed scan is scored again by Quality.

**Build and wave.** Build 5, wave 5a. Core, Coverage, CaptureCore, MeshRecord, RoomModel (`RoomInput`, `RoomOutline.floorPolygon`), Geometry, Support; ARKit (callback types only). About 1200 lines plus the self-test. CR-8 (3.31c) must be applied to Core before this module starts.

**Files.** `ios/Sources/CoverageLive/CoverageLiveRecorder.swift` (recorder, lock, rate, hooks, readers), `CoverageLiveRecorder+Work.swift` (the work-queue pass: anchor refresh, integration, states, evaluation, publishing), `CoverageLiveFaces.swift` (pure: faces of a chunk, visibility, rate), `CoverageLiveBoundary.swift` (pure: live room to boundary and exclusions), `CoverageLiveMissing.swift` (pure: missing-area filter, nearby choice, ages, watched fractions, completeness), `CoverageLiveMinimap.swift` (pure), `CoverageLiveSelfTest.swift`. No Copy file (no UI).

**Public Swift API.**
```swift
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
    var maxMinimapCells: Int = 96
    /// Faces tracked at most; anchors past the cap are left out (logged once per recording).
    var maxTrackedFaces: Int = 500_000
    /// With an expected room but no mesh face after this many seconds of scanning, the expected
    /// shell samples stand in for faces (meshStripped, D16).
    var shellFallbackSeconds: Double = 8
    /// Live-room mode only: missing areas reach guidance after this much scan time, once each has
    /// been missing this long, within this horizontal distance of the camera, at most 3.
    var nearbyAfterSeconds: Double = 30
    var nearbyMinAgeSeconds: Double = 15
    var nearbyRadius: Float = 3
    init() {}
}

/// One anchor's triangles with their live coverage states. A value copy: the arrays share
/// storage with MeshStore's chunk of the same version (copy on write, nothing is duplicated).
struct CoverageAnchorFaces {
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
    var integrations: Int
    var skippedBusy: Int
    var anchors: Int
    var trackedFaces: Int
    /// With an expected room: observed / expected area; otherwise the green share of the tracked face area. 0...1.
    var coverageFraction: Float
    /// Green share of the in-view face area at the last pass; nil when under 0.05 m^2 is in view.
    var viewCoverage: Float?
    var missingCount: Int
    var hasExpectedRoom: Bool
    var usesShellFallback: Bool
    var effectiveHz: Double
    var lastPassMilliseconds: Double
}

/// Live coverage recorder. ScanRecorder calls arrive on the hub queue and only copy values; all
/// grid work runs on the private serial queue "mapper.coverage.live" (QoS utility) with at most one
/// pass queued (a due frame that finds a pass in flight is skipped and counted). Published values
/// are lock-protected, so readers and hooks are safe on any thread and never compute.
final class CoverageLiveRecorder: ScanRecorder {
    static let logCategory = "coverage"
    let options: CoverageLiveOptions
    init(meshSource: MeshStore, options: CoverageLiveOptions = CoverageLiveOptions())

    // MARK: ScanRecorder (hub queue)
    /// A fresh grid for this room or pass: everything is cleared except `options`. Writes nothing into `folder`.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    /// When due (rate below, tracking `.normal`, no pass in flight) copies one `CoverageObservation`
    /// (`camera.transform`, `camera.intrinsics`, `camera.imageResolution`, `ARFrameReading.meanConfidence(of:)`,
    /// `timestamp`) and queues one pass. A frame that is not due returns after two comparisons.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    /// Stops queuing, waits for the pass in flight, drops every per-anchor array (so `MeshStore.evict()`
    /// really frees memory, D17), keeps the last published values, then calls `completion` on the work queue.
    func finishRecording(completion: @escaping () -> Void)
    /// Always zero: coverage records no raw data.
    var stats: RecorderStats { get }

    // MARK: Expected surfaces (any thread; applied at the next pass)
    /// The live RoomPlan room (RoomScanEngine.liveRoomHandler, at most 1 Hz). Turns on live-room
    /// mode (nearby missing areas and `overallComplete` for guidance).
    func setExpectedRoom(_ room: RoomInput)
    /// A boundary built elsewhere (a finished CleanRoom through `QualityInputs.boundary(for:)`), or nil
    /// to clear. Samples inside `exclusions` (window, door and opening boxes) are never expected.
    func setExpectedBoundary(_ boundary: CoverageRoomBoundary?, exclusions: [OrientedBox])
    /// Point sets to watch, keyed by the caller (MissingAreas: `MissingAreaRecord.id`). Their points are
    /// marked expected (they read red until observed) and their well-observed fraction is published
    /// after every pass. An empty dictionary clears them.
    func setWatchedAreas(_ areas: [Int: [SIMD3<Float>]])
    /// Integrates earlier observations of the same place (a patch pass starting from the room pass)
    /// in order before any live pass, until `deadlineSeconds` of work-queue time; logs how many were used.
    func seed(observations: [CoverageObservation], faces: [CoverageFace], deadlineSeconds: Double)

    // MARK: Engine hooks (hub queue; copy the latest published values)
    /// Sets `viewCoverage`; in live-room mode also `nearbyMissing` (options above) and `overallComplete`.
    func augment(_ input: inout GuidanceInput)
    /// Sets `coverageFraction` and `minimap` (with `camera` and `heading`, CR-8).
    func augment(_ snapshot: inout LiveScanSnapshot)
    /// Ready-made closures for `RoomScanEngine.liveRoomHandler`, `guidanceAugmenter` and
    /// `snapshotAugmenter` (and MeshScanEngine's two augmenters). They capture `self` weakly and are
    /// formed here, outside any actor: a closure formed inside a `@MainActor` method is main-actor
    /// isolated and must not be handed to a hub-queue hook (RoomCapture's `installHubClosures` rule).
    var liveRoomHook: (RoomInput) -> Void { get }
    var guidanceHook: (inout GuidanceInput) -> Void { get }
    var snapshotHook: (inout LiveScanSnapshot) -> Void { get }

    // MARK: Readers (any thread)
    /// Anchors whose revision is greater than `revision`, and the newest revision (0 returns all).
    func anchorFaces(changedSince revision: UInt64) -> (revision: UInt64, anchors: [CoverageAnchorFaces])
    /// Missing areas of the expected room after the exclusions, largest first.
    func currentMissingAreas() -> [MissingArea]
    /// Well-observed fraction 0...1 per watched set.
    func watchedFractions() -> [Int: Float]
    func summary() -> CoverageLiveSummary
    /// Camera to world of the last integrated observation.
    func lastCameraTransform() -> simd_float4x4?
}

/// Faces of a chunk, visibility and rate. Pure, any queue.
enum CoverageLiveFaces {
    /// One face per triangle: corners through `chunk.transform`; the normal is the cross product,
    /// flipped when it disagrees with the mean of the three ARKit vertex normals rotated to world,
    /// kept when that mean is zero (normals are per vertex, RESEARCH 3.8 gotcha 6); class
    /// `SurfaceClass(rawValue: chunk.classes[t])` when the count matches, else `.none`; area 0 and a
    /// zero normal for degenerate or out-of-range triangles.
    static func faces(of chunk: MeshChunk) -> [CoverageFace]
    /// Voxel key per face (`grid.key(for: centroid)`) and the unique keys of the anchor (area-0 faces
    /// get the key of their first corner and are never integrated).
    static func keys(_ faces: [CoverageFace], grid: CoverageGrid) -> (perFace: [SIMD3<Int32>], unique: [SIMD3<Int32>])
    /// Cone test: the bounding sphere of the bounds meets the view cone (the wider half field of view
    /// from the intrinsics plus 10 degrees) within `CoverageGrid.maxRange` of the camera.
    static func mayBeVisible(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, observation: CoverageObservation) -> Bool
    /// CoverageGrid's own projection test for one face: inside the image with the same margin,
    /// `CoverageGrid.minRange` to `maxRange` away, facing the camera.
    static func isInView(_ face: CoverageFace, observation: CoverageObservation) -> Bool
    /// min(maxHz, policy.coverageHz); 0 means never.
    static func effectiveHz(maxHz: Double, policy: ThermalPolicy) -> Double
    /// True when `timestamp - last >= 1 / hz` (always when `last` is nil); false when hz <= 0.
    static func isDue(timestamp: Double, last: Double?, hz: Double) -> Bool
}

/// The live RoomPlan room as a Coverage boundary. Pure. Never calls CleanModelBuilder or
/// RoomOutline.build: both log per call and a live room arrives every second.
enum CoverageLiveBoundary {
    /// Walls: endpoints `transform * (-+w/2, 0, 0, 1)` as world (x, z), baseY = center y - height / 2,
    /// height = dimensions.y (walls under 0.05 m long or with non-finite values skipped). Floor polygon:
    /// `RoomOutline.floorPolygon(room)` converted from plan (x, -z) to world (x, z), else the convex hull
    /// of the wall endpoints; floorY = the lowest wall base; ceilingY = floorY + the tallest wall;
    /// ceilingPolygon empty (Coverage reuses the floor). Nil with fewer than 2 usable walls.
    static func boundary(from room: RoomInput) -> CoverageRoomBoundary?
    /// One box per door, open door, window and opening (its transform, width, height and a 0.3 m
    /// depth), grown by `margin` on every side.
    static func exclusions(from room: RoomInput, margin: Float) -> [OrientedBox]
    /// Expected sample positions outside every exclusion.
    static func expectedPoints(_ samples: [ExpectedSample], exclusions: [OrientedBox]) -> [SIMD3<Float>]
}

/// First-seen times of missing areas across evaluations. A key is the surface raw value plus the
/// centroid rounded to 0.5 m (clusters drift as coverage grows).
struct CoverageLiveMissingAges: Equatable {
    init()
    /// Ages in seconds, one per area in the same order; keys not seen this time are forgotten.
    mutating func update(_ areas: [MissingArea], now: Double) -> [Double]
}

/// Missing areas, guidance inputs and watched fractions. Pure.
enum CoverageLiveMissing {
    /// Drops areas whose surface is `.window` or `.door`, or whose centroid lies in an exclusion (D19).
    static func filtered(_ areas: [MissingArea], exclusions: [OrientedBox]) -> [MissingArea]
    /// Empty before `options.nearbyAfterSeconds`; then areas at least `nearbyMinAgeSeconds` old within
    /// `nearbyRadius` (horizontal, camera to centroid), nearest first, at most 3.
    static func nearby(_ areas: [MissingArea], ages: [Double], camera: SIMD3<Float>, elapsed: Double,
                       options: CoverageLiveOptions) -> [MissingArea]
    /// Area-weighted share of `faces` whose state is green; nil when their total area is under 0.05 m^2.
    static func greenFraction(faces: [CoverageFace], states: [CoverageState]) -> Float?
    /// A point counts when a voxel within `radius` of it has `goodObservationCount >= 1`.
    static func wellObservedFraction(_ points: [SIMD3<Float>], grid: CoverageGrid, radius: Float) -> Float
    /// Observed at least 0.9 of the expected area and no missing area left.
    static func isComplete(observedFraction: Float, missingCount: Int) -> Bool
}

/// The top-down map. Pure.
enum CoverageLiveMinimap {
    /// Cells in plan coordinates (`PlanAxes`: x, -z) over the union of the voxels' extent and the
    /// boundary's floor polygon, `cellSize` doubled until both sides fit `maxCells`. A cell is
    /// `.covered` when a voxel in its column is green, else `.partial` when one is yellow, else
    /// `.missing` when an unobserved expected sample falls in it, else `.empty`. Walls are the boundary
    /// walls as plan polylines. `camera` and `heading` (CR-8) come from `camera` when given.
    static func make(voxels: [(key: SIMD3<Int32>, state: CoverageState)], voxelSize: Float,
                     boundary: CoverageRoomBoundary?, unobservedExpected: [SIMD3<Float>],
                     camera: simd_float4x4?, cellSize: Float, maxCells: Int) -> MinimapSnapshot
    /// Plan angle, radians counter-clockwise from plan +x, of the camera's forward direction (its -Z
    /// column) projected on the floor; of its top edge (its -X column, portrait) when the forward is
    /// within 30 degrees of vertical.
    static func heading(cameraToWorld: simd_float4x4) -> Float
}
```

One pass on the work queue, in this order:
1. Anchor refresh (at most every `anchorRefreshSeconds`): read `meshSource.index` (a lock-protected copy) and compare each entry's `updateCount` with the stored one; for changed or new anchors read `meshSource.currentChunks()` once and rebuild `faces(of:)` and `keys(_:grid:)`. Stale anchors keep their faces (RESEARCH 3.1 gotcha 15). Past `maxTrackedFaces`, new anchors are skipped.
2. Integration: the positive-area faces of the anchors that pass `mayBeVisible`, in first-seen anchor order, plus the shell samples as faces when the shell fallback is on (`ExpectedSurfaces.samples(for:)` positions and inward normals), then `grid.integrate(observation:faces:)`. The grid's per-face statistics are keyed by position in this per-pass list and are never read; every state comes from `state(atVoxel:)` of the face's voxel (RESEARCH 3.8 gotcha 7, 3.10 gotcha 16).
3. States: recomputed for the anchors of step 2, and for every anchor after the expected marks changed; an anchor gets a new revision only when a state or its geometry changed.
4. View coverage: `greenFraction` over the faces with `isInView` (every second face).
5. Expected marks, when the boundary or the watched sets changed: `clearExpected()`, then `markExpected` of `expectedPoints` (boundary samples outside exclusions) and of every watched point.
6. Evaluation (at most every `evaluationSeconds`): with a boundary, `ExpectedSurfaces.evaluate(room:grid:)`, observed fraction = sum of observed area / sum of expected area, missing = `filtered(result.missing, exclusions:)`, ages, nearby list (live-room mode), complete flag, minimap from every anchor's unique voxel keys and the unobserved expected samples; without one, the fraction is the green share of all tracked faces and the minimap has no missing cells.
7. Watched fractions (`wellObservedFraction`, radius 0.15 m), then one locked publish of everything.

Logs (category "coverage"): the effective rate whenever it changes; the face cap once; one line every 30 s with integrations, skipped passes, anchors, faces, fraction, missing count and the median pass time; the seed summary.

**Uses.** CaptureCore: `ScanRecorder`, `ARSessionHub` (`thermal.policy`), `ThermalPolicy` (`coverageHz`), `ScanProfile`, `RecorderStats`, `ARFrameReading.meanConfidence(of:stride:)`, `TrackingMonitor.summary(_:)`. MeshRecord: `MeshStore` (`index`, `currentChunks()`), `MeshChunkIndexEntry.updateCount`. Coverage: `CoverageGrid` (`init(voxelSize:)`, `integrate(observation:faces:)`, `key(for:)`, `state(atVoxel:)`, `voxelStats(_:)`, `markExpected(_:)`, `clearExpected()`, `minRange`, `maxRange`, `frustumMarginFraction`), `CoverageStats.goodObservationCount`, `CoverageFace`, `CoverageObservation`, `CoverageState`, `CoverageRoomBoundary`, `CoverageWall`, `SurfaceClass`, `ExpectedSurfaces.samples(for:spacing:)`, `ExpectedSurfaces.evaluate(room:grid:spacing:)`, `ExpectedSample`, `ExpectedSurfacesResult`, `MissingArea`, `GuidanceInput` (`viewCoverage`, `nearbyMissing`, `overallComplete`). RoomModel: `RoomInput`, `SurfaceInput`, `SurfaceKind` (`openingKind`), `RoomOutline.floorPolygon(_:)`. Core: `MeshChunk`, `RawScanFolder`, `LiveScanSnapshot` (`coverageFraction`, `minimap`), `MinimapSnapshot` (with CR-8), `MinimapCell`, `PlanAxes.toPlan(_:)`, `PlanAxes.toWorld(_:y:)`, `Vec2`, `Transform4` (`simd`, `translation`). Geometry: `OrientedBox` (`init(center:axes:halfExtents:)`, `contains(_:tolerance:)`), `Polygon2D.convexHull(_:)`. Support: `LogStore`.

**Apple APIs** (RESEARCH 3.1, read inside the callback only):
```swift
var camera: ARCamera { get }                                   // ARFrame
var timestamp: TimeInterval { get }                            // ARFrame
var transform: simd_float4x4 { get }                           // ARCamera, camera to world
var intrinsics: simd_float3x3 { get }                          // ARCamera, pixels of capturedImage
var imageResolution: CGSize { get }                            // ARCamera
var trackingState: ARCamera.TrackingState { get }              // .notAvailable, .limited(Reason), .normal
```
Depth confidence goes through CaptureCore's `ARFrameReading.meanConfidence(of:)`; no other ARKit call.

**Must NOT do.** Never write a file (coverage is not raw data). Never key coverage by face index across versions or passes (states only from voxels). Never retain an `ARFrame`, `ARAnchor` or ARKit buffer, and never pass the frame to the work queue. Never run grid work on the hub queue, never queue more than one pass, never integrate while the effective rate is 0 (thermal critical) or tracking is not `.normal`. Never call `CleanModelBuilder.buildRoom` or `RoomOutline.build` on live rooms. Never mark windows, doors or openings as expected (D19). Never read MeshStore beyond `index` and `currentChunks()`, never keep chunk arrays after `finishRecording` (D17). No UI, no RealityKit, no Copy.

**Copy strings.** None.

**Self-test.** `CoverageLiveSelfTest.run()`, at least 22 checks, hardware-free (MeshStore is fed through its internal `ingest(_:)` after `beginRecording` into a temporary folder that is removed afterwards; the recorder exposes an internal `ingest(observation:)` and a blocking `waitForWork()` for the test; the ARFrame path is covered on device):
1. `faces(of:)` of a 1 m square chunk (2 triangles, identity transform) gives 2 faces of area 0.5 with the right centroids.
2. A triangle wound against its vertex normals (0, 0, 1) gets normal (0, 0, 1); with zero vertex normals the cross product is kept.
3. A translation of (1, 2, 3) moves centroids and world bounds; a degenerate triangle has area 0 and state gray.
4. `mayBeVisible`: bounds 2 m ahead true, 2 m behind false, 8 m ahead false.
5. `isInView`: a face 2 m ahead facing the camera true, facing away false, 0.1 m away false.
6. `effectiveHz` gives 3 for nominal and fair, 1 for serious, 0 for critical.
7. `isDue` at 3 Hz: 0.2 s after the last false, 0.34 s true, nil last true, hz 0 false.
8. `boundary(from:)` of a 4 x 5 m fixture with 4 walls of 2.5 m and no floor surface: 4 walls, hull area 20 within 1e-3, ceilingY - floorY = 2.5.
9. The same fixture with a floor surface uses its polygon, converted so plan y 3 becomes world z -3.
10. `exclusions(from:)` gives one box per door, window and opening; `expectedPoints` drops the samples inside a 1 x 1 m window (about 25 fewer at 0.2 m spacing).
11. `filtered`: an area centered in a window box is dropped, one 1 m away is kept, a `.window` surface area is dropped.
12. `nearby`: at elapsed 20 s empty; at 40 s an area aged 20 s 2 m away is included, one 4 m away is not, one aged 5 s is not; at most 3, nearest first.
13. `CoverageLiveMissingAges`: an area keeps its age when its centroid moves 0.1 m and resets after it disappears for one evaluation.
14. Three observations 1.5 m in front of the square make its faces green; one observation makes them yellow.
15. `viewCoverage` is 1 after step 14 and nil when the camera looks away.
16. A watched set on the square reads 0 before and 1 after the observations; an unobserved watched point is expected, so its voxel state is red.
17. `anchorFaces(changedSince: 0)` returns the anchor with green states; asking again with the returned revision returns nothing; a new chunk version returns it again; `guidanceHook` applied to an empty `GuidanceInput` sets `viewCoverage`.
18. After `finishRecording`, an ingested observation changes nothing and no anchor arrays remain.
19. Shell fallback: with a boundary and no chunk after 9 s of observations the integrated faces equal the shell samples and the summary says so.
20. `coverageFraction` of a boundary seen from its center in 8 directions is at least 0.9 and `isComplete` is true with no missing area.
21. `CoverageLiveMinimap.make`: one green and one yellow voxel and one unobserved expected sample give codes 3, 2 and 1 in the right cells; a 40 m extent at 0.25 m cells gives cell size 0.5 within 96 cells; a boundary wall at world z 2 lies at plan y -2.
22. `heading`: identity camera (forward -Z) gives pi / 2 (plan +y); a camera looking straight down uses its top edge; the minimap camera of a camera at (1, 1.4, 2) is plan (1, -2).
23. `seed` with 3 observations and a 0 s deadline integrates none; with 1 s it integrates all 3.

**Acceptance checks.** The hub-queue callback copies only (under 0.5 ms when not due, under 2 ms when due, measured and logged once); no `ARFrame` or anchor crosses a queue; one pass in flight at most and skipped passes counted; the effective rate follows `ThermalPolicy.coverageHz`; the per-pass time is logged (target median under 60 ms for 50k visible faces on the A15); no integration after `finishRecording`; readers and hooks take the lock only to copy.

**SPEC owned.** "LIVE SCANNING EXPERIENCE" (GREEN = scanned well, YELLOW = partially scanned, RED = missing information, GRAY = not scanned: the states; "Scan this corner", "Point toward the floor", "Scan the ceiling", "This area needs another pass" through `nearbyMissing` and `viewCoverage`; "Do not overwhelm the user" by the nearby rules above); "SCAN QUALITY SYSTEM" ("Track coverage for surfaces and geometry", live; missing areas during capture).

**TEST_PLAN ids.** LIVE-02, LIVE-05, LIVE-08, LIVE-09, QUAL-02 (live part), QUAL-03 (filled detection), PERF-01, PERF-05 (rate drops at serious), PERF-08.

Lead note after wave 5a (CoverageLive as built): `beginRecording` clears everything except options and the inputs staged while idle (expected boundaries, watched sets and seeds set after the previous recording ended), because MissingAreas sets watched areas before `scan.start()`; `setExpectedRoom` is ignored while not recording.

### 3.31a Coverage revision: extra guidance conditions (wave 5a0, change request CR-9)

**Purpose.** LargeObject's `SectorCoverage` decides "Capture the left side", "Capture the right side", "Capture the back", "Capture the top", "Move closer to this area" and "This section needs more detail", but Coverage's `GuidanceEngine` only shows kinds its own `conditions(for:)` produced, so those decisions could not pass through the display rules (one message, hold, minimum time, repeat cooldown). The revision lets a caller add conditions.

**Build and wave.** Build 5, wave 5a0 (Coverage is wave 0; one small agent, branch `impl/coverage-extras`). Needed by LargeObject (5b); merges before wave 5a starts.

**Files.** `ios/Sources/Coverage/GuidanceEngine.swift`, `CoverageSelfTestGuidance.swift` (edits only).

**Public Swift API.**
```swift
struct GuidanceInput {
    // ... existing members unchanged ...
    /// Conditions decided outside the engine (LargeObject sector coverage). Tier 2 and 3 kinds count
    /// only while tracking is `.normal`, like the engine's own coverage conditions; tier 1 kinds are
    /// ignored here (the engine owns tier 1). Default empty.
    var extraConditions: Set<GuidanceKind> = []
}
```
In `conditions(for:)`, after `guard input.tracking == .normal else { return out }`: `for kind in input.extraConditions where kind.message.tier >= 2 { out.insert(kind) }`. Nothing else changes, so every existing caller compiles and behaves as before.

**Must NOT do.** No change to thresholds, priorities or display rules.

**Self-test.** Extend the Coverage guidance tests by at least 3 checks: an extra `.objectCaptureLeft` is shown after the 0.75 s hold; it is not shown while tracking is `.excessiveMotion`; an extra `.trackingLost` is ignored.

### 3.31b Quality revision: mesh-pass folders (wave 5a0, change request CR-10)

**Purpose.** Show Missing Areas and the two-pass fallback (D16) add sealed mesh-pass folders to a room (`raw/sessions/<s>/mesh-pass/<p>/`). The quality check after the tour and the pipeline's `QualityStep` must see their poses and keyframes, or the pipeline would replace the better score with a room-only one. The consolidated mesh already includes pass chunks once AppShell hands `ConsolidateMeshStep` the pass folders (3.43e).

**Build and wave.** Build 5, wave 5a0 (branch `impl/quality-passes`). Needed by MissingAreas (5b), the ScanUI revision (5c) and AppShell (5d); merges before wave 5a starts.

**Files.** `ios/Sources/Quality/QualityEvaluator+Sealed.swift`, `QualityStep.swift`, `QualitySelfTest+Files.swift` (edits only).

**Public Swift API.**
```swift
extension QualityEvaluator {
    /// `evaluateSealedRoom(package:record:now:)` plus the room's sealed mesh-pass folders, oldest first:
    /// pose samples and keyframe records of all folders concatenated (room first; one ARKit session,
    /// so one timebase), mesh = `MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [room] + passes))`,
    /// log from the room folder, input hash `doneInputHash(seals:)` over the room seal and every pass seal.
    /// With `passes` empty it equals the existing function.
    static func evaluateSealedRoom(package: ProjectPackage, record: RoomRecord, passes: [RawScanFolder],
                                   now: Date) throws -> QualityEvaluation
    /// InputHasher over the seals (nil entries skipped) plus extra ["done"].
    static func doneInputHash(seals: [SealFile?]) -> String
}
final class QualityStep: ProcessingStep {
    /// Mesh-pass folders whose poses and keyframes join the room's.
    let passes: [RawScanFolder]
    /// `passes` defaults to empty, so `QualityStep(room:)` call sites keep compiling.
    init(room: RoomRecord, passes: [RawScanFolder] = [])
}
```
`QualityStep.inputHash(_:)` adds every pass seal to the seals it hashes; the evaluation concatenates poses and keyframes as above and keeps using the consolidated mesh.

**Must NOT do.** Never read a pass folder that has no `SEAL.json`; never let a missing pass folder fail the step (log and skip it).

**Self-test.** At least 4 checks: a temporary room plus one pass with extra keyframes looking at wall 2 raise the walls score over the room alone; the hash with a pass differs from the room-only hash; `passes: []` gives the same evaluation and hash as before; an unsealed pass folder is skipped.

### 3.31c Core change CR-8: minimap camera (applied by the lead before wave 5a)

The Room-mode minimap (CoverageOverlay) needs a "you are here" marker, and `LiveScanSnapshot` carries no camera pose. `MinimapSnapshot` (`ios/Sources/Core/ScanEngine.swift`) gains two optional fields at the end:
```swift
/// Camera position on the plan when the map was made, plan meters; nil when unknown.
var camera: Vec2? = nil
/// Camera heading on the plan, radians counter-clockwise from plan +x; nil when unknown.
var heading: Float? = nil
```
Synthesized `Codable` decodes older recordings without these keys as nil, and the memberwise initializer keeps its existing call sites. `CoreSelfTest` gains 2 checks (round trip with both set; a JSON line without them decodes).

### 3.32 LiveMeshView (wave 5a)

**Purpose.** The mesh-only scan driver and its live camera view, used wherever capture runs without RoomPlan: Show Missing Areas patch passes and the two-pass fallback on the room's still-running session (D16, D19), large objects (D4), and space scans without room finding (AdvancedScan, build 6). `MeshScanEngine` is a `ScanEngine` (D1) over CaptureCore's `ARSessionHub` with the same recorders as a room scan, full Mapper guidance (Coverage's `GuidanceEngine` with speed, distance, light and depth inputs, since no RoomPlan coaching runs), interruptions, system stops (heat, storage, memory) and a finish sequence that seals the pass into `raw/sessions/<s>/mesh-pass/<p>/` or `raw/objects/<o>/`. It can own its hub or borrow a running one and give it back unchanged. `LiveMeshContainer` is the `ARView` in `.ar` mode on the hub's session with Apple's coaching overlay (goal `.tracking`), a tap hook and an `onViewReady` hook where 5b modules attach their RealityKit content (CoverageOverlay, the large-object box). `MeshScanModel` and `LiveMeshScreen` are the `@MainActor` facade and screen shell that MissingAreas, LargeObject and the build 6 space scan build on.

**Build and wave.** Build 5, wave 5a. Core, CaptureCore, Store, MeshRecord, Keyframes, GuidanceUI, Coverage, Pipeline (`IdleTimerGuard`), ScanUI (`Copy.ScanUI.elapsed` only), Support; ARKit, RealityKit, SwiftUI, UIKit. It must not reference CoverageLive or CoverageOverlay (same or later wave): coverage plugs in as an extra `ScanRecorder` plus the two augmenters. About 1450 lines plus the self-test.

**Files.** `ios/Sources/LiveMeshView/MeshScanTypes.swift` (target, result, recorder set, pass folders, settings key), `MeshScanEngine.swift` (public API, stored state, main entry points), `MeshScanEngine+Lifecycle.swift` (hub handlers, status tick, finish sequence), `MeshScanStats.swift` (pure rules), `MeshScanModel.swift`, `LiveMeshContainer.swift`, `LiveMeshScreen.swift`, `LiveMeshViewSelfTest.swift`, `ios/Sources/Support/Copy+LiveMeshView.swift`.

**Public Swift API.**
```swift
extension SettingsKey {
    /// Bool, absent means off. Diagnostics only: ARKit's scene-understanding wireframe in live views.
    static let liveMeshDebugView = "liveMeshDebugView"
}

/// What one mesh-only pass records and where it is sealed.
struct MeshScanTarget: Equatable, Sendable {
    var projectID: UUID
    var package: ProjectPackage
    /// ARKit session (raw/sessions/<id>/, FrameLink.projectFrame).
    var sessionID: UUID
    /// InProgress scan id and sealed folder name; the object id for `.object`.
    var passID: UUID
    /// `.meshPass` or `.object`.
    var kind: RawScanKind
    /// Profile mode and scan.json mode: room, house or advancedSpace for `.meshPass`; object or
    /// advancedObject for `.object`. Never quickMeasure (D14).
    var mode: ScanMode
    /// The room a patch pass or fallback pass belongs to (scan.json `roomID`).
    var roomID: UUID?
    /// `package.rawMeshPassURL(session:pass:)` or `package.rawObjectURL(_:)`.
    var destination: URL
    var settings: ScanSettings
    init(projectID: UUID, package: ProjectPackage, sessionID: UUID, passID: UUID, kind: RawScanKind,
         mode: ScanMode, roomID: UUID?, destination: URL, settings: ScanSettings)
    /// A pass on a room's session (Show Missing Areas, two-pass fallback). Pass the room's own mode
    /// and settings, so a borrowed hub keeps its profile.
    static func patchPass(projectID: UUID, package: ProjectPackage, sessionID: UUID, roomID: UUID,
                          mode: ScanMode, settings: ScanSettings, passID: UUID = UUID()) -> MeshScanTarget
    /// A large object (kind .object, mode .object, passID = objectID).
    static func largeObject(projectID: UUID, package: ProjectPackage, sessionID: UUID, objectID: UUID,
                            settings: ScanSettings) -> MeshScanTarget
    /// A space scan without room finding (kind .meshPass, mode .advancedSpace, no room).
    static func spaceScan(projectID: UUID, package: ProjectPackage, sessionID: UUID, settings: ScanSettings,
                          passID: UUID = UUID()) -> MeshScanTarget
}

/// What a finished pass produced; `MeshScanEngine.lastResult` after `.roomFinished(roomID: passID)`.
struct MeshScanResult: Equatable, Sendable {
    var passID: UUID
    var kind: RawScanKind
    var roomID: UUID?
    var sealedFolder: RawScanFolder
    /// roomlog.json of the pass (instructionSeconds empty, error nil unless a system stop).
    var log: RoomCaptureLog
    var keyframeCount: Int
    var photoCount: Int
    var meshFaceCount: Int
    var frameLink: FrameLink
    var capturedAt: Date
    /// The engine finished by itself (heat, storage, memory) and paused the session.
    var stoppedBySystem: Bool
}

/// The standard recorders of a mesh-only pass. Creating them touches no hardware.
struct MeshScanRecorderSet {
    let mesh: MeshStore
    let keyframes: KeyframeRecorder
    let poses: PoseTrackRecorder
    let photos: PhotoRecorder?
    /// Extra recorders (CoverageLiveRecorder, LargeObjectTracker), fed after the standard ones.
    var extra: [ScanRecorder]
    /// `mesh` is passed in so extras made first can read the same store
    /// (`CoverageLiveRecorder(meshSource: mesh)`).
    init(photos: Bool, mesh: MeshStore = MeshStore(), extra: [ScanRecorder] = [])
    /// mesh, keyframes, poses, photos (when present), then `extra`.
    var all: [ScanRecorder] { get }
}

/// Finding a room's sealed mesh passes (AppShell's processing plans, MissingAreas, the Quality revision's callers).
enum MeshPassFolders {
    /// Sealed folders under raw/sessions/*/mesh-pass/ whose scan.json has kind `.meshPass` and this
    /// roomID, oldest `startedAt` first. Unreadable scan.json files are skipped and logged.
    static func forRoom(_ roomID: UUID, in package: ProjectPackage) -> [RawScanFolder]
    /// Sealed mesh-pass folders without a room (space scans), oldest first.
    static func spacePasses(in package: ProjectPackage) -> [RawScanFolder]
}

/// Mesh-only engine. Call the ScanEngine methods on main; work runs on hub.queue; events arrive on
/// main. `state` and `lastResult` are written on main only, in the same main hop that emits the
/// matching event; hub.queue keeps a private phase copy. Not `@MainActor` (only the listed members).
final class MeshScanEngine: ScanEngine {
    static let logCategory = "meshscan"
    /// Seconds without a frame while scanning before the engine re-applies the configuration once.
    static let frameGapSeconds: Double = 1.5
    /// Seconds to wait for each recorder's `finishRecording`.
    static let recorderFinishTimeout: Double = 20
    private(set) var state: ScanEngineState
    var onEvent: ((ScanEngineEvent) -> Void)?
    let hub: ARSessionHub
    let target: MeshScanTarget
    let recorders: [ScanRecorder]
    /// True when this engine created the hub (it pauses it in teardown); false for a borrowed hub.
    let ownsHub: Bool
    /// Main. Valid after `.roomFinished`.
    private(set) var lastResult: MeshScanResult?
    /// Hub queue hooks (lock-protected get and set): adjust the guidance input before
    /// `GuidanceEngine.update`, and each snapshot before it is posted. Callers pass closures formed
    /// outside any actor (`CoverageLiveRecorder.guidanceHook`, `snapshotHook`, or a nonisolated
    /// static helper), never a closure written inside a `@MainActor` method.
    var guidanceAugmenter: ((inout GuidanceInput) -> Void)?
    var snapshotAugmenter: ((inout LiveScanSnapshot) -> Void)?
    /// Latest camera to world (any thread; updated at most 10 times a second from frames).
    var latestCameraTransform: simd_float4x4? { get }
    /// Main actor (creates the hub when `hub` is nil). Nothing runs until `start()`.
    @MainActor init(target: MeshScanTarget, recorders: [ScanRecorder], hub: ARSessionHub? = nil)
    /// Main. Checks, folders, hub, recorders (order below). Throws before creating anything on disk
    /// when a check fails: `.ioFailed(problem)` for an invalid target, `.unsupportedDevice`,
    /// `.lowStorage(freeBytes:)` under `ProjectStore.refuseScanBelowBytes`.
    func start() throws
    /// Main. State `.paused`, keyframes paused (the session keeps running). Used for interruptions.
    func pause()
    /// Main. Back to `.scanning`; after `sessionInterruptionEnded` the engine stays `.paused` until this call.
    func resume()
    /// Main. `finish(attachments: [:])`.
    func finish()
    /// Main. The finish sequence below; `attachments` are small extra files written into the folder
    /// root before the seal (names checked by `MeshScanStats.isSafeAttachmentName`), for example LargeObject's log.
    func finish(attachments: [String: Data])
    /// Main. Ordered stop without sealing (recorders detached and finished, writer flushed and
    /// closed); raw stays in InProgress for recovery; then `.stateChanged(.idle)`.
    func cancel()
    /// Main. `cancel()`'s ordered stop, then `InProgressScans.discard(scanID:)` once the writer is
    /// closed, then `.stateChanged(.idle)`.
    func discard()
    /// Main, idempotent, safe in any state: a capture still running gets `cancel()`'s ordered stop;
    /// recorders are detached; the four hub closures are restored to the ones saved at `start()` for
    /// a borrowed hub (nil for an owned hub); a borrowed hub gets `install()` again and keeps running,
    /// an owned hub is paused. Logs "mesh engine deinit" when released.
    func teardown()
}

/// Pure rules (tested).
enum MeshEngineSignal: Equatable, Sendable { case start, firstFrame, pause, interruptionEnded, resume, finish, sealed, failure, cancel }
enum MeshFinishStep: String, CaseIterable, Sendable {
    case detachRecorders, finishRecorders, writeAttachments, writeLogs, flushWriter, closeWriter, seal,
         pauseIfSystemStop, emitRoomFinished
}
enum MeshScanStats {
    static func next(_ state: ScanEngineState, on signal: MeshEngineSignal) -> ScanEngineState
    /// The finish sequence in order (tested as data).
    static let finishSteps: [MeshFinishStep]
    /// Mesh-mode input: tracking (`GuidanceSignals.tracking(status.tracking)`), angularSpeed, linearSpeed,
    /// centerDistance, depthConfidenceMean, ambientIntensity from the status, deviceHot at thermal
    /// serious or worse. Everything RoomScanStats leaves out in Room mode is set here (no RoomPlan coaching).
    static func guidanceInput(time: Double, status: HubStatus) -> GuidanceInput
    static func snapshot(timestamp: Double, status: HubStatus, recorders: RecorderStats, guidance: GuidanceKind?) -> LiveScanSnapshot
    /// thermal .critical -> .deviceTooHot, storage .pause -> .lowStorage(freeBytes: 0) (the caller
    /// fills the bytes), memory .critical -> .lowMemory, else nil.
    static func systemStopReason(thermal: ThermalLevel, storage: StorageState, memory: MemoryState) -> MapperError?
    /// Nil when valid: kind and mode agree (meshPass with room, house or advancedSpace; object with
    /// object or advancedObject), `destination` equals the package URL for the kind, session and passID.
    static func validationProblem(_ target: MeshScanTarget) -> String?
    /// The start checks as one pure rule: `.ioFailed(problem)` for an invalid target, then
    /// `.unsupportedDevice` without mesh support, then `.lowStorage(freeBytes:)` under
    /// `ProjectStore.refuseScanBelowBytes`; nil when capture may start.
    static func startProblem(_ target: MeshScanTarget, supportsMesh: Bool, freeBytes: Int64) -> MapperError?
    /// True only for an owned hub (teardown pauses it); a borrowed hub keeps running.
    static func pausesHubOnTeardown(ownsHub: Bool) -> Bool
    /// True once per gap: scanning, a previous frame known, and more than `frameGapSeconds` since it.
    static func shouldReapplyForFrameGap(now: Double, lastFrame: Double?, triedForThisGap: Bool, isScanning: Bool) -> Bool
    /// A single safe file name (RawScanFolder.isSafeRelativePath, no "/") that is not a name the
    /// engine or a recorder writes: SEAL.json, scan.json, roomlog.json, events.jsonl, keyframes.jsonl,
    /// photos.jsonl, poses.ptrk.
    static func isSafeAttachmentName(_ name: String) -> Bool
    static func log(seconds: Double, relocalizations: Int, limitedFraction: Double, degraded: DegradedMode,
                    error: String?) -> RoomCaptureLog
}

/// Main-actor facade for mesh-only screens (MissingAreas, LargeObject, build 6 space scans).
@MainActor final class MeshScanModel: ObservableObject {
    @Published private(set) var state: ScanEngineState
    @Published private(set) var snapshot: LiveScanSnapshot
    @Published private(set) var result: MeshScanResult?
    /// Latest `.failed` error, for the owner's alert (ScanUI's `ScanErrorCopy.alert(for:)`).
    @Published private(set) var failure: MapperError?
    @Published private(set) var isPaused: Bool
    let engine: MeshScanEngine
    /// After `.roomFinished` (the pass is sealed).
    var onFinished: ((MeshScanResult) -> Void)?
    /// After cancel or discard completed (`.stateChanged(.idle)`).
    var onIdle: (() -> Void)?
    init(engine: MeshScanEngine, photos: PhotoRecorder? = nil)
    /// `engine.start()`, an `IdleTimerGuard` token, `GuidanceAnnouncer` reset.
    func start() throws
    func finish(attachments: [String: Data] = [:])
    func pause(); func resume(); func cancel(); func discard()
    /// `engine.teardown()` and the token released; idempotent.
    func teardown()
    func takePhoto()
    /// `Copy.ScanUI.elapsed(minutes:seconds:)` of `snapshot.elapsed`.
    var elapsedText: String { get }
}

/// SwiftUI host of the live camera: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`,
/// then `arView.session = hub.session` and `hub.install()` at once (whoever assigns last wins; the hub
/// logs `session.delegate === hub`), `environment.sceneUnderstanding.options = []`, the debug
/// wireframe only when `SettingsKey.liveMeshDebugView` is on, `ARCoachingOverlayView` (session, goal
/// `.tracking`, activatesAutomatically) on top, a tap recognizer, then `onViewReady`.
/// `dismantleUIView` removes the recognizer and the coaching overlay, gives the ARView a fresh idle
/// `ARSession()` so the departing view can never pause or reconfigure the hub's session (a borrowed
/// hub must keep running for the room engine: the next room, a second tour), then calls
/// `hub.install()` again (as `HouseRelocalizationView`, 3.41). It never pauses the session.
struct LiveMeshContainer: UIViewRepresentable {
    init(hub: ARSessionHub, showsCoaching: Bool = true, onViewReady: (@MainActor (ARView) -> Void)? = nil,
         onTap: (@MainActor (CGPoint, ARView) -> Void)? = nil)
    func makeCoordinator() -> LiveMeshCoordinator
    func makeUIView(context: Context) -> ARView
    func updateUIView(_ uiView: ARView, context: Context)
    static func dismantleUIView(_ uiView: ARView, coordinator: LiveMeshCoordinator)
}
@MainActor final class LiveMeshCoordinator: NSObject {
    var onTap: (@MainActor (CGPoint, ARView) -> Void)?
    /// Target of the UITapGestureRecognizer; passes `location(in:)` of the ARView.
    @objc func handleTap(_ recognizer: UITapGestureRecognizer)
}

/// Screen shell: camera (LiveMeshContainer), guidance banner (`GuidanceBanner(kind: snapshot.guidance)`),
/// the "starting up" line while `.starting`, the paused card (`Copy.Scanning.paused` with Resume) while
/// paused, and the caller's HUD on top. Forced dark, `.persistentSystemOverlays(.hidden)`, HUD Dynamic
/// Type clamped to xxxLarge.
struct LiveMeshScreen<HUD: View>: View {
    init(model: MeshScanModel, showsCoaching: Bool = true, onViewReady: (@MainActor (ARView) -> Void)? = nil,
         onTap: (@MainActor (CGPoint, ARView) -> Void)? = nil, @ViewBuilder hud: @escaping () -> HUD)
}
/// Standard top bar for mesh-only screens: Cancel (left), elapsed time (center), Done (right, hidden when `onDone` is nil).
struct LiveMeshTopBar: View {
    init(elapsed: String, doneEnabled: Bool, onCancel: @escaping () -> Void, onDone: (() -> Void)?)
}
```

Start order (`start()`, main):
1. `MeshScanStats.startProblem(target, supportsMesh: ScanConfigurationFactory.supportsMesh, freeBytes: ProjectStore.freeBytes())` (throws before touching disk).
2. `ProjectStore.ensureDirectory(target.package.sessionURL(target.sessionID), inside: target.package.root)`; `InProgressScans.create(InProgressScanInfo(scanID: target.passID, projectID: target.projectID, sessionID: target.sessionID, roomID: target.kind == .object ? target.passID : target.roomID, kind: target.kind, mode: target.mode, startedAt: Date()))` (an object scan carries its object id in `roomID`, as ObjectCapture's does, so AppShell's recovery reads one field); `RawScanWriter(folder:)`. An IO failure removes what was made and throws `.ioFailed`.
3. Owned hub: `hub.install()`, `hub.run()`. Borrowed hub: save its four closures (`onCaptureEvent`, `onStatus`, `onFrame`, `onMemoryPressure`, lock-protected getters), `hub.install()`, then `hub.reapplyConfiguration(reason: "mesh pass start")` when `hub.isRunning`, else `hub.run()`. The re-apply restores mesh and depth after RoomPlan (the two-pass fallback for `meshStripped` relies on it) and is safe because RoomPlan is stopped; the options stay `[]`, so tracking, anchors and the world frame are kept (RESEARCH 3.1 gotcha 12). The profile of a borrowed hub is not changed (the target carries the room's own mode and settings).
4. The engine's four closures with `[weak self]`.
5. On hub.queue: attach every recorder and call `beginRecording(into:profile:startTimestamp:)` (latest frame timestamp or 0); state `.starting`.
6. First frame after start: `hub.markScanStart(timestamp:)`, state `.scanning`.

Each status tick (4 Hz, hub queue): a system stop reason (`systemStopReason`, the storage case with `status.freeBytes`) finishes the pass by itself; memory `.low` is logged once per episode (keyframes stop inside KeyframeRecorder); otherwise `guidanceInput` plus `guidanceAugmenter`, `GuidanceEngine.update`, `snapshot` from the status and the summed recorder stats, `snapshotAugmenter`, then `.snapshot` on main. The frame gap rule re-applies the configuration once per gap (for example after the RoomPlan objects of a borrowed session were released) and logs it. Interruptions come as `.tracking` events with `ARSessionHub.interruptedDetail` (state `.paused`, keyframes paused) and `interruptionEndedDetail` (stays paused until `resume()`); `sessionFailedPrefix` errors finish the pass with what exists and report `.trackingFailed` after `.roomFinished`. `hub.onMemoryPressure` flushes every recorder (`flushNow()`) and finishes the pass as a system stop with `.lowMemory`. Pause and resume set `KeyframeRecorder.isPaused` on any `KeyframeRecorder` among the recorders.

Finish sequence (`MeshScanStats.finishSteps`, one `Task` inside `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`, ended at the last step or on expiry; `UIApplication.shared` is main-actor only and the engine is not, so the task is begun and ended inside `await MainActor.run { }` with the identifier kept as its raw value behind a lock, the pattern of RoomCapture's `RoomBackgroundTask`, which this module cannot import):
1. `detachRecorders` on hub.queue, so no callback arrives after it.
2. `finishRecorders`: each `finishRecording(completion:)` awaited with `withCheckedContinuation`, at most `recorderFinishTimeout` each (every recorder flushes and closes its own `RawScanWriter`, so this must complete before the seal).
3. `writeAttachments`: each safe name written with `writer.writeFile(_:to:)` at the folder root.
4. `writeLogs`: `roomlog.json` (`MeshScanStats.log`, relocalizations and limited fraction from `hub.tracking`, degraded from `hub.degraded`), the remaining `events.jsonl` lines, and `raw/sessions/<s>/session.json` from `hub.diagnostics.sessionRecord(id:)` only when `package.sessionRecordURL(sessionID)` does not exist yet.
5. `flushWriter` (`await writer.flush()`), 6. `closeWriter`, 7. `seal` (`InProgressScans.seal(folder, into: target.destination, package: target.package)`), 8. `pauseIfSystemStop` (`hub.pause()` for a system stop, borrowed hub included, RESEARCH 3.1 recommended 10), 9. `emitRoomFinished` (main: `lastResult`, state `.finished`, `.roomFinished(roomID: target.passID)`, then `.failed(reason)` for a system stop; state stays `.finished`).
No file is written into the folder after `SEAL.json`. `cancel()` and `discard()` emit no `.stopping`, only `.stateChanged(.idle)` last (as RoomCapture).

A borrowed hub is given back as it was lent: same session still running (unless a system stop paused it), same profile, the saved closures restored, recorders detached, delegate re-asserted. Its owner (RoomScanEngine) must stay alive, and its `RoomCaptureView` mounted, until the borrowing engine is torn down (ScanUI revision, 3.43a).

**Uses.** CaptureCore: `ARSessionHub` (`init(profile:)`, `install()`, `run(options:)`, `pause()`, `isRunning`, `reapplyConfiguration(reason:)`, `attach(_:)`, `detach(_:)`, `markScanStart(timestamp:)`, `queue`, `onCaptureEvent`, `onStatus`, `onFrame`, `onMemoryPressure`, `tracking`, `degraded`, `diagnostics`, `interruptedDetail`, `interruptionEndedDetail`, `sessionFailedPrefix`), `ScanRecorder` (`flushNow()`), `ScanProfile`, `HubStatus`, `RecorderStats`, `ThermalLevel`, `StorageState`, `MemoryState`, `ScanConfigurationFactory.supportsMesh`, `CaptureDiagnostics.sessionRecord(id:)`, `TrackingMonitor` (`relocalizations`, `limitedFraction`). Store: `InProgressScans` (`create`, `seal(_:into:package:)`, `discard(scanID:)`), `InProgressScanInfo`, `RawScanKind`, `RawScanWriter` (`appendJSONLine`, `writeFile`, `flush()`, `close()`), `RawScanReader.info()`, `StorePackageOps.meshPassFolders(in:)`. MeshRecord: `MeshStore`. Keyframes: `KeyframeRecorder` (`init(jpegQuality:)`, `isPaused`), `PoseTrackRecorder`, `PhotoRecorder` (`requestPhoto(note:)`). GuidanceUI: `GuidanceSignals.tracking(_:)` (summary form), `GuidanceBanner`, `GuidanceAnnouncer` (`present(_:now:)`, `reset()`). Coverage: `GuidanceEngine`, `GuidanceInput`. Pipeline: `IdleTimerGuard.acquire(_:)`, `release(_:)`. Core: `ScanEngine`, `ScanEngineState`, `ScanEngineEvent`, `LiveScanSnapshot`, `MapperError`, `RoomCaptureLog`, `DegradedMode`, `CaptureEvent`, `CaptureEventKind`, `FrameLink`, `ProjectPackage` (`sessionURL(_:)`, `sessionRecordURL(_:)`, `rawMeshPassURL(session:pass:)`, `rawObjectURL(_:)`), `RawScanFolder` (`isSafeRelativePath(_:)`, `eventsLogURL`, `roomLogURL`, `sealURL`), `ScanMode`, `ScanSettings`, `ProjectStore` (`freeBytes()`, `refuseScanBelowBytes`, `ensureDirectory(_:inside:)`, `encoder`). Support: `Copy.Scanning` (`paused`, `resume`, `startingUp`, `done`, `cancel`), `Copy.A11y.scanView`, `Copy.ScanUI.elapsed(minutes:seconds:)` (3.24), `SettingsKey`, `LogStore`.

**Apple APIs** (RESEARCH 3.5, 3.10, 3.1):
```swift
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)   // ARView, .ar
dynamic var session: ARSession { get set }                       // ARView; assign hub.session, then hub.install()
var debugOptions: ARView.DebugOptions                            // ARView
static let showSceneUnderstanding: ARView.DebugOptions            // 13.4, Diagnostics only
var environment: ARView.Environment
var sceneUnderstanding: ARView.Environment.SceneUnderstanding { mutating get set }   // options stay [] (no .occlusion)
class ARCoachingOverlayView                                      // iOS 13.0: goal, activatesAutomatically, setActive(_:animated:)
func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])   // through the hub only, options []
@MainActor @preconcurrency protocol UIViewRepresentable : View   // makeUIView, updateUIView, makeCoordinator,
                                                                 // static func dismantleUIView(_ uiView: Self.UIViewType, coordinator: Self.Coordinator)
nonisolated func persistentSystemOverlays(_ visibility: Visibility) -> some View
func dynamicTypeSize<T>(_ range: T) -> some View where T : RangeExpression, T.Bound == DynamicTypeSize
```
Not in RESEARCH (checked against Apple's documentation JSON, all iOS 13.0 or earlier): `var session: ARSession? { get set }` and `var goal: ARCoachingOverlayView.Goal { get set }` (`.tracking`) on `ARCoachingOverlayView`; `ARSession()` (iOS 11, the idle session given to a dismantled view); `UITapGestureRecognizer(target:action:)` and `location(in:)` (iOS 3.2); `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` and `endBackgroundTask(_:)` (iOS 4, main).

**Must NOT do.** Plane detection stays off (D14): a target with mode `.quickMeasure` is invalid. Never create a second `ARSession` for a patch pass (borrow the room's hub; one session keeps one frame). Never pass reset run options. Never pause a borrowed hub except for a system stop, and never leave a borrowed hub's closures replaced after `teardown()`. Never show `.showSceneUnderstanding` as the user-facing view and never enable `.occlusion` (it would z-fight the coverage overlay, RESEARCH 3.5). Never write outside the InProgress folder except `session.json`, never write after `SEAL.json`, never emit `.roomFinished` before the seal. Never retain an `ARFrame` or anchor. No `ARView(frame:cameraMode:)` 2-argument init. Never import RoomPlan, CoverageLive or CoverageOverlay. Never mark the engine `@MainActor` (only the listed members). Never write `isIdleTimerDisabled` (IdleTimerGuard). No hardcoded text.

**Copy strings.** Existing: `Copy.Scanning.paused`, `resume`, `startingUp`, `done`, `cancel`, `addPhoto`, `photoSaved`; `Copy.A11y.scanView`, `doneScanning`; `Copy.ScanUI.elapsed(minutes:seconds:)`; guidance through `GuidanceKind.message`. New (`extension Copy { enum LiveMeshView }` in `Copy+LiveMeshView.swift`): `saving = "Saving your scan..."`, `debugViewToggle = "Show Scanner Debug View"`, `debugViewFooter = "Draws the scanner's raw output over the camera. For troubleshooting only."` (the last two for AppShell's Diagnostics screen).

**Self-test.** `LiveMeshViewSelfTest.run()`, at least 18 checks:
1. `next`: idle + start = starting; starting + firstFrame = scanning; scanning + pause = paused; paused + interruptionEnded = paused; paused + resume = scanning.
2. `next`: scanning + finish = stopping; stopping + sealed = finished; scanning + failure = failed; scanning + cancel = idle; finished + failure = finished (a notice after the seal).
3. `finishSteps` is exactly the 9 steps in order, with `seal` after `closeWriter` and `emitRoomFinished` last.
4. `guidanceInput` copies tracking, angular and linear speed, center distance, depth confidence and ambient intensity from a `HubStatus`, and sets deviceHot at serious and critical only.
5. `snapshot` takes mesh faces, keyframes and photos from `RecorderStats`, plus thermal, degraded, tracking, elapsed and the guidance raw value.
6. `systemStopReason` for thermal critical, storage pause, memory critical and all good.
7. `validationProblem` is nil for `patchPass` and `largeObject` targets, and not nil for kind `.object` with a mesh-pass destination, for a destination outside the package, for mode `.quickMeasure`, and for kind `.meshPass` with mode `.object`.
8. `patchPass` sets kind `.meshPass`, the room id and `rawMeshPassURL(session:pass:)`; `largeObject` sets passID = objectID and `rawObjectURL(_:)`.
9. `shouldReapplyForFrameGap`: 1.6 s after the last frame while scanning true; already tried false; paused false; no frame yet false.
10. `isSafeAttachmentName`: "largeobject.json" true; "../x", "a/b.json", "", "SEAL.json", "roomlog.json" false.
11. `log(...)` fills a `RoomCaptureLog` with empty instruction seconds.
12. `MeshScanRecorderSet(photos: true, extra: [one])`.all has 5 recorders in order; `photos: false` has 4 without a PhotoRecorder; a passed-in `mesh` is the first recorder (identity).
13. `MeshPassFolders.forRoom` in a temporary package: two sealed passes for room A (started t2 and t1) and one for room B, plus an unsealed one for A, return the two sealed A folders in t1, t2 order.
14. `spacePasses` returns only the sealed pass without a room.
15. A scan.json larger than `InProgressScanInfo.maxBytes` or unreadable is skipped.
16. `LiveMeshTopBar` and screen strings are non-empty (`Copy.LiveMeshView` members).
17. `pausesHubOnTeardown(ownsHub:)` is true only when owned.
18. `startProblem`: an invalid target gives `.ioFailed`, no mesh support gives `.unsupportedDevice`, 1 GB free gives `.lowStorage`, a valid target with 5 GB free gives nil (the engine's `start()` calls this before touching disk; the self-test never creates a hub, whose initializer is main actor).

**Acceptance checks.** The engine mirrors RoomCapture's queue discipline (state on main, private phase on hub.queue, value copies only); every hub closure captures `[weak self]`; a borrowed hub is returned with its saved closures, running, and its delegate re-asserted (log lines "hub lent" and "hub returned"); two passes in a row log two "mesh engine deinit" lines and, for owned hubs, two "hub deinit" lines; the finish sequence awaits every recorder before the seal; nothing is written after `SEAL.json`; the delegate identity is logged after the ARView takes the session and again after the container is dismantled (with `hub.isRunning`, which stays true for a borrowed hub); the debug wireframe appears only with the Diagnostics key.

**SPEC owned.** "LIVE SCANNING EXPERIENCE" in mesh-only scans ("The user should see the model forming while walking", with the overlay attached through `onViewReady`; "Move slower", "Move closer", "Too close", "Too far", "Tracking quality is low", "Lighting is poor" from Mapper's own guidance); "SCAN QUALITY SYSTEM" (the patch-pass driver behind SHOW MISSING AREAS); "OBJECT SCANNING" (the large-object driver); "ADVANCED SCAN" (the space-scan driver used in build 6); D16 two-pass fallback driver.

**TEST_PLAN ids.** LIVE-01 (mesh-only), LIVE-03, LIVE-04, LIVE-07, LIVE-10, QUAL-03, MODE-07 (build 6 space scan), PERF-05, PERF-06, PERF-14 (camera off after teardown), PERF-16, PERF-20, PERF-26 (recovery through AppShell).

### 3.33 ObjectCapture (wave 5a)

**Purpose.** Small and medium objects (D4) with Apple Object Capture: a port of Apple's GuidedCapture flow (REUSE 2.1) around `ObjectCaptureSession` and `ObjectCaptureView`, and on-device reconstruction with `PhotogrammetrySession`. It owns the capture model (`ObjectScanModel`, one session per scan, never reused after `.completed` or `.failed`), fresh empty `Images/` and `Checkpoint/` folders inside the scan's InProgress folder (D5; RESEARCH 3.3 gotcha 2), the three-pass onboarding state machine (flip or not), the capture screen with Mapper's controls over Apple's view and the review sheet with `ObjectCapturePointCloudView`, the Object Capture preflight (support and 3 GB free, D18), `objectlog.json` with the runtime limits, sealing (checkpoint moved to `derived/objects/<id>/checkpoint/`, CR-5, then `Images/` and `objectlog.json` sealed into `raw/objects/<id>/`), `PhotogrammetryStep` (`reconstructObject`, only the default `.reduced` detail, the capture's checkpoint reused), its progress for ObjectUI, and `reconstructionPending` clearing (D17).

**Build and wave.** Build 5, wave 5a. Core, Store, GuidanceUI, Pipeline (`ProcessingGuards.availableMemory()` only), Support; RealityKit and SwiftUI (every file that names an Object Capture or photogrammetry type imports both, CI lesson 0.2.13), Combine. About 1450 lines excluding the self-test.

**Files.** `ios/Sources/ObjectCapture/ObjectScanModel.swift`, `ObjectScanModel+Session.swift` (update tasks, log), `ObjectScanFolders.swift`, `ObjectOnboarding.swift`, `ObjectCaptureSignals.swift` (state, error and feedback mapping, preflight), `ObjectScanScreen.swift`, `PhotogrammetryStep.swift`, `PhotogrammetryStore.swift` (paths, info, progress, monitor), `ObjectCaptureSelfTest.swift`, `ios/Sources/Support/Copy+ObjectCapture.swift`.

**Public Swift API.**
```swift
// MARK: Types (ObjectScanModel.swift, ObjectCaptureSignals.swift)

struct ObjectScanTarget: Equatable, Sendable {
    var projectID: UUID
    var package: ProjectPackage
    /// The `ObjectRecord.id` the scan will become (also `InProgressScanInfo.roomID`, which
    /// carries the object id for `kind == .object`).
    var objectID: UUID
}

/// Mapper's copy of `ObjectCaptureSession.CaptureState` without the error payload.
enum ObjectCaptureStage: String, Equatable, Sendable {
    case initializing, ready, detecting, capturing, finishing, completed, failed
}

/// Why a capture stopped (from `ObjectCaptureSession.Error`, RESEARCH 3.3).
enum ObjectScanFailure: Equatable, Sendable {
    case cancelled, directoryNotEmpty, insufficientStorage(requiredBytes: Int64), sensorFailed, trackingFailed
    /// Any other error; the payload is for the log only.
    case other(String)
}

/// Contents of `objectlog.json`: capture diagnostics and the device's runtime limits.
struct ObjectCaptureLog: Codable, Equatable, Sendable {
    static let fileName = "objectlog.json"
    var objectID: UUID
    var startedAt: Date
    var seconds: Double
    var shotCount: Int
    /// `ObjectCaptureSession.maximumNumberOfInputImages` read after `start`.
    var maximumNumberOfInputImages: Int
    /// `PhotogrammetrySession.limits` (device-specific, RESEARCH 3.3 disputed 4).
    var photogrammetryMaxImages: Int
    var photogrammetryMaxImageDimension: Int
    var passes: Int
    var flips: Int
    /// Seconds each feedback case was present, keyed by `ObjectCaptureSignals.name(of:)`.
    var feedbackSeconds: [String: Double]
    var trackingLimitedSeconds: Double
    var detectionFailures: Int
    /// Last stage name and the failure, when any (logs only).
    var finalStage: String
    var failure: String?
    var thermalAtStart: String
    var thermalAtEnd: String
    var freeBytesAtStart: Int64
    var availableMemoryAtStart: UInt64
    var osVersion: String
}

struct ObjectScanResult: Equatable, Sendable {
    var objectID: UUID
    /// `raw/objects/<id>/` after sealing.
    var sealedFolder: URL
    /// Image files sealed under `Images/`.
    var imageCount: Int
    var log: ObjectCaptureLog
}

enum ObjectScanPhase: Equatable, Sendable {
    case idle, capturing, reviewing, finishing, sealing
    case done(ObjectScanResult)
    /// The session failed; `imageCount` photos are on disk (Use These Photos needs at least
    /// `ObjectScanFolders.minimumImages`).
    case failed(ObjectScanFailure, imageCount: Int)
    case cancelled
}

enum ObjectPreflightIssue: Equatable, Sendable { case unsupported, lowStorage(free: Int64), deviceHot, deviceWarm }
struct ObjectPreflightReport: Equatable, Sendable { var blocking: ObjectPreflightIssue?; var warnings: [ObjectPreflightIssue] }

enum ObjectCapturePreflight {
    /// Pure. Blocking: either API unsupported, free space below
    /// `ProjectStore.objectCapturePreflightBytes` (3 GB, D18), thermal `.critical`. Warning:
    /// thermal `.serious`. Camera permission, battery and LiDAR are ScanUI's `ScanPreflight`.
    static func evaluate(captureSupported: Bool, photogrammetrySupported: Bool, freeBytes: Int64,
                         thermal: ThermalLevel) -> ObjectPreflightReport
    /// Reads `ObjectCaptureSession.isSupported` (main actor), `PhotogrammetrySession.isSupported`,
    /// `ProjectStore.freeBytes()` and the thermal state (RESEARCH 3.3 gotcha 1: check before
    /// creating a session).
    @MainActor static func run() -> ObjectPreflightReport
}

/// Lock-protected counters, any thread (`ObjectCaptureSignals.swift`), so an `ObjectCaptureSession`
/// and a `PhotogrammetrySession` never live at the same time (RESEARCH 3.3 gotcha 10): neither when
/// a finished capture hands over to the pipeline, nor when a new capture starts while
/// `ProcessingRunner.suspendAll` is still cancelling a reconstruction (it only flags the step, and
/// `PhotogrammetrySession.cancel()` is asynchronous, gotcha 9).
enum ObjectCaptureActivity {
    /// Sessions ObjectScanModel holds: +1 right after `ObjectCaptureSession()`, -1 when `teardown`
    /// releases it.
    static var captureSessions: Int { get }
    /// Sessions alive in PhotogrammetryStep: +1 right before `PhotogrammetrySession(input:configuration:)`,
    /// -1 after the output loop ended and the session reference was dropped (every exit path).
    static var reconstructionSessions: Int { get }
    static func captureStarted()
    static func captureReleased()
    static func reconstructionStarted()
    static func reconstructionEnded()
    /// Polls every 0.25 s until `reconstructionSessions == 0` or `timeout` seconds passed; true when
    /// idle. AppShell awaits it before any capture cover starts its flow (3.43e).
    static func waitForNoReconstruction(timeout: Double) async -> Bool
}

/// Pure mappings, nonisolated (the self-test builds these enum values; no session is created).
enum ObjectCaptureSignals {
    static func stage(_ state: ObjectCaptureSession.CaptureState) -> ObjectCaptureStage
    /// `ObjectCaptureSession.Error` cases one to one; anything else `.other(localizedDescription)`.
    static func failure(_ error: any Error) -> ObjectScanFailure
    /// Stable log names ("movingTooFast", ...), distinct for the nine cases.
    static func name(of feedback: ObjectCaptureSession.Feedback) -> String
    static func isNormal(_ tracking: ObjectCaptureSession.Tracking) -> Bool
    static func containsNotFlippable(_ feedback: Set<ObjectCaptureSession.Feedback>) -> Bool
    static func containsOverCapturing(_ feedback: Set<ObjectCaptureSession.Feedback>) -> Bool
}

// MARK: Onboarding (ObjectOnboarding.swift): three passes, as Apple recommends

enum ObjectOnboardingState: Equatable, Sendable {
    case firstSegment                     // first lap at chest height
    case reviewFirst                      // lap 1 done: flip, or scan lower
    case flipObject                       // after beginNewScanPassAfterFlip: new box, second lap
    case captureFromLowerAngle            // second lap, lower
    case reviewSecond(flipped: Bool)      // lap 2 done
    case flipObjectAgain                  // third lap after a second flip
    case captureFromHigherAngle           // third lap, higher, capture the top
    case done                             // all laps done: only Done remains
}
enum ObjectOnboardingEvent: Equatable, Sendable { case passCompleted, chooseFlip, chooseNoFlip, finishTapped }
enum ObjectPassCommand: Equatable, Sendable { case none, beginNewScanPass, beginNewScanPassAfterFlip, finish }

enum ObjectOnboarding {
    static let recommendedPasses = 3
    /// Pure transition plus the session call to make. passCompleted moves a lap state to its
    /// review (the third lap to `.done`); in a review, chooseFlip gives
    /// `.beginNewScanPassAfterFlip` and chooseNoFlip `.beginNewScanPass`; finishTapped gives
    /// `.finish` from any review or `.done`; every other pair is ignored (`.none`, same state).
    static func next(_ state: ObjectOnboardingState, _ event: ObjectOnboardingEvent) -> (state: ObjectOnboardingState, command: ObjectPassCommand)
    /// Pass number of a state, 1...3 (for the log and the review title).
    static func pass(of state: ObjectOnboardingState) -> Int
    /// The instruction shown over the camera for a state (Copy.ObjectCapture).
    static func instruction(for state: ObjectOnboardingState) -> String
    /// False once `.objectNotFlippable` was seen during the scan (RESEARCH 3.3 gotcha 15); the
    /// review then leads with the no-flip choice and shows `Copy.ObjectCapture.flipWarning`.
    static func flipRecommended(sawNotFlippable: Bool) -> Bool
    static func canFinish(shots: Int) -> Bool           // shots >= ObjectScanFolders.minimumImages
}

// MARK: Folders and sealing (ObjectScanFolders.swift)

enum ObjectScanFolders {
    static let imagesFolderName = "Images"
    static let checkpointFolderName = "Checkpoint"
    /// Apple's sample refuses fewer than 10 images (RESEARCH 3.3 recommended 4).
    static let minimumImages = 10
    static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
    static func imagesURL(in folder: RawScanFolder) -> URL
    static func checkpointURL(in folder: RawScanFolder) -> URL
    /// Creates `Images/` and `Checkpoint/` in a new InProgress folder; throws
    /// `MapperError.ioFailed` when either exists and is not empty (the session would fail).
    static func prepare(_ folder: RawScanFolder) throws -> (images: URL, checkpoint: URL)
    static func isEmptyDirectory(_ url: URL) -> Bool
    static func imageCount(in images: URL) -> Int
    /// After the session is released and the writer closed: moves `Checkpoint/` to
    /// `PhotogrammetryStore.checkpointURL` (replacing an older one; created with
    /// `ensureDirectory(_:inside: package.root)`), removes the four empty RawScanFolder
    /// subfolders InProgressScans made (mesh, keyframes, depth, photos; only when empty), then
    /// `InProgressScans.seal(_:into: package.rawObjectURL(objectID), package:root:)`.
    @discardableResult
    static func seal(_ folder: RawScanFolder, objectID: UUID, package: ProjectPackage, root: URL? = nil) throws -> SealFile
    /// AppShell's RecoveryService (5d): an unsealed object scan can be built when it holds at
    /// least `minimumImages` images.
    static func canRecover(_ folder: RawScanFolder) -> Bool
}

// MARK: Capture model (ObjectScanModel.swift)

/// Main actor. Owns at most one `ObjectCaptureSession` (RESEARCH 3.3; REUSE 2.5). Stored Tasks
/// iterate `stateUpdates`, `feedbackUpdates`, `cameraTrackingUpdates`,
/// `userCompletedScanPassUpdates`, `numberOfShotsTakenUpdates` and `isPausedUpdates` with
/// `for await`, capturing `[weak self]`; `teardown()` cancels them.
@MainActor final class ObjectScanModel: ObservableObject {
    @Published private(set) var phase: ObjectScanPhase
    @Published private(set) var stage: ObjectCaptureStage
    @Published private(set) var onboarding: ObjectOnboardingState
    @Published private(set) var shotCount: Int
    /// `maximumNumberOfInputImages`, never a constant (RESEARCH 3.3 recommended 1).
    @Published private(set) var shotLimit: Int
    @Published private(set) var trackingNormal: Bool
    @Published private(set) var isPaused: Bool
    /// `.overCapturing` present: the shot counter turns red.
    @Published private(set) var overCapturing: Bool
    @Published private(set) var flipRecommended: Bool
    /// `startDetecting()` returned false: the hint `Copy.ObjectCapture.notFoundHint` shows.
    @Published private(set) var detectionFailed: Bool
    /// Done tapped with fewer than `minimumImages` shots.
    @Published var showsTooFewPhotos: Bool
    let target: ObjectScanTarget
    /// Guidance banner source: `GuidanceSignals.guidance(for:)` of the live feedback, presented
    /// through an announcer whose defaults have `SettingsKey.guidanceHaptics` false, so VoiceOver
    /// still speaks but Mapper adds no haptics during capture (the session plays its own).
    let announcer: GuidanceAnnouncer
    /// The live session (for `ObjectCaptureView`); nil before `start` and after completion.
    private(set) var session: ObjectCaptureSession?
    /// Main. Called once after sealing.
    var onComplete: ((ObjectScanResult) -> Void)?
    /// Main. Called once after a cancel or a discard (the InProgress folder is gone).
    var onEnded: (() -> Void)?
    /// UserDefaults suite of the quiet announcer.
    static let quietGuidanceSuite = "mapper.objectCapture.guidance"
    init(target: ObjectScanTarget)
    /// Main. `ObjectCapturePreflight.run()` (throws `.unsupportedDevice`, `.lowStorage(freeBytes:)`
    /// or `.deviceTooHot` for its three blocking issues), `InProgressScans.create` with
    /// `InProgressScanInfo(scanID: objectID, projectID:, sessionID: nil, roomID: objectID, kind: .object,
    /// mode: .object, startedAt:)` (no ARKit session; the object id in `roomID` as for large objects),
    /// `ObjectScanFolders.prepare`, then `ObjectCaptureSession()` (`ObjectCaptureActivity.captureStarted()`) and
    /// `start(imagesDirectory:configuration:)` with `checkpointDirectory` set and
    /// `isOverCaptureEnabled = false`. Logs the limits. Throws before creating a session when a
    /// check fails and removes the folder it made.
    func start() throws
    func continueTapped()                  // .ready: startDetecting(); false sets detectionFailed
    func resetBox()                        // .detecting: resetDetection()
    func startCapture()                    // .detecting: startCapturing()
    /// Review choices and Done go through `ObjectOnboarding.next` and run its command
    /// (`beginNewScanPass`, `beginNewScanPassAfterFlip` or `finish`).
    func choose(_ event: ObjectOnboardingEvent)
    /// Done button: `finish()` when `.capturing` and `canFinish(shots:)`, else `showsTooFewPhotos`.
    func finish()
    /// `pause()` / `resume()` for sheets, alerts and scene phase changes (RESEARCH 3.3 gotcha 5).
    func pauseForOverlay()
    func resumeFromOverlay()
    /// The user confirmed Discard: `cancel()`, wait for `.failed(.cancelled)`, release the session,
    /// close the writer, `InProgressScans.discard(scanID:)`, phase `.cancelled`, `onEnded`.
    func cancel()
    /// After `.failed` with enough images: seal what exists (same path as completion).
    func useCapturedPhotos()
    /// After `.failed`: discard as `cancel()` does.
    func discardAfterFailure()
    /// Idempotent: cancels the update tasks, releases the session (`ObjectCaptureActivity.captureReleased()`
    /// once). Called on every terminal phase.
    func teardown()
}

/// ZStack of `ObjectCaptureView(session:)` with `.id(session.id)` and Mapper's controls
/// (Cancel with the `Copy.Scanning.cancelConfirm*` dialog, instruction, shot counter, Continue,
/// Reset Box, Start Capture, Done), the guidance banner, and the review sheet (its content is
/// `ObjectCapturePointCloudView(session:).showShotLocations()` plus the review text and choices).
/// Controls hide while `!trackingNormal || isPaused` (RESEARCH 3.10 gotcha 14). Capture-time
/// alerts (too few photos, failure with Use These Photos or Discard) are shown here.
/// `ObjectCaptureView` is in the hierarchy only while `model.session` is non-nil: after completion
/// the saving text replaces it, so the view's own reference to the session goes with it.
struct ObjectScanScreen: View { init(model: ObjectScanModel) }

// MARK: Reconstruction (PhotogrammetryStore.swift, PhotogrammetryStep.swift)

enum PhotogrammetryStage: String, Codable, CaseIterable, Sendable {
    case preProcessing, imageAlignment, pointCloudGeneration, meshGeneration, textureMapping, optimization
}

/// Live reconstruction progress for ObjectUI (Mapper values only).
struct PhotogrammetryProgress: Equatable, Sendable {
    var objectID: UUID
    var fraction: Double = 0
    var stage: PhotogrammetryStage? = nil
    var remainingSeconds: Double? = nil
    var inputComplete = false
    var downsampled = false
    var stitchingIncomplete = false
    var invalidSamples = 0
    var skippedSamples = 0
    init(objectID: UUID)
}

/// Mapper's copy of the outputs that change progress (pure reducer input).
enum PhotogrammetryEvent: Equatable, Sendable {
    case inputComplete, progress(Double), stage(PhotogrammetryStage?, remaining: Double?)
    case invalidSample, skippedSample, downsampled, stitchingIncomplete
    case modelWritten, boundsReceived, requestFailed(String), completed, cancelled
}

enum PhotogrammetryOutputs {
    static func stage(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> PhotogrammetryStage?
    /// Every `Output` case mapped, `@unknown default` gives nil (logged).
    static func event(_ output: PhotogrammetrySession.Output) -> PhotogrammetryEvent?
    static func reduce(_ progress: PhotogrammetryProgress, _ event: PhotogrammetryEvent) -> PhotogrammetryProgress
}

/// `derived/objects/<id>/reconstruction.json`.
struct PhotogrammetryInfo: Codable, Equatable, Sendable {
    var objectID: UUID
    var imageCount: Int
    /// The `.bounds` result, meters, when it arrived.
    var boundsMin: Vec3?
    var boundsMax: Vec3?
    var seconds: Double
    var invalidSamples: Int
    var skippedSamples: Int
    var downsampled: Bool
    var stitchingIncomplete: Bool
    var maximumNumberOfInputImages: Int
    var maximumInputImageDimension: Int
    var thermalAtStart: String
    var thermalAtEnd: String
    var inputHash: String
    var finishedAt: Date
    /// boundsMax - boundsMin, nil without bounds.
    var boundsExtents: SIMD3<Float>? { get }
}

enum PhotogrammetryStore {
    static let modelFileName = "model.usdz"
    static let partialModelFileName = "model-partial.usdz"
    static let infoFileName = "reconstruction.json"
    static let checkpointFolderName = "checkpoint"
    static func folder(_ package: ProjectPackage, object: UUID) -> URL          // derived/objects/<id>/
    static func modelURL(_ package: ProjectPackage, object: UUID) -> URL        // model.usdz
    static func checkpointURL(_ package: ProjectPackage, object: UUID) -> URL   // checkpoint/
    static func infoURL(_ package: ProjectPackage, object: UUID) -> URL         // reconstruction.json
    static func imagesURL(_ package: ProjectPackage, object: UUID) -> URL       // raw/objects/<id>/Images/
    static func modelURLIfPresent(_ package: ProjectPackage, object: UUID) -> URL?
    static func loadInfo(_ package: ProjectPackage, object: UUID) -> PhotogrammetryInfo?
}

/// Main actor, observed by ObjectUI's processing view.
@MainActor final class PhotogrammetryMonitor: ObservableObject {
    static let shared: PhotogrammetryMonitor
    @Published private(set) var progress: [UUID: PhotogrammetryProgress]
    func update(_ value: PhotogrammetryProgress)
    func clear(_ objectID: UUID)
    /// Any thread: `DispatchQueue.main.async { MainActor.assumeIsolated { shared.update(value) } }`,
    /// throttled by the caller to 4 per second.
    nonisolated static func post(_ value: PhotogrammetryProgress)
}

/// id .reconstructObject, subject = object id; required in the object plan. Budget 1 GB,
/// reduced 500 MB: both variants make the same request (Apple manages photogrammetry memory
/// and downsamples by itself); the reduced one only lets a relaunch after a jetsam kill run
/// once more on the kept checkpoint before the runner gives up (3.15).
final class PhotogrammetryStep: ProcessingStep { init(object: ObjectRecord) }
```

**Rules.**

*Capture flow* (REUSE 2.1, ARCHITECTURE 4.4). `.ready`: Continue calls `startDetecting()`; a false result shows `notFoundHint` and counts a detection failure. `.detecting`: Reset Box (`resetDetection()`) and Start Capture (`startCapturing()`). `.capturing`: the shot counter shows `shotCount` of `shotLimit`, red while overcapturing; when `userCompletedScanPass` becomes true the onboarding state moves to its review and the review sheet opens with `pauseForOverlay()`; its choices call `choose(_:)`, and closing it calls `resumeFromOverlay()`. The `ObjectCaptureView` stays mounted for the whole scan (D17, RESEARCH 3.10 gotcha 13); the screen pauses on `scenePhase` `.background` and resumes on `.active`. Done calls `finish()`; `.finishing` shows `Copy.ObjectCapture.saving`. At `.completed`: the session and its tasks are released first (RESEARCH 3.3 gotcha 10), `objectlog.json` is written through a `RawScanWriter` on the InProgress folder, `await writer.flush()`, `writer.close()`, then `ObjectScanFolders.seal` runs in `Task.detached` and the phase becomes `.done(result)` and `onComplete` fires. A `.failed(error)` that is not the user's own cancel shows the failure alert; with at least 10 images it offers Use These Photos. The model never writes the manifest (ObjectUI does).

*Reconstruction* (RESEARCH 3.3 recommended 6, ARCHITECTURE 5.10). Input hash: the seal of `raw/objects/<id>/` and `"reconstruct-rules=1"`. Run: guard `PhotogrammetrySession.isSupported` else `MapperError.objectCaptureFailed`; wait while `ObjectCaptureActivity.captureSessions > 0` (poll 0.25 s, `ctx.checkCancelled()` each time, at most 60 s, then throw `MapperError.cancelled` so the job stays queued for the next launch; logged), because a capture session and a photogrammetry session must never overlap (gotcha 10); `ObjectCaptureActivity.reconstructionStarted()` right before the session is created and `reconstructionEnded()` on every exit path after the loop ended and the session was released; `var configuration = PhotogrammetrySession.Configuration()`, `checkpointDirectory` = `PhotogrammetryStore.checkpointURL` (created inside the package when missing; the capture's checkpoint is reused when present), `isObjectMaskingEnabled = true` (set explicitly: object mode, SPEC "separate the target object from its background"); `let session = try PhotogrammetrySession(input: PhotogrammetryStore.imagesURL(...), configuration: configuration)`; `try session.process(requests: [.modelFile(url: partialURL), .bounds])` with the default detail (never name a Detail case); then `for try await output in session.outputs`, mapping each output through `PhotogrammetryOutputs.event`, reducing progress, calling `ctx.progress(fraction * 0.95)` and `PhotogrammetryMonitor.post` at most 4 times a second, and breaking out at `.processingComplete` or `.processingCancelled` (the sequence never ends by itself, gotcha 8). `ctx.isCancelled` is checked on every output and by a 1 s watcher; on cancel `session.cancel()` is called and the loop waits for `.processingCancelled` (gotcha 9), then throws `MapperError.cancelled`. A `requestError` for the model request throws `MapperError.objectCaptureFailed(description)`; one for `.bounds` is only logged. Exception: when the capture's checkpoint was reused (it was written next to `Images/` inside InProgress and moved at sealing, and whether the session accepts a moved checkpoint is not documented), a model `requestError` or a throwing `process(requests:)` first empties the checkpoint folder and runs the requests once more from scratch on a new session (logged "checkpoint retry"); only a second failure throws. On success `model-partial.usdz` replaces `model.usdz` (`FileManager.replaceItemAt`, not in RESEARCH, iOS 4), reconstruction.json is written, and `ManifestWriter.update` sets the record's `modelFile = "model.usdz"` and `reconstructionPending = false`. The checkpoint is kept (build 6 ObjectCrop re-runs from it; it is derived and counts under derived storage). Logged: image count, limits, wall time, thermal at start and end, available memory, invalid and skipped samples, downsampling, stitching.

**Uses.** Core: `ProjectPackage` (`rawObjectURL`, `derivedObjectURL`, `root`), `RawScanFolder`, `ObjectRecord`, `ProjectStore` (`freeBytes`, `objectCapturePreflightBytes`, `ensureDirectory(_:inside:)`, `writeData`, `writeJSON`, `readJSON`, `encoder`), `SealFile`, `InputHasher`, `ProcessingStep`, `StepContext`, `MapperError` (`unsupportedDevice`, `lowStorage(freeBytes:)`, `deviceTooHot`, `objectCaptureFailed`, `cancelled`), `ThermalLevel.init(_:)`, `Vec3`. Store: `InProgressScans` (`create`, `seal(_:into:package:root:)`, `discard(scanID:)`), `InProgressScanInfo` (kind `.object`), `RawScanWriter` (`writeFile`, `flush() async`, `close()`), `ManifestWriter.update`. GuidanceUI: `GuidanceSignals.guidance(for:)`, `GuidanceBanner(kind:)`, `GuidanceAnnouncer(defaults:)`, `SettingsKey.guidanceHaptics`. Pipeline: `ProcessingGuards.availableMemory()`. Support: `Copy.ObjectCapture` (new), `Copy.Scanning.cancel`, `done`, `cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`, `Copy.Errors.objectUnsupported`, `storageFullTitle`, `storageFullBody(_:)`, `trackingFailed`, `generic`, `ok`, `Copy.A11y`, `GuidanceKind.objectLooksComplete`, `LogStore` (category "objectcapture").

**Apple APIs** (RESEARCH 3.3, 3.10; all iOS 17.0 unless noted):
```swift
@MainActor class ObjectCaptureSession                         // Identifiable, Observable, Sendable
@MainActor init()
@MainActor static var isSupported: Bool { get }
@MainActor func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())
@MainActor func startDetecting() -> Bool
@discardableResult @MainActor func resetDetection() -> Bool
@MainActor func startCapturing()
@MainActor func finish()
@MainActor func cancel()
@MainActor func pause() / @MainActor func resume()
@MainActor func beginNewScanPass() / @MainActor func beginNewScanPassAfterFlip()
@MainActor var stateUpdates: ObjectCaptureSession.Updates<ObjectCaptureSession.CaptureState> { get }
@MainActor var feedbackUpdates: ObjectCaptureSession.Updates<Set<ObjectCaptureSession.Feedback>> { get }
@MainActor var cameraTrackingUpdates: ObjectCaptureSession.Updates<ObjectCaptureSession.Tracking> { get }
@MainActor var userCompletedScanPassUpdates: ObjectCaptureSession.Updates<Bool> { get }
@MainActor var numberOfShotsTaken: Int { get }                // + numberOfShotsTakenUpdates
@MainActor var isPaused: Bool { get }                         // + isPausedUpdates
@MainActor var maximumNumberOfInputImages: Int { get }
@MainActor var isAutoCaptureEnabled: Bool { get set }         // iOS 18.0, logged, left on
@MainActor var shouldPlayHaptics: Bool { get set }            // iOS 18.0, logged, left on
struct ObjectCaptureSession.Configuration { init(); var checkpointDirectory: URL?; var isOverCaptureEnabled: Bool }
enum ObjectCaptureSession.CaptureState { case initializing, ready, detecting, capturing, finishing, completed; case failed(any Error) }
enum ObjectCaptureSession.Error { case cancelled; case directoryNotEmpty(URL); case insufficientStorage(requiredBytes: Int64); case sensorFailed; case trackingFailed }
enum ObjectCaptureSession.Feedback { case environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected /* 17.4 */,
                                     objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing }
enum ObjectCaptureSession.Tracking { case normal; case notAvailable; case limited(reason: ObjectCaptureSession.Tracking.Reason) }
@MainActor @preconcurrency struct ObjectCaptureView<Overlay> where Overlay : View
nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView
@MainActor struct ObjectCapturePointCloudView
@MainActor init(session: ObjectCaptureSession)
@MainActor func showShotLocations(_ value: Bool = true) -> ObjectCapturePointCloudView   // iOS 18.0
class PhotogrammetrySession
static var isSupported: Bool { get }
convenience init(input: URL, configuration: PhotogrammetrySession.Configuration = Configuration()) throws
var outputs: PhotogrammetrySession.Outputs { get }            // AsyncSequence, never ends
func process(requests: [PhotogrammetrySession.Request]) throws
func cancel()                                                  // asynchronous
static let limits: PhotogrammetrySession.Limits               // maximumNumberOfInputImages, maximumInputImageDimension
struct PhotogrammetrySession.Configuration { init(); var isObjectMaskingEnabled: Bool; var checkpointDirectory: URL? }
case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced, geometry: PhotogrammetrySession.Request.Geometry? = nil)
case bounds
enum PhotogrammetrySession.Result { case modelFile(URL); case modelEntity(ModelEntity); case bounds(BoundingBox); ... }
enum PhotogrammetrySession.Output { case inputComplete; case requestProgress(_, fractionComplete: Double);
    case requestProgressInfo(_, PhotogrammetrySession.Output.ProgressInfo); case requestComplete(_, _); case requestError(_, any Error);
    case processingComplete; case processingCancelled; case invalidSample(id: Int, reason: String); case skippedSample(id: Int);
    case automaticDownsampling; case stitchingIncomplete }
struct PhotogrammetrySession.Output.ProgressInfo { let estimatedRemainingTime: TimeInterval?; let processingStage: PhotogrammetrySession.Output.ProcessingStage? }
enum PhotogrammetrySession.Output.ProcessingStage { case preProcessing, imageAlignment, pointCloudGeneration, meshGeneration, textureMapping, optimization }
```
Not in RESEARCH (all long-standing): `UserDefaults(suiteName:)` (iOS 7), `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)` (iOS 4), `MainActor.assumeIsolated` (iOS 17.0), SwiftUI `.sheet(isPresented:)`, `.confirmationDialog`, `.alert`, `@Environment(\.scenePhase)` (iOS 14 to 15), `.persistentSystemOverlays(.hidden)` (RESEARCH 3.10). Every switch over these enums has `@unknown default`.

**Must NOT do.** Never name any `PhotogrammetrySession.Request.Detail` case (use the default argument); never request `.modelEntity`, `.poses` or `.pointCloud`; never create the `PhotogrammetrySession` while an `ObjectCaptureSession` exists (`ObjectCaptureActivity.captureSessions`), and never create an `ObjectCaptureSession` while a reconstruction is counted; never call `start` twice on one session or reuse a session after `.completed` or `.failed`; never start with a non-empty images or checkpoint folder; never tear down and recreate `ObjectCaptureView` between passes (pause instead); never add Mapper haptics during capture (the announcer is quiet, the session plays its own); never create an `ARSession` or `ARSessionHub` (Object Capture owns the camera); never hard-code the image limit; never enable over-capture; never write into `raw/objects/<id>/` after sealing; never delete the checkpoint after reconstruction (build 6 needs it); never write the manifest from the capture model.

**Copy strings.** Existing: `Copy.Scanning.cancel`, `done`, `cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`; `Copy.Errors.objectUnsupported`, `storageFullTitle`, `storageFullBody(_:)`, `trackingFailed`, `generic`, `ok`; `GuidanceKind.objectLooksComplete.message.text` ("All sides captured. Tap Done when you're ready") in the `.done` state; guidance texts through `GuidanceKind`. New in `Copy+ObjectCapture.swift` (`extension Copy { enum ObjectCapture }`):
- `continueButton = "Continue"`, `startCapture = "Start Capture"`, `resetBox = "Reset Box"`
- `aimHint = "Aim at your object, then tap Continue"`
- `notFoundHint = "Can't find your object. Step back so it fits on screen"`
- `boxHint = "Drag the box edges to fit your object"`
- `orbitHint = "Keep moving around your object"`
- `lowerHint = "Hold your iPhone lower and walk around again"`
- `higherHint = "Hold your iPhone higher and capture the top"`
- `flippedHint = "Walk around the object again"`
- `static func reviewTitle(_ laps: Int) -> String { "\(laps) of 3 laps done" }`
- `reviewFirstBody = "Turn the object on its side to capture the bottom, or walk around again from lower down."`
- `reviewSecondFlippedBody = "Turn the object onto another side for the last lap, or finish now."`
- `reviewSecondBody = "Walk around once more from higher up, or finish now."`
- `flipObject = "Flip Object"`, `flipAgain = "Flip Again"`, `scanLower = "Scan Lower"`, `scanHigher = "Scan Higher"`, `flipAnyway = "Flip Anyway"`
- `flipWarning = "This object may not line up after flipping. Walking around it again works better."`
- `static func shotCount(taken: Int, limit: Int) -> String { "\(taken) of \(limit) photos" }`
- `tooFewPhotos = (title: "Keep going", body: "Walk around the object a bit more. Mapper needs at least 10 photos to build a model.")`
- `saving = "Saving your photos..."`
- `failed = (title: "Object scan stopped", body: "Something went wrong with the camera. You can build a model from the photos taken so far.")`
- `usePhotos = "Use These Photos"`
- `a11yCaptureView = "Object scan view"`, `static func a11yShotCount(taken: Int, limit: Int) -> String { "\(taken) of \(limit) photos taken" }`

**Self-test.** `ObjectCaptureSelfTest.run()`, at least 30 checks, no session created: `stage` for all six plain `CaptureState` cases and a `.failed`; `failure` for the five `ObjectCaptureSession.Error` cases (building the enum values) and for an unrelated `NSError` (`.other`); `name(of:)` distinct for all nine feedback cases; `GuidanceSignals.guidance(for: [.movingTooFast, .objectTooFar])` is `.moveSlower` and `[.overCapturing]` gives nil; `containsNotFlippable` and `containsOverCapturing`; onboarding: flip path firstSegment, passCompleted, reviewFirst, chooseFlip (command `.beginNewScanPassAfterFlip`), passCompleted, reviewSecond(flipped: true), chooseFlip, passCompleted, done; no-flip path through captureFromLowerAngle and captureFromHigherAngle with `.beginNewScanPass`; finishTapped in reviewFirst gives `.finish`; passCompleted in `.done` is ignored; `pass(of:)` is 1, 2, 3; `flipRecommended(sawNotFlippable: true)` is false; `canFinish` false at 9 and true at 10; `instruction(for:)` non-empty for every state; preflight blocks unsupported, 2.9 GB free and critical heat, warns at serious heat, passes at 3.1 GB; `ObjectScanFolders.prepare` makes two empty folders in a temp InProgress root and throws when `Images/` holds a file; `imageCount` counts .heic and .jpg and ignores .txt; `seal` with a temp InProgress root and a temp package moves `Checkpoint/` to the derived checkpoint, removes the empty subfolders, seals `Images/` and `objectlog.json` and lists them in SEAL.json; `canRecover` false at 9 images and true at 10; `PhotogrammetryOutputs.stage` for all six stages; `event(.inputComplete)`, `event(.processingComplete)`, `event(.automaticDownsampling)`, `event(.requestProgress(.bounds, fractionComplete: 0.4))`; `reduce` of progress, stage and counters; `PhotogrammetryInfo` and `ObjectCaptureLog` Codable round trips; `boundsExtents`; the quiet announcer defaults read `guidanceHaptics` false; `ObjectCaptureActivity` counts up and down and `waitForNoReconstruction(timeout: 0.5)` returns false while a reconstruction is counted and true at once when none is.

**Acceptance checks.** Every file naming Object Capture or photogrammetry types imports SwiftUI and RealityKit; the model is `@MainActor` and every session call is on main; no `.reduced`, `.medium`, `.full`, `.raw`, `.preview` or `.custom` token appears in the module; update tasks are cancelled on teardown (two scans in a row log two "object session released" lines); objectlog.json is written before sealing and nothing after SEAL.json; the step's output loop always ends; the limits line (`maximumNumberOfInputImages`, `PhotogrammetrySession.limits`) appears in the log of every scan.

**SPEC owned.** "OBJECT SCANNING": guide the user around the object (Apple's guided capture with Mapper's instructions), "Move around the object slowly", "Capture the top" (`higherHint`), attempt to separate the object from its background (`isObjectMaskingEnabled`, box selection), camera images for textures (photogrammetry textures); "SCANNING MODES" OBJECT (small and medium); "CORE DESIGN PRINCIPLE" Representation B "photogrammetry where appropriate"; "LOCAL-FIRST ARCHITECTURE" ("Prefer on-device processing").

**TEST_PLAN ids.** OBJ-01 (guidance, capture states, image count, processing time logged), OBJ-04 (guidance during capture), OBJ-06 (small object, "Too close" and "Too far"), OBJ-07 (capture side), OBJ-09 (mode object), MODE-03 (Object starts), PERF-04 (processing time), PERF-26 (object InProgress recovery with AppShell 5d), smoke #9.

### 3.34 ObjectModel (wave 5a)

**Purpose.** Object results (Representation E) after capture: read the Object Capture USDZ with ModelIO into a Mapper `MeshWithAttributes` (UV-seam duplicates welded so a closed model tests watertight), measure it (gravity-aligned box: width, height, depth; surface area; volume only when watertight, with the reason otherwise), guard against a unit mismatch against the photogrammetry `.bounds` result, the untextured mesh file, confidence values for every dimension (one documented rule per size class), the large-object path (MeshProcessing's `ObjectIsolation` on the consolidated LiDAR mesh inside the user's crop box, an edit), the untextured export scene, and the `objectMetrics` step that writes `dims.json` and `mesh.mchk`.

**Build and wave.** Build 5, wave 5a. Core (with CR-1), Geometry, MeshProcessing, MeshModel (`MeshModelStore` for the large-object mesh and the chunk conversion), Export (`ExportScene`), Store (`EditStore`), Support; ModelIO, and RealityKit in the fallback loader only. About 900 lines excluding the self-test. The reconstruction outputs of ObjectCapture (same wave) arrive through two injected closures (section 3.1 rule), never by importing ObjectCapture.

**Files.** `ios/Sources/ObjectModel/ObjectModelLoader.swift`, `ObjectModelEntityLoader.swift` (RealityKit fallback), `ObjectDimensions.swift`, `ObjectModelStore.swift`, `ObjectMetricsStep.swift`, `ObjectModelExport.swift`, `ObjectModelSelfTest.swift`.

**Public Swift API.** Pure and nonisolated except the loader and the step (file IO, any queue off main).
```swift
/// Why an object has no volume. Raw values are persisted in dims.json.
enum ObjectVolumeReason: String, Codable, CaseIterable, Sendable {
    /// Open edges (the base was not seen, or thin parts left holes).
    case notWatertight
    /// Closed but encloses no measurable volume.
    case degenerate
}

/// `derived/objects/<id>/dims.json`.
struct ObjectDimensionsRecord: Codable, Equatable, Sendable {
    var objectID: UUID
    var source: ObjectSize
    /// Box sides, meters: width is the longer horizontal side (box axis 0), height is vertical
    /// (axis 1, world up), depth the shorter horizontal side (axis 2).
    var width: Float
    var height: Float
    var depth: Float
    /// Square meters.
    var surfaceArea: Float
    /// Cubic meters, only when the mesh is watertight.
    var volume: Float?
    /// Nil exactly when `volume` is set.
    var volumeUnavailableReason: ObjectVolumeReason?
    var box: OrientedBoxRecord
    var isWatertight: Bool
    var triangleCount: Int
    /// 1 unless the unit check rescaled the model (logged).
    var scaleCorrection: Float
    /// `.measured`; `.estimated` for a large object whose isolated mesh is open (a side was
    /// not seen, TEST_PLAN OBJ-05).
    var provenance: Provenance
    var inputHash: String
    var measuredAt: Date
}

/// The record's numbers as MeasureCore values (MeasureDisplay formats them).
struct ObjectMeasuredValues: Equatable, Sendable {
    var width: MeasuredValue
    var height: MeasuredValue
    var depth: MeasuredValue
    var surfaceArea: MeasuredValue
    var volume: MeasuredValue?
}

enum ObjectModelError: Error, Equatable {
    case cannotImport(String)     // MDLAsset cannot read the file
    case noTriangles              // no triangle submesh
}

/// Reads the Object Capture USDZ (RESEARCH 3.3 "Reading the finished model"). Any queue off main.
enum ObjectModelLoader {
    /// Positions closer than this are one vertex (UV seams duplicate them), meters.
    static let weldTolerance: Float = 1e-5
    /// `MDLAsset.canImportFileExtension("usdz")` (logged once).
    static var canReadUSDZ: Bool { get }
    /// `MDLAsset(url:)`, every `childObjects(of: MDLMesh.self)`: positions through
    /// `vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3)`
    /// honoring its `stride`, transformed by `MDLTransform.globalTransform(with:atTime: 0)`;
    /// triangle submeshes only (`geometryType == .triangles`, 16- or 32-bit indices; others
    /// skipped and logged); welded with `TriangleMesh.welded(tolerance: weldTolerance)`.
    /// Throws `ObjectModelError`.
    static func mesh(fromUSDZ url: URL) throws -> MeshWithAttributes
    /// Pure helper: indices from a raw index buffer, offset by `vertexBase`; nil when
    /// `bytesPerIndex` is not 2 or 4 or `count` is not a multiple of 3.
    static func triangleIndices(_ bytes: UnsafeRawBufferPointer, count: Int, bytesPerIndex: Int, vertexBase: UInt32) -> [UInt32]?
}

/// `ObjectModelEntityLoader.swift`, the only file importing RealityKit. Whether ModelIO reads Object
/// Capture's USDZ on iOS 18.3.2 is an open device question (2.2), and the small and medium plan has no
/// other way to measure the object, so a ModelIO failure must not fail the required step.
extension ObjectModelLoader {
    /// Fallback when `canReadUSDZ` is false or `mesh(fromUSDZ:)` throws `.cannotImport`:
    /// `try await Entity(contentsOf: url)`, then for every descendant with a `ModelComponent`, its
    /// `mesh.contents` instances (`contents.models[instance.model]`, each part's `positions` and
    /// `triangleIndices`) through `instance.transform` and the entity's `transformMatrix(relativeTo: nil)`,
    /// welded like the ModelIO path. Main actor by API (a 50k-triangle model takes milliseconds);
    /// returns a value, keeps no entity; throws `ObjectModelError.noTriangles` when nothing is found.
    @MainActor static func meshFromEntity(at url: URL) async throws -> MeshWithAttributes
}

enum ObjectDimensions {
    /// Confidence rule for objects (1 sigma = max(floor, relative x length)); 2 sigma then
    /// matches TEST_PLAN OBJ-01's "1.5 cm or 3 percent" for Object Capture and "2 cm or 4
    /// percent" for the LiDAR mesh of large objects. Tuned with the tape protocol.
    static let smallMediumSigmaFloor: Float = 0.0075
    static let smallMediumSigmaRelative: Float = 0.015
    static let largeSigmaFloor: Float = 0.01
    static let largeSigmaRelative: Float = 0.02
    /// A reported extent ratio outside 0.8...1.25 is a unit mismatch.
    static let scaleTolerance: ClosedRange<Float> = 0.8...1.25
    /// Small and medium: `ObjectIsolation.measure(_:support: nil)` on the welded mesh (box, sides,
    /// surface area, volume when watertight); nil when the mesh is empty.
    static func measure(_ mesh: MeshWithAttributes, objectID: UUID, source: ObjectSize,
                        scaleCorrection: Float, inputHash: String, now: Date) -> ObjectDimensionsRecord?
    /// Large: `ObjectIsolation.isolate(_:box:options:)` of the consolidated mesh with the crop box
    /// (support plane removed); the isolated mesh is returned for mesh.mchk. Provenance
    /// `.estimated` when the isolated mesh is open.
    static func isolate(_ roomMesh: MeshWithAttributes, box: OrientedBox, objectID: UUID,
                        inputHash: String, now: Date) -> (record: ObjectDimensionsRecord, mesh: MeshWithAttributes)?
    /// 1 when `reported` is nil or the ratio of the largest extents is inside `scaleTolerance`;
    /// otherwise the nearest power of ten that brings it inside (0.01, 0.1, 10, 100), else 1.
    static func scaleCorrection(meshExtents: SIMD3<Float>, reportedExtents: SIMD3<Float>?) -> Float
    static func sigma(length: Float, source: ObjectSize) -> Double
    /// Lengths with `sigma(length:source:)`; surface area and volume with a relative sigma of
    /// 2 x the size's relative length sigma (area and volume grow with two and three sides);
    /// provenance from the record.
    static func measuredValues(_ record: ObjectDimensionsRecord) -> ObjectMeasuredValues
}

enum ObjectModelStore {
    static func dimensionsURL(_ package: ProjectPackage, object: UUID) -> URL   // derived/objects/<id>/dims.json
    static func meshURL(_ package: ProjectPackage, object: UUID) -> URL         // derived/objects/<id>/mesh.mchk
    static func loadDimensions(_ package: ProjectPackage, object: UUID) -> ObjectDimensionsRecord?
    static func saveDimensions(_ record: ObjectDimensionsRecord, to package: ProjectPackage) throws
    /// The untextured object mesh (MeshModel `MeshModelStore.mesh(from:)` of the decoded chunk).
    static func loadMesh(_ package: ProjectPackage, object: UUID) throws -> MeshWithAttributes?
    /// `MeshModelStore.chunk(from:id:)` then Core `MeshChunkFile.encode`, written atomically.
    static func saveMesh(_ mesh: MeshWithAttributes, package: ProjectPackage, object: UUID) throws
    /// The box of the last `cropObject(object:box:)` in `log.flattenedActive` (CR-1) whose `object.uuid == objectID`
    /// (`OrientedBoxRecord.orientedBox`); LargeObject writes it, ObjectCrop edits it in build 6.
    static func cropBox(for objectID: UUID, in log: EditLog) -> OrientedBox?
    /// Stable text of that edit for input hashes ("-" when none).
    static func cropDigest(for objectID: UUID, in log: EditLog) -> String
}

enum ObjectExportAdapter {
    /// The untextured mesh as one `ExportMesh` with normals and a neutral gray material.
    static func scene(_ mesh: MeshWithAttributes, name: String) -> ExportScene
}

/// id .objectMetrics, subject = object id; required in both object plans; budget 300 MB.
/// `modelFile` (AppShell passes `PhotogrammetryStore.modelURLIfPresent`) and `reportedExtents`
/// (`PhotogrammetryStore.loadInfo(...)?.boundsExtents`) come from ObjectCapture, the same wave.
final class ObjectMetricsStep: ProcessingStep {
    static let rulesVersion = "objectMetrics-rules=1"
    init(object: ObjectRecord,
         modelFile: @escaping (ProjectPackage, UUID) -> URL?,
         reportedExtents: @escaping (ProjectPackage, UUID) -> SIMD3<Float>?)
}
```

**Rules.** Small and medium (`object.size == .smallMedium`): input hash = the `reconstructObject` stamp hash of the object ("-" when none) plus `rulesVersion`; the model file must exist (else `MapperError.processingFailed(step: .objectMetrics, reason:)`); `ObjectModelLoader.mesh(fromUSDZ:)`, or `await ObjectModelLoader.meshFromEntity(at:)` when ModelIO cannot import the file (logged with the path taken; only when both fail does the step fail), `scaleCorrection` against `reportedExtents` (positions scaled when not 1), `ObjectDimensions.measure`, then `saveMesh` and `saveDimensions`. Large (`.large`): input hash = the object's `consolidateMesh` stamp hash plus `cropDigest` plus `rulesVersion`; `MeshModelStore.loadMeasured(package, room: object.id)` (LargeObject's ConsolidateMeshStep uses the object id as its subject) and `cropBox` (missing: `processingFailed`, "no crop box"); `ObjectDimensions.isolate`; save both files. Every result is logged (sides, watertight, volume or reason, triangles, scale correction). Volume comes only from a closed mesh (Geometry's `isWatertight` then `signedVolume`); a bounding-box volume is never reported as the object's volume (TEST_PLAN OBJ-03).

**Uses.** Core: `ObjectRecord`, `ObjectSize`, `OrientedBoxRecord`, `Provenance`, `MeasuredValue`, `EditLog.flattenedActive` (CR-1), `EditOperation.cropObject`, `MeshChunkFile.encode`, `MeshChunkFile.decode`, `ProjectPackage.derivedObjectURL`, `ProjectStore` (`ensureDirectory(_:inside:)`, `writeData`, `writeJSON`, `readJSON`), `DerivedIndex`, `InputHasher`, `ProcessingStep`, `StepContext`, `MapperError`. Geometry: `TriangleMesh` (`welded(tolerance:)`, `isWatertight`, `signedVolume`, `surfaceArea`, `boundingBox`, `transformed(by:)`), `OrientedBox`, `AABB3`. MeshProcessing: `MeshWithAttributes`, `ObjectIsolation` (`measure(_:support:)`, `isolate(_:box:options:)`, nested `IsolatedObject` and `VolumeUnavailableReason`, mapped one to one to `ObjectVolumeReason`). MeshModel: `MeshModelStore` (`loadMeasured`, `chunk(from:id:)`, `mesh(from:)`). Export: `ExportMesh`, `ExportMaterial`, `ExportScene`. Store: `EditStore.load`. Support: `LogStore` (category "objectmodel").

**Apple APIs** (RESEARCH 3.3 "Reading the finished model"): `init(url URL: URL)` (MDLAsset, iOS 9.0), `var boundingBox: MDLAxisAlignedBoundingBox { get }` (logged next to the mesh bounds), `func childObjects(of objectClass: AnyClass) -> [MDLObject]`. Not in RESEARCH (ModelIO, iOS 9 or 10): `class func canImportFileExtension(_:) -> Bool`, `MDLMesh.vertexCount`, `MDLMesh.vertexAttributeData(forAttributeNamed:as:) -> MDLVertexAttributeData?` with `dataStart` and `stride`, `MDLVertexAttributePosition`, `MDLVertexFormat.float3`, `MDLMesh.submeshes`, `MDLSubmesh.indexBuffer`, `indexCount`, `indexType` (`MDLIndexBitDepth.uInt16`, `.uInt32`), `geometryType` (`MDLGeometryType.triangles`), `MDLMeshBuffer.map()` and `MDLMeshBufferMap.bytes`, `MDLTransform.globalTransform(with:atTime:)` (iOS 10). Fallback loader: `@MainActor @preconcurrency convenience init(contentsOf url: URL, withName resourceName: String? = nil) async throws` (RealityKit `Entity`, iOS 18.0, RESEARCH 3.3); not in RESEARCH (RealityKit, iOS 15 or earlier, checked against Apple's documentation JSON): `ModelComponent.mesh`, `@MainActor var contents: MeshResource.Contents { get }`, `Contents.models` and `.instances`, `MeshResource.Instance.model` and `.transform`, `MeshResource.Model.parts`, `MeshResource.Part.positions` (MeshBufferContainer) and `triangleIndices`, `MeshBuffer.elements`, `@MainActor func transformMatrix(relativeTo referenceEntity: Entity?) -> float4x4` (HasTransform, iOS 13).

**Must NOT do.** Never report a volume for a mesh that is not watertight after welding; never use SceneKit loaders; never use `MDLAsset.export` (no USD writing here); never load the USDZ with ModelIO on main (only the RealityKit fallback runs on the main actor, and only after ModelIO failed); never read the Object Capture folders except the model file the closure gives; never write outside `derived/objects/<id>/`; never keep more than one object mesh in memory in the step.

**Copy strings.** None (ObjectUI shows the text).

**Self-test.** `ObjectModelSelfTest.run()`, at least 20 checks: a unit cube gives width, height and depth 1, surface area 6, volume 1 within 1e-3 and `isWatertight`; the same cube with one face removed gives volume nil and `.notWatertight`; a cube whose faces have their own duplicated corner vertices (UV seams) is watertight after the loader's weld (pure weld path); a 0.6 x 0.3 x 0.4 box turned 30 degrees about +Y gives width 0.6 and depth 0.4 within 1e-3 and width >= depth; `isolate` of a 0.5 m box on a 3 x 3 m floor mesh gives 0.5 within 0.01 and removes the floor; `scaleCorrection` gives 0.01 for a 100 times too large mesh, 1 within 20 percent, 1 with no report; `sigma` of 0.3 m small is 0.0075, of 2 m small is 0.03, of 2 m large is 0.04; `measuredValues` of a 1 m small object is not low confidence (Core rule); volume value nil when the record has none; `triangleIndices` for 16-bit and 32-bit buffers with a vertex base and nil for 5 indices; `cropBox` returns the last active crop, finds one inside a `batch` and ignores an undone one; `cropDigest` changes with the crop; dims.json and mesh.mchk round trips in a temp package; `ObjectExportAdapter.scene` validates; USDZ round trip: `USDZWriter.data(for:)` of a box written to a temp `.usdz` reads back through `mesh(fromUSDZ:)` with 12 triangles and the same bounds within 1e-4 (checked only when `canReadUSDZ`, otherwise one failure line says ModelIO cannot read USDZ).

**Acceptance checks.** ModelIO is imported only in `ObjectModelLoader.swift` and RealityKit only in `ObjectModelEntityLoader.swift`; the log of every small or medium object says which loader produced the mesh; the loader honors `stride` and never assumes 12 bytes; dims.json and mesh.mchk are written with `ensureDirectory(_:inside:)` and `createParents: false`; the step's hash reads upstream stamps from `derived/index.json` (3.1 input hash rule).

**SPEC owned.** "OBJECT SCANNING" outputs: untextured mesh, bounding box, width, height, depth, "estimated volume where mathematically valid"; "MEASUREMENT SYSTEM": object width, height, depth, surface area, estimated volume; "MEASUREMENT CONFIDENCE" for objects (the sigma rule); "CORE DESIGN PRINCIPLE" Representation E (isolated object model).

**TEST_PLAN ids.** OBJ-01 (dimensions), OBJ-02 (volume within 5 percent for the box), OBJ-03 (no volume for an open chair), OBJ-05 (depth estimated when the back is open, large path), OBJ-09 (no room data), smoke #9.

### 3.34a Viewer3D revision: loadModel (wave 5a0)

**Purpose.** Show the Object Capture USDZ (textured, PBR materials) in Mapper's own viewer next to ordinary parts (the untextured mesh, the box), make it pickable and frame it.

**Build and wave.** Build 5, wave 5a0 (branch `impl/viewer3d-models`). Viewer3D only; RealityKit. Merges before wave 5a starts, so MeasureTool (5a) compiles against the revised viewer; its only new caller is ObjectUI (5b).

**Files.** Edits `ios/Sources/Viewer3D/ViewerModel.swift` (stored model state; `load`, `unload`, `setVisible`, `frameAll`, `updateViewSize`, `dollyCamera` and the memory-warning eviction learn about models), adds `ViewerModelFiles.swift` (the extension below and `ViewerBoundsMath`), extends `Viewer3DSelfTest.swift`.

**Public Swift API.**
```swift
enum ViewerModelError: Error, Equatable {
    case missingFile
    /// A newer `load`, `unload` or `removeModels` replaced the content while the file loaded;
    /// the entity was discarded.
    case superseded
}

@MainActor extension ViewerModel {
    /// Adds a USDZ model file under `layer` (its own parent entity per layer, enabled with the
    /// layer) with `try await Entity(contentsOf: url)`, sets the entity's transform to
    /// `transform` (ObjectUI passes the uniform scale correction), and returns its world bounds
    /// (`visualBounds(recursive: true, relativeTo: nil)`). When `pickMesh` is given (the same
    /// geometry in world coordinates, already placed like the entity after `transform`, for
    /// example ObjectModel's scale-corrected mesh.mchk), a `MeshBVH` of it is built off main and
    /// hits report `pickTag` while `layer` is visible. The camera frames
    /// the union of the content and model bounds unless the user moved it. Call after `load(_:)`
    /// returned; `load`, `unload` and `removeModels` remove models.
    @discardableResult
    func loadModel(_ url: URL, layer: ViewerLayer = .realistic, transform: simd_float4x4 = matrix_identity_float4x4,
                   pickMesh: TriangleMesh? = nil, pickTag: ViewerPickTag? = .rawMesh) async throws -> AABB3
    func removeModels()
    /// Union of the loaded models' world bounds; `AABB3.empty` when none.
    var modelBounds: AABB3 { get }
}

/// Pure bounds helpers (any queue).
enum ViewerBoundsMath {
    static func union(_ a: AABB3, _ b: AABB3) -> AABB3                          // empty boxes ignored
    static func transformed(_ box: AABB3, by matrix: simd_float4x4) -> AABB3      // bounds of the 8 corners
}
extension ViewerPicking {
    /// Pure: the pick entry of a model's world-space mesh (off main).
    static func entry(for mesh: TriangleMesh, partID: String, pickTag: ViewerPickTag?, layer: ViewerLayer) -> ViewerPickEntry
}
```
Picking searches the content's entries and the model entries (`ViewerPicking.nearestHit` over both lists); model entities are never evicted on a memory warning (Object Capture output is under 50k triangles; RESEARCH 3.3 table) and their parents follow `setVisible`.

**Apple APIs** (RESEARCH 3.3 table and 3.5): `@MainActor @preconcurrency convenience init(contentsOf url: URL, withName resourceName: String? = nil) async throws` (RealityKit `Entity`, iOS 18.0); `@MainActor @preconcurrency func visualBounds(recursive: Bool = true, relativeTo referenceEntity: Entity?, excludeInactive: Bool = false) -> BoundingBox` (iOS 13.0); `var extents: SIMD3<Float> { get }` (BoundingBox). Not in RESEARCH (iOS 13): `BoundingBox.min` and `.max`, `Entity.transform` set with `Transform(matrix:)` (already used by the viewer), `addChild(_:)`, `removeFromParent()`.

**Must NOT do.** No SceneKit, no `ModelEntity.load`, no `.modelEntity` photogrammetry request; never flip UVs or touch the loaded materials; never keep a model entity after `load`, `unload` or `removeModels`; never block main while building the pick BVH.

**Self-test.** At least 6 new checks in `Viewer3DSelfTest`: `union` ignores an empty box; `union` of two boxes; `transformed` of a unit box by a 90 degree yaw keeps its size, by a uniform scale of 2 doubles it; `ViewerPicking.entry(for:partID:pickTag:layer:)` of a quad is hit by `ViewerPicking.nearestHit` with its pick tag while its layer is visible and not when the layer is hidden; framing math of the union contains both boxes (`ViewerOrbitMath.framing`).

**Acceptance checks.** `loadModel` is awaited only on the main actor; a `load` issued while a model loads makes `loadModel` throw `.superseded` and leaves no entity; the log line of a model load gives file size, entity bounds, load time and whether a pick mesh was given.

**SPEC owned.** "OBJECT SCANNING" textured mesh display; "IMAGE / TEXTURE CAPTURE" (the object's photo textures shown as captured). **TEST_PLAN ids.** OBJ-02 (switch textured and untextured), OBJ-01 (the result shows the object).

### 3.35 MeasureTool (wave 5a)

**Purpose.** Measuring inside the finished model (SPEC MEASUREMENT SYSTEM: point-to-point distance, wall length, wall height, ceiling height, angle, surface area, "Users must be able to manually place measurement points", snapping to corner, wall, edge, floor, ceiling, door, window, object edge; SPEC MEASUREMENT CONFIDENCE on every value). Five tools on the result screen's 3D views (Realistic, 3D Clean, Raw Scan):

- Distance: two points.
- Height: the vertical distance between two points (tap the floor, then the ceiling, TEST_PLAN MEAS-03).
- Wall: tap a wall; its length and height come from the edited clean model with RoomPlan confidence.
- Area: three or more points on any surface, closed by tapping the first point again or Finish Area.
- Angle: three points, the middle one the corner (MEAS-07).

Every tapped point snaps through MeasureCore's `SnapSet` built from the edited clean model (corner, then edge, then plane, each tagged with its SPEC target) and otherwise to the nearest vertex of the tapped scan triangle, with a selection haptic and a "Snapped to door" tag; snapping can be switched off to place points freely (MEAS-08). Each endpoint gets Coverage evidence from the room's quality evidence (the snapped wall's camera distance and observation count), and values carry an honest plus-or-minus through `ConfidenceAdapter` and `MeasureDisplay` only. Points of the draft and of saved measurements can be dragged to adjust them (MEAS-01, MEAS-10). Finished measurements are saved at once in `edits/measurements.json` through `EditStore` (raw is never touched), listed with rename and delete, and drawn as SwiftUI overlays positioned with `ViewerModel.project` (no viewer content is added). MeasureTool is a component: Results (3.43b) hosts the overlay above its `ViewerContainer`, routes taps to it and shows its bar and list.

**Build and wave.** Build 5, wave 5a (branch `impl/measuretool`). Core (with CR-1, 3.37a: `CleanFloor.mergedOutlines`), Geometry, Coverage, MeasureCore, Viewer3D (as revised in 5a0, 3.34a), RoomModel (`CleanModelStore.loadEdited`; as revised in 5a0, 3.37b), Quality (`QualityStore.load`), Store (`EditStore`, `ProjectLibrary`), Units, Support; SwiftUI, Combine. About 1350 lines excluding the self-test.

**Files.** `ios/Sources/MeasureTool/MeasureToolModel.swift` (state, loading, saving), `MeasureToolModel+Points.swift` (tap, drag, completion, undo), `MeasureMath.swift` (pure geometry and sigmas), `MeasureToolSnaps.swift` (pure: context, point resolution, room lookup, evidence, values, records), `MeasureToolPresentation.swift` (pure texts and rows), `MeasureToolOverlay.swift` (lines, labels, drag handles), `MeasureToolBar.swift` (tool picker, hint, live value, buttons), `MeasureToolList.swift`, `MeasureToolSelfTest.swift`, `ios/Sources/Support/Copy+MeasureTool.swift`.

**Public Swift API.** Pure types and functions are nonisolated and safe on any queue; the model and views are main actor.
```swift
/// The five tools, in picker order.
enum MeasureToolKind: String, CaseIterable, Identifiable, Sendable {
    case distance, height, wall, area, angle
    var id: String { rawValue }
    /// Points that complete a measurement: distance 2, height 2, wall 1 (the tap on the wall),
    /// area 3 or more (closed by the user), angle 3.
    var minimumPoints: Int { get }
    /// The Core kind of the (first) record it makes: .distance, .height, .wallLength, .area, .angle.
    var measurementKind: MeasurementKind { get }
}

/// One placed point, world meters (the frame of the viewer content: the structure frame for House
/// projects, 3.43b).
struct MeasureToolPoint: Equatable, Sendable {
    var position: SIMD3<Float>
    /// Stored in `MeasurementRecord.snaps`.
    var snap: SnapKind
    /// What a SnapSet snap attached to (drives the "Snapped to" tag); nil for mesh snaps and free points.
    var feature: SnapSetFeature?
    /// The wall, opening, object or room it attached to, when known.
    var element: ElementID?
}

/// The measurement being placed.
struct MeasureToolDraft: Equatable, Sendable {
    var kind: MeasureToolKind
    var points: [MeasureToolPoint]
    /// Live value once there are enough points to show one (area from 3 points, the others when
    /// complete); nil before.
    var value: MeasuredValue?
    static func empty(_ kind: MeasureToolKind) -> MeasureToolDraft
}

/// A point that can be dragged on screen.
enum MeasureToolHandle: Hashable, Sendable {
    case draft(index: Int)
    case record(id: UUID, index: Int)
}

/// Pure geometry and uncertainty of the tools.
enum MeasureMath {
    /// Angle ABC at B, radians in 0...pi; 0 when an arm is shorter than 1 mm.
    static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float
    /// Area of a closed polygon in 3D: half the length of the Newell sum of p_i x p_(i+1). Exact for
    /// planar polygons, the area projected on the best-fit plane otherwise; 0 below 3 points.
    static func polygonArea(_ points: [SIMD3<Float>]) -> Float
    /// Unit normal of the Newell sum; nil below 3 points or for a degenerate polygon.
    static func polygonNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float>?
    /// Label anchor of an area: the vertex mean (never outside a convex polygon).
    static func polygonCenter(_ points: [SIMD3<Float>]) -> SIMD3<Float>
    /// |b.y - a.y|.
    static func verticalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float
    /// 1 sigma of a polygon area, square meters: sqrt(sum_i (s_i |p_(i+1) - p_(i-1)| / 2)^2 + (2 d A)^2),
    /// s_i the point sigmas (meters), d the drift rate (a fraction of length, so an area grows by 2 d).
    static func areaSigma(_ points: [SIMD3<Float>], pointSigmas: [Float], driftRate: Float) -> Float
    /// 1 sigma of the angle at B, radians, a first-order bound:
    /// sqrt((sA / |BA|)^2 + (sC / |BC|)^2 + sB^2 (1 / |BA|^2 + 1 / |BC|^2)).
    static func angleSigma(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           sigmaA: Float, sigmaB: Float, sigmaC: Float) -> Float
}

/// Everything placing a point needs, built off main from the edited clean model and the quality
/// evidence of its rooms. Never mutated after it is built.
struct MeasureToolContext {
    var model: CleanModel
    var snaps: SnapSet
    /// `QualityEvaluation.evidence` per `RoomRecord.id` (`CleanRoom.recordID`).
    var roomEvidence: [UUID: RoomEvidence]
    /// Every room's `WallEvidence` by wall id, so walls keep their evidence after a merge (CR-1).
    var wallEvidence: [ElementID: WallEvidence]
    static let empty: MeasureToolContext
}
/// SnapSet holds tuple arrays and has no Sendable conformance; the context is an immutable value.
extension MeasureToolContext: @unchecked Sendable {}

enum MeasureToolSnaps {
    /// Mesh vertex snap radius, meters.
    static let meshVertexRadius: Float = 0.02
    /// A tap this close on screen to the first area point closes the area, points.
    static let closeRadiusPoints: CGFloat = 24
    /// Most points of one area.
    static let maximumAreaPoints = 50
    /// The context: `SnapSet.build(from:includeObjects: true)` of every room (movable objects removed
    /// from a copy of the room first when `excludeMovable`), plus, for each `floor.mergedOutlines` entry
    /// (CR-1), a set built from a copy of the room whose floor outline is that part and whose walls,
    /// openings and objects are empty (its floor and ceiling planes), all joined with `combined(_:)`;
    /// `wallEvidence` from every room's evidence.
    static func context(model: CleanModel, evidence: [UUID: RoomEvidence], excludeMovable: Bool) -> MeasureToolContext
    /// The candidates of several sets in order, with every parallel array kept in step. A set whose
    /// optional arrays are shorter than its candidates is padded (element nil; feature `.corner`,
    /// `.edge` or `.wall`; region nil).
    static func combined(_ sets: [SnapSet]) -> SnapSet
    /// A tapped point. With snapping on: `context.snaps.hit(hit.position)` when its kind is not `.none`;
    /// else for a `.rawMesh` pick tag the nearest corner of triangle `hit.triangle` of the part
    /// `hit.partID` in `parts` within `meshVertexRadius` (`.meshVertex`), else `.meshSurface`; for an
    /// `.element(id)` pick tag (3D Clean surfaces are RoomPlan surfaces) `.plane` with that element.
    /// With snapping off: `.meshSurface` or `.plane` at `hit.position`, no feature.
    static func resolve(_ hit: ViewerHit, parts: [ViewerPart], context: MeasureToolContext,
                        snapping: Bool) -> MeasureToolPoint
    /// The room whose floor outline or merged outline contains the point in plan (`PlanAxes`), among
    /// rooms whose floor elevation is at most 0.5 m above the point; else the room with the nearest
    /// outline centroid; nil without rooms.
    static func room(containing point: SIMD3<Float>, in model: CleanModel) -> CleanRoom?
    /// Coverage evidence of one endpoint through `ConfidenceAdapter.evidence(distance:observations:room:snap:)`:
    /// the WallEvidence of the snapped wall (an opening uses its host wall), else the point's room
    /// `typicalWall`, else the ConfidenceAdapter defaults; room evidence of the point's room
    /// (`RoomEvidence.unknown` without); snap `ConfidenceAdapter.measurementSnapKind(point.snap)`.
    static func evidence(for point: MeasureToolPoint, context: MeasureToolContext) -> MeasurementEvidence
    /// The value of a draft, nil with too few points. Distance: `ConfidenceAdapter.distance(start:end:length:)`.
    /// Height: the same with `length` = `MeasureMath.verticalDistance`. Area: `MeasureMath.polygonArea`
    /// with `areaSigma` of the point sigmas `MeasurementConfidence.pointAccuracy(_:)` and
    /// `MeasurementConfidence.driftRate(trackingNormalFraction:)` of the lowest endpoint fraction.
    /// Angle: `MeasureMath.angle` with `angleSigma`. Area and angle sigmas are raised to
    /// `ConfidenceAdapter.lowConfidenceSigmaFactor * MeasuredValue.lowConfidenceRelative * value` when any
    /// endpoint `MeasurementConfidence.isWeak(_:)`, so Core's rule (CR-2) flags them. Provenance `.measured`.
    static func value(_ draft: MeasureToolDraft, context: MeasureToolContext) -> MeasuredValue?
    /// The wall a Wall-tool tap refers to: an `.element` pick tag of a wall, the host wall of a picked
    /// opening, or a SnapSet hit whose feature is `.wall`; nil otherwise.
    static func wall(for hit: ViewerHit, context: MeasureToolContext) -> CleanWall?
    /// Wall-tool records: `.wallLength` (points: base start and end; value
    /// `ConfidenceAdapter.roomPlanLength(MeasureRoomSizes.wallLength(wall), wall:, room:, provenance: wall.provenance)`)
    /// and `.height` (points: base start and start + height; value of `wall.height` the same way);
    /// snaps `.edge`, source `.viewer`, empty names, roomID of the wall's room.
    static func wallRecords(_ wall: CleanWall, context: MeasureToolContext, now: Date) -> [MeasurementRecord]
    /// The record of a complete distance, height, area or angle draft: points, snaps, `value`, source
    /// `.viewer`, empty name, roomID of the first point's room; nil when incomplete.
    static func record(for draft: MeasureToolDraft, context: MeasureToolContext, id: UUID, now: Date) -> MeasurementRecord?
    /// A saved record with point `index` moved and its value recomputed (same id, name and createdAt).
    /// `.wallLength` records are returned unchanged (they follow the wall, not the finger).
    static func moving(_ record: MeasurementRecord, index: Int, to point: MeasureToolPoint,
                       context: MeasureToolContext) -> MeasurementRecord
}

/// One row of the measurement list.
struct MeasureToolRow: Identifiable, Equatable, Sendable {
    var id: UUID
    /// The record's name, else the kind title numbered per kind in createdAt order ("Distance 2").
    var title: String
    var valueText: String          // MeasureDisplay.valueText
    var accuracyText: String?      // MeasureDisplay.accuracyText
    var isLowConfidence: Bool      // MeasureDisplay.isLowConfidence(_:kind:)
    var accessibility: String      // MeasureDisplay.accessibilityText(label: title, value:, kind:, prefs:)
}

enum MeasureToolPresentation {
    /// Picker titles: Copy.Measure.distance, Copy.Viewer.height, Copy.WallMenu.title, Copy.MeasureTool.area,
    /// Copy.Measure.angle.
    static func title(of tool: MeasureToolKind) -> String
    /// Row titles by Core kind: distance Copy.Measure.distance, wallLength Copy.Measure.wallLength,
    /// height Copy.Viewer.height, area Copy.Measure.surfaceArea, perimeter Copy.Measure.perimeter,
    /// angle Copy.Measure.angle, volume Copy.Measure.volume (exhaustive switch).
    static func kindTitle(_ kind: MeasurementKind) -> String
    static func rows(_ records: [MeasurementRecord], prefs: UnitPreferences) -> [MeasureToolRow]
    /// The hint for the next tap (Copy.MeasureTool tapFirst, tapSecond, tapWall, areaFirst, areaNext,
    /// areaClose, angleFirst, angleCorner, angleSecond).
    static func hint(_ tool: MeasureToolKind, placed: Int) -> String
    /// `SnapSetFeature.snappedText` of the point's feature; nil without a feature.
    static func snapText(_ point: MeasureToolPoint) -> String?
    /// On-model label lines: `MeasureDisplay.valueText` and `accuracyText`.
    static func label(_ value: MeasuredValue, kind: MeasurementKind, prefs: UnitPreferences) -> (value: String, accuracy: String?)
    /// Log line (category "measure"): kind, every point in millimeters, snaps, value and sigma (MEAS-01, MEAS-08).
    static func logLine(_ record: MeasurementRecord, event: String) -> String
}

/// Main actor. The measuring state of one project on one result screen.
@MainActor final class MeasureToolModel: ObservableObject {
    /// Changing the tool clears the draft.
    @Published var tool: MeasureToolKind
    /// Copy.Measure.snapToggle; on by default.
    @Published var snappingEnabled: Bool
    @Published private(set) var draft: MeasureToolDraft
    /// Saved measurements of the project (all sources), createdAt order.
    @Published private(set) var records: [MeasurementRecord]
    @Published private(set) var rows: [MeasureToolRow]
    @Published private(set) var hint: String
    /// Latest "Snapped to ..." text, cleared after 1.5 s.
    @Published private(set) var snapText: String?
    /// False until the first context is built.
    @Published private(set) var isReady: Bool
    @Published private(set) var prefs: UnitPreferences
    @Published var showsList: Bool
    @Published var showsDeleteAllConfirmation: Bool
    /// `Copy.Errors.saveFailed.body` after a failed write; the screen shows it and clears it.
    @Published var errorText: String?
    let projectID: UUID
    let viewer: ViewerModel
    init(projectID: UUID, viewer: ViewerModel)
    /// Off main: package, `CleanModelStore.loadEdited` (a failure leaves an empty context: points snap
    /// to the scan only, logged), `QualityStore.load(_:room:)` of every distinct `CleanRoom.recordID`,
    /// `EditStore.loadMeasurements`, `UnitPreferences.load()`; then the context. Also subscribes to
    /// `.mapperEditsDidChange` for this project (plan edits move walls): the context is rebuilt, and
    /// the records are reloaded when no write of this model is pending.
    func load() async
    /// Hide Furniture on the result screen: movable objects stop being snap targets (context rebuilt off main).
    func setExcludesMovableObjects(_ exclude: Bool) async
    /// A tap routed by Results while measuring (see Rules).
    func tap(_ hit: ViewerHit?)
    /// Area tool: completes the draft when it has at least 3 points.
    func finishArea()
    /// Removes the last draft point; with an empty draft, reopens the measurement completed last in
    /// this session (removing its saved record; both records of a Wall tap).
    func undoPoint()
    func clearDraft()
    /// Re-places a handle under `screenPoint` (`viewer.hitTest`, then `MeasureToolSnaps.resolve`);
    /// a miss keeps the point.
    func drag(_ handle: MeasureToolHandle, to screenPoint: CGPoint)
    /// A moved record is saved and logged ("measurement edited").
    func endDrag(_ handle: MeasureToolHandle)
    func rename(_ id: UUID, to name: String)
    func delete(_ id: UUID)
    /// After `Copy.MeasureTool.deleteAllTitle` was confirmed.
    func deleteAll()
    /// `viewer.project(world)`; the overlay calls it again whenever `viewer.cameraRevision` changes.
    func screenPoint(_ world: SIMD3<Float>) -> CGPoint?
}

/// Lines, area fills and labels (value and accuracy) of the draft and every saved record, and drag
/// handles (44 pt circles, VoiceOver `Copy.MeasureTool.pointLabel(n)` with `pointHint`). Observes the
/// model and `model.viewer` and redraws on `cameraRevision`. The line and label layer has
/// `.allowsHitTesting(false)`; only the handles take touches, so orbit, pan and tap reach the viewer.
struct MeasureToolOverlay: View { init(model: MeasureToolModel) }
/// Bottom bar: segmented tool picker, hint, live value with accuracy (or Copy.Measure.lowConfidence),
/// snap tag, snapping toggle, Undo (`Copy.Measure.undoPoint`), Finish Area (area with 3 or more points),
/// the list button (`Copy.Results.dimensionsTitle`), and Done (`Copy.Scanning.done`, calls `onDone`).
struct MeasureToolBar: View { init(model: MeasureToolModel, onDone: @escaping () -> Void) }
/// The measurement list, also the main content of Results' Quick Measure screen (3.43b): rows with
/// value and accuracy, swipe to delete, a rename alert, Delete All with confirmation when `onDeleteAll`
/// is set, a Done button when `onClose` is set (sheet use), `Copy.Measure.disclaimer` as the footer,
/// `Copy.Empty.noMeasurements` when empty.
struct MeasureToolList: View {
    init(rows: [MeasureToolRow], onRename: @escaping (UUID, String) -> Void, onDelete: @escaping (UUID) -> Void,
         onDeleteAll: (() -> Void)?, onClose: (() -> Void)?)
}
```
Changes from the earlier short sketch of this section (ARCHITECTURE.md may still show it; this section wins): the model loads its own snaps and evidence (`init(projectID:viewer:)` instead of passing a `SnapSet` and one `RoomEvidence`, because a project has several rooms), `kind` is now `tool: MeasureToolKind`, and a completed measurement is saved at once (no `save(name:)`; names are given by Rename).

**Rules.**

*Tap.* A nil hit sets the hint `Copy.MeasureTool.noSurface` and places nothing. Otherwise the point is `MeasureToolSnaps.resolve(hit, parts: viewer.content.parts, context:, snapping: snappingEnabled)`. A point with a feature fires `Haptics.selection()` and shows `snapText` (MEAS-08). Distance and height complete at 2 points, angle at 3. Area: a tap whose point projects (`screenPoint`) within `closeRadiusPoints` of the first point's projection, with 3 or more points placed, completes the area; otherwise the point is appended (at most `maximumAreaPoints`). Wall: `MeasureToolSnaps.wall(for:context:)` gives `wallRecords`, or the hint `noWall`. After every change `draft.value = MeasureToolSnaps.value(draft, context:)` and the hint follows `MeasureToolPresentation.hint`.

*Completion.* The record (or the two wall records) is appended to `records`, saved, logged with `logLine(_:event: "created")`, `Haptics.tap()` fires, and the draft is cleared (the tool stays). Saving is `EditStore.saveMeasurements(records, to: package)` on a private serial `DispatchQueue` (label "mapper.measuretool.io", QoS utility), so writes land in order and never block main; a failure is logged, sets `errorText` and reloads the records from disk.

*Drag.* Handles exist for draft points and for points of saved distance, height, area and angle records (wall records have none). Each drag event re-resolves the point under the finger; the value updates live; `endDrag` saves a moved record.

*Display.* The overlay draws every saved record and the draft while measuring (Results shows the overlay only in measure mode). Lines: distance and height as a segment (height from the lower point straight up to the upper point's height, then a thin dashed line to the upper point); area as a closed polygon with a translucent fill; angle as two arms with a small arc. Labels sit at the segment middle, the area center or next to the corner, showing `label(_:kind:prefs:)` in two lines. A label or line whose points project to nil (behind the camera) is skipped.

*Confidence.* No sigma is computed outside `ConfidenceAdapter`, `MeasurementConfidence` and `MeasureMath`; no text outside `MeasureDisplay`. RoomPlan-derived wall values keep the 3 cm floor (`roomPlanLength`); free points use Coverage's evidence model; a mesh vertex snap uses `MeasurementSnapKind.vertex` and a free scan surface `.none` (never `.roomSurface`).

**Uses.** Viewer3D: `ViewerModel` (`hitTest(_:)`, `project(_:)`, `cameraRevision`, `content`), `ViewerHit` (`position`, `partID`, `triangle`, `pickTag`), `ViewerPickTag`, `ViewerPart` (`id`, `positions`, `indices`). MeasureCore: `SnapSet` (`build(from:includeObjects:)`, `hit(_:)`, `empty`, `corners`, `cornerElements`, `cornerFeatures`, `edges`, `edgeElements`, `edgeFeatures`, `planes`, `planeElements`, `planeFeatures`, `planeRegions`), `SnapSetHit`, `SnapSetFeature` (`snappedText`), `ConfidenceAdapter` (`distance(start:end:length:)`, `roomPlanLength(_:wall:room:provenance:)`, `evidence(distance:observations:room:snap:)`, `measurementSnapKind(_:)`, `lowConfidenceSigmaFactor`), `RoomEvidence` (`wall(_:)`, `typicalWall`, `unknown`), `WallEvidence`, `MeasureDisplay` (`valueText`, `accuracyText`, `isLowConfidence(_:kind:)`, `accessibilityText(label:value:kind:prefs:)`), `MeasureRoomSizes.wallLength(_:)`. Coverage: `MeasurementEvidence`, `MeasurementSnapKind`, `MeasurementConfidence` (`pointAccuracy(_:)`, `driftRate(trackingNormalFraction:)`, `isWeak(_:)`). RoomModel: `CleanModelStore.loadEdited(_:)`. Quality: `QualityStore.load(_:room:)`, `QualityEvaluation.evidence`. Store: `EditStore` (`loadMeasurements`, `saveMeasurements(_:to:)`), `ProjectLibrary.shared.package(for:)`, `Notification.Name.mapperEditsDidChange`. Geometry: `Polygon2D` (`contains(point:)`, `centroid`). Core: `CleanModel`, `CleanRoom`, `CleanWall`, `CleanOpening`, `CleanFloor` (`mergedOutlines`, CR-1), `DetectedObject`, `MeasurementRecord`, `MeasurementKind`, `MeasuredValue` (`lowConfidenceRelative`), `SnapKind`, `MeasurementSource.viewer`, `ElementID`, `Vec3`, `PlanAxes.toPlan(_:)`. Units: `UnitPreferences.load(from:)`. Support: `Haptics.selection()`, `Haptics.tap()`, `LogStore` (category "measure"), Copy as listed below.

**Apple APIs.** SwiftUI `Canvas` (RESEARCH 3.6: `struct Canvas<Symbols>`, iOS 15.0) for lines and fills; `DragGesture` with `init(minimumDistance: CGFloat = 10, coordinateSpace: some CoordinateSpaceProtocol = .local)` (RESEARCH 3.6, iOS 17.0; handles use `minimumDistance: 0`); `Picker` with `.pickerStyle(.segmented)` (RESEARCH 3.10); not in RESEARCH: `.swipeActions` and `.confirmationDialog` (iOS 15), `.alert(_:isPresented:actions:)` with a `TextField` inside (iOS 16), `NotificationCenter.default.publisher(for:object:)` (Combine, iOS 13), `DispatchQueue(label:qos:)` (iOS 8).

**Must NOT do.** Never write raw data, the edit log or any file but `edits/measurements.json` (through `EditStore`). Never add parts to the viewer or call `viewer.load` (overlays only). Never show a value without the accuracy text, `Copy.Measure.lowConfidence` or `Copy.Measure.notMeasured` from `MeasureDisplay`, and never format a number outside Units. Never call a mesh vertex a corner (no snap tag for mesh snaps). Never measure a curved wall by its chord (`MeasureRoomSizes.wallLength`). Never block main on disk. No SceneKit, no `Scene.raycast`, no collision components. No hardcoded text.

**Copy strings.** Existing: `Copy.Measure.title`, `distance`, `wallLength`, `surfaceArea`, `perimeter`, `angle`, `volume`, `undoPoint`, `snapToggle`, `snapTargets` and `snapped(to:)` (through `SnapSetFeature.snappedText`), `lowConfidence`, `notMeasured`, `accuracy(_:)` (through MeasureDisplay), `disclaimer`; `Copy.Viewer.height`; `Copy.WallMenu.title`; `Copy.Scanning.done`; `Copy.Results.dimensionsTitle`; `Copy.Empty.noMeasurements`; `Copy.Project.rename`, `delete`, `cancel`; `Copy.Errors.saveFailed`, `ok`; `Copy.A11y.measurement(_:value:)` (through MeasureDisplay). New in `Copy+MeasureTool.swift` (`extension Copy { enum MeasureTool }`):
- `area = "Area"`
- `tapFirst = "Tap where the measurement starts"`, `tapSecond = "Now tap where it ends"`
- `tapWall = "Tap a wall"`, `noWall = "That isn't a wall. Tap a wall"`
- `areaFirst = "Tap the first corner of the area"`, `areaNext = "Tap the next corner"`, `areaClose = "Tap the first point again, or tap Finish Area"`
- `finishArea = "Finish Area"`
- `angleFirst = "Tap a point on the first side"`, `angleCorner = "Tap the corner"`, `angleSecond = "Tap a point on the second side"`
- `noSurface = "Tap on the model"`
- `static func numbered(_ title: String, _ n: Int) -> String { "\(title) \(n)" }`
- `renameTitle = "Rename Measurement"`, `namePlaceholder = "Measurement name"`
- `deleteAll = "Delete All"`, `deleteAllTitle = "Delete all measurements?"`, `deleteAllBody = "Only the measurements you made in this model are removed. Your scan is not affected."`
- `static func pointLabel(_ n: Int) -> String { "Point \(n)" }`, `pointHint = "Drag to move this point"`

**Self-test.** `MeasureToolSelfTest.run()`, at least 28 checks, fixtures built by hand (a 4 x 5 x 2.5 m clean room with a door, a window and a sofa; a second 2 x 2 m part in `mergedOutlines`; synthetic `ViewerPart`s and `ViewerHit`s; no ARView):
1. `angle` of (1,0,0), (0,0,0), (0,0,1) is pi / 2 within 1e-5; collinear points give pi; a 0.5 mm arm gives 0.
2. `polygonArea` of a 2 x 3 m rectangle on the floor is 6 within 1e-5, the same rectangle tilted 30 degrees is 6, a right triangle with legs 1 m is 0.5, two points give 0.
3. `polygonCenter` of the rectangle is its center; `polygonNormal` of the floor rectangle is (0, plus or minus 1, 0).
4. `verticalDistance` of (0, 0.1, 0) and (1, 2.6, 3) is 2.5.
5. `areaSigma` with zero sigmas and zero drift is 0; four sigmas of 0.01 on a 1 x 1 m square give 0.01 within 1e-5; a drift of 0.01 adds (0.02)^2 under the root.
6. `angleSigma` is larger with 0.5 m arms than with 2 m arms.
7. `combined` of the two room sets keeps every parallel array the same length as its candidate array.
8. A point 3 cm from a floor corner resolves to `.corner` with feature `.corner`; 2 cm from a wall and 1 m from its edges to `.plane` with feature `.wall` and that wall's element.
9. With `excludeMovable` a point 2 cm from a sofa box corner no longer snaps to a feature `.objectEdge`.
10. A point 2 cm above the floor of the merged part resolves to `.plane` with feature `.floor`.
11. A `.rawMesh` hit 1 cm from a triangle corner, far from the room, resolves to `.meshVertex` at that corner; 5 cm away to `.meshSurface`; with snapping off to `.meshSurface` at the hit position with no feature.
12. An `.element(wall)` hit far from every snap candidate resolves to `.plane` with that element.
13. `room(containing:)` picks the room whose outline holds the point; with two stacked rooms it picks the lower one for a point 0.1 m above the lower floor.
14. `evidence`: a point snapped to wall W uses W's `medianDistance` and `observations`; a point snapped to the door uses its host wall's; a free point uses the room's `typicalWall`; without evidence the distance is 2.0 m and the observations 3.
15. A 2.0 m distance with good evidence has a sigma above 0 and `MeasureDisplay.isLowConfidence(_:kind: .distance)` false; with tracking fraction 0.3 it is true.
16. A height draft's value equals `verticalDistance` of its points.
17. An area draft has a value at 3 points and none at 2.
18. An angle whose corner evidence has 0 observations is low confidence (`isLowConfidence(kind: .angle)`).
19. `wallRecords` of a 4 m by 2.5 m wall gives `.wallLength` 4 and `.height` 2.5, each with sigma at least 0.015.
20. `wallRecords` of a curved wall uses the arc length (larger than the chord).
21. `record(for:)` of a distance draft has 2 points, 2 snaps, source `.viewer` and the roomID of the first point's room.
22. `moving` a distance record changes its value and keeps id, name and createdAt; moving a `.wallLength` record returns it unchanged.
23. `rows` of two distances and one area, none named, titles "Distance 1", "Distance 2", "Surface area 1" (built with `Copy.MeasureTool.numbered` and `kindTitle`); a named record keeps its name.
24. Every row of a measured record has an accuracy text that is `Copy.Measure.lowConfidence` or contains exactly one plus-minus sign.
25. `hint` texts are non-empty and distinct for every tool and placed count used by the model.
26. `snapText` of a point with feature `.door` equals `Copy.Measure.snapped(to: "door")`; a mesh point gives nil.
27. `kindTitle` is non-empty for every `MeasurementKind.allCases`; `minimumPoints` and `measurementKind` match the table above.
28. `EditStore.saveMeasurements` then `loadMeasurements` of three records made by this module round trip in a temporary package.
29. `logLine` contains the kind raw value and each point in whole millimeters.

**Acceptance checks.** Measuring never changes raw data or the edit log (PEDIT rule, smoke #8 raw check); every value on screen shows its accuracy text or the low-confidence text; snapping order is corner, edge, plane, then mesh vertex; the overlay passes every touch but the handles to the viewer; a completed measurement appears in the list at once and survives closing and reopening the project (MEAS-10); the log has one "created", "edited" or "deleted" line per change with points, value, sigma and snap targets; all text from Copy.

**SPEC owned.** "MEASUREMENT SYSTEM": point-to-point distance, wall length, wall height, ceiling height (Height tool), angle, surface area (Area tool), "Users must be able to manually place measurement points", "Use snapping when appropriate" (corner, wall, edge, floor, ceiling, door, window, object edge), unit switching through MeasureDisplay; "MEASUREMENT CONFIDENCE" in the tool (plus-or-minus, "Low confidence, rescan this section", no survey-grade wording); "3D EDITING" Object: Measure and Wall: Measure (the Distance and Wall tools; the menus arrive in build 7); deliverables 5, 8 and 11.

**TEST_PLAN ids.** MEAS-01, MEAS-02, MEAS-03, MEAS-06 (surface area), MEAS-07, MEAS-08, MEAS-09, MEAS-10, MEAS-11 (object box edges), CONF-01 to CONF-04, OFF-01 (measuring inside the model), smoke #7.

### 3.36 LiveMeasure (wave 5a)

**Purpose.** Quick Measure: measure distances in the live camera without scanning a room. An `ARView` in `.ar` mode on its own `ARSessionHub` with `ScanProfile(mode: .quickMeasure, settings: ScanSettings.defaults(for: .quickMeasure))` (plane detection on, the only mode where it is, D14), a fixed center reticle and a large Add Point button (RESEARCH 3.10 measurement tool), snapping in the RESEARCH 3.8 order (existing points, plane corners from `ARPlaneAnchor` extents and plane-plane-floor intersections, then `.existingPlaneGeometry`, then `.estimatedPlane`) within the smaller of 10 cm in the world and 24 pt on screen, a live length label, plus or minus from `ConfidenceAdapter.distance` with evidence from the center depth samples, and Save, which creates a `.quickMeasure` project holding `raw/measure/quick.json` and a thumbnail. Nothing is recorded before Save and no raw ARKit data is recorded at all.

**Build and wave.** Build 5, wave 5a. Core, CaptureCore, MeasureCore, Store, GuidanceUI, Coverage (`MeasurementEvidence`, `MeasurementSnapKind`, `GuidanceEngine`), Geometry (`Plane`), Pipeline (`IdleTimerGuard`), ScanUI (`ScanFlowModel.defaultProjectName(mode:now:)` only), Units, Support; ARKit, RealityKit, SwiftUI, UIKit. It must not reference LiveMeshView (same wave): it has its own small container. About 1300 lines plus the self-test.

**Files.** `ios/Sources/LiveMeasure/LiveMeasureModel.swift` (the `@MainActor` model: hub, points, reticle loop), `LiveMeasureModel+Save.swift` (project creation, file, thumbnail), `LiveMeasureProbe.swift` (hub recorder: plane anchors and center depth samples), `LiveMeasureSnapping.swift` (pure: plane corners, candidate choice, evidence, tags), `LiveMeasureStore.swift` (`QuickMeasureFile`, `QuickMeasureStore`), `LiveMeasureContainer.swift`, `LiveMeasureScreen.swift`, `LiveMeasureSelfTest.swift`, `ios/Sources/Support/Copy+LiveMeasure.swift`.

**Public Swift API.**
```swift
enum LiveMeasurePlaneFacing: Equatable, Sendable { case horizontal, vertical }
enum LiveMeasurePlaneKind: Equatable, Sendable { case wall, floor, ceiling, table, seat, door, window, unknown }
/// An `ARPlaneAnchor` copied on the hub queue (the anchor itself is never kept).
struct LiveMeasurePlane: Equatable, Sendable {
    var id: UUID
    /// Anchor to world.
    var transform: simd_float4x4
    /// Anchor-local center of the extent.
    var center: SIMD3<Float>
    /// `planeExtent.width` (local x) and `planeExtent.height` (local z), meters.
    var width: Float
    var length: Float
    /// `planeExtent.rotationOnYAxis`, radians (applied by us, RESEARCH 3.1 gotcha 17).
    var rotationOnYAxis: Float
    var facing: LiveMeasurePlaneFacing
    var kind: LiveMeasurePlaneKind
}
/// One center-of-view sample (10 Hz).
struct LiveMeasureDepthSample: Equatable, Sendable {
    var timestamp: Double
    /// `ARFrameReading.centerDepth(of:)`: median depth of the 5 x 5 center pixels and their confidence 0...1.
    var distance: Float?
    var confidence: Float?
    var trackingNormal: Bool
    var cameraToWorld: simd_float4x4
}

/// Hub recorder of Quick Measure: copies plane anchors and 10 Hz center samples; records nothing.
/// Callbacks on the hub queue; readers lock-protected, any thread.
final class LiveMeasureProbe: ScanRecorder {
    static let sampleInterval: TimeInterval = 0.1
    /// Samples kept, seconds.
    static let windowSeconds: Double = 5
    init()
    /// Unused (Quick Measure has no raw folder); resets the samples.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor])
    /// Calls `completion` at once.
    func finishRecording(completion: @escaping () -> Void)
    var stats: RecorderStats { get }
    func planes() -> [LiveMeasurePlane]
    func recentSamples() -> [LiveMeasureDepthSample]
    /// Main-queue callbacks carrying values only.
    var onGuidance: ((GuidanceKind?) -> Void)?
    var onRelocalization: (() -> Void)?
    /// Installs the hub's `onStatus` (guidance through a `GuidanceEngine` confined to hub.queue, then
    /// `LiveMeasureSnapping.filterGuidance`, then `onGuidance` on main) and `onCaptureEvent`
    /// (`.relocalization` events to `onRelocalization` on main), both capturing `self` weakly. The
    /// probe is a plain class, so these closures are formed outside any actor; the `@MainActor` model
    /// never forms hub-queue closures itself. The first frame after install calls
    /// `hub.markScanStart(timestamp:)`.
    func install(on hub: ARSessionHub)
    /// Clears the two hub closures. Idempotent.
    func uninstall(from hub: ARSessionHub)
    /// Hub queue. The value copy of one plane anchor (ARKit).
    static func planeRecord(from anchor: ARPlaneAnchor) -> LiveMeasurePlane
    /// Pure mapping; `.none(_)` and unknown cases give `.unknown`.
    static func kind(_ classification: ARPlaneAnchor.Classification) -> LiveMeasurePlaneKind
}

/// Where a snapped point came from, in priority order.
enum LiveMeasureSnapSource: Int, Comparable, Sendable {
    case existingPoint = 0, planeCorner, planeGeometry, estimatedPlane
    static func < (lhs: LiveMeasureSnapSource, rhs: LiveMeasureSnapSource) -> Bool
}
/// Tags shown as "Snapped to {target}"; raw values index `Copy.Measure.snapTargets`.
enum LiveMeasureSnapTag: Int, CaseIterable, Sendable {
    case corner = 0, wall, edge, floor, ceiling, door, window, objectEdge
    /// `Copy.Measure.snapTargets[rawValue]`, bounds-checked (empty string when out of range).
    var target: String { get }
}
struct LiveMeasureCandidate: Equatable {
    var point: SIMD3<Float>
    /// `arView.project(point)`, nil when behind the camera.
    var screen: CGPoint?
    var source: LiveMeasureSnapSource
    var snap: SnapKind
    var tag: LiveMeasureSnapTag?
}
struct LiveMeasureResolution: Equatable {
    var point: SIMD3<Float>
    var source: LiveMeasureSnapSource
    var snap: SnapKind
    var measurementSnap: MeasurementSnapKind
    var tag: LiveMeasureSnapTag?
    /// True for existing points and plane corners (a haptic and the "Snapped to" tag).
    var isSnapped: Bool
}

/// Snapping, plane corners and evidence. Pure.
enum LiveMeasureSnapping {
    static let worldRadius: Float = 0.10
    static let screenRadius: CGFloat = 24
    /// A plane intersection counts as a corner within this distance of all three extents.
    static let cornerExtentSlack: Float = 0.30
    /// Corners farther than this from the camera are not offered.
    static let maxCornerDistance: Float = 4
    /// The 4 extent corners in world space: center plus the rotated half extents in the anchor's x-z plane, through `transform`.
    static func extentCorners(_ plane: LiveMeasurePlane) -> [SIMD3<Float>]
    /// Geometry `Plane` through the world extent center with the anchor's y axis as the normal.
    static func worldPlane(_ plane: LiveMeasurePlane) -> Plane
    /// `Plane.intersection(_:_:_:)` of every pair of vertical planes whose normals differ by more than
    /// 45 degrees with every horizontal plane, kept within `cornerExtentSlack` of all three extents.
    static func intersectionCorners(_ planes: [LiveMeasurePlane]) -> [SIMD3<Float>]
    /// Corner candidates (extent corners of every plane, then intersections) within `maxCornerDistance` of `camera`.
    static func cornerPoints(_ planes: [LiveMeasurePlane], camera: SIMD3<Float>) -> [SIMD3<Float>]
    /// Existing points, then plane corners: the nearest on screen among those within `worldRadius` of the
    /// ray hit (`hit.point`) and within `screenRadius` of `reticle` (when projected); else `hit` (plane
    /// geometry); else `fallback` (estimated plane); else nil.
    static func resolve(hit: LiveMeasureCandidate?, fallback: LiveMeasureCandidate?, candidates: [LiveMeasureCandidate],
                        reticle: CGPoint) -> LiveMeasureResolution?
    /// wall -> .wall, floor -> .floor, ceiling -> .ceiling, door -> .door, window -> .window,
    /// table and seat -> .objectEdge, unknown -> nil.
    static func tag(for kind: LiveMeasurePlaneKind) -> LiveMeasureSnapTag?
    /// existingPoint keeps the snapped point's kind; planeCorner and planeGeometry -> .plane; estimatedPlane -> .none.
    static func measurementSnap(for source: LiveMeasureSnapSource, inherited: MeasurementSnapKind?) -> MeasurementSnapKind
    /// Evidence at commit time: distance from the latest camera to `point`; observations = recent
    /// samples (last second) whose depth is within 2 cm of the latest, 1...9; confidence = their mean
    /// when the latest depth is within 5 cm of that distance, else nil; tracking fraction over the window.
    static func evidence(point: SIMD3<Float>, samples: [LiveMeasureDepthSample], snap: MeasurementSnapKind,
                         now: Double) -> MeasurementEvidence
    /// Tier 1 messages only (Quick Measure is not a coverage scan).
    static func filterGuidance(_ output: GuidanceOutput) -> GuidanceOutput
    /// The Mapper guidance input from a hub status (tracking, speeds, distance, light, depth confidence, heat).
    static func guidanceInput(time: Double, status: HubStatus) -> GuidanceInput
}

struct LiveMeasurePoint {
    var position: SIMD3<Float>
    var snap: SnapKind
    var evidence: MeasurementEvidence
}
struct LiveMeasureSegment: Identifiable {
    let id: UUID
    var start: LiveMeasurePoint
    var end: LiveMeasurePoint
    /// `ConfidenceAdapter.distance(start:end:length:)`.
    var value: MeasuredValue
    var createdAt: Date
    /// kind .distance, the two points and snaps, source .live, name "", roomID nil.
    func record() -> MeasurementRecord
}
enum LiveMeasurePhase: Equatable { case starting, measuring, saving, saved(UUID), failed(String) }

@MainActor final class LiveMeasureModel: ObservableObject {
    /// Reticle refresh rate, Hz.
    static let reticleHz: Double = 15
    @Published private(set) var phase: LiveMeasurePhase
    @Published private(set) var segments: [LiveMeasureSegment]
    @Published private(set) var pending: LiveMeasurePoint?
    @Published private(set) var reticle: LiveMeasureResolution?
    /// Pending point to reticle, while a point is pending.
    @Published private(set) var liveValue: MeasuredValue?
    /// Screen points of segment midpoints and endpoints for labels and lines (refreshed with the reticle).
    @Published private(set) var screenPoints: [UUID: (start: CGPoint?, end: CGPoint?, middle: CGPoint?)]
    @Published private(set) var guidance: GuidanceKind?
    @Published var snappingEnabled: Bool
    @Published var showsDiscardConfirmation: Bool
    @Published var alert: String?
    let hub: ARSessionHub
    let prefs: UnitPreferences
    /// Called with the new project id after Save.
    var onComplete: ((UUID) -> Void)?
    /// Called when the screen closes without saving.
    var onDismiss: (() -> Void)?
    init()
    /// Main. The container's view (kept weakly); starts the reticle loop.
    func attach(_ arView: ARView)
    /// Main. `hub.install()`, `hub.attach(probe)`, `probe.install(on: hub)`, `hub.run()`, an IdleTimerGuard token.
    func start()
    func addPoint()
    /// Removes the pending point, else reopens the last segment's end.
    func undo()
    func clearAll()
    /// Creates the project and files (below); phase `.saved(id)` then `onComplete`.
    func save()
    /// Asks to discard unsaved segments, else closes.
    func close()
    func confirmDiscard()
    /// Main, idempotent: loop stopped, `hub.pause()`, probe detached, hub closures nil, token released.
    func teardown()
    /// Value, accuracy and VoiceOver texts through MeasureDisplay.
    func valueText(_ value: MeasuredValue) -> String
    func accuracyText(_ value: MeasuredValue) -> String?
}

/// `raw/measure/quick.json` (`ProjectPackage.quickMeasureURL`).
struct QuickMeasureFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var createdAt: Date
    var records: [MeasurementRecord]
}
enum QuickMeasureStore {
    static let maxBytes: Int64 = 4 * 1024 * 1024
    /// raw/measure/.
    static func folder(_ package: ProjectPackage) -> URL
    /// Makes raw/measure/ with `ProjectStore.ensureDirectory(_:inside: package.root)`, writes quick.json with
    /// `ProjectStore.writeJSON(_:to:createParents: false)`, then seals the folder (`ProjectStore.sealRawFolder`).
    /// Throws when the package is gone.
    static func save(_ records: [MeasurementRecord], to package: ProjectPackage, now: Date) throws
    /// Nil when absent or unreadable (logged); reads with `maxBytes`.
    static func load(_ package: ProjectPackage) -> QuickMeasureFile?
}

/// ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false) on `model.hub.session`,
/// `hub.install()` right after, coaching overlay (goal `.tracking`), then `model.attach(_:)`.
struct LiveMeasureContainer: UIViewRepresentable {
    init(model: LiveMeasureModel)
}
/// Reticle, segment lines and labels (value plus accuracy), live label, "Snapped to" tag, hint
/// (aim or next), guidance banner, Undo, Add Point, Save, Clear All, Close; forced dark.
struct LiveMeasureScreen: View { init(model: LiveMeasureModel) }
```

Reticle loop (main, `Task` with `Task.sleep(nanoseconds:)` at `reticleHz`): with the view attached and phase `.measuring`: the view center; `arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any).first` gives the plane-geometry candidate (tag from the hit's `anchor` when it is an `ARPlaneAnchor`, looked up by identifier in `probe.planes()`), `arView.raycast(from: center, allowing: .estimatedPlane, alignment: .any).first` the fallback; candidates are the committed and pending points and, refreshed every fifth tick, `cornerPoints(probe.planes(), camera:)`, each with `arView.project(_:)`; with snapping off only the two raycast hits count. `resolve` gives the reticle; a newly snapped candidate fires `Haptics.selection()`. The live value is the pending point to the reticle with evidence from `evidence(point:samples:snap:now:)`. Add Point commits the reticle (nothing without one), fires `Haptics.tap()`, and closes a segment when a point was pending (non-chained: the next point starts a new measurement; snapping to an existing point chains them by hand).

Guidance: the probe's `onStatus` closure runs `guidanceInput(time:status:)` through a `GuidanceEngine` confined to hub.queue, then `filterGuidance`, then `onGuidance` on main. A `.relocalization` capture event while points exist sets `alert` to `Copy.LiveMeasure.relocalized`.

Save (`LiveMeasureModel+Save.swift`, main, with the file work in a detached task): `ProjectLibrary.shared.create(kind: .quickMeasure, name: ScanFlowModel.defaultProjectName(mode: .quickMeasure, now: Date()))` ("Measurement Sep 28", named at creation as ScanUI names rooms); `QuickMeasureStore.save(segments.map { $0.record() }, to: package, now: Date())`; then, as soon as quick.json is sealed, `ProjectLibrary.shared.update(id) { $0.status = .ready }` (a Quick Measure project has nothing to process; a kill between create and this update leaves a `.capturing` project that AppShell's recovery sets `.ready` when quick.json exists and deletes when it does not, 3.43e); `arView.snapshot(saveToHDR: false)` to `jpegData(compressionQuality: 0.7)` written with `ProjectStore.writeData(_:to: package.thumbnailURL)` (best effort, logged); then `teardown()` and `onComplete(id)`. A failure deletes the new project (`ProjectLibrary.shared.delete`), shows `Copy.Errors.saveFailed` and keeps the segments on screen.

**Uses.** CaptureCore: `ARSessionHub` (`init(profile:)`, `install()`, `run(options:)`, `pause()`, `attach(_:)`, `detach(_:)`, `markScanStart(timestamp:)`, `onStatus`, `onFrame`, `onCaptureEvent`, `queue`), `ScanRecorder`, `ScanProfile` (`wantsPlaneDetection`), `HubStatus`, `RecorderStats`, `ARFrameReading.centerDepth(of:)`, `TrackingMonitor.summary(_:)`. MeasureCore: `ConfidenceAdapter.distance(start:end:length:)`, `MeasureDisplay.valueText(_:kind:prefs:)`, `accuracyText(_:kind:prefs:)`, `accessibilityText(label:value:kind:prefs:)`, `isLowConfidence(_:kind:)`. Coverage: `MeasurementEvidence`, `MeasurementSnapKind`, `GuidanceEngine`, `GuidanceInput`, `GuidanceOutput`. GuidanceUI: `GuidanceSignals.tracking(_:)`, `GuidanceBanner`, `GuidanceAnnouncer`. Store: `ProjectLibrary` (`create(kind:name:)`, `update(_:_:)`, `delete(_:)`, `package(for:)`). Geometry: `Plane` (`init(point:normal:)`, `intersection(_:_:_:)`, `signedDistance(to:)`). Units: `UnitPreferences.load(from:)`. Pipeline: `IdleTimerGuard`. ScanUI: `ScanFlowModel.defaultProjectName(mode:now:)`. Core: `MeasurementRecord`, `MeasurementKind`, `MeasuredValue`, `SnapKind`, `MeasurementSource`, `Vec3`, `ScanMode`, `ScanSettings.defaults(for:)`, `ProjectPackage` (`quickMeasureURL`, `thumbnailURL`, `rawURL`), `ProjectStore` (`ensureDirectory(_:inside:)`, `writeJSON(_:to:protection:createParents:)`, `readJSON(_:from:maxBytes:)`, `writeData(_:to:protection:createParents:)`, `sealRawFolder(_:now:)`, `encoder`, `decoder`), `CaptureEvent`. Support: `Copy.Measure`, `Copy.Modes.quickMeasure`, `Copy.Errors.saveFailed`, `Copy.A11y` (`crosshair`, `crosshairHint`, `close`, `measurement(_:value:)`), `Haptics.selection()`, `Haptics.tap()`, `LogStore`.

**Apple APIs** (RESEARCH 3.1, 3.5, 3.8, 3.10):
```swift
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)
dynamic var session: ARSession { get set }
@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target,
                                        alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]   // view points, nearest first
// Target: existingPlaneGeometry, estimatedPlane. Alignment: any.
// ARRaycastResult: worldTransform, anchor (nil for estimatedPlane unless an existing plane is hit)
@MainActor @preconcurrency func project(_ point: SIMD3<Float>) -> CGPoint?
@MainActor @preconcurrency func snapshot(saveToHDR: Bool, completion: @escaping (ARView.Image?) -> Void)
var cameraTransform: Transform { get }                           // ARView
// ARPlaneAnchor: alignment, center, geometry (not used), classification: ARPlaneAnchor.Classification (iOS 12.0)
var planeExtent: ARPlaneExtent { get }                           // iOS 16.0 (width, height, rotationOnYAxis)
class ARCoachingOverlayView                                      // iOS 13.0: goal, activatesAutomatically, setActive(_:animated:)
var planeDetection: ARWorldTrackingConfiguration.PlaneDetection  // [.horizontal, .vertical] through ScanConfigurationFactory only
```
Not in RESEARCH (checked against Apple's documentation JSON): `ARPlaneAnchor.Classification` cases `wall`, `floor`, `ceiling`, `table`, `seat`, `door`, `window`, `none(_:)` (iOS 12.0; switch with `@unknown default`); `ARPlaneExtent` `var width: Float`, `var height: Float`, `var rotationOnYAxis: Float { get }` (iOS 16.0); `ARPlaneAnchor.Alignment` `.horizontal`, `.vertical` (iOS 11.0); `var session: ARSession?` and `goal` on `ARCoachingOverlayView` (iOS 13.0); `Transform.matrix` (RealityKit, iOS 13); `UIImage.jpegData(compressionQuality:)` (iOS 2); `Task.sleep(nanoseconds:)` (iOS 13).

**Must NOT do.** Never record raw ARKit data (no MeshStore, keyframes, pose track or InProgress folder). Never turn on plane detection in any other mode (the profile's mode is `.quickMeasure` only here, D14). Never create the project before Save, never leave it in `.capturing`. Never keep an `ARPlaneAnchor` or `ARFrame`. Never use `ARFrame.hitTest(_:types:)` or `ARPlaneAnchor.extent` (deprecated), never pass view points to `ARFrame.raycastQuery` (it takes normalized points). Never raycast off main. Never show a plus-minus that did not come through `MeasureDisplay`, never format a length without Units. Never show tier 2 or 3 guidance here. Never write `isIdleTimerDisabled`. No hardcoded text.

**Copy strings.** Existing: `Copy.Modes.quickMeasure` (title), `Copy.Measure.addPoint`, `undoPoint`, `clearAll`, `save`, `distance`, `aimHint`, `nextHint`, `snapToggle`, `snapTargets`, `snapped(to:)`, `accuracy(_:)` (through MeasureDisplay), `lowConfidence`, `disclaimer`; `Copy.Errors.saveFailed`; `Copy.A11y.crosshair`, `crosshairHint`, `close`, `measurement(_:value:)`; `Copy.Scanning.cancelConfirmKeep`. New (`extension Copy { enum LiveMeasure }` in `Copy+LiveMeasure.swift`): `noSurface = "Point at a surface"`, `findingSurfaces = "Move your iPhone slowly to find surfaces"`, `listTitle = "Measurements"`, `static func itemTitle(_ n: Int) -> String { "Distance \(n)" }`, `discardTitle = "Discard these measurements?"`, `discardBody = "They haven't been saved yet."`, `discardConfirm = "Discard"`, `saving = "Saving..."`, `relocalized = "Tracking was lost for a moment. Check your points, or clear them and measure again."`, `static func a11yLive(_ value: String) -> String { "Current distance, \(value)" }`.

**Self-test.** `LiveMeasureSelfTest.run()`, at least 20 checks:
1. `extentCorners` of a horizontal 1 x 2 m plane at the origin, rotation 0: corners (plus or minus 0.5, 0, plus or minus 1).
2. Rotation pi / 2 swaps the extents; a translation of (0, 0.75, 0) lifts every corner.
3. `intersectionCorners`: walls x = 0 and z = 0 (4 m extents) with a floor y = 0 give the corner (0, 0, 0).
4. Two parallel walls give no corner; a corner 1 m outside an extent is dropped.
5. `resolve`: an existing point 5 cm from the hit and a corner 3 cm from it: the existing point wins.
6. A corner 12 cm away in the world is not snapped (falls back to the plane-geometry hit).
7. A corner 8 cm away but 40 pt from the reticle on screen is not snapped.
8. No hit and a fallback: source `.estimatedPlane`, snap `.none`, measurementSnap `.none`, not snapped.
9. No hit and no fallback: nil.
10. `tag(for: .wall)` target equals `Copy.Measure.snapTargets[1]`; corner equals index 0; unknown gives nil.
11. `kind(_:)` for `.wall`, `.floor`, `.table` and `.none(.unknown)` (values built without ARKit running).
12. `evidence`: ten samples at 1.00 to 1.01 m give observations 9 and a confidence; half the window not normal gives trackingNormalFraction 0.5.
13. `evidence` without samples: observations 1, depthConfidence nil, distance equals the camera distance.
14. A 1.0 m segment with good evidence gives a sigma above 0 and `MeasureDisplay.isLowConfidence` false; with tracking fraction 0.3 it is true.
15. `record()`: kind `.distance`, 2 points, 2 snaps, source `.live`, roomID nil.
16. `QuickMeasureFile` round trip through `ProjectStore.encoder` and `decoder`.
17. `QuickMeasureStore.save` in a temporary package writes quick.json and SEAL.json listing it; `load` returns the records.
18. `save` into a deleted package throws and creates nothing.
19. `filterGuidance` keeps `.moveSlower` and drops `.moveCloser` and `.doorDetected`.
20. `guidanceInput` copies the status fields and sets deviceHot at serious.
21. `measurementSnap`: a point snapped to an existing point inherits `.plane`; a plane corner gives `.plane`.

**Acceptance checks.** The model is the only owner of its hub; the hub is paused on every exit (PERF-14: the camera indicator goes off); the probe copies anchors inside the callback; raycasts and projections run on main only; the reticle loop stops on teardown; Save leaves no project in `.capturing` and quick.json is sealed; the log has one line per saved measurement with both points, the value and sigma (MODE-06 "Log").

**SPEC owned.** "SCANNING MODES" QUICK MEASURE; "MEASUREMENT SYSTEM" (point-to-point distance in the live camera; "Users must be able to manually place measurement points"; snapping to corner, wall, floor, ceiling, door, window and edge live); "MEASUREMENT CONFIDENCE" (plus or minus and "Low confidence, rescan this section" on live measurements; no survey-grade wording).

**TEST_PLAN ids.** MODE-06, MEAS-08 (live variant), MEAS-09, CONF-01, CONF-03, CONF-04, smoke list #6, PERF-14.

### 3.37 PlanEditor (wave 5a)

**Purpose.** Floor plan editing through the one EditLog (D3, SPEC FLOOR PLAN EDITING, "Manual edits must not overwrite raw scan data"): a full-screen editor opened from the Floor Plan tab (Results 3.43b) with Undo, Redo, Reset to Scan and Done Editing. Every user action becomes exactly one log entry (one operation, or one `batch` of operations, CR-1), so one Undo reverts the whole action, and the same entry is replayed by RoomModel on the clean model and by FloorPlan on the plan, so a wall moved on the plan also moves in 3D Clean and in the measurements. Actions:

- Walls: Move Wall (drag the wall; walls joined at its ends stretch along their own lines so corners stay closed, and the shared face of the next room moves with it), drag a wall end (the corner moves with every wall joined there), Wall Length (tap the wall's length label or the command, type a length in feet and inches or metric through `LengthParser`), Wall Thickness (typed; the body grows outward, the room keeps its size), Add Wall (two taps with snapping), Delete Wall.
- Doors, windows and openings: Add Door, Add Window, Add Opening (tap a wall), Move (drag along its wall, it cannot leave the wall), Resize (typed width and height), Flip Door Swing (four taps cycle hinge side and direction; a `.user` swing is drawn solid), Delete.
- Rooms: Rename Room, Merge Rooms (tap the rooms to join), Split Room (draw a line across it), all through CR-1.
- Measurements and notes: Add Measurement (two taps, a user dimension line), Delete Measurement, Add Text, Add Symbol (a short list of outlet, switch, light and similar symbols), Add Note, move (drag) and edit them, delete them.
- Furniture and fixtures (SPEC deliverable 13 "Editable detected objects", review S14): move (drag), Turn (90 degrees), Change Category, Delete.
- Snapping of drawn and dragged points: wall ends within 5 cm (or 12 points on screen, whichever is larger), wall centerlines, 0, 45 and 90 degrees from the level's main wall direction, and a 100 mm (metric) or 1 inch (imperial) grid aligned with that direction; a toggle turns snapping off.
- Reset to Scan (after confirmation) removes every plan edit from the log and keeps the others (scale correction, room alignment, crops, labels and categories).

**Build and wave.** Build 5, wave 5a (branch `impl/planeditor`). Core (with CR-1, 3.37a), Geometry (with `Polygon2D.clipped(leftOf:_:)`, CR-1), FloorPlan (with its 5a0 revision, 3.37c), RoomModel (with its 5a0 revision, 3.37b), Store (with `EditStore.reset(_:keeping:)`, CR-1), Units, Support; SwiftUI, CoreGraphics, Combine. About 1500 lines excluding the self-test; if it passes 1500, the prompt sheets move to `PlanEditorSheets.swift` in the same module.

**Files.** `ios/Sources/PlanEditor/PlanEditorModel.swift` (state, loading, perform, undo, redo, reset, ordered writes), `PlanEditorModel+Input.swift` (tools, taps, drags, previews, prompts), `PlanEditorOps.swift` (pure: actions to operations, validation, joined walls, paired walls, orientation, swing cycle, fixture poses), `PlanEditorSnapping.swift` (pure), `PlanEditorPresentation.swift` (pure texts, inspector, operation descriptions, typed-length parsing), `PlanEditorCanvas.swift`, `PlanEditorScreen.swift` (bars, inspector, prompts), `PlanEditorSelfTest.swift`, `PlanEditorSelfTestFixtures.swift`, `ios/Sources/Support/Copy+PlanEditor.swift`.

**Public Swift API.**
```swift
/// What a tap on the canvas does.
enum PlanEditTool: Equatable, Sendable {
    case select
    case addWall
    /// Add Door, Add Window, Add Opening: a tap on a wall places it there.
    case addOpening(OpeningKind)
    case addDimension
    /// Add Text, Add Symbol, Add Note: a tap sets the point, then a prompt asks for the text or symbol.
    case addAnnotation(AnnotationKind)
    /// Two taps draw the cut line across this room.
    case splitRoom(ElementID)
    /// Taps toggle the rooms to join into this one; Merge Rooms commits.
    case mergeRooms(into: ElementID)
}

/// One user edit. `PlanEditorOps` maps it to operations; ids of new elements are made by the model
/// (`ElementID()`) before the action exists, so an action always maps to the same operations.
enum PlanEditAction: Equatable, Sendable {
    /// Move Wall: slide along the wall's left normal (into its room is positive), meters. Walls joined at
    /// its ends end on the moved line (intersection with their own lines); an antiparallel paired wall
    /// (the next room's face of a shared wall) moves by the same translation.
    case moveWall(ElementID, by: Float)
    /// Drag one wall end: every wall end joined there moves to `to`.
    case moveWallEnd(ElementID, atStart: Bool, to: Vec2)
    /// Wall Length: keeps `a`, moves `b` along the wall. When a non-parallel wall is joined at `b`, that
    /// wall moves sideways instead (a `moveWall` of it), which puts `b` exactly `length` from `a` and
    /// keeps the room closed (PEDIT-02).
    case setWallLength(ElementID, length: Float)
    case setWallThickness(ElementID, thickness: Float)
    case addWall(ElementID, a: Vec2, b: Vec2)
    case deleteWall(ElementID)
    /// Centered `center` meters from the wall's `a`; width clamped to the wall.
    case addOpening(ElementID, kind: OpeningKind, wall: ElementID, center: Float, width: Float)
    /// Near edge `offset` meters from the wall's `a`, clamped so the opening stays on its wall.
    case moveOpening(ElementID, offset: Float)
    /// New width keeping the center; `height` (head minus sill) nil keeps both heights.
    case resizeOpening(ElementID, width: Float, height: Float?)
    case flipDoorSwing(ElementID)
    case renameRoom(ElementID, name: String)
    /// `rooms` are joined into `into` (which is not listed in `rooms`).
    case mergeRooms([ElementID], into: ElementID)
    /// The part of the room on the right of a -> b becomes `newRoom`.
    case splitRoom(ElementID, a: Vec2, b: Vec2, newRoom: ElementID)
    /// Add Measurement: a user dimension line offset `PlanEditorOps.userDimensionOffset` to the left.
    case addDimension(ElementID, a: Vec2, b: Vec2)
    /// Add Text, Add Symbol, Add Note, and moving or editing one: the same id replaces it.
    case setAnnotation(PlanAnnotation)
    case moveFixture(ElementID, center: Vec2, yaw: Float)
    case deleteFixture(ElementID)
    case recategorizeFixture(ElementID, ObjectCategory)
    /// Delete a door, window, opening, measurement (dimension) or annotation.
    case deleteElement(ElementID)
}

/// Why an action was refused (texts from `PlanEditorPresentation.message(for:prefs:)`).
enum PlanEditorError: Error, Equatable, Sendable {
    case notFound, tooShort, outOfRange, curvedWall, lockedWall, splitMissesRoom, nothingToMerge, notOnLevel
}

/// Inputs of the pure mapping.
struct PlanEditorContext {
    /// The edited plan and clean model (the clean model gives opening heights and object poses).
    var plan: PlanModel
    var clean: CleanModel?
    /// `PlanLevel.id` of the level being edited.
    var level: Int
    /// Walls whose plan `a` is not the clean `start` (data written before the RoomModel revision,
    /// 3.37b, until the upgrade pass rebuilds it, 3.43e); geometry edits refuse them.
    var lockedWalls: Set<ElementID>
}

enum PlanEditorOps {
    /// Wall ends closer than this are one corner (FloorPlan's `PlanModel.outlineFollowTolerance`).
    static let jointTolerance: Float = 0.02
    static let minimumWallLength: Float = 0.05
    static let wallLengthRange: ClosedRange<Float> = 0.05...100
    static let thicknessRange: ClosedRange<Float> = 0.02...1.0
    static let openingWidthRange: ClosedRange<Float> = 0.2...6
    static let openingHeightRange: ClosedRange<Float> = 0.2...4
    static let defaultDoorWidth: Float = 0.81, defaultWindowWidth: Float = 0.9, defaultOpeningWidth: Float = 0.9
    static let userDimensionOffset: Float = 0.3
    /// Joined walls within this angle of parallel continue the moved wall (their end is translated, not intersected).
    static let parallelLimitDegrees: Float = 10
    /// A paired wall is antiparallel within this angle, its line within its thickness plus this gap, and
    /// overlapping the moved wall by at least half of the shorter length.
    static let pairedAngleDegrees: Float = 5, pairedGapSlack: Float = 0.05
    /// Validated operations of one action; throws `PlanEditorError`.
    static func operations(for action: PlanEditAction, context: PlanEditorContext) throws -> [EditOperation]
    /// One log entry: the single operation, or `.batch(operations:)` for several.
    static func operation(for action: PlanEditAction, context: PlanEditorContext) throws -> EditOperation
    /// The ends of other walls on the level within `jointTolerance` of the given end.
    static func joined(_ wall: ElementID, atStart: Bool, in level: PlanLevel) -> [(wall: ElementID, atStart: Bool)]
    /// The other room's face of a shared wall, or nil.
    static func pairedWall(of wall: PlanWall, in level: PlanLevel) -> PlanWall?
    /// New ends of `wall` moved by `distance` along its left normal: each end is the intersection of the
    /// moved line with the most non-parallel wall joined there, else the translated end.
    static func movedEnds(_ wall: PlanWall, by distance: Float, in level: PlanLevel) -> (a: SIMD2<Float>, b: SIMD2<Float>)
    /// A drawn wall ordered so the room containing its midpoint (else the nearest room) is on its left
    /// when only one side is inside that room; kept as drawn when both or neither side is inside. This
    /// matches the normal rule of `CleanModel.apply(.addWall)`, so the clean normal is the left normal.
    static func oriented(a: SIMD2<Float>, b: SIMD2<Float>, in level: PlanLevel) -> (a: SIMD2<Float>, b: SIMD2<Float>)
    /// Flip Door Swing cycle on (hingeAtStart, opensToNormalSide): (true, true) -> (true, false) ->
    /// (false, false) -> (false, true) -> (true, true); source `.user`. A nil swing starts from
    /// `PlanBuilder.defaultSwing(offset:width:wallLength:)`.
    static func nextSwing(_ swing: DoorSwing?, offset: Float, width: Float, wallLength: Float) -> DoorSwing
    /// moveFixture's world pose: the clean object's transform turned about world +Y by (yaw - its plan
    /// yaw from `PlanBuilder.planPose(of:)`), its translation moved to `center` at its own height.
    static func objectTransform(_ object: DetectedObject, center: Vec2, yaw: Float) -> Transform4
    /// True for operations Reset to Scan removes: every case except relabelObject, recategorizeObject,
    /// setScaleCorrection, setRoomAlignment and cropObject (label and category corrections, including
    /// Results' Change Category, are not floor plan geometry and survive a reset); a batch when any of
    /// its operations is.
    static func isPlanEdit(_ op: EditOperation) -> Bool
    /// Walls present in both models whose plan `a` is more than 1 cm from the clean `start` in plan.
    static func lockedWalls(plan: PlanModel, clean: CleanModel?) -> Set<ElementID>
}

/// Snapping (RESEARCH 3.6 recommended 12), plan meters.
enum PlanSnapKind: String, Equatable, Sendable { case endpoint, wall, angle, grid, none }
struct PlanSnapResult: Equatable, Sendable { var point: SIMD2<Float>; var kind: PlanSnapKind }
struct PlanSnapTargets: Equatable {
    /// Wall ends and user dimension ends.
    var endpoints: [SIMD2<Float>]
    /// Straight wall lines (curved walls give only their ends).
    var segments: [Segment2D]
    /// Unit direction of the level's longest straight wall; (1, 0) without walls.
    var axis: SIMD2<Float>
}
enum PlanEditorSnapping {
    static let endpointRadius: Float = 0.05
    static let angleStepDegrees: Float = 45
    static let angleToleranceDegrees: Float = 4
    static let metricGrid: Float = 0.1
    static let imperialGrid: Float = 0.0254
    /// Targets of a level, leaving out the walls in `excluding` (the wall being dragged and the ends
    /// that move with it).
    static func targets(level: PlanLevel, excluding: Set<ElementID>) -> PlanSnapTargets
    static func referenceAxis(_ level: PlanLevel) -> SIMD2<Float>
    /// metricGrid for metric preferences, imperialGrid for imperial.
    static func gridStep(_ prefs: UnitPreferences) -> Float
    /// Endpoint within `radius`; else the foot on a segment within `radius`; else, with an anchor, the
    /// direction anchor -> p turned to the nearest multiple of 45 degrees from `axis` when within 4
    /// degrees (its length rounded to the grid); else p rounded to the grid in the frame of `axis`
    /// through plan (0, 0). `.none` (p unchanged) when `enabled` is false.
    static func snap(_ p: SIMD2<Float>, anchor: SIMD2<Float>?, targets: PlanSnapTargets, radius: Float,
                     grid: Float, enabled: Bool) -> PlanSnapResult
    /// A scalar move (Move Wall) rounded to the grid step when enabled.
    static func snapDistance(_ d: Float, grid: Float, enabled: Bool) -> Float
}

/// What the inspector shows for the selection.
enum PlanEditorItem: Equatable {
    case wall(PlanWall)
    case opening(PlanOpening, wall: PlanWall)
    case room(PlanRoom)
    case fixture(PlanFixture)
    case annotation(PlanAnnotation)
    case dimension(PlanDimension)
}
/// Buttons of the inspector (for the selection) and of the add bar (nothing selected).
enum PlanEditorCommand: String, CaseIterable, Identifiable, Sendable {
    case wallLength, wallThickness, deleteWall, addDoor, addWindow, addOpening
    case resizeOpening, flipDoorSwing, deleteOpening
    case renameRoom, mergeRooms, splitRoom
    case turnFixture, changeCategory, deleteFixture
    case editAnnotation, deleteAnnotation, deleteMeasurement
    case addWall, addMeasurement, addText, addSymbol, addNote
    var id: String { rawValue }
}
/// A sheet or alert the model asks the screen to show.
enum PlanEditorPrompt: Identifiable, Equatable {
    case wallLength(ElementID, current: Float)
    case wallThickness(ElementID, current: Float)
    case openingSize(ElementID, width: Float, height: Float?)
    case renameRoom(ElementID, current: String)
    /// Text, note or symbol at `at`; `editing` is the annotation being changed.
    case annotation(kind: AnnotationKind, at: Vec2, editing: ElementID?, current: String)
    case category(ElementID, current: ObjectCategory)
    case resetConfirmation
    var id: String { get }
}

enum PlanEditorPresentation {
    /// Titles: Copy.FloorPlan (wallLength, wallThickness, addWall, deleteWall, addDoor, addWindow,
    /// addOpening, flipDoorSwing, renameRoom, mergeRooms, splitRoom, addMeasurement, deleteMeasurement,
    /// addText, addSymbol, addNote); resizeOpening reads Copy.FloorPlan.resizeDoor, resizeWindow or
    /// Copy.PlanEditor.resizeOpening by the selected opening's kind; Copy.PlanEditor.turn,
    /// Copy.ObjectMenu.changeCategory, Copy.PlanEditor.editText; Copy.Project.delete for deleteOpening,
    /// deleteFixture and deleteAnnotation.
    static func title(_ command: PlanEditorCommand, item: PlanEditorItem?) -> String
    static func hint(for tool: PlanEditTool, pending: Int) -> String?
    static func message(for error: PlanEditorError, prefs: UnitPreferences) -> String
    /// One line per operation kind for Results' orphaned-edit list (3.43b), exhaustive switch; a
    /// batch reads as its first operation.
    static func describe(_ op: EditOperation) -> String
    /// Room title (`RoomTitles`), or "Wall 3", "Door 1", "Window 2", "Opening 1" numbered in level order
    /// (Copy.MeasureCore wallTitle, doorTitle, windowTitle, openingTitle), the category name of a
    /// fixture, the annotation text (its symbol for a symbol), or `Copy.PlanEditor.measurementItem`.
    static func itemTitle(_ item: PlanEditorItem, level: PlanLevel, roomTitles: [ElementID: String]) -> String
    /// `PlanLevel.name`, else `Copy.House.floorLabel(id + 1)`.
    static func levelTitle(_ level: PlanLevel) -> String
    /// Add Symbol choices, stored in `PlanAnnotation.symbol` as shown (FloorPlan draws the text).
    static let symbols: [String]
    /// `LengthParser.meters(from:prefs:)` accepted when finite and inside `range`; nil otherwise.
    static func parseLength(_ text: String, prefs: UnitPreferences, range: ClosedRange<Float>) -> Float?
    /// The starting text of a length field: `LengthFormat.primary`.
    static func lengthText(_ meters: Float, prefs: UnitPreferences) -> String
}

/// Main actor. One editing session of one project.
@MainActor final class PlanEditorModel: ObservableObject {
    /// Layers shown while editing: `PlanToggles.standard` with the grid on.
    static let toggles: PlanToggles
    /// The edited plan (the drag preview while a drag runs) and the edited clean model.
    @Published private(set) var plan: PlanModel
    @Published private(set) var clean: CleanModel?
    @Published private(set) var levelIndex: Int
    @Published private(set) var drawing: PlanDrawingResult?
    @Published var selection: ElementID?
    @Published private(set) var tool: PlanEditTool
    /// First points of Add Wall, Add Measurement and Split Room.
    @Published private(set) var pendingPoints: [Vec2]
    @Published private(set) var mergeSelection: [ElementID]
    @Published private(set) var snapKind: PlanSnapKind?
    @Published var snappingEnabled: Bool
    @Published private(set) var canUndo: Bool
    @Published private(set) var canRedo: Bool
    @Published private(set) var isLoaded: Bool
    @Published private(set) var loadFailed: Bool
    @Published private(set) var prefs: UnitPreferences
    @Published var prompt: PlanEditorPrompt?
    /// A refused action or a failed write; shown in an alert, then cleared.
    @Published var message: String?
    let projectID: UUID
    init(projectID: UUID)
    /// Off main: `PlanModelStore.loadBase`, `CleanModelStore.loadBase` (optional), `EditStore.load`,
    /// `UnitPreferences.load()`; keeps the bases and the log; edited plan = `log.applied(to: basePlan)`,
    /// edited clean = `baseClean.applyingEdits(log)`; `lockedWalls`. A missing plan sets `loadFailed`.
    func load() async
    /// Maps, validates (applies to copies of both models; a false from either refuses the action),
    /// appends to the local log, recomputes, and writes through `EditStore.append` on the write queue.
    func perform(_ action: PlanEditAction) throws
    func undo() throws
    func redo() throws
    /// After `.resetConfirmation`: `EditStore.reset(_:keeping: { !PlanEditorOps.isPlanEdit($0) })`.
    func resetToScan() throws
    func run(_ command: PlanEditorCommand)
    func setTool(_ tool: PlanEditTool)
    func cancelTool()
    func selectLevel(_ index: Int)
    /// Plan meters; `tolerance` is 12 points converted with the canvas viewport.
    func tap(at point: SIMD2<Float>, tolerance: Float)
    /// True when the point grabs the selection (the canvas then edits instead of panning).
    func beginDrag(at point: SIMD2<Float>, tolerance: Float) -> Bool
    func drag(to point: SIMD2<Float>, tolerance: Float)
    func endDrag()
    func commitMerge()
    /// Text of a value, name or annotation prompt.
    func submit(_ prompt: PlanEditorPrompt, text: String)
    func submitSymbol(_ symbol: String, at: Vec2)
    func submitCategory(_ category: ObjectCategory, for fixture: ElementID)
    var selectedItem: PlanEditorItem? { get }
    /// For the selection, or the add commands when nothing is selected.
    var commands: [PlanEditorCommand] { get }
    /// Drag handles of the selection, plan meters (wall ends, opening ends, fixture center, annotation anchor).
    var handles: [SIMD2<Float>] { get }
    var levelTitles: [String] { get }
}

/// Canvas: `PlanRenderer.draw` of `model.drawing` inside `GraphicsContext.withCGContext`, then
/// `PlanRenderer.drawHighlight` of every hit of the selection (and of the merge selection), handles,
/// pending points and the snap marker. Viewport: fitted to the plan bounds with the user's zoom and
/// pan (as `PlanCanvasView`). One DragGesture: a drag starting on the selection edits
/// (`beginDrag`), any other drag pans; MagnifyGesture zooms about its anchor; SpatialTapGesture calls
/// `tap(at:tolerance:)`. Accessible as `Copy.A11y.floorPlan` with the hint `Copy.PlanEditor.canvasHint`.
struct PlanEditorCanvas: View { init(model: PlanEditorModel) }
/// Full screen. Top: Done Editing, the level menu (more than one level), Undo, Redo, More (snapping
/// toggle, Reset to Scan, the Plan Items menu for VoiceOver). Middle: the canvas. Bottom: the hint or
/// snap line, the inspector of the selection or the add bar, `Copy.FloorPlan.editsSafe`. Prompts as
/// sheets (typed lengths, names, text, symbols, categories) and alerts (reset, messages).
struct PlanEditorScreen: View { init(projectID: UUID, onDone: @escaping () -> Void) }
```
Changes from the earlier short sketch of this section (ARCHITECTURE.md may still show it; this section wins): `PlanEditorOps.operations(for:context:)` takes a `PlanEditorContext` instead of a `PlanLevel` (fixture moves and opening heights need the clean model), throws, and a multi-operation action is one `batch` entry; `canUndo` and `canRedo` are published.

**Rules.**

*Mapping* (`PlanEditorOps.operations`, all lengths in plan meters, the level from the context):
- `moveWall(w, by: d)`: refuses curved, locked or missing walls and joints with a curved wall. Ops: `moveWallEndpoint(wall: w, atStart: true, to: movedEnds.a)` and `(atStart: false, to: movedEnds.b)`, one `moveWallEndpoint` for every joined end (to the same corner point), and for the paired wall `p` (when any) the same set for `p` moved by `-d` (antiparallel normals). Refuses (`.tooShort`) when any wall would end shorter than `minimumWallLength` or reverse direction (dot of old and new direction at most 0).
- `moveWallEnd(w, atStart:, to:)`: `moveWallEndpoint` for `w` and for every joined end; same validation.
- `setWallLength(w, length:)`: `length` in `wallLengthRange` (else `.outOfRange`). With a non-parallel wall `v` joined at `b`: the operations of `moveWall(v, by: dot(u * (length - current), leftNormal(v)))` (u the unit direction of `w`), which move `b` to `a + u * length`. Else `moveWallEndpoint(w, atStart: false, to: a + u * length)` plus the joined ends.
- `setWallThickness`: in `thicknessRange`; `setWallThickness(wall:thickness:)`.
- `addWall(id, a, b)`: length at least `minimumWallLength`; `oriented(a:b:in:)`; `addWall(wall: PlanWall(id:, a:, b:, thickness: CleanBuildOptions().interiorThickness, thicknessSource: .estimated, arc: nil, provenance: .user, occludedSpans: []), level:)`.
- `deleteWall` and `deleteFixture` and `deleteElement`: `deleteElement(element:)`.
- `addOpening(id, kind, wall, center, width)`: the wall must be on the level and straight; width clamped to `openingWidthRange` and to the wall length (a wall shorter than the minimum width refuses `.tooShort`); offset = clamp(center - width / 2, 0, length - width); a door or open door gets `PlanBuilder.defaultSwing(offset:width:wallLength:)` so both models store the same swing; `addOpening(opening: PlanOpening(id:, wallID:, kind:, offset:, width:, swing:), level:)`.
- `moveOpening(o, offset)`: `moveOpening(opening:offset:)` with the offset clamped to [0, length - width].
- `resizeOpening(o, width, height)`: width in `openingWidthRange`; sill and head from the edited clean opening (doors sill 0), with `height` when given: head = sill + height capped by the wall height (height in `openingHeightRange`); without a clean opening the defaults of `CleanModel.apply(.addOpening)` (door 0 to 2.03 m, window 0.9 to 2.1 m, opening 0 to 2.1 m); `resizeOpening(opening:width:sillHeight:headHeight:)`.
- `flipDoorSwing(o)`: `setDoorSwing(door:swing: nextSwing(...))`.
- `renameRoom`: trimmed text, `renameRoom(room:name:)` (empty restores the default title).
- `mergeRooms(rooms, into)`: at least one room besides `into`, all on the level (else `.nothingToMerge`, `.notOnLevel`); `mergeRooms(rooms:into:)`.
- `splitRoom(r, a, b, newRoom)`: both sides of the line must hold at least 0.01 square meters of the room's outline parts by `Polygon2D.clipped(leftOf:_:)` (else `.splitMissesRoom`); `splitRoom(room:line: [a, b], newRoom:)`.
- `addDimension(id, a, b)`: length at least 0.05 m; `addDimension(dimension: PlanDimension(id:, a:, b:, offset: userDimensionOffset, isUser: true), level:)`.
- `setAnnotation(annotation)`: `addAnnotation(annotation:level:)` (the same id replaces it in the plan).
- `moveFixture(f, center, yaw)`: needs the clean object (else `.notFound`); `moveObject(object:transform: objectTransform(...))`. `recategorizeFixture`: `recategorizeObject(object:category:)`.

*Perform.* `operation(for:context:)` throws: the model shows `message(for:prefs:)` and rethrows. The operation is applied to copies of the edited plan and clean model; a false from either refuses it (`.notFound`) and nothing is written. Otherwise the local log mirror appends it, the edited models are recomputed from the bases, the drawing is rebuilt, and `EditStore.append(op, to:)` runs on a private serial queue (label "mapper.planeditor.io", QoS userInitiated) so writes land in order (PERF-28). Undo, redo and reset go through the same queue with `EditStore.undo`, `redo` and `reset(_:keeping:)` after mirroring the change locally (`EditLog.undo()`, `redo()`, `reset(keeping:)`). A failed write sets `message` to `Copy.Errors.saveFailed.body` and reloads from disk (the disk log wins). Every action logs one line (category "planeditor") with the action, the operation kinds and element ids.

*Taps.* Select tool: `PlanDrawing.hitTest(drawing.hits, at:tolerance:)`. A hit on a generated wall dimension (id `PlanBuilder.wallDimensionID(wall.id)`) selects that wall and opens `.wallLength` (PEDIT-02 "Tap a wall length label"); any other hit selects its element, empty space clears the selection. Add Wall and Add Measurement take two snapped taps (the second with the first as anchor), then perform and select the new element. Add Door, Window, Opening take one tap that must be within tolerance of a straight wall (wall hits only); the center is the tap projected on the wall; the default width is `defaultDoorWidth`, `defaultWindowWidth` or `defaultOpeningWidth`. Add Text, Symbol, Note take one tap, then the `.annotation` prompt. Split Room takes two taps (hint `Copy.FloorPlan.splitHint`, then `splitEndHint`). Merge Rooms toggles room hits in `mergeSelection` (hint `Copy.FloorPlan.mergeHint`), `commitMerge` performs. After an add, the tool returns to select with the new element selected.

*Drags.* `beginDrag` grabs the selection: a straight wall's end handle (within 1.5 x tolerance) or body, an opening's span, a fixture footprint (`PlanSymbols.footprint`), an annotation's hit box. While dragging, the action for the current point (snapped with `PlanEditorSnapping`, the moving wall and its joined walls excluded from the targets; a body move snaps its distance with `snapDistance`) is mapped, applied to a copy of the plan and drawn as the preview; an invalid state keeps the last valid preview. `endDrag` performs the last valid action. A drag on nothing pans.

*Prompts.* Typed lengths use `PlanEditorPresentation.parseLength` with the action's range; a rejected text keeps the sheet open with `Copy.PlanEditor.invalidLength` or the range message. Rename uses `Copy.House.nameRoomPlaceholder`; text and notes use `Copy.FloorPlan.textPlaceholder` and `notePlaceholder`; Add Symbol lists `symbols`; Change Category lists `ObjectCategory.allCases` by `Copy.FloorPlan.categoryName`.

*Levels.* The level menu (House projects with several floors) shows `levelTitle`; actions use the current level's id.

**Uses.** FloorPlan: `PlanModelStore` (`loadBase`), `PlanModel.apply(_:)` (with CR-1 cases, 3.37c), `PlanDrawing` (`make(level:toggles:prefs:roomTitles:name:)`, `hitTest(_:at:tolerance:)`), `PlanDrawingResult`, `PlanHit`, `PlanHitKind`, `PlanRenderer` (`draw(_:in:viewport:lineWidth:dark:)`, `drawHighlight(_:in:viewport:lineWidth:)`), `PlanViewport` (`fitting(min:max:in:margin:)`, `toScreen`, `toPlan`, `zoomed(by:about:)`, `panned(by:)`), `PlanToggles.standard`, `RoomTitles.titles(for:clean:)`, `PlanBuilder` (`defaultSwing(offset:width:wallLength:)`, `planPose(of:)`, `wallDimensionID(_:)`, `interiorPoint(of:)`), `PlanSymbols.footprint(_:)`, `Copy.FloorPlan.categoryName(_:)`. RoomModel: `CleanModelStore.loadBase`, `CleanModel.applyingEdits(_:)`, `CleanModel.apply(_:)`, `CleanBuildOptions`. Store: `EditStore` (`load`, `append(_:to:)`, `undo`, `redo`, `reset(_:keeping:)` CR-1), `ProjectLibrary.shared.package(for:)`. Geometry: `Polygon2D` (`contains(point:)`, `area`, `clipped(leftOf:_:)` CR-1), `Segment2D` (`closestPoint(to:)`, `distance(to:)`, `direction`, `angle(between:)`, `cross`). Core: `EditOperation` (with CR-1 cases), `EditLog` (`append`, `undo`, `redo`, `reset(keeping:)` CR-1, `applied(to:)`, `canUndo`, `canRedo`), `PlanModel`, `PlanLevel`, `PlanWall`, `PlanOpening`, `PlanRoom`, `PlanFixture`, `PlanAnnotation`, `AnnotationKind`, `PlanDimension`, `CleanModel`, `CleanOpening`, `DetectedObject`, `DoorSwing`, `OpeningKind`, `ObjectCategory`, `ElementID`, `Vec2`, `Transform4`, `PlanAxes`. Units: `LengthParser.meters(from:prefs:)`, `LengthFormat.primary(_:prefs:)`, `UnitPreferences.load(from:)`. Support: `Haptics.selection()` (a snap), `Haptics.tap()` (a committed edit), `LogStore` (category "planeditor"), Copy as below.

**Apple APIs** (RESEARCH 3.6): `struct Canvas<Symbols>` and `func withCGContext(content: (CGContext) throws -> Void) rethrows`; `DragGesture(minimumDistance: 10, coordinateSpace: .local)` (`init(minimumDistance: CGFloat = 10, coordinateSpace: some CoordinateSpaceProtocol = .local)`, iOS 17.0, `@MainActor @preconcurrency`); `MagnifyGesture(minimumScaleDelta: 0.01)` (iOS 17.0); `SpatialTapGesture(count: 1, coordinateSpace: .local)` (iOS 17.0). Not in RESEARCH: `CGContext.addEllipse(in:)`, `fillPath()`, `setFillColor(_:)` for handles (iOS 2); `.sheet(item:)`, `.alert(_:isPresented:actions:message:)` with a `TextField` (iOS 15 and 16); `Menu` (iOS 14); `DispatchQueue(label:qos:)`.

**Must NOT do.** Never write `plan.json`, `clean.json` or anything under `raw/` (the base stays derived; PEDIT rule "open RAW MESH and check it did not change"). Never write more than one log entry per user action. Never edit a locked wall or move a curved wall. Never use `MagnificationGesture`, `RotationGesture` or the `CoordinateSpace`-typed gesture initializers. Never flip y outside `PlanViewport`. Never format a length without Units or parse one without `LengthParser`. Never block main on disk. No hardcoded text.

**Copy strings.** Existing: every `Copy.FloorPlan` action, hint and dialog string (moveWall, wallLength, wallThickness, addWall, deleteWall, addDoor, moveDoor, resizeDoor, flipDoorSwing, addWindow, moveWindow, resizeWindow, addOpening, renameRoom, mergeRooms, splitRoom, addMeasurement, deleteMeasurement, addText, addSymbol, addNote, undo, redo, doneEditing, resetToScan, splitHint, mergeHint, resetTitle, resetBody, resetConfirm, editsSafe, notePlaceholder, textPlaceholder), `Copy.FloorPlan.categoryName(_:)`, `Copy.ObjectMenu.changeCategory`, `Copy.House.nameRoomPlaceholder`, `floorLabel(_:)`, `Copy.MeasureCore.wallTitle(_:)`, `doorTitle(_:)`, `windowTitle(_:)`, `openingTitle(_:)`, `Copy.Viewer.width`, `height`, `Copy.Measure.save`, `Copy.Project.delete`, `cancel`, `Copy.Errors.saveFailed`, `ok`, `Copy.Empty.noFloorPlan`, `Copy.A11y.floorPlan`. New in `Copy+PlanEditor.swift` (`extension Copy { enum PlanEditor }`):
- `selectHint = "Tap a wall, door, window, room or label to change it"`
- `wallStartHint = "Tap where the wall starts"`, `wallEndHint = "Tap where the wall ends"`
- `openingHint = "Tap a wall to place it"`, `tapWall = "Tap on a wall"`
- `dimensionStartHint = "Tap the first point"`, `dimensionEndHint = "Tap the second point"`
- `annotationHint = "Tap where it goes"`, `splitEndHint = "Now tap the other side of the room"`
- `turn = "Turn"`, `editText = "Edit Text"`, `resizeOpening = "Resize Opening"`, `measurementItem = "Measurement"`, `snapping = "Snap to walls and grid"`, `elements = "Plan Items"`
- `canvasHint = "Drag to move, pinch to zoom. Drag a selected item to change it"`
- `invalidLength = "Type a length, for example 12' 6\" or 3.8 m."`
- `static func tooShort(_ length: String) -> String { "Walls must be at least \(length) long." }`
- `static func outOfRange(_ low: String, _ high: String) -> String { "Use a value from \(low) to \(high)." }`
- `curvedWall = "Curved walls can't be moved or resized."`
- `lockedWall = "The floor plan is being updated. Try again in a moment."`
- `splitMisses = "Draw the line all the way across the room."`
- `nothingToMerge = "Tap at least one more room to join."`, `notOnLevel = "Rooms on different floors can't be joined."`
- `notFound = "That part of the plan changed. Try again."`
- `symbolOutlet = "Outlet"`, `symbolSwitch = "Switch"`, `symbolLight = "Light"`, `symbolSmokeAlarm = "Smoke Alarm"`, `symbolWater = "Water"`, `symbolGas = "Gas"`, `symbolVent = "Vent"`, `symbolThermostat = "Thermostat"`
- Operation descriptions for `describe(_:)`: `editRoomRenamed = "Room renamed"`, `editObjectRenamed = "Object renamed"`, `editCategoryChanged = "Category changed"`, `editHidden = "Hidden or shown"`, `editDeleted = "Deleted"`, `editObjectMoved = "Furniture moved"`, `editWallMoved = "Wall moved"`, `editWallAdded = "Wall added"`, `editOpeningAdded = "Door or window added"`, `editSwingChanged = "Door swing changed"`, `editThicknessChanged = "Wall thickness changed"`, `editLabelAdded = "Label added"`, `editMeasurementAdded = "Measurement added"`, `editScaleCorrected = "Size corrected"`, `editRoomLinedUp = "Room lined up"`, `editObjectCropped = "Object cropped"`, `editOpeningMoved = "Door or window moved"`, `editOpeningResized = "Door or window resized"`, `editRoomsMerged = "Rooms merged"`, `editRoomSplit = "Room split"`

**Self-test.** `PlanEditorSelfTest.run()`, at least 35 checks, fixtures in `PlanEditorSelfTestFixtures.swift`: a clean model with room A (4 x 5 m, walls W1 to W4 counter-clockwise, a door on W1, a window on W2, a sofa) and room B (3 x 4 m) east of A with a 0.12 m gap (a shared wall pair), its plan from `PlanBuilder.build(from:floors:)`, and a context over both. Every mapped action is also applied to the plan with `PlanModel.apply` and to the clean model with `CleanModel.applyingEdits` (one-entry `EditLog`):
1. `joined(W1, atStart: false)` is W2's start.
2. `moveWall(W3, by: -0.3)` gives one `.batch` of 4 `moveWallEndpoint` operations (8 with a paired wall; W3 has none); room A's plan area grows by 1.2 within 1e-3 and W2's `b` equals W3's `a` (PEDIT-01 corners closed).
3. The same entry on the clean model grows `metrics.floorArea` by 1.2 within 1e-3, and every plan wall's `a` equals the clean `start` in plan within 1e-4.
4. `setWallLength(W1, length: 4.5)`: W1 is 4.5 within 1e-4 in both models and W2 keeps its direction.
5. `setWallLength` of 0.01 m throws `.outOfRange`.
6. `moveWallEnd` past the other end throws `.tooShort`.
7. A curved wall throws `.curvedWall` for `moveWall`; a locked wall (in `lockedWalls`) throws `.lockedWall`.
8. `setWallThickness(W1, 0.15)` sets 0.15 with source `.user` in both models.
9. `oriented` reverses a wall drawn along the outside of A with A on its right and keeps a wall drawn across A's middle.
10. `addWall` adds a wall with a generated dimension to the plan and a clean wall whose normal is the left perpendicular.
11. `deleteWall(W1)` removes W1 and its door in both models.
12. `addOpening` of a door centered 2.0 m along W1, width 0.81 m: offset 1.595 in both models, same `.estimated` swing in both.
13. `moveOpening` to 3.9 m clamps to 3.19 m (length minus width) in both models.
14. `resizeOpening` to 0.9 m keeps the center (offset shifts by -0.045) in both; `height: 2.1` on the door gives head 2.1 and sill 0 in the clean model.
15. Four `flipDoorSwing` entries cycle back to the first swing; every result has source `.user`.
16. `renameRoom` sets the name in both models; an empty name restores the default title through `RoomTitles`.
17. `mergeRooms([B], into: A)`: one plan room with area 20 + 12 within 1e-3 (PEDIT-07) and one `mergedOutlines` entry; one clean room holding both rooms' walls with `metrics.floorArea` 32 within 1e-3.
18. `splitRoom(A, a: (-1, 2), b: (5, 2), newRoom:)` on the 4 x 5 m room at plan y 0 to 5: areas 8 and 12 (sum 20 within 1e-3) in both models, the new room has the given id and an empty name.
19. A split line outside the room throws `.splitMissesRoom`; `mergeRooms([], into: A)` throws `.nothingToMerge`.
20. `addDimension` adds a user dimension (`isUser` true); `deleteElement` of it removes it.
21. `setAnnotation` adds a text; the same id at a new point replaces it (one annotation); new text replaces it; `deleteElement` removes it.
22. `moveFixture(sofa, center: (1, 1), yaw: 0.5)`: the plan fixture's center and yaw equal them within 1e-4 and the clean object's height is unchanged.
23. `recategorizeFixture(sofa, .chair)` and `deleteFixture` apply in both models.
24. `isPlanEdit` is true for `moveWallEndpoint` and a batch of them, false for `setScaleCorrection`, `setRoomAlignment`, `cropObject`, `relabelObject` and `recategorizeObject`, and false for a batch of `setRoomAlignment` edits (AlignRoomsModel's save).
25. `operation(for:)` returns a single operation for `renameRoom` and a `.batch` for `moveWall`.
26. An `EditLog` with the `moveWall` batch appended then undone gives back the base plan (one Undo reverts the action).
27. Moving room A's shared wall moves room B's paired face by the same translation (gap 0.12 within 1e-4).
28. Snapping: a point 3 cm from a wall end snaps `.endpoint`; 3 cm from a wall's middle snaps `.wall` to the foot; with an anchor, a direction 3 degrees off the axis snaps `.angle`; otherwise `.grid` to 0.1 m (metric) or 1 inch (imperial) in the axis frame; `enabled: false` gives `.none`.
29. `referenceAxis` of a room rotated by 30 degrees is its longest wall's direction.
30. `lockedWalls` finds a wall whose plan ends are swapped against the clean model and none for a consistent pair.
31. `describe` gives non-empty, distinct texts for every `EditOperation` case (built by hand, including the CR-1 cases).
32. `message(for:)` is non-empty for every error, and `.tooShort` contains `LengthFormat.primary(0.05, prefs:)`.
33. `parseLength` accepts "3.8 m" and "12' 6\"" in their unit systems and rejects "abc", "-2 m" and a value outside the range.
34. `nextSwing(nil, ...)` starts from `PlanBuilder.defaultSwing` and then follows the cycle.
35. `objectTransform` keeps the object's box size (`DetectedObject.orientedBox.halfExtents`) and its world y.

**Acceptance checks.** One Undo reverts one user action (a wall move with its neighbors); Reset to Scan returns the generated plan and keeps scale corrections and alignments; 3D Clean and the measurement panel follow plan edits after Done Editing; raw folders and `plan.json` are byte-identical before and after an editing session (PEDIT-09); corners stay closed after moves; doors cannot leave their wall; typed lengths accept both unit systems; five quick edits then a force quit keep all five (PERF-28); the log has one line per action.

**SPEC owned.** "FLOOR PLAN EDITING": move wall, adjust wall length, change wall thickness, add wall, delete wall, add door, move door, resize door, add window, move window, resize window, add opening, rename room, merge rooms, split room, add measurement, delete measurement, add text annotation, add symbol, add notes, "Manual edits must not overwrite raw scan data"; "2D FLOOR PLAN" ("Allow manual editing", door swing confirmed by the user drawn solid); deliverable 13 "Editable detected objects" (move, turn, delete and change category on the plan); "3D EDITING" Wall: Adjust, Add opening, Add door, Add window (on the plan in build 5).

**TEST_PLAN ids.** PEDIT-01 to PEDIT-09, PLAN-03 (toggles after edits), EXP-05 (annotations in the PDF), REC-02 (Change Category), PERF-13, PERF-28, OFF-01 (plan editing offline), smoke #8.

### 3.37a Core change CR-1: plan editing operations (applied by the lead before wave 5a)

**Purpose.** The approved CR-1 (lead decision 1): the edit operations the plan editor needs that the build 4 `EditOperation` lacks, plus the smallest supporting additions, applied by the lead in one commit so `integration` stays green: Core (`EditOperation` cases and `targets`, a `batch` case so one user action is one undo step, `flattened`, `EditLog.flattenedActive`, `EditLog.reset(keeping:)`, `mergedOutlines` on `CleanFloor` and `PlanRoom`, the documented wall orientation and `WallArc` conventions), Geometry (`Polygon2D.clipped(leftOf:_:)`, so RoomModel and FloorPlan split rooms with the same arithmetic), Store (`EditStore.reset(_:keeping:)`), and temporary stub cases in the two `EditApplicable` conformances, which the 5a0 revisions (3.37b, 3.37c) replace.

**Build and wave.** Pre-5a, applied by the lead together with CR-7 (3.30a) and CR-8 (3.31c) in one commit, compiled green, before wave 5a0. Core, Geometry and Store keep their dependencies.

**Files.** `ios/Sources/Core/EditLog.swift`, `CleanModel.swift`, `FloorPlanModel.swift`, `CoreSelfTest.swift`; `ios/Sources/Geometry/Polygon2D.swift`, `GeometrySelfTest.swift`; `ios/Sources/Store/StoreEdits.swift`, `StoreSelfTest.swift`; stub cases only in `ios/Sources/RoomModel/CleanModel+Edits.swift` and `ios/Sources/FloorPlan/PlanModel+Edits.swift`. Before committing, the lead greps the target for every `switch` over `EditOperation` (today: CoreSelfTest, RoomModel, FloorPlan) and gives each the new cases.

**Public Swift API.**
```swift
enum EditOperation: Codable, Equatable, Sendable {
    // ... the 16 build 4 cases unchanged ...
    /// Move a door, window or opening along its wall: near edge `offset` meters from the wall's start
    /// (`CleanWall.start`, which is `PlanWall.a`), clamped by each model to [0, length - width].
    case moveOpening(opening: ElementID, offset: Float)
    /// Resize a door, window or opening: new width keeping its center, then clamped to the wall; sill and
    /// head heights above the floor (the clean model uses them; the plan has no heights).
    case resizeOpening(opening: ElementID, width: Float, sillHeight: Float, headHeight: Float)
    /// Join `rooms` into `into`: their outlines become `mergedOutlines` of `into`, their walls, openings
    /// and objects move to `into`, and they are removed. `into` is not listed in `rooms`.
    case mergeRooms(rooms: [ElementID], into: ElementID)
    /// Split `room` along the infinite line through the first and last point of `line` (plan meters;
    /// build 5 writes exactly two points): the part left of first -> last stays `room`, the part on the
    /// right becomes the new room `newRoom`.
    case splitRoom(room: ElementID, line: [Vec2], newRoom: ElementID)
    /// Several operations applied as one, in order, all or nothing: one user action, one undo step.
    case batch(operations: [EditOperation])

    /// (extended) moveOpening and resizeOpening: [opening]; mergeRooms: [into] + rooms without
    /// duplicates; splitRoom: [room, newRoom] (newRoom is the new element, as for additions); batch:
    /// the targets of its operations in order without duplicates.
    var targets: [ElementID] { get }
    /// `[self]` for every case but `.batch`, which gives its operations flattened recursively.
    var flattened: [EditOperation] { get }
}

extension EditLog {
    /// The active operations with every batch flattened, in order. Readers that look for one kind of
    /// operation (scale corrections, room alignments, crops) use this, never `active`.
    var flattenedActive: [EditOperation] { get }
    /// Keeps the active operations (top level) for which `keep` is true, in order, and drops the rest
    /// and the redo tail; `cursor` becomes the kept count; `revision` increases by 1. Returns false and
    /// changes nothing when every active operation is kept and there is no redo tail.
    @discardableResult
    mutating func reset(keeping keep: (EditOperation) -> Bool) -> Bool
}

struct CleanFloor: Codable, Equatable, Sendable {
    // ... outline, elevation, occludedArea, provenance unchanged ...
    /// Outlines of rooms merged into this one (CR-1 `mergeRooms`) or pieces of a split, plan meters,
    /// counter-clockwise. Nil for every room RoomModel builds, so build 4 JSON is unchanged (the
    /// synthesized coder skips a nil optional and decodes a missing key as nil).
    var mergedOutlines: [[Vec2]]? = nil
}
struct PlanRoom: Codable, Equatable, Identifiable, Sendable {
    // ... id, name, outline, labelAt, area unchanged; `area` is the total of all parts ...
    /// As `CleanFloor.mergedOutlines`.
    var mergedOutlines: [[Vec2]]? = nil
}

/// Arc of a curved wall (RoomPlan `Surface.Curve`, angles in radians). Convention (build 4 RoomModel,
/// written down by CR-1): `center` is a world point at the wall's base height; `startAngle < endAngle`,
/// both measured counter-clockwise from plan +x (`PlanAxes`) around the center's plan point; the wall
/// covers the angles from `startAngle` to `endAngle`, and its `start` and `end` lie on the arc in either
/// order, so reversing a wall (swapping start and end) leaves its arc unchanged.
struct WallArc: Codable, Equatable, Sendable { /* fields unchanged */ }

/// (CleanWall doc comment, added) Orientation invariant from build 5 (RoomModel 3.37b): the room is on
/// the left of `start` -> `end` in plan coordinates and `normal` is that left perpendicular, for loop
/// and stray walls alike. FloorPlan copies start -> end to `PlanWall.a` -> `b` unchanged, so
/// `moveWallEndpoint(atStart:)`, `offsetAlongWall` / `PlanOpening.offset` and `DoorSwing.hingeAtStart`
/// mean the same end in both models.

// Geometry, Polygon2D.swift
extension Polygon2D {
    /// The part of the ring on the left of the directed line through `a` and `b` (points on the line
    /// count as inside): Sutherland-Hodgman against one half-plane. For a concave ring cut into several
    /// pieces the result is one ring whose pieces are joined along the line by zero-width edges; its
    /// area is still the area of the pieces. Empty when nothing is on the left or `a == b`.
    func clipped(leftOf a: SIMD2<Float>, _ b: SIMD2<Float>) -> Polygon2D
}

// Store, StoreEdits.swift
extension EditStore {
    /// `EditLog.reset(keeping:)` under the edits lock, written like `append` (not written when
    /// nothing changed); posts `.mapperEditsDidChange` after a write. Throws without writing when an
    /// existing log cannot be read.
    @discardableResult
    static func reset(_ package: ProjectPackage, keeping keep: (EditOperation) -> Bool) throws -> EditLog
}
```
`batch` is a recursive case through an array, which needs no `indirect`; the synthesized `Codable` encodes it as `{"batch":{"operations":[...]}}`. Stubs until 3.37b and 3.37c land: `case .moveOpening, .resizeOpening, .mergeRooms, .splitRoom, .batch: return true` in both `apply(_:)` switches, and `CleanModel.applyingEdits` keeps reading `log.active` until 3.37b switches it to `flattenedActive`.

**Must NOT do.** No other Core change; no change to the build 4 cases, their coding keys or `targets`; `mergedOutlines` never becomes non-optional (old projects must decode); no behavior in the stubs.

**Self-test.** `CoreSelfTest` gains at least 10 checks: each new case round trips through `ProjectStore.encoder` and `decoder`, including a batch nested in a batch; `targets` of each new case (mergeRooms without duplicates, splitRoom lists both); `flattened` of a nested batch; `flattenedActive` of a log whose last batch was undone excludes it; `reset(keeping:)` keeps the chosen operations in order, drops the redo tail, raises `revision` and returns false when nothing changes; a `CleanFloor` and a `PlanRoom` encoded with nil `mergedOutlines` have no such key, and build 4 JSON without it decodes with nil. `GeometrySelfTest` gains at least 4: a 4 x 5 m rectangle clipped by the line y = 2 gives areas 12 (left of +x) and 8 (right, clipping with the reversed line); a line missing the rectangle gives the whole ring on one side and an empty ring on the other; an L-shape cut by a line crossing it twice keeps the correct total area; `a == b` gives an empty ring. `StoreSelfTest` gains at least 2: `EditStore.reset` in a temporary package keeps the chosen operations and raises the revision; a reset that changes nothing does not write.

**Acceptance checks.** `integration` compiles green with the stubs; build 4 projects open unchanged (smoke #2); no module other than RoomModel and FloorPlan needs a change for the new cases.

**SPEC owned.** "FLOOR PLAN EDITING" (move and resize doors and windows, merge and split rooms) as data; "Manual edits must not overwrite raw scan data" (edits stay overlays).

**TEST_PLAN ids.** PEDIT-05, PEDIT-06, PEDIT-07, PEDIT-09.

### 3.37b RoomModel revision: wall orientation and the CR-1 operations (wave 5a0)

**Purpose.** Two changes to the clean model. First, the FloorPlan change request: walls outside the room loop (stubs, partitions, and every wall of a room whose loop does not close) are reversed (start and end swapped) so the room is on their left, instead of keeping their direction and flipping the normal; with it every clean wall satisfies the CR-1 orientation invariant and FloorPlan no longer reverses walls, so `atStart`, opening offsets and hinge sides mean the same end in the clean model and the plan. Second, `CleanModel.apply` implements the CR-1 operations (move and resize openings, merge and split rooms, batches), metrics and the clean mesh count merged outlines, and edit readers flatten batches.

**Build and wave.** Build 5, wave 5a0 (branch `impl/roommodel-b5`), after CR-1 is on `integration` and before any wave 5a module starts (PlanEditor's and MeasureTool's self-tests apply these operations; Structure builds rooms with `CleanModelBuilder`). Dependencies as build 4. About 350 lines of changes.

**Files.** `ios/Sources/RoomModel/CleanModelBuilder.swift` (cleanWall), `CleanModel+Edits.swift`, new `CleanModel+RoomEdits.swift` (merge, split, opening moves, batch; keeps `CleanModel+Edits.swift` under about 450 lines), `RoomMetricsCalculator.swift`, `CleanMeshBuilder.swift`, `RoomModelSteps.swift` (rules version), `RoomModelSelfTest.swift`, `RoomModelSelfTestEdits.swift`, new `RoomModelSelfTestB5.swift`. `CleanModel.refresh(_:)` loses its `private` so the new file can call it.

**Public Swift API.** Unchanged signatures; new behavior:
```swift
extension CleanModelBuilder {
    /// (changed) A wall outside the loop whose left perpendicular points away from `reference` is
    /// reversed (`WallSegment.reversed`: start and end swapped, arc unchanged); the normal is always the
    /// left perpendicular of start -> end. Loop walls are unchanged (counter-clockwise, room on the left).
    static func cleanWall(_ segment: WallSegment, inLoop: Bool, reference: SIMD2<Float>, geometry: Provenance,
                          options: CleanBuildOptions) -> CleanWall
}
final class CleanModelStep: ProcessingStep {
    /// (changed value) Every clean.json made before this revision is rebuilt when its project is next
    /// processed (AppShell's upgrade pass, 3.43e, enqueues ready projects once).
    static let rulesVersion = "cleanModel-rules=2"
}
extension CleanModel {
    /// (extended) CR-1 operations, see the rules below.
    mutating func apply(_ op: EditOperation) -> Bool
    /// (changed) Scale corrections are read from `log.flattenedActive`.
    func applyingEdits(_ log: EditLog) -> (model: CleanModel, orphaned: [EditOperation])
}
extension RoomMetricsCalculator {
    /// (changed) Floor area and perimeter are sums over `floor.outline` and every `floor.mergedOutlines`
    /// part; length and width come from `Rectangle2D.minimumArea` of the points of all parts; volume is
    /// the total area times the ceiling height.
    static func metrics(for room: CleanRoom) -> RoomMetrics
}
extension CleanMeshBuilder {
    /// (changed) Floor and ceiling parts also triangulate every merged outline.
    static func parts(for model: CleanModel, includeCeiling: Bool, includeHidden: Bool) -> [CleanMeshPart]
}
```

**Rules for the new operations.** Each returns false only when a target is missing, and then changes nothing; geometry changes call the existing `refresh(_:)` of the room (occlusion and unscaled metrics); `applyingEdits` recomputes everything at the end as before.
- `moveOpening(opening, offset)`: missing opening false; an opening without a wall returns true unchanged; else `offsetAlongWall = clamp(offset, 0, max(0, wall.length - width))`, provenance `.user`.
- `resizeOpening(opening, width, sill, head)`: missing opening false; width clamped to [0.05, wall length] keeping the center (then the offset clamped as above); heights applied when finite with 0 <= sill < head: head capped by the wall height, sill forced to 0 for `door` and `openDoor`; invalid heights keep the old ones (logged); provenance `.user`.
- `mergeRooms(rooms, into)`: false when `into` or any listed room is missing. Each listed room on the same floor as `into` (others are skipped and logged) gives its walls, openings and objects to `into`, its outline and merged outlines to `into.floor.mergedOutlines`, and is removed; `into` keeps its name, section label, floor elevation and ceiling (a ceiling difference above 5 cm is logged).
- `splitRoom(room, line, newRoom)`: false when `room` is missing; true unchanged when `newRoom` already exists (a replay), when `line` has fewer than two points or they coincide, or when either side of the line holds less than 0.01 square meters (logged). Parts are `floor.outline` plus the merged outlines, each cut with `Polygon2D.clipped(leftOf: first, last)` for `room` and `clipped(leftOf: last, first)` for the new room; a side's largest piece becomes its `outline`, the others its `mergedOutlines` (nil when none). Walls go to the side of their plan midpoint (on the line: `room`), openings follow their wall (no wall: `room`), objects follow their center. The new room is `CleanRoom(id: newRoom, recordID: room.recordID, name: "", sectionLabel: nil, floorIndex:, ...)` with the same floor elevation, floor provenance and ceiling, inserted right after `room`.
- `batch(operations)`: applied in order to a copy; the first false returns false and leaves the model unchanged; else the copy replaces the model and true.
- `moveWallEndpoint` (extended): vertices of `mergedOutlines` at the old end (within 1 mm) move too.
- Builder: `cleanWall` for `!inLoop` uses `segment.reversed` when `simd_dot(leftNormal, reference - middle) < 0`, then the left normal. Openings are attached after the walls are built, so their offsets and default swings are measured from the new start; occlusion spans follow.

**Uses.** As build 4, plus Core `EditOperation` (CR-1 cases, `flattened`), `EditLog.flattenedActive`, `CleanFloor.mergedOutlines`; Geometry `Polygon2D.clipped(leftOf:_:)`.

**Must NOT do.** Never reverse a loop wall; never change a wall's arc when reversing it; never read `log.active` for scale corrections (batches hide them); never fill a merged room's gap between outlines with floor (the parts stay separate); never give the new room of a split a RoomPlan identifier.

**Self-test.** At least 16 new checks (`RoomModelSelfTestB5.swift`): a stray wall whose left side faces away from the room comes out reversed with the left normal; on every fixture (rectangle, L, stub, flipped `columns.0`, curved, loop not closed) each wall's normal is the left perpendicular of start -> end within 1e-4; a curved stray wall keeps its arc when reversed; an opening on a reversed stray wall has its offset from the new start; `moveOpening` clamps and sets `.user`; `resizeOpening` keeps the center, forces a door's sill to 0, caps the head at the wall height, and ignores head <= sill; `mergeRooms` of a 4 x 5 m and a 3 x 4 m room gives one room with both rooms' walls, one merged outline, floor area 32 and perimeter 18 + 14 within 1e-3; `mergeRooms` with a missing room returns false and changes nothing; `splitRoom` of the 4 x 5 m room at y = 2 gives rooms of 12 and 8 square meters with walls and objects on their sides and the new room's `recordID` equal to the old one; a split line missing the room and a replayed split return true unchanged; a batch applies all its operations; a batch with one missing target returns false and leaves the model equal to before; a scale correction inside a batch is applied by `applyingEdits`; length and width of a merged room come from all its points; `CleanMeshBuilder` floor parts of a merged room have the total area within 1e-3; `moveWallEndpoint` moves a matching merged-outline vertex; `CleanModelStep.rulesVersion` is "cleanModel-rules=2". The build 4 check "flipped wall still in loop order" stays; any build 4 check that expected a stray wall's normal to be flipped is replaced.

**Acceptance checks.** Every clean wall satisfies the orientation invariant (logged count of reversed stray walls per room); a plan edit shows in 3D Clean and in the measurement panel (PEDIT-06 "show in 3D CLEAN too"); old projects are rebuilt once by the upgrade pass and still open while they wait (smoke #2).

**SPEC owned.** "FLOOR PLAN EDITING" (move, resize, merge and split reach the clean model and the measurements); "CORE DESIGN PRINCIPLE" Representation C stays consistent with Representation D.

**TEST_PLAN ids.** PEDIT-01, PEDIT-05, PEDIT-06, PEDIT-07, MEAS-05 (merged and split room sizes), smoke #2.

### 3.37c FloorPlan revision: CR-1 operations, merged rooms, no reversed walls (wave 5a0)

**Purpose.** The plan side of CR-1: `PlanModel.apply` implements the new operations (move and resize openings, merge and split rooms, batches); `PlanBuilder` copies every clean wall start -> end to `PlanWall` a -> b (it no longer reverses walls, relying on the RoomModel revision's invariant), so edits address the same wall end in both models; merged rooms draw one tag and hit-test on all their parts; and room edges that no wall covers (a split line, the outline of a room whose loop did not close) are drawn as a thin dashed boundary on a new layer, shown with the room names.

**Build and wave.** Build 5, wave 5a0 (branch `impl/floorplan-b5`), in parallel with 3.37b, after CR-1. Dependencies as build 4. About 300 lines of changes.

**Files.** `ios/Sources/FloorPlan/PlanBuilder.swift`, `PlanModel+Edits.swift`, new `PlanModel+RoomEdits.swift` (merge, split, opening moves, batch), `PlanDrawing.swift` (layer, toggles, room hits, boundaries), `FloorPlanSteps.swift` (hash), `FloorPlanSelfTest.swift`, new `FloorPlanSelfTest+B5.swift`. The private lookups of `PlanModel+Edits.swift` (`levelIndex(_:)`, `updateRoom`, `updateOpening`, `updateWall`) lose their `private` so the new file can use them.

**Public Swift API.**
```swift
extension PlanBuilder {
    /// (changed) Walls are copied with a = start and b = end; opening offsets and swings unchanged.
    /// A clean wall whose normal points to the right of start -> end (data older than 3.37b) is kept as
    /// is and counted in one log line per build; it is not reversed.
    static func build(from model: CleanModel, floors: [FloorRecord]) -> PlanModel
    /// Sum of the polygon areas of `outline` and every merged outline.
    static func totalArea(_ room: PlanRoom) -> Float
}
extension PlanModel {
    /// (extended) CR-1 operations, see the rules below.
    mutating func apply(_ op: EditOperation) -> Bool
}
extension PlanLayers {
    /// Room edges not covered by a wall, drawn dashed; hidden with the room names.
    static let roomBoundaries = "A-AREA-BNDY"
}
extension PlanDrawing {
    /// An outline edge counts as covered when its midpoint lies within this distance of a wall segment
    /// of the level (or of its body, the wall offset to its right by its thickness), meters.
    static let boundaryWallSlack: Float = 0.08
}
final class FloorPlanStep: ProcessingStep {
    /// (new) Added to the input hash extra.
    static let rulesVersion = "planBuilder-rules=2"
}
```

**Rules.**
- `moveOpening(opening, offset)`: missing opening false; `offset` clamped to [0, wall length - width] on its wall.
- `resizeOpening(opening, width, _, _)`: missing opening false; width clamped to [0.05, wall length] keeping the center, then the offset clamped; heights ignored (the plan has none).
- `mergeRooms(rooms, into)`: false when any room is missing; listed rooms on another level are skipped (logged); each merged room's outline and merged outlines join `into.mergedOutlines`, it is removed, and `into.area = totalArea(into)`; `labelAt` unchanged.
- `splitRoom(room, line, newRoom)`: as in 3.37b (same `Polygon2D.clipped` calls, same thresholds, same replay rules); the kept room's outline and merged outlines are its left pieces, `area = totalArea`, `labelAt = PlanBuilder.interiorPoint(of:)` of its outline; the new `PlanRoom(id: newRoom, name: "", ...)` goes right after it on the same level.
- `batch`: all or nothing on a copy, as in 3.37b.
- `moveWallEndpoint` (extended): merged-outline vertices within `outlineFollowTolerance` move too, and the room area is `totalArea`.
- `PlanDrawing.make`: a room adds one `.room` hit per part (outline and each merged outline, same element); its tag is drawn once at `labelAt`. For every part edge whose midpoint is farther than `boundaryWallSlack` from every wall segment and wall body of the level, a dashed line (`PlanSketch.dashedLine`) on `PlanLayers.roomBoundaries`. `PlanLayers.all()`, `drawingOrder` (after `roomNames`), `color(of:)` (the room name color) and `PlanToggles.hiddenLayers` (hidden when `roomNames` is off) include the new layer.
- `FloorPlanStep.inputHash` adds `rulesVersion`, so plans older than this revision are rebuilt with their clean model.

**Uses.** As build 4, plus Core CR-1 (`EditOperation` cases, `PlanRoom.mergedOutlines`), Geometry `Polygon2D.clipped(leftOf:_:)`.

**Must NOT do.** Never reverse a wall in `PlanBuilder`; never draw a boundary line on a wall; never bake a default title into a split room's name; never add DXF-only layers (the new layer is an ordinary `Plan2D.Layer` every writer already handles).

**Self-test.** At least 16 new checks (`FloorPlanSelfTest+B5.swift`): for a revised clean model every plan wall's `a` equals the clean start in plan; a clean wall with a right-side normal keeps a = start (not reversed); the build 4 check that expected such a wall to be reversed, with its mirrored spans and hinge, is replaced by this one; `moveOpening` and `resizeOpening` clamp and keep the center; `mergeRooms` of two rooms leaves one room with area equal to the sum, one merged outline, and `PlanDrawing.hitTest` inside the second part returns the merged room; a merge with a missing room returns false; `splitRoom` gives two rooms whose areas sum to the original and whose `labelAt` lies inside each outline; a replayed split is unchanged; a batch is all or nothing; `moveWallEndpoint` moves merged-outline vertices and updates the area; a split room draws at least one `A-AREA-BNDY` entity along the cut and a rectangle room with walls on every edge draws none; `roomNames` off removes the boundary layer and nothing else; `PlanLayers.all()` names are unique and include the new layer; `FloorPlanStep.inputHash` changes with `rulesVersion`.

**Acceptance checks.** Plans of edited projects draw merged and split rooms with one tag each and the split line dashed; exports (PDF, SVG, DXF, PNG) carry the new layer like any other; a build 4 plan is rebuilt once by the upgrade pass (3.43e).

**SPEC owned.** "FLOOR PLAN EDITING" (move and resize doors and windows, merge and split rooms on the plan); "2D FLOOR PLAN" (room names and room outlines after edits).

**TEST_PLAN ids.** PEDIT-05, PEDIT-06, PEDIT-07, PLAN-02, PLAN-05, EXP-05, EXP-07.

### 3.38 CoverageOverlay (wave 5b)

**Purpose.** The visible side of live coverage (SPEC GREEN, YELLOW, RED, GRAY): the colored live mesh over the camera in mesh-only views (patch passes, large objects, space scans), one `LowLevelMesh` per ARKit anchor with four parts (green, yellow, red, gray `UnlitMaterial`, `blending = .transparent(opacity: 0.45)`), rebuilt from CoverageLive's changed anchors at most every 0.33 s on main, skipped outside the view, frozen from thermal `.serious`; plus the SwiftUI minimap (a `Canvas` of `MinimapSnapshot` with the camera marker) and the color legend, which Room mode shows over `RoomCaptureView` (ScanUI revision).

**Build and wave.** Build 5, wave 5b. Core, CoverageLive, CaptureCore (`ThermalGovernor`), Coverage (`CoverageState`), Support; RealityKit, SwiftUI. It attaches to any `ARView` handed to it, so it does not need LiveMeshView. About 900 lines plus the self-test.

**Files.** `ios/Sources/CoverageOverlay/CoverageOverlayPacking.swift` (pure: grouping, packing, parts, capacity, visibility, scheduling), `CoverageOverlayRenderer.swift` (main actor), `CoverageMinimapView.swift`, `CoverageLegendView.swift`, `CoverageOverlaySelfTest.swift`, `ios/Sources/Support/Copy+CoverageOverlay.swift`.

**Public Swift API.**
```swift
/// Colors of the four states; alpha is the opacity.
struct CoverageOverlayStyle: Equatable, Sendable {
    var opacity: Float = 0.45
    static let standard: CoverageOverlayStyle
    /// Green (0.15, 0.80, 0.35), yellow (0.98, 0.80, 0.15), red (0.92, 0.25, 0.22), gray (0.60, 0.60, 0.62), alpha `opacity`.
    func color(for state: CoverageState) -> SIMD4<Float>
}

/// One anchor packed for upload (built off main).
struct CoverageOverlayBuffers {
    var anchorID: UUID
    var revision: UInt64
    var transform: simd_float4x4
    /// 32 bytes per vertex: position .float3 at 0, normal .float3 at 12 ((0, 1, 0) when unknown), uv0 .float2 at 24 (zero).
    var vertexData: Data
    var vertexCount: Int
    /// Triangles grouped by state in `CoverageOverlayPacking.stateOrder`, each group in its original order.
    var indices: [UInt32]
    /// Index count per state, 4 entries in `stateOrder`.
    var groupCounts: [Int]
    /// Anchor-local bounds.
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
}
struct CoverageOverlayPart: Equatable, Sendable {
    /// Bytes from the start of the index buffer (`LowLevelMesh.Part.indexOffset` is in bytes).
    var byteOffset: Int
    var indexCount: Int
    /// Position of the state in `stateOrder` (the material index).
    var materialIndex: Int
}

/// Pure packing and scheduling. Any queue.
enum CoverageOverlayPacking {
    static let stateOrder: [CoverageState] = [.green, .yellow, .red, .gray]
    static let vertexStride = 32, positionOffset = 0, normalOffset = 12, uvOffset = 24
    static let capacityFactor: Double = 1.5
    /// Stable grouping of index triples by their triangle's state.
    static func grouped(indices: [UInt32], states: [CoverageState]) -> (indices: [UInt32], counts: [Int])
    /// Nil (logged) when `states.count != indices.count / 3` or an index is out of range.
    static func pack(_ anchor: CoverageAnchorFaces) -> CoverageOverlayBuffers?
    /// One part per non-empty group, byte offsets = preceding index counts x 4.
    static func parts(groupCounts: [Int]) -> [CoverageOverlayPart]
    /// `current` when it is enough, else ceil(needed x capacityFactor).
    static func capacity(needed: Int, current: Int) -> Int
    /// World bounds (`CoverageAnchorFaces.boundsMin`, `boundsMax`): their bounding sphere meets the cone of
    /// `halfAngleDegrees` around the camera's forward (-Z column) within `maxDistance`; true when the camera is inside them.
    static func isVisible(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, cameraToWorld: simd_float4x4,
                          halfAngleDegrees: Float, maxDistance: Float) -> Bool
    /// Up to `limit` visible anchors from `pending`, nearest bounds center first; the rest stay pending.
    static func schedule(_ pending: [UUID: CoverageAnchorFaces], cameraToWorld: simd_float4x4, halfAngleDegrees: Float,
                         maxDistance: Float, limit: Int) -> [UUID]
}

/// Draws CoverageLive's anchors into an ARView. Main actor.
@MainActor final class CoverageOverlayRenderer {
    struct Options: Equatable {
        var refreshInterval: Double = 0.33
        var maxAnchorsPerTick = 24
        var halfAngleDegrees: Float = 60
        var maxDistance: Float = 6
        var style: CoverageOverlayStyle = .standard
        init() {}
    }
    init(source: CoverageLiveRecorder, thermal: ThermalGovernor?, options: Options = Options())
    /// Adds one `AnchorEntity(world:)` root to `arView.scene` and starts the refresh loop. A second
    /// attach moves the root to the new view.
    func attach(to arView: ARView)
    /// Stops the loop and removes the root (entities and meshes released). Idempotent.
    func detach()
    /// User toggle (Show Colors / Hide Colors): the root's `isEnabled`.
    var isVisible: Bool { get set }
    /// True while `thermal.policy.overlayEnabled` is false (serious or critical): nothing is rebuilt.
    private(set) var isFrozen: Bool
    private(set) var anchorEntityCount: Int
    /// Pure rule behind `isFrozen` (nonisolated so the self-test can call it off main).
    nonisolated static func shouldFreeze(policy: ThermalPolicy) -> Bool
}

/// Top-down map: `MinimapSnapshot` cells (covered green, partial yellow, missing red, empty transparent
/// over a dark translucent square that reads as gray, not scanned), walls as white lines, plan +y up,
/// the camera as a small arrow at `camera` pointing along `heading` (CR-8). Fixed 120 pt square.
struct CoverageMinimapView: View { init(snapshot: MinimapSnapshot?, coverageFraction: Float) }
/// The four colors with `Copy.Scanning.legend*` texts under `Copy.Scanning.legendTitle`; one combined
/// VoiceOver element reading `Copy.A11y.coverageLegend`.
struct CoverageLegendView: View { init(compact: Bool = false) }
/// Pure layout of the minimap (tested).
enum CoverageMinimapLayout {
    /// Scale and offset that fit `width x height` cells into `size` points, centered.
    static func fit(width: Int, height: Int, in size: CGSize) -> (scale: CGFloat, offset: CGPoint)
    /// The rectangle of cell (x, y); plan +y points up on screen, so row 0 is drawn at the bottom.
    static func cellRect(x: Int, y: Int, height: Int, scale: CGFloat, offset: CGPoint) -> CGRect
    /// Screen point of a plan position.
    static func point(_ plan: Vec2, origin: Vec2, cellSize: Float, height: Int, scale: CGFloat, offset: CGPoint) -> CGPoint
    /// nil for `.empty`, else the style color of covered, partial or missing.
    static func color(for cell: MinimapCell, style: CoverageOverlayStyle) -> SIMD4<Float>?
    /// Rounded percent for VoiceOver.
    static func percent(_ fraction: Float) -> Int
}
```

Refresh loop (main, a `Task` with `Task.sleep(nanoseconds:)` at `refreshInterval`): frozen or hidden skips the tick; `source.anchorFaces(changedSince: lastRevision)` merges into a pending dictionary (latest wins); the camera is `arView.cameraTransform.matrix`; `schedule` picks up to `maxAnchorsPerTick`; one `Task.detached(priority: .userInitiated)` packs them (at most one pack in flight); back on main each buffer goes to its anchor's `LowLevelMesh`: when the capacities hold, copy the bytes with `withUnsafeMutableBytes(bufferIndex: 0)` and `withUnsafeMutableIndices`, then `parts.replaceAll` with `parts(groupCounts:)` (each part's `bounds` is the anchor bounds), and set the entity's transform; otherwise create a `LowLevelMesh` with `capacity(needed:current:)` for vertices and indices (layout as Viewer3D: position, normal, uv0, stride 32, `UInt32` indices), `try MeshResource(from:)` (the synchronous overload, main actor) and a new `ModelEntity(mesh:materials:)` with the four materials in `stateOrder`, replacing the old entity under the root. Every material is `UnlitMaterial(color:)` with `blending = .transparent(opacity: .init(floatLiteral: opacity))` and `faceCulling = .none` (LiDAR winding is inconsistent). The `MeshResource` keeps a reference to the `LowLevelMesh` and shows in-place changes without being rebuilt (RESEARCH 3.5).

**Uses.** CoverageLive: `CoverageLiveRecorder` (`anchorFaces(changedSince:)`), `CoverageAnchorFaces`. CaptureCore: `ThermalGovernor` (`policy`), `ThermalPolicy.overlayEnabled`. Coverage: `CoverageState`. Core: `MinimapSnapshot` (with CR-8), `MinimapCell`, `Vec2`. Support: `Copy.Scanning` (`legendTitle`, `legendGreen`, `legendYellow`, `legendRed`, `legendGray`), `Copy.A11y.coverageLegend`, `LogStore`.

**Apple APIs** (RESEARCH 3.5, 3.6):
```swift
@MainActor init(descriptor: LowLevelMesh.Descriptor) throws
// Descriptor(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType: .uint32)
// Attribute(semantic: .position/.normal/.uv0, format: .float3/.float2, layoutIndex: 0, offset:)
// Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: 32)
// Part(indexOffset:indexCount:topology: .triangle, materialIndex:bounds:)
var parts: LowLevelMesh.PartsCollection { get set }                         // replaceAll(_:)
@MainActor func withUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)
@MainActor func withUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)
@MainActor @preconcurrency convenience init(from mesh: LowLevelMesh) throws   // MeshResource, sync overload
var blending: UnlitMaterial.Blending                                         // .transparent(opacity:)
var faceCulling: UnlitMaterial.FaceCulling { get set }                       // .none, iOS 18.0
@MainActor @preconcurrency var isEnabled: Bool { get set }                   // Entity
var cameraTransform: Transform { get }                                       // ARView
struct Canvas<Symbols> where Symbols : View                                  // SwiftUI, iOS 15.0
```
Not in RESEARCH: `LowLevelMesh.Part.indexOffset` is "the offset, in bytes, of the first index" (Apple documentation JSON, iOS 18.0); `ModelEntity(mesh:materials:)`, `AnchorEntity(world:)`, `Scene.addAnchor(_:)`, `Scene.removeAnchor(_:)`, `Entity.addChild(_:)`, `removeFromParent()`, `Entity.transform`, `Transform(matrix:)`, `Transform.matrix` (RealityKit, iOS 13, as Viewer3D uses them); `Task.sleep(nanoseconds:)` (iOS 13).

**Must NOT do.** No `.showSceneUnderstanding` as the user-facing view; no CustomMaterial or ShaderGraphMaterial in the `.ar` view (RESEARCH 3.5: CustomMaterial crashed with AR compositing); no `.occlusion` scene understanding. Never regenerate meshes per frame (at most every 0.33 s, changed anchors only); never write a `LowLevelMesh` off main; no `MeshResource.generateAsync`, no `Descriptor.allowsPrimitiveRestart`, no 6-argument Descriptor init, no `UnlitMaterial.baseColor`. Never decide a coverage state (states come from CoverageLive), never mutate CoverageLive. No hardcoded text.

**Copy strings.** Existing: `Copy.Scanning.legendTitle`, `legendGreen`, `legendYellow`, `legendRed`, `legendGray`; `Copy.A11y.coverageLegend`. New (`extension Copy { enum CoverageOverlay }` in `Copy+CoverageOverlay.swift`): `minimapLabel = "Map of your scan"`, `static func minimapValue(_ percent: Int) -> String { "\(percent) percent scanned" }`, `showColors = "Show Colors"`, `hideColors = "Hide Colors"`.

**Self-test.** `CoverageOverlaySelfTest.run()`, at least 16 checks:
1. `grouped` of states gray, green, yellow, green, red gives triangles 1, 3, 2, 4, 0 and counts 6, 3, 3, 3.
2. `grouped` keeps every index triple intact (same multiset of triples).
3. `parts(groupCounts: [6, 0, 3, 3])` gives 3 parts: byte offsets 0, 24, 36, index counts 6, 3, 3, material indices 0, 2, 3.
4. `pack` writes 32 bytes per vertex with the normal at byte 12 and zero uv at 24.
5. `pack` uses (0, 1, 0) for a missing normal.
6. `pack` with a states count mismatch returns nil.
7. `pack` bounds equal the positions' bounds.
8. `capacity`: needed 100 of 0 gives 150; needed 100 of 120 gives 120; needed 130 of 120 gives 195.
9. `isVisible`: bounds 2 m ahead true; behind false; 10 m ahead false; camera inside true.
10. `schedule` returns the nearest visible first, at most `limit`, never an invisible one.
11. Style: four distinct colors, every alpha equal to `opacity`.
12. `CoverageMinimapLayout.fit` of 10 x 20 cells into 120 x 120 pt gives scale 6 and centers horizontally.
13. `cellRect(x: 0, y: 0, ...)` lies at the bottom row (plan +y up).
14. `color(for:)` is nil for `.empty` and the style colors for the others.
15. `percent(0.943)` is 94.
16. `CoverageOverlayRenderer.shouldFreeze(policy:)` is true for `ThermalPolicy.forLevel(.serious)` and `.critical`, false for `.nominal` and `.fair`.

**Acceptance checks.** All RealityKit calls on main; packing off main; at most one pack in flight; entity count logged every 30 s with the last tick time (target under 8 ms of main-thread work per tick); frozen state logged on change; every material has `faceCulling = .none`; `detach()` removes the root and stops the loop (no tick after it).

**SPEC owned.** "LIVE SCANNING EXPERIENCE" (GREEN = scanned well, YELLOW = partially scanned, RED = missing information, GRAY = not scanned, shown live; "The user should see the model forming while walking" in mesh-only scans); legend text for the four colors.

**TEST_PLAN ids.** LIVE-01 (frame rate with the overlay on), LIVE-02, smoke list #3 (minimap and colors during a room scan), PERF-01, PERF-05 (overlay frozen at serious).

### 3.39 LargeObject (wave 5b)

**Purpose.** Large objects (appliances, vehicles, machines, equipment; D4, ARCHITECTURE 4.5): capture on the LiDAR mesh driver instead of Object Capture. The user taps the object; the tap becomes a seed point (ray through the tap against the live faces, else an `.estimatedPlane` raycast); a gravity-aligned `OrientedBox.fit(_:gravityAligned: true)` is grown every second from the live faces connected to the seed above the floor (floor height from floor-classified faces, never from plane anchors, D14), with tall wall-classified columns left out; `SectorCoverage` tracks 8 azimuth sectors plus the top around the box from camera positions and face coverage and raises "Move around the object slowly", "Capture the left side", "Capture the right side", "Capture the back", "Capture the top", "Move closer to this area", "This section needs more detail" and "All sides captured. Tap Done when you're ready" through Coverage's `GuidanceEngine` (CR-9). At Done the pass is sealed as `raw/objects/<o>/` (RawScanFolder layout plus `largeobject.json`), an `ObjectRecord` (size `.large`) is added and the box is stored as a `cropObject` edit, which ObjectModel's `ObjectMetricsStep` uses to isolate the object.

**Build and wave.** Build 5, wave 5b. Core, CoverageLive, LiveMeshView, CaptureCore, MeshRecord, Store, Coverage (with CR-9), Geometry, ScanUI (`ScanErrorCopy`, `ScanAlert`, `ScanFlowModel.defaultProjectName`), Units, Support; ARKit, RealityKit, SwiftUI. It does not need ObjectModel or MeshProcessing (the isolation runs in ObjectModel's step from the edit). About 1400 lines plus the self-test.

**Files.** `ios/Sources/LargeObject/LargeObjectModel.swift` (the `@MainActor` flow), `LargeObjectTracker.swift` (hub recorder: poses; 1 Hz box and sector pass on its own queue), `LargeObjectSeed.swift` (pure: floor, growth, box, ray pick), `LargeObjectSectorCoverage.swift` (pure `SectorCoverage`), `LargeObjectBoxEntity.swift` (RealityKit wireframe box), `LargeObjectScreen.swift` (screen and HUD), `LargeObjectSelfTest.swift`, `ios/Sources/Support/Copy+LargeObject.swift`.

**Public Swift API.**
```swift
/// The object being captured; the project exists before capture.
struct LargeObjectTarget: Equatable, Sendable {
    var projectID: UUID
    var package: ProjectPackage
    var sessionID: UUID
    var objectID: UUID
    var settings: ScanSettings
    /// `ScanSettings.defaults(for: .object)` with detail `.high` (0.20 m or 10 degree keyframe gate)
    /// and distance `.normal` (0.3 to 4 m, large objects are walked around at arm's length or more).
    static func defaultSettings() -> ScanSettings
    /// Main. Creates the Object project (`ProjectLibrary.shared.create(kind: .object, name:
    /// ScanFlowModel.defaultProjectName(mode: .object, now: now))`, as ObjectUI does), sets `settings`, appends `CaptureSessionRef(id:startedAt:frameLink:
    /// .projectFrame(sessionID:), worldMapFile: nil)` and returns the target. The caller ran
    /// `ScanPreflight.run(mode: .object, isDemo: false)` (async) first.
    @MainActor static func makeNew(now: Date) throws -> LargeObjectTarget
}

/// `largeobject.json` in the sealed folder: capture facts (the user-facing box is the edit).
struct LargeObjectLog: Codable, Equatable, Sendable {
    static let fileName = "largeobject.json"
    var seed: Vec3?
    var floorY: Float?
    var front: Vec3?
    var box: OrientedBoxRecord?
    /// Seconds the camera viewed each region (8 sides, then top) and each region's face score.
    var viewSeconds: [Double]
    var faceScores: [Float?]
    var topRequired: Bool
    var covered: Int
    var required: Int
}

/// One live face for sector scoring.
struct SectorFace: Equatable {
    var centroid: SIMD3<Float>
    var normal: SIMD3<Float>
    var area: Float
    var state: CoverageState
}

/// 8 azimuth sectors (45 degrees each) plus the top around the box (D4). Azimuth is measured around
/// +Y from the front direction (box center toward the camera when the seed was set), positive toward
/// the viewer's right as seen from the front: sector 0 front, 1 front-right, 2 right, 3 back-right,
/// 4 back, 5 back-left, 6 left, 7 front-left; region 8 is the top. Pure value type.
struct SectorCoverage: Equatable {
    static let sideCount = 8
    static let topRegion = 8
    static let minViewSeconds: Double = 1.5
    static let viewConeDegrees: Float = 35
    static let viewDistance: ClosedRange<Float> = 0.3...3.5     // camera to the box surface
    static let topElevationDegrees: Float = 25
    static let maxReachableTop: Float = 1.9                       // box top above the floor
    static let minFaceArea: Float = 0.05
    static let coveredScore: Float = 0.6
    static let closerDistance: Float = 1.6
    static let startupSeconds: Double = 4
    private(set) var box: OrientedBox
    private(set) var floorY: Float
    /// Unit horizontal (x, z) front direction.
    let front: SIMD2<Float>
    private(set) var viewSeconds: [Double]        // 9 regions
    private(set) var meanViewDistance: [Float?]   // 9 regions
    private(set) var faceScores: [Float?]         // 9 regions, nil under minFaceArea
    private(set) var elapsed: Double
    init(box: OrientedBox, floorY: Float, firstCamera: SIMD3<Float>)
    mutating func updateBox(_ box: OrientedBox, floorY: Float)
    /// Adds `seconds` to the region the camera sees: a side sector when the camera looks at the box
    /// center within `viewConeDegrees` from `viewDistance` of its surface; the top when the camera is at
    /// least `topElevationDegrees` above the top face center and looks down at it. Nothing unless tracking is normal.
    mutating func observe(cameraToWorld: simd_float4x4, seconds: Double, trackingNormal: Bool)
    /// Face scores: faces inside the box grown by 0.05 m, normals turned outward from the box center;
    /// top = normal.y > 0.7 within 0.15 m of the top; bottom-facing faces ignored; side sector from the
    /// normal's horizontal azimuth. Score = (green area + 0.5 x yellow area) / area.
    mutating func updateFaces(_ faces: [SectorFace])
    /// Degrees in (-180, 180], 0 front, +90 right.
    func azimuthDegrees(of point: SIMD3<Float>) -> Float
    static func sector(azimuthDegrees: Float) -> Int
    /// False when the box top is more than `maxReachableTop` above the floor (a person cannot see it).
    var topRequired: Bool { get }
    /// viewSeconds >= minViewSeconds and (no score or score >= coveredScore).
    func isCovered(_ region: Int) -> Bool
    var coveredCount: Int { get }
    var requiredCount: Int { get }                // 8 or 9
    /// The one object message for now (camera-relative):
    /// startup with nothing covered -> .objectMoveAround; all required covered -> .objectLooksComplete;
    /// the camera's own sector uncovered: mean view distance > closerDistance -> .objectMoveCloserToArea,
    /// else a score below coveredScore after minViewSeconds -> .objectNeedsDetail, else nil (keep going);
    /// otherwise the uncovered side with the smallest |delta| from the camera's azimuth (ties to the right):
    /// |delta| > 135 -> .objectCaptureBack, delta > 0 -> .objectCaptureRight, delta < 0 -> .objectCaptureLeft;
    /// only the top left -> .objectCaptureTop.
    func guidance(cameraToWorld: simd_float4x4) -> GuidanceKind?
}

/// Seed, floor, growth and box. Pure.
struct LargeObjectSample: Equatable { var position: SIMD3<Float>; var surface: SurfaceClass }
enum LargeObjectSeed {
    static let voxelSize: Float = 0.10
    static let floorClearance: Float = 0.04
    static let searchRadius: Float = 4.0          // horizontal, from the seed
    static let maxHeight: Float = 3.0             // above the floor
    static let snapRadius: Float = 0.3            // to the nearest occupied voxel
    static let wallColumnHeight: Float = 2.3      // columns taller than this and mostly wall, door or window are walls
    static let boxMargin: Float = 0.05
    static let minPoints = 30
    /// Samples (face centroids with area > 0 and their class) of the anchors whose bounds come within
    /// `searchRadius` of the seed.
    static func samples(from anchors: [CoverageAnchorFaces], near seed: SIMD3<Float>) -> [LargeObjectSample]
    /// Median y of `.floor` samples within 3 m (horizontal) when at least 20, else the 5th percentile of
    /// all samples within 1.5 m, else nil.
    static func floorHeight(seed: SIMD3<Float>, samples: [LargeObjectSample]) -> Float?
    /// Occupied voxels above floorY + floorClearance and below floorY + maxHeight within searchRadius,
    /// `.floor` and `.ceiling` samples ignored, wall columns removed; 26-connected flood fill from the seed
    /// voxel or the nearest occupied voxel within snapRadius. Returns the sample positions of the filled
    /// voxels; empty when the seed is in a wall column or nothing is near.
    static func grow(seed: SIMD3<Float>, samples: [LargeObjectSample], floorY: Float) -> [SIMD3<Float>]
    /// `OrientedBox.fit(points, gravityAligned: true)`, bottom extended down to floorY, `boxMargin` on every
    /// side; nil under `minPoints` points.
    static func box(points: [SIMD3<Float>], floorY: Float) -> OrientedBox?
    /// Anchors whose world bounds the ray crosses within `maxDistance` (slab test).
    static func anchorsOnRay(_ ray: Ray, anchors: [CoverageAnchorFaces], maxDistance: Float) -> [CoverageAnchorFaces]
    /// World triangles of `anchors` (local positions through their transforms), merged.
    static func worldMesh(_ anchors: [CoverageAnchorFaces]) -> TriangleMesh
    /// Nearest hit on `mesh` (MeshBVH) within `maxDistance`.
    static func pick(_ ray: Ray, mesh: TriangleMesh, maxDistance: Float) -> SIMD3<Float>?
}

/// Tracker state for the model (any thread copy).
struct LargeObjectTrackerState: Equatable {
    var box: OrientedBox?
    var floorY: Float?
    var covered: Int
    var required: Int
    var guidance: GuidanceKind?
    var passes: Int
}

/// Hub recorder plus a 1 Hz pass on its own serial queue "mapper.largeobject" (QoS utility).
final class LargeObjectTracker: ScanRecorder {
    static let poseInterval: Double = 0.1
    static let passInterval: Double = 1.0
    init(coverage: CoverageLiveRecorder)
    /// Resets the seed, box and sectors.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    /// Every 0.1 s copies the camera transform and tracking state; the pass (below) runs every second.
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)
    func finishRecording(completion: @escaping () -> Void)
    var stats: RecorderStats { get }                                  // zero
    /// Any thread. A new seed (nil clears); `front` is the camera position at the tap.
    func setSeed(_ seed: SIMD3<Float>?, floorY: Float?, front: SIMD3<Float>?)
    /// Hub queue: `apply(decision:to:)` with the latest object message.
    func augment(_ input: inout GuidanceInput)
    /// Pure: `extraConditions` = [decision] (empty for nil, CR-9); `viewCoverage` = nil and
    /// `nearbyMissing` = [] (object guidance replaces room coverage nags).
    static func apply(decision: GuidanceKind?, to input: inout GuidanceInput)
    /// The engine's guidance hook: `coverage.guidanceHook`, then `augment`. Formed here, outside any
    /// actor, and capturing both weakly (never form hub-queue closures in the `@MainActor` model).
    func guidanceHook(after coverage: CoverageLiveRecorder) -> (inout GuidanceInput) -> Void
    func current() -> LargeObjectTrackerState
    func log() -> LargeObjectLog
}

enum LargeObjectPhase: Equatable { case starting, aiming, locating, capturing, finishing, done(UUID), cancelled, failed(String) }

@MainActor final class LargeObjectModel: ObservableObject {
    @Published private(set) var phase: LargeObjectPhase
    @Published private(set) var box: OrientedBox?
    @Published private(set) var sidesCovered: Int
    @Published private(set) var sidesRequired: Int
    /// Seed hints (Copy.LargeObject), nil while capturing.
    @Published private(set) var hint: String?
    @Published var showsCancelConfirmation: Bool
    @Published var alert: ScanAlert?
    let target: LargeObjectTarget
    let scan: MeshScanModel
    /// For AppShell's CoverageOverlay: `CoverageOverlayRenderer(source: model.coverage, thermal: model.scan.engine.hub.thermal)`.
    let coverage: CoverageLiveRecorder
    let tracker: LargeObjectTracker
    /// Project id after the seal, the ObjectRecord and the crop edit.
    var onComplete: ((UUID) -> Void)?
    /// After a confirmed cancel (the project is deleted when it holds nothing).
    var onDismiss: (() -> Void)?
    init(target: LargeObjectTarget)
    func start()
    /// From LiveMeshScreen's onViewReady: keeps the view weakly and attaches the box entity.
    func attach(_ arView: ARView)
    /// Seed from a tap (below).
    func handleTap(_ point: CGPoint, in arView: ARView)
    func chooseAgain()
    /// Done (enabled once a box exists).
    func finish()
    func requestCancel(); func confirmCancel(); func keepScanning()
    func teardown()
}

/// Wireframe box on the ARView (`MeshResource.generateBox(size:cornerRadius:)` with an UnlitMaterial,
/// `triangleFillMode = .lines`, `faceCulling = .none`, white), placed with `Transform(matrix:)` from the
/// box axes and center; the mesh is regenerated only when a size changes by more than 2 cm.
@MainActor final class LargeObjectBoxEntity {
    init()
    func attach(to arView: ARView)
    func update(_ box: OrientedBox?)
    func detach()
}
struct LargeObjectScreen: View {
    /// `LiveMeshScreen` with `onViewReady` = `{ model.attach($0); extra?($0) }` and `onTap` = `model.handleTap`,
    /// plus the HUD: `LiveMeshTopBar` (Done enabled with a box), the hint or the sides progress, the box
    /// size, Choose Again, the cancel confirmation and alerts.
    init(model: LargeObjectModel, onViewReady extra: (@MainActor (ARView) -> Void)? = nil)
}
```

Flow:
1. `init`: `let mesh = MeshStore()`, coverage = `CoverageLiveRecorder(meshSource: mesh)`, tracker = `LargeObjectTracker(coverage: coverage)`, recorders `MeshScanRecorderSet(photos: false, mesh: mesh, extra: [coverage, tracker]).all`, `MeshScanEngine(target: .largeObject(...), recorders:)` (owned hub, profile mode `.object`, no planes, D14), `engine.guidanceAugmenter = tracker.guidanceHook(after: coverage)`, `engine.snapshotAugmenter = coverage.snapshotHook`. `start()`: `scan.start()`; phase `.aiming`, hint `Copy.LargeObject.tapToSelect`.
2. Tap (`handleTap`, main): `arView.ray(through:)`; phase `.locating`; off main: `anchorsOnRay` over `coverage.anchorFaces(changedSince: 0).anchors`, `worldMesh`, `pick` within 6 m; when nothing is hit, back on main `arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first` gives the point. Then off main `samples(from:near:)`, `floorHeight`, `grow`, `box`: a box sets `tracker.setSeed(seed, floorY:, front: camera position)` and phase `.capturing`; no box gives hint `noObjectFound` (or `tappedWall` when the seed voxel lies in a wall column) and phase `.aiming`.
3. Capturing: the tracker regrows the box every second from the current faces (seed fixed), scores faces with `updateFaces` and camera poses with `observe`, and publishes the message; a 2 Hz main loop copies `tracker.current()` into the published values and `LargeObjectBoxEntity.update`.
4. Done: `scan.finish(attachments: [LargeObjectLog.fileName: log encoded with ProjectStore.encoder])`; on `onFinished(result)`: one `ProjectLibrary.shared.update(projectID)` appends `ObjectRecord(id: objectID, name: "", size: .large, status: .captured, imageCount: result.keyframeCount, modelFile: nil)` and sets status `.needsProcessing`; `EditStore.append(.cropObject(object: ElementID(uuid: objectID), box: OrientedBoxRecord(box)), to: package)`; `thumbnail.jpg` from `arView.snapshot(saveToHDR: false)` of the attached view (`jpegData(compressionQuality: 0.7)`, `ProjectStore.writeData(_:to: package.thumbnailURL)`, best effort, logged; FloorPlan's ThumbnailStep reads only room keyframes and `Images/`, so a large object would otherwise have no Home thumbnail); `scan.teardown()`; phase `.done(projectID)`; `onComplete`. A `.failed` after `.roomFinished` (heat, storage, memory) shows `ScanErrorCopy.alert(for:)` and still completes.
5. Cancel (after `Copy.Scanning.cancelConfirm*`): `scan.discard()`; on idle, `ProjectLibrary.shared.delete(projectID)` when the manifest has no object and no room; `onDismiss`.

**Uses.** LiveMeshView: `MeshScanEngine` (`guidanceAugmenter`, `snapshotAugmenter`, `latestCameraTransform`, `hub`), `MeshScanTarget.largeObject(projectID:package:sessionID:objectID:settings:)`, `MeshScanRecorderSet`, `MeshScanModel`, `MeshScanResult`, `LiveMeshScreen`, `LiveMeshTopBar`, `Copy.LiveMeshView.saving`. CoverageLive: `CoverageLiveRecorder` (`anchorFaces(changedSince:)`, `augment`), `CoverageAnchorFaces`. CaptureCore: `ScanRecorder`, `ARSessionHub`, `ScanProfile`, `RecorderStats`, `ThermalGovernor`. MeshRecord: `MeshStore` (through the set). Coverage: `GuidanceInput` (`extraConditions`, CR-9; `viewCoverage`, `nearbyMissing`), `CoverageState`, `SurfaceClass`. Geometry: `OrientedBox` (`fit(_:gravityAligned:)`, `enclosing(_:axes:)`, `contains(_:tolerance:)`, `corners`), `Ray`, `TriangleMesh` (`init(positions:indices:)`, `transformed(by:)`, `merged(with:)`), `MeshBVH` (`init(mesh:)`, `raycast(_:maxDistance:)`). Store: `ProjectLibrary` (`create(kind:name:)`, `update(_:_:)`, `delete(_:)`, `manifest(for:)`), `EditStore.append(_:to:)`. ScanUI: `ScanErrorCopy.alert(for:)`, `ScanAlert`, `ScanFlowModel.defaultProjectName(mode:now:)`. Units: `LengthFormat.display(_:prefs:)`, `UnitPreferences.load(from:)`. Core: `ObjectRecord`, `ObjectSize`, `RoomStatus`, `CaptureSessionRef`, `FrameLink`, `ElementID`, `EditOperation.cropObject(object:box:)`, `OrientedBoxRecord`, `Vec3`, `ScanMode`, `ScanSettings`, `ProjectStore` (`encoder`, `writeData(_:to:protection:createParents:)`), `ProjectPackage.thumbnailURL`, `MapperError`. Support: `Copy.Scanning.cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`, guidance through `GuidanceKind.message`, `LogStore`.

**Apple APIs** (RESEARCH 3.1, 3.5):
```swift
@MainActor @preconcurrency func ray(through screenPoint: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?   // ARView
@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target,
                                        alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]            // .estimatedPlane, .any
@MainActor @preconcurrency static func generateBox(size: SIMD3<Float>, cornerRadius: Float = 0) -> MeshResource
@MainActor @preconcurrency func snapshot(saveToHDR: Bool, completion: @escaping (ARView.Image?) -> Void)                  // ARView, thumbnail at Done
var triangleFillMode: UnlitMaterial.TriangleFillMode { get set }                      // .lines, iOS 18.0
var faceCulling: UnlitMaterial.FaceCulling { get set }                                // .none, iOS 18.0
var transform: simd_float4x4 { get }; var trackingState: ARCamera.TrackingState { get }   // ARCamera, in the frame callback
```
Not in RESEARCH (RealityKit, iOS 13, as Viewer3D uses them): `ModelEntity(mesh:materials:)`, `AnchorEntity(world:)`, `Scene.addAnchor(_:)`, `Scene.removeAnchor(_:)`, `Entity.transform`, `Transform(matrix:)`; `Task.sleep(nanoseconds:)`.

**Must NOT do.** Plane detection stays off (D14). Never use Object Capture here and never create a second ARSession. Never put the crop into raw (the edit holds it; `largeobject.json` records the capture-time box as a fact), never write after the seal. Never run the ray pick, growth or sector pass on main or on the hub queue (tracker queue or detached tasks only). Never keep an `ARFrame`. Never show a second message beside the guidance banner's one (object messages go through `extraConditions`). Never keep an empty project after a confirmed cancel. No hardcoded text; box sizes only through Units.

**Copy strings.** Existing: guidance texts of `.objectMoveAround`, `.objectCaptureLeft`, `.objectCaptureRight`, `.objectCaptureBack`, `.objectCaptureTop`, `.objectMoveCloserToArea`, `.objectNeedsDetail`, `.objectLooksComplete` (through `GuidanceKind.message`); `Copy.Modes.object`; `Copy.Scanning.done`, `cancel`, `cancelConfirmTitle`, `cancelConfirmBody`, `cancelConfirmDiscard`, `cancelConfirmKeep`; `Copy.Quality.objectSides`. New (`extension Copy { enum LargeObject }` in `Copy+LargeObject.swift`): `tapToSelect = "Tap the object you want to scan"`, `locating = "Finding the object..."`, `noObjectFound = "Couldn't find an object there. Tap the middle of it."`, `tappedWall = "That looks like a wall. Tap the object instead."`, `chooseAgain = "Choose Again"`, `static func sidesProgress(_ covered: Int, of total: Int) -> String { "\(covered) of \(total) sides captured" }`, `static func boxSize(width: String, depth: String, height: String) -> String { "About \(width) by \(depth) by \(height)" }`, `a11yBox = "Outline of the selected object"`.

**Self-test.** `LargeObjectSelfTest.run()`, at least 24 checks (all on synthetic samples and poses):
1. With the first camera at +Z from the center, a point at +X has azimuth +90, one at -X has -90, one at -Z has 180.
2. `sector`: 0 -> 0, 22.4 -> 0, 22.6 -> 1, 90 -> 2, 180 -> 4, -180 -> 4, -90 -> 6.
3. `observe`: a camera 1.5 m in front looking at the center for 20 poses of 0.1 s gives viewSeconds[0] of 2.
4. Looking away, standing 5 m away, or with tracking limited adds nothing.
5. A camera 1 m above a 1 m tall box looking down adds top seconds; a 2.2 m tall box has `topRequired` false and `requiredCount` 8.
6. `updateFaces` of a 1 m cube of faces, all green: side sectors 0, 2, 4, 6 score 1; diagonal sectors have no score.
7. Inward-wound faces are turned outward (the same scores).
8. Yellow faces score 0.5 (not covered).
9. `guidance` at startup with nothing covered: `.objectMoveAround`.
10. Front covered, camera at the front, sectors 1 and 7 uncovered: `.objectCaptureRight` (tie goes right).
11. Everything but the back covered: `.objectCaptureBack`; everything but the left: `.objectCaptureLeft`.
12. All sides covered, top required and not covered: `.objectCaptureTop`.
13. All required covered: `.objectLooksComplete`.
14. Own sector uncovered with mean view distance 2.5 m: `.objectMoveCloserToArea`; at 1 m with a 0.5 score after 1.5 s: `.objectNeedsDetail`.
15. `floorHeight` from 30 floor samples at y 0 plus or minus 5 mm is 0 within 0.005; without floor samples it is the 5th percentile.
16. `grow`: a 1 m cube of samples next to a 3 m tall wall-classified column returns only cube samples.
17. `box` of that result is about 1.1 x 1.1 x 1.05 m (margins) with its bottom at the floor.
18. A seed 0.2 m from the cube snaps to it; 0.5 m away returns nothing.
19. A seed inside the wall column returns nothing.
20. `box` with fewer than 30 points is nil.
21. `anchorsOnRay` keeps an anchor across the ray and drops one beside it.
22. `pick` on a 1 m quad at z -2 hits (0, 0, -2) along -Z and nothing along +Z.
23. `LargeObjectLog` round trip through `ProjectStore.encoder` and `decoder`.
24. `defaultSettings()` has detail `.high`, distance `.normal`, findRooms false.
25. `LargeObjectTracker.apply(decision:to:)` puts the message in `extraConditions` and clears `viewCoverage` and `nearbyMissing`; a nil decision leaves `extraConditions` empty.

**Acceptance checks.** The tracker's hub callback copies only; the 1 Hz pass time is logged (target under 50 ms for 300k tracked faces); the seed and box are logged with their sizes; the box entity updates at most twice a second; the ObjectRecord and the crop edit are written only after the seal; a cancelled capture leaves no project; guidance changes are logged by `GuidanceAnnouncer` (OBJ-01 "Log").

**SPEC owned.** "OBJECT SCANNING" for large objects ("Guide the user around the object"; "Move around the object slowly", "Capture the left side", "Capture the back", "Capture the top", "Move closer to this area", "This section needs more detail"; vehicles, appliances, machines, equipment; "Attempt to separate the target object from its background" at capture: seed region and box; bounding box capture); "SCANNING MODES" OBJECT (large path); "CORE DESIGN PRINCIPLE" Representation E (capture side).

**TEST_PLAN ids.** OBJ-01 (large-object variant of the guidance steps), OBJ-04 (the detail message), OBJ-05, OBJ-07, OBJ-09, MODE-03 (Object, large), PERF-06, PERF-26 (recovery through AppShell).

### 3.40 MissingAreas (wave 5b)

**Purpose.** Show Missing Areas (SPEC SCAN QUALITY SYSTEM, D19, lead decision 4): from the quality sheet, continue on the same running `ARSession` (the room's `RoomScanEngine` has not been torn down and its `RoomCaptureView` stays mounted) in a `MeshScanEngine` patch pass on the room engine's hub (new `mesh-pass/` folder, new recorders), tour the evaluation's missing areas in walking order with an arrow toward each suggested standable viewpoint, then toward the area itself, show each area red in the live overlay, mark it filled when coverage reaches it, skip what cannot be scanned (glass and mirrors: windows, doors and openings are already excluded by Quality), and return to the quality sheet with numbers evaluated again from the room plus the pass. Offered only when `RoomScanResult.stoppedBySystem` is false and the evaluation lists missing areas.

**Build and wave.** Build 5, wave 5b. Core, CoverageLive, LiveMeshView, Quality (with CR-10), MeshModel (`MeshConsolidator`), RoomModel (`CapturedRoomStore.rawFolder`), CaptureCore, Store, ScanUI (`ScanErrorCopy`), Units, Support; RealityKit (the `ARView` type in hooks), SwiftUI. About 1000 lines plus the self-test.

**Files.** `ios/Sources/MissingAreas/MissingAreasModel.swift`, `MissingAreaTour.swift` (pure tour state machine, order, arrow, samples), `MissingAreasReevaluation.swift` (seed inputs and the evaluation after the tour), `MissingAreasHUD.swift` (screen and HUD), `MissingAreasSelfTest.swift`, `ios/Sources/Support/Copy+MissingAreas.swift`.

**Public Swift API.**
```swift
/// Everything the tour needs; built by ScanUI from the finished room.
struct MissingAreasTarget {
    var projectID: UUID
    var package: ProjectPackage
    var room: RoomRecord
    var evaluation: QualityEvaluation
    /// The room's mode and settings (the borrowed hub keeps its profile).
    var mode: ScanMode
    var settings: ScanSettings
    /// `RoomScanEngine.hub` of the finished room, still running.
    var hub: ARSessionHub
}

enum MissingAreaStopStatus: String, Equatable, Sendable { case pending, filled, unscannable, passed }
struct MissingAreaStop: Identifiable, Equatable {
    /// `MissingAreaRecord.id`.
    var id: Int
    var record: MissingAreaRecord
    var samplePoints: [SIMD3<Float>]
    var status: MissingAreaStopStatus
    var fraction: Float
    /// Seconds spent facing the area from its viewpoint without progress.
    var facingSeconds: Double
}
/// Where to point the user. Angles in radians.
struct MissingAreaArrow: Equatable, Sendable {
    /// Horizontal bearing from the camera's facing direction to the target, positive to the right (clockwise seen from above).
    var bearing: Float
    /// Elevation of the target above the camera's horizontal plane.
    var pitch: Float
    var horizontalDistance: Float
    /// Within `MissingAreaTour.arrivalRadius` of the viewpoint (the arrow then points at the area itself).
    var atViewpoint: Bool
}
enum MissingAreaDirection: Equatable, Sendable { case ahead, left, right, behind, up, down }
enum MissingAreaTourEvent: Equatable, Sendable { case filled(Int), unscannable(Int), advanced(Int), finished }

/// The tour as a value. Pure.
struct MissingAreaTour: Equatable {
    static let filledFraction: Float = 0.8
    static let sampleSpacing: Float = 0.2
    static let observedRadius: Float = 0.15
    static let arrivalRadius: Float = 0.75
    static let facingConeDegrees: Float = 35
    static let facingMaxDistance: Float = 3.5
    static let unscannableSeconds: Double = 8
    static let unscannableMaxFraction: Float = 0.3
    private(set) var stops: [MissingAreaStop]
    /// Index into `stops` of the area shown now, nil when none is pending.
    private(set) var currentIndex: Int?
    /// Orders the records by `order(_:from:)`; records with surface `.window` or `.door` are dropped (D19).
    init(records: [MissingAreaRecord], start: SIMD3<Float>)
    /// Updates fractions of every pending stop; a stop at `filledFraction` or more becomes filled (any stop,
    /// not only the current); facing time counts for the current stop only with normal tracking; the current
    /// stop becomes unscannable after `unscannableSeconds` facing it with its fraction under
    /// `unscannableMaxFraction`; a resolved current stop advances to the nearest pending stop.
    mutating func update(fractions: [Int: Float], cameraToWorld: simd_float4x4, seconds: Double,
                         trackingNormal: Bool) -> [MissingAreaTourEvent]
    /// Next Area: the current stop becomes passed; advance.
    mutating func next() -> [MissingAreaTourEvent]
    var remainingCount: Int { get }
    var isFinished: Bool { get }
    /// Greedy walking order: from `start`, repeatedly the nearest suggested viewpoint (horizontal distance).
    static func order(_ records: [MissingAreaRecord], from start: SIMD3<Float>) -> [Int]
    /// Points on a disc of radius sqrt(area / pi) (at least 0.1 m) in the area's plane, `spacing` apart, centroid included.
    static func samplePoints(for record: MissingAreaRecord, spacing: Float) -> [SIMD3<Float>]
    /// Arrow to the viewpoint, or to the centroid once within `arrivalRadius`. The facing direction is the
    /// camera's forward (-Z column) on the floor plane, or its top edge (-X column, portrait) when the
    /// forward is within 30 degrees of vertical.
    static func arrow(cameraToWorld: simd_float4x4, record: MissingAreaRecord) -> MissingAreaArrow
    /// |bearing| <= 45 degrees ahead, 45 to 135 right or left, beyond behind; at the viewpoint, pitch
    /// above 35 degrees is up and below -35 degrees is down.
    static func direction(_ arrow: MissingAreaArrow) -> MissingAreaDirection
}

enum MissingAreasPhase: Equatable { case preparing, touring, allDone, finishing, rechecking, done, cancelled, failed(String) }

@MainActor final class MissingAreasModel: ObservableObject {
    /// Tour refresh rate, Hz.
    static let refreshHz: Double = 10
    @Published private(set) var phase: MissingAreasPhase
    @Published private(set) var tour: MissingAreaTour
    @Published private(set) var arrow: MissingAreaArrow?
    /// A short line after an event ("That area is filled in"), cleared after 2 s.
    @Published private(set) var notice: String?
    @Published var showsCancelConfirmation: Bool
    @Published var alert: ScanAlert?
    let target: MissingAreasTarget
    let scan: MeshScanModel
    /// For ScanUI's CoverageOverlay: `CoverageOverlayRenderer(source: model.coverage, thermal: target.hub.thermal)`.
    let coverage: CoverageLiveRecorder
    /// The evaluation after the tour (nil until then).
    private(set) var newEvaluation: QualityEvaluation?
    /// True when a system stop ended the pass (the session is paused; ScanUI hides Show Missing Areas).
    private(set) var stoppedBySystem: Bool
    /// Called once: the new evaluation after Done, or nil after Cancel.
    var onFinished: ((QualityEvaluation?) -> Void)?
    init(target: MissingAreasTarget)
    /// The tour's guidance rule: keep tracking, speed, distance, light and heat inputs; clear
    /// `viewCoverage` and `nearbyMissing` (the arrow is the guide).
    nonisolated static func tourGuidance(_ input: inout GuidanceInput)
    /// The engine's guidance hook: `coverage.guidanceHook` then `tourGuidance`. Nonisolated, so the
    /// closure is formed outside the main actor (it runs on the hub queue).
    nonisolated static func tourGuidanceHook(coverage: CoverageLiveRecorder) -> (inout GuidanceInput) -> Void
    func start()
    func nextArea()
    /// Done: finish the pass, record it, evaluate again (below).
    func finishTour()
    func requestCancel(); func confirmCancel(); func keepScanning()
    func teardown()
}

enum MissingAreasReevaluation {
    /// Off main. Room poses, keyframes and mesh as Coverage inputs for `CoverageLiveRecorder.seed`:
    /// `QualityRoomFiles.load`, `MeshConsolidator.fastWorldMesh(MeshConsolidator.latestChunks(in: [room]))`,
    /// `QualityInputs.observations(poses:keyframes:hz: 1)`, `QualityInputs.oriented(_:toward:limit: 100_000).faces`.
    static func seedInputs(package: ProjectPackage, record: RoomRecord) -> (observations: [CoverageObservation], faces: [CoverageFace])
    /// Off main. `QualityEvaluator.evaluateSealedRoom(package:record:passes:now:)` (CR-10) with
    /// `MeshPassFolders.forRoom(record.id, in: package)`, then `QualityStore.save`.
    static func run(package: ProjectPackage, record: RoomRecord, now: Date) throws -> QualityEvaluation
}

/// `LiveMeshScreen(model: model.scan, onViewReady: onViewReady) { MissingAreasHUD(model: model) }`.
struct MissingAreasScreen: View { init(model: MissingAreasModel, onViewReady: (@MainActor (ARView) -> Void)? = nil) }
/// Arrow (rotated by `bearing`, or up and down at the viewpoint), step line, hint, distance, notice,
/// Next Area, Done (`LiveMeshTopBar`), the all-done line, cancel confirmation, VoiceOver direction
/// announcements at most every 3 s.
struct MissingAreasHUD: View { init(model: MissingAreasModel) }
```

Flow:
1. `init` (main): `let mesh = MeshStore()`, coverage = `CoverageLiveRecorder(meshSource: mesh)` (it must read the pass's own mesh store), recorders `MeshScanRecorderSet(photos: false, mesh: mesh, extra: [coverage]).all`; `MeshScanEngine(target: .patchPass(projectID:package:sessionID: room.sessionID, roomID: room.id, mode:settings:), recorders:, hub: target.hub)`; `engine.guidanceAugmenter = MissingAreasModel.tourGuidanceHook(coverage: coverage)` (tier 1 safety messages stay), `engine.snapshotAugmenter = coverage.snapshotHook`. `start()`: `coverage.setWatchedAreas` with every stop's sample points (they read red); `scan.start()`; in a detached task `seedInputs` then `coverage.seed(observations:faces:deadlineSeconds: 2)` (best effort, logged) so the areas scanned in the room pass read green or yellow; phase `.touring` with the tour built from `latestCameraTransform` (else the first viewpoint).
2. Refresh loop (main, `refreshHz`): `tour.update(fractions: coverage.watchedFractions(), cameraToWorld: scan.engine.latestCameraTransform, seconds:, trackingNormal: scan.snapshot.tracking == .normal)`; events: filled gives `Haptics.success()` and `Copy.Quality.missingAreaDone`; unscannable gives `Copy.MissingAreas.cantScan`; finished gives phase `.allDone` and `Copy.Quality.allAreasDone`; the arrow is recomputed every tick.
3. Done (`finishTour()`): `scan.finish()`; on `onFinished(result)`: `ProjectLibrary.shared.update(projectID)` sets the room's `hasMeshPass = true`; phase `.rechecking`; `MissingAreasReevaluation.run` in a detached task; `newEvaluation`; `scan.teardown()` (the borrowed hub goes back to the room engine, still running unless a system stop paused it); phase `.done`; `onFinished(newEvaluation)`. A failed evaluation logs and returns the old evaluation (the pass stays sealed and the pipeline scores it later).
4. Cancel after `Copy.MissingAreas.cancelTitle` and `cancelBody`: `scan.discard()`; on idle, `scan.teardown()`; phase `.cancelled`; `onFinished(nil)`.
5. A system stop seals the pass as usual, then `stoppedBySystem = true`, the `ScanErrorCopy` alert, then step 3's recording and evaluation.

**Uses.** CoverageLive: `CoverageLiveRecorder` (`setWatchedAreas(_:)`, `watchedFractions()`, `seed(observations:faces:deadlineSeconds:)`, `augment`). LiveMeshView: `MeshScanEngine` (borrowed hub, `latestCameraTransform`, augmenters), `MeshScanTarget.patchPass(...)`, `MeshScanRecorderSet`, `MeshScanModel`, `MeshPassFolders.forRoom(_:in:)`, `LiveMeshScreen`, `LiveMeshTopBar`. Quality: `QualityEvaluation`, `MissingAreaRecord` (`surfaceClass`), `QualityStore.save(_:package:)`, `QualityEvaluator.evaluateSealedRoom(package:record:passes:now:)` (CR-10), `QualityRoomFiles.load(_:roomID:)`, `QualityInputs` (`observations(poses:keyframes:hz:)`, `viewpoints(_:)`, `oriented(_:toward:limit:)`). MeshModel: `MeshConsolidator.fastWorldMesh(_:)`, `latestChunks(in:)`. RoomModel: `CapturedRoomStore.rawFolder(_:room:)`. CaptureCore: `ARSessionHub` (`thermal`). Coverage: `CoverageObservation`, `CoverageFace`, `SurfaceClass`. Store: `ProjectLibrary.update(_:_:)`. ScanUI: `ScanErrorCopy.alert(for:)`, `ScanAlert`. Units: `LengthFormat.display(_:prefs:)`, `UnitPreferences.load(from:)`. Core: `RoomRecord` (`hasMeshPass`, `sessionID`), `ProjectPackage`, `ScanMode`, `ScanSettings`, `Vec3`. Support: `Copy.Quality` (`showMissingAreas`, `missingAreaHint`, `missingAreaDone`, `nextMissingArea`, `allAreasDone`, `missingAreaStep(_:of:)`), `Copy.Scanning` (`done`, `cancel`, `cancelConfirmKeep`), `GuidanceKind.scanCeiling` and `.pointAtFloor` messages (reused as the up and down hints), `Haptics.success()`, `LogStore`.

**Apple APIs.** None directly beyond the `ARView` type in the view hook and SwiftUI: `Image(systemName:)` with `.rotationEffect(_:)` for the arrow, `.confirmationDialog` (not in RESEARCH, iOS 13 to 15), `UIAccessibility.post(notification: .announcement, argument:)` (not in RESEARCH, iOS 3, main), `Task.sleep(nanoseconds:)` (iOS 13).

**Must NOT do.** Never create a second ARSession, never pause the room's session (only a system stop does, inside LiveMeshView), never tear the room engine down or let its `RoomCaptureView` be dismantled (ScanUI keeps it mounted). Never count windows, doors, openings or mirrors as missing (D19; mirrors and glass end as unscannable, never as a nag). Never write into the room's sealed folder (the pass has its own). Never block main with the seed or the evaluation. Never present the quality sheet itself (ScanUI does). No hardcoded text; distances through Units.

**Copy strings.** Existing: `Copy.Quality.showMissingAreas`, `missingAreaHint`, `missingAreaDone`, `nextMissingArea`, `allAreasDone`, `missingAreaStep(_:of:)`; `Copy.Scanning.done`, `cancel`, `cancelConfirmKeep`, `startingUp`; guidance texts of `.scanCeiling` and `.pointAtFloor`. New (`extension Copy { enum MissingAreas }` in `Copy+MissingAreas.swift`): `cantScan = "This spot can't be scanned. It may be glass or a mirror."`, `rechecking = "Checking your scan again..."`, `static func distanceAway(_ distance: String) -> String { "\(distance) away" }`, `cancelTitle = "Stop filling in missing areas?"`, `cancelBody = "What you scanned in this pass will be lost. Your room scan is kept."`, `cancelDiscardPass = "Discard This Pass"`, `a11yAhead = "Missing area ahead"`, `a11yLeft = "Missing area to your left"`, `a11yRight = "Missing area to your right"`, `a11yBehind = "Missing area behind you"`, `a11yUp = "Missing area above you"`, `a11yDown = "Missing area below you"`.

**Self-test.** `MissingAreasSelfTest.run()`, at least 20 checks:
1. `order` of viewpoints at x = 1, 5 and 3 from the origin is 1, 3, 5 (by record index).
2. `init` drops `.window` and `.door` records and keeps wall, floor and ceiling ones.
3. `samplePoints` of a 0.5 m^2 wall area lie in its plane (within 1e-5) and within radius 0.4; the centroid is included; a 0.01 m^2 area still has at least 1 point.
4. `arrow` with the identity camera (facing -Z) at the origin: target (0, 0, -2) bearing 0 and `direction` ahead; (2, 0, 0) bearing +pi / 2, right; (-2, 0, 0) left; (0, 0, 2) behind.
5. A ceiling area straight above the viewpoint while standing there: `atViewpoint` true, pitch above 35 degrees, `direction` up; a floor area: down.
6. A camera looking straight down still gets a bearing from its top edge.
7. `update` with fraction 0.79 keeps a stop pending; 0.8 fills it and emits `.filled`.
8. Filling the current stop advances to the nearest pending one (`.advanced`).
9. Filling a non-current stop marks it filled without moving the current one.
10. `next()` marks the current stop passed and advances.
11. Facing the current area from its viewpoint for 8 s at fraction 0.2 makes it unscannable; at 0.35 it does not.
12. Facing time does not grow with tracking limited or when standing 1.5 m from the viewpoint.
13. The tour is finished when every stop is filled, unscannable or passed; `remainingCount` counts pending ones.
14. An empty record list is finished at once.
15. `direction` boundaries: bearing 44 degrees ahead, 46 degrees right, 136 degrees behind.
16. `MissingAreasReevaluation.run` in a temporary package with a sealed room fixture and a sealed pass (scan.json roomID set) finds the pass and writes quality.json whose input hash differs from the room-only Done hash.
17. The same with no pass gives the room-only hash.
18. `seedInputs` of the fixture returns observations at 1 Hz and at most 100,000 faces.
19. `Copy.MissingAreas.distanceAway(LengthFormat.display(1.5, prefs:))` contains the formatted length.
20. `MissingAreasModel.tourGuidance(_:)` clears `viewCoverage` and `nearbyMissing` and keeps tracking and speed inputs.

**Acceptance checks.** The patch pass shares the room's session (log: "hub lent" and "hub returned", the same session identity, one "hub deinit" only when the flow ends); nothing is written into the room folder; the pass folder is sealed before the manifest update and the evaluation; the missing area count over time is logged (QUAL-03 "Log"); the arrow updates at 10 Hz without main-thread work above 2 ms per tick; the room's `RoomCaptureView` is never recreated.

**SPEC owned.** "SCAN QUALITY SYSTEM" ("Selecting SHOW MISSING AREAS should guide the user directly to locations requiring additional scanning"; the quality numbers after the extra pass); "LIVE SCANNING EXPERIENCE" (RED shown where information is missing during the tour).

**TEST_PLAN ids.** QUAL-01 (the button), QUAL-02 (step 2 through Show Missing Areas), QUAL-03, QUAL-04, LIVE-09, ROOM-06 (mirror areas end as unscannable), ROOM-07 (glass), smoke list #4.

### 3.41 HouseUI (wave 5b)

**Purpose.** The House / Building flow for an amateur, room by room (ARCHITECTURE 4.3, D9, D17): preflight, permission and tips; one `RoomScanEngine` (one `RoomCaptureView`, one `ARSession`) per visit with `startNextRoom(roomID:)` between rooms; the quality sheet after each room (QualityUI) over the live camera; naming each room with suggestions (the detected section label first); the room list with status ("Kitchen done", "Hallway needs additional scan", "Office needs lining up") grouped by floor; Scan Next Room, Rescan (the new capture supersedes the old one, CR-7), Add Floor, Finish Building; returning another day with world map relocalization (a new session that relocalizes against the latest saved room map with Apple's coaching overlay; "Start Fresh Here" after 30 s gives an unaligned session); per-room memory eviction and the "finish this floor" suggestion under 800 MB; the project room screen reached from Results (status, Continue Scanning, Rescan, Line Up by Hand, Join Rooms Again); the manual alignment screen (drag, turn, parallel-wall, wall-gap and doorway snapping from Structure) stored as `setRoomAlignment` edits; Demo Mode with synthetic rooms. The merge and alignment themselves are Structure's steps, run by the pipeline after Finish Building.

**Build and wave.** Build 5, wave 5b. Core (CR-7), Store, Structure, RoomCapture (with 3.30c), CaptureCore (with 3.30b), MeshRecord, Keyframes, Quality, QualityUI, ScanUI, GuidanceUI, RoomModel, FloorPlan, Pipeline (`IdleTimerGuard`), Support; SwiftUI, AVFoundation, ARKit, RealityKit (the relocalization `ARView` only). About 1450 lines excluding the self-test; if it grows past 1500, `HouseAlignRooms.swift` is split, never moved to another module.

**Files.** `ios/Sources/HouseUI/HouseFlowModel.swift`, `HouseFlowModel+Rooms.swift` (room finish, quality, naming, next room, rescan, floors), `HouseFlowModel+Session.swift` (sessions, relocalization, start fresh, teardown), `HouseScanScreen.swift`, `HouseRoomList.swift` (`HouseRoomListView`, `HouseProjectScreen`), `HouseRelocalization.swift` (`HouseRelocalization`, `HouseRelocalizationView`), `HouseAlignRooms.swift` (`AlignRoomsModel`, `AlignRoomsScreen`), `HousePresentation.swift` (pure rules, `HouseManifestRules`, `HouseAlert`), `HouseDemo.swift`, `HouseUISelfTest.swift`, `ios/Sources/Support/Copy+HouseUI.swift`.

**Public Swift API.**
```swift
/// How a house flow starts (AppShell 5d presents the flow as a full-screen cover).
enum HouseScanStart: Equatable, Sendable {
    /// New Scan > House / Building: creates the project; the first session is the project frame.
    case newProject
    /// Continue Scanning on an existing house: a new session that relocalizes first.
    case continueProject(UUID)
    /// Rescan one room of an existing house: a new session that relocalizes (preferring that
    /// room's own map); the new capture supersedes the room when the user keeps it.
    case rescan(project: UUID, room: UUID)
}
struct HouseScanRequest: Identifiable, Equatable, Sendable { var id: UUID; var start: HouseScanStart; var isDemo: Bool }

enum HouseFlowPhase: Equatable {
    case preflight, permission, tips, relocalizing, capturing, stopping, checking, quality, naming, roomList, finishing
    case done(UUID), failed(String), cancelled
}
enum HouseFlowSignal: Equatable, Sendable {
    case preflightPassed(showTips: Bool, relocalize: Bool), preflightBlocked, permissionNeeded
    case permissionGranted(showTips: Bool, relocalize: Bool), permissionDenied, tipsDone(relocalize: Bool)
    case relocalized, startedFresh, doneTapped, engineStopping, roomFinished, evaluated, finishTapped
    case roomDiscarded(hasRooms: Bool), named, nextRoom(relocalize: Bool), finishBuilding, finished(UUID)
    case cancelConfirmed(hasRooms: Bool), failed(String)
}

/// Room list row (pure presentation, `HousePresentation.rows`).
enum HouseRoomStatus: Equatable, Sendable { case done, needsScan, needsLineUp, notProcessed }
struct HouseRoomRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String            // user name, else "Room n" (Copy.FloorPlan.defaultRoomTitle)
    var statusText: String       // Copy.House.roomDone / roomNeedsScan, Copy.HouseUI.roomNeedsLineUp
    var status: HouseRoomStatus
    var floorIndex: Int
    var floorTitle: String       // FloorRecord.name, else Copy.House.floorLabel(index + 1)
    var accessibility: String    // Copy.A11y.roomDone / roomNeedsScan
}

/// Alerts of the house flow (ScanUI's `ScanAlertAction` has no house actions).
enum HouseAlertAction: Equatable, Sendable {
    case ok, openSettings, resume, finishNow, startFresh, keepLooking, lineUp(UUID), rescan(UUID), joinAgain, cancel
}
struct HouseAlert: Identifiable, Equatable {
    var id: String; var title: String; var body: String; var actions: [HouseAlertAction]
    /// ScanUI's `ScanErrorCopy.alert(for:)` text with its actions mapped one to one.
    static func from(_ alert: ScanAlert) -> HouseAlert
}

/// Naming prompt after a room is kept.
struct HouseNamingRequest: Identifiable, Equatable { var id: UUID; var suggestions: [String]; var current: String }

@MainActor final class HouseFlowModel: ObservableObject {
    @Published private(set) var phase: HouseFlowPhase
    @Published private(set) var snapshot: LiveScanSnapshot
    @Published private(set) var evaluation: QualityEvaluation?
    @Published private(set) var rows: [HouseRoomRow]
    @Published private(set) var progressText: String          // Copy.House.progressSummary(done:total:)
    @Published private(set) var currentFloor: Int
    @Published private(set) var relocalizationElapsed: Double  // seconds, for the Start Fresh Here offer
    @Published private(set) var showsStartFresh: Bool          // true after HouseRelocalization.timeoutSeconds
    @Published private(set) var lowMemory: Bool                // under 800 MB after a room (D17)
    @Published private(set) var isPaused: Bool
    /// True from the Show Missing Areas tap until `refreshEvaluation(_:stoppedBySystem:)`: the quality
    /// sheet is not presented while AppShell's missing-areas tour runs over this screen (3.43e).
    @Published private(set) var isTourActive: Bool
    @Published var alert: HouseAlert?
    @Published var showsCancelConfirmation: Bool
    @Published var naming: HouseNamingRequest?
    let request: HouseScanRequest
    let announcer: GuidanceAnnouncer
    private(set) var projectID: UUID?
    /// The visit's engine (nil in Demo Mode); HouseScanScreen hosts its view. AppShell's
    /// missing-areas tour (5d) uses it and `lastResult`.
    private(set) var roomEngine: RoomScanEngine?
    private(set) var lastResult: RoomScanResult?
    /// Main. Called once when the visit ends with at least one room (Finish Building, or the
    /// flow closing after a system stop); AppShell enqueues the House plan and opens Results.
    var onComplete: ((UUID) -> Void)?
    /// Main. Called when the flow ends without a room (the new project was deleted).
    var onDismiss: (() -> Void)?
    /// AppShell (5d) wires MissingAreas here. The quality sheet offers Show Missing Areas only when
    /// this is set and `canShowMissingAreas`; the tap sets `isTourActive`, then calls it.
    var onShowMissingAreas: (() -> Void)?
    /// Optional capture add-ons, called once per engine with its MeshStore before the engine
    /// exists: extra recorders plus a hook installer (AppShell 5d wires CoverageLive here the
    /// same way the ScanUI 5c revision does for rooms). Nil in build 5b.
    var captureExtras: ((MeshStore) -> (recorders: [ScanRecorder], install: (RoomScanEngine) -> Void))?
    /// `HousePresentation.canOfferMissingAreas` for the room on the quality sheet (not Demo Mode, the
    /// engine `.finished`, no system stop of the room or of an earlier tour of it, at least one
    /// missing area).
    var canShowMissingAreas: Bool { get }
    init(request: HouseScanRequest)
    func begin()                                   // preflight, permission, tips, then capture or relocalization
    func permissionContinue() async                // AVCaptureDevice.requestAccess(for: .video)
    func tipsFinished(dontShowAgain: Bool)
    func done(); func resume(); func finishNow()   // as ScanFlowModel
    func takePhoto()
    func finishRoom()                              // quality sheet Finish or Finish Anyway
    func discardRoom()                             // quality sheet Discard, after confirmation
    func name(_ text: String)                      // naming sheet Save (empty keeps the default title)
    func skipNaming()
    func scanNextRoom()
    func rescan(_ roomID: UUID)                    // in-visit Rescan from the room list
    func addFloor()
    func finishBuilding()
    func keepLooking()                             // relocalization: restart the 30 s timer
    func startFresh()                              // relocalization gave up: unaligned session
    func requestCancel(); func confirmCancel(); func keepScanning()
    func openSettings()
    /// AppShell calls this when the missing-areas tour ends: a nil evaluation (tour cancelled, or the
    /// evaluation failed) keeps the current one; `stoppedBySystem` (the tour's
    /// `MissingAreasModel.stoppedBySystem`) hides Show Missing Areas for the rest of this room; a
    /// non-nil evaluation also re-applies `HouseManifestRules.status(after:)` to the room's record
    /// (a room the tour fixed leaves `.needsRescan`); clears `isTourActive`, so the quality sheet
    /// shows again with the numbers.
    func refreshEvaluation(_ evaluation: QualityEvaluation?, stoppedBySystem: Bool)
    /// Pure phase reducer used by the model and the self-test.
    nonisolated static func nextPhase(_ phase: HouseFlowPhase, on signal: HouseFlowSignal) -> HouseFlowPhase
}

/// Camera (relocalization view, then `RoomCaptureContainer` mounted once for the rest of the
/// visit, or the demo placeholder). The container carries `.id(ObjectIdentifier(engine))`: its
/// coordinator is the engine it was made with and `updateUIView` ignores a new one, so a new
/// engine (a new session after a system stop, or Start Fresh Here after `sceneTooLarge`) must get
/// a new container, never the old view. Chrome (Cancel, room title and floor, timer, counts, Take
/// Photo, Done, paused overlay with Resume and Finish Now), guidance banner, and the sheets:
/// quality (`QualitySheet`, detents medium and large, not dismissable, not presented while
/// `isTourActive`), naming, room list.
/// Forced dark, `.persistentSystemOverlays(.hidden)`, holds an `IdleTimerGuard` token while visible.
struct HouseScanScreen: View { init(model: HouseFlowModel) }
/// The in-visit room list sheet: floor sections, rows, low-memory banner, Scan Next Room,
/// Add Floor, Finish Building; tapping a "needs additional scan" row offers Rescan.
struct HouseRoomListView: View { init(model: HouseFlowModel) }
/// The room screen of an existing house (Results 5c opens it): rows with the Structure report,
/// Continue Scanning, per-row Rescan and Line Up by Hand, Join Rooms Again after a crashed
/// merge, and the "These rooms didn't line up" alert once per report.
struct HouseProjectScreen: View {
    init(projectID: UUID, onContinueScanning: @escaping () -> Void, onRescan: @escaping (UUID) -> Void,
         onLineUp: @escaping (UUID) -> Void, onJoinAgain: @escaping () -> Void)
}

// MARK: Relocalization (HouseRelocalization.swift)

enum HouseRelocalizationDecision: Equatable, Sendable { case keepWaiting, relocalized, timedOut }
enum HouseRelocalization {
    static let timeoutSeconds: Double = 30
    /// Tracking must stay `.normal` this long before the session counts as relocalized.
    static let normalHoldSeconds: Double = 1
    /// Pure: relocalized when tracking has been `.normal` since `normalSince` for at least
    /// `normalHoldSeconds`; timedOut at `timeoutSeconds` without that; else keepWaiting.
    nonisolated static func decide(elapsed: Double, tracking: TrackingSummary, normalSince: Double?) -> HouseRelocalizationDecision
    /// The map to relocalize against: for a rescan the room's own `worldmap.arworldmap` when it
    /// exists and the room is in the anchor frame group (Structure `StructureEligibility`), else
    /// the most recently captured active anchor-group room with a map. Nil when there is none
    /// (the flow then goes straight to Start Fresh Here with `Copy.HouseUI.noMapTitle`).
    static func sourceMap(manifest: ProjectManifest, package: ProjectPackage, preferRoom: UUID?) -> (session: UUID, room: UUID, url: URL)?
    /// `CaptureSessionRef.worldMapFile` text for a room's map: "rooms/<id>/worldmap.arworldmap"
    /// (relative to the session folder; readers resolve it with `RawScanFolder.resolve`).
    static func worldMapPath(room: UUID) -> String
    /// Tracking read on the hub queue (`hub.tracking.summary` is hub-queue only).
    static func trackingSummary(of hub: ARSessionHub) async -> TrackingSummary
}
/// UIViewRepresentable: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`,
/// `arView.session = hub.session`, then `hub.install()` at once (whoever assigns the delegate last
/// wins), plus an `ARCoachingOverlayView` with goal `.tracking` on the same session. Dismantling
/// gives the ARView a fresh idle `ARSession()` before it goes away, then calls `hub.install()`
/// again, so the hub's session is never paused by the view.
struct HouseRelocalizationView: UIViewRepresentable { init(hub: ARSessionHub) }

// MARK: Manual alignment (HouseAlignRooms.swift)

/// Main actor. Works in the structure frame on the edited clean model.
@MainActor final class AlignRoomsModel: ObservableObject {
    @Published private(set) var others: [AlignShape]
    @Published private(set) var moving: AlignShape?
    @Published private(set) var placement: AlignPlacement?
    @Published private(set) var snapText: String?           // Copy.HouseUI.snappedDoorway / snappedWall
    @Published private(set) var isReady: Bool               // false until clean.json holds the room
    init(projectID: UUID, roomID: UUID)
    func load() async                                        // CleanModelStore.loadEdited off main
    func drag(by planDelta: SIMD2<Float>)                    // accumulates, re-snaps with StructureSnapping.snap
    func rotate(by radians: Float)
    func turn(clockwise: Bool)                               // 90 degree steps (VoiceOver and buttons)
    /// Appends one log entry: the `setRoomAlignment` edit (source `.user`,
    /// `StructureAlignment.compose(delta, after: effective record)`) of every room of the moved
    /// room's frame group, as one `.batch(operations:)` when the group has more than one room
    /// (CR-1: one Undo reverts the whole move).
    func save() throws
}
/// Canvas of all room outlines, walls and doors through FloorPlan's `PlanViewport`; the moving
/// room highlighted; DragGesture moves it, RotateGesture turns it about its centroid,
/// MagnifyGesture zooms the view; Turn Left and Turn Right buttons; Cancel and Save.
struct AlignRoomsScreen: View { init(projectID: UUID, roomID: UUID, onDone: @escaping (_ saved: Bool) -> Void) }

// MARK: Pure rules (HousePresentation.swift, HouseDemo.swift)

enum HousePresentation {
    /// D17: suggest finishing the floor below this much available memory after a room.
    static let lowMemoryBytes: UInt64 = 800_000_000
    /// Active rooms only (Structure `activeRooms`), floor then capture order.
    static func rows(manifest: ProjectManifest, report: StructureReport, userAligned: Set<UUID>) -> [HouseRoomRow]
    /// `.needsScan` for `.needsRescan` or `.failed`; `.needsLineUp` when the placement report
    /// asks for manual alignment and the room has no user alignment; `.notProcessed` while the
    /// room is `.capturing`; else `.done`.
    static func status(for record: RoomRecord, placement: RoomPlacementReport?, userAligned: Bool) -> HouseRoomStatus
    static func progressText(_ rows: [HouseRoomRow]) -> String
    static func suggestsFinishFloor(availableMemory: UInt64) -> Bool
    /// The Show Missing Areas rule (D19), the same as ScanUI's `ScanCoverageRules.canOfferMissingAreas`
    /// (3.43a, wave 5c, which HouseUI cannot import): false in Demo Mode, when `engineState` is not
    /// `.finished`, after a system stop, or with no missing area.
    static func canOfferMissingAreas(isDemo: Bool, engineState: ScanEngineState?, stoppedBySystem: Bool,
                                     missingAreas: Int) -> Bool
    /// The error a blocking ScanUI preflight issue shows through `ScanErrorCopy.alert(for:)`:
    /// cameraDenied -> `.cameraDenied`, noLidar -> `.unsupportedDevice`, lowStorage(free) ->
    /// `.lowStorage(freeBytes: free)`; nil for cameraUndetermined (the permission phase answers
    /// it) and for warnings.
    static func preflightError(_ issue: PreflightIssue) -> MapperError?
    /// The detected section name first (FloorPlan `RoomTitles.sectionName`), then
    /// `Copy.House.roomSuggestions` without duplicates.
    static func suggestedNames(sectionLabel: String?) -> [String]
}

enum HouseManifestRules {
    static func session(id: UUID, startedAt: Date, link: FrameLink) -> CaptureSessionRef
    /// The record for a finished room (status `.captured`, the session's frame link, never the
    /// engine's; name empty until named).
    static func roomRecord(_ result: RoomScanResult, sessionLink: FrameLink, floorIndex: Int) -> RoomRecord
    /// Appends the record and sets the project status `.needsProcessing` in the same update.
    static func append(_ record: RoomRecord, to manifest: inout ProjectManifest)
    /// Poor verdict (QualityVerdict.poor) gives `.needsRescan`, else `.captured`.
    static func status(after evaluation: QualityEvaluation) -> RoomStatus
    /// Sets `old.supersededBy = new` (CR-7) and copies the old name and floor when the new
    /// record has none.
    static func supersede(_ old: UUID, by new: UUID, in manifest: inout ProjectManifest)
    static func setWorldMap(session: UUID, room: UUID, in manifest: inout ProjectManifest)
    /// Appends `FloorRecord(id: max + 1, name: "", elevation: 0)` and returns its id.
    static func addFloor(to manifest: inout ProjectManifest) -> Int
}

enum HouseDemo {
    static let sharedWallGap: Float = 0.12
    /// Translation that places `room` to the +x side of `placed` with a 0.12 m wall gap.
    static func offset(for room: CleanRoom, after placed: [CleanRoom]) -> RoomAlignmentRecord
    /// Writes the demo house: `CleanModel` of the moved demo rooms with Structure's
    /// `sharedWalls` and `applyThickness` applied, `CleanModelStore.save`, then
    /// `PlanBuilder.build(from:floors:)` and `PlanModelStore.save`.
    static func write(_ rooms: [CleanRoom], manifest: ProjectManifest, package: ProjectPackage) throws
}
```

**Rules.**

*Starting.* `begin` runs ScanUI's `ScanPreflight.run(mode: .house, isDemo:)` (async, main actor) in a `Task`; a blocking issue shows `HouseAlert.from(ScanErrorCopy.alert(for: HousePresentation.preflightError(issue)))` then `onDismiss`, or the permission phase, exactly as ScanUI does (camera undetermined: a screen with `Copy.Permissions.cameraTitle`, `cameraBody`, `cameraContinue`; denied: Open Settings). Tips use ScanUI's `ScanTipsSheet(mode: .house, onStart:)` when `SettingsKey.tipsSeen(.house)` is unset (the merged sheet shows `Copy.Onboarding.house` for `.house`). `.newProject`: `ProjectLibrary.shared.create(kind: .house, name: ScanFlowModel.defaultProjectName(mode: .house, now: Date()))`, `keepAllPhotos` from `SettingsKey.keepScanPhotos`, and the first `CaptureSessionRef` with `.projectFrame(sessionID:)`, all before the engine starts. Recorders per engine: `MeshStore()`, `KeyframeRecorder()`, `PoseTrackRecorder()`, `PhotoRecorder()` plus `captureExtras`; `RoomScanEngine(target:recorders:)` with `RoomScanTarget(mode: .house)`. ScanUI's `extension KeyframeRecorder: PausableScanRecorder {}` already covers pausing (never declared again here). Processing is suspended by AppShell while the cover is up (3.29).

*Relocalizing* (`.continueProject`, `.rescan`, and Scan Next Room after a system stop). `HouseRelocalization.sourceMap`; the map file is read off main (`Data`), unarchived on main with `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)`; a new engine for a new session id; `hub.install()`, `hub.run(options: [.resetTracking, .removeExistingAnchors], initialWorldMap: map)` (3.30b); `HouseRelocalizationView(hub:)` with `Copy.HouseUI.relocalizeTitle` and `relocalizeBody`; every 0.5 s `trackingSummary(of:)` feeds `decide`. Relocalized: the session ref is appended with `.relocalized(sessionID: new, from: sourceSession)`, the relocalization view is replaced by `RoomCaptureContainer(engine:)` (its `makeCaptureView` keeps the running session, 3.30c) and `engine.start()` runs. At 30 s `showsStartFresh` offers Start Fresh Here and Keep Looking; Start Fresh Here re-runs the hub with `hub.run(options: [.resetTracking, .removeExistingAnchors])`, appends the ref with `.unaligned`, and continues (these rooms are parked until lined up). A `.failed(.sceneTooLarge)` within 15 s of starting a relocalized room shows `Copy.HouseUI.relocalizeLost` with Start Fresh Here (RESEARCH 3.2 disputed 7); the tiny room stays with status `.needsRescan`. Start Fresh Here in that case tears the engine down and starts a new engine on a new session appended with `.unaligned` (reset run options are never passed to a session RoomPlan has run on).

*Each room.* `.snapshot` events drive the chrome and `announcer.present`; `done` and `finishNow` call `engine.finish()`. On `.roomFinished` one `ProjectLibrary.update` appends `HouseManifestRules.roomRecord` (floor `currentFloor`) and sets `.needsProcessing`, and `setWorldMap` when the sealed folder holds `worldmap.arworldmap`; then `MeshStore.evict()` (D17) and a log line with `MemoryProbe.availableBytes()`; `lowMemory` from `suggestsFinishFloor`. Checking runs `QualityEvaluator.evaluateSealedRoom(package:record:now:)` in `Task.detached`, `QualityStore.save`, then the room status from `HouseManifestRules.status(after:)`, and the quality sheet (Show Missing Areas only when `onShowMissingAreas` is set and `canShowMissingAreas`; the tap sets `isTourActive` and calls `onShowMissingAreas`; the sheet returns after `refreshEvaluation(_:stoppedBySystem:)`). Finish keeps the room (a pending rescan now calls `supersede`), then naming: suggestions from `CapturedRoomStore.loadInput` and `CleanModelBuilder.sectionLabel(_:polygon:)` loaded off main; Save writes `RoomRecord.name`. Discard calls `ProjectLibrary.discardRoom(_:in:)` (the only raw removal; a first room discarded deletes the project and ends with `onDismiss`); its confirmation (`Copy.Scanning.cancelConfirm*`) is attached inside the quality sheet's content, because an alert attached to the screen under a presented sheet never appears (the build 4 AppShell rule). A room whose log says `.meshStripped` gets no D16 detail pass in build 5: it is logged, Raw Scan and Realistic show their honest fallback for that room, and Show Missing Areas still adds mesh passes; the House detail pass is scheduled in 3.49 (build 6). The room list follows. Scan Next Room calls `startNextRoom(roomID:)` on the same engine; after a system stop (`stoppedBySystem`), it tears the engine down and relocalizes a new session instead (the paused session's frame is not trusted). Add Floor appends a `FloorRecord` and switches `currentFloor`. Finish Building tears the engine down, sets `.finishing`, and calls `onComplete(projectID)` (the pipeline runs merge, alignment and the House clean model; Results shows `Copy.House.aligning` while those steps run, 5c). Cancel during a room uses `engine.discard()` (only that room's InProgress data) and returns to the room list, or ends the flow and deletes the project when it has no room. Every terminal phase calls `engine.teardown()`, which is idempotent.

*Alignment screen.* Opened from `HouseProjectScreen` (Line Up by Hand) only when `clean.json` holds the room (`isReady`), else `Copy.HouseUI.alignNotReady`. Shapes are `AlignShape.from` of the edited clean model's rooms on the moving room's floor; gestures accumulate a raw rotation and translation that `StructureSnapping.snap` turns into the placement shown; a snap fires `Haptics.selection()` once and shows its text. Save appends one entry through `EditStore.append(_:to:)` holding the edit of every room of the moving room's frame group (`StructureEligibility.frameGroups`; a `.batch` for more than one room), shows `Copy.House.alignDone`, and `onDone(true)`; AppShell then re-enqueues processing (the House clean model's hash includes the alignment digest, 3.30). Undo is the general edit undo of Results (PlanEditor, 5c).

*Project screen.* Rows from `HousePresentation.rows(manifest:report: StructureStore.loadReport(package), userAligned:)`, where `userAligned` is the key set of `StructureStore.userAlignments(EditStore.load(package))`. When any row needs lining up, the alert `Copy.House.alignFailedTitle`, `alignFailedBody` with `.lineUp(room)` (`Copy.House.alignManual`) and `.rescan(room)` (`Copy.House.alignRescanDoorway`) shows once per placements `inputHash`; `report.hasCrashedAttempt` or merge outcome `crashedBefore` shows `Copy.HouseUI.mergeFailedTitle` and `mergeFailedBody` with Join Rooms Again, which calls `StructureStore.clearCrashedAttempt` then `onJoinAgain`.

*Demo Mode* (`request.isDemo`): no camera, ARKit or LiDAR; each room is a `FakeScanEngine(roomID:)`; on `.roomFinished` ScanUI's `DemoProjectFactory.makeDemoRoom(package:sessionID:roomID:now:)` writes the room and returns its record and evaluation (the quality sheet shows it); the demo clean room is read back with `CleanModelStore.loadBase`, moved with `StructureAlignment.apply(HouseDemo.offset(...))`, and `HouseDemo.write` rewrites the combined clean.json and plan.json; the project ends `.ready` and is never enqueued.

**Uses.** RoomCapture: `RoomScanEngine` (`init(target:recorders:)`, `makeCaptureView`, `start`, `finish`, `pause`, `resume`, `discard`, `teardown`, `startNextRoom(roomID:)`, `lastResult`, `hub`), `RoomScanTarget`, `RoomScanResult`, `RoomCaptureContainer`. CaptureCore: `ARSessionHub` (`install`, `run(options:)`, `run(options:initialWorldMap:)` 3.30b, `queue`, `tracking.summary`, `isRunning`), `ScanRecorder`, `MemoryProbe.availableBytes()`. MeshRecord: `MeshStore` (`evict`). Keyframes: `KeyframeRecorder`, `PoseTrackRecorder`, `PhotoRecorder` (`requestPhoto(note:)`, `onPhotoSaved`). Quality: `QualityEvaluator.evaluateSealedRoom(package:record:now:)`, `QualityStore.save`, `QualityEvaluation`. QualityUI: `QualitySheet(evaluation:onFinish:onDiscard:onShowMissingAreas:)`. ScanUI: `ScanPreflight.run(mode:isDemo:)`, `ScanFlowModel.defaultProjectName(mode:now:)`, `PreflightReport`, `PreflightIssue`, `CameraPermission`, `ScanErrorCopy.alert(for:)`, `ScanAlert`, `ScanAlertAction`, `ScanTipsSheet(mode:onStart:)`, `DemoProjectFactory.makeDemoRoom`, `SettingsKey.demoMode`, `keepScanPhotos`, `tipsSeen(_:)`, `Copy.ScanUI` (`elapsed(minutes:seconds:)`, `counts(walls:doors:windows:)`, `finishNow`, `pausedFinishPrompt`, `timeHint`, `timeLimitTitle`, `timeLimitBody`, `demoBanner`). Structure: `StructureEligibility`, `StructureAlignment` (`apply`, `compose`, `identity`), `StructureSnapping`, `AlignShape`, `AlignPlacement`, `AlignSnapKind`, `StructureStore` (`loadReport`, `userAlignments`, `effectiveAlignments`, `clearCrashedAttempt`), `StructureReport`, `RoomPlacementReport`, `StructureWalls` (demo). GuidanceUI: `GuidanceBanner`, `GuidanceAnnouncer`. RoomModel: `CapturedRoomStore` (`loadInput`, `rawFolder`), `CleanModelBuilder.sectionLabel(_:polygon:)`, `RoomOutline.build`, `CleanModelStore` (`loadEdited`, `loadBase`, `save`). FloorPlan: `RoomTitles.sectionName(_:)`, `PlanViewport` (`fitting(min:max:in:margin:)`, `toScreen`, `toPlan`), `PlanBuilder.build(from:floors:)`, `PlanModelStore.save`. Pipeline: `IdleTimerGuard`. Store: `ProjectLibrary` (`create`, `update`, `discardRoom`, `delete`, `package(for:)`), `EditStore` (`load`, `append`). Core: `FakeScanEngine`, `ScanEngineEvent`, `ScanEngineState`, `LiveScanSnapshot`, `CaptureSessionRef`, `RoomRecord` (CR-7), `FloorRecord`, `FrameLink`, `RoomAlignmentRecord`, `EditOperation.setRoomAlignment`, `TrackingSummary`, `ProjectPackage` (`rawRoomURL`, `sessionURL`), `RawScanFolder` (`worldMapURL`, `resolve`), `MapperError`. Support: `Copy.House.*`, `Copy.Onboarding.house`, `Copy.Scanning.*`, `Copy.Permissions.*`, `Copy.Errors.*`, `Copy.A11y.roomDone(_:)`, `roomNeedsScan(_:)`, `rescanRoomHint`, `scanView`, `Copy.FloorPlan.defaultRoomTitle(_:)`, `Copy.Measure.save`, `Copy.Onboarding.skip`, `Copy.Project.cancel`, `Haptics.selection()`, `Haptics.success()`, `LogStore` (category "house").

**Apple APIs** (RESEARCH 3.1, 3.2, 3.5, 3.9, 3.10):
```swift
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)
dynamic var session: ARSession { get set }                                         // ARView
var initialWorldMap: ARWorldMap? { get set }                                       // ARWorldTrackingConfiguration (through 3.30b)
@nonobjc static func unarchivedObject<DecodedObjectType>(ofClass cls: DecodedObjectType.Type, from data: Data) throws -> DecodedObjectType?
    where DecodedObjectType : NSObject, DecodedObjectType : NSCoding            // NSKeyedUnarchiver, iOS 11.0
class ARCoachingOverlayView                                                        // goal, activatesAutomatically, setActive(_:animated:), iOS 13.0
nonisolated func persistentSystemOverlays(_ visibility: Visibility) -> some View
nonisolated func sensoryFeedback<T>(_ feedback: SensoryFeedback, trigger: T) -> some View where T : Equatable
MagnifyGesture(minimumScaleDelta: 0.01); DragGesture(minimumDistance: 10, coordinateSpace: .local)   // RESEARCH 3.6
```
Not in RESEARCH: `ARCoachingOverlayView.session` and `.goal = .tracking` (iOS 13.0), `ARSession()` (iOS 11), SwiftUI `RotateGesture(minimumAngleDelta:)` (iOS 17.0; never the deprecated `RotationGesture`), `Canvas` path drawing (RESEARCH 3.6 lists `Canvas`), `AVCaptureDevice.authorizationStatus(for:)` and `requestAccess(for:)` (iOS 7), `UIApplication.openSettingsURLString` (iOS 8), `.presentationDetents` and `.interactiveDismissDisabled` (iOS 15 and 16), `Task.sleep(nanoseconds:)` (iOS 13).

**Must NOT do.** Never create a second `RoomCaptureView` for the same session or mount `RoomCaptureContainer` in a branch that can switch back while its engine is in use (its dismantle tears the engine down; returning to the relocalization view is allowed only after that engine was torn down, with a new engine and `.id`); never pass reset run options except in the relocalization run before RoomPlan starts; never mark a session `.relocalized` unless tracking reached `.normal` against the map (D9); never reuse a session after a system stop for the next room; never delete a superseded room or its raw folder (CR-7 keeps both); never delete raw data except through `ProjectLibrary.discardRoom` after the Discard confirmation; never write alignment anywhere but `setRoomAlignment` edits; never run StructureBuilder or processing here (AppShell enqueues); never write `isIdleTimerDisabled` (IdleTimerGuard only); never show a banner that duplicates RoomPlan's coaching (the engine's filter already applies); never import MissingAreas, CoverageLive or LiveMeshView (closures only); never hardcode text.

**Copy strings.** Existing: all of `Copy.House` (title, addRoom, rescanRoom, continueRoom, nameRoomTitle, nameRoomPlaceholder, roomSuggestions, addFloor, finishBuilding, aligning, alignFailedTitle, alignFailedBody, alignManual, alignRescanDoorway, alignDone, roomDone, roomNeedsScan, floorLabel, progressSummary), `Copy.Onboarding.house`, `Copy.Empty.noRooms`, `Copy.Scanning` chrome and cancel dialog, `Copy.A11y.roomDone`, `roomNeedsScan`, `rescanRoomHint`, `Copy.Measure.save`, `Copy.Onboarding.skip`, `Copy.ScanUI.*` (3.24). New in `Copy+HouseUI.swift` (`extension Copy { enum HouseUI }`):
- `relocalizeTitle = "Go back to a room you already scanned"`
- `relocalizeBody = "Point your iPhone at its walls and move slowly. Mapper will find its place."`
- `relocalizeHint = "Looking for rooms you already scanned"`
- `startFresh = "Start Fresh Here"`, `keepLooking = "Keep Looking"`
- `startFreshBody = "Mapper couldn't find where you are. New rooms will need lining up by hand."`
- `noMapTitle = "Nothing to line up with"`, `noMapBody = "This house has no saved room to find. New rooms will need lining up by hand."`
- `relocalizeLost = (title: "Mapper lost its place", body: "Start fresh here and line up the new rooms by hand later.")`
- `static func roomNeedsLineUp(_ room: String) -> String { "\(room) needs lining up" }`
- `static func roomChip(_ room: String, floor: String) -> String { "\(room), \(floor)" }`
- `nextRoomHint = "Start at the doorway you walked in through"`
- `lowMemoryHint = "Your iPhone is low on memory. Finish Building now and scan the rest later."`
- `joinRoomsAgain = "Join Rooms Again"`
- `mergeFailedTitle = "Rooms weren't joined automatically"`, `mergeFailedBody = "Your rooms are saved. Try joining them again, or line them up by hand."`
- `lineUpTitle = "Line Up Rooms"`, `lineUpHint = "Drag the room into place. Turn it with two fingers."`
- `turnLeft = "Turn Left"`, `turnRight = "Turn Right"`
- `snappedDoorway = "Lined up with the doorway"`, `snappedWall = "Lined up with the wall"`
- `alignNotReady = "The rooms are still being built. Try again in a moment."`
- `a11yMoveRoomHint = "Drag with one finger to move the room, two fingers to turn it"`

**Self-test.** `HouseUISelfTest.run()`, at least 28 checks: `nextPhase` for the new-house path (preflight, tips, capturing, stopping, checking, quality, naming, roomList, capturing on nextRoom, finishing on finishBuilding, done), the relocalizing path (relocalized and startedFresh both reach capturing), `nextRoom(relocalize: true)` reaching relocalizing, discard with and without other rooms, cancel with and without rooms, `engineStopping` from capturing, a failure; `HouseManifestRules.status(after:)` gives `.needsRescan` for a poor evaluation and `.captured` for good and okay; `roomRecord` takes the session's link, not the result's; `append` sets `.needsProcessing`; `supersede` sets `supersededBy` and copies name and floor; `addFloor` returns max + 1; `status(for:placement:userAligned:)` for done, needs scan, needs lining up, lined up by the user, and capturing; `rows` hide a superseded room and group by floor with `Copy.House.floorLabel`; `progressText` counts done rooms; `suggestsFinishFloor` true at 799 MB and false at 801 MB; `preflightError` for cameraDenied, noLidar and lowStorage, nil for cameraUndetermined; `decide`: `.normal` held 1 s is relocalized, `.relocalizing` at 29 s keeps waiting, 30 s times out, `.normal` for 0.5 s keeps waiting; `sourceMap` in a temp package picks the rescanned room's map, else the latest anchor-group room with a map, skips an unaligned room's map, and returns nil without maps; `worldMapPath` resolves inside the session folder with `RawScanFolder.resolve`; `suggestedNames(sectionLabel: "kitchen")` starts with "Kitchen" and has no duplicate; `HouseAlert.from` keeps title, body and actions of a ScanUI alert; `HouseDemo.offset` leaves a 0.12 m gap between two demo rooms and the written demo model has one shared wall pair; `canOfferMissingAreas` is false in Demo Mode, after a system stop, with 0 missing areas and while the engine is not `.finished`, true otherwise.

**Acceptance checks.** One `RoomCaptureView` per visit (log "RoomCaptureView created" once per engine); `startNextRoom` is used between rooms of a visit; every room of a relocalized session carries `.relocalized` only after the decision; two visits in a row log two "hub deinit" lines; each room logs available memory after eviction; the quality sheet shows over the live camera; the room list and project screen read only the manifest, the Structure report and the edit log; all text from Copy.

**SPEC owned.** "HOUSE / BUILDING MODE": scan rooms separately and combine (capture side and the Finish Building hand-off), progress ("Dining Room done", "Hallway needs additional scan"), return to incomplete sections (Rescan, Continue Scanning with relocalization), manual correction when automatic alignment fails (AlignRoomsScreen), multiple floors (Add Floor); "SCANNING MODES" HOUSE / BUILDING; commercial spaces room by room (4.1).

**TEST_PLAN ids.** HOUSE-01, HOUSE-02, HOUSE-05, HOUSE-06, HOUSE-07, HOUSE-08, HOUSE-09, MODE-03 (House starts), PERF-03, PERF-05, PERF-25, PERF-26 (recovery of a house room with AppShell), OFF-01 (house workflow offline).

### 3.42 ObjectUI (wave 5b)

**Purpose.** The Object flow and result for an amateur ("Object scanning must behave differently from architectural scanning"): the size chooser (D4: small or medium goes to Object Capture here; large is handed to AppShell, which presents LargeObject), preflight (ScanUI's camera, LiDAR, storage, battery and heat checks plus ObjectCapture's support and 3 GB gate), the pre-permission screen, tips, project creation, the capture cover hosting ObjectCapture's `ObjectScanScreen`, the manifest update when the photos are sealed, and the object result screen: a processing view while reconstruction runs (stage, percent and time left from `PhotogrammetryMonitor`), then the model in Viewer3D (textured Object Capture model through `loadModel`, untextured mesh, box toggle), width, height, depth, surface area and volume (or `Copy.Viewer.volumeUnavailable`) with confidence, notes (photos downsampled, sides not joined), rename, Export and Retry callbacks, and Demo Mode with a synthetic object. Large objects' results (ObjectModel's large path) use the same result screen.

**Build and wave.** Build 5, wave 5b. Core, Store, ObjectCapture, ObjectModel, Viewer3D (with 3.34a), MeasureCore (`MeasureDisplay`), ScanUI, Pipeline (`ProcessingRunner`, `ProjectProcessingState`, `IdleTimerGuard`), TextureJob (`TextureStore` for large objects), Export (`USDZWriter`, demo), Geometry, MeshProcessing, Units, Support; SwiftUI, AVFoundation. About 1400 lines excluding the self-test.

**Files.** `ios/Sources/ObjectUI/ObjectSizeChooser.swift`, `ObjectFlowModel.swift`, `ObjectFlowScreen.swift`, `ObjectResultModel.swift`, `ObjectResultScreen.swift`, `ObjectPresentation.swift`, `ObjectDemo.swift`, `ObjectUISelfTest.swift`, `ios/Sources/Support/Copy+ObjectUI.swift`.

**Public Swift API.**
```swift
enum ObjectFlowPhase: Equatable {
    case chooser, preflight, permission, tips, capturing, saving
    case done(UUID), largeChosen, failed(String), cancelled
}
enum ObjectFlowSignal: Equatable, Sendable {
    case choseSmallMedium, choseLarge, preflightPassed(showTips: Bool), preflightBlocked, permissionNeeded
    case permissionGranted(showTips: Bool), permissionDenied, tipsDone, captureSealed, saved(UUID)
    case captureEnded, cancelled, failed(String)
}
enum ObjectAlertAction: Equatable, Sendable { case ok, openSettings }
struct ObjectAlert: Identifiable, Equatable {
    var id: String; var title: String; var body: String; var actions: [ObjectAlertAction]
    /// Keeps title and body; `.ok` and `.openSettings` map one to one, `.finishNow` and `.resume`
    /// (capture-time actions that preflight alerts never carry) are dropped, `[.ok]` when none is left.
    static func from(_ alert: ScanAlert) -> ObjectAlert
    /// `unsupported` -> Copy.Errors.objectUnsupported; `lowStorage` -> Copy.Errors.storageFullTitle
    /// and storageFullBody(_:) with the size text ScanUI's storage alert uses (3 GB needed);
    /// `deviceHot` -> Copy.ObjectUI.tooHotToStart; `deviceWarm` -> Copy.ScanUI.warmTitle, warmBody.
    static func preflight(_ issue: ObjectPreflightIssue) -> ObjectAlert
    /// ScanUI's blocking issue as an alert: `from(ScanErrorCopy.alert(for:))` of cameraDenied ->
    /// `.cameraDenied`, noLidar -> `.unsupportedDevice`, lowStorage(free) -> `.lowStorage(freeBytes:)`;
    /// nil for cameraUndetermined (the permission phase) and warnings.
    static func scanPreflight(_ issue: PreflightIssue) -> ObjectAlert?
}

@MainActor final class ObjectFlowModel: ObservableObject {
    @Published private(set) var phase: ObjectFlowPhase
    @Published var alert: ObjectAlert?
    let isDemo: Bool
    private(set) var projectID: UUID?
    /// The capture model while capturing (ObjectFlowScreen shows its ObjectScanScreen).
    private(set) var scanModel: ObjectScanModel?
    /// Main. Called once after the photos were sealed and the manifest updated (AppShell
    /// enqueues the object plan and opens the object result).
    var onComplete: ((UUID) -> Void)?
    /// Main. The user chose Large (AppShell presents LargeObject's flow).
    var onLargeObject: (() -> Void)?
    /// Main. The flow ended without an object (any project made for it was deleted).
    var onDismiss: (() -> Void)?
    init(isDemo: Bool)
    func begin()                                   // shows the chooser
    func choose(_ size: ObjectSize)
    func permissionContinue() async
    func tipsFinished(dontShowAgain: Bool)
    func openSettings()
    func cancel()                                  // chooser, permission or tips
    nonisolated static func nextPhase(_ phase: ObjectFlowPhase, on signal: ObjectFlowSignal) -> ObjectFlowPhase
}
/// Chooser, permission screen, tips (ScanUI's ScanTipsSheet(mode: .object)), the capture
/// (ObjectCapture's ObjectScanScreen) and the saving state; forced dark while capturing,
/// holds an IdleTimerGuard token while capturing or saving.
struct ObjectFlowScreen: View { init(model: ObjectFlowModel) }
struct ObjectSizeChooser: View { init(onPick: @escaping (ObjectSize) -> Void, onCancel: @escaping () -> Void) }

/// What exists on disk for the object.
struct ObjectResultFiles: Equatable, Sendable {
    var hasModel = false, hasMesh = false, hasDimensions = false, hasTexture = false
    var size: ObjectSize = .smallMedium
    init()
}
enum ObjectResultAvailability: Equatable, Sendable {
    case processing(text: String, percent: Int?, remaining: String?)
    case ready
    case failed(reason: String)
    case noObject
}
struct ObjectDimensionRow: Identifiable, Equatable, Sendable {
    var id: String                 // "object.width", "object.height", "object.depth", "object.area", "object.volume"
    var title: String              // Copy.Viewer.width, height, depth, Copy.Measure.surfaceArea, Copy.Viewer.volume
    var valueText: String          // MeasureDisplay.valueText, or Copy.Viewer.volumeUnavailable for the volume
    var accuracyText: String?      // MeasureDisplay.accuracyText
    var note: String?              // Copy.Measure.estimated when the record's provenance is .estimated
    var isLowConfidence: Bool      // MeasureDisplay.isLowConfidence(_:kind:)
    var accessibility: String      // MeasureDisplay.accessibilityText
}
enum ObjectPresentation {
    /// Pure. Ready when dims.json and (the model or the mesh) exist; processing while the job
    /// is queued or running (text from `stageText` of the monitor's stage, else the runner's
    /// current step: reconstructObject -> Copy.ObjectUI.stagePreparing until the monitor
    /// reports, objectMetrics -> Copy.ObjectUI.stageMeasuring, thumbnail -> Copy.Processing.stepSaving;
    /// waiting shows Copy.ObjectUI.waiting); failed when the status is `.needsAttention` or a
    /// step failed (Copy.Errors.processingFailed.body); noObject without an ObjectRecord.
    static func availability(files: ObjectResultFiles, processing: ProjectProcessingState, status: ProjectStatus,
                             progress: PhotogrammetryProgress?) -> ObjectResultAvailability
    /// Width, height, depth, surface area, volume, in that order, through
    /// `ObjectDimensions.measuredValues` and MeasureDisplay.
    static func rows(for record: ObjectDimensionsRecord, prefs: UnitPreferences) -> [ObjectDimensionRow]
    static func stageText(_ stage: PhotogrammetryStage?) -> String
    /// "About n min left" (minutes rounded up) or "Less than a minute left"; nil without an estimate.
    static func remainingText(seconds: Double?) -> String?
    static func notes(info: PhotogrammetryInfo?) -> [String]      // downsampled, stitching incomplete
    /// Small and medium: the model exists. Large: TextureStore has the object's texture (no build 5
    /// processing plan textures large objects, so this stays false for them until a later build).
    static func canShowTextured(files: ObjectResultFiles) -> Bool
    /// Large objects: textured page parts whose triangle centroid lies inside the box.
    static func texturedParts(_ parts: [TexturedPagePart], inside box: OrientedBox) -> [TexturedPagePart]
    /// The untextured mesh as one lit gray part on `.raw` with pick tag `.rawMesh`.
    static func untexturedPart(_ mesh: MeshWithAttributes) -> ViewerPart
    /// Box parts (`ViewerContentBuilder.boxParts`) on `.overlay`, no pick tag.
    static func boxParts(_ box: OrientedBox) -> [ViewerPart]
}

@MainActor final class ObjectResultModel: ObservableObject {
    @Published private(set) var availability: ObjectResultAvailability
    @Published private(set) var rows: [ObjectDimensionRow]
    @Published private(set) var notes: [String]
    @Published private(set) var title: String
    @Published private(set) var canShowTextured: Bool
    @Published var showsTextured: Bool          // textured (.realistic) or Solid Color (.raw)
    @Published var showsBox: Bool               // Copy.Viewer.boundingBox (.overlay)
    let viewer: ViewerModel
    let projectID: UUID
    init(projectID: UUID)
    /// Manifest, files, dims.json, mesh, info; while processing the viewer is unloaded
    /// (nothing else holds GPU memory while photogrammetry runs); when ready, `viewer.load`
    /// of the untextured part and the box, then `viewer.loadModel` of the Object Capture
    /// model with the scale correction and the mesh as pick mesh.
    func load() async
    func setTextured(_ on: Bool)
    func setBoxVisible(_ on: Bool)
    func rename(to name: String) throws          // ProjectLibrary.rename
}
/// Processing view (Copy.Processing.title, stage text, progress bar, time left,
/// Copy.Processing.keepOpen) or the viewer with the Textured / Solid Color control, Show Box,
/// the size panel with confidence and Copy.Measure.disclaimer, notes, Export and Retry.
/// Observes ProcessingRunner.shared.states[projectID], PhotogrammetryMonitor.shared and
/// `.mapperManifestDidChange`; tapping the title offers Rename.
struct ObjectResultScreen: View {
    init(projectID: UUID, onExport: @escaping () -> Void, onRetry: @escaping () -> Void)
}

enum ObjectDemo {
    /// A 0.40 x 0.30 x 0.25 m two-color box: raw/objects/<id>/ with a demo objectlog.json
    /// sealed by `ProjectStore.sealRawFolder`, `model.usdz` from `USDZWriter.data(for:)` at
    /// `PhotogrammetryStore.modelURL`, mesh.mchk and dims.json through ObjectModel; returns the
    /// record (status `.processed`, `modelFile` "model.usdz"). The caller sets the project `.ready`.
    static func makeDemoObject(package: ProjectPackage, objectID: UUID, now: Date) throws -> ObjectRecord
}
```

**Rules.** `choose(.large)` ends the flow with `onLargeObject` (no project is made here). `choose(.smallMedium)`: `ScanPreflight.run(mode: .object, isDemo:)` (async) then `ObjectCapturePreflight.run()` (Demo Mode skips both); a blocking issue shows `ObjectAlert.scanPreflight` or `ObjectAlert.preflight` and ends with `onDismiss`; camera undetermined goes to the permission phase (`Copy.Permissions` strings, `AVCaptureDevice.requestAccess(for: .video)`); tips when `SettingsKey.tipsSeen(.object)` is unset (the merged sheet shows `Copy.Onboarding.object` for `.object`). Then `ProjectLibrary.shared.create(kind: .object, name: ScanFlowModel.defaultProjectName(mode: .object, now: Date()))`, a new object id, `ObjectScanModel(target:)` and `start()` (a throw deletes the new project and shows the alert). On the model's `onComplete(result)`: one `ProjectLibrary.update` appends `ObjectRecord(id:, name: "", size: .smallMedium, status: .captured, imageCount: result.imageCount, modelFile: nil)`, sets status `.needsProcessing` and `reconstructionPending = true`, then `onComplete(projectID)`. On `onEnded` before any record the project is deleted (`ProjectLibrary.delete`) and `onDismiss` fires. Demo Mode: create the project, `ObjectDemo.makeDemoObject`, set `.ready`, `onComplete`. The result screen decides only from files and the in-memory runner state (never from stamps, as Results does); it shows Retry (`Copy.Errors.tryAgain`) when the status is `.needsAttention` or a step failed, and Retry calls `onRetry` (AppShell's `ProcessingPlans.retry`).

**Uses.** ObjectCapture: `ObjectScanModel` (`start`, `onComplete`, `onEnded`, `teardown`), `ObjectScanScreen`, `ObjectScanTarget`, `ObjectScanResult`, `ObjectCapturePreflight`, `ObjectPreflightReport`, `ObjectPreflightIssue`, `PhotogrammetryMonitor.shared`, `PhotogrammetryProgress`, `PhotogrammetryStage`, `PhotogrammetryStore` (`modelURL`, `modelURLIfPresent`, `loadInfo`), `PhotogrammetryInfo`. ObjectModel: `ObjectModelStore` (`loadDimensions`, `loadMesh`, `saveMesh`, `saveDimensions`), `ObjectDimensionsRecord`, `ObjectDimensions` (`measuredValues`, `measure`), `ObjectVolumeReason`. Viewer3D: `ViewerModel` (`load`, `loadModel(_:layer:transform:pickMesh:pickTag:)`, `unload`, `setVisible`, `resetView`), `ViewerContainer`, `ViewerContent`, `ViewerPart`, `ViewerMaterial`, `ViewerLayer`, `ViewerPickTag`, `ViewerContentBuilder` (`boxParts`, `texturedPart`). MeasureCore: `MeasureDisplay` (`valueText`, `accuracyText`, `isLowConfidence(_:kind:)`, `accessibilityText`). ScanUI: `ScanPreflight.run(mode:isDemo:)`, `ScanFlowModel.defaultProjectName(mode:now:)`, `PreflightReport`, `PreflightIssue`, `CameraPermission`, `ScanErrorCopy.alert(for:)`, `ScanAlert`, `ScanTipsSheet(mode:onStart:)`, `SettingsKey.tipsSeen(_:)`, `demoMode`. Pipeline: `ProcessingRunner.shared` (`states`), `ProjectProcessingState`, `IdleTimerGuard`. TextureJob: `TextureStore` (`exists`, `load`), `TexturedMesh.pageParts()`, `TexturedPagePart`. Export: `USDZWriter.data(for:layerName:modified:)`, `ExportScene`, `ExportMesh`, `ExportMaterial`. Geometry: `OrientedBox` (`contains(_:tolerance:)`, `corners`), `TriangleMesh`. MeshProcessing: `MeshWithAttributes`. Store: `ProjectLibrary` (`create`, `update`, `delete`, `rename`, `package(for:)`), `Notification.Name.mapperManifestDidChange`. Core: `ObjectRecord`, `ObjectSize`, `ProjectStatus`, `MeasurementKind`, `MapperError`, `ProjectStore.sealRawFolder`, `ProjectStore.verifyRawFolder` (self-test). Units: `UnitPreferences.load(from:)`. Support: `Copy.ObjectUI` (new), `Copy.Viewer` (`width`, `height`, `depth`, `volume`, `volumeUnavailable`, `boundingBox`, `textured`, `solidColor`, `export`, `resetView`), `Copy.Measure.surfaceArea`, `estimated`, `disclaimer`, `Copy.Processing.title`, `stepShape`, `stepTextures`, `stepSaving`, `keepOpen`, `Copy.Errors.processingFailed`, `tryAgain`, `objectUnsupported`, `storageFullTitle`, `storageFullBody(_:)`, `tooHot`, `ok`, `Copy.ScanUI.warmTitle`, `warmBody`, `Copy.Permissions.*`, `Copy.Onboarding.object`, `Copy.Project.rename`, `renameTitle`, `Copy.A11y.modelViewer`, `modelViewerHint`, `LogStore` (category "objectui").

**Apple APIs.** SwiftUI only beyond the modules above: `.fullScreenCover` is AppShell's; this module uses `ProgressView(value:)`, `Picker` with `.pickerStyle(.segmented)` for Textured and Solid Color, `Toggle`, `.alert`, `.sensoryFeedback(.success, trigger:)` on a finished model (RESEARCH 3.10); `AVCaptureDevice.authorizationStatus(for:)` and `requestAccess(for: .video)` (not in RESEARCH, iOS 7); `UIApplication.openSettingsURLString` (not in RESEARCH, iOS 8).

**Must NOT do.** Never start Object Capture for a large object; never create a project before preflight passes; never run processing (AppShell enqueues); never keep the viewer loaded while reconstruction runs; never show a size without its confidence text, or a volume when ObjectModel reported none; never present a bounding-box volume as the object's volume; never write `isIdleTimerDisabled`; never import LargeObject, Results or ExportUI; never hardcode text.

**Copy strings.** Existing as listed under Uses. New in `Copy+ObjectUI.swift` (`extension Copy { enum ObjectUI }`):
- `sizeTitle = "How big is it?"`
- `smallMedium = "Small or Medium"`, `smallMediumDetail = "Fits on a table or a chair. You walk all the way around it."`
- `large = "Large"`, `largeDetail = "An appliance, a vehicle or equipment."`
- `stagePreparing = "Getting your photos ready"`, `stageAligning = "Lining up your photos"`, `stageDetail = "Adding detail"`, `stageFinishing = "Finishing up"`, `stageMeasuring = "Measuring your object"` (`stageText` maps meshGeneration to `Copy.Processing.stepShape` and textureMapping to `Copy.Processing.stepTextures`; pointCloudGeneration to `stageDetail`)
- `waiting = "Waiting to start"`
- `tooHotToStart = (title: "Your iPhone is too hot", body: "Let it cool down for a few minutes, then try again.")`
- `static func remainingMinutes(_ minutes: Int) -> String { "About \(minutes) min left" }`, `remainingSoon = "Less than a minute left"`
- `sizeSection = "Size"`
- `downsampledNote = "Your photos were made smaller to fit in memory, so the model may show less detail."`
- `stitchingNote = "Some sides didn't join up, so parts of the model may be missing."`

**Self-test.** `ObjectUISelfTest.run()`, at least 18 checks: `nextPhase` for the small path (chooser, preflight, permission, tips, capturing, saving, done), the large choice, a blocked preflight, a denied permission and a cancel; `ObjectAlert.preflight` non-empty for every issue; `scanPreflight` nil for cameraUndetermined and a warning, Open Settings for cameraDenied; `availability`: processing with percent while `reconstructObject` runs, the waiting text when queued, ready with dims and a model, ready with dims and only a mesh (large), failed for `.needsAttention`, noObject; `stageText` non-empty and distinct for the six stages; `remainingText` of 30 s, 150 s ("About 3 min left") and nil; `rows` of a 0.40 x 0.30 x 0.25 m closed box give 5 rows with one plus-minus accuracy each in metric and imperial; a record without volume gives the volume row with `Copy.Viewer.volumeUnavailable` and no accuracy; an `.estimated` record gives the Estimated note; `canShowTextured` for small with a model, large with and without a texture; `texturedParts` keeps only faces inside the box; `ObjectDemo.makeDemoObject` in a temp package writes model.usdz, dims.json and mesh.mchk that load back through ObjectModel and a sealed raw folder that `ProjectStore.verifyRawFolder` accepts.

**Acceptance checks.** The flow owns the capture model and tears it down on every end; the result screen shows the processing view without any viewer content while reconstruction runs, then the model within a few seconds of `objectMetrics` finishing; switching Textured and Solid Color only toggles layers; every number goes through MeasureDisplay and Units; Demo Mode never touches the camera.

**SPEC owned.** "OBJECT SCANNING": "Object scanning must behave differently from architectural scanning" (size chooser, object-only result with no walls, floor plan or room numbers), outputs shown (textured mesh, untextured mesh, bounding box, width, height, depth, estimated volume where valid); "SCANNING MODES" OBJECT entry; "MEASUREMENT CONFIDENCE" shown for objects; "CORE DESIGN PRINCIPLE" Representation E (display).

**TEST_PLAN ids.** OBJ-01, OBJ-02, OBJ-03, OBJ-05 (Estimated note), OBJ-06, OBJ-09, MODE-02, MODE-03, OFF-01 (object workflow offline), PERF-04, smoke #9.

### 3.43 Build 5 revisions of the build 4 screens (waves 5c and 5d)

Every 5c revision edits only its own module folder and its own `Copy+<Module>.swift`, keeps the build 4 contract (3.24 to 3.28) and adds exactly the API below. No 5c revision imports another: the quality sheet (QualityUI) and its Show Missing Areas callback are composed by AppShell; Results reaches House actions, exports and Quick Measure exports only through closures AppShell wires; ScanUI's reusable pieces for House (`ScanCaptureExtras`, `ScanCoverageHUD`, `ScanTourLayer`) are used by AppShell (5d), never by Results or HouseUI. Where the build 4 implementation split a contract file differently (for example ScanUI's `ScanFlowReducer.swift` and `ScanQualityCheck.swift`, Results' `ResultLoader.swift` and `ResultContentBuilder.swift`), the agent edits the file that holds the code; new files use the names listed. AppShell (3.43e, wave 5d) is the only module that composes screens of different modules and the only editor of `ContentView.swift` and `MapperApp.swift`.

### 3.43a ScanUI revision (wave 5c)

**Purpose.** Wire the build 5 live-coverage pieces into the room scan: a `CoverageLiveRecorder` on every room capture (expected surfaces from the live room, coverage guidance "Scan this corner", "Point toward the floor", "Scan the ceiling", "This area needs another pass", `coverageFraction` and the minimap in the snapshots); the minimap and the color legend over `RoomCaptureView`; Show Missing Areas (D19) as a tour on the same running session between two quality-sheet appearances, with the re-evaluated numbers; and the two-pass fallback when RoomPlan stripped the mesh (D16): a same-session mesh and photo pass before the quality check. Also the reusable pieces AppShell needs for House rooms (coverage extras, the tour layer, the coverage HUD).

**Build and wave.** Build 5, wave 5c (branch `impl/scanui-b5`). Build 4 dependencies plus CoverageLive (5a), LiveMeshView (5a), Quality with CR-10 (5a), CoverageOverlay (5b), MissingAreas (5b); RealityKit (`ARView` in the overlay hook). About 400 lines of changes.

**Files.** Edits: `ScanFlowModel.swift` (state), `ScanFlowModel+Room.swift` (coverage in `makeEngine(for:)`, the detail offer), `ScanQualityCheck.swift` (passes in the quality check), `ScanFlowReducer.swift` (phases, signals, `nextPhase` and the computed phase properties), `RoomScanScreen.swift` (layers and the offer alert), `ScanUISelfTest.swift`, `Copy+ScanUI.swift`. New: `ScanFlowModel+Tour.swift` (tour and detail pass), `ScanCoverageViews.swift` (`ScanCoverageHUD`, `ScanTourLayer`, `ScanDetailPassLayer`), `ScanCoverageRules.swift` (pure rules and `ScanCaptureExtras`), `ScanUISelfTest+B5.swift`.

**Public Swift API** (additions and changed enums).
```swift
/// (changed) New phases: detailOffer, detailPass (D16 fallback, before the check) and touring (Show
/// Missing Areas, between two quality appearances). The build 4 computed properties get the new
/// cases: none is terminal, none is a sheet phase (`isSheetPhase` false, so AppShell's quality sheet
/// hides during them), and all three keep the capture view mounted (`showsCapture` true).
enum ScanFlowPhase: Equatable, Sendable {
    case preflight, permission, tips, capturing, stopping, detailOffer, detailPass, checking, quality, touring,
         finishing, done(UUID), failed(String), cancelled
}
/// (changed) New signals appended; the build 4 cases are unchanged.
enum ScanFlowSignal: Equatable, Sendable {
    case preflightPassed, preflightBlocked, permissionNeeded, permissionGranted, permissionDenied, tipsDone,
         engineStarted, doneTapped, engineStopping, roomFinished(UUID), evaluated, finishTapped, cancelConfirmed,
         discarded, failed(String)
    case completed(UUID)
    case detailOffered, detailStarted, detailSkipped, detailFinished, tourStarted, tourFinished
}
/// Pure rules of this revision.
enum ScanCoverageRules {
    /// Show Missing Areas is offered (D19): not Demo Mode, the room engine is `.finished`, neither the room
    /// nor an earlier tour was stopped by the system, and the evaluation lists at least one missing area.
    static func canOfferMissingAreas(isDemo: Bool, engineState: ScanEngineState?, stoppedBySystem: Bool,
                                     missingAreas: Int) -> Bool
    /// The detail pass is offered (D16): not Demo Mode, the room's log says `.meshStripped`, and the room
    /// was not stopped by the system (its session is still running).
    static func offersDetailPass(isDemo: Bool, degraded: DegradedMode, stoppedBySystem: Bool) -> Bool
}
/// Live coverage for a `RoomScanEngine`, shared with AppShell's House covers (3.43e). A plain enum, so
/// the closures are formed outside any actor (the hooks run on the hub queue, RoomCapture's
/// `installHubClosures` rule).
enum ScanCaptureExtras {
    /// A `CoverageLiveRecorder(meshSource: meshStore)`, the recorders to add (that recorder), and an
    /// installer that sets `liveRoomHandler`, `guidanceAugmenter` and `snapshotAugmenter` of an engine to
    /// its `liveRoomHook`, `guidanceHook` and `snapshotHook`.
    static func coverage(meshStore: MeshStore) -> (recorder: CoverageLiveRecorder, recorders: [ScanRecorder],
                                                   install: (RoomScanEngine) -> Void)
}
extension ScanFlowModel {
    // Declared in ScanFlowModel.swift:
    //   private(set) var coverage: CoverageLiveRecorder?          // nil in Demo Mode
    //   @Published private(set) var tour: MissingAreasModel?
    //   @Published private(set) var detailPass: MeshScanModel?
    /// The quality sheet may offer Show Missing Areas (AppShell passes `showMissingAreas` as the sheet's
    /// `onShowMissingAreas` only when this is true).
    var canShowMissingAreas: Bool { get }
    /// Quality sheet button: builds `MissingAreasTarget` (projectID, package, the room's `RoomRecord`,
    /// the evaluation, mode, settings, `roomEngine.hub`), `MissingAreasModel(target:)`, sets its
    /// `onFinished`, `start()`, signal `tourStarted`.
    func showMissingAreas()
    /// Detail offer buttons.
    func startDetailPass()
    func skipDetailPass()
}
/// Minimap (`CoverageMinimapView(snapshot: snapshot.minimap, coverageFraction: snapshot.coverageFraction)`)
/// at the bottom leading corner above the chrome's bottom bar, and a Colors button
/// (`Copy.Scanning.legendTitle`) that shows `CoverageLegendView()` in a card. Hidden when
/// `snapshot.minimap` is nil. Also placed by AppShell over `HouseScanScreen`.
struct ScanCoverageHUD: View { init(snapshot: LiveScanSnapshot) }
/// The tour over a still-mounted room view: `MissingAreasScreen(model:onViewReady:)` whose hook
/// attaches a `CoverageOverlayRenderer(source: model.coverage, thermal: model.target.hub.thermal)`
/// (detached in `onDisappear`). Also used by AppShell for House rooms.
struct ScanTourLayer: View { init(model: MissingAreasModel) }
/// The detail pass: `LiveMeshScreen(model:onViewReady:hud:)` with the same overlay attach, and a HUD of
/// `LiveMeshTopBar(elapsed: model.elapsedText, doneEnabled: model.state == .scanning, onCancel:, onDone:)`
/// with `Copy.ScanUI.detailHint`.
struct ScanDetailPassLayer: View {
    init(model: MeshScanModel, coverage: CoverageLiveRecorder, onCancel: @escaping () -> Void, onDone: @escaping () -> Void)
}
```

**Rules.**
- `makeEngine` (not Demo Mode): `let mesh = MeshStore()`, `let extras = ScanCaptureExtras.coverage(meshStore: mesh)`, recorders `[mesh, KeyframeRecorder(), PoseTrackRecorder(), photos] + extras.recorders`, `RoomScanEngine(target:recorders:)`, then `extras.install(room)`; `coverage = extras.recorder`. Never form the hook closures inside the `@MainActor` model.
- `RoomScanScreen`: `ScanCoverageHUD(snapshot: model.snapshot)` while capturing (not Demo Mode). In `detailPass` and `touring` the `RoomCaptureContainer` stays mounted with `.opacity(0)` and `.allowsHitTesting(false)` (dismantling it calls `teardown()`, which would stop the session the pass runs on) and `ScanDetailPassLayer` or `ScanTourLayer` covers the screen. `detailOffer` shows an alert: `Copy.ScanUI.detailTitle`, `detailBody`, buttons `detailStart` (`startDetailPass`) and `Copy.Onboarding.skip` (`skipDetailPass`).
- After `.roomFinished`: when `offersDetailPass(isDemo:degraded: roomEngine.lastResult.log.degraded, stoppedBySystem:)`, signal `detailOffered` instead of starting the check.
- `startDetailPass`: `let mesh = MeshStore()`, `let pass = CoverageLiveRecorder(meshSource: mesh)`, `let set = MeshScanRecorderSet(photos: true, mesh: mesh, extra: [pass])`, `MeshScanEngine(target: .patchPass(projectID:package:sessionID:roomID:mode:settings:), recorders: set.all, hub: roomEngine.hub)` with `guidanceAugmenter = pass.guidanceHook` and `snapshotAugmenter = pass.snapshotHook`, `MeshScanModel(engine:photos: set.photos)`, `onFinished` (sets the room's `hasMeshPass` through `ProjectLibrary.update`, then `detailFinished`) and `onIdle` (cancelled: `detailFinished` without a pass), `try start()` (a throw logs and signals `detailSkipped`), signal `detailStarted`. Done calls `finish()`, Cancel `discard()`.
- The quality check (build 4 `evaluateSealedRoom(package:record:now:)`) becomes `QualityEvaluator.evaluateSealedRoom(package:record:passes: MeshPassFolders.forRoom(roomID, in: package), now:)` (CR-10).
- Tour end (`MissingAreasModel.onFinished`): `teardown()` the tour model, keep the new evaluation (nil keeps the old one), remember `stoppedBySystem`, signal `tourFinished` (the sheet shows again).
- `finish()`, `discardScan()`, `confirmCancel()` and every terminal phase tear down the tour and the pass models (idempotent) before `roomEngine.teardown()`.

**Uses.** CoverageLive: `CoverageLiveRecorder` (`init(meshSource:options:)`, `liveRoomHook`, `guidanceHook`, `snapshotHook`). CoverageOverlay: `CoverageOverlayRenderer` (`init(source:thermal:options:)`, `attach(to:)`, `detach()`), `CoverageMinimapView(snapshot:coverageFraction:)`, `CoverageLegendView(compact:)`. MissingAreas: `MissingAreasTarget`, `MissingAreasModel` (`init(target:)`, `start()`, `teardown()`, `onFinished`, `coverage`, `target`, `stoppedBySystem`), `MissingAreasScreen(model:onViewReady:)`. LiveMeshView: `MeshScanTarget.patchPass(projectID:package:sessionID:roomID:mode:settings:passID:)`, `MeshScanEngine(target:recorders:hub:)` (`guidanceAugmenter`, `snapshotAugmenter`), `MeshScanRecorderSet(photos:mesh:extra:)`, `MeshScanModel` (`start()`, `finish(attachments:)`, `discard()`, `teardown()`, `onFinished`, `onIdle`, `state`, `elapsedText`), `MeshScanResult`, `LiveMeshScreen`, `LiveMeshTopBar`, `MeshPassFolders.forRoom(_:in:)`. Quality: `QualityEvaluator.evaluateSealedRoom(package:record:passes:now:)` (CR-10). RoomCapture: `RoomScanEngine` (`liveRoomHandler`, `guidanceAugmenter`, `snapshotAugmenter`, `hub`, `lastResult`, `state`), `RoomScanResult` (`stoppedBySystem`, `log.degraded`). CaptureCore: `ARSessionHub.thermal`. MeshRecord: `MeshStore`. Core: `DegradedMode`, `ScanEngineState`, `LiveScanSnapshot` (`minimap`, `coverageFraction`), `RoomRecord.hasMeshPass`. Support: `Copy.Scanning.legendTitle`, `Copy.Onboarding.skip`, `Copy.A11y.coverageLegend`.

**Apple APIs.** As 3.24, plus `ARView` only as the parameter type of `onViewReady` hooks (RealityKit); `.opacity(_:)` and `.allowsHitTesting(_:)` (SwiftUI, iOS 13, not in RESEARCH).

**Must NOT do.** Never merge while a `switch` over `ScanFlowPhase` or `ScanFlowSignal` outside ScanUI lacks the new cases (grep the target first; AppShell 4d compares phases with `==`; any exhaustive switch found is reported to the lead, who adds the cases in the same merge so `integration` stays green). Never unmount `RoomCaptureContainer` during a tour or a detail pass; never offer Show Missing Areas after a system stop or in Demo Mode; never import QualityUI, Results, ExportUI, HomeUI, HouseUI or AppShell; never create a second `ARSession` for a pass (the pass borrows `roomEngine.hub`); never form hub-queue closures inside `ScanFlowModel`; no hardcoded text.

**Copy strings.** Existing: `Copy.Scanning.legendTitle`, `legendGreen`, `legendYellow`, `legendRed`, `legendGray` (through `CoverageLegendView`), `Copy.Onboarding.skip`, `Copy.Quality.showMissingAreas` (the sheet's button, QualityUI). New in `Copy+ScanUI.swift` (`extension Copy.ScanUI`): `detailTitle = "Add the detailed scan?"`, `detailBody = "The detailed 3D scan didn't record. Walk slowly around the room once more to capture it. Your walls and floor plan are already saved."`, `detailStart = "Scan Detail"`, `detailHint = "Walk slowly around the room once"`.

**Self-test.** At least 12 new checks (`ScanUISelfTest+B5.swift`): `nextPhase` for capturing -> detailOffer -> detailPass -> checking, detailOffer -> checking on skip, a `.failed` during the pass reaching checking, quality -> touring -> quality, touring ignoring `finishTapped`; `canOfferMissingAreas` false in Demo Mode, false after a system stop, false with 0 missing areas, false while the engine is not `.finished`, true otherwise; `offersDetailPass` true only for `.meshStripped` without a system stop outside Demo Mode; `ScanCaptureExtras.coverage` returns one recorder in `recorders` and it is the returned `recorder` (built from a `MeshStore()`, no hardware).

**Acceptance checks.** Live coverage guidance appears during room scans (LIVE-05, LIVE-09); the minimap fills while walking; Show Missing Areas appears on the quality sheet only on a still-running session (smoke #4), the tour runs on the same session without a black screen, and the sheet returns with new numbers (QUAL-03); a `meshStripped` room offers the detail pass and the project's Raw Scan then has a mesh; the log shows one "RoomCaptureView created" per scan.

**SPEC owned.** "LIVE SCANNING EXPERIENCE" (coverage messages and the green, yellow, red and gray minimap in Room mode); "SCAN QUALITY SYSTEM" ("Selecting SHOW MISSING AREAS should guide the user directly to locations requiring additional scanning", entry and return); "CORE DESIGN PRINCIPLE" Representation A kept when RoomPlan strips the mesh (D16 fallback).

**TEST_PLAN ids.** LIVE-02 (minimap colors), LIVE-05, LIVE-09, QUAL-01 (with the button), QUAL-03, ROOM-05, smoke #3, #4.

### 3.43b Results revision (wave 5c)

**Purpose.** The result screen gains the build 5 tools and House support: measuring in the model (MeasureTool) on Realistic, 3D Clean and Raw Scan; Edit on the Floor Plan tab (PlanEditor); a floor picker for multi-level plans; for House projects the Rooms screen (HouseUI's `HouseProjectScreen`) with its actions forwarded to AppShell, per-room meshes and missing areas placed in the structure frame, superseded rooms left out, and "Joining rooms together..." while the merge runs; Change Category on the object card (honest: the card stops calling a user-set category a guess); orphaned edits listed with Remove These Edits (D3); Undo and Redo of the last edit (including alignment and category edits made elsewhere); and the Quick Measure project screen (the measurement list of a saved Quick Measure). Object projects are routed by AppShell to ObjectUI's result screen, never here.

**Build and wave.** Build 5, wave 5c (branch `impl/results-b5`). Build 4 dependencies plus MeasureTool (5a), PlanEditor (5a), Structure (5a: `StructureStore.effectiveAlignments`, `StructureStore.placementMatrices`), LiveMeasure (5a: `QuickMeasureStore`), HouseUI (5b: `HouseProjectScreen`), Core CR-1 and CR-7. About 650 lines of changes.

**Files.** Edits: `ResultScreen.swift`, `ResultModel.swift`, `ResultModel+Loading.swift` (and the loader and content builder files of the build 4 implementation), `ResultAvailability.swift` (`stepText`), `ResultObjectCard.swift`, `ResultsSelfTest.swift`, `Copy+Results.swift`. New: `ResultMeasuring.swift` (measure mode composition), `ResultHouse.swift` (pure House helpers), `ResultEdits.swift` (pure edit helpers, orphaned sheet, category picker), `ResultQuickMeasure.swift` (`QuickMeasureResultModel`, `QuickMeasureResultScreen`, `QuickMeasureRecords`), `ResultsSelfTest+B5.swift`.

**Public Swift API** (additions).
```swift
/// House actions forwarded to AppShell (HouseProjectScreen's callbacks).
enum ResultHouseAction: Equatable, Sendable { case continueScanning, rescan(UUID), lineUp(UUID), joinAgain }

/// (changed) `onHouseAction` added with a default, so AppShell 4d's call still compiles.
struct ResultScreen: View {
    init(projectID: UUID, onExport: @escaping (ExportViewState) -> Void, onRetry: @escaping () -> Void,
         onHouseAction: @escaping (ResultHouseAction) -> Void = { _ in })
}

extension ResultModel {
    // Declared in ResultModel.swift (build 4 members unchanged):
    //   let measureTool: MeasureToolModel                  // MeasureToolModel(projectID:viewer: viewer), made in init
    //   @Published private(set) var isMeasuring: Bool
    //   @Published var showsPlanEditor: Bool
    //   @Published var showsRooms: Bool
    //   @Published private(set) var isHouse: Bool
    //   @Published private(set) var levelIndex: Int
    //   @Published private(set) var levelTitles: [String]  // PlanEditorPresentation.levelTitle of each level
    //   @Published private(set) var orphaned: [EditOperation]
    //   @Published var showsOrphaned: Bool
    //   @Published var showsCategoryPicker: Bool
    //   @Published private(set) var canUndoEdit: Bool
    //   @Published private(set) var canRedoEdit: Bool
    //   @Published private(set) var userCategorized: Set<ElementID>
    /// Measure mode on a 3D tab: clears the selection, loads the tool on first use, forwards Hide
    /// Furniture (`setExcludesMovableObjects`); off: clears the draft.
    func setMeasuring(_ on: Bool) async
    /// Floor Plan tab level (rebuilds the drawing).
    func selectLevel(_ index: Int)
    /// Object card: appends `recategorizeObject(object:category:)` through `EditStore.append` off main.
    func changeCategory(_ category: ObjectCategory) throws
    /// `EditStore.reset(_:keeping: { !orphaned.contains($0) })` off main.
    func removeOrphanedEdits() throws
    /// `EditStore.undo` and `redo` off main.
    func undoEdit() throws
    func redoEdit() throws
}

enum ResultHouse {
    /// Active rooms (CR-7: `supersededBy == nil`), manifest order.
    static func activeRoomIDs(_ manifest: ProjectManifest) -> [UUID]
    /// Each active room's placement in the structure frame: `StructureStore.placementMatrices(manifest:alignments:)`
    /// of the effective records (`StructureStore.effectiveAlignments(package)`): the record's matrix,
    /// identity for an anchor-group room without a record (before AlignRoomsStep ran), no entry (the
    /// room is not drawn) for another group's room without a record, identity for every non-House project.
    static func transforms(manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord]) -> [UUID: simd_float4x4]
    /// A part moved by a rigid transform: positions by the matrix, normals by its rotation, uvs kept.
    static func transformed(_ part: ViewerPart, by matrix: simd_float4x4) -> ViewerPart
    /// A missing-area record moved by a rigid transform (centroid, normal, suggested viewpoint).
    static func transformed(_ record: MissingAreaRecord, by matrix: simd_float4x4) -> MissingAreaRecord
}
enum ResultEvidence {
    /// A clean room's evidence for its rows: its record's tracking fraction and relocalizations, with the
    /// WallEvidence of every room appended (walls merged in from another room keep theirs, CR-1).
    static func combined(for room: CleanRoom, evidence: [UUID: RoomEvidence]) -> RoomEvidence
}
enum ResultEdits {
    /// Orphaned operations of the clean model and the plan, without duplicates, in log order.
    static func orphaned(clean: [EditOperation], plan: [EditOperation], log: EditLog) -> [EditOperation]
    /// Objects whose category the user set: targets of the active (flattened) `recategorizeObject` operations.
    static func userCategorized(_ log: EditLog) -> Set<ElementID>
}

/// Quick Measure projects (AppShell's `.measurements` route).
enum QuickMeasureRecords {
    /// The saved list when `edits/measurements.json` exists (the user renamed or deleted), else the
    /// sealed `raw/measure/quick.json` records. The raw file is never rewritten.
    static func effective(saved: [MeasurementRecord]?, raw: [MeasurementRecord]) -> [MeasurementRecord]
}
@MainActor final class QuickMeasureResultModel: ObservableObject {
    @Published private(set) var rows: [MeasureToolRow]
    @Published private(set) var title: String
    let projectID: UUID
    init(projectID: UUID)
    /// Off main: `QuickMeasureStore.load(package)?.records`, `EditStore.loadMeasurements` only when
    /// `package.measurementsURL` exists, `UnitPreferences.load()`.
    func load() async
    /// Rename and delete write the whole effective list with `EditStore.saveMeasurements`.
    func rename(_ id: UUID, to name: String)
    func delete(_ id: UUID)
    func renameProject(to name: String) throws
}
/// Title with Rename, `MeasureToolList(rows:onRename:onDelete:onDeleteAll: nil, onClose: nil)`, Export.
struct QuickMeasureResultScreen: View { init(projectID: UUID, onExport: @escaping () -> Void) }
```

**Rules.**
- *Measure* (Copy.Viewer.measure in the toolbar of Realistic, 3D Clean and Raw Scan when that tab is ready): the `ViewerContainer` tap goes to `measureTool.tap(hit)` while `isMeasuring`, else to `handleTap(hit)`; `MeasureToolOverlay(model: measureTool)` sits over the viewer in the same frame; `MeasureToolBar(model:onDone:)` replaces the dimensions panel and the tab picker; its list is a sheet of `MeasureToolList` with Delete All. Switching to the Floor Plan tab ends measure mode. Hide Furniture changes are forwarded. 3D Clean floor parts get `pickTag: .element(room.id)` and Realistic textured parts `pickTag: .rawMesh` (build 4 left both unpickable), so floor and textured points can be tapped; the extra hierarchies are built off main at load like the others (their time is logged), and outside measure mode such a tap clears the selection, as a miss did.
- *Edit* (Copy.Viewer.edit on the Floor Plan tab when the plan is ready): `.fullScreenCover` of `PlanEditorScreen(projectID:onDone:)`; the screen reloads through `.mapperEditsDidChange` (build 4 observation).
- *Levels*: a segmented picker of `levelTitles` on the Floor Plan tab when the plan has more than one level; `PlanDrawing.make(level: plan.levels[levelIndex], ...)`; `RoomTitles.titles(for: plan, clean: clean)` for titles.
- *House* (`manifest.kind == .house`): a Rooms button (`Copy.House.title`) opens `HouseProjectScreen(projectID:onContinueScanning:onRescan:onLineUp:onJoinAgain:)` in a sheet; each callback closes the sheet and calls `onHouseAction`. Realistic and Raw Scan parts and missing-area records of each active room are moved with `ResultHouse.transforms` (the House clean model and plan are already in the structure frame); rooms not in `activeRoomIDs`, and rooms without an entry in `transforms`, are skipped everywhere. `ResultAvailability.stepText` maps `.mergeStructure` and `.alignRooms` to `Copy.House.aligning`.
- *Rows*: `RoomDimensions.rows(for: room, evidence: ResultEvidence.combined(for: room, evidence:))`.
- *Object card*: a Change Category button (`Copy.ObjectMenu.changeCategory`) opens a list of `ObjectCategory.allCases` by `Copy.FloorPlan.categoryName`; the card title is `Copy.FloorPlan.categoryName(category)` alone when the object is in `userCategorized`, else `Copy.Results.objectGuess(...)`.
- *Orphaned edits*: a banner (`Copy.Results.orphanedBanner`) when `orphaned` is not empty opens a sheet listing `PlanEditorPresentation.describe` of each, with `Copy.Results.orphanedBody`, Remove These Edits (`removeOrphaned`) and `Copy.Project.cancel`.
- *Undo and Redo* (`Copy.FloorPlan.undo`, `redo`) in the title menu, enabled from the loaded `EditLog`. AppShell re-runs processing after edits that need it (3.43e); Results only writes the log.
- *Quick Measure*: `QuickMeasureResultScreen` for `.quickMeasure` projects; Export calls `onExport` (AppShell presents `ExportSheet` with `ExportViewState.standard`).

**Uses.** MeasureTool: `MeasureToolModel`, `MeasureToolOverlay`, `MeasureToolBar`, `MeasureToolList`, `MeasureToolRow`, `MeasureToolPresentation.rows`. PlanEditor: `PlanEditorScreen(projectID:onDone:)`, `PlanEditorPresentation` (`describe`, `levelTitle`). HouseUI: `HouseProjectScreen(projectID:onContinueScanning:onRescan:onLineUp:onJoinAgain:)`. Structure: `StructureStore.effectiveAlignments(_:)`, `StructureStore.placementMatrices(manifest:alignments:)`. LiveMeasure: `QuickMeasureStore.load(_:)`, `QuickMeasureFile.records`. Store: `EditStore` (`load`, `append(_:to:)`, `undo`, `redo`, `reset(_:keeping:)`, `loadMeasurements`, `saveMeasurements`). FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing`, `RoomTitles.titles(for:clean:)`. RoomModel: `CleanModelStore.loadEdited`. MeasureCore: `RoomDimensions.rows(for:evidence:)`, `RoomEvidence`, `WallEvidence`. Core: `EditOperation`, `EditLog.flattenedActive`, `RoomRecord.supersededBy` (CR-7), `RoomAlignmentRecord`, `ObjectCategory`, `ScanMode`, `MeasurementRecord`, `ProjectPackage.measurementsURL`. Support: `Copy.Viewer.measure`, `edit`, `Copy.House.title`, `aligning`, `Copy.ObjectMenu.changeCategory`, `Copy.FloorPlan.undo`, `redo`, `categoryName(_:)`, `Copy.Project.cancel`, `rename`, `renameTitle`, `Copy.Empty.noMeasurements`.

**Apple APIs.** As 3.26, plus `.fullScreenCover(isPresented:content:)` (SwiftUI, iOS 14, not in RESEARCH).

**Must NOT do.** Never show Object projects (AppShell routes them to ObjectUI); never write raw data or `raw/measure/quick.json`; never enqueue processing (AppShell does after edits); never present ExportUI directly; never draw a superseded room; never call a user-set category a guess; never block main on disk.

**Copy strings.** Existing as listed under Uses. New in `Copy+Results.swift` (`extension Copy.Results`): `orphanedBanner = "Some edits no longer fit this scan"`, `orphanedBody = "They are kept but not shown. Remove them if you don't need them."`, `removeOrphaned = "Remove These Edits"`, `floorPicker = "Floor"`.

**Self-test.** At least 14 new checks (`ResultsSelfTest+B5.swift`): `activeRoomIDs` drops a superseded room; `transforms` gives identity for a Room project, the record's matrix for a House room, identity for an anchor-group House room without a record and no entry for an unaligned room without one; `transformed(part)` moves positions and turns normals, keeping uvs; `transformed(record)` moves the centroid and the viewpoint; `stepText(.mergeStructure)` and `stepText(.alignRooms)` equal `Copy.House.aligning`; `combined` keeps the room's tracking fraction and holds the walls of two records; `orphaned` removes duplicates and keeps log order; `userCategorized` finds a recategorize inside a batch and ignores an undone one; `QuickMeasureRecords.effective` returns the raw list when there is no saved file, the saved list (even empty) when there is one; the floor part of a 3D Clean room has pick tag `.element(room.id)` and a Realistic part has `.rawMesh`; `ResultHouseAction` values are distinct.

**Acceptance checks.** Measuring works on all three 3D tabs and never changes the dimensions panel's numbers; after Done Editing the plan, 3D Clean and the panel show the edits; a House project shows every active room in place on Realistic and Raw Scan; the Rooms screen's actions reach AppShell; a Quick Measure project opens its list, and rename and delete survive a relaunch while quick.json stays byte-identical.

**SPEC owned.** "MEASUREMENT SYSTEM" and "MEASUREMENT CONFIDENCE" (the tools on the result screen); "FLOOR PLAN EDITING" (entry); "HOUSE / BUILDING MODE" (the combined model on the result screen, return to incomplete sections through the Rooms screen); "AUTOMATIC OBJECT RECOGNITION" ("allow the user to correct labels": Change Category; guesses shown as guesses until corrected); "SCANNING MODES" QUICK MEASURE (the saved result).

**TEST_PLAN ids.** MEAS-01 to MEAS-11, CONF-01 to CONF-04, PEDIT-01 to PEDIT-09 (entry and result), PLAN-05, REC-02, HOUSE-05, HOUSE-06, HOUSE-07, HOUSE-08, MODE-06 (saved result), PERF-10, smoke #5, #7, #8.

### 3.43c HomeUI revision (wave 5c)

**Purpose.** Home for build 5: the mode picker enables House / Building, Object and Quick Measure (AppShell passes the set), a disabled mode shows its real reason (for example "Object scanning isn't available" on a device without Object Capture) instead of "Coming in a later version", and House rows count only active rooms (CR-7) in the subtitle and the needs-work badge.

**Build and wave.** Build 5, wave 5c (branch `impl/homeui-b5`). Build 4 dependencies plus Core CR-7. About 60 lines of changes.

**Files.** Edits: `HomePresentation.swift`, `HomeModePicker.swift`, `HomeScreen.swift`, `HomeUISelfTest.swift`.

**Public Swift API** (additions).
```swift
struct HomeModeEntry: Equatable, Identifiable, Sendable {
    // build 4 fields unchanged, plus:
    /// Shown under a disabled mode: its reason, else `Copy.HomeUI.comingLater`; nil when enabled.
    let note: String?
}
extension HomePresentation {
    static func modeEntries(availableModes: Set<ScanMode>, unavailableReasons: [ScanMode: String]) -> [HomeModeEntry]
    /// The build 4 form keeps working: `unavailableReasons` empty.
    static func modeEntries(availableModes: Set<ScanMode>) -> [HomeModeEntry]
    /// Rooms that count for a project: CR-7 `supersededBy == nil`.
    static func activeRooms(_ manifest: ProjectManifest) -> [RoomRecord]
}
struct HomeScreen: View {
    init(library: ProjectLibrary, runner: ProcessingRunner, availableModes: Set<ScanMode>,
         unavailableReasons: [ScanMode: String] = [:], onNewScan: @escaping (ScanMode) -> Void,
         onOpen: @escaping (UUID) -> Void, onSettings: @escaping () -> Void)
}
struct ModePickerSheet: View {
    init(availableModes: Set<ScanMode>, unavailableReasons: [ScanMode: String] = [:],
         onPick: @escaping (ScanMode) -> Void, onCancel: @escaping () -> Void)
}
```
Rules: `subtitle(for:dateText:)` counts `activeRooms` for `.house` and `.advancedSpace` (Quick Measure rows keep the build 4 `Copy.Home.measureSubtitle`); `badge(for:processing:)` looks for `.needsRescan` among active rooms only; the picker row and its VoiceOver value read `note` instead of the fixed later-version text. Opening a project still calls `onOpen(id)`; AppShell routes by kind (3.43e).

**Uses.** As 3.28, plus Core `RoomRecord.supersededBy` (CR-7).

**Must NOT do.** As 3.28; never decide mode availability here (AppShell passes it); never route by project kind (AppShell does).

**Copy strings.** Existing only: `Copy.HomeUI.comingLater`; reasons arrive as text from AppShell (`Copy.Errors.objectUnsupported.title`, `Copy.Errors.noLidar.title`).

**Self-test.** At least 6 new checks: House, Object and Quick Measure enabled when in the set; a disabled Object with a reason shows that reason as `note`; a disabled Advanced without a reason shows `Copy.HomeUI.comingLater`; an enabled entry has no note; a House with 3 rooms, one superseded, reads "2 rooms, {date}"; a superseded `.needsRescan` room gives no needs-work badge.

**Acceptance checks.** The picker shows five modes with House, Object and Quick Measure usable on the test phone (MODE-02, MODE-03); House rows count active rooms.

**SPEC owned.** "SCANNING MODES" (ROOM, HOUSE / BUILDING, OBJECT, QUICK MEASURE selectable).

**TEST_PLAN ids.** MODE-01, MODE-02, MODE-03, PROJ-01.

### 3.43d ExportUI revision (wave 5c)

**Purpose.** Exports for the build 5 project kinds and sizes: House projects (clean USDZ through RoomPlan's `CapturedStructure.export` when the automatic merge holds and nothing was edited, else our USDZ of the edited House clean model; raw and textured meshes of every active room placed with its alignment; plans with one PDF page per floor and one SVG, DXF or PNG per floor zipped), Object projects (Object Capture's USDZ as produced for small and medium objects; the untextured object mesh as USDZ for large ones; the dimensions as JSON), Quick Measure projects (the measurements as JSON), user measurements in every summary JSON when Include measurements is on, and progress with Cancel for long exports (EXP-09: no half file is left).

**Build and wave.** Build 5, wave 5c (branch `impl/exportui-b5`). Build 4 dependencies plus Structure (5a: `StructureStore`, `StructureAlignment`), ObjectCapture (5a: `PhotogrammetryStore`), ObjectModel (5a: `ObjectModelStore`, `ObjectExportAdapter`, `ObjectDimensionsRecord`), LiveMeasure (5a: `QuickMeasureStore`), Core CR-7; PDFKit. About 450 lines of changes.

**Files.** Edits: `ExportCatalog.swift`, `ExportRunner.swift`, `ExportAdapters.swift`, `ExportSummaryJSON.swift`, `ExportSheet.swift`, `ExportUISelfTest.swift`, `Copy+ExportUI.swift`. New: `ExportHouse.swift` (House scenes and plan pages), `ExportObject.swift` (object and Quick Measure outputs), `ExportPDFPages.swift`, `ExportUISelfTest+B5.swift`.

**Public Swift API** (additions and changed declarations).
```swift
/// (changed) `.object`: a scanned object's model (Object projects only).
enum ExportRepresentation: String, CaseIterable, Identifiable, Sendable {
    case realistic, clean, raw, floorPlan, data, object
    var id: String { rawValue }
}
struct ExportInputs: Equatable, Sendable {
    // build 4 fields unchanged, plus:
    var kind: ScanMode = .room
    /// Plan levels with rooms or walls.
    var levelCount = 1
    /// House: a merged structure (merge.json outcome `merged`, structure.json present) and no active edit.
    var structureExportable = false
    /// House: every active room has `TextureStore.exists`.
    var allRoomsTextured = false
    /// Object: model.usdz (small and medium) or the object mesh (large) exists.
    var hasObjectModel = false
    var hasObjectDimensions = false
    /// Saved measurements (measurements.json, or Quick Measure's raw file).
    var measurementCount = 0
}
extension ExportCatalog {
    /// (changed) By `inputs.kind`. Room and advancedSpace: as build 4. House: realistic usdz, obj, glb
    /// (reason `Copy.ExportUI.colorNotReady` unless `allRoomsTextured`, `Copy.Export.noColor` without
    /// keyframes), clean usdz, obj, glb, raw usdz, obj, ply, stl, glb, floorPlan pdf, svg, dxf, png,
    /// data json. Object and advancedObject: object usdz (reason `Copy.ExportUI.objectNotReady` until
    /// `hasObjectModel`), data json (same reason until `hasObjectDimensions`). Quick Measure: data json
    /// only (reason `Copy.Empty.noMeasurements.title` with no measurement).
    static func options(for inputs: ExportInputs) -> [ExportOption]
    /// (added overload; the build 4 `fileName(project:option:date:)` is this with `level: nil`) `level`
    /// (1-based) adds `Copy.ExportUI.levelSuffix(level)` before the extension of plan files of a
    /// multi-level plan; DXF keeps "_mm".
    static func fileName(project: String, option: ExportOption, date: Date, level: Int?) -> String
    /// `Copy.Modes.object` for `.object`; the build 4 labels otherwise.
    static func sectionTitle(_ representation: ExportRepresentation) -> String
}
/// House and multi-level outputs (`ExportHouse.swift`).
enum ExportHouse {
    /// One drawing per plan level with rooms or walls, in level order, with the result screen's toggles
    /// (EXP-05) and the level's title (`PlanLevel.name`, else `Copy.House.floorLabel(id + 1)`).
    static func planDrawings(_ package: ProjectPackage, prefs: UnitPreferences, toggles: PlanToggles) throws
        -> [(level: Int, title: String, plan: Plan2D)]
    /// Whole-house triangle budget of the binary raw formats (PLY, STL, GLB), whose build 4 rule
    /// (always the full measured mesh) would hold every room's full mesh at once on a 6 GB phone.
    static let maxBinaryTriangles = 2_000_000
    /// Per-room limit that keeps a house inside one budget: `max(50_000, total / rooms)`.
    static func perRoomLimit(total: Int, rooms: Int) -> Int
    /// Every active room's measured mesh (full, or the view mesh plus the inferred mesh above the
    /// room's limit, as build 4), placed with `StructureStore.placementMatrices` (rooms without an
    /// entry are left out, logged); one ExportMesh per room, named by its room title. `maxTextTriangles`
    /// is the whole-house budget: `ExportCatalog.textTriangleLimit` for OBJ and USDZ,
    /// `maxBinaryTriangles` for the binary formats, split with `perRoomLimit`. Rooms are read one at a
    /// time; each room's intermediates are released before the next.
    static func rawScene(_ package: ProjectPackage, manifest: ProjectManifest, alignments: [UUID: RoomAlignmentRecord],
                         maxTextTriangles: Int) throws -> ExportScene
    /// Every active room's `ExportAdapters.texturedScene` placed like `rawScene`, materials concatenated.
    static func texturedScene(_ package: ProjectPackage, manifest: ProjectManifest,
                              alignments: [UUID: RoomAlignmentRecord]) throws -> ExportScene
    /// A scene moved by a rigid transform: positions by the matrix, normals by its rotation, texcoords kept.
    static func transformed(_ scene: ExportScene, by matrix: simd_float4x4) -> ExportScene
    /// Clean USDZ of a House: `CapturedStructure.export(to:metadataURL:modelProvider:exportOptions: [.mesh])`
    /// into `folder` (with a `.plist` metadata URL next to it, never shared) when `structureExportable`,
    /// else nil (the caller writes `USDZWriter` of `ExportAdapters.cleanScene` of the edited model).
    static func structureUSDZ(_ package: ProjectPackage, into folder: URL, fileName: String) throws -> URL?
}
/// Object and Quick Measure outputs (`ExportObject.swift`).
enum ExportObject {
    /// Small and medium: a copy of `PhotogrammetryStore.modelURL(_:object:)` named `fileName` in `folder`.
    /// Large: `USDZWriter.data(for: ObjectExportAdapter.scene(mesh, name:))` of `ObjectModelStore.loadMesh`.
    static func objectUSDZ(_ package: ProjectPackage, object: ObjectRecord, into folder: URL, fileName: String) throws -> URL
}
/// Joins single-page PDFs into one document in order (PDFKit).
enum ExportPDFPages { static func merge(_ pages: [Data]) throws -> Data }
extension ExportSummaryJSON {
    /// (build 4, unchanged) The summary with a "measurements" array (kind, name, value in SI units and
    /// radians, sigma, provenance, points, snaps, source, createdAt); listed because House projects use it.
    static func data(model: CleanModel, evidence: [UUID: RoomEvidence], manifest: ProjectManifest,
                     measurements: [MeasurementRecord]) throws -> Data
    /// Quick Measure projects: project name and dates plus the measurements.
    static func measurementsData(_ records: [MeasurementRecord], manifest: ProjectManifest) throws -> Data
    /// Object projects: each object's dimensions (width, height, depth, surface area, volume or the
    /// unavailable reason, box) and the project name and dates.
    static func objectData(_ dimensions: [UUID: ObjectDimensionsRecord], manifest: ProjectManifest) throws -> Data
}
extension ExportRunner {
    /// (changed) As build 4 plus `progress` (0...1, called on main at each stage: load, build, write,
    /// zip; the default ignores it, so build 4 call sites compile). Cancellation stays as in build 4 (the
    /// task is checked between stages, now also between plan levels; a cancelled run removes its
    /// staging folder and throws `CancellationError`).
    static func run(_ option: ExportOption, settings: ExportSettings, viewState: ExportViewState, projectID: UUID,
                    package: ProjectPackage, prefs: UnitPreferences,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL
}
```

**Rules.**
- Inputs: `kind` from the manifest; House alignments from `StructureStore.effectiveAlignments(package)`; active rooms are CR-7 `supersededBy == nil`; `structureExportable` from `StructureStore.loadReport(package).merge?.outcome == .merged`, `StructureStore.loadStructure` not nil, and `EditStore.load(package).active` empty; `measurementCount` from `EditStore.loadMeasurements`, or `QuickMeasureStore.load(package)?.records` when `measurements.json` does not exist.
- Plans: a single level exports as build 4. With several levels: PDF writes one page per level with `PDFPlanWriter.data(for:options:)` (the level title in the plan name) and joins them with `ExportPDFPages.merge`; SVG, DXF and PNG write one file per level (`fileName(... level:)`) and zip them with `ZipWriter.archive`.
- House clean USDZ: `ExportHouse.structureUSDZ` or `USDZWriter` of `ExportAdapters.cleanScene(edited House model, includeHidden:, includeMovable: !viewState.hideFurniture)`. House raw and realistic: `ExportHouse.rawScene` (budget `ExportCatalog.textTriangleLimit` for OBJ and USDZ, `ExportHouse.maxBinaryTriangles` for PLY, STL and GLB, both for the whole house) and `texturedScene` with the build 4 writers; the simplified note (`Copy.ExportUI.simplifiedNote`) shows whenever a room fell back to its view mesh.
- Object projects export their first object (a second one is logged and left out in build 5).
- Summary JSON keeps passing the project's measurements when `settings.includeMeasurements` is on, as build 4 does (EXP-08 data side; CSV comes in build 6); House projects pass the edited House clean model.
- `ExportSheet` shows `ProgressView(value:)` with `Copy.Export.preparing` while a run is active, a Cancel button (`Copy.Project.cancel`) that cancels the run's task, and returns to the list after a cancel with no share sheet.

**Uses.** Structure: `StructureStore` (`loadStructure`, `loadReport`, `effectiveAlignments`, `placementMatrices`), `StructureMergeOutcome.merged`, `StructureAlignment.matrix`. ObjectCapture: `PhotogrammetryStore.modelURL(_:object:)`, `modelURLIfPresent(_:object:)`. ObjectModel: `ObjectModelStore` (`loadMesh`, `loadDimensions`), `ObjectExportAdapter.scene(_:name:)`, `ObjectDimensionsRecord`. LiveMeasure: `QuickMeasureStore.load(_:)`. Store: `EditStore` (`load`, `loadMeasurements`). FloorPlan: `PlanModelStore.loadEdited`, `PlanDrawing.make`, `RoomTitles`. Core: `ObjectRecord` (`size`), `ScanMode`, `RoomRecord.supersededBy` (CR-7), `RoomAlignmentRecord`, `MeasurementRecord`, `PlanLevel`. Export: `PDFPlanWriter`, `SVGWriter`, `DXFWriter.data(for:millimeters:unitsNote:)`, `USDZWriter`, `ZipWriter.archive`, `ExportScene`, `ExportMesh`. Support: `Copy.Modes.object`, `Copy.House.floorLabel(_:)`, `Copy.Export.preparing`, `Copy.Project.cancel`, `Copy.Empty.noMeasurements`.

**Apple APIs.** RESEARCH 3.2: `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedStructure.ModelProvider? = nil, exportOptions: CapturedStructure.USDExportOptions = .mesh) throws` (the only form on `CapturedStructure`, iOS 17.0). Not in RESEARCH: PDFKit `PDFDocument(data:)`, `page(at:)`, `insert(_:at:)`, `pageCount`, `dataRepresentation()` (iOS 11.0); `FileManager.copyItem(at:to:)` (iOS 2); `Task.checkCancellation()` (iOS 13).

**Must NOT do.** Never call `CapturedStructure.export(to:exportOptions:)` (it does not exist; 4-argument form only); never export a superseded room; never use `MDLAsset.export` for USD; never leave a staging folder after a cancel or a failure; never write outside `exports/`; never share a folder (zip first); no hardcoded text.

**Copy strings.** Existing as listed. New in `Copy+ExportUI.swift` (`extension Copy.ExportUI`): `objectNotReady = "Not available yet: the model is still being built"`, `static func levelSuffix(_ n: Int) -> String { "Floor\(n)" }`, `objectDetail = "The scanned object as a 3D model for iPhone, iPad and Mac."`.

**Self-test.** At least 12 new checks (`ExportUISelfTest+B5.swift`): catalog of a House with `levelCount` 2 lists PDF, SVG, DXF, PNG and realistic unavailable until `allRoomsTextured`; catalog of an Object with and without a model; catalog of a Quick Measure project is JSON only, unavailable with no measurement; file names of level 2 contain `levelSuffix(2)` and DXF still ends "_mm.dxf"; `ExportPDFPages.merge` of two one-page PDFs (made with `PDFPlanWriter`) has 2 pages; `ExportHouse.transformed` moves positions and normals and keeps texcoords; `rawScene` of a temporary two-room House package with one superseded room has one mesh; `perRoomLimit(total: 600_000, rooms: 8)` is 75,000 and `perRoomLimit(total: 600_000, rooms: 20)` is 50,000; summary JSON with 2 measurements has `measurements.count == 2` and numbers as numbers; `measurementsData` and `objectData` parse with `JSONSerialization`; a cancelled run (a task cancelled before the write stage) leaves no staging folder; `sectionTitle(.object)` is `Copy.Modes.object`.

**Acceptance checks.** A whole House exports as USDZ and PDF in Airplane Mode with progress, and Cancel leaves no file (EXP-09); a multi-floor House PDF has one page per floor; an object exports its Object Capture USDZ, which opens in Quick Look (OBJ-02); a Quick Measure project exports its measurements as JSON.

**SPEC owned.** Deliverable 14 "Exportable professional files" for House, Object and Quick Measure projects; "2D FLOOR PLAN" output files for multi-floor plans; "OBJECT SCANNING" outputs (USDZ); "PROJECT SYSTEM" (export).

**TEST_PLAN ids.** EXP-01, EXP-05 (annotations and floors), EXP-06, EXP-07, EXP-08 (JSON part), EXP-09, EXP-10, OBJ-02, PLAN-05, smoke #11.

### 3.43e AppShell revision (wave 5d)

**Purpose.** The composition root for build 5: routes by project kind (room and house results, object results, Quick Measure results), the covers for House, Object (small and medium), Large Object and Quick Measure with processing suspended while any cover is up, the House cover's live coverage, minimap and missing-areas tour, the quality sheet's Show Missing Areas for rooms, House actions from Results (Continue Scanning, Rescan, Line Up by Hand, Join Rooms Again), processing plans for House and Object projects and for rooms with mesh passes, processing after edits that need it, a one-time upgrade pass that rebuilds build 4 clean models and plans with the build 5 rules, recovery of House rooms, mesh passes and objects, the mode availability passed to Home, and the Diagnostics toggle of the live mesh debug view.

**Build and wave.** Build 5, wave 5d (branch `impl/appshell-b5`). Every build 4 and build 5 module. Still the only editor of `ContentView.swift` and `MapperApp.swift`. About 700 lines of changes.

**Files.** Edits: `AppRootView.swift`, `AppRouter.swift`, `AppScanCoordinator.swift` (quality sheet button), `AppResultsCoordinator.swift`, `AppProcessingPlans.swift`, `AppRecovery.swift`, `AppDiagnosticsScreen.swift`, `AppShellSelfTest.swift`. New: `AppCovers.swift` (`AppCover`, `AlignRequest`, `AppCapabilities`), `AppHouseCoordinator.swift`, `AppObjectCoordinators.swift` (object, large object and Quick Measure covers), `AppProcessingPlans+B5.swift` (house and object plans, edits, upgrade), `AppShellSelfTest+B5.swift`.

**Public Swift API** (additions and changed declarations).
```swift
/// (changed) Routes by project kind.
enum AppRoute: Hashable { case result(UUID), object(UUID), measurements(UUID), settings, diagnostics }
/// The one full-screen cover (replaces build 4's `scanRequest: ScanRequest?`; `ScanRequest` is kept for rooms).
enum AppCover: Identifiable, Equatable {
    case room(ScanRequest)
    case house(HouseScanRequest)
    case object(id: UUID, isDemo: Bool)
    case largeObject(id: UUID)
    case quickMeasure(id: UUID)
    var id: UUID { get }
}
/// Drives the Line Up by Hand sheet.
struct AlignRequest: Identifiable, Equatable { let id: UUID; var projectID: UUID; var roomID: UUID }
@MainActor final class AppRouter: ObservableObject {
    @Published var path: [AppRoute]
    @Published var cover: AppCover?
    @Published var exportRequest: ExportRequest?
    @Published var alignRequest: AlignRequest?
    /// (changed) room -> `.room`, house -> `.house(.newProject)`, object -> `.object`, quickMeasure ->
    /// `.quickMeasure`; Demo Mode (`SettingsKey.demoMode`) for room, house and object.
    func startScan(_ mode: ScanMode)
    /// (changed) Pushes `route(for:id:)` of the project's kind.
    func openResult(_ id: UUID)
    /// Results' House actions: continueScanning -> `.house(.continueProject(id))`, rescan(room) ->
    /// `.house(.rescan(project:room:))`, lineUp(room) -> `alignRequest`, joinAgain -> enqueue at the front.
    func houseAction(_ action: ResultHouseAction, projectID: UUID)
    /// room, house, advancedSpace -> `.result`; object, advancedObject -> `.object`; quickMeasure -> `.measurements`.
    nonisolated static func route(for kind: ScanMode, id: UUID) -> AppRoute
}
enum AppCapabilities {
    /// Pure. Room and House need LiDAR and RoomPlan; Object needs Object Capture (reason
    /// `Copy.Errors.objectUnsupported.title`); Quick Measure needs LiDAR (reason `Copy.Errors.noLidar.title`);
    /// in Demo Mode Room, House and Object are available on any device; Advanced stays off without a reason
    /// (Home shows "Coming in a later version").
    static func modes(lidar: Bool, roomPlan: Bool, objectCapture: Bool, demo: Bool)
        -> (available: Set<ScanMode>, reasons: [ScanMode: String])
    /// From the Diagnostics probe checks and `SettingsKey.demoMode`.
    @MainActor static func current() -> (available: Set<ScanMode>, reasons: [ScanMode: String])
}
/// House cover (see Rules).
struct AppHouseCoordinator: View { init(request: HouseScanRequest, onFinished: @escaping (UUID?) -> Void) }
/// Object cover: `ObjectFlowScreen(model: ObjectFlowModel(isDemo:))`; `onLargeObject` calls `onLarge`.
struct AppObjectCoordinator: View {
    init(isDemo: Bool, onLarge: @escaping () -> Void, onFinished: @escaping (UUID?) -> Void)
}
/// Large object cover: `ScanPreflight.run(mode: .object, isDemo: false)` (async; camera access and
/// other blocking issues as in the Rules, *Permission*), `LargeObjectTarget.makeNew(now:)`, `LargeObjectModel(target:)`,
/// `start()`, `LargeObjectScreen(model:onViewReady:)` whose hook attaches
/// `CoverageOverlayRenderer(source: model.coverage, thermal: model.scan.engine.hub.thermal)`.
struct AppLargeObjectCoordinator: View { init(onFinished: @escaping (UUID?) -> Void) }
/// Quick Measure cover: `ScanPreflight.run(mode: .quickMeasure, isDemo: false)` (camera access and other
/// blocking issues as in the Rules, *Permission*), then `LiveMeasureModel()`,
/// `start()`, `LiveMeasureScreen(model:)`; `onComplete` routes to `.measurements`; never enqueues.
struct AppQuickMeasureCoordinator: View { init(onFinished: @escaping (UUID?) -> Void) }

extension ProcessingPlans {
    /// Bumped when derived rules change; 5 = RoomModel "cleanModel-rules=2" and FloorPlan "planBuilder-rules=2".
    static let rulesVersion = 5
    /// By kind: room and advancedSpace `roomSteps`, house `houseSteps`, object and advancedObject
    /// `objectSteps`, quickMeasure none.
    static func steps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// (changed) With mesh passes (CR-10): `ConsolidateMeshStep(roomID:folders: roomFolders(room:package:))`,
    /// `QualityStep(room:passes: MeshPassFolders.forRoom(room.id, in:))`, `TextureLowStep(room:folders: roomFolders)`.
    static func roomSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// The room's raw folder (`CapturedRoomStore.rawFolder`) followed by its sealed mesh passes.
    static func roomFolders(room: RoomRecord, package: ProjectPackage) -> [RawScanFolder]
    /// House (active rooms, `StructureEligibility.activeRooms`): per room BuildRoomStep (optional, build 4
    /// conditions), `MergeStructureStep()` (optional), `AlignRoomsStep()` (optional), per room
    /// ConsolidateMeshStep (optional, with passes), `HouseCleanModelStep(meshProvider: { package, room in
    /// try? MeshModelStore.loadMeasured(package, room: room) })` (required, depends on the rooms' buildRoom
    /// steps), `FloorPlanStep(floors: [])` (required, depends on cleanModel), per room QualityStep
    /// (optional, with passes), ThumbnailStep (optional, depends on floorPlan), per room TextureLowStep (optional).
    static func houseSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// Small and medium: `PhotogrammetryStep(object:)` (required), `ObjectMetricsStep(object:modelFile:
    /// { p, id in PhotogrammetryStore.modelURLIfPresent(p, object: id) }, reportedExtents: { p, id in
    /// PhotogrammetryStore.loadInfo(p, object: id)?.boundsExtents })` (required, depends on
    /// reconstructObject), ThumbnailStep (optional, depends on objectMetrics). Large:
    /// `ConsolidateMeshStep(roomID: object.id, folders: [RawScanFolder(url: package.rawObjectURL(object.id))])`
    /// (required), ObjectMetricsStep (required, depends on consolidateMesh), ThumbnailStep (optional).
    static func objectSteps(manifest: ProjectManifest, package: ProjectPackage) -> [ScheduledStep]
    /// Demo projects: no room raw folder holds capturedroomdata.json, capturedroom.json,
    /// capturedroom-live.json or keyframes.jsonl, and no small or medium object holds photos.
    static func isDemoProject(_ manifest: ProjectManifest, package: ProjectPackage) -> Bool
    /// What an edit needs (pure): `.none` for Quick Measure, `.capturing`, demo and running projects;
    /// `.thumbnail` for room projects with a plan; `.full` for House and Object projects.
    static func afterEditPlan(manifest: ProjectManifest, package: ProjectPackage, isRunning: Bool) -> AfterEditPlan
    /// Debounced 2 s per project after `.mapperEditsDidChange`: `.full` enqueues `steps` (fresh steps are
    /// skipped, so the House clean model reruns only when its alignment digest changed); `.thumbnail`
    /// enqueues a job with only an optional ThumbnailStep and changes no status.
    @MainActor static func enqueueAfterEdit(projectID: UUID)
    /// Once per `rulesVersion` (`SettingsKey.processingRulesVersion`), after `resumePending`: enqueues every
    /// `.ready` room and house project that is not a demo (atFront false), so build 4 clean.json and
    /// plan.json are rebuilt with the build 5 rules (3.37b, 3.37c).
    @MainActor static func upgradeIfNeeded(defaults: UserDefaults = .standard)
}
enum AfterEditPlan: Equatable, Sendable { case none, thumbnail, full }
extension SettingsKey { static let processingRulesVersion = "processingRulesVersion" }   // Int
```

**Rules.**
- *Covers.* `cover` drives one `.fullScreenCover(item:onDismiss:)`; `ProcessingRunner.shared.suspendAll(reason: "capture")` when it becomes non-nil, and `resumeAll()` in `onDismiss` when `cover` is nil (build 4 rule, now for every cover): `onDismiss` runs after the content is gone, so a finished capture's `ARView` or `ObjectCaptureView` is released before any step runs, and a switch from `.object` to `.largeObject` keeps processing suspended. `suspendAll` only flags the running step, and a `PhotogrammetrySession` finishes cancelling asynchronously, so every coordinator first awaits `ObjectCaptureActivity.waitForNoReconstruction(timeout: 30)` (showing `Copy.Scanning.startingUp`, logged) before its flow's first step (preflight); on a timeout it shows `Copy.Errors.generic` and closes. `.room`: the build 4 `AppScanCoordinator`, whose `QualitySheet` now gets `onShowMissingAreas: model.canShowMissingAreas ? { model.showMissingAreas() } : nil` (ScanUI 3.43a hosts the tour inside `RoomScanScreen`). `.object`: `AppObjectCoordinator`; Large switches the cover to `.largeObject` (a new id). Each coordinator's `onComplete(projectID)` enqueues the kind's plan with `atFront: true` (never for Quick Measure) and pushes `route(for:id:)`; `onDismiss` closes the cover.
- *House cover.* `HouseFlowModel(request:)` with `captureExtras = { mesh in let extras = ScanCaptureExtras.coverage(meshStore: mesh); return (extras.recorders, extras.install) }`; `HouseScanScreen(model:)` with `ScanCoverageHUD(snapshot: model.snapshot)` over it while capturing; `onShowMissingAreas` builds `MissingAreasTarget(projectID:, package:, room: the finished room's record, evaluation: model.evaluation, mode: .house, settings:, hub:)` with `model.roomEngine?.hub` (no tour without an engine) and shows `ScanTourLayer(model:)` above the house screen (the room view stays mounted underneath); the tour's `onFinished` calls `model.refreshEvaluation(evaluation, stoppedBySystem: tour.stoppedBySystem)` (nil keeps the old evaluation), tears the tour model down and removes the layer; `onShowMissingAreas` is set on every House model, and HouseUI offers the button only when `model.canShowMissingAreas` and hides its sheet while `model.isTourActive` (3.41).
- *Permission* (Large Object and Quick Measure covers, which have no permission phase of their own): a blocking `.cameraUndetermined` shows ScanUI's `ScanPermissionScreen(isRequesting:onContinue:onCancel:)`; Continue calls `AVCaptureDevice.requestAccess(for: .video)`, granted continues the flow, denied shows `ScanErrorCopy.alert(for: .cameraDenied)` (Open Settings) and closes; any other blocking issue shows `ScanErrorCopy.preflightAlert(for:)` and closes. Without this a first-time user who picks Large or Quick Measure before any other scan would hit a dead end.
- *Routes.* `.result(id)`: `ResultScreen(projectID:onExport:onRetry:onHouseAction: { router.houseAction($0, projectID: id) })`. `.object(id)`: `ObjectResultScreen(projectID:onExport: { exportRequest = ExportRequest(id: UUID(), projectID: id, viewState: .standard) }, onRetry: { ProcessingPlans.retry(projectID: id) })`. `.measurements(id)`: `QuickMeasureResultScreen(projectID:onExport:)` with the same export request. Line Up by Hand: `.sheet(item: $router.alignRequest) { AlignRoomsScreen(projectID:roomID:onDone:) }`, a save (`onDone(true)`) enqueues the House plan at the front. Join Rooms Again: HouseUI clears the crashed attempt, AppShell enqueues at the front.
- *Home.* `HomeScreen(library:runner:availableModes:unavailableReasons:onNewScan:onOpen:onSettings:)` with `AppCapabilities.current()`; `onOpen` calls `router.openResult`. A device without LiDAR still shows `Copy.Errors.noLidar` on New Scan outside Demo Mode (build 4 rule).
- *Processing.* `enqueue(projectID:atFront:)` uses `steps(manifest:package:)`; on `.completed`: room and house projects set active `.captured` rooms to `.processed` (`.needsRescan` stays) and the project `.ready`; object projects set the object `.processed` and the project `.ready`; `.failed` and `.cancelled` as build 4. `resumePending` also resumes Object projects with `reconstructionPending`. `AppRootView` observes `.mapperEditsDidChange` and calls `enqueueAfterEdit`; launch runs `upgradeIfNeeded()` after `resumePending()`.
- *Recovery* (`RecoveryService`): an InProgress scan of kind `.meshPass` is sealed into `rawMeshPassURL(session:pass:)`, its room gets `hasMeshPass`, and the project is enqueued; for an `.object` scan the object id is scan.json `roomID` (both object drivers write it, 3.32 and 3.33; `scanID` as a fallback), and a folder holding `Images/` (`ObjectScanFolders.imagesURL`) is a small or medium object: offered only when `ObjectScanFolders.canRecover`, Keep seals it with `ObjectScanFolders.seal`, appends the `ObjectRecord` (`.captured`, image count), sets `reconstructionPending` and enqueues; any other `.object` folder is a large object, sealed into `rawObjectURL(_:)` with an `ObjectRecord` of size `.large` (without its crop edit ObjectMetricsStep reports "no crop box", so the result shows the failure honestly); a House room (`mode == .house`) is recovered like a Room room with its session's frame link and the floor of the latest room. A `.capturing` Quick Measure project (killed during Save, 3.36) becomes `.ready` when `raw/measure/quick.json` exists and is deleted when it does not; a `.ready` one is never touched.
- *Diagnostics.* A toggle for `SettingsKey.liveMeshDebugView` with `Copy.LiveMeshView.debugViewToggle` and `debugViewFooter`; the suite list gains the build 5 self-tests (lead-owned lines).

**Uses.** Every build 5 screen type named above: HouseUI (`HouseFlowModel` with `captureExtras`, `onShowMissingAreas`, `canShowMissingAreas`, `isTourActive`, `refreshEvaluation(_:stoppedBySystem:)`, `roomEngine`, `evaluation`, `onComplete`, `onDismiss`; `HouseScanScreen`, `HouseScanRequest`, `HouseScanStart`, `AlignRoomsScreen`), ObjectUI (`ObjectFlowModel`, `ObjectFlowScreen`, `ObjectResultScreen`), LargeObject (`LargeObjectTarget.makeNew(now:)`, `LargeObjectModel`, `LargeObjectScreen`), LiveMeasure (`LiveMeasureModel`, `LiveMeasureScreen`), MissingAreas (`MissingAreasTarget`, `MissingAreasModel`), CoverageOverlay (`CoverageOverlayRenderer`), ScanUI (`ScanCaptureExtras`, `ScanCoverageHUD`, `ScanTourLayer`, `ScanPreflight`, `ScanErrorCopy`, `ScanFlowModel.canShowMissingAreas`, `showMissingAreas()`), Results (`ResultScreen`, `ResultHouseAction`, `QuickMeasureResultScreen`), HomeUI (`HomeScreen` with `unavailableReasons`), QualityUI (`QualitySheet(evaluation:onFinish:onDiscard:onShowMissingAreas:)`), ExportUI (`ExportSheet`), Structure (`StructureEligibility.activeRooms`, `MergeStructureStep`, `AlignRoomsStep`, `HouseCleanModelStep`), ObjectCapture (`PhotogrammetryStep`, `PhotogrammetryStore`, `ObjectScanFolders` (`canRecover`, `seal`, `imagesURL`), `ObjectCaptureActivity.waitForNoReconstruction(timeout:)`), ScanUI permission pieces (`ScanPermissionScreen(isRequesting:onContinue:onCancel:)`, `ScanErrorCopy.preflightAlert(for:)`, `PreflightIssue`), ObjectModel (`ObjectMetricsStep`), LiveMeshView (`MeshPassFolders.forRoom(_:in:)`), Quality (`QualityStep(room:passes:)`, CR-10), and the build 4 symbols of 3.29.

**Apple APIs.** As 3.29, plus `.fullScreenCover(item:onDismiss:content:)` (iOS 14) and `AVCaptureDevice.requestAccess(for: .video)` (not in RESEARCH, iOS 7).

**Must NOT do.** As 3.29; never run processing while any cover is up, and never resume it before the cover's content is gone; never enqueue Quick Measure or demo projects (the upgrade and edit rules check `isDemoProject`); never keep two covers at once; no business logic of a feature module (flows stay in their modules); no hardcoded text.

**Copy strings.** Existing: `Copy.Errors.objectUnsupported`, `noLidar`, `Copy.LiveMeshView.debugViewToggle`, `debugViewFooter`, `Copy.AppShell.*` (3.29). New: none.

**Self-test.** At least 16 new checks (`AppShellSelfTest+B5.swift`): `route(for:)` for every `ScanMode`; `AppCapabilities.modes` without Object Capture disables Object with its reason, without LiDAR outside Demo Mode disables Quick Measure with its reason, in Demo Mode enables Room, House and Object, and never enables Advanced; `houseSteps` for a two-room House with one superseded room lists steps for one room only, in the order above, with `dependsOn` of cleanModel and floorPlan; `objectSteps` for a small object (reconstructObject then objectMetrics) and a large one (consolidateMesh with subject = object id, then objectMetrics); `roomFolders` of a temporary package with one sealed mesh pass returns 2 folders and ignores an unsealed pass; `steps` of a Quick Measure project is empty; `isDemoProject` true for a `DemoProjectFactory` package and false once `capturedroomdata.json` exists; `afterEditPlan` for each kind, for `.capturing`, running and demo projects; the upgrade decision runs once per `rulesVersion`; the Quick Measure recovery rule sets a `.capturing` project with quick.json `.ready` and deletes one without it; an `.object` InProgress folder with `Images/` is classified small or medium and one without is large, with the object id read from `roomID`.

**Acceptance checks.** New Scan starts all four modes on the test phone; each cover closes on finish and on cancel, and no job runs while one is up; House finishing opens the result with "Joining rooms together..."; the Rooms screen's actions open the right covers and sheets; an object opens its result screen, a Quick Measure its list; a build 4 project is rebuilt once after the update and then opens in the plan editor with no locked walls; force quits during House, object and patch-pass captures offer recovery (PERF-26).

**SPEC owned.** "SCANNING MODES" (all four modes reachable, sensible defaults); "HOUSE / BUILDING MODE" (entry, return to incomplete sections and manual correction wiring); "OBJECT SCANNING" (entry and results); "SCAN QUALITY SYSTEM" (Show Missing Areas for House rooms); "PROJECT SYSTEM" (every project kind opens and resumes processing); "LOCAL-FIRST ARCHITECTURE" (everything offline).

**TEST_PLAN ids.** MODE-02, MODE-03, MODE-06, HOUSE-01 to HOUSE-09, OBJ-01, OBJ-09, QUAL-03 (House rooms), PERF-03, PERF-25, PERF-26, PERF-27, OFF-01, smoke #6, #9, #10.

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
- HouseUI (6a) and AppShell (6c): the D16 detail pass for House rooms whose log says `meshStripped` (not offered in build 5, 3.41): HouseFlowModel gains a hook between `.roomFinished` and the quality check, AppShell shows ScanUI's `ScanDetailPassLayer` over `HouseScanScreen` on the room engine's hub, and the check then runs with the room's mesh-pass folders (CR-10).
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
| Multiple connected rooms; entire houses and buildings | HouseUI (room by room, relocalization, manual alignment), Structure (merge, alignment, floors, shared walls, House clean model) | 5 |
| Commercial spaces, restaurants, offices | HouseUI (room by room) | 5; very large open areas SpaceScan 7 |
| Warehouses; outdoor structures when technically possible | AdvancedScan (space without rooms, LiveMeshView driver) | 6; SpaceScan 7 |
| Furniture, appliances, equipment, boxes, small and medium objects, arbitrary objects | ObjectUI (size chooser, result), ObjectCapture (guided capture, reconstruction), ObjectModel (measurements) | 5 |
| Vehicles, large appliances and equipment | LargeObject (LiDAR mesh driver, tapped seed, gravity-aligned box, side guidance), ObjectModel (`ObjectIsolation` from the crop edit), ObjectUI (result) | 5 |
| Use both LiDAR geometry and camera imagery whenever possible | CaptureCore, MeshRecord, Keyframes | 4 |
| Usable by an amateur, advanced functionality available | Copy voice rules everywhere; AdvancedScan | 4; 6 |
| 1 Realistic textured 3D model | TextureJob (Textured), Results | 4; Photo Realistic 6; objects 5 (ObjectCapture `PhotogrammetryStep`, Viewer3D `loadModel`) |
| 2 High-detail LiDAR mesh | MeshRecord, MeshModel, Results (Raw Scan) | 4 |
| 3 Clean architectural 3D model | RoomModel, Viewer3D, Results | 4 |
| 4 2D floor plan | FloorPlan, Results | 4 |
| 5 Measurements | MeasureCore, Results (4); MeasureTool in the model, LiveMeasure live, Results (measurement list, Quick Measure result) (5) | 4; 5 |
| 6 Object dimensions | Results object card with MeasureCore `objectRows` (room objects, with confidence); ObjectModel `ObjectDimensions` with confidence, ObjectUI (scanned objects) | 4; 5 |
| 7 Room dimensions; 9 floor area; 10 ceiling height | RoomModel, MeasureCore, Results | 4 |
| 8 Surface area | room and per-wall area in MeasureCore (4, openings not counted, stated in the panel); MeasureTool Area tool, ObjectModel surface area (5) | 4; 5 |
| 11 Distance measurements | MeasureTool (Distance and Height tools), LiveMeasure | 5 |
| 12 Images and photos associated with scanned locations | Keyframes (capture, poses), ScanUI Take Photo; PhotoBrowser (browse) | 4; 7 |
| 13 Editable detected objects | Hide Furniture (4); PlanEditor move, turn, delete and change category of furniture and fixtures, Results Change Category (5); EditMenus rename, rotate, show raw (7) | 4; 5; 7 |
| 14 Exportable professional files | ExportUI (4); House, Object and Quick Measure exports and multi-floor plans (ExportUI revision 3.43d, 5); remaining formats 6 | 4; 5; 6 |

### 4.2 CORE DESIGN PRINCIPLE

| Requirement | Owner | Build |
|---|---|---|
| Multiple representations of the same scan | Store package layout (raw, derived, edits) | 4 |
| A: LiDAR mesh; ARKit anchors; world transforms | MeshRecord (anchor-local chunks with transforms, D8) | 4 |
| A: camera poses; timestamps; device orientation | Keyframes (10 Hz pose track, keyframe poses) | 4 |
| A: camera frames where permitted; depth; confidence; calibration | Keyframes (JPEG, Float16 depth plus confidence, intrinsics per keyframe) | 4 |
| A: feature points; detected planes | Feature points: the ARWorldMap at Done (mesh anchors stripped) in every room folder (RoomCapture, 4), reused by HouseUI to relocalize later sessions and referenced by `CaptureSessionRef.worldMapFile` (5); not recorded per frame (unstable, RESEARCH 3.8 gotcha 21). Planes: RoomPlan's surfaces in `capturedroomdata.json` (4); ARKit plane anchors are not recorded because plane detection flattens the raw mesh (D14); Quick Measure uses them live for snapping and records none (LiveMeasure, 5) | 4; 5 |
| A: never destroy the original raw scan | Store (sealed folders D5, no thinning D6), every module's "Must NOT do" | 4 |
| B: LiDAR geometry plus RGB imagery, texture projection, texture blending | TextureJob with Texturing | 4 |
| B: photogrammetry where appropriate | ObjectCapture `PhotogrammetryStep` (on device, default detail) | 5 |
| B: mesh cleanup; hole filling where reasonable (flagged inferred); simplification | MeshModel with MeshProcessing | 4 |
| C: walls, floors, ceilings, doors, windows, openings, stairs where detectable, furniture, appliances, other recognized objects | RoomModel (RoomPlan categories, D12, D13) | 4 |
| C: counters, cabinets (beyond RoomPlan storage), columns, structural features | MeshRefine | 8 |
| D: 2D floor plan from the reconstructed geometry | FloorPlan | 4 |
| E: isolated object model | ObjectCapture (model), ObjectModel (measurements; `ObjectIsolation` for large objects), ObjectUI (display), LargeObject (capture) | 5 |

### 4.3 SCANNING MODES

| Requirement | Owner | Build |
|---|---|---|
| Large NEW SCAN button on the home screen | HomeUI | 4 |
| ROOM | ScanUI, RoomCapture | 4 |
| HOUSE / BUILDING | HouseUI, Structure; HomeUI (enabled, 3.43c), AppShell (cover, 3.43e) | 5 |
| OBJECT | ObjectUI (chooser), ObjectCapture (small, medium), LargeObject (large); HomeUI (enabled), AppShell (covers) | 5 |
| QUICK MEASURE | LiveMeasure (capture), HomeUI (enabled, 3.43c), AppShell (cover and route, 3.43e), Results (saved list, 3.43b) | 5 |
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
| Scan rooms separately and combine into one structure | HouseUI (room by room, Finish Building), Structure (`MergeStructureStep`, `HouseCleanModelStep`) | 5 |
| Preserve room relationships; maintain coordinate alignment | Structure (frame groups, least-squares placement, fallbacks, `effectiveAlignments`, D9); HouseUI with the CaptureCore revision (relocalized sessions) | 5 |
| Recognize shared walls | Structure `StructureWalls.sharedWalls` (thickness measured from wall pairs) | 5 |
| Detect doorways connecting rooms | Structure `StructureWalls.doorwayLinks` (each doorway drawn once) | 5 |
| Combine rooms into one building model | Structure `HouseCleanModelStep`, FloorPlan | 5 |
| Multiple floors when technically possible | HouseUI Add Floor, Structure `StructureFloors.assign`; stair links LevelsAndStairs | 5; 8 |
| Manual correction when automatic alignment fails | HouseUI `AlignRoomsScreen` with Structure `StructureSnapping`, `setRoomAlignment` edits | 5 |
| Progress such as "Kitchen done", "Hallway needs additional scan" | HouseUI `HousePresentation.rows` | 5 |
| Return to incomplete sections | HouseUI Rescan and Continue Scanning (relocalization), CR-7 supersede; Results Rooms screen (3.43b) | 5 |

### 4.6 OBJECT SCANNING

| Requirement | Owner | Build |
|---|---|---|
| Behave differently from architectural scanning | ObjectUI (size chooser D4, object-only result) | 5 |
| Guide the user around the object; "Move around the object slowly"; "Capture the top" | ObjectCapture (Apple's guided capture, three-pass onboarding, `higherHint`), GuidanceUI feedback mapping (small and medium); LargeObject `SectorCoverage` (large) | 5 |
| "Capture the left side", "Capture the back", "Move closer to this area", "This section needs more detail" | LargeObject `SectorCoverage` through the Coverage revision CR-9 | 5 |
| Separate the target object from its background | ObjectCapture (box selection, `isObjectMaskingEnabled`), LargeObject (seed region and box), ObjectModel (`ObjectIsolation` from the crop edit) | 5 |
| Camera images for textures | ObjectCapture `PhotogrammetryStep` | 5 |
| Textured mesh, untextured mesh, bounding box, width, height, depth, estimated volume where valid | ObjectModel (watertight volume only), ObjectUI (display), Viewer3D `loadModel`; LargeObject (capture box as a `cropObject` edit) | 5 |
| Manually crop unwanted geometry | ObjectCrop | 6 |

### 4.7 IMAGE / TEXTURE CAPTURE

| Requirement | Owner | Build |
|---|---|---|
| Realistic textures from the camera; not a gray mesh | TextureJob | 4 |
| Capture imagery associated with camera poses | Keyframes | 4 |
| Texture the reconstructed mesh | TextureJob, Viewer3D, ExportUI (4); objects keep Object Capture's own textures (ObjectCapture, Viewer3D `loadModel`, 5) | 4; 5 |
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
| See the model forming while walking | RoomCaptureView outlines and mini model (RoomCapture, 4); LiveMeshView plus CoverageOverlay (colored mesh in mesh-only scans, large objects and the missing-area tour, 5) | 4; 5 |
| GREEN, YELLOW, RED, GRAY | CoverageLive (states), CoverageOverlay (colored mesh in mesh-only views and the tour; minimap and legend in Room mode through the ScanUI revision 3.43a); HeadlessRoom (colored 3D overlay in Room mode) | 5; 7 |
| "Move slower", "Move closer", "Too close", "Too far", "Tracking quality is low", "Lighting is poor" | Room mode: RoomPlan's own coaching (`slowDown`, `moveCloseToWall`, `moveAwayFromWall`, `turnOnLight`) plus Mapper's `trackingLow`, `trackingLost` and `deviceHot` through `GuidanceFilter` (4); Mapper's texts from `GuidanceEngine` in mesh-only scans (LiveMeshView) and tier 1 in Quick Measure (LiveMeasure) (5) | 4; 5 |
| "Window detected", "Door detected", "Wall detected" | RoomCapture detection counts | 4 |
| "Scan this corner", "Point toward the floor", "Scan the ceiling", "This area needs another pass" | CoverageLive (`viewCoverage`, `nearbyMissing`), wired into room scans by the ScanUI revision (3.43a) and House rooms by AppShell (3.43e) | 5 |
| Do not overwhelm; only important instructions | GuidancePolicy in `GuidanceEngine`, `GuidanceFilter` | 4 |

### 4.9 SCAN QUALITY SYSTEM

| Requirement | Owner | Build |
|---|---|---|
| Scan-completeness system tracking coverage | Quality (recorded data; mesh-pass folders from CR-10); CoverageLive (live) | 4; 5 |
| SCAN QUALITY before finishing: Geometry (Shape), Walls, Floor, Ceiling, Textures, Missing areas | Quality, QualityUI | 4 |
| FINISH ANYWAY | QualityUI | 4 |
| SHOW MISSING AREAS guiding the user to them | QualityUI (button, 4); MissingAreas (tour on the same session, re-evaluation through CR-10); ScanUI revision 3.43a (room entry, return with new numbers); HouseUI and AppShell 3.43e (House rooms; processing of pass folders) | 4; 5 |

### 4.10 AUTOMATIC OBJECT RECOGNITION

| Requirement | Owner | Build |
|---|---|---|
| Detect table, chair, sink, toilet, refrigerator, oven, bed, sofa, TV, stairs, appliance (dishwasher, washer, stove) | RoomModel from RoomPlan categories (`ObjectCategory`) | 4 |
| Detect door, window, wall, floor, ceiling | RoomModel (surfaces; ceiling from mesh class, D13) | 4 |
| Detect cabinet, counter, desk, column | RoomPlan storage and table cover part of it (4); MeshRefine heuristics | 4; 8 |
| Allow the user to correct object labels | Results Change Category (the card then shows the name, not a guess) and PlanEditor Change Category (5); EditMenus relabel and the full object menu (7) | 5; 7 |
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
| Wall length, wall height, ceiling height, door width and height, window dimensions, room length, width, area, floor area, wall area, perimeter, estimated volume (room) | RoomModel, MeasureCore, Results (4); MeasureTool Wall and Height tools, merged and split room metrics in RoomModel (5) | 4; 5 |
| Object width, height, depth | Results object card (room objects); ObjectModel, ObjectUI (scanned objects) | 4; 5 |
| Point-to-point distance, angle, surface area | MeasureTool (Distance, Angle and Area tools in the model), LiveMeasure (distance in the live camera: existing points, plane corners and intersections, plane geometry, estimated plane) | 5 |
| Estimated volume (objects) | ObjectModel (closed meshes only, reason otherwise) | 5 |
| Feet and inches and metric; preference switching | Units, MeasureDisplay, AppShell Settings | 4 |
| Manually placed measurement points | MeasureTool (tap, then drag to adjust), LiveMeasure | 5 |
| Snapping to corner, wall, edge, floor, ceiling, door, window, object edge | MeasureCore `SnapSet` (logic, 4); MeasureTool (SnapSet then mesh vertex, "Snapped to" tag, haptic, toggle), LiveMeasure (5) | 4; 5 |

### 4.13 MEASUREMENT CONFIDENCE

| Requirement | Owner | Build |
|---|---|---|
| Show measurement confidence ("Estimated accuracy ±0.6\"") | MeasureCore, Results (4); MeasureTool, LiveMeasure, ObjectUI (5) | 4; 5 |
| "Low confidence, rescan this section" | MeasureCore `MeasureDisplay.isLowConfidence` (4); MeasureTool raises area and angle sigmas for weak evidence so the one rule flags them (5) | 4; 5 |
| Never imply survey-grade accuracy | MeasureCore (3 cm RoomPlan floor), `Copy.Measure.disclaimer` | 4 |
| Confidence for scanned objects | ObjectModel `ObjectDimensions.sigma`, shown by ObjectUI through MeasureDisplay | 5 |
| Calibrate with one known length | ReferenceLength (D21) | 6 |

### 4.14 2D FLOOR PLAN

| Requirement | Owner | Build |
|---|---|---|
| Automatic clean plan with walls, doors, windows, openings, room names, room dimensions, overall dimensions, fixtures, stairs, bathroom fixtures, kitchen equipment | FloorPlan | 4 |
| Wall thickness where determinable | FloorPlan (estimated, outer face dashed on A-WALL-EST, 4); Structure `StructureWalls` (measured from wall pairs, estimated exterior, 5) | 4; 5 |
| Door swing direction when known | RoomModel default drawn dashed as estimated on A-DOOR-EST (4); PlanEditor Flip Door Swing stores a `.user` swing drawn solid (5) | 4; 5 |
| Room names after edits | FloorPlan (4); merged rooms keep one tag, split lines dashed on A-AREA-BNDY with the room names (FloorPlan revision 3.37c, 5) | 4; 5 |
| Counters | MeshRefine | 8 |
| Toggles: Furniture, Measurements, Room names, Doors/windows, Fixtures, Grid, Scale | FloorPlan `PlanToggles` (grid lines on A-GRID, scale bar on A-ANNO-SCAL), Results; exports use the same toggles (`ExportViewState`) | 4 |
| Allow manual editing | PlanEditor with CR-1 (3.37a) and the RoomModel and FloorPlan revisions (3.37b, 3.37c) | 5 |

### 4.15 FLOOR PLAN EDITING

| Requirement | Owner | Build |
|---|---|---|
| Move wall, adjust wall length, change wall thickness, add wall, delete wall | PlanEditor (joined walls follow, a shared wall's other face moves with it, typed lengths through `LengthParser`) | 5 |
| Add, move, resize door; add, move, resize window; add opening | PlanEditor; CR-1 `moveOpening` and `resizeOpening` applied by RoomModel and FloorPlan (5a0) | 5 |
| Rename room | PlanEditor | 5 |
| Merge rooms, split room | PlanEditor; CR-1 `mergeRooms` and `splitRoom` with `Polygon2D.clipped` in RoomModel and FloorPlan (5a0) | 5 |
| Add and delete measurement; add text annotation, symbol, notes | PlanEditor (user dimensions and annotations) | 5 |
| Manual edits must not overwrite raw scan data | EditLog overlays (Store, RoomModel, FloorPlan) (4); one entry per action with Undo, Redo and Reset to Scan (PlanEditor, CR-1) (5) | 4; 5 |

### 4.16 3D EDITING

| Requirement | Owner | Build |
|---|---|---|
| Tap objects | Results (read-only card with category guess and size with confidence; walls, doors and windows selectable to filter measurements, 4); Change Category on the card (5) | 4; 5 |
| Object: Hide, Delete from clean model, Move, Rotate, Rename, Change category, Show raw geometry | EditMenus | 7 |
| Object: Measure | MeasureTool Distance tool with object box edges as snap targets (5); from the object menu in EditMenus (7) | 5; 7 |
| Wall: Measure | MeasureTool Wall tool | 5 |
| Wall: Adjust, Add opening, Add door, Add window | PlanEditor (plan, 5); EditMenus wall menu (3D, 7) | 5; 7 |
| Wall: Hide, Inspect geometry | EditMenus | 7 |

### 4.17 PROJECT SYSTEM

| Requirement | Owner | Build |
|---|---|---|
| Stored locally by default; no account, subscription or cloud | Store, AppShell | 4 |
| Projects list | HomeUI | 4 |
| Each project contains its original scan data and derived models | Store (package layout) | 4 |
| Delete; export | HomeUI; ExportUI (4); House, Object and Quick Measure exports, multi-floor plans, progress (ExportUI revision 3.43d, 5) | 4; 5 |
| Rename | HomeUI and Results (Store `rename`) | 4 |
| Duplicate, archive, backup, restore | ProjectOps | 6 |

### 4.18 LOCAL-FIRST ARCHITECTURE

| Requirement | Owner | Build |
|---|---|---|
| Works offline after installation | all modules (no network code; only the opt-in token-protected DebugServer) | 4 |
| Prefer on-device processing | Pipeline, MeshModel, TextureJob, ObjectCapture (on-device photogrammetry) | 4; 5 |
| No AWS, Azure, Firebase, Supabase, subscription APIs or paid AI services | enforced by rule 0.2 (native frameworks only, no packages) | 4 |
