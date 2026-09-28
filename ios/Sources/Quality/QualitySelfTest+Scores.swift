import Foundation
import simd

// QualitySelfTest checks of the wall soft factors, the light test on texture, the no-room,
// no-mesh and reversed-winding paths, the capture log fields and the input hashes.
extension QualitySelfTest {
    // MARK: - Wall factors and light

    /// Confidence and edge factors change the walls score by the expected ratio; texture comes
    /// from keyframes in usable light only.
    static func checkFactorsAndLight(_ c: inout QualitySelfTestChecker, full: QualityRun) {
        c.near("factor.highAllEdges", QualityEvaluator.wallFactor(confidence: .high, completedEdges: 4), 1, 0)
        c.near("factor.edgeMissingIsSoft", QualityEvaluator.wallFactor(confidence: .high, completedEdges: 0), 0.85, 1e-6)
        c.near("factor.medium", QualityEvaluator.wallFactor(confidence: .medium, completedEdges: 4), 0.7, 1e-6)
        c.near("factor.low", QualityEvaluator.wallFactor(confidence: .low, completedEdges: 4), 0.5, 1e-6)

        let room = Fx.boxRoom()
        let mesh = Fx.boxMesh()
        let walk = Fx.walk()

        var lowRoom = room
        lowRoom.walls[1].confidence = .low
        let low = Fx.evaluate(room: lowRoom, mesh: mesh, walk: walk)
        let lowExpected = expectedWalls(full.detail, factors: [1, 0.5, 1, 1])
        c.near("factor.lowWallLowersWallsByRatio", Float(low.evaluation.summary.walls), lowExpected, 1e-4)
        c.between("factor.lowWallRatioAboutFiveSixths", lowExpected, 0.855, 0.867)
        c.check("factor.lowWallKeepsFloor", low.evaluation.summary.floor == full.evaluation.summary.floor)

        var mixedRoom = room
        mixedRoom.walls[0].completedEdges = 3
        mixedRoom.walls[1].confidence = .low
        mixedRoom.walls[3].confidence = .medium
        let mixed = Fx.evaluate(room: mixedRoom, mesh: mesh, walk: walk)
        let factors = mixed.detail.wallFactors
        let wanted: [Float] = [0.85, 0.5, 1, 0.7]
        c.check("factor.perWallFactors", factors.count == 4 && zip(factors, wanted).allSatisfy { abs($0 - $1) < 1e-6 }, "\(factors)")
        let mixedExpected = expectedWalls(full.detail, factors: [0.85, 0.5, 1, 0.7])
        c.near("factor.mixedWalls", Float(mixed.evaluation.summary.walls), mixedExpected, 1e-4)
        c.check("factor.neverAGate", mixed.evaluation.summary.walls > 0.6)

        let noFrames = Fx.evaluate(room: room, mesh: mesh, walk: walk, keyframesToo: false)
        c.near("texture.posesWithoutKeyframesGiveZero", Float(noFrames.evaluation.summary.texture), 0, 0)
        c.between("texture.posesStillGiveGeometry", Float(noFrames.evaluation.summary.walls), 0.9, 1)

        let dark = Fx.evaluate(room: room, mesh: mesh, walk: walk, ambient: 100)
        c.check("texture.darkKeyframesBelow0.2", dark.evaluation.summary.texture < 0.2, "\(dark.evaluation.summary.texture)")
        c.near("texture.darkFractionIs1", dark.evaluation.darkKeyframeFraction, 1, 0)
        c.between("texture.darkKeepsGeometry", Float(dark.evaluation.summary.walls), 0.9, 1)
        c.check("texture.brightAtLeast0.9", full.evaluation.summary.texture >= 0.9, "\(full.evaluation.summary.texture)")
        c.near("texture.brightDarkFractionIs0", full.evaluation.darkKeyframeFraction, 0, 0)
    }

    /// The walls score the full walk would have with these per-wall factors.
    private static func expectedWalls(_ detail: QualityScoreDetail, factors: [Float]) -> Float {
        var weighted: Float = 0
        var total: Float = 0
        for (i, area) in detail.wallExpectedAreas.enumerated() where i < factors.count && i < detail.wallFractions.count {
            guard let fraction = detail.wallFractions[i] else { continue }
            weighted += area * factors[i] * fraction
            total += area
        }
        return total > 0 ? weighted / total : -1
    }

    // MARK: - Paths

    /// No room, no mesh, reversed winding, log fields, degraded rules, conversions and hashes.
    static func checkPaths(_ c: inout QualitySelfTestChecker, full: QualityRun) {
        let room = Fx.boxRoom()
        let mesh = Fx.boxMesh()
        let walk = Fx.walk()

        let noRoom = Fx.evaluate(room: nil, mesh: mesh, walk: walk)
        let n = noRoom.evaluation.summary
        c.check("noRoom.roomPlanFailed", noRoom.evaluation.degraded == .roomPlanFailed && noRoom.detail.usedNoRoomPath)
        c.check("noRoom.wallsFloorCeilingZero", n.walls == 0 && n.floor == 0 && n.ceiling == 0)
        c.between("noRoom.shapeFromCoverage", Float(n.shape), 0.9, 1)
        c.between("noRoom.texture", Float(n.texture), 0.9, 1)
        c.check("noRoom.noMissingOrEvidence", noRoom.evaluation.missingAreas.isEmpty && noRoom.evaluation.evidence.walls.isEmpty)
        c.check("noRoom.verdictPoor", n.verdict == .poor)
        var empty = room
        empty.walls = []
        empty.floor.outline = []
        let unusable = Fx.evaluate(room: empty, mesh: mesh, walk: walk)
        c.check("noRoom.roomWithoutShellIsUnusable", unusable.evaluation.degraded == .roomPlanFailed
                && unusable.evaluation.summary.walls == 0)

        let reversed = Fx.evaluate(room: room, mesh: Fx.boxMesh(reversed: true), walk: walk)
        let r = reversed.evaluation.summary
        let f = full.evaluation.summary
        let wallsFloor = abs(r.walls - f.walls) < 2e-3 && abs(r.floor - f.floor) < 2e-3
        let ceilingTexture = abs(r.ceiling - f.ceiling) < 2e-3 && abs(r.texture - f.texture) < 2e-3
        c.check("winding.reversedGivesSameScores", wallsFloor && ceilingTexture, "\(r) vs \(f)")
        c.check("winding.allFlipped", reversed.detail.flippedFaceCount == 4340 && full.detail.flippedFaceCount == 0,
                "\(reversed.detail.flippedFaceCount) \(full.detail.flippedFaceCount)")

        let bare = Fx.evaluate(room: room, mesh: MeshWithAttributes(mesh: TriangleMesh()), walk: walk)
        let b = bare.evaluation.summary
        c.check("noMesh.shellStandsIn", bare.detail.usedShellFaces && bare.evaluation.degraded == .meshStripped)
        c.check("noMesh.coverageFromPoses", b.walls >= 0.9 && b.floor >= 0.9 && b.ceiling >= 0.9, "\(b)")

        let log = RoomCaptureLog(seconds: 60, instructionSeconds: [:], error: nil, relocalizations: 2,
                                 limitedTrackingFraction: 0.25, degraded: .depthStripped)
        let logged = Fx.evaluate(room: room, mesh: mesh, walk: walk, log: log)
        c.near("log.trackingFraction", logged.evaluation.evidence.trackingNormalFraction, 0.75, 1e-6)
        c.check("log.relocalizations", logged.evaluation.evidence.relocalizations == 2)
        c.check("log.degradedMode", logged.evaluation.degraded == .depthStripped)
        let failedMode: DegradedMode = QualityEvaluator.degradedMode(roomUsable: false, log: nil, meshFaceCount: 9)
        let strippedMode: DegradedMode = QualityEvaluator.degradedMode(roomUsable: true, log: nil, meshFaceCount: 0)
        let goodMode: DegradedMode = QualityEvaluator.degradedMode(roomUsable: true, log: nil, meshFaceCount: 9)
        c.check("degraded.noRoom", failedMode == DegradedMode.roomPlanFailed)
        c.check("degraded.noMesh", strippedMode == DegradedMode.meshStripped)
        c.check("degraded.allGood", goodMode == DegradedMode.allGood)

        c.check("percent.half", QualityEvaluator.fraction(percent: 50) == 0.5)
        c.check("percent.clampHigh", QualityEvaluator.fraction(percent: 150) == 1)
        c.check("percent.clampLow", QualityEvaluator.fraction(percent: -5) == 0)
        c.check("percent.nan", QualityEvaluator.fraction(percent: Float.nan) == 0)

        let seal = SealFile(sealedAt: Fx.fixedDate, files: [SealEntry(path: "poses.ptrk", size: 2660),
                                                            SealEntry(path: "keyframes.jsonl", size: 9000)])
        let done = QualityEvaluator.doneInputHash(seal: seal)
        let step = QualityStep.inputHash(seal: seal, buildRoomStamp: nil, consolidateMeshStamp: nil)
        c.check("hash.doneDiffersFromStep", done != step)
        c.check("hash.doneDeterministic", done == QualityEvaluator.doneInputHash(seal: seal) && done.count == 16)
        c.check("hash.stepIsSealPlusStamps", step == InputHasher.hash(seals: [seal], editRevision: nil, extra: ["-", "-"]))
        c.check("hash.stepFollowsMeshStamp",
                step != QualityStep.inputHash(seal: seal, buildRoomStamp: nil, consolidateMeshStamp: "m1"))

        var broken = full.evaluation
        broken.summary.shape = Double.nan
        broken.darkKeyframeFraction = Float.infinity
        if !broken.evidence.walls.isEmpty { broken.evidence.walls[0].medianDistance = Float.infinity }
        let clean = broken.sanitizedForStorage()
        let encoded = (try? ProjectStore.encoder.encode(clean)) != nil
        c.check("storage.sanitizedEncodes", encoded && clean.summary.shape == 0 && clean.darkKeyframeFraction == 0)
    }
}
