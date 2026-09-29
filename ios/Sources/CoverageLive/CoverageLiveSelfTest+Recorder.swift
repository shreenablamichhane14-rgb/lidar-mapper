import Foundation
import simd

// Recorder checks of CoverageLiveSelfTest (docs/MODULES.md 3.31 items 14 to 20 and 23): a real
// MeshStore recording into a temporary folder, fed through `ingest(_:)`, and a recorder fed
// through `ingest(observation:)` and `waitForWork()`. Observation times are fixed, so every
// rate-limited step (anchor refresh 1 s, evaluation 1 s, shell fallback 8 s) is deterministic.

extension CoverageLiveSelfTest {
    // MARK: 14 to 18: one anchor seen from the front

    /// Yellow then green states, view coverage, watched sets, revisions, hooks and finishing.
    static func recorderChecks(_ t: Checks, base: URL) throws {
        let folder = RawScanFolder(url: base.appendingPathComponent("room", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let mesh = MeshStore()
        let recorder = CoverageLiveRecorder(meshSource: mesh)
        mesh.beginRecording(into: folder, profile: profile, startTimestamp: 100)
        recorder.beginRecording(into: folder, profile: profile, startTimestamp: 100)
        defer { _ = finish(mesh) }

        let centroids = [SIMD3<Float>(2.0 / 3.0, 1.0 / 3.0, 0), SIMD3<Float>(1.0 / 3.0, 2.0 / 3.0, 0)]
        let unseen = SIMD3<Float>(3, 0.05, 3)
        recorder.setWatchedAreas([1: centroids, 2: [unseen]])
        let before = recorder.watchedFractions()
        t.check("watched.zeroBefore", before[1] == 0 && before[2] == 0, "\(before)")

        mesh.ingest(square(anchor: 1, degenerate: true))
        let eye = SIMD3<Float>(0.5, 0.5, 1.5)
        let front = SIMD3<Float>(0, 0, -1)
        t.check("ingest.queued", recorder.ingest(observation: observation(at: eye, looking: front, time: 101)))
        recorder.waitForWork()
        let once = recorder.anchorFaces(changedSince: 0).anchors.first?.states ?? []
        t.check("states.oneObservationYellow", once.count == 3 && once[0] == .yellow && once[1] == .yellow, "\(once)")
        t.check("states.degenerateGray", once.count == 3 && once[2] == .gray, "\(once)")
        t.check("watched.oneAfter", recorder.watchedFractions()[1] == 1, "\(recorder.watchedFractions())")

        for time in [101.4, 101.8] {
            recorder.ingest(observation: observation(at: eye, looking: front, time: time))
            recorder.waitForWork()
        }
        let first = recorder.anchorFaces(changedSince: 0)
        let states = first.anchors.first?.states ?? []
        let bothGreen = states.count == 3 && states[0] == .green && states[1] == .green
        t.check("states.threeObservationsGreen", first.anchors.count == 1 && bothGreen, "\(states)")
        t.check("viewCoverage.one", recorder.summary().viewCoverage == 1, "\(String(describing: recorder.summary().viewCoverage))")
        t.check("watched.unobservedIsRed", recorder.voxelState(at: unseen) == .red && recorder.watchedFractions()[2] == 0)
        let counted = recorder.summary()
        let countsMatch = counted.integrations == 3 && counted.trackedFaces == 3 && counted.anchors == 1
        t.check("summary.counts", countsMatch, "\(counted)")

        let again = recorder.anchorFaces(changedSince: first.revision)
        t.check("anchorFaces.unchangedEmpty", again.anchors.isEmpty && again.revision == first.revision)
        var input = GuidanceInput(time: 0)
        let guidance = recorder.guidanceHook
        guidance(&input)
        t.check("guidanceHook.viewCoverage", input.viewCoverage == 1 && input.nearbyMissing.isEmpty)
        var snapshot = LiveScanSnapshot()
        let snap = recorder.snapshotHook
        snap(&snapshot)
        t.check("snapshotHook.minimap", snapshot.minimap?.camera == Vec2(x: 0.5, y: -1.5),
                "\(String(describing: snapshot.minimap?.camera))")
        t.check("lastCamera", recorder.lastCameraTransform().map { Transform4($0) } == Transform4(camera(at: eye, looking: front)))

        mesh.ingest(square(anchor: 1, degenerate: true))
        recorder.ingest(observation: observation(at: eye, looking: front, time: 103))
        recorder.waitForWork()
        let third = recorder.anchorFaces(changedSince: first.revision)
        let newVersion = third.anchors.count == 1 && third.anchors.first?.updateCount == 2
        t.check("anchorFaces.newVersion", newVersion && third.revision > first.revision, "\(third.anchors.count) anchors")

        recorder.ingest(observation: observation(at: eye, looking: SIMD3<Float>(0, 0, 1), time: 103.4))
        recorder.waitForWork()
        t.check("viewCoverage.nilLookingAway", recorder.summary().viewCoverage == nil)

        t.check("finish.completes", finish(recorder))
        let integrations = recorder.summary().integrations
        let queued = recorder.ingest(observation: observation(at: eye, looking: front, time: 104))
        recorder.waitForWork()
        t.check("finish.ignoresObservations", !queued && recorder.summary().integrations == integrations)
        t.check("finish.dropsAnchors", recorder.anchorFaces(changedSince: 0).anchors.isEmpty && recorder.workAnchorCount() == 0)
        t.check("finish.keepsSummary", recorder.summary().anchors == 1 && recorder.stats == RecorderStats())
    }

    // MARK: 19 and 20: shell fallback and completeness

    /// Without mesh, the expected shell stands in after 8 s; eight views from the room center
    /// then cover it completely.
    static func shellChecks(_ t: Checks, base: URL) throws {
        let folder = RawScanFolder(url: base.appendingPathComponent("shell", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let mesh = MeshStore()
        let recorder = CoverageLiveRecorder(meshSource: mesh)
        mesh.beginRecording(into: folder, profile: profile, startTimestamp: 200)
        recorder.beginRecording(into: folder, profile: profile, startTimestamp: 200)
        defer {
            _ = finish(recorder)
            _ = finish(mesh)
        }
        guard let boundary = CoverageLiveBoundary.boundary(from: room()) else {
            t.check("shell.boundary", false)
            return
        }
        recorder.setExpectedBoundary(boundary, exclusions: [])
        let center = SIMD3<Float>(0, 1.4, 0)
        recorder.ingest(observation: observation(at: center, looking: SIMD3<Float>(1, 0, 0), time: 201, focal: 600))
        recorder.waitForWork()
        t.check("shell.notBefore8s", recorder.lastIntegratedFaceCount() == 0 && !recorder.summary().usesShellFallback)

        var views: [SIMD3<Float>] = []
        for i in 0..<6 {
            let angle = Float(i) * .pi / 3
            views.append(SIMD3<Float>(cos(angle), 0, sin(angle)))
        }
        views.append(SIMD3<Float>(0, -1, 0))
        views.append(SIMD3<Float>(0, 1, 0))
        let expectedCount = ExpectedSurfaces.samples(for: boundary).count
        for (i, view) in views.enumerated() {
            let time = 209.5 + 1.1 * Double(i)
            recorder.ingest(observation: observation(at: center, looking: view, time: time, focal: 600))
            recorder.waitForWork()
            if i == 0 {
                let integrated = recorder.lastIntegratedFaceCount()
                t.check("shell.facesAreSamples", integrated == expectedCount && integrated > 0, "\(integrated) of \(expectedCount)")
                t.check("shell.summary", recorder.summary().usesShellFallback && recorder.summary().hasExpectedRoom)
            }
        }
        let summary = recorder.summary()
        let missing = recorder.currentMissingAreas()
        t.check("complete.fraction", summary.coverageFraction >= 0.9, "\(summary.coverageFraction)")
        t.check("complete.noMissing", missing.isEmpty && summary.missingCount == 0, "\(missing.count) missing")
        t.check("complete.rule", CoverageLiveMissing.isComplete(observedFraction: summary.coverageFraction,
                                                                missingCount: missing.count))
        var snapshot = LiveScanSnapshot()
        recorder.augment(&snapshot)
        let covered = snapshot.minimap?.cells.contains(MinimapCell.covered.rawValue) ?? false
        t.check("complete.snapshot", snapshot.coverageFraction == summary.coverageFraction && covered)
        var input = GuidanceInput(time: 0)
        input.overallComplete = true
        recorder.augment(&input)
        t.check("boundaryMode.leavesGuidanceCompleteness", input.overallComplete && input.nearbyMissing.isEmpty)
    }

    // MARK: 23: seed

    /// A 0 s deadline integrates nothing, 1 s all three; a seed given before recording waits for it.
    static func seedChecks(_ t: Checks, base: URL) {
        let folder = RawScanFolder(url: base.appendingPathComponent("seed", isDirectory: true))
        let faces = CoverageLiveFaces.faces(of: square(anchor: 7))
        let eye = SIMD3<Float>(0.5, 0.5, 1.5)
        let front = SIMD3<Float>(0, 0, -1)
        let seeds = [300.0, 300.4, 300.8].map { observation(at: eye, looking: front, time: $0) }

        let recorder = CoverageLiveRecorder(meshSource: MeshStore())
        recorder.beginRecording(into: folder, profile: profile, startTimestamp: 300)
        recorder.seed(observations: seeds, faces: faces, deadlineSeconds: 0)
        recorder.waitForWork()
        t.check("seed.zeroDeadline", recorder.seededObservationCount() == 0, "\(recorder.seededObservationCount())")
        recorder.seed(observations: seeds, faces: faces, deadlineSeconds: 1)
        recorder.waitForWork()
        t.check("seed.oneSecond", recorder.seededObservationCount() == 3, "\(recorder.seededObservationCount())")
        t.check("seed.green", recorder.voxelState(at: faces[0].centroid) == .green)
        t.check("seed.finish", finish(recorder))

        let staged = CoverageLiveRecorder(meshSource: MeshStore())
        staged.setWatchedAreas([5: [faces[0].centroid]])
        staged.seed(observations: seeds, faces: faces, deadlineSeconds: 1)
        staged.beginRecording(into: folder, profile: profile, startTimestamp: 300)
        staged.waitForWork()
        let fractions = staged.watchedFractions()
        t.check("seed.stagedBeforeRecording", staged.seededObservationCount() == 3 && fractions[5] == 1, "\(fractions)")
        t.check("seed.stagedFinish", finish(staged))
    }
}
