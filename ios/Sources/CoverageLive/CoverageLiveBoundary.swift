import Foundation
import simd

// The live RoomPlan room as a Coverage boundary (docs/MODULES.md 3.31). A live room arrives
// every second (RoomScanEngine.liveRoomHandler), so this file converts the plain RoomInput
// values directly and never calls CleanModelBuilder.buildRoom or RoomOutline.build (both log
// per call). RoomOutline.floorPolygon is pure and silent, so it is reused for the floor.
//
// Frames: CoverageRoomBoundary works in world (x, z) on the horizontal plane; RoomModel's plan
// coordinates are (x, -z) (PlanAxes), so a plan point (px, py) is the world pair (px, -py).
// Windows, doors and openings are never expected surfaces (D19): they become exclusion boxes.

/// The live RoomPlan room as a Coverage boundary. Pure. Never calls CleanModelBuilder or
/// RoomOutline.build: both log per call and a live room arrives every second.
enum CoverageLiveBoundary {
    /// Walls shorter than this are skipped, meters (RoomOutline's minimum wall length).
    static let minimumWallLength: Float = 0.05
    /// Depth of an opening's exclusion box across its host wall, meters.
    static let openingDepth: Float = 0.3

    // MARK: Boundary

    /// Walls: endpoints `transform * (-+w/2, 0, 0, 1)` as world (x, z), baseY = center y - height / 2,
    /// height = dimensions.y (walls under 0.05 m long or with non-finite values skipped). Floor polygon:
    /// `RoomOutline.floorPolygon(room)` converted from plan (x, -z) to world (x, z), else the convex hull
    /// of the wall endpoints; floorY = the lowest wall base; ceilingY = floorY + the tallest wall;
    /// ceilingPolygon empty (Coverage reuses the floor). Nil with fewer than 2 usable walls.
    static func boundary(from room: RoomInput) -> CoverageRoomBoundary? {
        let walls = room.walls.compactMap { wall(from: $0) }
        guard walls.count >= 2 else { return nil }
        var floorY = Float.greatestFiniteMagnitude
        var tallest: Float = 0
        for wall in walls {
            floorY = min(floorY, wall.baseY)
            tallest = max(tallest, wall.height)
        }
        var polygon: [SIMD2<Float>] = []
        if let plan = RoomOutline.floorPolygon(room), plan.count >= 3 {
            polygon = plan.map { SIMD2<Float>($0.x, -$0.y) }
        }
        if polygon.count < 3 {
            var ends: [SIMD2<Float>] = []
            ends.reserveCapacity(walls.count * 2)
            for wall in walls {
                ends.append(wall.start)
                ends.append(wall.end)
            }
            polygon = Polygon2D.convexHull(ends).points
        }
        return CoverageRoomBoundary(walls: walls, floorPolygon: polygon, floorY: floorY,
                                    ceilingPolygon: [], ceilingY: floorY + tallest)
    }

    /// One wall surface as a Coverage wall, or nil when it is shorter than `minimumWallLength`,
    /// has no positive height or has non-finite values.
    static func wall(from surface: SurfaceInput) -> CoverageWall? {
        let t = surface.transform.simd
        let width = surface.dimensions.x
        let height = surface.dimensions.y
        guard width.isFinite, height.isFinite, height > 0 else { return nil }
        let half = width * 0.5
        let s = t * SIMD4<Float>(-half, 0, 0, 1)
        let e = t * SIMD4<Float>(half, 0, 0, 1)
        let start = SIMD2<Float>(s.x, s.z)
        let end = SIMD2<Float>(e.x, e.z)
        let centerY = t.columns.3.y
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite, centerY.isFinite else { return nil }
        guard simd_distance(start, end) >= minimumWallLength else { return nil }
        return CoverageWall(start: start, end: end, baseY: centerY - height * 0.5, height: height)
    }

    // MARK: Exclusions

    /// One box per door, open door, window and opening (its transform, width, height and a 0.3 m
    /// depth), grown by `margin` on every side.
    static func exclusions(from room: RoomInput, margin: Float) -> [OrientedBox] {
        let grow = margin.isFinite ? max(margin, 0) : 0
        return room.openings.compactMap { surface -> OrientedBox? in
            guard surface.kind.openingKind != nil else { return nil }
            return box(for: surface, margin: grow)
        }
    }

    /// The exclusion box of one opening surface, nil for non-finite or degenerate transforms.
    static func box(for surface: SurfaceInput, margin: Float) -> OrientedBox? {
        let t = surface.transform.simd
        let width = surface.dimensions.x
        let height = surface.dimensions.y
        guard width.isFinite, height.isFinite, width >= 0, height >= 0 else { return nil }
        guard let along = unit(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z)),
              let upRaw = unit(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z)) else { return nil }
        // Re-orthogonalize so the box axes are a rotation even for a slightly skewed transform.
        guard let across = unit(simd_cross(along, upRaw)), let up = unit(simd_cross(across, along)) else { return nil }
        let center = surface.transform.translation
        guard CoverageLiveFaces.isFinite(center) else { return nil }
        let halfExtents = SIMD3<Float>(width * 0.5 + margin, height * 0.5 + margin, openingDepth * 0.5 + margin)
        let axes = simd_float3x3(columns: (along, up, across))
        return OrientedBox(center: center, axes: axes, halfExtents: halfExtents)
    }

    /// Expected sample positions outside every exclusion.
    static func expectedPoints(_ samples: [ExpectedSample], exclusions: [OrientedBox]) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(samples.count)
        for sample in samples where !isExcluded(sample.position, exclusions: exclusions) {
            out.append(sample.position)
        }
        return out
    }

    /// True when `point` lies inside any exclusion box.
    static func isExcluded(_ point: SIMD3<Float>, exclusions: [OrientedBox]) -> Bool {
        for box in exclusions where box.contains(point) { return true }
        return false
    }

    // MARK: Helpers

    /// `v` scaled to unit length, nil when it is zero or not finite.
    private static func unit(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(v)
        guard length.isFinite, length > 1e-6 else { return nil }
        return v / length
    }
}
