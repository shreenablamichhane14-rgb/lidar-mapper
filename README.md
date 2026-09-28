# Mapper

Local-first iPhone LiDAR 3D mapping app: rooms, buildings, and objects scanned with the
iPhone's LiDAR + camera into textured models, clean architectural models, 2D floor plans,
and measurements. No account, no cloud, no subscription.

Product spec: `docs/SPEC.txt` (the original brief). Verified platform research: `docs/RESEARCH.md`.
Architecture: `docs/ARCHITECTURE.md`.

Build: GitHub Actions (`.github/workflows/ios-build.yml`) generates the Xcode project with
XcodeGen and builds an unsigned IPA; install with Sideloadly over USB.
