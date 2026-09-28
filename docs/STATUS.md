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
| `impl/meshrecord`, `impl/keyframes`, `impl/roomcapture`, `impl/quality`, `impl/texturejob`, `impl/homeui` | build 4 wave 4b (in progress) | pending |

The stopped routine sessions' branches (`design/architecture`, `docs/research-md`, `feat/texturing`, `feat/coverage`, `feat/meshproc`) were finished on the `impl/*` branches above and are fully contained in `integration`.

## What the current integration build does on the phone

Still the build 3 app shell (version 0.3): the capability probe and the on-device self-tests, now 16 suites: Units, Geometry, Export, Core, Texturing, Coverage, Mesh processing, Guidance UI, Pipeline, Mesh model, Store, Measure core, Viewer3D, Capture core, Room model and Floor plan. None of the new suites has run on a device yet. The build 4 screens arrive with waves 4c and 4d.

To test: install the IPA from the latest green `integration` run, open the app, wait for all suites, then pull the log with `python tools/phone_log.py usb` and report every line containing `self-test FAIL` and the per-suite timings (targets: Texturing under 3 s, Coverage under 2 s, Mesh processing under 3 s).

## Next

1. Build 4 (0.4), room MVP, in waves 4a, 4b, 4c, 4d as listed in docs/MODULES.md section 2.1.
2. Builds 5 and 6, then hardening, security and polish.
