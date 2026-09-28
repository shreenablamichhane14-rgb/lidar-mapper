import Foundation
import simd

// Plain-Swift checks of the Quality module (no XCTest), run from Settings > Diagnostics like
// UnitsSelfTest. Fixtures live in QualitySelfTestFixtures.swift, file checks in
// QualitySelfTest+Files.swift. Deterministic (fixed ids, dates and poses); about 15 room
// evaluations of a 4340-face mesh with 34 observations each plus one sealed folder in the
// temporary directory, well under 2 s on an A15.
//
// CHECK COUNT (117 when every group runs to the end):
//   boundary, faces and orientation      17
//   observations and the light test      11
//   full walk, wall 2, windows, Codable  25
//   wall factors and texture light       17
//   no room, no mesh, winding, hashes    26
//   sealed folder, store and step        21
// The thresholds were checked against a numpy port of Coverage on the same fixtures (walls,
// floor and ceiling fully observed, texture 0.957, wall 2 hidden: walls 0.83 and a 7.0 m^2
// missing area, small window: 2.3 m^2 less).

/// Quality module self-test. `run()` returns one line per failing check; empty means all passed.
enum QualitySelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var c = QualitySelfTestChecker()
        checkInputs(&c)
        checkObservations(&c)
        let full = Fx.evaluate(room: Fx.boxRoom(), mesh: Fx.boxMesh(), walk: Fx.walk())
        checkEvaluation(&c, full: full)
        checkFactorsAndLight(&c, full: full)
        checkPaths(&c, full: full)
        checkFiles(&c)
        if c.failures.isEmpty && c.count < 100 {
            c.failures.append("selfTest: only \(c.count) checks ran")
        }
        return c.failures
    }

    /// Short name of the fixtures.
    typealias Fx = QualitySelfTestFixtures
    /// One evaluation with its diagnostics.
    typealias QualityRun = (evaluation: QualityEvaluation, detail: QualityScoreDetail)

    // MARK: - Inputs

    /// Boundary conversion (plan y to world z), heights, curved walls, faces and orientation.
    private static func checkInputs(_ c: inout QualitySelfTestChecker) {
        var room = Fx.boxRoom()
        room.floor.outline = [Vec2(x: 0, y: 0), Vec2(x: 4, y: 0), Vec2(x: 4, y: 3), Vec2(x: 0, y: 3)]
        room.floor.elevation = 0.1
        room.walls[0].start = Vec3(PlanAxes.toWorld(SIMD2<Float>(0, 3), y: 0.1))
        let flipped = QualityInputs.boundary(for: room)
        let corner = flipped.floorPolygon.count > 2 ? flipped.floorPolygon[2] : SIMD2<Float>(0, 0)
        c.check("boundary.planY3IsWorldZMinus3", abs(corner.x - 4) < 1e-5 && abs(corner.y + 3) < 1e-5, "got \(corner)")
        let start = flipped.walls.first?.start ?? SIMD2<Float>(9, 9)
        c.check("boundary.wallStartFlipped", abs(start.x) < 1e-5 && abs(start.y + 3) < 1e-5, "got \(start)")
        c.near("boundary.floorY", flipped.floorY, 0.1, 1e-6)
        c.near("boundary.ceilingY", flipped.ceilingY, 2.6, 1e-5)
        c.check("boundary.ceilingReusesFloor", flipped.ceilingPolygon.isEmpty)

        let box = QualityInputs.boundaryWithWalls(for: Fx.boxRoom())
        c.check("boundary.wallMap", box.boundary.walls.count == 4 && box.wallIndex == [0, 1, 2, 3], "\(box.wallIndex)")

        var curved = Fx.boxRoom()
        let arcCenter = Vec3(x: 2, y: 0, z: 2.5)
        curved.walls[0].arc = WallArc(center: arcCenter, radius: 3.2, startAngle: 0.9, endAngle: 2.25)
        let split = QualityInputs.boundaryWithWalls(for: curved)
        let pieces = split.wallIndex.filter { $0 == 0 }.count
        let firstStart = split.boundary.walls.first?.start ?? SIMD2<Float>(9, 9)
        let lastPiece = split.boundary.walls[Swift.max(0, pieces - 1)].end
        c.check("boundary.curvedWallSplit", pieces >= 3 && split.wallIndex.count == pieces + 3, "pieces \(pieces)")
        let startGap: Float = simd_distance(firstStart, SIMD2<Float>(0, 0))
        let endGap: Float = simd_distance(lastPiece, SIMD2<Float>(4, 0))
        c.check("boundary.curvedWallEnds", startGap < 1e-4 && endGap < 1e-4, "\(firstStart) \(lastPiece)")

        let mesh = Fx.boxMesh()
        let faces = QualityInputs.faces(mesh)
        c.check("faces.onePerTriangle", faces.count == mesh.triangleCount && faces.count == 4340, "\(faces.count)")
        let totalArea = faces.reduce(Float(0)) { $0 + $1.area }
        c.near("faces.totalArea", totalArea, 85, 0.01)
        let unit = faces.allSatisfy { abs(simd_length($0.normal) - 1) < 1e-3 }
        c.check("faces.unitNormals", unit)
        let wallFaces = faces.filter { $0.surface == SurfaceClass.wall }.count
        let ceilingFaces = faces.filter { $0.surface == SurfaceClass.ceiling }.count
        c.check("faces.classes", wallFaces == 2340 && ceilingFaces == 1000, "\(wallFaces) \(ceilingFaces)")
        let inward = faces.allSatisfy { simd_dot($0.normal, Fx.eye - $0.centroid) > 0 }
        c.check("faces.crossProductNormalsFaceRoom", inward)

        let reversed = QualityInputs.oriented(Fx.boxMesh(reversed: true), toward: [Fx.eye], limit: Int.max)
        c.check("faces.orientFlipsReversedWinding", reversed.flipped == 4340 && reversed.faces.count == 4340,
                "flipped \(reversed.flipped)")
        let same = zip(reversed.faces, faces).allSatisfy { simd_distance($0.normal, $1.normal) < 1e-4 }
        c.check("faces.orientedMatchesOriginal", same)
        let thinned = QualityInputs.oriented(mesh, toward: [], limit: 1000)
        c.check("faces.limitThinsEvenly", thinned.stride == 5 && thinned.faces.count == 868,
                "stride \(thinned.stride) count \(thinned.faces.count)")
        let shell = QualityInputs.faces(fromSamples: ExpectedSurfaces.samples(for: box.boundary))
        c.check("faces.fromSamples", shell.count > 2000 && shell.allSatisfy { $0.area > 0 })
    }

    // MARK: - Observations

    /// Decimation, tracking codes, keyframe intrinsics and the light test.
    private static func checkObservations(_ c: inout QualitySelfTestChecker) {
        let pose = Fx.transform(Fx.walk()[0])
        let tenHz = (0..<100).map { i in
            PoseSample(timestamp: Double(i) * 0.1, transform: pose, tracking: 2, thermal: 0, exposureDuration: 0.01)
        }
        let kept = QualityInputs.decimated(tenHz, hz: 2)
        c.check("decimate.tenHzToTwoHzKeepsOneInFive", kept.count == 20, "kept \(kept.count)")
        let steps = zip(kept.dropFirst(), kept).map { $0.timestamp - $1.timestamp }
        c.check("decimate.halfSecondSpacing", steps.allSatisfy { abs($0 - 0.5) < 1e-6 })
        let defaulted = QualityInputs.observations(poses: tenHz, keyframes: [])
        c.check("decimate.defaultHzIs2", defaulted.count == 20, "count \(defaulted.count)")
        c.check("observations.defaultIntrinsicsWithoutKeyframes",
                defaulted.first.map { $0.imageResolution.x == 1920 && $0.intrinsics.columns.0.x == 1440 } ?? false)
        c.check("observations.depthConfidenceUnknown", defaulted.allSatisfy { $0.depthConfidenceMean == nil })

        let mixed = [PoseSample(timestamp: 0, transform: pose, tracking: 1, thermal: 0, exposureDuration: 0.01),
                     PoseSample(timestamp: 1, transform: pose, tracking: 2, thermal: 0, exposureDuration: 0.01),
                     PoseSample(timestamp: 2, transform: pose, tracking: 0, thermal: 0, exposureDuration: 0.01)]
        let tracked = QualityInputs.observations(poses: mixed, keyframes: [], hz: 2).map { $0.trackingNormal }
        c.check("observations.trackingNormalIsCode2", tracked == [false, true, false], "\(tracked)")

        let near = Intrinsics(fx: 1000, fy: 1000, cx: 500, cy: 400, width: 1000, height: 800)
        let far = Intrinsics(fx: 2000, fy: 2000, cx: 960, cy: 720, width: 1920, height: 1440)
        var early = Fx.keyframe(index: 0, transform: pose, ambient: 1000, camera: near)
        early.timestamp = 0
        var late = Fx.keyframe(index: 1, transform: pose, ambient: 1000, camera: far)
        late.timestamp = 10
        let probes = [PoseSample(timestamp: 1, transform: pose, tracking: 2, thermal: 0, exposureDuration: 0.01),
                      PoseSample(timestamp: 9, transform: pose, tracking: 2, thermal: 0, exposureDuration: 0.01)]
        let fx = QualityInputs.observations(poses: probes, keyframes: [late, early], hz: 2).map { $0.intrinsics.columns.0.x }
        c.check("observations.nearestKeyframeIntrinsics", fx == [1000, 2000], "\(fx)")

        let bright = Fx.keyframe(index: 0, transform: pose, ambient: 1000)
        let dark = Fx.keyframe(index: 1, transform: pose, ambient: 100)
        let blurred = Fx.keyframe(index: 2, transform: pose, ambient: 1000, exposure: 1.0 / 15)
        let lost = Fx.keyframe(index: 3, transform: pose, ambient: 1000, tracking: false)
        let texture = QualityInputs.observations(keyframes: [bright, dark, blurred, lost])
        c.check("texture.onlyNormalTrackingInGoodLight", texture.count == 1 && texture.first?.timestamp == bright.timestamp,
                "count \(texture.count)")
        c.near("texture.darkFraction", QualityInputs.darkFraction([bright, dark, blurred, lost]), 0.5, 1e-6)
        c.near("texture.darkFractionEmpty", QualityInputs.darkFraction([]), 0, 0)
        let edge = Fx.keyframe(index: 4, transform: pose, ambient: QualityEvaluator.darkAmbientIntensity,
                               exposure: QualityEvaluator.longExposureSeconds)
        c.check("texture.thresholdsInclusive", QualityInputs.passesLightTest(edge))
    }

    // MARK: - Evaluation

    /// The full walk, the walk that misses wall 2, windows on wall 2, evidence and Codable.
    private static func checkEvaluation(_ c: inout QualitySelfTestChecker, full: QualityRun) {
        let room = Fx.boxRoom()
        let mesh = Fx.boxMesh()
        let s = full.evaluation.summary
        c.between("full.walls", Float(s.walls), 0.9, 1)
        c.between("full.floor", Float(s.floor), 0.9, 1)
        c.between("full.ceiling", Float(s.ceiling), 0.9, 1)
        c.between("full.texture", Float(s.texture), 0.9, 1)
        c.between("full.shape", Float(s.shape), 0.9, 1)
        c.check("full.verdictGood", s.verdict == .good, "\(s.verdict)")
        c.check("full.noMissingAreas", full.evaluation.missingAreas.isEmpty && s.missingAreas == 0,
                "\(full.evaluation.missingAreas.count)")
        c.check("full.allGood", full.evaluation.degraded == .allGood)
        c.check("full.keepsHashAndDate", full.evaluation.inputHash == "test" && full.evaluation.evaluatedAt == Fx.fixedDate)
        let evidence = full.evaluation.evidence
        c.check("evidence.onePerWall", evidence.walls.map { $0.wallID } == room.walls.map { $0.id }, "\(evidence.walls.count)")
        let distances = evidence.walls.map { $0.medianDistance }
        c.check("evidence.medianDistanceIsCameraToWall", distances.count == 4 && distances.allSatisfy { $0 >= 1.8 && $0 <= 3.0 },
                "\(distances)")
        c.check("evidence.observed", evidence.walls.allSatisfy { $0.observations >= 1 })
        c.near("evidence.trackingFromPoses", evidence.trackingNormalFraction, 1, 1e-6)

        let hidden = Fx.evaluate(room: room, mesh: mesh, walk: Fx.walkHidingWall2())
        let hiddenWalls = hidden.evaluation.summary.walls
        c.check("hidden.wallsLower", hiddenWalls < s.walls - 0.1, "\(hiddenWalls) vs \(s.walls)")
        let onWall2 = { (e: QualityEvaluation) -> [MissingAreaRecord] in
            e.missingAreas.filter { $0.surface == SurfaceClass.wall.rawValue && $0.centroid.z > 4.9 }
        }
        let hiddenArea = onWall2(hidden.evaluation).reduce(Float(0)) { $0 + $1.area }
        c.check("hidden.missingAreaOnWall2", hiddenArea > 3, "area \(hiddenArea)")
        c.check("hidden.countMatchesSummary", hidden.evaluation.summary.missingAreas == hidden.evaluation.missingAreas.count)
        let coverage = hidden.detail.coverageMissing.map { $0.area }
        let ours = hidden.evaluation.missingAreas.map { $0.area }
        c.check("hidden.sameClustersAsCoverageWithoutOpenings", coverage.count == ours.count
                && zip(coverage, ours).allSatisfy { abs($0 - $1) < 1e-4 }, "\(coverage) vs \(ours)")
        c.check("hidden.idsInOrder", hidden.evaluation.missingAreas.enumerated().allSatisfy { $0.offset == $0.element.id })

        var glazed = room
        glazed.openings = [Fx.window(on: room, wall: 2, offset: 0, width: 4, sill: 0, head: 2.5)]
        let windowed = Fx.evaluate(room: glazed, mesh: mesh, walk: Fx.walkHidingWall2())
        c.check("window.removesWall2MissingArea", onWall2(windowed.evaluation).isEmpty, "\(onWall2(windowed.evaluation).count)")
        c.check("window.wallsScoreIgnoresGlass", windowed.evaluation.summary.walls > hiddenWalls + 0.1,
                "\(windowed.evaluation.summary.walls)")
        c.check("window.samplesExcluded", windowed.detail.excludedSampleCount >= 250, "\(windowed.detail.excludedSampleCount)")

        var partly = room
        partly.openings = [Fx.window(on: room, wall: 2, offset: 1, width: 2, sill: 0.8, head: 2.0)]
        let small = Fx.evaluate(room: partly, mesh: mesh, walk: Fx.walkHidingWall2())
        let smallArea = onWall2(small.evaluation).reduce(Float(0)) { $0 + $1.area }
        c.between("window.smallWindowShrinksMissingArea", hiddenArea - smallArea, 1.9, 2.9)
        c.check("window.restOfWall2StillMissing", smallArea > 1, "area \(smallArea)")

        do {
            let data = try ProjectStore.encoder.encode(full.evaluation)
            let back = try ProjectStore.decoder.decode(QualityEvaluation.self, from: data)
            c.check("codable.roundTrip", back == full.evaluation)
            let hiddenData = try ProjectStore.encoder.encode(hidden.evaluation)
            let hiddenBack = try ProjectStore.decoder.decode(QualityEvaluation.self, from: hiddenData)
            c.check("codable.roundTripWithMissingAreas", hiddenBack == hidden.evaluation && !hiddenBack.missingAreas.isEmpty)
        } catch {
            c.check("codable.roundTrip", false, "\(error)")
        }
    }
}

/// Counts checks and collects failure lines.
struct QualitySelfTestChecker {
    /// Failure lines so far.
    var failures: [String] = []
    /// Number of checks run.
    var count = 0

    /// Records one boolean check.
    mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        if !ok {
            let d = detail()
            failures.append(d.isEmpty ? "\(name): failed" : "\(name): \(d)")
        }
    }

    /// Records |actual - expected| <= tolerance (NaN fails).
    mutating func near(_ name: String, _ actual: Float, _ expected: Float, _ tolerance: Float) {
        check(name, abs(actual - expected) <= tolerance, "expected \(expected) +/- \(tolerance), got \(actual)")
    }

    /// Records lower <= actual <= upper (NaN fails).
    mutating func between(_ name: String, _ actual: Float, _ lower: Float, _ upper: Float) {
        check(name, actual >= lower && actual <= upper, "expected \(lower)...\(upper), got \(actual)")
    }
}
