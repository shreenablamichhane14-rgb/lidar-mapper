import Foundation
import simd

/// A `TriangleMesh` with optional per-face and per-vertex attribute arrays that travel with
/// it through merge, cleanup, simplification, hole filling and cropping.
///
/// Per-face arrays have one entry per triangle (`mesh.triangleCount`); per-vertex arrays
/// have one entry per position. A nil array means the attribute is absent. Functions in
/// MeshProcessing never mutate their input and always return arrays of the right length.
struct MeshWithAttributes: Equatable {
    /// The geometry.
    var mesh: TriangleMesh
    /// ARKit face classification raw value per triangle (ARMeshClassification: 0 none,
    /// 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door).
    var faceClass: [UInt8]?
    /// RGBA color per vertex.
    var vertexColor: [SIMD4<UInt8>]?
    /// True for triangles the app made up (hole filling), shown as INFERRED in the UI.
    var isInferred: [Bool]?

    /// Classification value used for faces with no known class.
    static let unclassified: UInt8 = 0

    /// Wraps a mesh and its attributes.
    init(mesh: TriangleMesh, faceClass: [UInt8]? = nil, vertexColor: [SIMD4<UInt8>]? = nil, isInferred: [Bool]? = nil) {
        self.mesh = mesh
        self.faceClass = faceClass
        self.vertexColor = vertexColor
        self.isInferred = isInferred
    }

    /// Number of triangles.
    var triangleCount: Int { mesh.triangleCount }

    /// True when every present attribute array has the right length and every index is in
    /// range.
    var isConsistent: Bool {
        let faces = mesh.triangleCount
        if let c = faceClass, c.count != faces { return false }
        if let f = isInferred, f.count != faces { return false }
        if let v = vertexColor, v.count != mesh.positions.count { return false }
        let n = UInt32(mesh.positions.count)
        return mesh.indices.count % 3 == 0 && mesh.indices.allSatisfy { $0 < n }
    }

    /// Number of faces flagged inferred.
    var inferredCount: Int {
        guard let flags = isInferred else { return 0 }
        return flags.filter { $0 }.count
    }

    /// The mesh with only the faces whose `keep` entry is true (missing entries count as
    /// false), with unused vertices dropped and indices, face and vertex attributes
    /// compacted to match. Face order and relative vertex order are preserved.
    func keepingFaces(_ keep: [Bool]) -> MeshWithAttributes {
        let faces = mesh.triangleCount
        let vertexCount = mesh.positions.count
        var remap = [Int32](repeating: -1, count: vertexCount)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<UInt8>]? = vertexColor.map { _ in [] }
        var indices: [UInt32] = []
        var classes: [UInt8]? = faceClass.map { _ in [] }
        var inferred: [Bool]? = isInferred.map { _ in [] }
        indices.reserveCapacity(mesh.indices.count)
        for t in 0..<faces where t < keep.count && keep[t] {
            let corners = [Int(mesh.indices[3 * t]), Int(mesh.indices[3 * t + 1]), Int(mesh.indices[3 * t + 2])]
            guard corners.allSatisfy({ $0 < vertexCount }) else { continue }
            for v in corners {
                if remap[v] < 0 {
                    remap[v] = Int32(positions.count)
                    positions.append(mesh.positions[v])
                    if let source = vertexColor, v < source.count { colors?.append(source[v]) }
                }
                indices.append(UInt32(remap[v]))
            }
            if let source = faceClass { classes?.append(t < source.count ? source[t] : MeshWithAttributes.unclassified) }
            if let source = isInferred { inferred?.append(t < source.count ? source[t] : false) }
        }
        if let c = colors, c.count != positions.count { colors = nil }
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices),
                                  faceClass: classes, vertexColor: colors, isInferred: inferred)
    }

    /// Both meshes in one (indices of `other` shifted). An attribute present on only one
    /// side is filled with defaults (unclassified, white, not inferred) for the other.
    func appending(_ other: MeshWithAttributes) -> MeshWithAttributes {
        let merged = mesh.merged(with: other.mesh)
        func join<T>(_ a: [T]?, _ aCount: Int, _ b: [T]?, _ bCount: Int, _ fill: T) -> [T]? {
            if a == nil && b == nil { return nil }
            return (a ?? [T](repeating: fill, count: aCount)) + (b ?? [T](repeating: fill, count: bCount))
        }
        let white = SIMD4<UInt8>(255, 255, 255, 255)
        return MeshWithAttributes(
            mesh: merged,
            faceClass: join(faceClass, mesh.triangleCount, other.faceClass, other.mesh.triangleCount, MeshWithAttributes.unclassified),
            vertexColor: join(vertexColor, mesh.positions.count, other.vertexColor, other.mesh.positions.count, white),
            isInferred: join(isInferred, mesh.triangleCount, other.isInferred, other.mesh.triangleCount, false))
    }
}

/// Small topology helpers shared by the MeshProcessing files. All work on flat arrays.
enum MeshTopology {
    /// Key for an undirected edge: (smaller index, larger index) packed into 64 bits.
    static func edgeKey(_ i: UInt32, _ j: UInt32) -> UInt64 {
        let lo = min(i, j), hi = max(i, j)
        return UInt64(lo) << 32 | UInt64(hi)
    }

    /// The two vertex indices of an edge key, smaller first.
    static func edgeVertices(_ key: UInt64) -> (UInt32, UInt32) {
        (UInt32(truncatingIfNeeded: key >> 32), UInt32(truncatingIfNeeded: key))
    }

    /// Centroid of triangle `t`, or nil when an index is out of range.
    static func centroid(_ mesh: TriangleMesh, _ t: Int) -> SIMD3<Float>? {
        guard let corners = mesh.triangle(t) else { return nil }
        return (corners.0 + corners.1 + corners.2) / 3
    }

    /// Unnormalized normal (cross product, length = 2 x area) of triangle `t`; zero when an
    /// index is out of range.
    static func areaVector(_ mesh: TriangleMesh, _ t: Int) -> SIMD3<Float> {
        guard let corners = mesh.triangle(t) else { return .zero }
        return simd_cross(corners.1 - corners.0, corners.2 - corners.0)
    }

    /// Area of triangle `t`.
    static func area(_ mesh: TriangleMesh, _ t: Int) -> Float {
        simd_length(areaVector(mesh, t)) * 0.5
    }
}

/// Undirected edge to face incidence as flat sorted arrays (no dictionary, no per-edge
/// objects). Entry k is corner edge `slot[k] % 3` of face `slot[k] / 3`; entries are
/// sorted by `key`, so all uses of one edge are contiguous. Faces with an out-of-range
/// index are skipped.
struct EdgeTable {
    /// Undirected edge key per entry (see `MeshTopology.edgeKey`), ascending.
    let keys: [UInt64]
    /// `3 * face + corner` per entry: the edge runs from corner to corner + 1 (mod 3).
    let slots: [UInt32]
    /// Start of each distinct edge's run in `keys`/`slots`, plus a final `keys.count`.
    let runStarts: [Int]

    /// Builds the table for `mesh` in O(n log n).
    init(mesh: TriangleMesh) {
        let faces = mesh.triangleCount
        let n = UInt32(mesh.positions.count)
        var pairs: [(UInt64, UInt32)] = []
        pairs.reserveCapacity(faces * 3)
        for t in 0..<faces {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            guard a < n, b < n, c < n else { continue }
            pairs.append((MeshTopology.edgeKey(a, b), UInt32(3 * t)))
            pairs.append((MeshTopology.edgeKey(b, c), UInt32(3 * t + 1)))
            pairs.append((MeshTopology.edgeKey(c, a), UInt32(3 * t + 2)))
        }
        pairs.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        keys = pairs.map { $0.0 }
        slots = pairs.map { $0.1 }
        var starts: [Int] = []
        starts.reserveCapacity(pairs.count / 2 + 1)
        for k in 0..<pairs.count where k == 0 || pairs[k].0 != pairs[k - 1].0 {
            starts.append(k)
        }
        starts.append(pairs.count)
        runStarts = starts
    }

    /// Number of distinct undirected edges.
    var edgeCount: Int { runStarts.count - 1 }

    /// Entry range of distinct edge `e` (0 ..< edgeCount).
    func run(_ e: Int) -> Range<Int> { runStarts[e]..<runStarts[e + 1] }

    /// Directed (from, to) of entry `k` in its face's winding.
    func directed(_ k: Int, in mesh: TriangleMesh) -> (UInt32, UInt32) {
        let slot = Int(slots[k])
        let face = slot / 3, corner = slot % 3
        return (mesh.indices[3 * face + corner], mesh.indices[3 * face + (corner + 1) % 3])
    }
}

/// Disjoint-set forest with path halving and union by size, over `0 ..< count`.
struct UnionFind {
    private var parent: [Int32]
    private var size: [Int32]

    /// `count` singleton sets.
    init(count: Int) {
        parent = (0..<count).map { Int32($0) }
        size = [Int32](repeating: 1, count: count)
    }

    /// Representative of `x`'s set.
    mutating func find(_ x: Int) -> Int {
        var i = x
        while Int(parent[i]) != i {
            parent[i] = parent[Int(parent[i])]
            i = Int(parent[i])
        }
        return i
    }

    /// Joins the sets of `a` and `b`; returns false when they were already joined.
    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Bool {
        var ra = find(a), rb = find(b)
        guard ra != rb else { return false }
        if size[ra] < size[rb] { swap(&ra, &rb) }
        parent[rb] = Int32(ra)
        size[ra] += size[rb]
        return true
    }
}
