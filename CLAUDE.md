# Mapper (lidar-mapper)

## Overview
Local-first iPhone LiDAR 3D mapping app: scan a room, a whole house (room by room), or an object, and get a textured realistic model, the raw LiDAR mesh, a clean architectural model, a 2D floor plan, measurements and professional exports. No account, no cloud, no subscription. Full brief: `docs/SPEC.txt` (source of truth for scope).

This repository is PUBLIC. Never commit personal data: no names of people, emails, Apple IDs, device identifiers (UDID, serials), home paths, tokens or keys. Machine- and person-specific notes live in `CLAUDE.local.md`, which is gitignored and exists only on the maintainer's PC. `tools/privacy_check.py` runs as a git pre-push hook there and blocks pushes that contain personal data.

## Current State (2026-09-28)
- CI: `.github/workflows/ios-build.yml` builds an unsigned IPA on macos-latest (Xcode 26.6, iOS 26 SDK) with XcodeGen; artifacts `Mapper-ipa` and `build-log`. Triggers: push to `main` touching `ios/`, or `workflow_dispatch` on any branch (feature branches use this). One in-progress build per ref. On failure the "Compiler errors" step prints every Swift error as `file:line:col: message`.
- Build 1 = skeleton: capability probe screen (ARKit mesh, scene depth, RoomPlan, Object Capture, photogrammetry support), LogStore, DebugServer (port 8765), haptics/device state, app icon. Deployment target iOS 18.0, Swift 5.9 language mode. Proves ARKit + RoomPlan + RealityKit Object Capture link on Xcode 26.6 (build time about 45 s).
- Merged from cloud sessions: `docs/TEST_PLAN.md` (on-device acceptance tests), `docs/UX_COPY.md` + `ios/Sources/Support/Copy.swift` (all user-facing text), `ios/Sources/Units/` (feet-inches and metric formatting, parsing, 40+ case self-test run at launch).
- Test device: iPhone 13 Pro Max (A15, 6 GB, LiDAR) on iOS 18.3.2. A second device on iOS 26 later.
- Research pass (multi-agent, adversarially verified) in progress; output goes to `docs/RESEARCH.md`. Architecture follows in `docs/ARCHITECTURE.md` and `docs/MODULES.md`.

## Architecture / Key Files
| Path | Purpose |
|---|---|
| `docs/SPEC.txt` | Product brief (source of truth for scope) |
| `docs/RESEARCH.md` | Verified Apple API facts, gotchas, risks (generated) |
| `docs/TEST_PLAN.md` | On-device acceptance tests, measurement accuracy protocol, smoke list |
| `docs/UX_COPY.md` | Every on-screen string with guidance message priorities and display rules |
| `ios/project.yml` | XcodeGen spec: bundle `com.shreehub.mapper`, iOS 18.0, camera permission, file sharing on |
| `ios/Sources/MapperApp.swift` | Entry point, starts log + optional debug server |
| `ios/Sources/ContentView.swift` | Build 1 capability probe (to be replaced by the real home screen) |
| `ios/Sources/Support/` | LogStore (Documents/Logs/mapper-YYYY-MM-DD.log, 7 days), DebugServer (Wi-Fi log viewer, token), DeviceFeatures (haptics, thermal), SettingsKey, Copy (UI strings) |
| `ios/Sources/Units/` | UnitSystem/UnitPreferences, LengthFormat/AreaFormat/VolumeFormat/AngleFormat/Tolerance, LengthParser, UnitsSelfTest |
| `tools/ci.py` | Watch the GitHub Actions run for HEAD, print compiler errors as file:line, download the IPA to ~/Desktop/Mapper.ipa |
| `tools/phone_log.py` | Pull/follow the app log: `usb`, `wifi <ip> <token>`, `syslog` |
| `tools/sideload.py` | Drive Sideloadly (Windows) to install ~/Desktop/Mapper.ipa over USB; stops at the Apple ID password/2FA prompt for the human; Apple ID comes from `SIDELOAD_APPLE_ID` in the environment or ~/.env; `--dry-run` prints the plan |
| `tools/privacy_check.py` | Scans files and commit metadata for personal data using patterns from a local, gitignored file; used as a pre-push hook |

## Build and install loop
1. Edit under `ios/`, commit, push. Feature branches: `gh workflow run ios-build --ref <branch>`.
2. `python tools/ci.py` waits for the run, prints errors or downloads `Mapper.ipa`.
3. `python tools/sideload.py` installs it over USB (free Apple ID signature lasts 7 days; re-sideload weekly).
4. Logs: `python tools/phone_log.py usb`.

## Rules for contributors and agents
- Swift 5.9 language mode, iOS 18.0 deployment target, native Apple frameworks only, no Swift packages.
- There is no Swift compiler on the maintainer's PC; every compile is a CI round trip. Use exact API names from `docs/RESEARCH.md`.
- All user-facing text comes from `Copy.swift`; all length/area/volume text from `ios/Sources/Units/`.
- Commit author identity: a GitHub noreply address or `Claude <noreply@anthropic.com>`. Do not add session links or personal details to commit messages.
- Writing style for docs: plain English, no em-dashes, no emojis.

## Recent Changes
- 2026-09-28: Repository made public with a fresh, sanitized history (the earlier private history is archived privately). Tools read personal settings from the environment. Privacy pre-push guard added.
- 2026-09-28: `tools/sideload.py` added. Quirk: `sideloadlydaemon.exe` keeps logging into the cwd it was first started from, so the script tails every known log location and treats the phone's app list (Path/SequenceNumber change) as the success signal.
- 2026-09-28: Project created from the brief. CI, skeleton, tools, icon. Research workflow launched. First cloud sessions: test plan, UX copy, units module.

## Known Issues / Next Steps
1. Finish research, then architecture design (3 proposals, judges, synthesis, adversarial review), then parallel module implementation by cloud sessions, each compiling via `workflow_dispatch` on its own branch.
2. No compiler locally or in cloud sandboxes (download.swift.org is blocked there); CI is the compiler.

## Credentials / Config
No API keys needed (fully local app). `SIDELOAD_APPLE_ID` for the sideload tool lives in ~/.env on the maintainer's PC, never in the repo.
