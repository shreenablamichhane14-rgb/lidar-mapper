import Foundation
import simd

/// An indexed triangle mesh: every 3 entries of `indices` name one triangle's corners in
/// `positions`, counter-clockwise when seen from outside. Indices must be in range;
/// functions that read triangles skip any triangle with an out-of-range index.
struct TriangleMesh: Equatable {
    /// Vertex positions in meters.
    var positions: [SIMD3<Float>]
    /// Triangle corner indices, 3 per triangle.
    var indices: [UInt32]

    /// Default weld distance: 0.1 mm, well under LiDAR noise.
    static let defaultWeldTolerance: Float = 1e-4
    /// Smallest weld tolerance accepted; smaller values are clamped to it.
    static let minimumWeldTolerance: Float = 1e-7
    /// Normal returned for vertices with no non-degenerate adjacent triangle.
    static let fallbackNormal = SIMD3<Float>(0, 1, 0)

    /// Creates a mesh from positions and triangle indices.
    init(positions: [SIMD3<Float>] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.indices = indices
    }

    /// Number of whole triangles (a trailing partial triangle is ignored).
    var triangleCount: Int { indices.count / 3 }

    /// Corners of triangle `t`, or nil when one of its indices is out of range.
    func triangle(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        let i0 = Int(indices[3 * t]), i1 = Int(indices[3 * t + 1]), i2 = Int(indices[3 * t + 2])
        let n = positions.count
        guard i0 < n, i1 < n, i2 < n else { return nil }
        return (positions[i0], positions[i1], positions[i2])
    }

    /// Total area of all triangles.
    var surfaceArea: Float {
        var sum: Double = 0
        for t in 0..<triangleCount {
            guard let corners = triangle(t) else { continue }
            let (a, b, c) = corners
            sum += Double(simd_length(simd_cross(b - a, c - a))) * 0.5
        }
        return Float(sum)
    }

    /// Bounds of all vertex positions; `AABB3.empty` when there are none.
    var boundingBox: AABB3 { AABB3(points: positions) }

    /// Signed enclosed volume by the divergence theorem (sum of signed tetrahedra to a
    /// common apex). Positive for a closed mesh with outward (counter-clockwise) winding. Only
    /// meaningful when `isWatertight` is true.
    var signedVolume: Float {
        // Tetrahedra to the first vertex instead of the origin (same result for a closed
        // mesh), in Double, to avoid cancellation for meshes far from the origin.
        guard let first = positions.first else { return 0 }
        let reference = SIMD3<Double>(first)
        var sum: Double = 0
        for t in 0..<triangleCount {
            guard let corners = triangle(t) else { continue }
            let a = SIMD3<Double>(corners.0) - reference
            let b = SIMD3<Double>(corners.1) - reference
            let c = SIMD3<Double>(corners.2) - reference
            sum += simd_dot(a, simd_cross(b, c))
        }
        return Float(sum / 6)
    }

    /// Key for an undirected edge: the ordered pair (smaller index, larger index) packed
    /// into 64 bits.
    private static func edgeKey(_ i: UInt32, _ j: UInt32) -> UInt64 {
        let lo = Swift.min(i, j), hi = Swift.max(i, j)
        return UInt64(lo) << 32 | UInt64(hi)
    }

    /// For every undirected edge, how many triangles use it, plus the directed edge as the
    /// first triangle saw it.
    private func edgeUse() -> [UInt64: (count: Int, from: UInt32, to: UInt32)] {
        var edges: [UInt64: (count: Int, from: UInt32, to: UInt32)] = [:]
        edges.reserveCapacity(indices.count)
        for t in 0..<triangleCount {
            for k in 0..<3 {
                let from = indices[3 * t + k]
                let to = indices[3 * t + (k + 1) % 3]
                let key = TriangleMesh.edgeKey(from, to)
                if let existing = edges[key] {
                    edges[key] = (existing.count + 1, existing.from, existing.to)
                } else {
                    edges[key] = (1, from, to)
                }
            }
        }
        return edges
    }

    /// True when the mesh has triangles and every edge is shared by exactly two of them.
    /// Topological only: meshes with duplicated vertices along seams need `welded` first.
    var isWatertight: Bool {
        guard triangleCount > 0 else { return false }
        return edgeUse().values.allSatisfy { $0.count == 2 }
    }

    /// Edges used by exactly one triangle, as directed (from, to) in that triangle's
    /// winding, sorted by (from, to).
    var boundaryEdges: [(UInt32, UInt32)] {
        edgeUse().values
            .filter { $0.count == 1 }
            .map { ($0.from, $0.to) }
            .sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
    }

    /// Area-weighted vertex normals (each triangle adds its unnormalized cross product to
    /// its corners). Vertices without any non-degenerate triangle get `fallbackNormal`.
    var vertexNormals: [SIMD3<Float>] {
        var sums = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in 0..<triangleCount {
            guard let corners = triangle(t) else { continue }
            let (a, b, c) = corners
            let weighted = simd_cross(b - a, c - a)
            for k in 0..<3 {
                sums[Int(indices[3 * t + k])] += weighted
            }
        }
        return sums.map { sum in
            let length = simd_length(sum)
            return length > 0 && length.isFinite ? sum / length : TriangleMesh.fallbackNormal
        }
    }

    /// The mesh with every position transformed by `m` (with perspective divide when w is
    /// not 1). Mirroring transforms (negative determinant) also reverse the winding so the
    /// outside stays counter-clockwise.
    func transformed(by m: simd_float4x4) -> TriangleMesh {
        let moved = positions.map { p -> SIMD3<Float> in
            let h = simd_mul(m, SIMD4<Float>(p, 1))
            return h.w != 0 && h.w != 1 ? SIMD3<Float>(h.x, h.y, h.z) / h.w : SIMD3<Float>(h.x, h.y, h.z)
        }
        var result = TriangleMesh(positions: moved, indices: indices)
        if simd_determinant(m) < 0 {
            for t in 0..<triangleCount {
                result.indices.swapAt(3 * t + 1, 3 * t + 2)
            }
        }
        return result
    }

    /// Both meshes in one, with `other`'s indices shifted past this mesh's vertices.
    func merged(with other: TriangleMesh) -> TriangleMesh {
        let offset = UInt32(positions.count)
        var result = self
        result.positions.append(contentsOf: other.positions)
        result.indices.reserveCapacity(indices.count + other.indices.count)
        result.indices.append(contentsOf: other.indices.map { $0 + offset })
        return result
    }

    /// Integer cell of the weld grid.
    private struct Cell: Hashable {
        var x: Int32, y: Int32, z: Int32
    }

    /// Merges vertices closer than `tolerance` using a spatial hash grid with cell size
    /// equal to the tolerance (each vertex checks the 27 neighboring cells). The first vertex
    /// seen in a cluster is kept. Triangles that collapse (two equal corners) and triangles
    /// with out-of-range indices are dropped.
    func welded(tolerance: Float = TriangleMesh.defaultWeldTolerance) -> TriangleMesh {
        let cellSize = Swift.max(tolerance, TriangleMesh.minimumWeldTolerance)
        let toleranceSquared = cellSize * cellSize
        let limit = Float(Int32.max / 2)
        func cell(_ p: SIMD3<Float>) -> Cell {
            let q = simd_clamp(simd_floor(p / cellSize), SIMD3<Float>(repeating: -limit), SIMD3<Float>(repeating: limit))
            return Cell(x: Int32(q.x), y: Int32(q.y), z: Int32(q.z))
        }

        var grid: [Cell: [UInt32]] = [:]
        grid.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        var kept: [SIMD3<Float>] = []
        kept.reserveCapacity(positions.count)
        for (i, p) in positions.enumerated() {
            let finite = p.x.isFinite && p.y.isFinite && p.z.isFinite
            let home = finite ? cell(p) : Cell(x: Int32.max, y: Int32.max, z: Int32.max)
            var match: UInt32?
            if finite {
                search: for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 {
                            let key = Cell(x: home.x &+ dx, y: home.y &+ dy, z: home.z &+ dz)
                            guard let bucket = grid[key] else { continue }
                            for candidate in bucket where simd_distance_squared(kept[Int(candidate)], p) <= toleranceSquared {
                                match = candidate
                                break search
                            }
                        }
                    }
                }
            }
            if let match = match {
                remap[i] = match
            } else {
                let index = UInt32(kept.count)
                kept.append(p)
                grid[home, default: []].append(index)
                remap[i] = index
            }
        }

        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(indices.count)
        for t in 0..<triangleCount {
            let i0 = Int(indices[3 * t]), i1 = Int(indices[3 * t + 1]), i2 = Int(indices[3 * t + 2])
            guard i0 < remap.count, i1 < remap.count, i2 < remap.count else { continue }
            let a = remap[i0], b = remap[i1], c = remap[i2]
            guard a != b, b != c, a != c else { continue }
            newIndices.append(contentsOf: [a, b, c])
        }
        return TriangleMesh(positions: kept, indices: newIndices)
    }
}
