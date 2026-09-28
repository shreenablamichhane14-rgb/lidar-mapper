import Foundation
import simd

/// Hand-made `RoomInput` fixtures and synthetic meshes for `RoomModelSelfTest`. Plan points are
/// `PlanAxes` meters; surfaces use RoomPlan's frame (columns.0 along the surface, columns.1 up,
/// center at mid-height). Everything is deterministic.
enum RoomModelSelfTestFixtures {
    /// Wall ids of the 4 x 5 rectangle: 1 runs (0,0)-(5,0), 2 (5,0)-(5,4), 3 (5,4)-(0,4), 4 (0,4)-(0,0).
    static let rectangleWalls = [1, 2, 3, 4]
    /// Door on wall 1 from x 1.0 to 1.9, 2.0 m tall.
    static let doorID = 11
    /// Door on wall 2 near its end (plan y 3.0 to 3.8).
    static let endDoorID = 12
    /// Window on wall 3, sill 0.9 and head 2.1 above the floor.
    static let windowID = 13
    /// Opening with no parent, 5 cm off wall 4.
    static let orphanOpeningID = 14
    /// Sofa 0.1 m from wall 1.
    static let sofaID = 40
    /// Stub wall near corner (5, 4).
    static let stubID = 30
    /// Curved wall of the curved room.
    static let curvedID = 50

    /// Deterministic UUID from a small number.
    static func uuid(_ n: Int) -> UUID {
        let hi = UInt8((n >> 8) & 0xff)
        let lo = UInt8(n & 0xff)
        return UUID(uuid: (0x52, 0x4d, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    /// RoomPlan-style frame from plan `a` to plan `b` with the center at `centerY`; `flipped`
    /// negates columns.0 and columns.2 (the computed ends swap).
    static func frame(_ a: SIMD2<Float>, _ b: SIMD2<Float>, centerY: Float, flipped: Bool) -> (Transform4, Float) {
        let wa = PlanAxes.toWorld(a, y: 0)
        let wb = PlanAxes.toWorld(b, y: 0)
        let length = simd_distance(wa, wb)
        var x = length > 0 ? (wb - wa) / length : SIMD3<Float>(1, 0, 0)
        if flipped { x = -x }
        let up = SIMD3<Float>(0, 1, 0)
        let z = simd_cross(x, up)
        let middle = (wa + wb) * 0.5
        let center = SIMD3<Float>(middle.x, centerY, middle.z)
        let m = simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(up, 0), SIMD4<Float>(z, 0), SIMD4<Float>(center, 1)))
        return (Transform4(m), length)
    }

    /// A straight wall from plan `a` to plan `b`.
    static func wall(_ id: Int, _ a: SIMD2<Float>, _ b: SIMD2<Float>, baseY: Float = 0, height: Float = 2.5,
                     flipped: Bool = false) -> SurfaceInput {
        let (transform, length) = frame(a, b, centerY: baseY + height * 0.5, flipped: flipped)
        return SurfaceInput(identifier: uuid(id), parentIdentifier: nil, kind: .wall, transform: transform,
                            dimensions: Vec3(x: length, y: height, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: [], story: 0)
    }

    /// A door, window or opening from plan `a` to `b`, bottom and top in world Y.
    static func opening(_ id: Int, kind: SurfaceKind, parent: Int?, _ a: SIMD2<Float>, _ b: SIMD2<Float>,
                        bottom: Float, top: Float) -> SurfaceInput {
        let (transform, length) = frame(a, b, centerY: (bottom + top) * 0.5, flipped: false)
        return SurfaceInput(identifier: uuid(id), parentIdentifier: parent.map { uuid($0) }, kind: kind, transform: transform,
                            dimensions: Vec3(x: length, y: top - bottom, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: [], story: 0)
    }

    /// A floor surface (local frame with columns.2 = world up) whose corners are the plan points.
    static func floor(_ corners: [SIMD2<Float>], y: Float) -> SurfaceInput {
        let m = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, -1, 0),
                                        SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, y, 0, 1)))
        let box = Polygon2D(points: corners).boundingBox
        let size = box.map { $0.max - $0.min } ?? .zero
        return SurfaceInput(identifier: uuid(90), parentIdentifier: nil, kind: .floor, transform: Transform4(m),
                            dimensions: Vec3(x: size.x, y: size.y, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: corners.map { Vec3(x: $0.x, y: $0.y, z: 0) }, story: 0)
    }

    /// A gravity-aligned object box centered at plan `center`, standing on `floorY`.
    static func object(_ id: Int, _ category: ObjectCategory, center: SIMD2<Float>, size: SIMD3<Float>,
                       floorY: Float = 0) -> ObjectInput {
        var m = matrix_identity_float4x4
        let world = PlanAxes.toWorld(center, y: floorY + size.y * 0.5)
        m.columns.3 = SIMD4<Float>(world, 1)
        return ObjectInput(identifier: uuid(id), parentIdentifier: nil, category: category, transform: Transform4(m),
                           dimensions: Vec3(size), confidence: .high, story: 0)
    }

    /// Plan corners of the 4 x 5 rectangle, counter-clockwise.
    static let rectangleCorners: [SIMD2<Float>] = [[0, 0], [5, 0], [5, 4], [0, 4]]

    /// The 4 x 5 m room (walls in scrambled order, wall 4 given end to start), floor at `floorY`,
    /// with the requested openings and objects.
    static func rectangle(floorY: Float = 0, doors: Bool = false, window: Bool = false, orphanOpening: Bool = false,
                          sofa: Bool = false, flippedWall: Int? = nil, provisional: Bool = false) -> RoomInput {
        let c = rectangleCorners
        let walls = [wall(3, c[2], c[3], baseY: floorY, flipped: flippedWall == 3),
                     wall(1, c[0], c[1], baseY: floorY, flipped: flippedWall == 1),
                     wall(4, c[0], c[3], baseY: floorY, flipped: flippedWall == 4),
                     wall(2, c[1], c[2], baseY: floorY, flipped: flippedWall == 2)]
        var openings: [SurfaceInput] = []
        if doors {
            openings.append(opening(doorID, kind: .door, parent: 1, [1.0, 0.02], [1.9, 0.02], bottom: floorY, top: floorY + 2.0))
            openings.append(opening(endDoorID, kind: .door, parent: 2, [5, 3.0], [5, 3.8], bottom: floorY, top: floorY + 2.0))
        }
        if window {
            openings.append(opening(windowID, kind: .window, parent: 3, [3.5, 4], [2.0, 4],
                                    bottom: floorY + 0.9, top: floorY + 2.1))
        }
        if orphanOpening {
            openings.append(opening(orphanOpeningID, kind: .opening, parent: nil, [0.05, 1.0], [0.05, 2.0],
                                    bottom: floorY, top: floorY + 2.1))
        }
        var objects: [ObjectInput] = []
        if sofa {
            objects.append(object(sofaID, .sofa, center: [2.5, 0.55], size: [2.0, 0.8, 0.9], floorY: floorY))
        }
        let sections = [SectionInput(label: "livingRoom", center: Vec3(PlanAxes.toWorld([2.5, 2], y: floorY)), story: 0)]
        return RoomInput(identifier: uuid(100), walls: walls, openings: openings, floors: [floor(c, y: floorY)],
                         objects: objects, sections: sections, story: 0, isProvisional: provisional)
    }

    /// The 4 x 5 room with exactly one door (for the wall area check).
    static func rectangleOneDoor() -> RoomInput {
        var input = rectangle()
        input.openings = [opening(doorID, kind: .door, parent: 1, [1.0, 0], [1.9, 0], bottom: 0, top: 2.0)]
        return input
    }

    /// L-shaped room: 6 walls, area 20, bounding rectangle 6 x 4 (24), floor polygon the rectangle.
    static func lShape() -> RoomInput {
        let p: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 2], [4, 2], [4, 4], [0, 4]]
        var walls: [SurfaceInput] = []
        for i in 0..<p.count { walls.append(wall(60 + i, p[i], p[(i + 1) % p.count])) }
        return RoomInput(identifier: uuid(101), walls: walls, openings: [], floors: [floor([[0, 0], [6, 0], [6, 4], [0, 4]], y: 0)],
                         objects: [], sections: [], story: 0)
    }

    /// The rectangle plus a 0.3 m stub starting 4 cm from corner (5, 4), pointing into the room.
    static func withStub() -> RoomInput {
        var input = rectangle()
        input.walls.append(wall(stubID, [4.97, 3.97], [4.76, 3.76]))
        return input
    }

    /// The rectangle with wall 1 overshooting corner (5, 0) by 5 cm.
    static func overshoot() -> RoomInput {
        var input = rectangle()
        input.walls = input.walls.map { $0.identifier == uuid(1) ? wall(1, [0, 0], [5.05, 0]) : $0 }
        return input
    }

    /// A 4 x 4 room whose north wall (4,4)-(0,4) is a half circle of radius 2 bulging to plan y 6.
    static func curved() -> RoomInput {
        var arcWall = wall(curvedID, [4, 4], [0, 4])
        arcWall.curve = WallArcInput(center: Vec2(x: 0, y: 0), radius: 2, startAngle: 0, endAngle: Float.pi)
        let walls = [wall(51, [0, 0], [4, 0]), wall(52, [4, 0], [4, 4]), arcWall, wall(53, [0, 4], [0, 0])]
        return RoomInput(identifier: uuid(102), walls: walls, openings: [], floors: [], objects: [], sections: [], story: 0)
    }

    /// A horizontal grid of 2 * nx * ny triangles over plan [x0, x1] x [y0, y1] at world `y`,
    /// every face classified `surfaceClass`.
    static func grid(x0: Float, x1: Float, y0: Float, y1: Float, y: Float, nx: Int, ny: Int, surfaceClass: UInt8) -> MeshWithAttributes {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for j in 0...ny {
            for i in 0...nx {
                let px = x0 + (x1 - x0) * Float(i) / Float(nx)
                let py = y0 + (y1 - y0) * Float(j) / Float(ny)
                positions.append(PlanAxes.toWorld([px, py], y: y))
            }
        }
        let row = UInt32(nx + 1)
        for j in 0..<ny {
            for i in 0..<nx {
                let v = UInt32(j) * row + UInt32(i)
                indices.append(contentsOf: [v, v + 1, v + row + 1, v, v + row + 1, v + row])
            }
        }
        let faces = indices.count / 3
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices),
                                  faceClass: [UInt8](repeating: surfaceClass, count: faces))
    }

    /// Floor faces over the whole 4 x 5 room at `floorY` plus ceiling faces at `floorY + 2.6`
    /// over `ceilingFraction` of it.
    static func roomMesh(ceilingFraction: Float, floorY: Float = 0) -> MeshWithAttributes {
        let floorFaces = grid(x0: 0, x1: 5, y0: 0, y1: 4, y: floorY, nx: 10, ny: 8, surfaceClass: RoomMetricsCalculator.floorClass)
        let ceilingFaces = grid(x0: 0, x1: 5, y0: 0, y1: 4 * ceilingFraction, y: floorY + 2.6, nx: 10, ny: 8,
                                surfaceClass: RoomMetricsCalculator.ceilingClass)
        return floorFaces.appending(ceilingFaces)
    }

    /// A room record for the fixtures.
    static func record(_ id: Int, name: String = "", floorIndex: Int = 0) -> RoomRecord {
        RoomRecord(id: uuid(id), name: name, sessionID: uuid(200), floorIndex: floorIndex, status: .captured,
                   capturedRoomID: nil, quality: nil, hasMeshPass: false, keyframeCount: 0,
                   capturedAt: Date(timeIntervalSince1970: 0), frameLink: .projectFrame(sessionID: uuid(200)))
    }
}
