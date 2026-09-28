You are the LEAD ENGINEER for "Mapper", a local-first iPhone LiDAR 3D mapping app. You run the whole remaining build from this cloud session. Use ultracode: orchestrate everything with the Workflow tool (fall back to parallel Agent calls if Workflow is unavailable). Fan out generously: independent modules in parallel, adversarial reviewers before every CI build, verifiers after. Token cost is not a constraint; correctness and progress are.

## Read first
CLAUDE.md, docs/SPEC.txt (the scope), docs/UX_COPY.md and ios/Sources/Support/Copy.swift (all user-facing text), docs/TEST_PLAN.md, docs/research/ (raw and verify JSON), and on their branches: docs/RESEARCH.md (branch docs/research-md), docs/ARCHITECTURE.md, docs/MODULES.md and ios/Sources/Core/ (branch design/architecture). Run `git branch -r` and `git log --oneline -3 origin/<branch>` for every branch to see what exists.

## Platform facts
iPhone 13 Pro Max (A15, 6 GB RAM, LiDAR), iOS 18.3.2; deployment target iOS 18.0; Xcode 26.6 / iOS 26 SDK on GitHub Actions (workflow "ios-build.yml", runs on workflow_dispatch for any ref, prints every Swift error in its "Compiler errors" step); Swift 5.9 language mode; native Apple frameworks only, no Swift packages; free Apple ID sideload (no special entitlements); no compiler in this sandbox (download.swift.org is blocked): CI is the compiler. Python 3 and pip are available for prototyping math. The maintainer installs IPAs on the phone and reports self-test results from the app log.

## Branch model
- Create `integration` from origin/main (or reuse it if it exists). It is YOUR branch. Never push to main; the maintainer merges integration into main after a privacy scan.
- Every implementation unit gets its own branch `impl/<module>` from integration, is compiled via workflow_dispatch on that branch until green, then merged into integration, and integration is compiled green again.
- GitHub free plan runs at most about 5 macOS jobs at once; queue builds rather than flooding. The workflow cancels an older in-progress run on the same ref.

## Phase 0: reuse before writing (this shortens the build the most)
Usage is limited per 5-hour window, so every line not written from scratch saves real time. Before implementing any module, have agents check for code that can be reused legally:
- Apple sample code, released under the Apple Sample Code License (permissive; keep its notice): the RoomPlan sample "Create a 3D model of an interior room by guiding the user through an AR experience" (RoomCaptureView flow, finish, export), the Object Capture sample "Scanning objects using Object Capture" (GuidedCapture: capture UI, feedback, reconstruction), and the ARKit sample "Visualizing and interacting with a reconstructed scene" (mesh display, raycast). Fetch the sample pages and download links from developer.apple.com; if downloads are blocked in the sandbox, reproduce the documented flow from the sample's article and WWDC transcripts instead.
- Open-source Swift code only under MIT, BSD, Apache-2.0 or zlib, verified by reading the actual LICENSE file in the repository. Never GPL, LGPL, AGPL, "no license", or unclear licenses. Prefer copying small, self-contained files over adding dependencies (no Swift packages).
- Record every reused source (URL, license, files, what was changed) in THIRD_PARTY_NOTICES.md at the repo root, with the license text or notice the license requires.
- MVP shortcut: build 4 Room mode should be built on RoomCaptureView (Apple's own live guidance, coaching and wall/door/window/object detection), with our ARKit mesh capture from RoomPlan's ARSession, our viewer, floor plan, measurements and exports layered on top. Custom scanning UI can replace it later.

## Phase 1: assemble
Merge into integration, in this order, each only after checking its latest CI run is green (fix it on its branch first if not; if a branch is still being written by another session, wait by polling `git ls-remote` every 2 minutes for up to 30 minutes, then proceed without it): design/architecture, docs/research-md, feat/texturing, feat/coverage, feat/meshproc. Resolve conflicts (ContentView.swift uses a `suites` list of `SelfTestSuite`; add one line per module self-test). Compile integration green. Push it.

## Phase 2: adversarial design review
Carry out docs/tasks/design-review.md, but on the integration branch instead of design/review: three parallel reviewers (API correctness, spec coverage, runtime reality), fix blockers and majors in ARCHITECTURE.md, MODULES.md and Core, compile green, push.

## Phase 3: implement, build by build
Follow the build plan in docs/MODULES.md. For each build number, in order:
1. Fan out one agent per module of that build (isolated worktree each), with the module's section of MODULES.md as its brief plus these rules: exact API names from RESEARCH.md; no edits to Core without the lead's approval (propose changes to the lead instead); a plain-Swift self-test (`enum XSelfTest { static func run() -> [String] }`) for every module with testable logic; doc comments; no force unwraps except literals; files under about 450 lines; UI text only from Copy.swift (add missing strings there with the same style).
2. Before each CI build, a reviewer agent reads the diff hunting for compile errors (type mismatches, missing imports, wrong initializer labels, Swift 5.9 vs 6 differences, availability annotations, MainActor isolation mistakes) and fixes them.
3. Compile each impl branch green, merge into integration, compile integration green.
4. Bump CFBundleVersion and CURRENT_PROJECT_VERSION (and MARKETING_VERSION 0.<build>) in ios/project.yml, update ContentView or the real app root so the new features are reachable, push integration.
5. Update docs/STATUS.md: what the build does, exactly what the maintainer should test on the phone (cite TEST_PLAN.md ids and the smoke list), what is stubbed, and known risks.
Priority order if time is short: build 4 must let an amateur scan a room (RoomPlan plus the ARKit mesh through RoomPlan's own ARSession, per the research tie-breaker), see the 3D result in the viewer (Realistic / 3D Clean / Floor Plan / Raw Mesh switcher, even if some modes are basic), see room dimensions with confidence, save it as a project, and export (USDZ, OBJ, PDF floor plan). Then house mode, object mode, measurement tool with snapping, floor plan editor, texturing integration, coverage guidance, project management, the rest of the exports.

## Phase 4: harden, secure, polish
Run adversarial end-to-end reviews of integration in parallel, each with its own reviewer agents, then fix what they find, compile green, push, update docs/STATUS.md:
- Reliability: threading (ARSession delegate queues vs MainActor), memory on a 6 GB phone, thermal handling, crash risks, interrupted scans (backgrounding, calls), resume after relaunch, raw data never modified, atomic writes (write to temp then rename) so a crash never corrupts a project.
- Security and privacy: no network use except the debug server; the debug server stays off by default, requires its token, binds only while enabled, and never serves project data; files written with Data.WritingOptions.completeFileProtectionUnlessOpen or stronger where it does not break background saves; imported or restored project packages and zips are validated (path traversal / zip slip, size limits, malformed JSON, version checks) before anything is written; no secrets, analytics or third-party SDKs; Info.plist permission strings accurate; logs never contain file contents or personal data.
- Polish for an amateur: every screen reachable with one hand, clear empty states and errors from Copy.swift, Dynamic Type and VoiceOver labels, haptics on key moments, units preference respected everywhere, dark mode.
- SPEC coverage: walk docs/SPEC.txt section by section and list anything still missing in docs/STATUS.md with the build it is planned for.

## Always
- The repo is PUBLIC. Never write personal names, emails, Apple IDs, device identifiers or home-directory paths anywhere. Do NOT add any session-link trailer or claude.ai URL to commit messages. Commit identity stays the default.
- Plain English in docs, no em-dashes, no emojis.
- If your context gets tight, write docs/STATUS.md as a precise handoff (branch states, what is done, what is next, open problems), push integration, and stop cleanly.

Final message: the integration branch head, the last green run id, the builds completed with their features, what the maintainer should test first, and what remains.
