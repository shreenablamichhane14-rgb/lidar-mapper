import Foundation
import simd

// Synthetic fixtures for QualitySelfTest, after the Coverage prototype recipe: the 4 x 5 x 2.5 m
// box room (walls in Coverage's order: wall 0 on z = 0, wall 1 on x = 4, wall 2 on z = 5, wall 3
// on x = 0) as a clean room and as a 0.2 m cell triangle mesh, and a 34-pose walk at 1.4 m eye
// height held in portrait (the image's long side vertical, as people scan): a circuit of 16
// outward looks from the room center alternating 40 degrees down and 30 degrees up, 8 looks 60
// degrees down and 8 looks 60 degrees up from a 1.2 m ring, and one look at the floor and one at
// the ceiling. A numpy port of Coverage gave walls, floor and ceiling fully observed, 95.7
// percent of the face area with a good observation and wall evidence distances of 2.3 to 2.6 m
// for this walk; the checks leave margins around those numbers.

/// Room, mesh, walk and record fixtures used by `QualitySelfTest`.
enum QualitySelfTestFixtures {
    /// One camera of the walk.
    struct WalkPose {
        /// Heading in degrees on the floor plane: 0 looks toward +x, 90 toward +z (wall 2).
        var heading: Float
        /// Degrees above (positive) or below (negative) the horizon.
        var pitch: Float
        /// Camera position, world meters.
        var position: SIMD3<Float>
    }

    /// Room center at eye height.
    static let eye = SIMD3<Float>(2, 1.4, 2.5)
    /// Pinhole camera of every keyframe: 1920 x 1440, fx = fy = 1440.
    static let intrinsics = Intrinsics(fx: 1440, fy: 1440, cx: 960, cy: 720, width: 1920, height: 1440)
    /// Fixed evaluation time.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// Room height, meters.
    static let height: Float = 2.5
    /// Wall ends in world (x, z), in Coverage fixture order.
    static let wallEnds: [(SIMD2<Float>, SIMD2<Float>)] = [
        (SIMD2<Float>(0, 0), SIMD2<Float>(4, 0)), (SIMD2<Float>(4, 0), SIMD2<Float>(4, 5)),
        (SIMD2<Float>(4, 5), SIMD2<Float>(0, 5)), (SIMD2<Float>(0, 5), SIMD2<Float>(0, 0)),
    ]
    /// Inward normals of the walls, world.
    static let wallNormals: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 1), SIMD3<Float>(-1, 0, 0),
                                              SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, 0)]

    /// A fixed identifier built from `n` (no randomness).
    static func fixedID(_ n: Int) -> UUID {
        let b = UInt8(truncatingIfNeeded: n)
        let c = UInt8(truncatingIfNeeded: n >> 8)
        return UUID(uuid: (0x51, 0x55, 0x41, 0x4C, 0x49, 0x54, 0x59, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, c, b))
    }

    // MARK: - Room

    /// The box room as a clean room: 4 walls (high confidence, 4 edges), floor outline
    /// counter-clockwise in plan coordinates, ceiling 2.5 m, no openings.
    static func boxRoom() -> CleanRoom {
        var walls: [CleanWall] = []
        for (i, ends) in wallEnds.enumerated() {
            walls.append(CleanWall(id: ElementID(uuid: fixedID(100 + i)), start: Vec3(x: ends.0.x, y: 0, z: ends.0.y),
                                   end: Vec3(x: ends.1.x, y: 0, z: ends.1.y), height: height,
                                   normal: Vec3(wallNormals[i]), thickness: 0.115, thicknessSource: .estimated, arc: nil,
                                   confidence: .high, completedEdges: 4, occludedSpans: [], provenance: .measured))
        }
        let outline = [Vec2(x: 0, y: 0), Vec2(x: 0, y: -5), Vec2(x: 4, y: -5), Vec2(x: 4, y: 0)]
        return CleanRoom(id: ElementID(uuid: fixedID(1)), recordID: fixedID(1), name: "", sectionLabel: nil, floorIndex: 0,
                         walls: walls, openings: [],
                         floor: CleanFloor(outline: outline, elevation: 0, occludedArea: 0, provenance: .measured),
                         ceiling: CleanCeiling(height: height, provenance: .measured), objects: [], metrics: .zero)
    }

    /// A window on wall `wall` from `offset` along it, `width` wide, between `sill` and `head`.
    static func window(on room: CleanRoom, wall: Int, offset: Float, width: Float, sill: Float, head: Float) -> CleanOpening {
        CleanOpening(id: ElementID(uuid: fixedID(200 + wall)), wallID: room.walls[wall].id, kind: .window,
                     offsetAlongWall: offset, width: width, sillHeight: sill, headHeight: head, swing: nil,
                     provenance: .measured)
    }

    // MARK: - Mesh

    /// The room shell as a triangle mesh with face classes (wall 1, floor 2, ceiling 3): each
    /// rectangle cut into ceil(L / cell - 0.001) cells per side, two triangles per cell with
    /// centroids at cell coordinates (i + 2/3, j + 1/3) and (i + 1/3, j + 2/3), wound so the
    /// cross product points into the room (`reversed` winds them the other way).
    static func boxMesh(cell: Float = 0.2, reversed: Bool = false) -> MeshWithAttributes {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classes: [UInt8] = []
        for (i, ends) in wallEnds.enumerated() {
            let d = ends.1 - ends.0
            let length = simd_length(d)
            appendRect(origin: SIMD3<Float>(ends.0.x, 0, ends.0.y), u: SIMD3<Float>(d.x, 0, d.y), v: SIMD3<Float>(0, height, 0),
                       nu: ExpectedSurfaces.cellCount(length: length, spacing: cell),
                       nv: ExpectedSurfaces.cellCount(length: height, spacing: cell),
                       normal: wallNormals[i], surface: 1, reversed: reversed,
                       positions: &positions, indices: &indices, classes: &classes)
        }
        let nx = ExpectedSurfaces.cellCount(length: 4, spacing: cell)
        let nz = ExpectedSurfaces.cellCount(length: 5, spacing: cell)
        let across = SIMD3<Float>(4, 0, 0)
        let deep = SIMD3<Float>(0, 0, 5)
        appendRect(origin: .zero, u: across, v: deep, nu: nx, nv: nz, normal: SIMD3<Float>(0, 1, 0), surface: 2,
                   reversed: reversed, positions: &positions, indices: &indices, classes: &classes)
        appendRect(origin: SIMD3<Float>(0, height, 0), u: across, v: deep, nu: nx, nv: nz, normal: SIMD3<Float>(0, -1, 0),
                   surface: 3, reversed: reversed, positions: &positions, indices: &indices, classes: &classes)
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices), faceClass: classes)
    }

    /// Appends one rectangle of nu x nv cells (rows outer, columns inner, two triangles each).
    private static func appendRect(origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, nu: Int, nv: Int,
                                   normal: SIMD3<Float>, surface: UInt8, reversed: Bool,
                                   positions: inout [SIMD3<Float>], indices: inout [UInt32], classes: inout [UInt8]) {
        guard nu > 0, nv > 0 else { return }
        let du = u / Float(nu)
        let dv = v / Float(nv)
        let base = UInt32(positions.count)
        for j in 0...nv {
            for i in 0...nu {
                positions.append(origin + du * Float(i) + dv * Float(j))
            }
        }
        let alongNormal = simd_dot(simd_cross(du, dv), normal) >= 0
        let flip = alongNormal == reversed
        let row = UInt32(nu + 1)
        for j in 0..<nv {
            for i in 0..<nu {
                let p00 = base + UInt32(j) * row + UInt32(i)
                let p10 = p00 + 1
                let p01 = p00 + row
                let p11 = p01 + 1
                indices.append(contentsOf: flip ? [p00, p11, p10] : [p00, p10, p11])
                indices.append(contentsOf: flip ? [p00, p01, p11] : [p00, p11, p01])
                classes.append(surface)
                classes.append(surface)
            }
        }
    }

    // MARK: - Walk

    /// The 34-pose walk (see the file header), in capture order.
    static func walk() -> [WalkPose] {
        var out: [WalkPose] = []
        for k in 0..<16 {
            out.append(WalkPose(heading: 22.5 * Float(k), pitch: k % 2 == 0 ? -40 : 30, position: eye))
        }
        for k in 0..<8 {
            let azimuth = 45 * Float(k)
            out.append(WalkPose(heading: azimuth, pitch: -60, position: ring(azimuth)))
        }
        for k in 0..<8 {
            let azimuth = 45 * Float(k) + 22.5
            out.append(WalkPose(heading: azimuth, pitch: 60, position: ring(azimuth)))
        }
        out.append(WalkPose(heading: 0, pitch: -80, position: eye))
        out.append(WalkPose(heading: 180, pitch: 80, position: eye))
        return out
    }

    /// The walk without the looks aimed at wall 2 (heading within 30 degrees of +z, excluding
    /// the straight up and down looks).
    static func walkHidingWall2() -> [WalkPose] {
        walk().filter { !(abs($0.heading - 90) <= 30 && abs($0.pitch) < 70) }
    }

    /// Point on the 1.2 m ring around the room center at `azimuth` degrees.
    private static func ring(_ azimuth: Float) -> SIMD3<Float> {
        let a = Double(azimuth) * Double.pi / 180
        return eye + SIMD3<Float>(Float(1.2 * cos(a)), 0, Float(1.2 * sin(a)))
    }

    /// Camera to world of a walk pose held in portrait: the camera looks down its local -Z
    /// along the heading and pitch, local +X points down along the image's long side.
    static func transform(_ p: WalkPose) -> simd_float4x4 {
        let h = Double(p.heading) * Double.pi / 180
        let t = Double(p.pitch) * Double.pi / 180
        let forward = SIMD3<Float>(Float(cos(h) * cos(t)), Float(sin(t)), Float(sin(h) * cos(t)))
        let up = SIMD3<Float>(0, 1, 0)
        let upInView = simd_normalize(up - forward * simd_dot(up, forward))
        let x = -upInView
        let z = -forward
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0),
                                       SIMD4<Float>(p.position, 1)))
    }

    /// One pose sample per walk pose, 0.5 s apart (so 2 Hz decimation keeps all of them).
    static func poses(_ walk: [WalkPose], tracking: UInt8 = 2) -> [PoseSample] {
        walk.enumerated().map { item in
            PoseSample(timestamp: Double(item.offset) * 0.5, transform: transform(item.element), tracking: tracking,
                       thermal: 0, exposureDuration: 1.0 / 60)
        }
    }

    /// One keyframe record per walk pose, 0.5 s apart, at `ambient` light.
    static func keyframes(_ walk: [WalkPose], ambient: Float) -> [KeyframeRecord] {
        walk.enumerated().map { item in
            keyframe(index: item.offset, transform: transform(item.element), ambient: ambient)
        }
    }

    /// One keyframe record with the fixture camera.
    static func keyframe(index: Int, transform: simd_float4x4, ambient: Float, exposure: Double = 1.0 / 60,
                         tracking: Bool = true, camera: Intrinsics = QualitySelfTestFixtures.intrinsics) -> KeyframeRecord {
        KeyframeRecord(index: index, timestamp: Double(index) * 0.5, transform: Transform4(transform), intrinsics: camera,
                       imageFile: RawScanFolder.keyframeImagePath(index), depthFile: nil, exposureDuration: exposure,
                       exposureOffset: 0, ambientIntensity: ambient, angularSpeed: 0, trackingNormal: tracking)
    }

    /// Evaluates the box room (or `room`) with the walk's poses and keyframes.
    static func evaluate(room: CleanRoom?, mesh: MeshWithAttributes, walk: [WalkPose], ambient: Float = 1000,
                         keyframesToo: Bool = true, log: RoomCaptureLog? = nil,
                         inputHash: String = "test") -> (evaluation: QualityEvaluation, detail: QualityScoreDetail) {
        let frames = keyframesToo ? keyframes(walk, ambient: ambient) : []
        return QualityEvaluator.evaluateRecords(roomID: fixedID(1), room: room, mesh: mesh, poses: poses(walk),
                                                keyframes: frames, log: log, inputHash: inputHash, now: fixedDate,
                                                faceLimit: QualityEvaluator.maxEvaluationFaces)
    }
}
