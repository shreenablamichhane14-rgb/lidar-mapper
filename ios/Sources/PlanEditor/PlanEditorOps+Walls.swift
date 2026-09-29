import Foundation
import simd

/// Wall geometry of the plan editor mapping: joined wall ends, the paired face of a shared wall,
/// the ends of a moved wall, the orientation of a drawn wall, and the validation of every wall end
/// an action moves (docs/MODULES.md 3.37, rules "Mapping").
extension PlanEditorOps {
    /// One wall end an action moves, in plan meters.
    typealias EndMove = (wall: ElementID, atStart: Bool, to: SIMD2<Float>)

    /// Probe distance on each side of a drawn wall when deciding which side its room is on,
    /// meters (the same probe `CleanModel.apply(.addWall)` uses).
    static let sideProbe: Float = 0.1

    /// The ends of other walls on the level within `jointTolerance` of the given end.
    static func joined(_ wall: ElementID, atStart: Bool, in level: PlanLevel) -> [(wall: ElementID, atStart: Bool)] {
        guard let moved = level.walls.first(where: { $0.id == wall }) else { return [] }
        let end = atStart ? moved.a.simd : moved.b.simd
        var result: [(wall: ElementID, atStart: Bool)] = []
        for other in level.walls where other.id != wall {
            if simd_distance(other.a.simd, end) <= jointTolerance { result.append((wall: other.id, atStart: true)) }
            if simd_distance(other.b.simd, end) <= jointTolerance { result.append((wall: other.id, atStart: false)) }
        }
        return result
    }

    /// The other room's face of a shared wall, or nil: a straight wall antiparallel within
    /// `pairedAngleDegrees`, lying on the body side (right) of `wall` no farther than the larger of
    /// the two thicknesses plus `pairedGapSlack`, and overlapping it by at least half of the shorter
    /// length. The nearest such wall wins.
    static func pairedWall(of wall: PlanWall, in level: PlanLevel) -> PlanWall? {
        guard wall.arc == nil, let frame = unitFrame(wall) else { return nil }
        let cosLimit = cos(pairedAngleDegrees * Float.pi / 180)
        var best: PlanWall?
        var bestGap = Float.greatestFiniteMagnitude
        for other in level.walls where other.id != wall.id && other.arc == nil {
            guard let otherFrame = unitFrame(other), simd_dot(frame.u, otherFrame.u) <= -cosLimit else { continue }
            let p = other.a.simd
            let q = other.b.simd
            let middle = (p + q) * 0.5
            let offset = simd_dot(middle - wall.a.simd, frame.n)
            let limit = max(finiteThickness(wall), finiteThickness(other)) + pairedGapSlack
            guard offset <= jointTolerance, -offset <= limit else { continue }
            let s0 = simd_dot(p - wall.a.simd, frame.u)
            let s1 = simd_dot(q - wall.a.simd, frame.u)
            let overlap = min(frame.length, max(s0, s1)) - max(0, min(s0, s1))
            guard overlap >= 0.5 * min(frame.length, otherFrame.length) else { continue }
            let gap = abs(offset)
            if gap < bestGap {
                bestGap = gap
                best = other
            }
        }
        return best
    }

    /// New ends of `wall` moved by `distance` along its left normal: each end is the intersection of the
    /// moved line with the most non-parallel wall joined there, else the translated end.
    static func movedEnds(_ wall: PlanWall, by distance: Float, in level: PlanLevel) -> (a: SIMD2<Float>, b: SIMD2<Float>) {
        let a = wall.a.simd
        let b = wall.b.simd
        guard distance.isFinite, let frame = unitFrame(wall) else { return (a, b) }
        let shift = frame.n * distance
        let movedA = a + shift
        let sineLimit = sin(parallelLimitDegrees * Float.pi / 180)
        /// The corner point at one end of the moved wall.
        func corner(atStart: Bool) -> SIMD2<Float> {
            var result = (atStart ? a : b) + shift
            var bestSine = sineLimit
            for end in joined(wall.id, atStart: atStart, in: level) {
                guard let other = level.walls.first(where: { $0.id == end.wall }),
                      let otherFrame = unitFrame(other) else { continue }
                let denominator = Segment2D.cross(frame.u, otherFrame.u)
                let sine = abs(denominator)
                guard sine > bestSine else { continue }
                let t = Segment2D.cross(other.a.simd - movedA, otherFrame.u) / denominator
                let point = movedA + frame.u * t
                guard isFinite(point) else { continue }
                bestSine = sine
                result = point
            }
            return result
        }
        return (corner(atStart: true), corner(atStart: false))
    }

    /// A drawn wall ordered so the room containing its midpoint (else the nearest room) is on its left
    /// when only one side is inside that room; kept as drawn when both or neither side is inside. This
    /// matches the normal rule of `CleanModel.apply(.addWall)`, so the clean normal is the left normal.
    static func oriented(a: SIMD2<Float>, b: SIMD2<Float>, in level: PlanLevel) -> (a: SIMD2<Float>, b: SIMD2<Float>) {
        let d = b - a
        let length = simd_length(d)
        guard length > 1e-6, let room = hostRoom(of: (a + b) * 0.5, in: level) else { return (a, b) }
        let middle = (a + b) * 0.5
        let left = SIMD2<Float>(-d.y, d.x) / length
        let leftInside = roomContains(room, middle + left * sideProbe)
        let rightInside = roomContains(room, middle - left * sideProbe)
        if !leftInside && rightInside { return (a: b, b: a) }
        return (a, b)
    }

    /// The room whose outline or merged outline contains `point`, else the room whose outline
    /// centroid is nearest (the host rule of `CleanModel.apply(.addWall)`).
    static func hostRoom(of point: SIMD2<Float>, in level: PlanLevel) -> PlanRoom? {
        if let inside = level.rooms.first(where: { roomContains($0, point) }) { return inside }
        var best: PlanRoom?
        var bestDistance = Float.greatestFiniteMagnitude
        for room in level.rooms where room.outline.count >= 3 {
            let centroid = Polygon2D(points: room.outline.map { $0.simd }).centroid
            let distance = simd_distance(centroid, point)
            if distance < bestDistance {
                bestDistance = distance
                best = room
            }
        }
        return best
    }

    /// True when a plan point lies inside any part of the room.
    static func roomContains(_ room: PlanRoom, _ point: SIMD2<Float>) -> Bool {
        PlanBuilder.parts(of: room).contains { part in
            part.count >= 3 && Polygon2D(points: part).contains(point: point)
        }
    }

    // MARK: - Mapped wall actions

    /// Move Wall: both ends of `wall` to `movedEnds`, every joined end to the same corner point,
    /// and the paired wall (when any) moved by `-distance` the same way.
    static func moveWallOperations(_ wall: PlanWall, by distance: Float, in level: PlanLevel,
                                   context: PlanEditorContext) throws -> [EditOperation] {
        var moves: [EndMove] = []
        try appendWallMove(wall, by: distance, in: level, context: context, into: &moves)
        if let paired = pairedWall(of: wall, in: level) {
            guard !context.lockedWalls.contains(paired.id) else { throw PlanEditorError.lockedWall }
            try appendWallMove(paired, by: -distance, in: level, context: context, into: &moves)
        }
        return try validated(moves, in: level)
    }

    /// Drag one wall end: the end and every end joined there move to `point`.
    static func moveWallEndOperations(_ wall: PlanWall, atStart: Bool, to point: SIMD2<Float>, in level: PlanLevel,
                                      context: PlanEditorContext) throws -> [EditOperation] {
        guard isFinite(point) else { throw PlanEditorError.outOfRange }
        var moves: [EndMove] = [(wall: wall.id, atStart: atStart, to: point)]
        for end in joined(wall.id, atStart: atStart, in: level) {
            try checkMovable(end.wall, in: level, context: context)
            add((wall: end.wall, atStart: end.atStart, to: point), to: &moves)
        }
        return try validated(moves, in: level)
    }

    /// Wall Length: with a non-parallel wall joined at `b`, that wall moves sideways so `b` lands
    /// `length` from `a`; else `b` (and the parallel walls joined there) moves along the wall.
    static func wallLengthOperations(_ wall: PlanWall, length: Float, in level: PlanLevel,
                                     context: PlanEditorContext) throws -> [EditOperation] {
        guard let frame = unitFrame(wall) else { throw PlanEditorError.tooShort }
        let sineLimit = sin(parallelLimitDegrees * Float.pi / 180)
        var hinge: PlanWall?
        var bestSine = sineLimit
        for end in joined(wall.id, atStart: false, in: level) {
            guard let other = level.walls.first(where: { $0.id == end.wall }), let otherFrame = unitFrame(other) else { continue }
            let sine = abs(Segment2D.cross(frame.u, otherFrame.u))
            if sine > bestSine {
                bestSine = sine
                hinge = other
            }
        }
        if let hinge, let hingeFrame = unitFrame(hinge) {
            let movable = try straightWall(hinge.id, in: level, context: context)
            let change: SIMD2<Float> = frame.u * (length - frame.length)
            let distance = simd_dot(change, hingeFrame.n)
            return try moveWallOperations(movable, by: distance, in: level, context: context)
        }
        let target = wall.a.simd + frame.u * length
        return try moveWallEndOperations(wall, atStart: false, to: target, in: level, context: context)
    }

    // MARK: - Helpers

    /// Adds the end moves of one moved wall: its two ends and every end joined to them.
    private static func appendWallMove(_ wall: PlanWall, by distance: Float, in level: PlanLevel,
                                       context: PlanEditorContext, into moves: inout [EndMove]) throws {
        try checkMovable(wall.id, in: level, context: context)
        let ends = movedEnds(wall, by: distance, in: level)
        add((wall: wall.id, atStart: true, to: ends.a), to: &moves)
        add((wall: wall.id, atStart: false, to: ends.b), to: &moves)
        let corners: [(atStart: Bool, point: SIMD2<Float>)] = [(atStart: true, point: ends.a), (atStart: false, point: ends.b)]
        for corner in corners {
            for end in joined(wall.id, atStart: corner.atStart, in: level) {
                try checkMovable(end.wall, in: level, context: context)
                add((wall: end.wall, atStart: end.atStart, to: corner.point), to: &moves)
            }
        }
    }

    /// Appends a move unless the same wall end is already listed (the first one wins).
    private static func add(_ move: EndMove, to moves: inout [EndMove]) {
        guard !moves.contains(where: { $0.wall == move.wall && $0.atStart == move.atStart }) else { return }
        moves.append(move)
    }

    /// A wall whose ends an action may move: present, not locked, straight.
    private static func checkMovable(_ id: ElementID, in level: PlanLevel, context: PlanEditorContext) throws {
        guard let wall = level.walls.first(where: { $0.id == id }) else { throw PlanEditorError.notFound }
        guard !context.lockedWalls.contains(id) else { throw PlanEditorError.lockedWall }
        guard wall.arc == nil else { throw PlanEditorError.curvedWall }
    }

    /// The operations of some end moves after checking every moved wall: finite ends (else
    /// `.outOfRange`), at least `minimumWallLength` long and not reversed (dot of the old and new
    /// directions above 0; else `.tooShort`).
    static func validated(_ moves: [EndMove], in level: PlanLevel) throws -> [EditOperation] {
        var ends: [ElementID: (a: SIMD2<Float>, b: SIMD2<Float>)] = [:]
        var order: [ElementID] = []
        for move in moves {
            guard isFinite(move.to) else { throw PlanEditorError.outOfRange }
            guard let wall = level.walls.first(where: { $0.id == move.wall }) else { throw PlanEditorError.notFound }
            var current = ends[move.wall] ?? (a: wall.a.simd, b: wall.b.simd)
            if ends[move.wall] == nil { order.append(move.wall) }
            if move.atStart {
                current.a = move.to
            } else {
                current.b = move.to
            }
            ends[move.wall] = current
        }
        for id in order {
            guard let wall = level.walls.first(where: { $0.id == id }), let moved = ends[id] else { continue }
            let before = wall.b.simd - wall.a.simd
            let after = moved.b - moved.a
            guard simd_length(after) >= minimumWallLength, simd_dot(before, after) > 0 else { throw PlanEditorError.tooShort }
        }
        return moves.map { EditOperation.moveWallEndpoint(wall: $0.wall, atStart: $0.atStart, to: Vec2($0.to)) }
    }

    /// Unit direction, left normal and length of a wall's a -> b line; nil when it is degenerate
    /// or not finite.
    static func unitFrame(_ wall: PlanWall) -> (u: SIMD2<Float>, n: SIMD2<Float>, length: Float)? {
        let d = wall.b.simd - wall.a.simd
        let length = simd_length(d)
        guard length.isFinite, length > 1e-6 else { return nil }
        let u = d / length
        return (u: u, n: SIMD2<Float>(-u.y, u.x), length: length)
    }

    /// A wall's thickness, 0 when it is not finite or negative.
    static func finiteThickness(_ wall: PlanWall) -> Float {
        wall.thickness.isFinite ? max(0, wall.thickness) : 0
    }
}
