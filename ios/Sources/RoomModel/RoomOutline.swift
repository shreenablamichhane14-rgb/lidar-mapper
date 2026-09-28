import Foundation
import simd

/// One RoomPlan wall as a plan segment (`PlanAxes` meters) with the values the clean model
/// needs. `start` and `end` come from the wall transform; after `RoomOutline.build` the loop
/// walls run counter-clockwise (room on the left) with their corners intersected.
struct WallSegment: Equatable, Sendable {
    /// Element id, `ElementID.derived(fromRoomPlan:)` of the RoomPlan wall identifier.
    var id: ElementID
    /// Start point, plan meters.
    var start: SIMD2<Float>
    /// End point, plan meters.
    var end: SIMD2<Float>
    /// World Y of the wall bottom, meters.
    var baseY: Float
    /// Wall height, meters.
    var height: Float
    /// RoomPlan detection confidence.
    var confidence: DetectionConfidence
    /// Number of edges RoomPlan marked complete, 0...4.
    var completedEdges: Int
    /// Arc of a curved wall (world center at `baseY`, plan angles), nil when straight.
    var arc: WallArc?

    /// Straight distance from start to end, meters.
    var length: Float { simd_distance(start, end) }

    /// Unit direction from start to end, or zero for a degenerate segment.
    var direction: SIMD2<Float> {
        let d = end - start
        let l = simd_length(d)
        return l > 1e-6 ? d / l : .zero
    }

    /// The same wall traversed the other way (start and end swapped, arc unchanged).
    var reversed: WallSegment {
        var swapped = self
        swapped.start = end
        swapped.end = start
        return swapped
    }
}

/// The room outline built from the wall loop (D12).
struct OutlineResult: Equatable, Sendable {
    /// Outline, counter-clockwise, plan meters (curved walls contribute arc samples). When the
    /// loop does not close this is the floor polygon, else the hull of the wall endpoints, else
    /// empty.
    var polygon: [SIMD2<Float>]
    /// Loop order, a to b counter-clockwise (room on the left), corners intersected. When the
    /// loop does not close: every wall segment unchanged, in input order.
    var walls: [WallSegment]
    /// Stubs and partitions not in the loop (unchanged segments, input order).
    var strayWalls: [WallSegment]
    /// True when a closed wall loop was found.
    var isClosed: Bool
    /// |loop area - floor polygon area| / loop area (cross-check only); nil without a closed
    /// loop or a floor polygon.
    var floorPolygonMismatch: Float?
}

/// Builds the room outline from RoomPlan walls (D12): the one outline shared by Quality,
/// `CleanModelBuilder` and FloorPlan's `PlanBuilder`. Pure functions, safe on any queue.
enum RoomOutline {
    /// Endpoints closer than this are joined into one corner, meters.
    static let joinTolerance: Float = 0.15
    /// Adjacent walls closer than this to parallel are joined at their endpoint midpoint
    /// instead of by line intersection, degrees.
    static let parallelLimitDegrees: Float = 10
    /// Walls shorter than this are ignored (logged), meters.
    static let minimumWallLength: Float = 0.05
    /// A line intersection farther than this from the joined endpoints is rejected in favor of
    /// their midpoint, meters.
    static let maxCornerShift: Float = 0.5
    /// Largest angle between two outline samples of a curved wall, degrees.
    static let arcStepDegrees: Float = 10
    /// Smallest loop area accepted as a room, square meters.
    static let minimumLoopArea: Float = 0.25
    /// Log category.
    static let logCategory = "roommodel"

    /// Endpoints transform * (+-dimensions.x / 2, 0, 0, 1); horizontal projection of columns.0
    /// when abs(columns.1.y) < 0.99 (logged).
    static func wallSegments(_ input: RoomInput) -> [WallSegment] {
        input.walls.compactMap { segment(for: $0) }
    }

    /// The plan segment of one wall surface, or nil when it is degenerate (logged).
    static func segment(for wall: SurfaceInput) -> WallSegment? {
        guard let ends = surfaceEndpoints(wall) else {
            LogStore.shared.write("wall \(wall.identifier) skipped: degenerate transform", category: logCategory)
            return nil
        }
        let height = wall.dimensions.y
        let centerY = wall.transform.translation.y
        guard height.isFinite, centerY.isFinite else {
            LogStore.shared.write("wall \(wall.identifier) skipped: non-finite height", category: logCategory)
            return nil
        }
        guard simd_distance(ends.start, ends.end) >= minimumWallLength else {
            LogStore.shared.write("wall \(wall.identifier) skipped: shorter than \(minimumWallLength) m", category: logCategory)
            return nil
        }
        let baseY = centerY - height * 0.5
        var arc: WallArc?
        if let curve = wall.curve {
            arc = planArc(curve, transform: wall.transform.simd, baseY: baseY, straightStart: ends.start, straightEnd: ends.end)
        }
        return WallSegment(id: ElementID.derived(fromRoomPlan: wall.identifier), start: ends.start, end: ends.end,
                           baseY: baseY, height: Swift.max(0, height), confidence: wall.confidence,
                           completedEdges: wall.completedEdges, arc: arc)
    }

    /// Plan endpoints of a wall, door, window or opening surface: transform * (-+w/2, 0, 0, 1),
    /// or the horizontal projection of columns.0 around the center when the surface is tilted
    /// (abs(columns.1.y) < 0.99, logged). Nil for non-finite or degenerate transforms.
    static func surfaceEndpoints(_ surface: SurfaceInput) -> (start: SIMD2<Float>, end: SIMD2<Float>)? {
        let t = surface.transform.simd
        let half = surface.dimensions.x * 0.5
        guard half.isFinite else { return nil }
        let startWorld: SIMD3<Float>
        let endWorld: SIMD3<Float>
        if abs(t.columns.1.y) < 0.99 {
            let along = SIMD3<Float>(t.columns.0.x, 0, t.columns.0.z)
            let alongLength = simd_length(along)
            guard alongLength > 1e-4, alongLength.isFinite else { return nil }
            let unit = along / alongLength
            let center = surface.transform.translation
            startWorld = center - unit * half
            endWorld = center + unit * half
            LogStore.shared.write("surface \(surface.identifier) tilted (columns.1.y \(t.columns.1.y)); using horizontal projection",
                                  category: logCategory)
        } else {
            let s = t * SIMD4<Float>(-half, 0, 0, 1)
            let e = t * SIMD4<Float>(half, 0, 0, 1)
            startWorld = SIMD3<Float>(s.x, s.y, s.z)
            endWorld = SIMD3<Float>(e.x, e.y, e.z)
        }
        let a = PlanAxes.toPlan(startWorld)
        let b = PlanAxes.toPlan(endWorld)
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        return (a, b)
    }

    /// floors[0].polygonCorners through the floor transform, plan meters; nil when absent.
    /// A floor without corners uses its (width, depth) rectangle. Counter-clockwise.
    static func floorPolygon(_ input: RoomInput) -> [SIMD2<Float>]? {
        guard let floor = input.floors.first else { return nil }
        let t = floor.transform.simd
        var local: [SIMD3<Float>] = floor.polygonCorners.map { $0.simd }
        if local.count < 3 {
            let hx = floor.dimensions.x * 0.5
            let hy = floor.dimensions.y * 0.5
            guard hx > 0, hy > 0 else { return nil }
            local = [SIMD3<Float>(-hx, -hy, 0), SIMD3<Float>(hx, -hy, 0), SIMD3<Float>(hx, hy, 0), SIMD3<Float>(-hx, hy, 0)]
        }
        var points: [SIMD2<Float>] = []
        for corner in local {
            let w = t * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
            let p = PlanAxes.toPlan(SIMD3<Float>(w.x, w.y, w.z))
            guard p.x.isFinite, p.y.isFinite else { return nil }
            points.append(p)
        }
        let polygon = Polygon2D(points: points)
        guard polygon.area > 1e-4 else { return nil }
        return polygon.isClockwise ? Array(points.reversed()) : points
    }

    /// Builds the outline: joins endpoints within `joinTolerance`, keeps the closed loop with
    /// the largest area, intersects adjacent lines unless nearly parallel, sends stubs and
    /// partitions to `strayWalls` and orients the loop counter-clockwise from connectivity
    /// (never from `columns.0` signs). Without a closed loop it returns every wall, the floor
    /// polygon (or the hull of the wall endpoints) and `isClosed` false.
    static func build(_ input: RoomInput) -> OutlineResult {
        let segments = wallSegments(input)
        let floor = floorPolygon(input)
        guard let loop = RoomLoopFinder.findLoop(segments, tolerance: joinTolerance, minimumArea: minimumLoopArea) else {
            var polygon = floor ?? []
            if polygon.isEmpty, segments.count >= 3 {
                let hull = Polygon2D.convexHull(segments.flatMap { [$0.start, $0.end] })
                if hull.area > minimumLoopArea { polygon = hull.points }
            }
            return OutlineResult(polygon: polygon, walls: segments, strayWalls: [], isClosed: false,
                                 floorPolygonMismatch: nil)
        }
        var oriented = loop.map { step in step.reversed ? segments[step.wall].reversed : segments[step.wall] }
        if Polygon2D(points: oriented.map { $0.start }).signedArea < 0 {
            oriented = oriented.reversed().map { $0.reversed }
        }
        let count = oriented.count
        var corners: [SIMD2<Float>] = []
        corners.reserveCapacity(count)
        for i in 0..<count {
            corners.append(corner(oriented[(i + count - 1) % count], oriented[i]))
        }
        for i in 0..<count {
            oriented[i].start = corners[i]
            oriented[i].end = corners[(i + 1) % count]
        }
        var polygon: [SIMD2<Float>] = []
        for wall in oriented {
            if let arc = wall.arc {
                polygon.append(contentsOf: arcPoints(from: wall.start, to: wall.end, arc: arc).dropLast())
            } else {
                polygon.append(wall.start)
            }
        }
        polygon = removingDuplicates(polygon)
        if Polygon2D(points: polygon).isClockwise { polygon.reverse() }
        let used = Set(loop.map { $0.wall })
        let strays = segments.enumerated().filter { !used.contains($0.offset) }.map { $0.element }
        var mismatch: Float?
        let loopArea = Polygon2D(points: polygon).area
        if let floor, loopArea > 0 {
            mismatch = abs(loopArea - Polygon2D(points: floor).area) / loopArea
        }
        return OutlineResult(polygon: polygon, walls: oriented, strayWalls: strays, isClosed: true,
                             floorPolygonMismatch: mismatch)
    }

    /// Corner between a wall ending at a joint and the next wall starting there: the
    /// intersection of their lines, or the midpoint of the two endpoints when either wall is
    /// curved, they are within `parallelLimitDegrees` of parallel, or the intersection lies
    /// more than `maxCornerShift` away.
    static func corner(_ previous: WallSegment, _ next: WallSegment) -> SIMD2<Float> {
        let joint = (previous.end + next.start) * 0.5
        guard previous.arc == nil, next.arc == nil else { return joint }
        let first = Segment2D(a: previous.start, b: previous.end)
        let second = Segment2D(a: next.start, b: next.end)
        let angle = first.angle(between: second)
        let limit = parallelLimitDegrees * Float.pi / 180
        guard angle > limit, angle < Float.pi - limit else { return joint }
        guard let x = lineIntersection(first, second), simd_distance(x, joint) <= maxCornerShift else { return joint }
        return x
    }

    /// Intersection of the infinite lines through two segments, nil when parallel.
    static func lineIntersection(_ first: Segment2D, _ second: Segment2D) -> SIMD2<Float>? {
        let r = first.b - first.a
        let s = second.b - second.a
        let denominator = Segment2D.cross(r, s)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = Segment2D.cross(second.a - first.a, s) / denominator
        let point = first.a + r * t
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    /// Points along a curved wall from `a` to `b` (both included) on the side of the circle
    /// that `arc` covers, at most `arcStepDegrees` apart. The radius blends from |a - center|
    /// to |b - center| so the samples meet the (possibly moved) corners exactly.
    static func arcPoints(from a: SIMD2<Float>, to b: SIMD2<Float>, arc: WallArc) -> [SIMD2<Float>] {
        let center = PlanAxes.toPlan(arc.center.simd)
        let radiusA = simd_distance(a, center)
        let radiusB = simd_distance(b, center)
        guard radiusA > 1e-3, radiusB > 1e-3, arc.radius > 1e-3 else { return [a, b] }
        let alpha = atan2(a.y - center.y, a.x - center.x)
        let beta = atan2(b.y - center.y, b.x - center.x)
        let middle = (arc.startAngle + arc.endAngle) * 0.5
        let counterClockwise = positiveAngle(beta - alpha)
        let sweep: Float = positiveAngle(middle - alpha) <= counterClockwise
            ? counterClockwise : -(2 * Float.pi - counterClockwise)
        guard abs(sweep) > 1e-4 else { return [a, b] }
        let stepRadians = arcStepDegrees * Float.pi / 180
        let steps = Swift.max(1, Int((abs(sweep) / stepRadians).rounded(.up)))
        var points: [SIMD2<Float>] = [a]
        for i in 1..<steps {
            let f = Float(i) / Float(steps)
            let angle = alpha + sweep * f
            let radius = radiusA + (radiusB - radiusA) * f
            points.append(center + SIMD2<Float>(cos(angle), sin(angle)) * radius)
        }
        points.append(b)
        return points
    }

    /// Converts RoomPlan's local curve into a `WallArc`: center in world (at `baseY`), angles in
    /// plan radians counter-clockwise from plan +x with `startAngle < endAngle`. Local angles are
    /// read from local +x toward local +z; the mirrored reading is used only when its end
    /// points match the straight wall ends clearly better (logged).
    static func planArc(_ curve: WallArcInput, transform t: simd_float4x4, baseY: Float,
                        straightStart: SIMD2<Float>, straightEnd: SIMD2<Float>) -> WallArc? {
        guard curve.radius.isFinite, curve.radius > 1e-3, curve.startAngle.isFinite, curve.endAngle.isFinite else { return nil }
        let axisX = SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let axisZ = SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let origin = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let r = curve.radius
        /// Plan point of local (x, z).
        func plan(_ x: Float, _ z: Float) -> SIMD2<Float> { PlanAxes.toPlan(origin + axisX * x + axisZ * z) }
        /// Plan point at a local angle, standard or mirrored reading.
        func point(_ angle: Float, mirrored: Bool) -> SIMD2<Float> {
            let s: Float = mirrored ? -1 : 1
            return plan(curve.center.x + r * cos(angle), curve.center.y + s * r * sin(angle))
        }
        /// Summed distance of the arc ends to the straight ends (best pairing).
        func endError(mirrored: Bool) -> Float {
            let p0 = point(curve.startAngle, mirrored: mirrored)
            let p1 = point(curve.endAngle, mirrored: mirrored)
            let direct = simd_distance(p0, straightStart) + simd_distance(p1, straightEnd)
            let swapped = simd_distance(p0, straightEnd) + simd_distance(p1, straightStart)
            return Swift.min(direct, swapped)
        }
        let mirrored = endError(mirrored: true) + 0.05 < endError(mirrored: false)
        if mirrored {
            LogStore.shared.write("curved wall: mirrored local angle reading matched the wall ends better", category: logCategory)
        }
        let center = plan(curve.center.x, curve.center.y)
        let p0 = point(curve.startAngle, mirrored: mirrored)
        let p1 = point(curve.endAngle, mirrored: mirrored)
        let pm = point((curve.startAngle + curve.endAngle) * 0.5, mirrored: mirrored)
        let a0 = atan2(p0.y - center.y, p0.x - center.x)
        let a1 = atan2(p1.y - center.y, p1.x - center.x)
        let am = atan2(pm.y - center.y, pm.x - center.x)
        let span01 = positiveAngle(a1 - a0)
        let startAngle: Float
        let sweep: Float
        if positiveAngle(am - a0) <= span01 {
            startAngle = a0
            sweep = span01
        } else {
            startAngle = a1
            sweep = positiveAngle(a0 - a1)
        }
        guard sweep > 1e-4 else { return nil }
        let world = PlanAxes.toWorld(center, y: baseY)
        return WallArc(center: Vec3(world), radius: r, startAngle: startAngle, endAngle: startAngle + sweep)
    }

    /// Angle wrapped into [0, 2 pi).
    static func positiveAngle(_ angle: Float) -> Float {
        let full = 2 * Float.pi
        var a = angle.truncatingRemainder(dividingBy: full)
        if a < 0 { a += full }
        return a
    }

    /// Length of a wall along its surface: the arc length for curved walls, else the chord.
    static func surfaceLength(start: SIMD2<Float>, end: SIMD2<Float>, arc: WallArc?) -> Float {
        guard let arc else { return simd_distance(start, end) }
        let points = arcPoints(from: start, to: end, arc: arc)
        var total: Float = 0
        for i in 1..<points.count { total += simd_distance(points[i - 1], points[i]) }
        return total
    }

    /// The ring without consecutive (and closing) duplicate points.
    static func removingDuplicates(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        for p in points where result.last.map({ simd_distance($0, p) > 1e-5 }) ?? true {
            result.append(p)
        }
        if result.count > 1, let first = result.first, let last = result.last, simd_distance(first, last) <= 1e-5 {
            result.removeLast()
        }
        return result
    }
}
