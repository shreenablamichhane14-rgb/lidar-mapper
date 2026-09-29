import Foundation
import simd

// Rigid room placement (D9, docs/MODULES.md 3.30): a yaw about world +Y followed by a world
// translation. Plan coordinates are `PlanAxes` (plan x = world x, plan y = -world z), so a
// positive yaw turns counter-clockwise both seen from above and in plan coordinates. Pure
// functions, nonisolated, deterministic, safe on any queue. Moving clean rooms and the stacked
// room check are in StructureAlignment+Room.swift.

/// One surface (wall, door, window or opening) found both in a room's own capture and in the
/// merged structure: plan segment endpoints and the surface center height (world y).
struct AlignmentSegmentPair: Equatable, Sendable {
    /// Start of the surface in the room's own capture, plan meters.
    var beforeStart: SIMD2<Float>
    /// End of the surface in the room's own capture, plan meters.
    var beforeEnd: SIMD2<Float>
    /// Center height in the room's own capture, world y meters.
    var beforeY: Float
    /// Start of the same surface in the merged structure, plan meters.
    var afterStart: SIMD2<Float>
    /// End of the same surface in the merged structure, plan meters.
    var afterEnd: SIMD2<Float>
    /// Center height in the merged structure, world y meters.
    var afterY: Float

    /// Creates a pair from both captures of one surface.
    init(beforeStart: SIMD2<Float>, beforeEnd: SIMD2<Float>, beforeY: Float,
         afterStart: SIMD2<Float>, afterEnd: SIMD2<Float>, afterY: Float) {
        self.beforeStart = beforeStart
        self.beforeEnd = beforeEnd
        self.beforeY = beforeY
        self.afterStart = afterStart
        self.afterEnd = afterEnd
        self.afterY = afterY
    }

    /// Weight in the solve: the length of the before segment, meters.
    var weight: Float { simd_distance(beforeStart, beforeEnd) }
}

/// A rigid placement solved from segment pairs.
struct AlignmentSolution: Equatable, Sendable {
    /// Rotation about world +Y, radians.
    var yaw: Float
    /// World translation, meters (y is the weighted median height change).
    var translation: SIMD3<Float>
    /// Root mean square plan distance of the matched endpoints after the transform, meters.
    var rms: Float
    /// Segment pairs used.
    var matches: Int

    /// The Core record for a room (Core `RoomAlignmentRecord`, translation as `Vec3`).
    func record(roomID: UUID, source: Provenance) -> RoomAlignmentRecord {
        RoomAlignmentRecord(roomID: roomID, yaw: yaw, translation: Vec3(translation), source: source)
    }

    /// True with at least `StructureAlignment.minimumMatches` pairs and a finite rms of at most
    /// `StructureAlignment.maxTrustedRMS`.
    var isTrusted: Bool {
        matches >= StructureAlignment.minimumMatches && rms.isFinite && rms <= StructureAlignment.maxTrustedRMS
    }
}

/// Least-squares room placement and the rigid transform algebra of `RoomAlignmentRecord`.
enum StructureAlignment {
    /// A solve is trusted only with at least `minimumMatches` pairs and rms at most this, meters.
    static let maxTrustedRMS: Float = 0.05
    /// Fewest segment pairs a trusted solve needs.
    static let minimumMatches = 2
    /// Midpoints closer than this to each other cannot fix a rotation, meters.
    static let minimumSpread: Float = 0.01

    // MARK: Solve

    /// Weighted 2D Procrustes (D9). Pass 1 solves yaw and translation from segment midpoints;
    /// pass 2 orders each pair's after endpoints to agree with the pass 1 rotation (RoomPlan's
    /// `columns.0` sign is arbitrary) and solves again on all endpoints. Nil with fewer than 2
    /// pairs or when the midpoints are all within 1 cm of each other.
    static func solve(_ pairs: [AlignmentSegmentPair]) -> AlignmentSolution? {
        let usable = pairs.filter { pair in
            let values: [Float] = [pair.beforeStart.x, pair.beforeStart.y, pair.beforeEnd.x, pair.beforeEnd.y,
                                   pair.afterStart.x, pair.afterStart.y, pair.afterEnd.x, pair.afterEnd.y,
                                   pair.beforeY, pair.afterY]
            return values.allSatisfy { $0.isFinite } && pair.weight > 1e-4
        }
        guard usable.count >= 2 else { return nil }
        let beforeMid = usable.map { ($0.beforeStart + $0.beforeEnd) * 0.5 }
        let afterMid = usable.map { ($0.afterStart + $0.afterEnd) * 0.5 }
        let weights = usable.map { $0.weight }
        guard spread(beforeMid) > minimumSpread, spread(afterMid) > minimumSpread,
              let first = weightedFit(from: beforeMid, to: afterMid, weights: weights) else { return nil }

        var from: [SIMD2<Float>] = []
        var to: [SIMD2<Float>] = []
        var endpointWeights: [Float] = []
        for pair in usable {
            let turned = rotate(pair.beforeEnd - pair.beforeStart, by: first.angle)
            let along = pair.afterEnd - pair.afterStart
            let agrees = simd_dot(turned, along) >= 0
            from.append(pair.beforeStart)
            from.append(pair.beforeEnd)
            to.append(agrees ? pair.afterStart : pair.afterEnd)
            to.append(agrees ? pair.afterEnd : pair.afterStart)
            endpointWeights.append(pair.weight)
            endpointWeights.append(pair.weight)
        }
        guard let second = weightedFit(from: from, to: to, weights: endpointWeights) else { return nil }
        var squared: Double = 0
        for i in from.indices {
            let moved = rotate(from[i], by: second.angle) + second.translation
            squared += Double(simd_distance_squared(moved, to[i]))
        }
        let rms = Float((squared / Double(Swift.max(1, from.count))).squareRoot())
        let heights = usable.map { $0.afterY - $0.beforeY }
        let rise = weightedMedian(heights, weights: weights) ?? 0
        let translation = SIMD3<Float>(second.translation.x, rise, -second.translation.y)
        return AlignmentSolution(yaw: wrapped(second.angle), translation: translation, rms: rms, matches: usable.count)
    }

    /// Pairs for one room: every wall, door, window and opening of `room` (its own capture,
    /// RoomModel `RoomInput`) whose identifier appears in `structure` (see
    /// `StructureSurfaces.index`), with endpoints from RoomModel `RoomOutline.surfaceEndpoints`
    /// and heights from the surface transforms. Surfaces without endpoints are skipped.
    static func pairs(room: RoomInput, structure: [UUID: SurfaceInput]) -> [AlignmentSegmentPair] {
        var result: [AlignmentSegmentPair] = []
        for surface in room.walls + room.openings {
            guard let merged = structure[surface.identifier],
                  let before = RoomOutline.surfaceEndpoints(surface),
                  let after = RoomOutline.surfaceEndpoints(merged) else { continue }
            let beforeY = surface.transform.translation.y
            let afterY = merged.transform.translation.y
            guard beforeY.isFinite, afterY.isFinite else { continue }
            result.append(AlignmentSegmentPair(beforeStart: before.start, beforeEnd: before.end, beforeY: beforeY,
                                               afterStart: after.start, afterEnd: after.end, afterY: afterY))
        }
        return result
    }

    /// Component-wise median of yaw and translation over trusted solutions (the caller passes
    /// only trusted ones); nil when empty. Yaws are unwrapped around the first one before the
    /// median; rms is the median rms and matches the smallest count.
    static func median(_ solutions: [AlignmentSolution]) -> AlignmentSolution? {
        guard let first = solutions.first else { return nil }
        let yaws = solutions.map { first.yaw + wrapped($0.yaw - first.yaw) }
        guard let yaw = plainMedian(yaws),
              let x = plainMedian(solutions.map { $0.translation.x }),
              let y = plainMedian(solutions.map { $0.translation.y }),
              let z = plainMedian(solutions.map { $0.translation.z }),
              let rms = plainMedian(solutions.map { $0.rms }) else { return nil }
        let matches = solutions.map { $0.matches }.min() ?? 0
        return AlignmentSolution(yaw: wrapped(yaw), translation: SIMD3<Float>(x, y, z), rms: rms, matches: matches)
    }

    // MARK: Record algebra

    /// Rotation about +Y by `record.yaw` (column-major: column 0 = (cos, 0, -sin, 0), column 2 =
    /// (sin, 0, cos, 0)), then translation by `record.translation`.
    static func matrix(_ record: RoomAlignmentRecord) -> simd_float4x4 {
        let c = cos(record.yaw)
        let s = sin(record.yaw)
        let t = record.translation
        return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0),
                                       SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(s, 0, c, 0),
                                       SIMD4<Float>(t.x, t.y, t.z, 1)))
    }

    /// A world point moved by the record: rotation about +Y, then translation.
    static func transform(_ point: SIMD3<Float>, by record: RoomAlignmentRecord) -> SIMD3<Float> {
        rotateWorld(point, yaw: record.yaw) + record.translation.simd
    }

    /// The same placement in plan coordinates: counter-clockwise rotation by yaw, then
    /// (translation.x, -translation.z).
    static func planTransform(_ point: SIMD2<Float>, by record: RoomAlignmentRecord) -> SIMD2<Float> {
        let turned = rotate(point, by: record.yaw)
        return SIMD2<Float>(turned.x + record.translation.x, turned.y - record.translation.z)
    }

    /// The record that leaves every point where it is.
    static func identity(roomID: UUID, source: Provenance) -> RoomAlignmentRecord {
        RoomAlignmentRecord(roomID: roomID, yaw: 0, translation: .zero, source: source)
    }

    /// The record that undoes `record` (same room and source).
    static func inverse(_ record: RoomAlignmentRecord) -> RoomAlignmentRecord {
        let back = rotateWorld(record.translation.simd, yaw: -record.yaw)
        return RoomAlignmentRecord(roomID: record.roomID, yaw: wrapped(-record.yaw), translation: Vec3(-back),
                                   source: record.source)
    }

    /// `inner` first, then `outer`; the result keeps `inner.roomID`.
    static func compose(_ outer: RoomAlignmentRecord, after inner: RoomAlignmentRecord, source: Provenance) -> RoomAlignmentRecord {
        let moved = transform(inner.translation.simd, by: outer)
        return RoomAlignmentRecord(roomID: inner.roomID, yaw: wrapped(outer.yaw + inner.yaw), translation: Vec3(moved),
                                   source: source)
    }

    /// A plan rotation about `pivot` expressed as a record (manual alignment turns rooms about
    /// their own centroid). Source `.user`.
    static func rotation(by angle: Float, about pivot: SIMD2<Float>, roomID: UUID) -> RoomAlignmentRecord {
        let shift = pivot - rotate(pivot, by: angle)
        return RoomAlignmentRecord(roomID: roomID, yaw: wrapped(angle), translation: Vec3(x: shift.x, y: 0, z: -shift.y),
                                   source: .user)
    }

    /// A plan move expressed as a record (world y unchanged). Source `.user`.
    static func translation(by delta: SIMD2<Float>, roomID: UUID) -> RoomAlignmentRecord {
        RoomAlignmentRecord(roomID: roomID, yaw: 0, translation: Vec3(x: delta.x, y: 0, z: -delta.y), source: .user)
    }

    // MARK: Helpers

    /// A plan vector turned counter-clockwise by `angle` radians.
    static func rotate(_ v: SIMD2<Float>, by angle: Float) -> SIMD2<Float> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2<Float>(c * v.x - s * v.y, s * v.x + c * v.y)
    }

    /// A world vector turned about +Y by `yaw` (the rotation part of `matrix`).
    static func rotateWorld(_ v: SIMD3<Float>, yaw: Float) -> SIMD3<Float> {
        let c = cos(yaw)
        let s = sin(yaw)
        return SIMD3<Float>(c * v.x + s * v.z, v.y, -s * v.x + c * v.z)
    }

    /// An angle wrapped into (-pi, pi].
    static func wrapped(_ angle: Float) -> Float {
        guard angle.isFinite else { return 0 }
        let full = 2 * Float.pi
        var a = angle.truncatingRemainder(dividingBy: full)
        if a > Float.pi { a -= full }
        if a <= -Float.pi { a += full }
        return a
    }

    /// Largest distance of any point from the first one (0 for fewer than 2 points), a cheap
    /// stand-in for "all within 1 cm of each other".
    static func spread(_ points: [SIMD2<Float>]) -> Float {
        guard let first = points.first else { return 0 }
        var largest: Float = 0
        for p in points { largest = Swift.max(largest, simd_distance(p, first)) }
        return largest
    }

    /// Weighted least-squares rotation and translation mapping `from` onto `to` (2D Procrustes
    /// without scale): angle = atan2(sum w cross(b, a), sum w dot(b, a)) over centered points.
    /// Nil when the weights sum to zero or the points give no direction.
    static func weightedFit(from: [SIMD2<Float>], to: [SIMD2<Float>],
                            weights: [Float]) -> (angle: Float, translation: SIMD2<Float>)? {
        guard from.count == to.count, from.count == weights.count, !from.isEmpty else { return nil }
        var total: Double = 0
        var fromCenter = SIMD2<Double>(0, 0)
        var toCenter = SIMD2<Double>(0, 0)
        for i in from.indices {
            let w = Double(weights[i])
            total += w
            fromCenter += SIMD2<Double>(Double(from[i].x), Double(from[i].y)) * w
            toCenter += SIMD2<Double>(Double(to[i].x), Double(to[i].y)) * w
        }
        guard total > 1e-12 else { return nil }
        fromCenter /= total
        toCenter /= total
        var dotSum: Double = 0
        var crossSum: Double = 0
        for i in from.indices {
            let w = Double(weights[i])
            let b = SIMD2<Double>(Double(from[i].x), Double(from[i].y)) - fromCenter
            let a = SIMD2<Double>(Double(to[i].x), Double(to[i].y)) - toCenter
            dotSum += w * (b.x * a.x + b.y * a.y)
            crossSum += w * (b.x * a.y - b.y * a.x)
        }
        guard abs(dotSum) + abs(crossSum) > 1e-12 else { return nil }
        let angle = atan2(crossSum, dotSum)
        let c = cos(angle)
        let s = sin(angle)
        let turnedX = c * fromCenter.x - s * fromCenter.y
        let turnedY = s * fromCenter.x + c * fromCenter.y
        let shift = SIMD2<Float>(Float(toCenter.x - turnedX), Float(toCenter.y - turnedY))
        return (angle: Float(angle), translation: shift)
    }

    /// Weighted median: the smallest value at which the running weight reaches half the total
    /// (values sorted ascending). Nil when empty or when the weights sum to zero.
    static func weightedMedian(_ values: [Float], weights: [Float]) -> Float? {
        guard values.count == weights.count, !values.isEmpty else { return nil }
        let order = values.indices.sorted { values[$0] != values[$1] ? values[$0] < values[$1] : $0 < $1 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var running: Float = 0
        for i in order {
            running += weights[i]
            if running >= total * 0.5 { return values[i] }
        }
        return order.last.map { values[$0] }
    }

    /// Plain median (mean of the two middle values for an even count); nil when empty.
    static func plainMedian(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) * 0.5
    }
}
