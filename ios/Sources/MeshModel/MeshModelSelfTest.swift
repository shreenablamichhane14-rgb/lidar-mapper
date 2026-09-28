import Foundation
import simd

/// Plain-Swift checks for the MeshModel module (no XCTest), run from Settings > Diagnostics.
/// `run()` returns one line per failing check ("name: detail"); empty means all passed. No
/// ARKit, camera or network; files only under `FileManager.default.temporaryDirectory`,
/// removed afterwards; fixed ids and no clock, so the result is deterministic. The largest
/// scene is a 20,000 triangle sphere, so a run stays well under 2 s on an A15. More cases live
/// in `MeshModelSelfTest+Files.swift`, the scenes in `MeshModelSelfTestFixtures.swift`.
enum MeshModelSelfTest {
    /// Fewer checks than this means a section stopped early without reporting.
    private static let minimumChecks = 60

    /// Collects failing checks and counts every check.
    final class Recorder {
        /// Failure lines, "name: detail".
        var failures: [String] = []
        /// Number of checks run so far.
        var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        /// Records a failure when `actual` is farther than `tolerance` from `expected`.
        func near(_ name: String, _ actual: Float, _ expected: Float, _ tolerance: Float) {
            count += 1
            if !(abs(actual - expected) <= tolerance) {
                failures.append("\(name): expected \(expected), got \(actual)")
            }
        }

        /// Records a thrown error as a failure of check `name`.
        func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): threw \(error)")
        }
    }

    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        let r = Recorder()
        selectionCases(r)
        cubeCases(r)
        holeCases(r)
        floaterCases(r)
        budgetCases(r)
        cropCases(r)
        fastMeshCases(r)
        storeCases(r)
        paletteCases(r)
        exportCases(r)
        stepCases(r)
        if r.failures.isEmpty && r.count < minimumChecks {
            r.failures.append("selfTest: only \(r.count) checks ran")
        }
        return r.failures
    }

    /// One log line: "mesh model self-test: all passed" or the failures joined.
    static func summary() -> String {
        let failures = run()
        if failures.isEmpty { return "mesh model self-test: all passed" }
        return "mesh model self-test: \(failures.count) failed: " + failures.joined(separator: "; ")
    }

    /// Consolidates with default options and never cancels.
    static func consolidated(_ chunks: [MeshChunk], _ options: ConsolidationOptions = ConsolidationOptions()) -> ConsolidationResult? {
        MeshConsolidator.consolidate(chunks, options: options, isCancelled: { false })
    }

    // MARK: - Chunk selection

    /// `latestChunks`: the later folder wins, the highest update count wins within a folder,
    /// corrupt files and missing folders are skipped.
    static func selectionCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("MeshModelSelfTest-select")
            defer { try? FileManager.default.removeItem(at: base) }
            let folderA = RawScanFolder(url: base.appendingPathComponent("a", isDirectory: true))
            let folderB = RawScanFolder(url: base.appendingPathComponent("b", isDirectory: true))
            let anchorX = fixedID(10)
            let anchorY = fixedID(11)
            let halves = cubeHalves()
            func version(_ source: MeshChunk, id: UUID, update: UInt32) -> MeshChunk {
                var copy = source
                copy.anchorID = id
                copy.updateCount = update
                return copy
            }
            try writeChunk(version(halves[0], id: anchorX, update: 3), into: folderA, fileName: anchorX.uuidString + ".mchk")
            try writeChunk(version(halves[1], id: anchorX, update: 5), into: folderA, fileName: "zz-older-copy.mchk")
            try writeChunk(version(halves[1], id: anchorY, update: 2), into: folderA, fileName: anchorY.uuidString + ".mchk")
            try Data([1, 2, 3, 4, 5]).write(to: folderA.meshURL.appendingPathComponent("broken.mchk"))
            try writeChunk(version(halves[0], id: anchorX, update: 1), into: folderB, fileName: anchorX.uuidString + ".mchk")

            let inA = MeshConsolidator.latestChunks(in: [folderA])
            r.check("select.folderCount", inA.count == 2, "\(inA.count) chunks, corrupt file not skipped?")
            let xInA = inA.first { $0.anchorID == anchorX }
            r.check("select.highestUpdate", xInA?.updateCount == 5, "update \(String(describing: xInA?.updateCount))")

            let both = MeshConsolidator.latestChunks(in: [folderA, folderB])
            r.check("select.count", both.count == 2, "\(both.count) chunks")
            let xBoth = both.first { $0.anchorID == anchorX }
            r.check("select.laterFolderWins", xBoth?.updateCount == 1, "update \(String(describing: xBoth?.updateCount))")
            r.check("select.keepsOtherAnchor", both.contains { $0.anchorID == anchorY && $0.updateCount == 2 })
            r.check("select.order", both.first?.anchorID == anchorX, "first appearance order not kept")

            let missing = RawScanFolder(url: base.appendingPathComponent("missing", isDirectory: true))
            r.check("select.missingFolder", MeshConsolidator.latestChunks(in: [missing]).isEmpty)
        } catch {
            r.fail("select.files", error)
        }
    }

    // MARK: - Cube

    /// Two overlapping anchor-local cube halves consolidate into one watertight unit cube;
    /// classes survive; cancellation returns nil.
    static func cubeCases(_ r: Recorder) {
        guard let result = consolidated(cubeHalves()) else {
            return r.check("cube.result", false, "nil without cancellation")
        }
        let measured = result.measured
        r.check("cube.faces", measured.triangleCount == 12, "\(measured.triangleCount) faces")
        r.check("cube.watertight", measured.mesh.isWatertight)
        r.near("cube.volume", measured.mesh.signedVolume, 1, 1e-3)
        r.check("cube.classes", result.stats.classTriangleCounts == ["1": 8, "2": 4],
                "\(result.stats.classTriangleCounts)")
        r.check("cube.classArray", measured.faceClass?.count == 12)
        r.check("cube.noInferred", result.inferred.triangleCount == 0 && measured.isInferred == nil)
        r.check("cube.noFloaters", result.floaters.triangleCount == 0)
        r.check("cube.viewEqualsMeasured", result.view.triangleCount == 12)
        r.check("cube.chunkCount", result.stats.chunkCount == 2)
        let lower: SIMD3<Float> = result.stats.boundsMin.simd
        let upper: SIMD3<Float> = result.stats.boundsMax.simd
        let expectedUpper: SIMD3<Float> = cubeOffset + SIMD3<Float>(repeating: 1)
        let lowerError: Float = simd_distance(lower, cubeOffset)
        let upperError: Float = simd_distance(upper, expectedUpper)
        r.check("cube.bounds", lowerError < 1e-4 && upperError < 1e-4, "\(lower) \(upper)")

        r.check("cube.cancelled", MeshConsolidator.consolidate(cubeHalves(), options: ConsolidationOptions(),
                                                               isCancelled: { true }) == nil)
        var calls = 0
        let late = MeshConsolidator.consolidate(cubeHalves(), options: ConsolidationOptions(), isCancelled: {
            calls += 1
            return calls > 3
        })
        r.check("cube.cancelledLater", late == nil, "a cancel after the merge stage was ignored")
    }

    // MARK: - Holes and floaters

    /// A 10 cm hole is filled and appears only in `inferred`; `view` has no inferred face.
    static func holeCases(_ r: Recorder) {
        guard let result = consolidated([holeChunk()]) else {
            return r.check("hole.result", false, "nil without cancellation")
        }
        let inferred = result.inferred
        r.check("hole.filled", inferred.triangleCount > 0, "no inferred faces")
        r.near("hole.inferredArea", inferred.mesh.surfaceArea, 0.01, 1e-4)
        let flags = inferred.isInferred ?? []
        r.check("hole.inferredFlags", flags.count == inferred.triangleCount && !flags.contains(false))
        r.check("hole.inferredClass", inferred.faceClass?.allSatisfy { $0 == 1 } == true, "fill lost the wall class")
        r.check("hole.measuredFaces", result.measured.triangleCount == 792, "\(result.measured.triangleCount) faces")
        r.check("hole.measuredOpen", !hasFaceInHole(result.measured), "measured mesh has a face in the hole")
        let viewClean = result.view.isInferred == nil && !hasFaceInHole(result.view)
        r.check("hole.viewNoInferred", viewClean && result.view.triangleCount == 792)
        let stats = result.stats
        let statsMatch = stats.inferredTriangleCount == inferred.triangleCount && stats.triangleCount == 792
        r.check("hole.stats", statsMatch && stats.viewTriangleCount == 792, "\(stats)")
        var noFill = ConsolidationOptions()
        noFill.holeMaxPerimeter = 0.3
        r.check("hole.largeHoleOpen", consolidated([holeChunk()], noFill)?.inferred.triangleCount == 0,
                "a 0.4 m hole was filled with a 0.3 m limit")
    }

    /// A 30-triangle floater is removed from `measured` and kept in `floaters`, by the same
    /// rule as `MeshCleanup.removingFloaters`.
    static func floaterCases(_ r: Recorder) {
        let chunks = floaterChunks()
        guard let result = consolidated(chunks) else {
            return r.check("floater.result", false, "nil without cancellation")
        }
        r.check("floater.measured", result.measured.triangleCount == 200, "\(result.measured.triangleCount) faces")
        r.check("floater.kept", result.floaters.triangleCount == 30, "\(result.floaters.triangleCount) faces")
        r.check("floater.position", result.floaters.mesh.positions.allSatisfy { $0.x > 2.5 },
                "floaters contain the main patch")
        r.check("floater.classes", result.floaters.faceClass?.allSatisfy { $0 == 4 } == true)
        let merged = ChunkMerge.merge(MeshConsolidator.mergeChunks(chunks))
        let options = ConsolidationOptions()
        let reference = MeshCleanup.removingFloaters(merged, minimumArea: options.minIslandArea,
                                                     minimumTriangles: options.minIslandTriangles)
        r.check("floater.ruleParity", reference.triangleCount == result.measured.triangleCount,
                "MeshCleanup keeps \(reference.triangleCount)")
        r.check("floater.stats", result.stats.classTriangleCounts == ["2": 200], "\(result.stats.classTriangleCounts)")
    }

    // MARK: - Budgets

    /// View budget respected on a 20k triangle sphere with budget 5k; the measured mesh is
    /// never simplified; the reduced variant halves chunks before merging.
    static func budgetCases(_ r: Recorder) {
        let sphere = sphereChunk()
        r.check("budget.sphereInput", sphere.faceCount == 20_000, "\(sphere.faceCount) faces")
        var options = ConsolidationOptions()
        options.viewTriangleBudget = 5_000
        guard let result = consolidated([sphere], options) else {
            return r.check("budget.result", false, "nil without cancellation")
        }
        r.check("budget.measuredFull", result.measured.triangleCount == 20_000, "\(result.measured.triangleCount)")
        let viewFaces = result.view.triangleCount
        r.check("budget.view", viewFaces <= 5_000 && viewFaces >= 2_500, "\(viewFaces) view faces")
        r.check("budget.stats", result.stats.viewTriangleCount == result.view.triangleCount)
        r.check("budget.noHoles", result.inferred.triangleCount == 0 && result.floaters.triangleCount == 0)

        var reduced = ConsolidationOptions()
        reduced.simplifyChunksBeforeMerge = true
        let halved = consolidated([fullGridChunk()], reduced)?.measured.triangleCount ?? -1
        r.check("budget.reduced", halved > 0 && halved <= 400, "\(halved) faces from 800")
    }

    /// The depth window drops faces no camera position saw inside the window; without camera
    /// positions nothing is dropped; camera positions are thinned per grid cell.
    static func cropCases(_ r: Recorder) {
        let near = grid(origin: SIMD3<Float>(-0.5, -0.5, -1), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), nu: 4, nv: 4)
        let far = grid(origin: SIMD3<Float>(-0.5, -0.5, -4), u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), nu: 2, nv: 2)
        let mesh = MeshWithAttributes(mesh: TriangleMesh(positions: near.positions, indices: near.indices))
            .appending(MeshWithAttributes(mesh: TriangleMesh(positions: far.positions, indices: far.indices)))
        let cropped = MeshConsolidator.croppingToDepthWindow(mesh, window: 0.3...2, viewpoints: [.zero])
        r.check("crop.dropsFar", cropped.triangleCount == 32, "\(cropped.triangleCount) of 40 kept")
        r.check("crop.keepsNear", cropped.mesh.positions.allSatisfy { $0.z > -2 })
        let untouched = MeshConsolidator.croppingToDepthWindow(mesh, window: 0.3...2, viewpoints: [])
        r.check("crop.noViewpoints", untouched.triangleCount == 40)
        let crowd = (0..<1000).map { SIMD3<Float>(0.001 * Float($0 % 10), 0.05, 0.1) }
        r.check("crop.thinned", MeshConsolidator.decimatedViewpoints(crowd).count == 1)
        var options = ConsolidationOptions()
        options.depthWindow = 0.3...2
        options.viewpoints = [SIMD3<Float>(0.5, 0.5, 1)]
        let windowed = consolidated([fullGridChunk()], options)?.measured.triangleCount ?? -1
        r.check("crop.inConsolidate", windowed == 800, "\(windowed) faces kept of a patch 0.5 to 1.2 m away")
    }
}
