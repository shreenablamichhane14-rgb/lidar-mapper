# Mapper architecture

This is the architecture of record for Mapper from build 4 onward. It is written from the decision record `docs/design/synthesis-decisions.md` (D1 to D27), with the lead decision on the build plan replacing D25, on top of the winning proposal `docs/design/proposal-ship-first.md`. API facts come from `docs/RESEARCH.md` (cited as "RESEARCH 3.2" for a subsystem section, "RESEARCH ruling 4" for section 2). Shared types are the Swift in `ios/Sources/Core/`; every module named here has its contract (files, Swift signatures, self-test, acceptance checks) in `docs/MODULES.md`, with the same names and the same build plan. Where this document and a proposal disagree, this document wins. Where this document and `docs/MODULES.md` disagree on a Swift signature, MODULES.md wins; where either disagrees with Core, Core wins until a change request in 3.8 lands. The adversarial design review (`docs/design/review.md`) is applied to this document, MODULES.md and Core.

Precedence: lead build-plan decision > D1 to D27 > this document and MODULES.md > ship-first proposal > other proposals. RESEARCH.md is the ground truth for Apple API spelling and availability.

## 1. Overview and principles

Mapper is one iOS app target (Swift 5.9 language mode, iOS 18.0 deployment target, Xcode 26.6 and the iOS 26 SDK on CI, no packages, no Metal files, no SceneKit, no macros). A scan produces a sealed raw record on disk; every model the user sees (Realistic, 3D Clean, Floor Plan, Raw Scan, object model, measurements) is derived from that record by resumable pipeline steps, and every user change is an overlay in one edit log.

Principles, each enforced by a named mechanism:

| # | Principle | Mechanism |
|---|---|---|
| P1 | Local-first. No account, no cloud, no network use. | No `URLSession` anywhere. The only listener is `DebugServer` (off by default, token, logs only). See 11. |
| P2 | Raw is never modified. | Only Store's `RawScanWriter` writes raw, only into an unsealed InProgress folder or the `session.json` of the open capture session (D5), and it never recreates a missing folder (CR-6). Sealed folders carry `SEAL.json` and are verified by `PackageCheck` when a project opens. No chmod. The only removals are project delete, the confirmed Discard of the scan just captured (`ProjectLibrary.discardRoom`, lead decision 4) and the confirmed "Free up space" in build 6 (D6). |
| P3 | Several representations of one scan. | Raw (anchor-local mesh chunks, keyframes, depth, pose track, RoomPlan data, D8), Realistic (TextureJob), Clean (`CleanModel`), Plan (`PlanModel`), Object (ObjectModel). All but raw live in `derived/` and can be deleted and rebuilt. |
| P4 | Edits are overlays. | One `EditLog` in `edits/editlog.json` replayed by pure functions onto `CleanModel` and `PlanModel` (D3). Operations reference `ElementID`, never raw RoomPlan ids. Orphaned operations are kept and listed. |
| P5 | Derived products are stamped. | `DerivedStamp` per step and subject in `derived/index.json`; a step reruns when `pipelineVersion` or `inputHash` changes (D11). |
| P6 | Honest numbers. | Every value carries `Provenance` (measured, estimated, inferred, user). Lengths carry a 1-sigma accuracy from Coverage's `MeasurementConfidence` through MeasureCore's `ConfidenceAdapter`, never better than plus or minus 3 cm for RoomPlan values (RESEARCH ruling 4). No survey-grade claims. |
| P7 | Apple does the hard parts. | `RoomCaptureView(frame:arSession:)` for room capture (lead decision, D15), `ObjectCaptureSession` and `PhotogrammetrySession` for small objects, RealityKit `ARView` for display. Our code covers what SPEC requires and Apple lacks. |
| P8 | Compile-risk discipline. | D26 rules, exact names from RESEARCH, D10 forbidden names, a self-test per module, waves that compile against earlier waves only (13). |
| P9 | Amateur first. | One message at a time (UX_COPY display rules), progressive results (D20), plain words only from `Copy`, degraded modes designed into the UI (D16). |
| P10 | Built for a 6 GB A15. | Memory, thermal and storage budgets (D17, D18, section 12), foreground processing with the idle timer off, resumable steps. |

Deliberate departures from RESEARCH.md recommendations:

| Topic | RESEARCH says | This architecture | Why |
|---|---|---|---|
| Room capture host | Ruling 1: headless `RoomCaptureSession` is the long-term target; builds 4 and 5 use `RoomCaptureView(frame:arSession:)` | `RoomCaptureView(frame:arSession:)` in builds 4 to 6; the headless path is the planned build 7 module HeadlessRoom behind a flag | Lead decision and D15: Apple's coaching, outlines and detection for free; the view path is documented to preserve session settings. Not a departure for builds 4 and 5, only a longer horizon. |
| Built-in preview | 3.10 recommended approach: return `true` from `captureView(shouldPresent:error:)` and show Keep or Rescan | Return `false`, run `RoomBuilder` ourselves (RESEARCH 3.2 allows it) and show Mapper's quality sheet over the still-running camera | D19: the quality sheet and, in build 5, Show Missing Areas continue on the same session. |
| Plane detection | 3.1 recommended 2: on | Off for Room, House, Advanced space and Large object; on only in Quick Measure (D14) | Planes flatten the raw mesh (RESEARCH 3.1 gotcha 21). |
| Texture stills | 3.1 recommended 5: hi-res stills | 60 fps stream keyframes (RESEARCH ruling 5) | Hi-res intrinsics and depth alignment unverified; build 6 only logs an experiment. |
| Exposure cap | 3.4 recommended 1: cap `activeMaxExposureDuration` | Not in builds 4 to 6 | Untested next to RoomPlan; darkens dim rooms (judges). |
| Picking | 3.5 recommended 6: `CollisionComponent` plus `Scene.raycast` | CPU `MeshBVH.raycast` (Geometry) over pickable parts | Synchronous, gives the triangle directly, already self-tested; collision raycast stays a fallback. |
| Low-confidence rule | Section 1: "Low confidence" above 4 cm (2 sigma) | Core `MeasuredValue.isLowConfidence(length:)` (CR-2, applied), reached through `MeasureDisplay.isLowConfidence`: 2 sigma above max(4 cm, 3 percent of the length), plus any low-confidence flag from Coverage carried through by `ConfidenceAdapter` | A fixed 4 cm limit flags every long wall from the drift term alone; the relative term keeps the 4 cm rule for short lengths. |
| Scan length | 3.2 recommended 10: warn at 4 minutes and stop at 5 per room | Hint at 4 minutes and the time-limit sheet at 5, never an automatic stop for time; the automatic stops are heat (`.critical`), storage (under 300 MB) and the memory floor (under 400 MB available or a memory warning, 4.2) | Real rooms can need more than 5 minutes; the memory floor protects against the jetsam that the time limit stood in for (TEST_PLAN PERF-11). |
| USDZ writer | Ruling 2: own usda, then `MDLUtility.convert(toUSDZ:writeTo:)`, own stored zip as fallback | Export's `USDZWriter` (own usda plus own 64-byte aligned stored zip) is primary; `MDLUtility` only as a probed alternative | `USDZWriter` exists and is self-tested; `MDLUtility` has no known device usage. |

RESEARCH ruling 1 is followed exactly on one point both drafts had wrong: on the `RoomCaptureView(frame:arSession:)` path Mapper does not reconfigure the session in `captureSession(_:didStartWith:)`; it logs the effective configuration and lets the watchdog re-apply only when depth or mesh is missing (4.2).

## 2. Module map

### 2.1 Layers and dependency rules

| Layer | Modules | May import |
|---|---|---|
| L0 Foundation (pure) | Support, Units, Geometry, Export, Core, Coverage, MeshProcessing, Texturing | Foundation, simd, CoreGraphics, ImageIO, UIKit (Support, Export PDF only), Network (`DebugServer` only). Core also RoomPlan in exactly one file (D27). |
| L0 Storage | Store | L0, Foundation, Combine (for `ObservableObject`; `import Combine` in the declaring file) |
| L1 Capture | CaptureCore, MeshRecord, Keyframes, RoomCapture, GuidanceUI, CoverageLive, LiveMeshView, ObjectCapture, LargeObject, LiveMeasure | L0, Store, ARKit, RoomPlan, RealityKit (live views, Object Capture and enum mapping only), AVFoundation (permission), CoreImage, CoreVideo, UIKit (memory warning, background task) |
| L2 Processing | Pipeline, RoomModel, MeshModel, FloorPlan, Quality, TextureJob, MeasureCore, Structure, ObjectModel | L0, Store, RoomPlan (RoomModel, Structure), ModelIO (ObjectModel), UIKit (Pipeline idle timer, FloorPlan images), Combine (Pipeline `ObservableObject`), SwiftUI (FloorPlan canvas only) |
| L3 Presentation | Viewer3D, ScanUI, QualityUI, Results, ExportUI, HomeUI, AppShell, MeasureTool, PlanEditor, CoverageOverlay, MissingAreas, HouseUI, ObjectUI, ProjectOps and later screens | everything below, SwiftUI, RealityKit, QuickLook |

Rules:
1. Dependencies point down a layer, or sideways only where the module index of MODULES.md section 1 lists them. A module never imports a module of the same or a later wave of its build (13).
2. The app is one Swift module, so the compiler cannot enforce rule 1. Reviewers enforce it, and Phase 2 adds `tools/check_layers.py` to CI: it greps `import ARKit|RoomPlan|RealityKit|SwiftUI` per folder against the table above and fails on a violation.
3. Pure modules (L0 Foundation) never touch ARKit, RoomPlan, RealityKit or the file system of a project; they take plain values and return plain values, so they are self-tested on the phone without capture.
4. Capture modules write only through Store's `RawScanWriter`. Processing modules never write raw. Presentation modules never write raw or `derived/` directly (they call Store, Pipeline or ExportUI's runner).
5. Dependency inversion keeps waves independent: CaptureCore defines the `ScanRecorder` protocol (including `flushNow()`), so RoomCapture drives recorders it never imports; Core defines `ProcessingStep` (steps) and `EditApplicable` (edit replay); a step that needs another same-wave module's output gets it through an injected closure (`CleanModelStep(meshProvider: (ProjectPackage, UUID) -> MeshWithAttributes?)`); screens of wave 4c talk to each other only through closures that AppShell wires, carrying shared value types from earlier waves (`ExportViewState` lives in FloorPlan). `ScanFlowModel` in ScanUI is the only place that knows every concrete capture type.
6. D26 applies to every module: `@MainActor final class X: ObservableObject` with `@Published` for UI models (with `import Combine` or `import SwiftUI` in the file); plain `NSObject` delegates; `DispatchQueue.main.async` with value types; `@unknown default` on every Apple enum; no force unwraps except literals; files under about 450 lines; doc comments; strings only from `Copy` (new ones in `Support/Copy+<Module>.swift`); `enum <Module>SelfTest { static func run() -> [String] }`. AppShell alone edits `ContentView.swift` and `MapperApp.swift`; the lead alone edits `ios/project.yml` and the Diagnostics self-test suite list.
7. An Apple API that RESEARCH does not list may be used only when it exists at iOS 17.0 or earlier and is not deprecated in the iOS 26 SDK; MODULES marks it "(not in RESEARCH)" and the pre-CI reviewer checks it first. Nothing after iOS 18.0 without `if #available`; no iOS 27 symbol.

### 2.2 Module table

"B/W" is build and wave (13). Lines are Swift estimates excluding self-tests. Existing modules are listed for completeness. The Swift contract of every row is in MODULES.md section 3 under the same name.

| Module | Folder | Layer | Responsibility (main types) | Depends on | B/W | Lines |
|---|---|---|---|---|---|---|
| Support | Support | L0 | `Copy`, `GuidanceKind`, `GuidancePolicy`, `LogStore`, `DebugServer`, `Haptics`, `DeviceState`, `SettingsKey` | none | 1 | exists |
| Units | Units | L0 | `LengthFormat`, `AreaFormat`, `VolumeFormat`, `AngleFormat`, `Tolerance`, `LengthParser`, `UnitPreferences` | none | 1 | exists |
| Geometry | Geometry | L0 | `TriangleMesh`, `AABB3`, `OrientedBox`, `Rectangle2D`, `Plane`, `Polygon2D`, `Segment2D`, `Ray`, `MeshBVH`, `Snap` | none | 3 | exists |
| Export | Export | L0 | `ExportScene`, `ExportMesh`, `ExportMaterial`, `Plan2D`, `OBJWriter`, `PLYWriter`, `STLWriter`, `GLBWriter`, `USDZWriter`, `DXFWriter`, `SVGWriter`, `PDFPlanWriter`, `ZipWriter` | none | 3 | exists |
| Core | Core | L0 | Shared contracts: manifest, package paths, raw records, binary formats, clean and plan models, `EditLog`, stamps, `ScanEngine`, `FakeScanEngine`, errors | Geometry, Export, Support | 4 / 0 | merged |
| Coverage | Coverage | L0 | `CoverageGrid`, `ExpectedSurfaces`, `ScanQuality`, `GuidanceEngine`, `MeasurementConfidence` | Support | 4 / 0 | merged |
| MeshProcessing | MeshProcessing | L0 | `ChunkMerge` with `MergeChunk`, `MeshCleanup`, `HoleFill`, `MeshSimplify`, `MeshSmooth`, `MeshCrop`, `ObjectIsolation`, `MeshWithAttributes` | Geometry | 4 / 0 | merged |
| Texturing | Texturing | L0 | `TextureBaker`, `KeyframeSelector`, `TXMesh`, `TXKeyframe`, `TXOptions`, `TXResult`, `TXExposure` | none | 4 / 0 | merged |
| Store | Store | L0 | `ProjectLibrary` (with `rename`, `discardRoom`), `ManifestWriter`, `InProgressScans`, `InProgressScanInfo` (`scan.json`), `RawScanWriter` (with `close`), `RawScanReader`, `PackageCheck`, `EditStore`, `StorageUsage` | Core, Support | 4a | 900 |
| CaptureCore | CaptureCore | L1 | `ARSessionHub` (owns the `ARSession`, delegate queue, fan-out, watchdog, memory warnings, `ARDelegateRelay`), `ScanProfile`, `ScanConfigurationFactory`, `ScanRecorder`, `HubStatus`, `TrackingMonitor`, `ThermalGovernor`, `StorageWatchdog`, `MemoryPolicy`, `CaptureWatchdogLogic`, `ARFrameReading`, `MeshAnchorCopier`, `CaptureDiagnostics` | Core, Support | 4a | 1400 |
| RoomModel | RoomModel | L2 | `RoomInput` (testable mirror of `CapturedRoom`), `RoomOutline` (D12), `CleanModelBuilder`, `RoomMetricsCalculator` (D13), `CleanModel: EditApplicable`, `CleanMeshBuilder`, `PolygonTriangulator`, `CleanModelStore`, `CapturedRoomStore`, `BuildRoomStep`, `CleanModelStep` | Core, Geometry, MeshProcessing, Support | 4a | 1400 |
| MeshModel | MeshModel | L2 | `MeshConsolidator`, `MeshModelStore`, `MeshClassPalette`, `MeshExportAdapter`, `ConsolidateMeshStep` | Core, Geometry, MeshProcessing, Export, Support | 4a | 800 |
| Pipeline | Pipeline | L2 | `ProcessingRunner` (main-actor facade over detached step tasks, suspend and resume), `ProcessingJob`, `ScheduledStep` (with `dependsOn`), `ProcessingGuards`, `ProjectProcessingState`, `PipelineAttempt` (crash-loop guard), `IdleTimerGuard` (the app's only idle-timer writer) | Core, Support | 4a | 700 |
| MeasureCore | MeasureCore | L2 | `ConfidenceAdapter`, `MeasureDisplay`, `RoomDimensions`, `DimensionRow`, `RoomEvidence`, `SnapSet` | Core, Geometry, Coverage, Units, Support | 4a | 700 |
| FloorPlan | FloorPlan | L2 | `PlanBuilder`, `PlanModel: EditApplicable`, `PlanModelStore`, `PlanDrawing` (to `Plan2D` plus `PlanHit`), `PlanToggles`, `ExportViewState`, `PlanRenderer`, `PlanCanvasView`, `RoomTitles`, `FloorPlanStep`, `ThumbnailStep`, `Copy.FloorPlan.categoryName` | Core, Geometry, Export, Units, Support | 4a | 1400 |
| Viewer3D | Viewer3D | L3 | `ViewerModel`, `ViewerContainer` (`ARView` `.nonAR`), `ViewerPart`, `ViewerContent`, `ViewerContentBuilder`, `ViewerDisplayStyle`, `ViewerHit`, `ViewerOrbitMath`, `ViewerDiagnostics` | Core, Geometry, MeshProcessing, Support | 4a | 1200 |
| GuidanceUI | GuidanceUI | L1/L3 | `GuidanceSignals` (ARKit, RoomPlan and Object Capture mapping), `GuidanceFilter`, `GuidanceBanner`, `GuidanceAnnouncer` | Core, Coverage, Support | 4a | 450 |
| Export revision | Export | L0 | `DXFWriter.data(for:millimeters:unitsNote:)`: DXF in millimeters with a units TEXT note (D23, MODULES 3.18a) | none | 4a | 60 |
| MeshRecord | MeshRecord | L1 | `MeshStore: ScanRecorder`: anchor-local `MeshChunk` copies, 3 s dirty flush, final flush, eviction (D8, D17) | CaptureCore, Store | 4b | 500 |
| Keyframes | Keyframes | L1 | `FrameCopier` (D7), `KeyframeRecorder` (gate from `KeyframeSelector`), `PoseTrackRecorder` (10 Hz, D8), `PhotoRecorder` | CaptureCore, Store, Texturing | 4b | 900 |
| RoomCapture | RoomCapture | L1 | `RoomScanEngine: ScanEngine`, `RoomCaptureController` (both RoomPlan delegates), `RoomCaptureContainer` (one `RoomCaptureView`), `RoomScanStats`, `RoomScanTarget`, `RoomScanResult` | CaptureCore, Store, RoomModel, GuidanceUI, Coverage | 4b | 1200 |
| Quality | Quality | L2 | `QualityEvaluator`, `QualityInputs`, `QualityEvaluation`, `MissingAreaRecord`, `QualityStore`, `QualityStep` | RoomModel, MeshModel, MeasureCore, Store, Coverage, MeshProcessing | 4b | 800 |
| TextureJob | TextureJob | L2 | `TextureDensity`, `TexturedMesh`, `TextureStore` (never slip); `KeyframeLoader`, `TextureLowStep` (may slip to 5a) | MeshModel, Store, Texturing, MeshProcessing, Export | 4b | 700 |
| HomeUI | HomeUI | L3 | `HomeScreen`, `ModePickerSheet`, `HomePresentation` (rename, delete, hides `.capturing` projects) | Store, Pipeline | 4b | 500 |
| ScanUI | ScanUI | L3 | `ScanFlowModel` (D1 facade), `ScanFlowPhase`, `ScanPreflight`, `ScanErrorCopy`, `RoomScanScreen`, `ScanTipsSheet`, `DemoProjectFactory`, `SnapshotRecorder` | RoomCapture, MeshRecord, Keyframes, Quality, CaptureCore, GuidanceUI, Store, Pipeline, RoomModel, MeshModel, FloorPlan | 4c | 1300 |
| QualityUI | QualityUI | L3 | `QualitySheet` (medium detent over the live camera, D19), `QualityPresentation` | Quality | 4c | 400 |
| Results | Results | L3 | `ResultScreen`, `ResultModel`, `ResultTab`, `TabAvailability`, `ResultAvailability`, dimensions panel, read-only object card | Viewer3D, FloorPlan, MeasureCore, RoomModel, MeshModel, Store, Pipeline, Quality, TextureJob | 4c | 1300 |
| ExportUI | ExportUI | L3 | `ExportSheet`, `ExportCatalog`, `ExportRunner`, `ExportAdapters`, `ExportSummaryJSON`, `ActivityShareSheet` | Export, MeshModel, RoomModel, FloorPlan, MeasureCore, Store, Quality, TextureJob | 4c | 1100 |
| AppShell | AppShell | L3 | `AppRootView`, `AppRouter`, `AppRoute`, `AppScanCoordinator`, `AppResultsCoordinator`, `ProcessingPlans`, `SettingsScreen`, `DiagnosticsScreen` (probe plus all self-tests, Demo Mode), `RecoveryService`; replaces `ContentView` | every build 4 module | 4d | 1300 |
| Structure | Structure | L2 | `StructureEligibility`, `StructureAlignment` (D9), `StructureFloors`, `MergeStructureStep`, `AlignRoomsStep` | RoomModel, Store | 5a | 800 |
| CoverageLive | CoverageLive | L1 | `CoverageLiveRecorder: ScanRecorder` (grid at up to 3 Hz, expected surfaces from the live room, minimap, guidance augmenters) | CaptureCore, MeshRecord, RoomModel, Coverage | 5a | 900 |
| LiveMeshView | LiveMeshView | L1 | `MeshScanEngine: ScanEngine` (mesh-only driver: space scans, patch passes, two-pass fallback, large objects), `LiveMeshContainer` (`ARView` `.ar` on the hub session) | CaptureCore, Store, MeshRecord, Keyframes, GuidanceUI, Coverage | 5a | 1000 |
| ObjectCapture | ObjectCapture | L1 | `ObjectScanModel`, `ObjectOnboardingState`, `ObjectScanScreen`, `PhotogrammetryStep` (`reconstructObject`) | Store, GuidanceUI | 5a | 1100 |
| ObjectModel | ObjectModel | L2 | `ObjectModelLoader` (MDLAsset), `ObjectDimensions`, `ObjectDimensionsRecord`, `ObjectMetricsStep` | MeshProcessing, Export, Store, Geometry | 5a | 800 |
| MeasureTool | MeasureTool | L3 | `MeasureToolModel`, `MeasureToolOverlay`, `MeasureToolList`, `MeasureMath` | Viewer3D, MeasureCore, Store | 5a | 1000 |
| LiveMeasure | LiveMeasure | L1 | Quick Measure screen and model (own session, planes on) | CaptureCore, MeasureCore, Store, GuidanceUI | 5a | 900 |
| PlanEditor | PlanEditor | L3 | `PlanEditorModel`, `PlanEditAction`, `PlanEditorOps` (edits through `EditLog` with undo) | FloorPlan, Store | 5a | 1300 |
| CoverageOverlay | CoverageOverlay | L3 | Live colored mesh per anchor, minimap view, legend | CoverageLive, LiveMeshView | 5b | 700 |
| LargeObject | LargeObject | L1 | Seed tap, gravity `OrientedBox`, `SectorCoverage` (D4), crop edit | CoverageLive, LiveMeshView, ObjectModel, CaptureCore | 5b | 800 |
| MissingAreas | MissingAreas | L3 | Show Missing Areas tour on a patch pass (D19) | CoverageLive, LiveMeshView, Quality | 5b | 600 |
| HouseUI | HouseUI | L3 | Room list, Scan Next Room, relocalization, Finish Building, manual alignment | Structure, RoomCapture, ScanUI, QualityUI, FloorPlan | 5b | 1200 |
| ObjectUI | ObjectUI | L3 | Size chooser, processing screen, object result | ObjectCapture, ObjectModel, Viewer3D | 5b | 900 |
| ProjectOps | ProjectOps | L3 | Rename, duplicate, archive, `StreamingZipWriter` and `StreamingZipReader` (D2), backup, restore with validation, Free up space | Store, Export (`CRC32`) | 6a | 1300 |
| ObjectCrop | ObjectCrop | L3 | Crop box; photogrammetry re-run with `PhotogrammetrySession.Request.Geometry` or mesh crop | ObjectModel, ObjectCapture, MeshProcessing, Viewer3D, Store | 6a | 500 |
| AdvancedScan | AdvancedScan | L3 | Advanced Scan options to `ScanSettings` and a driver choice | Core | 6a | 400 |
| ReferenceLength | ReferenceLength | L3 | One tape-measured length to a reversible `setScaleCorrection` edit (D21) | Store, MeasureCore, RoomModel | 6a | 400 |
| BackgroundWork | BackgroundWork | L2 | iOS 26 `BGContinuedProcessingTaskRequest` for CPU steps (with the `BGTaskSchedulerPermittedIdentifiers` Info.plist entry), hi-res still experiment, all behind `#available` | Pipeline | 6a | 400 |
| Texturing revision | Texturing | L0 | Atlas streaming callback on `TextureBaker` (accepted, lead decision 6) | none | 6a | 150 |
| EditMenus, PhotoBrowser, SurfaceEvidence, SpaceScan, HeadlessRoom | own folders | L2/L3 | Planned for build 7 (13.5) | see MODULES.md | 7a | planned |
| MeshRefine, LevelsAndStairs | own folders | L2 | Planned for build 8 (13.5) | see MODULES.md | 8a | planned |

### 2.3 Parallel-work rules

One agent per module per wave, on branch `impl/<module>`, editing only its folder and its `Support/Copy+<Module>.swift`. Core changes go through the lead (3.8). A module compiles against the `integration` head at the start of its wave, so it may use every module of earlier waves and nothing of its own wave. Interfaces between waves are the Swift signatures in MODULES.md; if an implementer needs a different signature from an earlier wave, the earlier module changes first (a revision on its own branch, merged before the dependent module).

## 3. Data model

### 3.1 Project package on disk

Paths are exactly those of `ProjectPackage` and `RawScanFolder` (Core, `ProjectPackage.swift`). Files marked with a module name are owned by that module and addressed through its store type (MODULES.md section 3.1).

```
Documents/Projects/<projectUUID>.mapperproj/     ProjectStore.package(for:), ProjectPackage(root:)
  project.json                                   ProjectManifest (ManifestWriter)      manifestURL
  thumbnail.jpg                                  512 px, FloorPlan ThumbnailStep        thumbnailURL
  raw/                                           rawURL, excluded from backup, sealed parts never modified
    sessions/<sessionUUID>/                      sessionURL(_:)
      session.json                               CaptureSessionRecord, first room of the session
      worldmap.arworldmap                        ARWorldMap without mesh anchors (HouseUI, build 5)
      rooms/<roomUUID>/                          rawRoomURL(session:room:), one sealed RawScanFolder
        SEAL.json                                SealFile                               sealURL
        scan.json                                InProgressScanInfo (Store), sealed with the folder
        capturedroomdata.json                    JSONEncoder(CapturedRoomData)          capturedRoomDataURL
        capturedroom.json                        JSONEncoder(CapturedRoom) from RoomBuilder   capturedRoomURL
        capturedroom-live.json                   latest didUpdate CapturedRoom, every 10 s (provisional)   liveCapturedRoomURL
        worldmap.arworldmap                      ARWorldMap at Done, mesh anchors stripped (best effort)   worldMapURL
        roomlog.json                             RoomCaptureLog                         roomLogURL
        poses.ptrk                               PoseTrackFile, 10 Hz                   poseTrackURL
        keyframes.jsonl                          KeyframeRecord per line                keyframesLogURL
        events.jsonl                             CaptureEvent per line                  eventsLogURL
        photos.jsonl                             PhotoPin per line                      photosLogURL
        mesh/<anchorUUID>.mchk                   MeshChunkFile, anchor-local (D8)       meshChunkURL(anchor:)
        keyframes/00012.jpg                      JPEG q0.85, sensor landscape           keyframeImagePath(_:)
        depth/00012.dpth                         DepthFile, Float16 plus confidence     depthPath(_:)
        photos/<photoUUID>.jpg                   Take Photo, JPEG q0.9                  photoPath(_:)
      mesh-pass/<passUUID>/                      rawMeshPassURL(session:pass:), same layout without RoomPlan files (build 5)
    objects/<objectUUID>/                        rawObjectURL(_:): Images/ + objectlog.json (small and medium, build 5)
                                                 or the RawScanFolder layout (large, ObjectRecord.size == .large)
    measure/quick.json                           [MeasurementRecord] (Quick Measure, build 5)   quickMeasureURL
  derived/                                       regenerable; deleting it costs only processing time
    index.json                                   DerivedIndex (ProcessingRunner only)   derivedIndexURL
    pipeline_attempt.json                        PipelineAttempt crash-loop marker (ProcessingRunner only)   pipelineAttemptURL
    clean.json                                   CleanModel before edits (CleanModelStep)   cleanModelURL
    plan.json                                    PlanModel before edits (FloorPlanStep)     planModelURL
    rooms/<roomUUID>/                            derivedRoomURL(_:)
      capturedroom.json                          BuildRoomStep, only when raw lacks one
      mesh.mchk                                  MeshModel: consolidated measured world mesh (identity transform, room id)
      mesh_inferred.mchk                         MeshModel: hole-fill faces only (Inferred)
      mesh_view.mchk                             MeshModel: simplified measured faces for the viewer and texturing (at most 300k)
      mesh_floaters.mchk                         MeshModel: islands removed by cleanup, shown in Raw Scan
      mesh_stats.json                            MeshModel: MeshStats
      quality.json                               Quality: QualityEvaluation
      texture/textured.mchk, textured.tuv, page_<n>.jpg   TextureJob: baked mesh, UVs, atlas pages
    objects/<objectUUID>/                        derivedObjectURL(_:): checkpoint/, model.usdz, dims.json (build 5)
    structure/structure.json, alignment.json, attempt.json   Structure (build 5, D9)   capturedStructureURL, alignmentURL
  edits/                                         user work, backed up, never touches raw
    editlog.json                                 EditLog (D3), Store EditStore          editLogURL
    measurements.json                            [MeasurementRecord], Store EditStore   measurementsURL
  exports/                                       staged share files, exports/<yyyyMMdd-HHmmss>/ and exports/simple/   exportsURL
Library/Application Support/InProgress/<scanUUID>/   ProjectStore.inProgressRoot() (excluded from backup); RawScanFolder layout plus scan.json while capturing
Documents/Logs/mapper-YYYY-MM-DD.log             LogStore, 7 days
```

The session folder's `session.json` is written once by RoomCapture for the first room of a capture session and never touched after the session ends; the world map (build 5) is replaced after each room while the session is open. Sealed scan folders are never touched after sealing.

### 3.2 Formats

| File | Format | Owner | Notes |
|---|---|---|---|
| JSON records | `ProjectStore.encoder` (ISO 8601 dates, sorted keys) | writer module | Every JSON has a schema through its Swift type; the manifest carries `schemaVersion`. RoomPlan's own types use plain `JSONEncoder()` and `JSONDecoder()`. |
| `*.jsonl` | One JSON object per line, `\n` terminated, append-only | `RawScanWriter.appendJSONLine` | A failed append is truncated back to the previous end. `RawScanReader` skips and counts every undecodable line (a torn last line after a crash, a middle line after a failed append) and drops records whose file paths fail `PackageCheck.isSafeRecordPath`; files are opened only through `RawScanFolder.resolve` (CR-4). |
| `.mchk` | `MeshChunkFile` v1: 100-byte header with anchor id, update count, transform; packed Float32 positions, optional normals, UInt32 indices, optional per-face class | Core | Raw chunks are anchor-local. Derived `mesh.mchk`, `mesh_inferred.mchk`, `mesh_view.mchk`, `mesh_floaters.mchk` and `textured.mchk` reuse the format with an identity transform and the room id as anchor id (`MeshModelStore.chunk(from:id:)`). The format has no inferred flag, so inferred faces live only in `mesh_inferred.mchk`. |
| `.dpth` | `DepthFile` v1: Float16 depth plus UInt8 confidence | Core | Size read at runtime, never assumed 256 x 192 (RESEARCH 3.4 gotcha 5). |
| `.ptrk` | `PoseTrackFile` v1: 8-byte header, fixed 78-byte records | Core | Partial last record ignored. |
| `mesh_stats.json` | `MeshStats`: chunk, triangle, view and inferred counts, per-class counts, bounds | MeshModel | |
| `textured.tuv` | "TUV1": magic, version UInt16 1, faceCount UInt32, pageCount UInt16, then per face atlas UInt16 and 3 x (Float32, Float32), little endian | TextureJob | Bottom-left UV origin, matching `TXResult` and `ExportMesh`. |
| `quality.json` | `QualityEvaluation`: `QualitySummary`, missing areas (`MissingAreaRecord`), degraded mode, `RoomEvidence`, dark keyframe fraction, input hash | Quality | |
| `scan.json` | `InProgressScanInfo`: scan, project, session and room ids, kind (room, meshPass, object), mode, start time | Store | Written at creation, sealed with the folder, used by recovery. |
| `worldmap.arworldmap` | `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)` of an `ARWorldMap` without `ARMeshAnchor`s | RoomCapture (room folder, build 4), HouseUI (session folder, build 5) | RESEARCH 3.1 world map block. |
| `capturedroom-live.json` | plain `JSONEncoder()` of the latest `didUpdate` `CapturedRoom` | RoomCapture | Provisional: only read when there is no `capturedroom.json` or `capturedroomdata.json`, every value `.estimated`. |

### 3.3 Write rules

1. Whole files are written with `ProjectStore.writeData` or `RawScanWriter.writeFile` (`.atomic`: temporary file in the same folder, then rename). JSON is never edited in place. Raw writers and derived writers pass `createParents: false`, and derived folders are created with `ProjectStore.ensureDirectory(_:inside: package.root)`, so a late write after a discard or delete fails instead of recreating a ghost folder (CR-6). `edits/`, `exports/` and `thumbnail.jpg` get `.completeFileProtectionUnlessOpen` automatically (`ProjectStore.defaultProtection(for:)`, CR-4, 11.2).
2. Raw binary files (JPEG, depth, mesh chunks) are written atomically by `RawScanWriter` on its serial queue `RawScanWriter.ioQueue` ("mapper.io", utility). A mesh chunk flush replaces `mesh/<anchor>.mchk` with the latest version of that anchor (D8).
3. JSON Lines and the pose track are appended through `FileHandle` on the same queue. A keyframe line is appended only after its JPEG and depth file are on disk, so a record never points at a missing file.
4. Single writer per file: `ManifestWriter` (process-wide lock, used by `ProjectLibrary` and every other caller) for `project.json`; `ProcessingRunner` for `derived/index.json` and `derived/pipeline_attempt.json`; `EditStore` (process-wide lock) for `edits/`; `RawScanWriter` for an InProgress folder and the session's `session.json`; the owning step for each derived output; ExportUI for `exports/`.
5. `raw/` is excluded from backup at creation and again after every seal, and `InProgress/` and every new scan folder in it likewise (`ProjectStore.inProgressRoot()`, `InProgressScans.create`), because the flag resets on some file operations (RESEARCH 3.9 gotcha 8).
6. Nothing half-written is ever visible in `Documents/`: in-progress capture lives in Application Support and is moved in only when sealed (D5, RESEARCH 3.9 gotcha 9).

### 3.4 InProgress, SEAL and recovery (D5)

1. Begin: ScanUI creates the project with `ProjectLibrary.create(kind:name:)` and appends a `CaptureSessionRef` with `frameLink: .projectFrame(sessionID:)`; the engine calls `InProgressScans.create(_:)` with an `InProgressScanInfo` (kind `.room`), which makes `InProgress/<scanUUID>/` with `mesh/`, `keyframes/`, `depth/`, `photos/` and `scan.json` and returns a `RawScanFolder`.
2. Capture: one `RawScanWriter(folder:)` is the only writer; recorders receive the folder in `beginRecording(into:profile:startTimestamp:)` and write through the writer.
3. Finish: the Done sequence of 4.2 runs in one ordered task: RoomPlan files, `RoomBuilder`, world map, recorders detached and finished (final mesh flush, JSON Lines closed, pose batch flushed), `roomlog.json`, `RawScanWriter.flush`, `RawScanWriter.close()`, then `InProgressScans.seal(_:into:package:)` writes `SEAL.json` inside InProgress, moves the folder to `rawRoomURL(session:room:)` (same volume, a rename) and re-applies backup exclusion. Nothing is written into the folder after `SEAL.json`. Only then does the engine emit `.roomFinished(roomID:)`; ScanUI appends the `RoomRecord` (status `.captured`, `capturedRoomID`, `keyframeCount`, `capturedAt`, `frameLink`) and sets the project `.needsProcessing` in the same `ProjectLibrary.update`.
4. Open: `ResultModel.load()` runs `PackageCheck.verify` off main (seal sizes, record paths); problems are logged and mark the project `.needsAttention`. Derived products whose inputs changed are rebuilt by stamp.
5. Launch recovery (`RecoveryService.pending()` before Home shows):
   - folder has `SEAL.json`: the crash hit between seal and move; the move and manifest update complete silently and the project is enqueued;
   - folder unsealed with a readable `scan.json`: Home offers "Recover unfinished scan" (`Copy.AppShell.recoverTitle`). Keep Scan seals the folder as it is (JSON Lines tolerate torn lines), moves it, writes no `roomlog.json` (readers treat it as absent) and enqueues processing: `BuildRoomStep` runs when `capturedroomdata.json` exists; otherwise `capturedroom-live.json` gives a provisional room (every value `.estimated`); with neither the room is mesh-only (Clean and Floor Plan unavailable). Discard removes the folder and then deletes the project when it has no rooms;
   - `scan.json` unreadable: nothing is listed; the folder stays until the user frees space (build 6);
   - projects still in `.capturing` (a kill while the quality sheet was up, an engine start that threw, a crash between the seal move and the manifest update) are reconciled: sealed room folders missing from `manifest.rooms` are added from `scan.json` and `RawScanReader`, a project with rooms becomes `.needsProcessing`, and one with no rooms and no InProgress scan naming it is deleted. Home never lists or opens a `.capturing` project.
6. Cancel: the confirmed "Discard Scan" while capturing calls `ScanEngine.discard()`: the engine stops RoomPlan, detaches and finishes the recorders, flushes and closes the writer, then deletes the InProgress folder, and only then reports `.stateChanged(.idle)`; ScanUI deletes the project after that event when it has no rooms. `ScanEngine.cancel()` alone (failure paths) does the same ordered stop and keeps the folder for recovery.
7. Discard after Done (quality sheet, lead decision 4): `ProjectLibrary.discardRoom(_:in:)` removes only the scan just captured (its `RoomRecord`, sealed raw room folder and `derived/rooms/<id>/`) and deletes the project when no room is left, which is always the case for a build 4 Room project.

### 3.5 Derived index and stamps (D11)

- `DerivedIndex.stamps` holds one `DerivedStamp` per `(step, subject)`; `subject` is the room or object id, nil for project-wide products (`clean.json`, `plan.json`, structure, thumbnail).
- `inputHash = InputHasher.hash(seals:editRevision:extra:)` with the `SealFile`s of the raw folders the step reads, `EditLog.revision` only for steps that read edits (thumbnail in build 4; alignRooms and objectMetrics in build 5), and `extra` = option strings (for example `"variant=reduced"`, `"density=textured"`) plus the current stamp `inputHash` of every upstream step whose output it reads (for example `CleanModelStep` adds the rooms' `consolidateMesh` stamps, `FloorPlanStep` the `cleanModel` stamp, `TextureLowStep` its room's `consolidateMesh` stamp), so a rebuilt input makes its readers rerun (MODULES.md section 3.1). `CleanModelStep` does not include the edit revision: the base model ignores edits.
- A step writes its outputs atomically first, then the runner records the stamp and writes the index atomically. A crash in between reruns the step; steps are idempotent.
- Bumping `ProjectManifest.currentPipelineVersion` makes every stamp stale. `schemaVersion` is independent and refuses newer manifests (`CoreError.unsupportedSchema`).
- Readers decide from the files on disk, not from stamps: a derived file that exists is shown, and a stale one stays visible until its rerun replaces it (atomically). Only the runner reads stamps. `ResultAvailability.compute` combines the files with the in-memory `ProjectProcessingState` for chips, so a demo project, a relaunched project and a failed job all open (MODULES 3.26).

### 3.6 Edits (D3)

- `EditStore` (Store, process-wide lock) loads and saves `EditLog` (`append`, `undo`, `redo`), writing atomically after each change and posting `.mapperEditsDidChange` on main.
- Replay: `log.applied(to: base)` with `CleanModel: EditApplicable` (RoomModel) and `PlanModel: EditApplicable` (FloorPlan); `CleanModelStore.loadEdited` and `PlanModelStore.loadEdited` return the edited model plus the orphaned operations. Viewer, plan, measurements and exports always show the edited models. Orphaned operations are listed in Results from build 5.
- Ids: walls, openings and objects use `ElementID.derived(fromRoomPlan: surface.identifier)`, so a rebuild finds the same element; rooms use `ElementID(uuid: RoomRecord.id)` with the RoomPlan id kept as provenance, because RoomPlan regenerates room ids on merge (D9); user-created elements get a fresh `UUID`.
- Build 4 writes no edits: the object card is read-only and Hide Furniture is a view setting (a layer toggle in Results, not an edit) that exports follow through `ExportViewState`. Project rename changes only the manifest name. Plan editing including fixture move, delete and recategorize, Change Category on the object card, and `cropObject` (build 5, PlanEditor, Results and LargeObject), `setRoomAlignment` (build 5, HouseUI), `setScaleCorrection` (build 6, ReferenceLength) and the 3D menus (build 7, EditMenus: `renameRoom`, `relabelObject`, `setHidden`, `moveObject` rotate, show raw) follow. Move, resize, merge and split of plan elements use CR-1, approved and applied by the lead before wave 5a (3.8).

### 3.7 In-memory model (Core)

| Group | Types | Used by |
|---|---|---|
| Project | `ProjectManifest`, `ScanMode`, `ProjectStatus`, `CaptureSessionRef`, `RoomRecord`, `RoomStatus`, `ObjectRecord`, `ObjectSize`, `FloorRecord`, `ScanSettings`, `DetailLevel`, `ScanDistance`, `QualitySummary`, `QualityVerdict` | Store, ScanUI, HomeUI, Pipeline |
| Paths and IO | `ProjectPackage`, `RawScanFolder`, `ProjectStore`, `SealFile`, `SealEntry` | Store, capture modules, every step |
| Raw records | `KeyframeRecord`, `PhotoPin`, `CaptureEvent`, `CaptureEventKind`, `CaptureSessionRecord`, `RoomCaptureLog`, `DegradedMode`, `PoseSample`, `MeshChunk`, `DepthMap` | capture modules, steps |
| Binary codecs | `MeshChunkFile`, `DepthFile`, `PoseTrackFile`, `CoreByteReader` | recorders, MeshModel, TextureJob, Quality |
| Clean model | `CleanModel`, `CleanRoom`, `CleanWall`, `WallArc`, `CleanOpening`, `OpeningKind`, `DoorSwing`, `CleanFloor`, `CleanCeiling`, `DetectedObject`, `DetectionConfidence`, `ObjectCategory`, `RoomMetrics`, `Provenance`, `PlanAxes` | RoomModel, Results, MeasureCore, ExportUI |
| Plan | `PlanModel`, `PlanLevel`, `PlanRoom`, `PlanWall`, `PlanOpening`, `PlanFixture`, `PlanAnnotation`, `AnnotationKind`, `PlanDimension` | FloorPlan, PlanEditor, ExportUI |
| Edits | `EditOperation`, `EditLog`, `EditApplicable`, `RoomAlignmentRecord`, `ElementID`, `FrameLink`, `OrientedBoxRecord` | Store, RoomModel, FloorPlan, Structure |
| Pipeline | `PipelineStepID`, `DerivedStamp`, `DerivedIndex`, `InputHasher`, `StepContext`, `ProcessingStep` | Pipeline and every step |
| Measurements | `MeasurementKind`, `SnapKind`, `MeasurementSource`, `MeasuredValue` (with the one low-confidence rule, CR-2), `MeasurementRecord` | MeasureCore, Results, MeasureTool |
| Live scan | `LiveScanSnapshot`, `TrackingSummary`, `ThermalLevel`, `MinimapSnapshot`, `MinimapCell`, `ScanEngine`, `ScanEngineState`, `ScanEngineEvent`, `SnapshotRecording`, `FakeScanEngine` | capture engines, ScanUI |
| Codable wrappers | `Vec2`, `Vec3`, `Transform4`, `Intrinsics`, `UUIDBytes` | everywhere |
| Errors | `MapperError` (with `copyKey` for logs; screens switch exhaustively), `CoreError` | everywhere |

Coordinate conventions: world is ARKit world (meters, +Y up). Plan coordinates always go through `PlanAxes` (plan x = world x, plan y = -world z). Coverage's 2D inputs (`CoverageWall`, `CoverageRoomBoundary`) are world (x, z), not `PlanAxes`; `QualityInputs.boundary(for:)` converts explicitly. Texture coordinates are bottom-left origin (`TXResult`, `ExportMesh`, `textured.tuv`); only `GLBWriter` flips, for glTF.

### 3.8 Core change requests (lead approval)

The design review applied CR-2, CR-4, CR-5 and CR-6 to Core before wave 4a; every build 4 contract in MODULES.md compiles against Core as it now is on `integration`, and build 4 needs no further Core change. The list below is identical to MODULES.md section 3.0.

| Id | Change | Status |
|---|---|---|
| CR-1 | `EditOperation` gains `moveOpening(opening:offset:)`, `resizeOpening(opening:width:sillHeight:headHeight:)`, `mergeRooms(rooms:into:)`, `splitRoom(room:line:newRoom:)`, each with `targets` entries. | Approved for build 5 (lead decision 1); the lead applies it before wave 5a (PlanEditor). |
| CR-2 | One low-confidence rule: `MeasuredValue.isLowConfidence(length:)` is 2 sigma above max(4 cm, 3 percent of the length), relative only for areas and volumes; `isLowConfidence(kind:)`; `MeasureDisplay` delegates to it. | Applied (lead decision 3). |
| CR-3 | MeshProcessing `MeshChunk` renamed `MergeChunk`; `Cleanup.swift` and `ObjectIsolation.swift` finished. | Done (merged). |
| CR-4 | Hardening: `RawScanFolder.resolve(_:) -> URL?` rejects absolute paths, `..`, empty or `.` components and anything outside the folder (`isSafeRelativePath`); `ProjectStore.readJSON(_:from:maxBytes:)` (default 32 MB, `project.json` 1 MB, `CoreError.fileTooLarge`); `listProjects()` accepts only canonical `<UUID>.mapperproj` folders whose manifest id matches; `writeData(_:to:protection:createParents:)` with `.completeFileProtectionUnlessOpen` by default for `edits/`, `exports/` and `thumbnail.jpg`; `inProgressRoot()` excluded from backup. | Applied now (lead decision 2), so Store codes against it in wave 4a. |
| CR-5 | `ProjectPackage` doc comment: the Object Capture checkpoint lives at `derived/objects/<id>/checkpoint/`, and the per-module derived files of 3.1 are listed. | Applied. |
| CR-6 | `writeData(... createParents: false)` and `ensureDirectory(_:inside:)` (no ghost folders from late writes); `ProjectPackage.pipelineAttemptURL`; `RawScanFolder.liveCapturedRoomURL` and `worldMapURL`; `MapperError.lowMemory`; `CoreError.fileTooLarge`; `ScanEngine.discard()`; doc comments on `ProjectStatus.capturing`, `PlanModel.northAngle` and `ObjectCategory` names. | Applied by the design review. |

## 4. Capture pipelines

### 4.1 The shared session (CaptureCore)

`ARSessionHub` owns one `ARSession` per capture session and is the only object that sets `session.delegate`. `install()` sets `session.delegateQueue = hub.queue` (serial "mapper.ar.delegate", QoS userInitiated) and `session.delegate = hub`; it is called before any RoomPlan object exists (RESEARCH 3.2 Disputed 1 and recommended 2). The hub fans every `ARSessionDelegate` callback out on its queue to attached recorders:

```swift
/// A raw-data recorder fed by ARSessionHub. Every method is called on hub.queue.
protocol ScanRecorder: AnyObject {
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval)
    func hub(_ hub: ARSessionHub, didUpdate frame: ARFrame)       // copy what you need, never retain
    func hub(_ hub: ARSessionHub, didAdd anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didUpdate anchors: [ARAnchor])
    func hub(_ hub: ARSessionHub, didRemove anchors: [ARAnchor])
    func finishRecording(completion: @escaping () -> Void)        // final flush, then stop writing; later callbacks are ignored
    func flushNow()                                               // memory pressure: write buffered data now
    var stats: RecorderStats { get }
}   // an extension gives empty defaults for the four hub callbacks and flushNow
```

`ScanConfigurationFactory.make(_ profile: ScanProfile) -> ARWorldTrackingConfiguration`, where `ScanProfile` holds the `ScanMode` and `ScanSettings`:
- `sceneReconstruction = .meshWithClassification` when `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`, else `.mesh`.
- `frameSemantics = [.sceneDepth]` when `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`; never smoothed depth.
- `planeDetection = []` unless `profile.wantsPlaneDetection` (Quick Measure only), which gives `[.horizontal, .vertical]` (D14).
- `environmentTexturing = .none`, `isLightEstimationEnabled = true`, default video format (never 4K, HDR or a hi-res format during RoomPlan, RESEARCH 3.8 Disputed 10).
- `initialWorldMap` only for relocalization (build 5, HouseUI).

`hub.reapplyConfiguration(reason:)` runs the same configuration with options `[]`. Never `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction` while RoomPlan uses the session (RESEARCH 3.1 Disputed 1, section 5).

Other CaptureCore parts: `TrackingMonitor` (tracking summary, relocalizations, limited-tracking fraction, pose codes), `ThermalGovernor` and `ThermalPolicy` (observes `ProcessInfo.thermalStateDidChangeNotification`, see 12.2), `StorageWatchdog` (10 s timer on `ProjectStore.freeBytes()`, D18), `MemoryProbe` (`os_proc_available_memory()`) and `MemoryPolicy` (`.low` under 600 MB and `.critical` under 400 MB for two consecutive status ticks, or at once on `UIApplication.didReceiveMemoryWarningNotification`, which the hub observes and forwards through `onMemoryPressure`), `CaptureWatchdogLogic` (depth and mesh arrival, pure and self-tested), `ARDelegateRelay` (installed only when the once-per-second identity check finds `session.delegate !== hub` and the Diagnostics setting `SettingsKey.captureRelay` is on, which it is by default; it keeps a strong reference to the replaced delegate and forwards every call first to it, synchronously on the incoming queue, then to the hub, and never changes `delegateQueue`; the late delegate swap is the one reported cause of a blacked-out view, RESEARCH 3.2 disputed 1, so the toggle lets a tester switch it off). The identity check logs both `session.delegate === hub` and `session.delegateQueue === queue` and re-asserts only the queue; every hub callback checks `DispatchQueue.getSpecific(key:)` and, on a foreign queue, copies what it needs and `queue.async`s the copies (never the `ARFrame`). `ARFrameReading` and `MeshAnchorCopier` (copy helpers honoring offset and stride), and `CaptureDiagnostics` (effective configuration, first-frame formats, per-second delegate identity, depth and mesh arrival, memory, projection round trip; D22). `HubStatus` carries tracking, degraded mode, thermal, storage, memory state, free bytes, available memory, depth presence, mesh anchor count, speeds, center distance and depth confidence at up to 4 Hz. The hub does no file IO; recorders write through Store. Owners set the hub closures with `[weak self]` captures and clear them in teardown, so no engine, hub and controller cycle keeps an `ARSession` alive; the hub and engines log a `deinit` line. `docs/REUSE.md` 4.4 is an older sketch superseded by MODULES 3.11 and 3.21 (no `override init()` hub, no re-apply in `didStartWith`).

### 4.2 Room (build 4, RoomCapture)

Preflight (`ScanPreflight`, ScanUI, main actor): blocking issues are camera denied, no LiDAR (`ScanConfigurationFactory.supportsMesh` and `RoomCaptureSession.isSupported`) and free space under `ProjectStore.refuseScanBelowBytes`; warnings are free space under `warnScanBelowBytes`, battery under 20 percent and thermal `.serious` or worse. Then ScanUI creates the project (`ProjectLibrary.create(kind: .room, name: Copy.Home.defaultRoomName(date))`), appends the `CaptureSessionRef`, creates the recorders (`MeshStore`, `KeyframeRecorder`, `PoseTrackRecorder`, `PhotoRecorder`) and `RoomScanEngine(target:recorders:)`, or `FakeScanEngine` in Demo Mode.

Creation order (`RoomScanEngine`; the members that touch UIKit are main actor, everything else runs on `hub.queue`):
1. `start()` (main, called by `ScanFlowModel`): checks `RoomCaptureSession.isSupported` and free space, creates the InProgress folder (3.4), attaches the recorders and calls their `beginRecording`. RoomPlan starts once the view exists.
2. `RoomCaptureContainer.makeUIView` calls `engine.makeCaptureView()` (main), which runs once (RESEARCH 3.10 gotcha 4): `hub.install()` (delegate queue and delegate first, before any RoomPlan object exists), `hub.run()` (`session.run(ScanConfigurationFactory.make(profile))`), then `RoomCaptureView(frame: .zero, arSession: hub.session)`, `view.captureSession.delegate = controller` and `view.delegate = controller`. The engine keeps the controller and the view's `captureSession` (both RoomPlan delegate slots are weak, RESEARCH 3.2 gotcha 3). `RoomCaptureController` is a plain `NSObject` conforming to `RoomCaptureSessionDelegate` and `RoomCaptureViewDelegate` with `encode(with:)` and `init?(coder:)` stubs (RESEARCH 3.10 gotcha 1), holding the engine weakly; delegate signatures are copied verbatim from RESEARCH 3.2. If CI reports an isolation error on the view delegate conformance, it moves to a `@MainActor` bridge object (MODULES 3.21). `RoomCaptureContainer.makeCoordinator()` returns the engine and the static `dismantleUIView(_:coordinator:)` calls `coordinator.teardown()` (a static method cannot read `self.engine`).
3. As soon as both `start()` and `makeCaptureView()` have happened: `captureSession.run(configuration: RoomCaptureSession.Configuration())`; `isCoachingEnabled` stays at its default `true` (D15).
4. `captureSession(_:didStartWith:)`: the controller hops to `hub.queue`; the engine calls `hub.markScanStart(timestamp:)`, logs the effective `hub.session.configuration` (frame semantics, scene reconstruction, plane detection, video format; D22) now, after 1 s and after 5 s, and logs whether `session.delegate === hub` and `session.delegateQueue === hub.queue`. It does not re-apply the configuration here: the view initializer preserves the session's settings (RESEARCH ruling 1). The re-apply belongs to the watchdog.
5. Watchdog (`CaptureWatchdogLogic`, fed every frame on `hub.queue`): no `frame.sceneDepth` for 2 s, or no `ARMeshAnchor` after 8 s of `.normal` tracking, triggers one `reapplyConfiguration(reason:)` and a `CaptureEvent(kind: .config)`. Still missing 2 s later, the hub sets `DegradedMode.depthStripped` (mesh arrives, depth does not) or `.meshStripped` (no mesh anchors) and writes a `CaptureEvent(kind: .degraded)`.

Per-callback work on `hub.queue` (copies only, no retained `ARFrame`, `ARAnchor` or buffer; RESEARCH 3.4 gotcha 4):
- Mesh (`MeshStore`, D8): for each `ARMeshAnchor` in `didAdd` or `didUpdate`, `MeshAnchorCopier.copy(_:updateCount:)` copies `vertices`, `normals` (per vertex), `faces` (UInt32 x 3) and `classification` (UInt8 per face) honoring each source's `offset`, `stride` and `format` (RESEARCH 3.1 gotcha 2, 3.9 gotcha 4) into a Core `MeshChunk` (anchor-local, `transform = anchor.transform`, update count plus 1), replaces the entry for `anchor.identifier` and marks it dirty. `didRemove` marks the entry stale and keeps it (anchors come back, RESEARCH 3.1 gotcha 15). Every 3 s the dirty chunks are handed as values to `RawScanWriter.perform`, where `MeshChunkFile.encode` output replaces `mesh/<anchor>.mchk`.
- Keyframes (`KeyframeRecorder`, D7): the selector is consulted only when a `FrameCopier` buffer is free, tracking is `.normal`, storage and memory are `.ok` and the engine is not paused, so a skipped frame never teaches the selector a pose it has no photo for; the gate is Texturing's `KeyframeSelector` with `Config.maxTranslation` and `maxRotationDegrees` from `ScanSettings.keyframeGate` (Standard 0.30 m or 15 degrees; times 1.5 when Keep all photos is off, D6), `maxAngularVelocity` 1.0 rad/s, exposure offset within plus or minus 2 EV and `maxKeyframes` unbounded (never thinned, D6); frames count only with tracking `.normal`, storage state `.ok` and the thermal policy's interval scale. For an accepted frame, `FrameCopier` copies both planes of `capturedImage` into one of 4 preallocated buffers of the first frame's size and pixel format (read at runtime, RESEARCH 3.4 gotcha 6), and `ARFrameReading.depthMap(of:)` copies `sceneDepth.depthMap` and `confidenceMap` into a Core `DepthMap`. If no buffer is free the keyframe is skipped and counted. The frame is released when the callback returns. On the io queue: JPEG encode of the copied buffer (one shared `CIContext`, quality 0.85), `DepthFile.encode`, atomic writes of `keyframes/NNNNN.jpg` and `depth/NNNNN.dpth`, `FrameCopier.release`, then the `KeyframeRecord` line (per-frame `Intrinsics`, `transform`, `exposureDuration`, `exposureOffset`, `ambientIntensity`, `angularSpeed`, `trackingNormal`). At most 4 keyframes are in flight.
- Pose track (`PoseTrackRecorder`, D8): a `PoseSample` every 0.1 s by timestamp (tracking code 0, 1, 2 from `TrackingMonitor.poseCode`; thermal level index; exposure duration), appended to `poses.ptrk` about once a second and at finish.
- Photos (`PhotoRecorder`): Take Photo marks the next frame with normal tracking; it is written as `photos/<id>.jpg` (quality 0.9) plus a `PhotoPin` line.
- Events: tracking changes, thermal changes, RoomPlan instruction changes, configuration lines, memory every 30 s and every memory state change or warning, degraded mode, errors and interruptions, into `events.jsonl`.
- Live room safety net: the latest `didUpdate` `CapturedRoom` is written to `capturedroom-live.json` at most every 10 s and at once on `sessionWasInterrupted` (through `RawScanWriter.perform`), so a scan killed by iOS keeps a provisional room (TEST_PLAN PERF-16 to PERF-18).
- Live snapshot: at 4 Hz the engine builds a `LiveScanSnapshot` (counts, tracking, thermal, free bytes, memory, degraded mode, guidance) and delivers `.snapshot` on main (D1).

RoomPlan callbacks (`RoomCaptureController`; the callback thread is undocumented, so the controller copies values and hops to `hub.queue`): `didUpdate room` keeps live counts (`RoomScanStats.counts` over `RoomInput(room)`) and, in build 5, feeds `liveRoomHandler` at most once a second; `didProvide instruction` accumulates seconds per instruction (`RoomScanStats.accumulate`, names from `GuidanceSignals.name(of:)`) for `RoomCaptureLog.instructionSeconds` and sets the coaching flag (`GuidanceSignals.isCoaching`); `didEndWith` is handled in the Done sequence. Every switch over `Instruction` and `CaptureError` has `@unknown default`.

Guidance (GuidanceUI, D15): `RoomScanStats.guidanceInput(time:status:newDoors:newWindows:newWalls:)` fills a Coverage `GuidanceInput` with tracking, `deviceHot` (thermal serious or worse) and new detection counts only. Angular speed, center distance, ambient intensity and depth confidence stay unset in Room mode, so `moveSlower`, `tooClose`, `tooFar`, `moveCloser` and `lightingPoor` never fire over RoomPlan's own coaching (RESEARCH 3.10 gotcha 6, 3.8 gotcha 23). `GuidanceEngine.update` applies the display rules; `GuidanceFilter(roomPlanCoaching:)` then passes only `deviceHot`, `trackingLost` and `trackingLow` while RoomPlan's instruction is not `.normal` (RoomPlan has no instruction for heat or tracking), so tier 3 detection messages never compete with Apple's coaching. In Room mode "Move slower", "Move closer" and "Lighting is poor" therefore come from RoomPlan's coaching (`slowDown`, `moveCloseToWall`, `turnOnLight`); Mapper's own texts for them run in mesh-only scans from build 5. `GuidanceBanner` shows the result and `GuidanceAnnouncer` posts the VoiceOver announcement and the tier 1 haptic (with the user's `SettingsKey.guidanceHaptics` setting). Tier 2 coverage hints arrive with CoverageLive in build 5.

Done and Finish (D19; Core's `ScanEngine.finish()` already means "finish and seal"):
1. Done (`ScanFlowModel.done()`, phase `stopping`) calls `engine.finish()`. The engine calls `captureSession.stop(pauseARSession: false)` (explicit `false`, RESEARCH 3.2 recommended 6). The `ARSession` keeps running, so the camera stays live behind the sheet. The engine also finishes by itself at thermal `.critical` or `CaptureError.deviceTooHot`, storage `.pause` and memory `.critical`; ScanUI maps the resulting `.stateChanged(.stopping)` to `capturing -> stopping`.
2. `captureSession(_:didEndWith:error:)` is synchronous, while `RoomBuilder` is `async`, so the controller copies the values and one `Task` runs the whole finish sequence in order (`RoomScanStats.finishSteps`, MODULES 3.21), inside `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` so a user who leaves the app does not cut it short: (a) `capturedroomdata.json` is queued first (a crash still leaves rebuildable data); (b) when `error` is nil or `exceedSceneSizeLimit`, `try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from:)` and `capturedroom.json` is queued; a throw is logged (the built room is the truth, not the last `didUpdate`, RESEARCH 3.2 gotcha 6; `captureView(shouldPresent:error:)` returns `false`, our sheet replaces Apple's preview); (c) the ARWorldMap is saved best effort (at most 3 s, mesh anchors stripped) when `worldMappingStatus` is `.mapped` or `.extending`; (d) the recorders are detached from the hub, then each `finishRecording(completion:)` is awaited; (e) `roomlog.json` (`RoomCaptureLog`: seconds, instruction seconds, error, relocalizations, limited tracking fraction, degraded mode) and `session.json` for the first room of the session (`CaptureDiagnostics.sessionRecord(id:)`: OS version, `UIDevice.current.model`, configuration lines; never a device name or identifier); (f) `RawScanWriter.flush`, then `close()`; (g) seal and move (3.4); (h) for an engine-initiated finish `hub.pause()` now (RESEARCH 3.1 recommended 10: pause at critical) and `RoomScanResult.stoppedBySystem = true`; (i) on main: `lastResult`, `state`, `.roomFinished(roomID:)`, then for a system stop `.failed(.deviceTooHot)`, `.failed(.lowStorage(freeBytes:))` or `.failed(.lowMemory)`. No file is written after `SEAL.json`.
3. ScanUI appends the `RoomRecord` and sets the project `.needsProcessing` in one `ProjectLibrary.update` (`.ready` in Demo Mode), sets phase `checking` ("Checking your scan..."), and runs `QualityEvaluator.evaluateSealedRoom(package:record:now:)` in a detached task (budget under 5 s on the A15). It reads the sealed folder only: the clean room from `capturedroom.json` through RoomModel with no mesh terms, `MeshConsolidator.fastWorldMesh` over the raw chunks, the pose track and the keyframe records. `QualityStore.save` writes `quality.json` (input hash extra `"done"`, so the pipeline's `QualityStep` always replaces it) and `RoomRecord.quality`; phase `quality` shows `QualitySheet` as a medium-detent sheet over the camera (live after Done, paused after a system stop).
4. Finish or Finish Anyway (`ScanFlowModel.finish()`) calls `engine.teardown()` (pauses the `ARSession`, detaches recorders, clears the hub closures, releases the view; idempotent and also called on every other terminal phase) and hands the project id to AppShell, which enqueues processing at the front of the queue and opens Results.
5. Discard on the sheet (same confirmation as Cancel; lead decision 4) tears the engine down and calls `ProjectLibrary.discardRoom(_:in:)`, which deletes only the scan just captured and the project when no room is left (always, for a build 4 Room project). A stopped RoomPlan pass cannot be continued without producing a second `CapturedRoom`, so "keep scanning" arrives in build 5 as Show Missing Areas: a patch pass (`MeshScanEngine`, new `mesh-pass/` folder, new recorders) on the same running session (D19, kept by lead decision 4), offered only when the room was not stopped by the system.

Errors (from `didEndWith`, `RoomBuilder` or the session), each mapped by `RoomScanStats.mapError` to a `MapperError` and a `Copy` string:

| Error | Behavior |
|---|---|
| `CaptureError.exceedSceneSizeLimit` | Keep the partial room (RoomBuilder still runs), review normally, `Copy.RoomCapture.sceneTooLarge` suggests scanning the rest as a new project (build 4 has one room per project). |
| `CaptureError.deviceTooHot` or thermal `.critical` | The engine finishes the room itself, pauses the session after the seal, then emits `.failed(.deviceTooHot)` after `.roomFinished`; the alert shows `Copy.RoomCapture.tooHotFinished` ("Scanning stopped...") and the quality sheet still opens. |
| Storage state `.pause` (under 300 MB) | Same as heat, with `.failed(.lowStorage(freeBytes:))`. |
| Memory `.critical` (under 400 MB for two ticks) or a memory warning | `flushNow()` on every recorder, then the same as heat, with `.failed(.lowMemory)` and `Copy.RoomCapture.lowMemory`; at `.low` (under 600 MB) keyframes stop first. |
| `CaptureError.worldTrackingFailure` | Review with what exists; `Copy.Errors.trackingFailed`. |
| `CaptureError.invalidARConfiguration` | Logged with the effective configuration (a watchdog re-apply is the suspect); degraded `.roomPlanFailed` when there is no room data. |
| `CaptureError.deviceNotSupported`, `internalError`, unknown | Degraded `.roomPlanFailed`: Raw Scan and Realistic only; `Copy.RoomCapture.roomPlanFailed`. The pipeline does not schedule `BuildRoomStep` for such a room, so consolidation, quality and texturing still run (5.3). |
| `RoomBuilder` throws | The room is sealed with `capturedroomdata.json` and no `capturedroom.json`; the error is logged and the optional `BuildRoomStep` retries once in the pipeline, completing without output (never failing the job) if RoomBuilder throws again. |

Interruptions: `sessionWasInterrupted` sets the engine state `.paused` (and writes the live room file) and the chrome shows `Copy.Scanning.paused` with Resume and Finish Now buttons; `sessionShouldAttemptRelocalization` returns `true`; after `sessionInterruptionEnded` the engine stays `.paused` until the user taps Resume, so they can walk back first as the text says (RoomPlan itself has no pause; no keyframes are taken while paused). After 30 s paused, the alert offers Finish Now or Resume (`Copy.ScanUI.pausedFinishPrompt`). A `didEndWith` with an error during the interruption ends the RoomPlan pass and goes to review.

Timer: a hint at 4 minutes (`Copy.ScanUI.timeHint`) and the time-limit sheet at 5 minutes (`Copy.ScanUI.timeLimitTitle`; Apple's scan-length advice, RESEARCH 3.2 recommended 10); never an automatic stop for time (a listed departure, section 1): the memory floor above is the safety stop.

Degraded modes (D16), shown as one line on the quality sheet (`QualityPresentation.degradedNote`) and in Results, and stored in `RoomCaptureLog.degraded`:

| Mode | Detected by | Build 4 behavior | Later |
|---|---|---|---|
| `allGood` | depth and mesh arrive | everything | |
| `depthStripped` | watchdog, mesh without depth | keyframes without depth (`depthFile` nil); texturing uses its own mesh z-buffer; confidence uses unknown depth confidence | build 5 coverage falls back to mesh faces |
| `meshStripped` | watchdog, no mesh anchors | Raw Scan and Realistic say "not available for this scan"; Clean, Plan and dimensions work (heights from RoomPlan) | build 5 two-pass fallback: a same-session mesh and photo pass in LiveMeshView after RoomPlan's Done |
| `roomPlanFailed` | RoomPlan error or no room data | Raw Scan and Realistic only (no room measurements; in-model measuring is build 5); the Floor Plan tab explains why; no `BuildRoomStep` is scheduled | |

### 4.3 House and building (build 5, HouseUI plus RoomCapture)

- One `RoomCaptureView` and one `ARSession` for the whole visit (RESEARCH 3.2 recommended 6 and Disputed 3). Per room: `RoomScanEngine.startNextRoom(roomID:)` (same view and session, new InProgress folder, recorders begin again), `run(configuration:)`, Done (`finish()` with `stop(pauseARSession: false)`, seal), review, then the HouseUI room list as a sheet over the dimmed camera ("Dining Room done", "Hallway needs additional scan"). The view is never recreated between rooms.
- Every room in the running session gets `FrameLink.projectFrame(sessionID:)`. HouseUI saves the world map after each room (`getCurrentWorldMap` when `worldMappingStatus` is `.mapped` or `.extending`, mesh anchors stripped, archived on the io queue).
- Memory (D17): after a room's final flush `MeshStore.evict()` drops geometry and keeps the index; `os_proc_available_memory()` is logged per room; under 800 MB the list suggests "Finish this floor".
- Returning another day: a new `CaptureSessionRef`, configuration with `initialWorldMap`, run with `[.resetTracking, .removeExistingAnchors]` (allowed here, before RoomPlan starts), a LiveMeshView screen with `ARCoachingOverlayView` (goal `.tracking`) until tracking is `.normal`, then the `ARView` is dismantled, `hub.install()` re-asserts the delegate and the `RoomCaptureView` is created. Success within 30 s gives `.relocalized(sessionID:from:)`; otherwise "Start fresh here" gives `.unaligned` and the room is placed later with manual alignment. `exceedSceneSizeLimit` right after relocalization (RESEARCH 3.2 Disputed 7) also offers Start fresh.
- Floors: Add Floor starts rooms with a new `floorIndex`; `StructureFloors.group(elevations:gap:)` groups levels by floor elevation (gap 1.2 m) with `story` as a hint only.
- Finish Building enqueues `mergeStructure` and `alignRooms` (5.9).

### 4.4 Object, small or medium (build 5, ObjectCapture)

- Size chooser first (D4, ObjectUI). Gate on `ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported`; storage preflight `objectCapturePreflightBytes` (3 GB, D18).
- Any `ARSessionHub` is released first: `ObjectCaptureSession` owns the camera (RESEARCH 3.8 gotcha 20).
- `@MainActor final class ObjectScanModel: ObservableObject` owns `ObjectCaptureSession?`, started once with fresh, empty `Images/` and `Checkpoint/` folders inside the scan's InProgress folder (RESEARCH 3.3 gotcha 2), `configuration.checkpointDirectory` set, `isOverCaptureEnabled = false`. Stored Tasks iterate `stateUpdates`, `feedbackUpdates`, `userCompletedScanPassUpdates`, `numberOfShotsTakenUpdates` and `cameraTrackingUpdates`.
- Flow per Apple's sample: `.ready` Continue calls `startDetecting()` (a `false` result shows a hint), `.detecting` Start Capture calls `startCapturing()`, a completed pass shows the review as an overlay while `ObjectCaptureView` stays mounted (leak report, RESEARCH 3.10 gotcha 13; D17) with `pause()` and `resume()`, then `beginNewScanPass()` or `beginNewScanPassAfterFlip()`, then `finish()` and wait for `.completed`. The shot counter uses `numberOfShotsTaken` and `maximumNumberOfInputImages`, never a constant.
- Feedback to `GuidanceKind` through `GuidanceSignals.guidance(for:)`: `movingTooFast` to `moveSlower`, `objectTooClose` to `tooClose`, `objectTooFar` to `tooFar`, `environmentTooDark` and `environmentLowLight` to `lightingPoor`, `outOfFieldOfView` to `objectKeepInView`; `overCapturing` turns the counter red; `@unknown default` ignored. Our overlay hides while `cameraTracking` is not `.normal` (RESEARCH 3.10 gotcha 14). Haptics come from the session (`shouldPlayHaptics`), not ours.
- After `.completed`: the session is set to nil (RESEARCH 3.3 gotcha 10), the checkpoint moves to `derived/objects/<id>/checkpoint/` (CR-5), `Images/` and `objectlog.json` are sealed and moved to `raw/objects/<id>/`, `manifest.reconstructionPending = true`, and Pipeline runs `PhotogrammetryStep` (`reconstructObject`, 5.10).

### 4.5 Object, large (build 5, LargeObject on LiveMeshView)

- Driver: `MeshScanEngine` with an `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)` whose `session` is the hub's; right after assigning it, `hub.install()` re-asserts the delegate and the identity is logged (whoever assigns last wins). Profile: mode `.object`, mesh and depth on, no planes. Recorders: `MeshStore`, `KeyframeRecorder` (Advanced close-up gate), `PoseTrackRecorder`, `CoverageLiveRecorder`.
- Seed: the user taps the object; `arView.ray(through:)` is intersected with the live chunks by `MeshBVH`, falling back to `arView.raycast(from:allowing: .estimatedPlane, alignment: .any)`.
- Box: `OrientedBox.fit(_:gravityAligned: true)` over mesh vertices within 2 m of the seed and above the floor, where the floor height comes from floor-classified faces, not plane anchors (D14).
- `SectorCoverage` (LargeObject): 8 azimuth sectors plus top around the box, filled from camera positions and face observations; the least-covered sector relative to the camera raises `objectCaptureLeft`, `objectCaptureRight`, `objectCaptureBack` or `objectCaptureTop`, and thin areas raise `objectMoveCloserToArea` or `objectNeedsDetail`.
- The raw folder is `raw/objects/<id>/` in RawScanFolder layout (`ObjectRecord.size == .large`). The crop box is an edit, `EditOperation.cropObject(object:box:)`; isolation, dimensions and volume come from MeshProcessing's `ObjectIsolation.isolate(_:box:options:)` in `ObjectMetricsStep`.

### 4.6 Quick Measure (build 5, LiveMeasure)

- Own `ARSessionHub` in an `ARView(.ar, automaticallyConfigureSession: false)`, profile `ScanProfile(mode: .quickMeasure, settings: ScanSettings.defaults(for: .quickMeasure))` (planes on, mesh on, depth on, no RoomPlan, no keyframes, no raw folder until Save).
- Center reticle plus a large Add Point button. Each frame the reticle is resolved in the RESEARCH 3.8 snapping order: existing points, `ARPlaneAnchor` boundary corners and plane-plane-floor intersections (with `planeExtent` and its `rotationOnYAxis`, RESEARCH 3.1 gotcha 17), `.existingPlaneGeometry`, then `.estimatedPlane`; radius the smaller of 10 cm in the world and 24 pt on screen; `Haptics.selection()` on snap.
- Each committed point keeps a Coverage `MeasurementEvidence` (camera distance, depth confidence from the `sceneDepth` confidence sample, tracking fraction, snap kind); `ConfidenceAdapter.distance(start:end:length:)` gives the live plus-or-minus.
- Save creates a `.quickMeasure` project with `raw/measure/quick.json` and an `ARView.snapshot` thumbnail.

### 4.7 Advanced (build 6, AdvancedScan)

Advanced options only produce `ScanSettings` and pick a driver:

| Option | Effect |
|---|---|
| What: A space, find walls on | Room driver (4.2) |
| What: A space, find walls off | LiveMeshView driver (`MeshScanEngine`): mesh, keyframes, coverage overlay, no RoomPlan; outputs Raw Scan, Realistic and measurements, no floor plan (the tab says why) |
| What: An object | Size chooser, then 4.4 or 4.5 |
| Detail | `ScanSettings.keyframeGate` (Standard 0.30 m or 15 degrees, High 0.20 m or 10, Maximum 0.12 m or 7); texture density |
| Keep all photos | Off multiplies the gate by 1.5 at capture time. Raw is never thinned afterwards (D6). |
| Find furniture | Off drops movable objects when the clean model is built; raw keeps them |
| Scanning distance | `ScanSettings.depthWindow` for coverage and keyframe depth; faces outside it are dropped in the derived mesh only (`ConsolidationOptions.depthWindow`) |

## 5. Processing pipelines

### 5.1 The runner (Pipeline)

`@MainActor final class ProcessingRunner: ObservableObject` processes one project at a time, one step at a time, publishing a `ProjectProcessingState` per project for progressive results (D20). A `ProcessingJob` is a project plus an ordered list of `ScheduledStep`s (a Core `ProcessingStep`, its subject, an optional flag and `dependsOn`, the steps of the same job whose output it reads); AppShell's `ProcessingPlans` builds the lists, so Pipeline imports no step module. For each step:
1. Build a `StepContext` (manifest from `ProjectStore.readManifest`, `availableMemory` from `os_proc_available_memory()`, `isCancelled` reading a lock-protected per-job flag, `progress` hopping to main at most 10 times a second, `ProcessingGuards.shouldPublish`).
2. Compute `inputHash(ctx)` off main (`Task.detached(priority: .userInitiated)`); when `DerivedIndex.isFresh(step:subject:version:inputHash:)`, skip.
3. Crash-loop guard (`PipelineAttempt`, `derived/pipeline_attempt.json`): the runner writes the marker (step, subject, variant, count) atomically before `step.run` and deletes it after recording the stamp or the failure. If a job starts and finds a marker for its step, the app died inside that step: after one death the step reruns forcing its reduced variant (refused when it has none); after two it is recorded as failed with `MapperError.outOfMemory(step:)` without running, so a step whose real peak exceeds the jetsam ceiling cannot kill every launch.
4. Memory gate (D17, `ProcessingGuards.variant`): full when available memory is at least the budget plus 300 MB headroom, reduced when a reduced budget fits with the same headroom, otherwise `MapperError.outOfMemory(step:)`. The step itself picks full or reduced from `ctx.availableMemory`; to force the reduced variant (crash-loop guard, heat) the runner passes an `availableMemory` capped just below the full budget plus headroom.
5. Thermal gate: at `.serious` the runner forces reduced variants and waits 30 s before any step whose budget is over 300 MB (RESEARCH 3.1 recommended 10: pause heavy post-processing); at `.critical`, `ProcessingGuards.waitWhileCritical` polls every 5 s before a step starts (`isPausedForHeat` shows in the UI).
6. `try await step.run(ctx)` inside `Task.detached(priority: .userInitiated)`; data-parallel loops inside a step may use `DispatchQueue.concurrentPerform`.
7. On success the runner records the `DerivedStamp` and writes the index atomically (it is the index's only writer). A failed step (optional or required) is recorded in `failed`; every step that depends on it, directly or transitively, is not run and is recorded as failed ("dependency failed"); independent steps still run. The job ends with `.failed(step:error:)` naming the first failed required step once nothing runnable is left, else `.completed`. Only the representation that depended on the failed step is marked unavailable.

The idle timer is owned by Pipeline's `IdleTimerGuard`, the only code that writes `UIApplication.shared.isIdleTimerDisabled`: it is disabled while at least one holder exists (the runner while any job runs, ScanUI while the scan screen is visible), so a job ending during a scan or a scan screen closing during processing never re-enables auto-lock under the other. Every step start, end, skip, give-up and failure is logged (category "pipeline") with wall time and available memory before and after. Resumability: steps are idempotent and write outputs before stamps; after Home appears `ProcessingPlans.resumePending()` re-enqueues projects in `.needsProcessing` or `.processing` (a cancelled job leaves `.processing`, never `.ready`), and a project with `reconstructionPending` runs `reconstructObject` before anything else loads (D17, build 5). When the app leaves the foreground on iOS 18 the process is suspended and the step continues on return (RESEARCH 3.9 gotcha 12); while the app is inactive or in the background the runner marks the running step's attempt marker (`backgroundedAt`), so an app that iOS or the user ends there is not counted as a death by the crash-loop guard, and a reduced run is stamped with a `+reduced` suffix, so it is never fresh and the next job for the project (Retry, a resume) redoes it; build 6 adds `BGContinuedProcessingTaskRequest` for CPU steps behind `#available(iOS 26, *)` (BackgroundWork). The runner never runs while a capture is active: AppShell calls `ProcessingRunner.suspendAll(reason:)` when a scan is requested (the running step is cancelled at its next check and stays queued; stamped steps skip on rerun) and `resumeAll()` when the scan cover closes, and a job enqueued by Finish goes to the front of the queue.

### 5.2 Steps

| `PipelineStepID` | Step class (module) | Subject | Inputs | Outputs | Budget full / reduced | Required | Build |
|---|---|---|---|---|---|---|---|
| `buildRoom` | `BuildRoomStep` (RoomModel) | room | raw `capturedroomdata.json`, scheduled only when raw lacks `capturedroom.json` and `roomlog.json` is not `.roomPlanFailed`; a RoomBuilder error completes without output | `derived/rooms/<id>/capturedroom.json` | 150 MB / none | no | 4 |
| `consolidateMesh` | `ConsolidateMeshStep` (MeshModel) | room | raw chunks of the room and its mesh passes, `settings.distance` | `mesh.mchk`, `mesh_inferred.mchk`, `mesh_view.mchk`, `mesh_floaters.mchk`, `mesh_stats.json` | 700 MB / 350 MB | no | 4 |
| `cleanModel` | `CleanModelStep` (RoomModel) | project | `capturedroom.json` per room (or the structure in build 5), consolidated mesh through `meshProvider` for heights (D13), `settings.findFurniture` | `derived/clean.json` | 200 MB / none | yes | 4 |
| `floorPlan` | `FloorPlanStep` (FloorPlan) | project | `clean.json` | `derived/plan.json` | 50 MB | yes | 4 |
| `quality` | `QualityStep` (Quality) | room | `capturedroom.json`, `mesh.mchk`, `poses.ptrk`, `keyframes.jsonl`; hash adds the room's `buildRoom` and `consolidateMesh` stamps | `quality.json`, `RoomRecord.quality` | 300 MB | no | 4 |
| `thumbnail` | `ThumbnailStep` (FloorPlan) | project | edited plan level 0, else the first keyframe or object image | `thumbnail.jpg` | 50 MB | no | 4 |
| `textureLow` | `TextureLowStep` (TextureJob) | room | `mesh_view.mchk`, up to 150 keyframes | `texture/` | 600 MB / 350 MB | no | 4 (the step alone may slip to 5) |
| `mergeStructure` | `MergeStructureStep` (Structure) | project | `capturedroom.json` of frame-shared rooms | `structure/structure.json` | 250 MB | yes (house) | 5 |
| `alignRooms` | `AlignRoomsStep` (Structure) | project | `structure.json`, input rooms, `setRoomAlignment` edits | `structure/alignment.json` | 50 MB | yes (house) | 5 |
| `reconstructObject` | `PhotogrammetryStep` (ObjectCapture) | object | `Images/`, checkpoint | `model.usdz` | Apple-managed; runs alone | yes | 5 |
| `objectMetrics` | `ObjectMetricsStep` (ObjectModel) | object | `model.usdz`, or the large-object mesh plus the `cropObject` edit | `dims.json` | 150 MB | yes | 5 |
| `textureHigh` | `TextureHighStep` (TextureJob) | room | `mesh.mchk` up to 1M faces, keyframes | `texture-high/` | 1 GB / 500 MB | no | 6 |

Budgets are starting values (the jetsam ceiling is unmeasured, RESEARCH 3.9 disputed 6); every step logs its peak and wall time, the build 4 diagnostics tune them, and the crash-loop guard of 5.1 covers a budget that is too low. A step whose inputs are absent completes without output (for example `ConsolidateMeshStep` with no chunks in `meshStripped`, `CleanModelStep` leaving out a room with no `CapturedRoom`), so its dependents report "unavailable" rather than failing the job.

### 5.3 Order per mode (`ProcessingPlans`)

| Mode | Order (a step follows the steps it reads) | Results opens after (D20) |
|---|---|---|
| Room | per room `buildRoom` (if needed and not `roomPlanFailed`), per room `consolidateMesh`, `cleanModel` (depends on `buildRoom`), `floorPlan` (depends on `cleanModel`), per room `quality`, `thumbnail` (depends on `floorPlan`), per room `textureLow`; `consolidateMesh`, `quality` and `textureLow` are independent, so a RoomPlan failure still yields Raw Scan and Realistic | `plan.json` exists (ResultScreen shows the processing view only while the job is queued or running and there is no plan) |
| House (5) | per room `buildRoom`; `mergeStructure`, `alignRooms`; per room `consolidateMesh`; `cleanModel`, `floorPlan`; per room `quality`; `thumbnail`; per room `textureLow` | Finish Building |
| Object small (5) | `reconstructObject`, `objectMetrics`, `thumbnail` | `objectMetrics` |
| Object large (5) | `consolidateMesh`, `objectMetrics`, `textureLow`, `thumbnail` | `objectMetrics` |
| Space (6) | `consolidateMesh`, `quality` (mesh only), `textureLow`, `thumbnail` | `consolidateMesh` |
| Quick Measure (5) | `thumbnail` | immediately |
| Demo Mode | none (the demo project is written complete and `.ready`) | immediately |

`consolidateMesh` precedes `cleanModel` because the D13 ceiling and floor heights read the consolidated mesh through `meshProvider`; it is not a hard dependency: if it fails or finds no chunks, `cleanModel` uses RoomPlan heights with provenance `.estimated`.

### 5.4 Mesh consolidation (MeshModel around MeshProcessing)

1. `MeshConsolidator.latestChunks(in:)` decodes every `.mchk` of the room's folder and its mesh passes through `MeshChunkFile.decode`; a later folder wins for the same anchor id, and within a folder the highest update count wins.
2. `MeshConsolidator.mergeChunks` converts each Core `MeshChunk` to MeshProcessing's `MergeChunk(localMesh: chunk.toTriangleMesh(world: false), anchorTransform: chunk.transform, faceClass: chunk.classes, vertexColor: nil)`.
3. `ChunkMerge.merge(_:weldTolerance: 0.005)` gives a welded world-space `MeshWithAttributes`; `ChunkMerge.removingDegenerateAndDuplicateFaces` tidies it.
4. `MeshCleanup.removingFloaters(_:minimumArea: 0.01, minimumTriangles: 50)` drops floating islands (the largest component is always kept); the dropped faces are kept as `mesh_floaters.mchk` so Raw Scan shows the scan with its noise as captured (TEST_PLAN ROOM-02), while 3D Clean, texturing and exports use the cleaned mesh. Faces outside the Advanced distance window are dropped here, in derived data only.
5. `HoleFill.fillSmallHoles(_:maxPerimeter: 0.5)`; filled faces carry `isInferred` and are split out into `mesh_inferred.mchk` (shown in the Inferred color and labeled Inferred; large holes stay open).
6. `mesh.mchk` holds the measured mesh only (identity transform, room id as anchor id) and is never simplified.
7. View mesh: `MeshSimplify.simplify(_:options:)` of the measured faces only with `targetTriangleCount` 300k (reduced variant 150k), `preserveClassBoundaries` true; written as `mesh_view.mchk` with `mesh_stats.json`. The chunk format has no inferred flag, so the inferred faces stay only in `mesh_inferred.mchk` (full resolution, small holes only) and Raw Scan draws the two files side by side; `MeshModelStore.loadView` returns `isInferred == nil`. The viewer groups faces into 2 m tiles in memory (`ViewerContentBuilder.tiles`).

Reduced variant: each chunk is simplified to half its faces before merging and the view budget is 150k, so peak memory scales down with the input.

### 5.5 Texturing (TextureJob around TextureBaker, D24)

- Mesh: `TXMesh(positions:indices:)` from `mesh_view.mchk` (fallback: the measured mesh simplified to 200k faces).
- Keyframes: `KeyframeLoader.keyframes(in:maxCount:)` reads `keyframes.jsonl` through `RawScanReader`, keeps records with `trackingNormal`, subsamples evenly to at most 150 for the bake (raw keeps all, D6), and creates each `TXKeyframe.image` lazily with ImageIO (`kCGImageSourceShouldCache: false`), so JPEG decoding happens only when the baker draws; `intrinsics` from `KeyframeRecord.intrinsics.matrix`, `imageResolution` from its width and height, `cameraToWorld` from `transform.simd`, `exposureOffset` from the record.
- Options: `TextureDensity.textured` (build 4) is `TXOptions` with `atlasSize` 2048, `texelsPerMeter` 100, `maxAtlases` 4, `normalizeExposure` false; its reduced variant uses a 150k-face mesh and 1024 atlases. `TextureDensity.photoRealistic` (build 6, Photo Realistic) uses 4096 atlases, 250 to 500 texels per meter by `DetailLevel`, 8 atlases and `normalizeExposure` true (`TXExposure` gain normalization).
- Run: `TextureBaker(options:).bake(mesh:keyframes:progress:)` off main; progress goes to `ctx.progress`, and `ctx.isCancelled` is forwarded to `baker.cancel()`.
- Output (`TextureStore.save`): each atlas page is written as `page_<n>.jpg` (JPEG 0.85 through `CGImageDestination`) and released; `texcoords` (bottom-left origin, 3 per face) and `faceAtlas` go into `textured.tuv`; the exact baked mesh goes into `textured.mchk`. The input hash includes the room's `consolidateMesh` stamp (3.5). Accepted for build 6 (lead decision 6): a Texturing revision in wave 6a adds an atlas callback so finished atlases stream to disk and the baker's peak drops (it estimates about 830 MB at 1M faces); `TextureHighStep` uses it.
- Slip rule: `TextureDensity`, `TexturedMesh`, `TexturedPagePart` and `TextureStore` never slip (Results and ExportUI import them in 4c); only `KeyframeLoader` and `TextureLowStep` may move to 5a, and then AppShell leaves the step out and Realistic shows its fallback.
- Display and export split vertices per face corner (`TexturedMesh.pageParts()`), so vertex count grows (RESEARCH 3.4 gotcha 17).
- `TXError.noKeyframes` or a failure: Realistic falls back (7.3) and the geometry stays usable (TEST_PLAN TEX-06).

### 5.6 Clean model (RoomModel)

- Source: decoded `CapturedRoom` (raw `capturedroom.json`, else the derived one, else the provisional `capturedroom-live.json` of a killed capture, which sets `RoomInput.isProvisional` and gives every element provenance `.estimated`) mirrored into the testable `RoomInput`; never re-imported USDZ (RESEARCH 3.2 recommended 8).
- Walls: `RoomOutline.wallSegments` takes endpoints `transform * (+-dimensions.x / 2, 0, 0, 1)` with the `columns.1.y` guard, and winding from loop connectivity, not column signs (RESEARCH 3.6); height `dimensions.y`; arcs from `curve`.
- `RoomOutline.build` (D12), the one outline used by Quality, `CleanModelBuilder` and `PlanBuilder`: join endpoints within 15 cm, intersect adjacent lines unless nearly parallel, send stubs and partitions to `strayWalls`, output a closed counter-clockwise outline in `PlanAxes`. Area and perimeter from the loop. `floors[0].polygonCorners` (through the floor transform) is only a cross-check; a mismatch over 5 percent is logged. When the loop cannot close, the floor polygon is used with provenance `.estimated`. An L-shaped fixture is part of `RoomModelSelfTest`.
- Openings: attached by `parentIdentifier`, projected onto the parent wall and clamped; a nil parent falls back to the nearest parallel wall within 0.3 m; `door(isOpen:)` maps through `OpeningKind.init?(_:)`; sill and head relative to the floor elevation; default door swing hinged at the end nearer a corner, source `.estimated`.
- Heights (D13, `RoomMetricsCalculator.ceilingFromMesh` and `floorFromMesh`): median Y of ceiling-classified faces (class 3) inside the outline minus the floor elevation; `.measured` when ceiling faces cover at least 25 percent of the outline area, otherwise RoomPlan's maximum wall height as `.estimated`. Floor elevation uses the same rule with RoomPlan's floor as fallback.
- Thickness: 0.115 m, `.estimated`, for every wall of a single room; Structure sets 0.15 m for exterior walls or a measured value from antiparallel wall pairs 0.05 to 0.5 m apart (build 5).
- Objects: `DetectedObject` with `ObjectCategory(object.category)`, `DetectionConfidence(object.confidence)`, transform and dimensions; `findFurniture` off drops movable objects.
- Occlusion (build 4 heuristic, `RoomMetricsCalculator.applyOcclusion`): wall spans behind movable objects closer than 0.3 m become `occludedSpans`, floor under movable footprints becomes `occludedArea`; both are shown as Occluded, never as measured: `CleanMeshBuilder` emits `.occluded` parts (a wall-plane quad per span, up to the blocking object's top plus 0.1 m, and each movable object's footprint 5 mm above the floor, provenance `.inferred`) that Results draws gray and hatched while Hide Furniture is on, and the plan draws the spans dashed. Build 7's SurfaceEvidence replaces the heuristic with ray tests.
- Metrics (`RoomMetrics`): floor area and perimeter from the loop, length and width from `Rectangle2D.minimumArea(enclosing:)`, ceiling height and provenance, wall area minus openings, volume with the ceiling's provenance.
- `CleanMeshBuilder.parts(for:includeCeiling:includeHidden:)` turns an edited `CleanModel` into `CleanMeshPart`s: each wall is decomposed in wall-local coordinates into rectangles around its openings (no general triangulation), floors and ceilings use `PolygonTriangulator` (ear clipping, L-shape tested), objects are boxes, occluded regions are `.occluded` quads. Each part keeps its `ElementID`, kind and provenance (walls and openings are pickable, 7.4).

### 5.7 Floor plan (FloorPlan)

- `PlanBuilder.build(from:floors:)`: `CleanModel` to `PlanModel`, one `PlanLevel` per floor, points through `PlanAxes`; walls a to b counter-clockwise around their room with the body drawn outward by the thickness, so room areas do not change; one interior dimension per wall (offset 0.3 m into the room) and two overall dimensions per room from the minimum-area rectangle (`PlanDimension.isUser == false`); fixtures from objects (footprint on the object's x and z, yaw from its transform).
- `PlanDrawing.make(level:toggles:prefs:roomTitles:name:) -> PlanDrawingResult` (a `Plan2D` plus `[PlanHit]`) with the `PlanLayers` names A-WALL, A-WALL-EST, A-WALL-OCCL, A-DOOR, A-DOOR-EST, A-GLAZ, A-FLOR-IDEN, A-ANNO-DIMS, A-ANNO-SCAL, A-FURN, A-FIXT, A-ANNO-NOTE and A-GRID; labels are formatted with `LengthFormat` and `AreaFormat` before they enter `Plan2D`. Estimates are drawn as estimates (SPEC "clearly distinguish estimated geometry"; RESEARCH 3.6: RoomPlan gives no hinge side and no thickness): a door swing with source `.estimated` or `.inferred` is dashed on A-DOOR-EST (solid on A-DOOR once the user sets it in build 5), and the outer face of a wall with estimated thickness is dashed on A-WALL-EST. `PlanToggles` covers the SPEC toggles (furniture, measurements, room names, doors and windows, fixtures, grid, scale): grid draws 1 m or 1 ft lines on A-GRID, scale a 4-segment bar with a Units label on A-ANNO-SCAL, and each toggle removes only its own layers. `RoomTitles` gives the user name, else the RoomPlan section label, else "Room n"; fixture labels come from `Copy.FloorPlan.categoryName(_:)`.
- `PlanRenderer.draw(_:in:viewport:lineWidth:dark:)` draws a `Plan2D` into a `CGContext`; `PlanCanvasView` (SwiftUI `Canvas` with `withCGContext`, `DragGesture` pan, `MagnifyGesture` zoom, `SpatialTapGesture` hit tests in model space), `PlanRenderer.pngData` and `jpegThumbnail` use it. PDF, SVG and DXF go through Export's writers from the same `Plan2D`, so screen and files share one drawing list. The one y flip (plan +y up, screen y down) lives in `PlanViewport` (RESEARCH 3.6 gotcha 18) and is verified on an L-shaped room.

### 5.8 Quality (Quality around Coverage)

- `QualityEvaluator.evaluate(roomID:room:mesh:geometryObservations:textureObservations:log:inputHash:now:) -> QualityEvaluation` is pure; `evaluateSealedRoom(package:record:now:)` gathers the inputs from a sealed folder and is used at Done (input hash extra `"done"`); `QualityStep` re-evaluates with the consolidated mesh and the rebuilt room during processing (its hash adds the room's `buildRoom` and `consolidateMesh` stamps, so it always supersedes the Done result and reruns after a rebuild), and its result replaces the review result in `quality.json` and `RoomRecord.quality`.
- Expected surfaces: `QualityInputs.boundary(for:)` converts the clean room outline (plan coordinates) back to Coverage's world (x, z) `CoverageRoomBoundary`, with walls, floor and ceiling heights from the clean room.
- Faces: `QualityInputs.faces` makes a `CoverageFace` per mesh face (world centroid, normal from the cross product rather than the per-vertex normals, RESEARCH 3.8 gotcha 6; area; `SurfaceClass(rawValue:)`).
- Observations: pose samples decimated to 2 Hz as `CoverageObservation` (camera to world, intrinsics of the nearest keyframe, image resolution, tracking normal, depth confidence nil) for geometry; keyframe records alone for the texture grid, and only those taken in usable light (`ambientIntensity` at least 250 and `exposureDuration` at most 1/30 s), so a dark but well-tracked scan scores low on Color and texture (TEST_PLAN TEX-06); the dark share is stored and QualityUI adds `Copy.Quality.noteDark` above 30 percent.
- Scores: walls from per-wall observed fractions of `ExpectedSurfaces.evaluate`, after dropping samples inside that wall's doors, windows and openings (windows and mirrors are never expected, D19), weighted by RoomPlan confidence and completed edges as soft factors (`edgeMissingFactor`, `mediumConfidenceFactor`, `lowConfidenceFactor`; RESEARCH 3.8 gotcha 3); floor and ceiling from observed over expected area; shape as the area-weighted mean; texture from the keyframe-only grid's `goodFaceAreaFraction`. Coverage percentages (0 to 100) are divided by 100 once into `QualitySummary`, whose verdict comes from `QualityVerdict.from`.
- Missing areas (`MissingAreaRecord`, with `suggestedViewpoint`) exclude those inside windows, doors and openings and are stored for Show Missing Areas (build 5). Per-wall evidence (`RoomEvidence`, `WallEvidence`: median best distance and good observation count; tracking fraction from `RoomCaptureLog`) feeds MeasureCore.
- Without a room (RoomPlan failed) Coverage's no-room path gives shape and texture; walls, floor and ceiling are 0 and the evaluation carries `.roomPlanFailed`.

### 5.9 Structure and alignment (build 5, D9)

- `MergeStructureStep` passes only rooms that `StructureEligibility.mergeable(_:sessions:)` accepts (frame link `mayShareFrame` true and, for `.relocalized`, tracking reached `.normal`), grouped by floor, to `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from:)` (label `options:`, RESEARCH 3.10 gotcha 10). `StructureBuilder.BuildError` is caught. A crash cannot be caught, so the step writes `structure/attempt.json` before calling the builder; after one crashed attempt the step is not retried automatically and HouseUI offers "Join rooms again" or manual alignment.
- `AlignRoomsStep`: for each input room, match wall, door, window and opening identifiers kept by the merge and solve yaw plus translation by least squares on matched wall endpoints (`StructureAlignment.solve`), writing `[RoomAlignmentRecord]` (source `.measured`) to `alignment.json`; rooms whose outlines overlap by more than 30 percent of the smaller room (`StructureAlignment.overlapRatio`) are flagged as stacked and sent to manual alignment. `setRoomAlignment` edits (source `.user`) override. Mesh, keyframes and textures are transformed by the alignment at derivation time; raw stays in its capture frame.

### 5.10 Object reconstruction and metrics (build 5)

- `PhotogrammetryStep` (ObjectCapture, `reconstructObject`) runs alone (the runner starts nothing else and Results releases its viewer): `PhotogrammetrySession(input: imagesURL, configuration:)` with `checkpointDirectory` set to the derived checkpoint; `process(requests: [.modelFile(url: modelURL), .bounds])` with the default detail (only `.reduced` exists on iOS, never name another case, RESEARCH 3.3). `outputs` is iterated in a stored Task that ends at `.processingComplete` or `.processingCancelled`; `requestProgress` and `requestProgressInfo` drive ObjectUI's processing screen; `reconstructionPending` is cleared on success.
- `ObjectMetricsStep` (ObjectModel): `ObjectModelLoader.mesh(fromUSDZ:)` reads the model with `MDLAsset(url:)` and `childObjects(of: MDLMesh.self)`; `ObjectDimensions.measure` gives width, height, depth and surface area, and volume only when the mesh is watertight (`Copy.Viewer.volumeUnavailable` otherwise). Large objects use `ObjectDimensions.isolate` (MeshProcessing's `ObjectIsolation`) on the consolidated mesh with the crop box. Results are stored as `ObjectDimensionsRecord` in `dims.json`.

## 6. Threading model

| Context | Owner | Runs | Rules |
|---|---|---|---|
| Main actor | SwiftUI, every `ObservableObject` model (`ProjectLibrary`, `ProcessingRunner`, `ScanFlowModel`, `ResultModel`, `ViewerModel`, `GuidanceAnnouncer`), `RoomCaptureView`, `ObjectCaptureSession` and `ObjectCaptureView`, `ARView` and every RealityKit entity, `LowLevelMesh` writes, `try await MeshResource(from:)` | UI and small file reads (manifests) | No mesh building, no image encoding, no step work. |
| `hub.queue` ("mapper.ar.delegate", serial) | `ARSessionHub` | every `ARSessionDelegate` callback, every `ScanRecorder` call, watchdog, snapshot assembly | Copy and return; no disk, no JPEG; target under 8 ms per frame, recorders under 2 ms. |
| `RawScanWriter.ioQueue` ("mapper.io", serial, utility) | Store | JPEG, Float16, all raw writes | Bounded: 4 keyframes in flight (`FrameCopier` count); mesh flushes coalesced every 3 s. |
| RoomPlan callbacks (thread undocumented) | `RoomCaptureController` | RoomPlan session and view delegate methods | Copy values, hop to `hub.queue` or main. |
| Object Capture Tasks (build 5) | `ObjectScanModel` (main actor) | `for await` over session updates | Tasks are stored and cancelled on teardown. |
| Detached step tasks | `ProcessingRunner` | one step at a time, `concurrentPerform` inside steps | Progress hops to main at 10 Hz or less. |
| Detached export tasks | `ExportRunner` | writer calls | The result URL is delivered on main. |
| LogStore and DebugServer queues | Support | existing | Unchanged. |

Rules:
1. `ScanEngine` (D1) is a non-isolated, class-bound protocol. `ScanFlowModel` calls it on main; engines work on their own queue (`RoomScanEngine` uses `hub.queue`); `onEvent` is always called on main through `DispatchQueue.main.async` with value types, and `state` and `lastResult` are written only inside that same main hop (the engine queue keeps a private copy; an engine-initiated finish hops to main before acting). Never a `@MainActor` protocol. Only the members that touch UIKit (`RoomScanEngine.makeCaptureView()`, the hub's initializer) are `@MainActor`.
2. Delegates (`ARSessionHub`, `RoomCaptureController`, `ARDelegateRelay`) are plain `NSObject` subclasses, never `@MainActor` (RESEARCH 3.9 gotcha 2). Hops use `DispatchQueue.main.async`.
3. Values that cross contexts: `LiveScanSnapshot`, `ScanEngineEvent`, `HubStatus`, `CapturedRoomData`, `CapturedRoom`, `MeshChunk`, `PoseSample`, `KeyframeRecord`, `QualityEvaluation`, `Data`, `URL`, and Mapper's own `FrameCopier` buffers, which pass from `hub.queue` to the io queue and return to the free list. In Swift 5 mode these hops need no explicit `Sendable` conformance.
4. Never crosses a callback boundary and is never retained: `ARFrame`, `ARAnchor`, `ARMeshGeometry` and its `MTLBuffer`s, `ARDepthData` buffers, `capturedImage` (design target: zero retained frames, RESEARCH 3.4 gotcha 4). RealityKit entities and `CGContext`s stay on the context that made them.
5. Recorder state is confined to `hub.queue`. Main reads it only through value copies.
6. Build settings stay Swift 5.9 mode with no default actor isolation (RESEARCH 3.9 recommended approach); `SWIFT_STRICT_CONCURRENCY: targeted` may be added for warnings. Isolation violations are hard errors even in Swift 5 mode, so code is written isolation-correct.

## 7. Rendering and viewer (Viewer3D)

### 7.1 Host and camera

- `ViewerContainer` is a `UIViewRepresentable` around `ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)` (the 3-argument init; the 2-argument one is deprecated, RESEARCH 3.5). `environment.background = .color(...)`: black for scans, system background for objects.
- Camera: a `PerspectiveCamera` under `AnchorEntity(world: .zero)`, posed by assigning `transform` from `ViewerOrbitMath.lookAt(eye:target:)`. UIKit recognizers on the `ARView` turn gestures into camera moves: one-finger drag orbits (yaw, pitch clamped to 5 to 85 degrees), two-finger drag pans the target, pinch changes distance, double tap frames all. RealityView camera controls allow one mode only (RESEARCH 3.5), so the orbit is ours.
- No SceneKit, no `ARSCNView`, no `.metal` file, no `CustomMaterial` or `ShaderGraphMaterial` in builds 4 to 6.

### 7.2 Mesh resources

- `ViewerPart` is the one drawable unit: world-space positions, optional normals and UVs (one per vertex), `UInt32` indices, a `ViewerMaterial`, a `ViewerLayer` and an optional `ViewerPickTag`. `ViewerContentBuilder` builds parts off main (tiles of 2 m, classification parts, object boxes, per-corner UV expansion).
- On main, `ViewerModel.load(_:)` creates one `ModelEntity` per part with its own `LowLevelMesh` (from `LowLevelMesh.Descriptor(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType:)`, interleaved position `.float3` at 0, normal `.float3` at 12, uv0 `.float2` at 24, stride 32) and exactly one `LowLevelMesh.Part`, fills it through `withUnsafeMutableBytes(bufferIndex:)` and `withUnsafeMutableIndices`, and makes the resource with `try await MeshResource(from: lowLevelMesh)` (RESEARCH ruling 7). Parts upload in batches of 16 with a yield between batches; iOS 27 descriptor members are never referenced.
- Entities of one layer share a parent whose `isEnabled` toggles the layer (Hide Furniture, tab changes); entity count stays in the low hundreds.
- Viewer3D knows no RoomModel, MeshModel or TextureJob type: Results converts `CleanMeshBuilder` parts, `mesh_view.mchk` and `TexturedMesh.pageParts()` into `ViewerPart`s, which keeps Viewer3D in wave 4a.

### 7.3 Display modes

| Tab or style (`ResultTab`, `ViewerDisplayStyle`) | What is drawn | Material (`ViewerMaterial`, always `faceCulling = .none`) |
|---|---|---|
| Realistic, Textured | textured view mesh from `textured.tuv` and `page_<n>.jpg` | `.texture(url)`: `UnlitMaterial(texture:)` with `TextureResource(image:withName:options:)`, semantic `.color` |
| Photo Realistic (build 4) | not available: the style menu shows `Copy.Results.photoRealisticLater` | n/a |
| Realistic before or without texturing | while `textureLow` runs, the preparing chip (`Copy.Results.colorPreparing` with a percent); when texturing failed or cannot run, a View Simple Model button that opens RoomPlan's own model in Quick Look (`ResultModel.openSimpleModel`, `Copy.Results.simpleModel`) when a `CapturedRoom` exists, else an honest unavailable state (`ResultAvailability.compute`) | n/a |
| Photo Realistic (build 6) | high-density textures | same as Textured |
| 3D Clean | `CleanMeshBuilder` parts from the edited `CleanModel`: walls with openings cut, floor, openings (walls and openings pickable), object boxes in the `.cleanFurniture` layer (so Hide Furniture toggles it), occluded wall spans and furniture footprints in `.cleanOccluded` (shown only while Hide Furniture is on), missing areas as red squares in `.overlay`, ceiling hidden | `.lit` light gray for walls, `.translucent` for openings and object boxes plus a `.wireframe` outline, translucent gray plus wireframe (a hatched look) for occluded parts, translucent red for missing areas |
| Floor Plan | not an `ARView`: `PlanCanvasView` | n/a |
| Raw Scan | `mesh_view.mchk` (measured) plus `mesh_inferred.mchk` plus `mesh_floaters.mchk` (the noise cleanup removed): one part per (tile, class); missing areas in `.overlay` | `.unlit` per class from `MeshClassPalette`; inferred faces in `.rawInferred` with `MeshClassPalette.inferred` |
| Solid Color | any mesh | `.lit`: `SimpleMaterial(color:roughness:isMetallic:)`, light gray |
| Wireframe | any mesh | `.wireframe`: `UnlitMaterial` with `triangleFillMode = .lines` |

No fixed-function material reads vertex colors (RESEARCH 3.5), so all per-face color is parts plus materials. Hide Furniture toggles the furniture layer off and the occluded layer on; it never rebuilds content. A Legend button on 3D Clean and Floor Plan opens a sheet (`Copy.Measure.legendTitle`) explaining Measured, Estimated, Inferred, Occluded and Unscanned with swatches matching these styles (TEST_PLAN FURN-02).

### 7.4 Picking and labels

- A tap goes to `ViewerModel.hitTest(_:)`: `arView.ray(through:)`, then `MeshBVH.raycast(_:maxDistance:)` over the pickable parts (BVHs built off main at load); the nearest hit becomes a `ViewerHit` with the part's `ViewerPickTag` (`.element(ElementID)` or `.rawMesh`). `Scene.raycast` with collision components is not used.
- Labels (room names, dimension values) are SwiftUI overlays positioned with `ViewerModel.project(_:)` and refreshed on `cameraRevision`, not 3D text.
- Build 4 taps: a wall, door, window or opening (3D Clean, or the Floor Plan tab through `PlanHit`) is selected, highlighted with a copy of its part on `.overlay`, and the dimensions panel shows only its rows (length, height and area for a wall) with a Show All control, so "Wall 3" is always a wall the user can see (TEST_PLAN MEAS-02, MEAS-06, smoke #7). An object box opens a read-only card with the category guess (`Copy.Results.objectGuess` with `Copy.FloorPlan.categoryName`; build 4 cannot correct it, so not `guessedLabel`) and width, height and depth with their confidence (MeasureCore `objectRows`). Change Category arrives on the card in build 5; Hide, Delete from clean model, Move, Rotate, Rename and Show raw geometry come with EditMenus in build 7; Measure comes with MeasureTool in build 5.

### 7.5 Performance

Target at most 300k displayed triangles (the view mesh) in about 150 parts at 30 fps or better on the A15; frame time and `MeshResource(from:)` time per part are logged in diagnostics (15). Under 30 fps, parts outside the view are disabled. An `MTKView` renderer (RESEARCH 3.5) is the documented escape hatch, not planned.

### 7.6 Live views and thumbnails

- Room capture uses `RoomCaptureView`'s own renderer; build 4 draws nothing in 3D during capture.
- Build 5 CoverageOverlay: `ARView` in `.ar` on the hub session (LiveMeshView); each `ARMeshAnchor` gets a `LowLevelMesh` with four parts (green, yellow, red, gray `UnlitMaterial` with `blending = .transparent(opacity:)`), rebuilt from a dirty set at most every 0.33 s, skipped outside the frustum, frozen at thermal `.serious` (RESEARCH 3.5). `.showSceneUnderstanding` is a debug toggle only.
- Object results (build 5): Viewer3D's `loadModel(_:)` adds the USDZ with `try await Entity(contentsOf:)` (iOS 18.0).
- Thumbnails come from `PlanRenderer.jpegThumbnail` (rooms) or the first image (objects), never from an off-screen `ARView` snapshot.

## 8. Measurements and confidence

### 8.1 Where values come from

| Value | Source | Provenance | Confidence |
|---|---|---|---|
| Room length and width | `RoomOutline` minimum-area rectangle | measured (estimated when the floor polygon fallback was used) | `ConfidenceAdapter.roomPlanLength` |
| Floor area, perimeter | closed wall loop (D12) | measured | `ConfidenceAdapter.area` from the two sides; `ConfidenceAdapter.sum` for the perimeter |
| Wall length and height, door and window width and height | `CleanWall`, `CleanOpening` | measured | `roomPlanLength` with that wall's `WallEvidence` |
| Wall area (room total and per wall) | wall rectangles minus that wall's openings; the panel states that doors and windows are not counted (`Copy.MeasureCore.wallAreaNote`) | measured | `ConfidenceAdapter.area` from its length and height |
| Ceiling height | D13 mesh medians, else RoomPlan wall height | measured, or estimated | measured: the depth model at the median camera distance; estimated: `roomPlanLength` |
| Volume | floor area times ceiling height | follows the ceiling | no plus-or-minus when inferred |
| Object width, height, depth (room scan) | `DetectedObject.dimensions` (RoomPlan box) through `RoomDimensions.objectRows` | measured, shown as box size | `roomPlanLength` (no wall evidence) |
| Point to point, angle, polygon area (build 5) | MeasureTool snapped points | measured | `ConfidenceAdapter.distance` from endpoint evidence |
| Live distance (build 5) | LiveMeasure | measured | endpoint evidence |
| Object dimensions and volume (build 5) | ObjectModel bounds, `ObjectIsolation` box | measured | box sizes |

### 8.2 The confidence rule (MeasureCore around Coverage)

- `ConfidenceAdapter` builds a Coverage `MeasurementEvidence` per endpoint and calls `MeasurementConfidence.estimate(start:end:length:)` (or `estimate(point:)`). `accuracy` is about one sigma and becomes `MeasuredValue.sigma`.
- RoomPlan-derived lengths use the wall's evidence from Quality (`WallEvidence`: median distance and observation count) or the defaults (`defaultDistance` 2.0 m, `defaultObservations` 3), tracking fraction `1 - RoomCaptureLog.limitedTrackingFraction`, snap `.roomSurface`.
- RoomPlan floor (RESEARCH ruling 4): `ConfidenceAdapter.roomPlanMinimumSigma` is 0.015 m, so no RoomPlan-derived length ever shows better than plus or minus 3 cm (1.2 in); drift makes it grow with length. This replaces Coverage's `roomSurfaceLengthFloor` (0.0125 m) for these values.
- Display (`MeasureDisplay.accuracyText`): `Copy.Measure.accuracy(...)` with the text of `Tolerance.plusMinus(2 * sigma, prefs:)` minus its leading plus-minus sign (Copy adds the sign), 2 sigma floored at 1 cm.
- Low confidence (Core `MeasuredValue.isLowConfidence(length:)`, CR-2, reached through `MeasureDisplay.isLowConfidence(_:length:)`, the only rule any screen uses): 2 sigma above max(4 cm, 3 percent of the length) for lengths, 2 sigma above 3 percent of the value for areas and volumes. When Coverage's own flag is set (sigma above max(5 cm, 3 percent), an endpoint with tracking normal under 70 percent, depth confidence under 0.34 or no observations), `ConfidenceAdapter` raises the sigma to `lowConfidenceSigma(length:)`, so the flag survives into the stored value. The UI then shows `Copy.Measure.lowConfidence` instead of the plus-or-minus.
- Reference length (D21, build 6): `setScaleCorrection(room:factor:)` multiplies lengths by f, areas by f squared and volumes by f cubed when edits are replayed; raw never changes; undo restores.
- Every number goes through Units (`LengthFormat.display`, `AreaFormat.display`, `VolumeFormat.primary`, `AngleFormat.degrees`, `Tolerance`) in both systems per `UnitPreferences`.
- Constants live in two places only (Coverage's `MeasurementConfidence` and MeasureCore's `ConfidenceAdapter`), tuned against the TEST_PLAN section 3 tape protocol (CONF-01 to CONF-04).

### 8.3 Provenance labels

| `Provenance` or state | UI label (`Copy.Measure`) | Shown how |
|---|---|---|
| `.measured` | `measured` ("Measured") | value plus the accuracy text |
| `.estimated` | `estimated` ("Estimated") | value plus the accuracy text from `roomPlanLength` (RoomPlan fallbacks); dashed on the plan (estimated door swings on A-DOOR-EST, estimated wall thickness on A-WALL-EST) |
| `.inferred` | `notMeasured` ("Estimated, not measured") and `inferred` in the legend | value without plus-or-minus; hole-filled mesh faces in the Inferred color |
| `.user` | none in build 4 | value without plus-or-minus; a user-set door swing is drawn solid (build 5) |
| occluded span or area | `occluded` | gray hatched regions in 3D Clean while Hide Furniture is on, dashed on the plan (A-WALL-OCCL), readable without color vision |
| never observed | `unscanned` | missing areas as translucent red squares in 3D Clean and Raw Scan (build 4); live gray coverage (build 5) |

The legend (`Copy.Measure.legendTitle`) explains the labels; `Copy.Measure.disclaimer` sits under every dimension list. AI labels (RoomPlan categories, section labels) are suggestions shown as guesses ("Mapper's guess: Oven", `Copy.Results.objectGuess` in build 4; `Copy.ObjectMenu.guessedLabel` once correction exists, which needs the same article-free form) and are never written into raw; corrections are edits (Change Category in build 5, the full menu in build 7).

### 8.4 Snapping (logic in build 4, tools in build 5)

`SnapSet.build(from:includeObjects:)` (MeasureCore) collects, from the edited clean room: wall-wall-floor and wall-wall-ceiling corners, opening corners and object box corners; then wall, opening and object edges; then floor, ceiling and wall planes. `SnapSet.snap(_:)` uses Geometry's `Snap.best` with radii 0.10 m (corner) and 0.05 m (edge, plane) and maps the result to Core's `SnapKind`; MeasureTool falls back to the raw mesh hit. The kind is stored in `MeasurementRecord.snaps` and mapped to Coverage's `MeasurementSnapKind` for the evidence.

## 9. Exports (ExportUI)

ExportUI adapts our models to Export's inputs and calls its writers; it never writes raw or edits. `ExportCatalog.options(for:)` lists what is available with reasons (`Copy.Export.noColor` when no keyframes were captured, `Copy.ExportUI.colorNotReady` while color is still being added or failed, `noFloorPlan`); `ExportCatalog.label(for:)` maps each format to its text by an explicit switch; `ExportRunner.run` writes into `exports/<yyyyMMdd-HHmmss>/` off main. Units: meters and Y up for 3D formats; millimeters for STL and DXF (DXF through the wave 4a Export revision, MODULES 3.18a).

| Representation (`ExportRepresentation`) | Format (`ExportFileFormat`) | Writer | Native or hand-written | Build |
|---|---|---|---|---|
| Raw Scan | OBJ (vertex colors by class) | `OBJWriter` via `MeshExportAdapter` | hand-written | 4 |
| Raw Scan | PLY binary with class colors (`Copy.ExportUI.plyDetail`; photo color in build 6) | `PLYWriter` | hand-written | 4 |
| Raw Scan | STL (mm, Z up) | `STLWriter.binary(for:options: .printing)` | hand-written | 4 |
| Raw Scan | GLB | `GLBWriter` | hand-written | 4 |
| Raw Scan | USDZ | `USDZWriter` (usda plus stored zip, 64-byte aligned) | hand-written | 4 |
| 3D Clean | USDZ | `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` with `[.mesh]` and a `.plist` metadata URL (RESEARCH 3.2 recommended 9) when the project has one room, a `CapturedRoom` and no active edits; `USDZWriter` from `ExportAdapters.cleanScene` otherwise | native or hand-written | 4 |
| 3D Clean | OBJ, GLB | writers from `CleanMeshBuilder` parts | hand-written | 4 |
| Data | JSON | `ExportSummaryJSON`: rooms with metrics (meters, provenance, sigma), openings, objects, quality, plus `capturedroom.json` when present, zipped (never Apple's private CapturedRoom schema as the interchange format, RESEARCH 3.2 gotcha 16) | hand-written | 4 |
| Floor Plan | PDF | `PDFPlanWriter` from `PlanDrawing`'s `Plan2D` | hand-written on UIKit PDF | 4 |
| Floor Plan | SVG | `SVGWriter` | hand-written | 4 |
| Floor Plan | DXF | `DXFWriter.data(for:millimeters: true, unitsNote: Copy.ExportUI.dxfUnitsNote)`: R12 (AC1009), millimeters, no `$INSUNITS`, "_mm" in the file name and a TEXT note (D23). The merged writer uses meters and no note; the Export revision in wave 4a adds this entry point (MODULES 3.18a) | hand-written | 4 |
| Floor Plan | PNG | `PlanRenderer.pngData(_:pixelWidth: 3000)` | native | 4 |
| Realistic | USDZ | `USDZWriter` with `ExportMaterial(textureJPEG:)` per atlas page (`ExportAdapters.texturedScene`) | hand-written | 4 if TextureLowStep lands, else 5 |
| Realistic | OBJ plus MTL plus JPEG in a zip | `OBJWriter.zipBundle(for:baseName:)` | hand-written | same |
| Realistic | GLB | `GLBWriter` (flips V for glTF) | hand-written | same |
| House | USDZ | `CapturedStructure.export(to:metadataURL:modelProvider:exportOptions:)` (4-argument form only) or `USDZWriter` | native | 5 |
| Object | USDZ | Object Capture output as is | native | 5 |
| Object | OBJ, STL, PLY, GLB | `MDLAsset` meshes to `ExportMesh`, then our writers | hand-written | 6 |
| Measurements | CSV and a room schedule page in the PDF | CSV text; `PDFPlanWriter` page | hand-written | 6 (JSON has them from build 4) |
| Images | PNG views of the model | `ViewerModel.snapshotJPEG` or `ARView.snapshot` | native | 6 |
| Project backup | ZIP of the package | ProjectOps `StreamingZipWriter` (D2) | hand-written | 6 |

Rules:
- File names come from `ExportCatalog.fileName(project:option:date:)` and always start with a letter (RESEARCH 3.7 gotcha 7). Options from UX_COPY: Include textures, Include hidden objects, Include measurements, Units (`unitsOverride`, nil means the app setting), paper size (`ExportSettings`).
- Exports use the edited models (`EditLog` replay) and the result screen's view state: `ExportSheet(projectID:viewState:)` receives an `ExportViewState` (plan toggles and Hide Furniture, declared in FloorPlan so Results and ExportUI share it), plan formats draw with those toggles (TEST_PLAN EXP-05 "all visible toggled layers"), and clean 3D formats drop movable objects while Hide Furniture is on unless Include hidden objects is set; occluded regions are never exported as surfaces.
- PDF north arrow: `PDFPlanWriter.Options.northAngle` is measured counter-clockwise from plan +x, `PlanModel.northAngle` counter-clockwise from +y, so ExportUI passes `Double.pi / 2 + Double(plan.northAngle)` (the writer's default while the angle is 0).
- Memory: `USDZWriter`, `OBJWriter` and `ZipWriter` build `Data` in memory, so the text formats take the full measured mesh only up to 600k triangles and otherwise the view mesh plus the inferred mesh as its own object (with `Copy.ExportUI.simplifiedNote`); binary PLY, STL and GLB take the full measured mesh.
- Cleanup: `ActivityShareSheet`'s completion handler deletes that export's staging folder, `openSimpleModel` reuses `exports/simple/`, and at launch `ExportRunner.removeStaleStaging()` deletes staging folders older than 24 hours (TEST_PLAN PERF-24).
- Sharing: `ActivityShareSheet` (a `UIActivityViewController` wrapper) with file URLs that survive until dismissal; multi-file results are zipped first, folders are never shared (RESEARCH 3.7); `.quickLookPreview` for USDZ and PDF, never an embedded `QLPreviewController` (RESEARCH 3.7 gotcha 19).
- The sheet shows `Copy.Export.preparing` then `ready`; errors map to `Copy.Errors.exportFailed`.

## 10. UX state machines

All models are `@MainActor final class ...: ObservableObject` with plain enums in `@Published` properties. All text comes from `Copy` and the module's `Copy+<Module>.swift`; errors map `MapperError.copyKey` to `Copy.Errors`; guidance text comes from `Copy.Guidance.all` under the UX_COPY display rules enforced by `GuidanceEngine`. Every message is announced to VoiceOver (tier 1 with high priority) by `GuidanceAnnouncer`.

### 10.1 Navigation (AppShell)

`AppRootView` is a `NavigationStack(path:)` over `HomeScreen` with `enum AppRoute: Hashable { case result(UUID), settings, diagnostics }` in `AppRouter`. Capture screens are `fullScreenCover(item:)` driven by `AppRouter.scanRequest` (they own the camera, and processing is suspended while one is up); the export sheet is `.sheet(item:)` driven by `AppRouter.exportRequest: ExportRequest?` (`struct ExportRequest: Identifiable, Equatable { let id: UUID; var projectID: UUID; var viewState: ExportViewState }`; `UUID` is not `Identifiable`, and no retroactive conformance is added). Portrait only; capture chrome forced dark. Build 4 screens:

```
Home (project list, New Scan, recovery sheet)
 +-- ModePickerSheet: Room enabled; House, Object, Quick Measure, Advanced shown as "Coming in a later version"
 |     +-- camera permission screen (first time only) or the Open Settings alert
 |     +-- ScanTipsSheet (once per mode, Don't show again)
 |     +-- RoomScanScreen (RoomCaptureView + chrome + GuidanceBanner) -> QualitySheet (medium detent) -> ResultScreen
 +-- Project row (swipe: Rename, Delete) -> ResultScreen: Realistic | 3D Clean | Floor Plan | Raw Scan, Display, Hide Furniture, Legend, dimensions, Export, Retry
 +-- Settings (units, inch fractions, show both, vibrate for warnings, keep scan photos, tips, storage, wireless debug) -> Diagnostics
```

### 10.2 Home (HomeUI)

`HomeScreen(library:runner:availableModes:onNewScan:onOpen:onSettings:)` (wave 4b) lists `ProjectLibrary.projects` except `.capturing` ones, with name, mode subtitle (`HomePresentation.subtitle`, for example `Copy.Home.roomSubtitle`), thumbnail, badges (`HomeBadge.processing` from `ProjectProcessingState`, `.needsWork` from a room in `.needsRescan`), search, Rename (swipe and context menu, `ProjectLibrary.rename`; default names such as "Room Sep 28" repeat within a day) and swipe-to-delete with confirmation (`Copy.Project.deleteTitle`), which cancels the project's processing job first. The empty state uses `Copy.Empty.noProjects`. The New Scan button is at the bottom, reachable with one hand. When `RecoveryService.pending()` is not empty at launch, AppShell shows the recovery sheet before the list (`Copy.AppShell.recoverTitle`, Keep Scan or Discard).

### 10.3 Scan flow (ScanUI)

```swift
enum ScanFlowPhase: Equatable { case preflight, permission, tips, capturing, stopping, checking, quality, finishing, done(UUID), failed(String), cancelled }
enum ScanFlowSignal: Equatable, Sendable {
    case preflightPassed, preflightBlocked, permissionNeeded, permissionGranted, permissionDenied, tipsDone,
         engineStarted, doneTapped, engineStopping, roomFinished(UUID), evaluated, finishTapped, cancelConfirmed,
         discarded, failed(String)
}
```

| From | Signal or event | To |
|---|---|---|
| preflight | camera not yet asked (never in Demo Mode) | permission (`Copy.Permissions.cameraTitle`, Continue asks iOS) |
| permission | granted | tips or capturing |
| permission, preflight | camera denied | alert with Open Settings and OK, then `onDismiss` |
| preflight | checks pass, tips not yet seen for the mode | tips |
| preflight | checks pass, tips seen | capturing |
| preflight | blocking issue (no LiDAR, storage; Demo Mode checks only 50 MB of storage) | alert with the Copy error, then `onDismiss` |
| tips | Start (optionally Don't show again) | capturing |
| capturing | `.stateChanged(.paused)` | capturing with the paused chrome, Resume and Finish Now; after 30 s the Finish Now or Resume alert |
| capturing | Done or Finish Now (`doneTapped`), or `.stateChanged(.stopping)` from an engine-initiated finish (thermal critical, storage pause, memory floor; `engineStopping`) | stopping |
| stopping, capturing | `.roomFinished(roomID:)` | checking (RoomRecord appended, project `.needsProcessing`, evaluation running) |
| checking | evaluation stored | quality (sheet over the camera) |
| quality | Finish or Finish Anyway | finishing, then done(projectID); teardown; AppShell enqueues processing at the front and opens Results |
| capturing, stopping | Cancel confirmed (`Copy.Scanning.cancelConfirmDiscard`) | cancelled; `engine.discard()` deletes the InProgress folder after the writer closed, then the empty project is deleted |
| quality | Discard confirmed | cancelled; `ProjectLibrary.discardRoom` removes the scan just captured and the project when no room is left |
| any | `.failed(MapperError)` before `.roomFinished` | failed; teardown; raw kept in InProgress for recovery |
| any after `.roomFinished` | `.failed(...)` (heat, storage, memory) | alert only; the flow continues to quality |

`ScanFlowModel.nextPhase(_:on:)` is the pure reducer behind this table and is self-tested.

Demo Mode (D1): a Diagnostics toggle (`SettingsKey.demoMode`, declared in ScanUI) makes New Scan use `FakeScanEngine()` with `SnapshotRecording.synthetic()`, and `ScanPreflight.run(mode:isDemo: true)` skips the camera and LiDAR checks (only a 50 MB storage check), so it also runs on a device without LiDAR or with the camera denied. On `.roomFinished`, `DemoProjectFactory.makeDemoRoom` writes a synthetic 4 m by 5 m room (sealed raw folder with one synthetic chunk, clean model, plan, mesh files and quality) and the project is set `.ready` in the same update, so it is never enqueued; the sheet shows its evaluation. Every screen can run without ARKit and without camera permission.

### 10.4 Results

```swift
enum ResultTab: String, CaseIterable, Identifiable, Sendable { case realistic, clean, floorPlan, raw }
enum TabAvailability: Equatable, Sendable { case ready, preparing(text: String, percent: Int?), unavailable(reason: String), failed(reason: String) }
// ViewerDisplayStyle is declared in Viewer3D (MODULES 3.17); Results only uses it.
```

While the project's job is queued or running and `plan.json` does not exist yet (`ResultAvailability.showsProcessingView`), `ResultScreen` shows the processing view (`Copy.Processing.title`, the current step, `Copy.Processing.keepOpen`) instead of the tabs (D20); otherwise the tabs show and each decides from its files, so a demo project, a relaunched project and a failed job always open. Retry (`Copy.Errors.tryAgain`) shows when the project is `.needsAttention` or a step failed and re-enqueues it through AppShell. `ResultModel` maps `ProcessingRunner.shared.states[projectID]` and the files on disk (`ResultFiles`) to a `TabAvailability` per tab (`ResultAvailability.compute`; chips such as `Copy.Results.stepProgress(Copy.Processing.stepTextures, percent:)`, D20), holds the display style, the Hide Furniture flag, the plan toggles, the `DimensionRow`s of `RoomDimensions.rows(for:evidence:)` (length, width, floor area, perimeter, ceiling height, wall area, estimated volume, then per wall length, height and area, per door and window, each with provenance and accuracy), the selected wall or opening (which filters the rows) and the selected object with its `objectRows`. Unavailable reasons come from the degraded mode read from `roomlog.json` (not from the quality evaluation) or the mode (for example `Copy.Results.noWalls`). The model reloads on `.mapperManifestDidChange` and when the runner's state changes. Units come from `UnitPreferences.load()` on appear.

### 10.5 Quality sheet and export

`QualitySheet(evaluation:onFinish:onDiscard:onShowMissingAreas:)` renders `QualityPresentation.rows` (Shape, Walls, Floor, Ceiling, Color and texture as `Copy.Quality.percent` with bars and tints), the missing area count, the summary line by verdict, the degraded-mode note, the dark-light note, Finish (nothing missing) or Finish Anyway, and Discard (removes only the scan just captured, lead decision 4); a nil evaluation shows "Checking your scan...". Show Missing Areas appears in build 5 when AppShell passes `onShowMissingAreas` (MissingAreas tour on a patch pass on the still-running session, D19), and only for rooms that were not stopped by the system. AppShell applies `.presentationDetents([.medium, .large])` and `.interactiveDismissDisabled()`.

`ExportSheet(projectID:viewState:)` groups `ExportCatalog.options(for:)` by representation (`Copy.ExportUI.realisticSection`, `cleanSection`, `rawSection`, `planSection`, `dataSection`), shows options and reasons, runs `ExportRunner.run` and presents `ActivityShareSheet` with the result.

## 11. Security and privacy

### 11.1 Network

- No networking code except `DebugServer`. No `URLSession`, analytics, crash reporters or third-party SDKs. Phase 2 adds a CI grep that fails on `URLSession`, `NWConnection` or `NWListener` outside `Support/DebugServer.swift`.
- `DebugServer`: off by default (`SettingsKey.wirelessDebug` false), started only from the Settings toggle, listening on port 8765 only while enabled, every request needs the token, and it serves only `/`, `/status`, `/tail`, `/logs` and `/log/<name>` (names without `/` or `..`, `.log` suffix, from `Documents/Logs` only). It never serves project data. Build 4 (AppShell, which owns `MapperApp.swift`): the setting is session-only (reset to false at launch, so the server no longer starts by itself at every launch), a new token is generated each time the toggle is turned on (the stored token is removed first), and the listener stops when the app goes to the background. Phase 4 hardening in `DebugServer.swift` (Support, lead): compare the token in constant time and require the Wi-Fi interface (`requiredInterfaceType = .wifi`).
- Info.plist: `NSCameraUsageDescription` and `NSLocalNetworkUsageDescription` stay accurate; `NSPhotoLibraryAddUsageDescription` is removed unless Save to Photos ships; no location, microphone or tracking keys; no entitlements file (RESEARCH 3.9). Build 6 adds `BGTaskSchedulerPermittedIdentifiers` with BackgroundWork's one identifier (the lead edits `project.yml`; registration happens once, inside `#available(iOS 26.0, *)`, and a false return is logged; MODULES 3.48).

### 11.2 Files

- File protection: raw and derived files keep the system default (`completeFileProtectionUntilFirstUserAuthentication`), so capture and the pipeline keep reading and writing if the user locks the phone during a long foreground run (`.complete` would make those reads fail, RESEARCH 3.9). From build 4 (CR-4, applied in Core) `ProjectStore.writeData` gives `edits/`, `exports/` and `thumbnail.jpg` `.completeFileProtectionUnlessOpen` by default (`ProjectStore.defaultProtection(for:)`); new files can still be created while locked. A step that reads `edits/` while the phone is locked (possible only with build 6 background processing) treats the read failure as retryable.
- Atomic writes everywhere (3.3); JSON Lines are append-only and tolerant of a torn last line; binary decoders are bounds-checked (`CoreByteReader`) and version-checked.
- Raw immutability is enforced in code and verified by `SEAL.json` (D5) through `PackageCheck`, never by POSIX permissions (judges: chmod breaks delete, duplicate and restore).
- Files app access: with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` on, users can see, delete or add packages in `Documents/Projects`, so every package is treated as untrusted input on open.

### 11.3 Import validation (PackageCheck in build 4, restore in ProjectOps build 6)

1. Zip entries (restore): reject absolute paths, `..` components, backslashes, NUL bytes, symlink entries (from external attributes), duplicate names and compression methods other than STORE; resolve each target with `standardizedFileURL` and require it to stay inside the staging folder (zip slip).
2. Limits: at most 200,000 entries; the declared total size must fit in free space minus `refuseScanBelowBytes`; ZIP64 fields are range-checked; `.mchk` at most 256 MB, `.dpth` at most 4 MB, JPEG at most 32 MB.
3. Staging: restore unpacks into `Library/Application Support/Import/<uuid>/`, validates, then moves into `Documents/Projects/`; a colliding project id gets a new id.
4. JSON: size caps before decoding (`project.json` 1 MB through `ProjectStore.maxManifestBytes`, every other `readJSON` 32 MB by default with `maxBytes` to lower it, for example `editlog.json` 16 MB; `capturedroom.json` 64 MB in RoomModel's own reader; one JSON Lines line 64 KB in `RawScanReader`; all applied from build 4, CR-4, and again in ProjectOps restore); an oversized file throws `CoreError.fileTooLarge`; decode errors and unknown enum raw values become `CoreError.corruptFile`.
5. Versions: `schemaVersion <= ProjectManifest.currentSchema` or `CoreError.unsupportedSchema`; binary format versions are checked by the Core decoders; a newer `pipelineVersion` only marks derived products stale.
6. Names and paths: package folder names must be the canonical `<UUID>.mapperproj` and the manifest id must match (`ProjectStore.listProjects`, CR-4); record paths (`KeyframeRecord.imageFile`, `depthFile`, `PhotoPin.imageFile`) must pass `RawScanFolder.isSafeRelativePath` (relative, no empty, `.` or `..` component, no backslash or NUL) and files are opened only through `RawScanFolder.resolve`, which returns nil outside the folder (CR-4).
7. Seals: a restored package keeps its `SEAL.json` files and `PackageCheck.verify` runs before the project is listed.

### 11.4 Logs and personal data

- Logs never contain file contents, image data, user-entered text (project, room and object names, labels, notes, annotations, measurement names), full paths (package-relative paths or ids only), device names or identifiers (`identifierForVendor` and `UIDevice.name` are never read). Allowed: our UUIDs, counts, timings, sizes, configuration, error descriptions, `UIDevice.current.model`, the hardware model code from `LogStore.hardwareModel`, OS version.
- Logs stay 7 days in `Documents/Logs` (visible in Files).
- A real room scan is personal data. Fixtures saved from Diagnostics stay on the phone; only synthetic or sanitized fixtures are committed, and `tools/privacy_check.py` guards pushes.
- The bundle id is rewritten by Sideloadly, so no code compares against it or builds names from it (RESEARCH 3.9).

## 12. Memory, thermal and storage budgets

### 12.1 Memory (D17)

Global peak target 2.5 GB, working set during capture under 1.5 GB including ARKit and RoomPlan (RESEARCH section 1; the real jetsam ceiling is measured in build 4).

| Phase | Our share | Mechanism |
|---|---|---|
| Room capture | `MeshStore` under 150 MB; 4 `FrameCopier` buffers about 20 MB; at most 4 keyframes in flight (about 25 MB); snapshots negligible | copies only, no retained frames, 3 s flush; memory floor: keyframes stop under 600 MB available, the room finishes itself (after `flushNow`) under 400 MB or on a memory warning (4.2); processing is suspended while a capture is up (5.1) |
| House capture (5) | per-room `MeshStore.evict()` after the final flush; memory logged per room; under 800 MB suggest "Finish this floor" | D17 |
| Check at Done | `evaluateSealedRoom` under 100 MB | unwelded fast mesh, poses decimated to 2 Hz |
| Processing | one step at a time; budgets in 5.2; full or reduced variant from `os_proc_available_memory()` with 300 MB headroom; crash-loop guard forces reduced, then gives up (5.1) | D17 |
| Viewer | view mesh at most 300k faces; atlas pages 2048 in build 4 | 7.2 |
| Object Capture (5) | `ObjectCaptureView` kept mounted; capture session released before `PhotogrammetrySession`; nothing else runs during reconstruction; `reconstructionPending` resumes after jetsam | D17, RESEARCH 3.3 gotcha 10 |
| Memory warning | viewer disables hidden layers' parts; capture: `ARSessionHub.onMemoryPressure`, every recorder's `flushNow()`, then the engine finishes the room (4.2) | CaptureCore, RoomCapture |

### 12.2 Thermal ladder (`ThermalGovernor`, `ThermalPolicy`)

| State | Capture | Processing |
|---|---|---|
| `.nominal`, `.fair` | normal; `.fair` logged | normal |
| `.serious` | tier 1 `deviceHot`; keyframe interval scale 2; (build 5) coverage at 1 Hz and overlay frozen | reduced variants forced; 30 s wait before any step over 300 MB (RESEARCH 3.1 recommended 10) |
| `.critical` or `CaptureError.deviceTooHot` | the engine finishes the room itself and pauses the session right after the seal, before the sheet (RESEARCH 3.1 recommended 10); `Copy.RoomCapture.tooHotFinished` | wait before the next step |

Every change is a `CaptureEvent(kind: .thermal)` and the `PoseSample.thermal` value, so thermal history feeds the logs and the confidence review. Low Power Mode is logged (`DeviceState.summary`).

### 12.3 Storage (D18)

- Before a scan: refuse under `ProjectStore.refuseScanBelowBytes` (1.5 GB), warn under `warnScanBelowBytes` (3 GB). Object Capture preflight `objectCapturePreflightBytes` (3 GB).
- During capture (`StorageWatchdog`, 10 s): under `stopKeyframesBelowBytes` (1 GB) keyframes stop (logged, the quality sheet notes it); under `pauseCaptureBelowBytes` (300 MB) the engine finishes the room itself.
- Per room raw estimate 200 to 350 MB (up to about 300 keyframe JPEGs at about 0.7 MB, depth at about 150 KB each, mesh 15 to 40 MB); derived 60 to 150 MB (meshes, textures). Object Capture 1 to 4 GB per object. Settings shows storage used (`StorageUsage`) and each project row its size.
- The only raw removals are project delete, the confirmed Discard of the scan just captured, `InProgressScans.discard` of a cancelled or declined recovery, and the confirmed Free up space in build 6 (D6); `derived/` and `exports/` can be cleared any time. Export staging is cleaned when a share finishes and at launch (24 hours), and Quick Look reuses `exports/simple/` (9).

## 13. Build plan

This section and MODULES.md section 2 state the same plan; MODULES.md adds the per-module contracts.

### 13.1 Shipped and merged

Builds 1 and 2 (skeleton, capability probe, `LogStore`, `DebugServer`, UX copy, Units) and build 3 (0.3: probe plus Units, Geometry and Export self-tests) are on main. Wave 0 of build 4 is merged on `integration` and compiled green: Core (the shared contract), Coverage, MeshProcessing (`MeshChunk` renamed `MergeChunk`, `Cleanup.swift` and `ObjectIsolation.swift` finished) and Texturing, each with its self-test in the Diagnostics suite list.

### 13.2 Build 4 (0.4): Room MVP

Goal (lead decision): an amateur creates a project, scans one room with `RoomCaptureView(frame:arSession:)` while the same app-owned session records the anchor-local mesh, texture keyframes and a pose track, sees the scan quality sheet, then Results with Realistic, 3D Clean, Floor Plan and Raw Scan (Realistic is the textured mesh when TextureLowStep lands, otherwise RoomPlan's own model in Quick Look, otherwise an honest "Color is still being added"), reads room, wall, door, window and object dimensions with plus-or-minus in their units, finds, renames and deletes the project on Home, and exports USDZ, OBJ and a PDF plan (plus PLY, STL, GLB, SVG, DXF in millimeters, PNG and JSON) that follow Hide Furniture and the plan toggles. Settings > Diagnostics keeps the probe, runs every self-test and offers Demo Mode.

| Wave | Module | Folder | Depends on (earlier waves and wave 0 only) | Lines |
|---|---|---|---|---|
| 4a | Store | `ios/Sources/Store` | Core, Support | 900 |
| 4a | CaptureCore | `ios/Sources/CaptureCore` | Core, Support | 1400 |
| 4a | RoomModel | `ios/Sources/RoomModel` | Core, Geometry, MeshProcessing, Support | 1400 |
| 4a | MeshModel | `ios/Sources/MeshModel` | Core, Geometry, MeshProcessing, Export, Support | 800 |
| 4a | Pipeline | `ios/Sources/Pipeline` | Core, Support | 600 |
| 4a | MeasureCore | `ios/Sources/MeasureCore` | Core, Geometry, Coverage, Units, Support | 700 |
| 4a | FloorPlan | `ios/Sources/FloorPlan` | Core, Geometry, Export, Units, Support | 1400 |
| 4a | Viewer3D | `ios/Sources/Viewer3D` | Core, Geometry, MeshProcessing, Support | 1200 |
| 4a | GuidanceUI | `ios/Sources/GuidanceUI` | Core, Coverage, Support | 450 |
| 4a | Export revision (DXF millimeters and note) | `ios/Sources/Export` | none | 60 |
| 4b | MeshRecord | `ios/Sources/MeshRecord` | CaptureCore, Store | 500 |
| 4b | Keyframes | `ios/Sources/Keyframes` | CaptureCore, Store, Texturing | 900 |
| 4b | RoomCapture | `ios/Sources/RoomCapture` | CaptureCore, Store, RoomModel, GuidanceUI, Coverage | 1200 |
| 4b | Quality | `ios/Sources/Quality` | RoomModel, MeshModel, MeasureCore, Store, Coverage, MeshProcessing | 800 |
| 4b | TextureJob (types and store first; the step may slip) | `ios/Sources/TextureJob` | MeshModel, Store, Texturing, MeshProcessing | 700 |
| 4b | HomeUI | `ios/Sources/HomeUI` | Store, Pipeline | 500 |
| 4c | ScanUI | `ios/Sources/ScanUI` | RoomCapture, MeshRecord, Keyframes, Quality, CaptureCore, GuidanceUI, Store, Pipeline, RoomModel, MeshModel, FloorPlan | 1300 |
| 4c | QualityUI | `ios/Sources/QualityUI` | Quality | 400 |
| 4c | Results | `ios/Sources/Results` | Viewer3D, FloorPlan, MeasureCore, RoomModel, MeshModel, Store, Pipeline, Quality, TextureJob | 1300 |
| 4c | ExportUI | `ios/Sources/ExportUI` | Export, MeshModel, RoomModel, FloorPlan, MeasureCore, Store, Quality, TextureJob | 1100 |
| 4d | AppShell | `ios/Sources/AppShell` (plus `ContentView.swift`, `MapperApp.swift`) | every module above | 1300 |

Membership follows the real dependencies: GuidanceUI and FloorPlan need no other new module, so they are 4a, and the small Export revision (ExportUI may not edit Export) lands in 4a too; RoomCapture drives recorders only through CaptureCore's `ScanRecorder` protocol, so MeshRecord and Keyframes sit next to it in 4b instead of before it; Quality needs RoomModel's outline, MeshModel's fast mesh and MeasureCore's evidence types, so it is 4b; HomeUI needs only Store and Pipeline, so it moved to 4b (lead decision 7); the four remaining screens are 4c and never import each other (shared value types such as `ExportViewState` live in 4a modules); AppShell composes them and so gets its own wave 4d.

Wave gates: every module of a wave branches `impl/<module>` from the `integration` head where the previous wave is merged and green; it compiles on its branch through `workflow_dispatch` until green, with its self-test; merges go one at a time with `integration` compiled green after each; the lead adds the module's self-test line. After wave 4d the lead bumps `MARKETING_VERSION` to 0.4 and `CURRENT_PROJECT_VERSION`. TextureJob's types and `TextureStore` must be merged before 4c starts (Results and ExportUI import them); if only `TextureLowStep` and `KeyframeLoader` are not green, AppShell leaves the step out of `ProcessingPlans`, Realistic ships with its fallback, and the step moves to build 5 wave 5a.

Build 4 acceptance on the phone (TEST_PLAN): the explicit per-test list with build 4 variants in MODULES.md section 2.1 (for example QUAL-01 without Show Missing Areas, QUAL-02 as two scans, ROOM-11 with Keep Scanning continuing the scan, TEX-02 with four modes, OFF-01 without plan editing, EXP-05 without annotations; LIVE-01, LIVE-06, LIVE-07, LIVE-08 and LIVE-10 included; REC-03, EXP-09, PERF-03, PERF-10, PERF-25, PERF-28 and smoke #6, #8 and #9 N/A until build 5 or 7). The lead adds the same notes to TEST_PLAN.md 0.3 so the tester marks them N/A rather than failed.

### 13.3 Build 5 (0.5): house, objects, measuring, editing, live coverage

| Wave | Module | Depends on |
|---|---|---|
| 5a | Structure | RoomModel, Store |
| 5a | CoverageLive | CaptureCore, MeshRecord, RoomModel, Coverage |
| 5a | LiveMeshView | CaptureCore, Store, MeshRecord, Keyframes, GuidanceUI, Coverage |
| 5a | ObjectCapture | Store, GuidanceUI |
| 5a | ObjectModel | MeshProcessing, Export, Store, Geometry |
| 5a | MeasureTool | Viewer3D, MeasureCore, Store |
| 5a | LiveMeasure (Quick Measure) | CaptureCore, MeasureCore, Store, GuidanceUI |
| 5a | PlanEditor (CR-1 approved, applied by the lead before 5a; also fixture move, delete and recategorize) | FloorPlan, Store |
| 5a | Viewer3D revision (`loadModel(_:)` for Object Capture USDZ) | as build 4 |
| 5a | TextureJob's TextureLowStep and KeyframeLoader (only if they slipped from build 4) | MeshModel, Store, Texturing, MeshProcessing |
| 5b | CoverageOverlay | CoverageLive, LiveMeshView |
| 5b | LargeObject | CoverageLive, LiveMeshView, ObjectModel, CaptureCore |
| 5b | MissingAreas | CoverageLive, LiveMeshView, Quality |
| 5b | HouseUI | Structure, RoomCapture, ScanUI, QualityUI, FloorPlan |
| 5b | ObjectUI | ObjectCapture, ObjectModel, Viewer3D |
| 5c | ScanUI revision (CoverageLive hooks, minimap, CoverageOverlay, Show Missing Areas entry, two-pass fallback for `meshStripped`) | 5a, 5b |
| 5c | Results revision (MeasureTool, PlanEditor, object results, Change Category on the object card, orphaned edits) | 5a, 5b |
| 5c | HomeUI revision (House, Object, Quick Measure enabled) | 5a, 5b |
| 5c | ExportUI revision (house USDZ via `CapturedStructure`, multi-level plan, object USDZ) | 5a, 5b |
| 5d | AppShell revision (routes and covers, house and object processing plans) | everything |

User outcome: House mode room by room with the progress list, merge with alignment (D9), manual alignment, return to incomplete rooms, multiple floors; Object mode small and medium (Object Capture) and large (mesh driver with side guidance and crop); in-viewer measuring with snapping and confidence; Quick Measure; floor plan editing with undo; live colored coverage in mesh scans and patch passes, the minimap in Room mode; Show Missing Areas.

### 13.4 Build 6 (0.6): projects, photo realism, advanced

| Wave | Module | Depends on |
|---|---|---|
| 6a | ProjectOps: rename, duplicate (new id), archive, backup and restore with `StreamingZipWriter` and `StreamingZipReader` (STORE, CRC32 in 1 MB blocks, ZIP64 over 4 GB) and the 11.3 validation, Free up space (superseded scans or original photos, with the warning that Realistic cannot be rebuilt), `.mapperproj` document type | Store, Export (`CRC32`) |
| 6a | ObjectCrop: `PhotogrammetrySession.Request.Geometry(bounds:transform:)` re-run from the kept checkpoint; mesh crop for large objects | ObjectModel, ObjectCapture, MeshProcessing, Viewer3D, Store |
| 6a | AdvancedScan: the options of 4.7, including space scans without RoomPlan | Core |
| 6a | ReferenceLength (D21) through `setScaleCorrection` | Store, MeasureCore, RoomModel |
| 6a | BackgroundWork: `BGContinuedProcessingTaskRequest` for CPU steps and a `captureHighResolutionFrame(using:)` experiment, both behind `#available(iOS 26, *)` | Pipeline |
| 6a | Texturing revision: atlas streaming callback (accepted, lead decision 6) | none |
| 6a | TextureJob revision: `TextureHighStep` (Photo Realistic density, exposure normalization with `TXExposure`, pages written from the atlas callback) | as build 4 plus the Texturing revision |
| 6a | ExportUI revision: object OBJ, STL, PLY, GLB, measurements CSV and PDF room schedule, PNG model views, Photo Realistic exports | as build 4 plus ObjectModel |
| 6b | HomeUI, Results, ScanUI revisions (project menu, Photo Realistic style, crop, reference length, Advanced flow) | 6a |
| 6c | AppShell revision (routes, background processing wiring) | everything |

### 13.5 Build 7 and later

Everything else in SPEC.txt, explicitly (the same list as MODULES.md section 2.4):
- Build 7, wave 7a: EditMenus (3D editing: object menu Hide, Delete from clean model, Move, Rotate, Measure, Rename, Change category, Show raw geometry; wall menu Measure, Adjust, Add opening, Add door, Add window, Hide, Inspect geometry; label corrections), PhotoBrowser (photos associated with scan locations, fly to a photo's pose), SurfaceEvidence (5 cm measured, occluded, unscanned and inferred evidence map by BVH ray tests, for honest Hide Furniture and measurement grading), SpaceScan (commercial spaces, restaurants, offices, warehouses and outdoor structures beyond RoomPlan's envelope as several mesh passes with relocalization), HeadlessRoom (scheduled for build 7 by lead decision 5; D15 experiment behind a Diagnostics flag: `RoomCaptureSession(arSession:)` with our own `ARView`, the live green, yellow, red and gray overlay and our own coaching in Room mode, shipped only if device logs show depth and mesh survive). Wave 7b revises Results, ScanUI and AppShell.
- Build 8, wave 8a: MeshRefine (mesh-refined wall planes and jambs, counters, cabinets, columns and structural features with strict acceptance tests, keeping both RoomPlan and refined values), LevelsAndStairs (stair links between floors, UP and DN on both levels, level alignment by stairs). Wave 8b revises Results, FloorPlan and AppShell.
- Later, not scheduled (none is required by SPEC.txt): per-vertex color display (`ShaderGraphMaterial` spike, RESEARCH 3.5), a Metal visibility pass for texturing if CPU timing is too slow, high-resolution texture stills if the build 6 experiment proves their intrinsics and depth alignment, point cloud (E57, LAS) export, export of Object Capture images for Mac reconstruction, seam-based gain solve improvements, landscape viewer and iPad layout, localization of `Copy`.

MODULES.md section 4 maps every SPEC.txt requirement to its module and build.

## 14. Risk register

| # | Risk | Likelihood | Impact | Mitigation | Owner |
|---|---|---|---|---|---|
| 1 | RoomPlan's run drops depth or mesh on the `RoomCaptureView` path, or a watchdog re-apply raises `invalidARConfiguration` | Medium | High | Configuration logged at `didStartWith`, 1 s and 5 s; re-apply only when the watchdog sees depth or mesh missing; delegate identity check and relay; degraded modes with honest UI; two-pass fallback in build 5; raw capture never depends on RoomPlan | RoomCapture, CaptureCore |
| 2 | Parallel modules burn CI round trips (wrong API spellings, isolation errors, contract mismatches) | High | Medium | Core changes for build 4 applied before wave 4a (CR-2, CR-4, CR-5, CR-6) and none after; waves compile against merged waves only; exact names from RESEARCH and "(not in RESEARCH)" markers; the adversarial design review's API fixes (Combine imports, `ExportRequest`, static `dismantleUIView`, provider closure types); reviewer pass before each CI run; self-test per module | Lead, every module |
| 3 | A coordinate or UV convention error (plan handedness, projection signs, V origin) ruins plans or textures | Medium | High | One `PlanAxes`; one y flip in `PlanViewport`; bottom-left UVs end to end; D22 projection round trip and UV checkerboard in build 4 diagnostics; L-shaped room test | FloorPlan, TextureJob, Viewer3D |
| 4 | Jetsam during capture, consolidation, texturing or photogrammetry on the 6 GB A15 | Medium | High | Capture memory floor and memory-warning finish; processing suspended during capture; per-step budgets with reduced variants and 300 MB headroom; crash-loop guard; one step at a time; lazy CGImages; reconstruction alone; stamps make every step resumable | CaptureCore, RoomCapture, Pipeline, MeshModel, TextureJob, ObjectCapture |
| 5 | Wall loop fails on real rooms (stubs, split thick walls, open plans, curved walls) | Medium | High | Tolerant loop builder; floor polygon fallback marked estimated; mismatch logging; L-shaped, stub and curved fixtures; device fixtures from diagnostics | RoomModel |
| 6 | `hub.queue` stalls from mesh copies or frame work degrade tracking | Medium | High | Copy-only callbacks; JPEG on the io queue; 4-buffer bound; per-callback timing logged | MeshRecord, Keyframes, CaptureCore |
| 7 | Measurement numbers look better than the hardware supports | Medium | High | Coverage confidence plus the 3 cm RoomPlan floor; one low-confidence rule; provenance labels; tape protocol calibration; disclaimer | MeasureCore |
| 8 | Thermal throttling during 5-minute scans | High | Medium | `ThermalGovernor` ladder; 4 and 5 minute prompts; thermal in pose track and events | CaptureCore, ScanUI |
| 9 | RealityKit frame rate or memory with a 300k-face view mesh and atlases | Medium | Medium | View mesh budget, 2 m tile parts with layer culling, unlit materials, fps logged, budget lowered from device data | Viewer3D, MeshModel |
| 10 | Crash or kill corrupts a project or loses a scan | Low | High | InProgress plus seal plus move; ordered finish with nothing written after the seal; atomic writes that never recreate folders; tolerant JSON Lines; the live room file; launch recovery including sealed-but-unmoved folders and `.capturing` projects; stamps after outputs | Store, RoomCapture, AppShell |
| 11 | House merge stacks rooms silently, throws or crashes (build 5) | High | High | FrameLink gate; rooms saved before merge; attempt marker against crash loops; overlap check; manual alignment; per-room fallback | Structure, HouseUI |
| 12 | Object Capture limits: `.reduced` only, unknown image limit, view leak, long reconstruction (build 5) | High | Medium | Limits read at runtime; view kept mounted; reconstruction alone with progress and resume; large objects on the mesh path | ObjectCapture, ObjectModel |

## 15. Open device questions for build 4 diagnostics

Each answer is written to the log (`CaptureDiagnostics`, `LogStore`) in the first on-device run and read with `tools/phone_log.py`. The decision each one drives is named.

| # | Question | How it is measured | Drives |
|---|---|---|---|
| 1 | Does our configuration survive `RoomCaptureView(frame:arSession:)`'s run without a re-apply? | `session.configuration` (semantics, reconstruction, planes, format) at `didStartWith`, after 1 s and after 5 s; watchdog re-apply count | Whether the watchdog re-apply ever fires; HeadlessRoom (build 7) |
| 2 | Is `session.delegate === hub` after the view is created and after `didStartWith`? | identity check, relay installed or not | `ARDelegateRelay` need |
| 3 | Depth rate and format with RoomPlan running | share of frames with `sceneDepth`, depth and confidence pixel formats, sizes, confidence histogram | `depthStripped` frequency, confidence mapping |
| 4 | Mesh arrival | anchor count, faces per anchor, update interval per anchor, remove and re-add churn | 3 s flush, eviction, view mesh budget |
| 5 | Does RoomPlan still deliver a final room with walls after a watchdog re-apply? | `didUpdate` count, `didEndWith` error, wall count of the built room, `RoomBuilder` time | `invalidARConfiguration` handling |
| 6 | Memory | `os_proc_available_memory()` at launch, every 30 s in capture, at Done, before and after every step | Budgets in 5.2 and 12.1 |
| 7 | Thermal and battery over a 5-minute scan | thermal events, battery every 30 s | Thermal ladder, scan-length prompts |
| 8 | Keyframe path cost | JPEG encode time on the io queue, keyframes per minute, skipped keyframes (no free buffer), callback time on `hub.queue` | Gate and buffer count |
| 9 | Projection round trip (D22) | `CaptureDiagnostics.projectionRoundTrip`: unproject a live depth pixel with scaled intrinsics, reproject; error under 0.5 px | Texturing and coverage conventions |
| 10 | RealityKit V origin (D22) | `ViewerDiagnostics.uvCheckerContent()` in Diagnostics, and the same checkerboard in a QuickLook USDZ | UV convention |
| 11 | Plan handedness and wall axes | L-shaped room: `PlanAxes` drawing vs reality, `columns.1.y` of walls, floor polygon vs wall loop area mismatch | `RoomOutline`, `PlanViewport` |
| 12 | `completedEdges` on a half-scanned wall | edges per wall in the built room | Quality edge factor |
| 13 | Ceiling coverage | ceiling-face fraction of the outline, mesh ceiling height vs RoomPlan wall height vs tape | D13 25 percent gate |
| 14 | Viewer performance | fps and memory at 150k and 300k faces, `MeshResource(from:)` time per part | View mesh budget |
| 15 | Step timings | wall time of `consolidateMesh`, `cleanModel`, `floorPlan`, `quality`, `textureLow` | Progress UI, budgets |
| 16 | Export checks | `USDZWriter` output opens in QuickLook; RoomPlan export `.plist` metadata first bytes | Export paths |
| 17 | Quality check time at Done | wall time of `evaluateSealedRoom` for a 5-minute room | Sheet latency, 5 s budget |
| 18 | Object limits (logged in the probe for build 5) | `PhotogrammetrySession.limits`, `ObjectCaptureSession.maximumNumberOfInputImages` on a live session | Object preflight and counter |
| 19 | Storage per room | raw and derived bytes per room | Storage gates and estimates |
| 20 | Accuracy | TEST_PLAN section 3 tape table for walls, doors and ceiling | MeasureCore and Coverage constants |
