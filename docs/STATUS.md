# Mapper build status

This file is the lead session's handoff. It says what is on the `integration` branch, what the maintainer should test on the phone, what is stubbed, and what comes next. The maintainer merges `integration` into `main` after a privacy scan.

## Branch states (2026-09-28)

| Branch | Content | CI |
|---|---|---|
| `integration` | main plus Core contracts (with design review fixes), RESEARCH.md (final check done), REUSE.md, THIRD_PARTY_NOTICES.md, ARCHITECTURE.md, MODULES.md, docs/design/review.md, Texturing, Coverage, MeshProcessing, all self-tests wired | green, run 36485459310 |
| `impl/core` | Core contracts, merged | green, run 36466990651 |
| `impl/texturing` | texturing completion, merged | green, run 36468628757 |
| `impl/coverage` | coverage completion, merged | green, run 36468934774 |
| `impl/meshproc` | Cleanup, ObjectIsolation, MergeChunk rename, merged | green, run 36469943388 |
| `impl/research`, `impl/reuse`, `impl/docs` | docs, merged | docs only |
| `impl/design-review` | Phase 2 adversarial design review: 58 findings (5 blockers, 27 majors, 26 minors), all fixed, merged | green, run 36485459310 |
| `impl/store` | build 4 wave 4a: project library, raw writer and reader, recovery, package check, edits; 71 self-test checks; merged | green, run 36489632202 |
| `impl/capturecore` | wave 4a: ARSession hub, delegate relay, depth and mesh watchdog, thermal, storage, frame reading; 96 checks; merged | green, run 36490617439 |
| `impl/roommodel` | wave 4a: room outline from the wall loop, clean model, metrics, clean mesh, edits, steps; 121 checks; merged | green, run 36490689063 |
| `impl/meshmodel` | wave 4a: mesh consolidation, store, export adapter, consolidate step; 92 checks; merged | green, run 36489160068 |
| `impl/measurecore` | wave 4a: confidence adapter, display, room dimensions, snap set; 52 checks; merged | green, run 36489820409 |
| `impl/pipeline` | wave 4a: processing runner, guards, crash-loop marker, idle timer; 94 checks; merged | green, run 36489222148 |
| `impl/floorplan` | wave 4a: plan builder, drawing, renderer, canvas, plan and thumbnail steps; 112 checks; merged | green, run 36491739901 |
| `impl/viewer3d` | wave 4a: RealityKit viewer, render mesh packing, orbit camera, picking; 79 checks; merged | green, run 36490322971 |
| `impl/guidanceui` | wave 4a: guidance banner, coaching filter, announcer; 54 checks; merged | green, run 36488457971 |
| `impl/export-dxf` | wave 4a: DXF in millimeters with a units note; 21 new checks; merged | green, run 36487700322 |
| `impl/meshrecord`, `impl/keyframes`, `impl/roomcapture`, `impl/quality`, `impl/texturejob`, `impl/homeui` | build 4 wave 4b, merged | green, runs 36493342975, 36494443298, 36495914817, 36496342489, 36494186747, 36493553196 |
| `impl/scanui`, `impl/qualityui`, `impl/results`, `impl/exportui` | build 4 wave 4c, merged | green, runs 36501518279, 36498756414, 36501407751, 36500269139 |
| `impl/appshell` | build 4 wave 4d, merged; version 0.4 (build 4) | green, run 36505491410 |
| `impl/b4-e2e` | build 4 end-to-end review fixes (in progress) | pending |
| `impl/build5-spec` | build 5 module contracts (in progress) | docs only |

The stopped routine sessions' branches (`design/architecture`, `docs/research-md`, `feat/texturing`, `feat/coverage`, `feat/meshproc`) were finished on the `impl/*` branches above and are fully contained in `integration`.

## Build 4 (0.4): room MVP

### What it does

- Home lists projects (thumbnail, subtitle, processing and needs-work badges, search, rename, delete). New Scan opens the mode picker; Room is enabled, the other modes say "Coming in a later version".
- Room scan: preflight (free space, camera permission with Open Settings on denial), tips, Apple's RoomCaptureView with live coaching and outlines on Mapper's own ARSession, which records the LiDAR mesh (anchor-local chunks every 3 s), texture keyframes with depth, a pose track and photos at the same time. Mapper's guidance banner adds messages RoomPlan does not give. Pause, Resume, Cancel (Keep Scanning or Discard) and Done.
- Done shows the scan quality sheet over the camera (Shape, Walls, Floor, Ceiling, Color and texture, missing areas count, a plain verdict), then Finish, Finish Anyway or Discard.
- Finish seals the raw scan (never modified afterwards) and processing runs in order: room model, clean model, floor plan (the result screen opens here), mesh consolidation, quality, thumbnail, textures.
- Result screen: Realistic (photo textured mesh), 3D Clean, Floor Plan and Raw Scan, room dimensions (length, width, floor area, perimeter, ceiling height, wall, door and window sizes) with plus or minus confidence in the chosen units, estimated and inferred values labeled, Hide Furniture, legend, read-only object card.
- Export: USDZ, OBJ, PLY, STL, GLB, PDF floor plan, SVG, DXF (millimeters, units note), PNG and JSON; exports follow the result screen's view state.
- Settings: units, inch fractions, both units, guidance vibration, keep scan photos, tips reset, storage used, wireless debug log (session only, off at every launch, stops in the background), Diagnostics.
- Diagnostics: capability probe, memory, 27 self-test suites (they also run once automatically after each new install and log to the phone log), Demo Mode (the whole flow with a sample room, no camera), snapshot recording, texture orientation check, Share Log.
- Launch: unfinished scans are offered for recovery; interrupted processing resumes.

### What to test first on the phone

1. Install the IPA from the latest green `integration` run and open the app. Wait about a minute, then pull the log (`python tools/phone_log.py usb`) and report every `self-test FAIL` line and each suite's time. None of the 27 suites has run on a device yet.
2. Settings > Diagnostics > Demo Mode on, then run New Scan > Room through to the result screen and an export. This checks every screen without the camera.
3. Demo Mode off. Scan one real room (TEST_PLAN ROOM-01 to ROOM-05), finish, and wait for the result screen. The log answers the open device questions: whether scene depth and the LiDAR mesh keep arriving under RoomCaptureView (lines from the capture watchdog and `degraded` mode), mesh anchor counts, keyframe counts and skips, memory, and the RoomPlan callback thread.
4. Then the build 4 acceptance list in `docs/TEST_PLAN.md` section 0.3 ("Build 4 (0.4) notes"). TextureLowStep made it into build 4, so TEX-01 and EXP-02 run with textures. PROJ-02 (rename) also works in build 4.
5. Measurement accuracy protocol (TEST_PLAN section 3) on the tape-measured room, and the smoke list (section 5) except #6, #8, #9 and the Show Missing Areas button.

### Stubbed or not in build 4

- House, Object, Quick Measure and Advanced modes (build 5 and 6); measuring inside the model and plan editing (build 5); Show Missing Areas (build 5); Photo Realistic density (build 6); project duplicate, archive, backup and restore (build 6).
- Label correction for detected objects (build 7).

### Known risks for the first device run

- RoomCaptureView may still drop scene depth or the mesh on iOS 18.3; the watchdog re-applies the configuration once and the degraded mode is logged and shown (meshStripped falls back to the room shell for coverage).
- Memory during texturing and mesh consolidation on 6 GB is estimated, not measured; steps pick a reduced variant under memory pressure and log the peak.
- `CapturedRoom.export` is called off the main thread; if it throws, export falls back to Mapper's own USDZ writer (logged).
- Texture orientation and UV conventions are verified by self-tests and the Diagnostics texture check, not yet by eye on a real scan.

## Next

1. Merge the build 4 end-to-end review fixes and compile green.
2. Build 5 (0.5): House, Object and Quick Measure modes, measuring in the model, plan editing, live coverage and Show Missing Areas, from the expanded contracts in docs/MODULES.md.
3. Build 6, then hardening, security and polish.
