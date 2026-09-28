# Mapper build status

This file is the lead session's handoff. It says what is on the `integration` branch, what the maintainer should test on the phone, what is stubbed, and what comes next. The maintainer merges `integration` into `main` after a privacy scan.

## Branch states (2026-09-28)

| Branch | Content | CI |
|---|---|---|
| `integration` | main plus Core contracts, RESEARCH.md (final check done), REUSE.md, THIRD_PARTY_NOTICES.md, ARCHITECTURE.md, MODULES.md, Texturing, Coverage, MeshProcessing, all self-tests wired | green, run 36470642558 |
| `impl/core` | Core contracts, merged | green, run 36466990651 |
| `impl/texturing` | texturing completion, merged | green, run 36468628757 |
| `impl/coverage` | coverage completion, merged | green, run 36468934774 |
| `impl/meshproc` | Cleanup, ObjectIsolation, MergeChunk rename, merged | green, run 36469943388 |
| `impl/research`, `impl/reuse`, `impl/docs` | docs, merged | docs only |
| `impl/design-review` | Phase 2 adversarial design review (in progress) | pending |

The stopped routine sessions' branches (`design/architecture`, `docs/research-md`, `feat/texturing`, `feat/coverage`, `feat/meshproc`) were finished on the `impl/*` branches above and are fully contained in `integration`.

## What the current integration build does on the phone

Still the build 3 app shell (version 0.3): the capability probe and the on-device self-tests. The self-test list now has seven suites: Units, Geometry, Export, Core, Texturing, Coverage and Mesh processing. None of the new suites has run on a device yet.

To test: install the IPA from the latest green `integration` run, open the app, wait for all seven suites, then pull the log with `python tools/phone_log.py usb` and report every line containing `self-test FAIL` and the per-suite timings (targets: Texturing under 3 s, Coverage under 2 s, Mesh processing under 3 s).

## Next

1. Phase 2: fix the design review findings in ARCHITECTURE.md, MODULES.md and Core, compile green, merge.
2. Build 4 (0.4), room MVP, in waves 4a, 4b, 4c, 4d as listed in docs/MODULES.md section 2.1.
3. Builds 5 and 6, then hardening, security and polish.
