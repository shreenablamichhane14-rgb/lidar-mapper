import Foundation
import simd

/// Hand-made fixtures for `StructureSelfTest`: `RoomInput` rectangles in RoomPlan's surface
/// frame (columns.0 along the surface, columns.1 up, center at mid-height), clean rooms built
/// from them by RoomModel's `CleanModelBuilder` (no mesh), manifests, footprints and alignment
/// shapes. No RoomPlan object is created; everything is deterministic.
enum StructureSelfTestFixtures {
    /// Deterministic UUID from a small number (a prefix no other self-test uses).
    static func uuid(_ n: Int) -> UUID {
        let hi = UInt8((n >> 8) & 0xff)
        let lo = UInt8(n & 0xff)
        return UUID(uuid: (0x53, 0x54, 0x52, 0x43, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    /// A fixed date (whole seconds, so ISO 8601 JSON round trips keep it).
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// RoomPlan-style frame from plan `a` to plan `b` with the center at `centerY`, and the length.
    static func frame(_ a: SIMD2<Float>, _ b: SIMD2<Float>, centerY: Float) -> (Transform4, Float) {
        let wa = PlanAxes.toWorld(a, y: 0)
        let wb = PlanAxes.toWorld(b, y: 0)
        let length = simd_distance(wa, wb)
        let x = length > 0 ? (wb - wa) / length : SIMD3<Float>(1, 0, 0)
        let up = SIMD3<Float>(0, 1, 0)
        let z = simd_cross(x, up)
        let middle = (wa + wb) * 0.5
        let center = SIMD3<Float>(middle.x, centerY, middle.z)
        let m = simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(up, 0), SIMD4<Float>(z, 0), SIMD4<Float>(center, 1)))
        return (Transform4(m), length)
    }

    /// A straight wall from plan `a` to plan `b`, 2.5 m tall from `baseY`.
    static func wall(_ id: Int, _ a: SIMD2<Float>, _ b: SIMD2<Float>, baseY: Float = 0) -> SurfaceInput {
        let height: Float = 2.5
        let (transform, length) = frame(a, b, centerY: baseY + height * 0.5)
        return SurfaceInput(identifier: uuid(id), parentIdentifier: nil, kind: .wall, transform: transform,
                            dimensions: Vec3(x: length, y: height, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: [], story: 0)
    }

    /// A door (or `kind`) from plan `a` to `b` on wall `parent`, 2 m tall from `baseY`.
    static func door(_ id: Int, parent: Int, _ a: SIMD2<Float>, _ b: SIMD2<Float>, kind: SurfaceKind = .door,
                     baseY: Float = 0) -> SurfaceInput {
        let (transform, length) = frame(a, b, centerY: baseY + 1.0)
        return SurfaceInput(identifier: uuid(id), parentIdentifier: uuid(parent), kind: kind, transform: transform,
                            dimensions: Vec3(x: length, y: 2.0, z: 0), confidence: .high, completedEdges: 4,
                            curve: nil, polygonCorners: [], story: 0)
    }

    /// Wall ids of `rectangle(...wallBase:)`: base+1 bottom (y0), base+2 right (x1), base+3 top
    /// (y1), base+4 left (x0), each running counter-clockwise.
    static func rectangle(_ id: Int, _ low: SIMD2<Float>, _ high: SIMD2<Float>, wallBase: Int, baseY: Float = 0,
                          openings: [SurfaceInput] = []) -> RoomInput {
        let corners: [SIMD2<Float>] = [low, SIMD2<Float>(high.x, low.y), high, SIMD2<Float>(low.x, high.y)]
        var walls: [SurfaceInput] = []
        for i in 0..<4 {
            walls.append(wall(wallBase + i + 1, corners[i], corners[(i + 1) % 4], baseY: baseY))
        }
        return RoomInput(identifier: uuid(id), walls: walls, openings: openings, floors: [], objects: [],
                         sections: [], story: 0)
    }

    /// A clean room built by RoomModel from `input` (no mesh), record id `record`.
    static func cleanRoom(_ input: RoomInput, record: UUID, floor: Int = 0) -> CleanRoom {
        CleanModelBuilder.buildRoom(input, recordID: record, name: "", floorIndex: floor, mesh: nil)
    }

    /// A room record in `session` with `link`.
    static func record(_ id: UUID, session: UUID, link: FrameLink, status: RoomStatus = .processed,
                       superseded: UUID? = nil, floor: Int = 0) -> RoomRecord {
        RoomRecord(id: id, name: "", sessionID: session, floorIndex: floor, status: status, capturedRoomID: nil,
                   quality: nil, hasMeshPass: false, keyframeCount: 0, capturedAt: date, frameLink: link,
                   supersededBy: superseded)
    }

    /// A session record with `link`.
    static func session(_ id: UUID, link: FrameLink) -> CaptureSessionRef {
        CaptureSessionRef(id: id, startedAt: date, frameLink: link, worldMapFile: nil)
    }

    /// A manifest of `kind` with the given sessions and rooms.
    static func manifest(_ kind: ScanMode, sessions: [CaptureSessionRef], rooms: [RoomRecord]) -> ProjectManifest {
        var manifest = ProjectManifest.new(kind: kind, name: "", now: date)
        manifest.sessions = sessions
        manifest.rooms = rooms
        return manifest
    }

    /// Axis-aligned rectangle outline, counter-clockwise.
    static func box(_ low: SIMD2<Float>, _ high: SIMD2<Float>) -> [SIMD2<Float>] {
        [low, SIMD2<Float>(high.x, low.y), high, SIMD2<Float>(low.x, high.y)]
    }

    /// A footprint with a rectangle outline.
    static func footprint(_ id: UUID, _ low: SIMD2<Float>, _ high: SIMD2<Float>, elevation: Float = 0) -> RoomFootprint {
        RoomFootprint(roomID: id, outline: box(low, high), floorElevation: elevation)
    }

    /// A trusted-looking solution.
    static func solution(yaw: Float, translation: SIMD3<Float>, rms: Float = 0.01, matches: Int = 4) -> AlignmentSolution {
        AlignmentSolution(yaw: yaw, translation: translation, rms: rms, matches: matches)
    }

    /// An alignment shape of an axis-aligned rectangle with counter-clockwise walls, inward
    /// normals and the given door centers.
    static func alignBox(_ id: UUID, _ low: SIMD2<Float>, _ high: SIMD2<Float>, doors: [SIMD2<Float>] = []) -> AlignShape {
        let c = box(low, high)
        let inward: [SIMD2<Float>] = [SIMD2<Float>(0, 1), SIMD2<Float>(-1, 0), SIMD2<Float>(0, -1), SIMD2<Float>(1, 0)]
        var walls: [AlignWall] = []
        for i in 0..<4 {
            walls.append(AlignWall(start: c[i], end: c[(i + 1) % 4], inward: inward[i]))
        }
        return AlignShape(roomID: id, outline: c, walls: walls, doors: doors)
    }

    /// The segment pairs of a `size.x` by `size.y` rectangle's walls moved by `record` (after
    /// height = before height + translation.y).
    static func rectanglePairs(size: SIMD2<Float>, record: RoomAlignmentRecord) -> [AlignmentSegmentPair] {
        let c = box(.zero, size)
        var pairs: [AlignmentSegmentPair] = []
        for i in 0..<4 {
            let a = c[i]
            let b = c[(i + 1) % 4]
            pairs.append(AlignmentSegmentPair(beforeStart: a, beforeEnd: b, beforeY: 1.25,
                                              afterStart: StructureAlignment.planTransform(a, by: record),
                                              afterEnd: StructureAlignment.planTransform(b, by: record),
                                              afterY: 1.25 + record.translation.y))
        }
        return pairs
    }

    /// True when two floats differ by at most `tolerance`.
    static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool { abs(a - b) <= tolerance }

    /// True when two plan points are at most `tolerance` apart.
    static func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float) -> Bool {
        simd_distance(a, b) <= tolerance
    }

    /// True when two world points are at most `tolerance` apart.
    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float) -> Bool {
        simd_distance(a, b) <= tolerance
    }
}
