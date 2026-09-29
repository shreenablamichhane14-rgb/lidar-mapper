import Foundation
import simd

/// Room boundaries (docs/MODULES.md 3.37c): room edges that no wall covers, such as a split
/// line or the outline of a room whose wall loop did not close, drawn as thin dashed lines on
/// `PlanLayers.roomBoundaries` so every room reads as a closed area without pretending a wall
/// is there. Never drawn on a wall.
extension PlanDrawing {
    /// End points closer than this make two boundary pieces the same (drawn once), and edge
    /// points closer than this to another edge's line count as on it, meters.
    static let boundaryMatchTolerance: Float = 0.001
    /// Boundary pieces shorter than this are not drawn, meters.
    static let minimumBoundaryLength: Float = 0.01

    /// A wall's face segments and body, for the coverage test.
    private struct WallCover {
        /// Inner and outer face segments, plan meters.
        var segments: [(SIMD2<Float>, SIMD2<Float>)]
        /// The wall body between its faces, nil when the wall has no thickness.
        var body: Polygon2D?
    }

    /// Draws every uncovered edge of every room part of the level, once, dashed.
    static func drawRoomBoundaries(level: PlanLevel, into sketch: inout PlanSketch) {
        for segment in roomBoundaries(level: level) {
            sketch.dashedLine(PlanLayers.roomBoundaries, segment.0, segment.1)
        }
    }

    /// The uncovered room edges of a level, plan meters: the edges of every part of every room
    /// (without the zero-width bridges of a ring cut into pieces by `Polygon2D.clipped`), each
    /// kept when its midpoint is farther than `boundaryWallSlack` from every wall face and
    /// outside every wall body; an edge shared by two rooms (a split line) is listed once.
    static func roomBoundaries(level: PlanLevel) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let covers = level.walls.compactMap { wallCover($0) }
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for room in level.rooms {
            for part in PlanBuilder.parts(of: room) {
                for edge in openEdges(of: part) where !isCovered(edge, by: covers) && !isListed(edge, in: result) {
                    result.append(edge)
                }
            }
        }
        return result
    }

    /// The edges of a closed ring as segments, without degenerate or non-finite edges and
    /// without the parts that an opposite edge of the same ring runs back over (the zero-width
    /// bridges that join the pieces of a clipped concave ring along the cut line).
    static func openEdges(of ring: [SIMD2<Float>]) -> [(SIMD2<Float>, SIMD2<Float>)] {
        guard ring.count >= 2 else { return [] }
        var edges: [(SIMD2<Float>, SIMD2<Float>)] = []
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            guard PlanSketch.isFinite(a), PlanSketch.isFinite(b), simd_distance(a, b) > minimumBoundaryLength else { continue }
            edges.append((a, b))
        }
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for (i, edge) in edges.enumerated() {
            let length = simd_distance(edge.0, edge.1)
            let u = (edge.1 - edge.0) / length
            var cuts: [(Float, Float)] = []
            for (j, other) in edges.enumerated() where j != i {
                if let cut = backtrack(of: other, along: edge.0, direction: u, length: length) { cuts.append(cut) }
            }
            for piece in uncut(length: length, cuts: cuts) where piece.1 - piece.0 > minimumBoundaryLength {
                result.append((edge.0 + u * piece.0, edge.0 + u * piece.1))
            }
        }
        return result
    }

    /// The interval (meters from `origin` along the unit `direction`, within 0...length) that
    /// `other` covers when it lies on the same line and runs the opposite way, else nil.
    private static func backtrack(of other: (SIMD2<Float>, SIMD2<Float>), along origin: SIMD2<Float>,
                                  direction u: SIMD2<Float>, length: Float) -> (Float, Float)? {
        let v = other.1 - other.0
        guard simd_dot(u, v) < 0 else { return nil }
        let normal = SIMD2<Float>(-u.y, u.x)
        let off0 = abs(simd_dot(other.0 - origin, normal))
        let off1 = abs(simd_dot(other.1 - origin, normal))
        guard off0 <= boundaryMatchTolerance, off1 <= boundaryMatchTolerance else { return nil }
        let t0 = simd_dot(other.0 - origin, u)
        let t1 = simd_dot(other.1 - origin, u)
        let lower = max(0, min(t0, t1))
        let upper = min(length, max(t0, t1))
        return upper > lower ? (lower, upper) : nil
    }

    /// 0...length minus the cut intervals, as sorted pieces.
    private static func uncut(length: Float, cuts: [(Float, Float)]) -> [(Float, Float)] {
        var pieces: [(Float, Float)] = []
        var cursor: Float = 0
        for cut in cuts.sorted(by: { $0.0 < $1.0 }) {
            if cut.0 > cursor { pieces.append((cursor, cut.0)) }
            cursor = max(cursor, cut.1)
        }
        if length > cursor { pieces.append((cursor, length)) }
        return pieces
    }

    /// Face segments and body of a wall, nil when it has no usable geometry.
    private static func wallCover(_ wall: PlanWall) -> WallCover? {
        guard let faces = PlanWallDrawing.faces(of: wall) else { return nil }
        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        for polyline in [faces.inner, faces.outer] where polyline.count >= 2 {
            for i in 1..<polyline.count {
                segments.append((polyline[i - 1], polyline[i]))
            }
        }
        let thick = wall.thickness.isFinite && wall.thickness > 1e-4
        let body: Polygon2D? = thick ? Polygon2D(points: faces.inner + Array(faces.outer.reversed())) : nil
        return WallCover(segments: segments, body: body)
    }

    /// True when the edge's midpoint is within `boundaryWallSlack` of a wall face or inside a
    /// wall body.
    private static func isCovered(_ edge: (SIMD2<Float>, SIMD2<Float>), by covers: [WallCover]) -> Bool {
        let middle = (edge.0 + edge.1) * 0.5
        for cover in covers {
            for segment in cover.segments where Segment2D(a: segment.0, b: segment.1).distance(to: middle) <= boundaryWallSlack {
                return true
            }
            if let body = cover.body, body.contains(point: middle) { return true }
        }
        return false
    }

    /// True when `edge` (either direction) is already in `list`.
    private static func isListed(_ edge: (SIMD2<Float>, SIMD2<Float>), in list: [(SIMD2<Float>, SIMD2<Float>)]) -> Bool {
        let tolerance = boundaryMatchTolerance
        return list.contains { other in
            let same = simd_distance(other.0, edge.0) <= tolerance && simd_distance(other.1, edge.1) <= tolerance
            let reversed = simd_distance(other.0, edge.1) <= tolerance && simd_distance(other.1, edge.0) <= tolerance
            return same || reversed
        }
    }
}
