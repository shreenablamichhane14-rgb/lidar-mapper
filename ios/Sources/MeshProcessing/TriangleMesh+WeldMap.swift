import Foundation
import simd

// Geometry's `TriangleMesh.welded(tolerance:)` returns only the welded mesh, so attributes
// (face classes, vertex colors) cannot follow it. This extension runs the same spatial-hash
// clustering (cell size = tolerance, 27-cell search, first vertex of a cluster kept) but
// returns the vertex remap, so callers can carry attributes. Candidate for Geometry.

extension TriangleMesh {
    /// Integer cell of the weld grid.
    private struct WeldCell: Hashable {
        var x: Int32, y: Int32, z: Int32
    }

    /// Clusters vertices closer than `tolerance` exactly like `welded(tolerance:)` and
    /// returns the kept positions plus `remap[i]`, the kept index of original vertex `i`.
    /// Non-finite positions are never merged. Triangles are not touched.
    func weldMap(tolerance: Float) -> (positions: [SIMD3<Float>], remap: [UInt32]) {
        let cellSize = Swift.max(tolerance, TriangleMesh.minimumWeldTolerance)
        let toleranceSquared = cellSize * cellSize
        let limit = Float(Int32.max / 2)
        func cell(_ p: SIMD3<Float>) -> WeldCell {
            let q = simd_clamp((p / cellSize).rounded(.down), SIMD3<Float>(repeating: -limit), SIMD3<Float>(repeating: limit))
            return WeldCell(x: Int32(q.x), y: Int32(q.y), z: Int32(q.z))
        }

        var grid: [WeldCell: [UInt32]] = [:]
        grid.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        var kept: [SIMD3<Float>] = []
        kept.reserveCapacity(positions.count)
        for (i, p) in positions.enumerated() {
            let finite = p.x.isFinite && p.y.isFinite && p.z.isFinite
            var match: UInt32?
            if finite {
                let home = cell(p)
                search: for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 {
                            let key = WeldCell(x: home.x &+ dx, y: home.y &+ dy, z: home.z &+ dz)
                            guard let bucket = grid[key] else { continue }
                            for candidate in bucket where simd_distance_squared(kept[Int(candidate)], p) <= toleranceSquared {
                                match = candidate
                                break search
                            }
                        }
                    }
                }
                if match == nil {
                    grid[home, default: []].append(UInt32(kept.count))
                }
            }
            if let match = match {
                remap[i] = match
            } else {
                remap[i] = UInt32(kept.count)
                kept.append(p)
            }
        }
        return (kept, remap)
    }
}
