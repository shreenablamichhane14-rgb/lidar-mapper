import Foundation
import simd

// Self-test of the LargeObject module (docs/MODULES.md 3.39, section 0.5): the sector coverage
// (azimuth, sectors, viewing, face scores, guidance), the seed rules (floor, growth, wall
// columns, snapping, box, ray pick), the pass, the log file, the settings, the guidance hook and
// the manifest and copy helpers. Deterministic, synthetic samples and poses only, no ARKit
// session, camera or network; the one file check writes under the temporary directory and
// removes it. Returns one line per failing check.

/// `LargeObjectSelfTest.run()`: empty when every check passes.
enum LargeObjectSelfTest {
    /// Runs every check (nonisolated; the Diagnostics suite calls it off the main actor).
    static func run() -> [String] {
        var f: [String] = []
        checkAzimuthAndSectors(&f)
        checkObserve(&f)
        checkFaceScores(&f)
        checkGuidance(&f)
        checkFloorAndGrowth(&f)
        checkRayPick(&f)
        checkPass(&f)
        checkLogAndSettings(&f)
        checkHooksAndHelpers(&f)
        return f
    }

    /// Appends "name: detail" when `ok` is false.
    static func check(_ failures: inout [String], _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String) {
        if !ok { failures.append("\(name): \(detail())") }
    }

    /// True when `a` and `b` differ by at most `tolerance`.
    static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Checks 1 and 2: azimuth and sectors

    /// Azimuth around the front (+Z) and the sector boundaries.
    private static func checkAzimuthAndSectors(_ f: inout [String]) {
        let sectors = freshSectors()
        let right = sectors.azimuthDegrees(of: SIMD3<Float>(1, 0.5, 0))
        let left = sectors.azimuthDegrees(of: SIMD3<Float>(-1, 0.5, 0))
        let back = sectors.azimuthDegrees(of: SIMD3<Float>(0, 0.5, -1))
        check(&f, "azimuth.right", near(right, 90, 0.01), "\(right)")
        check(&f, "azimuth.left", near(left, -90, 0.01), "\(left)")
        check(&f, "azimuth.back", near(back, 180, 0.01), "\(back)")
        let cases: [(Float, Int)] = [(0, 0), (22.4, 0), (22.6, 1), (90, 2), (180, 4), (-180, 4), (-90, 6)]
        for (degrees, expected) in cases {
            let got = SectorCoverage.sector(azimuthDegrees: degrees)
            check(&f, "sector.\(degrees)", got == expected, "\(got), expected \(expected)")
        }
    }

    // MARK: - Checks 3 to 5: viewing

    /// Seconds per region from poses: in front, looking away, too far, limited tracking, the top.
    private static func checkObserve(_ f: inout [String]) {
        var front = freshSectors()
        observe(&front, orbitCamera(azimuth: 0, distance: 1.5), count: 20)
        check(&f, "observe.front", abs(front.viewSeconds[0] - 2) < 1e-6, "\(front.viewSeconds[0])")
        check(&f, "observe.frontDistance", near(front.meanViewDistance[0] ?? -1, 1, 1e-3), "\(String(describing: front.meanViewDistance[0]))")

        var none = freshSectors()
        let away = lookAt(eye: SIMD3<Float>(0, 0.5, 2), target: SIMD3<Float>(0, 0.5, 5))
        observe(&none, away, count: 10)
        observe(&none, orbitCamera(azimuth: 0, distance: 5.5), count: 10)
        for _ in 0..<10 {
            none.observe(cameraToWorld: orbitCamera(azimuth: 0, distance: 1.5), seconds: 0.1, trackingNormal: false)
        }
        let total = none.viewSeconds.reduce(0, +)
        check(&f, "observe.nothing", total == 0, "\(total) s")
        check(&f, "observe.elapsed", abs(none.elapsed - 3) < 1e-6, "\(none.elapsed)")

        var top = freshSectors()
        observe(&top, lookAt(eye: SIMD3<Float>(0, 2, 0.01), target: SIMD3<Float>(0, 1, 0)), count: 10)
        check(&f, "observe.top", top.viewSeconds[SectorCoverage.topRegion] > 0.9, "\(top.viewSeconds)")
        check(&f, "observe.topRequired", top.topRequired && top.requiredCount == 9, "\(top.requiredCount)")
        let tall = OrientedBox(center: SIMD3<Float>(0, 1.1, 0), axes: matrix_identity_float3x3,
                               halfExtents: SIMD3<Float>(0.5, 1.1, 0.5))
        let tallSectors = freshSectors(tall)
        check(&f, "observe.tallTop", !tallSectors.topRequired && tallSectors.requiredCount == 8,
              "\(tallSectors.topRequired) \(tallSectors.requiredCount)")
    }

    // MARK: - Checks 6 to 8: face scores

    /// Scores of a cube of faces: green, inward-wound, yellow.
    private static func checkFaceScores(_ f: inout [String]) {
        var green = freshSectors()
        green.updateFaces(cubeFaces(state: .green))
        let sideScores = [0, 2, 4, 6].map { green.faceScores[$0] ?? -1 }
        check(&f, "faces.sides", sideScores.allSatisfy { near($0, 1, 1e-5) }, "\(sideScores)")
        let diagonals = [1, 3, 5, 7].map { green.faceScores[$0] }
        check(&f, "faces.diagonals", diagonals.allSatisfy { $0 == nil }, "\(diagonals)")
        check(&f, "faces.top", near(green.faceScores[SectorCoverage.topRegion] ?? -1, 1, 1e-5),
              "\(String(describing: green.faceScores[SectorCoverage.topRegion]))")

        var inward = freshSectors()
        inward.updateFaces(cubeFaces(state: .green, inward: true))
        check(&f, "faces.inward", inward.faceScores == green.faceScores, "\(inward.faceScores)")

        var yellow = freshSectors()
        observe(&yellow, orbitCamera(azimuth: 0, distance: 2), count: 20)
        yellow.updateFaces(cubeFaces(state: .yellow))
        check(&f, "faces.yellowScore", near(yellow.faceScores[0] ?? -1, 0.5, 1e-5), "\(String(describing: yellow.faceScores[0]))")
        check(&f, "faces.yellowNotCovered", !yellow.isCovered(0), "covered")
    }

    // MARK: - Checks 9 to 14: guidance

    /// The object message for startup, the nearest side (ties right), back, left, top, complete,
    /// move closer and needs detail.
    private static func checkGuidance(_ f: inout [String]) {
        let atFront = orbitCamera(azimuth: 0, distance: 2)
        let fresh = freshSectors()
        check(&f, "guidance.startup", fresh.guidance(cameraToWorld: atFront) == .objectMoveAround,
              "\(String(describing: fresh.guidance(cameraToWorld: atFront)))")

        var tie = freshSectors()
        cover(&tie, sides: [0, 2, 3, 4, 5, 6], top: true)
        check(&f, "guidance.tieRight", tie.guidance(cameraToWorld: atFront) == .objectCaptureRight,
              "\(String(describing: tie.guidance(cameraToWorld: atFront)))")

        var noBack = freshSectors()
        cover(&noBack, sides: [0, 1, 2, 3, 5, 6, 7], top: true)
        check(&f, "guidance.back", noBack.guidance(cameraToWorld: atFront) == .objectCaptureBack,
              "\(String(describing: noBack.guidance(cameraToWorld: atFront)))")

        var noLeft = freshSectors()
        cover(&noLeft, sides: [0, 1, 2, 3, 4, 5, 7], top: true)
        check(&f, "guidance.left", noLeft.guidance(cameraToWorld: atFront) == .objectCaptureLeft,
              "\(String(describing: noLeft.guidance(cameraToWorld: atFront)))")

        var noTop = freshSectors()
        cover(&noTop, sides: Array(0..<8))
        check(&f, "guidance.top", noTop.guidance(cameraToWorld: atFront) == .objectCaptureTop,
              "\(String(describing: noTop.guidance(cameraToWorld: atFront)))")

        var complete = noTop
        cover(&complete, sides: [], top: true)
        check(&f, "guidance.complete", complete.guidance(cameraToWorld: atFront) == .objectLooksComplete,
              "\(String(describing: complete.guidance(cameraToWorld: atFront)))")
        check(&f, "guidance.completeCount", complete.coveredCount == 9, "\(complete.coveredCount)")

        var far = freshSectors()
        cover(&far, sides: [4])
        let farCamera = orbitCamera(azimuth: 0, distance: 3)
        observe(&far, farCamera, count: 10)
        check(&f, "guidance.closer", far.guidance(cameraToWorld: farCamera) == .objectMoveCloserToArea,
              "\(String(describing: far.guidance(cameraToWorld: farCamera)))")

        var detail = freshSectors()
        cover(&detail, sides: [4])
        let nearCamera = orbitCamera(azimuth: 0, distance: 1.5)
        observe(&detail, nearCamera, count: 16)
        detail.updateFaces(frontFaces(state: .yellow))
        check(&f, "guidance.detail", detail.guidance(cameraToWorld: nearCamera) == .objectNeedsDetail,
              "\(String(describing: detail.guidance(cameraToWorld: nearCamera)))")
    }

    // MARK: - Checks 15 to 20: floor, growth and box

    /// Floor median and percentile, growth beside a wall column, box margins, snapping, wall seed, few points.
    private static func checkFloorAndGrowth(_ f: inout [String]) {
        var floorOnly: [LargeObjectSample] = []
        for i in 0..<30 {
            let y = 0.005 * Float((i % 3) - 1)
            floorOnly.append(LargeObjectSample(position: SIMD3<Float>(Float(i) * 0.05, y, 0.3), surface: .floor))
        }
        let median = LargeObjectSeed.floorHeight(seed: SIMD3<Float>(0.5, 0.5, 0), samples: floorOnly)
        check(&f, "floor.median", near(median ?? 9, 0, 0.005), "\(String(describing: median))")
        var ramp: [LargeObjectSample] = []
        for i in 0..<100 {
            ramp.append(LargeObjectSample(position: SIMD3<Float>(0.2, Float(i) * 0.01, 0), surface: .none))
        }
        let percentile = LargeObjectSeed.floorHeight(seed: SIMD3<Float>(0, 0.5, 0), samples: ramp)
        check(&f, "floor.percentile", near(percentile ?? 9, 0.05, 1e-4), "\(String(describing: percentile))")

        let scene = sceneSamples()
        let cubeCount = cubeSamples().filter { $0.position.y > LargeObjectSeed.floorClearance }.count
        let grown = LargeObjectSeed.grow(seed: SIMD3<Float>(0.01, 0.5, 0.51), samples: scene, floorY: 0)
        let onlyCube = grown.allSatisfy { $0.x < 0.6 }
        check(&f, "grow.cubeOnly", grown.count == cubeCount && onlyCube, "\(grown.count) of \(cubeCount), only cube \(onlyCube)")

        if let box = LargeObjectSeed.box(points: grown, floorY: 0) {
            let size = box.halfExtents * 2
            let horizontal = [size.x, size.z].sorted()
            let bottom = box.center.y - box.halfExtents.y
            let sizeOK = near(horizontal[0], 1.1, 0.02) && near(horizontal[1], 1.1, 0.02) && near(size.y, 1.05, 0.02)
            check(&f, "box.size", sizeOK, "\(size)")
            check(&f, "box.bottom", near(bottom, 0, 1e-4), "\(bottom)")
        } else {
            check(&f, "box.size", false, "no box")
        }

        let snapped = LargeObjectSeed.grow(seed: SIMD3<Float>(-0.69, 0.5, 0.01), samples: scene, floorY: 0)
        check(&f, "grow.snap", snapped.count == cubeCount, "\(snapped.count)")
        let tooFar = LargeObjectSeed.growDetailed(seed: SIMD3<Float>(-0.99, 0.5, 0.01), samples: scene, floorY: 0)
        check(&f, "grow.tooFar", tooFar.points.isEmpty && !tooFar.seedInWallColumn, "\(tooFar.points.count)")
        let wall = LargeObjectSeed.growDetailed(seed: SIMD3<Float>(0.65, 1.5, 0.01), samples: scene, floorY: 0)
        check(&f, "grow.wall", wall.points.isEmpty && wall.seedInWallColumn, "\(wall.points.count) \(wall.seedInWallColumn)")

        let few = (0..<29).map { SIMD3<Float>(Float($0) * 0.01, 0.5, 0) }
        check(&f, "box.fewPoints", LargeObjectSeed.box(points: few, floorY: 0) == nil, "box")
    }

    // MARK: - Checks 21 and 22: ray pick

    /// The slab test keeps the anchor on the ray; the pick hits the quad at z -2 only toward -Z.
    private static func checkRayPick(_ f: inout [String]) {
        let onRay = quadAnchor(id: 1, transform: translation(SIMD3<Float>(0, 0, -2)), corners: unitQuad)
        let beside = quadAnchor(id: 2, transform: translation(SIMD3<Float>(3, 0, -2)), corners: unitQuad)
        // Off the quad's diagonal, so the hit never lies on the edge shared by its two triangles.
        let ahead = Ray(origin: SIMD3<Float>(0.1, 0.2, 0), direction: SIMD3<Float>(0, 0, -1))
        let kept = LargeObjectSeed.anchorsOnRay(ahead, anchors: [onRay, beside], maxDistance: 6)
        check(&f, "ray.slab", kept.count == 1 && kept.first?.anchorID == onRay.anchorID, "\(kept.count) kept")

        let mesh = LargeObjectSeed.worldMesh([onRay])
        let hit = LargeObjectSeed.pick(ahead, mesh: mesh, maxDistance: 6)
        let hitOK = hit.map { simd_distance($0, SIMD3<Float>(0.1, 0.2, -2)) < 1e-4 } ?? false
        check(&f, "ray.pickHit", hitOK, "\(String(describing: hit))")
        let backward = Ray(origin: SIMD3<Float>(0.1, 0.2, 0), direction: SIMD3<Float>(0, 0, 1))
        let miss = LargeObjectSeed.pick(backward, mesh: mesh, maxDistance: 6)
        check(&f, "ray.pickMiss", miss == nil, "\(String(describing: miss))")
        let located = LargeObjectLocator.pick(ahead, anchors: [beside, onRay])
        check(&f, "ray.locator", located.map { abs($0.z + 2) < 1e-4 } ?? false, "\(String(describing: located))")
    }
}
