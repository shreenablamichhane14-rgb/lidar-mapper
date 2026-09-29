import Foundation
import simd

// Plain-Swift checks for the coverage module (no XCTest), run at launch in debug builds like
// UnitsSelfTest. Fixtures (box room, mesh, camera path, guidance trace) live in
// CoverageSelfTestFixtures.swift. Expected numbers come from the numpy prototype of the same
// scenario at a 16 px frustum margin, with tolerances wide enough for float32 differences.
//
// CHECK COUNT (166 in total; guidance and measurement live in CoverageSelfTestGuidance.swift):
//   observation quality and state rules  18
//   single-face grid behavior            25
//   box room face states and voxels      26
//   expected surfaces and missing areas  34
//   scan quality                         10
//   guidance engine (6 for CR-9 extras)  38
//   measurement confidence               15
// Runtime: about 143k face tests and 280k voxel lookups (0.2 m mesh, 33 observations); well
// under 2 s on an A15 even in a Debug build.

/// Coverage module self-test. `run()` returns one line per failing check; empty means all passed.
enum CoverageSelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var c = CoverageSelfTestChecker()
        checkQuality(&c)
        checkSingleFace(&c)
        checkBoxRoom(&c)
        checkGuidance(&c)
        checkMeasurement(&c)
        let ran = c.count
        if c.failures.isEmpty && ran < 45 {
            c.failures.append("selfTest: only \(ran) checks ran")
        }
        return c.failures
    }

    /// One log line: "coverage self-test: all passed" or the failures joined.
    static func summary() -> String {
        let failures = run()
        if failures.isEmpty { return "coverage self-test: all passed" }
        return "coverage self-test: \(failures.count) failed: " + failures.joined(separator: "; ")
    }

    // MARK: - Quality and state rules

    /// Observation quality terms and ranges, and the stats-to-state rule.
    private static func checkQuality(_ c: inout CoverageSelfTestChecker) {
        typealias G = CoverageGrid
        c.near("quality.ideal.nilConfidence", G.observationQuality(distance: 1, viewCosine: 1, depthConfidence: nil), 0.8, 1e-5)
        c.near("quality.ideal.fullConfidence", G.observationQuality(distance: 1, viewCosine: 1, depthConfidence: 1), 1, 1e-5)
        c.near("quality.zeroConfidence", G.observationQuality(distance: 1, viewCosine: 1, depthConfidence: 0), 0.4, 1e-5)
        c.near("quality.tooNear", G.observationQuality(distance: 0.1, viewCosine: 1, depthConfidence: 1), 0, 1e-6)
        c.near("quality.nearRamp", G.observationQuality(distance: 0.35, viewCosine: 1, depthConfidence: nil), 0.4, 1e-4)
        c.near("quality.knee", G.observationQuality(distance: 2.5, viewCosine: 1, depthConfidence: nil), 0.8, 1e-3)
        c.near("quality.farRamp", G.observationQuality(distance: 3.75, viewCosine: 1, depthConfidence: nil), 0.4, 1e-4)
        c.near("quality.maxRange", G.observationQuality(distance: 5, viewCosine: 1, depthConfidence: 1), 0, 1e-6)
        c.near("quality.grazing", G.observationQuality(distance: 1, viewCosine: 0.1, depthConfidence: 1), 0, 1e-6)
        c.near("quality.incidenceHalf", G.observationQuality(distance: 1, viewCosine: 0.435, depthConfidence: nil), 0.4, 1e-4)
        c.near("quality.nan", G.observationQuality(distance: Float.nan, viewCosine: 1, depthConfidence: 1), 0, 0)

        var inRange = true
        var farMonotonic = true
        var previous: Float = 2
        for i in 0...60 {
            let d = Float(i) * 0.1
            for cosine in [Float(-0.5), 0, 0.3, 0.7, 1] {
                for conf in [Float(0), 0.5, 1, 7] {
                    let q = G.observationQuality(distance: d, viewCosine: cosine, depthConfidence: conf)
                    if !(q >= 0 && q <= 1) { inRange = false }
                }
            }
            if d >= 2.5 {
                let q = G.observationQuality(distance: d, viewCosine: 1, depthConfidence: 0.5)
                if q > previous + 1e-6 { farMonotonic = false }
                previous = q
            }
        }
        c.check("quality.alwaysIn0to1", inRange)
        c.check("quality.nonIncreasingBeyond2.5m", farMonotonic)

        var s = CoverageStats.empty
        c.check("state.empty.gray", G.state(for: s) == .gray)
        s.observationCount = 1
        c.check("state.oneWeak.yellow", G.state(for: s) == .yellow)
        s.observationCount = 2
        s.goodObservationCount = 2
        c.check("state.twoGood.yellow", G.state(for: s) == .yellow)
        s.observationCount = 3
        s.goodObservationCount = 3
        c.check("state.threeGood.green", G.state(for: s) == .green)
        var e = CoverageStats.empty
        e.observationCount = 1
        e.goodObservationCount = 1
        e.bestQuality = 0.9
        c.check("state.oneExcellent.green", G.state(for: e) == .green)
    }

    // MARK: - Single face

    /// One camera at the origin looking down -Z and six faces: one visible, the others behind
    /// the camera, out of range, too near, facing away and outside the image.
    private static func checkSingleFace(_ c: inout CoverageSelfTestChecker) {
        let camera = CSTF.pose(yaw: 0, pitch: 0, at: SIMD3<Float>(0, 0, 0))
        let toward = SIMD3<Float>(0, 0, 1)
        let faces: [CoverageFace] = [
            CoverageFace(centroid: SIMD3<Float>(0, 0, -1.5), normal: toward, area: 0.01, surface: .wall),
            CoverageFace(centroid: SIMD3<Float>(0, 0, 1.5), normal: -toward, area: 0.01, surface: .wall),
            CoverageFace(centroid: SIMD3<Float>(0, 0, -6), normal: toward, area: 0.01, surface: .wall),
            CoverageFace(centroid: SIMD3<Float>(0, 0, -0.1), normal: toward, area: 0.01, surface: .wall),
            CoverageFace(centroid: SIMD3<Float>(0.2, 0, -1.5), normal: -toward, area: 0.01, surface: .wall),
            CoverageFace(centroid: SIMD3<Float>(3, 0, -1.5), normal: toward, area: 0.01, surface: .wall),
        ]
        var g = CoverageGrid()
        let ignored = g.integrate(observation: CSTF.observation(camera, confidence: nil, tracking: false), faces: faces)
        c.check("face.trackingLimited.ignored", ignored.facesTested == 0 && ignored.facesUpdated == 0
                && g.faceStats(0) == nil && g.voxelCount == 0, "tested \(ignored.facesTested)")
        c.check("face.unknown.gray", g.state(ofFace: 0) == .gray)

        let first = g.integrate(observation: CSTF.observation(camera, confidence: nil), faces: faces)
        c.check("face.integrate.counts", first.facesTested == 6 && first.facesUpdated == 1 && !first.truncated,
                "tested \(first.facesTested) updated \(first.facesUpdated)")
        c.check("face.oneGood.yellow", g.state(ofFace: 0) == .yellow, "got \(g.state(ofFace: 0))")
        let stats = g.faceStats(0) ?? CoverageStats.empty
        c.check("face.stats.good", stats.goodObservationCount == 1 && stats.observationCount == 1)
        c.near("face.stats.bestDistance", stats.bestDistance, 1.5, 1e-4)
        c.near("face.stats.bestViewCosine", stats.bestViewCosine, 1, 1e-4)
        c.near("face.stats.bestQuality", stats.bestQuality, 0.8, 1e-4)
        c.check("face.behindCamera.untouched", g.faceStats(1) == nil)
        c.check("face.outOfRange.untouched", g.faceStats(2) == nil)
        c.check("face.tooNear.untouched", g.faceStats(3) == nil)
        c.check("face.facingAway.untouched", g.faceStats(4) == nil)
        c.check("face.outsideImage.untouched", g.faceStats(5) == nil)

        g.integrate(observation: CSTF.observation(camera, confidence: nil), faces: faces)
        c.check("face.twoGood.yellow", g.state(ofFace: 0) == .yellow)
        g.integrate(observation: CSTF.observation(camera, confidence: nil), faces: faces)
        c.check("face.threeGood.green", g.state(ofFace: 0) == .green)
        let voxel = g.key(for: faces[0].centroid)
        c.check("voxel.countedOncePerCall", g.voxelStats(voxel)?.goodObservationCount == 3)
        c.check("voxel.isObserved", g.isObserved(near: faces[0].centroid, radius: 0.15)
                && !g.isObserved(near: SIMD3<Float>(0, 0, -3), radius: 0.15))
        c.check("voxel.key", g.key(for: SIMD3<Float>(0.05, -0.05, 1.05)) == SIMD3<Int32>(0, -1, 10))
        c.nearVec("voxel.center", g.center(of: SIMD3<Int32>(0, -1, 10)), SIMD3<Float>(0.05, -0.05, 1.05), 1e-5)

        var grown = faces
        grown.append(CoverageFace(centroid: SIMD3<Float>(0.5, 0, -2), normal: toward, area: 0.01, surface: .floor))
        g.integrate(observation: CSTF.observation(camera, confidence: nil), faces: grown)
        c.check("face.meshGrows", g.faceCount == 7 && g.state(ofFace: 6) == .yellow)
        let hole = SIMD3<Float>(1, 1, -2)
        g.markExpected([hole])
        c.check("voxel.expectedUnseen.red", g.state(atVoxel: g.key(for: hole)) == .red
                && (g.stateCounts()[.red] ?? 0) == 1)
        g.clearExpected()
        c.check("voxel.clearExpected", (g.stateCounts()[.red] ?? 0) == 0)
        g.reset()
        c.check("grid.reset", g.voxelCount == 0 && g.faceCount == 0)

        var excellent = CoverageGrid()
        excellent.integrate(observation: CSTF.observation(camera, confidence: 1), faces: faces)
        c.check("face.oneExcellent.green", excellent.state(ofFace: 0) == .green)
        var weakGrid = CoverageGrid()
        for _ in 0..<5 { weakGrid.integrate(observation: CSTF.observation(camera, confidence: 0), faces: faces) }
        c.check("face.weakForever.yellow", weakGrid.state(ofFace: 0) == .yellow
                && weakGrid.faceStats(0)?.goodObservationCount == 0 && weakGrid.faceStats(0)?.observationCount == 5)
    }

    // MARK: - Box room

    /// The 4 x 5 x 2.5 m room seen from its center over three passes of the prototype path.
    private static func checkBoxRoom(_ c: inout CoverageSelfTestChecker) {
        let room = CSTF.boxRoom()
        let mesh = CSTF.boxMesh(room: room, cell: 0.2)
        c.check("room.mesh.faceCount", mesh.faces.count == 4340, "got \(mesh.faces.count)")
        guard mesh.faces.count == 4340 else { return }
        c.nearVec("room.mesh.anchorCentroid", mesh.faces[2838].centroid, SIMD3<Float>(1.9333, 0, 2.4667), 1e-3)

        var grid = CoverageGrid()
        grid.markExpected(ExpectedSurfaces.samples(for: room).map { $0.position })
        var greenAfterOne = 0
        var voxelGreenAfterOne = 0
        for pass in 1...3 {
            for (k, a) in CSTF.passPoses.enumerated() {
                let obs = CSTF.observation(CSTF.pose(yaw: a.yaw, pitch: a.pitch, at: CSTF.eye), confidence: nil,
                                           time: Double(pass * 20 + k) * 0.5)
                grid.integrate(observation: obs, faces: mesh.faces)
            }
            if pass == 1 {
                greenAfterOne = totalGreen(grid, mesh)
                voxelGreenAfterOne = grid.stateCounts()[.green] ?? 0
                let w0 = elementStates(grid, mesh, 0), w1 = elementStates(grid, mesh, 1)
                let w2 = elementStates(grid, mesh, 2), w3 = elementStates(grid, mesh, 3)
                let fl = elementStates(grid, mesh, -1), ce = elementStates(grid, mesh, -2)
                c.check("room.pass1.wall0AllSeen", w0.gray == 0, "gray \(w0.gray)")
                c.check("room.pass1.wall3AllSeen", w3.gray == 0, "gray \(w3.gray)")
                c.check("room.pass1.wall1Unseen", w1.gray >= 630, "gray \(w1.gray)")
                c.check("room.pass1.wall2Unseen", w2.gray >= 480, "gray \(w2.gray)")
                c.check("room.pass1.ceilingNeverGreen", ce.green == 0 && ce.gray >= 790, "gray \(ce.gray) green \(ce.green)")
                c.check("room.pass1.floorPartly", fl.gray >= 370 && fl.gray <= 400, "gray \(fl.gray)")
                c.check("room.pass1.totalGreen", greenAfterOne >= 470 && greenAfterOne <= 600, "got \(greenAfterOne)")
                c.check("room.pass1.wallFace298.yellow", grid.state(ofFace: 298) == .yellow)
                c.check("room.pass1.wallFace2064.yellow", grid.state(ofFace: 2064) == .yellow)
                c.check("room.pass1.floorFace2838.yellow", grid.state(ofFace: 2838) == .yellow
                        && grid.faceStats(2838)?.goodObservationCount == 1)
                c.check("room.pass1.floorFace2511.green", grid.state(ofFace: 2511) == .green)
                c.check("room.pass1.unseenWallFace.gray", grid.faceStats(894) == nil && grid.state(ofFace: 894) == .gray)
                c.check("room.pass1.unseenCeilingFace.gray", grid.faceStats(3838) == nil)
            } else if pass == 2 {
                c.check("room.pass2.wallFace298.green", grid.state(ofFace: 298) == .green)
                c.check("room.pass2.wallFace2064.green", grid.state(ofFace: 2064) == .green)
                c.check("room.pass2.floorFace2838.stillYellow", grid.state(ofFace: 2838) == .yellow)
            }
        }
        let green = totalGreen(grid, mesh)
        c.check("room.pass3.floorFace2838.green", grid.state(ofFace: 2838) == .green)
        c.check("room.pass3.wall0AllGreen", elementStates(grid, mesh, 0).green == 520)
        c.check("room.pass3.totalGreen", green >= 1600 && green <= 1700 && green > greenAfterOne, "got \(green)")
        c.check("room.pass3.permanentYellow", grid.state(ofFace: 2290) == .yellow
                && grid.faceStats(2290)?.goodObservationCount == 0)
        c.check("room.pass3.ceilingNeverGreen", elementStates(grid, mesh, -2).green == 0)
        let counts = grid.stateCounts()
        c.check("room.voxels.red", (counts[.red] ?? 0) > 1500, "got \(counts[.red] ?? 0)")
        c.check("room.voxels.greenGrows", (counts[.green] ?? 0) > voxelGreenAfterOne)
        c.check("room.voxels.seenWallGreen", grid.state(atVoxel: grid.key(for: mesh.faces[298].centroid)) == .green)

        checkMissing(&c, room: room, grid: grid)
        checkScanQuality(&c, room: room, grid: grid, mesh: mesh)
    }

    /// Missing areas: exactly the ceiling, wall 1, wall 2 and the far floor, with sensible viewpoints.
    private static func checkMissing(_ c: inout CoverageSelfTestChecker, room: CoverageRoomBoundary, grid: CoverageGrid) {
        let result = ExpectedSurfaces.evaluate(room: room, grid: grid)
        c.check("expected.sampleCount", result.samples.count == 2170, "got \(result.samples.count)")
        c.near("expected.wallArea", result.expectedArea[.wall] ?? 0, 45, 0.01)
        c.near("expected.floorArea", result.expectedArea[.floor] ?? 0, 20, 0.01)
        c.near("expected.ceilingArea", result.expectedArea[.ceiling] ?? 0, 20, 0.01)
        var seenWalls = true
        for (k, s) in result.samples.enumerated() where s.element == 0 || s.element == 3 {
            if k >= result.observed.count || !result.observed[k] { seenWalls = false }
        }
        c.check("expected.seenWallsObserved", seenWalls)
        if let k = result.samples.firstIndex(where: { $0.element == 1 && $0.cell == SIMD2<Int32>(12, 6) }) {
            let p = result.samples[k].position
            c.check("expected.unseenSample.red", !result.observed[k] && grid.state(atVoxel: grid.key(for: p)) == .red)
        } else {
            c.check("expected.unseenSample.exists", false)
        }
        c.check("missing.count", result.missing.count == 4, "got \(result.missing.count)")
        c.check("missing.noneOnSeenWalls", result.missing.allSatisfy {
            $0.surface != .wall || (abs($0.centroid.x) > 0.5 && abs($0.centroid.z) > 0.5)
        })
        guard result.missing.count == 4 else { return }
        let expected: [CSTMissingExpectation] = [
            CSTMissingExpectation(surface: .ceiling, area: 16.0, centroid: SIMD3<Float>(2.199, 2.5, 2.801),
                                  normal: SIMD3<Float>(0, -1, 0), viewpoint: SIMD3<Float>(2.199, 1.4, 2.801)),
            CSTMissingExpectation(surface: .wall, area: 11.92, centroid: SIMD3<Float>(4, 1.258, 2.615),
                                  normal: SIMD3<Float>(-1, 0, 0), viewpoint: SIMD3<Float>(2.5, 1.4, 2.615)),
            CSTMissingExpectation(surface: .wall, area: 9.38, centroid: SIMD3<Float>(2.122, 1.264, 5),
                                  normal: SIMD3<Float>(0, 0, -1), viewpoint: SIMD3<Float>(2.122, 1.4, 3.5)),
            CSTMissingExpectation(surface: .floor, area: 7.6, centroid: SIMD3<Float>(2.855, 0, 3.522),
                                  normal: SIMD3<Float>(0, 1, 0), viewpoint: SIMD3<Float>(2.855, 1.4, 3.522)),
        ]
        for (i, e) in expected.enumerated() {
            let m = result.missing[i]
            c.check("missing\(i).surface", m.surface == e.surface, "got \(m.surface)")
            c.near("missing\(i).area", m.area, e.area, 0.5)
            c.nearVec("missing\(i).centroid", m.centroid, e.centroid, 0.1)
            c.check("missing\(i).normalInward", simd_dot(m.normal, e.normal) > 0.99)
            c.nearVec("missing\(i).viewpoint", m.suggestedViewpoint, e.viewpoint, 0.1)
            let vp = m.suggestedViewpoint
            let inside = ExpectedSurfaces.pointInPolygon(SIMD2<Float>(vp.x, vp.z), room.floorPolygon)
            let front = simd_dot(vp - m.centroid, m.normal)
            let frontOK = m.surface == .wall ? abs(front - 1.5) < 0.05 : front > 0.5
            c.check("missing\(i).viewpointInRoomInFront", inside && abs(vp.y - 1.4) < 1e-3 && frontOK,
                    "viewpoint \(vp) front \(front)")
        }
        c.check("guidance.missingCeiling", GuidanceEngine.missingKind(for: result.missing[0], among: result.missing) == .scanCeiling)
        c.check("guidance.missingFloor", GuidanceEngine.missingKind(for: result.missing[3], among: result.missing) == .pointAtFloor)
    }

    /// Scan quality percentages with and without the room boundary.
    private static func checkScanQuality(_ c: inout CoverageSelfTestChecker, room: CoverageRoomBoundary, grid: CoverageGrid,
                                         mesh: CSTF.Mesh) {
        let q = ScanQuality.evaluate(grid: grid, faces: mesh.faces, room: room)
        c.between("quality.walls", q.walls, 50, 55)
        c.between("quality.floor", q.floor, 57, 66)
        c.between("quality.ceiling", q.ceiling, 14, 25)
        c.between("quality.geometry", q.geometry, 44, 50)
        c.check("quality.geometryBetween", q.ceiling < q.geometry && q.geometry < q.floor)
        c.between("quality.textures", q.textures, 35, 40)
        c.check("quality.missingAreas", q.missingAreas.count == 4)
        let noRoom = ScanQuality.evaluate(grid: grid, faces: mesh.faces, room: nil)
        c.check("quality.noRoom.noMissing", noRoom.missingAreas.isEmpty)
        c.check("quality.noRoom.wallsPartial", noRoom.walls > 0 && noRoom.walls < 100, "got \(noRoom.walls)")
        c.near("quality.noRoom.textures", noRoom.textures, q.textures, 1e-3)
    }

    /// Per-state face counts of one element.
    private static func elementStates(_ grid: CoverageGrid, _ mesh: CSTF.Mesh,
                                      _ element: Int) -> (gray: Int, yellow: Int, green: Int) {
        var gray = 0, yellow = 0, green = 0
        for i in 0..<mesh.faces.count where mesh.element[i] == element {
            switch grid.state(ofFace: i) {
            case .gray, .red: gray += 1
            case .yellow: yellow += 1
            case .green: green += 1
            }
        }
        return (gray, yellow, green)
    }

    /// Number of green faces in the whole mesh.
    private static func totalGreen(_ grid: CoverageGrid, _ mesh: CSTF.Mesh) -> Int {
        var n = 0
        for i in 0..<mesh.faces.count where grid.state(ofFace: i) == .green { n += 1 }
        return n
    }
}

/// Short alias for the fixtures.
private typealias CSTF = CoverageSelfTestFixtures

/// Expected values for one missing area of the box room scenario.
private struct CSTMissingExpectation {
    /// Surface class, area (m^2), area-weighted centroid, inward normal and suggested viewpoint.
    var surface: SurfaceClass
    var area: Float
    var centroid: SIMD3<Float>
    var normal: SIMD3<Float>
    var viewpoint: SIMD3<Float>
}
