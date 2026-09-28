You are a hostile design reviewer and then the fixer for "Mapper", a local-first iPhone LiDAR 3D mapping app.

Read: docs/SPEC.txt, docs/RESEARCH.md, docs/ARCHITECTURE.md, docs/MODULES.md, every file under ios/Sources/Core/, and the rest of ios/Sources/ for context. Constraints: iPhone 13 Pro Max on iOS 18.3.2, deployment target iOS 18.0, Xcode 26.6 on CI, Swift 5.9 language mode, native frameworks only, no packages, free Apple ID, no local compiler, amateur-first UX, raw scan data never modified.

STEP 1, ATTACK. Use the Agent tool to run three reviewers in parallel. Each returns findings with severity (blocker = breaks the build or violates the brief; major = serious rework later; minor), exact location, evidence quoted from RESEARCH.md or SPEC.txt, and the fix:
(a) API CORRECTNESS: every API in ARCHITECTURE.md, MODULES.md and Core/*.swift against RESEARCH.md: unverified, disputed, macOS-only, wrong signature or availability, Swift that will not compile (type errors, missing imports, Codable on simd types without wrappers, unsatisfiable protocol requirements, name collisions with Apple types such as RoomPlan's CapturedRoom.Object or RealityKit types).
(b) SPEC COVERAGE: walk SPEC.txt section by section; every requirement needs a concrete owner module and build number in MODULES.md; flag anything missing, hand-waved, or silently deferred.
(c) RUNTIME REALITY: threading (ARSession delegate queues vs MainActor), memory budgets on 6 GB, session lifecycles (RoomPlan plus ARKit coexistence, Object Capture handoff), storage sizes, thermal, data safety (raw never destroyed, edits as overlays), and whether build 3 really gives a usable app.
Save all findings to docs/design/review.md.

STEP 2, FIX. Fix every blocker and major and the cheap minors in ARCHITECTURE.md, MODULES.md and Core/*.swift. Record rejected findings with reasons at the end of docs/design/review.md.

STEP 3, COMPILE. Trigger "ios-build.yml" on your branch (workflow_dispatch, ref = your branch) with the GitHub tools, read the "Compiler errors" step of failed runs, fix, repeat until green (budget 8 builds).

Git rules (public repo): branch design/review from origin/main. Commit message first line "design: adversarial review fixes". Do NOT add any session-link trailer or claude.ai URL to commit messages; no personal names, emails or device identifiers. Push with git push -u origin design/review. Never push to main.

Final message: branch, green build run id, counts of findings by severity, what was fixed, what was rejected and why, and whether the design is ready for parallel implementation.
