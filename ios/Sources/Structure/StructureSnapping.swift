import Foundation
import simd

// Manual alignment math used by HouseUI's AlignRoomsScreen (docs/MODULES.md 3.30, RESEARCH
// 3.10 recommended 13: drag, rotate, parallel-wall snapping with gap = thickness, shared-door
// snapping). Shapes are in the structure frame, plan meters (`PlanAxes`). Pure functions,
// nonisolated, deterministic, safe on any queue.

/// One wall of an alignment shape.
struct AlignWall: Equatable, Sendable {
    /// Start, plan meters.
    var start: SIMD2<Float>
    /// End, plan meters.
    var end: SIMD2<Float>
    /// Unit plan normal pointing into the room.
    var inward: SIMD2<Float>
}

/// A room as the alignment screen draws and snaps it, plan meters, structure frame.
struct AlignShape: Equatable, Sendable {
    /// Our `RoomRecord.id`.
    var roomID: UUID
    /// Floor outline, counter-clockwise.
    var outline: [SIMD2<Float>]
    /// Walls (curved walls as their chord).
    var walls: [AlignWall]
    /// Centers of doors and openings.
    var doors: [SIMD2<Float>]

    /// From a clean room (edited model, already in the structure frame). Doors and openings
    /// without a host wall are left out.
    static func from(_ room: CleanRoom) -> AlignShape {
        let walls = room.walls.map { wall -> AlignWall in
            let normal = PlanAxes.toPlan(wall.normal.simd)
            let length = simd_length(normal)
            let inward = length > 1e-6 ? normal / length : SIMD2<Float>.zero
            return AlignWall(start: PlanAxes.toPlan(wall.start.simd), end: PlanAxes.toPlan(wall.end.simd), inward: inward)
        }
        var doors: [SIMD2<Float>] = []
        for opening in room.openings where StructureWalls.isPassage(opening.kind) {
            guard let wall = room.walls.first(where: { $0.id == opening.wallID }) else { continue }
            doors.append(StructureWalls.openingCenter(opening, on: wall))
        }
        return AlignShape(roomID: room.recordID, outline: room.floor.outline.map { $0.simd }, walls: walls, doors: doors)
    }

    /// The shape moved by a record (`StructureAlignment.planTransform` for points, the yaw for
    /// normals).
    func moved(by record: RoomAlignmentRecord) -> AlignShape {
        let movedWalls = walls.map { wall in
            AlignWall(start: StructureAlignment.planTransform(wall.start, by: record),
                      end: StructureAlignment.planTransform(wall.end, by: record),
                      inward: StructureAlignment.rotate(wall.inward, by: record.yaw))
        }
        return AlignShape(roomID: roomID,
                          outline: outline.map { StructureAlignment.planTransform($0, by: record) },
                          walls: movedWalls,
                          doors: doors.map { StructureAlignment.planTransform($0, by: record) })
    }

    /// Area centroid of the outline; the mean wall midpoint without an outline; the origin
    /// without walls.
    var centroid: SIMD2<Float> {
        if outline.count >= 3 { return Polygon2D(points: outline).centroid }
        guard !walls.isEmpty else { return .zero }
        let sum = walls.reduce(SIMD2<Float>.zero) { $0 + ($1.start + $1.end) * 0.5 }
        return sum / Float(walls.count)
    }
}

/// Which snap decided the placement.
enum AlignSnapKind: String, CaseIterable, Sendable { case none, parallel, wallGap, doorway }

/// A snapped placement for the room being moved.
struct AlignPlacement: Equatable, Sendable {
    /// Delta to compose after the room's current effective alignment.
    var delta: RoomAlignmentRecord
    /// The snap that decided it (the last one applied).
    var snap: AlignSnapKind
}

/// Snapping rules of manual alignment.
enum StructureSnapping {
    /// Largest turn the parallel snap makes, degrees.
    static let angleSnapDegrees: Float = 5
    /// Largest face distance the wall snap acts on, meters.
    static let wallSnapDistance: Float = 0.3
    /// Largest door center distance the doorway snap acts on, meters.
    static let doorSnapDistance: Float = 0.4
    /// Gap the wall and doorway snaps leave between two faces, meters.
    static let assumedWallThickness: Float = 0.12
    /// Walls shorter than this do not take part in the parallel and wall snaps, meters.
    static let minimumSnapWall: Float = 0.3
    /// Largest angle between two faces' normals and exact opposition for the wall snaps, degrees.
    static let antiparallelToleranceDegrees: Float = 10
    /// A door center this close to a wall line belongs to that wall, meters.
    static let hostWallTolerance: Float = 0.05

    /// The user's raw gesture (rotation about the moving shape's centroid, then translation)
    /// snapped in this order: yaw to the nearest wall direction of `others` within 5 degrees
    /// (parallel, modulo 90 degrees); then door centers within 0.4 m made to coincide
    /// (doorway); else the nearest antiparallel wall within 0.3 m moved to a 0.12 m gap
    /// (wallGap). Pure; the returned delta applies to `moving` as given.
    ///
    /// When the two doors sit on antiparallel walls (a doorway through a shared wall), the
    /// doorway snap lines the door centers up along the wall and leaves the two faces
    /// `assumedWallThickness` apart instead of pulling the faces onto each other; other door
    /// pairs are made to coincide exactly.
    static func snap(_ moving: AlignShape, rotation: Float, translation: SIMD2<Float>, others: [AlignShape]) -> AlignPlacement {
        let pivot = moving.centroid
        var angle: Float = rotation.isFinite ? rotation : 0
        var shift: SIMD2<Float> = (translation.x.isFinite && translation.y.isFinite) ? translation : .zero
        var kind = AlignSnapKind.none
        if let correction = parallelCorrection(moving, rotation: angle, others: others) {
            angle += correction
            kind = .parallel
        }
        let turned = moving.moved(by: delta(angle: angle, shift: shift, pivot: pivot, roomID: moving.roomID))
        if let move = doorwayMove(turned, others: others) {
            shift += move
            kind = .doorway
        } else if let move = wallGapMove(turned, others: others) {
            shift += move
            kind = .wallGap
        }
        return AlignPlacement(delta: delta(angle: angle, shift: shift, pivot: pivot, roomID: moving.roomID), snap: kind)
    }

    /// Rotation by `angle` about `pivot`, then the plan move `shift`, as one `.user` record.
    static func delta(angle: Float, shift: SIMD2<Float>, pivot: SIMD2<Float>, roomID: UUID) -> RoomAlignmentRecord {
        let turn = StructureAlignment.rotation(by: angle, about: pivot, roomID: roomID)
        let move = StructureAlignment.translation(by: shift, roomID: roomID)
        return StructureAlignment.compose(move, after: turn, source: .user)
    }

    /// The smallest extra turn (radians, within `angleSnapDegrees`) that makes a wall of the
    /// moving shape, turned by `rotation`, parallel or perpendicular to a wall of `others`.
    static func parallelCorrection(_ moving: AlignShape, rotation: Float, others: [AlignShape]) -> Float? {
        let limit = angleSnapDegrees * Float.pi / 180
        var best: Float?
        for wall in moving.walls where simd_distance(wall.start, wall.end) >= minimumSnapWall {
            let own = direction(of: wall) + rotation
            for other in others {
                for target in other.walls where simd_distance(target.start, target.end) >= minimumSnapWall {
                    let difference = quarterWrapped(direction(of: target) - own)
                    guard abs(difference) <= limit else { continue }
                    if let current = best, abs(current) <= abs(difference) { continue }
                    best = difference
                }
            }
        }
        return best
    }

    /// The move that lines up the nearest pair of door centers within `doorSnapDistance`.
    static func doorwayMove(_ turned: AlignShape, others: [AlignShape]) -> SIMD2<Float>? {
        var best: (move: SIMD2<Float>, distance: Float)?
        for door in turned.doors {
            for other in others {
                for target in other.doors {
                    let distance = simd_distance(door, target)
                    guard distance <= doorSnapDistance else { continue }
                    if let current = best, current.distance <= distance { continue }
                    let move = doorMove(door, in: turned, onto: target, in: other)
                    best = (move: move, distance: distance)
                }
            }
        }
        return best?.move
    }

    /// Move for one door pair: along the target's host wall onto the target and across to an
    /// `assumedWallThickness` gap when both host walls are antiparallel; else onto the target.
    static func doorMove(_ door: SIMD2<Float>, in shape: AlignShape, onto target: SIMD2<Float>,
                         in other: AlignShape) -> SIMD2<Float> {
        let limit = cos(antiparallelToleranceDegrees * Float.pi / 180)
        guard let own = hostWall(of: door, in: shape), let host = hostWall(of: target, in: other),
              simd_dot(own.inward, host.inward) <= -limit else { return target - door }
        let length = simd_distance(host.start, host.end)
        guard length > 1e-6 else { return target - door }
        let along = (host.end - host.start) / length
        let across = simd_dot(door - host.start, host.inward)
        let slide = along * simd_dot(target - door, along)
        return slide + host.inward * (-assumedWallThickness - across)
    }

    /// The move that brings the nearest antiparallel wall pair (faces within `wallSnapDistance`,
    /// overlapping along the wall) to an `assumedWallThickness` gap, the moving face behind the
    /// other.
    static func wallGapMove(_ turned: AlignShape, others: [AlignShape]) -> SIMD2<Float>? {
        let limit = cos(antiparallelToleranceDegrees * Float.pi / 180)
        var best: (move: SIMD2<Float>, score: Float)?
        for wall in turned.walls where simd_distance(wall.start, wall.end) >= minimumSnapWall {
            let middle = (wall.start + wall.end) * 0.5
            for other in others {
                for target in other.walls {
                    let length = simd_distance(target.start, target.end)
                    guard length >= minimumSnapWall, simd_dot(wall.inward, target.inward) <= -limit else { continue }
                    let across = simd_dot(middle - target.start, target.inward)
                    guard abs(across) <= wallSnapDistance else { continue }
                    let along = (target.end - target.start) / length
                    let t0 = simd_dot(wall.start - target.start, along)
                    let t1 = simd_dot(wall.end - target.start, along)
                    let overlap = Swift.min(length, Swift.max(t0, t1)) - Swift.max(0, Swift.min(t0, t1))
                    guard overlap > 0 else { continue }
                    let score = abs(across)
                    if let current = best, current.score <= score { continue }
                    best = (move: target.inward * (-assumedWallThickness - across), score: score)
                }
            }
        }
        return best?.move
    }

    /// The wall of `shape` whose segment is nearest to `point` within `hostWallTolerance`.
    static func hostWall(of point: SIMD2<Float>, in shape: AlignShape) -> AlignWall? {
        var best: (wall: AlignWall, distance: Float)?
        for wall in shape.walls {
            let distance = Segment2D(a: wall.start, b: wall.end).distance(to: point)
            guard distance <= hostWallTolerance else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (wall: wall, distance: distance)
        }
        return best?.wall
    }

    /// Plan direction angle of a wall, radians counter-clockwise from plan +x.
    static func direction(of wall: AlignWall) -> Float {
        let d = wall.end - wall.start
        return atan2(d.y, d.x)
    }

    /// An angle wrapped into (-pi/4, pi/4] (walls repeat every 90 degrees for this snap).
    static func quarterWrapped(_ angle: Float) -> Float {
        guard angle.isFinite else { return 0 }
        let quarter = Float.pi / 2
        var a = angle.truncatingRemainder(dividingBy: quarter)
        if a > quarter / 2 { a -= quarter }
        if a <= -quarter / 2 { a += quarter }
        return a
    }
}
