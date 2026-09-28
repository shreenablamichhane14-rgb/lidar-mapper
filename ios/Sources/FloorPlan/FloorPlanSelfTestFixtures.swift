import Foundation
import simd

/// Collects FloorPlan self-test results: one line per failing check ("name: detail").
struct FloorPlanSelfTestLog {
    /// Failing checks.
    private(set) var failures: [String] = []
    /// Number of checks run.
    private(set) var count = 0

    /// Records one check.
    mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        guard !condition else { return }
        let text = detail()
        failures.append(text.isEmpty ? name : "\(name): \(text)")
    }

    /// Records a float comparison within `tolerance`.
    mutating func near(_ name: String, _ actual: Float, _ expected: Float, tolerance: Float = 1e-4) {
        expect(name, abs(actual - expected) <= tolerance, "expected \(expected), got \(actual)")
    }
}

/// Hand-made clean models for `FloorPlanSelfTest` (deterministic identifiers, no RoomPlan).
enum FloorPlanSelfTestFixtures {
    /// Room, wall, opening and object identifiers of the 4 x 5 room.
    static let roomID = id(1)
    static let southWall = id(10), eastWall = id(11), northWall = id(12), westWall = id(13)
    static let door = id(20), window = id(21)
    static let sofa = id(30), sink = id(31), hiddenTable = id(32)

    /// A fixed UUID whose last two bytes encode `n`.
    static func uuid(_ n: Int) -> UUID {
        let high = UInt8(truncatingIfNeeded: n >> 8)
        let low = UInt8(truncatingIfNeeded: n)
        return UUID(uuid: (0x46, 0x50, 0x53, 0x54, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
    }

    /// A fixed element identifier.
    static func id(_ n: Int) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A world transform at plan point `p` rotated by `yaw` about +Y (plan counter-clockwise).
    static func pose(at p: SIMD2<Float>, yaw: Float = 0) -> Transform4 {
        let world = PlanAxes.toWorld(p, y: 0.4)
        let c = cos(yaw)
        let s = sin(yaw)
        let matrix = simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                                             SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(world.x, world.y, world.z, 1)))
        return Transform4(matrix)
    }

    /// A clean wall from plan point `a` to `b` whose normal points to the left of a->b.
    static func wall(_ wallID: ElementID, from a: SIMD2<Float>, to b: SIMD2<Float>, normalSide: Float = 1,
                     thicknessSource: Provenance = .estimated, occluded: [ClosedRange<Float>] = []) -> CleanWall {
        let d = simd_normalize(b - a)
        let left = SIMD2<Float>(-d.y, d.x) * normalSide
        return CleanWall(id: wallID, start: Vec3(PlanAxes.toWorld(a, y: 0)), end: Vec3(PlanAxes.toWorld(b, y: 0)),
                         height: 2.5, normal: Vec3(PlanAxes.toWorld(left, y: 0)), thickness: 0.115,
                         thicknessSource: thicknessSource, arc: nil, confidence: .high, completedEdges: 4,
                         occludedSpans: occluded, provenance: .measured)
    }

    /// A detected object at plan point `p` with footprint `width` x `depth`.
    static func object(_ objectID: ElementID, _ category: ObjectCategory, at p: SIMD2<Float>, width: Float, depth: Float,
                       hidden: Bool = false) -> DetectedObject {
        DetectedObject(id: objectID, category: category, label: "", transform: pose(at: p),
                       dimensions: Vec3(x: width, y: 0.8, z: depth), confidence: .high, isHidden: hidden, provenance: .measured)
    }

    /// A clean room around `outline` (counter-clockwise) with the given walls and parts.
    static func room(_ roomID: ElementID, outline: [SIMD2<Float>], walls: [CleanWall], openings: [CleanOpening] = [],
                     objects: [DetectedObject] = [], sectionLabel: String? = nil) -> CleanRoom {
        let polygon = Polygon2D(points: outline)
        let metrics = RoomMetrics(floorArea: polygon.area, perimeter: polygon.perimeter, ceilingHeight: 2.5,
                                  ceilingProvenance: .measured, wallArea: polygon.perimeter * 2.5, length: 0, width: 0,
                                  volume: polygon.area * 2.5, volumeProvenance: .measured)
        return CleanRoom(id: roomID, recordID: roomID.uuid, name: "", sectionLabel: sectionLabel, floorIndex: 0,
                         walls: walls, openings: openings,
                         floor: CleanFloor(outline: outline.map { Vec2($0) }, elevation: 0, occludedArea: 0, provenance: .measured),
                         ceiling: CleanCeiling(height: 2.5, provenance: .measured), objects: objects, metrics: metrics)
    }

    /// The 4 x 5 m room: south wall measured thickness, the others estimated; north wall with
    /// an occluded span 1...2 m; an estimated door on the south wall (offset 1.0, width 0.9);
    /// a window on the east wall (offset 2.0, width 1.2); a sofa, a sink and a hidden table.
    static func rectangleRoom() -> CleanRoom {
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)]
        let walls = [
            wall(southWall, from: corners[0], to: corners[1], thicknessSource: .measured),
            wall(eastWall, from: corners[1], to: corners[2]),
            wall(northWall, from: corners[2], to: corners[3], occluded: [1...2]),
            wall(westWall, from: corners[3], to: corners[0])
        ]
        let openings = [
            CleanOpening(id: door, wallID: southWall, kind: .door, offsetAlongWall: 1.0, width: 0.9, sillHeight: 0,
                         headHeight: 2.0, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .estimated),
                         provenance: .measured),
            CleanOpening(id: window, wallID: eastWall, kind: .window, offsetAlongWall: 2.0, width: 1.2, sillHeight: 0.9,
                         headHeight: 2.1, swing: nil, provenance: .measured)
        ]
        let objects = [
            object(sofa, .sofa, at: SIMD2<Float>(2, 4.4), width: 2.0, depth: 0.9),
            object(sink, .sink, at: SIMD2<Float>(3.5, 0.4), width: 0.6, depth: 0.5),
            object(hiddenTable, .table, at: SIMD2<Float>(2, 2.5), width: 1.2, depth: 0.8, hidden: true)
        ]
        return room(roomID, outline: corners, walls: walls, openings: openings, objects: objects)
    }

    /// The 4 x 5 room as a one-room clean model.
    static func rectangleModel() -> CleanModel {
        CleanModel(rooms: [rectangleRoom()], sourceIsStructure: false, stamp: nil)
    }

    /// The default floor list.
    static let floors = [FloorRecord(id: 0, name: "", elevation: 0)]

    /// An L-shaped room (6 x 4 bounding box, area 16) with six walls in loop order.
    static func lShapedModel() -> CleanModel {
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(6, 0), SIMD2<Float>(6, 2), SIMD2<Float>(2, 2),
                       SIMD2<Float>(2, 4), SIMD2<Float>(0, 4)]
        var walls: [CleanWall] = []
        for i in 0..<corners.count {
            walls.append(wall(id(100 + i), from: corners[i], to: corners[(i + 1) % corners.count]))
        }
        return CleanModel(rooms: [room(id(99), outline: corners, walls: walls)], sourceIsStructure: false, stamp: nil)
    }

    /// The 4 x 5 room whose south wall is stored end to start (normal still into the room),
    /// with a door 2.1 m from the stored start, hinged at the stored start, and an occluded
    /// span 0.5...1.0 m from the stored start.
    static func flippedWallModel() -> CleanModel {
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(4, 0), SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)]
        let walls = [
            wall(southWall, from: corners[1], to: corners[0], normalSide: -1, occluded: [0.5...1.0]),
            wall(eastWall, from: corners[1], to: corners[2]),
            wall(northWall, from: corners[2], to: corners[3]),
            wall(westWall, from: corners[3], to: corners[0])
        ]
        let openings = [
            CleanOpening(id: door, wallID: southWall, kind: .door, offsetAlongWall: 2.1, width: 0.9, sillHeight: 0,
                         headHeight: 2.0, swing: DoorSwing(hingeAtStart: true, opensToNormalSide: true, source: .estimated),
                         provenance: .measured)
        ]
        return CleanModel(rooms: [room(roomID, outline: corners, walls: walls, openings: openings)],
                          sourceIsStructure: false, stamp: nil)
    }

    /// Entity count per layer.
    static func layerCounts(_ plan: Plan2D) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entity in plan.entities {
            counts[entity.layer, default: 0] += 1
        }
        return counts
    }

    /// Radii of the arc entities on a layer.
    static func arcRadii(_ plan: Plan2D, layer: String) -> [Double] {
        var radii: [Double] = []
        for entity in plan.entities where entity.layer == layer {
            if case let .arc(_, radius, _, _) = entity.geometry { radii.append(radius) }
        }
        return radii
    }

    /// Labels of the dimension entities.
    static func dimensionLabels(_ plan: Plan2D) -> [String] {
        var labels: [String] = []
        for entity in plan.entities {
            if case let .dimension(_, _, _, label) = entity.geometry { labels.append(label) }
        }
        return labels
    }
}
