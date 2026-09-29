import Foundation
import simd

// The top-down coverage map of the live minimap (docs/MODULES.md 3.31, Core CR-8). Cells are in
// plan coordinates (PlanAxes: plan x = world x, plan y = -world z), row-major with row 0 at the
// smallest plan y, cell (0, 0) cornered at `origin`. A column takes the best code of its voxels
// (green 3 > yellow 2); a column with neither shows red (1) when an unobserved expected sample
// falls in it, else stays empty (0). MinimapCell raw values follow that order, so the code of a
// cell is simply the maximum of the codes that land in it.

/// The top-down map. Pure.
enum CoverageLiveMinimap {
    /// A camera whose forward direction is within this angle of vertical uses its top edge for
    /// the heading, degrees.
    static let verticalLimitDegrees: Float = 30
    /// Most doublings of the cell size before giving up on fitting `maxCells` (a safety cap).
    static let maxDoublings = 40

    /// Cells in plan coordinates (`PlanAxes`: x, -z) over the union of the voxels' extent and the
    /// boundary's floor polygon, `cellSize` doubled until both sides fit `maxCells`. A cell is
    /// `.covered` when a voxel in its column is green, else `.partial` when one is yellow, else
    /// `.missing` when an unobserved expected sample falls in it, else `.empty`. Walls are the boundary
    /// walls as plan polylines. `camera` and `heading` (CR-8) come from `camera` when given.
    static func make(voxels: [(key: SIMD3<Int32>, state: CoverageState)], voxelSize: Float,
                     boundary: CoverageRoomBoundary?, unobservedExpected: [SIMD3<Float>],
                     camera: simd_float4x4?, cellSize: Float, maxCells: Int) -> MinimapSnapshot {
        let size = voxelSize.isFinite && voxelSize > 0 ? voxelSize : CoverageGrid.defaultVoxelSize
        var extent = CoverageLiveMinimapExtent()
        var voxelPoints: [(plan: SIMD2<Float>, code: UInt8)] = []
        voxelPoints.reserveCapacity(voxels.count)
        let half = SIMD2<Float>(repeating: size * 0.5)
        for voxel in voxels {
            let x = (Float(voxel.key.x) + 0.5) * size
            let z = (Float(voxel.key.z) + 0.5) * size
            let plan = SIMD2<Float>(x, -z)
            extent.include(plan - half)
            extent.include(plan + half)
            voxelPoints.append((plan: plan, code: code(for: voxel.state)))
        }
        var walls: [[Vec2]] = []
        if let boundary {
            for p in boundary.floorPolygon { extent.include(SIMD2<Float>(p.x, -p.y)) }
            for wall in boundary.walls {
                let a = SIMD2<Float>(wall.start.x, -wall.start.y)
                let b = SIMD2<Float>(wall.end.x, -wall.end.y)
                extent.include(a)
                extent.include(b)
                walls.append([Vec2(a), Vec2(b)])
            }
        }
        var missingPoints: [SIMD2<Float>] = []
        missingPoints.reserveCapacity(unobservedExpected.count)
        for p in unobservedExpected {
            let plan = PlanAxes.toPlan(p)
            extent.include(plan)
            missingPoints.append(plan)
        }
        let cameraPlan = camera.map { Vec2(PlanAxes.toPlan(SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z))) }
        let cameraHeading = camera.map { heading(cameraToWorld: $0) }
        var cell = cellSize.isFinite && cellSize > 0 ? cellSize : 0.25
        guard let low = extent.low, let high = extent.high else {
            return MinimapSnapshot(cellSize: cell, origin: .zero, width: 0, height: 0, cells: [], walls: walls,
                                   camera: cameraPlan, heading: cameraHeading)
        }
        let limit = max(maxCells, 1)
        var width = 1
        var height = 1
        for _ in 0...maxDoublings {
            width = cellCount(high.x - low.x, cell)
            height = cellCount(high.y - low.y, cell)
            if width <= limit && height <= limit { break }
            cell *= 2
        }
        width = min(width, limit)
        height = min(height, limit)
        var cells = [UInt8](repeating: MinimapCell.empty.rawValue, count: width * height)
        for point in voxelPoints where point.code > 0 {
            guard let index = cellIndex(of: point.plan, origin: low, cellSize: cell, width: width, height: height) else { continue }
            let slot = index.y * width + index.x
            cells[slot] = max(cells[slot], point.code)
        }
        for plan in missingPoints {
            guard let index = cellIndex(of: plan, origin: low, cellSize: cell, width: width, height: height) else { continue }
            let slot = index.y * width + index.x
            cells[slot] = max(cells[slot], MinimapCell.missing.rawValue)
        }
        return MinimapSnapshot(cellSize: cell, origin: Vec2(low), width: width, height: height, cells: cells,
                               walls: walls, camera: cameraPlan, heading: cameraHeading)
    }

    /// Plan angle, radians counter-clockwise from plan +x, of the camera's forward direction (its -Z
    /// column) projected on the floor; of its top edge (its -X column, portrait) when the forward is
    /// within 30 degrees of vertical.
    static func heading(cameraToWorld: simd_float4x4) -> Float {
        let back = cameraToWorld.columns.2
        var direction = -SIMD3<Float>(back.x, back.y, back.z)
        let length = simd_length(direction)
        let limit = cos(verticalLimitDegrees * .pi / 180)
        if length > 1e-6, length.isFinite, abs(direction.y) / length > limit {
            let side = cameraToWorld.columns.0
            direction = -SIMD3<Float>(side.x, side.y, side.z)
        }
        let plan = PlanAxes.toPlan(direction)
        let planLength = simd_length(plan)
        guard planLength.isFinite, planLength > 1e-6 else { return 0 }
        return atan2(plan.y, plan.x)
    }

    /// Column and row of a plan point in a grid, clamped to the grid for points on its far edges;
    /// nil for points more than one cell outside or not finite.
    static func cellIndex(of plan: SIMD2<Float>, origin: SIMD2<Float>, cellSize: Float,
                          width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width > 0, height > 0, cellSize > 0 else { return nil }
        let fx = ((plan.x - origin.x) / cellSize).rounded(.down)
        let fy = ((plan.y - origin.y) / cellSize).rounded(.down)
        guard fx.isFinite, fy.isFinite, fx >= -1, fy >= -1, fx <= Float(width), fy <= Float(height) else { return nil }
        let x = min(max(Int(fx), 0), width - 1)
        let y = min(max(Int(fy), 0), height - 1)
        return (x: x, y: y)
    }

    /// Column and row of a plan point in an existing snapshot (for readers and the self-test).
    static func cellIndex(of plan: SIMD2<Float>, in snapshot: MinimapSnapshot) -> (x: Int, y: Int)? {
        cellIndex(of: plan, origin: snapshot.origin.simd, cellSize: snapshot.cellSize,
                  width: snapshot.width, height: snapshot.height)
    }

    /// Minimap code of a voxel state: green covered, yellow partial, anything else nothing.
    static func code(for state: CoverageState) -> UInt8 {
        switch state {
        case .green: return MinimapCell.covered.rawValue
        case .yellow: return MinimapCell.partial.rawValue
        case .gray, .red: return MinimapCell.empty.rawValue
        }
    }

    /// Cells needed to cover `length` at `size`: at least 1, capped to stay representable.
    private static func cellCount(_ length: Float, _ size: Float) -> Int {
        let n = (length / size).rounded(.up)
        guard n.isFinite else { return Int.max / 4 }
        if n < 1 { return 1 }
        if n > 1_000_000_000 { return Int.max / 4 }
        return Int(n)
    }
}

/// Running plan bounds of the minimap inputs (finite points only).
struct CoverageLiveMinimapExtent {
    /// Smallest and largest plan coordinates seen, nil before the first finite point.
    private(set) var low: SIMD2<Float>?
    private(set) var high: SIMD2<Float>?

    /// Grows the bounds to include `p`; non-finite points are ignored.
    mutating func include(_ p: SIMD2<Float>) {
        guard p.x.isFinite, p.y.isFinite else { return }
        if let l = low, let h = high {
            low = simd_min(l, p)
            high = simd_max(h, p)
        } else {
            low = p
            high = p
        }
    }
}
