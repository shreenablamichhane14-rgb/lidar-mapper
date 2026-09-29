import Foundation
import simd

/// Plain-Swift checks for MeasureTool (no XCTest, no ARView, no viewer): the math, snapping and
/// point resolution (this file), then values, records, texts and the saved file
/// (MeasureToolSelfTest+Records.swift). Deterministic; the one temporary package lives under
/// `FileManager.default.temporaryDirectory` and is removed. `run()` returns one line per failing
/// check ("name: detail"); empty means all passed.
enum MeasureToolSelfTest {
    /// Number of checks `run()` performs.
    static let checkCount = 52

    /// Runs every check.
    static func run() -> [String] {
        let log = MeasureToolSelfTestLog()
        mathChecks(log)
        snapChecks(log)
        roomAndEvidenceChecks(log)
        valueChecks(log)
        recordChecks(log)
        presentationChecks(log)
        storeChecks(log)
        var failures = log.failures
        if log.count != checkCount {
            failures.append("selfTest.count: expected \(checkCount) checks, ran \(log.count)")
        }
        return failures
    }

    /// Shorthand for the fixtures.
    typealias F = MeasureToolSelfTestFixtures

    /// True when two floats differ by at most `tolerance`.
    static func near(_ a: Float, _ b: Float, _ tolerance: Float = 1e-5) -> Bool {
        abs(a - b) <= tolerance
    }

    /// True when two points differ by at most `tolerance` meters.
    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
        simd_distance(a, b) <= tolerance
    }

    // MARK: - Math (12 checks)

    /// Angles, polygon area, center, normal, vertical distance and the sigma formulas.
    static func mathChecks(_ log: MeasureToolSelfTestLog) {
        let origin = SIMD3<Float>(0, 0, 0)
        let right = MeasureMath.angle(SIMD3<Float>(1, 0, 0), origin, SIMD3<Float>(0, 0, 1))
        log.check("angle.right", near(right, Float.pi / 2), "\(right)")
        let straight = MeasureMath.angle(SIMD3<Float>(1, 0, 0), origin, SIMD3<Float>(-2, 0, 0))
        log.check("angle.collinear", near(straight, Float.pi, 1e-4), "\(straight)")
        let tiny = MeasureMath.angle(SIMD3<Float>(0.0005, 0, 0), origin, SIMD3<Float>(0, 0, 1))
        log.check("angle.shortArm", tiny == 0, "\(tiny)")

        let rectangle: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(2, 0, -3),
                                         SIMD3<Float>(0, 0, -3)]
        let cosine: Float = cos(Float.pi / 6)
        let sine: Float = sin(Float.pi / 6)
        let tilted = rectangle.map { p in SIMD3<Float>(p.x, -p.z * sine, p.z * cosine) }
        let triangle: [SIMD3<Float>] = [origin, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)]
        let flatArea = MeasureMath.polygonArea(rectangle)
        let tiltedArea = MeasureMath.polygonArea(tilted)
        let triangleArea = MeasureMath.polygonArea(triangle)
        let twoPoints = MeasureMath.polygonArea(Array(rectangle.prefix(2)))
        log.check("area.rectangleFlatAndTilted", near(flatArea, 6) && near(tiltedArea, 6, 1e-4),
                  "flat \(flatArea), tilted \(tiltedArea)")
        log.check("area.triangleAndTwoPoints", near(triangleArea, 0.5) && twoPoints == 0,
                  "triangle \(triangleArea), two points \(twoPoints)")

        let center = MeasureMath.polygonCenter(rectangle)
        let normal = MeasureMath.polygonNormal(rectangle)
        var normalOK = false
        if let unit = normal {
            let vertical: Bool = near(abs(unit.y), 1)
            let level: Bool = near(unit.x, 0) && near(unit.z, 0)
            normalOK = vertical && level
        }
        log.check("area.centerAndNormal", near(center, SIMD3<Float>(1, 0, -1.5)) && normalOK,
                  "center \(center), normal \(String(describing: normal))")

        let vertical = MeasureMath.verticalDistance(SIMD3<Float>(0, 0.1, 0), SIMD3<Float>(1, 2.6, 3))
        log.check("verticalDistance", near(vertical, 2.5), "\(vertical)")

        let square: [SIMD3<Float>] = [origin, SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, -1), SIMD3<Float>(0, 0, -1)]
        let zero = MeasureMath.areaSigma(square, pointSigmas: [0, 0, 0, 0], driftRate: 0)
        log.check("areaSigma.zero", zero == 0, "\(zero)")
        // The stated formula: each corner contributes s |p(i+1) - p(i-1)| / 2 = 0.01 * sqrt(2) / 2,
        // four of them give 0.01 * sqrt(2).
        let sigmas: [Float] = [0.01, 0.01, 0.01, 0.01]
        let points = MeasureMath.areaSigma(square, pointSigmas: sigmas, driftRate: 0)
        let expected: Float = 0.01 * Float(2).squareRoot()
        log.check("areaSigma.pointsOnly", near(points, expected), "\(points), expected \(expected)")
        let withDrift = MeasureMath.areaSigma(square, pointSigmas: sigmas, driftRate: 0.01)
        let driftExpected: Float = (expected * expected + 0.02 * 0.02).squareRoot()
        log.check("areaSigma.drift", near(withDrift, driftExpected), "\(withDrift), expected \(driftExpected)")

        let short = MeasureMath.angleSigma(SIMD3<Float>(0.5, 0, 0), origin, SIMD3<Float>(0, 0, 0.5),
                                           sigmaA: 0.01, sigmaB: 0.01, sigmaC: 0.01)
        let long = MeasureMath.angleSigma(SIMD3<Float>(2, 0, 0), origin, SIMD3<Float>(0, 0, 2),
                                          sigmaA: 0.01, sigmaB: 0.01, sigmaC: 0.01)
        log.check("angleSigma.shortArmsLarger", short > long && long > 0, "0.5 m \(short), 2 m \(long)")
        let degenerate = MeasureMath.angleSigma(origin, origin, SIMD3<Float>(0, 0, 1), sigmaA: 0.01, sigmaB: 0.01, sigmaC: 0.01)
        log.check("angleSigma.degenerateIsPi", degenerate == Float.pi, "\(degenerate)")
    }

    // MARK: - Snapping and resolution (12 checks)

    /// `combined`, `context` and `resolve`.
    static func snapChecks(_ log: MeasureToolSelfTestLog) {
        let context = F.context()
        let s = context.snaps
        let cornersAligned: Bool = s.cornerElements.count == s.corners.count && s.cornerFeatures.count == s.corners.count
        let edgesAligned: Bool = s.edgeElements.count == s.edges.count && s.edgeFeatures.count == s.edges.count
        let planeCount = s.planes.count
        let planesAligned: Bool = s.planeElements.count == planeCount && s.planeFeatures.count == planeCount
        let regionsAligned: Bool = s.planeRegions.count == planeCount
        let floors: Int = s.planeFeatures.filter { $0 == SnapSetFeature.floor }.count
        let aligned: Bool = cornersAligned && edgesAligned && planesAligned && regionsAligned
        log.check("combined.parallelArrays", aligned && floors == 2 && !s.corners.isEmpty,
                  "corners \(s.corners.count), planes \(s.planes.count), floors \(floors)")

        let plane = Plane(point: .zero, normal: SIMD3<Float>(0, 1, 0))
        let short = SnapSet(corners: [SIMD3<Float>(9, 0, 0), SIMD3<Float>(9, 1, 0)], cornerElements: [nil],
                            edges: [(SIMD3<Float>(9, 0, 0), SIMD3<Float>(9, 1, 0))], planes: [plane])
        let joined = MeasureToolSnaps.combined([short, short])
        let cornerPad: [SnapSetFeature] = [.corner, .corner, .corner, .corner]
        let edgePad: [SnapSetFeature] = [.edge, .edge]
        let planePad: [SnapSetFeature] = [.wall, .wall]
        let featuresPadded: Bool = joined.cornerFeatures == cornerPad && joined.edgeFeatures == edgePad
            && joined.planeFeatures == planePad
        let countsPadded: Bool = joined.cornerElements.count == 4 && joined.planeRegions.count == 2
            && joined.edgeElements.count == 2
        log.check("combined.padsShortArrays", featuresPadded && countsPadded, "corners \(joined.cornerElements.count)")

        let corner = MeasureToolSnaps.resolve(F.hit(SIMD3<Float>(0.03, 0, 0), tag: .rawMesh), parts: [],
                                              context: context, snapping: true)
        let cornerKind: Bool = corner.snap == SnapKind.corner && corner.feature == SnapSetFeature.corner
        log.check("resolve.floorCorner", cornerKind && near(corner.position, SIMD3<Float>.zero), "\(corner)")
        let onWall = MeasureToolSnaps.resolve(F.hit(SIMD3<Float>(2, 1.25, -0.02), tag: .rawMesh), parts: [],
                                              context: context, snapping: true)
        let wallKind: Bool = onWall.snap == SnapKind.plane && onWall.feature == SnapSetFeature.wall
        log.check("resolve.wallPlane", wallKind && onWall.element == F.wall1 && near(onWall.position.z, 0), "\(onWall)")

        let sofaCorner = SIMD3<Float>(0.52, 0.8, -2.05)
        let withSofa = context.snaps.hit(sofaCorner)
        let withoutSofa = F.context(excludeMovable: true).snaps.hit(sofaCorner)
        let sofaSnaps: Bool = withSofa.feature == SnapSetFeature.objectEdge
        let sofaGone: Bool = withoutSofa.feature != SnapSetFeature.objectEdge
        log.check("resolve.hideFurniture", sofaSnaps && sofaGone,
                  "with \(String(describing: withSofa.feature)), without \(String(describing: withoutSofa.feature))")

        let merged = MeasureToolSnaps.resolve(F.hit(SIMD3<Float>(5, 0.02, -1), tag: .rawMesh), parts: [],
                                              context: context, snapping: true)
        let mergedKind: Bool = merged.snap == SnapKind.plane && merged.feature == SnapSetFeature.floor
        log.check("resolve.mergedFloor", mergedKind && near(merged.position.y, 0), "\(merged)")

        let parts = [F.scanPart()]
        let vertex = MeasureToolSnaps.resolve(F.scanHit(SIMD3<Float>(20.01, 0, 20)), parts: parts, context: context,
                                              snapping: true)
        let vertexKind: Bool = vertex.snap == SnapKind.meshVertex && vertex.feature == nil
        log.check("resolve.meshVertex", vertexKind && near(vertex.position, SIMD3<Float>(20, 0, 20)), "\(vertex)")
        let surface = MeasureToolSnaps.resolve(F.scanHit(SIMD3<Float>(20.05, 0, 20)), parts: parts, context: context,
                                               snapping: true)
        let surfaceKind: Bool = surface.snap == SnapKind.meshSurface
        log.check("resolve.meshSurface", surfaceKind && near(surface.position, SIMD3<Float>(20.05, 0, 20)), "\(surface)")
        let off = MeasureToolSnaps.resolve(F.scanHit(SIMD3<Float>(20.01, 0, 20)), parts: parts, context: context,
                                           snapping: false)
        let offCorner = MeasureToolSnaps.resolve(F.hit(SIMD3<Float>(0.03, 0, 0), tag: .rawMesh), parts: [],
                                                 context: context, snapping: false)
        let offKinds: Bool = off.snap == SnapKind.meshSurface && off.feature == nil && offCorner.snap == SnapKind.meshSurface
        log.check("resolve.snappingOff", offKinds && near(off.position, SIMD3<Float>(20.01, 0, 20)), "\(off), \(offCorner)")

        let element = MeasureToolSnaps.resolve(F.hit(SIMD3<Float>(30, 5, 30), tag: .element(F.wall1)), parts: [],
                                               context: context, snapping: true)
        let elementKind: Bool = element.snap == SnapKind.plane && element.feature == nil
        log.check("resolve.elementTag", elementKind && element.element == F.wall1, "\(element)")

        let byDoor = MeasureToolSnaps.wall(for: F.hit(SIMD3<Float>(4, 1, -1.4), tag: .element(F.door)), context: context)
        let byScan = MeasureToolSnaps.wall(for: F.hit(SIMD3<Float>(2, 1.25, -0.02), tag: .rawMesh), context: context)
        let nearEdge = MeasureToolSnaps.wall(for: F.hit(SIMD3<Float>(2, 0.03, -0.01), tag: .rawMesh), context: context)
        let wallsFound: Bool = byDoor?.id == F.wall2 && byScan?.id == F.wall1
        log.check("wall.fromTagDoorAndScan", wallsFound && nearEdge?.id == F.wall1,
                  "door \(String(describing: byDoor?.id)), scan \(String(describing: byScan?.id))")
        let onFloor = MeasureToolSnaps.wall(for: F.hit(SIMD3<Float>(2, 0, -2.5), tag: .rawMesh), context: context)
        let onSofa = MeasureToolSnaps.wall(for: F.hit(SIMD3<Float>(0.05, 0.5, -2.5), tag: .element(F.sofa)), context: context)
        log.check("wall.noneOnFloorOrObject", onFloor == nil && onSofa == nil,
                  "floor \(String(describing: onFloor?.id)), sofa \(String(describing: onSofa?.id))")
    }

    // MARK: - Rooms and evidence (6 checks)

    /// `room(containing:)` and `evidence(for:context:)`.
    static func roomAndEvidenceChecks(_ log: MeasureToolSelfTestLog) {
        let model = F.model()
        let inside = MeasureToolSnaps.room(containing: SIMD3<Float>(2, 1, -2), in: model)
        let inMerged = MeasureToolSnaps.room(containing: SIMD3<Float>(5, 0, -1), in: model)
        var other = F.room(merged: false)
        other.id = F.id(40)
        other.recordID = F.uuid(41)
        other.floor.outline = other.floor.outline.map { Vec2(x: $0.x + 10, y: $0.y) }
        let sideBySide = CleanModel(rooms: [F.room(), other], sourceIsStructure: false, stamp: nil)
        let inOther = MeasureToolSnaps.room(containing: SIMD3<Float>(12, 0, -2), in: sideBySide)
        let otherID = F.id(40)
        let roomsFound: Bool = inside?.id == F.roomID && inMerged?.id == F.roomID
        log.check("room.outlineAndMerged", roomsFound && inOther?.id == otherID,
                  "\(String(describing: inside?.id)), \(String(describing: inMerged?.id)), \(String(describing: inOther?.id))")

        let upper = F.room(elevation: 3, id: F.id(42), record: F.uuid(43), merged: false)
        let stacked = CleanModel(rooms: [upper, F.room(merged: false)], sourceIsStructure: false, stamp: nil)
        let low = MeasureToolSnaps.room(containing: SIMD3<Float>(2, 0.1, -2), in: stacked)
        let high = MeasureToolSnaps.room(containing: SIMD3<Float>(2, 3.1, -2), in: stacked)
        let empty = MeasureToolSnaps.room(containing: SIMD3<Float>(2, 0.1, -2), in: .empty)
        let upperID = F.id(42)
        let stackedOK: Bool = low?.id == F.roomID && high?.id == upperID
        log.check("room.stackedPicksOwnFloor", stackedOK && empty == nil,
                  "low \(String(describing: low?.id)), high \(String(describing: high?.id))")

        let context = F.context()
        let onWall = MeasureToolPoint(position: SIMD3<Float>(2, 1, 0), snap: .plane, feature: .wall, element: F.wall1)
        let wallEvidence = MeasureToolSnaps.evidence(for: onWall, context: context)
        let wallSnap: Bool = wallEvidence.snap == MeasurementSnapKind.roomSurface && wallEvidence.observations == 4
        log.check("evidence.snappedWall", wallSnap && near(wallEvidence.distance, 1.0), "\(wallEvidence)")
        let onDoor = MeasureToolPoint(position: SIMD3<Float>(4, 1, -1.4), snap: .plane, feature: .door, element: F.door)
        let doorEvidence = MeasureToolSnaps.evidence(for: onDoor, context: context)
        log.check("evidence.doorUsesHostWall", near(doorEvidence.distance, 1.2) && doorEvidence.observations == 5,
                  "\(doorEvidence)")
        let freeEvidence = MeasureToolSnaps.evidence(for: F.free(2, 1, -2), context: context)
        let freeSnap: Bool = freeEvidence.snap == MeasurementSnapKind.none && freeEvidence.observations == 5
        log.check("evidence.freeUsesTypicalWall", freeSnap && near(freeEvidence.distance, 1.4), "\(freeEvidence)")
        let bare = MeasureToolSnaps.context(model: F.model(), evidence: [:], excludeMovable: false)
        let defaults = MeasureToolSnaps.evidence(for: F.free(2, 1, -2), context: bare)
        let vertex = MeasureToolSnaps.evidence(for: MeasureToolPoint(position: SIMD3<Float>(2, 1, -2), snap: .meshVertex),
                                               context: bare)
        let defaultCounts: Bool = defaults.observations == 3 && vertex.snap == MeasurementSnapKind.vertex
        log.check("evidence.defaults", defaultCounts && near(defaults.distance, 2.0), "\(defaults)")
    }
}

/// Collects check results for `MeasureToolSelfTest`.
final class MeasureToolSelfTestLog {
    /// One line per failing check.
    private(set) var failures: [String] = []
    /// Number of checks run.
    private(set) var count = 0

    /// Records one check; `detail` is evaluated only when it fails.
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "failed") {
        count += 1
        if !ok { failures.append("\(name): \(detail())") }
    }
}
