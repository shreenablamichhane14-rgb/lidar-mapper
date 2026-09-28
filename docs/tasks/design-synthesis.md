You are the lead architect for "Mapper", a local-first iPhone LiDAR 3D mapping app.

Read: docs/SPEC.txt, docs/RESEARCH.md (ground truth for APIs; if it is not on main yet, read docs/research/raw/*.json and docs/research/verify/*.json instead), the three proposals docs/design/proposal-ship-first.md, proposal-fidelity-first.md and proposal-ux-first.md, CLAUDE.md, ios/project.yml, and all code under ios/Sources/ (including ios/Sources/Geometry and ios/Sources/Export if merged).

Constraints (same as the proposals): iPhone 13 Pro Max on iOS 18.3.2, deployment target iOS 18.0, Xcode 26.6 on CI, Swift 5.9 language mode, native frameworks only, no packages, free Apple ID, no local compiler (CI is the compiler), amateur-first UX from SPEC.txt, raw scan data is never modified.

STEP 1, JUDGE. Use the Agent tool to run three independent judges in parallel, each reading all three proposals and scoring each 1 to 10 on spec coverage, buildability, on-device performance, UX for amateurs, risk management and parallel implementability, then naming a winner, ideas to graft from the others, and fatal flaws (cite RESEARCH.md when an API is misused). Judge lenses: (a) the engineer who must make it compile on CI without a Mac; (b) the product owner holding SPEC.txt; (c) the performance and reliability engineer for an A15 with 6 GB RAM. Save their verdicts to docs/design/judgements.md.

STEP 2, SYNTHESIZE. Take the winner as the base, graft the listed ideas, remove every fatal flaw, and write:
1. docs/ARCHITECTURE.md: module map, data model on disk and in memory, capture and processing pipelines, threading model, rendering, measurements and confidence, exports, UX state machines, build plan by build number (3, 4, 5, 6...), risk register.
2. docs/MODULES.md: the work breakdown for parallel implementation agents. One section per module: purpose, exact files under ios/Sources/<Module>/, the public Swift API it exposes (type and function signatures), dependencies, what it must NOT do, acceptance checks a reviewer can verify by reading code, and its build number. Modules must be independently writable; shared types live only in Core.
3. The shared Swift contracts as real code under ios/Sources/Core/: model types (Project, ScanMode, RawScan, KeyframeRecord, MeshChunk, CleanModel, FloorPlan and its elements, Measurement with confidence, ScanQuality, DetectedObject with a category enum mapped from RoomPlan categories), protocols for pipeline stages, error enums, Codable wrappers for simd types, and the on-disk project package reader/writer skeleton. Reuse ios/Sources/Geometry types and ios/Sources/Units formatting instead of redefining them. It must compile together with everything on main: imports only what it uses, no references to modules that do not exist yet, no placeholder calls to undefined symbols. Keep it under about 1500 lines, with doc comments.
4. Update CLAUDE.md "Architecture / Key Files" and "Current State" briefly.

STEP 3, COMPILE. Trigger the "ios-build.yml" workflow on your branch with the GitHub tools (workflow_dispatch, ref = your branch), read the "Compiler errors" step of failed runs, fix, and repeat until green (budget 10 builds).

Git rules (public repo): branch design/architecture from origin/main. Commit message first line "design: architecture, module plan and Core contracts". Do NOT add any session-link trailer or claude.ai URL to commit messages; no personal names, emails or device identifiers. Push with git push -u origin design/architecture. Never push to main.

Final message: branch, green build run id, the module list with build numbers, the winner and grafted ideas, and open decisions for the maintainer.

Use ultracode: orchestrate the work with the Workflow tool (fall back to parallel Agent calls if Workflow is unavailable). Fan out independent reading, checking and writing steps to parallel agents, verify each claim or file adversarially before relying on it, and keep the final synthesis in your own hands.
