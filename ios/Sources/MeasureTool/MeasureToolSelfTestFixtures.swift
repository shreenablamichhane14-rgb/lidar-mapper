import Foundation
import simd

/// Hand-built fixtures for `MeasureToolSelfTest`: a 4 x 5 x 2.5 m clean room (walls 1 to 4 in loop
/// order, room on the left, inward normals) with a door on wall 2, a window on wall 3 and a sofa,
/// plus a 2 x 2 m merged floor part next to wall 2 (`mergedOutlines`, CR-1); quality evidence with
/// a distinct distance per wall; a synthetic scan triangle far from the room. Fixed identifiers,
/// so every run is identical.
enum MeasureToolSelfTestFixtures {
    /// Wall and ceiling height, meters.
    static let height: Float = 2.5

    /// A fixed identifier whose last UUID byte is `n`.
    static func id(_ n: UInt8) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A fixed UUID whose last byte is `n`.
    static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x35, n))
    }

    /// Wall ids 1 to 4, door 11, window 12, sofa 20, room 30 (record 31), merged part owner 30.
    static let wall1 = id(1), wall2 = id(2), wall3 = id(3), wall4 = id(4)
    static let door = id(11), window = id(12), sofa = id(20), roomID = id(30)
    static let recordID = uuid(31)

    /// Room corners, world meters (plan x = world x, plan y = -world z).
    static let corners: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, -5), SIMD3<Float>(0, 0, -5),
    ]

    /// Inward wall normals in loop order (the left perpendicular in plan).
    static let normals: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0),
    ]

    /// The four straight walls.
    static func walls(elevation: Float = 0) -> [CleanWall] {
        var result: [CleanWall] = []
        let lift = SIMD3<Float>(0, elevation, 0)
        let ids = [wall1, wall2, wall3, wall4]
        for i in 0..<4 {
            result.append(CleanWall(id: ids[i], start: Vec3(corners[i] + lift), end: Vec3(corners[(i + 1) % 4] + lift),
                                    height: height, normal: Vec3(normals[i]), thickness: 0.1,
                                    thicknessSource: .estimated, arc: nil, confidence: .high, completedEdges: 4,
                                    occludedSpans: [], provenance: .measured))
        }
        return result
    }

    /// Door on wall 2 (1.0 m from its start, 0.9 m wide, 2.0 m high) and window on wall 3.
    static func openings() -> [CleanOpening] {
        [
            CleanOpening(id: door, wallID: wall2, kind: .door, offsetAlongWall: 1.0, width: 0.9, sillHeight: 0,
                         headHeight: 2.0, swing: nil, provenance: .measured),
            CleanOpening(id: window, wallID: wall3, kind: .window, offsetAlongWall: 1.0, width: 1.2, sillHeight: 0.9,
                         headHeight: 2.1, swing: nil, provenance: .measured),
        ]
    }

    /// A 2 x 0.8 x 0.9 m sofa centered at (1.5, 0.4, -2.5): box corners at x 0.5...2.5,
    /// y 0...0.8, z -2.95...-2.05.
    static func sofaObject() -> DetectedObject {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(1.5, 0.4, -2.5, 1)
        return DetectedObject(id: sofa, category: .sofa, label: "", transform: Transform4(t),
                              dimensions: Vec3(x: 2, y: 0.8, z: 0.9), confidence: .high, isHidden: false,
                              provenance: .measured)
    }

    /// The merged 2 x 2 m part next to wall 2: plan (4, 0) to (6, 2), world x 4...6, z 0...-2.
    static let mergedPart: [Vec2] = [Vec2(x: 4, y: 0), Vec2(x: 6, y: 0), Vec2(x: 6, y: 2), Vec2(x: 4, y: 2)]

    /// Metrics RoomModel would store (only the ceiling height matters here).
    static let metrics = RoomMetrics(floorArea: 24, perimeter: 18, ceilingHeight: height, ceilingProvenance: .measured,
                                     wallArea: 45, length: 5, width: 4, volume: 60, volumeProvenance: .measured)

    /// The room with its openings, the sofa and the merged part.
    static func room(elevation: Float = 0, id roomElement: ElementID = roomID, record: UUID = recordID,
                     merged: Bool = true) -> CleanRoom {
        let outline = corners.map { PlanAxes.toPlan(Vec3($0)) }
        let floor = CleanFloor(outline: outline, elevation: elevation, occludedArea: 0, provenance: .measured,
                               mergedOutlines: merged ? [mergedPart] : nil)
        return CleanRoom(id: roomElement, recordID: record, name: "", sectionLabel: nil, floorIndex: 0,
                         walls: walls(elevation: elevation), openings: openings(), floor: floor,
                         ceiling: CleanCeiling(height: height, provenance: .measured), objects: [sofaObject()],
                         metrics: metrics)
    }

    /// The model with the one room.
    static func model() -> CleanModel {
        CleanModel(rooms: [room()], sourceIsStructure: false, stamp: nil)
    }

    /// Evidence: wall 1 at 1.0 m (4 observations), wall 2 at 1.2 m (5), wall 3 at 1.6 m (6),
    /// wall 4 at 3.0 m (8); typical wall 1.4 m with 5 observations; tracking fraction `tracking`.
    /// `wall1Observations` replaces wall 1's observation count.
    static func evidence(tracking: Float = 1, wall1Observations: Int = 4) -> [UUID: RoomEvidence] {
        let walls = [
            WallEvidence(wallID: wall1, medianDistance: 1.0, observations: wall1Observations),
            WallEvidence(wallID: wall2, medianDistance: 1.2, observations: 5),
            WallEvidence(wallID: wall3, medianDistance: 1.6, observations: 6),
            WallEvidence(wallID: wall4, medianDistance: 3.0, observations: 8),
        ]
        return [recordID: RoomEvidence(trackingNormalFraction: tracking, relocalizations: 0, walls: walls)]
    }

    /// The context of `model()` with `evidence()`.
    static func context(excludeMovable: Bool = false, tracking: Float = 1, wall1Observations: Int = 4) -> MeasureToolContext {
        MeasureToolSnaps.context(model: model(), evidence: evidence(tracking: tracking, wall1Observations: wall1Observations),
                                 excludeMovable: excludeMovable)
    }

    /// A curved wall: quarter circle of radius 2 around the origin (arc 3.14 m, chord 2.83 m).
    static func curvedWall() -> CleanWall {
        let arc = WallArc(center: Vec3.zero, radius: 2, startAngle: 0, endAngle: Float.pi / 2)
        return CleanWall(id: id(50), start: Vec3(x: 2, y: 0, z: 0), end: Vec3(x: 0, y: 0, z: -2), height: height,
                         normal: Vec3(x: -1, y: 0, z: 0), thickness: 0.1, thicknessSource: .estimated, arc: arc,
                         confidence: .high, completedEdges: 4, occludedSpans: [], provenance: .measured)
    }

    /// A synthetic scan part far from the room: one triangle with corners (20, 0, 20), (21, 0, 20)
    /// and (20, 0, 21).
    static func scanPart() -> ViewerPart {
        ViewerPart(id: "selftest.scan", positions: [SIMD3<Float>(20, 0, 20), SIMD3<Float>(21, 0, 20), SIMD3<Float>(20, 0, 21)],
                   indices: [0, 1, 2], material: .unlit(SIMD4<Float>(1, 1, 1, 1)), layer: .raw, pickTag: .rawMesh)
    }

    /// A hit on the scan part's triangle.
    static func scanHit(_ position: SIMD3<Float>) -> ViewerHit {
        ViewerHit(position: position, normal: SIMD3<Float>(0, 1, 0), partID: "selftest.scan", triangle: 0, pickTag: .rawMesh)
    }

    /// A hit with a pick tag (no part lookup needed).
    static func hit(_ position: SIMD3<Float>, tag: ViewerPickTag?) -> ViewerHit {
        ViewerHit(position: position, normal: SIMD3<Float>(0, 1, 0), partID: "selftest.other", triangle: 0, pickTag: tag)
    }

    /// A free scan point.
    static func free(_ x: Float, _ y: Float, _ z: Float) -> MeasureToolPoint {
        MeasureToolPoint(position: SIMD3<Float>(x, y, z), snap: .meshSurface)
    }

    /// A fixed date `seconds` after a fixed epoch (whole seconds, so ISO 8601 round trips).
    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + seconds)
    }
}
