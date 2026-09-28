import Foundation
import simd

/// Fixtures for `MeasureCoreSelfTest`: a 4 x 5 x 2.5 m rectangular room (walls in loop order,
/// counter-clockwise seen from above) with one door on the 5 m wall "W2", one window on the
/// 4 m wall "W3", and a 1 m table. All identifiers are fixed, so every run is identical.
enum MeasureCoreSelfTestFixtures {
    /// Wall height and ceiling height, meters.
    static let height: Float = 2.5
    /// Door on wall 2: offset, width, head height (sill 0), meters.
    static let doorOffset: Float = 1.0, doorWidth: Float = 0.9, doorHead: Float = 2.0
    /// Window on wall 3: offset, width, sill and head heights, meters.
    static let windowOffset: Float = 1.0, windowWidth: Float = 1.2
    static let windowSill: Float = 0.9, windowHead: Float = 2.1

    /// A fixed identifier whose last UUID byte is `n`.
    static func id(_ n: UInt8) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A fixed UUID whose last byte is `n`.
    static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x4D, n))
    }

    /// Room corners in world meters (plan x = world x, plan y = -world z).
    static let corners: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, -5), SIMD3<Float>(0, 0, -5),
    ]

    /// Inward wall normals in loop order.
    static let normals: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0),
    ]

    /// The four walls, ids 1 to 4.
    static func walls(provenance: Provenance = .measured) -> [CleanWall] {
        (0..<4).map { i in
            CleanWall(id: id(UInt8(i + 1)), start: Vec3(corners[i]), end: Vec3(corners[(i + 1) % 4]),
                      height: height, normal: Vec3(normals[i]), thickness: 0.1, thicknessSource: .estimated,
                      arc: nil, confidence: .high, completedEdges: 4, occludedSpans: [], provenance: provenance)
        }
    }

    /// The door (id 11, on wall 2) and the window (id 12, on wall 3).
    static func openings() -> [CleanOpening] {
        [
            CleanOpening(id: id(11), wallID: id(2), kind: .door, offsetAlongWall: doorOffset, width: doorWidth,
                         sillHeight: 0, headHeight: doorHead, swing: nil, provenance: .measured),
            CleanOpening(id: id(12), wallID: id(3), kind: .window, offsetAlongWall: windowOffset,
                         width: windowWidth, sillHeight: windowSill, headHeight: windowHead, swing: nil,
                         provenance: .measured),
        ]
    }

    /// A 1 m x 0.75 m x 0.6 m table (id 20) in the middle of the room.
    static func table() -> DetectedObject {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(2, 0.375, -2.5, 1)
        return DetectedObject(id: id(20), category: .table, label: "", transform: Transform4(t),
                              dimensions: Vec3(x: 1, y: 0.75, z: 0.6), confidence: .high, isHidden: false,
                              provenance: .measured)
    }

    /// The metrics RoomModel would store for the room.
    static func metrics(volumeProvenance: Provenance = .measured) -> RoomMetrics {
        let doorArea: Float = doorWidth * doorHead
        let windowArea: Float = windowWidth * (windowHead - windowSill)
        let grossWalls: Float = 2 * 4 * height + 2 * 5 * height
        return RoomMetrics(floorArea: 20, perimeter: 18, ceilingHeight: height, ceilingProvenance: .measured,
                           wallArea: grossWalls - doorArea - windowArea, length: 5, width: 4,
                           volume: 20 * height, volumeProvenance: volumeProvenance)
    }

    /// The room (id 30) with the door, the window and the table.
    static func room(metrics: RoomMetrics? = nil, includeOpenings: Bool = true) -> CleanRoom {
        let outline = corners.map { PlanAxes.toPlan(Vec3($0)) }
        return CleanRoom(id: id(30), recordID: uuid(31), name: "", sectionLabel: nil, floorIndex: 0,
                         walls: walls(), openings: includeOpenings ? openings() : [],
                         floor: CleanFloor(outline: outline, elevation: 0, occludedArea: 0, provenance: .measured),
                         ceiling: CleanCeiling(height: height, provenance: .measured),
                         objects: [table()], metrics: metrics ?? self.metrics())
    }

    /// A room with no walls, openings or objects and zero metrics.
    static func emptyRoom() -> CleanRoom {
        CleanRoom(id: id(40), recordID: uuid(41), name: "", sectionLabel: nil, floorIndex: 0, walls: [],
                  openings: [], floor: CleanFloor(outline: [], elevation: 0, occludedArea: 0, provenance: .estimated),
                  ceiling: CleanCeiling(height: 0, provenance: .inferred), objects: [], metrics: .zero)
    }

    /// Good evidence: every wall seen from 2 m with 5 observations, clean tracking.
    static func goodEvidence() -> RoomEvidence {
        let walls = (1...4).map { WallEvidence(wallID: id(UInt8($0)), medianDistance: 2, observations: 5) }
        return RoomEvidence(trackingNormalFraction: 1, relocalizations: 0, walls: walls)
    }

    /// The expected row ids of `room()` in order.
    static func expectedRowIDs() -> [String] {
        var ids = ["room.length", "room.width", "room.floorArea", "room.perimeter", "room.ceilingHeight",
                   "room.wallArea", "room.volume"]
        for n in 1...4 {
            let key = "wall.\(id(UInt8(n)).uuid.uuidString)"
            ids.append(contentsOf: ["\(key).length", "\(key).height", "\(key).area"])
        }
        let door = id(11).uuid.uuidString
        let window = id(12).uuid.uuidString
        ids.append(contentsOf: ["door.\(door).width", "door.\(door).height",
                                "window.\(window).width", "window.\(window).height"])
        return ids
    }
}
