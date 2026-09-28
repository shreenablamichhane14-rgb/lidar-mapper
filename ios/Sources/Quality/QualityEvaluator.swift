import Foundation
import simd

// The scan quality evaluation of one finished room (docs/MODULES.md 3.22, ARCHITECTURE 5.8),
// computed from recorded data with Coverage's math:
//
// 1. Faces: every usable mesh triangle becomes a `CoverageFace` whose cross-product normal is
//    turned toward the nearest camera position (LiDAR winding is not reliable). A mesh above
//    `maxEvaluationFaces` is thinned evenly. A room with no mesh at all (`meshStripped`) uses
//    its expected shell as faces, so coverage still tells which parts the camera looked at.
// 2. Two grids over that one fixed face list: a geometry grid fed by the pose track (2 Hz) and
//    a texture grid fed only by keyframes taken in usable light (dark frames do not count).
// 3. With a usable room: expected samples from the clean room (`QualityInputs.boundary`),
//    wall samples inside doors, windows and openings dropped (D19). Walls = area-weighted
//    per-wall observed fraction times the wall's soft factor (1.0, `edgeMissingFactor`,
//    `mediumConfidenceFactor` or `lowConfidenceFactor`; completed edges are never a gate,
//    RESEARCH 3.8 gotcha 3). Floor and ceiling = observed / expected area. Shape = area-weighted
//    mean of the three. Missing areas = clusters of unobserved samples, openings excluded.
// 4. Without a usable room (RoomPlan failed): Coverage's no-room path gives shape; walls, floor
//    and ceiling are 0 and the evaluation carries `.roomPlanFailed`.
// 5. Texture = the texture grid's `goodFaceAreaFraction`. Coverage percentages (0...100) are
//    turned into fractions in exactly one place, `fraction(percent:)`.
// 6. Evidence per wall: median best distance and lower-median good observation count of the
//    geometry voxels at the wall's samples; tracking from the capture log.
//
// Everything here is pure and nonisolated. `evaluateSealedRoom` (QualityEvaluator+Sealed.swift)
// adds the file reading.

/// Scores one room from its mesh, pose track, keyframes and clean room.
enum QualityEvaluator {
    /// Tunables in one place (RESEARCH 3.8 disputed 13).
    static let edgeMissingFactor = 0.85, mediumConfidenceFactor = 0.7, lowConfidenceFactor = 0.5
    /// Light tunables (ARKit ambient intensity: 1000 is neutral; SPEC "lighting changes", TEST_PLAN TEX-06).
    static let darkAmbientIntensity: Float = 250
    /// Longest exposure a keyframe may have to count for texture, seconds.
    static let longExposureSeconds: Double = 1.0 / 30
    /// Most mesh faces one evaluation scores; larger meshes use every n-th face (keeps the Done
    /// check near its 5 s budget on the A15).
    static let maxEvaluationFaces = 100_000
    /// Wall samples within this distance of a door, window or opening count as inside it, meters.
    static let openingMargin: Float = 0.05
    /// Log category of the module.
    static let logCategory = "quality"

    // MARK: - Public API

    /// Scores one room. `room` nil (or a room without usable walls and outline) takes the no-room
    /// path. `mesh` is world space with face classes when known. `darkKeyframeFraction` is 0
    /// here because only observations are given; the keyframe overload fills it.
    static func evaluate(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes,
                         geometryObservations: [CoverageObservation], textureObservations: [CoverageObservation],
                         log: RoomCaptureLog?, inputHash: String, now: Date) -> QualityEvaluation {
        evaluateDetailed(roomID: roomID, room: room, mesh: mesh, geometryObservations: geometryObservations,
                         textureObservations: textureObservations, log: log, inputHash: inputHash, now: now,
                         faceLimit: maxEvaluationFaces).evaluation
    }

    /// Scores one room from recorded pose samples and keyframe records: geometry observations
    /// are the poses decimated to 2 Hz, texture observations the keyframes that pass the light
    /// test, and `darkKeyframeFraction` is the share that fails it.
    static func evaluate(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes, poses: [PoseSample],
                         keyframes: [KeyframeRecord], log: RoomCaptureLog?, inputHash: String, now: Date) -> QualityEvaluation {
        evaluateRecords(roomID: roomID, room: room, mesh: mesh, poses: poses, keyframes: keyframes, log: log,
                        inputHash: inputHash, now: now, faceLimit: maxEvaluationFaces).evaluation
    }

    /// The keyframe overload with its diagnostics and a face limit (QualityStep's reduced
    /// variant passes a smaller one).
    static func evaluateRecords(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes, poses: [PoseSample],
                                keyframes: [KeyframeRecord], log: RoomCaptureLog?, inputHash: String, now: Date,
                                faceLimit: Int) -> (evaluation: QualityEvaluation, detail: QualityScoreDetail) {
        let geometry = QualityInputs.observations(poses: poses, keyframes: keyframes)
        let texture = QualityInputs.observations(keyframes: keyframes)
        var result = evaluateDetailed(roomID: roomID, room: room, mesh: mesh, geometryObservations: geometry,
                                      textureObservations: texture, log: log, inputHash: inputHash, now: now,
                                      faceLimit: faceLimit)
        result.evaluation.darkKeyframeFraction = QualityInputs.darkFraction(keyframes)
        return result
    }

    /// The whole evaluation (see the file header) with its diagnostics.
    static func evaluateDetailed(roomID: UUID, room: CleanRoom?, mesh: MeshWithAttributes,
                                 geometryObservations: [CoverageObservation], textureObservations: [CoverageObservation],
                                 log: RoomCaptureLog?, inputHash: String, now: Date,
                                 faceLimit: Int) -> (evaluation: QualityEvaluation, detail: QualityScoreDetail) {
        var detail = QualityScoreDetail()
        let shell = room.map { QualityInputs.boundaryWithWalls(for: $0) }
        let expected = shell.map { ExpectedSurfaces.samples(for: $0.boundary) } ?? []
        let roomUsable = shell != nil && !expected.isEmpty

        let viewpoints = QualityInputs.viewpoints(geometryObservations + textureObservations)
        let oriented = QualityInputs.oriented(mesh, toward: viewpoints, limit: faceLimit)
        var faces = oriented.faces
        let meshFaceCount = faces.count
        detail.flippedFaceCount = oriented.flipped
        detail.faceStride = oriented.stride
        if faces.isEmpty && roomUsable {
            faces = QualityInputs.faces(fromSamples: expected)
            detail.usedShellFaces = true
        }
        detail.faceCount = faces.count

        var geometryGrid = CoverageGrid()
        for observation in geometryObservations {
            let step = geometryGrid.integrate(observation: observation, faces: faces)
            if step.truncated { detail.truncatedIntegrations += 1 }
        }
        var textureGrid = CoverageGrid()
        for observation in textureObservations {
            let step = textureGrid.integrate(observation: observation, faces: faces)
            if step.truncated { detail.truncatedIntegrations += 1 }
        }
        detail.geometryObservationCount = geometryObservations.count
        detail.textureObservationCount = textureObservations.count

        let texture = QualityMath.unit(Double(textureGrid.goodFaceAreaFraction(faces: faces)))
        let tracking = trackingFraction(log: log, observations: geometryObservations)
        let relocalizations = Swift.max(0, log?.relocalizations ?? 0)
        let degraded = degradedMode(roomUsable: roomUsable, log: log, meshFaceCount: meshFaceCount)

        guard roomUsable, let room = room, let boundary = shell else {
            detail.usedNoRoomPath = true
            let report = ScanQuality.evaluate(grid: geometryGrid, faces: faces, room: nil)
            let summary = QualitySummary(shape: fraction(percent: report.geometry), walls: 0, floor: 0, ceiling: 0,
                                         texture: texture, missingAreas: 0)
            let evidence = RoomEvidence(trackingNormalFraction: tracking, relocalizations: relocalizations, walls: [])
            let evaluation = QualityEvaluation(roomID: roomID, summary: summary, missingAreas: [], degraded: degraded,
                                               evidence: evidence, darkKeyframeFraction: 0, inputHash: inputHash,
                                               evaluatedAt: now)
            return (evaluation, detail)
        }

        let result = ExpectedSurfaces.evaluate(room: boundary.boundary, grid: geometryGrid)
        detail.coverageMissing = result.missing
        let excluded = openingMask(result.samples, boundary: boundary, room: room)
        detail.excludedSampleCount = excluded.filter { $0 }.count
        let walls = wallScores(result, excluded: excluded, boundary: boundary, room: room)
        detail.wallFractions = walls.fractions
        detail.wallFactors = walls.factors
        detail.wallExpectedAreas = walls.areas

        let floor = fraction(percent: ScanQuality.classPercent(result, .floor))
        let ceiling = fraction(percent: ScanQuality.classPercent(result, .ceiling))
        let shape = shapeScore(walls: walls, floor: floor, ceiling: ceiling, result: result)
        let missing = missingAreas(result, excluded: excluded, room: boundary.boundary)
        let records = missing.enumerated().map { MissingAreaRecord(id: $0.offset, $0.element) }
        let perWall = wallEvidence(result, excluded: excluded, boundary: boundary, room: room, grid: geometryGrid)

        let summary = QualitySummary(shape: shape, walls: walls.score, floor: floor, ceiling: ceiling, texture: texture,
                                     missingAreas: records.count)
        let evidence = RoomEvidence(trackingNormalFraction: tracking, relocalizations: relocalizations, walls: perWall)
        let evaluation = QualityEvaluation(roomID: roomID, summary: summary, missingAreas: records, degraded: degraded,
                                           evidence: evidence, darkKeyframeFraction: 0, inputHash: inputHash, evaluatedAt: now)
        return (evaluation, detail)
    }

    // MARK: - Rules

    /// The one percent-to-fraction conversion: a Coverage percentage (0...100) as a 0...1
    /// score, clamped; NaN and infinities become 0.
    static func fraction(percent: Float) -> Double {
        guard percent.isFinite else { return 0 }
        return Double(Swift.min(Swift.max(percent, 0), 100)) / 100
    }

    /// Soft factor of one wall: `lowConfidenceFactor` for low and `mediumConfidenceFactor` for
    /// medium RoomPlan confidence; for high confidence 1.0 with all 4 edges complete, else
    /// `edgeMissingFactor`. A hint only, never a gate (RESEARCH 3.8 gotcha 3).
    static func wallFactor(confidence: DetectionConfidence, completedEdges: Int) -> Float {
        switch confidence {
        case .low: return Float(lowConfidenceFactor)
        case .medium: return Float(mediumConfidenceFactor)
        case .high: return completedEdges >= 4 ? 1 : Float(edgeMissingFactor)
        }
    }

    /// Fraction of the capture with normal tracking: `1 - limitedTrackingFraction` from the log,
    /// else the share of geometry observations with normal tracking, else 1.
    static func trackingFraction(log: RoomCaptureLog?, observations: [CoverageObservation]) -> Float {
        if let limited = log?.limitedTrackingFraction, limited.isFinite {
            return QualityMath.unit(Float(1 - limited))
        }
        guard !observations.isEmpty else { return 1 }
        let normal = observations.filter { $0.trackingNormal }.count
        return Float(normal) / Float(observations.count)
    }

    /// `.roomPlanFailed` without a usable room; otherwise the logged mode when it is not
    /// `.allGood`, else `.meshStripped` when the mesh had no usable face, else `.allGood`.
    static func degradedMode(roomUsable: Bool, log: RoomCaptureLog?, meshFaceCount: Int) -> DegradedMode {
        guard roomUsable else { return .roomPlanFailed }
        if let logged = log?.degraded, logged != .allGood { return logged }
        return meshFaceCount == 0 ? .meshStripped : .allGood
    }

    /// Area-weighted mean of the walls score (over wall area after openings), floor and ceiling;
    /// 0 when nothing is expected.
    static func shapeScore(walls: QualityWallScores, floor: Double, ceiling: Double,
                           result: ExpectedSurfacesResult) -> Double {
        let wallArea = Double(walls.expectedArea)
        let floorArea = Double(QualityMath.finite(result.expectedArea[.floor] ?? 0))
        let ceilingArea = Double(QualityMath.finite(result.expectedArea[.ceiling] ?? 0))
        let total = wallArea + Swift.max(0, floorArea) + Swift.max(0, ceilingArea)
        guard total > Double(ScanQuality.minExpectedArea) else { return 0 }
        let sum = walls.score * wallArea + floor * Swift.max(0, floorArea) + ceiling * Swift.max(0, ceilingArea)
        return QualityMath.unit(sum / total)
    }
}
