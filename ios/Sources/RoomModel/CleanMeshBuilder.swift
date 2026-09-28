import Foundation
import simd

/// What a clean mesh part shows (viewer layers and export materials pick by kind).
enum CleanPartKind: Hashable, Sendable {
    case wall, floor, ceiling, door, window, opening, object(ObjectCategory), occluded
}

/// One pickable piece of the clean model as a world-space triangle mesh.
struct CleanMeshPart: Equatable {
    /// The element it belongs to (the room for floors and ceilings; the wall or the object for
    /// occluded regions).
    var element: ElementID
    /// What it shows.
    var kind: CleanPartKind
    /// World-space triangles, front faces toward the room (walls, openings, occluded wall
    /// quads), up (floors, footprints), down (ceilings) or outward (object boxes).
    var mesh: TriangleMesh
    /// True for furniture that Hide Furniture removes.
    var isMovable: Bool
    /// True when the element is hidden.
    var isHidden: Bool
    /// Where the geometry came from.
    var provenance: Provenance
}

/// Builds triangle meshes of the (edited) clean model for the viewer and exports. Pure
/// functions, safe on any queue.
enum CleanMeshBuilder {
    /// Occluded floor footprints sit this far above the floor, meters.
    static let footprintLift: Float = 0.005
    /// Occluded wall quads sit this far in front of the wall, meters.
    static let occludedWallOffset: Float = 0.005
    /// Occluded wall quads reach this far above the blocking object's top, meters.
    static let occluderMargin: Float = 0.1
    /// Movable objects this close to a wall are considered when finding a span's blocker, meters.
    static let blockerSearchDistance: Float = 0.5

    /// Also emits `.occluded` parts (provenance `.inferred`, `element` = the wall or the object):
    /// for every `CleanWall.occludedSpans` range a wall-plane quad of the span's length and
    /// height min(wall height, top of the blocking movable object + 0.1 m), and for every movable
    /// `DetectedObject` its footprint quad from `orientedBox`, 5 mm above the floor. Viewers show
    /// them only while Hide Furniture is on (SPEC FURNITURE REMOVAL: blocked regions are marked,
    /// never shown as measured).
    static func parts(for model: CleanModel, includeCeiling: Bool, includeHidden: Bool) -> [CleanMeshPart] {
        var parts: [CleanMeshPart] = []
        for room in model.rooms {
            appendParts(for: room, includeCeiling: includeCeiling, includeHidden: includeHidden, into: &parts)
        }
        return parts
    }

    /// Wall rectangle minus opening rectangles as strips of quads (no general triangulation).
    /// Only openings whose `wallID` is this wall are cut. Curved walls follow their arc.
    static func wallMesh(_ wall: CleanWall, openings: [CleanOpening]) -> TriangleMesh {
        let frame = WallFrame(wall)
        let height = wall.height
        guard frame.total > 1e-4, height > 1e-4, height.isFinite else { return TriangleMesh() }
        var holes: [(u0: Float, u1: Float, v0: Float, v1: Float)] = []
        for opening in openings where opening.wallID == wall.id {
            let u0 = Swift.max(0, frame.u(forOffset: opening.offsetAlongWall))
            let u1 = Swift.min(frame.total, frame.u(forOffset: opening.offsetAlongWall + opening.width))
            let v0 = Swift.min(Swift.max(0, opening.sillHeight), height)
            let v1 = Swift.min(Swift.max(0, opening.headHeight), height)
            if u1 - u0 > 1e-4 && v1 - v0 > 1e-4 { holes.append((u0, u1, v0, v1)) }
        }
        var breaks: [Float] = frame.cumulative
        for hole in holes { breaks.append(contentsOf: [hole.u0, hole.u1]) }
        breaks = uniqueSorted(breaks.map { Swift.min(Swift.max(0, $0), frame.total) })
        var builder = MeshAccumulator()
        for i in 0..<Swift.max(0, breaks.count - 1) {
            let u0 = breaks[i]
            let u1 = breaks[i + 1]
            guard u1 - u0 > 1e-6 else { continue }
            let middle = (u0 + u1) * 0.5
            var blocked: [(low: Float, high: Float)] = []
            for hole in holes where hole.u0 <= middle && middle <= hole.u1 {
                blocked.append((low: hole.v0, high: hole.v1))
            }
            blocked.sort { $0.low < $1.low }
            var v: Float = 0
            for gap in blocked {
                if gap.low > v + 1e-6 { builder.addQuad(frame, u0: u0, u1: u1, v0: v, v1: gap.low, offset: 0) }
                v = Swift.max(v, gap.high)
            }
            if height > v + 1e-6 { builder.addQuad(frame, u0: u0, u1: u1, v0: v, v1: height, offset: 0) }
        }
        return builder.mesh
    }

    // MARK: - Room parts

    /// Appends the parts of one room.
    private static func appendParts(for room: CleanRoom, includeCeiling: Bool, includeHidden: Bool,
                                    into parts: inout [CleanMeshPart]) {
        for wall in room.walls {
            let hosted = room.openings.filter { $0.wallID == wall.id }
            let mesh = wallMesh(wall, openings: hosted)
            if mesh.triangleCount > 0 {
                parts.append(CleanMeshPart(element: wall.id, kind: .wall, mesh: mesh, isMovable: false, isHidden: false,
                                           provenance: wall.provenance))
            }
            let frame = WallFrame(wall)
            for opening in hosted {
                let u0 = Swift.max(0, frame.u(forOffset: opening.offsetAlongWall))
                let u1 = Swift.min(frame.total, frame.u(forOffset: opening.offsetAlongWall + opening.width))
                let v0 = Swift.max(0, opening.sillHeight)
                let v1 = Swift.max(v0, opening.headHeight)
                var builder = MeshAccumulator()
                if u1 - u0 > 1e-4 && v1 - v0 > 1e-4 {
                    let cuts = segmentBreaks(frame, u0, u1)
                    for (a, b) in zip(cuts.dropLast(), cuts.dropFirst()) {
                        builder.addQuad(frame, u0: a, u1: b, v0: v0, v1: v1, offset: 0)
                    }
                }
                if builder.mesh.triangleCount > 0 {
                    parts.append(CleanMeshPart(element: opening.id, kind: partKind(opening.kind), mesh: builder.mesh,
                                               isMovable: false, isHidden: false, provenance: opening.provenance))
                }
            }
            for span in wall.occludedSpans {
                let top = occludedHeight(span: span, wall: wall, room: room)
                let u0 = Swift.max(0, frame.u(forOffset: span.lowerBound))
                let u1 = Swift.min(frame.total, frame.u(forOffset: span.upperBound))
                var builder = MeshAccumulator()
                if u1 - u0 > 1e-4 && top > 1e-4 {
                    let cuts = segmentBreaks(frame, u0, u1)
                    for (a, b) in zip(cuts.dropLast(), cuts.dropFirst()) {
                        builder.addQuad(frame, u0: a, u1: b, v0: 0, v1: top, offset: occludedWallOffset)
                    }
                }
                if builder.mesh.triangleCount > 0 {
                    parts.append(CleanMeshPart(element: wall.id, kind: .occluded, mesh: builder.mesh, isMovable: false,
                                               isHidden: false, provenance: .inferred))
                }
            }
        }
        let outline = room.floor.outline.map { $0.simd }
        if let floorMesh = horizontalMesh(outline, y: room.floor.elevation, facingUp: true) {
            parts.append(CleanMeshPart(element: room.id, kind: .floor, mesh: floorMesh, isMovable: false, isHidden: false,
                                       provenance: room.floor.provenance))
        }
        if includeCeiling, room.ceiling.height > 0,
           let ceilingMesh = horizontalMesh(outline, y: room.floor.elevation + room.ceiling.height, facingUp: false) {
            parts.append(CleanMeshPart(element: room.id, kind: .ceiling, mesh: ceilingMesh, isMovable: false, isHidden: false,
                                       provenance: room.ceiling.provenance))
        }
        for object in room.objects {
            if includeHidden || !object.isHidden {
                parts.append(CleanMeshPart(element: object.id, kind: .object(object.category), mesh: boxMesh(object.orientedBox),
                                           isMovable: object.isMovable, isHidden: object.isHidden, provenance: object.provenance))
            }
            if object.isMovable,
               let footprint = horizontalMesh(RoomMetricsCalculator.footprint(of: object),
                                              y: room.floor.elevation + footprintLift, facingUp: true) {
                parts.append(CleanMeshPart(element: object.id, kind: .occluded, mesh: footprint, isMovable: false,
                                           isHidden: false, provenance: .inferred))
            }
        }
    }

    /// Part kind of an opening kind.
    static func partKind(_ kind: OpeningKind) -> CleanPartKind {
        switch kind {
        case .door, .openDoor: return .door
        case .window: return .window
        case .opening: return .opening
        }
    }

    /// Height above the wall base of an occluded span: the highest top (plus the margin) of the
    /// movable objects blocking it, capped by the wall height; the wall height when no blocker
    /// is found.
    static func occludedHeight(span: ClosedRange<Float>, wall: CleanWall, room: CleanRoom) -> Float {
        var top: Float?
        for object in room.objects where object.isMovable {
            guard let covered = RoomMetricsCalculator.occlusionSpan(of: object, wall: wall, distance: blockerSearchDistance),
                  covered.overlaps(span) else { continue }
            let objectTop = RoomMetricsCalculator.occluderTop(object) + occluderMargin - wall.start.y
            top = Swift.max(top ?? objectTop, objectTop)
        }
        guard let found = top else { return wall.height }
        return Swift.min(wall.height, Swift.max(0, found))
    }

    /// Triangulated horizontal polygon at height `y` (plan points through `PlanAxes`), nil when
    /// the polygon cannot be triangulated.
    static func horizontalMesh(_ polygon: [SIMD2<Float>], y: Float, facingUp: Bool) -> TriangleMesh? {
        let indices = PolygonTriangulator.triangulate(polygon)
        guard !indices.isEmpty else { return nil }
        let positions = polygon.map { PlanAxes.toWorld($0, y: y) }
        var ordered: [UInt32] = []
        ordered.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            if facingUp {
                ordered.append(contentsOf: [indices[t], indices[t + 1], indices[t + 2]])
            } else {
                ordered.append(contentsOf: [indices[t], indices[t + 2], indices[t + 1]])
            }
            t += 3
        }
        return TriangleMesh(positions: positions, indices: ordered)
    }

    /// Closed box with outward-facing triangles (12 triangles, 8 corners).
    static func boxMesh(_ box: OrientedBox) -> TriangleMesh {
        let quads: [[UInt32]] = [[0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6]]
        let mirrored = simd_determinant(box.axes) < 0
        var indices: [UInt32] = []
        indices.reserveCapacity(36)
        for q in quads {
            if mirrored {
                indices.append(contentsOf: [q[0], q[2], q[1], q[0], q[3], q[2]])
            } else {
                indices.append(contentsOf: [q[0], q[1], q[2], q[0], q[2], q[3]])
            }
        }
        return TriangleMesh(positions: box.corners, indices: indices)
    }

    /// Sorted values with near-duplicates (within 1e-6) removed.
    private static func uniqueSorted(_ values: [Float]) -> [Float] {
        var result: [Float] = []
        for v in values.sorted() where result.last.map({ v - $0 > 1e-6 }) ?? true {
            result.append(v)
        }
        return result
    }

    /// `u0`, `u1` and every polyline vertex of the frame between them, sorted.
    private static func segmentBreaks(_ frame: WallFrame, _ u0: Float, _ u1: Float) -> [Float] {
        uniqueSorted([u0, u1] + frame.cumulative.filter { $0 > u0 && $0 < u1 })
    }
}

extension CleanMeshBuilder {
    /// A wall's base as a plan polyline (two points, or arc samples for curved walls), mapping
    /// wall-local (u along the base, v up from the base) to world points.
    struct WallFrame {
        /// Plan polyline from the wall start to its end.
        let points: [SIMD2<Float>]
        /// Cumulative length at each polyline point, meters (first 0, last `total`).
        let cumulative: [Float]
        /// Polyline length, meters.
        let total: Float
        /// Straight start-to-end length, meters.
        let chord: Float
        /// World Y of the base at the start.
        let startY: Float
        /// World Y of the base at the end.
        let endY: Float
        /// Unit normal into the room, world (the chord's normal for curved walls).
        let wallNormal: SIMD3<Float>
        /// Plan center of a curved wall's arc, nil for straight walls.
        let arcCenter: SIMD2<Float>?
        /// True when the room lies on the concave side of a curved wall (normals point toward
        /// the arc center), false when the arc bulges into the room.
        let towardCenter: Bool

        /// Frame of a clean wall.
        init(_ wall: CleanWall) {
            let a = PlanAxes.toPlan(wall.start.simd)
            let b = PlanAxes.toPlan(wall.end.simd)
            let polyline = wall.arc.map { RoomOutline.arcPoints(from: a, to: b, arc: $0) } ?? [a, b]
            var sums: [Float] = [0]
            for i in 1..<polyline.count { sums.append(sums[i - 1] + simd_distance(polyline[i - 1], polyline[i])) }
            points = polyline
            cumulative = sums
            total = sums.last ?? 0
            chord = simd_distance(a, b)
            startY = wall.start.y
            endY = wall.end.y
            let n = wall.normal.simd
            let length = simd_length(n)
            let unitNormal = length > 1e-6 ? n / length : SIMD3<Float>(0, 0, 0)
            wallNormal = unitNormal
            if let arc = wall.arc, polyline.count > 2 {
                arcCenter = PlanAxes.toPlan(arc.center.simd)
                let bulge = polyline[polyline.count / 2] - (a + b) * 0.5
                towardCenter = simd_dot(PlanAxes.toPlan(unitNormal), bulge) <= 0
            } else {
                arcCenter = nil
                towardCenter = true
            }
        }

        /// Plan point at polyline parameter `u`.
        func planPoint(u: Float) -> SIMD2<Float> {
            var k = 0
            while k + 2 < cumulative.count && cumulative[k + 1] < u { k += 1 }
            let span = cumulative[k + 1] - cumulative[k]
            let f = span > 1e-9 ? Swift.min(Swift.max((u - cumulative[k]) / span, 0), 1) : 0
            return points[k] + (points[k + 1] - points[k]) * f
        }

        /// Unit normal into the room at polyline parameter `u`: the wall normal for straight
        /// walls, the radial direction (toward or away from the center) for curved walls.
        func normal(at u: Float) -> SIMD3<Float> {
            guard let center = arcCenter else { return wallNormal }
            let radial = planPoint(u: u) - center
            let length = simd_length(radial)
            guard length > 1e-6 else { return wallNormal }
            let inward = towardCenter ? -radial / length : radial / length
            return PlanAxes.toWorld(inward, y: 0)
        }

        /// Polyline parameter of a distance measured along the chord (openings and spans use
        /// chord distances; for curved walls they are stretched to the arc length).
        func u(forOffset offset: Float) -> Float {
            chord > 1e-6 ? offset * total / chord : offset
        }

        /// World point at polyline parameter `u`, `v` above the base, pushed `offset` along the normal.
        func point(u: Float, v: Float, offset: Float) -> SIMD3<Float> {
            let plan = planPoint(u: u)
            let g = total > 1e-9 ? Swift.min(Swift.max(u / total, 0), 1) : 0
            let baseY = startY + (endY - startY) * g
            let world = PlanAxes.toWorld(plan, y: baseY + v)
            return offset == 0 ? world : world + normal(at: u) * offset
        }
    }

    /// Collects quads into one triangle mesh, winding each quad so its front faces the room.
    struct MeshAccumulator {
        /// The mesh built so far.
        private(set) var mesh = TriangleMesh()

        /// Adds the quad [u0, u1] x [v0, v1] of a wall frame.
        mutating func addQuad(_ frame: WallFrame, u0: Float, u1: Float, v0: Float, v1: Float, offset: Float) {
            let p00 = frame.point(u: u0, v: v0, offset: offset)
            let p10 = frame.point(u: u1, v: v0, offset: offset)
            let p11 = frame.point(u: u1, v: v1, offset: offset)
            let p01 = frame.point(u: u0, v: v1, offset: offset)
            let base = UInt32(mesh.positions.count)
            mesh.positions.append(contentsOf: [p00, p10, p11, p01])
            let facing = simd_dot(simd_cross(p10 - p00, p01 - p00), frame.normal(at: (u0 + u1) * 0.5))
            if facing >= 0 {
                mesh.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            } else {
                mesh.indices.append(contentsOf: [base, base + 2, base + 1, base, base + 3, base + 2])
            }
        }
    }
}
