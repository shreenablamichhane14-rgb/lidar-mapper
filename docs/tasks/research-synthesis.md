You are the lead iOS engineer for "Mapper", a local-first iPhone LiDAR 3D mapping app. Read CLAUDE.md and docs/SPEC.txt first.

INPUT: docs/research/raw/*.json (first research pass: facts with exact Swift declarations, availability, sources, confidence; gotchas; recommendations; open questions; verifier verdicts) and docs/research/verify/*.json (second pass: verdicts on the remaining critical claims, tie-breaker rulings on disputed claims, answers to open questions). Read every file completely.

Hard platform facts: test device iPhone 13 Pro Max (A15, 6 GB RAM, LiDAR) on iOS 18.3.2; deployment target iOS 18.0; built on GitHub Actions with Xcode 26.6 (iOS 26 SDK); free Apple ID sideloading (no paid entitlements); native Apple frameworks only; no Mac for the developer (every compile is a CI round trip, so exact API facts matter most).

TASK: write docs/RESEARCH.md, the single verified reference that the architecture and every implementation agent will rely on. Rules: plain English, no em-dashes, no emojis, short sentences. Length is fine (1500 to 3000 lines). Every API you list must come from the input files or from a page you fetch yourself now to double-check (WebFetch Apple's documentation JSON: https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json). Never invent declarations. When a researcher and a verifier disagree, state which side has the stronger evidence and why, and use the tie-breaker ruling when one exists.

Structure:
1. Executive summary (15 to 25 bullets): the decisions this research forces (which frameworks for which scan mode, how ARKit and RoomPlan coexist, what texturing approach is feasible on device, what rendering stack, what export formats are native vs hand-written, what is impossible or deferred, the deployment target).
2. One section per subsystem: ARKit mesh and depth; RoomPlan; Object Capture; texturing pipeline; rendering and viewer; floor plan and CAD output; 3D export formats; scan quality, coverage and measurement confidence; storage, deployment and concurrency; UX patterns. In each: a verified API table or code block with EXACT Swift declarations and availability; gotchas; the recommended approach; a "disputed or unsure" list with the ruling.
3. Risk register: the top 12 risks to the build with likelihood, impact and mitigation.
4. A "do not do" list: APIs that are macOS-only, deprecated, unavailable on iOS 18, unavailable to free Apple IDs, or refuted.
5. Answers to the open questions that matter for the architecture.
6. Sources: every URL used, grouped by subsystem.

Before committing, scan your file for personal names, emails, device identifiers and home-directory paths and remove them (the repo is public).

Git rules: create branch docs/research-md from origin/main, commit only docs/RESEARCH.md with message "docs: RESEARCH.md synthesized from verified research". Do NOT add any session-link trailer or claude.ai URL to commit messages. Push with git push -u origin docs/research-md. Never push to main.

Final message: branch, line count, the executive summary bullets, and anything still unresolved.
