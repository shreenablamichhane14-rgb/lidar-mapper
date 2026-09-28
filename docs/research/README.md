# Research data

`raw/<topic>.json` holds the first research pass (2026-09-28): ten researchers, one per subsystem, each returning structured facts with exact Swift declarations, availability, sources and a confidence level, plus gotchas, recommendations and open questions. `verdicts` are independent checks by skeptical reviewers through two lenses (official Apple documentation JSON, and real-world evidence). `unverified_critical_claims` lists architecture-critical facts that were not checked in the first pass.

`verify/<topic>.json` holds the second pass on those unverified claims.

`../RESEARCH.md` is the synthesized reference the architecture and all implementation work rely on.

Topics: arkit-mesh-depth, roomplan, object-capture, export-formats, texturing, rendering-viewer, floorplan-cad, quality-coverage-measure, storage-deploy, ui-ux-patterns.
