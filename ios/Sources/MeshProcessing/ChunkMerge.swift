import Foundation
import simd

/// One ARKit mesh anchor's geometry in anchor-local coordinates, with its anchor to world
/// transform and optional attributes: the input of `ChunkMerge.merge`. Named MergeChunk so
/// it does not clash with Core's stored `MeshChunk` record in the same app target.
struct MergeChunk {
    /// Triangles in anchor-local coordinates.
    var localMesh: TriangleMesh
    /// Anchor to world transform.
    var anchorTransform: simd_float4x4
    /// Classification per triangle of `localMesh`, or nil.
    var faceClass: [UInt8]?
    /// Color per vertex of `localMesh`, or nil.
    var vertexColor: [SIMD4<UInt8>]?

    /// Creates a chunk from its local mesh, transform and optional attributes.
    init(localMesh: TriangleMesh, anchorTransform: simd_float4x4, faceClass: [UInt8]? = nil, vertexColor: [SIMD4<UInt8>]? = nil) {
        self.localMesh = localMesh
        self.anchorTransform = anchorTransform
        self.faceClass = faceClass
        self.vertexColor = vertexColor
    }
}

/// Merges ARKit mesh chunks into one world-space mesh: transform, append, weld duplicate
/// vertices at chunk borders, then drop degenerate and duplicate triangles. Face classes
/// and vertex colors follow their faces and vertices.
enum ChunkMerge {
    /// Default weld distance in meters (chunk borders overlap within a few millimeters).
    static let defaultWeldTolerance: Float = 0.005
    /// Triangles with a smaller area (square meters) count as degenerate.
    static let defaultMinimumArea: Float = 1e-10
    /// Color used for vertices of chunks without colors when other chunks have them.
    private static let white = SIMD4<UInt8>(255, 255, 255, 255)

    /// Transforms every chunk to world space (`TriangleMesh.transformed(by:)`), appends
    /// them, welds vertices closer than `weldTolerance` (`TriangleMesh.weldMap`, the kept
    /// vertex keeps its color) and removes degenerate and duplicate faces (the first copy
    /// of a duplicate wins, so earlier chunks take priority). Triangles with out-of-range
    /// indices are dropped. An attribute present on some chunks only is filled with
    /// defaults (unclassified, white) for the others; a chunk attribute array of the wrong
    /// length is treated like a missing one (face classes are padded with unclassified).
    static func merge(_ chunks: [MergeChunk], weldTolerance: Float = ChunkMerge.defaultWeldTolerance) -> MeshWithAttributes {
        let hasClass = chunks.contains { $0.faceClass != nil }
        let hasColor = chunks.contains { $0.vertexColor != nil }
        let totalVertices = chunks.reduce(0) { $0 + $1.localMesh.positions.count }
        let totalFaces = chunks.reduce(0) { $0 + $1.localMesh.triangleCount }
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var classes: [UInt8] = []
        var colors: [SIMD4<UInt8>] = []
        positions.reserveCapacity(totalVertices)
        indices.reserveCapacity(3 * totalFaces)
        if hasClass { classes.reserveCapacity(totalFaces) }
        if hasColor { colors.reserveCapacity(totalVertices) }

        for chunk in chunks {
            let world = chunk.localMesh.transformed(by: chunk.anchorTransform)
            let base = UInt32(positions.count)
            let localCount = world.positions.count
            positions.append(contentsOf: world.positions)
            if hasColor {
                if let source = chunk.vertexColor, source.count == localCount {
                    colors.append(contentsOf: source)
                } else {
                    colors.append(contentsOf: [SIMD4<UInt8>](repeating: white, count: localCount))
                }
            }
            let limit = UInt32(localCount)
            for t in 0..<world.triangleCount {
                let a = world.indices[3 * t], b = world.indices[3 * t + 1], c = world.indices[3 * t + 2]
                guard a < limit, b < limit, c < limit else { continue }
                indices.append(a + base)
                indices.append(b + base)
                indices.append(c + base)
                if hasClass {
                    if let source = chunk.faceClass, t < source.count {
                        classes.append(source[t])
                    } else {
                        classes.append(MeshWithAttributes.unclassified)
                    }
                }
            }
        }

        let weld = TriangleMesh(positions: positions, indices: []).weldMap(tolerance: weldTolerance)
        let remapped = indices.map { weld.remap[Int($0)] }
        var keptColors: [SIMD4<UInt8>]?
        if hasColor {
            var out = [SIMD4<UInt8>](repeating: white, count: weld.positions.count)
            var assigned = [Bool](repeating: false, count: weld.positions.count)
            for i in 0..<weld.remap.count {
                let k = Int(weld.remap[i])
                if !assigned[k] {
                    assigned[k] = true
                    out[k] = colors[i]
                }
            }
            keptColors = out
        }
        let welded = MeshWithAttributes(mesh: TriangleMesh(positions: weld.positions, indices: remapped),
                                        faceClass: hasClass ? classes : nil, vertexColor: keptColors)
        return removingDegenerateAndDuplicateFaces(welded)
    }

    /// The mesh without degenerate faces (an out-of-range or repeated index, or an area
    /// below `minimumArea` or not finite) and without duplicate faces (the same three
    /// vertices in any order or winding; the first one is kept). Unused vertices are
    /// dropped and attributes follow (`MeshWithAttributes.keepingFaces`).
    static func removingDegenerateAndDuplicateFaces(_ input: MeshWithAttributes,
                                                    minimumArea: Float = ChunkMerge.defaultMinimumArea) -> MeshWithAttributes {
        let mesh = input.mesh
        let n = UInt32(mesh.positions.count)
        var seen = Set<SIMD3<UInt32>>()
        seen.reserveCapacity(mesh.triangleCount)
        var keep = [Bool](repeating: false, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[3 * t], b = mesh.indices[3 * t + 1], c = mesh.indices[3 * t + 2]
            guard a < n, b < n, c < n, a != b, b != c, a != c else { continue }
            let area = MeshTopology.area(mesh, t)
            guard area.isFinite, area >= minimumArea else { continue }
            let lo = Swift.min(a, Swift.min(b, c))
            let hi = Swift.max(a, Swift.max(b, c))
            // The three indices are distinct, so XOR of all five leaves the middle one.
            let mid = a ^ b ^ c ^ lo ^ hi
            guard seen.insert(SIMD3<UInt32>(lo, mid, hi)).inserted else { continue }
            keep[t] = true
        }
        return input.keepingFaces(keep)
    }
}
