import Foundation
import simd

/// Build 5 (3.37c) fixtures for `FloorPlanSelfTest`: a second room east of the 4 x 5 room, a
/// stray partition, a U-shaped room and helpers that read the drawing back.
extension FloorPlanSelfTestFixtures {
    /// Room B (3 x 4 m, 0.12 m east of the 4 x 5 room) and its walls, counter-clockwise.
    static let roomB = id(2)
    /// Room B's south, east, north and west walls.
    static let bSouth = id(40), bEast = id(41), bNorth = id(42), bWest = id(43)
    /// A stray partition inside the 4 x 5 room, and the room a split creates.
    static let partition = id(44), splitNewRoom = id(70)

    /// Room B: x 4.12 ... 7.12, y 0 ... 4, four walls with the room on their left.
    static func roomBRoom() -> CleanRoom {
        let corners = [SIMD2<Float>(4.12, 0), SIMD2<Float>(7.12, 0), SIMD2<Float>(7.12, 4), SIMD2<Float>(4.12, 4)]
        let ids = [bSouth, bEast, bNorth, bWest]
        var walls: [CleanWall] = []
        for i in 0..<4 {
            walls.append(wall(ids[i], from: corners[i], to: corners[(i + 1) % 4]))
        }
        return room(roomB, outline: corners, walls: walls)
    }

    /// The 4 x 5 room and room B.
    static func twoRoomModel() -> CleanModel {
        CleanModel(rooms: [rectangleRoom(), roomBRoom()], sourceIsStructure: false, stamp: nil)
    }

    /// A clean model that follows the build 5 orientation invariant everywhere: the two rooms
    /// plus a stray partition in the 4 x 5 room whose normal is its left perpendicular.
    static func revisedModel() -> CleanModel {
        var model = twoRoomModel()
        model.rooms[0].walls.append(wall(partition, from: SIMD2<Float>(2, 1), to: SIMD2<Float>(2, 3)))
        return model
    }

    /// The 4 x 5 room without its north wall (a loop that did not close).
    static func openLoopModel() -> CleanModel {
        var model = rectangleModel()
        model.rooms[0].walls.removeAll { $0.id == northWall }
        return model
    }

    /// A U-shaped room (6 x 4 box with a 2 x 3 notch from the top, area 18) with walls in loop
    /// order.
    static func uShapedModel() -> CleanModel {
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(6, 0), SIMD2<Float>(6, 4), SIMD2<Float>(4, 4),
                       SIMD2<Float>(4, 1), SIMD2<Float>(2, 1), SIMD2<Float>(2, 4), SIMD2<Float>(0, 4)]
        var walls: [CleanWall] = []
        for i in 0..<corners.count {
            walls.append(wall(id(120 + i), from: corners[i], to: corners[(i + 1) % corners.count]))
        }
        return CleanModel(rooms: [room(id(119), outline: corners, walls: walls)], sourceIsStructure: false, stamp: nil)
    }

    /// The 4 x 5 room with room B's outline stored as a merged outline (clockwise, to check
    /// that the builder normalizes it) and the matching floor area.
    static func mergedCleanModel() -> CleanModel {
        var model = rectangleModel()
        let part = [SIMD2<Float>(4.12, 4), SIMD2<Float>(7.12, 4), SIMD2<Float>(7.12, 0), SIMD2<Float>(4.12, 0)]
        model.rooms[0].floor.mergedOutlines = [part.map { Vec2($0) }]
        model.rooms[0].metrics.floorArea = 32
        return model
    }

    /// End points of the `.line` entities on a layer, plan meters.
    static func lines(_ plan: Plan2D, layer: String) -> [(SIMD2<Double>, SIMD2<Double>)] {
        var result: [(SIMD2<Double>, SIMD2<Double>)] = []
        for entity in plan.entities where entity.layer == layer {
            if case let .line(from, to) = entity.geometry { result.append((from, to)) }
        }
        return result
    }

    /// Lengths of a room's generated overall dimensions on a level, sorted.
    static func overallLengths(_ room: ElementID, in level: PlanLevel?) -> [Float] {
        let ids = [PlanBuilder.overallDimensionID(room, 0), PlanBuilder.overallDimensionID(room, 1)]
        return (level?.dimensions ?? []).filter { ids.contains($0.id) }.map { $0.length }.sorted()
    }

    /// True when two sorted lengths match `expected` within 1 mm.
    static func lengthsMatch(_ lengths: [Float], _ expected: [Float]) -> Bool {
        guard lengths.count == expected.count else { return false }
        return zip(lengths, expected).allSatisfy { pair in abs(pair.0 - pair.1) < 0.001 }
    }
}
