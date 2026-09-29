# Adversarial design review: findings and dispositions

Three hostile reviewers (API, spec and runtime lenses) read `docs/ARCHITECTURE.md`, `docs/MODULES.md` and `ios/Sources/Core/` on `integration` against `docs/SPEC.txt`, `docs/RESEARCH.md`, `docs/TEST_PLAN.md`, `docs/UX_COPY.md`, `docs/REUSE.md` and the merged modules. The design fixer checked every finding against those sources before acting (the code of the merged modules, the Core Swift, Copy.swift and the TEST_PLAN cases each finding cites) and applied the fixes to ARCHITECTURE.md, MODULES.md and Core on branch `impl/design-review`.

Totals: 58 findings (5 blockers, 27 majors, 26 minors). All 58 were confirmed. 58 are fixed in the three files in scope; 5 of them also need a small follow-up in a file outside this review's scope (listed at the end), which does not block implementation. None was rejected outright; where the fix differs from the reviewer's proposal, the line says how and why.

Ids below are this document's: A for the API lens, S for the spec lens, R for the runtime lens.

## API lens

### Blockers

- A1. DXF contract says millimeters and a units note, the merged `DXFWriter` writes meters with no note. Confirmed (DXFWriter.swift header: "1 drawing unit = 1 meter", no scaling, no note). Fixed: new MODULES 3.18a "Export revision" in wave 4a adds `DXFWriter.text(for:millimeters:unitsNote:)` and `data(for:millimeters:unitsNote:)` (x1000 on coordinates, radii, text heights, offsets, extents; one TEXT note), keeps `data(for:)` unchanged; ExportUI calls the new entry point with `Copy.ExportUI.dxfUnitsNote`; MODULES 3.5, 3.27 and ARCHITECTURE 9 describe the real behavior. Differs from the proposal only in that the note text comes from the caller (Export has no Copy dependency) and the new function has no defaults, so the old one keeps its meaning.

### Majors

- A2. Seal order does not wait for the async RoomBuilder task. Confirmed. Fixed: MODULES 3.21 and ARCHITECTURE 4.2 define one `Task` running 11 ordered steps (`RoomScanStats.finishSteps`, self-tested): room data, `try await RoomBuilder`, world map, detach recorders, awaited `finishRecording`, logs, flush, `RawScanWriter.close()`, seal, pause on a system stop, emit on main; "no file is written after SEAL.json" is an acceptance check.
- A3. `mesh_view.mchk` cannot store `isInferred`, so Raw Scan draws hole fills twice and some as measured. Confirmed (Core `.mchk` flags have no inferred bit). Fixed: the view mesh is simplified from measured faces only, `mesh_inferred.mchk` stays full resolution, `loadView` documents `isInferred == nil`, and the raw text-format fallback exports the inferred mesh as its own object (MODULES 3.13, 3.27; ARCHITECTURE 3.2, 5.4).

### Minors

- A4. `.sheet(item:)` over `UUID?` does not compile. Confirmed. Fixed: `struct ExportRequest: Identifiable, Equatable { let id: UUID; var projectID: UUID; var viewState: ExportViewState }` and `@Published var exportRequest` in AppShell (MODULES 3.29, ARCHITECTURE 10.1), no retroactive conformance.
- A5. `CleanModelStep(meshProvider: MeshModelStore.loadMeasured)` does not type-check. Confirmed. Fixed: `init(meshProvider: @escaping (ProjectPackage, UUID) -> MeshWithAttributes?)` and the verbatim closure `{ package, room in try? MeshModelStore.loadMeasured(package, room: room) }` in 3.29.
- A6. Store and Pipeline declare `ObservableObject` without Combine. Confirmed. Fixed: rule 0.2.2 requires `import Combine` (or SwiftUI) in every declaring file; Store and Pipeline rows, 3.10 and 3.15, ARCHITECTURE 2.1 list Combine.
- A7. TextureJob uses `UTType.jpeg` without UniformTypeIdentifiers. Confirmed. Fixed: `"public.jpeg" as CFString`, no new import.
- A8. `dismantleUIView` is static and cannot reach `engine`. Confirmed (RESEARCH 3.10 declaration). Fixed: `makeCoordinator() -> RoomScanEngine` and `static func dismantleUIView(_:coordinator:)` calling `coordinator.teardown()`.
- A9. `PlanViewport.fitting(min:max:...)` parameters shadow `Swift.min` and `Swift.max`. Confirmed. Fixed: internal names `lower` and `upper`.
- A10. `PlanModel.northAngle` and `PDFPlanWriter.Options.northAngle` use different conventions. Confirmed. Fixed: Core doc comment states counter-clockwise from plan +y and the conversion; ExportUI passes `Double.pi / 2 + Double(plan.northAngle)` (MODULES 3.5, 3.27; ARCHITECTURE 9).
- A11. ARCHITECTURE 10.4 redeclares `ViewerDisplayStyle`. Confirmed. Fixed: replaced by a comment that Viewer3D declares it.
- A12. REUSE 4.4 skeleton contradicts the CaptureCore and RoomCapture contracts. Confirmed. Fixed in scope: MODULES 3.11 and 3.21 and ARCHITECTURE 4.1 state that REUSE 4.4 is superseded (no `override init()` hub, no re-apply in `didStartWith`). Follow-up for the lead: the banner in REUSE.md itself.
- A13. APIs outside RESEARCH are unmarked or carry wrong versions. Confirmed. Fixed: GuidanceUI note now "UIAccessibility.post iOS 3, announcement priority iOS 17.0"; `ARPlaneGeometry.boundaryVertices` marked "(not in RESEARCH, iOS 11.3)"; new non-RESEARCH APIs added by this review are marked too (`beginBackgroundTask`, `openSettingsURLString`, `ARWorldMap.anchors`).
- A14. `QualityInputs.observations` claims a 2 Hz default the signature lacks. Confirmed. Fixed: `hz: Double = 2`.
- A15. BackgroundWork does not plan `BGTaskSchedulerPermittedIdentifiers` or single registration. Confirmed. Fixed: MODULES 3.48 and ARCHITECTURE 11.1 add the lead-owned Info.plist entry, one guarded `register` call in AppShell 6c and a self-test on the constant; added a device check because the bundle-id prefix rule is unverified under Sideloadly's bundle-id rewrite (a false return is logged and the feature stays off).

## Spec lens

### Blockers

- S1. Hide Furniture shows the wall and floor behind furniture as ordinary surfaces, no 3D marking, no legend. Confirmed (no occluded parts, scalar `occludedArea`, missing legend strings). Fixed: `CleanPartKind.occluded` quads for occluded wall spans and movable footprints (provenance `.inferred`, self-tested), `ViewerLayer.cleanOccluded` shown only while Hide Furniture is on, gray hatched material, a legend sheet with all five labels and their detail strings (MODULES 3.12, 3.17, 3.26, matrix 4.11; ARCHITECTURE 5.6, 7.3, 8.3). Core `CleanFloor.occludedArea` doc says footprints are derived from the object boxes, so no Core type change was needed.
- S2. Estimated door swing and wall thickness drawn like known geometry. Confirmed (RESEARCH: no hinge side, no thickness). Fixed: `PlanLayers.doorSwingEstimated` ("A-DOOR-EST", dashed leaf and arc for `.estimated` or `.inferred` swings, solid on A-DOOR for `.user`) and `wallsEstimated` ("A-WALL-EST", dashed outer face), both toggled with their groups, self-tested; matrix 4.14 updated.

### Majors

- S3. The build 4 acceptance list includes tests build 4 cannot pass. Confirmed for every id cited. Fixed: MODULES 2.1 now has an explicit list with build 4 variants (QUAL-01, QUAL-02, ROOM-11, TEX-02, OFF-01, EXP-05), N/A items (REC-03, EXP-09, PERF-03, PERF-10, PERF-25, PERF-28, smoke #6, #8, #9, the Show Missing Areas button in #4) and the added LIVE tests; ARCHITECTURE 13.2 points to it. Follow-up for the lead: the same notes in TEST_PLAN.md 0.3.
- S4. Walls, doors and windows cannot be selected, so "Wall 3" cannot be tied to a wall. Confirmed. Fixed: wall and opening parts carry `pickTag .element`, `ResultModel.selectedElement`, `selectPlanHit`, `visibleRows` filtering with Show All, a highlight copy on `.overlay`; self-test on row filtering (MODULES 3.26, ARCHITECTURE 7.4).
- S5. No per-wall area and no statement about openings. Confirmed. Fixed: a third row per wall ("wall.<uuid>.area", openings subtracted, `ConfidenceAdapter.area` sigma), `Copy.MeasureCore.wallAreaNote`, self-test now expects 12 wall rows and checks the door wall's area.
- S6. Object dimensions have no confidence API. Confirmed. Fixed: `DimensionGroup.objects` and `RoomDimensions.objectRows(for:evidence:)` with `roomPlanLength`; the Results card renders them; self-test.
- S7. Object category names and MapperError texts have no Copy source. Confirmed (`copyKey` values map to nothing; Copy's category list is unkeyed and differs). Fixed: `Copy.FloorPlan.categoryName(_:)` as an exhaustive switch in FloorPlan (4a), `ScanErrorCopy.alert(for:)` as an exhaustive switch in ScanUI, both self-tested; Core doc comments now say `copyKey` is for logs only. Follow-up for the lead: UX_COPY.md section 10 category list.
- S8. Camera-denied path has no Open Settings and no pre-permission screen. Confirmed. Fixed: `ScanAlertAction` and `ScanAlert.actions`, phase `permission` with the existing Permissions strings, `openSettings()` with `UIApplication.openSettingsURLString` (marked not in RESEARCH), reducer and self-test.
- S9. "Tap Resume" but no Resume control. Confirmed. Fixed with the reviewer's primary option: `ScanFlowModel.resume()` and `finishNow()`, Resume and Finish Now in the paused chrome and alerts, and the engine now stays `.paused` after `sessionInterruptionEnded` until Resume, so the existing text is true (MODULES 3.21, 3.24; ARCHITECTURE 4.2).
- S10. Exports ignore Hide Furniture and the plan toggles. Confirmed. Fixed: `ExportViewState` (declared in FloorPlan so Results and ExportUI, both 4c, share it without importing each other), `ResultScreen(projectID:onExport:onRetry:)`, `ExportSheet(projectID:viewState:)`, `planDrawing(_:prefs:toggles:)`, `cleanScene(_:includeHidden:includeMovable:)`, self-tests. Differs from the proposal only in where the shared type lives (the proposal placed it in ExportUI, which Results cannot import).
- S11. Texture score ignores lighting. Confirmed. Fixed: `darkAmbientIntensity` 250 and `longExposureSeconds` 1/30 tunables, dark keyframes excluded from the texture grid, `darkKeyframeFraction` stored, `Copy.Quality.noteDark` above 30 percent, self-test (100 vs 1000 lux).
- S12. QualityStep never re-evaluates, so the quick Done result is permanent. Confirmed. Fixed: the step hash adds the room's `buildRoom` and `consolidateMesh` stamps and the Done evaluation stores extra "done"; Results takes the degraded mode from `roomlog.json`, not from the evaluation.
- S13. The TextureJob slip contingency breaks 4c. Confirmed. Fixed: types and `TextureStore` never slip and merge first; only `KeyframeLoader` and `TextureLowStep` may slip, and AppShell then drops the step (MODULES 2.1, 3.23, 3.29; ARCHITECTURE 5.5, 13.2, 13.3).
- S14. Matrix promises editable objects in build 5 with no owner. Confirmed. Fixed: PlanEditor gains `moveFixture`, `deleteFixture`, `recategorizeFixture` (mapped to existing operations, self-tested); the build 5 Results revision adds Change Category; matrix 4.1 row 13 and 4.10 updated.
- S15. Missing areas are never shown in the result (QUAL-04). Confirmed. Fixed: one translucent red overlay square per `MissingAreaRecord` in 3D Clean and Raw Scan, a count, the Unscanned legend entry, a pure builder and self-test.

### Minors

- S16. LIVE matrix row and RoomCapture's "SPEC owned" claim messages Room mode never fires; no LIVE tests in build 4. Confirmed. Fixed: matrix row and SPEC-owned line now credit RoomPlan's coaching in Room mode and Mapper's texts in mesh-only scans (build 5); `GuidanceFilter.alwaysAllowed` gains `trackingLow` (RoomPlan has no tracking instruction) for LIVE-07; LIVE-01, 06, 07, 08, 10 added to the build 4 list.
- S17. Grid and Scale toggles have nothing to toggle. Confirmed. Fixed: grid lines on A-GRID and a scale bar on a new A-ANNO-SCAL layer, self-tested for all seven toggles.
- S18. Build 4 strings promise what build 4 does not do. Confirmed. Fixed: `Copy.Results.objectGuess` without "Tap to correct it"; new `roomPlanFailed`, `sceneTooLarge`, `tooHotFinished` texts; `Copy.ExportUI.colorNotReady` for color still being added.
- S19. No format-to-Copy mapping; a Units string with no setting. Confirmed. Fixed: `ExportCatalog.label(for:)` as an explicit switch with a self-test, `Copy.ExportUI.plyDetail`, and `ExportSettings.unitsOverride` so the existing Units option is real (the reviewer's first option).
- S20. Raw Scan shows the cleaned mesh, not the scan as captured. Confirmed. Fixed: removed floaters kept as `mesh_floaters.mchk` and drawn in Raw Scan; 3D Clean and exports keep the cleaned mesh.
- S21. Projects cannot be renamed until build 6. Confirmed. Fixed: Rename in HomeUI (swipe, context menu) and on the Results title through the existing `ProjectLibrary.rename`; matrix 4.17 moved to build 4.
- S22. Feature points are never kept in Room mode; the matrix promises plane anchors D14 disables. Confirmed. Fixed: best-effort `worldmap.arworldmap` (mesh anchors stripped, at most 3 s) in every room folder before sealing, new Core path `RawScanFolder.worldMapURL`; matrix 4.2 row rewritten (planes come from RoomPlan surfaces, ARKit plane anchors are not recorded by D14).

## Runtime lens

### Blockers

- R1. A RoomPlan failure blocks every representation because a required BuildRoomStep ends the job. Confirmed. Fixed: BuildRoomStep is optional and not scheduled for `roomPlanFailed` rooms, it catches RoomBuilder errors and completes without output, and `ScheduledStep.dependsOn` makes a failed step stop only its dependents (runner algorithm, ARCHITECTURE 5.1 item 7, self-tests in Pipeline and AppShell).
- R2. The Results tab gate has no data source, so demo, relaunched and failed projects never leave the processing view. Confirmed. Fixed: the processing view shows only while the job is queued or running and there is no `plan.json`; tabs decide from files; readers no longer depend on stamps (ARCHITECTURE 3.5); Retry via `onRetry` and `ProcessingPlans.retry`; self-tests for demo, empty state and queued cases.

### Majors

- R3. `.capturing` is never reconciled. Confirmed. Fixed: `.needsProcessing` is set in the same update that appends the room (`.ready` in Demo Mode), a failed `engine.start()` deletes the new project, `RecoveryService` reconciles every `.capturing` project (pure `reconcile` decision, self-tested), `discard` removes an emptied project, and HomeUI hides `.capturing` projects. Core `ProjectStatus` doc comment updated.
- R4. Processing keeps running during the next capture; a cancelled job can end `.ready`. Confirmed. Fixed: `ProcessingRunner.suspendAll(reason:)` and `resumeAll()` called by AppShell around the scan cover, `enqueue(_:atFront:onFinish:)` for the scan just finished, and `.cancelled` keeps `.processing`.
- R5. Two owners toggle `isIdleTimerDisabled`. Confirmed. Fixed with a different placement: `IdleTimerGuard` (holder tokens) lives in Pipeline (wave 4a, already the idle-timer owner and a dependency of every screen that needs it), not in a new lead-owned Support file, so no extra pre-wave task; ScanUI adds Pipeline as a dependency; acceptance checks forbid other writes.
- R6. No crash-loop guard for resumed steps. Confirmed. Fixed: `PipelineAttempt` marker at `derived/pipeline_attempt.json` (new Core path `pipelineAttemptURL`; renamed from the proposed `attempt.json` to avoid confusion with Structure's), first death reruns reduced, second gives up with `outOfMemory`; resumePending runs only after Home appears; pure decision self-tested.
- R7. Late writes recreate discarded or deleted folders; cancel has no ordered teardown. Confirmed (Core `writeData` always created parents). Fixed: Core CR-6 `writeData(... createParents:)` and `ensureDirectory(_:inside:)`, `RawScanWriter.close()` with dropped-write counting, `ScanEngine.discard()` doing the ordered stop before deleting, recorders detached before `finishRecording` with later callbacks ignored, HomeUI cancelling the job before delete, Store's seal creating parents only inside an existing package.
- R8. ARSession teardown is not guaranteed; retain cycle. Confirmed. Fixed: one idempotent `teardown()` replaces `close()` and `stopIfRunning()`, called on every terminal phase and by `dismantleUIView`; hub closures captured weakly and cleared; controller holds the engine weakly; deinit log lines and a smoke check.
- R9. No memory watchdog during capture; memory warnings have no owner. Confirmed. Fixed: `MemoryPolicy` (600 MB stop keyframes, 400 MB or a warning finishes the room), the hub observes the memory warning notification, `ScanRecorder.flushNow()` (default empty, MeshStore flushes), Core `MapperError.lowMemory` with Copy text; the no-auto-stop-at-5-minutes choice is now a listed departure.
- R10. A kill during capture loses all RoomPlan data. Confirmed. Fixed: `capturedroom-live.json` every 10 s and on interruption (new Core path `liveCapturedRoomURL`), RoomModel falls back to it with `RoomInput.isProvisional` and every value estimated, and the finish sequence runs inside `beginBackgroundTask`.
- R11. Engine-initiated finish has no reducer transition. Confirmed. Fixed: `ScanFlowSignal.engineStopping` (capturing to stopping) and `roomFinished` accepted in capturing; self-tests.
- R12. The delegate relay installs itself after run and nothing checks `delegateQueue`. Confirmed. Fixed: the identity check logs delegate and queue and re-asserts only the queue; the relay forwards to the previous delegate first on the incoming queue and never changes the queue; auto-install behind `SettingsKey.captureRelay` (default on, Diagnostics toggle); hub callbacks re-hop value copies when on a foreign queue.
- R13. At thermal critical the session keeps running behind the sheet. Confirmed. Fixed: engine-initiated finishes pause the hub right after the seal and set `RoomScanResult.stoppedBySystem`, which build 5 uses to hide Show Missing Areas.
- R14. Demo Mode is blocked by the camera and LiDAR preflight. Confirmed. Fixed: `ScanPreflight.run(mode:isDemo:)` and `evaluate(... isDemo:)` skip camera and LiDAR (50 MB storage floor), AppShell's no-LiDAR gate lets Demo Mode through; self-test.

### Minors

- R15. The keyframe gate records a pose before the pool check. Confirmed (`KeyframeSelector.consider` appends on accept). Fixed: the selector is consulted only when a buffer is free and tracking, storage, memory and pause allow; pure helper and self-test.
- R16. Engine `state` and `lastResult` are mutated off main. Confirmed. Fixed: written only in the main hop that emits the event (Core `ScanEngine` doc, MODULES 3.21, ARCHITECTURE 6); the RoomPlan-on-main acceptance check reworded.
- R17. The InProgress root is not excluded from backup. Confirmed. Fixed in Core: `inProgressRoot()` applies the exclusion on every call; Store excludes each new scan folder.
- R18. DebugServer auto-starts at every launch with a token that never rotates. Confirmed. Fixed in scope: AppShell makes the setting session-only, removes the token before each enable and stops the listener in the background. Follow-up for the lead (Phase 4, Support file): `requiredInterfaceType = .wifi` and a constant-time token compare.
- R19. The JSON Lines reader tolerates only a torn last line. Confirmed. Fixed: every undecodable line is skipped and counted, and a failed append is truncated back.
- R20. Processing runs at full speed at thermal `.serious`. Confirmed. Fixed: the runner forces reduced variants and waits 30 s before steps over 300 MB (ARCHITECTURE 5.1, 12.2).
- R21. Export staging and Quick Look files accumulate. Confirmed. Fixed: the share sheet deletes its staging folder, Quick Look reuses `exports/simple/`, and launch removes staging older than 24 hours.

## Lead decisions applied

1. CR-1 (move, resize, merge and split edit operations) is marked approved for build 5 in MODULES 3.0 and ARCHITECTURE 3.8; the lead applies it before wave 5a. PlanEditor 3.37 and ARCHITECTURE 13.3 say so.
2. CR-4 hardening is applied in Core now: `RawScanFolder.resolve(_:) -> URL?` with `isSafeRelativePath` (absolute paths, `..`, `.` and empty components, backslash and NUL rejected; lexical containment check after standardizing the folder), `readJSON(_:from:maxBytes:)` with a 32 MB default, 1 MB for `project.json` and `CoreError.fileTooLarge`, `listProjects()` accepting only canonical `<UUID>.mapperproj` folders whose manifest id matches, and `writeData(_:to:protection:createParents:)` keeping `.atomic` and defaulting to `.completeFileProtectionUnlessOpen` for `edits/`, `exports/` and `thumbnail.jpg` (raw and derived keep the system default). CoreSelfTest checks path rejection, the size cap, package names and protection.
3. CR-2 is applied: `MeasuredValue.isLowConfidence(length:)` is exactly "2 sigma above max(4 cm, 3 percent of the length)" (relative part only for areas and volumes), with `isLowConfidence(kind:)`; `MeasureDisplay.isLowConfidence` delegates to it and every screen uses MeasureDisplay. CoreSelfTest covers short, long, area and no-sigma cases.
4. The quality sheet after sealing is kept for build 4. Discard deletes only the scan just captured through the new `ProjectLibrary.discardRoom(_:in:)` and deletes the project only when no room is left. Show Missing Areas (build 5, MissingAreas 3.40) is specified on the still-running session per D19 and only for rooms not stopped by the system.
5. HeadlessRoom is scheduled for build 7 (both documents already had it there; now annotated as the lead's decision).
6. The Texturing atlas-streaming callback is accepted for build 6: a Texturing revision in wave 6a, used by `TextureHighStep` (MODULES 1, 2.3, 3.49; ARCHITECTURE 2.2, 5.5, 13.4).
7. HomeUI moved from wave 4c to 4b. Verified: its dependencies are Core, Store, Pipeline, Units and Support only (Store and Pipeline are 4a), and the features this review added (rename, delete after cancel, hiding `.capturing`) use only Store and Pipeline.

## Core files changed

- `ProjectPackage.swift`: CR-4 (safe `resolve`, `isSafeRelativePath`, size-capped `readJSON`, canonical package names in `listProjects`, `defaultProtection(for:)`), CR-6 (`createParents`, `ensureDirectory(_:inside:)`), new paths `pipelineAttemptURL`, `liveCapturedRoomURL`, `worldMapURL`, InProgress backup exclusion, CR-5 doc comment.
- `CoreErrors.swift`: `MapperError.lowMemory`, `CoreError.fileTooLarge`, `copyKey` documented as a log key.
- `MeasurementRecord.swift`: CR-2 rule (`isLowConfidence(length:)`, `isLowConfidence(kind:)`, `lowConfidenceRelative`).
- `ScanEngine.swift`: `ScanEngine.discard()`, main-only `state` rule, `FakeScanEngine.discard()`.
- `FloorPlanModel.swift`, `CleanModel.swift`, `ProjectModel.swift`: doc comments (north angle convention, category names and occluded footprints, `.capturing` reconciliation).
- `CoreSelfTest.swift`: checks for path rejection, JSON size cap, no parent recreation, package names, file protection, the low-confidence rule, `lowMemory`, new paths and `FakeScanEngine.discard`.

## Follow-ups outside this review's file scope (not blocking)

- TEST_PLAN.md 0.3: the build 4 N/A and variant notes of MODULES 2.1 (S3).
- UX_COPY.md section 10: the category list matching `ObjectCategory` (S7).
- REUSE.md 4.4: a "superseded by MODULES 3.11 and 3.21" banner (A12).
- DebugServer.swift (Phase 4): Wi-Fi-only listener and constant-time token compare (R18).
- project.yml before wave 6a: `BGTaskSchedulerPermittedIdentifiers` (A15).

## Readiness

The design is ready for parallel implementation of build 4 once `impl/design-review` compiles green on CI (Core changed) and is merged into `integration`; wave 4a (Store, CaptureCore, RoomModel, MeshModel, Pipeline, MeasureCore, FloorPlan, Viewer3D, GuidanceUI and the Export revision) can then start.

## Build 4 end-to-end review

Three reviewers (flow, threads and UX lenses) walked the assembled build 4 on `integration` end to end: scan, processing, Results, export, relaunch. The fixer checked every finding against the code on branch `impl/b4-e2e` and fixed it there. Totals: 13 findings (5 majors, 8 minors), all confirmed, all fixed. Ids below are this section's (E1 to E13).

### Majors

- E1 (flow). A failed optional step (textureLow, consolidateMesh) was forgotten after a relaunch: the job completed, the project became `.ready`, and Realistic and Raw Scan said "Not ready yet" with no Retry. Confirmed. Fixed: `ProcessingPlans.statusAfter` returns `.needsAttention` when a step in `ProcessingPlans.attentionSteps` (consolidateMesh, textureLow, textureHigh) produced nothing, and rooms are still marked processed. Quality and thumbnail failures keep `.ready`, because the result is complete without them. After a relaunch, `ResultAvailability.compute(..., status:)` shows captured but missing color and a missing raw mesh as failed next to Retry (`isSettledFailure`), the Retry banner says color when only Realistic failed, and the export sheet says `Copy.ExportUI.colorMissing` instead of "still being added" once processing has ended (`ExportInputs.isProcessing`). Self-tests in AppShell, Results and ExportUI.
- E2 (threads). The crash-loop guard counted any end of the app during a step as an out-of-memory death, so leaving the app during processing forced reduced output or a false failure, and a reduced result stayed fresh forever. Confirmed. Fixed differently from the proposal: the step is not cancelled when the app leaves the foreground (a quick app switch would restart a long bake), and no background task is taken (an unended one gets the app killed). Instead the runner observes willResignActive, didEnterBackground and didBecomeActive, and the running step's marker carries `backgroundedAt` while the app is out of the foreground (`PipelineForeground`, one file lock around every marker access, so a mark never brings back a marker a step just ended). `prepare` removes such a marker without counting it. A reduced run chosen for memory or heat is stamped with a `+reduced` suffix (`PipelineStepExecutor.stampHash`), so Retry or the next job redoes it at full quality when memory allows; a reduced run that followed a real death in that step keeps the plain stamp, so Retry does not crash the app again with the full variant. The lifecycle code lives in `ProcessingRunner+Lifecycle.swift`. Self-tests in Pipeline; ARCHITECTURE 5.1 updated.
- E3 (UX). Well scanned short walls and small rooms showed "Low confidence, rescan this section" on their areas, because the relative-only area rule met RoomPlan's 0.015 m sigma floor. Confirmed with the real constants. Fixed: areas and volumes take their flag from their factors (wall area from its length and height, floor area from room length and width, wall area total from the wall areas, volume from floor area and ceiling height). New row overloads of `MeasureDisplay.accuracyText`, `accessibilityText` and `spokenAccuracy` use `DimensionRow.isLowConfidence`, and the Results row view and VoiceOver use them. This refines how CR-2 is applied to products; the rule for lengths is unchanged. MeasureCore self-test adds a 0.8 x 1.5 x 2.4 m closet (60 checks).
- E4 (UX). The PDF floor plan picked its scale and scale bar by paper size, so a metric user got 1/4" = 1'-0" with a feet scale bar. Confirmed. Fixed: `PDFPlanWriter.Options.metric` (nil keeps the paper rule) selects 1:50 and 1:100, or 1/4", 1/8" and a new 1/16" = 1'-0"; the 1:N fallback and the scale bar follow the same units. ExportRunner passes the effective plan units after the export's Units override, and the sheet starts on A4 for metric. Export and ExportUI self-tests.
- E5 (UX). Estimated values looked exactly like measured ones in the list and in VoiceOver. Confirmed. Fixed: estimated values read "Not measured directly, estimated ±x" (`Copy.MeasureCore.estimatedAccuracy` and its spoken form, UX_COPY section 9), low confidence still wins, and rows not measured directly show a dashed circle icon so they differ without color.

### Minors

- E6 (flow). After a RoomPlan failure, CleanModelStep still built walls from the provisional `capturedroom-live.json`, so Results said "no walls" while listing measurements and exporting a plan. Confirmed. Fixed: CleanModelStep leaves out a room whose roomlog.json says `.roomPlanFailed` (`CleanModelStep.roomPlanFailed`), matching ARCHITECTURE 4.2. Recovered scans have no roomlog.json and keep the live fallback. RoomModel self-test.
- E7 (flow). A job interrupted by `suspendAll` was requeued at index 0, in front of the scan just finished, when its step outlived the capture. Confirmed. Fixed: `PipelineJobQueue` remembers jobs put at the front while another job runs and requeues the interrupted job behind them. Pipeline self-test.
- E8 (threads). `MeshStore.evict()` was never called, so the room mesh stayed in RAM through the Done quality check. Confirmed. Fixed: `ScanRecorder.releaseMemory()` (empty by default, MeshStore evicts), called for every recorder on the hub queue at the end of `finishRecorders()`; index and stats survive.
- E9 (UX). At accessibility text sizes the open measurement list collapsed the 3D view or plan. Confirmed. Fixed: the list is capped at 35 percent of the screen and the content keeps at least 160 pt.
- E10 (UX). The floor plan had no way back after being dragged off screen. Confirmed. Fixed: double tap, the VoiceOver action Reset View, and a Reset View button on the Floor Plan tab reset pan and zoom.
- E11 (UX). No haptic or announcement when processing finished. Confirmed. Fixed: when the processing view gives way to the result without a failure, ResultModel plays the success haptic and announces `Copy.Processing.done`.
- E12 (UX). The object card read "Mapper thinks this is a Oven." Confirmed. Fixed: `Copy.Results.objectGuess` reads "Mapper's guess: Oven". Follow-up for build 5: `Copy.ObjectMenu.guessedLabel` has the same article problem and needs the same form before it is used.
- E13 (UX). The export sheet never said DXF is in millimeters but offered a feet Units choice. Confirmed. Fixed: `Copy.ExportUI.dxfDetail` ("Drawn in millimeters.") and the picker is titled "Label units" for DXF (`Copy.ExportUI.labelUnits`); UX_COPY section 14 updated.

### Files changed

AppShell: `AppProcessingPlans.swift`, `AppShellSelfTest.swift`. Pipeline: `PipelineAttempt.swift`, `PipelineStepExecutor.swift`, `PipelineJobQueue.swift`, `ProcessingRunner.swift`, `ProcessingRunner+Lifecycle.swift` (new), `PipelineSelfTest.swift`, `PipelineSelfTest+Files.swift`. Results: `ResultAvailability.swift`, `ResultLoader.swift`, `ResultModel.swift`, `ResultScreen.swift`, `ResultTabs.swift`, `ResultDimensionsPanel.swift`, `ResultObjectCard.swift`, `ResultsSelfTest.swift`. ExportUI: `ExportCatalog.swift`, `ExportRunner.swift`, `ExportSheet.swift`, `ExportUISelfTest.swift`. Export: `PDFPlanWriter.swift`, `ExportSelfTest.swift`. MeasureCore: `MeasureDisplay.swift`, `MeasureRoomDimensions.swift`, `MeasureCoreSelfTest.swift`, `MeasureCoreSelfTestFixtures.swift`. RoomModel: `RoomModelSteps.swift`, `RoomModelSelfTestEdits.swift`. CaptureCore: `CaptureRecorder.swift`. MeshRecord: `MeshStore.swift`, `MeshRecordSelfTest.swift`. RoomCapture: `RoomScanPersistence.swift`. FloorPlan: `PlanCanvasView.swift`. Support: `Copy+ExportUI.swift`, `Copy+MeasureCore.swift`, `Copy+Results.swift`. Docs: `ARCHITECTURE.md` (5.1 and 8.3), `UX_COPY.md` (sections 9 and 14), this file.
